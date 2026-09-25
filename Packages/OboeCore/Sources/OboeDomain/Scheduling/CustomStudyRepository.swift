import Foundation

/// `buildQueue`/`countQueueCandidates` 的运行期上下文。
///
/// `studyDayStartsAt`/`studyDayEndsAt` 是「当前学习日」的半开窗口
/// [startsAt, endsAt)——学习时区 04:00 边界，由调用方用
/// `StudyDayBoundaryCalculator` + `learning_time_zone_id` 算出。
/// `answeredWrongToday`/`frequentAgainLast7Days` 两个 preset 需要它；
/// 调用方未提供时持久层按序回退：`study_days` 表中含 now 的行 →
/// `app_settings.learning_time_zone_id` + 边界计算器；都不可得则
/// 这两个 preset 产出空候选（详见 GRDB 实现注释）。
public struct CustomStudyQueueContext: Equatable, Sendable {
    public let now: Date
    public let studyDayStartsAt: Date?
    public let studyDayEndsAt: Date?

    public init(
        now: Date,
        studyDayStartsAt: Date? = nil,
        studyDayEndsAt: Date? = nil
    ) {
        self.now = now
        self.studyDayStartsAt = studyDayStartsAt
        self.studyDayEndsAt = studyDayEndsAt
    }
}

/// Custom Study 持久层契约（v16 三表：custom_study_sessions /
/// practice_attempts / scheduled_review_origins；设计 §7.2–7.3）。
///
/// 写语义冻结点：
/// - `createSession` 在同一写事务内先把仍 active 的其它 session 标
///   interrupted（`finished_at` = 新 session 的 started_at），再插入
///   ——「至多一个 active」由此原子保证。
/// - `recordPracticeAttempt` 按 eventID 幂等：同 eventID 同内容返回
///   已存行，同 eventID 不同内容抛 `conflictingEventID`。
/// - `undoPracticeAttempt` 只置 `undone_at_ms`——不改 FSRS、不碰
///   review_logs/daily_tasks。
/// - `recordScheduledOrigin` 登记 scheduled 评分的正式来源；与
///   review_log 同事务由集成层走 GRDB static in-db 写函数完成。
/// - session 删除级联抹掉 attempts/origins，但**不得**波及正式
///   review_logs（FK 方向是 origin → review_logs RESTRICT）。
public protocol CustomStudyRepository: Sendable {
    // MARK: - 队列生成（过滤 SQL 在持久层编译）

    /// 按 `filter` 编译并执行候选查询，返回冻结顺序的 cardID 序列：
    /// 先按稳定序（due_at_ms, id）截取 `limit` 个候选；`order == .random`
    /// 时用 `randomSeed` 对候选集做确定性洗牌（候选集不变，只换呈现序）。
    /// 调用前应先过 `CustomStudyService.validate`；实现侧对 limit 做
    /// 防御性 clamp 到 [0, 500]。
    func buildQueue(
        filter: CustomStudyFilter,
        context: CustomStudyQueueContext
    ) async throws -> [UUID]

    /// 预览计数：与 `buildQueue` 完全相同的 WHERE 编译，不排序不截断。
    func countQueueCandidates(
        filter: CustomStudyFilter,
        context: CustomStudyQueueContext
    ) async throws -> Int

    // MARK: - 会话

    /// 原子启动语义：同一事务内打断现存 active（status → interrupted，
    /// finished_at = session.startedAt）再插入；插入非 active 会话
    /// （如恢复/补录）时不做打断。`id` 已存在抛 `sessionAlreadyExists`。
    func createSession(_ session: CustomStudySession) async throws

    /// 状态迁移落库：只允许 active → finished/interrupted；目标为
    /// `active`（复活）或源行非 active 时抛 `invalidStatusTransition`，
    /// 行不存在抛 `sessionNotFound`。
    func updateSessionStatus(
        id: UUID,
        to status: CustomStudyStatus,
        finishedAt: Date?
    ) async throws

    func fetchSession(id: UUID) async throws -> CustomStudySession?

    /// 当前唯一 active session；不变量被破坏时取最近启动者（防御性
    /// 兜底，正常路径至多一行）。
    func fetchActiveSession() async throws -> CustomStudySession?

    /// 恢复语义（备份恢复/冷启动对齐）：把全部仍 active 的 session
    /// 标为 interrupted，返回受影响行数。
    @discardableResult
    func interruptActiveSessions(at finishedAt: Date) async throws -> Int

    // MARK: - practice 提交（不动 FSRS/review_logs）

    /// 幂等写入：同 eventID 同内容 → 返回已存行；同 eventID 不同内容 →
    /// `conflictingEventID`；session_id 外键失败 → `sessionNotFound`。
    @discardableResult
    func recordPracticeAttempt(_ attempt: PracticeAttempt) async throws -> PracticeAttempt

    /// 撤销：仅置 `undone_at_ms`。不存在 → `attemptNotFound`；
    /// 已撤销 → `attemptAlreadyUndone`。返回撤销后的行。
    @discardableResult
    func undoPracticeAttempt(
        eventID: UUID,
        undoneAt: Date
    ) async throws -> PracticeAttempt

    /// 会话内全部 attempt（含已撤销），按 (answered_at_ms, id) 升序——
    /// 与 `practice_attempts_on_session` 索引同序。
    func fetchAttempts(sessionID: UUID) async throws -> [PracticeAttempt]

    func fetchAttempt(eventID: UUID) async throws -> PracticeAttempt?

    // MARK: - scheduled 来源登记

    /// 登记一次正式提交的来源（review_logs.event_id → session）。
    /// event_id 对应的 review_log 不存在 → `missingReviewLog`；
    /// session 不存在 → `sessionNotFound`；同 eventID 重复登记同内容
    /// 幂等成功，不同内容 → `conflictingEventID`。
    func recordScheduledOrigin(_ origin: ScheduledReviewOrigin) async throws

    func fetchScheduledOrigin(eventID: UUID) async throws -> ScheduledReviewOrigin?
}

/// 持久层失败语义（与 `SourceContextRepositoryError` 同模式：领域
/// 错误只覆盖冻结的写入冲突，运行期查询/解码失败归这里）。
public enum CustomStudyRepositoryError: Error, Equatable, Sendable {
    /// `createSession` 的 id 已存在。
    case sessionAlreadyExists(UUID)
    /// 会话不存在（含 practice_attempts.session_id / origins.session_id
    /// 外键失败的映射）。
    case sessionNotFound(UUID)
    /// `updateSessionStatus` 非法迁移：目标是 active（复活）或源行
    /// 已不是 active。
    case invalidStatusTransition
    /// 同 eventID 但内容不同的重放/登记冲突（attempt 与 origin 共用）。
    case conflictingEventID(UUID)
    case attemptNotFound(UUID)
    case attemptAlreadyUndone(UUID)
    /// `scheduled_review_origins.event_id` 指向的 review_log 不存在。
    case missingReviewLog(UUID)
    /// 已持久化字段无法解码（filter_json/queue_json/mode/status 落库值
    /// 非法）——数据损坏信号，不静默吞掉。
    case invalidPersistedValue(field: String)
    /// `.customScheduled` 提交的 session 存在但不合格：mode 不是
    /// `scheduled` 或 status 已不是 `active`（设计 §7.3）。
    case sessionNotEligibleForScheduledSubmission(UUID)
    /// 提交的 card 不在该 session 启动时冻结的队列里（设计 §7.3：
    /// 队列成员以 queue_json 为准，UI 不能传任意 allowEarly 绕过）。
    case cardNotInSessionQueue(cardID: UUID, sessionID: UUID)
}
