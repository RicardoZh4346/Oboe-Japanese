import Foundation
import OboeDomain
import OboeInfrastructure

/// v0.7.5 S20「阅读学习」统计数据源——VM 只依赖这条窄协议，
/// 测试用桩件。生产实现 `AppReaderStudyMetricsSource` 是
/// `GRDBReaderStudyMetricsRepository` 的薄适配（同 S21/S22 模式）。
///
/// 口径纪律：漏斗与活算投影是**当前态**（当前 content_revision +
/// 最新 selection revision + 活算 Coverage v2）；快照趋势是**历史
/// 留痕**（v26 落库行，按版本三元组分段）。两口径在 UI 分开标注，
/// 绝不混为一条累计线——旧 `coverage-1.0.0` 趋势仍由
/// `ReaderAnalyticsFetching.coverageTrend` 提供，与 v2 段互相独立、
/// 永不连线。
protocol ReaderStudyMetricsFetching: Sendable {
    /// Reader→学习项转化漏斗（当前态口径）。
    func funnel(documentID: UUID) async throws -> ReaderStudyFunnel
    /// Coverage v2 活算投影（当前态，不落库）。文档不存在/已删 → nil。
    func liveCoverage(documentID: UUID) async throws
        -> GRDBReaderCoverageSnapshotStore.DocumentCoverageProjection?
    /// v26 快照历史——版本三元组连续 run 分段（跨版本不连线，
    /// 已删文档按 document_id_snapshot 追溯）。
    func coverageTrend(documentID: UUID) async throws
        -> [ReaderStudyCoverageSegment]
}

/// S20 阅读学习生产数据源：`GRDBReaderStudyMetricsRepository` 的
/// 薄适配。装配（factory 在容器构建时构造）：
/// ```swift
/// AppReaderStudyMetricsSource(
///     repository: GRDBReaderStudyMetricsRepository(database: database)
/// )
/// ```
struct AppReaderStudyMetricsSource: ReaderStudyMetricsFetching {
    let repository: GRDBReaderStudyMetricsRepository

    func funnel(documentID: UUID) async throws -> ReaderStudyFunnel {
        try await repository.funnel(documentID: documentID)
    }

    func liveCoverage(documentID: UUID) async throws
        -> GRDBReaderCoverageSnapshotStore.DocumentCoverageProjection? {
        try await repository.liveCoverage(documentID: documentID)
    }

    func coverageTrend(documentID: UUID) async throws
        -> [ReaderStudyCoverageSegment] {
        try await repository.coverageTrend(documentID: documentID)
    }
}
