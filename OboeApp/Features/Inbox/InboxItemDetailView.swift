import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit

struct InboxItemDetailView: View {
    private let service: InboxService
    private let processingServices: InboxProcessingServices?
    private let inboxImageStore: InboxImageStore?
    private let onChanged: () -> Void

    @State private var item: InboxItem
    @State private var imagePreviewData: Data?
    @State private var imageLoadFailed = false
    @State private var isEditorPresented = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(
        item: InboxItem,
        service: InboxService,
        processingServices: InboxProcessingServices? = nil,
        inboxImageStore: InboxImageStore? = nil,
        onChanged: @escaping () -> Void
    ) {
        self.service = service
        self.processingServices = processingServices
        self.inboxImageStore = inboxImageStore
        self.onChanged = onChanged
        _item = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.lg) {
                OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
                    Text(item.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("inbox-detail-text")
                }

                attachmentSection

                metadata

                processingSection

                actionsSection
            }
            .padding(OboeTheme.pageHorizontalPadding)
        }
        .background(OboeTheme.Colors.pageBackground)
        .navigationTitle("收集条目")
        .secondaryPage()
        .sheet(isPresented: $isEditorPresented) {
            NavigationStack {
                InboxItemEditView(item: item, service: service) { updated in
                    item = updated
                    onChanged()
                }
            }
        }
        .confirmationDialog(
            "删除这条内容？",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task { await deleteItem() }
            }
            .accessibilityIdentifier("inbox-detail-delete-confirm-button")
            Button("取消", role: .cancel) {}
        } message: {
            Text("已生成的学习内容仍会保留。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { shown in
                    if !shown {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .task {
            await loadImagePreview()
        }
    }

    /// Optional local image preview. Missing or unreadable attachments
    /// degrade to a caption — the item's text and actions stay usable, per
    /// the "缺图仍能编辑正文" contract.
    @ViewBuilder
    private var attachmentSection: some View {
        if item.imageReference != nil {
            OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
                VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                    Text("图片附件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let imagePreviewData,
                       let image = UIImage(data: imagePreviewData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: OboeTheme.Radius.medium
                                )
                            )
                            .accessibilityIdentifier("inbox-detail-image")
                    } else if imageLoadFailed {
                        Label("图片附件不可用", systemImage: "photo.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("inbox-detail-image-missing")
                    } else {
                        ProgressView()
                            .accessibilityIdentifier("inbox-detail-image-loading")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func loadImagePreview() async {
        guard let reference = item.imageReference, let inboxImageStore else {
            return
        }
        do {
            imagePreviewData = try inboxImageStore.loadPreviewData(for: reference)
        } catch {
            imageLoadFailed = true
        }
    }

    private var metadata: some View {
        OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                detailRow("状态", value: item.status.title, identifier: "inbox-detail-status")
                detailRow("来源", value: item.sourceLabel, identifier: "inbox-detail-source")
                if let sourceURL = item.sourceURL {
                    detailRow("链接", value: sourceURL, identifier: "inbox-detail-source-url")
                }
                detailRow(
                    "收集时间",
                    value: item.createdAt.formatted(date: .abbreviated, time: .shortened),
                    identifier: "inbox-detail-created-at"
                )
                detailRow(
                    "最近修改",
                    value: item.updatedAt.formatted(date: .abbreviated, time: .shortened),
                    identifier: "inbox-detail-updated-at"
                )
                if let processedAt = item.processedAt {
                    detailRow(
                        "处理完成",
                        value: processedAt.formatted(date: .abbreviated, time: .shortened),
                        identifier: "inbox-detail-processed-at"
                    )
                }
            }
        }
    }

    private func detailRow(_ title: String, value: String, identifier: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: OboeTheme.Spacing.md)
            Text(value)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(identifier)
        }
        .font(.subheadline)
    }

    private var canProcess: Bool {
        processingServices != nil
            && item.status != .archived
            && item.status != .processed
    }

    private var processingSection: some View {
        OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
            VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
                Text("处理")
                    .font(.headline)
                if item.status == .processing {
                    NavigationLink {
                        processingDestination(preferredMode: nil)
                    } label: {
                        Label("继续处理", systemImage: "arrow.right.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.oboePrimary)
                    .disabled(!canProcess)
                    .accessibilityIdentifier("inbox-detail-continue-button")
                } else {
                    NavigationLink {
                        processingDestination(
                            preferredMode: .suggested(forText: item.text)
                        )
                    } label: {
                        Label("AI 分析并制卡", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.oboePrimary)
                    .disabled(!canProcess)
                    .accessibilityIdentifier("inbox-detail-analyze-button")

                    NavigationLink {
                        processingDestination(preferredMode: .manualEdit)
                    } label: {
                        Label("直接加入学习", systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canProcess)
                    .accessibilityIdentifier("inbox-detail-manual-add-button")
                }
                Text(
                    canProcess
                        ? "处理进度会自动续编；中途退出后可从收集箱继续。"
                        : "已归档或已处理的条目不能再次处理。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("inbox-detail-processing-section")
    }

    private func processingDestination(
        preferredMode: CaptureProcessingMode?
    ) -> some View {
        InboxProcessingView(
            itemID: item.id,
            preferredMode: preferredMode,
            inboxService: service,
            services: processingServices!
        )
    }

    private var actionsSection: some View {
        OboeCardSurface(padding: OboeTheme.Spacing.cardPaddingCompact) {
            VStack(spacing: OboeTheme.Spacing.sm) {
                if item.status != .archived {
                    Button {
                        isEditorPresented = true
                    } label: {
                        Label("编辑文本", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inbox-detail-edit-button")
                }

                Button {
                    Task { await toggleArchive() }
                } label: {
                    Label(
                        item.status == .archived ? "取消归档" : "归档",
                        systemImage: item.status == .archived
                            ? "tray.and.arrow.up" : "archivebox"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inbox-detail-archive-button")

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inbox-detail-delete-button")
            }
        }
    }

    private func toggleArchive() async {
        do {
            if item.status == .archived {
                item = try await service.unarchive(id: item.id)
            } else {
                try await service.archive(ids: [item.id])
                if let fresh = try await service.fetchItem(id: item.id) {
                    item = fresh
                }
            }
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteItem() async {
        do {
            try await service.delete(id: item.id)
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct InboxItemEditView: View {
    private let service: InboxService
    private let onSaved: (InboxItem) -> Void

    @State private var item: InboxItem
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(item: InboxItem, service: InboxService, onSaved: @escaping (InboxItem) -> Void) {
        self.service = service
        self.onSaved = onSaved
        _item = State(initialValue: item)
        _text = State(initialValue: item.text)
    }

    private var isSaveDisabled: Bool {
        isSaving
            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || text.count > InboxText.maximumCharacterCount
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("inbox-edit-text-editor")
                HStack {
                    Spacer()
                    Text("\(text.count)/\(InboxText.maximumCharacterCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            text.count > InboxText.maximumCharacterCount
                                ? .red : .secondary
                        )
                        .accessibilityIdentifier("inbox-edit-count")
                }
            } header: {
                Text("内容")
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("保存")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSaveDisabled)
                .accessibilityIdentifier("inbox-edit-save-button")
            }
        }
        .navigationTitle("编辑文本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
                    .accessibilityIdentifier("inbox-edit-cancel-button")
            }
        }
        .alert(
            "无法保存",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { shown in
                    if !shown {
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

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await service.updateText(
                id: item.id,
                expectedRevision: item.contentRevision,
                text: text
            )
            onSaved(updated)
            dismiss()
        } catch InboxError.revisionConflict {
            if let fresh = try? await service.fetchItem(id: item.id) {
                item = fresh
                text = fresh.text
                errorMessage = "内容已在别处更新为最新版本，请核对后重新保存。"
            } else {
                errorMessage = "这条内容已不存在。"
            }
        } catch InboxError.itemArchived {
            errorMessage = "已归档的条目不能编辑。"
        } catch InboxError.itemNotFound {
            errorMessage = "这条内容已不存在。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
