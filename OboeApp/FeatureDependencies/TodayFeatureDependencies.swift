import Foundation
import OboeDomain
import OboeInfrastructure

/// 今日页所需的窄依赖包。`processingServices` 在容器构建时一次装好，
/// 根组合不再逐项传递十余个服务。
struct TodayFeatureDependencies {
    let studyService: StudySessionService
    let historyService: StudyHistoryService
    let deckService: DeckManagementService
    let speechPreferencesService: SpeechPreferencesService
    let adaptiveCardService: AdaptiveCardService
    let adaptivePreferencesService: AdaptivePreferencesService
    let aiRepairService: AIRepairService
    let inboxService: InboxService
    let processingServices: InboxProcessingServices
    /// S21：统计页数据源（保持率三线/趋势/预测）。nil 时首页不挂
    /// 「学习统计」入口——便于增量接入，不接源即不呈现。
    var statisticsSource: (any StatisticsInsightFetching)? = nil
    /// S22：阅读分析页数据源（事件流/知识态/版本分段覆盖率）。
    /// nil 时统计页不显示「阅读分析」入口。
    var readerAnalyticsSource: (any ReaderAnalyticsFetching)? = nil
    /// v0.7.5 S20：阅读学习数据源（漏斗 + Coverage v2）。
    /// nil 时阅读分析页不渲染「阅读学习」区块。
    var readerStudyMetricsSource: (any ReaderStudyMetricsFetching)? = nil
}
