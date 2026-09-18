import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit

struct AddContentEditorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: AddContentViewModel
    private let deckService: DeckManagementService
    private let vocabularyService: VocabularyService
    private let grammarService: GrammarService
    private let knowledgePointService: KnowledgePointService
    private let contentCardService: ContentCardService
    private let aiCardGenerationService: AICardGenerationService
    private let sentenceAnalysisService: SentenceAnalysisService
    private let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    private let historyService: StudyHistoryService
    private let speechService: any SpeechService
    private let inboxService: InboxService?
    private let inboxImageStore: InboxImageStore?
    private let ocrService: (any OCRRecognizing)?
    private let drainSharedCaptures: @Sendable () async -> Void
    private let sharedCapturesAwaitingImport: Int?
    private let importAwaitingSharedCaptures: @Sendable () async -> Void
    @State private var unprocessedInboxCount = 0
    @State private var isImageCapturePresented = false
    @State private var isConfirmingDuplicateCommit = false
    @State private var isVocabularyAdditionalFieldsExpanded = false
    @State private var isGrammarAdditionalFieldsExpanded = false
    @FocusState private var isSentenceAnalysisInputFocused: Bool

    private let title: String

    init(
        deckService: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        contentCardService: ContentCardService,
        aiCardGenerationService: AICardGenerationService,
        sentenceAnalysisService: SentenceAnalysisService,
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService,
        historyService: StudyHistoryService,
        speechService: any SpeechService,
        inboxService: InboxService? = nil,
        inboxImageStore: InboxImageStore? = nil,
        ocrService: (any OCRRecognizing)? = nil,
        drainSharedCaptures: @escaping @Sendable () async -> Void = {},
        sharedCapturesAwaitingImport: Int? = nil,
        importAwaitingSharedCaptures: @escaping @Sendable () async -> Void = {},
        captureSession: CaptureEditorSession? = nil,
        title: String = "添加"
    ) {
        self.deckService = deckService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.contentCardService = contentCardService
        self.aiCardGenerationService = aiCardGenerationService
        self.sentenceAnalysisService = sentenceAnalysisService
        self.sentenceAnalysisCardCreationService = sentenceAnalysisCardCreationService
        self.historyService = historyService
        self.speechService = speechService
        self.inboxService = inboxService
        self.inboxImageStore = inboxImageStore
        self.ocrService = ocrService
        self.drainSharedCaptures = drainSharedCaptures
        self.sharedCapturesAwaitingImport = sharedCapturesAwaitingImport
        self.importAwaitingSharedCaptures = importAwaitingSharedCaptures
        self.title = title
        _model = State(
            initialValue: AddContentViewModel(
                deckService: deckService,
                vocabularyService: vocabularyService,
                grammarService: grammarService,
                knowledgePointService: knowledgePointService,
                contentCardService: contentCardService,
                aiCardGenerationService: aiCardGenerationService,
                sentenceAnalysisService: sentenceAnalysisService,
                sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
                capture: captureSession
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        Form {
            if model.isCaptureSession {
                captureSourceSection
                captureApproachSection
            }
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("内容类型", selection: $model.kind) {
                        ForEach(AddContentKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("add-content-kind-picker")
                } else {
                    Picker("内容类型", selection: $model.kind) {
                        ForEach(AddContentKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("add-content-kind-picker")
                }
            }

            if model.kind == .sentenceAnalysis {
                SentenceAnalysisSections(
                    model: model,
                    isInputFocused: $isSentenceAnalysisInputFocused,
                    vocabularyService: vocabularyService,
                    grammarService: grammarService,
                    knowledgePointService: knowledgePointService,
                    deckService: deckService,
                    contentCardService: contentCardService,
                    historyService: historyService,
                    speechService: speechService
                )
            } else {
                if !model.isCaptureSession || !model.captureIsManualEdit {
                    aiGenerationSection
                }
                aiCandidateSection

                if let statusMessage = model.currentStatusMessage {
                    Section {
                        Label(statusMessage, systemImage: "doc.badge.clock")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(model.kind.draftStatusIdentifier)
                    }
                }

                targetDeckSection
                duplicateWarningSection

                Section {
                    if model.kind == .vocabulary {
                        Toggle("日语 → 中文", isOn: $model.vocabularyJapaneseToChinese)
                            .accessibilityIdentifier("vocabulary-direction-ja-zh")
                        Toggle("中文 → 日语", isOn: $model.vocabularyChineseToJapanese)
                            .accessibilityIdentifier("vocabulary-direction-zh-ja")
                    } else {
                        Toggle("语法形式 → 解释", isOn: $model.grammarFormToExplanation)
                            .accessibilityIdentifier("grammar-direction-form-explanation")
                    }
                } header: {
                    Text("卡片方向")
                } footer: {
                    Text("正式保存至少选择一个方向；每个方向拥有独立的复习进度。")
                }

                if model.kind == .vocabulary {
                    VocabularyRequiredSection(form: $model.vocabularyForm)
                    VocabularyAdditionalFieldsSection(
                        form: $model.vocabularyForm,
                        tagsText: $model.vocabularyTagsText,
                        isExpanded: $isVocabularyAdditionalFieldsExpanded
                    )
                } else {
                    GrammarRequiredSection(form: $model.grammarForm)
                    GrammarAdditionalFieldsSection(
                        form: $model.grammarForm,
                        tagsText: $model.grammarTagsText,
                        isExpanded: $isGrammarAdditionalFieldsExpanded
                    )
                }

                Section("内容预览") {
                    if model.kind == .vocabulary {
                        VocabularyPreview(form: model.vocabularyForm)
                    } else {
                        GrammarPreview(form: model.grammarForm)
                    }
                }

                Section("卡片预览") {
                    if model.kind == .vocabulary {
                        VocabularyCardPreviews(
                            form: model.vocabularyForm,
                            japaneseToChinese: model.vocabularyJapaneseToChinese,
                            chineseToJapanese: model.vocabularyChineseToJapanese
                        )
                    } else {
                        GrammarCardPreviews(
                            form: model.grammarForm,
                            isEnabled: model.grammarFormToExplanation
                        )
                    }
                }

                Section {
                    Button {
                        if model.duplicates.isEmpty {
                            Task { await model.commitCurrentContent() }
                        } else {
                            isConfirmingDuplicateCommit = true
                        }
                    } label: {
                        if model.isCommitting {
                            ProgressView()
                        } else {
                            Text("正式保存")
                        }
                    }
                        .disabled(!model.canCommit)
                        .accessibilityIdentifier(model.kind.formalSaveIdentifier)
                } footer: {
                    Text(model.commitAvailabilityMessage)
                }

                if model.hasCurrentDraft {
                    Section {
                        Button("清除草稿", role: .destructive) {
                            Task { await model.clearCurrentDraft() }
                        }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier(model.kind.clearDraftIdentifier)
                    }
                }
            }

            if let inboxService {
                Section {
                    NavigationLink {
                        InboxView(
                            service: inboxService,
                            processingServices: processingServices,
                            inboxImageStore: inboxImageStore,
                            drainSharedCaptures: drainSharedCaptures,
                            sharedCapturesAwaitingImport: sharedCapturesAwaitingImport,
                            importAwaitingSharedCaptures: importAwaitingSharedCaptures
                        )
                    } label: {
                        HStack {
                            Label("收集箱", systemImage: "tray.and.arrow.down")
                            Spacer()
                            Text(
                                unprocessedInboxCount > 0
                                    ? "\(unprocessedInboxCount) 条待处理"
                                    : "先收集，稍后处理"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("add-inbox-entry")

                    if inboxImageStore != nil, let ocrService {
                        Button {
                            isImageCapturePresented = true
                        } label: {
                            HStack {
                                Label("图片收集", systemImage: "photo.badge.plus")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("本地识别图片中的文字")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("add-image-capture-entry")
                        .sheet(isPresented: $isImageCapturePresented) {
                            ImageCaptureView(
                                imageStore: inboxImageStore!,
                                ocrService: ocrService,
                                inboxService: inboxService,
                                processingServices: processingServices
                            )
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.saveCurrentDraft() }
                } label: {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Label(
                            model.kind == .sentenceAnalysis ? "保存分析草稿" : "保存草稿",
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }
                .disabled(model.isLoading || model.isSaving)
                .accessibilityIdentifier(model.kind.saveDraftIdentifier)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    dismissKeyboard()
                }
                .accessibilityIdentifier("add-keyboard-done-button")
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView("正在恢复草稿…")
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
            await model.load()
        }
        .task {
            await observeInboxCount()
        }
        .task(id: model.duplicateQuery) {
            await model.checkDuplicates()
        }
        .onChange(of: model.kind) { _, _ in
            model.contentKindDidChange()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            isSentenceAnalysisInputFocused = false
            model.cancelGeneration(silently: true)
            model.cancelSentenceAnalysis(silently: true)
            speechService.stop()
        }
        .onDisappear {
            isSentenceAnalysisInputFocused = false
            model.cancelGeneration(silently: true)
            model.cancelSentenceAnalysis(silently: true)
            model.persistCaptureResume()
            speechService.stop()
        }
        .confirmationDialog(
            "发现可能重复的知识点",
            isPresented: $isConfirmingDuplicateCommit,
            titleVisibility: .visible
        ) {
            Button("明确另建义项并保存") {
                Task { await model.commitCurrentContent() }
            }
            .accessibilityIdentifier("duplicate-commit-confirm-button")
            Button("取消", role: .cancel) {}
        } message: {
            Text("建议先核对已有内容；如果含义或语境不同，可以明确另建。")
        }
    }

    /// Shared bundle for the Inbox detail and the image-capture sheet's
    /// "保存并处理" destination — one construction, one path.
    private var processingServices: InboxProcessingServices {
        InboxProcessingServices(
            deckService: deckService,
            vocabularyService: vocabularyService,
            grammarService: grammarService,
            knowledgePointService: knowledgePointService,
            contentCardService: contentCardService,
            aiCardGenerationService: aiCardGenerationService,
            sentenceAnalysisService: sentenceAnalysisService,
            sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
            historyService: historyService,
            speechService: speechService
        )
    }

    @ViewBuilder
    private var captureSourceSection: some View {
        if let capture = model.captureSession {
            Section {
                Text(capture.context.inputText)
                    .font(.callout)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("capture-source-text")
                if let notice = model.captureStaleNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("capture-stale-notice")
                }
                if let notice = model.captureInputLimitNotice {
                    Label(notice, systemImage: "scissors")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("capture-input-limit-notice")
                }
            } header: {
                Text("收集原文")
            }
        }
    }

    @ViewBuilder
    private var captureApproachSection: some View {
        @Bindable var model = model
        if model.kind != .sentenceAnalysis {
            Section {
                Picker(
                    "处理方式",
                    selection: Binding(
                        get: { model.captureIsManualEdit },
                        set: { model.captureApproachDidChange(manual: $0) }
                    )
                ) {
                    Text("AI 辅助").tag(false)
                    Text("手动填写").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("capture-approach-picker")
            }
        }
    }

    @MainActor
    private func observeInboxCount() async {
        guard let inboxService else { return }
        do {
            for try await count in inboxService.observeUnprocessedCount() {
                unprocessedInboxCount = count
            }
        } catch {
            return
        }
    }

    private func dismissKeyboard() {
        isSentenceAnalysisInputFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    @ViewBuilder
    private var aiGenerationSection: some View {
        @Bindable var model = model
        Section {
            if model.kind == .vocabulary {
                TextField("要生成的日语单词或短语", text: $model.vocabularyAIInput)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ai-card-vocabulary-input")
                TextField("补充语境（可选）", text: $model.vocabularyAIContext, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("ai-card-vocabulary-context")
            } else {
                TextField("要生成的日语语法形式", text: $model.grammarAIInput)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ai-card-grammar-input")
                TextField("补充语境（可选）", text: $model.grammarAIContext, axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("ai-card-grammar-context")
            }

            if model.isGenerating {
                HStack {
                    ProgressView()
                    Text("正在生成独立候选…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", role: .cancel) {
                        model.cancelGeneration()
                    }
                    .accessibilityIdentifier("ai-card-cancel-button")
                }
            } else {
                Button {
                    model.startGeneration()
                } label: {
                    Label(
                        model.generatedCandidate == nil ? "生成 AI 草稿" : "重新生成候选",
                        systemImage: "sparkles"
                    )
                }
                .disabled(!model.canGenerate)
                .accessibilityIdentifier("ai-card-generate-button")
            }

            if let message = model.aiGenerationStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai-card-generation-status")
            }
            if let message = model.aiGenerationErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("ai-card-generation-error")
                Button("转为手动填写") {
                    model.continueManually()
                }
                .accessibilityIdentifier("ai-card-continue-manually-button")
            }
        } header: {
            Text("AI 辅助制卡")
        } footer: {
            Text("会把本次输入和补充语境发送到已配置的 AI 服务，可能产生 API 用量。响应只作为候选，不会自动覆盖表单或写入正式知识点。")
                .accessibilityIdentifier("ai-card-generation-privacy-note")
        }
    }

    @ViewBuilder
    private var aiCandidateSection: some View {
        if let candidate = model.generatedCandidate {
            Section {
                switch candidate.payload {
                case let .vocabulary(form):
                    VocabularyPreview(form: form)
                case let .grammar(form):
                    GrammarPreview(form: form)
                }

                ForEach(Array(candidate.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.bubble")
                        .foregroundStyle(.orange)
                }

                Button("采用此候选并保存草稿") {
                    Task {
                        if await model.applyGeneratedCandidate() {
                            if model.kind == .vocabulary {
                                isVocabularyAdditionalFieldsExpanded = true
                            } else {
                                isGrammarAdditionalFieldsExpanded = true
                            }
                        }
                    }
                }
                .disabled(model.isSaving || model.isCommitting)
                .accessibilityIdentifier("ai-card-apply-candidate-button")
            } header: {
                Text("AI 草稿候选")
                    .accessibilityIdentifier("ai-card-candidate-section")
            } footer: {
                Text("请先核对假名、释义和例句。采用会替换当前类型的编辑表单并保存为普通本地草稿，仍需你确认后才能正式入库。")
            }
        }
    }

    @ViewBuilder
    private var targetDeckSection: some View {
        @Bindable var model = model
        Section("目标牌组") {
            if model.kind == .vocabulary {
                Picker("牌组", selection: $model.vocabularyDeckID) {
                    DeckPickerOptions(decks: model.decks)
                }
                .accessibilityIdentifier("vocabulary-deck-picker")
            } else {
                Picker("牌组", selection: $model.grammarDeckID) {
                    DeckPickerOptions(decks: model.decks)
                }
                .accessibilityIdentifier("grammar-deck-picker")
            }
        }
    }

    @ViewBuilder
    private var duplicateWarningSection: some View {
        if !model.duplicates.isEmpty {
            Section {
                Label(
                    "发现 \(model.duplicates.count) 个匹配的已有知识点",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("duplicate-warning")

                ForEach(model.duplicates) { item in
                    NavigationLink {
                        KnowledgePointDetailDestination(
                            item: item,
                            vocabularyService: vocabularyService,
                            grammarService: grammarService,
                            knowledgePointService: knowledgePointService,
                            deckService: deckService,
                            contentCardService: contentCardService,
                            historyService: historyService,
                            speechService: speechService
                        ) {
                            await model.checkDuplicates(immediately: true)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.headword)
                            if let reading = item.reading {
                                Text(reading)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.meaningZH)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("duplicate-row-\(item.id.uuidString)")
                }
            } header: {
                Text("可能重复")
            } footer: {
                Text("可先打开已有内容核对。重复提示不会阻止在正式保存时明确另建义项。")
            }
        }
    }
}
