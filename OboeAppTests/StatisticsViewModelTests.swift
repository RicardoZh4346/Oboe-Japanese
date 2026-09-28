import Foundation
import OboeDomain
import XCTest
@testable import Oboe

/// S21 `StatisticsViewModel` 语义测试：三线分离文案、范围切换只重拉
/// 序列（且过期响应被世代号丢弃）、forecast 分桶选择、new card 注释、
/// 无数据态、图表 AX 摘要与数值明细文本。
@MainActor
final class StatisticsViewModelTests: XCTestCase {

    private func makeStudyDay() -> StudyDay {
        StudyDay(
            id: UUID(),
            localDate: "2026-09-15",
            timeZoneID: "Asia/Shanghai",
            startsAt: Date(timeIntervalSince1970: 1_789_948_800),
            endsAt: Date(timeIntervalSince1970: 1_790_035_200),
            newCardLimit: 10
        )
    }

    private func makeInsight(
        newCardCount: Int = 3,
        sampleCount: Int = 12,
        actual: Double? = 0.83,
        predicted: Double? = 0.91,
        profiles: [ProfileRetentionSlice] = []
    ) -> RetentionInsight {
        RetentionInsight(
            targetRetention: 0.9,
            actualSampleCount: sampleCount,
            actualRetention: actual,
            predictedRecall: predicted,
            profiles: profiles,
            totalEnabledNonNewCardCount: 42,
            newCardCount: newCardCount
        )
    }

    private func makePoints(_ count: Int) -> [DailyMetricPoint] {
        (0..<count).map { index in
            DailyMetricPoint(
                studyDayID: "day-\(index)",
                localDate: "2026-09-\(String(format: "%02d", index + 1))",
                effectiveRatingCount: index == 0 ? 0 : 10 + index,
                passCount: index == 0 ? 0 : 8 + index,
                newLearnedCount: index == 0 ? 0 : 2,
                averageDurationMilliseconds: index == 0 ? nil : 900
            )
        }
    }

    // MARK: - 载入

    func testLoadPopulatesAllSections() async {
        let source = StubStatisticsInsightSource()
        await source.setInsight(makeInsight())
        await source.setSeries(makePoints(30))
        await source.setForecast(
            ForecastStats(
                next7Days: [1, 2, 3, 0, 0, 5, 6],
                next30Days: Array(repeating: 2, count: 30),
                overdue: 4
            )
        )
        await source.setMaturity(
            CardMaturityStats(
                mature: 10, youngReview: 20, learning: 3,
                suspended: 1, newCards: 8
            )
        )
        await source.setWeakness([
            WeaknessEntry(
                noteID: UUID(), headword: "難しい",
                againCount30d: 5, totalReviews30d: 9
            )
        ])
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(), source: source
        )

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.insight?.targetRetention, 0.9)
        XCTAssertEqual(model.series.count, 30)
        XCTAssertEqual(model.forecast?.overdue, 4)
        XCTAssertEqual(model.maturity?.mature, 10)
        XCTAssertEqual(model.weaknessEntries.count, 1)
        // 默认 30 学习日窗口。
        let requests = await source.dailyMetricsRequests
        XCTAssertEqual(requests.map(\.dayCount), [30])
    }

    func testLoadFailureSurfacesErrorAndKeepsEmptyState() async {
        let source = StubStatisticsInsightSource()
        await source.setFailure(TestError.boom)
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(), source: source
        )

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.insight)
        XCTAssertTrue(model.series.isEmpty)
    }

    // MARK: - 范围切换

    func testRangeSwitchReloadsSeriesOnly() async {
        let source = StubStatisticsInsightSource()
        await source.setInsight(makeInsight())
        await source.setSeries(makePoints(30))
        await source.setForecast(ForecastStats(
            next7Days: [Int](repeating: 1, count: 7),
            next30Days: [Int](repeating: 1, count: 30),
            overdue: 0
        ))
        await source.setMaturity(CardMaturityStats(
            mature: 0, youngReview: 0, learning: 0, suspended: 0, newCards: 0
        ))
        await source.setWeakness([])
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(), source: source
        )
        await model.load()

        let insightCallsBefore = await source.insightCallCount
        await source.setSeries(makePoints(7))
        model.range = .seven
        // didSet 里调度的是 Task——直接等序列落地。
        while model.isSeriesLoading || model.series.count != 7 {
            await Task.yield()
        }

        XCTAssertEqual(model.series.count, 7)
        // 保持率/预测不重拉——范围与它们无关。
        let insightCallsAfter = await source.insightCallCount
        XCTAssertEqual(insightCallsAfter, insightCallsBefore)
        let requests = await source.dailyMetricsRequests
        XCTAssertEqual(requests.map(\.dayCount), [30, 7])
    }

    func testStaleSeriesResponseIsDiscarded() async {
        let source = StubStatisticsInsightSource()
        await source.setInsight(makeInsight())
        await source.setSeries(makePoints(30))
        await source.setForecast(ForecastStats(
            next7Days: [], next30Days: [], overdue: 0
        ))
        await source.setMaturity(CardMaturityStats(
            mature: 0, youngReview: 0, learning: 0, suspended: 0, newCards: 0
        ))
        await source.setWeakness([])
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(), source: source
        )
        await model.load()

        // 闸门关闭后切 7：请求已记录并锁定「7 点」结果但被挂起；
        // 再切 90 记录第三请求；放闸后旧响应必须被世代号丢弃——
        // 最终序列只反映 .ninety 的 90 点响应，与回放顺序无关。
        await source.setSeries(makePoints(7))
        await source.setDailyMetricsGate(true)
        model.range = .seven
        while await source.dailyMetricsRequests.count < 2 {
            await Task.yield()
        }
        await source.setSeries(makePoints(90))
        model.range = .ninety
        while await source.dailyMetricsRequests.count < 3 {
            await Task.yield()
        }
        await source.openDailyMetricsGate()
        while model.isSeriesLoading || model.series.count != 90 {
            await Task.yield()
        }
        XCTAssertEqual(model.series.count, 90)
        XCTAssertEqual(model.range, .ninety)
    }

    // MARK: - 展示语义

    func testForecastBucketsFollowRange() async {
        let source = StubStatisticsInsightSource()
        await source.setInsight(makeInsight())
        await source.setSeries(makePoints(30))
        await source.setForecast(ForecastStats(
            next7Days: [Int](repeating: 1, count: 7),
            next30Days: [Int](repeating: 2, count: 30),
            overdue: 3
        ))
        await source.setMaturity(CardMaturityStats(
            mature: 0, youngReview: 0, learning: 0, suspended: 0, newCards: 0
        ))
        await source.setWeakness([])
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(), source: source
        )
        await model.load()

        model.range = .seven
        XCTAssertEqual(model.displayedForecast.count, 7)
        XCTAssertEqual(model.forecastCoverageDays, 7)
        XCTAssertFalse(model.forecastAnnotation.contains("30 天分桶"))

        model.range = .ninety
        XCTAssertEqual(model.displayedForecast.count, 30)
        XCTAssertEqual(model.forecastCoverageDays, 30)
        XCTAssertTrue(model.forecastAnnotation.contains("30 天分桶"))
        XCTAssertTrue(model.forecastAnnotation.contains("FSRS-6"))
        // new card 豁免注释。
        XCTAssertTrue(
            model.predictedAnnotation?.contains("3 张新卡暂无预测") == true
        )
    }

    func testNoDataRenderingNeverFakesZero() async {
        let source = StubStatisticsInsightSource()
        await source.setInsight(makeInsight(
            newCardCount: 0, sampleCount: 0, actual: nil, predicted: nil
        ))
        await source.setSeries([])
        await source.setForecast(ForecastStats(
            next7Days: [], next30Days: [], overdue: 0
        ))
        await source.setMaturity(CardMaturityStats(
            mature: 0, youngReview: 0, learning: 0, suspended: 0, newCards: 0
        ))
        await source.setWeakness([])
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(), source: source
        )
        await model.load()

        // nil → 「—」而不是 0%。
        XCTAssertEqual(model.actualRetentionText, "—")
        XCTAssertEqual(model.predictedRecallText, "—")
        XCTAssertEqual(model.targetRetentionText, "90%")
        XCTAssertEqual(
            model.actualAnnotation,
            "近 30 个学习日没有符合口径的长期复习样本（需距上次复习 ≥1 天）。"
        )
        XCTAssertTrue(model.displayedForecast.isEmpty)
        XCTAssertTrue(
            model.forecastChartAccessibilitySummary.contains("0 张")
        )
    }

    func testSeriesSummariesForAccessibility() async {
        let model = StatisticsViewModel(
            studyDay: makeStudyDay(),
            source: StubStatisticsInsightSource()
        )
        model.series = [
            DailyMetricPoint(
                studyDayID: "d0", localDate: "2026-09-14",
                effectiveRatingCount: 0, passCount: 0,
                newLearnedCount: 0, averageDurationMilliseconds: nil
            ),
            DailyMetricPoint(
                studyDayID: "d1", localDate: "2026-09-15",
                effectiveRatingCount: 10, passCount: 8,
                newLearnedCount: 3, averageDurationMilliseconds: 800
            )
        ]

        XCTAssertEqual(
            model.seriesPointSummary(model.series[0]),
            "2026-09-14：未学习"
        )
        XCTAssertEqual(
            model.seriesPointSummary(model.series[1]),
            "2026-09-15：评分 10 次，通过 8 次，成功率 80%，新学 3"
        )
        XCTAssertEqual(
            model.seriesChartAccessibilitySummary,
            "近 30 天评分趋势，共 10 次有效评分，平均成功率 80%"
        )
    }
}

// MARK: - 桩件

private enum TestError: Error {
    case boom
}

/// `StatisticsInsightFetching` 桩件：结果可换、dailyMetrics 记录请求
/// 序列、可选闸门延迟响应以复现「过期响应丢弃」。
private actor StubStatisticsInsightSource: StatisticsInsightFetching {
    private var insightResult: Result<RetentionInsight, Error> = .failure(
        TestError.boom
    )
    private var seriesResult: Result<[DailyMetricPoint], Error> =
        .success([])
    private var forecastResult: Result<ForecastStats, Error> =
        .failure(TestError.boom)
    private var maturityResult: Result<CardMaturityStats, Error> =
        .failure(TestError.boom)
    private var weaknessResult: Result<[WeaknessEntry], Error> =
        .success([])

    private(set) var dailyMetricsRequests:
        [(studyDayID: String, dayCount: Int)] = []
    private(set) var insightCallCount = 0
    private var gateDailyMetrics = false
    private var gateContinuations: [CheckedContinuation<Void, Never>] = []

    func setInsight(_ value: RetentionInsight) {
        insightResult = .success(value)
    }
    func setSeries(_ value: [DailyMetricPoint]) {
        seriesResult = .success(value)
    }
    func setForecast(_ value: ForecastStats) {
        forecastResult = .success(value)
    }
    func setMaturity(_ value: CardMaturityStats) {
        maturityResult = .success(value)
    }
    func setWeakness(_ value: [WeaknessEntry]) {
        weaknessResult = .success(value)
    }
    func setFailure(_ error: Error) {
        insightResult = .failure(error)
        seriesResult = .failure(error)
        forecastResult = .failure(error)
        maturityResult = .failure(error)
        weaknessResult = .failure(error)
    }
    func setDailyMetricsGate(_ closed: Bool) {
        gateDailyMetrics = closed
    }
    /// 放出所有等在闸门上的请求（此时按最新 seriesResult 应答）。
    func openDailyMetricsGate() {
        gateDailyMetrics = false
        let pending = gateContinuations
        gateContinuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func retentionInsight(
        asOf date: Date
    ) async throws -> RetentionInsight {
        insightCallCount += 1
        return try insightResult.get()
    }

    func dailyMetrics(
        endingAtStudyDayID: String,
        dayCount: Int
    ) async throws -> [DailyMetricPoint] {
        dailyMetricsRequests.append((endingAtStudyDayID, dayCount))
        // 结果在进入时锁定：闸门拖延的是「送达」不是「取值」，
        // 测试才能区分「过期响应被丢弃」与「恰好取到新值」。
        let result = seriesResult
        if gateDailyMetrics {
            await withCheckedContinuation { c in
                gateContinuations.append(c)
            }
        }
        return try result.get()
    }

    func forecast(
        fromStudyDayID: String
    ) async throws -> ForecastStats {
        try forecastResult.get()
    }

    func cardMaturity() async throws -> CardMaturityStats {
        try maturityResult.get()
    }

    func weakness(limit: Int) async throws -> [WeaknessEntry] {
        try weaknessResult.get()
    }
}
