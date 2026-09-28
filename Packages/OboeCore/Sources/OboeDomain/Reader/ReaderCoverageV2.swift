import Foundation

/// v0.7.5 S14（角色 C 纯函数部分）：Reader「已解析词义覆盖率」
/// 纯计算（contracts-frozen §5.2、技术文档 §13.3、decision D09）。
///
/// 与旧 `ReaderCoverageMath`（`coverage-1.0.0`，lexeme/token 口径）
/// 并存不替换：历史快照按 metricVersion 分段保留，旧曲线不接续、
/// 不重命名（D09）。
///
/// 冻结口径（`coverage-resolved-sense-2.0.0`）：
/// - 分母 = 范围内已确认身份的 distinct unit（dictionary/local
///   均可）；身份未确认的 occurrence 不入分母。
/// - `resolvedCoverage = (learning + mastered 的 unit 数) / 分母`；
///   `masteredCoverage = mastered unit 数 / 分母`；空分母 → nil。
/// - OOV/未确认 occurrence 不进分母，但必须保留 occurrence 计数
///   与已分析块范围相邻展示——1 个已解析词不许显示「全书 100%」。
/// - 已解析但处 unknown 态（无 Note、未标 tooEasy）的 unit
///   计入分母、不计入分子（§13.3 分母是「已解析」而非「已学习」）。
public enum ReaderCoverageV2 {
    /// 口径版本：分母/分类规则变化必须 bump（快照
    /// `reader_learning_coverage_snapshots.metric_version` 与
    /// 唯一键组成部分，contracts §6 v26）。
    public static let metricVersion = "coverage-resolved-sense-2.0.0"

    /// 范围内一个已解析 unit 的出现记录。同一 unitID 可有多行
    /// （多处 occurrence 解析到同义项、跨块重复），`compute` 按
    /// unitID 去重。
    ///
    /// `state` 是该 unit 的当前三态（全局唯一值）；重复行状态不
    /// 一致属投影异常，按 `mastered > learning > unknown` 取最强者
    /// 保证确定性。
    public struct ResolvedUnit: Equatable, Sendable {
        public let unitID: UUID
        public let state: LearningKnowledgeState

        public init(unitID: UUID, state: LearningKnowledgeState) {
            self.unitID = unitID
            self.state = state
        }
    }

    /// occurrence 级展示统计：全部不进分母（D09）。
    public struct OccurrenceStats: Equatable, Sendable {
        /// 未确认/未消歧 occurrence 数（「待确认」标记）。
        public let pendingOccurrences: Int
        /// 词典无候选 occurrence 数（OOV）。
        public let oovOccurrences: Int
        /// 已分析块数 / 范围总块数；analyzed < total → partial，
        /// 只能按「已分析范围」展示。
        public let analyzedBlocks: Int
        public let totalBlocks: Int

        public init(
            pendingOccurrences: Int,
            oovOccurrences: Int,
            analyzedBlocks: Int,
            totalBlocks: Int
        ) {
            self.pendingOccurrences = pendingOccurrences
            self.oovOccurrences = oovOccurrences
            self.analyzedBlocks = analyzedBlocks
            self.totalBlocks = totalBlocks
        }
    }

    /// 一次 Coverage v2 计算的完整结果（内存态；持久化投影见
    /// v26 `reader_learning_coverage_snapshots`，本值提供列值来源）。
    public struct Result: Equatable, Sendable {
        /// 本结果对应的口径版本。
        public static let metricVersion = ReaderCoverageV2.metricVersion

        /// 分母：distinct 已解析 unit 数。
        public let resolvedUnique: Int
        /// 其中 mastered（tooEasy）unit 数。
        public let masteredUnique: Int
        /// 其中 learning（有词汇 Note 关联）unit 数。
        public let learningUnique: Int
        /// 未确认 occurrence 数（展示用，不进分母）。
        public let pendingOccurrences: Int
        /// OOV occurrence 数（展示用，不进分母）。
        public let oovOccurrences: Int
        /// 已分析/总块数。
        public let analyzedBlocks: Int
        public let totalBlocks: Int
        /// `(learning + mastered) / resolvedUnique`；空分母 → nil。
        public let resolvedCoverage: Double?
        /// `mastered / resolvedUnique`；空分母 → nil。
        public let masteredCoverage: Double?

        public init(
            resolvedUnique: Int,
            masteredUnique: Int,
            learningUnique: Int,
            pendingOccurrences: Int,
            oovOccurrences: Int,
            analyzedBlocks: Int,
            totalBlocks: Int,
            resolvedCoverage: Double?,
            masteredCoverage: Double?
        ) {
            self.resolvedUnique = resolvedUnique
            self.masteredUnique = masteredUnique
            self.learningUnique = learningUnique
            self.pendingOccurrences = pendingOccurrences
            self.oovOccurrences = oovOccurrences
            self.analyzedBlocks = analyzedBlocks
            self.totalBlocks = totalBlocks
            self.resolvedCoverage = resolvedCoverage
            self.masteredCoverage = masteredCoverage
        }

        /// unknown 态已解析 unit 数
        /// = resolved − learning − mastered（在分母不在分子）。
        public var unlearnedUnique: Int {
            resolvedUnique - masteredUnique - learningUnique
        }

        /// 分析未完成：结果只能展示为「已分析范围」覆盖率，
        /// 不得冒充全书（同 §7 partial 纪律）。
        public var isPartial: Bool { analyzedBlocks < totalBlocks }
    }

    /// 计算 Coverage v2。`units` 无需调用方去重——按 unitID
    /// 去重是本口径的一部分（D09「resolved units 去重分母」）。
    public static func compute(
        units: [ResolvedUnit],
        occurrenceStats: OccurrenceStats
    ) -> Result {
        var stateByUnit: [UUID: LearningKnowledgeState] = [:]
        stateByUnit.reserveCapacity(units.count)
        for unit in units {
            if let existing = stateByUnit[unit.unitID] {
                stateByUnit[unit.unitID] = stronger(existing, unit.state)
            } else {
                stateByUnit[unit.unitID] = unit.state
            }
        }

        var mastered = 0
        var learning = 0
        for state in stateByUnit.values {
            switch state {
            case .mastered: mastered += 1
            case .learning: learning += 1
            case .unknown: break
            }
        }

        let resolved = stateByUnit.count
        let resolvedCoverage: Double? = resolved > 0
            ? Double(learning + mastered) / Double(resolved)
            : nil
        let masteredCoverage: Double? = resolved > 0
            ? Double(mastered) / Double(resolved)
            : nil

        return Result(
            resolvedUnique: resolved,
            masteredUnique: mastered,
            learningUnique: learning,
            pendingOccurrences: occurrenceStats.pendingOccurrences,
            oovOccurrences: occurrenceStats.oovOccurrences,
            analyzedBlocks: occurrenceStats.analyzedBlocks,
            totalBlocks: occurrenceStats.totalBlocks,
            resolvedCoverage: resolvedCoverage,
            masteredCoverage: masteredCoverage
        )
    }

    /// 状态强度：mastered > learning > unknown。unit 状态本应全局
    /// 唯一，重复行不一致时取最强者保持确定性（不随机择行）。
    private static func stronger(
        _ a: LearningKnowledgeState,
        _ b: LearningKnowledgeState
    ) -> LearningKnowledgeState {
        rank(a) >= rank(b) ? a : b
    }

    private static func rank(_ state: LearningKnowledgeState) -> Int {
        switch state {
        case .mastered: 2
        case .learning: 1
        case .unknown: 0
        }
    }
}
