import OboeDomain
import SwiftUI

struct JLPTDashboardView: View {
    let progressService: JLPTProgressService
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
    let deckService: DeckManagementService
    let speechService: any SpeechService
    /// T25 薄弱词汇：与易错中心同源的单卡服务与详情/编辑入口。
    let adaptiveCardService: AdaptiveCardService
    let contentCardService: ContentCardService
    let aiRepairService: AIRepairService
    /// Builds the existing note detail/editor for a card's note (T04 复用)。
    let noteEditor: (AdaptiveCardItem, @escaping () async -> Void) -> AnyView
    /// T07 修卡页的手动编辑兜底，按 note id + kind 构造。
    let repairNoteEditor: (UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView

    @Environment(\.scenePhase) private var scenePhase
    @State private var target: JLPTLevel = .n5
    @State private var snapshot: JLPTProgressSnapshot?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var requestID = UUID()

    var body: some View {
        List {
            Section {
                Picker("累计目标", selection: $target) {
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .accessibilityIdentifier("jlpt-progress-target")
            } footer: {
                Text("累计包含 \(JLPTLevel.cumulativeLevels(upTo: target).map(\.rawValue).joined(separator: "、"))。按词库条目计数，同词多方向只计一次。")
            }

            if isLoading {
                ProgressView("正在计算学习进度…")
            } else if let errorMessage {
                Section {
                    Text(errorMessage)
                    Button("重试") { Task { await refresh() } }
                } header: { Text("无法读取进度") }
            } else if let snapshot {
                Section {
                    Text("共 \(snapshot.summary.totalEntries) 个词")
                        .accessibilityIdentifier("jlpt-progress-total")
                    ForEach(JLPTWordBucket.displayOrder, id: \.self) { bucket in
                        NavigationLink {
                            JLPTProgressListView(
                                target: target,
                                bucket: bucket,
                                progressService: progressService,
                                libraryService: libraryService,
                                importer: importer,
                                deckService: deckService,
                                speechService: speechService
                            )
                        } label: {
                            LabeledContent(bucket.title, value: "\(snapshot.summary.count(bucket)) 个词")
                        }
                        .accessibilityIdentifier("jlpt-progress-\(bucket.rawValue)")
                    }
                } header: { Text("词汇状态") }
                Section("已加入的辅助状态") {
                    LabeledContent("未开始", value: "\(snapshot.summary.notStartedCount) 个词")
                    LabeledContent("已暂停", value: "\(snapshot.summary.suspendedCount) 个词")
                    Text("未开始指已加入但尚未学习；已暂停指所有方向均暂停。两者属于学习中，可能重叠，不额外增加总数。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink {
                        JLPTWeakVocabularyView(
                            target: target,
                            progressService: progressService,
                            libraryService: libraryService,
                            adaptiveCardService: adaptiveCardService,
                            contentCardService: contentCardService,
                            aiRepairService: aiRepairService,
                            deckService: deckService,
                            noteEditor: noteEditor,
                            repairNoteEditor: repairNoteEditor
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("需要关注")
                            Text("经常遗忘 \(snapshot.weakEntries(matching: .leech).count) 个词 · 近期偏难 \(snapshot.weakEntries(matching: .warning).count) 个词")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("jlpt-weak-entry")
                } footer: {
                    Text("与易错卡中心同一判定规则；每个词只出现一次，可展开查看各薄弱方向并进入卡片详情。")
                }
            }
            Section("统计说明") {
                Text("社区整理的 JLPT 参考词汇，非官方词表；数量随当前词库变化。此处展示学习状态，不代表考试通过率。")
                Text("按经常遗忘、近期遗忘、较稳定、学习中的顺序归类；未关联学习卡的词为未加入。")
                Text("近期遗忘：启用方向最近一次有效评分为近 7 日内的 Again。较稳定：所有启用方向均处于复习态，稳定性至少 21 天，最近评分为 Good/Easy，近 7 日无 Again 且无易错或预警。新增未学方向会回到学习中。")
            }
            .font(.footnote)
        }
        .navigationTitle("JLPT 学习进度")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: target) { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        let token = UUID()
        requestID = token
        isLoading = true
        errorMessage = nil
        do {
            let result = try await progressService.snapshot(targetLevel: target, at: Date())
            try Task.checkCancellation()
            guard token == requestID else { return }
            snapshot = result
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard token == requestID else { return }
            snapshot = nil
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}

private struct JLPTProgressListView: View {
    let target: JLPTLevel
    let bucket: JLPTWordBucket
    let progressService: JLPTProgressService
    let libraryService: JLPTLibraryService
    let importer: any JLPTImporting
    let deckService: DeckManagementService
    let speechService: any SpeechService

    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [JLPTProgressEntry] = []
    @State private var words: [BuiltinJLPTVocabulary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var requestID = UUID()
    private let pageSize = 40

    var body: some View {
        List {
            Section {
                Text("\(target.rawValue) 累计 · \(entries.count) 个词")
                    .accessibilityIdentifier("jlpt-progress-list-total")
                ForEach(words.indices, id: \.self) { index in
                    let word = words[index]
                    let status = entries[index].status
                    NavigationLink {
                        JLPTVocabularyDetailView(
                            vocabularyID: word.id,
                            libraryService: libraryService,
                            importer: importer,
                            deckService: deckService,
                            speechService: speechService
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(word.headword).font(.headline)
                            Text(word.reading).foregroundStyle(.secondary)
                            Text(word.meaningZH ?? word.meaningsEN.joined(separator: "；"))
                            Text([word.level.rawValue, bucket.title,
                                  status.isNotStarted ? "未开始" : nil,
                                  status.isSuspended ? "已暂停" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if isLoading {
                    ProgressView("正在读取词汇…")
                } else if let errorMessage {
                    Text(errorMessage)
                    Button("重试") { Task { await reload() } }
                } else if entries.isEmpty {
                    ContentUnavailableView("此分类暂无词汇", systemImage: "books.vertical")
                } else if words.count < entries.count {
                    Text("已显示 \(words.count) / \(entries.count) 个词")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("jlpt-progress-loaded-count")
                    Button("载入更多") { Task { await loadMore() } }
                        .accessibilityIdentifier("jlpt-progress-load-more")
                }
            }
        }
        .navigationTitle(bucket.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    private func reload() async {
        let token = UUID()
        requestID = token
        isLoading = true
        errorMessage = nil
        do {
            let snapshot = try await progressService.snapshot(targetLevel: target, at: Date())
            let selected = snapshot.entries(in: bucket)
            let page = try await readWords(Array(selected.prefix(pageSize)))
            try Task.checkCancellation()
            guard requestID == token else { return }
            entries = selected
            words = page
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard requestID == token else { return }
            entries = []
            words = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        let token = requestID
        isLoading = true
        do {
            let page = try await readWords(Array(entries.dropFirst(words.count).prefix(pageSize)))
            try Task.checkCancellation()
            guard requestID == token else { return }
            words.append(contentsOf: page)
            isLoading = false
        } catch {
            guard requestID == token else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func readWords(_ page: [JLPTProgressEntry]) async throws -> [BuiltinJLPTVocabulary] {
        var result: [BuiltinJLPTVocabulary] = []
        for entry in page {
            try Task.checkCancellation()
            guard let word = try await libraryService.vocabulary(id: entry.id) else {
                throw JLPTProgressListError.missingVocabulary
            }
            result.append(word)
        }
        return result
    }
}

private enum JLPTProgressListError: LocalizedError {
    case missingVocabulary
    var errorDescription: String? { "词库条目已变化，请重试以重新计算分类。" }
}

/// T25「需要关注」词汇列表（设计 §11.2）：按词去重，复用
/// `AdaptiveListFilter` 的同一筛选规则；每个词可展开查看匹配筛选的
/// 薄弱方向，方向行进入与易错中心相同的 `AdaptiveCardDetailView`
/// （暂停/编辑/AI 修卡）。卡级状态永远来自 `LeechClassifier` ——
/// 这里不维护第二套阈值。
private struct JLPTWeakVocabularyView: View {
    let target: JLPTLevel
    let progressService: JLPTProgressService
    let libraryService: JLPTLibraryService
    let adaptiveCardService: AdaptiveCardService
    let contentCardService: ContentCardService
    let aiRepairService: AIRepairService
    let deckService: DeckManagementService
    let noteEditor: (AdaptiveCardItem, @escaping () async -> Void) -> AnyView
    let repairNoteEditor: (UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView

    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: AdaptiveListFilter = .leech
    @State private var entries: [JLPTProgressEntry] = []
    @State private var weakCounts: [AdaptiveListFilter: Int] = [:]
    @State private var words: [BuiltinJLPTVocabulary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var requestID = UUID()
    private let pageSize = 40

    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(AdaptiveListFilter.allCases, id: \.self) { item in
                        Text("\(item.weakFilterTitle) \(weakCounts[item] ?? 0)")
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("jlpt-weak-filter-picker")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                Text("\(target.rawValue) 累计 · \(entries.count) 个词")
                    .accessibilityIdentifier("jlpt-weak-total")
                ForEach(words.indices, id: \.self) { index in
                    JLPTWeakVocabularyRow(
                        word: words[index],
                        entry: entries[index],
                        filter: filter,
                        adaptiveCardService: adaptiveCardService,
                        contentCardService: contentCardService,
                        aiRepairService: aiRepairService,
                        deckService: deckService,
                        noteEditor: noteEditor,
                        repairNoteEditor: repairNoteEditor,
                        onChanged: { await reload() }
                    )
                }
                if isLoading {
                    ProgressView("正在分析薄弱词汇…")
                } else if let errorMessage {
                    Text(errorMessage)
                    Button("重试") { Task { await reload() } }
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        filter.weakEmptyTitle,
                        systemImage: "checkmark.circle",
                        description: Text(filter.weakEmptyDescription)
                    )
                    .accessibilityIdentifier("jlpt-weak-empty-\(filter.rawValue)")
                } else if words.count < entries.count {
                    Text("已显示 \(words.count) / \(entries.count) 个词")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("jlpt-weak-loaded-count")
                    Button("载入更多") { Task { await loadMore() } }
                        .accessibilityIdentifier("jlpt-weak-load-more")
                }
            } footer: {
                Text("卡片状态与易错卡中心一致；进入方向详情可暂停、编辑或 AI 修卡，返回后自动重新计算。")
                    .font(.footnote)
            }
        }
        .navigationTitle("需要关注")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) { await reload() }
        .refreshable { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
    }

    private func reload() async {
        let token = UUID()
        requestID = token
        isLoading = true
        errorMessage = nil
        do {
            let snapshot = try await progressService.snapshot(targetLevel: target, at: Date())
            var counts: [AdaptiveListFilter: Int] = [:]
            var selected: [JLPTProgressEntry] = []
            for item in AdaptiveListFilter.allCases {
                let weak = snapshot.weakEntries(matching: item)
                counts[item] = weak.count
                if item == filter { selected = weak }
            }
            let page = try await readWords(Array(selected.prefix(pageSize)))
            try Task.checkCancellation()
            guard requestID == token else { return }
            weakCounts = counts
            entries = selected
            words = page
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard requestID == token else { return }
            entries = []
            words = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        let token = requestID
        isLoading = true
        do {
            let page = try await readWords(Array(entries.dropFirst(words.count).prefix(pageSize)))
            try Task.checkCancellation()
            guard requestID == token else { return }
            words.append(contentsOf: page)
            isLoading = false
        } catch {
            guard requestID == token else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func readWords(_ page: [JLPTProgressEntry]) async throws -> [BuiltinJLPTVocabulary] {
        var result: [BuiltinJLPTVocabulary] = []
        for entry in page {
            try Task.checkCancellation()
            guard let word = try await libraryService.vocabulary(id: entry.id) else {
                throw JLPTProgressListError.missingVocabulary
            }
            result.append(word)
        }
        return result
    }
}

/// One weak word: appears exactly once per library entry; expanding lists
/// the directions matching the current filter, each linking to the shared
/// adaptive card detail.
private struct JLPTWeakVocabularyRow: View {
    let word: BuiltinJLPTVocabulary
    let entry: JLPTProgressEntry
    let filter: AdaptiveListFilter
    let adaptiveCardService: AdaptiveCardService
    let contentCardService: ContentCardService
    let aiRepairService: AIRepairService
    let deckService: DeckManagementService
    let noteEditor: (AdaptiveCardItem, @escaping () async -> Void) -> AnyView
    let repairNoteEditor: (UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView
    let onChanged: () async -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(entry.weakCards(matching: filter), id: \.cardID) { card in
                NavigationLink {
                    AdaptiveCardDetailView(
                        service: adaptiveCardService,
                        cardID: card.cardID,
                        contentCardService: contentCardService,
                        aiRepairService: aiRepairService,
                        deckService: deckService,
                        noteEditor: noteEditor,
                        repairNoteEditor: repairNoteEditor,
                        onChanged: onChanged
                    )
                } label: {
                    HStack(spacing: 8) {
                        Text(card.templateKind.adaptiveDirectionLabel)
                            .font(.subheadline)
                        if !card.isEnabled {
                            Text("已暂停")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(card.adaptiveStatus.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(card.adaptiveStatus.tint.opacity(0.12), in: Capsule())
                            .foregroundStyle(card.adaptiveStatus.tint)
                    }
                }
                .accessibilityIdentifier("jlpt-weak-card-\(card.cardID.uuidString)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(word.headword)
                    .font(.headline)
                    .accessibilityIdentifier("jlpt-weak-word-\(word.id)")
                Text(word.reading).foregroundStyle(.secondary)
                Text(word.meaningZH ?? word.meaningsEN.joined(separator: "；"))
                Text("\(word.level.rawValue) · \(entry.weakCards(matching: filter).count) 个薄弱方向")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}

private extension AdaptiveListFilter {
    var weakFilterTitle: String {
        switch self {
        case .leech: "易错"
        case .warning: "预警"
        case .suspended: "已暂停"
        }
    }

    var weakEmptyTitle: String {
        switch self {
        case .leech: "当前没有易错词汇"
        case .warning: "当前没有预警词汇"
        case .suspended: "没有已暂停的方向"
        }
    }

    var weakEmptyDescription: String {
        switch self {
        case .leech: "该累计范围内暂无经常遗忘的词汇。"
        case .warning: "该累计范围内暂无接近易错阈值的词汇。"
        case .suspended: "暂停的方向保留学习记录，可随时在详情中重新启用。"
        }
    }
}

private extension JLPTWordBucket {
    static let displayOrder: [Self] = [.notAdded, .learning, .stable, .recentlyForgotten, .frequentlyForgotten]
    var title: String {
        switch self {
        case .notAdded: "未加入"
        case .learning: "学习中"
        case .stable: "较稳定"
        case .recentlyForgotten: "近期遗忘"
        case .frequentlyForgotten: "经常遗忘"
        }
    }
}
