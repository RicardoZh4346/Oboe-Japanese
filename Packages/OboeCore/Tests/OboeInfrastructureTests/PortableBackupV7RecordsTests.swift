import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// 记录协议 v7（D05/§2.5）：sourceContext + Custom Study 三表的
/// 导出、导入与恢复语义。外层 ZIP 包版本恒 7 不变；纯 NDJSON 与
/// 包内 records 共用本文件的断言对象。
final class PortableBackupV7RecordsTests: XCTestCase {

    // MARK: - 完整 round trip

    /// v7 导出必须携带四类新记录且导入后逐字段一致；scheduled origin
    /// 与 review_logs 的关联恢复后仍成立。
    func testV7RoundTripPreservesSourceContextsAndCustomStudy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source, sessionStatus: "finished")
        let backup = try await fixture.export(source)

        let objects = try fixture.backupObjects(backup.url)
        for type in [
            "sourceContext", "customStudySession",
            "practiceAttempt", "scheduledReviewOrigin"
        ] {
            XCTAssertEqual(
                objects.filter { $0["recordType"] as? String == type }.count,
                1, "v7 export must contain one \(type) record"
            )
        }
        // 记录序：sourceContext 在 noteDeck 之后；origin 在 review 与
        // sessions 之后。
        let order = objects.compactMap { $0["recordType"] as? String }
        let idx = { (type: String) in order.firstIndex(of: type)! }
        XCTAssertLessThan(idx("noteDeck"), idx("sourceContext"))
        XCTAssertLessThan(idx("review"), idx("scheduledReviewOrigin"))
        XCTAssertLessThan(idx("customStudySession"), idx("scheduledReviewOrigin"))
        XCTAssertLessThan(idx("customStudySession"), idx("practiceAttempt"))

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: backup.url)
        XCTAssertEqual(prepared.sourceFormatVersion, 7)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let context = try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_contexts WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.noteID)]
            )
            let row = try XCTUnwrap(context)
            XCTAssertEqual(row["source_type"] as? String, "ocr")
            XCTAssertEqual(row["original_sentence"] as? String, "パンを食べたい。")
            XCTAssertEqual(row["dictionary_entry_id"] as? Int64, 1_358_280)
            XCTAssertEqual(row["dictionary_sense_key"] as? String, "1358280-1")
            XCTAssertEqual(row["is_primary"] as? Int64, 1)

            let session = try Row.fetchOne(
                db,
                sql: "SELECT status, queue_json FROM custom_study_sessions WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.sessionID)]
            )
            XCTAssertEqual(session?["status"] as? String, "finished")

            let attempt = try Row.fetchOne(
                db,
                sql: "SELECT card_key, rating, duration_ms FROM practice_attempts"
            )
            XCTAssertEqual(
                attempt?["card_key"] as? String,
                DatabaseValueCodec.encode(fixture.cardID)
            )
            XCTAssertEqual(attempt?["rating"] as? Int64, 3)

            let origin = try Row.fetchOne(
                db,
                sql: "SELECT submission_kind FROM scheduled_review_origins WHERE event_id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.reviewEventID)]
            )
            XCTAssertEqual(origin?["submission_kind"] as? String, "customScheduled")
        }
    }

    /// 恢复语义：导出时 active 的 session 在目标库标 interrupted，
    /// finished_at 落在导出时刻。
    func testActiveSessionRestoresAsInterrupted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source, sessionStatus: "active")
        let backup = try await fixture.export(source)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: backup.url)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let session = try Row.fetchOne(
                db,
                sql: "SELECT status, finished_at_ms FROM custom_study_sessions"
            )
            let row = try XCTUnwrap(session)
            XCTAssertEqual(row["status"] as? String, "interrupted")
            let expectedMs = try DatabaseValueCodec.encode(fixture.exportedAt)
            XCTAssertEqual(row["finished_at_ms"] as? Int64, expectedMs)
        }
    }

    /// v6 记录文件（无新表记录）仍能导入——新表在临时库中存在但为空。
    func testV6RecordsStillImportWithEmptyNewTables() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source, sessionStatus: "finished")
        let backup = try await fixture.export(source)

        let legacyURL = fixture.rootURL.appendingPathComponent("v6.oboe-backup")
        try rewriteBackup(backup.url, to: legacyURL) { objects in
            downgradeBackupToLegacyFormat(&objects, version: 6)
        }
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: legacyURL)
        XCTAssertEqual(prepared.sourceFormatVersion, 6)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            for table in [
                "source_contexts", "custom_study_sessions",
                "practice_attempts", "scheduled_review_origins"
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0
                )
            }
            // 旧表数据仍完整恢复。
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"),
                1
            )
        }
    }

    /// 不可解析的 image_reference 在 source_contexts 上同样降级为 NULL
    /// （D09：finalize 覆盖统一引用集）。
    func testUnresolvedSourceContextImageReferenceDegradesToNull() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(
            source,
            sessionStatus: "finished",
            sourceImageReference: "inbox-missing-resource"
        )
        let backup = try await fixture.export(source)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: backup.url)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let reference: String? = try Row.fetchOne(
                db,
                sql: "SELECT image_reference FROM source_contexts"
            )?["image_reference"]
            XCTAssertNil(reference)
            // 其余字段保留——降级只清引用不丢来源。
            let sentence: String? = try Row.fetchOne(
                db,
                sql: "SELECT original_sentence FROM source_contexts"
            )?["original_sentence"]
            XCTAssertEqual(sentence, "パンを食べたい。")
        }
    }

    /// session 的 filter_json 损坏（CHECK 放行但解码失败）→ 拒绝。
    func testMalformedSessionFilterJSONRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source, sessionStatus: "finished")
        try await source.pool.write { db in
            // 绕过领域层直接写合法 JSON 但不合领域结构的值。
            try db.execute(
                sql: "UPDATE custom_study_sessions SET filter_json = '{}'"
            )
        }
        let backup = try await fixture.export(source)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        do {
            _ = try await fixture.preparer(current: current)
                .prepare(fileURL: backup.url)
            XCTFail("malformed filter_json must be rejected")
        } catch let error as PortableBackupPreparationError {
            guard case .databaseValidation = error else {
                return XCTFail("expected databaseValidation, got \(error)")
            }
        }
    }
}

private extension PortableBackupV7RecordsTests {
    struct Fixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let reviewEventID = UUID()
        let sessionID = UUID()

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupV7RecordsTests-\(UUID().uuidString)",
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

        func preparer(current: OboeDatabase) -> PortableBackupRestorationPreparer {
            PortableBackupRestorationPreparer(
                currentDatabase: current,
                workingDirectoryURL: preparationsURL
            )
        }

        func export(_ database: OboeDatabase) async throws -> PortableBackupExport {
            try await PortableBackupExporter(
                database: database,
                workingDirectoryURL: exportsURL
            ).export(appVersion: "test", at: exportedAt)
        }

        func backupObjects(_ url: URL) throws -> [[String: Any]] {
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8))
                        as? [String: Any]
                }
        }

        func seed(
            _ database: OboeDatabase,
            sessionStatus: String,
            sourceImageReference: String? = nil
        ) async throws {
            let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
            let parameters = String(
                decoding: try JSONEncoder().encode(
                    SchedulerProfile.fsrs6DefaultParameters
                ),
                as: UTF8.self
            )
            let filterJSON = String(
                decoding: try JSONEncoder().encode(CustomStudyFilter()),
                as: UTF8.self
            )
            let queueJSON = String(
                decoding: try JSONEncoder().encode(
                    CustomStudyQueue.ordered(
                        cardIDs: [cardID],
                        order: .due,
                        randomSeed: nil,
                        generatedAt: exportedAt
                    )
                ),
                as: UTF8.self
            )
            // origin 需要指向真实 review_logs 行——快照经
            // validateScheduling 严格校验，用真实编码产物。
            let previous = ReviewSchedulingSnapshot(
                scheduling: SchedulingCard(
                    dueAt: exportedAt,
                    state: .new
                ),
                firstStudiedAt: nil,
                stateVersion: 0,
                algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                profileID: profileID
            )
            let next = ReviewSchedulingSnapshot(
                scheduling: SchedulingCard(
                    dueAt: exportedAt.addingTimeInterval(86_400),
                    stability: 4,
                    difficulty: 4,
                    elapsedDays: 0,
                    scheduledDays: 1,
                    learningStep: 0,
                    repetitions: 1,
                    lapses: 0,
                    state: .review,
                    lastReviewAt: exportedAt
                ),
                firstStudiedAt: exportedAt,
                stateVersion: 1,
                algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                profileID: profileID
            )
            let encoder = JSONEncoder()
            let previousJSON = String(
                decoding: try encoder.encode(previous), as: UTF8.self
            )
            let nextJSON = String(
                decoding: try encoder.encode(next), as: UTF8.self
            )
            try await database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO decks VALUES (?, 'A', 0, 1, 2)",
                    arguments: [encode(deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                                  'manual', 2, 1, 2)
                        """,
                    arguments: [encode(noteID), encode(deckID)]
                )
                try insertHomeMembershipIfSupported(
                    noteID: noteID, deckID: deckID, in: db
                )
                try db.execute(
                    sql: """
                        INSERT INTO scheduler_profiles(
                            id, configuration_version, algorithm_version,
                            library_revision, parameters_json, desired_retention,
                            max_interval_days, created_at_ms
                        ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0',
                                  ?, ?, 0.9, 36500, 1)
                        """,
                    arguments: [
                        encode(profileID),
                        SwiftFSRSReviewScheduler.dependencyRevision,
                        parameters
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state,
                            due_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 2, 1789056000000,
                                  4, 4, 1, 0, 1, 0, 0, 1, 'FSRS-6.0', ?)
                        """,
                    arguments: [encode(cardID), encode(noteID), encode(profileID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO study_days(
                            id, local_date, time_zone_id, starts_at_ms,
                            ends_at_ms, new_limit
                        ) VALUES (?, '2026-09-11', 'Asia/Shanghai',
                                  1789056000000, 1789142400000, 10)
                        """,
                    arguments: [encode(studyDayID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO review_logs(
                            id, event_id, card_id, card_key, note_id,
                            deck_id_at_review, reviewed_at_ms, study_day_id,
                            was_first_study, rating, previous_state_json,
                            next_state_json, duration_ms, content_version,
                            profile_id, algorithm_version, undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, 1789056000123, ?, 1, 3,
                                  ?, ?, 800, 2, ?, 'FSRS-6.0', NULL)
                        """,
                    arguments: [
                        encode(UUID()), encode(reviewEventID), encode(cardID),
                        encode(cardID), encode(noteID), encode(deckID),
                        encode(studyDayID), previousJSON, nextJSON,
                        encode(profileID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO source_contexts(
                            id, note_id, source_type, original_sentence,
                            surrounding_text, source_title, source_url,
                            source_app, image_reference, dictionary_entry_id,
                            dictionary_version, dictionary_sense_key,
                            selected_gloss_language, is_primary, created_at_ms
                        ) VALUES (?, ?, 'ocr', 'パンを食べたい。', '上下文',
                                  'テスト記事', 'https://example.com/a',
                                  'com.example.reader', ?, 1358280,
                                  '2026.09.24-1', '1358280-1', 'zho', 1, 3)
                        """,
                    arguments: [
                        encode(UUID()), encode(noteID),
                        sourceImageReference ?? NSNull()
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO custom_study_sessions(
                            id, filter_json, mode, status,
                            started_at_ms, finished_at_ms, queue_json
                        ) VALUES (?, ?, 'scheduled', ?, 1789056000100, NULL, ?)
                        """,
                    arguments: [encode(sessionID), filterJSON, sessionStatus, queueJSON]
                )
                try db.execute(
                    sql: """
                        INSERT INTO practice_attempts(
                            id, event_id, session_id, card_key, note_id,
                            rating, answered_at_ms, duration_ms,
                            content_version, undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, 3, 1789056000150, 400, 2, NULL)
                        """,
                    arguments: [
                        encode(UUID()), encode(UUID()), encode(sessionID),
                        encode(cardID), encode(noteID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO scheduled_review_origins(
                            event_id, session_id, submission_kind
                        ) VALUES (?, ?, 'customScheduled')
                        """,
                    arguments: [encode(reviewEventID), encode(sessionID)]
                )
            }
        }
    }
}
