import OboeDomain
import OboeInfrastructure
import SwiftUI

/// v0.7.0 S13：Reader → 单 blank Cloze 创建表单（sheet）。
/// 流程：句快照（可改，改动即重选范围）→「第 N 处」blank 选择 →
/// 遮罩预览 → accepted answers/hint/原形/读音 → 牌组 → 保存
/// （`ReaderMiningService.mineCloze` 原子提交）。
///
/// 正面预览只显示遮罩句——目标/完整句/来源不进正面（§9.2）；
/// 原文删除后本卡仍可编辑复习（来源是弱引用 + 独立快照）。
struct ReaderClozeCreateView: View {
    @State private var model: ReaderClozeCreateViewModel
    @Environment(\.dismiss) private var dismiss

    init(model: ReaderClozeCreateViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            editorForm
                .navigationTitle("挖句成卡")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .accessibilityIdentifier(
                                "cloze-create-cancel"
                            )
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            model.save()
                        } label: {
                            if model.isSaving {
                                ProgressView()
                            } else {
                                Text("保存")
                            }
                        }
                        .disabled(!model.canSave)
                        .accessibilityIdentifier("cloze-create-save")
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { model.load() }
        .onChange(of: model.committedNoteID != nil) { _, committed in
            if committed { dismiss() }
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

    @ViewBuilder
    private var editorForm: some View {
        List {
            sentenceSection
            blankSection
            answerSection
            noteSection
            deckSection
            sourceSection
        }
    }

    // MARK: - 区块

    private var sentenceSection: some View {
        Section("原句（快照）") {
            TextEditor(text: .init(
                get: { model.form.sentence },
                set: { model.form.sentence = $0 }
            ))
            .frame(minHeight: 66)
            .onChange(of: model.form.sentence) { _, _ in
                // §9.2：改句必须重选范围。
                model.form.invalidateRangeSelection()
            }
            .accessibilityLabel("原句快照")
            .accessibilityIdentifier("cloze-create-sentence")
        }
    }

    private var blankSection: some View {
        Section("挖空位置") {
            TextField(
                "挖空表记（如 見た）",
                text: .init(
                    get: { model.form.targetSurface },
                    set: { model.form.targetSurface = $0 }
                )
            )
            .onChange(of: model.form.targetSurface) { _, _ in
                syncSelectionAfterSurfaceChange()
            }
            .accessibilityIdentifier("cloze-create-surface")
            let candidates = model.form.candidateRanges
            if candidates.isEmpty {
                Label(
                    model.form.targetSurface.isEmpty
                        ? "填写挖空表记后自动列出出现位置"
                        : "句中没有这个表记",
                    systemImage: "exclamationmark.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Picker(
                    "出现位置",
                    selection: Binding(
                        get: { model.form.selectedOccurrenceOrdinal },
                        set: { ordinal in
                            if let ordinal {
                                _ = model.form.selectOccurrence(ordinal)
                            } else {
                                model.form.invalidateRangeSelection()
                            }
                        }
                    )
                ) {
                    Text("未选择").tag(Int?.none)
                    ForEach(
                        Array(candidates.enumerated()),
                        id: \.offset
                    ) { ordinal, _ in
                        Text("第 \(ordinal + 1) 处")
                            .tag(Int?.some(ordinal))
                    }
                }
                .accessibilityIdentifier("cloze-create-occurrence")
            }
            if let preview = model.maskedPreview {
                LabeledContent("正面预览") {
                    Text(preview)
                        .oboeFont(.exampleJapanese)
                }
            }
        }
    }

    private var answerSection: some View {
        Section("答案") {
            TextField(
                "读音（活用形，如 みた）",
                text: .init(
                    get: { model.form.targetReading },
                    set: { model.form.targetReading = $0 }
                )
            )
            TextField(
                "原形（如 見る）",
                text: .init(
                    get: { model.form.targetLemma },
                    set: { model.form.targetLemma = $0 }
                )
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("可接受答案（每行一条）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: .init(
                    get: { model.answersText },
                    set: { model.answersText = $0 }
                ))
                .frame(minHeight: 56)
                .accessibilityLabel("可接受答案，每行一条")
            }
            Text("表记会自动并入答案集；lemma 不自动接受（§9.3）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(
                "提示（可选）",
                text: .init(
                    get: { model.form.hint },
                    set: { model.form.hint = $0 }
                )
            )
        }
    }

    private var noteSection: some View {
        Section("中文与备注") {
            TextField(
                "整句中文（可留空）",
                text: .init(
                    get: { model.form.meaningZH },
                    set: { model.form.meaningZH = $0 }
                )
            )
            TextField(
                "备注（可留空）",
                text: .init(
                    get: { model.form.notes },
                    set: { model.form.notes = $0 }
                )
            )
        }
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
                .accessibilityIdentifier("cloze-create-deck-picker")
                if model.decks.count > 1 {
                    ForEach(model.decks) { deck in
                        if deck.id != model.targetDeckID {
                            Toggle(isOn: .init(
                                get: {
                                    model.additionalDeckIDs
                                        .contains(deck.id)
                                },
                                set: { on in
                                    if on {
                                        model.additionalDeckIDs
                                            .insert(deck.id)
                                    } else {
                                        model.additionalDeckIDs
                                            .remove(deck.id)
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

    private var sourceSection: some View {
        Section("来源") {
            LabeledContent("文档") {
                Text(model.draft.context.sourceTitle ?? "（未命名）")
                    .foregroundStyle(.secondary)
            }
            let location = model.draft.context.location
            LabeledContent("位置") {
                Text(
                    "第 \(location.chapterOrdinal + 1) 节"
                        + " · 块 \(location.blockOrdinal + 1)"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// surface 编辑后：若候选只剩一处自动选中；当前坐标不再出现于
    /// 候选时清空（例如把「見た」改成句中不存在的词）。
    private func syncSelectionAfterSurfaceChange() {
        let candidates = model.form.candidateRanges
        if candidates.count == 1 {
            _ = model.form.selectOccurrence(0)
        } else if model.form.selectedOccurrenceOrdinal == nil {
            model.form.invalidateRangeSelection()
        }
    }
}
