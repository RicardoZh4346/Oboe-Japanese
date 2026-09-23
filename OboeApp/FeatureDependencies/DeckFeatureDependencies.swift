import Foundation
import OboeDomain
import OboeInfrastructure

/// 牌组 Feature 的窄依赖包。JLPT 词库相关依赖单独打包——词库 bundle
/// 缺失时整个容器构建失败（`.failed`），不再出现根部 Optional 散落。
struct DeckFeatureDependencies {
    let deckService: DeckManagementService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let searchService: KnowledgeSearchService
    let contentCardService: ContentCardService
    let studyService: StudySessionService
    let historyService: StudyHistoryService
    let speechPreferencesService: SpeechPreferencesService
    let adaptivePreferencesService: AdaptivePreferencesService
    let adaptiveCardService: AdaptiveCardService
    let aiRepairService: AIRepairService
    let aiCardGenerationService: AICardGenerationService
    let sentenceAnalysisService: SentenceAnalysisService
    let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    let jlpt: JLPTFeatureDependencies
}

/// 内置 JLPT 词库一组依赖：进度、词库查询、导入器。
struct JLPTFeatureDependencies {
    let progressService: JLPTProgressService
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
}
