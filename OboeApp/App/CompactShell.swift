import OboeDomain
import OboeInfrastructure
import SwiftUI

private enum PrimaryTab: Hashable {
    case today
    case decks
    case reader

    /// compact 三 Tab 与 scene `AppSection` 的双向映射：inbox/
    /// settings 在 compact 没有独立 Tab——落到今日（Inbox 挂
    /// 今日页内、设置走 sheet）。
    init(section: AppSection) {
        switch section {
        case .decks: self = .decks
        case .reader: self = .reader
        case .today, .inbox, .settings: self = .today
        }
    }

    var section: AppSection {
        switch self {
        case .today: .today
        case .decks: .decks
        case .reader: .reader
        }
    }
}

/// compact 壳层：三 Tab `TabView`（今日 + 牌组 + 阅读）。v0.5.8 起设置收进
/// 今日页右上角齿轮，以 sheet 呈现。只在 `.ready` 分支出现——服务依赖
/// 从 `AppFeatureContainer` 整体取到，不再有逐个 Optional 展开。
struct CompactShell: View {
    let container: AppFeatureContainer
    let operations: AppRuntimeOperations
    let jlptEnrichmentStatus: JLPTEnrichmentStatus
    let pendingContinueItemID: UUID?
    let sharedCapturesAwaitingImport: Int?
    let isDatabaseOperationInProgress: Bool

    /// S18：Tab 选择改由 scene 导航状态驱动——`openDeck`/
    /// `openReaderDocument` 跨区路由的「切 Tab」就是写它。
    @Environment(SceneNavigationState.self) private var navigation
    @State private var isSettingsPresented = false

    var body: some View {
        // `.tabBarOnly` 需要 iOS 18；iOS 17 下回退为系统默认样式
        // （iPad 常规宽度可能呈现 sidebarAdaptable，功能等价）。
        if #available(iOS 26.0, *) {
            // iOS 26+ 的悬浮 Tab Bar 默认「滚动时自动最小化」——二级
            // 页内滚动把它收起后，pop 回一级页时 bar 走最小化的恢复
            // 路径而不是转场动画，表现为晚到 + 内容上跳（真机实测）。
            // 关闭最小化：bar 显隐只由二级页的 hidesBottomBarWhenPushed
            // 驱动，push/pop 双侧都随转场同步。
            tabContent
                .tabViewStyle(.tabBarOnly)
                .tabBarMinimizeBehavior(.never)
        } else if #available(iOS 18.0, *) {
            tabContent
                .tabViewStyle(.tabBarOnly)
        } else {
            tabContent
        }
    }

    private var tabContent: some View {
        let today = container.today
        let decks = container.decks
        let tabSelection = Binding<PrimaryTab>(
            get: { PrimaryTab(section: navigation.section) },
            set: { navigation.selectTab($0.section) }
        )
        return TabView(selection: tabSelection) {
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
                sourceContextRepository: container.shared.sourceContextRepository,
                customStudyRepository: container.shared.customStudyRepository,
                customStudyService: container.shared.customStudyService,
                ocrService: container.shared.ocrService,
                drainSharedCaptures: operations.drainSharedCaptures,
                pendingContinueItemID: pendingContinueItemID,
                clearPendingContinueItem: {
                    Task { await operations.clearPendingContinueItem() }
                },
                sharedCapturesAwaitingImport: sharedCapturesAwaitingImport,
                importAwaitingSharedCaptures: operations.importAwaitingSharedCaptures,
                openSettings: { isSettingsPresented = true },
                statisticsSource: today.statisticsSource,
                readerAnalyticsSource: today.readerAnalyticsSource,
                readerStudyMetricsSource: today.readerStudyMetricsSource,
                learningProgress: container.shared.learningProgress
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
                sentenceAnalysisCardCreationService: decks.sentenceAnalysisCardCreationService,
                dictionaryQueryService: container.dictionary.queryService,
                sourceContextRepository: container.shared.sourceContextRepository,
                clozeRepository: container.shared.clozeRepository,
                inboxImageStore: container.shared.inboxImageStore,
                customStudyRepository: container.shared.customStudyRepository,
                customStudyService: container.shared.customStudyService,
                learningProgress: container.shared.learningProgress,
                studyDecks: container.shared.studyDecks,
                externalPath: Binding(
                    get: { navigation.decksPath },
                    set: { navigation.decksPath = $0 }
                ),
                onOpenDocument: { documentID in
                    navigation.openReaderDocument(documentID)
                }
            )
                .id(container.generation)
                .tabItem {
                    Label("牌组", systemImage: "rectangle.stack")
                }
                .tag(PrimaryTab.decks)

            ReaderRootView(
                dependencies: container.readerWithEditorFactory,
                navigation: navigation
            )
                .id(container.generation)
                .tabItem {
                    Label("阅读", systemImage: "book")
                }
                .tag(PrimaryTab.reader)
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
