import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class OboeDatabaseTests: XCTestCase {
    func testEmptyDatabaseCreatesCurrentSchemaAndEnablesForeignKeys() throws {
        try withTemporaryDatabase { database, _ in
            let tableNames = try database.pool.read { db in
                Set(try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
                ))
            }
            let foreignKeysEnabled = try database.pool.read { db in
                try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")!
            }
            let appliedMigrations = try database.pool.read { db in
                try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            }

            XCTAssertEqual(tableNames, OboeDatabaseSchema.tableNames)
            XCTAssertTrue(foreignKeysEnabled)
            XCTAssertEqual(appliedMigrations, Set(OboeDatabaseSchema.migrationIdentifiers))
        }
    }

    func testReopenKeepsExistingData() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let deckID = UUID()

        do {
            let database = try OboeDatabase(path: location.file.path)
            try database.pool.write { db in
                try Self.insertDeck(id: deckID, name: "重开保留", in: db)
            }
            try database.pool.close()
        }

        let reopened = try OboeDatabase(path: location.file.path)
        let name = try reopened.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT name FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        XCTAssertEqual(name, "重开保留")
    }

    func testForeignKeyAndUniqueConstraintsAreEnforced() throws {
        try withTemporaryDatabase { database, _ in
            XCTAssertThrowsError(try database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', '食べる', '吃', 'manual', 1, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(UUID())
                    ]
                )
            })

            try database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO tags(id, name, normalized_name) VALUES (?, '动词', '动词')",
                    arguments: [DatabaseValueCodec.encode(UUID())]
                )
            }
            XCTAssertThrowsError(try database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO tags(id, name, normalized_name) VALUES (?, '動詞', '动词')",
                    arguments: [DatabaseValueCodec.encode(UUID())]
                )
            })
        }
    }

    func testWriteTransactionRollsBackAllChanges() throws {
        try withTemporaryDatabase { database, _ in
            XCTAssertThrowsError(try database.pool.write { db in
                try Self.insertDeck(id: UUID(), name: "不应保留", in: db)
                throw IntentionalFailure()
            })

            let count = try database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks")!
            }
            XCTAssertEqual(count, 0)
        }
    }

    func testLegacyV1FixtureMigratesWithoutLosingData() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "legacy-v1",
                withExtension: "sql",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(forResource: "legacy-v1", withExtension: "sql")
        )
        let fixtureSQL = try String(contentsOf: fixtureURL, encoding: .utf8)

        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            let legacyDatabase = try DatabaseQueue(
                path: location.file.path,
                configuration: configuration
            )
            try legacyDatabase.write { db in
                try db.execute(sql: fixtureSQL)
            }
            try legacyDatabase.close()
        }

        let migrated = try OboeDatabase(path: location.file.path)
        let result = try migrated.pool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT name FROM decks")!,
                try String.fetchOne(db, sql: "SELECT headword FROM notes")!,
                try String.fetchOne(db, sql: "SELECT japanese FROM examples")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduler_profiles")!,
                try String.fetchOne(db, sql: "SELECT normalized_reading FROM search_documents")!,
                try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            )
        }

        XCTAssertEqual(result.0, "旧版测试牌组")
        XCTAssertEqual(result.1, "食べる")
        XCTAssertEqual(result.2, "毎朝パンを食べます。")
        XCTAssertEqual(result.3, 0)
        XCTAssertEqual(result.4, "たべる")
        XCTAssertEqual(result.5, Set(OboeDatabaseSchema.migrationIdentifiers))
    }

    func testFailedMigrationDoesNotClearOrPartiallyModifyDatabase() throws {
        try withTemporaryDatabase { database, _ in
            let retainedID = UUID()
            try database.pool.write { db in
                try Self.insertDeck(id: retainedID, name: "必须保留", in: db)
            }

            var migrator = OboeDatabaseSchema.makeMigrator()
            migrator.registerMigration("test_intentional_failure") { db in
                try Self.insertDeck(id: UUID(), name: "必须回滚", in: db)
                throw IntentionalFailure()
            }

            XCTAssertFalse(migrator.eraseDatabaseOnSchemaChange)
            XCTAssertThrowsError(try migrator.migrate(database.pool))

            let decks = try database.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT id, name FROM decks ORDER BY name")
            }
            XCTAssertEqual(decks.count, 1)
            XCTAssertEqual(decks[0]["id"], DatabaseValueCodec.encode(retainedID))
            XCTAssertEqual(decks[0]["name"], "必须保留")
        }
    }

    func testSchedulingCardDTOHasLosslessRoundTripAtMillisecondPrecision() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        let deckID = UUID()
        let noteID = UUID()
        let profileID = UUID()
        try await database.pool.write { db in
            try Self.insertDeck(id: deckID, name: "调度往返", in: db)
            try Self.insertNote(id: noteID, deckID: deckID, in: db)
            try Self.insertProfile(id: profileID, in: db)
        }

        let reviewTime = Date(timeIntervalSince1970: 1_768_478_400.123)
        let card = PersistedSchedulingCard(
            id: UUID(),
            noteID: noteID,
            templateKind: .vocabularyJapaneseToChinese,
            isEnabled: true,
            scheduling: SchedulingCard(
                dueAt: reviewTime.addingTimeInterval(72 * 86_400),
                stability: 71.71901709,
                difficulty: 4.99022837,
                elapsedDays: 30,
                scheduledDays: 72,
                learningStep: 0,
                repetitions: 11,
                lapses: 1,
                state: .review,
                lastReviewAt: reviewTime
            ),
            firstStudiedAt: Date(timeIntervalSince1970: 1_760_000_000.456),
            stateVersion: 7,
            algorithmVersion: "FSRS-6.0",
            profileID: profileID
        )
        let repository = GRDBSchedulingCardRepository(database: database)

        try await repository.saveCard(card)
        let fetched = try await repository.fetchCard(id: card.id)

        XCTAssertEqual(fetched, card)
    }

    func testUUIDAndDateStorageRulesAreCanonical() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let date = Date(timeIntervalSince1970: 1_768_478_400.123)

        XCTAssertEqual(DatabaseValueCodec.encode(uuid), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(try DatabaseValueCodec.decodeUUID(DatabaseValueCodec.encode(uuid)), uuid)
        XCTAssertEqual(try DatabaseValueCodec.encode(date), 1_768_478_400_123)
        XCTAssertEqual(
            DatabaseValueCodec.decodeDate(milliseconds: 1_768_478_400_123),
            date
        )
    }
}

private struct IntentionalFailure: Error {}

private extension OboeDatabaseTests {
    struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OboeDatabaseTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite")
        )
    }

    func withTemporaryDatabase(
        _ body: (OboeDatabase, TemporaryDatabaseLocation) throws -> Void
    ) throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        try body(database, location)
    }

    static func insertDeck(id: UUID, name: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, 0, 1, 1)",
            arguments: [DatabaseValueCodec.encode(id), name]
        )
    }

    static func insertNote(id: UUID, deckID: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    origin, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', 'manual', 1, 1, 1)
                """,
            arguments: [DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(deckID)]
        )
        try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
    }

    static func insertProfile(id: UUID, in db: Database) throws {
        let data = try JSONEncoder().encode(SchedulerProfile.fsrs6DefaultParameters)
        let parameters = String(decoding: data, as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO scheduler_profiles(
                    id, configuration_version, algorithm_version, library_revision,
                    parameters_json, desired_retention, max_interval_days, created_at_ms
                ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0', ?, ?, 0.9, 36500, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                SwiftFSRSReviewScheduler.dependencyRevision,
                parameters
            ]
        )
    }
}
