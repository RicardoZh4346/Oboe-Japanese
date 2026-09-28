import Foundation
import Observation
import OboeDomain

/// v0.7.0 S21：统计页数据源——VM 只依赖这条窄协议，测试用桩件。
/// 生产实现见 `AppStatisticsInsightSource`（GRDBRetentionInsightRepository
/// + StatisticsRepository 的组合适配）。
protocol StatisticsInsightFetching: Sendable {
    func retentionInsight(asOf date: Date) async throws -> RetentionInsight
    func dailyMetrics(
        endingAtStudyDayID: String,
        dayCount: Int
    ) async throws -> [DailyMetricPoint]
    func forecast(fromStudyDayID: String) async throws -> ForecastStats
    func cardMaturity() async throws -> CardMaturityStats
    func weakness(limit: Int) async throws -> [WeaknessEntry]
}

/// S21 统计页视图模型：保持率三线分离（目标/实测/预测）、评分趋势
/// （7/30/90 学习日切换）、到期预测、成熟度与弱项。
///
/// 展示纪律：
/// - 「无数据」一律以 nil→「—」/「暂无数据」呈现，绝不显示 0% 假象；
///   new card 不进预测分母（`RetentionInsight.newCardCount` 只作注释）。
/// - 预测数值旁必须挂 `forecastAnnotation`——「按当前 FSRS-6 参数估计」，
///   参数一改预测就变，不是历史事实。
/// - 实测口径沿用 S20：30 学习日窗口 + prev.state=review + 间隔 ≥1 日；
///   同日/小时级重评与 practice 事件天然不计入（样本数如实显示）。
/// - 趋势图窗口 = 最近 N 个**已落库学习日**（不开 App 的日子不占格）；
///   标签写「近 N 天」沿用产品语言，口径以数值明细表为准。
@MainActor
@Observable
final class StatisticsViewModel {
    /// 趋势范围切换：契约与 UI 约定 7/30/90。
    enum TrendRange: Int, CaseIterable, Identifiable, Sendable {
        case seven = 7
        case thirty = 30
        case ninety = 90

        var id: Int { rawValue }
        var title: String { "近 \(rawValue) 天" }
        var dayCount: Int { rawValue }
        var accessibilityLabel: String {
            "趋势范围 \(rawValue) 个学习日"
        }
    }

    /// 弱项条数上限（S20 `WeaknessEntry.minimumSampleCount` 已在查询层
    /// 保证 ≥3 样本，这里只截展示量）。
    static let weaknessDisplayLimit = 5

    private let studyDay: StudyDay
    private let source: any StatisticsInsightFetching
    private let clock: @Sendable () -> Date
    /// 切范围时丢弃过期响应（同 DictionarySearchViewModel 的世代模式）。
    private var seriesGeneration = 0

    var range: TrendRange = .thirty {
        didSet {
            guard range != oldValue else { return }
            scheduleSeriesReload()
        }
    }
    var insight: RetentionInsight?
    var series: [DailyMetricPoint] = []
    var forecast: ForecastStats?
    var maturity: CardMaturityStats?
    var weaknessEntries: [WeaknessEntry] = []
    var isLoading = true
    var isSeriesLoading = false
    var errorMessage: String?

    init(
        studyDay: StudyDay,
        source: any StatisticsInsightFetching,
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.studyDay = studyDay
        self.source = source
        self.clock = clock
    }

    // MARK: - 载入

    /// 全量刷新：明细 + 预测 + 成熟度 + 弱项 + 当前范围趋势序列。
    /// 各支路并发；失败整体收敛为 errorMessage（幂等重试由视图触发）。
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let insightTask = source.retentionInsight(asOf: clock())
            async let forecastTask = source.forecast(
                fromStudyDayID: studyDay.id.uuidString
            )
            async let maturityTask = source.cardMaturity()
            async let weaknessTask = source.weakness(
                limit: Self.weaknessDisplayLimit
            )
            let points = try await source.dailyMetrics(
                endingAtStudyDayID: studyDay.id.uuidString,
                dayCount: range.dayCount
            )
            series = points
            insight = try await insightTask
            forecast = try await forecastTask
            maturity = try await maturityTask
            weaknessEntries = try await weaknessTask
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 范围切换只重拉趋势序列（保持率/预测与窗口无关，不重复查询）。
    private func scheduleSeriesReload() {
        seriesGeneration += 1
        let generation = seriesGeneration
        isSeriesLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let points = try await self.source.dailyMetrics(
                    endingAtStudyDayID: self.studyDay.id.uuidString,
                    dayCount: self.range.dayCount
                )
                guard generation == self.seriesGeneration else { return }
                self.series = points
                self.errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.seriesGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
            if generation == self.seriesGeneration {
                self.isSeriesLoading = false
            }
        }
    }

    // MARK: - 展示语义（可测的纯映射）

    /// 到期预测的可见分桶：7 天档用契约 7 桶；30/90 天档契约上限即
    /// 30 桶（没有更长窗口），图注如实声明截断。
    var displayedForecast: [Int] {
        guard let forecast else { return [] }
        return range == .seven ? forecast.next7Days : forecast.next30Days
    }

    /// 当前档下 forecast 实际覆盖的天数（90 档也只有 30——契约上限）。
    var forecastCoverageDays: Int {
        displayedForecast.count
    }

    /// forecast 注释（验收项）：按当前到期时间 + 当前 FSRS-6 参数
    /// 估计；90 档额外声明窗口截断。
    var forecastAnnotation: String {
        var text = "按当前到期时间估计，不含新卡；预测基于当前 FSRS-6 参数。"
        if range == .ninety, forecast != nil {
            text += "当前仅提供未来 30 天分桶。"
        }
        return text
    }

    /// 保持率卡片的预测脚注：锁定算法版本 + new card 豁免说明。
    var predictedAnnotation: String? {
        guard let insight else { return nil }
        var text = "预测基于当前 FSRS-6 调度参数（锁定算法版本）"
        if insight.newCardCount > 0 {
            text += "；\(insight.newCardCount) 张新卡暂无预测"
        }
        return text + "。"
    }

    /// 实测脚注：口径一句话 + 样本数。
    var actualAnnotation: String? {
        guard let insight else { return nil }
        if insight.actualSampleCount == 0 {
            return "近 30 个学习日没有符合口径的长期复习样本（需距上次复习 ≥1 天）。"
        }
        return "近 30 个学习日共 \(insight.actualSampleCount) 次长期复习样本（同日重练不计入）。"
    }

    // MARK: - 格式化（集中在此便于 VM 测试断言）

    func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int((value * 100).rounded()))%"
    }

    var targetRetentionText: String {
        percentText(insight?.targetRetention)
    }

    var actualRetentionText: String {
        percentText(insight?.actualRetention)
    }

    var predictedRecallText: String {
        percentText(insight?.predictedRecall)
    }

    /// 单点数值明细行文本（等价于图表读数，供 VoiceOver 与表格共用）。
    func seriesPointSummary(_ point: DailyMetricPoint) -> String {
        if point.effectiveRatingCount == 0 {
            return "\(point.localDate)：未学习"
        }
        var text = "\(point.localDate)：评分 \(point.effectiveRatingCount) 次"
        text += "，通过 \(point.passCount) 次"
        if let rate = point.successRate {
            text += "，成功率 \(percentText(rate))"
        }
        if point.newLearnedCount > 0 {
            text += "，新学 \(point.newLearnedCount)"
        }
        return text
    }

    /// 图表整体 AX 摘要：范围 + 合计评分 + 平均成功率。
    var seriesChartAccessibilitySummary: String {
        let rated = series.reduce(0) { $0 + $1.effectiveRatingCount }
        let passed = series.reduce(0) { $0 + $1.passCount }
        var text = "\(range.title)评分趋势，共 \(rated) 次有效评分"
        if rated > 0 {
            text += "，平均成功率 \(percentText(Double(passed) / Double(rated)))"
        }
        return text
    }

    /// 预测图表 AX 摘要。
    var forecastChartAccessibilitySummary: String {
        guard let forecast else { return "暂无到期预测" }
        let total = displayedForecast.reduce(0, +)
        return "未来 \(displayedForecast.count) 天共有 \(total) 张卡到期，另有过期 \(forecast.overdue) 张"
    }
}
