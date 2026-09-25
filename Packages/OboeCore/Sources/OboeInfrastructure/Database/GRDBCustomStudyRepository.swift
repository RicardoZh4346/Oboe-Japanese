import Foundation
import GRDB
import OboeDomain

/// v16 `custom_study_sessions` / `practice_attempts` /
/// `scheduled_review_origins`（v0.6.0，设计 §7.2，D06/§2.3 冻结）的
/// GRDB 实现。
///
/// - `createSession` 在同一写事务内先把仍 active 的 session 标
///   interrupted（`finished_at` = 新 session 的 `started_at`），再插入
///   ——「至多一个 active」由这条事务路径保证，不留双 active 窗口。
/// - `practice_attempts.event_id` UNIQUE 幂等：重放同内容返回已存行，
///   不同内容抛 `conflictingEventID`；`session_id` 外键失败映射为
///   `sessionNotFound`。`card_key`/`note_id` 故意不加 FK——Card/Note
///   删除后练习历史按 card_key 保留。
/// - `scheduled_review_origins` 的写与 review_log 同事务：集成层在
///   commit 事务内复用 `static …(in db:)` 共享写函数
///   （`insertScheduledOrigin(_:in:)`），与 `GRDBSourceContextRepository`
///   的模式一致。
/// - `session` 删除级联抹掉 attempts/origins；FK 方向是
///   `origins.event_id → review_logs(event_id) RESTRICT`，正式日志
///   不随 session 消失。
/// - 过滤队列：preset 规则 + 属性维度（`note_decks`/`note_tags`/
///   `notes.jlpt`/`notes.is_favorite`）编译成一条参数化 SQL，预览计数
///   与队列共用同一 WHERE；`.leech` 复用 `AdaptiveRepository` +
///   `LeechClassifier`（纯 SQL 无法表达样本窗口分类）。
public struct GRDBCustomStudyRepository: CustomStudyRepository, Sendable {
    private let pool: DatabasePool
    private let adaptiveRepository: any AdaptiveRepository
    private let classifier: LeechClassifier

    public init(
        database: OboeDatabase,
        adaptiveRepository: (any AdaptiveRepository)? = nil,
        adaptivePolicy: AdaptivePolicy = .standard
    ) {
        pool = database.pool
        self.adaptiveRepository = adaptiveRepository
            ?? GRDBAdaptiveRepository(database: database)
        classifier = LeechClassifier(policy: adaptivePolicy)
    }

    // MARK: - v16 schema（主 agent 注册进 makeMigrator；测试经自建 migrator 验证）

    /// `v16_custom_study` 的 DDL（冻结 wire spec §2.3）。
    /// `custom_study_sessions.queue_json`/`filter_json` 有 `json_valid`
    /// CHECK——JSON 序列化是写路径的一部分，不是装饰。
    public static func createCustomStudySchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE custom_study_sessions (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                filter_json TEXT NOT NULL CHECK (json_valid(filter_json)),
                mode TEXT NOT NULL CHECK (mode IN ('practiceOnly','scheduled')),
                status TEXT NOT NULL CHECK (status IN ('active','finished','interrupted')),
                started_at_ms INTEGER NOT NULL,
                finished_at_ms INTEGER,
                queue_json TEXT NOT NULL CHECK (json_valid(queue_json))
            );

            CREATE TABLE practice_attempts (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
                event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
                session_id TEXT NOT NULL
                    REFERENCES custom_study_sessions(id) ON DELETE CASCADE,
                card_key TEXT NOT NULL CHECK (length(card_key) = 36),
                note_id TEXT NOT NULL CHECK (length(note_id) = 36),
                rating INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 4),
                answered_at_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
                content_version INTEGER NOT NULL CHECK (content_version >= 1),
                undone_at_ms INTEGER
            );

            CREATE INDEX practice_attempts_on_session
                ON practice_attempts(session_id, answered_at_ms, id);

            CREATE TABLE scheduled_review_origins (
                event_id TEXT PRIMARY KEY NOT NULL CHECK (length(event_id) = 36)
                    REFERENCES review_logs(event_id) ON DELETE RESTRICT,
                session_id TEXT NOT NULL
                    REFERENCES custom_study_sessions(id) ON DELETE CASCADE,
                submission_kind TEXT NOT NULL
                    CHECK (submission_kind IN ('customScheduled'))
            );
            """)
    }

    // MARK: - 队列生成

    public func buildQueue(
        filter: CustomStudyFilter,
        context: CustomStudyQueueContext
    ) async throws -> [UUID] {
        let adaptiveIDs = try await resolveAdaptiveCardIDs(
            filter: filter,
            at: context.now
        )
        if filter.preset == .leech, adaptiveIDs?.isEmpty == true {
            return []
        }
        return try await pool.read { db in
            let (sql, arguments) = try Self.candidateQuery(
                filter: filter,
                context: context,
                adaptiveCardIDs: adaptiveIDs,
                limited: true,
                in: db
            )
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            var cardIDs = try rows.map { row -> UUID in
                let value: String = row["id"]
                return try DatabaseValueCodec.decodeUUID(value)
            }
            if filter.order == .random {
                var generator = CustomStudyRandomSource(seed: filter.randomSeed ?? 0)
                cardIDs.shuffle(using: &generator)
            }
            return cardIDs
        }
    }

    public func countQueueCandidates(
        filter: CustomStudyFilter,
        context: CustomStudyQueueContext
    ) async throws -> Int {
        let adaptiveIDs = try await resolveAdaptiveCardIDs(
            filter: filter,
            at: context.now
        )
        if filter.preset == .leech, adaptiveIDs?.isEmpty == true {
            return 0
        }
        return try await pool.read { db in
            let (sql, arguments) = try Self.candidateQuery(
                filter: filter,
                context: context,
                adaptiveCardIDs: adaptiveIDs,
                limited: false,
                in: db
            )
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM (\(sql))",
                arguments: arguments
            ) ?? 0
        }
    }

    /// `.leech` preset 的候选集：同一份 Adaptive 证据 + LeechClassifier，
    /// 「仅有效、未暂停卡」沿用 `AdaptiveListFilter.leech` 的判定——专项
    /// 队列与 Adaptive 中心对同一张卡给出同一结论。非 leech preset 返回
    /// nil（不需要候选集）。
    private func resolveAdaptiveCardIDs(
        filter: CustomStudyFilter,
        at now: Date
    ) async throws -> Set<String>? {
        guard filter.preset == .leech else { return nil }
        let snapshot = try await adaptiveRepository.fetchSnapshot(scope: .all)
        var result = Set<String>()
        for record in snapshot.records {
            let assessment = classifier.assess(
                evidence: record.evidence,
                at: now
            )
            if AdaptiveListFilter.leech.matches(
                isEnabled: record.evidence.isEnabled,
                status: assessment.status
            ) {
                result.insert(DatabaseValueCodec.encode(record.evidence.cardID))
            }
        }
        return result
    }

    /// 学习日窗口解析（preset `answeredWrongToday` /
    /// `frequentAgainLast7Days` 需要）：调用方显式给的 context 优先 →
    /// `study_days` 表中含 now 的行 → `app_settings` 学习时区 +
    /// `StudyDayBoundaryCalculator`。都不可得返回 nil（对应 preset
    /// 产出空候选）。
    private static func studyDayWindow(
        context: CustomStudyQueueContext,
        in db: Database
    ) throws -> (startsAtMs: Int64, endsAtMs: Int64)? {
        if let startsAt = context.studyDayStartsAt,
           let endsAt = context.studyDayEndsAt,
           startsAt < endsAt {
            return try (
                DatabaseValueCodec.encode(startsAt),
                DatabaseValueCodec.encode(endsAt)
            )
        }
        let nowMs = try DatabaseValueCodec.encode(context.now)
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT starts_at_ms, ends_at_ms FROM study_days
                WHERE starts_at_ms <= ? AND ? < ends_at_ms
                ORDER BY starts_at_ms DESC
                LIMIT 1
                """,
            arguments: [nowMs, nowMs]
        ) {
            return (row["starts_at_ms"], row["ends_at_ms"])
        }
        guard let timeZoneID = try String.fetchOne(
            db,
            sql: "SELECT learning_time_zone_id FROM app_settings WHERE id = 1"
        ) else {
            return nil
        }
        let day = try StudyDayBoundaryCalculator().studyDay(
            containing: context.now,
            timeZoneID: timeZoneID,
            newCardLimit: 0
        )
        return try (
            DatabaseValueCodec.encode(day.startsAt),
            DatabaseValueCodec.encode(day.endsAt)
        )
    }

    /// 编译过滤 WHERE（预览计数与实际队列共用同一规则——设计 §7.1）。
    /// 基底恒为 `cards.is_enabled = 1`；属性维度（AND）：
    /// `note_decks` 成员 / `note_tags` / `notes.jlpt` /
    /// `notes.is_favorite`；preset 语义见 `CustomStudyPreset`。
    /// 依赖学习日窗口的 preset 在窗口不可得时退化为永假条件（空队列）。
    private static func candidateQuery(
        filter: CustomStudyFilter,
        context: CustomStudyQueueContext,
        adaptiveCardIDs: Set<String>?,
        limited: Bool,
        in db: Database
    ) throws -> (String, StatementArguments) {
        let nowMs = try DatabaseValueCodec.encode(context.now)
        var conditions = ["cards.is_enabled = 1"]
        var values: [any DatabaseValueConvertible] = []

        if filter.favoriteOnly {
            conditions.append("notes.is_favorite = 1")
        }
        if !filter.jlptLevels.isEmpty {
            let placeholders = filter.jlptLevels.map { _ in "?" }
                .joined(separator: ",")
            conditions.append("notes.jlpt IN (\(placeholders))")
            let levels: [any DatabaseValueConvertible] = filter.jlptLevels
                .sorted { $0.rawValue < $1.rawValue }
                .map { $0.rawValue }
            values.append(contentsOf: levels)
        }
        if !filter.deckIDs.isEmpty {
            let placeholders = filter.deckIDs.map { _ in "?" }
                .joined(separator: ",")
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = notes.id
                      AND nd.deck_id IN (\(placeholders))
                )
                """)
            let decks: [any DatabaseValueConvertible] = filter.deckIDs
                .sorted { $0.uuidString < $1.uuidString }
                .map { DatabaseValueCodec.encode($0) }
            values.append(contentsOf: decks)
        }
        if !filter.tagIDs.isEmpty {
            let placeholders = filter.tagIDs.map { _ in "?" }
                .joined(separator: ",")
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM note_tags nt
                    WHERE nt.note_id = notes.id
                      AND nt.tag_id IN (\(placeholders))
                )
                """)
            let tags: [any DatabaseValueConvertible] = filter.tagIDs
                .sorted { $0.uuidString < $1.uuidString }
                .map { DatabaseValueCodec.encode($0) }
            values.append(contentsOf: tags)
        }

        switch filter.preset {
        case .none:
            break
        case .answeredWrongToday, .frequentAgainLast7Days:
            guard let window = try studyDayWindow(context: context, in: db) else {
                conditions.append("0")
                break
            }
            let lowerBound: Int64
            if filter.preset == .frequentAgainLast7Days {
                // 当前学习日及前 6 个学习日边界（不是滚动 168 小时）。
                lowerBound = window.startsAtMs - 6 * 86_400_000
            } else {
                lowerBound = window.startsAtMs
            }
            if filter.preset == .answeredWrongToday {
                // EXISTS 天然按 Card 去重。
                conditions.append("""
                    EXISTS (
                        SELECT 1 FROM review_logs rl
                        WHERE rl.card_key = cards.id
                          AND rl.undone_at_ms IS NULL
                          AND rl.rating = ?
                          AND rl.reviewed_at_ms >= ?
                          AND rl.reviewed_at_ms < ?
                    )
                    """)
            } else {
                conditions.append("""
                    (SELECT COUNT(*) FROM review_logs rl
                     WHERE rl.card_key = cards.id
                       AND rl.undone_at_ms IS NULL
                       AND rl.rating = ?
                       AND rl.reviewed_at_ms >= ?
                       AND rl.reviewed_at_ms < ?) >= 2
                    """)
            }
            let windowArgs: [any DatabaseValueConvertible] = [
                Int64(ReviewRating.again.rawValue),
                lowerBound,
                window.endsAtMs
            ]
            values.append(contentsOf: windowArgs)
        case .dueSoon:
            // now < dueAt ≤ now+24h；排除 new。
            conditions.append(
                "cards.state != ? AND cards.due_at_ms > ? AND cards.due_at_ms <= ?"
            )
            let dueArgs: [any DatabaseValueConvertible] = [
                Int64(SchedulingState.new.rawValue),
                nowMs,
                nowMs + 86_400_000
            ]
            values.append(contentsOf: dueArgs)
        case .earlyReview:
            // 未来到期且非 new；用户窗口 1–30 天（防御性 clamp）。
            let days = min(
                max(filter.earlyReviewWindowDays, 1),
                CustomStudyService.earlyReviewWindowDaysRange.upperBound
            )
            conditions.append(
                "cards.state != ? AND cards.due_at_ms > ? AND cards.due_at_ms <= ?"
            )
            let earlyArgs: [any DatabaseValueConvertible] = [
                Int64(SchedulingState.new.rawValue),
                nowMs,
                nowMs + Int64(days) * 86_400_000
            ]
            values.append(contentsOf: earlyArgs)
        case .unstudiedNew:
            // firstStudiedAt = nil 且未禁用（禁用由基底条件排除）。
            conditions.append("cards.first_studied_at_ms IS NULL")
        case .leech:
            guard let adaptiveCardIDs, !adaptiveCardIDs.isEmpty else {
                conditions.append("0")
                break
            }
            let placeholders = adaptiveCardIDs.map { _ in "?" }
                .joined(separator: ",")
            conditions.append("cards.id IN (\(placeholders))")
            let ids: [any DatabaseValueConvertible] = adaptiveCardIDs.sorted()
            values.append(contentsOf: ids)
        }

        var sql = """
            SELECT cards.id AS id
            FROM cards
            JOIN notes ON notes.id = cards.note_id
            WHERE \(conditions.joined(separator: "\n  AND "))
            """
        if limited {
            // 候选截取恒用稳定序（due_at_ms, id）；.random 只洗牌
            // 已截取的候选集——候选集本身在 seed 变化间保持稳定。
            sql += "\nORDER BY cards.due_at_ms, cards.id\nLIMIT ?"
            values.append(
                min(
                    max(filter.limit, 0),
                    CustomStudyService.maximumQueueLimit
                )
            )
        }
        return (sql, StatementArguments(values))
    }

    // MARK: - 会话

    public func createSession(_ session: CustomStudySession) async throws {
        try await pool.write { db in
            try Self.insertSession(session, in: db)
        }
    }

    public func updateSessionStatus(
        id: UUID,
        to status: CustomStudyStatus,
        finishedAt: Date?
    ) async throws {
        try await pool.write { db in
            try Self.updateSessionStatus(
                id: id,
                to: status,
                finishedAt: finishedAt,
                in: db
            )
        }
    }

    public func fetchSession(id: UUID) async throws -> CustomStudySession? {
        try await pool.read { db in
            try Self.fetchSessionRow(id: id, in: db).map(Self.decodeSession)
        }
    }

    public func fetchActiveSession() async throws -> CustomStudySession? {
        try await pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.sessionColumns) FROM custom_study_sessions
                    WHERE status = 'active'
                    ORDER BY started_at_ms DESC, id DESC
                    LIMIT 1
                    """
            ).map(Self.decodeSession)
        }
    }

    @discardableResult
    public func interruptActiveSessions(at finishedAt: Date) async throws -> Int {
        try await pool.write { db in
            try Self.interruptActiveSessions(at: finishedAt, in: db)
        }
    }

    // MARK: - practice 提交

    @discardableResult
    public func recordPracticeAttempt(
        _ attempt: PracticeAttempt
    ) async throws -> PracticeAttempt {
        try await pool.write { db in
            try Self.insertAttempt(attempt, in: db)
        }
    }

    @discardableResult
    public func undoPracticeAttempt(
        eventID: UUID,
        undoneAt: Date
    ) async throws -> PracticeAttempt {
        try await pool.write { db in
            try Self.undoAttempt(eventID: eventID, undoneAt: undoneAt, in: db)
        }
    }

    public func fetchAttempts(sessionID: UUID) async throws -> [PracticeAttempt] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.attemptColumns) FROM practice_attempts
                    WHERE session_id = ?
                    ORDER BY answered_at_ms, id
                    """,
                arguments: [DatabaseValueCodec.encode(sessionID)]
            ).map(Self.decodeAttempt)
        }
    }

    public func fetchAttempt(eventID: UUID) async throws -> PracticeAttempt? {
        try await pool.read { db in
            try Self.fetchAttemptRow(eventID: eventID, in: db)
                .map(Self.decodeAttempt)
        }
    }

    // MARK: - scheduled 来源登记

    public func recordScheduledOrigin(_ origin: ScheduledReviewOrigin) async throws {
        try await pool.write { db in
            try Self.insertScheduledOrigin(origin, in: db)
        }
    }

    public func fetchScheduledOrigin(
        eventID: UUID
    ) async throws -> ScheduledReviewOrigin? {
        try await pool.read { db in
            try Self.fetchScheduledOriginRow(eventID: eventID, in: db)
                .map(Self.decodeOrigin)
        }
    }

    // MARK: - 共享实现（commit 事务内复用）

    static let sessionColumns = """
        id, filter_json, mode, status, started_at_ms, finished_at_ms, queue_json
        """

    static let attemptColumns = """
        id, event_id, session_id, card_key, note_id, rating,
        answered_at_ms, duration_ms, content_version, undone_at_ms
        """

    /// 原子启动：插入 active session 前，同事务把现存 active 全部
    /// interrupted（finished_at = 新 session 的 started_at）。插入
    /// 非 active 会话不打断——恢复/补录路径可直写历史状态。
    static func insertSession(
        _ session: CustomStudySession,
        in db: Database
    ) throws {
        if session.status == .active {
            try interruptActiveSessions(at: session.startedAt, in: db)
        }
        do {
            try db.execute(
                sql: """
                    INSERT INTO custom_study_sessions(
                        id, filter_json, mode, status,
                        started_at_ms, finished_at_ms, queue_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(session.id),
                    try encodeJSON(session.filter),
                    session.mode.rawValue,
                    session.status.rawValue,
                    DatabaseValueCodec.encode(session.startedAt),
                    try session.finishedAt.map(DatabaseValueCodec.encode),
                    try encodeJSON(session.queue)
                ]
            )
        } catch let error as DatabaseError {
            if error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY {
                throw CustomStudyRepositoryError.sessionAlreadyExists(session.id)
            }
            throw error
        }
    }

    /// 恢复语义：全部仍 active 的 session 标 interrupted。
    @discardableResult
    static func interruptActiveSessions(
        at finishedAt: Date,
        in db: Database
    ) throws -> Int {
        try db.execute(
            sql: """
                UPDATE custom_study_sessions
                SET status = 'interrupted', finished_at_ms = ?
                WHERE status = 'active'
                """,
            arguments: [try DatabaseValueCodec.encode(finishedAt)]
        )
        return db.changesCount
    }

    /// 状态迁移守卫：只允许 active → finished/interrupted。目标 active
    /// （复活）直接拒绝；源行非 active 同样拒绝（迁移机是全序单向的）。
    static func updateSessionStatus(
        id: UUID,
        to status: CustomStudyStatus,
        finishedAt: Date?,
        in db: Database
    ) throws {
        guard status != .active else {
            throw CustomStudyRepositoryError.invalidStatusTransition
        }
        guard let row = try fetchSessionRow(id: id, in: db) else {
            throw CustomStudyRepositoryError.sessionNotFound(id)
        }
        let currentStatus: String = row["status"]
        guard currentStatus == CustomStudyStatus.active.rawValue else {
            throw CustomStudyRepositoryError.invalidStatusTransition
        }
        try db.execute(
            sql: """
                UPDATE custom_study_sessions
                SET status = ?, finished_at_ms = ?
                WHERE id = ? AND status = 'active'
                """,
            arguments: [
                status.rawValue,
                try finishedAt.map(DatabaseValueCodec.encode),
                DatabaseValueCodec.encode(id)
            ]
        )
        guard db.changesCount == 1 else {
            throw CustomStudyRepositoryError.invalidStatusTransition
        }
    }

    /// eventID 幂等写入：已存在时按语义载荷比较（sessionID/cardKey/
    /// noteID/rating/answeredAt/durationMs/contentVersion——`id` 与
    /// `undoneAt` 不参与，重放拿到的是已存行的完整现状）；不一致抛
    /// `conflictingEventID`。
    @discardableResult
    static func insertAttempt(
        _ attempt: PracticeAttempt,
        in db: Database
    ) throws -> PracticeAttempt {
        if let existingRow = try fetchAttemptRow(eventID: attempt.eventID, in: db) {
            let stored = try decodeAttempt(existingRow)
            guard stored.sessionID == attempt.sessionID,
                  stored.cardKey == attempt.cardKey,
                  stored.noteID == attempt.noteID,
                  stored.rating == attempt.rating,
                  stored.answeredAt == attempt.answeredAt,
                  stored.durationMilliseconds == attempt.durationMilliseconds,
                  stored.contentVersion == attempt.contentVersion else {
                throw CustomStudyRepositoryError.conflictingEventID(attempt.eventID)
            }
            return stored
        }
        do {
            try db.execute(
                sql: """
                    INSERT INTO practice_attempts(
                        id, event_id, session_id, card_key, note_id, rating,
                        answered_at_ms, duration_ms, content_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(attempt.id),
                    DatabaseValueCodec.encode(attempt.eventID),
                    DatabaseValueCodec.encode(attempt.sessionID),
                    DatabaseValueCodec.encode(attempt.cardKey),
                    DatabaseValueCodec.encode(attempt.noteID),
                    attempt.rating.rawValue,
                    DatabaseValueCodec.encode(attempt.answeredAt),
                    attempt.durationMilliseconds,
                    attempt.contentVersion
                ]
            )
        } catch let error as DatabaseError {
            switch error.extendedResultCode {
            case .SQLITE_CONSTRAINT_FOREIGNKEY:
                throw CustomStudyRepositoryError.sessionNotFound(attempt.sessionID)
            case .SQLITE_CONSTRAINT_UNIQUE:
                // 并发同 eventID 写入的兜底：读回已存行按同一幂等规则裁决。
                if let raced = try fetchAttemptRow(eventID: attempt.eventID, in: db) {
                    let stored = try decodeAttempt(raced)
                    guard stored.sessionID == attempt.sessionID,
                          stored.cardKey == attempt.cardKey,
                          stored.noteID == attempt.noteID,
                          stored.rating == attempt.rating,
                          stored.answeredAt == attempt.answeredAt,
                          stored.durationMilliseconds == attempt.durationMilliseconds,
                          stored.contentVersion == attempt.contentVersion else {
                        throw CustomStudyRepositoryError.conflictingEventID(
                            attempt.eventID
                        )
                    }
                    return stored
                }
                throw error
            default:
                throw error
            }
        }
        return attempt
    }

    /// 撤销只置 `undone_at_ms`——不触碰 FSRS/cards/review_logs（D06）。
    @discardableResult
    static func undoAttempt(
        eventID: UUID,
        undoneAt: Date,
        in db: Database
    ) throws -> PracticeAttempt {
        guard let row = try fetchAttemptRow(eventID: eventID, in: db) else {
            throw CustomStudyRepositoryError.attemptNotFound(eventID)
        }
        let attempt = try decodeAttempt(row)
        guard attempt.undoneAt == nil else {
            throw CustomStudyRepositoryError.attemptAlreadyUndone(eventID)
        }
        try db.execute(
            sql: """
                UPDATE practice_attempts SET undone_at_ms = ?
                WHERE event_id = ? AND undone_at_ms IS NULL
                """,
            arguments: [
                DatabaseValueCodec.encode(undoneAt),
                DatabaseValueCodec.encode(eventID)
            ]
        )
        guard db.changesCount == 1,
              let updated = try fetchAttemptRow(eventID: eventID, in: db) else {
            throw CustomStudyRepositoryError.attemptAlreadyUndone(eventID)
        }
        return try decodeAttempt(updated)
    }

    /// scheduled 评分落 `review_logs` 后的同事务来源登记（设计 §7.3：
    /// 「正式提交、review_logs、origin、session 进度同事务」）。先按
    /// eventID 幂等查回；再显式校验两端 FK 目标存在——把外键失败映射
    /// 成领域错误而不是裸 SQLite 报错。
    static func insertScheduledOrigin(
        _ origin: ScheduledReviewOrigin,
        in db: Database
    ) throws {
        let eventIDValue = DatabaseValueCodec.encode(origin.eventID)
        if let existing = try fetchScheduledOriginRow(
            eventID: origin.eventID,
            in: db
        ) {
            let storedSession: String = existing["session_id"]
            let storedKind: String = existing["submission_kind"]
            guard try DatabaseValueCodec.decodeUUID(storedSession) == origin.sessionID,
                  storedKind == origin.submissionKind.rawValue else {
                throw CustomStudyRepositoryError.conflictingEventID(origin.eventID)
            }
            return
        }
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM review_logs WHERE event_id = ?)",
            arguments: [eventIDValue]
        ) == true else {
            throw CustomStudyRepositoryError.missingReviewLog(origin.eventID)
        }
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM custom_study_sessions WHERE id = ?)",
            arguments: [DatabaseValueCodec.encode(origin.sessionID)]
        ) == true else {
            throw CustomStudyRepositoryError.sessionNotFound(origin.sessionID)
        }
        try db.execute(
            sql: """
                INSERT INTO scheduled_review_origins(
                    event_id, session_id, submission_kind
                ) VALUES (?, ?, ?)
                """,
            arguments: [
                eventIDValue,
                DatabaseValueCodec.encode(origin.sessionID),
                origin.submissionKind.rawValue
            ]
        )
    }

    /// `.customScheduled` 提交的事务层资格校验（设计 §7.3）：session
    /// 必须存在、mode = scheduled、status = active、card 属于启动时
    /// 冻结的队列。UI 传任意 policy 绕不过这里的 queue_json 成员检查。
    static func requireScheduledSubmissionTarget(
        sessionID: UUID,
        cardID: UUID,
        in db: Database
    ) throws {
        guard let row = try fetchSessionRow(id: sessionID, in: db) else {
            throw CustomStudyRepositoryError.sessionNotFound(sessionID)
        }
        let modeValue: String = row["mode"]
        let statusValue: String = row["status"]
        guard modeValue == CustomStudyMode.scheduled.rawValue,
              statusValue == CustomStudyStatus.active.rawValue else {
            throw CustomStudyRepositoryError
                .sessionNotEligibleForScheduledSubmission(sessionID)
        }
        let queueJSON: String = row["queue_json"]
        guard let queue = try? jsonDecoder.decode(
            CustomStudyQueue.self,
            from: Data(queueJSON.utf8)
        ) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(
                field: "queue_json"
            )
        }
        guard queue.cardIDs.contains(cardID) else {
            throw CustomStudyRepositoryError.cardNotInSessionQueue(
                cardID: cardID,
                sessionID: sessionID
            )
        }
    }

    static func fetchSessionRow(id: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(sessionColumns) FROM custom_study_sessions WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(id)]
        )
    }

    static func fetchAttemptRow(eventID: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(attemptColumns) FROM practice_attempts WHERE event_id = ?",
            arguments: [DatabaseValueCodec.encode(eventID)]
        )
    }

    static func fetchScheduledOriginRow(
        eventID: UUID,
        in db: Database
    ) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT event_id, session_id, submission_kind
                FROM scheduled_review_origins
                WHERE event_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(eventID)]
        )
    }

    static func decodeSession(_ row: Row) throws -> CustomStudySession {
        let idValue: String = row["id"]
        let filterJSON: String = row["filter_json"]
        let queueJSON: String = row["queue_json"]
        let modeValue: String = row["mode"]
        let statusValue: String = row["status"]
        let startedAtMs: Int64 = row["started_at_ms"]
        let finishedAtMs: Int64? = row["finished_at_ms"]
        guard let filter = try? jsonDecoder.decode(
            CustomStudyFilter.self,
            from: Data(filterJSON.utf8)
        ) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(
                field: "filter_json"
            )
        }
        guard let queue = try? jsonDecoder.decode(
            CustomStudyQueue.self,
            from: Data(queueJSON.utf8)
        ) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(
                field: "queue_json"
            )
        }
        guard let mode = CustomStudyMode(rawValue: modeValue) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(field: "mode")
        }
        guard let status = CustomStudyStatus(rawValue: statusValue) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(field: "status")
        }
        return CustomStudySession(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            filter: filter,
            mode: mode,
            status: status,
            queue: queue,
            startedAt: DatabaseValueCodec.decodeDate(milliseconds: startedAtMs),
            finishedAt: finishedAtMs.map(DatabaseValueCodec.decodeDate)
        )
    }

    static func decodeAttempt(_ row: Row) throws -> PracticeAttempt {
        let idValue: String = row["id"]
        let eventIDValue: String = row["event_id"]
        let sessionIDValue: String = row["session_id"]
        let cardKeyValue: String = row["card_key"]
        let noteIDValue: String = row["note_id"]
        let ratingValue: Int = row["rating"]
        let answeredAtMs: Int64 = row["answered_at_ms"]
        let durationMs: Int64 = row["duration_ms"]
        let contentVersion: Int = row["content_version"]
        let undoneAtMs: Int64? = row["undone_at_ms"]
        guard let rating = ReviewRating(rawValue: ratingValue) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(
                field: "rating"
            )
        }
        return try PracticeAttempt(
            id: DatabaseValueCodec.decodeUUID(idValue),
            eventID: DatabaseValueCodec.decodeUUID(eventIDValue),
            sessionID: DatabaseValueCodec.decodeUUID(sessionIDValue),
            cardKey: DatabaseValueCodec.decodeUUID(cardKeyValue),
            noteID: DatabaseValueCodec.decodeUUID(noteIDValue),
            rating: rating,
            answeredAt: DatabaseValueCodec.decodeDate(milliseconds: answeredAtMs),
            durationMilliseconds: Int(durationMs),
            contentVersion: contentVersion,
            undoneAt: undoneAtMs.map(DatabaseValueCodec.decodeDate)
        )
    }

    static func decodeOrigin(_ row: Row) throws -> ScheduledReviewOrigin {
        let eventIDValue: String = row["event_id"]
        let sessionIDValue: String = row["session_id"]
        let kindValue: String = row["submission_kind"]
        guard let kind = ScheduledReviewSubmissionKind(rawValue: kindValue) else {
            throw CustomStudyRepositoryError.invalidPersistedValue(
                field: "submission_kind"
            )
        }
        return try ScheduledReviewOrigin(
            eventID: DatabaseValueCodec.decodeUUID(eventIDValue),
            sessionID: DatabaseValueCodec.decodeUUID(sessionIDValue),
            submissionKind: kind
        )
    }

    /// 排序键确定性：filter_json/queue_json 落库字节稳定（Equatable
    /// 断言与备份 round-trip 比较都受益）。
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let jsonDecoder = JSONDecoder()

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try jsonEncoder.encode(value), as: UTF8.self)
    }
}
