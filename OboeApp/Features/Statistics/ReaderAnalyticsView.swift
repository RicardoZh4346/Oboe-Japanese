import Charts
import Observation
import OboeDomain
import SwiftUI

/// v0.7.0 S22 阅读分析页：Reader 活动聚合 + 当前知识态 + 版本分段
/// 覆盖率趋势 + 事件时间线。空态与 AX 约定同 S21 统计页：
/// 每个区块独立「暂无」文案、图表配 AX 标签与等价数值明细。
///
/// 独立页面（不改 Reader* UI）：由统计页「阅读分析」入口进入。
struct ReaderAnalyticsView: View {
    @State private var model: ReaderAnalyticsViewModel

    init(source: any ReaderAnalyticsFetching) {
        _model = State(initialValue: ReaderAnalyticsViewModel(source: source))
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
