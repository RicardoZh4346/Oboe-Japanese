import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v16 `custom_study_sessions` / `practice_attempts` /
/// `scheduled_review_origins` 仓储测试（设计 §7.1–7.3，D06/§2.3）。
/// 迁移已注册进 `makeMigrator`（`v16_custom_study` →
/// `GRDBCustomStudyRepository.createCustomStudySchema`）。
final class GRDBCustomStudyRepositoryTests: XCTestCase {

    // MARK: - v16 DDL（自建 migrator 验证，不经 makeMigrator）

    func testV16TableShapesAndConstraints() async throws {
        try await withRepository { _, fixture in
            try await fixture.database.pool.read { db in
                XCTAssertTrue(try db.tableExists("custom_study_sessions"))
                XCTAssertTrue(try db.tableExists("practice_attempts"))
                XCTAssertTrue(try db.tableExists("scheduled_review_origins"))
                XCTAssertEqual(
                    Set(try db.columns(in: "custom_study_sessions").map(\.name)),
                    [
                        "id", "filter_json", "mode", "status",
                        "started_at_ms", "finished_at_ms", "queue_json"
                    ]
                )
                XCTAssertEqual(
                    Set(try db.columns(in: "practice_attempts").map(\.name)),
                    [
                        "id", "event_id", "session_id", "card_key",
                        "note_id", "rating", "answered_at_ms", "duration_ms",
                        "content_version", "undone_at_ms"
                    ]
                )
                XCTAssertEqual(
                    Set(try db.columns(in: "scheduled_review_origins").map(\.name)),
                    ["event_id", "session_id", "submission_kind"]
                )
            }

            let sessionID = UUID().uuidString.lowercased()
            try await fixture.database.pool.write { db in
                // 合法行。
                try db.execute(
                    sql: """
                        INSERT INTO custom_study_sessions(
                            id, filter_json, mode, status,
                            started_at_ms, finished_at_ms, queue_json
                        ) VALUES (?, '{}', 'practiceOnly', 'active', 1, NULL, '[]')
                        """,
                    arguments: [sessionID]
                )
            }
            // mode/status CHECK。
            try await assertConstraintFails(fixture.database) { db in
                try db.execute(
                    sql: """
                        INSERT INTO custom_study_sessions(
                            id, filter_json, mode, status,
                            started_at_ms, finished_at_ms, queue_json
                        ) VALUES (?, '{}', 'practice', 'active', 1, NULL, '[]')
                        """,
                    arguments: [UUID().uuidString.lowercased()]
                )
            }
            try await assertConstraintFails(fixture.database) { db in
                try db.execute(
                    sql: """
                        INSERT INTO custom_study_sessions(
                            id, filter_json, mode, status,
                            started_at_ms, finished_at_ms, queue_json
                        ) VALUES (?, '{}', 'practiceOnly', 'paused', 1, NULL, '[]')
                        """,
                    arguments: [UUID().uuidString.lowercased()]
                )
            }
            // filter_json / queue_json 必须 json_valid。
            try await assertConstraintFails(fixture.database) { db in
                try db.execute(
                    sql: """
                        INSERT INTO custom_study_sessions(
                            id, filter_json, mode, status,
                            started_at_ms, finished_at_ms, queue_json
                        ) VALUES (?, 'not-json', 'practiceOnly', 'active', 1, NULL, '[]')
                        """,
                    arguments: [UUID().uuidString.lowercased()]
                )
            }
            // event_id UNIQUE + rating/duration CHECK。
            let eventID = UUID().uuidString.lowercased()
            try await fixture.database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO practice_attempts(
                            id, event_id, session_id, card_key, note_id, rating,
                            answered_at_ms, duration_ms, content_version
                        ) VALUES (?, ?, ?, ?, ?, 3, 100, 50, 1)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(), eventID, sessionID,
                        UUID().uuidString.lowercased(),
                        UUID().uuidString.lowercased()
                    ]
                )
            }
            try await assertConstraintFails(fixture.database) { db in
                try db.execute(
                    sql: """
                        INSERT INTO practice_attempts(
                            id, event_id, session_id, card_key, note_id, rating,
                            answered_at_ms, duration_ms, content_version
                        ) VALUES (?, ?, ?, ?, ?, 3, 101, 50, 1)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(), eventID, sessionID,
                        UUID().uuidString.lowercased(),
                        UUID().uuidString.lowercased()
                    ]
                )
            }
            try await assertConstraintFails(fixture.database) { db in
                try db.execute(
                    sql: """
                        INSERT INTO practice_attempts(
                            id, event_id, session_id, card_key, note_id, rating,
                            answered_at_ms, duration_ms, content_version
                        ) VALUES (?, ?, ?, ?, ?, 5, 100, 50, 1)
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(),
                        UUID().uuidString.lowercased(), sessionID,
                        UUID().uuidString.lowercased(),
                        UUID().uuidString.lowercased()
                    ]
                )
            }
            // submission_kind CHECK。
            try await assertConstraintFails(fixture.database) { db in
                try db.execute(
                    sql: """
                        INSERT INTO scheduled_review_origins(
                            event_id, session_id, submission_kind
                        ) VALUES (?, ?, 'normal')
                        """,
                    arguments: [
                        UUID().uuidString.lowercased(), sessionID
                    ]
                )
            }
        }
    }

    // MARK: - 会话 CRUD 与「至多一个 active」

    func testSessionRoundTripPreservesFilterAndQueue() async throws {
        try await withRepository { repository, _ in
            let filter = CustomStudyFilter(
                preset: .earlyReview,
                deckIDs: [UUID()],
                tagIDs: [UUID()],
                jlptLevels: [.n2],
                favoriteOnly: true,
                earlyReviewWindowDays: 14,
                limit: 120,
                order: .random,
                randomSeed: 7
            )
            let queue = CustomStudyQueue(
                cardIDs: [UUID(), UUID()],
                order: .random,
                randomSeed: 7,
                generatedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            let session = CustomStudySession(
                id: UUID(),
                filter: filter,
                mode: .scheduled,
                status: .active,
                queue: queue,
                startedAt: Date(timeIntervalSince1970: 1_768_000_000),
                finishedAt: nil
            )
            try await repository.createSession(session)

            let fetched = try await repository.fetchSession(id: session.id)
            XCTAssertEqual(fetched, session, "filter_json/queue_json 必须完整回读")
            let active = try await repository.fetchActiveSession()
            XCTAssertEqual(active?.id, session.id)
        }
    }

    /// 「至多一个 active」：插入第二个 active session 的同一事务里，
    /// 旧的被标 interrupted（finished_at = 新 session 的 started_at）。
    func testCreateSessionInterruptsPreviousActive() async throws {
        try await withRepository { repository, _ in
            let t1 = Date(timeIntervalSince1970: 1_768_000_000)
            let t2 = Date(timeIntervalSince1970: 1_768_000_600)
            let first = makeSession(startedAt: t1)
            let second = makeSession(startedAt: t2)

            try await repository.createSession(first)
            try await repository.createSession(second)

            let oldSession = try await repository.fetchSession(id: first.id)
            XCTAssertEqual(oldSession?.status, .interrupted)
            XCTAssertEqual(oldSession?.finishedAt, t2)
            let active = try await repository.fetchActiveSession()
            XCTAssertEqual(active?.id, second.id)
        }
    }

    /// 插入非 active 会话（恢复/补录路径）不打断现存 active。
    func testCreateNonActiveSessionDoesNotInterrupt() async throws {
        try await withRepository { repository, _ in
            let active = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(active)
            let historical = makeSession(
                status: .interrupted,
                startedAt: Date(timeIntervalSince1970: 1_767_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_767_000_100)
            )
            try await repository.createSession(historical)

            let fetchedActive = try await repository.fetchActiveSession()
            XCTAssertEqual(fetchedActive?.id, active.id)
        }
    }

    func testUpdateSessionStatusRules() async throws {
        try await withRepository { repository, _ in
            let session = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)

            let finishedAt = Date(timeIntervalSince1970: 1_768_000_900)
            try await repository.updateSessionStatus(
                id: session.id,
                to: .finished,
                finishedAt: finishedAt
            )
            let finished = try await repository.fetchSession(id: session.id)
            XCTAssertEqual(finished?.status, .finished)
            XCTAssertEqual(finished?.finishedAt, finishedAt)

            // 复活被拒绝。
            await assertRepoError(.invalidStatusTransition) {
                try await repository.updateSessionStatus(
                    id: session.id,
                    to: .active,
                    finishedAt: nil
                )
            }
            // 非 active 源行再迁移被拒绝。
            await assertRepoError(.invalidStatusTransition) {
                try await repository.updateSessionStatus(
                    id: session.id,
                    to: .interrupted,
                    finishedAt: finishedAt
                )
            }
            // 行不存在。
            let missing = UUID()
            await assertRepoError(.sessionNotFound(missing)) {
                try await repository.updateSessionStatus(
                    id: missing,
                    to: .finished,
                    finishedAt: finishedAt
                )
            }
            // 幂等键冲突：同 id 的 session 不能二次插入。
            await assertRepoError(.sessionAlreadyExists(session.id)) {
                try await repository.createSession(
                    makeSession(id: session.id, status: .finished)
                )
            }
        }
    }

    /// 恢复语义：即便不变量被破坏出现多个 active，
    /// `interruptActiveSessions` 也能一次性全部打断。
    func testInterruptActiveSessionsSweepsAll() async throws {
        try await withRepository { repository, fixture in
            let first = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(first)
            // 直写第二个 active，绕过 createSession 的事务内打断。
            let second = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_100)
            )
            // 直写第二个 active，绕过 createSession 的事务内打断；
            // filter/queue 写合法 JSON，后续 fetchSession 才能解码。
            let filterJSON = String(
                decoding: try JSONEncoder().encode(second.filter),
                as: UTF8.self
            )
            let queueJSON = String(
                decoding: try JSONEncoder().encode(second.queue),
                as: UTF8.self
            )
            try await fixture.database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO custom_study_sessions(
                            id, filter_json, mode, status,
                            started_at_ms, finished_at_ms, queue_json
                        ) VALUES (?, ?, 'practiceOnly', 'active', ?, NULL, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(second.id),
                        filterJSON,
                        DatabaseValueCodec.encode(second.startedAt),
                        queueJSON
                    ]
                )
            }

            let sweptAt = Date(timeIntervalSince1970: 1_768_000_999)
            let count = try await repository.interruptActiveSessions(at: sweptAt)
            XCTAssertEqual(count, 2)
            let activeAfterSweep = try await repository.fetchActiveSession()
            XCTAssertNil(activeAfterSweep)
            for id in [first.id, second.id] {
                let session = try await repository.fetchSession(id: id)
                XCTAssertEqual(session?.status, .interrupted)
                XCTAssertEqual(session?.finishedAt, sweptAt)
            }
        }
    }

    // MARK: - practice_attempts

    func testPracticeAttemptRoundTripAndOrdering() async throws {
        try await withRepository { repository, _ in
            let session = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let base = Date(timeIntervalSince1970: 1_768_000_000)
            let attemptB = makeAttempt(
                sessionID: session.id,
                answeredAt: base.addingTimeInterval(200)
            )
            let attemptA = makeAttempt(
                sessionID: session.id,
                answeredAt: base.addingTimeInterval(100)
            )
            try await repository.recordPracticeAttempt(attemptB)
            try await repository.recordPracticeAttempt(attemptA)

            let attempts = try await repository.fetchAttempts(
                sessionID: session.id
            )
            XCTAssertEqual(
                attempts.map(\.id),
                [attemptA.id, attemptB.id],
                "按 (answered_at_ms, id) 升序"
            )
            let fetched = try await repository.fetchAttempt(
                eventID: attemptA.eventID
            )
            XCTAssertEqual(fetched, attemptA)
        }
    }

    /// event_id 幂等：同内容重放返回已存行且不重复落行；
    /// 撤销后的重放也返回现状（含 undoneAt）。
    func testPracticeAttemptIdempotentReplay() async throws {
        try await withRepository { repository, fixture in
            let session = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let attempt = makeAttempt(sessionID: session.id)
            try await repository.recordPracticeAttempt(attempt)

            // 同 eventID + 同内容（即便行级 id 不同）→ 返回已存。
            let replay = PracticeAttempt(
                id: UUID(),
                eventID: attempt.eventID,
                sessionID: attempt.sessionID,
                cardKey: attempt.cardKey,
                noteID: attempt.noteID,
                rating: attempt.rating,
                answeredAt: attempt.answeredAt,
                durationMilliseconds: attempt.durationMilliseconds,
                contentVersion: attempt.contentVersion
            )
            let returned = try await repository.recordPracticeAttempt(replay)
            XCTAssertEqual(returned, attempt)
            let count = try await fixture.database.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM practice_attempts"
                )
            }
            XCTAssertEqual(count, 1)

            // 撤销后同内容重放返回已存行（含 undoneAt）。
            let undoneAt = Date(timeIntervalSince1970: 1_768_000_500)
            _ = try await repository.undoPracticeAttempt(
                eventID: attempt.eventID,
                undoneAt: undoneAt
            )
            let replayed = try await repository.recordPracticeAttempt(replay)
            XCTAssertEqual(replayed.undoneAt, undoneAt)
        }
    }

    func testPracticeAttemptConflictingEventID() async throws {
        try await withRepository { repository, _ in
            let session = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let attempt = makeAttempt(sessionID: session.id)
            try await repository.recordPracticeAttempt(attempt)

            let conflicting = PracticeAttempt(
                id: attempt.id,
                eventID: attempt.eventID,
                sessionID: attempt.sessionID,
                cardKey: attempt.cardKey,
                noteID: attempt.noteID,
                rating: .easy,
                answeredAt: attempt.answeredAt,
                durationMilliseconds: attempt.durationMilliseconds,
                contentVersion: attempt.contentVersion
            )
            await assertRepoError(.conflictingEventID(attempt.eventID)) {
                try await repository.recordPracticeAttempt(conflicting)
            }
        }
    }

    func testPracticeAttemptMissingSessionMapsToDomainError() async throws {
        try await withRepository { repository, _ in
            let missing = UUID()
            let attempt = makeAttempt(sessionID: missing)
            await assertRepoError(.sessionNotFound(missing)) {
                try await repository.recordPracticeAttempt(attempt)
            }
        }
    }

    /// 撤销只置 undone_at_ms：不动 FSRS（cards.state_version 不变），
    /// 不写 review_logs。
    func testUndoPracticeAttemptOnlyMarksUndone() async throws {
        try await withRepository { repository, fixture in
            let session = makeSession(
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let attempt = makeAttempt(sessionID: session.id)
            try await repository.recordPracticeAttempt(attempt)

            let undoneAt = Date(timeIntervalSince1970: 1_768_000_500)
            let undone = try await repository.undoPracticeAttempt(
                eventID: attempt.eventID,
                undoneAt: undoneAt
            )
            XCTAssertEqual(undone.undoneAt, undoneAt)
            XCTAssertEqual(undone.rating, attempt.rating)

            await assertRepoError(.attemptAlreadyUndone(attempt.eventID)) {
                try await repository.undoPracticeAttempt(
                    eventID: attempt.eventID,
                    undoneAt: undoneAt
                )
            }
            let missing = UUID()
            await assertRepoError(.attemptNotFound(missing)) {
                try await repository.undoPracticeAttempt(
                    eventID: missing,
                    undoneAt: undoneAt
                )
            }

            // D06：practice 路径绝不写正式 review_logs。
            let logCount = try await fixture.database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs")
            }
            XCTAssertEqual(logCount, 0)
        }
    }

    // MARK: - scheduled_review_origins

    func testScheduledOriginRoundTripAndIdempotency() async throws {
        try await withRepository { repository, fixture in
            let session = makeSession(
                mode: .scheduled,
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let setup = try await fixture.insertCardGraph()
            let studyDayID = try await fixture.addStudyDay(
                startsAt: Date(timeIntervalSince1970: 1_767_999_600),
                endsAt: Date(timeIntervalSince1970: 1_768_086_000)
            )
            let eventID = try await fixture.addReviewLog(
                cardKey: setup.cardID,
                noteID: setup.noteID,
                deckID: setup.deckID,
                studyDayID: studyDayID,
                rating: .good,
                reviewedAt: Date(timeIntervalSince1970: 1_768_000_100)
            )

            let origin = ScheduledReviewOrigin(
                eventID: eventID,
                sessionID: session.id
            )
            try await repository.recordScheduledOrigin(origin)
            let fetched = try await repository.fetchScheduledOrigin(
                eventID: eventID
            )
            XCTAssertEqual(fetched, origin)

            // 同内容重放幂等；不同内容冲突。
            try await repository.recordScheduledOrigin(origin)
            await assertRepoError(.conflictingEventID(eventID)) {
                try await repository.recordScheduledOrigin(
                    ScheduledReviewOrigin(
                        eventID: eventID,
                        sessionID: UUID()
                    )
                )
            }
        }
    }

    func testScheduledOriginMissingReviewLog() async throws {
        try await withRepository { repository, _ in
            let session = makeSession(
                mode: .scheduled,
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let eventID = UUID()
            await assertRepoError(.missingReviewLog(eventID)) {
                try await repository.recordScheduledOrigin(
                    ScheduledReviewOrigin(eventID: eventID, sessionID: session.id)
                )
            }
        }
    }

    /// session 删除级联抹掉 attempts/origins，但正式 review_logs 保留
    /// （origin → review_logs 是 RESTRICT 引用，不是父表）。
    func testSessionDeleteCascadesButKeepsReviewLogs() async throws {
        try await withRepository { repository, fixture in
            let session = makeSession(
                mode: .scheduled,
                startedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.createSession(session)
            let setup = try await fixture.insertCardGraph()
            let studyDayID = try await fixture.addStudyDay(
                startsAt: Date(timeIntervalSince1970: 1_767_999_600),
                endsAt: Date(timeIntervalSince1970: 1_768_086_000)
            )
            let eventID = try await fixture.addReviewLog(
                cardKey: setup.cardID,
                noteID: setup.noteID,
                deckID: setup.deckID,
                studyDayID: studyDayID,
                rating: .good,
                reviewedAt: Date(timeIntervalSince1970: 1_768_000_100)
            )
            try await repository.recordPracticeAttempt(
                makeAttempt(sessionID: session.id)
            )
            try await repository.recordScheduledOrigin(
                ScheduledReviewOrigin(eventID: eventID, sessionID: session.id)
            )

            try await fixture.database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM custom_study_sessions WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(session.id)]
                )
            }

            let attempts = try await repository.fetchAttempts(
                sessionID: session.id
            )
            XCTAssertTrue(attempts.isEmpty)
            let originAfterDelete = try await repository.fetchScheduledOrigin(
                eventID: eventID
            )
            XCTAssertNil(originAfterDelete)
            let logCount = try await fixture.database.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM review_logs WHERE event_id = ?",
                    arguments: [DatabaseValueCodec.encode(eventID)]
                )
            }
            XCTAssertEqual(logCount, 1, "正式 review_log 不随 session 消失")
        }
    }

    // MARK: - 队列生成

    /// 稳定序 = (due_at_ms, id)；limit 截断在候选集层面。
    func testQueueStableOrderAndLimit() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            // 插入序故意打乱 due 序；期望按 (due_at_ms, id) 稳定升序。
            var cards: [(id: UUID, dueAt: Date)] = []
            for offset in [300.0, 100.0, 200.0] {
                let noteID = try await fixture.addNote(deckID: deckID)
                let dueAt = now.addingTimeInterval(-offset)
                let cardID = try await fixture.addCard(
                    noteID: noteID,
                    state: .review,
                    dueAt: dueAt,
                    firstStudiedAt: now.addingTimeInterval(-86_400)
                )
                cards.append((cardID, dueAt))
            }
            let expected = cards
                .sorted {
                    $0.dueAt != $1.dueAt
                        ? $0.dueAt < $1.dueAt
                        : $0.id.uuidString < $1.id.uuidString
                }
                .map(\.id)
            let filter = CustomStudyFilter(limit: 2)
            let context = CustomStudyQueueContext(now: now)
            let queue = try await repository.buildQueue(
                filter: filter,
                context: context
            )
            XCTAssertEqual(queue, Array(expected.prefix(2)))
            let full = try await repository.buildQueue(
                filter: CustomStudyFilter(limit: 10),
                context: context
            )
            XCTAssertEqual(full, expected)
            let count = try await repository.countQueueCandidates(
                filter: filter,
                context: context
            )
            XCTAssertEqual(count, 3, "预览计数不受 limit 截断")
        }
    }

    func testQueueUnstudiedNewPreset() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            let noteA = try await fixture.addNote(deckID: deckID)
            let fresh = try await fixture.addCard(
                noteID: noteA, state: .new, dueAt: now
            )
            let noteB = try await fixture.addNote(deckID: deckID)
            _ = try await fixture.addCard(
                noteID: noteB, state: .review, dueAt: now,
                firstStudiedAt: now.addingTimeInterval(-86_400)
            )
            let noteC = try await fixture.addNote(deckID: deckID)
            _ = try await fixture.addCard(
                noteID: noteC, state: .new, dueAt: now, isEnabled: false
            )

            let queue = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .unstudiedNew),
                context: CustomStudyQueueContext(now: now)
            )
            XCTAssertEqual(queue, [fresh], "仅有效且 firstStudiedAt=nil 的卡")
        }
    }

    func testQueueDueSoonAndEarlyReviewWindows() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            let studied = now.addingTimeInterval(-86_400)
            func addFutureCard(hours: Double) async throws -> UUID {
                let noteID = try await fixture.addNote(deckID: deckID)
                return try await fixture.addCard(
                    noteID: noteID,
                    state: .review,
                    dueAt: now.addingTimeInterval(hours * 3_600),
                    firstStudiedAt: studied
                )
            }
            let in12h = try await addFutureCard(hours: 12)
            let in48h = try await addFutureCard(hours: 48)
            let in10d = try await addFutureCard(hours: 240)
            let noteNew = try await fixture.addNote(deckID: deckID)
            _ = try await fixture.addCard(
                noteID: noteNew, state: .new, dueAt: now.addingTimeInterval(3_600)
            )
            let noteDue = try await fixture.addNote(deckID: deckID)
            _ = try await fixture.addCard(
                noteID: noteDue, state: .review, dueAt: now,
                firstStudiedAt: studied
            )

            let context = CustomStudyQueueContext(now: now)
            let dueSoon = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .dueSoon),
                context: context
            )
            XCTAssertEqual(dueSoon, [in12h], "now < dueAt ≤ now+24h")

            let early7d = try await repository.buildQueue(
                filter: CustomStudyFilter(
                    preset: .earlyReview,
                    earlyReviewWindowDays: 7
                ),
                context: context
            )
            XCTAssertEqual(early7d, [in12h, in48h])
            let early30d = try await repository.buildQueue(
                filter: CustomStudyFilter(
                    preset: .earlyReview,
                    earlyReviewWindowDays: 30
                ),
                context: context
            )
            XCTAssertEqual(early30d, [in12h, in48h, in10d])
        }
    }

    /// 今天答错：学习日窗口内、未撤销、rating=Again，按 Card 去重；
    /// 窗口由 context 显式给出。
    func testQueueAnsweredWrongToday() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let dayStart = Date(timeIntervalSince1970: 1_768_000_000)
            let dayEnd = dayStart.addingTimeInterval(86_400)
            let now = dayStart.addingTimeInterval(3_600)
            let studyDayID = try await fixture.addStudyDay(
                startsAt: dayStart, endsAt: dayEnd
            )

            func wrongCard(
                rating: ReviewRating = .again,
                reviewedAt: Date,
                undoneAt: Date? = nil
            ) async throws -> UUID {
                let noteID = try await fixture.addNote(deckID: deckID)
                let cardID = try await fixture.addCard(
                    noteID: noteID, state: .review,
                    dueAt: now.addingTimeInterval(3_600),
                    firstStudiedAt: dayStart.addingTimeInterval(-86_400)
                )
                _ = try await fixture.addReviewLog(
                    cardKey: cardID, noteID: noteID, deckID: deckID,
                    studyDayID: studyDayID, rating: rating,
                    reviewedAt: reviewedAt, undoneAt: undoneAt
                )
                return cardID
            }

            let wrongToday = try await wrongCard(
                reviewedAt: dayStart.addingTimeInterval(600)
            )
            // 同卡窗口内第二次 Again 不重复入队。
            let dupNote = try await fixture.addNote(deckID: deckID)
            let dupCard = try await fixture.addCard(
                noteID: dupNote, state: .review,
                dueAt: now.addingTimeInterval(7_200),
                firstStudiedAt: dayStart.addingTimeInterval(-86_400)
            )
            for delta: TimeInterval in [600, 1_200] {
                _ = try await fixture.addReviewLog(
                    cardKey: dupCard, noteID: dupNote, deckID: deckID,
                    studyDayID: studyDayID, rating: .again,
                    reviewedAt: dayStart.addingTimeInterval(delta)
                )
            }
            // 窗口外 Again 不算。
            _ = try await wrongCard(
                reviewedAt: dayStart.addingTimeInterval(-1)
            )
            // 已撤销 Again 不算。
            _ = try await wrongCard(
                reviewedAt: dayStart.addingTimeInterval(900),
                undoneAt: dayStart.addingTimeInterval(1_800)
            )
            // Good 评分不算。
            _ = try await wrongCard(
                rating: .good,
                reviewedAt: dayStart.addingTimeInterval(900)
            )

            let queue = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .answeredWrongToday),
                context: CustomStudyQueueContext(
                    now: now,
                    studyDayStartsAt: dayStart,
                    studyDayEndsAt: dayEnd
                )
            )
            XCTAssertEqual(
                Set(queue), Set([wrongToday, dupCard]),
                "窗口内未撤销 Again 的卡各出现一次"
            )
        }
    }

    /// 最近 7 天错 ≥2：窗口 = [当前学习日起点 − 6d, 当前学习日终点)。
    func testQueueFrequentAgainLast7Days() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let dayStart = Date(timeIntervalSince1970: 1_768_000_000)
            let dayEnd = dayStart.addingTimeInterval(86_400)
            let now = dayStart.addingTimeInterval(3_600)
            let studyDayID = try await fixture.addStudyDay(
                startsAt: dayStart, endsAt: dayEnd
            )

            func cardWithAgains(_ offsets: [TimeInterval]) async throws -> UUID {
                let noteID = try await fixture.addNote(deckID: deckID)
                let cardID = try await fixture.addCard(
                    noteID: noteID, state: .review,
                    dueAt: now.addingTimeInterval(3_600),
                    firstStudiedAt: dayStart.addingTimeInterval(-10 * 86_400)
                )
                for offset in offsets {
                    _ = try await fixture.addReviewLog(
                        cardKey: cardID, noteID: noteID, deckID: deckID,
                        studyDayID: studyDayID, rating: .again,
                        reviewedAt: dayStart.addingTimeInterval(offset)
                    )
                }
                return cardID
            }

            // 窗口内 2 次 Again → 命中（一次 6 天前、一次今天）。
            let hit = try await cardWithAgains([-6 * 86_400 + 100, 100])
            // 窗口内只有 1 次（更早的在 7 个学习日边界外）→ 不命中。
            _ = try await cardWithAgains([-6 * 86_400 - 100, 200])
            // 窗口内 1 次 + 1 次撤销 → 不命中。
            let onceNote = try await fixture.addNote(deckID: deckID)
            let onceCardID = try await fixture.addCard(
                noteID: onceNote, state: .review,
                dueAt: now.addingTimeInterval(3_600),
                firstStudiedAt: dayStart.addingTimeInterval(-10 * 86_400)
            )
            _ = try await fixture.addReviewLog(
                cardKey: onceCardID, noteID: onceNote, deckID: deckID,
                studyDayID: studyDayID, rating: .again,
                reviewedAt: dayStart.addingTimeInterval(100)
            )
            _ = try await fixture.addReviewLog(
                cardKey: onceCardID, noteID: onceNote, deckID: deckID,
                studyDayID: studyDayID, rating: .again,
                reviewedAt: dayStart.addingTimeInterval(200),
                undoneAt: dayStart.addingTimeInterval(300)
            )

            let queue = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .frequentAgainLast7Days),
                context: CustomStudyQueueContext(
                    now: now,
                    studyDayStartsAt: dayStart,
                    studyDayEndsAt: dayEnd
                )
            )
            XCTAssertEqual(queue, [hit])
        }
    }

    /// 无 context 窗口时回退到 study_days 表中含 now 的行；
    /// 连行都没有则窗口 preset 产出空队列。
    func testQueueStudyDayWindowFallbacks() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let dayStart = Date(timeIntervalSince1970: 1_768_000_000)
            let dayEnd = dayStart.addingTimeInterval(86_400)
            let now = dayStart.addingTimeInterval(3_600)

            // 无 context 窗口且无 study_days 行 → 空。
            let empty = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .answeredWrongToday),
                context: CustomStudyQueueContext(now: now)
            )
            XCTAssertEqual(empty, [])

            // 有 study_days 行 → 回退命中。
            let studyDayID = try await fixture.addStudyDay(
                startsAt: dayStart, endsAt: dayEnd
            )
            let noteID = try await fixture.addNote(deckID: deckID)
            let cardID = try await fixture.addCard(
                noteID: noteID, state: .review,
                dueAt: now.addingTimeInterval(3_600),
                firstStudiedAt: dayStart.addingTimeInterval(-86_400)
            )
            _ = try await fixture.addReviewLog(
                cardKey: cardID, noteID: noteID, deckID: deckID,
                studyDayID: studyDayID, rating: .again,
                reviewedAt: dayStart.addingTimeInterval(600)
            )
            let queue = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .answeredWrongToday),
                context: CustomStudyQueueContext(now: now)
            )
            XCTAssertEqual(queue, [cardID])
        }
    }

    /// 回退链末端：无 context 窗口、study_days 中也没有含 now 的行
    /// 时，按 `app_settings.learning_time_zone_id` + 04:00 边界计算
    /// 当前学习日窗口。
    func testQueueStudyDayWindowFromLearningTimeZone() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            let timeZoneID = "Asia/Shanghai"
            try await fixture.setLearningTimeZone(timeZoneID)

            // 推导窗口，把 review_log 放进窗口内（FK 目标用一条
            // 不含 now 的旧 study_days 行，证明走的是时区计算分支）。
            let window = try StudyDayBoundaryCalculator().studyDay(
                containing: now,
                timeZoneID: timeZoneID,
                newCardLimit: 0
            )
            let oldStudyDayID = try await fixture.addStudyDay(
                startsAt: now.addingTimeInterval(-10 * 86_400),
                endsAt: now.addingTimeInterval(-9 * 86_400)
            )
            let noteID = try await fixture.addNote(deckID: deckID)
            let cardID = try await fixture.addCard(
                noteID: noteID, state: .review,
                dueAt: now.addingTimeInterval(3_600),
                firstStudiedAt: now.addingTimeInterval(-86_400)
            )
            _ = try await fixture.addReviewLog(
                cardKey: cardID, noteID: noteID, deckID: deckID,
                studyDayID: oldStudyDayID, rating: .again,
                reviewedAt: window.startsAt.addingTimeInterval(600)
            )

            let queue = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .answeredWrongToday),
                context: CustomStudyQueueContext(now: now)
            )
            XCTAssertEqual(
                queue, [cardID],
                "应由 learning_time_zone_id 推出 04:00 窗口"
            )
        }
    }

    /// 属性维度：deck（note_decks 成员）/ tag / jlpt / favorite，
    /// 跨字段 AND。
    func testQueueDimensionFilters() async throws {
        try await withRepository { repository, fixture in
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            let deckA = try await fixture.addDeck(name: "A")
            let deckB = try await fixture.addDeck(name: "B")
            let noteA1 = try await fixture.addNote(
                deckID: deckA, favorite: true, jlpt: .n3
            )
            let cardA1 = try await fixture.addCard(
                noteID: noteA1, state: .review, dueAt: now,
                firstStudiedAt: now.addingTimeInterval(-86_400)
            )
            let noteB1 = try await fixture.addNote(deckID: deckB)
            let cardB1 = try await fixture.addCard(
                noteID: noteB1, state: .review, dueAt: now,
                firstStudiedAt: now.addingTimeInterval(-86_400)
            )
            // noteB1 同时是 deckA 成员 → deck 过滤应命中两张卡。
            try await fixture.addMembership(noteID: noteB1, deckID: deckA)
            let tagID = try await fixture.addTag(noteID: noteA1, name: "动词")

            let context = CustomStudyQueueContext(now: now)
            let byDeck = try await repository.buildQueue(
                filter: CustomStudyFilter(deckIDs: [deckA]),
                context: context
            )
            XCTAssertEqual(
                Set(byDeck), Set([cardA1, cardB1]),
                "成员牌组命中共享 Note，且不去重放大行数"
            )
            let byTag = try await repository.buildQueue(
                filter: CustomStudyFilter(tagIDs: [tagID]),
                context: context
            )
            XCTAssertEqual(byTag, [cardA1])
            let byJLPT = try await repository.buildQueue(
                filter: CustomStudyFilter(jlptLevels: [.n3]),
                context: context
            )
            XCTAssertEqual(byJLPT, [cardA1])
            let byFavorite = try await repository.buildQueue(
                filter: CustomStudyFilter(favoriteOnly: true),
                context: context
            )
            XCTAssertEqual(byFavorite, [cardA1])
            // 跨字段 AND：deckA ∧ jlpt=n2 无命中。
            let anded = try await repository.buildQueue(
                filter: CustomStudyFilter(
                    deckIDs: [deckA], jlptLevels: [.n2]
                ),
                context: context
            )
            XCTAssertEqual(anded, [])
        }
    }

    /// 易错卡 preset 复用 Adaptive 分类：lapses ≥ 阈值且无恢复证据 →
    /// leech；停用卡被排除（AdaptiveListFilter.leech 语义）。
    func testQueueLeechPreset() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            let studied = now.addingTimeInterval(-86_400)
            let noteLeech = try await fixture.addNote(deckID: deckID)
            let leech = try await fixture.addCard(
                noteID: noteLeech, state: .review, dueAt: now,
                firstStudiedAt: studied, lapses: 6, stability: 1
            )
            let noteNormal = try await fixture.addNote(deckID: deckID)
            _ = try await fixture.addCard(
                noteID: noteNormal, state: .review, dueAt: now,
                firstStudiedAt: studied, lapses: 0, stability: 1
            )
            let noteSuspended = try await fixture.addNote(deckID: deckID)
            _ = try await fixture.addCard(
                noteID: noteSuspended, state: .review, dueAt: now,
                isEnabled: false,
                firstStudiedAt: studied, lapses: 9, stability: 1
            )

            let queue = try await repository.buildQueue(
                filter: CustomStudyFilter(preset: .leech),
                context: CustomStudyQueueContext(now: now)
            )
            XCTAssertEqual(queue, [leech])
        }
    }

    /// 随机序：同 seed 可复现且是候选集的置换。
    func testQueueRandomSeedDeterministic() async throws {
        try await withRepository { repository, fixture in
            let deckID = try await fixture.addDeck()
            let now = Date(timeIntervalSince1970: 1_768_000_000)
            var all: [UUID] = []
            for offset in 0 ..< 10 {
                let noteID = try await fixture.addNote(deckID: deckID)
                all.append(
                    try await fixture.addCard(
                        noteID: noteID, state: .review,
                        dueAt: now.addingTimeInterval(-Double(offset) * 60),
                        firstStudiedAt: now.addingTimeInterval(-86_400)
                    )
                )
            }
            let filter = CustomStudyFilter(
                limit: 10, order: .random, randomSeed: 42
            )
            let context = CustomStudyQueueContext(now: now)
            let first = try await repository.buildQueue(
                filter: filter, context: context
            )
            let second = try await repository.buildQueue(
                filter: filter, context: context
            )
            XCTAssertEqual(first, second, "同 seed 重放必须一致")
            XCTAssertEqual(Set(first), Set(all))
            let other = try await repository.buildQueue(
                filter: CustomStudyFilter(
                    limit: 10, order: .random, randomSeed: 43
                ),
                context: context
            )
            XCTAssertNotEqual(first, other)
        }
    }

    // MARK: - 工具

    private func withRepository(
        _ body: (GRDBCustomStudyRepository, CustomStudyFixture) async throws -> Void
    ) async throws {
        let fixture = try await CustomStudyFixture.make()
        defer { fixture.remove() }
        try await body(
            GRDBCustomStudyRepository(database: fixture.database),
            fixture
        )
    }

    private func makeSession(
        id: UUID = UUID(),
        mode: CustomStudyMode = .practiceOnly,
        status: CustomStudyStatus = .active,
        startedAt: Date = Date(timeIntervalSince1970: 1_768_000_000),
        finishedAt: Date? = nil
    ) -> CustomStudySession {
        CustomStudySession(
            id: id,
            filter: CustomStudyFilter(),
            mode: mode,
            status: status,
            queue: CustomStudyQueue(
                cardIDs: [],
                order: .due,
                randomSeed: nil,
                generatedAt: startedAt
            ),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private func makeAttempt(
        sessionID: UUID,
        rating: ReviewRating = .good,
        answeredAt: Date = Date(timeIntervalSince1970: 1_768_000_100)
    ) -> PracticeAttempt {
        PracticeAttempt(
            id: UUID(),
            eventID: UUID(),
            sessionID: sessionID,
            cardKey: UUID(),
            noteID: UUID(),
            rating: rating,
            answeredAt: answeredAt,
            durationMilliseconds: 1_500,
            contentVersion: 1
        )
    }

    private func assertRepoError(
        _ expected: CustomStudyRepositoryError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("预期抛出 \(expected)，但调用成功返回", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                expected,
                file: file,
                line: line
            )
        }
    }

    /// 失败的 INSERT 不产生行——闭包抛错即整次写事务回滚，无需
    /// savepoint 包装。
    private func assertConstraintFails(
        _ database: OboeDatabase,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @Sendable (Database) throws -> Void
    ) async throws {
        do {
            try await database.pool.write { db in
                try body(db)
            }
            XCTFail("预期约束失败，但写入成功", file: file, line: line)
        } catch {
            // 约束错误：预期路径。
        }
    }
}

// MARK: - 测试夹具

/// v16 局部 migrator 建库 + 内容夹具。`OboeDatabase(pool:)` 是 internal
/// 初始化器——经 @testable 注入已迁移的 pool，绕过尚未注册 v16 的
/// `OboeDatabase(path:)` 全量迁移入口。
private final class CustomStudyFixture: @unchecked Sendable {
    let directoryURL: URL
    let database: OboeDatabase
    let profileID: UUID
    private var noteSequence = 0

    private init(directoryURL: URL, database: OboeDatabase, profileID: UUID) {
        self.directoryURL = directoryURL
        self.database = database
        self.profileID = profileID
    }

    static func make() async throws -> CustomStudyFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBCustomStudy-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let pool = try OboeDatabase.openPool(path: fileURL.path)
        let migrator = OboeDatabaseSchema.makeMigrator()
        do {
            try migrator.migrate(pool)
        } catch {
            try? pool.close()
            throw error
        }
        let database = OboeDatabase(pool: pool)
        let profileID = UUID()
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json, desired_retention,
                        max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters,
                    profile.targetRetention,
                    profile.maximumIntervalDays
                ]
            )
        }
        return CustomStudyFixture(
            directoryURL: directoryURL,
            database: database,
            profileID: profileID
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func addDeck(name: String = "Deck") async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(id), name]
            )
        }
        return id
    }

    func addNote(
        deckID: UUID,
        favorite: Bool = false,
        jlpt: JLPTLevel? = nil
    ) async throws -> UUID {
        noteSequence += 1
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, jlpt,
                        is_favorite, origin, content_version,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, '含义', ?, ?, 'manual', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID),
                    "词\(noteSequence)",
                    jlpt?.rawValue,
                    favorite,
                    noteSequence,
                    noteSequence
                ]
            )
            try insertHomeMembershipIfSupported(
                noteID: id, deckID: deckID, in: db
            )
        }
        return id
    }

    /// `app_settings.learning_time_zone_id`——学习日窗口回退链末端
    /// 的时区来源。
    func setLearningTimeZone(_ timeZoneID: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id
                    ) VALUES (1, 1, ?)
                    ON CONFLICT(id) DO UPDATE
                        SET learning_time_zone_id = excluded.learning_time_zone_id
                    """,
                arguments: [timeZoneID]
            )
        }
    }

    func addMembership(noteID: UUID, deckID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                    VALUES (?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
        }
    }

    func addTag(noteID: UUID, name: String) async throws -> UUID {
        let tagID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tags(id, name, normalized_name)
                    VALUES (?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(tagID), name,
                    name.lowercased()
                ]
            )
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(tagID)
                ]
            )
        }
        return tagID
    }

    func addCard(
        noteID: UUID,
        template: CardTemplateKind = .vocabularyJapaneseToChinese,
        state: SchedulingState,
        dueAt: Date,
        isEnabled: Bool = true,
        firstStudiedAt: Date? = nil,
        lapses: Int = 0,
        stability: Double = 1,
        difficulty: Double = 5
    ) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, last_review_at_ms, stability, difficulty,
                        reps, lapses, scheduled_days, elapsed_days,
                        learning_step, first_studied_at_ms, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 1, 1, 0, ?, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    isEnabled,
                    state.rawValue,
                    try DatabaseValueCodec.encode(dueAt),
                    try firstStudiedAt.map(DatabaseValueCodec.encode),
                    stability,
                    difficulty,
                    lapses,
                    try firstStudiedAt.map(DatabaseValueCodec.encode),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return id
    }

    /// 便捷夹具：deck + note + card 一条链（origins/review_logs 测试用）。
    func insertCardGraph() async throws -> (
        deckID: UUID, noteID: UUID, cardID: UUID
    ) {
        let deckID = try await addDeck()
        let noteID = try await addNote(deckID: deckID)
        let cardID = try await addCard(
            noteID: noteID,
            state: .review,
            dueAt: Date(timeIntervalSince1970: 1_768_000_000),
            firstStudiedAt: Date(timeIntervalSince1970: 1_767_900_000)
        )
        return (deckID, noteID, cardID)
    }

    func addStudyDay(startsAt: Date, endsAt: Date) async throws -> UUID {
        let id = UUID()
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: startsAt
        )
        let localDate = String(
            format: "%04d-%02d-%02d",
            components.year!, components.month!, components.day!
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id,
                        starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, ?, 'Asia/Shanghai', ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    localDate,
                    try DatabaseValueCodec.encode(startsAt),
                    try DatabaseValueCodec.encode(endsAt)
                ]
            )
        }
        return id
    }

    /// 最小 review_log 行：snapshot JSON 用 '{}'（列 CHECK 只要求
    /// json_valid），仅承载 preset 查询与 origin 外键所需的字段语义。
    func addReviewLog(
        cardKey: UUID,
        noteID: UUID,
        deckID: UUID,
        studyDayID: UUID,
        rating: ReviewRating,
        reviewedAt: Date,
        undoneAt: Date? = nil
    ) async throws -> UUID {
        let logID = UUID()
        let eventID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id,
                        deck_id_at_review, reviewed_at_ms, study_day_id,
                        was_first_study, rating, previous_state_json,
                        next_state_json, duration_ms, content_version,
                        profile_id, algorithm_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, '{}', '{}', 100, 1, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(logID),
                    DatabaseValueCodec.encode(eventID),
                    DatabaseValueCodec.encode(cardKey),
                    DatabaseValueCodec.encode(cardKey),
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    try DatabaseValueCodec.encode(reviewedAt),
                    DatabaseValueCodec.encode(studyDayID),
                    rating.rawValue,
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    try undoneAt.map(DatabaseValueCodec.encode)
                ]
            )
        }
        return eventID
    }
}
