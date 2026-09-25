import Foundation

/// Custom Study 会话模式（v0.6.0，设计 §7.2 / D06 冻结 §2.3）。
///
/// - `practiceOnly`（默认）：不调用 FSRS、不写 review_logs、不动
///   firstStudiedAt/新词额度/统计，只写 `practice_attempts`。
/// - `scheduled`（显式开启）：评分走真实 FSRS 提交，经
///   `ReviewSubmissionPolicy.customScheduled(sessionID:)` 事务层校验；
///   首学按 Note 去重计入已用额度。
///
/// 模式在 session 启动时冻结进 `mode` 列，评分过程中不可切换。
public enum CustomStudyMode: String, Codable, CaseIterable, Sendable {
    case practiceOnly
    case scheduled
}

/// `custom_study_sessions.status`：恢复后仍 active 的 session 由恢复
/// 管线/启动规则标为 `interrupted`（不承诺跨设备继续同一 UI）；同进程
/// resize/rotation 不重建 session。
public enum CustomStudyStatus: String, Codable, CaseIterable, Sendable {
    case active
    case finished
    case interrupted
}

/// 内置过滤 preset（需求 §10.2 / 设计 §7.1）。preset 是规则型过滤
/// （依赖 review 历史/调度状态），与属性维度（牌组/标签/JLPT/收藏）
/// 正交，可叠加；`nil` 表示纯属性过滤。
public enum CustomStudyPreset: String, Codable, CaseIterable, Sendable {
    /// 今天答错：当前学习时区 04:00 边界内、未撤销正式 review 的
    /// rating = Again，按 Card 去重。
    case answeredWrongToday
    /// 最近 7 天错 ≥2：当前学习日及前 6 个学习日边界内未撤销 Again
    /// 次数 ≥ 2（按学习日窗口，不是滚动 168 小时）。
    case frequentAgainLast7Days
    /// 易错卡：复用 Adaptive 分类（LeechClassifier），仅有效、未暂停卡。
    case leech
    /// 即将到期：now < dueAt ≤ now + 24h，排除 new。
    case dueSoon
    /// 提前复习：未来到期且非 new，窗口 1–30 天（默认 7），见
    /// `CustomStudyFilter.earlyReviewWindowDays`。
    case earlyReview
    /// 新增未学习：firstStudiedAt = nil 且未禁用。
    case unstudiedNew
}

/// 队列呈现顺序。默认稳定序（due_at_ms 升序 + card id 决胜）；随机
/// 必须固定 seed——同 seed + 同候选集必须完全可复现。
public enum CustomStudyOrder: String, Codable, CaseIterable, Sendable {
    case due
    case random
}

/// Custom Study 过滤条件（设计 §7.1，D 序列冻结 §2.4）。
///
/// 匹配语义：同一字段多选 OR，不同字段 AND；preset 结果集与属性维度
/// 再取交集。预览计数与实际队列必须共用同一编译规则（持久层
/// `buildQueue`/`countQueueCandidates` 同一 WHERE），SQL 参数绑定。
///
/// 支持维度（均落在既有表上，无凭空字段）：
/// - `deckIDs`：`note_decks` 成员关系（多牌组 EXISTS 去重，共享 Note
///   在每个成员牌组下可见）；
/// - `tagIDs`：`note_tags`；
/// - `jlptLevels`：`notes.jlpt`；
/// - `favoriteOnly`：`notes.is_favorite`；
/// - `preset`：见 `CustomStudyPreset`，学习日窗口由
///   `CustomStudyQueueContext` 提供（持久层可回退到 `study_days` 表）。
///
/// 所有 preset 的共同基底：`cards.is_enabled = 1`（删除/停用的卡不进
/// 队列，冻结后缺席由会话内跳过处理，队列不重复扩张）。
public struct CustomStudyFilter: Codable, Equatable, Hashable, Sendable {
    public var preset: CustomStudyPreset?
    public var deckIDs: Set<UUID>
    public var tagIDs: Set<UUID>
    public var jlptLevels: Set<JLPTLevel>
    public var favoriteOnly: Bool
    /// 提前复习窗口天数，仅 `preset == .earlyReview` 时生效。
    public var earlyReviewWindowDays: Int
    /// 候选截断上限：默认 50，最大 500（设计 §7.1）。
    public var limit: Int
    public var order: CustomStudyOrder
    /// `order == .random` 时必填的固定 seed。
    public var randomSeed: Int64?

    public init(
        preset: CustomStudyPreset? = nil,
        deckIDs: Set<UUID> = [],
        tagIDs: Set<UUID> = [],
        jlptLevels: Set<JLPTLevel> = [],
        favoriteOnly: Bool = false,
        earlyReviewWindowDays: Int = CustomStudyService.defaultEarlyReviewWindowDays,
        limit: Int = CustomStudyService.defaultQueueLimit,
        order: CustomStudyOrder = .due,
        randomSeed: Int64? = nil
    ) {
        self.preset = preset
        self.deckIDs = deckIDs
        self.tagIDs = tagIDs
        self.jlptLevels = jlptLevels
        self.favoriteOnly = favoriteOnly
        self.earlyReviewWindowDays = earlyReviewWindowDays
        self.limit = limit
        self.order = order
        self.randomSeed = randomSeed
    }
}

/// 冻结的 cardID 序列（`queue_json`）：session 启动时固定，删除/停用
/// 的卡由会话内跳过，内容更新加载新内容，队列本身不重复扩张。
/// `order`/`randomSeed`/`generatedAt` 是冻结时的出处记录。
public struct CustomStudyQueue: Codable, Equatable, Hashable, Sendable {
    public let cardIDs: [UUID]
    public let order: CustomStudyOrder
    public let randomSeed: Int64?
    public let generatedAt: Date

    public init(
        cardIDs: [UUID],
        order: CustomStudyOrder,
        randomSeed: Int64?,
        generatedAt: Date
    ) {
        self.cardIDs = cardIDs
        self.order = order
        self.randomSeed = randomSeed
        self.generatedAt = generatedAt
    }

    /// 按 `order` 组装冻结序列：`.due` 原样采用传入的稳定序；
    /// `.random` 用固定 seed 做确定性 Fisher–Yates 洗牌（SplitMix64，
    /// 不依赖系统随机源）。`seed` 为 nil 时退化到 0——正式路径由
    /// `CustomStudyService.validate` 强制要求 seed。
    public static func ordered(
        cardIDs: [UUID],
        order: CustomStudyOrder,
        randomSeed: Int64?,
        generatedAt: Date
    ) -> CustomStudyQueue {
        var ids = cardIDs
        if order == .random {
            var generator = CustomStudyRandomSource(seed: randomSeed ?? 0)
            ids.shuffle(using: &generator)
        }
        return CustomStudyQueue(
            cardIDs: ids,
            order: order,
            randomSeed: randomSeed,
            generatedAt: generatedAt
        )
    }
}

/// 固定 seed 的确定性 RNG（SplitMix64）。专项队列的随机序不能走系统
/// 随机源——同 seed + 同候选集在任何一次重放里必须给出同一序列。
public struct CustomStudyRandomSource: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: Int64) {
        state = UInt64(bitPattern: seed)
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// 一个已冻结的 Custom Study 会话（v16 `custom_study_sessions`）。
/// `filter`/`queue` 序列化进 `filter_json`/`queue_json`；`status` 的
/// 合法迁移只有 active → finished / interrupted（见
/// `CustomStudyService` 的 transition 规则与持久层状态守卫）。
public struct CustomStudySession: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let filter: CustomStudyFilter
    public let mode: CustomStudyMode
    public let status: CustomStudyStatus
    public let queue: CustomStudyQueue
    public let startedAt: Date
    public let finishedAt: Date?

    public init(
        id: UUID,
        filter: CustomStudyFilter,
        mode: CustomStudyMode,
        status: CustomStudyStatus,
        queue: CustomStudyQueue,
        startedAt: Date,
        finishedAt: Date?
    ) {
        self.id = id
        self.filter = filter
        self.mode = mode
        self.status = status
        self.queue = queue
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// 状态迁移只在服务层/持久层守卫内发生——不提供公开的可变写入口。
    func setting(status: CustomStudyStatus, finishedAt: Date?) -> CustomStudySession {
        CustomStudySession(
            id: id,
            filter: filter,
            mode: mode,
            status: status,
            queue: queue,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

/// 领域层装配/规则错误。
public enum CustomStudyError: Error, Equatable, Sendable {
    /// `limit` 不在 1 … maximumQueueLimit 内。
    case invalidQueueLimit(Int)
    /// `earlyReview` preset 的窗口天数不在 1…30。
    case invalidEarlyReviewWindow(Int)
    /// `order == .random` 但未提供固定 seed。
    case missingRandomSeed
    /// 冻结队列条数超过 filter.limit（装配错配）。
    case queueExceedsLimit(limit: Int, actual: Int)
    /// 队列的 order/seed 与 filter 不一致（装配错配）。
    case queueFilterMismatch
    /// 对非 active session 做 finish/interrupt 迁移。
    case sessionNotActive(UUID)
}

/// Custom Study 的领域协调器：纯装配与规则，不直接触 DB（与
/// `SubmitReview`/`UndoReview` 同层）。过滤 SQL 的编译在持久层
/// （`CustomStudyRepository.buildQueue`），这里只做参数校验、冻结
/// 装配与状态机规则。
///
/// 「至多一个 active」规则：启动第二个 session 前必须把上一个 active
/// 标为 interrupted。持久层 `createSession` 在同一写事务内执行该
/// 打断（原子保证）；`interruptTransition` 供需要显式两步流程的
/// 调用方（如恢复管线语义对齐）使用。
public struct CustomStudyService: Sendable {
    /// 队列容量：默认 50、最大 500（设计 §7.1）。
    public static let defaultQueueLimit = 50
    public static let maximumQueueLimit = 500
    /// 提前复习窗口：默认 7 天，可选 1–30（设计 §7.1）。
    public static let defaultEarlyReviewWindowDays = 7
    public static let earlyReviewWindowDaysRange = 1 ... 30

    public init() {}

    /// 过滤条件合法性：limit 边界、earlyReview 窗口、随机 seed。
    /// `buildQueue`/预览计数前必须先过这道校验。
    public func validate(_ filter: CustomStudyFilter) throws {
        guard (1 ... Self.maximumQueueLimit).contains(filter.limit) else {
            throw CustomStudyError.invalidQueueLimit(filter.limit)
        }
        if filter.preset == .earlyReview,
           !Self.earlyReviewWindowDaysRange.contains(filter.earlyReviewWindowDays) {
            throw CustomStudyError.invalidEarlyReviewWindow(filter.earlyReviewWindowDays)
        }
        if filter.order == .random, filter.randomSeed == nil {
            throw CustomStudyError.missingRandomSeed
        }
    }

    /// 冻结装配：mode/queue 启动即冻结，产出的 session 以 active 落库。
    /// `queue` 必须来自同一 `filter` 编译的队列生成（order/seed 一致，
    /// 条数 ≤ filter.limit），否则视为装配错配。
    public func makeSession(
        filter: CustomStudyFilter,
        queue: CustomStudyQueue,
        mode: CustomStudyMode,
        now: Date,
        makeID: () -> UUID = UUID.init
    ) throws -> CustomStudySession {
        try validate(filter)
        guard queue.cardIDs.count <= filter.limit else {
            throw CustomStudyError.queueExceedsLimit(
                limit: filter.limit,
                actual: queue.cardIDs.count
            )
        }
        guard queue.order == filter.order, queue.randomSeed == filter.randomSeed else {
            throw CustomStudyError.queueFilterMismatch
        }
        return CustomStudySession(
            id: makeID(),
            filter: filter,
            mode: mode,
            status: .active,
            queue: queue,
            startedAt: now,
            finishedAt: nil
        )
    }

    /// active → interrupted。对非 active session 抛 `sessionNotActive`。
    public func interruptTransition(
        of session: CustomStudySession,
        at now: Date
    ) throws -> CustomStudySession {
        guard session.status == .active else {
            throw CustomStudyError.sessionNotActive(session.id)
        }
        return session.setting(status: .interrupted, finishedAt: now)
    }

    /// active → finished。对非 active session 抛 `sessionNotActive`。
    public func finishTransition(
        of session: CustomStudySession,
        at now: Date
    ) throws -> CustomStudySession {
        guard session.status == .active else {
            throw CustomStudyError.sessionNotActive(session.id)
        }
        return session.setting(status: .finished, finishedAt: now)
    }

    /// scheduled 模式评分走正式提交时的事务层策略（设计 §7.3）；
    /// practiceOnly 返回 nil——practice 提交永远不进 `SubmitReview`/
    /// `commitReview`，只写 `practice_attempts`。
    public func submissionPolicy(
        for session: CustomStudySession
    ) -> ReviewSubmissionPolicy? {
        session.mode == .scheduled ? .customScheduled(sessionID: session.id) : nil
    }
}
