import OboeDomain
import SwiftUI

struct DeckDetailView: View {
    let deckID: UUID
    let model: DeckListModel
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
    /// regular 壳层：知识点行改为 selection 语义（写入 detail 列
    /// 选择）而非 push；compact 下为 nil，保持 NavigationLink 行为。
    let onSelectNote: ((KnowledgePointSummary) -> Void)?
    /// regular 壳层：删除成功后通知壳层清空 sidebar/detail 选择；
    /// compact 下为 nil，仅 dismiss() 出栈。
    let onDeleted: (() -> Void)?
    /// regular 壳层 detail 列编辑后由壳层递增触发本页内容重取；
    /// compact 恒为 0。
    let contentRefreshToken: Int

    @Environment(\.dismiss) private var dismiss
    @State private var isPresentingAdd = false
    @State private var isPresentingRename = false
    @State private var isConfirmingDelete = false
    @State private var isChoosingNonEmptyDeletion = false
    @State private var isConfirmingContentDeletion = false
    @State private var isMovingBeforeDeletion = false
    @State private var didDeleteAfterMove = false
    @State private var contentModel: DeckContentModel
    @State private var searchText = ""
    @State private var searchModel: KnowledgeSearchModel

    init(
        deckID: UUID,
        model: DeckListModel,
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
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService,
        onSelectNote: ((KnowledgePointSummary) -> Void)? = nil,
        onDeleted: (() -> Void)? = nil,
        contentRefreshToken: Int = 0
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
        self.onSelectNote = onSelectNote
        self.onDeleted = onDeleted
        self.contentRefreshToken = contentRefreshToken
        _contentModel = State(
            initialValue: DeckContentModel(
                deckID: deckID,
                service: knowledgePointService
            )
        )
        _searchModel = State(
            initialValue: KnowledgeSearchModel(
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
                let baseView = AnyView(
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
                                noteRow(item)
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
                )

                let deletionView = AnyView(
                    baseView.alert(
                    "确定删除“\(deck.name)”吗？",
                    isPresented: $isConfirmingDelete
                ) {
                    Button("确认删除", role: .destructive) {
                        Task {
                            if await model.deleteEmptyDeck(id: deck.id) {
                                onDeleted?()
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
                                onDeleted?()
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
                )

                deletionView
                .sheet(isPresented: $isMovingBeforeDeletion, onDismiss: {
                    dismissAfterMoveIfNeeded()
                }) {
                    moveBeforeDeletionSheet(for: deck)
                }
                .task(id: deckID) {
                    await contentModel.load()
                }
                .task(id: contentRefreshToken) {
                    // regular 壳层 detail 列保存后由壳层令牌触发重取；
                    // 0 为首载占位（上面 deckID task 已负责）。
                    guard contentRefreshToken != 0 else { return }
                    await contentModel.load()
                    await model.refreshDecks()
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

    private func dismissAfterMoveIfNeeded() {
        if didDeleteAfterMove {
            onDeleted?()
            dismiss()
        }
    }

    private func moveBeforeDeletionSheet(for deck: DeckSummary) -> some View {
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

    @ViewBuilder
    private func noteRow(_ item: KnowledgePointSummary) -> some View {
        if let onSelectNote {
            // regular 壳层：行选择写入 detail 列，不在本列内 push。
            Button {
                onSelectNote(item)
            } label: {
                KnowledgePointRow(item: item)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                destination(for: item)
            } label: {
                KnowledgePointRow(item: item)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        ForEach(searchModel.items) { item in
            noteRow(item)
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
