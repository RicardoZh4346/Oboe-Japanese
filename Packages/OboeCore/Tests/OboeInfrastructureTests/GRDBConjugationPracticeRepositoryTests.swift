import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S15 活用练习 GRDB 仓储测试：v21 schema 落地、幂等回放、撤销软删除、
/// 会话级联删除，以及 practice-only 隔离断言（练习后 review_logs /
/// study_days / daily_tasks / practice_attempts 行数不变）。
final class GRDBConjugationPracticeRepositoryTests: XCTestCase {

    private var directory: URL!
    private var pool: DatabasePool!
    private var store: GRDBConjugationPracticeRepository!
    private var service: ConjugationPracticeService!
    private var clock: ClockBox!

    private final class ClockBox: @unchecked Sendable {
        var ms: Int64
        init(_ ms: Int64) { self.ms = ms }
        func advance(seconds: Int64 = 60) { ms += seconds * 1_000 }
        var date: Date {
            Date(timeIntervalSince1970: Double(ms) / 1_000)
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Conjugation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: config)
        // 已注册迁移全量施加；v21 未注册（主 agent 排号），按 v18 测试
        // 同款手动注册追加。
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        var v21 = DatabaseMigrator()
        v21.registerMigration(
            GRDBConjugationSchema.expectedMigrationIdentifier,
            migrate: GRDBConjugationSchema.migrate)
        try v21.migrate(pool)

        store = GRDBConjugationPracticeRepository(pool: pool)
        clock = ClockBox(1_700_000_000_000)
        let clock = self.clock!
        service = ConjugationPracticeService(
            store: store, now: { clock.date })
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func question(
        lemma: String = "食べる", reading: String? = "たべる",
        cls: ConjugationClass = .ichidan, form: ConjugationForm = .te
    ) throws -> ConjugationQuestion {
        try service.makeQuestion(ConjugationExercise(
            lemma: lemma, reading: reading,
            conjugationClass: cls, form: form))
    }

    private func countRows(_ table: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: - schema

    func testMigrationCreatesTablesAndConstraints() async throws {
        let tables = try await pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type='table' AND name LIKE 'conjugation%'
                    ORDER BY name
                    """)
        }
        XCTAssertEqual(tables, [
            "conjugation_practice_attempts", "conjugation_sessions"])
        // CHECK：correct 必须有 matched_answer
        let session = try await service.startSession()
        await XCTAssertThrowsErrorAsync(try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conjugation_practice_attempts(
                        id, event_id, session_id, question_id,
                        lemma, reading, conjugation_class, form, rule_id,
                        prompt, expected_primary, accepted_json,
                        user_input, normalized_input, result,
                        matched_answer, duration_ms, answered_at_ms,
                        undone_at_ms)
                    VALUES (?, ?, ?, ?, 'x', NULL, 'ichidan', 'te',
                            'r', 'p', 'y', '[]', 'u', 'u', 'correct',
                            NULL, 0, 1, NULL)
                    """,
                arguments: [
                    UUID().uuidString, UUID().uuidString,
                    session.id.uuidString, UUID().uuidString
                ])
        })
    }

    // MARK: - 会话 + 作答往返

    func testRecordAttemptRoundTrip() async throws {
        let session = try await service.startSession(
            plannedQuestionCount: 5)
        let q = try question()
        let attempt = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 1500)
        XCTAssertEqual(attempt.result, .correct)

        let list = try await store.attempts(
            sessionID: session.id, includeUndone: true)
        XCTAssertEqual(list.count, 1)
        let row = list[0]
        XCTAssertEqual(row.lemma, "食べる")
        XCTAssertEqual(row.reading, "たべる")
        XCTAssertEqual(row.conjugationClass, "ichidan")
        XCTAssertEqual(row.form, "te")
        XCTAssertEqual(row.ruleID, "conj.ichidan.te")
        XCTAssertEqual(row.prompt, "食べる（たべる）→ て形")
        XCTAssertEqual(row.expectedPrimary, "食べて")
        XCTAssertEqual(row.acceptedTexts, ["食べて", "たべて"])
        XCTAssertEqual(row.normalizedInput, "食べて")
        XCTAssertEqual(row.matchedAnswer, "食べて")
        XCTAssertEqual(row.durationMilliseconds, 1500)
        XCTAssertNil(row.undoneAt)
    }

    func testIdempotentReplayReturnsStoredRow() async throws {
        let session = try await service.startSession()
        let q = try question()
        let eventID = UUID()
        let first = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100,
            eventID: eventID)
        let replay = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100,
            eventID: eventID)
        XCTAssertEqual(first.id, replay.id)
        XCTAssertEqual(first.eventID, replay.eventID)
        let rowCount = try await countRows("conjugation_practice_attempts")
        XCTAssertEqual(rowCount, 1)
    }

    func testConflictingEventIDThrows() async throws {
        let session = try await service.startSession()
        let q = try question()
        let eventID = UUID()
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100,
            eventID: eventID)
        await XCTAssertThrowsErrorAsync(
            try await service.submitAnswer(
                sessionID: session.id, question: q,
                input: "食べた", durationMilliseconds: 100,
                eventID: eventID)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError,
                .conflictingEventID(eventID))
        }
    }

    // MARK: - 撤销

    func testUndoSoftDeletesLatestOnly() async throws {
        let session = try await service.startSession()
        let q = try question()
        let first = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 100)
        clock.advance(seconds: 2)
        let second = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べた", durationMilliseconds: 200)

        let undone = try await service.undoLatestAnswer(
            sessionID: session.id)
        XCTAssertEqual(undone?.eventID, second.eventID)
        XCTAssertNotNil(undone?.undoneAt)
        // 软删除：行还在
        let all = try await store.attempts(
            sessionID: session.id, includeUndone: true)
        XCTAssertEqual(all.count, 2)
        let active = try await store.attempts(
            sessionID: session.id, includeUndone: false)
        XCTAssertEqual(active.map(\.eventID), [first.eventID])
        // 幂等：已撤销行再次 undoLatest 跳过
        let secondUndo = try await service.undoLatestAnswer(
            sessionID: session.id)
        XCTAssertEqual(secondUndo?.eventID, first.eventID)
        let thirdUndo = try await service.undoLatestAnswer(
            sessionID: session.id)
        XCTAssertNil(thirdUndo)
    }

    func testSessionDeleteCascadesAttempts() async throws {
        let session = try await service.startSession()
        let q = try question()
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 1)
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM conjugation_sessions WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(session.id)])
        }
        let remaining = try await countRows("conjugation_practice_attempts")
        XCTAssertEqual(remaining, 0)
    }

    // MARK: - practice-only 隔离（验收红线）

    /// 完整练习流程后，正式调度/统计/卡片练习表的行数必须不变。
    func testPracticeIsolatesFromSchedulingTables() async throws {
        let watchTables = [
            "review_logs", "study_days", "daily_tasks",
            "practice_attempts", "reader_activity_events",
        ]
        var before: [String: Int] = [:]
        for table in watchTables {
            before[table] = try await countRows(table)
        }

        // 完整会话：开 → 3 题（对/错/变体）→ 撤销 → 结束。
        let session = try await service.startSession(
            plannedQuestionCount: 3)
        let q1 = try question(
            lemma: "食べる", cls: .ichidan, form: .te)
        let q2 = try question(
            lemma: "書く", reading: "かく", cls: .godanKu,
            form: .causativePassive)
        let q3 = try question(
            lemma: "来る", cls: .kuru, form: .past)
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q1,
            input: "食べて", durationMilliseconds: 1000)
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q2,
            input: "書かされる", durationMilliseconds: 2000)
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q3,
            input: "きた", durationMilliseconds: 500)
        _ = try await service.undoLatestAnswer(sessionID: session.id)
        try await service.finishSession(id: session.id)

        for table in watchTables {
            let after = try await countRows(table)
            XCTAssertEqual(
                after, before[table],
                "practice 不得写 \(table)")
        }
        // 练习数据本身落库
        let attemptCount = try await countRows("conjugation_practice_attempts")
        let sessionCount = try await countRows("conjugation_sessions")
        XCTAssertEqual(attemptCount, 3)
        XCTAssertEqual(sessionCount, 1)
    }

    /// 中断会话可正常 abandon，attempts 保留。
    func testAbandonedSessionKeepsAttempts() async throws {
        let session = try await service.startSession()
        let q = try question()
        _ = try await service.submitAnswer(
            sessionID: session.id, question: q,
            input: "食べて", durationMilliseconds: 1)
        try await service.abandonSession(id: session.id)
        let stored = try await store.session(id: session.id)
        XCTAssertEqual(stored?.status, .abandoned)
        let activeCount = try await store.attempts(
            sessionID: session.id, includeUndone: false).count
        XCTAssertEqual(activeCount, 1)
        // abandoned 后不能再作答
        await XCTAssertThrowsErrorAsync(
            try await service.submitAnswer(
                sessionID: session.id, question: q,
                input: "食べて", durationMilliseconds: 1)
        ) {
            XCTAssertEqual(
                $0 as? ConjugationPracticeError,
                .sessionNotActive(session.id))
        }
    }
}

/// async 断言辅助。
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        handler(error)
    }
}
