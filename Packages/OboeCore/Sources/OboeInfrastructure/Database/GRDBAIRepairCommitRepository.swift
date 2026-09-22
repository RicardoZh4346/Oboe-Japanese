import Foundation
import GRDB
import OboeDomain

/// Single-transaction in-place repair commit (设计 §6.3, T08). One
/// `pool.write` performs the content-version-guarded note update, the
/// primary-example replacement (which feeds the search index through the
/// notes triggers) and the draft's `committed` + receipt upsert — any
/// failure rolls all of it back.
public struct GRDBAIRepairCommitRepository: AIRepairCommitStore, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func commitInPlaceRepair(
        draftID: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        content: AIRepairValidatedContent,
        newExampleID: UUID,
        updatedAt: Date
    ) async throws {
        let payloadJSON = try AIRepairDraftCodec.encode(envelope)
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(updatedAt)
        try await pool.write { db in
            switch content {
            case let .vocabulary(content):
                try updateNote(
                    noteID: envelope.targetNoteID,
                    expectedContentVersion: envelope.expectedContentVersion,
                    assignments: """
                        headword = ?, reading = ?, meaning_zh = ?,
                        part_of_speech = ?, jlpt = ?, notes = ?, pitch_accent = ?
                        """,
                    values: [
                        content.headword,
                        content.reading,
                        content.meaningZH,
                        content.partOfSpeech,
                        content.jlpt?.rawValue,
                        content.notes,
                        content.pitchAccent?.rawValue
                    ],
                    kind: "vocabulary",
                    updatedAtMilliseconds: updatedAtMilliseconds,
                    in: db
                )
                let existingExampleIDs = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM examples WHERE note_id = ? ORDER BY sort_order, id",
                    arguments: [DatabaseValueCodec.encode(envelope.targetNoteID)]
                )
                try GRDBVocabularyRepository.replacePrimaryExample(
                    noteID: envelope.targetNoteID,
                    content: content.example,
                    existingExampleIDs: existingExampleIDs,
                    newExampleID: newExampleID,
                    in: db
                )
            case let .grammar(content):
                try updateNote(
                    noteID: envelope.targetNoteID,
                    expectedContentVersion: envelope.expectedContentVersion,
                    assignments: """
                        headword = ?, meaning_zh = ?, usage = ?,
                        connection = ?, jlpt = ?, notes = ?
                        """,
                    values: [
                        content.grammarForm,
                        content.meaningZH,
                        content.usage,
                        content.connection,
                        content.jlpt?.rawValue,
                        content.notes
                    ],
                    kind: "grammar",
                    updatedAtMilliseconds: updatedAtMilliseconds,
                    in: db
                )
                let existingExampleIDs = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM examples WHERE note_id = ? ORDER BY sort_order, id",
                    arguments: [DatabaseValueCodec.encode(envelope.targetNoteID)]
                )
                try GRDBGrammarRepository.replacePrimaryExample(
                    noteID: envelope.targetNoteID,
                    content: content.example,
                    existingExampleIDs: existingExampleIDs,
                    newExampleID: newExampleID,
                    in: db
                )
            }

            try GRDBAIRepairDraftRepository.saveDraft(
                id: draftID,
                payloadJSON: payloadJSON,
                provenance: provenance,
                updatedAtMilliseconds: updatedAtMilliseconds,
                in: db
            )
        }
    }

    /// Single-transaction split commit (设计 §6.5, T09). Guards run first —
    /// target Note/Card must still exist and belong together, the note's
    /// `content_version` and direction set must match the preview's
    /// snapshot, and the deck must exist — then every candidate's
    /// Note/Example/Cards insert (New state, `origin=ai`, no source refs,
    /// no copied history or tasks), the original card's disposition and
    /// finally the committed-draft receipt. Any throw anywhere aborts the
    /// whole write: the database only ever sees "untouched" or "fully
    /// committed".
    public func commitSplitRepair(
        draftID: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        commits: [AIRepairSplitNoteCommit],
        originalCardDisposition: AIRepairOriginalCardDisposition,
        updatedAt: Date
    ) async throws {
        let payloadJSON = try AIRepairDraftCodec.encode(envelope)
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(updatedAt)
        try await pool.write { db in
            // --- Guards (before any write) --------------------------------
            guard let noteRow = try Row.fetchOne(
                db,
                sql: "SELECT content_version FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(envelope.targetNoteID)]
            ) else {
                throw AIRepairCommitError.targetUnavailable
            }
            let contentVersion: Int = noteRow["content_version"]
            guard contentVersion == envelope.expectedContentVersion else {
                throw AIRepairCommitError.contentConflict
            }
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM cards WHERE id = ? AND note_id = ?)",
                arguments: [
                    DatabaseValueCodec.encode(envelope.targetCardID),
                    DatabaseValueCodec.encode(envelope.targetNoteID)
                ]
            ) == true else {
                throw AIRepairCommitError.targetUnavailable
            }
            let liveKinds = try GRDBContentCardRepository.fetchCardDirections(
                noteID: envelope.targetNoteID,
                in: db
            ).map(\.templateKind)
            guard Set(liveKinds) == Set(envelope.affectedTemplateKinds) else {
                throw AIRepairCommitError.contentConflict
            }

            // --- New notes + cards ---------------------------------------
            for commit in commits {
                guard !commit.cards.isEmpty else {
                    throw AIRepairCommitError.invalidSplitPlan("新笔记至少需要一个学习方向。")
                }
                for memberDeckID in commit.deckIDs.union([commit.deckID]) {
                    try GRDBSentenceAnalysisCardRepository.requireDeck(
                        memberDeckID,
                        in: db
                    )
                }
                switch commit.content {
                case let .vocabulary(content):
                    try GRDBSentenceAnalysisCardRepository.insertVocabulary(
                        VocabularyContentCommit(
                            noteID: commit.noteID,
                            exampleID: commit.exampleID,
                            draftID: nil,
                            deckID: commit.deckID,
                            content: content,
                            tags: [],
                            cards: commit.cards,
                            schedulerProfileID: commit.schedulerProfileID,
                            createdAt: commit.createdAt,
                            origin: .ai,
                            sourceRef: nil,
                            sourceText: nil,
                            deckIDs: commit.deckIDs
                        ),
                        in: db
                    )
                case let .grammar(content):
                    guard commit.cards.count == 1, let card = commit.cards.first else {
                        throw AIRepairCommitError.invalidSplitPlan(
                            "语法候选需要恰好一个学习方向。"
                        )
                    }
                    try GRDBSentenceAnalysisCardRepository.insertGrammar(
                        GrammarContentCommit(
                            noteID: commit.noteID,
                            exampleID: commit.exampleID,
                            draftID: nil,
                            deckID: commit.deckID,
                            content: content,
                            tags: [],
                            card: card,
                            schedulerProfileID: commit.schedulerProfileID,
                            createdAt: commit.createdAt,
                            origin: .ai,
                            sourceText: nil,
                            deckIDs: commit.deckIDs
                        ),
                        in: db
                    )
                }
            }

            // --- Original-card disposition --------------------------------
            switch originalCardDisposition {
            case .keep:
                break
            case .pause:
                _ = try GRDBContentCardRepository.setCardEnabled(
                    cardID: envelope.targetCardID,
                    isEnabled: false,
                    timestampMilliseconds: updatedAtMilliseconds,
                    in: db
                )
            case .delete:
                // §5.3: only the target Card row goes — the note, sibling
                // cards and orphaned history stay untouched.
                try GRDBContentCardRepository.deleteCard(
                    cardID: envelope.targetCardID,
                    in: db
                )
            }

            // --- Committed draft + receipt --------------------------------
            try GRDBAIRepairDraftRepository.saveDraft(
                id: draftID,
                payloadJSON: payloadJSON,
                provenance: provenance,
                updatedAtMilliseconds: updatedAtMilliseconds,
                in: db
            )
        }
    }

    /// Guarded note write: the optimistic-concurrency clause is part of the
    /// UPDATE itself, so a concurrent manual edit can never be overwritten —
    /// zero changed rows means the version moved and the whole transaction
    /// aborts.
    private func updateNote(
        noteID: UUID,
        expectedContentVersion: Int,
        assignments: String,
        values: [DatabaseValueConvertible?],
        kind: String,
        updatedAtMilliseconds: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE notes SET
                    \(assignments),
                    content_version = content_version + 1,
                    updated_at_ms = ?
                WHERE id = ? AND kind = ? AND content_version = ?
                """,
            arguments: StatementArguments(
                values + [
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(noteID),
                    kind,
                    expectedContentVersion
                ]
            )
        )
        guard db.changesCount > 0 else {
            throw AIRepairCommitError.contentConflict
        }
    }
}
