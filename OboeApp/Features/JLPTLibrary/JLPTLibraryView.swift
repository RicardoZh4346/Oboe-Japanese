import OboeDomain
import SwiftUI

struct JLPTLibraryView: View {
    let progressService: JLPTProgressService
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
    let deckService: DeckManagementService
    let speechService: any SpeechService
    /// T12: 已导入词条的音调/例句中文回填状态（设计 §7.4）；进入本页
    /// 会触发一次幂等调度，失败时在此给出可重试入口。
    let enrichmentStatus: JLPTEnrichmentStatus
    let scheduleEnrichment: () -> Void
    /// T25: the dashboard's weak-vocabulary list reuses the adaptive
    /// detail/actions — same services, same editor destinations.
    let adaptiveCardService: AdaptiveCardService
    let contentCardService: ContentCardService
    let aiRepairService: AIRepairService
    let noteEditor: (AdaptiveCardItem, @escaping () async -> Void) -> AnyView
    let repairNoteEditor: (UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView

    @AppStorage("didShowJLPTLibraryNotice") private var didShowNotice = false
    @State private var counts: [JLPTLevel: Int] = [:]
    @State private var importedCounts: [JLPTLevel: Int] = [:]
    @State private var isLoading = true
    @State private var isShowingNotice = false
    @State private var errorMessage: String?

    private let levels: [JLPTLevel] = [.n5, .n4, .n3, .n2, .n1]

    var body: some View {
        List {
            Section {
                NavigationLink {
                    JLPTDashboardView(
                        progressService: progressService,
                        libraryService: libraryService,
                        importer: importer,
                        deckService: deckService,
                        speechService: speechService,
                        adaptiveCardService: adaptiveCardService,
                        contentCardService: contentCardService,
                        aiRepairService: aiRepairService,
                        noteEditor: noteEditor,
                        repairNoteEditor: repairNoteEditor
                    )
                } label: {
                    Label("JLPT 学习进度", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("jlpt-progress-entry")
            }
            enrichmentStatusSection
            Section {
                ForEach(levels, id: \.self) { level in
                    NavigationLink {
                        JLPTLevelView(
                            level: level,
                            totalCount: counts[level, default: 0],
                            libraryService: libraryService,
                            importer: importer,
                            deckService: deckService,
                            speechService: speechService
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(level.rawValue).font(.headline)
                                Text("\(counts[level, default: 0]) 个词")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if importedCounts[level, default: 0] > 0 {
                                Text("已导入 \(importedCounts[level, default: 0])")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("jlpt-level-\(level.rawValue)")
                }
            } header: {
                Text("等级")
            } footer: {
                Text("词库可完全离线浏览；只有导入后的词才会进入复习和备份。")
            }

            Section("说明") {
                Text("此处是社区整理的 JLPT 参考词汇，不是日本国际交流基金会发布的官方词表。")
                    .font(.footnote)
            }
        }
        .overlay { if isLoading { ProgressView("正在载入词库…") } }
        .navigationTitle("JLPT 词汇库")
        .secondaryPage()
        .task {
            scheduleEnrichment()
            await refresh()
        }
        .adaptivePresentation(role: .inspector, isPresented: $isShowingNotice) { noticeSheet }
        .alert("无法读取词库", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var noticeSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("使用前说明", systemImage: "info.circle")
                    .font(.title2.bold())
                Text("本词库由开放数据整理，用于学习参考，并非官方 JLPT 词表。词义和等级可能存在差异，导入前可先查看并编辑。")
                Spacer()
                Button("我知道了") {
                    didShowNotice = true
                    isShowingNotice = false
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("内置词库")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(!didShowNotice)
    }

    /// 最低限度回填提示（设计 §7.4）：只在进行/失败时占用一行；
    /// 失败保留可重试入口，不展示内部错误细节。
    @ViewBuilder
    private var enrichmentStatusSection: some View {
        switch enrichmentStatus {
        case .idle:
            EmptyView()
        case let .running(processed, total):
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(
                        total > 0
                            ? "正在补充音调与例句翻译 \(processed)/\(total)"
                            : "正在补充音调与例句翻译…"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("jlpt-enrichment-running")
            }
        case .failed:
            Section {
                Label(
                    "词库新字段补充未完成；学习不受影响，可重试。",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
                Button("重试") { scheduleEnrichment() }
                    .accessibilityIdentifier("jlpt-enrichment-retry")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func refresh() async {
        do {
            async let libraryCounts = libraryService.levelCounts()
            async let userCounts = importer.importedCounts()
            counts = try await libraryCounts
            importedCounts = try await userCounts
            isLoading = false
            if !didShowNotice { isShowingNotice = true }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct JLPTLevelView: View {
    let level: JLPTLevel
    let totalCount: Int
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
    let deckService: DeckManagementService
    let speechService: any SpeechService

    @State private var query = ""
    @State private var sort = JLPTLibrarySort.source
    @State private var items: [BuiltinJLPTVocabulary] = []
    @State private var importedSourceRefs: Set<String> = []
    @State private var nextOffset: Int?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var importProgress: JLPTImportProgress?
    @State private var importTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var isConfirmingLevelImport = false
    @State private var isChoosingLevelImportDeck = false

    private var reloadKey: String { "\(query)|\(sort.rawValue)" }

    var body: some View {
        List {
            Section {
                Picker("排序", selection: $sort) {
                    Text("词表顺序").tag(JLPTLibrarySort.source)
                    Text("常用优先").tag(JLPTLibrarySort.frequency)
                    Text("假名顺序").tag(JLPTLibrarySort.kana)
                }
                .pickerStyle(.segmented)
            }

            Section {
                if isLoading && items.isEmpty {
                    ProgressView("正在读取…")
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(items) { item in
                        NavigationLink {
                            JLPTVocabularyDetailView(
                                vocabularyID: item.id,
                                libraryService: libraryService,
                                importer: importer,
                                deckService: deckService,
                                speechService: speechService
                            )
                        } label: {
                            JLPTVocabularyRow(
                                vocabulary: item,
                                isImported: importedSourceRefs.contains(item.id)
                            )
                        }
                    }
                    if nextOffset != nil {
                        Button(isLoading ? "正在载入…" : "载入更多") {
                            Task { await loadMore() }
                        }
                        .disabled(isLoading)
                    }
                }
            }
        }
        .navigationTitle(level.rawValue)
        .secondaryPage()
        .searchable(text: $query, prompt: "搜索日文、假名或中文")
        .task(id: reloadKey) { await reload() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("导入全级", systemImage: "square.and.arrow.down") {
                    isConfirmingLevelImport = true
                }
                .disabled(isImporting)
            }
        }
        .alert(
            "导入 \(level.rawValue) 全部可用词汇？",
            isPresented: $isConfirmingLevelImport
        ) {
            Button("选择牌组并导入") { isChoosingLevelImportDeck = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(totalCount) 个词条。导入需要选择一个既有牌组，最多新增 \(totalCount) 个知识点，每个词条生成“日文 → 中文 / 中文 → 日文 / 听力 → 中文”三个方向卡片。每日新词限制保持不变；重复词会跳过，缺少中文释义的词不会导入。")
        }
        .sheet(isPresented: $isChoosingLevelImportDeck) {
            JLPTLevelImportSheet(
                level: level,
                totalCount: totalCount,
                deckService: deckService
            ) { selection in
                startLevelImport(into: selection)
            }
        }
        .safeAreaInset(edge: .bottom) { importStatus }
        .alert("操作结果", isPresented: resultBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? errorMessage ?? "未知结果")
        }
    }
}

private extension JLPTLevelView {
    @ViewBuilder
    var importStatus: some View {
        if isImporting {
            VStack(spacing: 8) {
                if let importProgress {
                    ProgressView(
                        value: Double(importProgress.processed),
                        total: Double(max(importProgress.total, 1))
                    )
                    Text("已处理 \(importProgress.processed)/\(importProgress.total)")
                        .font(.caption)
                } else {
                    ProgressView("正在准备导入…")
                }
                Button("取消导入", role: .cancel) { importTask?.cancel() }
                    .font(.caption)
            }
            .padding()
            .background(.bar)
        }
    }

    var resultBinding: Binding<Bool> {
        Binding(
            get: { resultMessage != nil || errorMessage != nil },
            set: { shown in
                if !shown {
                    resultMessage = nil
                    errorMessage = nil
                }
            }
        )
    }
}

private extension JLPTLevelView {
    func reload() async {
        do {
            try await Task.sleep(for: .milliseconds(200))
            isLoading = true
            let page = try await libraryService.vocabulary(
                level: level,
                query: query,
                sort: sort
            )
            try Task.checkCancellation()
            items = page.items
            importedSourceRefs = try await importer.importedSourceRefs(page.items.map(\.id))
            nextOffset = page.nextOffset
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let offset = nextOffset, !isLoading else { return }
        do {
            isLoading = true
            let page = try await libraryService.vocabulary(
                level: level,
                query: query,
                sort: sort,
                offset: offset
            )
            items.append(contentsOf: page.items)
            importedSourceRefs.formUnion(
                try await importer.importedSourceRefs(page.items.map(\.id))
            )
            nextOffset = page.nextOffset
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// v0.5.5：整级导入写入用户在确认页选择的既有牌组（可多成员），
    /// 不再自动创建「JLPT Nx」牌组。
    func startLevelImport(into selection: DeckMembershipSelection) {
        guard let homeDeckID = selection.homeDeckID, !selection.deckIDs.isEmpty else {
            return
        }
        importTask?.cancel()
        isImporting = true
        importProgress = nil
        importTask = Task {
            do {
                let all = try await libraryService.vocabulary(
                    level: level,
                    sort: .source,
                    limit: 10_000
                ).items
                let result = try await importer.importLevel(
                    level,
                    vocabulary: all,
                    deckID: homeDeckID,
                    deckIDs: selection.deckIDs,
                    directions: Set(VocabularyCardDirection.allCases)
                ) { progress in
                    await MainActor.run { importProgress = progress }
                }
                importedSourceRefs = try await importer.importedSourceRefs(all.map(\.id))
                isImporting = false
                resultMessage = "导入完成：新增 \(result.imported)，跳过 \(result.skipped)，未导入 \(result.failed)。"
            } catch is CancellationError {
                isImporting = false
                resultMessage = "导入已取消；已完成的批次已安全保留。"
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct JLPTVocabularyRow: View {
    let vocabulary: BuiltinJLPTVocabulary
    let isImported: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(vocabulary.headword).font(.headline)
                if vocabulary.reading != vocabulary.headword {
                    Text(vocabulary.reading)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(vocabulary.meaningZH ?? vocabulary.meaningsEN.joined(separator: "；"))
                .font(.subheadline)
                .foregroundStyle(vocabulary.meaningZH == nil ? .orange : .secondary)
                .lineLimit(2)
            HStack {
                Text(vocabulary.level.rawValue)
                if let pitch = pitchAccentDisplayValue(vocabulary.pitchAccent) {
                    Text("音调 \(pitch)")
                }
                Spacer()
                Text(isImported ? "已加入学习" : "未加入")
            }
            .font(.caption)
            .foregroundStyle(isImported ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }
}

struct JLPTVocabularyDetailView: View {
    let vocabularyID: String
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
    let deckService: DeckManagementService
    let speechService: any SpeechService

    @State private var vocabulary: BuiltinJLPTVocabulary?
    @State private var isLoading = true
    @State private var isShowingImport = false
    @State private var isImported = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let vocabulary {
                List {
                    Section {
                        Text(vocabulary.headword).font(.largeTitle.bold())
                        LabeledContent("假名", value: vocabulary.reading)
                        if let partOfSpeech = vocabulary.partOfSpeech {
                            LabeledContent("词性", value: partOfSpeech)
                        }
                        if let pitch = pitchAccentDisplayValue(vocabulary.pitchAccent) {
                            LabeledContent("音调", value: pitch)
                        }
                        LabeledContent("等级", value: vocabulary.level.rawValue)
                    }

                    Section("中文释义") {
                        if let meaning = vocabulary.meaningZH {
                            Text(meaning)
                        } else {
                            Text("暂无可靠中文匹配；导入前请填写中文释义。")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("英文释义") {
                        ForEach(vocabulary.meaningsEN, id: \.self) { Text($0) }
                    }

                    if !vocabulary.examples.isEmpty {
                        Section("例句") {
                            ForEach(vocabulary.examples) { example in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(example.japanese)
                                    if let translation = example.translationZH {
                                        Text(translation)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let english = example.english {
                                        Text(english)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Button("朗读", systemImage: "speaker.wave.2") {
                            speechService.speak([vocabulary.reading]) { error in
                                errorMessage = error.localizedDescription
                            }
                        }
                        Button {
                            isShowingImport = true
                        } label: {
                            Text("导入到牌组")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Section("学习状态") {
                        Label(
                            isImported ? "已加入学习" : "未加入",
                            systemImage: isImported ? "checkmark.circle.fill" : "circle"
                        )
                        if isImported {
                            Text("已有词条保存在我的牌组中；再次导入会跳过，不会重置复习进度。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .sheet(isPresented: $isShowingImport, onDismiss: {
                    Task { await refreshImportedState() }
                }) {
                    JLPTSingleImportSheet(
                        vocabulary: vocabulary,
                        importer: importer,
                        deckService: deckService
                    )
                }
            } else if isLoading {
                ProgressView("正在读取词条…")
            } else {
                ContentUnavailableView("找不到词条", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("词条详情")
        .secondaryPage()
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadVocabulary() }
        .onDisappear { speechService.stop() }
        .alert("无法完成操作", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func loadVocabulary() async {
        do {
            vocabulary = try await libraryService.vocabulary(id: vocabularyID)
            await refreshImportedState()
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func refreshImportedState() async {
        do {
            isImported = try await importer.importedSourceRefs([vocabularyID]).contains(vocabularyID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct JLPTSingleImportSheet: View {
    let vocabulary: BuiltinJLPTVocabulary
    let importer: any JLPTImporting
    let deckService: DeckManagementService

    @Environment(\.dismiss) private var dismiss
    @State private var decks: [DeckSummary] = []
    @State private var selection = DeckMembershipSelection()
    @State private var meaningZH: String
    @State private var isImporting = false
    @State private var isCreatingDeck = false
    @State private var message: String?

    init(
        vocabulary: BuiltinJLPTVocabulary,
        importer: any JLPTImporting,
        deckService: DeckManagementService
    ) {
        self.vocabulary = vocabulary
        self.importer = importer
        self.deckService = deckService
        _meaningZH = State(initialValue: vocabulary.meaningZH ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("预览") {
                    LabeledContent("日文", value: vocabulary.headword)
                    LabeledContent("假名", value: vocabulary.reading)
                    TextField("中文释义", text: $meaningZH, axis: .vertical)
                }

                Section("目标牌组") {
                    if decks.isEmpty {
                        Text("导入需要至少一个牌组。")
                            .foregroundStyle(.secondary)
                        Button("新建牌组") {
                            isCreatingDeck = true
                        }
                        .accessibilityIdentifier("jlpt-import-create-deck")
                    } else {
                        DeckMembershipField(
                            decks: decks,
                            selection: $selection,
                            rowAccessibilityID: "jlpt-import-deck-picker"
                        )
                    }
                }

                if let message {
                    Section { Text(message) }
                }
            }
            .navigationTitle("导入词条")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "导入中…" : "导入") {
                        Task { await performImport() }
                    }
                    .disabled(!canImport)
                }
            }
            .task { await loadDecks() }
            .sheet(isPresented: $isCreatingDeck) {
                DeckNameEditor(title: "新建牌组", initialName: "") { name in
                    do {
                        _ = try await deckService.createDeck(named: name)
                        await loadDecks()
                        return true
                    } catch {
                        message = error.localizedDescription
                        return false
                    }
                }
            }
        }
    }

    private var canImport: Bool {
        selection.homeDeckID != nil
            && !selection.deckIDs.isEmpty
            && !meaningZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isImporting
    }

    private func loadDecks() async {
        do {
            decks = try await deckService.fetchDecks()
            selection = selection.normalized(decks: decks)
            if selection.deckIDs.isEmpty, let first = decks.first?.id {
                selection = DeckMembershipSelection(single: first)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func performImport() async {
        guard let homeDeckID = selection.homeDeckID, !selection.deckIDs.isEmpty else {
            return
        }
        isImporting = true
        do {
            let result = try await importer.importVocabulary(
                vocabulary,
                deckID: homeDeckID,
                deckIDs: selection.deckIDs,
                meaningZH: meaningZH,
                directions: Set(VocabularyCardDirection.allCases)
            )
            isImporting = false
            if result.imported == 1 {
                dismiss()
            } else {
                message = "这个词已导入，原有复习进度保持不变。"
            }
        } catch {
            isImporting = false
            message = error.localizedDescription
        }
    }
}

/// v0.5.5 整级导入的目标牌组选择页：只写入既有牌组（可额外加入其他
/// 成员牌组）；没有牌组时提供新建入口，不再自动创建「JLPT Nx」牌组。
private struct JLPTLevelImportSheet: View {
    let level: JLPTLevel
    let totalCount: Int
    let deckService: DeckManagementService
    let onConfirm: (DeckMembershipSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var decks: [DeckSummary] = []
    @State private var selection = DeckMembershipSelection()
    @State private var isCreatingDeck = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if decks.isEmpty {
                        Text("导入需要至少一个牌组。")
                            .foregroundStyle(.secondary)
                        Button("新建牌组") {
                            isCreatingDeck = true
                        }
                        .accessibilityIdentifier("jlpt-level-import-create-deck")
                    } else {
                        DeckMembershipField(
                            decks: decks,
                            selection: $selection,
                            rowAccessibilityID: "jlpt-level-import-deck-picker"
                        )
                    }
                } header: {
                    Text("目标牌组")
                } footer: {
                    Text("共 \(totalCount) 个词条；归属牌组决定新卡额度与复习归因。")
                }

                if let message {
                    Section { Text(message) }
                }
            }
            .navigationTitle("导入 \(level.rawValue) 全级")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        onConfirm(selection)
                        dismiss()
                    }
                    .disabled(selection.homeDeckID == nil || selection.deckIDs.isEmpty)
                    .accessibilityIdentifier("jlpt-level-import-confirm")
                }
            }
            .task { await loadDecks() }
            .sheet(isPresented: $isCreatingDeck) {
                DeckNameEditor(title: "新建牌组", initialName: "JLPT \(level.rawValue)") { name in
                    do {
                        _ = try await deckService.createDeck(named: name)
                        await loadDecks()
                        return true
                    } catch {
                        message = error.localizedDescription
                        return false
                    }
                }
            }
        }
    }

    private func loadDecks() async {
        do {
            decks = try await deckService.fetchDecks()
            selection = selection.normalized(decks: decks)
            if selection.deckIDs.isEmpty, let first = decks.first?.id {
                selection = DeckMembershipSelection(single: first)
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
