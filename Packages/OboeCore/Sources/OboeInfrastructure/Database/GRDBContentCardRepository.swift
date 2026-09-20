import Foundation
import GRDB
import OboeDomain

public struct GRDBContentCardRepository: ContentCardRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func commitVocabulary(
        _ commit: VocabularyContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        return try await pool.write { db in
            if let capture {
                let digest = CaptureCommitDigest.vocabulary(commit)
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
            if let sourceRef = commit.sourceRef,
               let existing = try Row.fetchOne(
                   db,
                   sql: """
                       SELECT notes.id, COUNT(cards.id) AS card_count
                       FROM notes
                       LEFT JOIN cards ON cards.note_id = notes.id
                       WHERE notes.origin = 'builtin_jlpt' AND notes.source_ref = ?
                       GROUP BY notes.id
                       """,
                   arguments: [sourceRef]
               ) {
                return ContentCommitResult(
                    noteID: try DatabaseValueCodec.decodeUUID(existing["id"]),
                    cardCount: existing["card_count"],
                    wasCreated: false
                )
            }
            try Self.requireDeck(commit.deckID, in: db)
            let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
                candidateID: commit.schedulerProfileID,
                createdAtMilliseconds: timestamp,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, jlpt, notes, origin, source_ref, source_text,
                        content_version, created_at_ms, updated_at_ms
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
                    commit.sourceRef,
                    commit.sourceText,
                    timestamp,
                    timestamp
                ]
            )
            if let example = commit.content.example {
                try Self.insertExample(
                    id: commit.exampleID,
                    noteID: commit.noteID,
                    japanese: example.japanese,
                    translationZH: example.translationZH,
                    in: db
                )
            }
            try Self.insertTags(commit.tags, noteID: commit.noteID, in: db)
            for card in commit.cards {
                guard card.templateKind.knowledgePointKind == .vocabulary else {
                    throw ContentCardError.invalidTemplateForKnowledgePoint
                }
                try Self.insertOrEnableCard(
                    card,
                    noteID: commit.noteID,
                    profileID: profileID,
                    dueAtMilliseconds: timestamp,
                    in: db
                )
            }
            if let draftID = commit.draftID {
                try Self.deleteDraft(id: draftID, kind: "vocabulary", in: db)
            }
            let result = ContentCommitResult(
                noteID: commit.noteID,
                cardCount: commit.cards.count
            )
            if let capture {
                try Self.recordCaptureCommit(
                    capture,
                    payloadHash: CaptureCommitDigest.vocabulary(commit),
                    resultJSON: Self.encodeCommitResult(result),
                    inboxItemID: capture.inboxItemID,
                    at: commit.createdAt,
                    in: db
                )
            }
            return result
        }
    }

    public func commitGrammar(
        _ commit: GrammarContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        return try await pool.write { db in
            if let capture {
                let digest = CaptureCommitDigest.grammar(commit)
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
            try Self.requireDeck(commit.deckID, in: db)
            guard commit.card.templateKind == .grammarFormToExplanation else {
                throw ContentCardError.invalidTemplateForKnowledgePoint
            }
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
            if let example = commit.content.example {
                try Self.insertExample(
                    id: commit.exampleID,
                    noteID: commit.noteID,
                    japanese: example.japanese,
                    translationZH: example.translationZH,
                    in: db
                )
            }
            try Self.insertTags(commit.tags, noteID: commit.noteID, in: db)
            try Self.insertOrEnableCard(
                commit.card,
                noteID: commit.noteID,
                profileID: profileID,
                dueAtMilliseconds: timestamp,
                in: db
            )
            if let draftID = commit.draftID {
                try Self.deleteDraft(id: draftID, kind: "grammar", in: db)
            }
            let result = ContentCommitResult(noteID: commit.noteID, cardCount: 1)
            if let capture {
                try Self.recordCaptureCommit(
                    capture,
                    payloadHash: CaptureCommitDigest.grammar(commit),
                    resultJSON: Self.encodeCommitResult(result),
                    inboxItemID: capture.inboxItemID,
                    at: commit.createdAt,
                    in: db
                )
            }
            return result
        }
    }

    public func fetchCardDirections(noteID: UUID) async throws -> [CardDirectionState] {
        try await pool.read { db in
            try Self.fetchCardDirections(noteID: noteID, in: db)
        }
    }

    public func replaceEnabledCardDirections(
        _ replacement: CardDirectionReplacement
    ) async throws -> [CardDirectionState] {
        let timestamp = try DatabaseValueCodec.encode(replacement.updatedAt)
        return try await pool.write { db in
            guard let persistedKind: String = try String.fetchOne(
                db,
                sql: "SELECT kind FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(replacement.noteID)]
            ) else {
                throw ContentCardError.knowledgePointNotFound
            }
            guard persistedKind == replacement.kind.rawValue else {
                throw ContentCardError.invalidTemplateForKnowledgePoint
            }
            let allowedTemplates = Set(CardTemplateKind.applicable(to: replacement.kind))
            guard replacement.enabledCards.allSatisfy({ allowedTemplates.contains($0.templateKind) }) else {
                throw ContentCardError.invalidTemplateForKnowledgePoint
            }

            let noteID = DatabaseValueCodec.encode(replacement.noteID)
            // Disable every direction card of this note kind. The template
            // list derives from the kind↔template mapping so a template the
            // current whitelist doesn't offer (or a future one) can never
            // linger enabled after a direction-set replacement.
            let kindTemplateValues = CardTemplateKind.allCases
                .filter { $0.knowledgePointKind == replacement.kind }
                .map(\.rawValue)
            let placeholders = kindTemplateValues.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: """
                    UPDATE cards SET is_enabled = 0
                    WHERE note_id = ? AND template_kind IN (\(placeholders))
                    """,
                arguments: StatementArguments([noteID] + kindTemplateValues)
            )

            if !replacement.enabledCards.isEmpty {
                let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
                    candidateID: replacement.schedulerProfileID,
                    createdAtMilliseconds: timestamp,
                    in: db
                )
                for card in replacement.enabledCards {
                    try Self.insertOrEnableCard(
                        card,
                        noteID: replacement.noteID,
                        profileID: profileID,
                        dueAtMilliseconds: timestamp,
                        in: db
                    )
                }
            }

            try Self.cancelPendingTasksForDisabledCards(noteID: replacement.noteID, at: timestamp, in: db)
            return try Self.fetchCardDirections(noteID: replacement.noteID, in: db)
        }
    }

    public func setCardEnabled(
        cardID: UUID,
        isEnabled: Bool,
        at updatedAt: Date
    ) async throws -> CardDirectionState {
        try await pool.write { db in
            try Self.setCardEnabled(
                cardID: cardID,
                isEnabled: isEnabled,
                timestampMilliseconds: DatabaseValueCodec.encode(updatedAt),
                in: db
            )
        }
    }

    public func deleteCard(cardID: UUID) async throws {
        try await pool.write { db in
            try Self.deleteCard(cardID: cardID, in: db)
        }
    }

    /// Single-card suspend/resume (design §5.2). Callable inside a larger
    /// transaction — the repair commit uses it for the "suspend original"
    /// disposition so the choice shares the operation's atomicity (§6.5).
    /// Only `is_enabled` changes: due/stability/difficulty/reps/lapses/
    /// stateVersion, the note and every review log survive untouched.
    static func setCardEnabled(
        cardID: UUID,
        isEnabled: Bool,
        timestampMilliseconds: Int64,
        in db: Database
    ) throws -> CardDirectionState {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT template_kind FROM cards WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(cardID)]
        ) else {
            throw ContentCardError.cardNotFound
        }
        let templateValue: String = row["template_kind"]
        guard let template = CardTemplateKind(rawValue: templateValue) else {
            throw DatabaseValueCodecError.invalidCardTemplate(templateValue)
        }
        try db.execute(
            sql: "UPDATE cards SET is_enabled = ? WHERE id = ?",
            arguments: [isEnabled, DatabaseValueCodec.encode(cardID)]
        )
        if !isEnabled {
            // Same rule replaceEnabledCardDirections applies: pending tasks
            // for the suspended card are cancelled once (COALESCE keeps the
            // first timestamp). Re-enabling never un-cancels — the next
            // study-day preparation decides re-admission (§5.2).
            try db.execute(
                sql: """
                    UPDATE daily_tasks
                    SET cancelled_at_ms = COALESCE(cancelled_at_ms, ?)
                    WHERE card_id = ? AND cancelled_at_ms IS NULL
                    """,
                arguments: [timestampMilliseconds, DatabaseValueCodec.encode(cardID)]
            )
        }
        return CardDirectionState(cardID: cardID, templateKind: template, isEnabled: isEnabled)
    }

    /// Single-card delete (design §5.3): only the target Card row goes —
    /// never the note-level `deleteKnowledgePoint`. `review_logs.card_id`
    /// SET NULLs so `card_key` history stays orphaned (a rebuilt direction
    /// gets a fresh Card.id and must not reattach it), `daily_tasks` rows
    /// cascade, and the Note survives even with zero cards left.
    static func deleteCard(cardID: UUID, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM cards WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(cardID)]
        )
        guard db.changesCount == 1 else {
            throw ContentCardError.cardNotFound
        }
    }

    private static func cancelPendingTasksForDisabledCards(
        noteID: UUID,
        at timestamp: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE daily_tasks
                SET cancelled_at_ms = COALESCE(cancelled_at_ms, ?)
                WHERE card_id IN (
                    SELECT id FROM cards WHERE note_id = ? AND is_enabled = 0
                )
                """,
            arguments: [timestamp, noteID]
        )
    }

    /// Receipt replay: identical operationID + identical content digest returns
    /// the stored result without rewriting anything — including when the note
    /// has since been deleted. A mismatched digest is a real conflict.
    static func replayCommitReceipt(
        _ receiptRow: Row,
        expectedPayloadHash: String
    ) throws -> ContentCommitResult {
        let receipt = try GRDBInboxRepository.decodeCommitReceipt(receiptRow)
        guard receipt.payloadHash == expectedPayloadHash else {
            throw InboxError.commitPayloadConflict(operationID: receipt.operationID)
        }
        return try decodeCommitResult(receipt.resultJSON)
    }

    /// Inside the same transaction: persist the commit receipt and mark the
    /// Inbox item processed, so "create content" and "mark processed" cannot
    /// be separated by a crash.
    static func recordCaptureCommit(
        _ capture: CaptureCommitContext,
        payloadHash: String,
        resultJSON: String,
        inboxItemID: UUID,
        at committedAt: Date,
        in db: Database
    ) throws {
        try GRDBInboxRepository.insertCommitReceipt(
            InboxCommitReceipt(
                operationID: capture.operationID,
                processingContextID: capture.processingContextID,
                payloadHash: payloadHash,
                resultJSON: resultJSON,
                committedAt: committedAt
            ),
            in: db
        )
        try requireCurrentRevision(
            inboxItemID: inboxItemID,
            expected: capture.expectedContentRevision,
            in: db
        )
        _ = try GRDBInboxRepository.transition(
            id: inboxItemID,
            expected: .processing,
            to: .processed,
            at: committedAt,
            in: db
        )
    }

    /// The capture must commit against the same text the user confirmed — if the
    /// item was edited after processing began, abort so everything rolls back.
    static func requireCurrentRevision(
        inboxItemID: UUID,
        expected: Int,
        in db: Database
    ) throws {
        guard let row = try GRDBInboxRepository.fetchItemRow(id: inboxItemID, in: db) else {
            throw InboxError.itemNotFound
        }
        let actual: Int = row["content_revision"]
        guard actual == expected else {
            throw InboxError.revisionConflict(expected: expected, actual: actual)
        }
    }

    static func encodeCommitResult(_ result: ContentCommitResult) -> String {
        #"{"note_id":""# + result.noteID.uuidString
            + #"","card_count":"# + String(result.cardCount) + "}"
    }

    static func decodeCommitResult(_ json: String) throws -> ContentCommitResult {
        struct Stored: Decodable {
            let noteID: UUID
            let cardCount: Int
            enum CodingKeys: String, CodingKey {
                case noteID = "note_id"
                case cardCount = "card_count"
            }
        }
        let stored = try JSONDecoder().decode(Stored.self, from: Data(json.utf8))
        return ContentCommitResult(
            noteID: stored.noteID,
            cardCount: stored.cardCount,
            wasCreated: false
        )
    }

    private static func requireDeck(_ deckID: UUID, in db: Database) throws {
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
            ) else {
                continue
            }
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [DatabaseValueCodec.encode(noteID), tagID]
            )
        }
    }

    private static func insertOrEnableCard(
        _ card: NewCardSeed,
        noteID: UUID,
        profileID: UUID,
        dueAtMilliseconds: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cards(
                    id, note_id, template_kind, is_enabled, state, due_at_ms,
                    stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                    learning_step, state_version, algorithm_version, profile_id
                ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                ON CONFLICT(note_id, template_kind) DO UPDATE SET is_enabled = 1
                """,
            arguments: [
                DatabaseValueCodec.encode(card.id),
                DatabaseValueCodec.encode(noteID),
                card.templateKind.rawValue,
                dueAtMilliseconds,
                SwiftFSRSReviewScheduler.algorithmVersion,
                DatabaseValueCodec.encode(profileID)
            ]
        )
    }

    private static func deleteDraft(id: UUID, kind: String, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM drafts WHERE id = ? AND draft_kind = ?",
            arguments: [DatabaseValueCodec.encode(id), kind]
        )
    }

    /// In-transaction direction read — the split commit (设计 §6.5) uses it
    /// to verify the preview's direction snapshot inside the same
    /// transaction that writes the new cards.
    static func fetchCardDirections(
        noteID: UUID,
        in db: Database
    ) throws -> [CardDirectionState] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, template_kind, is_enabled
                FROM cards
                WHERE note_id = ?
                ORDER BY template_kind, id
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        ).map { row in
            let templateValue: String = row["template_kind"]
            guard let template = CardTemplateKind(rawValue: templateValue) else {
                throw DatabaseValueCodecError.invalidCardTemplate(templateValue)
            }
            return CardDirectionState(
                cardID: try DatabaseValueCodec.decodeUUID(row["id"]),
                templateKind: template,
                isEnabled: row["is_enabled"]
            )
        }
    }
}
