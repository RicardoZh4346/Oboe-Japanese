import OboeDomain
import OboeInfrastructure
import SwiftUI
import UniformTypeIdentifiers

/// Reader 库列表（S10）：文档行（标题/格式/进度/覆盖率徽章）、
/// 导入（文件选择 + 粘贴）、删除确认、missing 徽标 + 重链入口。
///
/// 自适应：自身不感知壳层——compact 壳层下在 NavigationStack 内被
/// push；regular 壳层下作为 NavigationSplitView 的 sidebar 列表。
struct ReaderLibraryView: View {
    @State private var model: ReaderLibraryViewModel
    /// regular 壳层下点行不 push——通过该回调交给壳层做列选择；
    /// compact 壳层下传 nil，行内嵌 NavigationLink push。
    private let selectInSplit: ((UUID) -> Void)?

    @State private var showFileImporter = false
    @State private var showPasteSheet = false
    @State private var deletingDocument: ReaderDocumentMetadata?
    /// relink 文件选择器（model.relinkTarget 驱动）。
    @State private var showRelinkImporter = false

    /// 可导入类型：txt/epub/srt/vtt（epub/vtt 无系统声明则
    /// filenameExtension 兜底构造）。
    private static let importableTypes: [UTType] = [
        .plainText,
        UTType.epub,
        UTType(filenameExtension: "srt") ?? .plainText,
        UTType(filenameExtension: "vtt") ?? .plainText,
    ]

    init(
        model: ReaderLibraryViewModel,
        selectInSplit: ((UUID) -> Void)? = nil
    ) {
        _model = State(initialValue: model)
        self.selectInSplit = selectInSplit
    }

    var body: some View {
        List {
            // 导入入口一等展示：两张等宽卡片磁贴，粘贴文本与文件
            // 导入同地位，不再只收在右上角菜单里。
            Section {
                HStack(spacing: OboeTheme.Spacing.sm) {
                    importTile(
                        title: "导入文件",
                        systemImage: "doc.badge.plus",
                        detail: "TXT / EPUB / SRT / VTT",
                        identifier: "reader-import-file-entry"
                    ) { showFileImporter = true }
                    importTile(
                        title: "粘贴文本",
                        systemImage: "doc.on.clipboard",
                        detail: "直接贴一段日文",
                        identifier: "reader-paste-entry"
                    ) { showPasteSheet = true }
                }
                .padding(.vertical, 2)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: 2,
                    leading: OboeTheme.pageHorizontalPadding,
                    bottom: 2,
                    trailing: OboeTheme.pageHorizontalPadding
                ))
                .listRowBackground(Color.clear)
            }
            .disabled(model.isImporting)
            if model.isLoading {
                ProgressView("正在载入…")
            } else if model.rows.isEmpty {
                OboeEmptyState(
                    systemImage: "books.vertical",
                    title: "还没有读物",
                    message: "支持 TXT / EPUB / SRT / VTT，或直接粘贴一段文本。",
                    stateIdentifier: "reader-empty-state"
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(model.rows) { row in
                    rowView(for: row)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("阅读")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.importPickedFile(url) }
            }
        }
        // relink：model.relinkTarget 存在即呈现第二套 fileImporter。
        .fileImporter(
            isPresented: Binding(
                get: { model.relinkTarget != nil },
                set: { if !$0 { model.relinkTarget = nil } }
            ),
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.relinkPickedFile(url) }
            }
        }
        .sheet(isPresented: $showPasteSheet) {
            ReaderPasteSheet { text in
                Task { await model.importPastedText(text) }
            }
        }
        .confirmationDialog(
            "删除「\(deletingDocument?.title ?? "")」？",
            isPresented: Binding(
                get: { deletingDocument != nil },
                set: { if !$0 { deletingDocument = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除文档与本地文件", role: .destructive) {
                if let document = deletingDocument {
                    Task { await model.delete(document) }
                }
                deletingDocument = nil
            }
            Button("取消", role: .cancel) { deletingDocument = nil }
        } message: {
            Text("文档、书签、阅读位置与本地文件都会被移除，词卡不受影响。")
        }
        .alert("提示", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - 行

    /// 导入入口磁贴：图标 + 标题 + 一行格式说明，卡片底。
    private func importTile(
        title: String,
        systemImage: String,
        detail: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: OboeTheme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(height: 28)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, OboeTheme.Spacing.md)
            .background(
                OboeTheme.Colors.cardBackground,
                in: RoundedRectangle(
                    cornerRadius: OboeTheme.Radius.medium,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(OboeTheme.Colors.accent)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func rowView(for row: ReaderLibraryViewModel.Row) -> some View {
        let label = ReaderDocumentRow(row: row) {
            model.beginRelink(row.document)
        } onCoverage: {
            Task { await model.runCoverage(for: row.document.id) }
        } isAnalyzing: {
            model.analyzingDocumentIDs.contains(row.document.id)
        }
        Group {
            if let selectInSplit {
                // regular：列选择回调交壳层。
                Button { selectInSplit(row.document.id) } label: { label }
                    .buttonStyle(.plain)
            } else if row.document.availability == .missing {
                // missing 文档不进阅读页（内容不可用）——行内给重链。
                label
            } else {
                NavigationLink(value: row.document.id) { label }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deletingDocument = row.document
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            if row.document.availability == .missing {
                Button {
                    model.beginRelink(row.document)
                } label: {
                    Label("重新链接文件", systemImage: "link.badge.plus")
                }
            }
            Button(role: .destructive) {
                deletingDocument = row.document
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("reader-row-\(row.document.id.uuidString)")
    }
}

/// 文档行：标题 + 格式 + 进度 + 覆盖率徽章 + missing 徽标。
private struct ReaderDocumentRow: View {
    let row: ReaderLibraryViewModel.Row
    let onRelink: () -> Void
    let onCoverage: () -> Void
    let isAnalyzing: () -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: OboeTheme.Spacing.sm) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(OboeTheme.Colors.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.document.title)
                        .font(.headline)
                        .lineLimit(1)
                    if row.document.availability == .missing {
                        Text("文件缺失")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange, in: Capsule())
                            .accessibilityLabel("文件缺失")
                    }
                }
                HStack(spacing: OboeTheme.Spacing.xs) {
                    Text(row.document.format.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("进度 \(row.document.progressBasisPoints / 100)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    coverageBadge
                }
            }
            Spacer()
            if row.document.availability == .missing {
                Button("重新链接", action: onRelink)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "reader-relink-\(row.document.id.uuidString)"
                    )
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch row.document.format {
        case .epub: "book"
        case .srt, .vtt: "captions.bubble"
        case .txt: "doc.text"
        case .paste: "doc.on.clipboard"
        }
    }

    @ViewBuilder
    private var coverageBadge: some View {
        if let fraction = row.coverageFraction {
            Text("覆盖率 \(Int((fraction * 100).rounded()))%"
                + (row.coverageIsPartial ? "·部分" : ""))
                .font(.caption.weight(.medium))
                .foregroundStyle(OboeTheme.Colors.accent)
        } else if isAnalyzing() {
            ProgressView().controlSize(.mini)
        } else {
            Button("计算覆盖率", action: onCoverage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "reader-coverage-\(row.document.id.uuidString)"
                )
        }
    }
}

/// 粘贴导入 sheet：多行文本输入 + 导入/取消。
private struct ReaderPasteSheet: View {
    @State private var text = ""
    let onImport: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: OboeTheme.Spacing.md) {
                TextEditor(text: $text)
                    .font(.body)
                    .padding(OboeTheme.Spacing.xs)
                    .background(
                        OboeTheme.Colors.cardBackground,
                        in: RoundedRectangle(
                            cornerRadius: OboeTheme.Radius.medium,
                            style: .continuous
                        )
                    )
                    .accessibilityLabel("要导入的文本")
                    .accessibilityIdentifier("reader-paste-editor")
            }
            .padding(OboeTheme.pageHorizontalPadding)
            .navigationTitle("粘贴文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        onImport(text)
                        dismiss()
                    }
                    .disabled(
                        text.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                    )
                    .accessibilityIdentifier("reader-paste-import")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
