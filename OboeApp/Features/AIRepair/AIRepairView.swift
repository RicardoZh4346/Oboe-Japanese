import OboeDomain
import SwiftUI

/// AI 修卡 (T07/T08): resumable analysis session for one card. Suggestions
/// stay candidates until the user confirms adoption in the preview — only
/// then does the guarded commit transaction write to the Note.
struct AIRepairView: View {
    let cardID: UUID
    /// Builds the existing note editor for the draft's target — the always-
    /// available manual fallback ("不可用时可继续手动编辑和学习").
    let noteEditor: ((UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView)?
    /// Fired when the session ends so callers can refresh evidence.
    let onChanged: () async -> Void
    /// Fired once a suggestion commit lands — review uses it to re-present
    /// the question face with cleared input.
    let onCommitted: () async -> Void

    @State private var model: AIRepairViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        service: AIRepairService,
        cardID: UUID,
        deckService: DeckManagementService? = nil,
        noteEditor: ((UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView)? = nil,
        onChanged: @escaping () async -> Void = {},
        onCommitted: @escaping () async -> Void = {}
    ) {
        self.cardID = cardID
        self.noteEditor = noteEditor
        self.onChanged = onChanged
        self.onCommitted = onCommitted
        _model = State(initialValue: AIRepairViewModel(
            service: service,
            cardID: cardID,
            deckService: deckService,
            onCommitted: onCommitted
        ))
    }

    var body: some View {
        Group {
            if model.isLoading, model.envelope == nil {
                ProgressView("正在载入修卡草稿…")
                    .accessibilityIdentifier("ai-repair-loading")
            } else if let error = model.loadErrorMessage, model.envelope == nil {
                ContentUnavailableView(
                    "无法开始修卡",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .accessibilityIdentifier("ai-repair-load-error")
            } else {
                content
            }
        }
        .navigationTitle("AI 修卡")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onDisappear {
            Task { await model.persistComment() }
        }
    }

    private var content: some View {
        List {
            contextSection
            if model.isBlocked {
                blockedSection
            } else {
                commentSection
                analysisSection
                if model.isCommitted {
                    committedSection
                }
                if model.showsSuggestions {
                    suggestionsSection
                }
            }
            manualSection
        }
        .scrollContentBackground(.hidden)
        .background(OboeTheme.Colors.pageBackground)
        .accessibilityIdentifier("ai-repair-content")
    }

    /// Honest context explainer — what the request carries and what it can
    /// never contain (设计 §6.1 白名单).
    private var contextSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("分析会发送这张卡的内容、学习方向、近期遗忘统计和你的补充说明，不包含任何账号或历史明细。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("AI 建议仅供参考，确认后才会修改卡片。")
                    .font(.footnote.weight(.medium))
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("ai-repair-context")
    }

    private var commentSection: some View {
        Section {
            TextField(
                "可选：说明你觉得哪里难记（如：总和其他词混淆）",
                text: $model.comment,
                axis: .vertical
            )
            .lineLimit(2...5)
            .accessibilityIdentifier("ai-repair-comment")
            HStack {
                Spacer()
                Text("\(model.comment.utf16.count) / 1000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.commentIsOverLimit ? .red : .secondary)
            }
        } header: {
            Text("补充说明")
        }
        .accessibilityIdentifier("ai-repair-comment-section")
    }

    private var analysisSection: some View {
        Section {
            if model.showsAnalyzingState {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在分析…")
                    Spacer()
                    Button("取消") {
                        model.cancelAnalysis()
                    }
                    .accessibilityIdentifier("ai-repair-cancel")
                }
                .accessibilityIdentifier("ai-repair-analyzing")
            } else {
                Button {
                    model.analyze()
                } label: {
                    Label(
                        model.phase == .suggested ? "重新分析" : "分析这张卡",
                        systemImage: "sparkles"
                    )
                }
                .disabled(!model.canAnalyze || model.commentIsOverLimit)
                .accessibilityIdentifier("ai-repair-analyze")
            }
            if let error = model.analysisErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ai-repair-error")
            }
        } header: {
            Text("AI 分析")
        }
    }

    /// Post-commit confirmation banner — the draft is finished; the receipt
    /// stays visible so the adopted state is reviewable after returning.
    private var committedSection: some View {
        Section {
            Label(committedTitle, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
            Text(committedDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ai-repair-committed")
    }

    /// Split receipts carry created ids — their banner reports the split
    /// outcome; in-place receipts have none and keep the original wording.
    private var committedTitle: String {
        guard let receipt = model.committedReceipt,
              !receipt.createdNoteIDs.isEmpty else {
            return "已采用建议，卡片内容已更新。"
        }
        return "已拆分为 \(receipt.createdNoteIDs.count) 个新笔记。"
    }

    private var committedDetail: String {
        guard let receipt = model.committedReceipt,
              !receipt.createdNoteIDs.isEmpty else {
            return "学习进度与复习记录不受影响。"
        }
        let disposition: String
        switch receipt.originalCardDisposition {
        case .keep: disposition = "保留"
        case .pause: disposition = "暂停"
        case .delete: disposition = "删除"
        }
        return "共创建 \(receipt.createdCardIDs.count) 张新卡；原卡已\(disposition)，其复习历史保留。"
    }

    private var suggestionsSection: some View {
        Section {
            if let summary = model.responseSummary {
                Text(summary)
                    .font(.subheadline)
                    .accessibilityIdentifier("ai-repair-summary")
            }
            if !model.problemTypes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.problemTypes, id: \.self) { problem in
                        Text(problem.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .accessibilityIdentifier("ai-repair-problems")
            }
            if let edited = model.editedCandidate {
                NavigationLink {
                    AIRepairSuggestionPreviewView(
                        model: model,
                        suggestion: edited,
                        suggestionIndex: -1,
                        isEditedCandidate: true,
                        preview: model.editedPreview,
                        affectedKinds: model.envelope?.affectedTemplateKinds ?? []
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(edited.title)
                                .font(.subheadline.weight(.medium))
                            Text(edited.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: "pencil")
                            .foregroundStyle(OboeTheme.Colors.accent)
                    }
                }
                .accessibilityIdentifier("ai-repair-suggestion-edited")
            }
            ForEach(Array(model.suggestions.enumerated()), id: \.element.title) { index, suggestion in
                NavigationLink {
                    AIRepairSuggestionPreviewView(
                        model: model,
                        suggestion: suggestion,
                        suggestionIndex: index,
                        isEditedCandidate: false,
                        preview: model.preview(for: suggestion),
                        affectedKinds: model.envelope?.affectedTemplateKinds ?? []
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(suggestion.title)
                                .font(.subheadline.weight(.medium))
                            Text(suggestion.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } icon: {
                        Image(systemName: suggestion.type.systemImage)
                            .foregroundStyle(OboeTheme.Colors.accent)
                    }
                }
                .accessibilityIdentifier("ai-repair-suggestion-\(suggestion.type.rawValue)")
            }
        } header: {
            Text(model.isCommitted ? "建议" : "建议（候选，不会自动应用）")
        }
        .accessibilityIdentifier("ai-repair-suggestions")
    }

    private var blockedSection: some View {
        Section {
            Label(
                "目标卡片或笔记已不可用，这份草稿仅供查看，不能继续修卡。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let comment = model.envelope?.userComment, !comment.isEmpty {
                LabeledContent("你的说明", value: comment)
            }
        }
        .accessibilityIdentifier("ai-repair-blocked")
    }

    private var manualSection: some View {
        Section {
            if let noteEditor, let envelope = model.envelope,
               let kind = envelope.affectedTemplateKinds.first?.knowledgePointKind {
                NavigationLink {
                    noteEditor(envelope.targetNoteID, kind) {
                        await model.load()
                        await onChanged()
                    }
                } label: {
                    Label("手动编辑卡片", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("ai-repair-manual-edit")
            } else {
                Text("关闭本页即可继续学习，手动编辑可在卡片详情或牌组页面进行。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("其他方式")
        }
    }
}

/// Candidate detail (T08): type, reason, field-level 修改前→修改后 diff (or
/// the split candidate contents), the affected directions — and, for an
/// in-place suggestion, the guarded adopt path. Opening this page never
/// writes anything; adoption requires an explicit confirmation.
private struct AIRepairSuggestionPreviewView: View {
    let model: AIRepairViewModel
    let suggestion: AIRepairSuggestion
    /// Response index — `-1` for the stored edited candidate (the service
    /// resolves it through `isEditedCandidate` and ignores the index).
    let suggestionIndex: Int
    let isEditedCandidate: Bool
    let preview: AIRepairSuggestionPreview?
    let affectedKinds: [CardTemplateKind]

    @State private var adoptEditedCandidate = false
    @State private var showsAdoptConfirmation = false
    @State private var showsEditSheet = false
    /// The saved edited candidate adopts through the same confirmation — the
    /// alert only fires after the edit sheet has fully dismissed.
    @State private var pendingEditedAdopt = false
    /// T09 split picks: per-candidate direction sets (index → kinds),
    /// the target deck membership (home + members) and the required
    /// original-card disposition — nil until the user picks one
    /// (推荐暂停只是标签，不是默认值).
    @State private var splitDirections: [Int: Set<CardTemplateKind>] = [:]
    @State private var splitMembership = DeckMembershipSelection()
    @State private var splitDisposition: AIRepairOriginalCardDisposition?
    @State private var showsSplitConfirmation = false

    private var isSplit: Bool {
        suggestion.type == .splitCard
    }

    var body: some View {
        List {
            Section {
                LabeledContent("建议类型", value: suggestion.type.title)
                Text(suggestion.title)
                    .font(.subheadline.weight(.medium))
                Text(suggestion.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("ai-repair-preview-header")

            if let preview {
                if !preview.changes.isEmpty {
                    Section("修改前后对照") {
                        ForEach(preview.changes, id: \.field) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.field.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(change.before.isEmpty ? "（空）" : change.before)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .strikethrough(false)
                                Image(systemName: "arrow.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(change.after.isEmpty ? "（清空）" : change.after)
                                    .font(.footnote)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("ai-repair-diff-\(change.field.rawValue)")
                        }
                    }
                    .accessibilityIdentifier("ai-repair-preview-changes")
                }
                if !preview.splitContents.isEmpty {
                    Section("拆分为 \(preview.splitContents.count) 张新卡") {
                        ForEach(Array(preview.splitContents.enumerated()), id: \.offset) { _, content in
                            Text(content.candidateSummary)
                                .font(.footnote)
                        }
                    }
                    .accessibilityIdentifier("ai-repair-preview-split")
                }
            } else {
                Section {
                    Text("这条建议的修改内容暂时无法预览，可作为参考手动编辑。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !affectedKinds.isEmpty {
                Section("受影响的学习方向") {
                    ForEach(affectedKinds, id: \.self) { kind in
                        Text(kind.adaptiveDirectionLabel)
                            .font(.footnote)
                    }
                }
                .accessibilityIdentifier("ai-repair-preview-affected")
            }

            if model.isCommitted {
                Section {
                    Label(committedPreviewTitle, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                    if let detail = committedPreviewDetail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("ai-repair-preview-committed")
            } else if isSplit {
                splitAdoptSections
            } else {
                adoptSection
            }

            if let error = model.commitErrorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("ai-repair-commit-error")
                }
            }
        }
        .navigationTitle("建议预览")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("ai-repair-preview")
        .task {
            await model.notePreviewing()
            // Split defaults: the note's existing directions filtered to each
            // candidate's applicable kinds (方向快照), the target note's deck —
            // the disposition stays unset on purpose (必选).
            if splitDirections.isEmpty, let preview {
                for (index, content) in preview.splitContents.enumerated() {
                    let applicable = Set(CardTemplateKind.applicable(to: content.kind))
                    let defaults = Set(affectedKinds).intersection(applicable)
                    splitDirections[index] = defaults.isEmpty ? applicable : defaults
                }
            }
            if splitMembership.deckIDs.isEmpty {
                splitMembership = DeckMembershipSelection(
                    homeDeckID: model.targetDeckID,
                    deckIDs: model.targetDeckID.map { [$0] } ?? []
                ).normalized(decks: model.decks)
            }
        }
        .alert("采用此建议？", isPresented: $showsAdoptConfirmation) {
            Button("采用") {
                Task { _ = await model.adoptSuggestion(
                    at: suggestionIndex,
                    edited: adoptEditedCandidate
                ) }
            }
            .accessibilityIdentifier("ai-repair-adopt-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("卡片内容会按预览修改，学习进度不受影响。")
        }
        .alert("确认拆分？", isPresented: $showsSplitConfirmation) {
            Button("拆分") {
                guard let deckID = splitMembership.homeDeckID,
                      !splitMembership.deckIDs.isEmpty,
                      let disposition = splitDisposition,
                      let preview else { return }
                let directions = preview.splitContents.indices.map { index in
                    Array(splitDirections[index] ?? [])
                }
                Task {
                    _ = await model.adoptSplitSuggestion(
                        at: suggestionIndex,
                        edited: adoptEditedCandidate,
                        deckID: deckID,
                        deckIDs: splitMembership.deckIDs,
                        directions: directions,
                        disposition: disposition
                    )
                }
            }
            .accessibilityIdentifier("ai-repair-split-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text(splitConfirmationMessage)
        }
        .sheet(isPresented: $showsEditSheet, onDismiss: {
            guard pendingEditedAdopt else { return }
            pendingEditedAdopt = false
            adoptEditedCandidate = true
            showsAdoptConfirmation = true
        }) {
            if let content = preview?.resultContent {
                AIRepairCandidateEditView(
                    kind: content.kind,
                    fields: content.editableFields
                ) { suggestion in
                    let saved = await model.saveEditedCandidate(suggestion)
                    if saved { pendingEditedAdopt = true }
                    return saved
                }
            }
        }
    }

    /// The guarded adopt path — a confirmation stands between the preview
    /// and the single atomic commit; editing first routes through the same
    /// confirmation with the edited candidate.
    private var adoptSection: some View {
        Section {
            Button {
                adoptEditedCandidate = isEditedCandidate
                showsAdoptConfirmation = true
            } label: {
                if model.isCommitting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在采用…")
                    }
                } else {
                    Label("采用此建议", systemImage: "checkmark.circle")
                }
            }
            .disabled(!model.canCommit)
            .accessibilityIdentifier("ai-repair-adopt")
            Button {
                showsEditSheet = true
            } label: {
                Label("编辑后采用", systemImage: "square.and.pencil")
            }
            .disabled(!model.canCommit || preview?.resultContent == nil)
            .accessibilityIdentifier("ai-repair-edit-adopt")
        } footer: {
            Text("候选内容：确认采用后才会修改卡片，当前不会自动应用。")
        }
    }

    // MARK: - Split adopt (T09)

    /// Split preview + confirm sections: every candidate's content with its
    /// direction toggles, the shared deck and the required original-card
    /// disposition — nothing is staged until the confirmation alert.
    @ViewBuilder
    private var splitAdoptSections: some View {
        if let preview, !preview.splitContents.isEmpty {
            Section("新卡设置") {
                ForEach(
                    Array(preview.splitContents.enumerated()),
                    id: \.offset
                ) { index, content in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第 \(index + 1) 个笔记")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(content.candidateSummary)
                            .font(.footnote)
                        ForEach(
                            CardTemplateKind.applicable(to: content.kind),
                            id: \.self
                        ) { kind in
                            directionToggle(candidate: index, kind: kind)
                        }
                    }
                    .padding(.vertical, 2)
                }
                deckPicker
            }
            .accessibilityIdentifier("ai-repair-split-settings")

            Section {
                ForEach(
                    AIRepairOriginalCardDisposition.allCases,
                    id: \.self
                ) { option in
                    Button {
                        splitDisposition = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(option.title, systemImage: option.systemImage)
                                    .font(.subheadline)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if splitDisposition == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(OboeTheme.Colors.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier(
                        "ai-repair-disposition-\(option.rawValue)"
                    )
                }
            } header: {
                Text("原卡处置（必选）")
            } footer: {
                Text("删除只移除当前学习方向，不会影响其他方向或笔记。")
            }
            .accessibilityIdentifier("ai-repair-disposition-section")

            Section {
                Button {
                    showsSplitConfirmation = true
                } label: {
                    if model.isCommitting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在拆分…")
                        }
                    } else {
                        Label("采用拆分", systemImage: "rectangle.split.2x1")
                    }
                }
                .disabled(!canAdoptSplit)
                .accessibilityIdentifier("ai-repair-split-adopt")
            } footer: {
                Text("确认后才会创建新卡并处置原卡，当前不会自动应用。")
            }
        } else {
            Section {
                Text("这条拆卡建议的候选内容不完整，暂不能采用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func directionToggle(
        candidate index: Int,
        kind: CardTemplateKind
    ) -> some View {
        let isOn = Binding<Bool>(
            get: { splitDirections[index]?.contains(kind) ?? false },
            set: { on in
                var set = splitDirections[index] ?? []
                if on { set.insert(kind) } else { set.remove(kind) }
                splitDirections[index] = set
            }
        )
        return Toggle(kind.adaptiveDirectionLabel, isOn: isOn)
            .font(.footnote)
            .accessibilityIdentifier(
                "ai-repair-split-direction-\(index)-\(kind.rawValue)"
            )
    }

    @ViewBuilder
    private var deckPicker: some View {
        if model.decks.isEmpty {
            LabeledContent("新卡所属牌组", value: "与原笔记相同")
        } else {
            DeckMembershipField(
                decks: model.decks,
                selection: $splitMembership,
                rowAccessibilityID: "ai-repair-split-deck"
            )
        }
    }

    private var canAdoptSplit: Bool {
        guard model.canCommit,
              splitDisposition != nil,
              splitMembership.homeDeckID != nil,
              !splitMembership.deckIDs.isEmpty,
              let preview, !preview.splitContents.isEmpty else { return false }
        return preview.splitContents.indices.allSatisfy {
            !(splitDirections[$0]?.isEmpty ?? true)
        }
    }

    /// The confirmation restates the current selection — changing directions
    /// before submitting refreshes the card count shown here (§6.5).
    private var splitConfirmationMessage: String {
        let noteCount = preview?.splitContents.count ?? 0
        let cardCount = splitDirections.values.reduce(0) { $0 + $1.count }
        let homeName = model.decks.first(where: { $0.id == splitMembership.homeDeckID })?.name
            ?? "所选牌组"
        let deckDescription = splitMembership.deckIDs.count <= 1
            ? "「\(homeName)」"
            : "\(splitMembership.deckIDs.count) 个牌组（归属「\(homeName)」）"
        let disposition: String
        switch splitDisposition {
        case .keep, nil: disposition = "保留"
        case .pause: disposition = "暂停"
        case .delete: disposition = "删除"
        }
        return "将在\(deckDescription)创建 \(noteCount) 个新笔记、\(cardCount) 张新卡（从「新卡」状态开始学习）；原卡将被\(disposition)。"
    }

    private var committedPreviewTitle: String {
        guard let receipt = model.committedReceipt,
              !receipt.createdNoteIDs.isEmpty else {
            return "已采用建议，卡片内容已更新。"
        }
        return "已拆分为 \(receipt.createdNoteIDs.count) 个新笔记。"
    }

    private var committedPreviewDetail: String? {
        guard let receipt = model.committedReceipt,
              !receipt.createdNoteIDs.isEmpty else { return nil }
        let disposition: String
        switch receipt.originalCardDisposition {
        case .keep: disposition = "保留"
        case .pause: disposition = "暂停"
        case .delete: disposition = "删除"
        }
        return "共创建 \(receipt.createdCardIDs.count) 张新卡；原卡已\(disposition)。"
    }
}

/// "编辑后采用" sheet (T08): the suggestion's merged result content as a
/// plain form — saving produces a full-replacement edited candidate that
/// adopts through the same guarded commit as a decoded suggestion.
private struct AIRepairCandidateEditView: View {
    let kind: KnowledgePointKind
    @State var fields: AIRepairEditableFields
    /// Returns whether the candidate persisted — the caller dismisses on
    /// success and surfaces the adopt confirmation.
    let onSave: (AIRepairSuggestion) async -> Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(kind == .vocabulary ? "词汇内容" : "语法内容") {
                    TextField(kind == .vocabulary ? "写法" : "语法形式", text: $fields.headword)
                    if kind == .vocabulary {
                        TextField("读音", text: $fields.reading)
                        VocabularyPitchAccentField(
                            reading: $fields.reading,
                            pitchAccent: $fields.pitchAccent,
                            accessibilityIdentifier: "ai-repair-pitch-accent-picker"
                        )
                    }
                    TextField("释义", text: $fields.meaningZH, axis: .vertical)
                        .lineLimit(2...4)
                    if kind == .vocabulary {
                        VocabularyPartOfSpeechField(
                            value: $fields.partOfSpeech,
                            accessibilityIdentifier: "ai-repair-part-of-speech-field"
                        )
                    } else {
                        TextField("用法", text: $fields.usage, axis: .vertical)
                            .lineLimit(1...3)
                        TextField("接续", text: $fields.connection)
                    }
                }
                Section("例句") {
                    TextField("日文例句", text: $fields.exampleJapanese, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("例句翻译", text: $fields.exampleTranslationZH, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("说明") {
                    TextField("说明", text: $fields.notes, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
            .navigationTitle("编辑后采用")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            let saved = await onSave(fields.editedSuggestion(kind: kind))
                            if saved { dismiss() }
                        }
                    }
                    .disabled(!fields.hasRequiredContent)
                    .accessibilityIdentifier("ai-repair-edit-save")
                }
            }
        }
    }
}
