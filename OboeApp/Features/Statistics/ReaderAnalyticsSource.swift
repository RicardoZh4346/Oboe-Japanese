import Foundation
import OboeDomain
import OboeInfrastructure

/// S22 阅读分析生产数据源：`GRDBReaderAnalyticsRepository` 的薄适配，
/// 与 S21 `AppStatisticsInsightSource` 同构。
///
/// 装配（主进程负责接进 Xcode 工程后在 factory 中构造）：
/// ```swift
/// AppReaderAnalyticsSource(
///     repository: GRDBReaderAnalyticsRepository(database: database)
/// )
/// ```
struct AppReaderAnalyticsSource: ReaderAnalyticsFetching {
    let repository: GRDBReaderAnalyticsRepository

    func activityTotals() async throws -> ReaderActivityTotals {
        try await repository.activityTotals()
    }

    func dailyActivity(
        dayCount: Int
    ) async throws -> [ReaderActivityDayPoint] {
        try await repository.dailyActivity(dayCount: dayCount)
    }

    func knowledgeSummary() async throws -> ReaderKnowledgeSummary {
        try await repository.knowledgeSummary()
    }

    func documentSummaries(
        limit: Int
    ) async throws -> [ReaderDocumentSummary] {
        try await repository.documentSummaries(limit: limit)
    }

    func coverageTrend(
        documentID: UUID
    ) async throws -> [ReaderCoverageTrendSegment] {
        try await repository.coverageTrend(documentID: documentID)
    }

    func activityTimeline(
        limit: Int
    ) async throws -> [ReaderTimelineEntry] {
        try await repository.activityTimeline(limit: limit)
    }
}
