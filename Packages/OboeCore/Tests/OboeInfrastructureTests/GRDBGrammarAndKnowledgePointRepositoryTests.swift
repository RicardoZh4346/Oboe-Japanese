import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBGrammarAndKnowledgePointRepositoryTests: XCTestCase {
    func testGrammarAndVocabularyDraftsRemainTypeIsolatedAcrossReopen() async throws {
        let location = try P07ATestDatabaseLocation()
        defer { location.remove() }
        let grammarDraftID = UUID()
        let vocabularyDraftID = UUID()

        do {
            let database = try OboeDatabase(path: location.databaseURL.path)
            let grammarRepository = GRDBGrammarRepository(database: database)
            let vocabularyRepository = GRDBVocabularyRepository(database: database)
            try await grammarRepository.saveGrammarDraft(
                GrammarDraft(
                    id: grammarDraftID,
                    deckID: nil,
                    formData: GrammarFormData(
                        grammarForm: "～たことがある",
                        meaningZH: "曾经做过",
                        usage: "表示经历",
                        connection: "动词た形"
                    ),
                    updatedAt: Date(timeIntervalSince1970: 2)
                )
            )
            try await vocabularyRepository.saveVocabularyDraft(
                VocabularyDraft(
                    id: vocabularyDraftID,
                    deckID: nil,
                    formData: VocabularyFormData(
                        headword: "経験",
                        reading: "けいけん",
                        meaningZH: "经验"
                    ),
                    updatedAt: Date(timeIntervalSince1970: 1)
                )
            )
            try database.close()
        }

        let reopened = try OboeDatabase(path: location.databaseURL.path)
        let grammarDraft = try await GRDBGrammarRepository(database: reopened).fetchLatestGrammarDraft()
        let vocabularyDraft = try await GRDBVocabularyRepository(database: reopened).fetchLatestVocabularyDraft()
        XCTAssertEqual(grammarDraft?.id, grammarDraftID)
        XCTAssertEqual(grammarDraft?.formData.connection, "动词た形")
        XCTAssertEqual(vocabularyDraft?.id, vocabularyDraftID)
        XCTAssertEqual(vocabularyDraft?.formData.reading, "けいけん")

        let payloads = try await reopened.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT draft_kind, payload_json FROM drafts")
                .map { ($0["draft_kind"] as String?, $0["payload_json"] as String?) }
        }
        let grammarJSON = payloads.first { $0.0 == "grammar" }?.1
        let vocabularyJSON = payloads.first { $0.0 == "vocabulary" }?.1
        XCTAssertFalse(grammarJSON?.contains("reading") == true)
        XCTAssertFalse(vocabularyJSON?.contains("usage") == true)
    }

    func testGrammarEditPreservesIdentityAssociationsAndRejectsVocabularyType() async throws {
        let location = try P07ATestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBGrammarRepository(database: database)
        let deckID = UUID()
        let grammarID = UUID()
        let vocabularyID = UUID()
        let exampleID = UUID()
        let cardID = UUID()
        let profileID = UUID()
        try await seedP07AContent(
            deckID: deckID,
            grammarID: grammarID,
            vocabularyID: vocabularyID,
            exampleID: exampleID,
            cardID: cardID,
            profileID: profileID,
            in: database
        )

        let updated = try await repository.updateGrammar(
            id: grammarID,
            content: try GrammarFormData(
                grammarForm: " ～たことがある ",
                meaningZH: "有过……经历",
                usage: "表示过去经历",
                connection: "动词た形 + ことがある",
                exampleJapanese: "北海道へ行ったことがあります。",
                exampleTranslationZH: "曾经去过北海道。",
                jlpt: .n4,
                notes: "不表示经常发生"
            ).validatedContent(),
            newExampleID: UUID(),
            at: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(updated?.id, grammarID)
        XCTAssertEqual(updated?.deckID, deckID)
        XCTAssertEqual(updated?.usage, "表示过去经历")
        XCTAssertEqual(updated?.connection, "动词た形 + ことがある")
        XCTAssertEqual(updated?.contentVersion, 2)
        XCTAssertEqual(updated?.examples.map(\.id), [exampleID])
        XCTAssertEqual(updated?.examples.first?.japanese, "北海道へ行ったことがあります。")

        let persistedCardID = try await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(grammarID)]
            )
        }
        XCTAssertEqual(persistedCardID, DatabaseValueCodec.encode(cardID))

        let wrongType = try await repository.updateGrammar(
            id: vocabularyID,
            content: try GrammarFormData(grammarForm: "错误", meaningZH: "不应写入").validatedContent(),
            newExampleID: UUID(),
            at: Date()
        )
        XCTAssertNil(wrongType)
        let vocabularyHeadword = try await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT headword FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(vocabularyID)]
            )
        }
        XCTAssertEqual(vocabularyHeadword, "経験")
    }

    func testTagsAreDeduplicatedAndFavoritePersistsAcrossReopen() async throws {
        let location = try P07ATestDatabaseLocation()
        defer { location.remove() }
        let deckID = UUID()
        let grammarID = UUID()
        let vocabularyID = UUID()

        do {
            let database = try OboeDatabase(path: location.databaseURL.path)
            try await database.pool.write { db in
                try insertP07ADeck(id: deckID, in: db)
                try insertP07ANote(id: grammarID, deckID: deckID, kind: "grammar", headword: "～ながら", in: db)
                try insertP07ANote(id: vocabularyID, deckID: deckID, kind: "vocabulary", headword: "同時", in: db)
            }
            let service = KnowledgePointService(repository: GRDBKnowledgePointRepository(database: database))
            let favoriteUpdated = try await service.setFavorite(noteID: grammarID, isFavorite: true)
            XCTAssertTrue(favoriteUpdated)
            let grammarTagsUpdated = try await service.replaceTags(
                noteID: grammarID,
                rawNames: ["N5", "ｎ５", " 日常 表达 ", "日常　表达"]
            )
            XCTAssertTrue(grammarTagsUpdated)
            let vocabularyTagsUpdated = try await service.replaceTags(
                noteID: vocabularyID,
                rawNames: ["n5"]
            )
            XCTAssertTrue(vocabularyTagsUpdated)
            let tagCount = try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags")
            }
            XCTAssertEqual(tagCount, 2)
            try database.close()
        }

        let reopened = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBKnowledgePointRepository(database: reopened)
        let metadata = try await repository.fetchMetadata(noteID: grammarID)
        XCTAssertEqual(metadata?.isFavorite, true)
        XCTAssertEqual(metadata?.tags.map(\.normalizedName), ["n5", "日常 表达"])
        let favorites = try await repository.fetchFavoriteSummaries()
        XCTAssertEqual(favorites.map(\.id), [grammarID])
        XCTAssertEqual(favorites.map(\.kind), [.grammar])
        let deckContent = try await repository.fetchKnowledgePointSummaries(deckID: deckID)
        XCTAssertEqual(Set(deckContent.map(\.kind)), [.vocabulary, .grammar])
    }
}

private struct P07ATestDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBP07ARepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func seedP07AContent(
    deckID: UUID,
    grammarID: UUID,
    vocabularyID: UUID,
    exampleID: UUID,
    cardID: UUID,
    profileID: UUID,
    in database: OboeDatabase
) async throws {
    try await database.pool.write { db in
        try insertP07ADeck(id: deckID, in: db)
        try insertP07ANote(id: grammarID, deckID: deckID, kind: "grammar", headword: "～たことがある", in: db)
        try insertP07ANote(id: vocabularyID, deckID: deckID, kind: "vocabulary", headword: "経験", in: db)
        try db.execute(
            sql: "INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order) VALUES (?, ?, '日本へ行ったことがあります。', '去过日本。', 0)",
            arguments: [DatabaseValueCodec.encode(exampleID), DatabaseValueCodec.encode(grammarID)]
        )
        try db.execute(
            sql: """
                INSERT INTO scheduler_profiles(
                    id, configuration_version, algorithm_version, library_revision,
                    parameters_json, desired_retention, max_interval_days, created_at_ms
                ) VALUES (?, ?, 'FSRS-6.0', 'test', '[]', 0.9, 36500, 1)
                """,
            arguments: [DatabaseValueCodec.encode(profileID), "p07a-\(profileID.uuidString)"]
        )
        try db.execute(
            sql: """
                INSERT INTO cards(
                    id, note_id, template_kind, is_enabled, state, due_at_ms,
                    stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                    learning_step, state_version, algorithm_version, profile_id
                ) VALUES (?, ?, 'grammar_form_explanation', 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'FSRS-6.0', ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(cardID),
                DatabaseValueCodec.encode(grammarID),
                DatabaseValueCodec.encode(profileID)
            ]
        )
    }
}

private func insertP07ADeck(id: UUID, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P07a', 0, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id)]
    )
}

private func insertP07ANote(
    id: UUID,
    deckID: UUID,
    kind: String,
    headword: String,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO notes(
                id, deck_id, kind, headword, meaning_zh,
                origin, content_version, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, '含义', 'manual', 1, 1, 1)
            """,
        arguments: [
            DatabaseValueCodec.encode(id),
            DatabaseValueCodec.encode(deckID),
            kind,
            headword
        ]
    )
}
