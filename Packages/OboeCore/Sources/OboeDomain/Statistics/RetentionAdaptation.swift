import Foundation

/// v0.7.0 S21：保持率展示适配层（Domain 纯计算件 + 展示模型）。
///
/// 背景：S20 `RetentionStats` 已把「目标/实测/预测」三口径按冻结
/// §11.1 返回，但全部压成单值——S21 UI 需要按 profile 分组的明细
/// 与图表友好的展开模型，本文件承担：
///
/// - `RetentionCurveMath`：锁定 revision `4fbaf20`（`SwiftFSRSReviewScheduler.
///   dependencyRevision`）的 FSRS-6 遗忘曲线的**纯函数重实现**——
///   `R(t,S) = (1 + FACTOR·t/S)^DECAY`，`DECAY = -w[20]`，
///   `FACTOR = 0.9^(1/DECAY) − 1`。与引擎逐步保持 `toFixed(8)`
///   精度截断；Domain 不依赖 FSRS 包（Package.swift 依赖纪律），
///   等价性由 `RetentionInsightTests` 的参考向量 + 引擎对照断言锁死。
/// - `RetentionInsight` / `ProfileRetentionSlice`：三线分离展示模型。
///   new card（state=0 或无复习史）不进任何预测口径；
///   短间隔（同日/小时级）实测样本由 `StatisticsMetricMath.
///   isRetentionSample` 谓词在 SQL 层排除，本模型只承接结果。
/// - `DailyMetricPoint`：评分趋势图的逐学习日序列（7/30/90 切换的
///   数据载体；窗口口径同 S20——按已落库 `study_days` 行取，不补日历）。
///
/// 契约纪律：本文件是 S21 的**增量**类型（不改 `StatisticsContracts.swift`
/// 冻结成员）；口径全部复用 S20 冻结定义，仅做展示层分组/展开。

// MARK: - 锁定 FSRS-6 遗忘曲线（纯函数）

public enum RetentionCurveMath {
    /// S21 锁定的上游依赖 revision（与 `SwiftFSRSReviewScheduler.
    /// dependencyRevision` 同源；不跨模块引用以避免循环依赖——测试断言一致）。
    public static let lockedDependencyRevision =
        "4fbaf20184d62f82a9f44f343337c61a2c5483e9"

    /// v6 参数向量长度；w 不是 21 元的 profile 不产出预测（保守失配）。
    public static let v6ParameterCount = 21

    /// `DECAY = -w[20]`（v6）；参数非 v6 形态返回 nil。
    public static func decay(parameters: [Double]) -> Double? {
        guard parameters.count == v6ParameterCount else { return nil }
        return -parameters[20]
    }

    /// `FACTOR = 0.9^(1/DECAY) − 1`，按引擎 `toFixedNumber(8)` 截断
    /// （`String(format:"%.8f")` round-trip）。
    public static func factor(decay: Double) -> Double {
        Self.toFixed8(exp(log(0.9) / decay) - 1.0)
    }

    /// `R(t,S) = (1 + FACTOR·t/S)^DECAY`，结果 `toFixed(8)`。
    /// `elapsedDays` 取整天数（`elapsedWholeDays`），与引擎
    /// `dateDiff(.days) = floor(Δt/86400)` 语义一致。
    /// stability ≤ 0 或参数非 v6 → nil（该卡不进预测均值）。
    public static func predictedRecall(
        elapsedDays: Double,
        stability: Double,
        parameters: [Double]
    ) -> Double? {
        guard let decay = decay(parameters: parameters),
              stability > 0 else { return nil }
        let f = factor(decay: decay)
        return Self.toFixed8(pow(1 + f * elapsedDays / stability, decay))
    }

    /// `floor(Δt/86400)`——锁定 revision 中 `getRetrievability` 的
    /// 整天数语义；负值（时钟回拨）截断到 0，与引擎 `max(...,0)` 一致。
    public static func elapsedWholeDays(from lastReview: Date, to now: Date) -> Int {
        max(0, Int((now.timeIntervalSince(lastReview) / 86_400).rounded(.down)))
    }

    /// 引擎同款 `toFixedNumber(8)`：`%.8f` 格式化后再解析。
    static func toFixed8(_ value: Double) -> Double {
        Double(String(format: "%.8f", value)) ?? 0
    }
}

// MARK: - 三线分离展示模型

/// 单个 scheduler profile 的保持率切片（图表「按方案分组」的数据行）。
public struct ProfileRetentionSlice: Equatable, Sendable, Identifiable {
    public let profileID: UUID
    /// UI 标签（如 `fsrs-6.0-default-r90-v1`）。
    public let configurationVersion: String
    /// 该 profile 下启用且非 new 的卡数（目标保持率的加权分母）。
    public let cardCount: Int
    /// 其中可预测卡数（有复习史且 stability>0）；
    /// `cardCount - predictableCardCount` = 不参与预测的尾部
    /// （无 `last_review_at` 的 learning/review 卡——new 另有全局计数）。
    public let predictableCardCount: Int
    /// 该 profile 的 `desired_retention`（目标线）。
    public let targetRetention: Double
    /// 该 profile 可预测卡的遗忘曲线均值；无可预测卡为 nil。
    public let predictedRecall: Double?

    public init(
        profileID: UUID,
        configurationVersion: String,
        cardCount: Int,
        predictableCardCount: Int,
        targetRetention: Double,
        predictedRecall: Double?
    ) {
        self.profileID = profileID
        self.configurationVersion = configurationVersion
        self.cardCount = cardCount
        self.predictableCardCount = predictableCardCount
        self.targetRetention = targetRetention
        self.predictedRecall = predictedRecall
    }

    public var id: UUID { profileID }
}

/// 保持率总览：目标（卡数加权 desired_retention）、实测
/// （`isRetentionSample` 口径 30 学习日窗口）、预测（锁定 FSRS-6
/// 遗忘曲线均值）三线分离 + 按 profile 分组的明细。
///
/// `nil` 语义：「无数据」用 nil 表达，绝不伪造 0 或目标值。
public struct RetentionInsight: Equatable, Sendable {
    /// 目标保持率：启用非 new 卡按卡数加权的 `desired_retention`；
    /// 无卡时回退 app_settings preset → standard(0.9)（S20 同源裁决）。
    public let targetRetention: Double
    /// 实测样本数（30 学习日窗口内合格评分数）。
    public let actualSampleCount: Int
    /// 实测保持率 = 非 Again 比例；样本 0 时为 nil。
    public let actualRetention: Double?
    /// 全体可预测卡的遗忘曲线均值（与 S20 `predictedRecall` 同口径：
    /// 逐卡等权，非逐 profile 等权）。
    public let predictedRecall: Double?
    /// 按 profile 分组的明细（启用非 new 卡数 >0 的 profile 才有行）。
    public let profiles: [ProfileRetentionSlice]
    /// 启用非 new 卡总数（Σ profiles.cardCount）。
    public let totalEnabledNonNewCardCount: Int
    /// 启用且 state=new 的卡数——它们天然无预测（供 UI 注释）。
    public let newCardCount: Int

    public init(
        targetRetention: Double,
        actualSampleCount: Int,
        actualRetention: Double?,
        predictedRecall: Double?,
        profiles: [ProfileRetentionSlice],
        totalEnabledNonNewCardCount: Int,
        newCardCount: Int
    ) {
        self.targetRetention = targetRetention
        self.actualSampleCount = actualSampleCount
        self.actualRetention = actualRetention
        self.predictedRecall = predictedRecall
        self.profiles = profiles
        self.totalEnabledNonNewCardCount = totalEnabledNonNewCardCount
        self.newCardCount = newCardCount
    }

    /// 全库可预测卡数（Σ profiles.predictableCardCount）。
    public var predictableCardCount: Int {
        profiles.reduce(0) { $0 + $1.predictableCardCount }
    }
}

/// 逐学习日聚合点：评分趋势图（7/30/90 学习日切换）的数据载体。
/// 零记录学习日保留为全 0 行（与「每日统计」口径一致——不跳过）。
public struct DailyMetricPoint: Equatable, Sendable, Identifiable {
    public let studyDayID: String
    /// "YYYY-MM-DD"（学习日内的本地日历日）。
    public let localDate: String
    /// 有效正式评分数（undo 排除，practice 结构性不进 review_logs）。
    public let effectiveRatingCount: Int
    /// 其中 Hard/Good/Easy 数（自评通过口径）。
    public let passCount: Int
    /// 当日新学 Note 去重数（was_first_study=1 的 distinct note_id）。
    public let newLearnedCount: Int
    /// 有有效时长（>0ms）的评分均时长；无评分日为 nil。
    public let averageDurationMilliseconds: Double?

    public init(
        studyDayID: String,
        localDate: String,
        effectiveRatingCount: Int,
        passCount: Int,
        newLearnedCount: Int,
        averageDurationMilliseconds: Double?
    ) {
        self.studyDayID = studyDayID
        self.localDate = localDate
        self.effectiveRatingCount = effectiveRatingCount
        self.passCount = passCount
        self.newLearnedCount = newLearnedCount
        self.averageDurationMilliseconds = averageDurationMilliseconds
    }

    public var id: String { studyDayID }

    /// 当日成功率；无评分为 nil（不是 0）。
    public var successRate: Double? {
        effectiveRatingCount > 0
            ? Double(passCount) / Double(effectiveRatingCount)
            : nil
    }
}
