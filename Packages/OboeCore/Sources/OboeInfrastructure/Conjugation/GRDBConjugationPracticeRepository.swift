import Foundation
import GRDB
import OboeDomain

/// S15 `ConjugationPracticeStore` 的 GRDB 实现（`conjugation_sessions`
/// / `conjugation_practice_attempts`，v21 迁移）。
///
/// 隔离红线（技术文档 §12）：本文件只读写上述两表——不调 FSRS、不写
/// review_logs/study_days/daily_tasks，不影响正式 streak/retention。
/// attempt 不持 cardID/noteID；lemma 快照入列使历史题面不被词典/
/// Note 变更抹掉。
///
/// 幂等：`event_id` UNIQUE。同 eventID 重放时逐字段比对语义内容
/// （sessionID/questionID/lemma/reading/class/form/ruleID/prompt/
/// expected/accepted/userInput/normalizedInput/result/matched/duration/
/// answeredAt），一致返回已存行，任一不一致抛
/// `ConjugationPracticeError.conflictingEventID`；`id`/`undoneAt` 不参与
/// 比较（对齐 v16 `practice_attempts` 语义）。
public struct GRDBConjugationPracticeRepository: ConjugationPracticeStore {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - ConjugationPracticeStore

    public func insertSession(
        _ session: ConjugationPracticeSession
    ) async throws {
        try await pool.write { db in
            try Self.insertSession(session, in: db)
        }
    }

    public func updateSessionStatus(
        id: UUID,
        status: ConjugationSessionStatus,
        finishedAt: Date?
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE conjugation_sessions
                    SET status = ?, finished_at_ms = ?
                    WHERE id = ?
                    """,
                arguments: [
                    status.rawValue,
                    try finishedAt.map(DatabaseValueCodec.encode),
                    DatabaseValueCodec.encode(id)
                ])
            if db.changesCount == 0 {
                throw ConjugationPracticeError.sessionNotFound(id)
            }
        }
    }

    @discardableResult
    public func recordAttempt(
        _ attempt: ConjugationPracticeAttempt
    ) async throws -> ConjugationPracticeAttempt {
        try await pool.write { db in
            do {
                try Self.insertAttempt(attempt, in: db)
                return attempt
            } catch let error as DatabaseError
                where error.resultCode == .SQLITE_CONSTRAINT
                      && error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                guard let existing = try Self.fetchAttempt(
                    eventID: attempt.eventID, in: db) else {
                    throw error
                }
                guard Self.semanticMatch(existing, attempt) else {
                    throw ConjugationPracticeError.conflictingEventID(
                        attempt.eventID)
                }
                return existing
            }
        }
    }

    @discardableResult
    public func undoLatestAttempt(
        sessionID: UUID,
        undoneAt: Date
    ) async throws -> ConjugationPracticeAttempt? {
        try await pool.write { db in
            guard let latest = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM conjugation_practice_attempts
                    WHERE session_id = ? AND undone_at_ms IS NULL
                    ORDER BY answered_at_ms DESC, rowid DESC
                    LIMIT 1
                    """,
                arguments: [DatabaseValueCodec.encode(sessionID)]
            ).map({ try Self.decodeAttempt($0) }) else {
                return nil
            }
            try db.execute(
                sql: """
                    UPDATE conjugation_practice_attempts
                    SET undone_at_ms = ?
                    WHERE event_id = ? AND undone_at_ms IS NULL
                    """,
                arguments: [
                    DatabaseValueCodec.encode(undoneAt),
                    DatabaseValueCodec.encode(latest.eventID)
                ])
            guard db.changesCount > 0 else { return nil }
            return ConjugationPracticeAttempt(
                id: latest.id, eventID: latest.eventID,
                sessionID: latest.sessionID, questionID: latest.questionID,
                lemma: latest.lemma, reading: latest.reading,
                conjugationClass: latest.conjugationClass,
                form: latest.form, ruleID: latest.ruleID,
                prompt: latest.prompt,
                expectedPrimary: latest.expectedPrimary,
                acceptedTexts: latest.acceptedTexts,
                userInput: latest.userInput,
                normalizedInput: latest.normalizedInput,
                result: latest.result,
                matchedAnswer: latest.matchedAnswer,
                durationMilliseconds: latest.durationMilliseconds,
                answeredAt: latest.answeredAt, undoneAt: undoneAt)
        }
    }

    public func attempts(
        sessionID: UUID,
        includeUndone: Bool
    ) async throws -> [ConjugationPracticeAttempt] {
        try await pool.read { db in
            let filter = includeUndone ? "" : "AND undone_at_ms IS NULL"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM conjugation_practice_attempts
                    WHERE session_id = ? \(filter)
                    ORDER BY answered_at_ms, rowid
                    """,
                arguments: [DatabaseValueCodec.encode(sessionID)]
            ).map { try Self.decodeAttempt($0) }
        }
    }

    public func session(
        id: UUID
    ) async throws -> ConjugationPracticeSession? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conjugation_sessions WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            ) else { return nil }
            return try Self.decodeSession(row)
        }
    }

    // MARK: - 事务内共享写（供同库其他事务复用，不经 async）

    /// 事务内会话插入（INSERT；重复 id 让约束自然报错）。
    static func insertSession(
        _ session: ConjugationPracticeSession, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO conjugation_sessions(
                    id, planned_question_count, status,
                    started_at_ms, finished_at_ms)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(session.id),
                session.plannedQuestionCount,
                session.status.rawValue,
                DatabaseValueCodec.encode(session.startedAt),
                try session.finishedAt.map(DatabaseValueCodec.encode)
            ])
    }

    /// 事务内 attempt 插入（调用方负责 event_id UNIQUE 冲突语义）。
    static func insertAttempt(
        _ attempt: ConjugationPracticeAttempt, in db: Database
    ) throws {
        let encoder = JSONEncoder()
        let acceptedJSON = String(
            data: try encoder.encode(attempt.acceptedTexts),
            encoding: .utf8)!
        try db.execute(
            sql: """
                INSERT INTO conjugation_practice_attempts(
                    id, event_id, session_id, question_id,
                    lemma, reading, conjugation_class, form, rule_id,
                    prompt, expected_primary, accepted_json,
                    user_input, normalized_input, result, matched_answer,
                    duration_ms, answered_at_ms, undone_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(attempt.id),
                DatabaseValueCodec.encode(attempt.eventID),
                DatabaseValueCodec.encode(attempt.sessionID),
                DatabaseValueCodec.encode(attempt.questionID),
                attempt.lemma,
                attempt.reading,
                attempt.conjugationClass,
                attempt.form,
                attempt.ruleID,
                attempt.prompt,
                attempt.expectedPrimary,
                acceptedJSON,
                attempt.userInput,
                attempt.normalizedInput,
                attempt.result.rawValue,
                attempt.matchedAnswer,
                attempt.durationMilliseconds,
                try DatabaseValueCodec.encode(attempt.answeredAt),
                try attempt.undoneAt.map(DatabaseValueCodec.encode)
            ])
    }

    // MARK: - 解码

    private static func fetchAttempt(
        eventID: UUID, in db: Database
    ) throws -> ConjugationPracticeAttempt? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM conjugation_practice_attempts
                WHERE event_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(eventID)]
        )
        guard let row else { return nil }
        return try decodeAttempt(row)
    }

    private static func decodeSession(_ row: Row) throws -> ConjugationPracticeSession {
        let finishedMs: Int64? = row["finished_at_ms"]
        return ConjugationPracticeSession(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            plannedQuestionCount: row["planned_question_count"],
            status: ConjugationSessionStatus(
                rawValue: row["status"]) ?? .active,
            startedAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["started_at_ms"]),
            finishedAt: finishedMs.map(DatabaseValueCodec.decodeDate))
    }

    private static func decodeAttempt(_ row: Row) throws -> ConjugationPracticeAttempt {
        let acceptedJSON: String = row["accepted_json"]
        let accepted = try JSONDecoder().decode(
            [String].self, from: Data(acceptedJSON.utf8))
        let undoneMs: Int64? = row["undone_at_ms"]
        return ConjugationPracticeAttempt(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            eventID: try DatabaseValueCodec.decodeUUID(row["event_id"]),
            sessionID: try DatabaseValueCodec.decodeUUID(row["session_id"]),
            questionID: try DatabaseValueCodec.decodeUUID(row["question_id"]),
            lemma: row["lemma"],
            reading: row["reading"],
            conjugationClass: row["conjugation_class"],
            form: row["form"],
            ruleID: row["rule_id"],
            prompt: row["prompt"],
            expectedPrimary: row["expected_primary"],
            acceptedTexts: accepted,
            userInput: row["user_input"],
            normalizedInput: row["normalized_input"],
            result: ConjugationAttemptResult(
                rawValue: row["result"]) ?? .incorrect,
            matchedAnswer: row["matched_answer"],
            durationMilliseconds: row["duration_ms"],
            answeredAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["answered_at_ms"]),
            undoneAt: undoneMs.map(DatabaseValueCodec.decodeDate))
    }

    /// 幂等回放语义字段比对（`id`/`undoneAt` 不参与——与 v16
    /// `practice_attempts` 回放判定同款）。
    private static func semanticMatch(
        _ a: ConjugationPracticeAttempt, _ b: ConjugationPracticeAttempt
    ) -> Bool {
        a.eventID == b.eventID
            && a.sessionID == b.sessionID
            && a.questionID == b.questionID
            && a.lemma == b.lemma
            && a.reading == b.reading
            && a.conjugationClass == b.conjugationClass
            && a.form == b.form
            && a.ruleID == b.ruleID
            && a.prompt == b.prompt
            && a.expectedPrimary == b.expectedPrimary
            && a.acceptedTexts == b.acceptedTexts
            && a.userInput == b.userInput
            && a.normalizedInput == b.normalizedInput
            && a.result == b.result
            && a.matchedAnswer == b.matchedAnswer
            && a.durationMilliseconds == b.durationMilliseconds
            && a.answeredAt == b.answeredAt
    }
}
