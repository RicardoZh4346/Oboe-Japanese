import OboeDomain
import OboeInfrastructure
import SwiftUI

/// regular 壳层：NavigationSplitView 分栏导航。
///
/// - Decks 区：三栏（sidebar 选择 → content 列表 → detail 条目详情）。
/// - Inbox 区：三栏（sidebar → content 条目列表 → detail 条目详情，
///   宽屏下 OCR 原图与文本并排）。
/// - Settings 区：三栏（sidebar → content 分类列表 → detail 分类表单）。
/// - 今日：两栏（sidebar + detail 整页）——没有独立的中间列表列，
///   强行占一列只会留下空列。
///
/// sidebar 在各分支间共享同一份内容（顶层 section + Decks 区
/// 条目）；壳层只组合既有页面，不复制页面实现；compact 行为由
/// `CompactShell` 完整保留。
struct RegularShell: View {
    let container: AppFeatureContainer
    let operations: AppRuntimeOperations
    let jlptEnrichmentStatus: JLPTEnrichmentStatus
    let pendingContinueItemID: UUID?
    let sharedCapturesAwaitingImport: Int?
    let isDatabaseOperationInProgress: Bool

    @Environment(SceneNavigationState.self) private var navigation

    /// Decks 区 sidebar 列表数据：与 compact `DecksView` 同一个 model。
    @State private var deckModel: DeckListModel
    /// Inbox 区 content 列共享的 model——detail 列编辑/删除后驱动列表
    /// 重取，也负责把选中条目对象喂给 detail 列。
    @State private var inboxModel: InboxViewModel
    /// detail 列保存后递增，驱动 content 列 `DeckDetailView` 重取。
    @State private var deckContentRevision = 0
    @State private var isPresentingCreateDeck = false
    /// ⌘N 在 Inbox 上下文触发「手动添加」的壳层侧 binding。
    @State private var isInboxCapturePresented = false

    /// sidebar 单 selection 词表：顶层 section 与 decks 内选择合并。
    private enum SidebarItem: Hashable {
        case today
        case inbox
        case settings
        case decks(DeckSidebarSelection)
    }

    init(
        container: AppFeatureContainer,
        operations: AppRuntimeOperations,
        jlptEnrichmentStatus: JLPTEnrichmentStatus,
        pendingContinueItemID: UUID?,
        sharedCapturesAwaitingImport: Int?,
        isDatabaseOperationInProgress: Bool
    ) {
        self.container = container
        self.operations = operations
        self.jlptEnrichmentStatus = jlptEnrichmentStatus
        self.pendingContinueItemID = pendingContinueItemID
        self.sharedCapturesAwaitingImport = sharedCapturesAwaitingImport
        self.isDatabaseOperationInProgress = isDatabaseOperationInProgress
        let decks = container.decks
        _deckModel = State(
            initialValue: DeckListModel(
                service: decks.deckService,
                studyService: decks.studyService,
                historyService: decks.historyService
            )
        )
        _inboxModel = State(
            initialValue: InboxViewModel(service: container.today.inboxService)
        )
    }

    var body: some View {
        @Bindable var navigation = navigation
        Group {
            if navigation.section == .today {
                NavigationSplitView(
                    columnVisibility: $navigation.splitVisibility,
                    preferredCompactColumn: $navigation.preferredCompactColumn
                ) {
                    sidebar
                } detail: {
                    featureDetail
                }
            } else {
                NavigationSplitView(
                    columnVisibility: $navigation.splitVisibility,
                    preferredCompactColumn: $navigation.preferredCompactColumn
                ) {
                    sidebar
                } content: {
                    middleColumn
                } detail: {
                    regularDetail
                }
            }
        }
        // 世代替换时整个壳层重建：content/detail 内的 @State model
        // 不得继续持有旧世代的 service 引用。
        .id(container.generation)
        .task {
            await deckModel.observeDecks()
        }
        .onAppear {
            updateColumnVisibility(for: navigation.section)
        }
        .onChange(of: navigation.section) { _, section in
            updateColumnVisibility(for: section)
        }
        .adaptivePresentation(
            role: .editor,
            isPresented: $isPresentingCreateDeck
        ) {
            DeckNameEditor(title: "新建牌组", initialName: "") { name in
                await deckModel.createDeck(named: name)
            }
        }
        // 硬件键盘快捷键（iPad）：⌘1-4 切 section、⌘F 跳搜索、
        // ⌘N 在当前上下文新建。隐藏按钮承载 shortcut，不进可访问性树。
        .background {
            Group {
                Button("") { navigation.selectTab(.today) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { navigation.selectTab(.decks) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { navigation.selectTab(.inbox) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { navigation.selectTab(.settings) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { navigation.selectDeckSidebar(.search) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") {
                    switch navigation.section {
                    case .decks:
                        isPresentingCreateDeck = true
                    case .inbox:
                        isInboxCapturePresented = true
                    case .today, .settings:
                        break
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Sidebar

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch navigation.section {
                case .today:
                    return .today
                case .inbox:
                    return .inbox
                case .settings:
                    return .settings
                case .decks:
                    return navigation.selectedDeck.map(SidebarItem.decks)
                }
            },
            set: { item in
                // List 在重建瞬间可能回写 nil——不响应取消选择。
                guard let item else { return }
                switch item {
                case .today:
                    navigation.selectTab(.today)
                case .inbox:
                    navigation.selectTab(.inbox)
                case .settings:
                    navigation.selectTab(.settings)
                case .decks(let selection):
                    navigation.selectDeckSidebar(selection)
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                Label("今日", systemImage: "sun.max")
                    .tag(SidebarItem.today)
                    .accessibilityIdentifier("sidebar-today")
                Label("收集箱", systemImage: "tray")
                    .tag(SidebarItem.inbox)
                    .accessibilityIdentifier("sidebar-inbox")
                Label("设置", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
                    .accessibilityIdentifier("sidebar-settings")
            }
            Section("牌组") {
                Label("JLPT 标准词汇库", systemImage: "books.vertical")
                    .tag(SidebarItem.decks(.library))
                    .accessibilityIdentifier("sidebar-jlpt-library")
                Label("收藏", systemImage: "star")
                    .tag(SidebarItem.decks(.favorites))
                    .accessibilityIdentifier("sidebar-favorites")
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(SidebarItem.decks(.search))
                    .accessibilityIdentifier("sidebar-search")
                if deckModel.isLoading {
                    ProgressView()
                } else {
                    ForEach(deckModel.decks) { deck in
                        DeckRow(
                            deck: deck,
                            today: deckModel.todayTasks(for: deck.id),
                            isPrimary: deckModel.primaryDeckID == deck.id
                        )
                        .tag(SidebarItem.decks(.deck(deck.id)))
                        .accessibilityIdentifier("sidebar-deck-\(deck.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle("Oboe")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingCreateDeck = true
                } label: {
                    Label("新建牌组", systemImage: "plus")
                }
                .accessibilityIdentifier("sidebar-deck-create-button")
            }
        }
    }

    // MARK: - 三栏 split 的 content / detail 分发

    /// 三栏 split 的 content 列：decks→牌组内容，inbox→收集箱列表，
    /// settings→分类列表。
    @ViewBuilder
    private var middleColumn: some View {
        switch navigation.section {
        case .decks:
            decksContent
        case .inbox:
            inboxContent
        case .settings:
            SettingsCategoryListView(
                selection: Binding(
                    get: { navigation.selectedSettingsRoute },
                    set: { route in
                        if let route { navigation.selectedSettingsRoute = route }
                    }
                )
            )
        case .today:
            // 不可达：today 走两栏分支。
            EmptyView()
        }
    }

    /// 三栏 split 的 detail 列：decks→条目详情，inbox→收集条目详情，
    /// settings→分类表单。
    @ViewBuilder
    private var regularDetail: some View {
        switch navigation.section {
        case .decks:
            decksDetail
        case .inbox:
            inboxDetail
        case .settings:
            settingsDetail
        case .today:
            EmptyView()
        }
    }

    // MARK: - Decks 区 content / detail

    @ViewBuilder
    private var decksContent: some View {
        let decks = container.decks
        switch navigation.selectedDeck {
        case .deck(let deckID):
            NavigationStack {
                DeckDetailView(
                    deckID: deckID,
                    model: deckModel,
                    deckService: decks.deckService,
                    vocabularyService: decks.vocabularyService,
                    grammarService: decks.grammarService,
                    knowledgePointService: decks.knowledgePointService,
                    searchService: decks.searchService,
                    contentCardService: decks.contentCardService,
                    studyService: decks.studyService,
                    historyService: decks.historyService,
                    speechPreferencesService: decks.speechPreferencesService,
                    adaptiveCardService: decks.adaptiveCardService,
                    adaptivePreferencesService: decks.adaptivePreferencesService,
                    aiRepairService: decks.aiRepairService,
                    speechService: container.shared.speechService,
                    aiCardGenerationService: decks.aiCardGenerationService,
                    sentenceAnalysisService: decks.sentenceAnalysisService,
                    sentenceAnalysisCardCreationService: decks.sentenceAnalysisCardCreationService,
                    onSelectNote: { item in
                        navigation.selectNote(id: item.id, kind: item.kind)
                    },
                    onDeleted: {
                        navigation.deckWasDeleted(deckID)
                    },
                    contentRefreshToken: deckContentRevision
                )
                // selection 驱动重建时必须重置内部 @State（contentModel
                // 以 deckID 初始化，不随参数自动换绑）。
                .id(deckID)
            }
        case .library:
            NavigationStack {
                JLPTLibraryView(
                    progressService: decks.jlpt.progressService,
                    libraryService: decks.jlpt.libraryService,
                    importer: decks.jlpt.importer,
                    deckService: decks.deckService,
                    speechService: container.shared.speechService,
                    enrichmentStatus: jlptEnrichmentStatus,
                    scheduleEnrichment: operations.scheduleJLPTEnrichment,
                    adaptiveCardService: decks.adaptiveCardService,
                    contentCardService: decks.contentCardService,
                    aiRepairService: decks.aiRepairService,
                    noteEditor: { item, onUpdated in
                        AnyView(noteDetail(
                            noteID: item.noteID,
                            kind: item.templateKind.knowledgePointKind,
                            onUpdated: onUpdated
                        ))
                    },
                    repairNoteEditor: { noteID, kind, onUpdated in
                        AnyView(noteDetail(
                            noteID: noteID,
                            kind: kind,
                            onUpdated: onUpdated
                        ))
                    }
                )
            }
        case .favorites:
            NavigationStack {
                FavoritesView(
                    deckService: decks.deckService,
                    knowledgeService: decks.knowledgePointService,
                    vocabularyService: decks.vocabularyService,
                    grammarService: decks.grammarService,
                    contentCardService: decks.contentCardService,
                    historyService: decks.historyService,
                    speechService: container.shared.speechService
                )
            }
        case .search:
            NavigationStack {
                KnowledgeSearchView(
                    searchService: decks.searchService,
                    deckService: decks.deckService,
                    knowledgeService: decks.knowledgePointService,
                    vocabularyService: decks.vocabularyService,
                    grammarService: decks.grammarService,
                    contentCardService: decks.contentCardService,
                    historyService: decks.historyService,
                    speechService: container.shared.speechService
                )
            }
        case nil:
            ContentUnavailableView(
                "选择一个牌组",
                systemImage: "rectangle.stack",
                description: Text("在侧栏选择词库、收藏、搜索或某个牌组。")
            )
            .accessibilityIdentifier("decks-content-empty")
        }
    }

    @ViewBuilder
    private var decksDetail: some View {
        if let noteID = navigation.selectedNoteID,
           let kind = navigation.selectedNoteKind {
            NavigationStack {
                noteDetail(noteID: noteID, kind: kind) {
                    deckContentRevision += 1
                }
                // selection 驱动重建时重置详情内部 @State。
                .id(noteID)
            }
        } else {
            ContentUnavailableView(
                "选择条目",
                systemImage: "doc.text.magnifyingglass",
                description: Text("在中间列选择一个知识点查看详情。")
            )
            .accessibilityIdentifier("decks-detail-empty")
        }
    }

    // MARK: - Inbox 区 content / detail

    @ViewBuilder
    private var inboxContent: some View {
        let today = container.today
        NavigationStack {
            InboxView(
                service: today.inboxService,
                processingServices: today.processingServices,
                inboxImageStore: container.shared.inboxImageStore,
                ocrService: container.shared.ocrService,
                drainSharedCaptures: operations.drainSharedCaptures,
                sharedCapturesAwaitingImport: sharedCapturesAwaitingImport,
                importAwaitingSharedCaptures: operations.importAwaitingSharedCaptures,
                model: inboxModel,
                onSelectItem: { item in
                    navigation.selectInboxItem(id: item.id)
                },
                externalCapturePresentation: $isInboxCapturePresented
            )
        }
    }

    @ViewBuilder
    private var inboxDetail: some View {
        if let itemID = navigation.selectedInboxItemID,
           let item = inboxModel.items.first(where: { $0.id == itemID }) {
            NavigationStack {
                InboxItemDetailView(
                    item: item,
                    service: container.today.inboxService,
                    processingServices: container.today.processingServices,
                    inboxImageStore: container.shared.inboxImageStore,
                    onChanged: {
                        Task { await inboxModel.reload() }
                    },
                    onDeleted: {
                        navigation.selectedInboxItemID = nil
                    }
                )
                // selection 驱动重建时重置详情内部 @State。
                .id(item.id)
            }
        } else {
            ContentUnavailableView(
                "选择一条收集内容",
                systemImage: "tray",
                description: Text("在中间列选择一条收集内容查看详情。")
            )
            .accessibilityIdentifier("inbox-detail-empty")
        }
    }

    // MARK: - Settings 区 detail

    @ViewBuilder
    private var settingsDetail: some View {
        if let route = navigation.selectedSettingsRoute {
            SettingsView(
                dependencies: container.settings,
                operations: operations,
                isDatabaseOperationInProgress: isDatabaseOperationInProgress,
                categoryFilter: route
            )
            // 分类切换时重建，重置分类视图内部 @State。
            .id(route)
        } else {
            ContentUnavailableView(
                "选择一个设置分类",
                systemImage: "gearshape",
                description: Text("在中间列选择一个分类查看设置。")
            )
            .accessibilityIdentifier("settings-detail-empty")
        }
    }

    // MARK: - 今日 detail（两栏 split）

    @ViewBuilder
    private var featureDetail: some View {
        switch navigation.section {
        case .today:
            let today = container.today
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
                importAwaitingSharedCaptures: operations.importAwaitingSharedCaptures
            )
        case .settings, .inbox, .decks:
            // 不可达：这三个区走三栏分支。
            EmptyView()
        }
    }

    /// detail 列条目详情：与 compact `DecksView`/`DeckDetailView` 同一组
    /// 详情页，服务与校验完全一致。
    @ViewBuilder
    private func noteDetail(
        noteID: UUID,
        kind: KnowledgePointKind,
        onUpdated: @escaping () async -> Void
    ) -> some View {
        let decks = container.decks
        switch kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: noteID,
                service: decks.vocabularyService,
                knowledgeService: decks.knowledgePointService,
                deckService: decks.deckService,
                contentCardService: decks.contentCardService,
                historyService: decks.historyService,
                speechService: container.shared.speechService,
                onUpdated: onUpdated
            )
        case .grammar:
            GrammarDetailView(
                noteID: noteID,
                service: decks.grammarService,
                knowledgeService: decks.knowledgePointService,
                deckService: decks.deckService,
                contentCardService: decks.contentCardService,
                historyService: decks.historyService,
                speechService: container.shared.speechService,
                onUpdated: onUpdated
            )
        }
    }

    /// 三栏区（decks/inbox/settings）全显 `.all`；两栏 today 用
    /// `.doubleColumn`。reducer 已同批归一化，这里兜底——三栏语义下
    /// `.doubleColumn` 折叠的是 sidebar 而非 content。
    private func updateColumnVisibility(for section: AppSection) {
        navigation.splitVisibility = section == .today ? .doubleColumn : .all
    }
}
