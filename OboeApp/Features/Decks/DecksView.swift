import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI

struct DecksView: View {
    @State private var model: DeckListModel
    @State private var isPresentingCreate = false
    /// S07：词典词条制卡——非 nil 时以该预填打开编辑器 sheet。
    /// 元组同时携带表单与来源草稿（词条快照 + dataset 版本）。
    @State private var dictionaryCardPrefill: (
        form: VocabularyFormData,
        source: SourceContextDraft
    )?
    private let deckService: DeckManagementService
    private let vocabularyService: VocabularyService
    private let grammarService: GrammarService
    private let knowledgePointService: KnowledgePointService
    private let searchService: KnowledgeSearchService
    private let contentCardService: ContentCardService
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService
    private let speechPreferencesService: SpeechPreferencesService
    private let adaptivePreferencesService: AdaptivePreferencesService
    private let speechService: any SpeechService
    private let jlptProgressService: JLPTProgressService
    private let jlptLibraryService: JLPTLibraryService
    private let jlptImporter: any JLPTImporting
    /// T12: 词库回填状态与幂等调度入口，透传给词库页。
    private let jlptEnrichmentStatus: JLPTEnrichmentStatus
    private let scheduleJLPTEnrichment: () -> Void
    /// T25: the JLPT weak-vocabulary list drills into the shared adaptive
    /// card detail — same services as the Today-tab Adaptive center.
    private let adaptiveCardService: AdaptiveCardService
    private let aiRepairService: AIRepairService
    /// v0.5.5：牌组详情内的添加流需要 AI 制卡/句子分析服务。
    private let aiCardGenerationService: AICardGenerationService
    private let sentenceAnalysisService: SentenceAnalysisService
    private let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    /// S06：全局搜索的词典 scope。
    private let dictionaryQueryService: DictionaryQueryService
    /// S07：牌组内复习的背面来源区。
    private let sourceContextRepository: (any SourceContextRepository)?
    /// S12：sentence 详情页读取挖空定义；nil 时降级为摘要展示。
    private let clozeRepository: (any ClozeRepository)?
    private let inboxImageStore: InboxImageStore?
    /// S09：专项学习驱动（详情页复习/专项入口透传）。
    private let customStudyRepository: (any CustomStudyRepository)?
    private let customStudyService: CustomStudyService?
    /// S18：壳层持有的栈路径（`SceneNavigationState.decksPath`）——
    /// `openDeck` 跨区路由把 deckID 压栈后由本栈解析。nil = 本地
    /// 栈（测试/预览）。
    private let externalPath: Binding<NavigationPath>?
    /// S18：详情页文章覆盖区 → 打开绑定文档的跨区回调。
    private let onOpenDocument: ((UUID) -> Void)?
    /// externalPath 缺席时的本地栈路径。
    @State private var localPath = NavigationPath()

    private var pathBinding: Binding<NavigationPath> {
        externalPath ?? $localPath
    }

    init(
        service: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        searchService: KnowledgeSearchService,
        contentCardService: ContentCardService,
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        adaptivePreferencesService: AdaptivePreferencesService,
        speechService: any SpeechService,
        jlptProgressService: JLPTProgressService,
        jlptLibraryService: JLPTLibraryService,
        jlptImporter: any JLPTImporting,
        jlptEnrichmentStatus: JLPTEnrichmentStatus,
        scheduleJLPTEnrichment: @escaping () -> Void,
        adaptiveCardService: AdaptiveCardService,
        aiRepairService: AIRepairService,
        aiCardGenerationService: AICardGenerationService,
        sentenceAnalysisService: SentenceAnalysisService,
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService,
        dictionaryQueryService: DictionaryQueryService,
        sourceContextRepository: (any SourceContextRepository)? = nil,
        clozeRepository: (any ClozeRepository)? = nil,
        inboxImageStore: InboxImageStore? = nil,
        customStudyRepository: (any CustomStudyRepository)? = nil,
        customStudyService: CustomStudyService? = nil,
        learningProgress: (any LearningProgressProviding)? = nil,
        studyDecks: (any StudyDeckSurfacing)? = nil,
        externalPath: Binding<NavigationPath>? = nil,
        onOpenDocument: ((UUID) -> Void)? = nil
    ) {
        deckService = service
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.searchService = searchService
        self.contentCardService = contentCardService
        self.studyService = studyService
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.adaptivePreferencesService = adaptivePreferencesService
        self.speechService = speechService
        self.jlptProgressService = jlptProgressService
        self.jlptLibraryService = jlptLibraryService
        self.jlptImporter = jlptImporter
        self.jlptEnrichmentStatus = jlptEnrichmentStatus
        self.scheduleJLPTEnrichment = scheduleJLPTEnrichment
        self.adaptiveCardService = adaptiveCardService
        self.aiRepairService = aiRepairService
        self.aiCardGenerationService = aiCardGenerationService
        self.sentenceAnalysisService = sentenceAnalysisService
        self.sentenceAnalysisCardCreationService = sentenceAnalysisCardCreationService
        self.dictionaryQueryService = dictionaryQueryService
        self.sourceContextRepository = sourceContextRepository
        self.clozeRepository = clozeRepository
        self.inboxImageStore = inboxImageStore
        self.customStudyRepository = customStudyRepository
        self.customStudyService = customStudyService
        self.externalPath = externalPath
        self.onOpenDocument = onOpenDocument
        _model = State(
            initialValue: DeckListModel(
                service: service,
                studyService: studyService,
                historyService: historyService,
                learningProgress: learningProgress,
                studyDecks: studyDecks
            )
        )
    }

    var body: some View {
        NavigationStack(path: pathBinding) {
            List {
                Section {
                    NavigationLink {
                        JLPTLibraryView(
                            progressService: jlptProgressService,
                            libraryService: jlptLibraryService,
                            importer: jlptImporter,
                            deckService: deckService,
                            speechService: speechService,
                            enrichmentStatus: jlptEnrichmentStatus,
                            scheduleEnrichment: scheduleJLPTEnrichment,
                            adaptiveCardService: adaptiveCardService,
                            contentCardService: contentCardService,
                            aiRepairService: aiRepairService,
                            noteEditor: { item, onUpdated in
                                AnyView(noteEditorDestination(
                                    noteID: item.noteID,
                                    kind: item.templateKind.knowledgePointKind,
                                    onUpdated: onUpdated
                                ))
                            },
                            repairNoteEditor: { noteID, kind, onUpdated in
                                AnyView(noteEditorDestination(
                                    noteID: noteID,
                                    kind: kind,
                                    onUpdated: onUpdated
                                ))
                            }
                        )
                    } label: {
                        Label("JLPT 标准词汇库", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("jlpt-library-entry")
                } header: {
                    Text("内置词库")
                } footer: {
                    Text("社区整理的 N5–N1 参考词汇，可离线浏览并导入牌组。")
                }

                Section {
                    if model.isLoading {
                        ProgressView("正在载入牌组…")
                    } else if model.decks.isEmpty {
                        Button("还没有牌组，点此新建") {
                            isPresentingCreate = true
                        }
                        .accessibilityIdentifier("deck-create-empty-button")
                    } else {
                        ForEach(model.decks) { deck in
                            NavigationLink(value: deck.id) {
                                DeckRow(
                                    deck: deck,
                                    today: model.todayTasks(for: deck.id),
                                    isPrimary: model.primaryDeckID == deck.id,
                                    learningProgress: model
                                        .learningProgress(for: deck.id)
                                )
                            }
                            .accessibilityIdentifier("deck-row-\(deck.id.uuidString)")
                        }
                    }
                } header: {
                    Text("我的牌组")
                } footer: {
                    Text("今日页会汇总全部任务；牌组详情内可按本牌组范围学习。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("牌组")
            // 一级页不声明 Tab Bar 可见性：钉住 .visible 会在新系统上
            // 盖住二级页 secondaryPage() 的 .hidden。pop 返回由系统
            // 自动恢复 Tab Bar。
            .primaryPage()
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink {
                        GlobalSearchView(
                            searchService: searchService,
                            deckService: deckService,
                            knowledgeService: knowledgePointService,
                            vocabularyService: vocabularyService,
                            grammarService: grammarService,
                            contentCardService: contentCardService,
                            historyService: historyService,
                            speechService: speechService,
                            dictionaryQueryService: dictionaryQueryService,
                            clozeRepository: clozeRepository,
                            onCreateCard: { entry in
                                Task {
                                    let version = try? await dictionaryQueryService
                                        .metadata().datasetVersion
                                    dictionaryCardPrefill = (
                                        form: DictionaryCardPrefill
                                            .vocabularyForm(from: entry),
                                        source: DictionaryCardPrefill
                                            .sourceContextDraft(
                                                from: entry,
                                                datasetVersion: version
                                            )
                                    )
                                }
                            }
                        )
                    } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .accessibilityIdentifier("global-search-button")

                    NavigationLink {
                        FavoritesView(
                            deckService: deckService,
                            knowledgeService: knowledgePointService,
                            vocabularyService: vocabularyService,
                            grammarService: grammarService,
                            contentCardService: contentCardService,
                            historyService: historyService,
                            speechService: speechService,
                            clozeRepository: clozeRepository
                        )
                    } label: {
                        Label("收藏", systemImage: "star")
                    }
                    .accessibilityIdentifier("favorites-button")

                    Button {
                        isPresentingCreate = true
                    } label: {
                        Label("新建牌组", systemImage: "plus")
                    }
                    .accessibilityIdentifier("deck-create-toolbar-button")
                }
            }
            .navigationDestination(for: UUID.self) { deckID in
                DeckDetailView(
                    deckID: deckID,
                    model: model,
                    deckService: deckService,
                    vocabularyService: vocabularyService,
                    grammarService: grammarService,
                    knowledgePointService: knowledgePointService,
                    searchService: searchService,
                    contentCardService: contentCardService,
                    studyService: studyService,
                    historyService: historyService,
                    speechPreferencesService: speechPreferencesService,
                    adaptiveCardService: adaptiveCardService,
                    adaptivePreferencesService: adaptivePreferencesService,
                    aiRepairService: aiRepairService,
                    speechService: speechService,
                    aiCardGenerationService: aiCardGenerationService,
                    sentenceAnalysisService: sentenceAnalysisService,
                    sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
                    sourceContextRepository: sourceContextRepository,
                    clozeRepository: clozeRepository,
                    inboxImageStore: inboxImageStore,
                    dictionaryQueryService: dictionaryQueryService,
                    customStudyRepository: customStudyRepository,
                    customStudyService: customStudyService,
                    onOpenDocument: onOpenDocument
                )
            }
            .sheet(isPresented: $isPresentingCreate) {
                DeckNameEditor(title: "新建牌组", initialName: "") { name in
                    await model.createDeck(named: name)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { dictionaryCardPrefill != nil },
                    set: { if !$0 { dictionaryCardPrefill = nil } }
                )
            ) {
                NavigationStack {
                    AddContentEditorView(
                        deckService: deckService,
                        vocabularyService: vocabularyService,
                        grammarService: grammarService,
                        knowledgePointService: knowledgePointService,
                        contentCardService: contentCardService,
                        aiCardGenerationService: aiCardGenerationService,
                        sentenceAnalysisService: sentenceAnalysisService,
                        sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
                        historyService: historyService,
                        speechService: speechService,
                        studyService: studyService,
                        vocabularyPrefill: dictionaryCardPrefill?.form,
                        sourceContextDraft: dictionaryCardPrefill?.source,
                        dictionaryQueryService: dictionaryQueryService,
                        sourceContextRepository: sourceContextRepository,
                        title: "词典制卡"
                    )
                }
            }
            .alert(
                "无法完成操作",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            model.errorMessage = nil
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "未知错误")
            }
            .task {
                // S18：model 自持观察任务（decks 摘要 + 学习表面流），
                // 幂等——详情页内再次调用不重复订阅。
                model.startObserving()
            }
        }
    }

    /// T25: the weak-vocabulary card detail's edit/修卡 fallback reuses the
    /// existing note detail/editors — same services and validation as the
    /// Today-tab wiring, keyed by note id + kind.
    @ViewBuilder
    private func noteEditorDestination(
        noteID: UUID,
        kind: KnowledgePointKind,
        onUpdated: @escaping () async -> Void
    ) -> some View {
        switch kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: noteID,
                service: vocabularyService,
                knowledgeService: knowledgePointService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService,
                onUpdated: onUpdated
            )
        case .grammar:
            GrammarDetailView(
                noteID: noteID,
                service: grammarService,
                knowledgeService: knowledgePointService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService,
                onUpdated: onUpdated
            )
        case .sentence:
            SentenceNoteDetailView(
                noteID: noteID,
                clozeRepository: clozeRepository,
                knowledgeService: knowledgePointService,
                onUpdated: onUpdated
            )
        }
    }
}
