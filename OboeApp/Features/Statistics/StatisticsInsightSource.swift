import Foundation
import OboeDomain
import OboeInfrastructure

/// S21 统计页生产数据源：`GRDBRetentionInsightRepository`（分组明细 +
/// 逐日序列，S21 增量）与 S20 `StatisticsRepository`（预测/成熟度/弱项）
/// 的薄适配——把两个只读查询面合成 VM 依赖的单一协议。
///
/// 装配（主进程负责接进 Xcode 工程后在 factory 中构造）：
/// ```swift
/// AppStatisticsInsightSource(
///     statistics: GRDBStatisticsRepository(database: database),
///     insights: GRDBRetentionInsightRepository(database: database)
/// )
/// ```
struct AppStatisticsInsightSource: StatisticsInsightFetching {
    let statistics: any StatisticsRepository
    let insights: GRDBRetentionInsightRepository

    func retentionInsight(asOf date: Date) async throws -> RetentionInsight {
        try await insights.retentionInsight(asOf: date)
    }

    func dailyMetrics(
        endingAtStudyDayID: String,
        dayCount: Int
    ) async throws -> [DailyMetricPoint] {
        try await insights.dailyMetrics(
            endingAtStudyDayID: endingAtStudyDayID,
            dayCount: dayCount
        )
    }

    func forecast(fromStudyDayID: String) async throws -> ForecastStats {
        try await statistics.forecast(fromStudyDayID: fromStudyDayID)
    }

    func cardMaturity() async throws -> CardMaturityStats {
        try await statistics.cardMaturity()
    }

    func weakness(limit: Int) async throws -> [WeaknessEntry] {
        try await statistics.weakness(limit: limit)
    }
}
