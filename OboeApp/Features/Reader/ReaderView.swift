import OboeDomain
import OboeInfrastructure
import SwiftUI

/// 单文档阅读页（S10）：正文 UITextView 桥 + 顶部进度条 + 工具栏
/// （目录/书签/加书签）。章级渲染——blocks 一次性入串（单章
/// ≤20MiB 上限兜底，典型章远小于此）。
///
/// 位置保持策略：滚动回调报 (blockOrdinal, 块内 utf16Offset) 给 VM；
/// onDisappear/scenePhase 后台化时 `persistPosition` 落库；
/// 字号/Dynamic Type 变化只重建 attributed 串，恢复仍按块定位。
struct ReaderView: View {
    @State private var model: ReaderDocumentViewModel
    @State private var showChapterSheet = false
    @State private var showBookmarkSheet = false
    @Environment(\.scenePhase) private var scenePhase
    /// 状态图例折叠（unknown 用户在正文被着色时给图例入口）。
    @State private var showLegend = false
    /// S11 Inspector（点词弹层）——nil = 关闭。
    @State private var inspector: ReaderInspectorViewModel?
    /// S11 批量选词态：开启后点词入队而非弹 Inspector。
    @State private var isBatchSelecting = false
    @State private var batchModel: ReaderBatchMiningViewModel?
    @State private var showBatchSheet = false
    /// S13「挖句成卡」创建表单载荷（正文选段路径）——nil = 关闭。
    @State private var clozeDraft: ReaderClozeDraft?
    /// S11 挖词依赖包；nil = 词典等装配缺席，点词静默不弹层。
    private let mining: ReaderMiningDependencies?
    /// v0.7.5 AI Study 依赖包；nil/无 preparation = 隐藏 AI 入口。
    private let aiStudy: ReaderAIStudyDependencies?
    /// AI 学习流程模型——nil = 弹层关闭（值语义 @State 持有）。
    @State private var aiStudyModel: ReaderAIStudyFlowModel?
    /// S17 译文依赖包；nil = 隐藏模式选择器/译文入口，原文阅读不变。
    private let translation: ReaderTranslationDependencies?
    /// S17 译文 VM（按文档实例持有——水合/折叠/占位态随章刷新）。
    @State private var translationModel: ReaderTranslationViewModel?
    /// 模式切换/外部跳转下发的滚动锚（块序；消费后清零）。
    @State private var scrollAnchor: Int?
    /// v0.7.5 S18：工具栏「学习牌组」按钮 → 跨区路由到 Decks 区
    /// （`SceneNavigationState.openDeck`）。nil = 隐藏入口。
    private let onOpenDeck: ((UUID) -> Void)?

    init(
        model: ReaderDocumentViewModel,
        mining: ReaderMiningDependencies? = nil,
        aiStudy: ReaderAIStudyDependencies? = nil,
        translation: ReaderTranslationDependencies? = nil,
        onOpenDeck: ((UUID) -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.mining = mining
        self.aiStudy = aiStudy
        self.translation = translation
        self.onOpenDeck = onOpenDeck
        _translationModel = State(
            initialValue: translation.map {
                ReaderTranslationViewModel(dependencies: $0)
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 进度条：视觉进度 = 全局 utf16 占比（VM 同一口径）。
            ProgressView(value: Double(model.visibleProgressBasisPoints) / 10_000)
                .progressViewStyle(.linear)
                .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                .accessibilityIdentifier("reader-progress")

            Group {
                if model.isLoading {
                    ProgressView("正在打开…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.blocks.isEmpty {
                    OboeEmptyState(
                        systemImage: "book.closed",
                        title: "本章节没有内容",
                        message: model.document == nil
                            ? nil : "该章节没有可显示的正文块。"
                    )
                } else if displayMode == .translatedOnly,
                          let translationModel {
                    // S17 纯译文：块序锚与 ReaderTextView 同源——
                    // 位置上报写回同一 updateVisiblePosition。
                    ReaderTranslatedOnlyList(
                        blocks: model.blocks,
                        model: translationModel,
                        onTopBlockChange: { ordinal in
                            model.updateVisiblePosition(
                                blockOrdinal: ordinal, utf16Offset: 0
                            )
                            scrollAnchor = nil
                        },
                        scrollAnchor: scrollAnchor
                            ?? model.pendingRestore?.blockOrdinal,
                        onTranslate: { blockID in
                            Task {
                                await translationModel.translate(blockID)
                            }
                        },
                        onRetry: { blockID in
                            Task {
                                await translationModel.translate(blockID)
                            }
                        },
                        onRetranslate: { blockID in
                            Task {
                                await translationModel.retranslate(blockID)
                            }
                        }
                    )
                } else {
                    ReaderTextView(
                        blocks: model.blocks,
                        highlights: model.highlights,
                        // 批量挖词已入队的词在正文里换选中配色——
                        // 否则用户看不出哪些词已选（S11 反馈缺口）。
                        selectedTokens: isBatchSelecting
                            ? Set((batchModel?.items ?? []).map {
                                ReaderTextView.TokenRef(
                                    blockID: $0.tap.blockID,
                                    range: $0.tap.utf16Range
                                )
                            })
                            : [],
                        restoreBlockOrdinal: model.pendingRestore?.blockOrdinal,
                        restoreUTF16Offset: model.pendingRestore?.utf16Offset ?? 0,
                        // 重组保持锚：模式切换锚 > 当前可见块——
                        // 字号/译文水合/折叠重组都不丢原文位置。
                        anchorOrdinal: scrollAnchor
                            ?? model.visibleBlockOrdinal,
                        anchorUTF16Offset: scrollAnchor != nil
                            ? 0 : model.visibleUTF16Offset,
                        onRestoreApplied: {
                            model.consumeRestoredLocation()
                            scrollAnchor = nil
                        },
                        translations: displayMode == .bilingual
                            ? translationModel?.bilingualSegments ?? [:]
                            : [:],
                        onTranslationAction: { blockID, action in
                            switch action {
                            case .toggleCollapse:
                                translationModel?.toggleCollapse(blockID)
                            case .translate:
                                Task {
                                    await translationModel?.translate(
                                        blockID)
                                }
                            case .retry:
                                Task {
                                    await translationModel?.retranslate(
                                        blockID)
                                }
                            }
                        },
                        onVisibleBlockChange: { ordinal, offset in
                            model.updateVisiblePosition(
                                blockOrdinal: ordinal, utf16Offset: offset
                            )
                        },
                        onTokenTap: { blockID, range in
                            model.handleTap(blockID: blockID, utf16Range: range)
                        },
                        onClozeSelection: mining == nil ? nil : { blockID, range in
                            clozeDraft = model.clozeDraft(
                                forSelectionIn: blockID,
                                utf16Range: range
                            )
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OboeTheme.Colors.pageBackground)
        .navigationTitle(model.currentChapterTitle)
        .navigationBarTitleDisplayMode(.inline)
        // compact 下作为二级页 push：隐藏底部 Tab Bar。
        .secondaryPage()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showChapterSheet = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("reader-chapter-list")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // S17 三模式菜单——译文依赖装配缺席时隐藏（原文
                // 阅读路径完全不变）。
                if let translationModel {
                    Menu {
                        Picker("显示模式", selection: modeBinding) {
                            Text("原文").tag(
                                ReaderTranslationViewModel.DisplayMode
                                    .original)
                            Text("对照").tag(
                                ReaderTranslationViewModel.DisplayMode
                                    .bilingual)
                            Text("译文").tag(
                                ReaderTranslationViewModel.DisplayMode
                                    .translatedOnly)
                        }
                        Divider()
                        Button {
                            Task {
                                await translationModel.translateChapter()
                            }
                        } label: {
                            Label(
                                "翻译本章缺失段落",
                                systemImage: "character.bubble")
                        }
                        .disabled(translationModel.chapterTranslating)
                        Button {
                            Task {
                                await translationModel.retranslateChapter()
                            }
                        } label: {
                            Label(
                                "重新翻译本章",
                                systemImage: "arrow.clockwise")
                        }
                        .disabled(translationModel.chapterTranslating)
                    } label: {
                        Label("译文", systemImage: "text.alignleft")
                    }
                    .accessibilityIdentifier("reader-translation-menu")
                }
                // v0.7.5 S15：AI 学习入口——preparation 装配缺席
                // （无形态分析）时隐藏；文档未载入时置灰而不是消
                // 失（工具栏在加载前后保持同一组按钮，不跳变）。
                if let aiStudy, aiStudy.preparation != nil {
                    Button {
                        guard let document = model.document else { return }
                        aiStudyModel = ReaderAIStudyFlowModel(
                            context: aiStudyContext(
                                documentID: document.id,
                                title: document.title),
                            dependencies: aiStudy)
                    } label: {
                        Label("AI 学习", systemImage: "sparkles")
                    }
                    .disabled(model.document == nil)
                    .accessibilityIdentifier("reader-ai-study-button")
                }
                // 牌组入口按用户裁决移出阅读工具栏——文章→牌组的
                // 跳转留在 Reader 库行的徽标 affordance。
                if mining != nil {
                    Button {
                        isBatchSelecting.toggle()
                        if !isBatchSelecting, batchModel == nil {
                            // 关闭批量态且队列空——无残留。
                        }
                    } label: {
                        Label(
                            "批量选词",
                            systemImage: isBatchSelecting
                                ? "checklist.checked" : "checklist"
                        )
                    }
                    .accessibilityIdentifier("reader-batch-toggle")
                }
                if isBatchSelecting, (batchModel?.items.count ?? 0) > 0 {
                    Button {
                        showBatchSheet = true
                    } label: {
                        Text("批量挖词(\(batchModel?.items.count ?? 0))")
                    }
                    .accessibilityIdentifier("reader-batch-open")
                }
                Button {
                    Task { await model.toggleBookmark() }
                } label: {
                    // Label 标题即 VoiceOver 标签——纯 Image 在
                    // 工具栏只暴露 SF Symbol 名，用户无法区分
                    // 「切换书签」与旁边的「书签」列表按钮。
                    Label(
                        "标记书签",
                        systemImage: model.currentLocationIsBookmarked
                            ? "bookmark.fill" : "bookmark"
                    )
                }
                .accessibilityValue(
                    model.currentLocationIsBookmarked ? "已标记" : "未标记"
                )
                .accessibilityIdentifier("reader-bookmark-toggle")
                Button {
                    showBookmarkSheet = true
                } label: {
                    Label("书签", systemImage: "bookmark.square.on.square")
                }
                .accessibilityIdentifier("reader-bookmark-list")
                Button {
                    showLegend = true
                } label: {
                    Label("图例", systemImage: "paintpalette")
                }
                .accessibilityIdentifier("reader-legend-button")
            }
        }
        .sheet(isPresented: $showChapterSheet) {
            ReaderChapterSheet(model: model)
        }
        .sheet(isPresented: $showBookmarkSheet) {
            ReaderBookmarkSheet(model: model)
        }
        .sheet(isPresented: $showLegend) {
            ReaderStateLegendView()
                .presentationDetents([.height(280)])
        }
        // S11 Inspector：sheet 呈现期间 onTokenTap 回调仍经 VM
        // ——层叠面板各自持有独立 VM，互不串扰。
        .sheet(isPresented: .init(
            get: { inspector != nil },
            set: { if !$0 { inspector = nil } }
        )) {
            if let inspector {
                ReaderInspectorView(model: inspector)
            }
        }
        .sheet(isPresented: $showBatchSheet) {
            if let batchModel {
                ReaderBatchMiningSheet(model: batchModel)
            }
        }
        // S13：正文选段 → 挖句成卡创建表单（点词路径的入口在
        // Inspector 内——两处共用同一表单）。
        .sheet(item: $clozeDraft) { draft in
            if let mining {
                ReaderClozeCreateView(
                    model: ReaderClozeCreateViewModel(
                        draft: draft, dependencies: mining
                    )
                )
            }
        }
        // v0.7.5 S15：AI 学习流程弹层——预检/分析/预览/摘要全链路
        // 在 sheet 内闭环；取消与返回阅读都经流程模型。
        .sheet(isPresented: .init(
            get: { aiStudyModel != nil },
            set: { if !$0 { aiStudyModel = nil } }
        )) {
            if let aiStudyModel {
                ReaderAIStudySheet(model: aiStudyModel)
            }
        }
        .overlay(alignment: .bottom) {
            if isBatchSelecting {
                Text(
                    batchModel?.items.isEmpty ?? true
                        ? "批量选词中——点击正文词汇加入队列"
                        : "已选 \(batchModel?.items.count ?? 0) 词——点右上角进入批量挖词"
                )
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 12)
            }
        }
        .task { await model.load() }
        // S18：绑定变化（AI 学习建组/牌组删除 SET NULL/恢复替换）
        // 经共享流驱动——只重取绑定单行，不触发任何分析。
        .task { await model.observeLearningSurface() }
        // 知识态变更（AI 制卡/挖词/太简单/笔记关联写提交）→ 重取
        // state 重着色——不重分词，tokenCache 复用。
        .task { await model.observeKnowledgeChanges() }
        // S17：章块集合变化（载入/切章/重链后重新取块）→ 译文
        // 水合——纯本地行重锚，零网络。
        .onChange(of: model.blocks, initial: true) { _, _ in
            Task {
                await translationModel?.refresh(
                    document: model.document,
                    chapterOrdinal: model.chapters.indices
                        .contains(model.currentChapterIndex)
                        ? model.chapters[model.currentChapterIndex].ordinal
                        : 0,
                    blocks: model.blocks)
            }
        }
        .onAppear {
            // S11 挂载点：token tap → Inspector（或批量入队）。
            // mining 缺席时静默——着色仍在，只是不可挖词。
            model.onTokenTap = { tap in
                guard let mining else { return }
                if isBatchSelecting {
                    if batchModel == nil {
                        batchModel = ReaderBatchMiningViewModel(
                            document: model, dependencies: mining
                        )
                    }
                    batchModel?.enqueue(tap)
                } else {
                    guard let context = model.miningContext(for: tap)
                    else { return }
                    inspector = ReaderInspectorViewModel(
                        tap: tap, context: context, dependencies: mining,
                        clozeDraftProvider: { [model] lemma in
                            model.clozeDraft(for: tap, lemma: lemma)
                        }
                    )
                }
            }
        }
        // 降级提示：块 hash 不符 → banner 而非静默落章首。
        .overlay(alignment: .top) {
            if model.restoreDegraded {
                Text("位置未能精确恢复，已回到章节开头")
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .onDisappear {
            Task { await model.persistPosition() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await model.persistPosition() }
            }
        }
        .alert("提示", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("翻译", isPresented: .init(
            get: { translationModel?.errorMessage != nil },
            set: { if !$0 { translationModel?.clearError() } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(translationModel?.errorMessage ?? "")
        }
    }

    /// 三模式当前值（无译文 VM 恒原文）。
    private var displayMode: ReaderTranslationViewModel.DisplayMode {
        translationModel?.mode ?? .original
    }

    /// 模式切换绑定：先锚定当前可见块序再切渲染容器——
    /// 原文/对照同一 UITextView（译文间隙插入，原文坐标不动），
    /// 纯译文换 SwiftUI 列表（scrollAnchor 下发 + 顶块序上报同源）。
    private var modeBinding: Binding<ReaderTranslationViewModel.DisplayMode> {
        Binding(
            get: { displayMode },
            set: { newMode in
                scrollAnchor = model.visibleBlockOrdinal
                translationModel?.mode = newMode
            }
        )
    }

    /// AI 流程上下文：当前章/当前可见块的定位快照——范围解析
    /// （currentChapter/currentText）的锚参数。
    private func aiStudyContext(
        documentID: UUID, title: String
    ) -> ReaderAIStudyFlowModel.Context {
        let chapterID = model.chapters.indices
            .contains(model.currentChapterIndex)
            ? model.chapters[model.currentChapterIndex].id
            : nil
        let blockID = model.blocks.first(where: {
            $0.ordinal == model.visibleBlockOrdinal
        })?.id ?? model.blocks.first?.id
        return ReaderAIStudyFlowModel.Context(
            documentID: documentID,
            documentTitle: title,
            currentChapterID: chapterID,
            currentBlockID: blockID,
            chapterCount: model.chapters.count)
    }
}

/// 章节目录（sheet）：序号 + 标题 + 字数；选中后切章并滚动到章首
/// （relink 的书签跳转走 model.jump）。
private struct ReaderChapterSheet: View {
    let model: ReaderDocumentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.chapters) { chapter in
                Button {
                    Task {
                        try? await model.selectChapter(
                            index: model.chapters.firstIndex(of: chapter)
                                ?? chapter.ordinal
                        )
                        await model.persistPosition()
                        dismiss()
                    }
                } label: {
                    HStack {
                        Text("\(chapter.ordinal + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        Text(chapter.title ?? "第 \(chapter.ordinal + 1) 节")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(chapter.textUTF16Length) 字")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if chapter.ordinal
                            == (model.chapters.indices
                                .contains(model.currentChapterIndex)
                                ? model.chapters[model.currentChapterIndex]
                                    .ordinal : -1) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(OboeTheme.Colors.accent)
                        }
                    }
                }
                .accessibilityIdentifier(
                    "reader-chapter-\(chapter.ordinal)"
                )
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// 书签列表（sheet）：章节标题 + 上下文预览；点按跳转；左滑删除。
private struct ReaderBookmarkSheet: View {
    let model: ReaderDocumentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.bookmarks.isEmpty {
                    Text("还没有书签。阅读时点右上角书签图标即可标记。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.bookmarks) { bookmark in
                    Button {
                        Task {
                            try? await model.jump(to: bookmark)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                bookmark.label
                                    ?? chapterTitle(for: bookmark)
                            )
                            .font(.headline)
                            .foregroundStyle(.primary)
                            Text(bookmark.location.suffix.isEmpty
                                 ? bookmark.location.prefix
                                 : bookmark.location.suffix)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier(
                        "reader-bookmark-\(bookmark.id.uuidString)"
                    )
                }
                .onDelete { indexes in
                    for index in indexes {
                        Task {
                            await model.removeBookmark(
                                model.bookmarks[index]
                            )
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func chapterTitle(for bookmark: ReaderBookmark) -> String {
        let ordinal = bookmark.location.chapterOrdinal
        return model.chapters.first { $0.ordinal == ordinal }?.title
            ?? "第 \(ordinal + 1) 节"
    }
}

/// 状态图例（§状态图例）：known/learning/unknown/ignored 四色说明。
struct ReaderStateLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
            Text("词汇状态图例")
                .font(.headline)
            legendRow(color: .primary, title: "已掌握", detail: "确认为认识的词")
            legendRow(
                color: OboeTheme.Colors.accent,
                title: "学习中", detail: "已挖词制卡，正在学习"
            )
            legendRow(
                color: .orange, title: "未知",
                detail: "尚未关联词汇记录，可点词挖掘"
            )
            legendRow(
                color: Color(.secondaryLabel),
                title: "已忽略", detail: "手动标记为不需要学习"
            )
            Text("浅色底纹由着色承担；VoiceOver 下词级链接可从转子中激活。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(OboeTheme.Spacing.lg)
    }

    private func legendRow(
        color: Color, title: String, detail: String
    ) -> some View {
        HStack(spacing: OboeTheme.Spacing.sm) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
