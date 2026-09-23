import Observation
import OboeDomain
import SwiftUI

struct DecksView: View {
    @State private var model: DecksViewModel
    @State private var isPresentingCreate = false
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
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
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
        _model = State(
            initialValue: DecksViewModel(
                service: service,
                studyService: studyService,
                historyService: historyService
            )
        )
    }

    var body: some View {
        NavigationStack {
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
                                    isPrimary: model.primaryDeckID == deck.id
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
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink {
                        KnowledgeSearchView(
                            searchService: searchService,
                            deckService: deckService,
                            knowledgeService: knowledgePointService,
                            vocabularyService: vocabularyService,
                            grammarService: grammarService,
                            contentCardService: contentCardService,
                            historyService: historyService,
                            speechService: speechService
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
                            speechService: speechService
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
                    sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService
                )
            }
            .sheet(isPresented: $isPresentingCreate) {
                DeckNameEditor(title: "新建牌组", initialName: "") { name in
                    await model.createDeck(named: name)
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
                await model.observeDecks()
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
        }
    }
}

@MainActor
@Observable
private final class DecksViewModel {
    let service: DeckManagementService
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService

    var decks: [DeckSummary] = []
    var todayStatistics: TodayReviewStatistics?
    var primaryDeckID: UUID?
    var deletionImpacts: [UUID: DeckDeletionImpact] = [:]
    var isLoading = true
    var errorMessage: String?

    init(
        service: DeckManagementService,
        studyService: StudySessionService,
        historyService: StudyHistoryService
    ) {
        self.service = service
        self.studyService = studyService
        self.historyService = historyService
    }

    func observeDecks() async {
        do {
            for try await decks in service.observeDecks() {
                guard !Task.isCancelled else {
                    return
                }
                self.decks = decks
                await refreshTodayStatistics()
                self.isLoading = false
            }
        } catch is CancellationError {
            // SwiftUI cancels this task with the view lifecycle.
        } catch {
            self.isLoading = false
            self.errorMessage = Self.message(for: error)
        }
    }

    func createDeck(named name: String) async -> Bool {
        do {
            try await service.createDeck(named: name)
            await refreshDecks()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func renameDeck(id: UUID, to name: String) async -> Bool {
        do {
            guard try await service.renameDeck(id: id, to: name) else {
                errorMessage = "这个牌组已不存在。"
                return false
            }
            await refreshDecks()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    func deleteEmptyDeck(id: UUID) async -> Bool {
        do {
            switch try await service.deleteEmptyDeck(id: id) {
            case .deleted:
                await refreshDecks()
                return true
            case .notFound:
                errorMessage = "这个牌组已不存在。"
            case let .notEmpty(noteCount, cardCount):
                errorMessage = "牌组包含 \(noteCount) 个知识点和 \(cardCount) 张卡片，请重新选择移动内容或连同内容删除。"
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        return false
    }

    func deleteDeck(id: UUID, strategy: DeckDeletionStrategy) async -> Bool {
        do {
            switch try await service.deleteDeck(id: id, strategy: strategy) {
            case .deleted:
                await refreshDecks()
                return true
            case .sourceNotFound:
                errorMessage = "这个牌组已不存在。"
            case .destinationNotFound:
                errorMessage = "目标牌组已不存在。"
            case .destinationMatchesSource:
                errorMessage = "目标牌组不能与待删除牌组相同。"
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        return false
    }

    /// 删除确认页预览：独占（将删除）/共享（仅解除关系）计数
    /// （设计 §4.8）。预览失败不阻断流程，文案回退为汇总计数。
    func loadDeletionImpact(for deckID: UUID) async {
        do {
            deletionImpacts[deckID] = try await service.previewDeletionImpact(id: deckID)
        } catch {}
    }

    func refreshDecks() async {
        do {
            decks = try await service.fetchDecks()
            await refreshTodayStatistics()
            isLoading = false
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func todayTasks(for deckID: UUID) -> DeckTodayTaskCount {
        todayStatistics?.tasks(for: deckID)
            ?? DeckTodayTaskCount(deckID: deckID, newCount: 0, reviewCount: 0)
    }

    /// 切换主牌组会立即重算当日新卡分配：额度先满足主牌组，剩余轮转其他牌组。
    func setPrimaryDeck(_ deckID: UUID?) async {
        do {
            _ = try await studyService.setPrimaryDeck(
                deckID,
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            primaryDeckID = deckID
            await refreshTodayStatistics()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func refreshTodayStatistics() async {
        do {
            let plan = try await studyService.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            let settings = try await studyService.loadLearningSettings(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            primaryDeckID = settings.primaryDeckID
            todayStatistics = try await historyService.fetchTodayStatistics(
                studyDayID: plan.studyDay.id
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case DeckNameValidationError.empty:
            return "牌组名称不能为空。"
        case let DeckNameValidationError.tooLong(maximum):
            return "牌组名称不能超过 \(maximum) 个字符。"
        case DeckNameValidationError.containsLineBreakOrControlCharacter:
            return "牌组名称不能包含换行或控制字符。"
        default:
            return error.localizedDescription
        }
    }
}

private struct DeckRow: View {
    let deck: DeckSummary
    let today: DeckTodayTaskCount
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(deck.name)
                    .font(.headline)
                if isPrimary {
                    Text("主牌组")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(OboeTheme.Colors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            OboeTheme.Colors.accent.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            HStack(spacing: 16) {
                Label("\(deck.noteCount) 个知识点", systemImage: "text.book.closed")
                Label("\(deck.cardCount) 张卡片", systemImage: "rectangle.on.rectangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("今日新词 \(today.newCount) · 复习 \(today.reviewCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("deck-today-counts-\(deck.id.uuidString)")
        }
        .padding(.vertical, 4)
    }
}

private struct DeckDetailView: View {
    let deckID: UUID
    let model: DecksViewModel
    let deckService: DeckManagementService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let searchService: KnowledgeSearchService
    let contentCardService: ContentCardService
    let studyService: StudySessionService
    let historyService: StudyHistoryService
    let speechPreferencesService: SpeechPreferencesService
    let adaptiveCardService: AdaptiveCardService
    let adaptivePreferencesService: AdaptivePreferencesService
    let aiRepairService: AIRepairService
    let speechService: any SpeechService
    let aiCardGenerationService: AICardGenerationService
    let sentenceAnalysisService: SentenceAnalysisService
    let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService

    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingAdd = false
    @State private var isPresentingRename = false
    @State private var isConfirmingDelete = false
    @State private var isChoosingNonEmptyDeletion = false
    @State private var isConfirmingContentDeletion = false
    @State private var isMovingBeforeDeletion = false
    @State private var didDeleteAfterMove = false
    @State private var contentModel: DeckContentViewModel
    @State private var searchText = ""
    @State private var searchModel: KnowledgeSearchViewModel

    init(
        deckID: UUID,
        model: DecksViewModel,
        deckService: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        searchService: KnowledgeSearchService,
        contentCardService: ContentCardService,
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService,
        aiRepairService: AIRepairService,
        speechService: any SpeechService,
        aiCardGenerationService: AICardGenerationService,
        sentenceAnalysisService: SentenceAnalysisService,
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    ) {
        self.deckID = deckID
        self.model = model
        self.deckService = deckService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.searchService = searchService
        self.contentCardService = contentCardService
        self.studyService = studyService
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.adaptiveCardService = adaptiveCardService
        self.adaptivePreferencesService = adaptivePreferencesService
        self.aiRepairService = aiRepairService
        self.speechService = speechService
        self.aiCardGenerationService = aiCardGenerationService
        self.sentenceAnalysisService = sentenceAnalysisService
        self.sentenceAnalysisCardCreationService = sentenceAnalysisCardCreationService
        _contentModel = State(
            initialValue: DeckContentViewModel(
                deckID: deckID,
                service: knowledgePointService
            )
        )
        _searchModel = State(
            initialValue: KnowledgeSearchViewModel(
                service: searchService,
                deckID: deckID
            )
        )
    }

    private var deck: DeckSummary? {
        model.decks.first { $0.id == deckID }
    }

    private var contentErrorIsPresented: Binding<Bool> {
        Binding(
            get: { contentModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    contentModel.errorMessage = nil
                }
            }
        )
    }

    private var searchErrorIsPresented: Binding<Bool> {
        Binding(
            get: { searchModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    searchModel.errorMessage = nil
                }
            }
        )
    }

    var body: some View {
        Group {
            if let deck {
                List {
                    Section {
                        if model.primaryDeckID == deck.id {
                            Label("当前主牌组", systemImage: "star.fill")
                                .foregroundStyle(OboeTheme.Colors.accent)
                                .accessibilityIdentifier("deck-primary-status")
                        } else {
                            Button("设为主牌组") {
                                Task { await model.setPrimaryDeck(deck.id) }
                            }
                            .accessibilityIdentifier("deck-set-primary")
                        }
                    } header: {
                        Text("今日主牌组")
                    } footer: {
                        Text("每日新词额度优先分配给主牌组，剩余额度再分配给其他牌组。一个词的全部方向占一个名额。切换后立即重算今日新词。未手动指定时自动使用排序最前的牌组。")
                    }

                    Section {
                        Button("重命名") {
                            isPresentingRename = true
                        }
                        .accessibilityIdentifier("deck-rename-button")

                        Button("删除牌组", role: .destructive) {
                            if deck.isEmpty {
                                isConfirmingDelete = true
                            } else {
                                isChoosingNonEmptyDeletion = true
                                Task { await model.loadDeletionImpact(for: deck.id) }
                            }
                        }
                        .accessibilityIdentifier("deck-delete-button")
                    } footer: {
                        if !deck.isEmpty {
                            Text("删除前可把全部知识点和卡片移动到其他牌组，或明确选择连同内容删除。评分历史仍保留原牌组标识。")
                        }
                    }

                    Section("概览") {
                        LabeledContent("知识点") {
                            Text("\(deck.noteCount)")
                                .accessibilityIdentifier("deck-note-count")
                        }
                        LabeledContent("卡片") {
                            Text("\(deck.cardCount)")
                                .accessibilityIdentifier("deck-card-count")
                        }
                    }

                    Section("牌组内容") {
                        if !SearchTextNormalizer.normalize(searchText).isEmpty {
                            if searchModel.isLoading {
                                ProgressView("正在搜索…")
                            } else if searchModel.items.isEmpty {
                                Label("没有匹配的知识点", systemImage: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                            } else {
                                searchResults
                            }
                        } else if contentModel.isLoading {
                            ProgressView("正在载入内容…")
                        } else if contentModel.items.isEmpty {
                            Label("暂无学习内容", systemImage: "tray")
                            Button("添加单词或语法") {
                                isPresentingAdd = true
                            }
                            .accessibilityIdentifier("deck-add-empty-button")
                        } else {
                            ForEach(contentModel.items) { item in
                                NavigationLink {
                                    destination(for: item)
                                } label: {
                                    KnowledgePointRow(item: item)
                                }
                                .accessibilityIdentifier("knowledge-row-\(item.id.uuidString)")
                            }
                        }
                    }

                    Section("今日") {
                        let counts = model.todayTasks(for: deck.id)
                        NavigationLink {
                            ReviewView(
                                service: studyService,
                                historyService: historyService,
                                speechPreferencesService: speechPreferencesService,
                                adaptiveCardService: adaptiveCardService,
                                adaptivePreferencesService: adaptivePreferencesService,
                                aiRepairService: aiRepairService,
                                deckService: deckService,
                                repairNoteEditor: { noteID, kind, onUpdated in
                                    AnyView(noteEditorDestination(
                                        noteID: noteID,
                                        kind: kind,
                                        onUpdated: onUpdated
                                    ))
                                },
                                speechService: speechService,
                                scope: StudyScope(deckID: deck.id, title: deck.name)
                            )
                        } label: {
                            Label("学习此牌组", systemImage: "play.fill")
                        }
                        .accessibilityIdentifier("deck-study-button")
                        LabeledContent("分配新词", value: "\(counts.newCount)")
                            .accessibilityIdentifier("deck-detail-today-new-count")
                        LabeledContent("复习任务", value: "\(counts.reviewCount)")
                            .accessibilityIdentifier("deck-detail-today-review-count")
                    }

                }
                .navigationTitle(deck.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresentingAdd = true
                        } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .accessibilityIdentifier("deck-add-button")
                    }
                }
                .navigationDestination(isPresented: $isPresentingAdd) {
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
                        requiredDeckID: deckID
                    )
                }
                .onChange(of: isPresentingAdd) { _, isPresenting in
                    // v0.5.5 第五步：添加流退出（正式保存或重复提示的
                    // 「加入当前牌组」复用）回到详情时刷新内容与计数；
                    // 成员关系变化不走 ValueObservation，需要主动重取。
                    guard !isPresenting else { return }
                    Task {
                        await contentModel.load()
                        await model.refreshDecks()
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索本牌组"
                )
                .sheet(isPresented: $isPresentingRename) {
                    DeckNameEditor(title: "重命名牌组", initialName: deck.name) { name in
                        await model.renameDeck(id: deck.id, to: name)
                    }
                }
                .alert(
                    "确定删除“\(deck.name)”吗？",
                    isPresented: $isConfirmingDelete
                ) {
                    Button("确认删除", role: .destructive) {
                        Task {
                            if await model.deleteEmptyDeck(id: deck.id) {
                                dismiss()
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("空牌组删除后无法撤销。")
                }
                .alert(
                    "删除非空牌组“\(deck.name)”",
                    isPresented: $isChoosingNonEmptyDeletion
                ) {
                    Button("移动内容后删除") {
                        isMovingBeforeDeletion = true
                    }
                    .disabled(model.decks.allSatisfy { $0.id == deck.id })
                    Button("连同内容删除", role: .destructive) {
                        isConfirmingContentDeletion = true
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    if let impact = model.deletionImpacts[deck.id] {
                        Text("本牌组包含 \(impact.noteCount) 个知识点（\(impact.exclusiveNoteCount) 个独占、\(impact.sharedNoteCount) 个共享）与 \(impact.cardCount) 张卡片。移动会保留卡片进度；连同内容删除只移除独占内容，共享内容仅解除与本牌组的关系。")
                    } else {
                        Text("将影响 \(deck.noteCount) 个知识点和 \(deck.cardCount) 张卡片。移动会保留卡片进度；连同内容删除会移除正文与卡片。")
                    }
                    if model.primaryDeckID == deck.id {
                        if model.decks.count > 1 {
                            Text("这是当前主牌组，删除后将自动把排序最前的牌组设为主牌组。")
                        } else {
                            Text("这是当前主牌组，删除后将没有牌组，主牌组显示为未设置。")
                        }
                    }
                }
                .alert(
                    "确认连同牌组内容删除？",
                    isPresented: $isConfirmingContentDeletion
                ) {
                    Button(
                        model.deletionImpacts[deck.id].map {
                            "删除 \($0.exclusiveNoteCount) 个独占知识点与 \($0.exclusiveCardCount) 张卡片"
                        } ?? "删除 \(deck.noteCount) 个知识点与 \(deck.cardCount) 张卡片",
                        role: .destructive
                    ) {
                        Task {
                            if await model.deleteDeck(id: deck.id, strategy: .deleteContents) {
                                dismiss()
                            }
                        }
                    }
                    .accessibilityIdentifier("deck-delete-with-content-confirm-button")
                    Button("取消", role: .cancel) {}
                } message: {
                    if let impact = model.deletionImpacts[deck.id], impact.sharedNoteCount > 0 {
                        Text("独占内容的例句、标签关联、卡片和当前任务会删除；\(impact.sharedNoteCount) 个共享知识点仅解除与本牌组的关系，卡片与进度保留。评分历史仅保留不可变标识。操作不可撤销，可通过已有备份恢复。")
                    } else {
                        Text("例句、标签关联、卡片和当前任务会删除；评分历史仅保留不可变标识。操作不可撤销，可通过已有备份恢复。")
                    }
                }
                .sheet(isPresented: $isMovingBeforeDeletion, onDismiss: {
                    if didDeleteAfterMove {
                        dismiss()
                    }
                }) {
                    DeckMoveBeforeDeletionSheet(
                        sourceDeck: deck,
                        destinations: model.decks.filter { $0.id != deck.id }
                    ) { destinationID in
                        await model.deleteDeck(
                            id: deck.id,
                            strategy: .moveContents(to: destinationID)
                        )
                    } onDeleted: {
                        didDeleteAfterMove = true
                    }
                }
                .task(id: deckID) {
                    await contentModel.load()
                }
                .task(id: searchText) {
                    await searchModel.debouncedSearch(searchText)
                }
                .alert(
                    "无法载入牌组内容",
                    isPresented: contentErrorIsPresented
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(contentModel.errorMessage ?? "未知错误")
                }
                .alert(
                    "无法搜索",
                    isPresented: searchErrorIsPresented
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(searchModel.errorMessage ?? "未知错误")
                }
            } else {
                ContentUnavailableView(
                    "牌组已不存在",
                    systemImage: "rectangle.stack.badge.minus"
                )
            }
        }
        .secondaryPage()
    }

    @ViewBuilder
    private var searchResults: some View {
        ForEach(searchModel.items) { item in
            NavigationLink {
                destination(for: item)
            } label: {
                KnowledgePointRow(item: item)
            }
            .accessibilityIdentifier("deck-search-result-\(item.id.uuidString)")
        }
        if searchModel.nextOffset != nil {
            Button {
                Task { await searchModel.loadMore(searchText) }
            } label: {
                if searchModel.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("载入更多")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(searchModel.isLoadingMore)
            .accessibilityIdentifier("deck-search-load-more-button")
        }
    }

    @ViewBuilder
    private func destination(for item: KnowledgePointSummary) -> some View {
        switch item.kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: item.id,
                service: vocabularyService,
                knowledgeService: knowledgePointService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await contentModel.load()
                await model.refreshDecks()
                await searchModel.refresh(searchText)
            }
        case .grammar:
            GrammarDetailView(
                noteID: item.id,
                service: grammarService,
                knowledgeService: knowledgePointService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await contentModel.load()
                await model.refreshDecks()
                await searchModel.refresh(searchText)
            }
        }
    }

    /// AI 拆卡 sheet 的手动编辑兜底：按 noteID + kind 直达详情页。
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
        }
    }
}

@MainActor
@Observable
private final class DeckContentViewModel {
    private let deckID: UUID
    private let service: KnowledgePointService

    var items: [KnowledgePointSummary] = []
    var isLoading = true
    var errorMessage: String?

    init(deckID: UUID, service: KnowledgePointService) {
        self.deckID = deckID
        self.service = service
    }

    func load() async {
        isLoading = true
        do {
            items = try await service.fetchSummaries(deckID: deckID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct KnowledgePointRow: View {
    let item: KnowledgePointSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.headword)
                    .font(.headline)
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("已收藏")
                }
                Spacer()
                Text(item.kind == .vocabulary ? "单词" : "语法")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.kind == .vocabulary, let reading = item.reading {
                Text(reading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(item.meaningZH)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct KnowledgeSearchView: View {
    let deckService: DeckManagementService
    let knowledgeService: KnowledgePointService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService

    @State private var query = ""
    @State private var model: KnowledgeSearchViewModel

    init(
        searchService: KnowledgeSearchService,
        deckService: DeckManagementService,
        knowledgeService: KnowledgePointService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        contentCardService: ContentCardService,
        historyService: StudyHistoryService,
        speechService: any SpeechService
    ) {
        self.deckService = deckService
        self.knowledgeService = knowledgeService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
        _model = State(
            initialValue: KnowledgeSearchViewModel(service: searchService, deckID: nil)
        )
    }

    var body: some View {
        Group {
            if SearchTextNormalizer.normalize(query).isEmpty {
                ContentUnavailableView(
                    "搜索知识点",
                    systemImage: "magnifyingglass",
                    description: Text("可输入日语原形、假名或中文释义。")
                )
                .accessibilityIdentifier("global-search-empty-state")
            } else if model.isLoading {
                ProgressView("正在搜索…")
            } else if model.items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(model.items) { item in
                        NavigationLink {
                            destination(for: item)
                        } label: {
                            KnowledgePointRow(item: item)
                        }
                        .accessibilityIdentifier("global-search-result-\(item.id.uuidString)")
                    }
                    if model.nextOffset != nil {
                        Button {
                            Task { await model.loadMore(query) }
                        } label: {
                            if model.isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("载入更多")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(model.isLoadingMore)
                        .accessibilityIdentifier("global-search-load-more-button")
                    }
                }
            }
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .searchable(text: $query, prompt: "日语、假名或中文")
        .task(id: query) {
            await model.debouncedSearch(query)
        }
        .alert(
            "无法搜索",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.errorMessage = nil }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private func destination(for item: KnowledgePointSummary) -> some View {
        switch item.kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: item.id,
                service: vocabularyService,
                knowledgeService: knowledgeService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await model.refresh(query)
            }
        case .grammar:
            GrammarDetailView(
                noteID: item.id,
                service: grammarService,
                knowledgeService: knowledgeService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await model.refresh(query)
            }
        }
    }
}

@MainActor
@Observable
private final class KnowledgeSearchViewModel {
    private let service: KnowledgeSearchService
    private let deckID: UUID?
    private var generation = 0
    private var activeNormalizedQuery = ""

    var items: [KnowledgePointSummary] = []
    var nextOffset: Int?
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?

    init(service: KnowledgeSearchService, deckID: UUID?) {
        self.service = service
        self.deckID = deckID
    }

    func debouncedSearch(_ query: String) async {
        generation += 1
        let currentGeneration = generation
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        activeNormalizedQuery = normalizedQuery
        errorMessage = nil
        isLoadingMore = false

        guard !normalizedQuery.isEmpty else {
            items = []
            nextOffset = nil
            isLoading = false
            return
        }

        isLoading = true
        do {
            try await Task.sleep(for: .milliseconds(200))
            try Task.checkCancellation()
            let page = try await service.search(query, deckID: deckID)
            guard currentGeneration == generation, !Task.isCancelled else { return }
            items = page.items
            nextOffset = page.nextOffset
            isLoading = false
        } catch is CancellationError {
            if currentGeneration == generation {
                isLoading = false
            }
        } catch {
            guard currentGeneration == generation else { return }
            items = []
            nextOffset = nil
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func refresh(_ query: String) async {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        activeNormalizedQuery = normalizedQuery
        errorMessage = nil
        isLoading = true
        do {
            let page = try await service.search(query, deckID: deckID)
            guard currentGeneration == generation else { return }
            items = page.items
            nextOffset = page.nextOffset
            isLoading = false
        } catch is CancellationError {
            if currentGeneration == generation { isLoading = false }
        } catch {
            guard currentGeneration == generation else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func loadMore(_ query: String) async {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        guard normalizedQuery == activeNormalizedQuery,
              let offset = nextOffset,
              !isLoadingMore else { return }
        let currentGeneration = generation
        isLoadingMore = true
        do {
            let page = try await service.search(query, deckID: deckID, offset: offset)
            guard currentGeneration == generation,
                  normalizedQuery == activeNormalizedQuery else { return }
            items.append(contentsOf: page.items)
            nextOffset = page.nextOffset
            isLoadingMore = false
        } catch is CancellationError {
            if currentGeneration == generation { isLoadingMore = false }
        } catch {
            guard currentGeneration == generation else { return }
            isLoadingMore = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct FavoritesView: View {
    let deckService: DeckManagementService
    let knowledgeService: KnowledgePointService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService

    @State private var model: FavoritesViewModel

    init(
        deckService: DeckManagementService,
        knowledgeService: KnowledgePointService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        contentCardService: ContentCardService,
        historyService: StudyHistoryService,
        speechService: any SpeechService
    ) {
        self.deckService = deckService
        self.knowledgeService = knowledgeService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
        _model = State(initialValue: FavoritesViewModel(service: knowledgeService))
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在载入收藏…")
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "还没有收藏",
                    systemImage: "star",
                    description: Text("可以在单词或语法详情页点击星标收藏。")
                )
                .accessibilityIdentifier("favorites-empty-state")
            } else {
                List(model.items) { item in
                    NavigationLink {
                        destination(for: item)
                    } label: {
                        KnowledgePointRow(item: item)
                    }
                    .accessibilityIdentifier("favorite-row-\(item.id.uuidString)")
                }
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .task {
            await model.load()
        }
        .alert(
            "无法载入收藏",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.errorMessage = nil }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    @ViewBuilder
    private func destination(for item: KnowledgePointSummary) -> some View {
        switch item.kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: item.id,
                service: vocabularyService,
                knowledgeService: knowledgeService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await model.load()
            }
        case .grammar:
            GrammarDetailView(
                noteID: item.id,
                service: grammarService,
                knowledgeService: knowledgeService,
                deckService: deckService,
                contentCardService: contentCardService,
                historyService: historyService,
                speechService: speechService
            ) {
                await model.load()
            }
        }
    }
}

@MainActor
@Observable
private final class FavoritesViewModel {
    private let service: KnowledgePointService

    var items: [KnowledgePointSummary] = []
    var isLoading = true
    var errorMessage: String?

    init(service: KnowledgePointService) {
        self.service = service
    }

    func load() async {
        isLoading = true
        do {
            items = try await service.fetchFavorites()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct DeckMoveBeforeDeletionSheet: View {
    let sourceDeck: DeckSummary
    let destinations: [DeckSummary]
    let onDelete: (UUID) async -> Bool
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List(destinations) { deck in
                Button {
                    moveAndDelete(to: deck.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(deck.name)
                        Text("目标现有 \(deck.noteCount) 个知识点、\(deck.cardCount) 张卡片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("deck-delete-move-destination-\(deck.id.uuidString)")
            }
            .navigationTitle("移动内容后删除")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("将移动“\(sourceDeck.name)”中的 \(sourceDeck.noteCount) 个知识点和 \(sourceDeck.cardCount) 张卡片；已是目标牌组成员的知识点不重复移动，卡片进度保留，评分历史仍记录原牌组。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
    }

    private func moveAndDelete(to destinationID: UUID) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            if await onDelete(destinationID) {
                onDeleted()
                dismiss()
            } else {
                isWorking = false
            }
        }
    }
}
