import OboeDomain
import SwiftUI

struct SentenceAnalysisSections: View {
    @Bindable var model: AddContentViewModel
    var isInputFocused: FocusState<Bool>.Binding
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let deckService: DeckManagementService
    let contentCardService: ContentCardService
    let historyService: StudyHistoryService
    let speechService: any SpeechService

    @State private var selectedItemID: UUID?

    var body: some View {
        Section {
            TextEditor(text: $model.sentenceAnalysisInput)
                .frame(minHeight: 110)
                .textInputAutocapitalization(.never)
                .focused(isInputFocused)
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
                        isInputFocused.wrappedValue = false
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
                $0.id == (selectedItemID ?? result.items.first?.id)
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
                            selectedItemID = item.id
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
                                    if item.id == (selectedItemID ?? result.items.first?.id) {
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
                        DeckPickerOptions(decks: model.decks)
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
                            Text("将创建全部三个方向的卡片")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
                                        await model.checkSentenceCardDuplicate(
                                            itemID: draft.id,
                                            immediately: true
                                        )
                                    }
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
                    selectedItemID = nil
                    Task { await model.clearCurrentDraft() }
                }
                .disabled(model.isSaving)
                .accessibilityIdentifier(model.kind.clearDraftIdentifier)
            }
        }
    }
}
