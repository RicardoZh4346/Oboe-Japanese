import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBDeckRepositoryTests: XCTestCase {
    func testCreateRenameObservationAndReopenPersistence() async throws {
        let location = try DeckTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBDeckRepository(database: database)
        var updates = repository.observeDeckSummaries().makeAsyncIterator()

        let initialUpdate = try await updates.next()
        XCTAssertEqual(initialUpdate, [])
        let deckID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_768_478_400.123)
        let deck = try await repository.createDeck(
            id: deckID,
            name: "N5 单词",
            at: createdAt
        )
        XCTAssertEqual(deck.sortOrder, 0)
        let createdUpdate = try await updates.next()
        XCTAssertEqual(createdUpdate?.map(\.name), ["N5 单词"])

        let didRename = try await repository.renameDeck(
            id: deckID,
            name: "日语基础",
            at: createdAt.addingTimeInterval(1)
        )
        XCTAssertTrue(didRename)
        let renamedUpdate = try await updates.next()
        XCTAssertEqual(renamedUpdate?.map(\.name), ["日语基础"])

        try database.close()
        let reopened = try OboeDatabase(path: location.databaseURL.path)
        let reopenedRepository = GRDBDeckRepository(database: reopened)
        let reopenedSummaries = try await reopenedRepository.fetchDeckSummaries()
        XCTAssertEqual(reopenedSummaries, [
            DeckSummary(id: deckID, name: "日语基础", noteCount: 0, cardCount: 0)
        ])
    }

    func testSummariesReturnRealNoteAndCardCounts() async throws {
        let location = try DeckTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBDeckRepository(database: database)
        let deckID = UUID()
        let noteID = UUID()
        let profileID = UUID()
        _ = try await repository.createDeck(id: deckID, name: "计数", at: Date())

        try await database.pool.write { db in
            try insertNote(id: noteID, deckID: deckID, in: db)
            try insertProfile(id: profileID, in: db)
            try insertCard(
                id: UUID(),
                noteID: noteID,
                profileID: profileID,
                template: "vocabulary_ja_zh",
                in: db
            )
            try insertCard(
                id: UUID(),
                noteID: noteID,
                profileID: profileID,
                template: "vocabulary_zh_ja",
                in: db
            )
        }

        let summaries = try await repository.fetchDeckSummaries()
        XCTAssertEqual(summaries, [
            DeckSummary(id: deckID, name: "计数", noteCount: 1, cardCount: 2)
        ])
    }

    func testOnlyEmptyDeckCanBeDeleted() async throws {
        let location = try DeckTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBDeckRepository(database: database)
        let emptyDeckID = UUID()
        let nonEmptyDeckID = UUID()
        _ = try await repository.createDeck(id: emptyDeckID, name: "空牌组", at: Date())
        _ = try await repository.createDeck(id: nonEmptyDeckID, name: "非空牌组", at: Date())
        try await database.pool.write { db in
            try insertNote(id: UUID(), deckID: nonEmptyDeckID, in: db)
        }

        let emptyDeletion = try await repository.deleteDeckIfEmpty(id: emptyDeckID)
        XCTAssertEqual(emptyDeletion, .deleted)
        let nonEmptyDeletion = try await repository.deleteDeckIfEmpty(id: nonEmptyDeckID)
        XCTAssertEqual(
            nonEmptyDeletion,
            .notEmpty(noteCount: 1, cardCount: 0)
        )
        let missingDeletion = try await repository.deleteDeckIfEmpty(id: UUID())
        XCTAssertEqual(missingDeletion, .notFound)
        let emptyDeckExists = try await repository.deckExists(id: emptyDeckID)
        let nonEmptyDeckExists = try await repository.deckExists(id: nonEmptyDeckID)
        XCTAssertFalse(emptyDeckExists)
        XCTAssertTrue(nonEmptyDeckExists)
    }
}

private struct DeckTestDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBDeckRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func insertNote(id: UUID, deckID: UUID, in db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO notes(
                id, deck_id, kind, headword, meaning_zh,
                origin, content_version, created_at_ms, updated_at_ms
            ) VALUES (?, ?, 'vocabulary', '食べる', '吃', 'manual', 1, 1, 1)
            """,
        arguments: [DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(deckID)]
    )
}

private func insertProfile(id: UUID, in db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO scheduler_profiles(
                id, configuration_version, algorithm_version, library_revision,
                parameters_json, desired_retention, max_interval_days, created_at_ms
            ) VALUES (?, ?, 'FSRS-6.0', 'test', '[]', 0.9, 36500, 1)
            """,
        arguments: [DatabaseValueCodec.encode(id), "test-\(id.uuidString)"]
    )
}

private func insertCard(
    id: UUID,
    noteID: UUID,
    profileID: UUID,
    template: String,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO cards(
                id, note_id, template_kind, is_enabled, state, due_at_ms,
                stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                learning_step, state_version, algorithm_version, profile_id
            ) VALUES (?, ?, ?, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'FSRS-6.0', ?)
            """,
        arguments: [
            DatabaseValueCodec.encode(id),
            DatabaseValueCodec.encode(noteID),
            template,
            DatabaseValueCodec.encode(profileID)
        ]
    )
}
