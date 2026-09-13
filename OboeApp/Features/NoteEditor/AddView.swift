import Observation
import OboeDomain
import SwiftUI
import UIKit

struct AddView: View {
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
    @State private var isConfirmingDuplicateCommit = false
    @State private var isVocabularyAdditionalFieldsExpanded = false
    @State private var isGrammarAdditionalFieldsExpanded = false
    @State private var selectedSentenceAnalysisItemID: UUID?
    @FocusState private var isSentenceAnalysisInputFocused: Bool

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
        speechService: any SpeechService
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
        _model = State(
            initialValue: AddContentViewModel(
                deckService: deckService,
                vocabularyService: vocabularyService,
                grammarService: grammarService,
                knowledgePointService: knowledgePointService,
                contentCardService: contentCardService,
                aiCardGenerationService: aiCardGenerationService,
                sentenceAnalysisService: sentenceAnalysisService,
                sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
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
                    sentenceAnalysisSections
                } else {
                    aiGenerationSection
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
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("添加")
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
    private var sentenceAnalysisSections: some View {
        @Bindable var model = model
        Section {
            TextEditor(text: $model.sentenceAnalysisInput)
                .frame(minHeight: 110)
                .textInputAutocapitalization(.never)
                .focused($isSentenceAnalysisInputFocused)
                .accessibilityIdentifier("sentence-analysis-input")
                .onChange(of: model.sentenceAnalysisInput) { _, _ in
                    model.sentenceAnalysisInputDidChange()
                }
            HStack {
                Text("\(model.sentenceAnalysisInput.count) / 1,000")
                    .font(.caption)
                    .foregroundStyle(
                        model.sentenceAnalysisInput.count > 1_000 ? .red : .secondary
                    )
                Spacer()
                if model.isAnalyzingSentence {
                    ProgressView()
                    Button("取消", role: .cancel) {
                        model.cancelSentenceAnalysis()
                    }
                    .accessibilityIdentifier("sentence-analysis-cancel-button")
                } else {
                    Button {
                        isSentenceAnalysisInputFocused = false
                        model.startSentenceAnalysis()
                    } label: {
                        Label(
                            model.sentenceAnalysisResult == nil ? "分析句子" : "重新分析",
                            systemImage: "text.magnifyingglass"
                        )
                    }
                    .disabled(!model.canAnalyzeSentence)
                    .accessibilityIdentifier("sentence-analysis-start-button")
                }
            }
            if let message = model.sentenceAnalysisStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sentence-analysis-status")
            }
            if let message = model.sentenceAnalysisErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("sentence-analysis-error")
            }
        } header: {
            Text("AI 句子分析")
        } footer: {
            Text("分析会把这段日语发送到已配置的 AI 服务，可能产生 API 用量。后续勾选、编辑、查重和制卡只复用当前结果，不会再次请求 AI。")
                .accessibilityIdentifier("sentence-analysis-privacy-note")
        }

        if let statusMessage = model.currentStatusMessage {
            Section {
                Label(statusMessage, systemImage: "doc.badge.clock")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(model.kind.draftStatusIdentifier)
            }
        }

        if let result = model.sentenceAnalysisResult {
            let selectedItem = result.items.first {
                $0.id == (selectedSentenceAnalysisItemID ?? result.items.first?.id)
            }
            Section {
                Text(result.sentence)
                    .font(.title3)
                    .accessibilityIdentifier("sentence-analysis-original")
                LabeledContent("翻译") {
                    Text(result.translationZH)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("sentence-analysis-translation")
                Text(result.explanationZH)
                    .accessibilityIdentifier("sentence-analysis-explanation")

                if let selectedItem {
                    Divider()
                    if selectedItem.isFullyAligned {
                        Label(
                            selectedItem.spans.count == 1
                                ? "所选项目已在原文中安全定位"
                                : "所选项目已按 \(selectedItem.spans.count) 个片段安全定位",
                            systemImage: "scope"
                        )
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("sentence-analysis-aligned")
                        ForEach(Array(selectedItem.spans.enumerated()), id: \.offset) { _, span in
                            if let range = span.range {
                                Text("\(span.text) · 第 \(span.occurrence) 次 · 字符 \(range.lowerBound + 1)–\(range.upperBound)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Label(
                            "未能安全定位全部原文片段；解释仍可阅读，未进行高亮",
                            systemImage: "scope"
                        )
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("sentence-analysis-unaligned")
                    }
                }
            } header: {
                Text("原句与解释")
            }

            Section {
                ForEach(Array(result.items.enumerated()), id: \.element.id) { index, item in
                    Toggle(
                        "\(item.kind.displayName) · \(item.canonicalForm.isEmpty ? item.surface : item.canonicalForm)",
                        isOn: Binding(
                            get: {
                                model.selectedSentenceAnalysisItemIDs.contains(item.id)
                            },
                            set: { selected in
                                model.setSentenceCardSelection(
                                    itemID: item.id,
                                    selected: selected
                                )
                            }
                        )
                    )
                    .accessibilityIdentifier("sentence-card-select-\(item.kind.rawValue)-\(index)")
                }
            } header: {
                Text("选择制卡项目")
            } footer: {
                Text("只转换勾选项；转换复用当前分析结果，不会重新请求 AI。")
            }

            Section {
                ForEach(Array(result.items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            selectedSentenceAnalysisItemID = item.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.kind.displayName)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(item.surface)
                                        .font(.headline)
                                    if !item.canonicalForm.isEmpty,
                                       item.canonicalForm != item.surface {
                                        Text("→ \(item.canonicalForm)")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.id == (selectedSentenceAnalysisItemID ?? result.items.first?.id) {
                                        Image(systemName: "scope")
                                    }
                                }
                                if !item.reading.isEmpty {
                                    Text(item.reading)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.meaningZH)
                                Text(item.roleZH)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if item.suggestedCard != nil {
                                    Label("包含可复用的制卡草稿字段", systemImage: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sentence-analysis-item-\(item.kind.rawValue)-\(index)")
                    }
                }
            } header: {
                Text("分析项目（\(result.items.count)）")
                    .accessibilityIdentifier("sentence-analysis-items")
            } footer: {
                Text("点击项目可查看经过本地验证的原文定位。")
                    .accessibilityIdentifier("sentence-analysis-card-actions")
            }

            if !model.selectedSentenceAnalysisItemIDs.isEmpty {
                Section {
                    Text("已选择 \(model.selectedSentenceAnalysisItemIDs.count) 项；转换未发起新的 AI 请求。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sentence-card-selection-count")
                }
            }

            if let message = model.sentenceCardStatusMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sentence-card-status")
                }
            }

            if !model.sentenceCardDrafts.isEmpty {
                Section("目标牌组") {
                    Picker("牌组", selection: $model.sentenceAnalysisDeckID) {
                        deckPickerOptions(model.decks)
                    }
                    .accessibilityIdentifier("sentence-card-deck-picker")
                }

                ForEach(model.sentenceCardDrafts) { draftSnapshot in
                    let draftBinding = model.sentenceCardDraftBinding(fallback: draftSnapshot)
                    let draft = draftBinding.wrappedValue
                    Section {
                        Picker("知识点类型", selection: draftBinding.kind) {
                            Text("单词").tag(KnowledgePointKind.vocabulary)
                            Text("语法").tag(KnowledgePointKind.grammar)
                        }
                        .onChange(of: draft.kind) { _, _ in
                            model.sentenceCardDraftDidChange(itemID: draft.id)
                        }
                        TextField(
                            draft.kind == .vocabulary ? "日语词形" : "语法形式",
                            text: draftBinding.headword
                        )
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("sentence-card-headword-\(draft.id.uuidString)")
                        .onChange(of: draft.headword) { _, _ in
                            model.sentenceCardDraftDidChange(itemID: draft.id)
                        }
                        TextField("中文释义", text: draftBinding.meaningZH, axis: .vertical)
                            .lineLimit(2...4)

                        if draft.kind == .vocabulary {
                            TextField("假名（可选）", text: draftBinding.reading)
                                .textInputAutocapitalization(.never)
                                .onChange(of: draft.reading) { _, _ in
                                    model.sentenceCardDraftDidChange(itemID: draft.id)
                                }
                            TextField("词性（可选）", text: draftBinding.partOfSpeech)
                            Toggle(
                                "日语 → 中文",
                                isOn: Binding(
                                    get: {
                                        model.sentenceCardDirectionEnabled(
                                            itemID: draft.id,
                                            direction: .japaneseToChinese
                                        )
                                    },
                                    set: { enabled in
                                        model.setSentenceCardDirection(
                                            itemID: draft.id,
                                            direction: .japaneseToChinese,
                                            enabled: enabled
                                        )
                                    }
                                )
                            )
                            Toggle(
                                "中文 → 日语",
                                isOn: Binding(
                                    get: {
                                        model.sentenceCardDirectionEnabled(
                                            itemID: draft.id,
                                            direction: .chineseToJapanese
                                        )
                                    },
                                    set: { enabled in
                                        model.setSentenceCardDirection(
                                            itemID: draft.id,
                                            direction: .chineseToJapanese,
                                            enabled: enabled
                                        )
                                    }
                                )
                            )
                        } else {
                            TextField("用法（可选）", text: draftBinding.usage, axis: .vertical)
                                .lineLimit(2...4)
                            TextField("接续（可选）", text: draftBinding.connection, axis: .vertical)
                                .lineLimit(2...4)
                        }

                        TextField("日语例句（可选）", text: draftBinding.exampleJapanese, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("例句翻译（可选）", text: draftBinding.exampleTranslationZH, axis: .vertical)
                            .lineLimit(2...4)
                        TextField("备注（可选）", text: draftBinding.notes, axis: .vertical)
                            .lineLimit(2...4)

                        let duplicates = model.sentenceCardDuplicates[draft.id, default: []]
                        if !duplicates.isEmpty {
                            Label(
                                "发现 \(duplicates.count) 个匹配项，默认跳过本条",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("sentence-card-duplicate-\(draft.id.uuidString)")
                            ForEach(duplicates) { item in
                                NavigationLink {
                                    duplicateDestination(for: item, sentenceDraftID: draft.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.headword)
                                        Text(item.meaningZH)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Toggle("明确另建义项", isOn: draftBinding.createDespiteDuplicate)
                                .accessibilityIdentifier("sentence-card-create-duplicate-\(draft.id.uuidString)")
                        }
                    } header: {
                        Text("制卡预览 · \(draft.headword)")
                            .accessibilityIdentifier("sentence-card-preview-\(draft.id.uuidString)")
                    }
                }

                Section {
                    Button {
                        Task { await model.commitSentenceCards() }
                    } label: {
                        if model.isCommitting {
                            ProgressView()
                        } else {
                            Text("原子保存所选知识点（\(model.sentenceCardDraftsForCommit.count)）")
                        }
                    }
                    .disabled(!model.canCommit)
                    .accessibilityIdentifier("sentence-card-batch-save-button")
                } footer: {
                    Text("所有待保存预览会先统一校验，再在一个数据库事务中写入；任一项失败都不会部分保存。")
                }
            }

            if !result.warnings.isEmpty {
                Section("需要核对") {
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.bubble")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }

        if model.hasCurrentDraft {
            Section {
                Button("清除分析草稿", role: .destructive) {
                    selectedSentenceAnalysisItemID = nil
                    Task { await model.clearCurrentDraft() }
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier(model.kind.clearDraftIdentifier)
            }
        }
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
    private func deckPickerOptions(_ decks: [DeckSummary]) -> some View {
        Text("暂不选择").tag(nil as UUID?)
        ForEach(decks) { deck in
            Text(deck.name).tag(deck.id as UUID?)
        }
    }

    @ViewBuilder
    private var targetDeckSection: some View {
        @Bindable var model = model
        Section("目标牌组") {
            if model.kind == .vocabulary {
                Picker("牌组", selection: $model.vocabularyDeckID) {
                    deckPickerOptions(model.decks)
                }
                .accessibilityIdentifier("vocabulary-deck-picker")
            } else {
                Picker("牌组", selection: $model.grammarDeckID) {
                    deckPickerOptions(model.decks)
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
                        duplicateDestination(for: item)
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

    @ViewBuilder
    private func duplicateDestination(
        for item: KnowledgePointSummary,
        sentenceDraftID: UUID? = nil
    ) -> some View {
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
                if let sentenceDraftID {
                    await model.checkSentenceCardDuplicate(
                        itemID: sentenceDraftID,
                        immediately: true
                    )
                } else {
                    await model.checkDuplicates(immediately: true)
                }
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
                if let sentenceDraftID {
                    await model.checkSentenceCardDuplicate(
                        itemID: sentenceDraftID,
                        immediately: true
                    )
                } else {
                    await model.checkDuplicates(immediately: true)
                }
            }
        }
    }
}

private enum AddContentKind: String, CaseIterable, Identifiable {
    case vocabulary
    case grammar
    case sentenceAnalysis = "sentence_analysis"

    var id: Self { self }
    var title: String {
        switch self {
        case .vocabulary: "单词"
        case .grammar: "语法"
        case .sentenceAnalysis: "句子分析"
        }
    }
    var draftStatusIdentifier: String { "\(rawValue)-draft-status" }
    var formalSaveIdentifier: String { "\(rawValue)-formal-save-button" }
    var clearDraftIdentifier: String { "\(rawValue)-clear-draft-button" }
    var saveDraftIdentifier: String { "\(rawValue)-save-draft-button" }
}

private struct DuplicateQuery: Hashable {
    let kind: AddContentKind
    let headword: String
    let reading: String
}

@MainActor
@Observable
private final class AddContentViewModel {
    private let deckService: DeckManagementService
    private let vocabularyService: VocabularyService
    private let grammarService: GrammarService
    private let knowledgePointService: KnowledgePointService
    private let contentCardService: ContentCardService
    private let aiCardGenerationService: AICardGenerationService
    private let sentenceAnalysisService: SentenceAnalysisService
    private let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    private var didLoad = false
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationGate = AIGenerationRequestGate()
    @ObservationIgnored private var nextInputVersion = 0
    @ObservationIgnored private var sentenceAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var sentenceAnalysisGate = AIGenerationRequestGate()
    @ObservationIgnored private var nextSentenceInputVersion = 0
    @ObservationIgnored private var isRestoringSentenceDraft = false

    var kind = AddContentKind.vocabulary
    var decks: [DeckSummary] = []
    var vocabularyDeckID: UUID?
    var vocabularyForm = VocabularyFormData()
    var vocabularyDraftID: UUID?
    var vocabularyStatusMessage: String?
    var grammarDeckID: UUID?
    var grammarForm = GrammarFormData()
    var grammarDraftID: UUID?
    var grammarStatusMessage: String?
    var vocabularyTagsText = ""
    var grammarTagsText = ""
    var vocabularyJapaneseToChinese = true
    var vocabularyChineseToJapanese = false
    var grammarFormToExplanation = true
    var vocabularyAIInput = ""
    var vocabularyAIContext = ""
    var grammarAIInput = ""
    var grammarAIContext = ""
    var generatedCandidate: AICardDraftCandidate?
    var aiGenerationStatusMessage: String?
    var aiGenerationErrorMessage: String?
    var isGenerating = false
    var sentenceAnalysisInput = ""
    var sentenceAnalysisResult: SentenceAnalysisResult?
    var sentenceAnalysisDraftID: UUID?
    var sentenceAnalysisProviderID: String?
    var sentenceAnalysisModelID: String?
    var sentenceAnalysisStatusMessage: String?
    var sentenceAnalysisDraftStatusMessage: String?
    var sentenceAnalysisErrorMessage: String?
    var isAnalyzingSentence = false
    var selectedSentenceAnalysisItemIDs = Set<UUID>()
    var sentenceCardDrafts: [SentenceAnalysisCardDraft] = []
    var sentenceCardDuplicates: [UUID: [KnowledgePointSummary]] = [:]
    var sentenceAnalysisDeckID: UUID?
    var sentenceCardStatusMessage: String?
    var errorMessage: String?
    var isLoading = true
    var isSaving = false
    var isCommitting = false
    var duplicates: [KnowledgePointSummary] = []

    var currentStatusMessage: String? {
        switch kind {
        case .vocabulary: vocabularyStatusMessage
        case .grammar: grammarStatusMessage
        case .sentenceAnalysis: sentenceAnalysisDraftStatusMessage
        }
    }

    var hasCurrentDraft: Bool {
        switch kind {
        case .vocabulary: vocabularyDraftID != nil
        case .grammar: grammarDraftID != nil
        case .sentenceAnalysis: sentenceAnalysisDraftID != nil
        }
    }

    var duplicateQuery: DuplicateQuery {
        switch kind {
        case .vocabulary:
            DuplicateQuery(
                kind: kind,
                headword: vocabularyForm.headword,
                reading: vocabularyForm.reading
            )
        case .grammar:
            DuplicateQuery(kind: kind, headword: grammarForm.grammarForm, reading: "")
        case .sentenceAnalysis:
            DuplicateQuery(kind: kind, headword: "", reading: "")
        }
    }

    init(
        deckService: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        contentCardService: ContentCardService,
        aiCardGenerationService: AICardGenerationService,
        sentenceAnalysisService: SentenceAnalysisService,
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    ) {
        self.deckService = deckService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.contentCardService = contentCardService
        self.aiCardGenerationService = aiCardGenerationService
        self.sentenceAnalysisService = sentenceAnalysisService
        self.sentenceAnalysisCardCreationService = sentenceAnalysisCardCreationService
    }

    var vocabularyDirections: Set<VocabularyCardDirection> {
        var directions = Set<VocabularyCardDirection>()
        if vocabularyJapaneseToChinese { directions.insert(.japaneseToChinese) }
        if vocabularyChineseToJapanese { directions.insert(.chineseToJapanese) }
        return directions
    }

    var canCommit: Bool {
        guard !isLoading, !isSaving, !isCommitting else { return false }
        switch kind {
        case .vocabulary:
            return vocabularyDeckID != nil
                && !vocabularyDirections.isEmpty
                && (try? vocabularyForm.validatedContent()) != nil
                && tagsAreValid(vocabularyTagsText)
        case .grammar:
            return grammarDeckID != nil
                && grammarFormToExplanation
                && (try? grammarForm.validatedContent()) != nil
                && tagsAreValid(grammarTagsText)
        case .sentenceAnalysis:
            return sentenceAnalysisDeckID != nil
                && !sentenceCardDraftsForCommit.isEmpty
                && (try? sentenceAnalysisCardCreationService.validate(
                    sentenceCardDraftsForCommit
                )) != nil
        }
    }

    var canGenerate: Bool {
        guard kind != .sentenceAnalysis, !isLoading, !isGenerating else { return false }
        return !currentAIInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canAnalyzeSentence: Bool {
        guard kind == .sentenceAnalysis, !isLoading, !isAnalyzingSentence else { return false }
        return (try? SentenceAnalysisDecoder.validated(
            SentenceAnalysisInput(sentence: sentenceAnalysisInput)
        )) != nil
    }

    func contentKindDidChange() {
        cancelGeneration(silently: true)
        cancelSentenceAnalysis(silently: true)
        generatedCandidate = nil
        aiGenerationStatusMessage = nil
        aiGenerationErrorMessage = nil
    }

    var sentenceCardDraftsForCommit: [SentenceAnalysisCardDraft] {
        sentenceCardDrafts.filter { draft in
            sentenceCardDuplicates[draft.id, default: []].isEmpty
                || draft.createDespiteDuplicate
        }
    }

    func sentenceCardDraftBinding(
        fallback: SentenceAnalysisCardDraft
    ) -> Binding<SentenceAnalysisCardDraft> {
        Binding(
            get: { [weak self] in
                self?.sentenceCardDrafts.first(where: { $0.id == fallback.id }) ?? fallback
            },
            set: { [weak self] updated in
                guard let self,
                      let index = sentenceCardDrafts.firstIndex(where: { $0.id == fallback.id })
                else { return }
                sentenceCardDrafts[index] = updated
            }
        )
    }

    func sentenceCardDirectionEnabled(
        itemID: UUID,
        direction: VocabularyCardDirection
    ) -> Bool {
        sentenceCardDrafts.first(where: { $0.id == itemID })?
            .vocabularyDirections.contains(direction) ?? false
    }

    func setSentenceCardDirection(
        itemID: UUID,
        direction: VocabularyCardDirection,
        enabled: Bool
    ) {
        guard let index = sentenceCardDrafts.firstIndex(where: { $0.id == itemID }) else { return }
        if enabled {
            sentenceCardDrafts[index].vocabularyDirections.insert(direction)
        } else {
            sentenceCardDrafts[index].vocabularyDirections.remove(direction)
        }
    }

    func setSentenceCardSelection(itemID: UUID, selected: Bool) {
        guard let result = sentenceAnalysisResult else { return }
        guard selected != selectedSentenceAnalysisItemIDs.contains(itemID) else { return }
        if !selected {
            selectedSentenceAnalysisItemIDs.remove(itemID)
            sentenceCardDrafts.removeAll { $0.id == itemID }
            sentenceCardDuplicates[itemID] = nil
            sentenceCardStatusMessage = nil
            return
        }
        selectedSentenceAnalysisItemIDs.insert(itemID)
        do {
            let generated = try sentenceAnalysisCardCreationService.makeDrafts(
                from: result,
                selectedItemIDs: selectedSentenceAnalysisItemIDs
            )
            let current = Dictionary(uniqueKeysWithValues: sentenceCardDrafts.map { ($0.id, $0) })
            sentenceCardDrafts = generated.map { current[$0.id] ?? $0 }
            sentenceCardStatusMessage = "已选择 \(sentenceCardDrafts.count) 项；转换未发起新的 AI 请求。"
            Task { await checkSentenceCardDuplicate(itemID: itemID, immediately: true) }
        } catch {
            selectedSentenceAnalysisItemIDs.remove(itemID)
            errorMessage = error.localizedDescription
        }
    }

    func checkSentenceCardDuplicate(itemID: UUID, immediately: Bool = false) async {
        guard let draft = sentenceCardDrafts.first(where: { $0.id == itemID }) else { return }
        let kind = draft.kind
        let headword = draft.headword
        let reading = draft.reading
        do {
            if !immediately {
                try await Task.sleep(for: .milliseconds(250))
            }
            let matches = try await knowledgePointService.fetchDuplicates(
                kind: kind,
                headword: headword,
                reading: reading
            )
            guard let current = sentenceCardDrafts.first(where: { $0.id == itemID }),
                  current.kind == kind,
                  current.headword == headword,
                  current.reading == reading else { return }
            sentenceCardDuplicates[itemID] = matches
        } catch is CancellationError {
            // A later edit supersedes this local lookup.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sentenceCardDraftDidChange(itemID: UUID) {
        sentenceCardStatusMessage = nil
        Task { await checkSentenceCardDuplicate(itemID: itemID) }
    }

    func commitSentenceCards() async {
        guard kind == .sentenceAnalysis, canCommit else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            let drafts = sentenceCardDraftsForCommit
            let result = try await sentenceAnalysisCardCreationService.commit(
                deckID: sentenceAnalysisDeckID,
                drafts: drafts
            )
            let savedIDs = Set(drafts.map(\.id))
            selectedSentenceAnalysisItemIDs.subtract(savedIDs)
            sentenceCardDrafts.removeAll { savedIDs.contains($0.id) }
            for id in savedIDs {
                sentenceCardDuplicates[id] = nil
            }
            sentenceCardStatusMessage = "已原子保存 \(result.noteIDs.count) 个知识点，生成 \(result.cardCount) 张卡片。"
        } catch {
            errorMessage = Self.commitMessage(for: error)
        }
    }

    private func resetSentenceCardSelection() {
        selectedSentenceAnalysisItemIDs = []
        sentenceCardDrafts = []
        sentenceCardDuplicates = [:]
        sentenceCardStatusMessage = nil
    }

    func startGeneration() {
        guard kind != .sentenceAnalysis, canGenerate else { return }
        nextInputVersion += 1
        let requestID = UUID()
        let input = AICardGenerationInput(
            requestID: requestID,
            inputVersion: nextInputVersion,
            kind: kind == .vocabulary ? .vocabulary : .grammar,
            text: currentAIInput,
            context: currentAIContext
        )
        do {
            _ = try AICardOutputDecoder.validated(input)
        } catch {
            aiGenerationErrorMessage = error.localizedDescription
            return
        }

        generationTask?.cancel()
        generationGate.begin(requestID)
        isGenerating = true
        aiGenerationStatusMessage = nil
        aiGenerationErrorMessage = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate = try await aiCardGenerationService.generate(
                    input,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                guard generationGate.finish(requestID) else { return }
                generatedCandidate = candidate
                aiGenerationStatusMessage = "已生成独立候选；当前表单尚未改变。"
                isGenerating = false
                generationTask = nil
            } catch {
                guard generationGate.finish(requestID) else { return }
                isGenerating = false
                generationTask = nil
                if error is CancellationError || error as? AIConnectionError == .cancelled {
                    aiGenerationStatusMessage = "生成已取消，原始输入已保留。"
                } else {
                    aiGenerationErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelGeneration(silently: Bool = false) {
        guard isGenerating || generationTask != nil else { return }
        generationTask?.cancel()
        generationTask = nil
        generationGate.cancel()
        isGenerating = false
        if !silently {
            aiGenerationStatusMessage = "生成已取消，原始输入已保留。"
        }
    }

    func sentenceAnalysisInputDidChange() {
        guard !isRestoringSentenceDraft else { return }
        if isAnalyzingSentence {
            cancelSentenceAnalysis(silently: true)
            sentenceAnalysisStatusMessage = "输入已改变，旧请求已取消。"
        }
        let currentSentence = sentenceAnalysisInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result = sentenceAnalysisResult, result.sentence != currentSentence {
            sentenceAnalysisResult = nil
            sentenceAnalysisProviderID = nil
            sentenceAnalysisModelID = nil
            resetSentenceCardSelection()
            sentenceAnalysisStatusMessage = "输入已修改，请重新分析。"
        }
        sentenceAnalysisErrorMessage = nil
    }

    func startSentenceAnalysis() {
        guard canAnalyzeSentence else { return }
        nextSentenceInputVersion += 1
        let requestID = UUID()
        let input: SentenceAnalysisInput
        do {
            input = try SentenceAnalysisDecoder.validated(
                SentenceAnalysisInput(
                    requestID: requestID,
                    inputVersion: nextSentenceInputVersion,
                    sentence: sentenceAnalysisInput
                )
            )
        } catch {
            sentenceAnalysisErrorMessage = error.localizedDescription
            return
        }

        sentenceAnalysisTask?.cancel()
        sentenceAnalysisGate.begin(requestID)
        isAnalyzingSentence = true
        sentenceAnalysisStatusMessage = nil
        sentenceAnalysisErrorMessage = nil
        sentenceAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate = try await sentenceAnalysisService.analyze(
                    input,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                guard sentenceAnalysisGate.finish(requestID) else { return }
                isAnalyzingSentence = false
                sentenceAnalysisTask = nil
                sentenceAnalysisResult = candidate.result
                sentenceAnalysisProviderID = candidate.providerID
                sentenceAnalysisModelID = candidate.modelID
                resetSentenceCardSelection()
                sentenceAnalysisStatusMessage = "分析完成；原文定位已在本机核验。"
                do {
                    let draft = try await sentenceAnalysisService.saveDraft(
                        id: sentenceAnalysisDraftID,
                        sentence: input.sentence,
                        result: candidate.result,
                        providerID: candidate.providerID,
                        modelID: candidate.modelID
                    )
                    sentenceAnalysisDraftID = draft.id
                    sentenceAnalysisDraftStatusMessage = "分析结果已保存为本地草稿"
                } catch {
                    sentenceAnalysisErrorMessage = "分析完成，但无法保存草稿：\(error.localizedDescription)"
                }
            } catch {
                guard sentenceAnalysisGate.finish(requestID) else { return }
                isAnalyzingSentence = false
                sentenceAnalysisTask = nil
                if error is CancellationError || error as? AIConnectionError == .cancelled {
                    sentenceAnalysisStatusMessage = "分析已取消，原始输入已保留。"
                } else {
                    sentenceAnalysisErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelSentenceAnalysis(silently: Bool = false) {
        guard isAnalyzingSentence || sentenceAnalysisTask != nil else { return }
        sentenceAnalysisTask?.cancel()
        sentenceAnalysisTask = nil
        sentenceAnalysisGate.cancel()
        isAnalyzingSentence = false
        if !silently {
            sentenceAnalysisStatusMessage = "分析已取消，原始输入已保留。"
        }
    }

    func continueManually() {
        aiGenerationErrorMessage = nil
        aiGenerationStatusMessage = "可继续在下方手动填写；AI 输入仍已保留。"
    }

    func applyGeneratedCandidate() async -> Bool {
        guard let candidate = generatedCandidate, !isSaving, !isCommitting else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            switch candidate.payload {
            case let .vocabulary(form):
                guard kind == .vocabulary else { return false }
                vocabularyForm = form
                let draft = try await vocabularyService.saveDraft(
                    id: vocabularyDraftID,
                    deckID: vocabularyDeckID,
                    formData: form
                )
                vocabularyDraftID = draft.id
                vocabularyStatusMessage = "AI 候选已采用并保存为本地草稿"
            case let .grammar(form):
                guard kind == .grammar else { return false }
                grammarForm = form
                let draft = try await grammarService.saveDraft(
                    id: grammarDraftID,
                    deckID: grammarDeckID,
                    formData: form
                )
                grammarDraftID = draft.id
                grammarStatusMessage = "AI 候选已采用并保存为本地草稿"
            }
            generatedCandidate = nil
            aiGenerationStatusMessage = "已采用候选；请继续核对、修改并确认正式保存。"
            aiGenerationErrorMessage = nil
            return true
        } catch {
            aiGenerationErrorMessage = "无法保存 AI 草稿：\(error.localizedDescription)"
            return false
        }
    }

    private var currentAIInput: String {
        switch kind {
        case .vocabulary: vocabularyAIInput
        case .grammar: grammarAIInput
        case .sentenceAnalysis: sentenceAnalysisInput
        }
    }

    private var currentAIContext: String {
        switch kind {
        case .vocabulary: vocabularyAIContext
        case .grammar: grammarAIContext
        case .sentenceAnalysis: ""
        }
    }

    var commitAvailabilityMessage: String {
        if decks.isEmpty { return "请先在牌组页创建目标牌组。" }
        if kind == .vocabulary, vocabularyDirections.isEmpty {
            return "至少选择一个单词卡片方向。"
        }
        if kind == .grammar, !grammarFormToExplanation {
            return "至少选择语法形式 → 解释方向。"
        }
        return "确认后会原子保存正文、例句、标签和卡片；卡片暂不提供评分或下次复习时间。"
    }

    func load() async {
        if didLoad {
            do {
                decks = try await deckService.fetchDecks()
                if !decks.contains(where: { $0.id == vocabularyDeckID }) {
                    vocabularyDeckID = decks.first?.id
                }
                if !decks.contains(where: { $0.id == grammarDeckID }) {
                    grammarDeckID = decks.first?.id
                }
                if !decks.contains(where: { $0.id == sentenceAnalysisDeckID }) {
                    sentenceAnalysisDeckID = decks.first?.id
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        didLoad = true

        do {
            decks = try await deckService.fetchDecks()
            try await restoreVocabularyDraft()
            try await restoreGrammarDraft()
            try await restoreSentenceAnalysisDraft()
            sentenceAnalysisDeckID = decks.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func saveCurrentDraft() async {
        guard !isSaving else {
            return
        }
        isSaving = true
        defer { isSaving = false }

        do {
            switch kind {
            case .vocabulary:
                let draft = try await vocabularyService.saveDraft(
                    id: vocabularyDraftID,
                    deckID: vocabularyDeckID,
                    formData: vocabularyForm
                )
                vocabularyDraftID = draft.id
                vocabularyStatusMessage = "草稿已保存"
            case .grammar:
                let draft = try await grammarService.saveDraft(
                    id: grammarDraftID,
                    deckID: grammarDeckID,
                    formData: grammarForm
                )
                grammarDraftID = draft.id
                grammarStatusMessage = "草稿已保存"
            case .sentenceAnalysis:
                let currentSentence = sentenceAnalysisInput.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let result = sentenceAnalysisResult?.sentence == currentSentence
                    ? sentenceAnalysisResult
                    : nil
                let draft = try await sentenceAnalysisService.saveDraft(
                    id: sentenceAnalysisDraftID,
                    sentence: currentSentence,
                    result: result,
                    providerID: result == nil ? nil : sentenceAnalysisProviderID,
                    modelID: result == nil ? nil : sentenceAnalysisModelID
                )
                sentenceAnalysisDraftID = draft.id
                sentenceAnalysisDraftStatusMessage = "分析草稿已保存"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearCurrentDraft() async {
        do {
            switch kind {
            case .vocabulary:
                guard let vocabularyDraftID else { return }
                try await vocabularyService.deleteDraft(id: vocabularyDraftID)
                self.vocabularyDraftID = nil
                vocabularyForm = VocabularyFormData()
                vocabularyDeckID = decks.first?.id
                vocabularyStatusMessage = "草稿已清除"
            case .grammar:
                guard let grammarDraftID else { return }
                try await grammarService.deleteDraft(id: grammarDraftID)
                self.grammarDraftID = nil
                grammarForm = GrammarFormData()
                grammarDeckID = decks.first?.id
                grammarStatusMessage = "草稿已清除"
            case .sentenceAnalysis:
                guard let sentenceAnalysisDraftID else { return }
                try await sentenceAnalysisService.deleteDraft(id: sentenceAnalysisDraftID)
                self.sentenceAnalysisDraftID = nil
                sentenceAnalysisInput = ""
                sentenceAnalysisResult = nil
                sentenceAnalysisProviderID = nil
                sentenceAnalysisModelID = nil
                resetSentenceCardSelection()
                sentenceAnalysisStatusMessage = nil
                sentenceAnalysisDraftStatusMessage = "分析草稿已清除"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commitCurrentContent() async {
        guard canCommit else { return }
        isCommitting = true
        defer { isCommitting = false }

        do {
            let result: ContentCommitResult
            switch kind {
            case .vocabulary:
                result = try await contentCardService.commitVocabulary(
                    draftID: vocabularyDraftID,
                    deckID: vocabularyDeckID,
                    formData: vocabularyForm,
                    directions: vocabularyDirections,
                    rawTagNames: parsedTags(vocabularyTagsText)
                )
                vocabularyDraftID = nil
                vocabularyForm = VocabularyFormData()
                vocabularyTagsText = ""
                vocabularyJapaneseToChinese = true
                vocabularyChineseToJapanese = false
                vocabularyStatusMessage = "已正式保存，生成 \(result.cardCount) 张卡片"
            case .grammar:
                result = try await contentCardService.commitGrammar(
                    draftID: grammarDraftID,
                    deckID: grammarDeckID,
                    formData: grammarForm,
                    includesDirection: grammarFormToExplanation,
                    rawTagNames: parsedTags(grammarTagsText)
                )
                grammarDraftID = nil
                grammarForm = GrammarFormData()
                grammarTagsText = ""
                grammarFormToExplanation = true
                grammarStatusMessage = "已正式保存，生成 \(result.cardCount) 张卡片"
            case .sentenceAnalysis:
                return
            }
            duplicates = []
        } catch {
            errorMessage = Self.commitMessage(for: error)
        }
    }

    func checkDuplicates(immediately: Bool = false) async {
        let query = duplicateQuery
        guard !query.headword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            duplicates = []
            return
        }
        do {
            if !immediately {
                try await Task.sleep(for: .milliseconds(250))
            }
            let result = try await knowledgePointService.fetchDuplicates(
                kind: query.kind == .vocabulary ? .vocabulary : .grammar,
                headword: query.headword,
                reading: query.reading
            )
            guard query == duplicateQuery else { return }
            duplicates = result
        } catch is CancellationError {
            // A later field value supersedes this lookup.
        } catch {
            guard query == duplicateQuery else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func restoreVocabularyDraft() async throws {
        if let draft = try await vocabularyService.fetchLatestDraft() {
            vocabularyDraftID = draft.id
            vocabularyDeckID = decks.contains { $0.id == draft.deckID } ? draft.deckID : nil
            vocabularyForm = draft.formData
            vocabularyStatusMessage = "已恢复上次草稿"
        } else {
            vocabularyDeckID = decks.first?.id
        }
    }

    private func restoreGrammarDraft() async throws {
        if let draft = try await grammarService.fetchLatestDraft() {
            grammarDraftID = draft.id
            grammarDeckID = decks.contains { $0.id == draft.deckID } ? draft.deckID : nil
            grammarForm = draft.formData
            grammarStatusMessage = "已恢复上次草稿"
        } else {
            grammarDeckID = decks.first?.id
        }
    }

    private func restoreSentenceAnalysisDraft() async throws {
        guard let draft = try await sentenceAnalysisService.fetchLatestDraft() else { return }
        isRestoringSentenceDraft = true
        sentenceAnalysisDraftID = draft.id
        sentenceAnalysisInput = draft.sentence
        sentenceAnalysisResult = draft.result
        sentenceAnalysisProviderID = draft.providerID
        sentenceAnalysisModelID = draft.modelID
        sentenceAnalysisDraftStatusMessage = "已恢复上次分析草稿"
        isRestoringSentenceDraft = false
    }

    private func parsedTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func tagsAreValid(_ text: String) -> Bool {
        parsedTags(text).allSatisfy { (try? KnowledgeTagName(validating: $0)) != nil }
    }

    private static func commitMessage(for error: Error) -> String {
        switch error {
        case ContentCardError.deckRequired:
            "请选择目标牌组。"
        case ContentCardError.cardDirectionRequired, VocabularyValidationError.cardDirectionRequired:
            "请至少选择一个卡片方向。"
        case ContentCardError.deckNotFound:
            "目标牌组已不存在，请重新选择。"
        case ContentCardError.knowledgePointNotFound:
            "知识点已不存在。"
        case ContentCardError.invalidTemplateForKnowledgePoint:
            "卡片方向与知识点类型不匹配。"
        case VocabularyValidationError.headwordRequired:
            "请填写日语词形。"
        case VocabularyValidationError.meaningRequired, GrammarValidationError.meaningRequired:
            "请填写中文释义。"
        case VocabularyValidationError.exampleJapaneseRequired,
             GrammarValidationError.exampleJapaneseRequired:
            "填写例句翻译时也需要日语例句。"
        case GrammarValidationError.grammarFormRequired:
            "请填写语法形式。"
        default:
            error.localizedDescription
        }
    }
}

private struct VocabularyRequiredSection: View {
    @Binding var form: VocabularyFormData

    var body: some View {
        Section("必填") {
            TextField("日语词形", text: $form.headword)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("vocabulary-headword-field")
            TextField("中文释义", text: $form.meaningZH)
                .accessibilityIdentifier("vocabulary-meaning-field")
        }
    }
}

private struct VocabularyAdditionalFieldsSection: View {
    @Binding var form: VocabularyFormData
    @Binding var tagsText: String
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup("更多字段（可选）", isExpanded: $isExpanded) {
                TextField("假名", text: $form.reading)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("vocabulary-reading-field")
                TextField("词性", text: $form.partOfSpeech)
                    .accessibilityIdentifier("vocabulary-part-of-speech-field")
                Picker("JLPT", selection: $form.jlpt) {
                    Text("未设置").tag(nil as JLPTLevel?)
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as JLPTLevel?)
                    }
                }
                .accessibilityIdentifier("vocabulary-jlpt-picker")
                TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("vocabulary-example-field")
                TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("vocabulary-example-translation-field")
                TextField("标签（逗号或换行分隔）", text: $tagsText)
                    .accessibilityIdentifier("vocabulary-new-tags-field")
                TextEditor(text: $form.notes)
                    .frame(minHeight: 90)
                    .accessibilityIdentifier("vocabulary-notes-field")
            }
        } footer: {
            Text("标签、例句、备注和卡片会在同一事务保存。")
        }
    }
}

private struct VocabularyFormSections: View {
    @Binding var form: VocabularyFormData

    var body: some View {
        VocabularyRequiredSection(form: $form)
        Section("词条信息") {
            TextField("假名", text: $form.reading)
            TextField("词性", text: $form.partOfSpeech)
            Picker("JLPT", selection: $form.jlpt) {
                Text("未设置").tag(nil as JLPTLevel?)
                ForEach(JLPTLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level as JLPTLevel?)
                }
            }
        }
        Section("例句") {
            TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
            TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
        }
        Section("备注") {
            TextEditor(text: $form.notes)
                .frame(minHeight: 90)
        }
    }
}

private struct GrammarRequiredSection: View {
    @Binding var form: GrammarFormData

    var body: some View {
        Section("必填") {
            TextField("语法形式", text: $form.grammarForm)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("grammar-form-field")
            TextField("中文含义", text: $form.meaningZH)
                .accessibilityIdentifier("grammar-meaning-field")
        }
    }
}

private struct GrammarAdditionalFieldsSection: View {
    @Binding var form: GrammarFormData
    @Binding var tagsText: String
    @Binding var isExpanded: Bool

    var body: some View {
        Section {
            DisclosureGroup("更多字段（可选）", isExpanded: $isExpanded) {
                TextField("使用说明", text: $form.usage, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-usage-field")
                TextField("接续方式", text: $form.connection, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-connection-field")
                Picker("JLPT", selection: $form.jlpt) {
                    Text("未设置").tag(nil as JLPTLevel?)
                    ForEach(JLPTLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level as JLPTLevel?)
                    }
                }
                .accessibilityIdentifier("grammar-jlpt-picker")
                TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-example-field")
                TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("grammar-example-translation-field")
                TextField("标签（逗号或换行分隔）", text: $tagsText)
                    .accessibilityIdentifier("grammar-new-tags-field")
                TextEditor(text: $form.notes)
                    .frame(minHeight: 90)
                    .accessibilityIdentifier("grammar-notes-field")
            }
        } footer: {
            Text("标签、例句、注意事项和卡片会在同一事务保存。")
        }
    }
}

private struct GrammarFormSections: View {
    @Binding var form: GrammarFormData

    var body: some View {
        GrammarRequiredSection(form: $form)
        Section("语法信息") {
            TextField("使用说明", text: $form.usage, axis: .vertical)
            TextField("接续方式", text: $form.connection, axis: .vertical)
            Picker("JLPT", selection: $form.jlpt) {
                Text("未设置").tag(nil as JLPTLevel?)
                ForEach(JLPTLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level as JLPTLevel?)
                }
            }
        }
        Section("例句") {
            TextField("日语例句", text: $form.exampleJapanese, axis: .vertical)
            TextField("例句翻译", text: $form.exampleTranslationZH, axis: .vertical)
        }
        Section("注意事项") {
            TextEditor(text: $form.notes)
                .frame(minHeight: 90)
        }
    }
}

private struct VocabularyPreview: View {
    let form: VocabularyFormData

    var body: some View {
        if let content = try? form.validatedContent() {
            VStack(alignment: .leading, spacing: 6) {
                Text(content.headword)
                    .font(.title3.bold())
                if let reading = content.reading {
                    Text(reading)
                        .foregroundStyle(.secondary)
                }
                Text(content.meaningZH)
                if let example = content.example {
                    Divider()
                    Text(example.japanese)
                    if let translation = example.translationZH {
                        Text(translation)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text(vocabularyValidationMessage(for: form))
                .foregroundStyle(.secondary)
        }
    }
}

private struct GrammarPreview: View {
    let form: GrammarFormData

    var body: some View {
        if let content = try? form.validatedContent() {
            VStack(alignment: .leading, spacing: 6) {
                Text(content.grammarForm)
                    .font(.title3.bold())
                Text(content.meaningZH)
                if let connection = content.connection {
                    LabeledContent("接续", value: connection)
                }
                if let usage = content.usage {
                    Text(usage)
                        .foregroundStyle(.secondary)
                }
                if let example = content.example {
                    Divider()
                    Text(example.japanese)
                    if let translation = example.translationZH {
                        Text(translation)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text(grammarValidationMessage(for: form))
                .foregroundStyle(.secondary)
        }
    }
}

private struct VocabularyCardPreviews: View {
    let form: VocabularyFormData
    let japaneseToChinese: Bool
    let chineseToJapanese: Bool

    var body: some View {
        if let content = try? form.validatedContent() {
            if japaneseToChinese {
                CardFacePreview(
                    title: "日语 → 中文",
                    front: [content.headword],
                    back: [
                        content.reading,
                        content.meaningZH,
                        content.partOfSpeech,
                        content.example?.japanese,
                        content.example?.translationZH
                    ].compactMap { $0 },
                    identifier: "vocabulary-ja-zh"
                )
            }
            if chineseToJapanese {
                CardFacePreview(
                    title: "中文 → 日语",
                    front: [content.meaningZH, content.partOfSpeech].compactMap { $0 },
                    back: [
                        content.headword,
                        content.reading,
                        content.example?.japanese
                    ].compactMap { $0 },
                    identifier: "vocabulary-zh-ja"
                )
            }
            if !japaneseToChinese && !chineseToJapanese {
                Text("选择方向后显示卡片预览。")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("填写必填内容后显示卡片预览。")
                .foregroundStyle(.secondary)
        }
    }
}

private struct GrammarCardPreviews: View {
    let form: GrammarFormData
    let isEnabled: Bool

    var body: some View {
        if let content = try? form.validatedContent() {
            if isEnabled {
                CardFacePreview(
                    title: "语法形式 → 解释",
                    front: [content.grammarForm],
                    back: [
                        content.meaningZH,
                        content.connection,
                        content.usage,
                        content.example?.japanese,
                        content.example?.translationZH,
                        content.notes
                    ].compactMap { $0 },
                    identifier: "grammar-form-explanation"
                )
            } else {
                Text("选择方向后显示卡片预览。")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("填写必填内容后显示卡片预览。")
                .foregroundStyle(.secondary)
        }
    }
}

private struct CardFacePreview: View {
    let title: String
    let front: [String]
    let back: [String]
    let identifier: String

    @State private var isShowingAnswer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            previewLines(front)
            if isShowingAnswer {
                Divider()
                previewLines(back)
                    .accessibilityIdentifier("card-preview-answer-\(identifier)")
            }
            Button(isShowingAnswer ? "隐藏答案" : "显示答案") {
                isShowingAnswer.toggle()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("card-preview-flip-\(identifier)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func previewLines(_ lines: [String]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line)
                .font(index == 0 ? .title3.bold() : .body)
                .foregroundStyle(index == 0 ? .primary : .secondary)
        }
    }
}

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

                    if note.partOfSpeech != nil || note.jlpt != nil {
                        Section("分类") {
                            if let partOfSpeech = note.partOfSpeech {
                                LabeledContent("词性", value: partOfSpeech)
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
            do {
                try speechService.speak([text])
                speechErrorMessage = nil
            } catch {
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

    var note: VocabularyNote?
    var metadata: KnowledgePointMetadata?
    var isLoading = true
    var errorMessage: String?

    init(
        noteID: UUID,
        service: VocabularyService,
        knowledgeService: KnowledgePointService
    ) {
        self.noteID = noteID
        self.service = service
        self.knowledgeService = knowledgeService
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

private func vocabularyValidationMessage(for form: VocabularyFormData) -> String {
    do {
        _ = try form.validatedContent()
        return "内容可用于正式保存。"
    } catch VocabularyValidationError.headwordRequired {
        return "请填写日语词形。"
    } catch VocabularyValidationError.meaningRequired {
        return "请填写中文释义。"
    } catch VocabularyValidationError.exampleJapaneseRequired {
        return "填写例句翻译时，也需要填写日语例句。"
    } catch {
        return "内容格式不正确。"
    }
}

private func grammarValidationMessage(for form: GrammarFormData) -> String {
    do {
        _ = try form.validatedContent()
        return "内容可用于正式保存。"
    } catch GrammarValidationError.grammarFormRequired {
        return "请填写语法形式。"
    } catch GrammarValidationError.meaningRequired {
        return "请填写中文含义。"
    } catch GrammarValidationError.exampleJapaneseRequired {
        return "填写例句翻译时，也需要填写日语例句。"
    } catch {
        return "内容格式不正确。"
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
    @State private var destinationDecks: [DeckSummary] = []
    @State private var isPresentingMove = false
    @State private var isConfirmingDelete = false
    @State private var deletionImpact: KnowledgePointDeletionImpact?
    @State private var didMove = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button("移动到其他牌组") {
                isPresentingMove = true
            }
            .disabled(destinationDecks.isEmpty || isWorking)
            .accessibilityIdentifier("knowledge-move-button")

            Button("删除知识点", role: .destructive) {
                prepareDeletion()
            }
            .disabled(isWorking)
            .accessibilityIdentifier("knowledge-delete-button")
        } header: {
            Text("管理")
        } footer: {
            if destinationDecks.isEmpty {
                Text("创建另一个牌组后才能移动。删除会移除正文和卡片，但保留不含正文的评分历史。")
            } else {
                Text("移动会带上全部卡片并保留历史牌组标识。删除会移除正文和卡片，但保留不含正文的评分历史。")
            }
        }
        .task {
            await loadDestinationDecks()
        }
        .sheet(isPresented: $isPresentingMove, onDismiss: {
            if didMove {
                dismiss()
            }
        }) {
            KnowledgePointMoveSheet(
                noteID: noteID,
                destinations: destinationDecks,
                knowledgeService: knowledgeService
            ) {
                didMove = true
                await onChanged()
            }
        }
        .confirmationDialog(
            "确定删除这个知识点吗？",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
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

    private var deleteButtonTitle: String {
        "删除正文与 \(deletionImpact?.cardCount ?? 0) 张卡片"
    }

    private var deleteImpactMessage: String {
        let logs = deletionImpact?.reviewLogCount ?? 0
        return "例句、标签关联、卡片和当前任务会一并删除；\(logs) 条评分历史仅保留标识与调度记录。此操作不可撤销，可通过已有备份恢复。"
    }

    private func loadDestinationDecks() async {
        do {
            destinationDecks = try await deckService.fetchDecks().filter { $0.id != currentDeckID }
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

private struct KnowledgePointMoveSheet: View {
    let noteID: UUID
    let destinations: [DeckSummary]
    let knowledgeService: KnowledgePointService
    let onMoved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(destinations) { deck in
                Button {
                    move(to: deck.id)
                } label: {
                    HStack {
                        Text(deck.name)
                        Spacer()
                        Text("\(deck.noteCount) 个知识点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("knowledge-move-destination-\(deck.id.uuidString)")
            }
            .navigationTitle("移动知识点")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .alert(
                "无法移动知识点",
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

    private func move(to deckID: UUID) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                switch try await knowledgeService.move(noteID: noteID, to: deckID) {
                case .moved:
                    await onMoved()
                    dismiss()
                case .noteNotFound:
                    errorMessage = "这个知识点已不存在。"
                    isWorking = false
                case .destinationNotFound:
                    errorMessage = "目标牌组已不存在。"
                    isWorking = false
                case .alreadyInDestination:
                    errorMessage = "知识点已在这个牌组中。"
                    isWorking = false
                }
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
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
            do {
                try speechService.speak([text])
                speechErrorMessage = nil
            } catch {
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
