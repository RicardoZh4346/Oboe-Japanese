import Charts
import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI

/// v0.7.0 S22 阅读分析页：Reader 活动聚合 + 当前知识态 + 版本分段
/// 覆盖率趋势 + 事件时间线。空态与 AX 约定同 S21 统计页：
/// 每个区块独立「暂无」文案、图表配 AX 标签与等价数值明细。
///
/// v0.7.5 S20 增量：「阅读学习」区（AI 学习漏斗 + Coverage v2
/// 当前态/快照史）——`studyMetricsSource` 未接时整区隐藏。
///
/// 独立页面（不改 Reader* UI）：由统计页「阅读分析」入口进入。
struct ReaderAnalyticsView: View {
    @State private var model: ReaderAnalyticsViewModel

    init(
        source: any ReaderAnalyticsFetching,
        studyMetricsSource: (any ReaderStudyMetricsFetching)? = nil
    ) {
        _model = State(initialValue: ReaderAnalyticsViewModel(
            source: source,
            studyMetricsSource: studyMetricsSource))
    }

    var body: some View {
        Group {
            if model.isLoading, model.totals == nil {
                ProgressView("正在载入阅读分析…")
            } else if model.totals != nil || model.knowledge != nil {
                content
            } else {
                ContentUnavailableView(
                    "无法载入阅读分析",
                    systemImage: "book.closed",
                    description: Text(model.errorMessage ?? "请稍后重试。")
                )
            }
        }
        .navigationTitle("阅读分析")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .disabled(model.isLoading)
                .accessibilityIdentifier("reader-analytics-refresh")
            }
        }
        .task {
            await model.load()
        }
    }

    private var content: some View {
        List {
            knowledgeSection
            activitySection
            dailySection
            coverageSection
            studySection
            timelineSection
        }
        .refreshable {
            await model.load()
        }
    }

    // MARK: - 当前知识态

    @ViewBuilder
    private var knowledgeSection: some View {
        Section {
            if let knowledge = model.knowledge {
                ReaderMetricRow(
                    title: "当前已掌握词数",
                    value: "\(knowledge.knownCount)",
                    caption: "按当前知识状态统计，不受切换历史影响",
                    accessibilityID: "reader-analytics-known"
                )
                ReaderMetricRow(
                    title: "学习中",
                    value: "\(knowledge.learningCount)",
                    caption: "已关联词汇笔记",
                    accessibilityID: "reader-analytics-learning"
                )
                ReaderMetricRow(
                    title: "已忽略",
                    value: "\(knowledge.ignoredCount)",
                    caption: "标记为不再学习",
                    accessibilityID: "reader-analytics-ignored"
                )
                ReaderMetricRow(
                    title: "词元库总量",
                    value: "\(knowledge.trackedLexemeCount)",
                    caption: "含未标记词元 \(knowledge.unmarkedCount)",
                    accessibilityID: "reader-analytics-tracked"
                )
            } else {
                Text("暂无知识数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("词汇知识")
        } footer: {
            Text("掌握词数按 lexeme 当前状态去重统计；反复切换已知/忽略不会重复计数。")
        }
    }

    // MARK: - 活动总量

    @ViewBuilder
    private var activitySection: some View {
        Section {
            if let totals = model.totals, totals.totalEffective > 0 {
                ReaderMetricRow(
                    title: "挖词",
                    value: "\(totals.miningCount)",
                    caption: "新建 \(totals.minedNewNote) · 关联既有 \(totals.linkedExistingNote)",
                    accessibilityID: "reader-analytics-mined"
                )
                ReaderMetricRow(
                    title: "制卡",
                    value: "\(totals.cardCreationCount)",
                    caption: "词汇卡 \(totals.minedNewNote) · 句卡 \(totals.createdCloze)",
                    accessibilityID: "reader-analytics-cards"
                )
                ReaderMetricRow(
                    title: "标为已掌握",
                    value: "\(totals.markedKnown)",
                    caption: "历史操作次数",
                    accessibilityID: "reader-analytics-marked"
                )
                ReaderMetricRow(
                    title: "重置知识状态",
                    value: "\(totals.resetKnowledge)",
                    caption: "历史操作次数",
                    accessibilityID: "reader-analytics-resets"
                )
                if totals.undoneCount > 0 {
                    ReaderMetricRow(
                        title: "已撤销",
                        value: "\(totals.undoneCount)",
                        caption: "不计入上方有效计数",
                        accessibilityID: "reader-analytics-undone"
                    )
                }
            } else {
                Text("暂无阅读操作")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader-analytics-activity-empty")
            }
        } header: {
            Text("活动总量")
        } footer: {
            Text("此处为历史操作次数（事件流口径），与上方「当前已掌握词数」（当前态）是两个口径。")
        }
    }

    // MARK: - 逐日活动

    @ViewBuilder
    private var dailySection: some View {
        Section {
            if model.daily.isEmpty {
                Text("暂无逐日记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader-analytics-daily-empty")
            } else {
                ReaderDailyActivityChart(points: model.daily)
                    .frame(height: 140)
                    .accessibilityLabel("逐日阅读活动图")
                    .accessibilityValue(
                        model.dailyChartAccessibilitySummary)
                    .accessibilityIdentifier("reader-analytics-daily-chart")
            }
        } header: {
            Text("逐日活动")
        } footer: {
            Text("按学习日聚合有效事件；未落入任何学习日的事件归入末尾的「未归档」。")
        }

        if !model.daily.isEmpty {
            Section("数值明细") {
                ForEach(model.daily) { point in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.isUnfiled ? "未归档" : point.localDate)
                            .font(.subheadline.monospacedDigit())
                        Text(model.dayPointSummary(point))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(model.dayPointSummary(point))
                    .accessibilityIdentifier(
                        "reader-analytics-day-\(point.id)")
                }
            }
        }
    }

    // MARK: - 覆盖率趋势

    @ViewBuilder
    private var coverageSection: some View {
        Section {
            if model.documents.isEmpty {
                Text("暂无文档")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader-analytics-docs-empty")
            } else {
                Picker("文档", selection: $model.selectedDocumentID) {
                    ForEach(model.documents) { document in
                        Text(documentTitle(document))
                            .tag(Optional(document.documentID))
                    }
                }
                .accessibilityIdentifier("reader-analytics-doc-picker")

                Text(model.selectedDocumentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "reader-analytics-doc-status")

                if model.isTrendLoading {
                    HStack {
                        ProgressView()
                        Text("正在更新…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if model.trendSegments.isEmpty {
                    Text("暂无覆盖率记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "reader-analytics-trend-empty")
                } else {
                    ReaderCoverageTrendChart(segments: model.trendSegments)
                        .frame(height: 160)
                        .accessibilityLabel("覆盖率趋势图")
                        .accessibilityValue(
                            model.trendChartAccessibilitySummary)
                        .accessibilityIdentifier(
                            "reader-analytics-trend-chart")
                }
            }
        } header: {
            Text("覆盖率趋势")
        } footer: {
            if !model.trendSegments.isEmpty {
                Text(
                    "按分析版本分段连线；形态/口径/词典版本变化即开新段，"
                        + "不跨版本连线。分母为 0 的点显示为「暂无可统计词汇」。"
                )
            }
        }

        // 等价数值明细（每段一组）。
        ForEach(model.trendSegments) { segment in
            Section("第 \(segment.index + 1) 段 · \(segment.morphologyVersion)") {
                ForEach(segment.points) { point in
                    Text(model.trendPointSummary(point))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "reader-analytics-trend-\(segment.index)-\(point.studyDayID)")
                }
            }
        }

        if !model.documents.isEmpty {
            Section("文档概览") {
                ForEach(model.documents) { document in
                    documentRow(document)
                }
            }
        }
    }

    private func documentTitle(_ document: ReaderDocumentSummary) -> String {
        document.documentExists ? document.title : "\(document.title)（已删除）"
    }

    @ViewBuilder
    private func documentRow(_ document: ReaderDocumentSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(document.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if !document.documentExists {
                    Text("已删除")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let coverage = document.latestCoverage,
                   let value = coverage.uniqueKnownOrLearningCoverage {
                    Text(model.percentText(value))
                        .font(.subheadline.monospacedDigit())
                }
            }
            HStack(spacing: 12) {
                if let progress = document.progress {
                    Text("进度 \(Int((progress * 100).rounded()))%")
                }
                if let coverage = document.latestCoverage {
                    if coverage.hasNoBody {
                        Text("无正文")
                    } else if coverage.isPartial {
                        Text("部分块")
                    }
                }
                if document.eventCount > 0 {
                    Text("操作 \(document.eventCount) 次")
                }
                Spacer()
                if let opened = document.lastOpenedAt {
                    Text(opened, format: .dateTime.month().day())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "reader-analytics-doc-\(document.documentID.uuidString)")
    }

    // MARK: - 阅读学习（v0.7.5 S20：漏斗 + Coverage v2）

    /// 「阅读学习」区块：随上方文档选择联动；源未接 → 整区隐藏。
    /// 口径纪律：漏斗与活算 Coverage v2 是**当前态**，快照史是
    /// **历史留痕**——两口径分 Section 标注；v2 与旧
    /// `coverage-1.0.0` 趋势（上方「覆盖率趋势」）分列展示，
    /// 永不合并为一条累计线。
    @ViewBuilder
    private var studySection: some View {
        if model.hasStudyMetrics {
            // —— Reader → 学习项漏斗（当前态）——
            Section {
                if let funnel = model.studyFunnel, model.hasStudyData {
                    StudyMetricRow(
                        title: "准备（occurrence 锚点）",
                        value: "\(funnel.preparedOccurrences)",
                        accessibilityID: "reader-study-funnel-prepared")
                    StudyMetricRow(
                        title: "已解析",
                        value: "\(funnel.resolvedOccurrences)",
                        accessibilityID: "reader-study-funnel-resolved")
                    StudyMetricRow(
                        title: "待确认",
                        value: "\(funnel.pendingOccurrences)",
                        accessibilityID: "reader-study-funnel-pending")
                    StudyMetricRow(
                        title: "OOV（无候选）",
                        value: "\(funnel.oovOccurrences)",
                        accessibilityID: "reader-study-funnel-oov")
                    StudyMetricRow(
                        title: "已确认选择",
                        value: "复用 \(funnel.selectedReuse)"
                            + " · 新增 \(funnel.selectedCreate)"
                            + " · 跳过 \(funnel.selectedSkip)"
                            + " · 太简单 \(funnel.selectedTooEasy)"
                            + (funnel.selectedPending > 0
                                ? " · 未定 \(funnel.selectedPending)" : ""),
                        accessibilityID: "reader-study-funnel-selected")
                    StudyMetricRow(
                        title: "已应用",
                        value: "复用 \(funnel.appliedReuse)"
                            + " · 新增 \(funnel.appliedCreate)"
                            + " · 跳过 \(funnel.appliedSkip)"
                            + " · 太简单 \(funnel.appliedTooEasy)",
                        accessibilityID: "reader-study-funnel-applied")
                    Text("Job：\(model.funnelJobSummary(funnel))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader-study-funnel-jobs")
                } else {
                    Text("暂无学习记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader-study-funnel-empty")
                }
            } header: {
                Text("阅读学习（AI 学习漏斗）")
            } footer: {
                Text("漏斗按当前态统计：本文档当前修订的锚点 + 最新选择"
                    + "修订；「已应用」是「已确认」的子集（receipt 幂等）。")
            }

            // —— Coverage v2 当前态（活算投影）——
            Section {
                if let live = model.liveCoverageV2 {
                    coverageV2Rows(
                        resolvedUnique: live.resolvedUnique,
                        learningUnique: live.learningUnique,
                        masteredUnique: live.masteredUnique,
                        unlearnedUnique: live.unlearnedUnique,
                        pendingOccurrences: live.pendingOccurrences,
                        oovOccurrences: live.oovOccurrences,
                        resolvedCoverage: live.resolvedCoverage,
                        masteredCoverage: live.masteredCoverage,
                        isPartial: live.isPartial,
                        analyzedBlocks: live.analyzedBlocks,
                        totalBlocks: live.totalBlocks,
                        caption: "当前态活算")
                } else if let latest = model.coverageV2Segments
                    .last?.points.last {
                    // 文档已删/无活算对象——最近快照行仍可读（历史
                    // 留痕，标注来源防止误读为当前值）。
                    coverageV2Rows(
                        resolvedUnique: latest.resolvedUnique,
                        learningUnique: latest.learningUnique,
                        masteredUnique: latest.masteredUnique,
                        unlearnedUnique: latest.unlearnedUnique,
                        pendingOccurrences: latest.pendingOccurrences,
                        oovOccurrences: latest.oovOccurrences,
                        resolvedCoverage: latest.resolvedCoverage,
                        masteredCoverage: latest.masteredCoverage,
                        isPartial: latest.isPartial,
                        analyzedBlocks: latest.analyzedBlocks,
                        totalBlocks: latest.totalBlocks,
                        caption: "最近快照（历史）")
                } else {
                    Text("暂无 Coverage v2 数据")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("reader-study-v2-empty")
                }
            } header: {
                Text("覆盖率 v2（已解析词义）")
            } footer: {
                Text("口径 \(ReaderCoverageV2.metricVersion)：分母为已确认"
                    + "身份的 distinct 词义；待确认/OOV 相邻展示不进分母。"
                    + "与 coverage-1.0.0 旧口径分列，互不连线合并。")
            }

            // —— Coverage v2 快照史（版本分段）——
            if !model.coverageV2Segments.isEmpty {
                Section {
                    ReaderStudyCoverageTrendChart(
                        segments: model.coverageV2Segments)
                        .frame(height: 140)
                        .accessibilityLabel("Coverage v2 快照趋势图")
                        .accessibilityValue(
                            model.coverageV2ChartAccessibilitySummary)
                        .accessibilityIdentifier("reader-study-v2-chart")
                } header: {
                    Text("Coverage v2 快照史")
                } footer: {
                    Text("按 口径/形态/词典 版本三元组分段连线——跨版本"
                        + "不连线；历史快照是留痕口径，不随当前态改写。")
                }

                ForEach(model.coverageV2Segments) { segment in
                    Section {
                        ForEach(segment.points) { point in
                            Text(model.coverageV2PointSummary(point))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(
                                    "reader-study-v2-point-"
                                        + "\(point.id.uuidString)")
                        }
                    } header: {
                        Text("v2 第 \(segment.index + 1) 段 · "
                            + segment.metricVersion)
                    } footer: {
                        Text(model.coverageV2SegmentLabel(segment))
                    }
                }
            }
        }
    }

    /// Coverage v2 覆盖读数行组（活算/最近快照共用——caption 区分
    /// 当前态与历史快照两个口径）。
    @ViewBuilder
    private func coverageV2Rows(
        resolvedUnique: Int,
        learningUnique: Int,
        masteredUnique: Int,
        unlearnedUnique: Int,
        pendingOccurrences: Int,
        oovOccurrences: Int,
        resolvedCoverage: Double?,
        masteredCoverage: Double?,
        isPartial: Bool,
        analyzedBlocks: Int,
        totalBlocks: Int,
        caption: String
    ) -> some View {
        ReaderMetricRow(
            title: "已解析覆盖率",
            value: model.percentText(resolvedCoverage),
            caption: "\(caption) · 已解析 \(resolvedUnique) 词义"
                + "（学习中 \(learningUnique) · 已掌握 \(masteredUnique)）",
            accessibilityID: "reader-study-v2-resolved")
        ReaderMetricRow(
            title: "已掌握覆盖率",
            value: model.percentText(masteredCoverage),
            caption: "仍待学 \(unlearnedUnique) 词义计分母不计分子",
            accessibilityID: "reader-study-v2-mastered")
        HStack(spacing: 8) {
            Text("口径 \(ReaderCoverageV2.metricVersion)")
            if isPartial {
                Text("部分范围 \(analyzedBlocks)/\(totalBlocks) 块")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("reader-study-v2-metric")
        if pendingOccurrences > 0 || oovOccurrences > 0 {
            Text("相邻计数：待确认 \(pendingOccurrences)"
                + " · OOV \(oovOccurrences)（不进分母）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reader-study-v2-adjacent")
        }
    }

    // MARK: - 事件时间线

    @ViewBuilder
    private var timelineSection: some View {
        Section {
            if model.timeline.isEmpty {
                Text("暂无事件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reader-analytics-timeline-empty")
            } else {
                ForEach(model.timeline) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.timelineEntrySummary(entry))
                                .font(.subheadline)
                                .foregroundStyle(
                                    entry.isUndone ? .secondary : .primary)
                                .strikethrough(entry.isUndone)
                            Text(entry.localDate.isEmpty
                                 ? "未归档" : entry.localDate)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "reader-analytics-event-\(entry.id.uuidString)")
                }
            }
        } header: {
            Text("事件时间线")
        } footer: {
            if !model.timeline.isEmpty {
                Text("最近 \(model.timeline.count) 条；已撤销操作以删除线标示。")
            }
        }
    }
}

// MARK: - 子视图

/// 指标行：标题 + 大数字 + 注脚（与 S21 RetentionMetricRow 同构）。
private struct ReaderMetricRow: View {
    let title: String
    let value: String
    let caption: String
    let accessibilityID: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityID)
    }
}

/// 逐日事件柱图（窗口内零活动日保留——如实显示空档）。
private struct ReaderDailyActivityChart: View {
    let points: [ReaderActivityDayPoint]

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("学习日", point.id),
                y: .value("事件", point.total)
            )
        }
    }
}

/// S20 漏斗行：标题 + 值（同一行宽排版，值已含分桶文案）。
private struct StudyMetricRow: View {
    let title: String
    let value: String
    let accessibilityID: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityID)
    }
}

/// v0.7.5 S20：Coverage v2 快照趋势——每段一条线（`foregroundStyle(by:)`
/// 以段序号为序列键——版本切换/回退都开新段，绝不跨版本连线；
/// 与 `coverage-1.0.0` 旧趋势图分列，两族序列永不合并）。
private struct ReaderStudyCoverageTrendChart: View {
    let segments: [ReaderStudyCoverageSegment]

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    if let value = point.resolvedCoverage {
                        LineMark(
                            x: .value("快照时刻", point.calculatedAt),
                            y: .value("覆盖率", value),
                            series: .value("段", "段 \(segment.index)")
                        )
                        PointMark(
                            x: .value("快照时刻", point.calculatedAt),
                            y: .value("覆盖率", value)
                        )
                        .foregroundStyle(by: .value("段", "段 \(segment.index)"))
                    }
                }
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v * 100))%")
                    }
                }
            }
        }
    }
}

/// 覆盖率趋势：每段一条线（`foregroundStyle(by:)` 以段序号为序列
/// 键——同版本回退也开新段，绝不跨版本连线）。
private struct ReaderCoverageTrendChart: View {
    let segments: [ReaderCoverageTrendSegment]

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    if let value = point.uniqueKnownOrLearningCoverage {
                        LineMark(
                            x: .value("学习日", point.studyDayID),
                            y: .value("覆盖率", value),
                            series: .value("段", "段 \(segment.index)")
                        )
                        PointMark(
                            x: .value("学习日", point.studyDayID),
                            y: .value("覆盖率", value)
                        )
                        .foregroundStyle(by: .value("段", "段 \(segment.index)"))
                    }
                }
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v * 100))%")
                    }
                }
            }
        }
    }
}
