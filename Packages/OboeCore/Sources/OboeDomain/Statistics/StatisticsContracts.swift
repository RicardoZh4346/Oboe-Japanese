import Foundation

/// v0.7.0 S02 冻结契约：Statistics 2.0 只读查询层 + Reader 活动事件。
/// 依据：详细技术实现文档 §11（口径表、Reader 历史、索引/缓存纪律）。
/// 冻结项：各指标的冻结口径（不得换分母）、practiceOnly 隔离、
/// undo 排除、学习日 04:00 边界沿用现有规则。
///
/// 纪律：统计层只读——不写伪 ReviewLog；任何口径变更升级
/// metric version，不静默换分母。

// MARK: - 查询结果类型（§11.1 冻结口径）

/// 今日复习：有效评分次数 + 非首学去重 Card 数。
/// `undone_at_ms IS NULL` 之外，practiceOnly 事件一律排除。
public struct TodayReviewStats: Equatable, Sendable {
    /// 有效正式评分次数。
    public let effectiveRatingCount: Int
    /// 去重 Card 数（同一卡多次评分计 1；首学不计入）。
    public let distinctCardCount: Int

    public init(effectiveRatingCount: Int, distinctCardCount: Int) {
        self.effectiveRatingCount = effectiveRatingCount
        self.distinctCardCount = distinctCardCount
    }
}

/// 当日新学：有效首次学习 Note 去重，细分 kind；
/// 已删卡日志仍按历史 noteID 计。
public struct NewLearnedStats: Equatable, Sendable {
    public let vocabulary: Int
    public let grammar: Int
    public let sentence: Int

    public init(vocabulary: Int, grammar: Int, sentence: Int) {
        self.vocabulary = vocabulary
        self.grammar = grammar
        self.sentence = sentence
    }

    public var total: Int { vocabulary + grammar + sentence }
}

/// 评分成功率：(Hard+Good+Easy)/全部有效正式评分。
/// 标注「自评」——不是机器判题正确率。
public struct SuccessRateStats: Equatable, Sendable {
    public let ratedCount: Int
    public let passCount: Int

    public init(ratedCount: Int, passCount: Int) {
        self.ratedCount = ratedCount
        self.passCount = passCount
    }

    public var rate: Double? {
        ratedCount > 0 ? Double(passCount) / Double(ratedCount) : nil
    }
}

/// 平均作答时长：Σduration_ms / 有有效时长的正式评分数。
/// 输入时间与总评分时间不混称。
public struct DurationStats: Equatable, Sendable {
    public let totalMilliseconds: Int64
    public let ratedWithDurationCount: Int

    public init(totalMilliseconds: Int64, ratedWithDurationCount: Int) {
        self.totalMilliseconds = totalMilliseconds
        self.ratedWithDurationCount = ratedWithDurationCount
    }
}

/// 保持率三口径分离（D09）：
/// target = scheduler profile.desired_retention（多 profile 分组）；
/// actual = 过去 30 学习日、评分前 state=review 且距上次正式评分
///   ≥1 日的有效正式事件中非 Again 比例——小样本显示 N，不伪装置信度；
/// predicted = 锁定 FSRS-6 公式按当前时间计算——无历史则无值。
public struct RetentionStats: Equatable, Sendable {
    public let targetRetention: Double
    public let actualSampleCount: Int
    public let actualRetention: Double?
    public let predictedRecall: Double?

    public init(
        targetRetention: Double,
        actualSampleCount: Int,
        actualRetention: Double?,
        predictedRecall: Double?
    ) {
        self.targetRetention = targetRetention
        self.actualSampleCount = actualSampleCount
        self.actualRetention = actualRetention
        self.predictedRecall = predictedRecall
    }
}

/// Card 成熟度口径：非 new、启用、state=review 且
/// scheduledDays ≥21 → mature（产品阈值，非 FSRS 官方状态）；
/// state=learning/relearning → learning；review <21 天 → young。
public struct CardMaturityStats: Equatable, Sendable {
    public static let matureScheduledDaysThreshold = 21

    public let mature: Int
    public let youngReview: Int
    public let learning: Int
    /// 暂停与 new 单列，不用零值拉低均值。
    public let suspended: Int
    public let newCards: Int

    public init(mature: Int, youngReview: Int, learning: Int, suspended: Int, newCards: Int) {
        self.mature = mature
        self.youngReview = youngReview
        self.learning = learning
        self.suspended = suspended
        self.newCards = newCards
    }
}

/// Forecast：现有启用、非 new Card 的 dueAt 未来 7/30 学习日分桶；
/// 过期单列；共享牌组去重。图注：「按当前到期时间估计」。
public struct ForecastStats: Equatable, Sendable {
    /// dayOffset(0..6)→dueCount。
    public let next7Days: [Int]
    /// dayOffset(0..29)→dueCount。
    public let next30Days: [Int]
    public let overdue: Int

    public init(next7Days: [Int], next30Days: [Int], overdue: Int) {
        self.next7Days = next7Days
        self.next30Days = next30Days
        self.overdue = overdue
    }
}

/// Weakness：30 日 Again 排行；样本 <3 不进榜；Leech 复用现有分类。
public struct WeaknessEntry: Equatable, Sendable {
    public static let minimumSampleCount = 3

    public let noteID: UUID
    public let headword: String
    public let againCount30d: Int
    public let totalReviews30d: Int

    public init(noteID: UUID, headword: String, againCount30d: Int, totalReviews30d: Int) {
        self.noteID = noteID
        self.headword = headword
        self.againCount30d = againCount30d
        self.totalReviews30d = totalReviews30d
    }

    public var failureRate: Double {
        totalReviews30d > 0 ? Double(againCount30d) / Double(totalReviews30d) : 0
    }
}

/// 只读统计边界（§11）。实现端 SQL 按 study_day/card_key 聚合，
/// 成员筛选用 EXISTS；缓存绑定 generation + 写入修订号。
public protocol StatisticsRepository: Sendable {
    func todayReviewStats(studyDayID: String) async throws -> TodayReviewStats
    func newLearnedStats(studyDayID: String) async throws -> NewLearnedStats
    func successRate(fromStudyDayID: String, toStudyDayID: String) async throws -> SuccessRateStats
    func averageDuration(studyDayID: String) async throws -> DurationStats
    func retentionStats(asOf date: Date) async throws -> RetentionStats
    func cardMaturity() async throws -> CardMaturityStats
    func forecast(fromStudyDayID: String) async throws -> ForecastStats
    func weakness(limit: Int) async throws -> [WeaknessEntry]
}

// MARK: - Reader 活动事件（§11.2）

/// reader_activity_events.kind 的封闭集合。
/// 事件与真实业务动作同事务写入；重复点击返回同 receipt。
public enum ReaderActivityKind: String, Codable, Sendable {
    /// 新建词汇 Note（区别于给已有词追加来源）。
    case minedNewNote
    case linkedExistingNote
    case createdCloze
    case markedKnown
    case resetKnowledge
}

/// 历史事实记录：卡/原文删除不抹掉历史；弱引用 + 必要快照。
public struct ReaderActivityEvent: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 操作幂等键——同一 operationID 重放返回同 receipt 不新增事件。
    public let operationID: UUID
    public let kind: ReaderActivityKind
    /// 弱引用目标（可为 nil——目标删除后事件仍成立）。
    public let lexemeID: UUID?
    public let noteID: UUID?
    public let documentID: UUID?
    /// 必要快照（标题/表记等），限额沿用领域层。
    public let snapshotJSON: String?
    public let createdAt: Date
    /// 撤销时间；undo 后统计排除。
    public let undoneAt: Date?

    public init(
        id: UUID,
        operationID: UUID,
        kind: ReaderActivityKind,
        lexemeID: UUID?,
        noteID: UUID?,
        documentID: UUID?,
        snapshotJSON: String?,
        createdAt: Date,
        undoneAt: Date?
    ) {
        self.id = id
        self.operationID = operationID
        self.kind = kind
        self.lexemeID = lexemeID
        self.noteID = noteID
        self.documentID = documentID
        self.snapshotJSON = snapshotJSON
        self.createdAt = createdAt
        self.undoneAt = undoneAt
    }
}
