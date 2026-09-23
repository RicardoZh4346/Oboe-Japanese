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
}
