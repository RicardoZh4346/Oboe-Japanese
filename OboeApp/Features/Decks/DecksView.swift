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
    private let historyService: StudyHistoryService
    private let speechService: any SpeechService
    private let jlptLibraryService: JLPTLibraryService
    private let jlptImporter: any JLPTImporting

    init(
        service: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        searchService: KnowledgeSearchService,
        contentCardService: ContentCardService,
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        speechService: any SpeechService,
        jlptLibraryService: JLPTLibraryService,
        jlptImporter: any JLPTImporting
    ) {
        deckService = service
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.searchService = searchService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
        self.jlptLibraryService = jlptLibraryService
        self.jlptImporter = jlptImporter
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
                            libraryService: jlptLibraryService,
                            importer: jlptImporter,
                            deckService: deckService,
                            speechService: speechService
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
                                DeckRow(deck: deck, today: model.todayTasks(for: deck.id))
                            }
                            .accessibilityIdentifier("deck-row-\(deck.id.uuidString)")
                        }
                    }
                } header: {
                    Text("我的牌组")
                } footer: {
                    Text("今日页会汇总全部任务，并可按牌组开始学习。")
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
                    historyService: historyService,
                    speechService: speechService
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
}

@MainActor
@Observable
private final class DecksViewModel {
    let service: DeckManagementService
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService

    var decks: [DeckSummary] = []
    var todayStatistics: TodayReviewStatistics?
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

    private func refreshTodayStatistics() async {
        do {
            let plan = try await studyService.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(deck.name)
                .font(.headline)
            HStack(spacing: 16) {
                Label("\(deck.noteCount) 个知识点", systemImage: "text.book.closed")
                Label("\(deck.cardCount) 张卡片", systemImage: "rectangle.on.rectangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("今日新卡 \(today.newCount) · 复习 \(today.reviewCount)")
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
    let historyService: StudyHistoryService
    let speechService: any SpeechService

    @Environment(\.dismiss) private var dismiss
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
        historyService: StudyHistoryService,
        speechService: any SpeechService
    ) {
        self.deckID = deckID
        self.model = model
        self.deckService = deckService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.searchService = searchService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
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

    var body: some View {
        Group {
            if let deck {
                List {
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
                            Text("可从“添加”入口填写并保存单词或语法草稿。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
                        LabeledContent("分配新卡", value: "\(counts.newCount)")
                            .accessibilityIdentifier("deck-detail-today-new-count")
                        LabeledContent("复习任务", value: "\(counts.reviewCount)")
                            .accessibilityIdentifier("deck-detail-today-review-count")
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
                            }
                        }
                        .accessibilityIdentifier("deck-delete-button")
                    } footer: {
                        if !deck.isEmpty {
                            Text("删除前可把全部知识点和卡片移动到其他牌组，或明确选择连同内容删除。评分历史仍保留原牌组标识。")
                        }
                    }
                }
                .navigationTitle(deck.name)
                .navigationBarTitleDisplayMode(.inline)
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
                .confirmationDialog(
                    "确定删除“\(deck.name)”吗？",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
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
                .confirmationDialog(
                    "删除非空牌组“\(deck.name)”",
                    isPresented: $isChoosingNonEmptyDeletion,
                    titleVisibility: .visible
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
                    Text("将影响 \(deck.noteCount) 个知识点和 \(deck.cardCount) 张卡片。移动会保留卡片进度；连同内容删除会移除正文与卡片。")
                }
                .confirmationDialog(
                    "确认连同牌组内容删除？",
                    isPresented: $isConfirmingContentDeletion,
                    titleVisibility: .visible
                ) {
                    Button(
                        "删除 \(deck.noteCount) 个知识点与 \(deck.cardCount) 张卡片",
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
                    Text("例句、标签关联、卡片和当前任务会删除；评分历史仅保留不可变标识。操作不可撤销，可通过已有备份恢复。")
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
                    isPresented: Binding(
                        get: { contentModel.errorMessage != nil },
                        set: { isPresented in
                            if !isPresented {
                                contentModel.errorMessage = nil
                            }
                        }
                    )
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(contentModel.errorMessage ?? "未知错误")
                }
                .alert(
                    "无法搜索",
                    isPresented: Binding(
                        get: { searchModel.errorMessage != nil },
                        set: { isPresented in
                            if !isPresented {
                                searchModel.errorMessage = nil
                            }
                        }
                    )
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
                Text("将移动“\(sourceDeck.name)”中的 \(sourceDeck.noteCount) 个知识点和 \(sourceDeck.cardCount) 张卡片；卡片进度保留，评分历史仍记录原牌组。")
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

private struct DeckNameEditor: View {
    let title: String
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(
        title: String,
        initialName: String,
        onSave: @escaping (String) async -> Bool
    ) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var isNameValid: Bool {
        (try? DeckName(validating: name)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("牌组名称", text: $name)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .accessibilityIdentifier("deck-name-field")
                            .onSubmit(save)
                        if !name.isEmpty {
                            Button {
                                name = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清空牌组名称")
                            .accessibilityIdentifier("deck-name-clear-button")
                        }
                    }
                } footer: {
                    Text("名称不能为空，最多 \(DeckName.maximumLength) 个字符。")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!isNameValid || isSaving)
                        .accessibilityIdentifier("deck-name-save-button")
                }
            }
        }
    }

    private func save() {
        guard isNameValid, !isSaving else {
            return
        }
        isSaving = true
        Task {
            if await onSave(name) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}
