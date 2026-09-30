import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit

struct VocabularyDetailView: View {
    let noteID: UUID
    let service: VocabularyService
    let knowledgeService: KnowledgePointService
    let deckService: DeckManagementService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService
    let onUpdated: () async -> Void

    @State private var model: VocabularyDetailViewModel
    @State private var isEditing = false
    @State private var isEditingTags = false
    @State private var speechErrorMessage: String?
    /// S16：太简单开启前的后果确认。
    @State private var showingTooEasyConfirmation = false

    init(
        noteID: UUID,
        service: VocabularyService,
        knowledgeService: KnowledgePointService,
        deckService: DeckManagementService,
        contentCardService: ContentCardService,
        historyService: StudyHistoryService,
        speechService: any SpeechService,
        onUpdated: @escaping () async -> Void = {}
    ) {
        self.noteID = noteID
        self.service = service
        self.knowledgeService = knowledgeService
        self.deckService = deckService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
        self.onUpdated = onUpdated
        _model = State(
            initialValue: VocabularyDetailViewModel(
                noteID: noteID,
                service: service,
                knowledgeService: knowledgeService
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在载入单词…")
            } else if let note = model.note {
                List {
                    Section("释义") {
                        LabeledContent("词形") {
                            HStack(spacing: 10) {
                                Text(note.headword)
                                speechButton(
                                    text: preferredVocabularySpeechText(note),
                                    label: "播放单词发音",
                                    identifier: "vocabulary-speech-button"
                                )
                            }
                        }
                        if let reading = note.reading {
                            LabeledContent("假名", value: reading)
                        }
                        LabeledContent("中文", value: note.meaningZH)
                        if !speechService.availability.isAvailable {
                            Label(
                                "设备未发现可用的日语语音；可在“设置”查看下载说明。",
                                systemImage: "speaker.slash"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if note.partOfSpeech != nil || note.pitchAccent != nil || note.jlpt != nil {
                        Section("分类") {
                            if let partOfSpeech = note.partOfSpeech {
                                LabeledContent("词性", value: partOfSpeech)
                            }
                            if let pitch = pitchAccentDisplayValue(note.pitchAccent) {
                                LabeledContent("音调", value: pitch)
                            }
                            if let jlpt = note.jlpt {
                                LabeledContent("JLPT", value: jlpt.rawValue)
                            }
                        }
                    }

                    if !note.examples.isEmpty {
                        Section("例句") {
                            ForEach(note.examples) { example in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(example.japanese)
                                        if let translation = example.translationZH {
                                            Text(translation)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    speechButton(
                                        text: example.japanese,
                                        label: "播放例句发音",
                                        identifier: "vocabulary-example-speech-button-\(example.id.uuidString)"
                                    )
                                }
                            }
                        }
                    }

                    if let notes = note.notes {
                        Section("备注") {
                            Text(notes)
                        }
                    }

                    KnowledgeMetadataSection(metadata: model.metadata)

                    // S16：学习单元三态 + 太简单开关。ON 需先弹后果
                    // 确认；OFF 随时可清（不受复习页撤销窗口限制）。
                    // CAS 冲突不覆盖——报错并重新载入真实状态。
                    if model.unitStateLoaded {
                        Section("学习单元") {
                            LabeledContent("知识状态") {
                                Text(model.unitStateLabel)
                                    .foregroundStyle(
                                        model.unitContext?.tooEasy == true
                                            ? OboeTheme.Colors.accent
                                            : .primary
                                    )
                            }
                            .accessibilityIdentifier(
                                "vocabulary-unit-state-row"
                            )
                            if model.unitContext != nil {
                                Toggle(
                                    isOn: Binding(
                                        get: {
                                            model.unitContext?.tooEasy
                                                ?? false
                                        },
                                        set: { on in
                                            if on {
                                                showingTooEasyConfirmation = true
                                            } else {
                                                Task {
                                                    _ = await model
                                                        .setTooEasy(false)
                                                    await onUpdated()
                                                }
                                            }
                                        }
                                    )
                                ) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("太简单")
                                        Text(
                                            "开启后，本词所有方向的卡不再进入学习计划。"
                                        )
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(model.isApplyingUnitFlag)
                                .accessibilityIdentifier(
                                    "vocabulary-too-easy-toggle"
                                )
                            } else {
                                Text("该词条未关联学习单元。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    CardDirectionManagementSection(
                        noteID: note.id,
                        kind: .vocabulary,
                        service: contentCardService,
                        onChanged: onUpdated
                    )

                    CardHistorySection(noteID: note.id, service: historyService)

                    KnowledgePointLifecycleSection(
                        noteID: note.id,
                        currentDeckID: note.deckID,
                        deckService: deckService,
                        knowledgeService: knowledgeService,
                        onChanged: onUpdated
                    )

                    Section("记录") {
                        LabeledContent("内容版本", value: "\(note.contentVersion)")
                        LabeledContent("知识点 ID", value: note.id.uuidString)
                    }
                }
                .navigationTitle(note.headword)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            Task {
                                if await model.toggleFavorite() {
                                    await onUpdated()
                                }
                            }
                        } label: {
                            Label(
                                model.metadata?.isFavorite == true ? "取消收藏" : "收藏",
                                systemImage: model.metadata?.isFavorite == true ? "star.fill" : "star"
                            )
                        }
                        .accessibilityIdentifier("vocabulary-favorite-button")

                        Button("标签") {
                            isEditingTags = true
                        }
                        .accessibilityIdentifier("vocabulary-tags-button")

                        Button("编辑") {
                            isEditing = true
                        }
                        .accessibilityIdentifier("vocabulary-edit-button")
                    }
                }
                .sheet(isPresented: $isEditing) {
                    VocabularyEditView(note: note, service: service) { updated in
                        model.note = updated
                        await onUpdated()
                    }
                }
                .sheet(isPresented: $isEditingTags) {
                    TagEditor(
                        initialNames: model.metadata?.tags.map(\.name) ?? []
                    ) { names in
                        let saved = await model.replaceTags(names)
                        if saved {
                            await onUpdated()
                        }
                        return saved
                    }
                }
            } else {
                ContentUnavailableView("单词已不存在", systemImage: "text.book.closed")
            }
        }
        .secondaryPage()
        .alert(
            "无法载入单词",
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
        .alert(
            "无法播放日语发音",
            isPresented: Binding(
                get: { speechErrorMessage != nil },
                set: { shown in if !shown { speechErrorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(speechErrorMessage ?? "未知错误")
        }
        .alert(
            "无法更新「太简单」标记",
            isPresented: Binding(
                get: { model.unitFlagErrorMessage != nil },
                set: { shown in if !shown { model.unitFlagErrorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.unitFlagErrorMessage ?? "未知错误")
        }
        .alert(
            "标记为「太简单」？",
            isPresented: $showingTooEasyConfirmation
        ) {
            Button("太简单——不再进入学习计划") {
                Task {
                    _ = await model.setTooEasy(true)
                    await onUpdated()
                }
            }
            .accessibilityIdentifier("vocabulary-too-easy-confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("本词所有方向的卡将不再进入学习计划；此开关随时可再次关闭。")
        }
        .task(id: noteID) {
            await model.load()
        }
        .onDisappear { speechService.stop() }
    }

    private func preferredVocabularySpeechText(_ note: VocabularyNote) -> String {
        guard let reading = note.reading?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reading.isEmpty else { return note.headword }
        return reading
    }

    private func speechButton(text: String, label: String, identifier: String) -> some View {
        Button {
            speechErrorMessage = nil
            speechService.speak([text]) { error in
                speechErrorMessage = japaneseSpeechErrorDescription(error)
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .buttonStyle(.bordered)
        .disabled(!speechService.availability.isAvailable)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
@Observable
private final class VocabularyDetailViewModel {
    private let noteID: UUID
    private let service: VocabularyService
    private let knowledgeService: KnowledgePointService
    /// S16：learning-unit flag 门面——缺省由词汇服务派生同 pool
    /// 门面；nil 时「学习单元」区只显示状态不提供开关。
    private let learningUnits: (any LearningUnitFlagProviding)?

    var note: VocabularyNote?
    var metadata: KnowledgePointMetadata?
    var isLoading = true
    var errorMessage: String?

    // MARK: - S16 学习单元 / 太简单

    /// note → unit → flag 解析出的三态上下文；nil = 无关联 unit。
    var unitContext: LearningUnitContext?
    /// 单元态是否已完成至少一次解析（区分「载入中」与「未关联」）。
    var unitStateLoaded = false
    var isApplyingUnitFlag = false
    var unitFlagErrorMessage: String?
    private var unitObservationTask: Task<Void, Never>?

    init(
        noteID: UUID,
        service: VocabularyService,
        knowledgeService: KnowledgePointService,
        learningUnits: (any LearningUnitFlagProviding)? = nil
    ) {
        self.noteID = noteID
        self.service = service
        self.knowledgeService = knowledgeService
        self.learningUnits = learningUnits ?? service.learningUnitFlags
    }

    func load() async {
        isLoading = true
        do {
            note = try await service.fetchVocabulary(id: noteID)
            metadata = try await knowledgeService.fetchMetadata(noteID: noteID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        await loadUnitState()
        startUnitObservationIfNeeded()
    }

    /// 重新解析本 Note 的学习单元三态——观察 ping 与显式刷新共用。
    /// link 缺失/指向已删除 unit → nil（「未关联」，绝不按词形猜）。
    func loadUnitState() async {
        guard let learningUnits else {
            unitContext = nil
            unitStateLoaded = true
            return
        }
        do {
            unitContext = try await LearningUnitFlagOperator(
                flags: learningUnits
            ).context(forNoteID: noteID)
            unitFlagErrorMessage = nil
        } catch {
            // 观察触发的静默失败不弹错——保守保留旧状态。
            if !unitStateLoaded { unitContext = nil }
        }
        unitStateLoaded = true
    }

    /// Too Easy 开/关（§12.3）：CAS 取当前 revision——另一窗口改过
    /// 时冲突报错并重新载入状态，绝不覆盖。ON/OFF 都可随时执行，
    /// 不受复习页撤销窗口限制。
    @discardableResult
    func setTooEasy(_ value: Bool) async -> Bool {
        guard let learningUnits,
              let unitID = unitContext?.unit.id,
              !isApplyingUnitFlag else { return false }
        isApplyingUnitFlag = true
        defer { isApplyingUnitFlag = false }
        do {
            _ = try await LearningUnitFlagOperator(flags: learningUnits)
                .set(value, unitID: unitID, operationID: UUID(), at: Date())
            await loadUnitState()
            return true
        } catch {
            unitFlagErrorMessage = LearningUnitFlagOperator.message(
                for: error
            )
            await loadUnitState()
            return false
        }
    }

    /// 三态显示文案（§2.1 状态复用 `LearningKnowledgeResolver`）。
    var unitStateLabel: String {
        guard let unitContext else { return "未关联学习单元" }
        return switch unitContext.knowledgeState {
        case .unknown: "未知"
        case .learning: "学习中"
        case .mastered: "已掌握"
        }
    }

    /// 跨窗口刷新（§14.3）：flags/links 观察流有变更就重解析自身
    /// 上下文——复习页/Inspector/另一窗口的写入实时反映。
    private func startUnitObservationIfNeeded() {
        guard unitObservationTask == nil,
              let observing =
                learningUnits as? any LearningUnitFlagObserving
        else { return }
        unitObservationTask = Task { [weak self] in
            do {
                for try await _ in observing.observeChanges() {
                    guard let self, !Task.isCancelled else { return }
                    await self.loadUnitState()
                }
            } catch {
                // 流失败即停——下一次 load() 会重建。
            }
        }
    }

    func toggleFavorite() async -> Bool {
        do {
            guard let metadata else { return false }
            guard try await knowledgeService.setFavorite(
                noteID: noteID,
                isFavorite: !metadata.isFavorite
            ) else {
                errorMessage = "这个单词已不存在。"
                return false
            }
            self.metadata = try await knowledgeService.fetchMetadata(noteID: noteID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func replaceTags(_ names: [String]) async -> Bool {
        do {
            guard try await knowledgeService.replaceTags(noteID: noteID, rawNames: names) else {
                errorMessage = "这个单词已不存在。"
                return false
            }
            metadata = try await knowledgeService.fetchMetadata(noteID: noteID)
            return true
        } catch KnowledgeTagValidationError.tooLong(let maximum) {
            errorMessage = "每个标签不能超过 \(maximum) 个字符。"
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private struct VocabularyEditView: View {
    let note: VocabularyNote
    let service: VocabularyService
    let onSaved: (VocabularyNote) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: VocabularyFormData
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        note: VocabularyNote,
        service: VocabularyService,
        onSaved: @escaping (VocabularyNote) async -> Void
    ) {
        self.note = note
        self.service = service
        self.onSaved = onSaved
        _form = State(initialValue: note.formData)
    }

    private var isValid: Bool {
        (try? form.validatedContent()) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                VocabularyFormSections(form: $form)
                if !isValid {
                    Section {
                        Text(vocabularyValidationMessage(for: form))
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑单词")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("vocabulary-edit-save-button")
                }
            }
            .alert(
                "无法保存单词",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func save() {
        guard isValid, !isSaving else {
            return
        }
        isSaving = true
        Task {
            do {
                guard let updated = try await service.updateVocabulary(id: note.id, formData: form) else {
                    errorMessage = "这个单词已不存在。"
                    isSaving = false
                    return
                }
                await onSaved(updated)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct KnowledgeMetadataSection: View {
    let metadata: KnowledgePointMetadata?

    var body: some View {
        Section("整理") {
            LabeledContent("收藏", value: metadata?.isFavorite == true ? "已收藏" : "未收藏")
            LabeledContent("标签") {
                if let tags = metadata?.tags, !tags.isEmpty {
                    Text(tags.map(\.name).joined(separator: " · "))
                        .multilineTextAlignment(.trailing)
                } else {
                    Text("无")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TagEditor: View {
    let onSave: ([String]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false

    init(initialNames: [String], onSave: @escaping ([String]) async -> Bool) {
        self.onSave = onSave
        _text = State(initialValue: initialNames.joined(separator: "，"))
    }

    private var names: [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var isValid: Bool {
        names.allSatisfy { (try? KnowledgeTagName(validating: $0)) != nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：N5，日常表达", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("knowledge-tags-field")
                } footer: {
                    Text("使用逗号或换行分隔。大小写、全角半角及重复空白等价的标签只保留一个。")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task {
                            if await onSave(names) {
                                dismiss()
                            } else {
                                isSaving = false
                            }
                        }
                    }
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("knowledge-tags-save-button")
                }
            }
        }
    }
}

private struct KnowledgePointLifecycleSection: View {
    let noteID: UUID
    let currentDeckID: UUID
    let deckService: DeckManagementService
    let knowledgeService: KnowledgePointService
    let onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var decks: [DeckSummary] = []
    @State private var membership: DeckMembershipSelection?
    @State private var isPresentingMembership = false
    @State private var isConfirmingDelete = false
    @State private var deletionImpact: KnowledgePointDeletionImpact?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button {
                isPresentingMembership = membership != nil
            } label: {
                HStack {
                    Text("管理牌组")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(membershipSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(decks.isEmpty || membership == nil || isWorking)
            .accessibilityIdentifier("knowledge-membership-button")

            Button(role: .destructive) {
                prepareDeletion()
            } label: {
                Text("删除知识点")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .disabled(isWorking)
            .accessibilityIdentifier("knowledge-delete-button")
        } header: {
            Text("管理")
        } footer: {
            Text("知识点可同时属于多个牌组；卡片与复习进度在所有成员间共享，归属牌组决定新卡额度与复习归因。删除会移除正文和卡片，但保留不含正文的评分历史。")
        }
        .task {
            await loadMembershipState()
        }
        .sheet(isPresented: $isPresentingMembership) {
            if let membership {
                KnowledgePointMembershipSheet(
                    noteID: noteID,
                    decks: decks,
                    initial: membership,
                    knowledgeService: knowledgeService
                ) { updated in
                    self.membership = DeckMembershipSelection(membership: updated)
                    await onChanged()
                }
            }
        }
        .alert(
            "确定删除这个知识点吗？",
            isPresented: $isConfirmingDelete
        ) {
            Button(deleteButtonTitle, role: .destructive) {
                deleteKnowledgePoint()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteImpactMessage)
        }
        .alert(
            "无法完成内容操作",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private var membershipSummary: String {
        guard let membership, !membership.deckIDs.isEmpty else { return "" }
        let homeName = decks.first(where: { $0.id == membership.homeDeckID })?.name
        if membership.deckIDs.count == 1 {
            return homeName ?? "1 个牌组"
        }
        return "\(membership.deckIDs.count) 个牌组 · 归属 \(homeName ?? "未指定")"
    }

    private var deleteButtonTitle: String {
        "删除正文与 \(deletionImpact?.cardCount ?? 0) 张卡片"
    }

    private var deleteImpactMessage: String {
        let logs = deletionImpact?.reviewLogCount ?? 0
        return "例句、标签关联、卡片和当前任务会一并删除；\(logs) 条评分历史仅保留标识与调度记录。此操作不可撤销，可通过已有备份恢复。"
    }

    private func loadMembershipState() async {
        do {
            decks = try await deckService.fetchDecks()
            if let fetched = try await knowledgeService.fetchMembership(noteID: noteID) {
                membership = DeckMembershipSelection(membership: fetched)
                    .normalized(decks: decks)
            } else {
                errorMessage = "这个知识点已不存在。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareDeletion() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                guard let impact = try await knowledgeService.fetchDeletionImpact(noteID: noteID) else {
                    errorMessage = "这个知识点已不存在。"
                    isWorking = false
                    return
                }
                deletionImpact = impact
                isConfirmingDelete = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func deleteKnowledgePoint() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                switch try await knowledgeService.delete(noteID: noteID) {
                case .deleted:
                    await onChanged()
                    dismiss()
                case .notFound:
                    errorMessage = "这个知识点已不存在。"
                    isWorking = false
                }
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}

/// 「管理牌组」sheet：编辑成员集合与归属牌组，保存时一次性原子替换。
/// 取消不产生任何写入；保存失败时草稿选择保留，可修正后重试。
private struct KnowledgePointMembershipSheet: View {
    let noteID: UUID
    let decks: [DeckSummary]
    let initial: DeckMembershipSelection
    let knowledgeService: KnowledgePointService
    let onSaved: (NoteDeckMembership) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeckMembershipSelection
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        noteID: UUID,
        decks: [DeckSummary],
        initial: DeckMembershipSelection,
        knowledgeService: KnowledgePointService,
        onSaved: @escaping (NoteDeckMembership) async -> Void
    ) {
        self.noteID = noteID
        self.decks = decks
        self.initial = initial
        self.knowledgeService = knowledgeService
        self.onSaved = onSaved
        _draft = State(initialValue: initial)
    }

    private var hasChanges: Bool { draft != initial }
    private var isValid: Bool {
        !draft.deckIDs.isEmpty
            && draft.homeDeckID.map({ draft.deckIDs.contains($0) }) == true
    }

    var body: some View {
        NavigationStack {
            Form {
                DeckMembershipList(decks: decks, selection: $draft)
            }
            .navigationTitle("管理牌组")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("knowledge-membership-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid || !hasChanges || isSaving)
                        .accessibilityIdentifier("knowledge-membership-save")
                }
            }
            .alert(
                "无法保存牌组设置",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func save() {
        guard isValid, !isSaving else { return }
        isSaving = true
        let target = draft.normalized(decks: decks)
        guard let home = target.homeDeckID else {
            isSaving = false
            return
        }
        Task {
            do {
                let updated = try await knowledgeService.replaceMembership(
                    noteID: noteID,
                    deckIDs: target.deckIDs,
                    homeDeckID: home
                )
                await onSaved(updated)
                dismiss()
            } catch {
                // 草稿选择保留，用户可修正后重试。
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct CardDirectionManagementSection: View {
    let noteID: UUID
    let kind: KnowledgePointKind
    let service: ContentCardService
    let onChanged: () async -> Void

    @State private var directions: [CardDirectionState] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            ForEach(CardTemplateKind.applicable(to: kind), id: \.self) { template in
                Toggle(
                    template.displayName,
                    isOn: Binding(
                        get: { isEnabled(template) },
                        set: { update(template: template, isEnabled: $0) }
                    )
                )
                .disabled(isWorking)
                .accessibilityIdentifier("card-direction-toggle-\(template.rawValue)")
            }
        } header: {
            Text("卡片方向")
        } footer: {
            Text("停用会保留卡片 ID 与复习进度；重新启用恢复原状态。尚未创建的方向会新增为 New。")
        }
        .task(id: noteID) {
            await load()
        }
        .alert(
            "无法更新卡片方向",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func isEnabled(_ template: CardTemplateKind) -> Bool {
        directions.first { $0.templateKind == template }?.isEnabled == true
    }

    private func update(template: CardTemplateKind, isEnabled: Bool) {
        guard !isWorking else { return }
        var enabled = Set(directions.filter(\.isEnabled).map(\.templateKind))
        if isEnabled {
            enabled.insert(template)
        } else {
            enabled.remove(template)
        }
        isWorking = true
        Task {
            do {
                directions = try await service.replaceEnabledCardDirections(
                    noteID: noteID,
                    kind: kind,
                    enabledTemplates: enabled
                )
                await onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func load() async {
        do {
            directions = try await service.fetchCardDirections(noteID: noteID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CardHistorySection: View {
    let noteID: UUID
    let service: StudyHistoryService

    @State private var histories: [CardReviewHistory] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if isLoading {
                ProgressView("正在载入学习历史…")
            } else if histories.isEmpty {
                Text("尚无卡片方向")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(histories) { history in
                    NavigationLink {
                        CardHistoryView(history: history)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(history.templateKind.displayName)
                            HStack {
                                Text("有效回答 \(history.activeAnswerCount) 次")
                                if let lastReviewedAt = history.lastReviewedAt {
                                    Text("· 上次 \(lastReviewedAt, format: .relative(presentation: .named))")
                                } else {
                                    Text("· 尚未复习")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("card-history-card-\(history.cardID.uuidString)")
                }
            }
        } header: {
            Text("学习历史")
        } footer: {
            Text("有效回答次数不包含已撤销评分；撤销记录仍保留在明细中。")
        }
        .task(id: noteID) {
            await load()
        }
        .alert(
            "无法载入学习历史",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("重试") { Task { await load() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
    }

    private func load() async {
        isLoading = true
        do {
            histories = try await service.fetchCardHistories(noteID: noteID)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct CardHistoryView: View {
    let history: CardReviewHistory

    var body: some View {
        List {
            Section("概览") {
                LabeledContent("有效回答", value: "\(history.activeAnswerCount) 次")
                    .accessibilityIdentifier("card-history-active-count")
                LabeledContent("最近有效评分") {
                    if let lastReviewedAt = history.lastReviewedAt {
                        Text(lastReviewedAt, format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text("尚无")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("评分记录") {
                if history.entries.isEmpty {
                    Text("这张卡还没有评分记录。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("card-history-empty")
                } else {
                    ForEach(history.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.rating.historyTitle)
                                    .font(.headline)
                                if entry.isUndone {
                                    Text("已撤销")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                } else if entry.wasFirstStudy {
                                    Text("首次学习")
                                        .font(.caption.bold())
                                        .foregroundStyle(.blue)
                                }
                                Spacer()
                                Text(entry.reviewedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("下次到期：\(entry.nextDueAt.formatted(.dateTime.year().month().day().hour().minute()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("用时 \(historyDuration(entry.durationMilliseconds))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .opacity(entry.isUndone ? 0.6 : 1)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("card-history-entry-\(entry.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle(history.templateKind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
    }

    private func historyDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) 毫秒" }
        return String(format: "%.1f 秒", Double(milliseconds) / 1_000)
    }
}

private extension ReviewRating {
    var historyTitle: String {
        switch self {
        case .again: "重来"
        case .hard: "困难"
        case .good: "良好"
        case .easy: "简单"
        }
    }
}

private extension CardTemplateKind {
    var displayName: String {
        switch self {
        case .vocabularyJapaneseToChinese:
            "日语 → 中文"
        case .vocabularyChineseToJapanese:
            "中文 → 日语"
        case .vocabularyListening:
            "听力 → 中文"
        case .sentenceCloze:
            "句子挖空"
        case .grammarFormToExplanation:
            "语法形式 → 解释"
        }
    }
}

struct GrammarDetailView: View {
    let noteID: UUID
    let service: GrammarService
    let knowledgeService: KnowledgePointService
    let deckService: DeckManagementService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService
    let onUpdated: () async -> Void

    @State private var model: GrammarDetailViewModel
    @State private var isEditing = false
    @State private var isEditingTags = false
    @State private var speechErrorMessage: String?

    init(
        noteID: UUID,
        service: GrammarService,
        knowledgeService: KnowledgePointService,
        deckService: DeckManagementService,
        contentCardService: ContentCardService,
        historyService: StudyHistoryService,
        speechService: any SpeechService,
        onUpdated: @escaping () async -> Void = {}
    ) {
        self.noteID = noteID
        self.service = service
        self.knowledgeService = knowledgeService
        self.deckService = deckService
        self.contentCardService = contentCardService
        self.historyService = historyService
        self.speechService = speechService
        self.onUpdated = onUpdated
        _model = State(
            initialValue: GrammarDetailViewModel(
                noteID: noteID,
                service: service,
                knowledgeService: knowledgeService
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("正在载入语法…")
            } else if let note = model.note {
                List {
                    Section("含义") {
                        LabeledContent("语法形式") {
                            HStack(spacing: 10) {
                                Text(note.grammarForm)
                                speechButton(
                                    text: note.grammarForm,
                                    label: "播放语法发音",
                                    identifier: "grammar-speech-button"
                                )
                            }
                        }
                        LabeledContent("中文", value: note.meaningZH)
                        if !speechService.availability.isAvailable {
                            Label(
                                "设备未发现可用的日语语音；可在“设置”查看下载说明。",
                                systemImage: "speaker.slash"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if note.usage != nil || note.connection != nil || note.jlpt != nil {
                        Section("语法信息") {
                            if let usage = note.usage {
                                LabeledContent("使用说明", value: usage)
                            }
                            if let connection = note.connection {
                                LabeledContent("接续方式", value: connection)
                            }
                            if let jlpt = note.jlpt {
                                LabeledContent("JLPT", value: jlpt.rawValue)
                            }
                        }
                    }

                    if !note.examples.isEmpty {
                        Section("例句") {
                            ForEach(note.examples) { example in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(example.japanese)
                                        if let translation = example.translationZH {
                                            Text(translation)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    speechButton(
                                        text: example.japanese,
                                        label: "播放例句发音",
                                        identifier: "grammar-example-speech-button-\(example.id.uuidString)"
                                    )
                                }
                            }
                        }
                    }

                    if let notes = note.notes {
                        Section("注意事项") {
                            Text(notes)
                        }
                    }

                    KnowledgeMetadataSection(metadata: model.metadata)

                    CardDirectionManagementSection(
                        noteID: note.id,
                        kind: .grammar,
                        service: contentCardService,
                        onChanged: onUpdated
                    )

                    CardHistorySection(noteID: note.id, service: historyService)

                    KnowledgePointLifecycleSection(
                        noteID: note.id,
                        currentDeckID: note.deckID,
                        deckService: deckService,
                        knowledgeService: knowledgeService,
                        onChanged: onUpdated
                    )

                    Section("记录") {
                        LabeledContent("内容版本", value: "\(note.contentVersion)")
                        LabeledContent("知识点 ID", value: note.id.uuidString)
                    }
                }
                .navigationTitle(note.grammarForm)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            Task {
                                if await model.toggleFavorite() {
                                    await onUpdated()
                                }
                            }
                        } label: {
                            Label(
                                model.metadata?.isFavorite == true ? "取消收藏" : "收藏",
                                systemImage: model.metadata?.isFavorite == true ? "star.fill" : "star"
                            )
                        }
                        .accessibilityIdentifier("grammar-favorite-button")

                        Button("标签") {
                            isEditingTags = true
                        }
                        .accessibilityIdentifier("grammar-tags-button")

                        Button("编辑") {
                            isEditing = true
                        }
                        .accessibilityIdentifier("grammar-edit-button")
                    }
                }
                .sheet(isPresented: $isEditing) {
                    GrammarEditView(note: note, service: service) { updated in
                        model.note = updated
                        await onUpdated()
                    }
                }
                .sheet(isPresented: $isEditingTags) {
                    TagEditor(
                        initialNames: model.metadata?.tags.map(\.name) ?? []
                    ) { names in
                        let saved = await model.replaceTags(names)
                        if saved {
                            await onUpdated()
                        }
                        return saved
                    }
                }
            } else {
                ContentUnavailableView("语法已不存在", systemImage: "text.book.closed")
            }
        }
        .secondaryPage()
        .alert(
            "无法载入语法",
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
        .alert(
            "无法播放日语发音",
            isPresented: Binding(
                get: { speechErrorMessage != nil },
                set: { shown in if !shown { speechErrorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(speechErrorMessage ?? "未知错误")
        }
        .task(id: noteID) {
            await model.load()
        }
        .onDisappear { speechService.stop() }
    }

    private func speechButton(text: String, label: String, identifier: String) -> some View {
        Button {
            speechErrorMessage = nil
            speechService.speak([text]) { error in
                speechErrorMessage = japaneseSpeechErrorDescription(error)
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
        }
        .buttonStyle(.bordered)
        .disabled(!speechService.availability.isAvailable)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private func japaneseSpeechErrorDescription(_ error: Error) -> String {
    guard let error = error as? JapaneseSpeechError else {
        return "系统语音暂时无法播放，请稍后重试。"
    }
    return switch error {
    case .voiceUnavailable:
        "设备未安装可用的日语语音。请在系统设置的辅助功能“朗读内容”中下载日语声音；其他功能仍可继续使用。"
    case .noSpeakableText:
        "当前内容没有可朗读的日语文本。"
    case .audioSessionUnavailable:
        "音频正被其他应用或通话占用，请稍后重试。"
    }
}

@MainActor
@Observable
private final class GrammarDetailViewModel {
    private let noteID: UUID
    private let service: GrammarService
    private let knowledgeService: KnowledgePointService

    var note: GrammarNote?
    var metadata: KnowledgePointMetadata?
    var isLoading = true
    var errorMessage: String?

    init(
        noteID: UUID,
        service: GrammarService,
        knowledgeService: KnowledgePointService
    ) {
        self.noteID = noteID
        self.service = service
        self.knowledgeService = knowledgeService
    }

    func load() async {
        isLoading = true
        do {
            note = try await service.fetchGrammar(id: noteID)
            metadata = try await knowledgeService.fetchMetadata(noteID: noteID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func toggleFavorite() async -> Bool {
        do {
            guard let metadata else { return false }
            guard try await knowledgeService.setFavorite(
                noteID: noteID,
                isFavorite: !metadata.isFavorite
            ) else {
                errorMessage = "这个语法已不存在。"
                return false
            }
            self.metadata = try await knowledgeService.fetchMetadata(noteID: noteID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func replaceTags(_ names: [String]) async -> Bool {
        do {
            guard try await knowledgeService.replaceTags(noteID: noteID, rawNames: names) else {
                errorMessage = "这个语法已不存在。"
                return false
            }
            metadata = try await knowledgeService.fetchMetadata(noteID: noteID)
            return true
        } catch KnowledgeTagValidationError.tooLong(let maximum) {
            errorMessage = "每个标签不能超过 \(maximum) 个字符。"
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private struct GrammarEditView: View {
    let note: GrammarNote
    let service: GrammarService
    let onSaved: (GrammarNote) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var form: GrammarFormData
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        note: GrammarNote,
        service: GrammarService,
        onSaved: @escaping (GrammarNote) async -> Void
    ) {
        self.note = note
        self.service = service
        self.onSaved = onSaved
        _form = State(initialValue: note.formData)
    }

    private var isValid: Bool {
        (try? form.validatedContent()) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                GrammarFormSections(form: $form)
                if !isValid {
                    Section {
                        Text(grammarValidationMessage(for: form))
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("编辑语法")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid || isSaving)
                        .accessibilityIdentifier("grammar-edit-save-button")
                }
            }
            .alert(
                "无法保存语法",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { errorMessage = nil }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func save() {
        guard isValid, !isSaving else { return }
        isSaving = true
        Task {
            do {
                guard let updated = try await service.updateGrammar(id: note.id, formData: form) else {
                    errorMessage = "这个语法已不存在。"
                    isSaving = false
                    return
                }
                await onSaved(updated)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
