import Foundation

/// v0.7.0 S09：Reader 覆盖率双口径纯计算（设计 §7 / D04）。
/// 本文件只有纯函数与值类型——无 IO、无 SQL，口径的唯一实现点。
///
/// 冻结口径（§7，改动必须升级 `metricVersion`，不静默换分母）：
/// - 计入分母：`ReaderTokenClass.lexical / .auxiliary / .outOfVocabulary`
///   （助词/助动词计入，独立英文字词作 OOV 计 unknown）；
///   `nonLexical`（空白/标点/纯符号/独立纯数字）不计。
/// - `eligible = K + L + U`；已知覆盖率 = K/eligible；
///   已知或学习中覆盖率 = (K+L)/eligible；ignored 单列，排除分母。
/// - eligible == 0 → 覆盖率为 nil（「暂无可统计词汇」），不是 100%。
/// - unique 口径按 dedupKey 去重后套同一公式；同一 key 只归一个状态。
/// - 模糊 token 按确定性 unresolved key 计 unknown，并单列
///   `pendingConfirmation`（待确认数量）。
public enum ReaderCoverageMath {
    /// 口径版本：分母/分类规则变化时 bump（`reader_coverage_snapshots.
    /// metric_version` 列与快照 UNIQUE 键组成部分）。
    public static let currentMetricVersion = "coverage-1.0.0"

    /// 未确认 token 的确定性去重键前缀（§7「确定性 unresolved key」）。
    /// 与 `LexicalIdentityKey` 的 `jmdict|`/`local|` 命名空间天然不冲突。
    public static let unresolvedDedupPrefix = "unresolved|"

    /// 单 token 对覆盖率的贡献。`countsForCoverage == false` 的 token
    /// 不产生 contribution（返回 nil）。
    public struct TokenContribution: Equatable, Sendable {
        /// unique 口径去重键：已确认身份 = `lexicalKey.identityKey`；
        /// 未确认（ambiguous/unresolved 无 key）=
        /// `unresolved|<normalized surface>`——不按候选臆造身份。
        public let dedupKey: String
        /// 需要查知识状态的 identity key；nil = 无身份 token（计 unknown）。
        public let identityKey: String?
        /// 候选并列待用户确认（ambigous）：仍计 unknown，但单列数量。
        public let isAmbiguous: Bool
        /// 词典无候选（OOV：空候选的 lexical/auxiliary/outOfVocabulary）。
        public let isOutOfVocabulary: Bool

        public init(
            dedupKey: String,
            identityKey: String?,
            isAmbiguous: Bool,
            isOutOfVocabulary: Bool
        ) {
            self.dedupKey = dedupKey
            self.identityKey = identityKey
            self.isAmbiguous = isAmbiguous
            self.isOutOfVocabulary = isOutOfVocabulary
        }
    }

    /// token → contribution。nil = 不计入分母（nonLexical）。
    public static func contribution(of token: ReaderToken) -> TokenContribution? {
        guard token.tokenClass.countsForCoverage else { return nil }
        if let key = token.lexicalKey {
            return TokenContribution(
                dedupKey: key.identityKey,
                identityKey: key.identityKey,
                isAmbiguous: token.resolutionStatus == .ambiguous,
                isOutOfVocabulary: token.candidates.isEmpty
            )
        }
        return TokenContribution(
            dedupKey: unresolvedDedupPrefix
                + SearchTextNormalizer.normalize(token.surface),
            identityKey: nil,
            isAmbiguous: token.resolutionStatus == .ambiguous,
            isOutOfVocabulary: token.candidates.isEmpty
        )
    }

    /// contribution + 状态表 → 应归状态。无身份 / 身份未落库 → unknown
    /// （词典缺条不把人推出分母，§6.3「未知词不应因词典缺条而被排除」）。
    public static func state(
        of contribution: TokenContribution,
        states: [String: VocabularyKnowledgeState]
    ) -> VocabularyKnowledgeState {
        guard let identityKey = contribution.identityKey else { return .unknown }
        return states[identityKey] ?? .unknown
    }
}

/// 覆盖率累加器：token 计数 + 每状态去重集合（unique 口径）。
/// 块级累加器经 `merge` 集成为文档级——unique 集合取并集，
/// 跨块重复 lemma 自然去重（不能用块级 unique 数相加）。
public struct ReaderCoverageAccumulator: Equatable, Sendable {
    public private(set) var known = 0
    public private(set) var learning = 0
    public private(set) var unknown = 0
    public private(set) var ignored = 0
    /// 歧义待确认 token 数（已计入 unknown，单列供 UI 提示）。
    public private(set) var pendingConfirmation = 0
    /// 词典无候选 token 数（已计入 unknown，OOV 标记）。
    public private(set) var outOfVocabulary = 0
    private var uniqueKeys: [VocabularyKnowledgeState: Set<String>] = [:]

    public init() {}

    public mutating func add(
        _ contribution: ReaderCoverageMath.TokenContribution,
        state: VocabularyKnowledgeState
    ) {
        switch state {
        case .known: known += 1
        case .learning: learning += 1
        case .unknown: unknown += 1
        case .ignored: ignored += 1
        }
        if contribution.isAmbiguous { pendingConfirmation += 1 }
        if contribution.isOutOfVocabulary { outOfVocabulary += 1 }
        uniqueKeys[state, default: []].insert(contribution.dedupKey)
    }

    /// 便捷入口：token → contribution → 归类。
    public mutating func add(
        token: ReaderToken,
        states: [String: VocabularyKnowledgeState]
    ) {
        guard let contribution = ReaderCoverageMath.contribution(of: token)
        else { return }
        add(contribution, state: ReaderCoverageMath.state(
            of: contribution, states: states))
    }

    /// 并入另一累加器（块 → 文档）：计数相加、去重集合取并。
    public mutating func merge(_ other: ReaderCoverageAccumulator) {
        known += other.known
        learning += other.learning
        unknown += other.unknown
        ignored += other.ignored
        pendingConfirmation += other.pendingConfirmation
        outOfVocabulary += other.outOfVocabulary
        for (state, keys) in other.uniqueKeys {
            uniqueKeys[state, default: []].formUnion(keys)
        }
    }

    public func metrics(
        analyzedBlocks: Int,
        totalBlocks: Int
    ) -> ReaderCoverageMetrics {
        ReaderCoverageMetrics(
            known: known, learning: learning, unknown: unknown, ignored: ignored,
            uniqueKnown: uniqueKeys[.known]?.count ?? 0,
            uniqueLearning: uniqueKeys[.learning]?.count ?? 0,
            uniqueUnknown: uniqueKeys[.unknown]?.count ?? 0,
            uniqueIgnored: uniqueKeys[.ignored]?.count ?? 0,
            pendingConfirmation: pendingConfirmation,
            outOfVocabulary: outOfVocabulary,
            analyzedBlocks: analyzedBlocks, totalBlocks: totalBlocks
        )
    }
}

/// 一次覆盖率计算的完整结果（内存态；持久化投影见
/// `reader_coverage_snapshots`——unique_numerator 存
/// `uniqueKnown + uniqueLearning`，即 D04 头条口径的分子）。
public struct ReaderCoverageMetrics: Equatable, Sendable {
    /// 当前口径版本（快照 `metric_version` 列值）。
    public static let metricVersion = ReaderCoverageMath.currentMetricVersion

    // token 口径计数（次数）。
    public let known: Int
    public let learning: Int
    public let unknown: Int
    public let ignored: Int
    // unique 口径计数（distinct dedupKey）。
    public let uniqueKnown: Int
    public let uniqueLearning: Int
    public let uniqueUnknown: Int
    public let uniqueIgnored: Int
    /// 候选并列待确认 token 数（unknown 子集）。
    public let pendingConfirmation: Int
    /// 词典无候选 token 数（unknown 子集，OOV）。
    public let outOfVocabulary: Int
    /// 已分析/总块数；analyzed < total → partial（不可展示为全书）。
    public let analyzedBlocks: Int
    public let totalBlocks: Int

    public init(
        known: Int, learning: Int, unknown: Int, ignored: Int,
        uniqueKnown: Int, uniqueLearning: Int,
        uniqueUnknown: Int, uniqueIgnored: Int,
        pendingConfirmation: Int, outOfVocabulary: Int,
        analyzedBlocks: Int, totalBlocks: Int
    ) {
        self.known = known
        self.learning = learning
        self.unknown = unknown
        self.ignored = ignored
        self.uniqueKnown = uniqueKnown
        self.uniqueLearning = uniqueLearning
        self.uniqueUnknown = uniqueUnknown
        self.uniqueIgnored = uniqueIgnored
        self.pendingConfirmation = pendingConfirmation
        self.outOfVocabulary = outOfVocabulary
        self.analyzedBlocks = analyzedBlocks
        self.totalBlocks = totalBlocks
    }

    /// token 口径分母：K+L+U（ignored 排除）。
    public var eligible: Int { known + learning + unknown }

    /// 已知覆盖率（token 口径）。eligible==0 → nil。
    public var tokenCoverage: Double? {
        eligible > 0 ? Double(known) / Double(eligible) : nil
    }

    /// 已知或学习中覆盖率（token 口径）。
    public var knownOrLearningCoverage: Double? {
        eligible > 0 ? Double(known + learning) / Double(eligible) : nil
    }

    /// unique 口径分母：|K∪L∪U| distinct key。
    public var uniqueEligible: Int {
        uniqueKnown + uniqueLearning + uniqueUnknown
    }

    /// 已知覆盖率（unique 口径）。
    public var uniqueCoverage: Double? {
        uniqueEligible > 0
            ? Double(uniqueKnown) / Double(uniqueEligible) : nil
    }

    /// 已知或学习中覆盖率（unique 口径）——D04 头条数字（93.08%）
    /// 对应 `(uniqueKnown+uniqueLearning)/uniqueEligible`，快照
    /// `unique_numerator/unique_denominator` 即此分子分母。
    public var uniqueKnownOrLearningCoverage: Double? {
        uniqueEligible > 0
            ? Double(uniqueKnown + uniqueLearning) / Double(uniqueEligible)
            : nil
    }

    /// 分析未完成：partial 结果只能展示为「已分析范围」的覆盖率，
    /// 不得冒充全书（§7）。
    public var isPartial: Bool { analyzedBlocks < totalBlocks }

    /// 文档内是否存在任何可计词汇 token（含 ignored）。
    /// false = 无词文档（整块 nonLexical/空文档）。
    public var hasAnyCountableTokens: Bool { eligible + ignored > 0 }

    /// 「暂无可统计词汇」：eligible==0。与「无词文档」区分——
    /// 全 ignored 文档也落入此分支（有 token 但全被排除分母）。
    public var hasEligibleTokens: Bool { eligible > 0 }
}

/// 未知词列表条目（S09 交付：分页查询，`isOutOfVocabulary` 标记 OOV）。
public struct UnknownWordItem: Equatable, Sendable {
    /// 稳定去重键（identityKey 或 unresolved|<surface>）。
    public let dedupKey: String
    /// 展示表记：已入库 lexeme 取 writtenForm，否则取 token surface。
    public let displayForm: String
    public let reading: String?
    /// 关联的 lexeme（未入库/未确认身份为 nil）。
    public let lexemeID: UUID?
    /// 在已分析范围内出现次数。
    public let occurrenceCount: Int
    /// 词典无候选（OOV）。
    public let isOutOfVocabulary: Bool
    /// 有候选待用户确认（ambiguous）。
    public let isAmbiguous: Bool

    public init(
        dedupKey: String,
        displayForm: String,
        reading: String?,
        lexemeID: UUID?,
        occurrenceCount: Int,
        isOutOfVocabulary: Bool,
        isAmbiguous: Bool
    ) {
        self.dedupKey = dedupKey
        self.displayForm = displayForm
        self.reading = reading
        self.lexemeID = lexemeID
        self.occurrenceCount = occurrenceCount
        self.isOutOfVocabulary = isOutOfVocabulary
        self.isAmbiguous = isAmbiguous
    }
}
