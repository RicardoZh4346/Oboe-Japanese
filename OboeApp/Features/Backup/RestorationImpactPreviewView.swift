import OboeDomain
import OboeInfrastructure
import SwiftUI

/// 恢复影响预览（S11 提升为共享视图——Settings 入口与 AirDrop/
/// 外部 URL 入口走同一确认页；确认动作由调用方注入）。
struct RestorationImpactPreviewView: View {
    let preparation: PreparedRestoration
    let apply: @MainActor @Sendable () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("备份信息") {
                    LabeledContent("文件", value: preparation.sourceFilename)
                    LabeledContent("导出时间") {
                        Text(preparation.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("应用版本", value: preparation.sourceAppVersion)
                    LabeledContent(
                        "格式版本",
                        value: preparation.attachmentDescriptors.isEmpty
                            ? "v\(preparation.sourceFormatVersion) → v\(preparation.preparedFormatVersion)"
                            : "v\(preparation.sourceFormatVersion)（含附件包）"
                    )
                }

                Section("完整替换影响") {
                    impactRow("牌组", current: preparation.current.deckCount, backup: preparation.backup.deckCount)
                    impactRow("知识点", current: preparation.current.noteCount, backup: preparation.backup.noteCount)
                    impactRow("卡片", current: preparation.current.cardCount, backup: preparation.backup.cardCount)
                    impactRow("评分历史", current: preparation.current.reviewCount, backup: preparation.backup.reviewCount)
                    impactRow("草稿", current: preparation.current.draftCount, backup: preparation.backup.draftCount)
                    impactRow(
                        "收集箱",
                        current: preparation.current.inboxItemCount,
                        backup: preparation.backup.inboxItemCount
                    )
                    impactRow(
                        "处理中",
                        current: preparation.current.processingInboxItemCount,
                        backup: preparation.backup.processingInboxItemCount
                    )
                }

                if !preparation.attachmentDescriptors.isEmpty {
                    Section("图片附件") {
                        LabeledContent("附件数量", value: "\(preparation.attachmentDescriptors.count)")
                        LabeledContent("附件大小") {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(
                                        preparation.attachmentDescriptors.reduce(0) {
                                            $0 + $1.byteCount
                                        }
                                    ),
                                    countStyle: .file
                                )
                            )
                        }
                        .accessibilityIdentifier("portable-backup-preview-attachment-size")
                        Text("附件已通过逐文件 SHA-256 校验，恢复时随资料库一并安装。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !preparation.restoresInboxData {
                    Section {
                        Label(
                            "此备份早于收集箱格式，恢复后收集箱将为空。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("portable-backup-preview-inbox-empty-warning")
                    }
                }

                Section {
                    Text(
                        preparation.attachmentDescriptors.isEmpty
                            ? "备份不包含 API 密钥、AI 连接配置、共享中转文件和本地图片附件；条目中的图片引用若无法解析将置空并保留正文。"
                            : "备份不包含 API 密钥、AI 连接配置和共享中转文件；图片附件已随备份打包并逐文件校验。"
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-preview-excluded-scopes")
                }

                Section {
                    Label("文件已在临时区通过格式、校验值、数量、外键和调度状态检查。", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("portable-backup-preview-valid")
                    Text("当前资料库尚未改变。选择完整替换后仍需再次确认。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-preview-requires-confirmation")
                }
            }
            .navigationTitle("恢复影响预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完整替换恢复", role: .destructive) { isConfirming = true }
                        .disabled(isApplying)
                        .accessibilityIdentifier("portable-backup-apply-button")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isApplying)
                }
            }
            .interactiveDismissDisabled(isApplying)
            .overlay {
                if isApplying {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                        ProgressView("正在安全替换资料库…")
                    }
                }
            }
            .alert("确认完整替换？", isPresented: $isConfirming) {
                Button("替换当前资料库", role: .destructive) {
                    isApplying = true
                    Task {
                        do {
                            try await apply()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isApplying = false
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前资料库会先创建回滚快照；替换完成后将重建搜索数据并校正今日额度。")
            }
            .alert(
                "恢复失败",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { shown in if !shown { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func impactRow(_ title: String, current: Int, backup: Int) -> some View {
        LabeledContent(title) {
            Text("当前 \(current) → 备份 \(backup)")
                .monospacedDigit()
        }
    }
}
