import Foundation
import Observation
import OboeDomain
import OboeInfrastructure

/// v0.7.0 S22：阅读分析页数据源——VM 只依赖这条窄协议，测试用桩件。
/// 生产实现见 `AppReaderAnalyticsSource`（GRDBReaderAnalyticsRepository
/// 的薄适配）。
protocol ReaderAnalyticsFetching: Sendable {
    func activityTotals() async throws -> ReaderActivityTotals
    func dailyActivity(dayCount: Int) async throws -> [ReaderActivityDayPoint]
    func knowledgeSummary() async throws -> ReaderKnowledgeSummary
    func documentSummaries(
        limit: Int
    ) async throws -> [ReaderDocumentSummary]
    func coverageTrend(
        documentID: UUID
    ) async throws -> [ReaderCoverageTrendSegment]
    func activityTimeline(limit: Int) async throws -> [ReaderTimelineEntry]
}

/// S22 阅读分析页视图模型：事件流聚合（挖词/标知/制卡/重置）、
/// 当前掌握词数、版本分段覆盖率趋势、事件时间线。
///
/// 展示纪律（沿用 S21）：
/// - 「无数据」以 nil→「—」/「暂无」呈现，绝不伪造 0 或 0%；
///   覆盖率分母为 0 的快照点不进入连线序列（不显示 0% 假象）。
/// - 事件计数是历史行为量；掌握词数是当前态——两口径在 UI 文案
///   上明确分离（「标记过 N 次」vs「当前掌握 N 词」）。
/// - 撤销事件不进有效计数，但时间线照常展示（标灰）。
/// - v0.7 无阅读会话时长表：文档行展示最近打开时间与进度，
///   不伪造时长数字（见 s22 报告「已知限制」）。
@MainActor
@Observable
final class ReaderAnalyticsViewModel {
    /// 文档概览行数上限（统计页用途——全量列表归文档库页）。
    static let documentListLimit = 20
    /// 时间线条目上限。
    static let timelineLimit = 50
    /// 逐日活动窗口：最近 N 个已落库学习日。
    static let dailyWindowCount = 30

    private let source: any ReaderAnalyticsFetching
    /// v0.7.5 S20：「阅读学习」数据源（漏斗 + Coverage v2）。
    /// nil 时整个新区块隐藏——增量接入不破坏 S22 页面。
    private let studyMetricsSource: (any ReaderStudyMetricsFetching)?
    /// 切换选中文档时丢弃过期趋势响应（世代守卫，同 S21 模式）。
    private var trendGeneration = 0

    var totals: ReaderActivityTotals?
    var knowledge: ReaderKnowledgeSummary?
    var daily: [ReaderActivityDayPoint] = []
    var documents: [ReaderDocumentSummary] = []
    var timeline: [ReaderTimelineEntry] = []
    /// 覆盖率趋势的目标文档；nil 时自动取概览首行。
    var selectedDocumentID: UUID? {
        didSet {
            guard selectedDocumentID != oldValue else { return }
            scheduleTrendReload()
        }
    }
    var trendSegments: [ReaderCoverageTrendSegment] = []
    /// S20：选中文档的 Reader→学习项漏斗（当前态）。
    var studyFunnel: ReaderStudyFunnel?
    /// S20：选中文档的 Coverage v2 活算结果（当前态，不落库）。
    var liveCoverageV2: ReaderCoverageV2.Result?
    /// S20：选中文档的 v26 快照历史（版本分段）。
    var coverageV2Segments: [ReaderStudyCoverageSegment] = []
    var isLoading = true
    var isTrendLoading = false
    var errorMessage: String?

    init(
        source: any ReaderAnalyticsFetching,
        studyMetricsSource: (any ReaderStudyMetricsFetching)? = nil
    ) {
        self.source = source
        self.studyMetricsSource = studyMetricsSource
    }

    // MARK: - 载入

    /// 全量刷新：各支路并发；失败整体收敛为 errorMessage。
    /// 成功后默认选中有快照的首个文档。
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let totalsTask = source.activityTotals()
            async let dailyTask = source.dailyActivity(
                dayCount: Self.dailyWindowCount)
            async let knowledgeTask = source.knowledgeSummary()
            async let documentsTask = source.documentSummaries(
                limit: Self.documentListLimit)
            async let timelineTask = source.activityTimeline(
                limit: Self.timelineLimit)
            totals = try await totalsTask
            daily = try await dailyTask
            knowledge = try await knowledgeTask
            documents = try await documentsTask
            timeline = try await timelineTask
            errorMessage = nil
            if selectedDocumentID == nil
                || !documents.contains(where: { $0.documentID == selectedDocumentID }) {
                selectedDocumentID = documents.first?.documentID
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 只重拉选中文档的趋势段（其他区块与该选择无关）。
    private func scheduleTrendReload() {
        trendGeneration += 1
        let generation = trendGeneration
        guard let documentID = selectedDocumentID else {
            trendSegments = []
            return
        }
        isTrendLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await self.source.coverageTrend(
                    documentID: documentID)
                // S20：阅读学习三支路随文档选择一并刷新（源未接 →
                // nil/空——视图区隐藏不渲染空框）。
                var funnel: ReaderStudyFunnel?
                var live: ReaderCoverageV2.Result?
                var v2Segments: [ReaderStudyCoverageSegment] = []
                if let metrics = self.studyMetricsSource {
                    async let funnelTask = metrics.funnel(
                        documentID: documentID)
                    async let liveTask = metrics.liveCoverage(
                        documentID: documentID)
                    async let trendTask = metrics.coverageTrend(
                        documentID: documentID)
                    funnel = try await funnelTask
                    live = try await liveTask?.result
                    v2Segments = try await trendTask
                }
                guard generation == self.trendGeneration else { return }
                self.trendSegments = segments
                self.studyFunnel = funnel
                self.liveCoverageV2 = live
                self.coverageV2Segments = v2Segments
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.trendGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
            if generation == self.trendGeneration {
                self.isTrendLoading = false
            }
        }
    }

    // MARK: - 展示语义（可测的纯映射）

    /// 各统计区块是否有可呈现数据（空文档行/0-块快照不算数——
    /// 无正文文档只产生「暂无可统计词汇」文案，不算统计数据）。
    var hasAnyData: Bool {
        (totals?.totalEffective ?? 0) > 0
            || (knowledge?.trackedLexemeCount ?? 0) > 0
            || documents.contains {
                $0.eventCount > 0
                    || ($0.latestCoverage.map { !$0.hasNoBody } ?? false)
            }
    }

    /// 选中文档的概览行（含已删文档——历史仍可读）。
    var selectedDocument: ReaderDocumentSummary? {
        documents.first { $0.documentID == selectedDocumentID }
    }

    /// 选中文档的状态文案：未分析 > 快照（含 0/0 无正文行，显示
    /// 「暂无可统计词汇」而非伪造 0%；「无正文」徽标在文档行上）。
    var selectedDocumentStatus: String {
        guard let document = selectedDocument else { return "暂无文档" }
        guard let coverage = document.latestCoverage else {
            return document.documentExists ? "尚未分析" : "已删除（未分析）"
        }
        var text = "最近学习日 \(coverage.studyDayID)："
        if let value = coverage.uniqueKnownOrLearningCoverage {
            text += "覆盖率 \(percentText(value))"
        } else {
            text += "暂无可统计词汇"
        }
        if coverage.isPartial { text += "（部分块）" }
        if !document.documentExists { text += " · 已删除" }
        return text
    }

    // MARK: - 格式化（集中在此便于 VM 测试断言）

    func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    /// 学习日行的数值明细文本（等价于图表读数）。
    func dayPointSummary(_ point: ReaderActivityDayPoint) -> String {
        let day = point.isUnfiled ? "未归档" : point.localDate
        guard point.total > 0 else { return "\(day)：无阅读操作" }
        var parts: [String] = []
        if point.miningCount > 0 { parts.append("挖词 \(point.miningCount)") }
        if point.createdCloze > 0 { parts.append("句卡 \(point.createdCloze)") }
        if point.markedKnown > 0 { parts.append("标知 \(point.markedKnown)") }
        if point.resetKnowledge > 0 {
            parts.append("重置 \(point.resetKnowledge)")
        }
        return "\(day)：\(parts.joined(separator: "，"))"
    }

    /// 事件 kind 的展示名。
    func kindTitle(_ kind: ReaderActivityKind) -> String {
        switch kind {
        case .minedNewNote: return "挖词（新建）"
        case .linkedExistingNote: return "关联既有笔记"
        case .createdCloze: return "制作句卡"
        case .markedKnown: return "标为已掌握"
        case .resetKnowledge: return "重置知识状态"
        }
    }

    /// 时间线行文本：kind + 表记 + 文档 + 撤销标记。
    func timelineEntrySummary(_ entry: ReaderTimelineEntry) -> String {
        var text = kindTitle(entry.kind)
        if let form = entry.writtenForm { text += "「\(form)」" }
        if let title = entry.documentTitle { text += " · \(title)" }
        if entry.isUndone { text += "（已撤销）" }
        return text
    }

    /// 覆盖率段的版本标签（给 AX/图注说明断线原因）。
    func segmentLabel(_ segment: ReaderCoverageTrendSegment) -> String {
        "形态 \(segment.morphologyVersion)"
            + " · 口径 \(segment.metricVersion)"
            + " · 词典 \(segment.dictionaryVersion ?? "未记录")"
    }

    /// 趋势段内一个点的明细文本。
    func trendPointSummary(_ point: ReaderCoverageTrendPoint) -> String {
        var text = point.studyDayID
        if let value = point.uniqueKnownOrLearningCoverage {
            text += "：覆盖率 \(percentText(value))"
        } else {
            text += "：暂无可统计词汇"
        }
        if point.isPartial {
            text += "（已分析 \(point.analyzedBlocks)/\(point.totalBlocks) 块）"
        }
        return text
    }

    // MARK: - S20 阅读学习展示语义

    /// 「阅读学习」区块可见性——源未接 → 整区隐藏（增量接入纪律）。
    var hasStudyMetrics: Bool { studyMetricsSource != nil }

    /// 选中文档是否有任何漏斗/Coverage v2 可读数据（全空 → 「暂无」，
    /// 不渲染一排 0）。
    var hasStudyData: Bool {
        (studyFunnel?.preparedOccurrences ?? 0) > 0
            || (studyFunnel?.selectedTotal ?? 0) > 0
            || (studyFunnel?.appliedTotal ?? 0) > 0
            || liveCoverageV2 != nil
            || !coverageV2Segments.isEmpty
    }

    /// Coverage v2 段的版本标签（同 S22 segmentLabel——断线原因展示）。
    func coverageV2SegmentLabel(
        _ segment: ReaderStudyCoverageSegment
    ) -> String {
        "口径 \(segment.metricVersion)"
            + " · 形态 \(segment.morphologyVersion)"
            + " · 词典 \(segment.dictionaryVersion)"
    }

    /// v2 快照点明细文本（等价于图表读数——日期 + 已解析覆盖 +
    /// 已掌握 + 部分范围标注）。
    func coverageV2PointSummary(
        _ point: ReaderStudyCoveragePoint
    ) -> String {
        var text = point.calculatedAt
            .formatted(date: .abbreviated, time: .shortened) + "："
        if let value = point.resolvedCoverage {
            text += "覆盖率 \(percentText(value))"
        } else {
            text += "暂无可统计词汇"
        }
        if let mastered = point.masteredCoverage,
           point.masteredUnique > 0 {
            text += " · 已掌握 \(percentText(mastered))"
        }
        if point.isPartial {
            text += "（已分析 \(point.analyzedBlocks)/"
                + "\(point.totalBlocks) 块）"
        }
        return text
    }

    /// 漏斗 Job 行计数摘要（零 Job → 「无 Job」而非一排 0）。
    func funnelJobSummary(_ funnel: ReaderStudyFunnel) -> String {
        var parts: [String] = []
        if funnel.activeJobs > 0 {
            parts.append("活跃 \(funnel.activeJobs)")
        }
        if funnel.completedJobs > 0 {
            parts.append("完成 \(funnel.completedJobs)")
        }
        if funnel.failedJobs > 0 {
            parts.append("失败 \(funnel.failedJobs)")
        }
        if funnel.cancelledJobs > 0 {
            parts.append("取消 \(funnel.cancelledJobs)")
        }
        return parts.isEmpty ? "无 Job" : parts.joined(separator: "，")
    }

    /// v2 趋势图 AX 摘要（段数 + 各段点数）。
    var coverageV2ChartAccessibilitySummary: String {
        guard !coverageV2Segments.isEmpty else {
            return "暂无 Coverage v2 记录"
        }
        let detail = coverageV2Segments.map {
            "\(coverageV2SegmentLabel($0)) 共 \($0.points.count) 个快照"
        }.joined(separator: "；")
        return "共 \(coverageV2Segments.count) 个版本段：\(detail)"
    }

    // MARK: - 图表 AX 摘要

    /// 逐日活动图 AX 摘要。
    var dailyChartAccessibilitySummary: String {
        guard let totals, totals.totalEffective > 0 else {
            return "暂无阅读活动"
        }
        let activeDays = daily.filter { $0.total > 0 }.count
        var text = "近 \(daily.count) 个学习日内有 \(activeDays) 天产生阅读操作"
        if totals.totalEffective > 0 {
            text += "，挖词 \(totals.miningCount) 次，句卡 "
                + "\(totals.createdCloze) 次，标知 \(totals.markedKnown) 次"
        }
        if totals.undoneCount > 0 {
            text += "；已撤销 \(totals.undoneCount) 次不计入"
        }
        return text
    }

    /// 覆盖率趋势图 AX 摘要（段数 + 各段点数）。
    var trendChartAccessibilitySummary: String {
        guard !trendSegments.isEmpty else { return "暂无覆盖率记录" }
        let detail = trendSegments.map {
            "\(segmentLabel($0)) 共 \($0.points.count) 个学习日"
        }.joined(separator: "；")
        return "共 \(trendSegments.count) 个版本段：\(detail)"
    }
}
