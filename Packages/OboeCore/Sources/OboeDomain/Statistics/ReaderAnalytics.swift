import Foundation

/// v0.7.0 S22：Reader Analytics 只读查询层结果模型 + 版本分段纯函数。
///
/// 本文件是 S22 的**增量**类型——不改 `StatisticsContracts.swift` 的
/// 冻结成员；事件枚举沿用 `ReaderActivityKind` 五态。
///
/// 口径总则（详细报告见 docs/v0.7/s22-reader-analytics.md）：
/// - 事件计数是**历史行为量**：`undone_at_ms IS NULL` 的有效事件按
///   kind 聚合；撤销事件计入 `undoneCount` 单列，绝不参与有效计数。
///   ignored/backfill/unlink 等操作按冻结枚举不产生事件（S08 裁决），
///   不出现「缺失的 markedIgnored 桶」。
/// - 「当前掌握词数」是**当前态**：由 `vocabulary_knowledge_overrides`
///   （每 lexeme 至多一行）+ `lexeme_note_links` 真值表直出，lexeme
///   去重——known↔ignored 反复切换只是同一行的状态迁移，不放大计数。
/// - 覆盖率趋势按快照持久化的版本三元组
///   `(metric_version, morphology_version, dictionary_version)` 分段，
///   跨版本永不连线（版本回退 A→B→A 也开新段，不跨时段回接）。
/// - `reader_activity_events` / `reader_coverage_snapshots` 对文档是
///   弱引用/快照字段：文档删除后历史照常返回，绝不 INNER JOIN
///   `reader_documents` 丢行。
public protocol ReaderAnalyticsRepository: Sendable {
    /// 全部有效事件按 kind 聚合 + 撤销事件单列。
    func activityTotals() async throws -> ReaderActivityTotals
    /// 最近 N 个已落库学习日（按 `study_days` 行取窗，不补日历）的
    /// 逐日事件聚合；落不进任何学习日窗口的有效事件归入
    /// `localDate.isEmpty` 的未归档桶（不静默丢弃）。
    func dailyActivity(dayCount: Int) async throws -> [ReaderActivityDayPoint]
    /// 当前知识态聚合（lexeme 去重、真值表口径）。
    func knowledgeSummary() async throws -> ReaderKnowledgeSummary
    /// 文档概览：reader_documents ∪ 快照 ∪ 事件三方 document_id 并集；
    /// 已删文档凭快照标题呈现，`documentExists=false`。
    func documentSummaries(limit: Int) async throws -> [ReaderDocumentSummary]
    /// 单文档 `scope_key='document'` 快照趋势，按版本三元组分段。
    /// 文档已删除也照常返回（快照是历史事实）。
    func coverageTrend(documentID: UUID) async throws -> [ReaderCoverageTrendSegment]
    /// 事件时间线（新→旧），snapshot_json 解码出表记/文档标题兜底
    /// 弱引用删除后的展示。
    func activityTimeline(limit: Int) async throws -> [ReaderTimelineEntry]
}

// MARK: - 活动流聚合

/// 单个学习日（或未归档桶）的 Reader 活动聚合计数。
/// 事件计数 = 有效事件次数（历史行为量，非当前态）。
public struct ReaderActivityDayPoint: Equatable, Sendable, Identifiable {
    /// 学习日 `local_date`（"yyyy-MM-dd"）；无 study_days 行可归的
    /// 事件归入未归档桶（`localDate` 为空、`isUnfiled` 为 true）。
    public let localDate: String
    /// 新建词汇 Note 的挖词事件数。
    public let minedNewNote: Int
    /// 关联既有 Note 的事件数。
    public let linkedExistingNote: Int
    /// Reader→Cloze 制卡事件数。
    public let createdCloze: Int
    /// 「标为已掌握」事件数（`markedKnown`——override=known 才写）。
    public let markedKnown: Int
    /// 重置知识事件数（override 清除）。
    public let resetKnowledge: Int

    public init(
        localDate: String,
        minedNewNote: Int,
        linkedExistingNote: Int,
        createdCloze: Int,
        markedKnown: Int,
        resetKnowledge: Int
    ) {
        self.localDate = localDate
        self.minedNewNote = minedNewNote
        self.linkedExistingNote = linkedExistingNote
        self.createdCloze = createdCloze
        self.markedKnown = markedKnown
        self.resetKnowledge = resetKnowledge
    }

    /// 未归档桶：事件 `created_at_ms` 落不进任何已落库 study_days
    /// 窗口（例如早于首个学习日的历史导入）。
    public var isUnfiled: Bool { localDate.isEmpty }
    public var id: String { isUnfiled ? "__unfiled__" : localDate }

    /// 当日有效事件总数。
    public var total: Int {
        minedNewNote + linkedExistingNote + createdCloze
            + markedKnown + resetKnowledge
    }
    /// 挖词口径：新建 + 关联既有（cloze 是句卡挖掘，单列不计入）。
    public var miningCount: Int { minedNewNote + linkedExistingNote }
    /// 制卡口径：新建词汇卡 + cloze 卡（关联既有不产新卡）。
    public var cardCreationCount: Int { minedNewNote + createdCloze }
}

/// 全时段事件聚合（有效 + 撤销单列）。
public struct ReaderActivityTotals: Equatable, Sendable {
    public let minedNewNote: Int
    public let linkedExistingNote: Int
    public let createdCloze: Int
    public let markedKnown: Int
    public let resetKnowledge: Int
    /// `undone_at_ms` 非空的事件数——撤销语义：不计入上面的有效桶。
    public let undoneCount: Int

    public init(
        minedNewNote: Int,
        linkedExistingNote: Int,
        createdCloze: Int,
        markedKnown: Int,
        resetKnowledge: Int,
        undoneCount: Int
    ) {
        self.minedNewNote = minedNewNote
        self.linkedExistingNote = linkedExistingNote
        self.createdCloze = createdCloze
        self.markedKnown = markedKnown
        self.resetKnowledge = resetKnowledge
        self.undoneCount = undoneCount
    }

    public var totalEffective: Int {
        minedNewNote + linkedExistingNote + createdCloze
            + markedKnown + resetKnowledge
    }
    public var miningCount: Int { minedNewNote + linkedExistingNote }
    public var cardCreationCount: Int { minedNewNote + createdCloze }
}

// MARK: - 当前知识态

/// 全库 lexeme 的当前知识态分布（真值表，每 lexeme 恰归一桶）。
/// `known`/`ignored` 来自 override 单行；`learning` = 有 vocabulary
/// Note 关联且无 override；其余计入 `unmarked`。
public struct ReaderKnowledgeSummary: Equatable, Sendable {
    /// 当前 override=known 的 lexeme 数（「已掌握」词数——当前态）。
    public let knownCount: Int
    /// 有 ≥1 条 vocabulary Note 关联且无 override 的 lexeme 数。
    public let learningCount: Int
    /// 当前 override=ignored 的 lexeme 数。
    public let ignoredCount: Int
    /// `lexemes` 全表行数（知识网承载过的词元总数）。
    public let trackedLexemeCount: Int

    public init(
        knownCount: Int,
        learningCount: Int,
        ignoredCount: Int,
        trackedLexemeCount: Int
    ) {
        self.knownCount = knownCount
        self.learningCount = learningCount
        self.ignoredCount = ignoredCount
        self.trackedLexemeCount = trackedLexemeCount
    }

    /// 无 override 且无 vocabulary 关联的 lexeme 数（真值表 unknown）。
    /// 钳到 ≥0：并发写窗口里四支计数非同一快照，不向外暴露负值。
    public var unmarkedCount: Int {
        max(0, trackedLexemeCount - knownCount - learningCount - ignoredCount)
    }
}

// MARK: - 覆盖率趋势（版本分段）

/// 文档级快照的趋势点。`studyDayID` 是快照口径的 `local_date`
/// （"yyyy-MM-dd"，由写入侧按学习日边界算出——非 study_days.id）。
public struct ReaderCoverageTrendPoint: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let studyDayID: String
    public let createdAt: Date
    /// unique 口径 (K+L)/|K∪L∪U|；分母 0 → nil（不伪造 0%/100%）。
    public let uniqueKnownOrLearningCoverage: Double?
    /// token 口径 K/(K+L+U)；eligible 0 → nil。
    public let tokenCoverage: Double?
    /// partial 行（analyzed < total）照常入点——UI 标记为「已分析范围」。
    public let isPartial: Bool
    public let analyzedBlocks: Int
    public let totalBlocks: Int

    public init(
        id: UUID,
        studyDayID: String,
        createdAt: Date,
        uniqueKnownOrLearningCoverage: Double?,
        tokenCoverage: Double?,
        isPartial: Bool,
        analyzedBlocks: Int,
        totalBlocks: Int
    ) {
        self.id = id
        self.studyDayID = studyDayID
        self.createdAt = createdAt
        self.uniqueKnownOrLearningCoverage = uniqueKnownOrLearningCoverage
        self.tokenCoverage = tokenCoverage
        self.isPartial = isPartial
        self.analyzedBlocks = analyzedBlocks
        self.totalBlocks = totalBlocks
    }
}

/// 同一版本三元组下的一段连续趋势点。版本切换（含回退）开新段，
/// 图表按段连线——绝不跨版本连出误导性的斜线。
public struct ReaderCoverageTrendSegment: Equatable, Sendable, Identifiable {
    /// 趋势内的段序（稳定 id：同键回退不会与前段合并）。
    public let index: Int
    /// 覆盖率口径版本（`ReaderCoverageMath.currentMetricVersion`）。
    public let metricVersion: String
    /// 形态管线版本。
    public let morphologyVersion: String
    /// 词典 dataset 版本（provenance；nil 行归入单独段而非与有值段混淆）。
    public let dictionaryVersion: String?
    public let points: [ReaderCoverageTrendPoint]

    public init(
        index: Int,
        metricVersion: String,
        morphologyVersion: String,
        dictionaryVersion: String?,
        points: [ReaderCoverageTrendPoint]
    ) {
        self.index = index
        self.metricVersion = metricVersion
        self.morphologyVersion = morphologyVersion
        self.dictionaryVersion = dictionaryVersion
        self.points = points
    }

    public var id: Int { index }
    /// 折叠版本键（分段的等价判据）。
    public var versionKey: String {
        "\(metricVersion)|\(morphologyVersion)|\(dictionaryVersion ?? "—")"
    }
}

/// 趋势点 → 版本段的纯函数分段器（连续 run 归并；版本回退开新段）。
/// 单点也成段——孤立版本行照常显示为点而不是被丢掉。
public enum ReaderCoverageSegmentation {
    public static func segments(
        of points: [(metricVersion: String, morphologyVersion: String,
                     dictionaryVersion: String?, point: ReaderCoverageTrendPoint)]
    ) -> [ReaderCoverageTrendSegment] {
        var result: [ReaderCoverageTrendSegment] = []
        for item in points {
            if let last = result.last,
               last.metricVersion == item.metricVersion,
               last.morphologyVersion == item.morphologyVersion,
               last.dictionaryVersion == item.dictionaryVersion {
                result[result.count - 1] = ReaderCoverageTrendSegment(
                    index: last.index,
                    metricVersion: last.metricVersion,
                    morphologyVersion: last.morphologyVersion,
                    dictionaryVersion: last.dictionaryVersion,
                    points: last.points + [item.point]
                )
            } else {
                result.append(ReaderCoverageTrendSegment(
                    index: result.count,
                    metricVersion: item.metricVersion,
                    morphologyVersion: item.morphologyVersion,
                    dictionaryVersion: item.dictionaryVersion,
                    points: [item.point]
                ))
            }
        }
        return result
    }
}

// MARK: - 文档概览与时间线

/// 阅读文档概览行：覆盖三件事的并集——现存文档、有快照的文档
/// （含已删）、有事件归因的文档。
public struct ReaderDocumentSummary: Equatable, Sendable, Identifiable {
    public let documentID: UUID
    /// 展示标题：活文档取 `reader_documents.title`，已删文档取
    /// 快照内 `document_title`（删除后历史仍可读）。
    public let title: String
    /// `reader_documents` 行是否仍在（false = 已删文档的历史行）。
    public let documentExists: Bool
    /// 最近打开时间（已删文档为 nil——`reader_documents` 行不存在）。
    public let lastOpenedAt: Date?
    /// 阅读进度基点（0...10000；已删/无行为 nil）。
    public let progressBasisPoints: Int?
    /// 该文档归因的有效事件数（`document_id` 为 SET NULL 弱引用——
    /// 已删文档的事件不再可归属到本文档，只在全局口径中计）。
    public let eventCount: Int
    /// 最新文档级快照（任意版本——趋势分段另行处理版本切换）。
    public let latestCoverage: ReaderDocumentLatestCoverage?

    public init(
        documentID: UUID,
        title: String,
        documentExists: Bool,
        lastOpenedAt: Date?,
        progressBasisPoints: Int?,
        eventCount: Int,
        latestCoverage: ReaderDocumentLatestCoverage?
    ) {
        self.documentID = documentID
        self.title = title
        self.documentExists = documentExists
        self.lastOpenedAt = lastOpenedAt
        self.progressBasisPoints = progressBasisPoints
        self.eventCount = eventCount
        self.latestCoverage = latestCoverage
    }

    public var id: UUID { documentID }
    /// 阅读进度 0...1；无进度数据为 nil。
    public var progress: Double? {
        progressBasisPoints.map { Double($0) / 10_000.0 }
    }
}

/// 文档最近一次文档级快照的摘要字段。
public struct ReaderDocumentLatestCoverage: Equatable, Sendable {
    public let studyDayID: String
    public let metricVersion: String
    public let morphologyVersion: String
    public let uniqueKnownOrLearningCoverage: Double?
    public let tokenCoverage: Double?
    public let isPartial: Bool
    public let analyzedBlocks: Int
    public let totalBlocks: Int

    public init(
        studyDayID: String,
        metricVersion: String,
        morphologyVersion: String,
        uniqueKnownOrLearningCoverage: Double?,
        tokenCoverage: Double?,
        isPartial: Bool,
        analyzedBlocks: Int,
        totalBlocks: Int
    ) {
        self.studyDayID = studyDayID
        self.metricVersion = metricVersion
        self.morphologyVersion = morphologyVersion
        self.uniqueKnownOrLearningCoverage = uniqueKnownOrLearningCoverage
        self.tokenCoverage = tokenCoverage
        self.isPartial = isPartial
        self.analyzedBlocks = analyzedBlocks
        self.totalBlocks = totalBlocks
    }

    /// 无正文/未分析过：文档没有任何块（快照 0/0 行）。
    public var hasNoBody: Bool { totalBlocks == 0 }
}

/// 事件时间线条目：kind + 时间 + snapshot_json 解码的表记/标题。
/// 弱引用已 SET NULL 的事件仍可读——展示字段全部来自快照或兜底。
public struct ReaderTimelineEntry: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: ReaderActivityKind
    public let createdAt: Date
    /// 事件落入的学习日 local_date；无匹配行时为空串。
    public let localDate: String
    /// `snapshot_json.written_form`（挖词/知识事件均写入）。
    public let writtenForm: String?
    /// `snapshot_json.document_title` → 活文档 title 的回退链。
    public let documentTitle: String?
    /// 已撤销（`undone_at_ms` 非空）——时间线照常展示但 UI 标灰。
    public let isUndone: Bool

    public init(
        id: UUID,
        kind: ReaderActivityKind,
        createdAt: Date,
        localDate: String,
        writtenForm: String?,
        documentTitle: String?,
        isUndone: Bool
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.localDate = localDate
        self.writtenForm = writtenForm
        self.documentTitle = documentTitle
        self.isUndone = isUndone
    }
}
