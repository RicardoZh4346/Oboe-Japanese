import Foundation
import GRDB
import XCTest
@testable import OboeInfrastructure

final class DatabaseLifecycleTests: XCTestCase {
    func testSnapshotIsReadableAndContainsCommittedData() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        try await database.pool.write { db in
            try insertDeck(id: deckID, name: "一致快照", in: db)
        }
        let service = DatabaseSnapshotService(directoryURL: location.snapshotsURL)

        let snapshot = try await service.createSnapshot(
            from: database.pool,
            reason: .daily,
            at: Date(timeIntervalSince1970: 1_768_478_400.123)
        )
        let snapshotDatabase = try await service.openValidatedSnapshot(at: snapshot.url)
        defer { try? snapshotDatabase.close() }

        let savedDeck = try await snapshotDatabase.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, name FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)]
            ).map { ($0["id"] as String?, $0["name"] as String?) }
        }
        XCTAssertEqual(savedDeck?.1, "一致快照")
        XCTAssertEqual(savedDeck?.0, DatabaseValueCodec.encode(deckID))
    }

    func testDailySnapshotsAreCreatedOncePerDayAndKeepLatestThree() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let service = DatabaseSnapshotService(directoryURL: location.snapshotsURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let firstDay = Date(timeIntervalSince1970: 1_768_478_400)

        let unchanged = try await service.createDailySnapshotIfNeeded(
            from: database.pool,
            hasChanges: false,
            at: firstDay,
            calendar: calendar
        )
        XCTAssertNil(unchanged)

        for dayOffset in 0..<4 {
            let date = firstDay.addingTimeInterval(Double(dayOffset) * 86_400)
            let created = try await service.createDailySnapshotIfNeeded(
                from: database.pool,
                hasChanges: true,
                at: date,
                calendar: calendar
            )
            XCTAssertNotNil(created)

            let duplicate = try await service.createDailySnapshotIfNeeded(
                from: database.pool,
                hasChanges: true,
                at: date.addingTimeInterval(60),
                calendar: calendar
            )
            XCTAssertNil(duplicate)
        }

        let snapshots = try await service.snapshots()
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertTrue(snapshots.allSatisfy { $0.reason == .daily })
        XCTAssertEqual(snapshots.map(\.createdAt), [
            firstDay.addingTimeInterval(3 * 86_400),
            firstDay.addingTimeInterval(2 * 86_400),
            firstDay.addingTimeInterval(86_400)
        ])
    }

    func testLifecycleSnapshotsLegacyDatabaseBeforeMigration() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        try createLegacyDatabase(at: location.databaseURL)
        let service = DatabaseSnapshotService(directoryURL: location.snapshotsURL)
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotService: service,
            migrator: OboeDatabaseSchema.makeMigrator()
        )

        let migrated = try await lifecycle.open()
        let migratedIdentifiers = try await migrated.pool.read { db in
            try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(migratedIdentifiers, Set(OboeDatabaseSchema.migrationIdentifiers))

        let snapshots = try await service.snapshots()
        let rollbackSnapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(rollbackSnapshot.reason, .migration)
        let validation = try await service.validateSnapshot(at: rollbackSnapshot.url)
        XCTAssertEqual(validation.appliedMigrationIdentifiers, ["v1_content"])

        let snapshotDatabase = try await service.openValidatedSnapshot(at: rollbackSnapshot.url)
        defer { try? snapshotDatabase.close() }
        let legacyDeckName = try await snapshotDatabase.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(legacyDeckName, "旧版测试牌组")
    }

    func testFailedMigrationKeepsDataAndPreMigrationSnapshot() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        try createLegacyDatabase(at: location.databaseURL)
        let service = DatabaseSnapshotService(directoryURL: location.snapshotsURL)
        var failingMigrator = OboeDatabaseSchema.makeMigrator()
        failingMigrator.registerMigration("test_failure") { db in
            try db.execute(sql: "DELETE FROM decks")
            throw IntentionalMigrationFailure()
        }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotService: service,
            migrator: failingMigrator
        )

        do {
            _ = try await lifecycle.open()
            XCTFail("The lifecycle must surface migration failures")
        } catch is IntentionalMigrationFailure {
            // Expected.
        }
        let current = await lifecycle.currentDatabase()
        XCTAssertNil(current)

        let source = try OboeDatabase.openPool(path: location.databaseURL.path)
        defer { try? source.close() }
        let retainedName = try await source.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(retainedName, "旧版测试牌组")
        let retainedMigrationIdentifiers = try await source.read { db in
            try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(retainedMigrationIdentifiers, ["v1_content"])

        let snapshots = try await service.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        let validation = try await service.validateSnapshot(at: snapshots[0].url)
        XCTAssertEqual(validation.appliedMigrationIdentifiers, ["v1_content"])
    }

    func testSnapshotDiskErrorStopsMigrationAndIsSurfaced() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        try createLegacyDatabase(at: location.databaseURL)
        try Data("not a directory".utf8).write(to: location.snapshotsURL)
        let service = DatabaseSnapshotService(directoryURL: location.snapshotsURL)
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotService: service,
            migrator: OboeDatabaseSchema.makeMigrator()
        )

        do {
            _ = try await lifecycle.open()
            XCTFail("A snapshot storage error must not be reported as success")
        } catch {
            // Expected: the snapshots path is a regular file.
        }
        let current = await lifecycle.currentDatabase()
        XCTAssertNil(current)

        let source = try OboeDatabase.openPool(path: location.databaseURL.path)
        defer { try? source.close() }
        let appliedIdentifiers = try await source.read { db in
            try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(appliedIdentifiers, ["v1_content"])
    }

    func testLifecycleCanCloseAndReopenWithoutLosingData() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotDirectoryURL: location.snapshotsURL
        )
        let database = try await lifecycle.open()
        let deckID = UUID()
        try await database.pool.write { db in
            try insertDeck(id: deckID, name: "安全重开", in: db)
        }

        try await lifecycle.close()
        let current = await lifecycle.currentDatabase()
        XCTAssertNil(current)
        let reopened = try await lifecycle.reopen()
        let name = try await reopened.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT name FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        XCTAssertEqual(name, "安全重开")
    }

    func testConcurrentOpenCallsShareOneDatabaseInstance() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotDirectoryURL: location.snapshotsURL
        )

        async let first = lifecycle.open()
        async let second = lifecycle.open()
        let (firstDatabase, secondDatabase) = try await (first, second)

        XCTAssertTrue(firstDatabase === secondDatabase)
        let current = await lifecycle.currentDatabase()
        XCTAssertTrue(current === firstDatabase)
    }

    func testDailySnapshotWaitsForDatabaseReplacementToFinish() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let sourceURL = location.directoryURL.appendingPathComponent("prepared.sqlite")
        let source = try OboeDatabase(path: sourceURL.path)
        try await source.pool.write { db in
            try insertDeck(id: UUID(), name: "恢复后资料", in: db)
        }
        try source.close()

        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotDirectoryURL: location.snapshotsURL
        )
        _ = try await lifecycle.open()
        let gate = RestorationCommitGate()
        let replacementTask = Task {
            try await lifecycle.replaceDatabase(with: sourceURL) { _ in
                await gate.enterAndWait()
            }
        }
        await gate.waitUntilEntered()

        let snapshotCompletion = CompletionProbe()
        let snapshotTask = Task {
            let snapshot = try await lifecycle.createDailySnapshotIfNeeded(
                hasChanges: true
            )
            await snapshotCompletion.markCompleted()
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(50))
        let completedBeforeReplacement = await snapshotCompletion.isCompleted
        XCTAssertFalse(completedBeforeReplacement)

        await gate.release()
        _ = try await replacementTask.value
        let snapshot = try await snapshotTask.value
        XCTAssertNotNil(snapshot)
        let completedAfterReplacement = await snapshotCompletion.isCompleted
        XCTAssertTrue(completedAfterReplacement)
    }

    func testCompleteReplacementPreservesDeviceAISettingsAndRebuildsSearch() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let sourceURL = location.directoryURL.appendingPathComponent("prepared.sqlite")
        let source = try OboeDatabase(path: sourceURL.path)
        let sourceDeckID = UUID()
        let sourceNoteID = UUID()
        try await source.pool.write { db in
            try insertDeck(id: sourceDeckID, name: "恢复资料", in: db)
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', 'ＴＥＳＴ', 'てすと', '测试',
                        'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(sourceNoteID),
                    DatabaseValueCodec.encode(sourceDeckID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, appearance
                    ) VALUES (1, 1, 'Asia/Shanghai', 'dark')
                    """
            )
        }
        try source.close()

        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotDirectoryURL: location.snapshotsURL
        )
        let current = try await lifecycle.open()
        try await current.pool.write { db in
            try insertDeck(id: UUID(), name: "当前资料", in: db)
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        ai_provider_id, ai_base_url, ai_model_id,
                        ai_enabled, ai_service_name, ai_credential_id,
                        ai_response_format_mode
                    ) VALUES (
                        1, 1, 'Asia/Shanghai', 'custom', 'https://device.example', 'local-model',
                        1, '设备服务', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                        'json_schema'
                    )
                    """
            )
        }

        let replacement = try await lifecycle.replaceDatabase(with: sourceURL)

        let result = try await replacement.pool.read { db in
            let deckNames = try String.fetchAll(db, sql: "SELECT name FROM decks")
            let settings = try Row.fetchOne(db, sql: "SELECT * FROM app_settings WHERE id = 1")
            let search = try Row.fetchOne(
                db,
                sql: "SELECT * FROM search_documents WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(sourceNoteID)]
            )
            return (
                deckNames,
                settings?["appearance"] as String?,
                settings?["ai_provider_id"] as String?,
                settings?["ai_base_url"] as String?,
                settings?["ai_model_id"] as String?,
                settings?["ai_enabled"] as Bool?,
                settings?["ai_service_name"] as String?,
                settings?["ai_credential_id"] as String?,
                settings?["ai_response_format_mode"] as String?,
                search?["normalized_headword"] as String?,
                search?["normalized_reading"] as String?,
                search?["normalized_meaning"] as String?
            )
        }
        XCTAssertEqual(result.0, ["恢复资料"])
        XCTAssertEqual(result.1, "dark")
        XCTAssertEqual(result.2, "custom")
        XCTAssertEqual(result.3, "https://device.example")
        XCTAssertEqual(result.4, "local-model")
        XCTAssertEqual(result.5, true)
        XCTAssertEqual(result.6, "设备服务")
        XCTAssertEqual(result.7, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(result.8, "json_schema")
        XCTAssertEqual(result.9, "test")
        XCTAssertEqual(result.10, "てすと")
        XCTAssertEqual(result.11, "测试")
        let snapshots = try await lifecycle.snapshotService.snapshots()
        XCTAssertEqual(snapshots.filter { $0.reason == .restoration }.count, 1)
    }

    func testReplacementFailureAfterInstallRollsBackAndKeepsDatabaseOpen() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let sourceURL = location.directoryURL.appendingPathComponent("prepared.sqlite")
        let source = try OboeDatabase(path: sourceURL.path)
        try await source.pool.write { db in
            try insertDeck(id: UUID(), name: "不应保留", in: db)
        }
        try source.close()
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotService: DatabaseSnapshotService(directoryURL: location.snapshotsURL),
            migrator: OboeDatabaseSchema.makeMigrator(),
            restorationFaultInjector: { stage in
                if case .candidateInstalled = stage {
                    throw IntentionalRestorationFailure()
                }
            }
        )
        let current = try await lifecycle.open()
        try await current.pool.write { db in
            try insertDeck(id: UUID(), name: "必须保留", in: db)
        }

        do {
            _ = try await lifecycle.replaceDatabase(with: sourceURL)
            XCTFail("Injected replacement failure must be surfaced")
        } catch is IntentionalRestorationFailure {
            // Expected.
        }

        let currentAfterFailure = await lifecycle.currentDatabase()
        let restored = try XCTUnwrap(currentAfterFailure)
        let names = try await restored.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(names, ["必须保留"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: location.directoryURL.appendingPathComponent(
                ".oboe-restoration-state.json"
            ).path
        ))
    }

    func testOpeningRecoversInterruptedReplacementFromValidatedRollbackSnapshot() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let service = DatabaseSnapshotService(directoryURL: location.snapshotsURL)
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotService: service,
            migrator: OboeDatabaseSchema.makeMigrator()
        )
        let current = try await lifecycle.open()
        try await current.pool.write { db in
            try insertDeck(id: UUID(), name: "中断前资料", in: db)
        }
        let rollback = try await service.createSnapshot(
            from: current.pool,
            reason: .restoration
        )
        try await lifecycle.close()

        let candidateSourceURL = location.directoryURL.appendingPathComponent("new.sqlite")
        let candidateSource = try OboeDatabase(path: candidateSourceURL.path)
        try await candidateSource.pool.write { db in
            try insertDeck(id: UUID(), name: "未完成的新资料", in: db)
        }
        try candidateSource.close()
        let token = "interrupted"
        let originalURL = location.directoryURL.appendingPathComponent(
            ".restore-original-\(token).sqlite"
        )
        let candidateURL = location.directoryURL.appendingPathComponent(
            ".restore-candidate-\(token).sqlite"
        )
        try FileManager.default.moveItem(at: location.databaseURL, to: originalURL)
        try FileManager.default.copyItem(at: candidateSourceURL, to: location.databaseURL)
        try FileManager.default.copyItem(at: candidateSourceURL, to: candidateURL)
        let markerData = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "rollbackSnapshotFilename": rollback.url.lastPathComponent,
                "candidateFilename": candidateURL.lastPathComponent,
                "originalFilename": originalURL.lastPathComponent,
                "phase": "candidateInstalled"
            ],
            options: [.sortedKeys]
        )
        try markerData.write(
            to: location.directoryURL.appendingPathComponent(
                ".oboe-restoration-state.json"
            )
        )

        let recoveredLifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotDirectoryURL: location.snapshotsURL
        )
        let recovered = try await recoveredLifecycle.open()
        let names = try await recovered.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(names, ["中断前资料"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
    }

    func testReplacementStopsBeforeClosingCurrentDatabaseWhenRollbackSnapshotCannotBeWritten() async throws {
        let location = try TemporaryDatabaseDirectory()
        defer { location.remove() }
        let sourceURL = location.directoryURL.appendingPathComponent("prepared.sqlite")
        let source = try OboeDatabase(path: sourceURL.path)
        try await source.pool.write { db in
            try insertDeck(id: UUID(), name: "候选资料", in: db)
        }
        try source.close()
        try Data("not a directory".utf8).write(to: location.snapshotsURL)
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: location.databaseURL,
            snapshotDirectoryURL: location.snapshotsURL
        )
        let current = try await lifecycle.open()
        try await current.pool.write { db in
            try insertDeck(id: UUID(), name: "原库仍可用", in: db)
        }

        do {
            _ = try await lifecycle.replaceDatabase(with: sourceURL)
            XCTFail("Replacement must stop if its rollback snapshot cannot be written")
        } catch {
            // Expected: snapshots path is deliberately a regular file.
        }

        let sameCurrent = await lifecycle.currentDatabase()
        XCTAssertTrue(sameCurrent === current)
        let names = try await current.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(names, ["原库仍可用"])
    }
}

private struct IntentionalMigrationFailure: Error {}
private struct IntentionalRestorationFailure: Error {}

private actor RestorationCommitGate {
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private struct TemporaryDatabaseDirectory {
    let directoryURL: URL
    let databaseURL: URL
    let snapshotsURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OboeDatabaseLifecycleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        snapshotsURL = directoryURL.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func createLegacyDatabase(at url: URL) throws {
    let fixtureURL = try XCTUnwrap(
        Bundle.module.url(
            forResource: "legacy-v1",
            withExtension: "sql",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: "legacy-v1", withExtension: "sql")
    )
    let fixtureSQL = try String(contentsOf: fixtureURL, encoding: .utf8)
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let database = try DatabaseQueue(path: url.path, configuration: configuration)
    try database.write { db in
        try db.execute(sql: fixtureSQL)
    }
    try database.close()
}

private func insertDeck(id: UUID, name: String, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, 0, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id), name]
    )
}
