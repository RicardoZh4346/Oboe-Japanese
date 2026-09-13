import Foundation
import GRDB
import OboeDomain

public struct GRDBSentenceAnalysisCardRepository: SentenceAnalysisCardRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func commitSentenceAnalysisCards(
        _ batch: SentenceAnalysisCardBatchCommit
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
            try Self.requireDeck(batch.deckID, in: db)
            guard batch.items.allSatisfy({ item in
                switch item {
                case let .vocabulary(commit): commit.deckID == batch.deckID
                case let .grammar(commit): commit.deckID == batch.deckID
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
            return SentenceAnalysisCardBatchResult(noteIDs: noteIDs, cardCount: cardCount)
        }
    }

    private static func insertVocabulary(
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
                    part_of_speech, jlpt, notes, origin, content_version,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', ?, ?, ?, ?, ?, ?, 'ai', 1, ?, ?)
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
                timestamp,
                timestamp
            ]
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

    private static func insertGrammar(
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
                    connection, jlpt, notes, origin, content_version,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'grammar', ?, ?, ?, ?, ?, ?, 'ai', 1, ?, ?)
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
