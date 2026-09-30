import OboeDomain
import OboeInfrastructure
import SwiftUI

/// v0.7.0 S12 落地、S13 补完手动编辑：sentence Note 详情页。
/// 展示遮罩预览 + 答案字段（详情页非复习正面，原句可展示）并保留
/// 删除入口；`clozeRepository` 同时具备 `ClozeEditingRepository`
/// 能力（即 GRDB 实现）时出现「编辑」入口，打开手动编辑器——cloze
/// 不进 AI 修卡（§9.1）。
///
/// `clozeRepository` 为 nil（窄注入路径）或非编辑实现时降级为只读：
/// 不渲染遮罩预览、不显示编辑按钮，也绝不会把遮罩句伪装成其它内容。
struct SentenceNoteDetailView: View {
    let noteID: UUID
    /// 列表侧已携带的 summary 字段（详情页非复习正面，原句可展示）。
    var headword: String? = nil
    var meaningZH: String? = nil
    var clozeRepository: (any ClozeRepository)? = nil
    var knowledgeService: KnowledgePointService? = nil
    var onUpdated: (() async -> Void)? = nil

    /// 编辑能力需要 `ClozeEditingRepository`——`fetchSentence` 取聚合、
    /// `updateSentence` 落库；只读实现下编辑入口隐藏。
    private var editingRepository: (any ClozeEditingRepository)? {
        clozeRepository as? any ClozeEditingRepository
    }

    @State private var sentenceNote: SentenceNote?
    @State private var definition: ClozeDefinition?
    @State private var isEditing = false
    @State private var isDeleting = false
    @State private var isDeleteConfirmPresented = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var displayedDefinition: ClozeDefinition? {
        sentenceNote?.definition ?? definition
    }

    private var displayedMeaningZH: String? {
        sentenceNote?.meaningZH ?? meaningZH
    }

    var body: some View {
        List {
            Section("原句") {
                Text(
                    displayedDefinition?.sentenceSnapshot
                        ?? headword ?? "…"
                )
                .oboeFont(.exampleJapanese)
                .textSelection(.enabled)
            }
            if let definition = displayedDefinition {
                Section("挖空预览") {
                    Text(
                        ClozeValidator.maskedSentence(
                            definition.sentenceSnapshot,
                            range: definition.range,
                            blank: String(
                                repeating: "＿",
                                count: max(definition.targetSurface.count, 1)
                            )
                        )
                    )
                    .oboeFont(.exampleJapanese)
                    .textSelection(.enabled)
                }
                Section("答案") {
                    LabeledContent("表记", value: definition.targetSurface)
                    if let reading = definition.targetReading {
                        LabeledContent("读音", value: reading)
                    }
                    if let lemma = definition.targetLemma {
                        LabeledContent("原形", value: lemma)
                    }
                    let alternates = definition.acceptedAnswers
                        .filter { $0 != definition.targetSurface }
                    if !alternates.isEmpty {
                        LabeledContent(
                            "其他可接受答案",
                            value: alternates.joined(separator: " ・ ")
                        )
                    }
                    if let hint = definition.hint {
                        LabeledContent("提示", value: hint)
                    }
                }
            }
            if let meaningZH = displayedMeaningZH, !meaningZH.isEmpty {
                Section("中文") {
                    Text(meaningZH)
                        .textSelection(.enabled)
                }
            }
            if let notes = sentenceNote?.notes, !notes.isEmpty {
                Section("备注") {
                    Text(notes)
                        .textSelection(.enabled)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            if let knowledgeService {
                Section {
                    Button(role: .destructive) {
                        isDeleteConfirmPresented = true
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("删除句子卡片")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("sentence-note-delete")
                    .alert(
                        "删除这张句子卡片？",
                        isPresented: $isDeleteConfirmPresented
                    ) {
                        Button("删除", role: .destructive) {
                            Task { await deleteNote(using: knowledgeService) }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("将同时删除挖空定义与复习记录关联，无法撤销。")
                    }
                }
            }
        }
        .navigationTitle("句子卡片")
        .toolbar {
            if editingRepository != nil, sentenceNote != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { isEditing = true }
                        .accessibilityIdentifier("sentence-note-edit")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let editingRepository {
                SentenceNoteEditView(
                    noteID: noteID,
                    service: SentenceService(repository: editingRepository)
                ) {
                    await reload()
                    await onUpdated?()
                }
            }
        }
        .task(id: noteID) { await reload() }
    }

    /// 编辑能力路径取聚合（definition + note 字段）；窄路径只取
    /// definition——两个分支都不会伪装成其它内容类型。
    private func reload() async {
        guard let clozeRepository else { return }
        do {
            if let editingRepository {
                sentenceNote = try await editingRepository
                    .fetchSentence(noteID: noteID)
                definition = nil
            } else {
                definition = try await clozeRepository
                    .fetchDefinition(noteID: noteID)
                sentenceNote = nil
            }
        } catch {
            errorMessage = "载入失败：\(error.localizedDescription)"
        }
    }

    /// 整 Note 删除：cloze definition 与卡片随 notes FK CASCADE 消失——
    /// 这是 cloze 卡唯一合法的删除路径（单卡 deleteCard 已被仓储拒绝）。
    private func deleteNote(using service: KnowledgePointService) async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            _ = try await service.delete(noteID: noteID)
            await onUpdated?()
            dismiss()
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}
