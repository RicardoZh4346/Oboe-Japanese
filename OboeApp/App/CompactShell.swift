import OboeDomain
import OboeInfrastructure
import SwiftUI

private enum PrimaryTab: Hashable {
    case today
    case decks
}

/// compact 壳层：两 Tab `TabView`（今日 + 牌组）。v0.5.8 起设置收进
/// 今日页右上角齿轮，以 sheet 呈现。只在 `.ready` 分支出现——服务依赖
/// 从 `AppFeatureContainer` 整体取到，不再有逐个 Optional 展开。
struct CompactShell: View {
    let container: AppFeatureContainer
    let operations: AppRuntimeOperations
    let jlptEnrichmentStatus: JLPTEnrichmentStatus
    let pendingContinueItemID: UUID?
    let sharedCapturesAwaitingImport: Int?
    let isDatabaseOperationInProgress: Bool

    @State private var selectedTab = PrimaryTab.today
    @State private var isSettingsPresented = false

    var body: some View {
        // `.tabBarOnly` 需要 iOS 18；iOS 17 下回退为系统默认样式
        // （iPad 常规宽度可能呈现 sidebarAdaptable，功能等价）。
        if #available(iOS 18.0, *) {
            tabContent
                .tabViewStyle(.tabBarOnly)
        } else {
            tabContent
        }
    }

    private var tabContent: some View {
        let today = container.today
        let decks = container.decks
        return TabView(selection: $selectedTab) {
            TodayView(
                studyService: today.studyService,
                historyService: today.historyService,
                deckService: today.deckService,
                speechPreferencesService: today.speechPreferencesService,
                adaptiveCardService: today.adaptiveCardService,
                adaptivePreferencesService: today.adaptivePreferencesService,
                aiRepairService: today.aiRepairService,
                speechService: container.shared.speechService,
                inboxService: today.inboxService,
                processingServices: today.processingServices,
                inboxImageStore: container.shared.inboxImageStore,
                ocrService: container.shared.ocrService,
                drainSharedCaptures: operations.drainSharedCaptures,
                pendingContinueItemID: pendingContinueItemID,
                clearPendingContinueItem: {
                    Task { await operations.clearPendingContinueItem() }
                },
                sharedCapturesAwaitingImport: sharedCapturesAwaitingImport,
                importAwaitingSharedCaptures: operations.importAwaitingSharedCaptures,
                openSettings: { isSettingsPresented = true }
            )
                .id(container.generation)
                .tabItem {
                    Label("今日", systemImage: "sun.max")
                }
                .tag(PrimaryTab.today)

            DecksView(
                service: decks.deckService,
                vocabularyService: decks.vocabularyService,
                grammarService: decks.grammarService,
                knowledgePointService: decks.knowledgePointService,
                searchService: decks.searchService,
                contentCardService: decks.contentCardService,
                studyService: decks.studyService,
                historyService: decks.historyService,
                speechPreferencesService: decks.speechPreferencesService,
                adaptivePreferencesService: decks.adaptivePreferencesService,
                speechService: container.shared.speechService,
                jlptProgressService: decks.jlpt.progressService,
                jlptLibraryService: decks.jlpt.libraryService,
                jlptImporter: decks.jlpt.importer,
                jlptEnrichmentStatus: jlptEnrichmentStatus,
                scheduleJLPTEnrichment: operations.scheduleJLPTEnrichment,
                adaptiveCardService: decks.adaptiveCardService,
                aiRepairService: decks.aiRepairService,
                aiCardGenerationService: decks.aiCardGenerationService,
                sentenceAnalysisService: decks.sentenceAnalysisService,
                sentenceAnalysisCardCreationService: decks.sentenceAnalysisCardCreationService
            )
                .id(container.generation)
                .tabItem {
                    Label("牌组", systemImage: "rectangle.stack")
                }
                .tag(PrimaryTab.decks)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(
                dependencies: container.settings,
                operations: operations,
                isDatabaseOperationInProgress: isDatabaseOperationInProgress,
                dismissAction: { isSettingsPresented = false }
            )
            .id(container.generation)
        }
    }
}
