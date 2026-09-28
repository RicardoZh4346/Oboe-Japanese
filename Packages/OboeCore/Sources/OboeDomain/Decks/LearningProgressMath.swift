import Foundation

/// v0.7.5 S14（角色 C 纯函数部分）：「Oboe 学习进度」纯函数。
/// 依据：contracts-frozen §5.1、技术文档 §13.1、decisions D08/D13。
///
/// 口径要点（冻结）：
/// - active = enabled 的 vocabulary 三方向卡；Cloze/Grammar 卡
///   不参与本指标（由调用方过滤后传入）。
/// - legacy secondary Note 的启用词汇卡同样参与该 unit 的方向
///   平均；unit 在 deck 只占一票（DISTINCT unitID）。
/// - 这是基于 stability 的自定义估计，不是 FSRS 官方掌握率；
///   可随新卡、暂停、删除、评分下降，不承诺单调增长。
///   `learning` 也可能 progress = 100%——仅显式 tooEasy 才是
///   mastered。
///
/// 本文件只有纯函数与值类型：不依赖 SQLite 数学函数（批量投影
/// 读出原始 stability 后在此算 log，§13.2）。
public enum LearningProgressMath {
    /// log1p 归一目标稳定度天数（首版固定策略值，contracts §5.1）。
    public static let targetStabilityDays: Double = 30

    /// 单张卡进度：
    /// `0`（未学习/无 stability）|
    /// `clamp(log1p(max(0, stabilityDays)) / log1p(targetStabilityDays), 0, 1)`
    ///
    /// - `stabilityDays` 为 NaN/±inf → `isDataAnomalous = true`、
    ///   `value = 0`——数据异常待修复，绝不把 NaN 传播至 UI（D13）；
    ///   负值是有限数，按 `max(0,·)` 归零，不算异常。
    /// - `enabled == false` → `countsTowardUnitMean = false`：
    ///   停用卡不算「无卡」也不进 unit 均值（D13 active 口径）；
    ///   `value` 仍照常计算，`isDataAnomalous` 照常标记。
    public static func cardProgress(
        stabilityDays: Double?,
        enabled: Bool
    ) -> CardProgressResult {
        guard let stabilityDays else {
            return CardProgressResult(
                value: 0,
                countsTowardUnitMean: enabled,
                isDataAnomalous: false
            )
        }
        guard stabilityDays.isFinite else {
            return CardProgressResult(
                value: 0,
                countsTowardUnitMean: enabled,
                isDataAnomalous: true
            )
        }
        let raw = log1p(max(0, stabilityDays)) / log1p(targetStabilityDays)
        return CardProgressResult(
            value: min(1, max(0, raw)),
            countsTowardUnitMean: enabled,
            isDataAnomalous: false
        )
    }

    /// `unitProgress = 1`（tooEasy）|
    ///   `mean(启用词汇卡 value)`（非空集合）|
    ///   `0`（无启用卡且非 tooEasy）。
    ///
    /// `cardProgresses` 由调用方按 unit 汇集——该 unit 名下所有
    /// vocabulary 方向卡（primary + legacy secondary Note，跨 Note）
    /// 逐张 `cardProgress` 的结果；本函数只按
    /// `countsTowardUnitMean` 过滤，不再做模板筛选。
    /// tooEasy 时 `value` 恒 1，但启用卡数/异常数仍如实上报。
    public static func unitProgress(
        tooEasy: Bool,
        cardProgresses: [CardProgressResult]
    ) -> UnitProgressResult {
        let counted = cardProgresses.filter(\.countsTowardUnitMean)
        let anomalies = cardProgresses.filter(\.isDataAnomalous).count
        if tooEasy {
            return UnitProgressResult(
                value: 1,
                enabledCardCount: counted.count,
                anomalousCardCount: anomalies
            )
        }
        guard !counted.isEmpty else {
            return UnitProgressResult(
                value: 0,
                enabledCardCount: 0,
                anomalousCardCount: anomalies
            )
        }
        let mean = counted.reduce(0.0) { $0 + $1.value } / Double(counted.count)
        return UnitProgressResult(
            value: mean,
            enabledCardCount: counted.count,
            anomalousCardCount: anomalies
        )
    }

    /// `deckProgress = mean(DISTINCT unitID.progress)` |
    ///   `nil`（空集 / 全 nil）。
    ///
    /// 去重先于平均——同 unitID 重复行只计一票（同一 unit 跨 deck
    /// 或跨 Note 的进度是全局唯一值，重复行属投影冗余）；首个带
    /// 非 nil progress 的行生效，`progress == nil` 的行视为投影
    /// 缺失，直接跳过不当 0 计入。
    /// 空 deck、仅 Cloze/Grammar 的 deck 由调用方传入空集 → nil，
    /// UI 显示「—」，不是 0%。
    public static func deckProgress(
        units: [DeckUnitProgressInput]
    ) -> Double? {
        var seen = Set<UUID>()
        var sum = 0.0
        var count = 0
        for unit in units {
            guard let progress = unit.progress else { continue }
            guard seen.insert(unit.unitID).inserted else { continue }
            sum += progress
            count += 1
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }
}

/// 单卡 `cardProgress` 的结果（见 `LearningProgressMath.cardProgress`）。
public struct CardProgressResult: Equatable, Sendable {
    /// 清洗后的进度值 ∈ [0,1]（NaN/±inf 输入归零，不传播）。
    public let value: Double
    /// 该卡是否计入 unit 均值——即 `is_enabled`（停用卡被排除，
    /// 既不是分子也不是「有启用卡」证据）。
    public let countsTowardUnitMean: Bool
    /// stability 为 NaN/±inf——D13「数据异常待修复」标记。
    public let isDataAnomalous: Bool

    public init(
        value: Double,
        countsTowardUnitMean: Bool,
        isDataAnomalous: Bool
    ) {
        self.value = value
        self.countsTowardUnitMean = countsTowardUnitMean
        self.isDataAnomalous = isDataAnomalous
    }
}

/// `unitProgress` 的结果：value 口径见 §13.1；附带计数供 UI
/// 「无启用方向」（D13）与「待修复」标记使用。
public struct UnitProgressResult: Equatable, Sendable {
    /// unit 进度 ∈ [0,1]。
    public let value: Double
    /// 参与均值的启用词汇卡数。
    public let enabledCardCount: Int
    /// stability 非有限的卡数（含停用卡——数据异常与启用状态无关）。
    public let anomalousCardCount: Int

    public init(
        value: Double,
        enabledCardCount: Int,
        anomalousCardCount: Int
    ) {
        self.value = value
        self.enabledCardCount = enabledCardCount
        self.anomalousCardCount = anomalousCardCount
    }

    /// 「无启用方向」：false 时 UI 应标注（全停用/无卡且非
    /// tooEasy → value 恒 0，D13）。
    public var hasEnabledVocabularyCards: Bool { enabledCardCount > 0 }
}

/// `deckProgress` 的输入单元：unitID + 该 unit 的全局进度。
/// 同一 unit 可在牌组内经多条 Note 出现——调用方逐行投影即可，
/// 去重在本函数内完成。
public struct DeckUnitProgressInput: Equatable, Sendable {
    public let unitID: UUID
    /// 该 unit 的 `unitProgress.value`；nil = 投影缺失（跳过）。
    public let progress: Double?

    public init(unitID: UUID, progress: Double?) {
        self.unitID = unitID
        self.progress = progress
    }
}
