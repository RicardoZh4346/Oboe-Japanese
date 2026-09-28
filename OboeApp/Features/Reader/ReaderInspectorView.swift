import OboeDomain
import OboeInfrastructure
import SwiftUI

/// S11 挖词 Inspector（sheet）：候选列表 + 义项选择 + 既有 Note
/// 「只加来源」+ 知识状态操作 + 目标牌组 + 挖词/编辑后挖词。
///
/// ambiguous 保护：`lookup.requiresSelection` 时顶部给出说明，
/// 未点选候选前挖词按钮保持禁用（`model.canMine`）。
struct ReaderInspectorView: View {
    @State private var model: ReaderInspectorViewModel
    @Environment(\.dismiss) private var dismiss
    /// 「编辑后挖词」sheet：VM 通过依赖包里的 editorFactory 产出
    /// 已装好提交回调的 AddContentEditorView。
    @State private var editorPresentation: EditorPresentation?

    init(model: ReaderInspectorViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("正在查词…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .navigationTitle(model.tap.surface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        model.dismiss()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { model.load() }
        .onDisappear { model.dismiss() }
        .onChange(of: model.editorDraft != nil) { _, hasDraft in
            if hasDraft {
                editorPresentation = model.makeEditorPresentation()
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            presentation.view
        }
        // S13「挖句成卡」：以点中 token 为 blank 的句卡创建表单，
        // sheet 叠在 Inspector 之上——保存成功即连同本层关闭。
        .sheet(item: .init(
            get: { model.clozeDraft },
            set: { if $0 == nil { model.clearClozeDraft() } }
        )) { draft in
            ReaderClozeCreateView(
                model: ReaderClozeCreateViewModel(
                    draft: draft, dependencies: model.miningDependencies
                )
            )
        }
        .alert("提示", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// sheet(item:) 需要 Identifiable——对工厂产出的视图装箱。
    struct EditorPresentation: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    @ViewBuilder
    private var content: some View {
        List {
            contextSection
            candidateSection
            senseSection
            existingNoteSection
            knowledgeSection
            deckSection
            actionSection
        }
    }

    // MARK: - 区块

    private var contextSection: some View {
        Section("原文") {
            Text(model.context.sentence)
                .font(.body)
                .textSelection(.enabled)
            if let title = model.context.sourceTitle {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var candidateSection: some View {
        Section {
            if let lookup = model.lookup {
                if lookup.requiresSelection {
                    Text("该词有多个候选，请显式选择一个再操作。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(lookup.candidates) { candidate in
                    candidateRow(candidate)
                }
            }
        } header: {
            Text("候选")
        }
    }

    private func candidateRow(
        _ candidate: ReaderMiningCandidate
    ) -> some View {
        Button {
            model.selectedCandidateKey = candidate.lexicalKey.identityKey
            model.selectedExistingNoteID = nil
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: model.selectedCandidateKey
                    == candidate.lexicalKey.identityKey
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(OboeTheme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(candidate.writtenForm)
                            .foregroundStyle(.primary)
                        if let reading = candidate.reading,
                           reading != candidate.writtenForm {
                            Text(reading)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        knowledgeBadge(candidate.knowledgeState)
                    }
                    if let gloss = candidate.senses.first {
                        Text(gloss.glossText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if candidate.entryID == nil {
                        Text("词典外词（自建）")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(candidate.linkedNotes) { note in
                        Text("已关联：\(note.headword)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .accessibilityAddTraits(
            model.selectedCandidateKey == candidate.lexicalKey.identityKey
                ? .isSelected : []
        )
        .accessibilityIdentifier(
            "inspector-candidate-\(candidate.lexicalKey.identityKey)"
        )
    }

    private var senseSection: some View {
        Group {
            if let candidate = model.selectedCandidate,
               !candidate.senses.isEmpty {
                Section("义项") {
                    ForEach(candidate.senses) { sense in
                        Button {
                            model.selectedSenseID = sense.id
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: model.selectedSenseID
                                    == sense.id
                                    ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(OboeTheme.Colors.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sense.glossText.isEmpty
                                         ? "（无释义）" : sense.glossText)
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        if !sense.posCodes.isEmpty {
                                            Text(sense.posCodes
                                                .joined(separator: "·"))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        if let lang = sense.glossLanguage,
                                           lang != "zho" {
                                            Text("释义语言：\(lang)")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                        .accessibilityAddTraits(
                            model.selectedSenseID == sense.id
                                ? .isSelected : []
                        )
                        .accessibilityIdentifier(
                            "inspector-sense-\(sense.id)"
                        )
                    }
                }
            }
        }
    }

    private var existingNoteSection: some View {
        Group {
            if let lookup = model.lookup, !lookup.duplicateNotes.isEmpty {
                Section {
                    ForEach(lookup.duplicateNotes) { note in
                        Button {
                            model.selectedExistingNoteID =
                                model.selectedExistingNoteID == note.noteID
                                    ? nil : note.noteID
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: model.selectedExistingNoteID
                                    == note.noteID
                                    ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(OboeTheme.Colors.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.headword)
                                        .foregroundStyle(.primary)
                                    Text(note.meaningZH)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .accessibilityAddTraits(
                            model.selectedExistingNoteID == note.noteID
                                ? .isSelected : []
                        )
                        .accessibilityIdentifier(
                            "inspector-existing-\(note.noteID.uuidString)"
                        )
                    }
                } header: {
                    Text("已有笔记")
                } footer: {
                    Text("勾选后挖词只给该笔记追加来源与牌组成员，不新建卡片。")
                        .font(.footnote)
                }
            }
        }
    }

    /// 「自动」＝ 无人工覆盖，状态由制卡情况判定（未制卡=未知、
    /// 挖词后=学习中）；「已知/已忽略」＝ 人工覆盖，措辞与图例一致。
    private var knowledgeSection: some View {
        Section {
            Picker("标注方式", selection: knowledgeBinding) {
                Text("自动").tag(KnowledgeOverride?.none)
                Text("已知").tag(KnowledgeOverride?.some(.known))
                Text("已忽略").tag(KnowledgeOverride?.some(.ignored))
            }
            .pickerStyle(.segmented)
            // 标记任务可取消、最新值生效——picker 全程保持可点。
            .disabled(model.selectedCandidate == nil)
            .accessibilityIdentifier("inspector-knowledge-override-picker")
        } header: {
            HStack {
                Text("知识状态")
                Spacer()
                if let candidate = model.selectedCandidate {
                    knowledgeBadge(displayedState(of: candidate))
                }
            }
        } footer: {
            Text("「自动」按是否已制卡判定：未制卡记为未知，挖词后自动转学习中。")
                .font(.footnote)
        }
    }

    /// Picker 选择 ←→ 人工覆盖：已知/已忽略恒来自 override，故
    /// 解析态可直接反推；其余解析态一律回落到「自动」。
    private var knowledgeBinding: Binding<KnowledgeOverride?> {
        Binding(
            get: {
                // 有 pending 选择先回显（乐观更新），否则按解析态反推：
                // 已知/已忽略恒来自 override；其余解析态一律「自动」。
                if let pending = model.pendingMark {
                    return pending.override
                }
                return switch model.selectedCandidate?.knowledgeState {
                case .known: .known
                case .ignored: .ignored
                default: nil
                }
            },
            set: { model.mark($0) }
        )
    }

    private var deckSection: some View {
        Section {
            if model.decks.isEmpty {
                Text("尚无牌组——请先在牌组页创建。")
                    .foregroundStyle(.secondary)
            } else {
                Picker("目标牌组", selection: .init(
                    get: { model.targetDeckID },
                    set: { model.targetDeckID = $0 }
                )) {
                    ForEach(model.decks) { deck in
                        Text(deck.name).tag(Optional(deck.id))
                    }
                }
                .accessibilityIdentifier("inspector-deck-picker")
                if model.decks.count > 1 {
                    ForEach(model.decks) { deck in
                        if deck.id != model.targetDeckID {
                            Toggle(isOn: .init(
                                get: {
                                    model.additionalDeckIDs.contains(deck.id)
                                },
                                set: { on in
                                    if on {
                                        model.additionalDeckIDs.insert(deck.id)
                                    } else {
                                        model.additionalDeckIDs.remove(deck.id)
                                    }
                                }
                            )) {
                                Text("同时加入「\(deck.name)」")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("牌组")
        }
    }

    private var actionSection: some View {
        Section {
            if let notice = model.noticeMessage {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.mine()
            } label: {
                Label("挖词", systemImage: "plus.rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canMine)
            .accessibilityIdentifier("inspector-mine")
            if model.canEditThenMine {
                Button {
                    model.openEditor()
                } label: {
                    Label("编辑后挖词", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("inspector-mine-edit")
            }
            // S13：以本句建 cloze 卡（blank = 点中 token）——不需
            // 候选选定即可进入；lemma 预填取当前显式候选。
            Button {
                model.openClozeCreate()
            } label: {
                Label("挖句成卡", systemImage: "rectangle.dashed")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.isBusy || model.targetDeckID == nil)
            .accessibilityIdentifier("inspector-create-cloze")
        }
    }

    /// pending 选择优先：known/ignored 立即回显；auto 的真值要等
    /// 服务端解析，沿用当前徽章。
    private func displayedState(
        of candidate: ReaderMiningCandidate
    ) -> VocabularyKnowledgeState {
        switch model.pendingMark {
        case .known: .known
        case .ignored: .ignored
        case .auto, nil: candidate.knowledgeState
        }
    }

    private func knowledgeBadge(
        _ state: VocabularyKnowledgeState
    ) -> some View {
        let (label, color): (String, Color) = switch state {
        case .known: ("已知", .primary)
        case .learning: ("学习中", OboeTheme.Colors.accent)
        case .unknown: ("未知", .orange)
        case .ignored: ("已忽略", Color(.secondaryLabel))
        }
        return Text(label)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// 批量挖词队列（sheet）：批量选词态下入队的 token 列表——
/// 逐行 lookup、勾选/改选候选、开始/取消、结束摘要。
struct ReaderBatchMiningSheet: View {
    @State private var model: ReaderBatchMiningViewModel
    @Environment(\.dismiss) private var dismiss

    init(model: ReaderBatchMiningViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            List {
                if let summary = model.summary {
                    Section("摘要") {
                        Text(batchSummaryText(summary))
                            .font(.subheadline)
                        ForEach(summary.failures, id: \.operationID) { f in
                            Text("\(f.label)：\(f.errorDescription)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Picker("目标牌组", selection: .init(
                        get: { model.targetDeckID },
                        set: { model.targetDeckID = $0 }
                    )) {
                        ForEach(model.decks) { deck in
                            Text(deck.name).tag(Optional(deck.id))
                        }
                    }
                }
                Section("队列（\(model.items.count)）") {
                    ForEach(model.items) { item in
                        batchRow(item)
                    }
                    .onDelete { indexes in
                        for index in indexes {
                            model.remove(model.items[index])
                        }
                    }
                }
            }
            .navigationTitle("批量挖词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isRunning {
                        Button("取消", role: .destructive) {
                            model.cancel()
                        }
                    } else {
                        Button("开始挖词") { model.start() }
                            .disabled(
                                model.items.isEmpty
                                    || model.targetDeckID == nil
                            )
                            .accessibilityIdentifier("batch-mine-start")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { model.load() }
        .onDisappear { model.cancel() }
    }

    private func batchSummaryText(
        _ summary: ReaderMiningBatchSummary
    ) -> String {
        var parts = [
            "共 \(summary.totalCount) 项",
            "新建 \(summary.committedCount)"
        ]
        if summary.replayedCount > 0 {
            parts.append("回放 \(summary.replayedCount)")
        }
        if summary.skippedCount > 0 {
            parts.append("跳过 \(summary.skippedCount)")
        }
        if summary.requiresSelectionCount > 0 {
            parts.append("待选择 \(summary.requiresSelectionCount)")
        }
        if summary.cancelledCount > 0 {
            parts.append("已取消 \(summary.cancelledCount)")
        }
        if !summary.failures.isEmpty {
            parts.append("失败 \(summary.failures.count)")
        }
        return parts.joined(separator: "，")
    }

    private func batchRow(_ item: ReaderBatchMiningViewModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // List 行内按钮用 .borderless + 整行 contentShape——
            // .plain/默认样式在 List cell 里命中区不可靠（真机上
            // 会只剩最末子视图可点）。
            Button {
                // 方形勾 = 该项是否参与挖掘：取消勾选时连带清空
                // 候选选择，重新勾选后需重新显式选定。
                let binding = itemBinding(for: item)
                var value = binding.wrappedValue
                value.isSelected.toggle()
                if !value.isSelected {
                    value.selectedCandidateKey = nil
                    value.selectedSenseID = nil
                }
                binding.wrappedValue = value
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.isSelected
                        ? "checkmark.square.fill" : "square")
                        .foregroundStyle(OboeTheme.Colors.accent)
                    Text(item.tap.surface)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(item.isSelected ? .isSelected : [])
            .accessibilityIdentifier("batch-item-\(item.id)")
            if item.isLoading {
                Text("查词中…").font(.footnote).foregroundStyle(.secondary)
            } else if item.lookupFailed {
                Text("查词失败——该项将计为失败")
                    .font(.footnote).foregroundStyle(.orange)
            } else if let lookup = item.lookup {
                ForEach(lookup.candidates) { candidate in
                    Button {
                        let binding = itemBinding(for: item)
                            .selectedCandidateKey
                        let key = candidate.lexicalKey.identityKey
                        // 切换语义：点已选中的取消，点其他候选换选——
                        // 单向赋值下歧义项一旦选错就回不去。
                        binding.wrappedValue =
                            binding.wrappedValue == key ? nil : key
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.selectedCandidateKey
                                == candidate.lexicalKey.identityKey
                                ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(OboeTheme.Colors.accent)
                            Text(candidate.writtenForm)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if let reading = candidate.reading {
                                Text(reading)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let gloss = candidate.senses.first {
                                Text(gloss.glossText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    // 未勾选该项时候选不可点——先勾上方形勾。
                    .disabled(!item.isSelected)
                    .accessibilityAddTraits(
                        item.selectedCandidateKey
                            == candidate.lexicalKey.identityKey
                            ? .isSelected : []
                    )
                    .accessibilityIdentifier(
                        "batch-candidate-\(item.id)-\(candidate.lexicalKey.identityKey)"
                    )
                }
                if item.isSelected && lookup.requiresSelection
                    && item.selectedCandidateKey == nil {
                    Text("歧义候选——需显式选择，否则该项跳过。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// `ForEach` 的 item 是值拷贝——绑定写回 `model.items` 原数组。
    private func itemBinding(
        for item: ReaderBatchMiningViewModel.Item
    ) -> Binding<ReaderBatchMiningViewModel.Item> {
        Binding(
            get: {
                model.items.first { $0.id == item.id } ?? item
            },
            set: { newValue in
                if let index = model.items.firstIndex(
                    where: { $0.id == item.id }
                ) {
                    model.items[index] = newValue
                }
            }
        )
    }
}

/// 「编辑后挖词」编辑器宿主：把 Reader 侧载荷接到
/// `AddContentEditorView`（服务集取自容器；牌组选择/方向/草稿机制
/// 全沿用）。提交成功后 `onCommitted` 回调补 lexeme↔Note 关联。
struct ReaderMiningEditorHost: View {
    let draft: ReaderEditorDraft
    let container: AppFeatureContainer
    let onCommitted: @MainActor (UUID) -> Void

    var body: some View {
        let decks = container.decks
        NavigationStack {
            AddContentEditorView(
                deckService: decks.deckService,
                vocabularyService: decks.vocabularyService,
                grammarService: decks.grammarService,
                knowledgePointService: decks.knowledgePointService,
                contentCardService: decks.contentCardService,
                aiCardGenerationService: decks.aiCardGenerationService,
                sentenceAnalysisService: decks.sentenceAnalysisService,
                sentenceAnalysisCardCreationService: decks.sentenceAnalysisCardCreationService,
                historyService: decks.historyService,
                speechService: container.shared.speechService,
                studyService: decks.studyService,
                requiredDeckID: draft.requiredDeckID,
                vocabularyPrefill: draft.form,
                sourceContextDraft: draft.source,
                dictionaryQueryService: container.dictionary.queryService,
                sourceContextRepository: container.shared.sourceContextRepository,
                onVocabularyCommitted: onCommitted,
                title: "挖词"
            )
        }
    }
}
