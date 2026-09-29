import Charts
import Observation
import OboeDomain
import SwiftUI

/// v0.7.0 S21 统计页：保持率三线分离（目标 / 实测 / 预测）+ 评分
/// 趋势（7/30/90 学习日切换）+ 到期预测 + 成熟度 + 弱项。
///
/// 空态纪律：每个区块独立「暂无数据」文案，绝不用 0% 充数；
/// 图表均有 AX 标签 + 等价数值明细列表（VoiceOver 可读全量数据）。
struct StatisticsView: View {
    @State private var model: StatisticsViewModel
    /// S22：「阅读分析」页数据源；nil 时不显示入口（增量接入）。
    private let readerAnalyticsSource: (any ReaderAnalyticsFetching)?
    /// v0.7.5 S20：「阅读学习」数据源（漏斗 + Coverage v2）；
    /// nil 时阅读分析页不渲染该区块。
    private let readerStudyMetricsSource: (any ReaderStudyMetricsFetching)?

    init(
        studyDay: StudyDay,
        source: any StatisticsInsightFetching,
        readerAnalyticsSource: (any ReaderAnalyticsFetching)? = nil,
        readerStudyMetricsSource: (any ReaderStudyMetricsFetching)? = nil
    ) {
        self.readerAnalyticsSource = readerAnalyticsSource
        self.readerStudyMetricsSource = readerStudyMetricsSource
        _model = State(
            initialValue: StatisticsViewModel(
                studyDay: studyDay,
                source: source
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading, model.insight == nil {
                ProgressView("正在载入统计…")
            } else if model.insight != nil {
                content
            } else {
                ContentUnavailableView(
                    "无法载入统计",
                    systemImage: "chart.bar.xaxis",
                    description: Text(model.errorMessage ?? "请稍后重试。")
                )
            }
        }
        .navigationTitle("学习统计")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .disabled(model.isLoading)
                .accessibilityIdentifier("statistics-insight-refresh")
            }
        }
        .task {
            await model.load()
        }
        .alert(
            "刷新失败",
            isPresented: Binding(
                get: { model.insight != nil && model.errorMessage != nil },
                set: { shown in if !shown { model.errorMessage = nil } }
            )
        ) {
            Button("重试") { Task { await model.load() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var content: some View {
        List {
            Section {
                Picker("趋势范围", selection: $model.range) {
                    ForEach(StatisticsViewModel.TrendRange.allCases) { r in
                        Text(r.title).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("statistics-range-picker")
            } header: {
                Text("趋势范围（按学习日计）")
            }

            retentionSection
            profileSection
            trendSection
            forecastSection
            maturitySection
            weaknessSection
            readerAnalyticsSection
        }
        .refreshable {
            await model.load()
        }
    }

    /// S22：阅读分析入口（数据源未接入时不渲染）。
    @ViewBuilder
    private var readerAnalyticsSection: some View {
        if let readerSource = readerAnalyticsSource {
            Section {
                NavigationLink {
                    ReaderAnalyticsView(
                        source: readerSource,
                        studyMetricsSource: readerStudyMetricsSource)
                } label: {
                    Label("阅读分析", systemImage: "book")
                }
                .accessibilityIdentifier("statistics-reader-analytics-entry")
            } footer: {
                Text("挖词、标知与覆盖率趋势——按阅读域单独聚合。")
            }
        }
    }

    // MARK: - 保持率（三线分离）

    @ViewBuilder
    private var retentionSection: some View {
        Section {
            if let insight = model.insight {
                RetentionMetricRow(
                    title: "目标保持率",
                    valueText: model.targetRetentionText,
                    caption: "调度参数设定的目标",
                    accessibilityID: "statistics-retention-target"
                )
                RetentionMetricRow(
                    title: "实测保持率",
                    valueText: model.actualRetentionText,
                    caption: insight.actualSampleCount > 0
                        ? "样本 \(insight.actualSampleCount) 次"
                        : "暂无合格样本",
                    accessibilityID: "statistics-retention-actual"
                )
                RetentionMetricRow(
                    title: "预测保持率",
                    valueText: model.predictedRecallText,
                    caption: insight.predictableCardCount > 0
                        ? "\(insight.predictableCardCount) 张卡参与预测"
                        : "暂无可预测卡片",
                    accessibilityID: "statistics-retention-predicted"
                )
            }
        } header: {
            Text("保持率")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let actual = model.actualAnnotation {
                    Text(actual)
                }
                if let predicted = model.predictedAnnotation {
                    Text(predicted)
                }
            }
        }
    }

    // MARK: - 按调度方案分组

    @ViewBuilder
    private var profileSection: some View {
        if let insight = model.insight, !insight.profiles.isEmpty {
            Section {
                ForEach(insight.profiles) { slice in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slice.configurationVersion)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 12) {
                            Text("\(slice.cardCount) 张卡")
                            Text("目标 \(model.percentText(slice.targetRetention))")
                            if let predicted = slice.predictedRecall {
                                Text("预测 \(model.percentText(predicted))")
                            } else {
                                Text("无预测")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "statistics-profile-\(slice.profileID.uuidString)"
                    )
                }
            } header: {
                Text("按调度方案")
            } footer: {
                if insight.newCardCount > 0 {
                    Text("另有 \(insight.newCardCount) 张新卡未开始调度，不产生预测。")
                }
            }
        }
    }

    // MARK: - 评分趋势（图表 + 数值明细）

    @ViewBuilder
    private var trendSection: some View {
        Section {
            if model.isSeriesLoading {
                HStack {
                    ProgressView()
                    Text("正在更新…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.series.isEmpty {
                Text("暂无评分记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("statistics-trend-empty")
            } else {
                SuccessRateChart(points: model.series)
                    .frame(height: 160)
                    .accessibilityLabel("评分成功率趋势图")
                    .accessibilityValue(
                        model.seriesChartAccessibilitySummary
                    )
                    .accessibilityIdentifier("statistics-trend-chart")
                Text("窗口内共 \(model.series.count) 个学习日")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("评分趋势")
        } footer: {
            Text("成功率 = 当日自评非「重来」比例；零记录学习日保留在列表中。")
        }

        Section("数值明细") {
            ForEach(model.series) { point in
                VStack(alignment: .leading, spacing: 2) {
                    Text(point.localDate)
                        .font(.subheadline.monospacedDigit())
                    Text(model.seriesPointSummary(point)
                        .replacingOccurrences(
                            of: "\(point.localDate)：", with: ""
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.seriesPointSummary(point))
                .accessibilityIdentifier(
                    "statistics-trend-row-\(point.localDate)"
                )
            }
        }
    }

    // MARK: - 到期预测

    private var forecastSection: some View {
        Section {
            if let forecast = model.forecast {
                if model.displayedForecast.isEmpty {
                    Text("暂无到期预测")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("statistics-forecast-empty")
                } else {
                    ForecastChart(buckets: model.displayedForecast)
                        .frame(height: 140)
                        .accessibilityLabel("到期卡片预测图")
                        .accessibilityValue(
                            model.forecastChartAccessibilitySummary
                        )
                        .accessibilityIdentifier("statistics-forecast-chart")
                    HStack {
                        Text("已过期")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(forecast.overdue) 张")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("statistics-forecast-overdue")
                }
            }
        } header: {
            Text("到期预测")
        } footer: {
            Text(model.forecastAnnotation)
        }
    }

    // MARK: - 成熟度

    @ViewBuilder
    private var maturitySection: some View {
        if let maturity = model.maturity {
            Section("卡片成熟度") {
                MaturityRow(label: "成熟（≥21 天）", value: maturity.mature)
                MaturityRow(label: "年轻复习卡", value: maturity.youngReview)
                MaturityRow(label: "学习中", value: maturity.learning)
                MaturityRow(label: "新卡", value: maturity.newCards)
                MaturityRow(label: "已暂停", value: maturity.suspended)
            }
        }
    }

    // MARK: - 弱项

    @ViewBuilder
    private var weaknessSection: some View {
        if !model.weaknessEntries.isEmpty {
            Section {
                ForEach(model.weaknessEntries, id: \.noteID) { entry in
                    HStack {
                        Text(entry.headword)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(
                            "30 天错 \(entry.againCount30d)/\(entry.totalReviews30d) 次"
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "statistics-weakness-\(entry.noteID.uuidString)"
                    )
                }
            } header: {
                Text("易错项")
            } footer: {
                Text("按近 30 天「重来」次数排序；不足 3 次样本的词不入榜。")
            }
        }
    }
}

// MARK: - 子视图

/// 保持率指标行：标题 + 大数字 + 样本数注脚。valueText 为 "—" 时
/// 表示无数据（语义与 0% 明确区分）。
private struct RetentionMetricRow: View {
    let title: String
    let valueText: String
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
            Text(valueText)
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(valueText == "—" ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct MaturityRow: View {
    let label: String
    let value: Int

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text("\(value)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statistics-maturity-\(label)")
    }
}

/// 逐学习日成功率折线（无评分日跳过——断点处自然留空，
/// 不把无数据日画成 0% 误导读数）。
private struct SuccessRateChart: View {
    let points: [DailyMetricPoint]

    var body: some View {
        Chart(points) { point in
            if let rate = point.successRate {
                LineMark(
                    x: .value("学习日", point.localDate),
                    y: .value("成功率", rate)
                )
                PointMark(
                    x: .value("学习日", point.localDate),
                    y: .value("成功率", rate)
                )
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

/// 到期分桶柱状图（dayOffset → dueCount，offset 0 = 今天学习日）。
private struct ForecastChart: View {
    let buckets: [Int]

    var body: some View {
        Chart(Array(buckets.enumerated()), id: \.offset) { offset, count in
            BarMark(
                x: .value("天", "+\(offset)"),
                y: .value("到期", count)
            )
        }
    }
}
