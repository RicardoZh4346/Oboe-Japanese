import OboeDomain
import OboeInfrastructure
import SwiftUI

/// v0.7.0 S13：sentence/Cloze 手动编辑器（设计 §9.2 + 分步计划 S13
/// 「原文删除仍可编辑」）。只读详情在 `SentenceNoteDetailView`；本页
/// 承载表单与保存。
///
/// 语义要点：
/// - 编辑句子后必须重选挖空位置——文本变更即 `invalidateRangeSelection`，
///   保存前未选中一律拒绝（域层 `ClozeError.invalidRange` 同判据兜底）。
/// - 挖空位置以「第 N 处出现」选择：候选由 `ClozeValidator.surfaceRanges`
///   枚举，全部为 UTF-16 边界安全点。
/// - 保存走 `SentenceService.updateSentence`：乐观版本来自详情读取的
///   `definition.contentVersion`；并发修改以 `staleContentVersion` 拒绝，
///   界面提示重新打开而不是覆盖他人改动。
/// - Card/FSRS 不在本页出现——编辑不重置调度状态。
struct SentenceNoteEditView: View {
    let noteID: UUID
    let service: SentenceService
    var onSaved: (() async -> Void)? = nil

    @State private var sentenceNote: SentenceNote?
    @State private var form = SentenceFormData()
    /// 答案编辑器原文（每行一条）；保存时拆分回 `acceptedAnswers`。
    @State private var answersText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在载入句子…")
                } else if loadFailed {
                    ContentUnavailableView(
                        "无法打开句子卡片",
                        systemImage: "exclamationmark.triangle",
                        description: Text("该笔记可能已被删除，或不是句子卡片。")
                    )
                } else {
                    editorForm
                }
            }
            .navigationTitle("编辑句子卡片")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("sentence-edit-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isSaving || !canSave)
                    .accessibilityIdentifier("sentence-edit-save")
                }
            }
        }
        .task(id: noteID) { await load() }
    }

    @ViewBuilder
    private var editorForm: some View {
        List {
            Section("原句（快照）") {
                TextEditor(text: $form.sentence)
                    .frame(minHeight: 66)
                    .onChange(of: form.sentence) { _, _ in
                        // §9.2：改句必须重选范围。
                        form.invalidateRangeSelection()
                    }
                    .accessibilityIdentifier("sentence-edit-sentence")
            }

            Section("挖空位置") {
                TextField("挖空表记（如 見た）", text: $form.targetSurface)
                    .onChange(of: form.targetSurface) { _, _ in
                        syncSelectionAfterSurfaceChange()
                    }
                    .accessibilityIdentifier("sentence-edit-surface")
                let candidates = form.candidateRanges
                if candidates.isEmpty {
                    Label(
                        form.targetSurface.isEmpty
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
                            get: { form.selectedOccurrenceOrdinal },
                            set: { ordinal in
                                if let ordinal {
                                    _ = form.selectOccurrence(ordinal)
                                } else {
                                    form.invalidateRangeSelection()
                                }
                            }
                        )
                    ) {
                        Text("未选择").tag(Int?.none)
                        ForEach(
                            Array(candidates.enumerated()),
                            id: \.offset
                        ) { ordinal, _ in
                            Text("第 \(ordinal + 1) 处").tag(Int?.some(ordinal))
                        }
                    }
                    .accessibilityIdentifier("sentence-edit-occurrence")
                }
                if let preview = maskedPreview {
                    LabeledContent("正面预览") {
                        Text(preview)
                            .oboeFont(.exampleJapanese)
                    }
                }
            }

            Section("答案") {
                TextField("读音（活用形，如 みた）", text: $form.targetReading)
                TextField("原形（如 見る）", text: $form.targetLemma)
                VStack(alignment: .leading, spacing: 4) {
                    Text("可接受答案（每行一条）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $answersText)
                        .frame(minHeight: 56)
                }
                Text("表记会自动并入答案集；lemma 不自动接受（§9.3）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("提示（可选）", text: $form.hint)
            }

            Section("中文与备注") {
                TextField("整句中文（可留空）", text: $form.meaningZH)
                TextField("备注（可留空）", text: $form.notes)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("sentence-edit-error")
                }
            }
        }
    }

    /// 可保存 = 域校验通过 + 内容与已载入态有差异。
    private var canSave: Bool {
        guard sentenceNote != nil,
              (try? form.validatedContent()) != nil else {
            return false
        }
        return true
    }

    /// 正面预览串——未选中范围时不显示（预览即考点形态，绝不展示
    /// 未遮罩的整句）。
    private var maskedPreview: String? {
        guard let start = form.utf16Start,
              let length = form.utf16Length,
              let range = try? ClozeRange(
                  utf16Start: start,
                  utf16Length: length
              )
        else { return nil }
        return ClozeValidator.maskedSentence(
            form.sentence,
            range: range,
            blank: "＿"
        )
    }

    private func load() async {
        do {
            guard let note = try await service.fetchSentence(noteID: noteID)
            else {
                loadFailed = true
                isLoading = false
                return
            }
            sentenceNote = note
            form = SentenceFormData(
                definition: note.definition,
                meaningZH: note.meaningZH,
                notes: note.notes
            )
            answersText = note.definition.acceptedAnswers
                .joined(separator: "\n")
            isLoading = false
        } catch {
            errorMessage = "载入失败：\(error.localizedDescription)"
            loadFailed = true
            isLoading = false
        }
    }

    /// surface 编辑后：若候选只剩一处自动选中；当前坐标不再出现于
    /// 候选时清空（例如把「見た」改成句中不存在的词）。
    private func syncSelectionAfterSurfaceChange() {
        let candidates = form.candidateRanges
        if candidates.count == 1 {
            _ = form.selectOccurrence(0)
        } else if form.selectedOccurrenceOrdinal == nil {
            form.invalidateRangeSelection()
        }
    }

    private func save() async {
        guard let sentenceNote else { return }
        isSaving = true
        defer { isSaving = false }
        // 表记必须入答案集（域约束）——编辑器把它并入用户输入而不是
        // 要求用户手写重复一遍。
        var answers = answersText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let surface = form.targetSurface
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !surface.isEmpty && !answers.contains(surface) {
            answers.insert(surface, at: 0)
        }
        var submitted = form
        submitted.acceptedAnswers = answers
        submitted.targetSurface = surface

        do {
            _ = try await service.updateSentence(
                noteID: sentenceNote.id,
                formData: submitted
            )
            await onSaved?()
            dismiss()
        } catch let error as ClozeError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private static func describe(_ error: ClozeError) -> String {
        switch error {
        case .invalidRange:
            return "挖空位置无效——请重新选择表记在句中的出现位置。"
        case .rangeSurfaceMismatch:
            return "所选范围与表记不一致——请重选出现位置。"
        case .emptySentence:
            return "原句不能为空。"
        case .emptyAcceptedAnswers:
            return "至少需要一个可接受答案。"
        case .acceptedAnswersMissingSurface:
            return "可接受答案必须包含挖空表记。"
        case .staleContentVersion:
            return "这张卡片刚被其他编辑改过——请关闭后重新打开再编辑。"
        case .inconsistentCardLink:
            return "卡片关联已损坏，无法安全更新——请通过备份/排查修复。"
        case .snapshotHashMismatch:
            return "快照校验失败——数据不一致，未写入。"
        case .unsupportedRangeVersion:
            return "范围编码版本不受支持，未写入。"
        }
    }
}
