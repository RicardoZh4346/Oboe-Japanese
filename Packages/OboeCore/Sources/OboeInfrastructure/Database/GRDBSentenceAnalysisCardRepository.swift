import Foundation
import GRDB
import OboeDomain

public struct GRDBSentenceAnalysisCardRepository: SentenceAnalysisCardRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func commitSentenceAnalysisCards(
        _ batch: SentenceAnalysisCardBatchCommit,
        capture: CaptureCommitContext?
    ) async throws -> SentenceAnalysisCardBatchResult {
        guard !batch.items.isEmpty else {
            throw SentenceAnalysisCardCreationError.selectionRequired
        }
        guard batch.items.count <= SentenceAnalysisCardCreationService.maximumBatchItems else {
            throw SentenceAnalysisCardCreationError.tooManyItems(
                maximum: SentenceAnalysisCardCreationService.maximumBatchItems
            )
        }
        return try await pool.write { db in
            if let capture {
                let digest = CaptureCommitDigest.batch(batch)
                if let receipt = try GRDBInboxRepository.fetchCommitReceiptRow(
                    operationID: capture.operationID,
                    in: db
                ) {
                    return try Self.replayCommitReceipt(
                        receipt,
                        expectedPayloadHash: digest
                    )
                }
            }
            for memberDeckID in batch.deckIDs {
                try Self.requireDeck(memberDeckID, in: db)
            }
            guard batch.items.allSatisfy({ item in
                switch item {
                case let .vocabulary(commit):
                    commit.deckID == batch.deckID && commit.deckIDs == batch.deckIDs
                case let .grammar(commit):
                    commit.deckID == batch.deckID && commit.deckIDs == batch.deckIDs
                }
            }) else {
                throw ContentCardError.deckNotFound
            }

            var noteIDs: [UUID] = []
            var cardCount = 0
            for item in batch.items {
                switch item {
                case let .vocabulary(commit):
                    try Self.insertVocabulary(commit, in: db)
                    noteIDs.append(commit.noteID)
                    cardCount += commit.cards.count
                case let .grammar(commit):
                    try Self.insertGrammar(commit, in: db)
                    noteIDs.append(commit.noteID)
                    cardCount += 1
                }
            }
            let result = SentenceAnalysisCardBatchResult(
                noteIDs: noteIDs,
                cardCount: cardCount
            )
            if let capture {
                let committedAt = batch.items.first?.createdAt ?? Date()
                try GRDBContentCardRepository.recordCaptureCommit(
                    capture,
                    payloadHash: CaptureCommitDigest.batch(batch),
                    resultJSON: Self.encodeBatchResult(result),
                    inboxItemID: capture.inboxItemID,
                    at: committedAt,
                    in: db
                )
            }
            return result
        }
    }

    /// Identical semantics to the single-commit receipt replay.
    static func replayCommitReceipt(
        _ receiptRow: Row,
        expectedPayloadHash: String
    ) throws -> SentenceAnalysisCardBatchResult {
        let receipt = try GRDBInboxRepository.decodeCommitReceipt(receiptRow)
        guard receipt.payloadHash == expectedPayloadHash else {
            throw InboxError.commitPayloadConflict(operationID: receipt.operationID)
        }
        return try decodeBatchResult(receipt.resultJSON)
    }

    static func encodeBatchResult(_ result: SentenceAnalysisCardBatchResult) -> String {
        let ids = result.noteIDs
            .map { "\"" + $0.uuidString + "\"" }
            .joined(separator: ",")
        return #"{"note_ids":["# + ids + #"],"card_count":"# + String(result.cardCount) + "}"
    }

    static func decodeBatchResult(_ json: String) throws -> SentenceAnalysisCardBatchResult {
        struct Stored: Decodable {
            let noteIDs: [UUID]
            let cardCount: Int
            enum CodingKeys: String, CodingKey {
                case noteIDs = "note_ids"
                case cardCount = "card_count"
            }
        }
        let stored = try JSONDecoder().decode(Stored.self, from: Data(json.utf8))
        return SentenceAnalysisCardBatchResult(
            noteIDs: stored.noteIDs,
            cardCount: stored.cardCount
        )
    }

    /// In-transaction note+example+tags+cards insert — shared with the AI
    /// split commit (设计 §6.5) so a repair split and a sentence-analysis
    /// batch can never diverge on how a new note is born: `origin` comes
    /// from the commit, `source_ref` stays NULL (schema CHECK), cards land
    /// in New state through the configured-profile flow.
    static func insertVocabulary(
        _ commit: VocabularyContentCommit,
        in db: Database
    ) throws {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
            candidateID: commit.schedulerProfileID,
            createdAtMilliseconds: timestamp,
            in: db
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    part_of_speech, jlpt, notes, origin, source_text,
                    pitch_accent, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(commit.noteID),
                DatabaseValueCodec.encode(commit.deckID),
                commit.content.headword,
                commit.content.reading,
                commit.content.meaningZH,
                commit.content.partOfSpeech,
                commit.content.jlpt?.rawValue,
                commit.content.notes,
                commit.origin.rawValue,
                commit.sourceText,
                commit.content.pitchAccent?.rawValue,
                timestamp,
                timestamp
            ]
        )
        try GRDBContentCardRepository.insertMemberships(
            noteID: commit.noteID,
            deckIDs: commit.deckIDs,
            atMilliseconds: timestamp,
            in: db
        )
        if let example = commit.content.example {
            try insertExample(
                id: commit.exampleID,
                noteID: commit.noteID,
                japanese: example.japanese,
                translationZH: example.translationZH,
                in: db
            )
        }
        try insertTags(commit.tags, noteID: commit.noteID, in: db)
        for card in commit.cards {
            guard card.templateKind.knowledgePointKind == .vocabulary else {
                throw ContentCardError.invalidTemplateForKnowledgePoint
            }
            try insertCard(
                card,
                noteID: commit.noteID,
                profileID: profileID,
                timestamp: timestamp,
                in: db
            )
        }
    }

    static func insertGrammar(
        _ commit: GrammarContentCommit,
        in db: Database
    ) throws {
        guard commit.card.templateKind == .grammarFormToExplanation else {
            throw ContentCardError.invalidTemplateForKnowledgePoint
        }
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
            candidateID: commit.schedulerProfileID,
            createdAtMilliseconds: timestamp,
            in: db
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, meaning_zh, usage,
                    connection, jlpt, notes, origin, source_text,
                    content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'grammar', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(commit.noteID),
                DatabaseValueCodec.encode(commit.deckID),
                commit.content.grammarForm,
                commit.content.meaningZH,
                commit.content.usage,
                commit.content.connection,
                commit.content.jlpt?.rawValue,
                commit.content.notes,
                commit.origin.rawValue,
                commit.sourceText,
                timestamp,
                timestamp
            ]
        )
        try GRDBContentCardRepository.insertMemberships(
            noteID: commit.noteID,
            deckIDs: commit.deckIDs,
            atMilliseconds: timestamp,
            in: db
        )
        if let example = commit.content.example {
            try insertExample(
                id: commit.exampleID,
                noteID: commit.noteID,
                japanese: example.japanese,
                translationZH: example.translationZH,
                in: db
            )
        }
        try insertTags(commit.tags, noteID: commit.noteID, in: db)
        try insertCard(
            commit.card,
            noteID: commit.noteID,
            profileID: profileID,
            timestamp: timestamp,
            in: db
        )
    }

    static func requireDeck(_ deckID: UUID, in db: Database) throws {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
            arguments: [DatabaseValueCodec.encode(deckID)]
        ) == true else {
            throw ContentCardError.deckNotFound
        }
    }

    private static func insertExample(
        id: UUID,
        noteID: UUID,
        japanese: String,
        translationZH: String?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                VALUES (?, ?, ?, ?, 0)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(noteID),
                japanese,
                translationZH
            ]
        )
    }

    private static func insertTags(
        _ tags: [KnowledgeTag],
        noteID: UUID,
        in db: Database
    ) throws {
        for tag in tags {
            try db.execute(
                sql: """
                    INSERT INTO tags(id, name, normalized_name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(normalized_name) DO NOTHING
                    """,
                arguments: [DatabaseValueCodec.encode(tag.id), tag.name, tag.normalizedName]
            )
            guard let tagID: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE normalized_name = ?",
                arguments: [tag.normalizedName]
            ) else { continue }
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [DatabaseValueCodec.encode(noteID), tagID]
            )
        }
    }

    private static func insertCard(
        _ card: NewCardSeed,
        noteID: UUID,
        profileID: UUID,
        timestamp: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cards(
                    id, note_id, template_kind, is_enabled, state, due_at_ms,
                    stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                    learning_step, state_version, algorithm_version, profile_id
                ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(card.id),
                DatabaseValueCodec.encode(noteID),
                card.templateKind.rawValue,
                timestamp,
                SwiftFSRSReviewScheduler.algorithmVersion,
                DatabaseValueCodec.encode(profileID)
            ]
        )
    }
}
