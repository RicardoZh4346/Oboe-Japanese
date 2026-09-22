import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBVocabularyRepositoryTests: XCTestCase {
    func testDraftRoundTripUpdateDeleteAndReopen() async throws {
        let location = try VocabularyTestDatabaseLocation()
        defer { location.remove() }
        let draftID = UUID()
        let deckID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_768_478_400.123)

        do {
            let database = try OboeDatabase(path: location.databaseURL.path)
            let repository = GRDBVocabularyRepository(database: database)
            let first = VocabularyDraft(
                id: draftID,
                deckID: deckID,
                formData: VocabularyFormData(headword: "食べ", reading: "たべ"),
                updatedAt: timestamp
            )
            try await repository.saveVocabularyDraft(first)

            let updated = VocabularyDraft(
                id: draftID,
                deckID: deckID,
                formData: VocabularyFormData(
                    headword: "食べる",
                    reading: "たべる",
                    meaningZH: "吃",
                    jlpt: .n5,
                    exampleJapanese: "毎朝パンを食べます。"
                ),
                updatedAt: timestamp.addingTimeInterval(1)
            )
            try await repository.saveVocabularyDraft(updated)
            let fetched = try await repository.fetchLatestVocabularyDraft()
            XCTAssertEqual(fetched, updated)
            try database.close()
        }

        let reopened = try OboeDatabase(path: location.databaseURL.path)
        let reopenedRepository = GRDBVocabularyRepository(database: reopened)
        let reopenedDraft = try await reopenedRepository.fetchLatestVocabularyDraft()
        XCTAssertEqual(reopenedDraft?.formData.meaningZH, "吃")
        try await reopenedRepository.deleteVocabularyDraft(id: draftID)
        let deleted = try await reopenedRepository.fetchLatestVocabularyDraft()
        XCTAssertNil(deleted)
    }

    func testEditPreservesNoteCardAndExampleIdentity() async throws {
        let location = try VocabularyTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBVocabularyRepository(database: database)
        let deckID = UUID()
        let noteID = UUID()
        let exampleID = UUID()
        let cardID = UUID()
        let profileID = UUID()
        try await seedExistingVocabulary(
            deckID: deckID,
            noteID: noteID,
            exampleID: exampleID,
            cardID: cardID,
            profileID: profileID,
            in: database
        )

        let content = try VocabularyFormData(
            headword: " 食べる ",
            reading: "たべる",
            meaningZH: " 吃；用餐 ",
            partOfSpeech: "一段动词",
            jlpt: .n5,
            exampleJapanese: "寿司を食べます。",
            exampleTranslationZH: "吃寿司。",
            notes: "更新后的说明"
        ).validatedContent()
        let updated = try await repository.updateVocabulary(
            id: noteID,
            content: content,
            newExampleID: UUID(),
            at: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(updated?.id, noteID)
        XCTAssertEqual(updated?.deckID, deckID)
        XCTAssertEqual(updated?.meaningZH, "吃；用餐")
        XCTAssertEqual(updated?.contentVersion, 2)
        XCTAssertEqual(updated?.examples.map(\.id), [exampleID])
        XCTAssertEqual(updated?.examples.first?.japanese, "寿司を食べます。")

        let persistedCardID = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM cards WHERE note_id = ?", arguments: [DatabaseValueCodec.encode(noteID)])
        }
        XCTAssertEqual(persistedCardID, DatabaseValueCodec.encode(cardID))
    }

    func testSummariesAreDeckScopedAndMissingUpdateDoesNotInsert() async throws {
        let location = try VocabularyTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBVocabularyRepository(database: database)
        let firstDeckID = UUID()
        let secondDeckID = UUID()
        let firstNoteID = UUID()
        let secondNoteID = UUID()

        try await database.pool.write { db in
            try insertDeck(id: firstDeckID, name: "第一组", in: db)
            try insertDeck(id: secondDeckID, name: "第二组", in: db)
            try insertVocabulary(id: firstNoteID, deckID: firstDeckID, headword: "食べる", in: db)
            try insertVocabulary(id: secondNoteID, deckID: secondDeckID, headword: "見る", in: db)
        }

        let summaries = try await repository.fetchVocabularySummaries(deckID: firstDeckID)
        XCTAssertEqual(summaries.map(\.id), [firstNoteID])
        XCTAssertEqual(summaries.map(\.headword), ["食べる"])
        let vocabulary = try await repository.fetchVocabulary(id: firstNoteID)
        XCTAssertNotNil(vocabulary)

        let missingID = UUID()
        let result = try await repository.updateVocabulary(
            id: missingID,
            content: try VocabularyFormData(headword: "新規", meaningZH: "新建").validatedContent(),
            newExampleID: UUID(),
            at: Date()
        )
        XCTAssertNil(result)
        let missingCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes WHERE id = ?", arguments: [DatabaseValueCodec.encode(missingID)])
        }
        XCTAssertEqual(missingCount, 0)
    }
}

private struct VocabularyTestDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBVocabularyRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func seedExistingVocabulary(
    deckID: UUID,
    noteID: UUID,
    exampleID: UUID,
    cardID: UUID,
    profileID: UUID,
    in database: OboeDatabase
) async throws {
    try await database.pool.write { db in
        try insertDeck(id: deckID, name: "编辑测试", in: db)
        try insertVocabulary(id: noteID, deckID: deckID, headword: "食べる", in: db)
        try db.execute(
            sql: "INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order) VALUES (?, ?, 'パンを食べます。', '吃面包。', 0)",
            arguments: [DatabaseValueCodec.encode(exampleID), DatabaseValueCodec.encode(noteID)]
        )
        try db.execute(
            sql: """
                INSERT INTO scheduler_profiles(
                    id, configuration_version, algorithm_version, library_revision,
                    parameters_json, desired_retention, max_interval_days, created_at_ms
                ) VALUES (?, ?, 'FSRS-6.0', 'test', '[]', 0.9, 36500, 1)
                """,
            arguments: [DatabaseValueCodec.encode(profileID), "p06-\(profileID.uuidString)"]
        )
        try db.execute(
            sql: """
                INSERT INTO cards(
                    id, note_id, template_kind, is_enabled, state, due_at_ms,
                    stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                    learning_step, state_version, algorithm_version, profile_id
                ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'FSRS-6.0', ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(cardID),
                DatabaseValueCodec.encode(noteID),
                DatabaseValueCodec.encode(profileID)
            ]
        )
    }
}

private func insertDeck(id: UUID, name: String, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, 0, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id), name]
    )
}

private func insertVocabulary(id: UUID, deckID: UUID, headword: String, in db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO notes(
                id, deck_id, kind, headword, reading, meaning_zh,
                origin, content_version, created_at_ms, updated_at_ms
            ) VALUES (?, ?, 'vocabulary', ?, 'たべる', '吃', 'manual', 1, 1, 1)
            """,
        arguments: [
            DatabaseValueCodec.encode(id),
            DatabaseValueCodec.encode(deckID),
            headword
        ]
    )
    try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
}
