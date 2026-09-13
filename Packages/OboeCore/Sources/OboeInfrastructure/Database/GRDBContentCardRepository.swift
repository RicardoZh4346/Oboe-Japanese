import Foundation
import GRDB
import OboeDomain

public struct GRDBContentCardRepository: ContentCardRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func commitVocabulary(
        _ commit: VocabularyContentCommit
    ) async throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        return try await pool.write { db in
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
                        part_of_speech, jlpt, notes, origin, source_ref, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
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
            return ContentCommitResult(noteID: commit.noteID, cardCount: commit.cards.count)
        }
    }

    public func commitGrammar(
        _ commit: GrammarContentCommit
    ) async throws -> ContentCommitResult {
        let timestamp = try DatabaseValueCodec.encode(commit.createdAt)
        return try await pool.write { db in
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
                        connection, jlpt, notes, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'grammar', ?, ?, ?, ?, ?, ?, 'manual', 1, ?, ?)
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
            return ContentCommitResult(noteID: commit.noteID, cardCount: 1)
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
            switch replacement.kind {
            case .vocabulary:
                try db.execute(
                    sql: """
                        UPDATE cards SET is_enabled = 0
                        WHERE note_id = ?
                          AND template_kind IN ('vocabulary_ja_zh', 'vocabulary_zh_ja')
                        """,
                    arguments: [noteID]
                )
            case .grammar:
                try db.execute(
                    sql: """
                        UPDATE cards SET is_enabled = 0
                        WHERE note_id = ? AND template_kind = 'grammar_form_explanation'
                        """,
                    arguments: [noteID]
                )
            }

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
            return try Self.fetchCardDirections(noteID: replacement.noteID, in: db)
        }
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

    private static func fetchCardDirections(
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
