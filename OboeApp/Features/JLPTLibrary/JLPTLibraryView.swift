import OboeDomain
import SwiftUI

struct JLPTLibraryView: View {
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
    let deckService: DeckManagementService
    let speechService: any SpeechService

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
        .task { await refresh() }
        .sheet(isPresented: $isShowingNotice) { noticeSheet }
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
        .confirmationDialog(
            "导入 \(level.rawValue) 全部可用词汇？",
            isPresented: $isConfirmingLevelImport,
            titleVisibility: .visible
        ) {
            Button("导入到 JLPT \(level.rawValue) 牌组") { startLevelImport() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(totalCount) 个词条。将创建或复用 1 个“JLPT \(level.rawValue)”牌组，最多新增 \(totalCount) 个知识点和同数量的“日文 → 中文”卡片。每日新卡限制保持不变；重复词会跳过，缺少中文释义的词不会导入。")
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

    func startLevelImport() {
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
                    directions: [.japaneseToChinese]
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
                Spacer()
                Text(isImported ? "已加入学习" : "未加入")
            }
            .font(.caption)
            .foregroundStyle(isImported ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct JLPTVocabularyDetailView: View {
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
                        Button("导入到牌组", systemImage: "square.and.arrow.down") {
                            isShowingImport = true
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
    @State private var selectedDeckID: UUID?
    @State private var meaningZH: String
    @State private var japaneseToChinese = true
    @State private var chineseToJapanese = false
    @State private var isImporting = false
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
                        Text("请先在牌组页创建一个牌组。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("牌组", selection: $selectedDeckID) {
                            ForEach(decks) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                    }
                }

                Section("卡片方向") {
                    Toggle("日文 → 中文", isOn: $japaneseToChinese)
                    Toggle("中文 → 日文", isOn: $chineseToJapanese)
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
        }
    }

    private var canImport: Bool {
        selectedDeckID != nil
            && !meaningZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (japaneseToChinese || chineseToJapanese)
            && !isImporting
    }

    private func loadDecks() async {
        do {
            decks = try await deckService.fetchDecks()
            selectedDeckID = selectedDeckID ?? decks.first?.id
        } catch {
            message = error.localizedDescription
        }
    }

    private func performImport() async {
        guard let selectedDeckID else { return }
        var directions = Set<VocabularyCardDirection>()
        if japaneseToChinese { directions.insert(.japaneseToChinese) }
        if chineseToJapanese { directions.insert(.chineseToJapanese) }
        isImporting = true
        do {
            let result = try await importer.importVocabulary(
                vocabulary,
                deckID: selectedDeckID,
                meaningZH: meaningZH,
                directions: directions
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
