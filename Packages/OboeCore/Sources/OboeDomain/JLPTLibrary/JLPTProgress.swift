import Foundation

/// JLPT 进度策略参数（设计 §11.2）。所有阈值集中在 policy，UI/服务
/// 不得自行解释；版本号随结果输出，便于缓存与排障。
public struct JLPTProgressPolicy: Equatable, Sendable {
    public static let currentVersion = "jlpt-progress-v1"

    /// 「近期遗忘」窗口：距今天数。是时间跨度，不是评分次数。
    public var recentAgainDaysWindow: Int
    /// 「较稳定」所需的最低 FSRS stability（天）。
    public var stableMinimumStabilityDays: Double

    public init(
        recentAgainDaysWindow: Int = 7,
        stableMinimumStabilityDays: Double = 21
    ) {
        self.recentAgainDaysWindow = recentAgainDaysWindow
        self.stableMinimumStabilityDays = stableMinimumStabilityDays
    }

    public static let standard = JLPTProgressPolicy()

    public var version: String { Self.currentVersion }
}

/// 词库条目的互斥分类（设计 §11.2）。统计单位是内置条目 ID，
/// 不是 Card —— 同一 Note 的多方向卡聚合到同一个词。
public enum JLPTWordBucket: String, CaseIterable, Codable, Equatable, Sendable {
    /// 没有关联 Note。
    case notAdded
    /// 任一启用 Card 评估为 leech（与易错中心同一 classifier）。
    case frequentlyForgotten
    /// 任一启用已学 Card 的最近有效评分为 Again 且发生于近窗口内。
    case recentlyForgotten
    /// 至少一张启用 Card，且所有启用 Card 均满足稳定条件。
    case stable
    /// 其余已加入（含全部暂停、全 New 未开始）。
    case learning
}

/// 单条词库条目的分类结果：互斥桶 + 辅助状态。
public struct JLPTWordStatus: Equatable, Sendable {
    public let bucket: JLPTWordBucket
    /// 已加入但所有 Card 均暂停 —— 仍计学习中，附「已暂停」。
    public let isSuspended: Bool
    /// 已加入但所有 Card 均无有效评分（全 New）—— 附「未开始」。
    public let isNotStarted: Bool

    public init(bucket: JLPTWordBucket, isSuspended: Bool, isNotStarted: Bool) {
        self.bucket = bucket
        self.isSuspended = isSuspended
        self.isNotStarted = isNotStarted
    }
}

/// 词级分类所需的单卡输入。`adaptiveStatus` 必须由 `LeechClassifier`
/// 产出 —— 与易错中心严格同源，这里不维护第二套 leech 阈值。
/// `cardID`/`templateKind` 供薄弱词汇列表展开各薄弱方向并跳转
/// 易错详情（T25），不参与词级分类计算。
public struct JLPTCardProgressInput: Equatable, Sendable {
    public let cardID: UUID
    public let templateKind: CardTemplateKind
    public let isEnabled: Bool
    public let adaptiveStatus: AdaptiveCardStatus
    public let state: SchedulingState
    public let stability: Double
    /// 曾有过有效学习（first_studied_at 非空）。
    public let hasStudied: Bool
    /// 最近一条有效（未撤销）评分；无评分时为 nil。
    public let lastEffectiveRating: ReviewRating?
    public let lastEffectiveRatingAt: Date?
    /// 最近一次有效 Again 的时间；无 Again 为 nil。
    public let lastAgainAt: Date?

    public init(
        cardID: UUID,
        templateKind: CardTemplateKind,
        isEnabled: Bool,
        adaptiveStatus: AdaptiveCardStatus,
        state: SchedulingState,
        stability: Double,
        hasStudied: Bool,
        lastEffectiveRating: ReviewRating?,
        lastEffectiveRatingAt: Date?,
        lastAgainAt: Date?
    ) {
        self.cardID = cardID
        self.templateKind = templateKind
        self.isEnabled = isEnabled
        self.adaptiveStatus = adaptiveStatus
        self.state = state
        self.stability = stability
        self.hasStudied = hasStudied
        self.lastEffectiveRating = lastEffectiveRating
        self.lastEffectiveRatingAt = lastEffectiveRatingAt
        self.lastAgainAt = lastAgainAt
    }
}

/// 纯函数词级分类器（设计 §11.2）。不访问数据库，`now` 注入，
/// 同一输入恒得同一输出。
public enum JLPTWordClassifier {
    /// `cards` 为该条目全部已关联 Note 的全部 Card。空数组表示未加入。
    public static func classify(
        cards: [JLPTCardProgressInput],
        at now: Date,
        policy: JLPTProgressPolicy = .standard
    ) -> JLPTWordStatus {
        guard !cards.isEmpty else {
            return JLPTWordStatus(
                bucket: .notAdded, isSuspended: false, isNotStarted: false
            )
        }
        let windowStart = now.addingTimeInterval(
            -TimeInterval(policy.recentAgainDaysWindow) * 86_400
        )
        let enabled = cards.filter(\.isEnabled)
        let notStarted = cards.allSatisfy { !$0.hasStudied }

        // 全部暂停仍属已加入/学习中，附「已暂停」——不落入未加入，
        // 也不可能满足较稳定（没有启用卡可供判断）。
        guard !enabled.isEmpty else {
            return JLPTWordStatus(
                bucket: .learning, isSuspended: true, isNotStarted: notStarted
            )
        }

        if enabled.contains(where: { $0.adaptiveStatus == .leech }) {
            return JLPTWordStatus(
                bucket: .frequentlyForgotten, isSuspended: false, isNotStarted: false
            )
        }

        let hasRecentAgain = enabled.contains { card in
            card.hasStudied
                && card.lastEffectiveRating == .again
                && (card.lastEffectiveRatingAt ?? .distantPast) >= windowStart
        }
        if hasRecentAgain {
            return JLPTWordStatus(
                bucket: .recentlyForgotten, isSuspended: false, isNotStarted: false
            )
        }

        let allStable = enabled.allSatisfy { card in
            card.state == .review
                && card.stability >= policy.stableMinimumStabilityDays
                && (card.lastEffectiveRating == .good
                    || card.lastEffectiveRating == .easy)
                && (card.lastAgainAt.map { $0 < windowStart } ?? true)
                && card.adaptiveStatus == .normal
        }
        if allStable {
            return JLPTWordStatus(
                bucket: .stable, isSuspended: false, isNotStarted: false
            )
        }

        return JLPTWordStatus(
            bucket: .learning, isSuspended: false, isNotStarted: notStarted
        )
    }
}

/// 只读内置词库的条目引用（进度统计的最小输入）。
public struct JLPTVocabularyRef: Equatable, Sendable {
    public let id: String
    public let level: JLPTLevel

    public init(id: String, level: JLPTLevel) {
        self.id = id
        self.level = level
    }
}

/// 用户库中 `origin = builtin_jlpt` 的关联查询。sourceRef 精确匹配
/// 内置条目 ID，不按 headword 猜测；同一 sourceRef 的多个 Note
/// （防御性）聚合其全部 Card。
public protocol JLPTNoteAssociationRepository: Sendable {
    func builtinNoteAssociations() async throws -> [String: [UUID]]
}

/// 目标等级的进度汇总。`bucketCounts` 五桶互斥、总和等于
/// `totalEntries`；`suspendedCount`/`notStartedCount` 为辅助计数，
/// 与桶重叠（只出现在学习中桶内）。
public struct JLPTTargetProgress: Equatable, Sendable {
    public let targetLevel: JLPTLevel
    public let includedLevels: [JLPTLevel]
    public let totalEntries: Int
    public let bucketCounts: [JLPTWordBucket: Int]
    public let suspendedCount: Int
    public let notStartedCount: Int
    public let generatedAt: Date
    public let policyVersion: String

    public init(
        targetLevel: JLPTLevel,
        includedLevels: [JLPTLevel],
        totalEntries: Int,
        bucketCounts: [JLPTWordBucket: Int],
        suspendedCount: Int,
        notStartedCount: Int,
        generatedAt: Date,
        policyVersion: String
    ) {
        self.targetLevel = targetLevel
        self.includedLevels = includedLevels
        self.totalEntries = totalEntries
        self.bucketCounts = bucketCounts
        self.suspendedCount = suspendedCount
        self.notStartedCount = notStartedCount
        self.generatedAt = generatedAt
        self.policyVersion = policyVersion
    }

    public func count(_ bucket: JLPTWordBucket) -> Int {
        bucketCounts[bucket] ?? 0
    }
}

extension JLPTLevel {
    /// 累计目标包含的等级：N3 = N5+N4+N3，N1 为全量（设计 §11.1）。
    public static func cumulativeLevels(upTo target: JLPTLevel) -> [JLPTLevel] {
        guard let index = allCases.firstIndex(of: target) else { return [target] }
        return Array(allCases[...index])
    }
}

/// Dashboard 的计数和分类列表共享一次计算，避免分别查询造成数目漂移。
/// `cards` 是产生 `status` 的全部关联卡证据 —— 薄弱词汇列表（T25）
/// 从同一份证据展开各薄弱方向，不另行查询。
public struct JLPTProgressEntry: Identifiable, Equatable, Sendable {
    public let vocabulary: JLPTVocabularyRef
    public let status: JLPTWordStatus
    public let cards: [JLPTCardProgressInput]
    public var id: String { vocabulary.id }

    public init(
        vocabulary: JLPTVocabularyRef,
        status: JLPTWordStatus,
        cards: [JLPTCardProgressInput]
    ) {
        self.vocabulary = vocabulary
        self.status = status
        self.cards = cards
    }

    /// 当前筛选下的薄弱方向卡 —— 与易错中心同一 `AdaptiveListFilter`
    /// 规则（启用卡按评估状态、暂停筛选收集全部暂停卡），同一词下
    /// 保持方向序稳定。
    public func weakCards(matching filter: AdaptiveListFilter) -> [JLPTCardProgressInput] {
        cards.filter { filter.matches(isEnabled: $0.isEnabled, status: $0.adaptiveStatus) }
    }
}

public struct JLPTProgressSnapshot: Equatable, Sendable {
    public let summary: JLPTTargetProgress
    public let entries: [JLPTProgressEntry]

    public func entries(in bucket: JLPTWordBucket) -> [JLPTProgressEntry] {
        entries.filter { $0.status.bucket == bucket }
    }

    /// 「需要关注」词汇：按词去重（每条词库条目至多出现一次），
    /// 保留至少一张匹配筛选的方向卡。计数与展开明细来自同一次
    /// 分类，与五桶数字天然一致（设计 §11.2/T25）。
    public func weakEntries(matching filter: AdaptiveListFilter) -> [JLPTProgressEntry] {
        entries.filter { !$0.weakCards(matching: filter).isEmpty }
    }
}

/// JLPT 进度服务（设计 §11）：词库条目 ↔ builtin Note ↔ 卡证据
/// 三方汇合后逐词分类。卡级状态走 `LeechClassifier`——与易错中心
/// 同一 classifier、同一阈值，不复制规则。
///
/// 服务是纯协调器：不直接访问数据库，`now` 注入保证确定性。
public struct JLPTProgressService: Sendable {
    private let libraryRepository: any JLPTLibraryRepository
    private let associationRepository: any JLPTNoteAssociationRepository
    private let adaptiveRepository: any AdaptiveRepository
    private let leechClassifier: LeechClassifier
    private let progressPolicy: JLPTProgressPolicy

    public init(
        libraryRepository: any JLPTLibraryRepository,
        associationRepository: any JLPTNoteAssociationRepository,
        adaptiveRepository: any AdaptiveRepository,
        progressPolicy: JLPTProgressPolicy = .standard,
        adaptivePolicy: AdaptivePolicy = .standard
    ) {
        self.libraryRepository = libraryRepository
        self.associationRepository = associationRepository
        self.adaptiveRepository = adaptiveRepository
        self.leechClassifier = LeechClassifier(policy: adaptivePolicy)
        self.progressPolicy = progressPolicy
    }

    /// 目标等级的累计进度（N3 汇总 N5+N4+N3）。词库条目为只读
    /// 资源；`origin=ai` 的 Note 不参与内置条目关联（设计 §11.2）。
    public func progress(
        targetLevel: JLPTLevel,
        at now: Date
    ) async throws -> JLPTTargetProgress {
        try await snapshot(targetLevel: targetLevel, at: now).summary
    }

    public func snapshot(
        targetLevel: JLPTLevel,
        at now: Date
    ) async throws -> JLPTProgressSnapshot {
        let levels = JLPTLevel.cumulativeLevels(upTo: targetLevel)
        async let refsRequest = libraryRepository.vocabularyRefs(levels: levels)
        async let associationsRequest = associationRepository.builtinNoteAssociations()
        async let snapshotRequest = adaptiveRepository.fetchSnapshot(scope: .all)
        let refs = try await refsRequest
        let associations = try await associationsRequest
        let snapshot = try await snapshotRequest

        var inputsByNote: [UUID: [JLPTCardProgressInput]] = [:]
        for record in snapshot.records {
            let evidence = record.evidence
            let assessment = leechClassifier.assess(evidence: evidence, at: now)
            let samples = evidence.samples
            let input = JLPTCardProgressInput(
                cardID: evidence.cardID,
                templateKind: evidence.templateKind,
                isEnabled: evidence.isEnabled,
                adaptiveStatus: assessment.status,
                state: evidence.scheduling.state,
                stability: evidence.scheduling.stability,
                hasStudied: evidence.firstStudiedAt != nil,
                lastEffectiveRating: samples.first?.rating,
                lastEffectiveRatingAt: samples.first?.reviewedAt,
                lastAgainAt: samples.first(where: { $0.rating == .again })?.reviewedAt
            )
            inputsByNote[evidence.noteID, default: []].append(input)
        }

        var bucketCounts: [JLPTWordBucket: Int] = [:]
        var suspendedCount = 0
        var notStartedCount = 0
        var entries: [JLPTProgressEntry] = []
        for ref in refs {
            let noteIDs = associations[ref.id] ?? []
            let cards = noteIDs
                .flatMap { inputsByNote[$0] ?? [] }
                .sorted(by: Self.cardDisplayOrder)
            let status = JLPTWordClassifier.classify(
                cards: cards, at: now, policy: progressPolicy
            )
            entries.append(
                JLPTProgressEntry(vocabulary: ref, status: status, cards: cards)
            )
            bucketCounts[status.bucket, default: 0] += 1
            if status.isSuspended { suspendedCount += 1 }
            if status.isNotStarted { notStartedCount += 1 }
        }
        let summary = JLPTTargetProgress(
            targetLevel: targetLevel,
            includedLevels: levels,
            totalEntries: refs.count,
            bucketCounts: bucketCounts,
            suspendedCount: suspendedCount,
            notStartedCount: notStartedCount,
            generatedAt: now,
            policyVersion: progressPolicy.version
        )
        return JLPTProgressSnapshot(summary: summary, entries: entries)
    }

    /// Deterministic direction order inside one word — template declaration
    /// order, then card id — so the weak-direction expansion renders the
    /// same sequence for identical evidence.
    private static func cardDisplayOrder(
        _ lhs: JLPTCardProgressInput,
        _ rhs: JLPTCardProgressInput
    ) -> Bool {
        let left = templateOrder(lhs.templateKind)
        let right = templateOrder(rhs.templateKind)
        if left != right { return left < right }
        return lhs.cardID.uuidString < rhs.cardID.uuidString
    }

    private static func templateOrder(_ kind: CardTemplateKind) -> Int {
        CardTemplateKind.allCases.firstIndex(of: kind) ?? .max
    }
}
