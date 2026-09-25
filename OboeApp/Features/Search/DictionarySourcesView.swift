import OboeDomain
import SwiftUI

/// S06 词典 Sources/Licenses 页（D03：唯一事实源为
/// `dictionary_sources` 表，经 `DictionaryQueryService.sources()`
/// 透出；元数据来自 `metadata()`）。
///
/// 进入页面时在 `.task` 中一次性加载元数据 + 来源列表；
/// 词典包缺失/损坏收敛为「来源信息不可用」重试态，不崩溃。
struct DictionarySourcesView: View {
    let queryService: DictionaryQueryService

    @State private var metadata: DictionaryMetadata?
    @State private var sources: [DictionarySourceInfo] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在读取来源信息…")
            } else if loadFailed {
                ContentUnavailableView {
                    Label("来源信息不可用", systemImage: "book.closed")
                } description: {
                    Text("内置词典文件缺失或损坏，无法读取来源与许可信息。")
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("dictionary-sources-unavailable")
            } else {
                List {
                    metadataSection
                    sourcesSection
                }
            }
        }
        .navigationTitle("词典来源与许可")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .task { await load() }
    }

    // MARK: - 词典元数据

    @ViewBuilder
    private var metadataSection: some View {
        if let metadata {
            Section("词典数据") {
                LabeledContent("数据集版本", value: metadata.datasetVersion)
                if !metadata.dictionaryVersion.isEmpty,
                   metadata.dictionaryVersion != metadata.datasetVersion {
                    LabeledContent("词典版本", value: metadata.dictionaryVersion)
                }
                LabeledContent("词条数", value: "\(metadata.entryCount)")
                if let rate = metadata.zhAlignmentRate {
                    LabeledContent(
                        "中文对齐率",
                        value: rate.formatted(.percent.precision(.fractionLength(1)))
                    )
                }
                if let builtAt = metadata.builtAt, !builtAt.isEmpty {
                    LabeledContent("构建时间", value: builtAt)
                }
                if let normalizer = metadata.normalizer, !normalizer.isEmpty {
                    LabeledContent("规范化器", value: normalizer)
                }
            }
        }
    }

    // MARK: - 来源列表

    private var sourcesSection: some View {
        Section("来源与许可") {
            if sources.isEmpty {
                Text("未记录来源信息。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sources, id: \.id) { source in
                    sourceRow(source)
                }
            }
        }
    }

    private func sourceRow(_ source: DictionarySourceInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(source.name)
                    .font(.headline)
                Spacer()
                if !source.version.isEmpty {
                    Text(source.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if !source.license.isEmpty {
                    Text(source.license)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if let licenseURL = URL(string: source.licenseURL),
                   !source.licenseURL.isEmpty {
                    Link("许可原文", destination: licenseURL)
                        .font(.caption)
                }
                if let url = URL(string: source.url), !source.url.isEmpty {
                    Link("项目主页", destination: url)
                        .font(.caption)
                }
            }

            if !source.attribution.isEmpty {
                Text(source.attribution)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !source.modifications.isEmpty {
                Text("修改：\(source.modifications)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !source.consumedTables.isEmpty {
                Text("数据表：\(source.consumedTables.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            LabeledContent("获取时间", value: source.retrievedAt)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !source.sha256.isEmpty {
                Text("SHA-256 \(source.sha256.prefix(16))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("dictionary-source-row")
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        loadFailed = false
        do {
            async let fetchedMetadata = queryService.metadata()
            async let fetchedSources = queryService.sources()
            metadata = try await fetchedMetadata
            sources = try await fetchedSources
            isLoading = false
        } catch {
            isLoading = false
            loadFailed = true
        }
    }
}
