import CryptoKit
import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class PortableBackupRestorationPreparerTests: XCTestCase {
    func testValidV1BackupImportsIntoTemporaryDatabaseAndPreviewsReplacement() async throws {
        let fixture = try RestorationTestFixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedCompleteValidBackupSource(source)
        try await seedCurrentDatabase(current)
        let backup = try await PortableBackupExporter(
            database: source,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "0.1.0-test", at: fixture.exportedAt)
        let legacyBackupURL = fixture.rootURL.appendingPathComponent("legacy-v1.oboe-backup")
        try rewriteBackup(backup.url, to: legacyBackupURL) { objects in
            objects[0]["formatVersion"] = 1
            for index in objects.indices where objects[index]["recordType"] as? String == "note" {
                objects[index].removeValue(forKey: "source_ref")
            }
        }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )

        let prepared = try await preparer.prepare(fileURL: legacyBackupURL)

        XCTAssertEqual(prepared.sourceFormatVersion, 1)
        XCTAssertEqual(prepared.preparedFormatVersion, 2)
        XCTAssertEqual(prepared.sourceAppVersion, "0.1.0-test")
        XCTAssertEqual(prepared.exportedAt, fixture.exportedAt)
        XCTAssertEqual(prepared.backup.deckCount, 1)
        XCTAssertEqual(prepared.backup.noteCount, 1)
        XCTAssertEqual(prepared.backup.cardCount, 1)
        XCTAssertEqual(prepared.backup.reviewCount, 1)
        XCTAssertEqual(prepared.backup.draftCount, 1)
        XCTAssertEqual(prepared.current.deckCount, 1)
        XCTAssertEqual(prepared.current.noteCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.temporaryDatabaseURL.path))

        let imported = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        let importedValues = try await imported.pool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT headword FROM notes"),
                try String.fetchOne(db, sql: "SELECT source_ref FROM notes"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_tasks"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents"),
                try String.fetchOne(db, sql: "SELECT ai_base_url FROM app_settings")
            )
        }
        XCTAssertEqual(importedValues.0, "食べる")
        XCTAssertNil(importedValues.1)
        XCTAssertEqual(importedValues.2, 1)
        XCTAssertEqual(importedValues.3, 1)
        XCTAssertEqual(importedValues.4, 1)
        XCTAssertNil(importedValues.5)
        try imported.close()

        let currentName = try await current.pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(currentName, "当前资料")

        try await preparer.discard(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.temporaryDatabaseURL.path))
    }

    func testDamagedChecksumIsRejectedAndNeverChangesCurrentDatabase() async throws {
        let fixture = try RestorationTestFixture()
        defer { fixture.remove() }
        let (current, backupURL) = try await makeValidBackup(in: fixture)
        var text = try String(contentsOf: backupURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "完整备份", with: "损坏备份")
        let damagedURL = fixture.rootURL.appendingPathComponent("damaged.oboe-backup")
        try Data(text.utf8).write(to: damagedURL)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )

        do {
            _ = try await preparer.prepare(fileURL: damagedURL)
            XCTFail("Checksum damage must be rejected")
        } catch let error as PortableBackupPreparationError {
            XCTAssertEqual(error, .invalidChecksum)
        }
        try await assertCurrentDatabaseAndPreparationDirectoryAreUntouched(
            current: current,
            fixture: fixture
        )
    }

    func testFutureFormatAndConfiguredFileLimitsAreRejectedBeforeImport() async throws {
        let fixture = try RestorationTestFixture()
        defer { fixture.remove() }
        let (current, backupURL) = try await makeValidBackup(in: fixture)
        var futureText = try String(contentsOf: backupURL, encoding: .utf8)
        futureText = futureText.replacingOccurrences(
            of: #""formatVersion":2"#,
            with: #""formatVersion":3"#
        )
        let futureURL = fixture.rootURL.appendingPathComponent("future.oboe-backup")
        try Data(futureText.utf8).write(to: futureURL)
        let normalPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )

        do {
            _ = try await normalPreparer.prepare(fileURL: futureURL)
            XCTFail("Future formats must be rejected")
        } catch let error as PortableBackupPreparationError {
            XCTAssertEqual(error, .futureFormatVersion(3))
        }

        let fileSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: backupURL.path)[.size] as? NSNumber)?
                .int64Value
        )
        let sizeLimitedPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            limits: PortableBackupPreparationLimits(maximumFileBytes: fileSize - 1)
        )
        do {
            _ = try await sizeLimitedPreparer.prepare(fileURL: backupURL)
            XCTFail("Oversized files must be rejected")
        } catch let error as PortableBackupPreparationError {
            XCTAssertEqual(error, .fileTooLarge(actual: fileSize, limit: fileSize - 1))
        }

        let lineLimitedPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            limits: PortableBackupPreparationLimits(maximumLineBytes: 32)
        )
        do {
            _ = try await lineLimitedPreparer.prepare(fileURL: backupURL)
            XCTFail("Oversized lines must be rejected")
        } catch let error as PortableBackupPreparationError {
            XCTAssertEqual(error, .lineTooLarge(line: 1, limit: 32))
        }

        let recordLimitedPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            limits: PortableBackupPreparationLimits(maximumRecordCount: 1)
        )
        do {
            _ = try await recordLimitedPreparer.prepare(fileURL: backupURL)
            XCTFail("Excessive declared record counts must be rejected")
        } catch let error as PortableBackupPreparationError {
            XCTAssertEqual(error, .tooManyRecords(declared: 12, limit: 1))
        }

        let stringLimitedPreparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL,
            limits: PortableBackupPreparationLimits(maximumStringBytes: 8)
        )
        do {
            _ = try await stringLimitedPreparer.prepare(fileURL: backupURL)
            XCTFail("Oversized string fields must be rejected")
        } catch let error as PortableBackupPreparationError {
            guard case .invalidRecord = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try await assertCurrentDatabaseAndPreparationDirectoryAreUntouched(
            current: current,
            fixture: fixture
        )
    }

    func testMissingProfileReferenceAndUnknownSchedulingAlgorithmAreRejected() async throws {
        let fixture = try RestorationTestFixture()
        defer { fixture.remove() }
        let (current, backupURL) = try await makeValidBackup(in: fixture)
        let missingProfileURL = fixture.rootURL.appendingPathComponent("missing-profile.oboe-backup")
        try rewriteBackup(backupURL, to: missingProfileURL) { objects in
            objects.removeAll { $0["recordType"] as? String == "profile" }
            var counts = objects[0]["counts"] as! [String: Any]
            counts["profile"] = 0
            objects[0]["counts"] = counts
        }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )

        do {
            _ = try await preparer.prepare(fileURL: missingProfileURL)
            XCTFail("Missing profile references must be rejected")
        } catch let error as PortableBackupPreparationError {
            guard case .invalidRecord = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let unknownAlgorithmURL = fixture.rootURL.appendingPathComponent("unknown-algorithm.oboe-backup")
        try rewriteBackup(backupURL, to: unknownAlgorithmURL) { objects in
            let index = objects.firstIndex { $0["recordType"] as? String == "profile" }!
            objects[index]["algorithm_version"] = "FSRS-99.0"
        }
        do {
            _ = try await preparer.prepare(fileURL: unknownAlgorithmURL)
            XCTFail("Unknown algorithms must be rejected")
        } catch let error as PortableBackupPreparationError {
            XCTAssertEqual(error, .unsupportedAlgorithmVersion("FSRS-99.0"))
        }
        try await assertCurrentDatabaseAndPreparationDirectoryAreUntouched(
            current: current,
            fixture: fixture
        )
    }

    func testExportPrepareAndCompleteReplacementRoundTripKeepsAllRestorableData() async throws {
        let fixture = try RestorationTestFixture()
        defer { fixture.remove() }
        let (current, backupURL) = try await makeValidBackup(in: fixture)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let prepared = try await preparer.prepare(fileURL: backupURL)
        try current.close()
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: fixture.currentDatabaseURL,
            snapshotDirectoryURL: fixture.rootURL.appendingPathComponent(
                "snapshots",
                isDirectory: true
            )
        )
        _ = try await lifecycle.open()

        let restored = try await lifecycle.replaceDatabase(
            with: prepared.temporaryDatabaseURL
        )

        let counts = try await restored.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drafts"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_tasks"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents")
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(counts.3, 1)
        XCTAssertEqual(counts.4, 1)
        XCTAssertEqual(counts.5, 1)
        XCTAssertEqual(counts.6, 1)
        let restoredNote = try await restored.pool.read { db in
            (
                try String.fetchOne(db, sql: "SELECT headword FROM notes"),
                try String.fetchOne(db, sql: "SELECT origin FROM notes"),
                try String.fetchOne(db, sql: "SELECT source_ref FROM notes")
            )
        }
        XCTAssertEqual(restoredNote.0, "食べる")
        XCTAssertEqual(restoredNote.1, "builtin_jlpt")
        XCTAssertEqual(restoredNote.2, "openjlpt:N5:000001")
    }
}

private extension PortableBackupRestorationPreparerTests {
    struct RestorationTestFixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupRestorationPreparerTests-\(UUID().uuidString)",
                isDirectory: true
            )
            sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
            currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            preparationsURL = rootURL.appendingPathComponent("preparations", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func makeValidBackup(
        in fixture: RestorationTestFixture
    ) async throws -> (OboeDatabase, URL) {
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedCompleteValidBackupSource(source)
        try await seedCurrentDatabase(current)
        let backup = try await PortableBackupExporter(
            database: source,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "test", at: fixture.exportedAt)
        return (current, backup.url)
    }

    func seedCurrentDatabase(_ database: OboeDatabase) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '当前资料', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(UUID())]
            )
        }
    }

    func seedCompleteValidBackupSource(_ database: OboeDatabase) async throws {
        let deckID = UUID()
        let noteID = UUID()
        let exampleID = UUID()
        let tagID = UUID()
        let profileID = UUID()
        let cardID = UUID()
        let studyDayID = UUID()
        let reviewID = UUID()
        let eventID = UUID()
        let draftID = UUID()
        let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
        let previous = ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: Date(timeIntervalSince1970: 1_789_056_000),
                state: .new
            ),
            firstStudiedAt: nil,
            stateVersion: 0,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        let next = ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: Date(timeIntervalSince1970: 1_789_142_400),
                stability: 1.2,
                difficulty: 5,
                elapsedDays: 0,
                scheduledDays: 1,
                learningStep: 0,
                repetitions: 1,
                lapses: 0,
                state: .review,
                lastReviewAt: Date(timeIntervalSince1970: 1_789_056_000)
            ),
            firstStudiedAt: Date(timeIntervalSince1970: 1_789_056_000),
            stateVersion: 1,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .millisecondsSince1970
        jsonEncoder.outputFormatting = [.sortedKeys]
        let previousJSON = String(decoding: try jsonEncoder.encode(previous), as: UTF8.self)
        let nextJSON = String(decoding: try jsonEncoder.encode(next), as: UTF8.self)
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(SchedulerProfile.fsrs6DefaultParameters),
            as: UTF8.self
        )

        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '完整备份', 0, 1, 2)",
                arguments: [encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh, part_of_speech,
                        jlpt, usage, connection, notes, is_favorite, source_text, origin,
                        source_ref, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', '动词',
                        'N5', '用法', NULL, '说明', 1, '原句', 'builtin_jlpt',
                        'openjlpt:N5:000001', 2, 3, 4)
                    """,
                arguments: [encode(noteID), encode(deckID)]
            )
            try db.execute(
                sql: "INSERT INTO examples VALUES (?, ?, '魚を食べる。', '吃鱼。', 0)",
                arguments: [encode(exampleID), encode(noteID)]
            )
            try db.execute(
                sql: "INSERT INTO tags VALUES (?, '动词', '动词')",
                arguments: [encode(tagID)]
            )
            try db.execute(
                sql: "INSERT INTO note_tags VALUES (?, ?)",
                arguments: [encode(noteID), encode(tagID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles VALUES(
                        ?, 'test-r90-v1', ?, ?, ?, 0.9, 36500, 5
                    )
                    """,
                arguments: [
                    encode(profileID), SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision, parametersJSON
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO cards VALUES(
                        ?, ?, 'vocabulary_ja_zh', 1, 2, 1789142400000, 1789056000000,
                        1.2, 5, 1, 0, 1, 0, 0, 1789056000000, 1, ?, ?
                    )
                    """,
                arguments: [
                    encode(cardID), encode(noteID), SwiftFSRSReviewScheduler.algorithmVersion,
                    encode(profileID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO study_days VALUES(
                        ?, '2026-09-11', 'Asia/Shanghai', 1789056000000, 1789142400000, 10
                    )
                    """,
                arguments: [encode(studyDayID)]
            )
            try db.execute(
                sql: "INSERT INTO daily_tasks VALUES (?, ?, 'new', 1789056000000, NULL)",
                arguments: [encode(studyDayID), encode(cardID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO review_logs VALUES(
                        ?, ?, ?, ?, ?, ?, 1789056000123, ?, 1, 3,
                        ?, ?, 800, 2, ?, ?, NULL
                    )
                    """,
                arguments: [
                    encode(reviewID), encode(eventID), encode(cardID), encode(cardID),
                    encode(noteID), encode(deckID), encode(studyDayID), previousJSON,
                    nextJSON, encode(profileID), SwiftFSRSReviewScheduler.algorithmVersion
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO drafts VALUES(
                        ?, 'vocabulary', 1, '{"headword":"草稿"}',
                        'draft-provider', 'draft-model', 'prompt-v1', 1789056000000
                    )
                    """,
                arguments: [encode(draftID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, daily_new_card_limit,
                        retention_preset, auto_play_word_audio, auto_play_example_audio,
                        appearance, ai_provider_id, ai_base_url, ai_model_id
                    ) VALUES(
                        1, 1, 'Asia/Shanghai', 10, 90, 1, 0, 'dark',
                        'secret-provider', 'https://secret.example/token', 'secret-model'
                    )
                    """
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO search_documents VALUES (?, '食べる', 'たべる', '吃')",
                arguments: [encode(noteID)]
            )
        }
    }

    func rewriteBackup(
        _ sourceURL: URL,
        to destinationURL: URL,
        transform: (inout [[String: Any]]) -> Void
    ) throws {
        let source = try Data(contentsOf: sourceURL)
        var objects = try source.split(separator: 0x0A).map { line -> [String: Any] in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            )
        }
        XCTAssertEqual(objects.removeLast()["recordType"] as? String, "footer")
        transform(&objects)

        var output = Data()
        var hasher = SHA256()
        for object in objects {
            var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            line.append(0x0A)
            output.append(line)
            hasher.update(data: line)
        }
        let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var footer = try JSONSerialization.data(
            withJSONObject: [
                "recordType": "footer",
                "checksumAlgorithm": "sha256",
                "checksum": checksum
            ],
            options: [.sortedKeys]
        )
        footer.append(0x0A)
        output.append(footer)
        try output.write(to: destinationURL)
    }

    func assertCurrentDatabaseAndPreparationDirectoryAreUntouched(
        current: OboeDatabase,
        fixture: RestorationTestFixture
    ) async throws {
        let currentDecks = try await current.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(currentDecks, ["当前资料"])
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: fixture.preparationsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Failed preparation left files: \(leftovers)")
    }
}
