import OboeDomain
import OboeInfrastructure
import SwiftUI

private enum PrimaryTab: Hashable {
    case today
    case decks
    case settings
}

struct RootTabView: View {
    let dependencies: AppDependencies
    @State private var selectedTab = PrimaryTab.today

    var body: some View {
        Group {
            if !dependencies.isLoading,
               let deckManagementService = dependencies.deckManagementService,
               let vocabularyService = dependencies.vocabularyService,
               let grammarService = dependencies.grammarService,
               let knowledgePointService = dependencies.knowledgePointService,
               let knowledgeSearchService = dependencies.knowledgeSearchService,
               let contentCardService = dependencies.contentCardService,
               let studySessionService = dependencies.studySessionService,
               let studyHistoryService = dependencies.studyHistoryService,
               let speechPreferencesService = dependencies.speechPreferencesService,
               let adaptiveCardService = dependencies.adaptiveCardService,
               let adaptivePreferencesService = dependencies.adaptivePreferencesService,
               let aiConfigurationService = dependencies.aiConfigurationService,
               let aiConnectionTestService = dependencies.aiConnectionTestService,
               let aiModelCatalogService = dependencies.aiModelCatalogService,
               let aiCardGenerationService = dependencies.aiCardGenerationService,
               let sentenceAnalysisService = dependencies.sentenceAnalysisService,
               let sentenceAnalysisCardCreationService = dependencies.sentenceAnalysisCardCreationService,
               let aiRepairService = dependencies.aiRepairService,
               let jlptProgressService = dependencies.jlptProgressService,
               let jlptLibraryService = dependencies.jlptLibraryService,
               let jlptImporter = dependencies.jlptImporter,
               let inboxService = dependencies.inboxService,
               let portableBackupExporter = dependencies.portableBackupExporter,
               let portableBackupRestorationPreparer = dependencies.portableBackupRestorationPreparer {
                tabs(
                    deckManagementService: deckManagementService,
                    vocabularyService: vocabularyService,
                    grammarService: grammarService,
                    knowledgePointService: knowledgePointService,
                    knowledgeSearchService: knowledgeSearchService,
                    contentCardService: contentCardService,
                    studySessionService: studySessionService,
                    studyHistoryService: studyHistoryService,
                    speechPreferencesService: speechPreferencesService,
                    adaptiveCardService: adaptiveCardService,
                    adaptivePreferencesService: adaptivePreferencesService,
                    aiConfigurationService: aiConfigurationService,
                    aiConnectionTestService: aiConnectionTestService,
                    aiModelCatalogService: aiModelCatalogService,
                    aiCardGenerationService: aiCardGenerationService,
                    sentenceAnalysisService: sentenceAnalysisService,
                    sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
                    aiRepairService: aiRepairService,
                    jlptProgressService: jlptProgressService,
                    jlptLibraryService: jlptLibraryService,
                    jlptImporter: jlptImporter,
                    inboxService: inboxService,
                    speechService: dependencies.speechService,
                    portableBackupExporter: portableBackupExporter,
                    portableBackupRestorationPreparer: portableBackupRestorationPreparer,
                    databaseGeneration: dependencies.databaseGeneration
                )
            } else if let launchErrorMessage = dependencies.launchErrorMessage {
                ContentUnavailableView(
                    "无法启动 Oboe",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(launchErrorMessage)
                )
                .accessibilityIdentifier("app-launch-error")
            } else {
                ProgressView("正在打开本地资料库…")
                    .accessibilityIdentifier("app-loading")
            }
        }
        .disabled(dependencies.isDatabaseOperationInProgress)
        .overlay {
            if dependencies.isDatabaseOperationInProgress {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    ProgressView("正在安全替换资料库…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("database-restoration-progress")
                }
            }
        }
        .preferredColorScheme(dependencies.appearancePreference.colorScheme)
    }

    private func tabs(
        deckManagementService: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        knowledgeSearchService: KnowledgeSearchService,
        contentCardService: ContentCardService,
        studySessionService: StudySessionService,
        studyHistoryService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService,
        aiConfigurationService: AIConfigurationService,
        aiConnectionTestService: AIConnectionTestService,
        aiModelCatalogService: AIModelCatalogService,
        aiCardGenerationService: AICardGenerationService,
        sentenceAnalysisService: SentenceAnalysisService,
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService,
        aiRepairService: AIRepairService,
        jlptProgressService: JLPTProgressService,
        jlptLibraryService: JLPTLibraryService,
        jlptImporter: any JLPTImporting,
        inboxService: InboxService,
        speechService: any SpeechService,
        portableBackupExporter: PortableBackupExporter,
        portableBackupRestorationPreparer: PortableBackupRestorationPreparer,
        databaseGeneration: Int
    ) -> some View {
        TabView(selection: $selectedTab) {
            TodayView(
                studyService: studySessionService,
                historyService: studyHistoryService,
                deckService: deckManagementService,
                speechPreferencesService: speechPreferencesService,
                adaptiveCardService: adaptiveCardService,
                adaptivePreferencesService: adaptivePreferencesService,
                aiRepairService: aiRepairService,
                speechService: speechService,
                inboxService: inboxService,
                processingServices: InboxProcessingServices(
                    deckService: deckManagementService,
                    vocabularyService: vocabularyService,
                    grammarService: grammarService,
                    knowledgePointService: knowledgePointService,
                    contentCardService: contentCardService,
                    aiCardGenerationService: aiCardGenerationService,
                    sentenceAnalysisService: sentenceAnalysisService,
                    sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
                    historyService: studyHistoryService,
                    speechService: speechService,
                    studyService: studySessionService
                ),
                inboxImageStore: dependencies.inboxImageStore,
                ocrService: dependencies.ocrService,
                drainSharedCaptures: { await dependencies.drainSharedCaptures() },
                pendingContinueItemID: dependencies.pendingContinueItemID,
                clearPendingContinueItem: {
                    Task { await dependencies.clearPendingContinueItem() }
                },
                sharedCapturesAwaitingImport: dependencies.sharedCapturesAwaitingImport,
                importAwaitingSharedCaptures: { await dependencies.importAwaitingSharedCaptures() }
            )
                .id(databaseGeneration)
                .tabItem {
                    Label("今日", systemImage: "sun.max")
                }
                .tag(PrimaryTab.today)

            DecksView(
                service: deckManagementService,
                vocabularyService: vocabularyService,
                grammarService: grammarService,
                knowledgePointService: knowledgePointService,
                searchService: knowledgeSearchService,
                contentCardService: contentCardService,
                studyService: studySessionService,
                historyService: studyHistoryService,
                speechPreferencesService: speechPreferencesService,
                adaptivePreferencesService: adaptivePreferencesService,
                speechService: speechService,
                jlptProgressService: jlptProgressService,
                jlptLibraryService: jlptLibraryService,
                jlptImporter: jlptImporter,
                jlptEnrichmentStatus: dependencies.jlptEnrichmentStatus,
                scheduleJLPTEnrichment: { dependencies.scheduleJLPTEnrichment() },
                adaptiveCardService: adaptiveCardService,
                aiRepairService: aiRepairService,
                aiCardGenerationService: aiCardGenerationService,
                sentenceAnalysisService: sentenceAnalysisService,
                sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService
            )
                .id(databaseGeneration)
                .tabItem {
                    Label("牌组", systemImage: "rectangle.stack")
                }
                .tag(PrimaryTab.decks)

            SettingsView(
                dependencies: dependencies,
                exporter: portableBackupExporter,
                restorationPreparer: portableBackupRestorationPreparer,
                studyService: studySessionService,
                speechPreferencesService: speechPreferencesService,
                adaptivePreferencesService: adaptivePreferencesService,
                aiConfigurationService: aiConfigurationService,
                aiConnectionTestService: aiConnectionTestService,
                aiModelCatalogService: aiModelCatalogService,
                speechService: speechService
            )
                .id(databaseGeneration)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
                .tag(PrimaryTab.settings)
        }
    }
}

private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
