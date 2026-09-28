import OboeDomain
import OboeInfrastructure
import SwiftUI

/// v0.7.0 S18：词汇 CSV/TSV 导出页（§10.4）。
/// 选项：牌组范围、卡类型白名单（=排除仅有其他方向卡的词）、
/// 多例句策略、转义模式（安全 RFC4180 / 原样）、分隔符、表头。
/// 导出完交系统 Share Sheet（沿用 S11 ShareSheet）。
struct VocabularyExportView: View {
    @State private var model: VocabularyExportViewModel
    @State private var shareURL: URL?

    init(model: VocabularyExportViewModel) {
        _model = State(initialValue: model)
    }

    private static let vocabularyTemplates: [CardTemplateKind] =
        CardTemplateKind.allCases.filter {
            $0 != .sentenceCloze && $0 != .grammarFormToExplanation
        }

    var body: some View {
        NavigationStack {
            Form {
                scopeSection
                templateSection
                exampleSection
                escapeSection
                exportButtonSection
                summarySection
                errorSection
            }
            .navigationTitle("导出词汇 CSV / TSV")
            .task { await model.loadDecks() }
            .sheet(
                isPresented: Binding(
                    get: { shareURL != nil },
                    set: { if !$0 { shareURL = nil } }
                )
            ) {
                if let url = shareURL {
                    ShareSheet(activityItems: [url]) { _ in shareURL = nil }
                }
            }
            .onChange(of: model.exportedFileURL) { _, url in
                shareURL = url
            }
        }
    }

    // MARK: - 分区视图（拆分避免 type-check 超时）

    private var scopeSection: some View {
        Section("范围") {
            Picker("牌组", selection: $model.deckID) {
                Text("全部词汇").tag(UUID?.none)
                ForEach(model.decks) { deck in
                    Text(deck.name).tag(UUID?.some(deck.id))
                }
            }
            Picker("分隔符", selection: $model.delimiterIsTSV) {
                Text("逗号（CSV）").tag(false)
                Text("制表符（TSV）").tag(true)
            }
            Toggle("写中文表头", isOn: $model.includeHeader)
        }
    }

    private var templateSection: some View {
        Section("卡片类型（至少有一张所选方向的词才导出）") {
            ForEach(Self.vocabularyTemplates, id: \.rawValue) { kind in
                Toggle(
                    ImportWizardView.templateTitle(kind),
                    isOn: Binding(
                        get: { model.includedTemplates.contains(kind) },
                        set: { on in
                            if on {
                                model.includedTemplates.insert(kind)
                            } else {
                                model.includedTemplates.remove(kind)
                            }
                        }
                    )
                )
            }
        }
    }

    private var exampleSection: some View {
        Section("多例句") {
            Picker("例句策略", selection: $model.multiExampleRule) {
                Text("仅主例句（提示丢弃数）")
                    .tag(CSVExportOptions.MultiExampleRule.primaryOnly)
                Text("全部合并进字段")
                    .tag(CSVExportOptions.MultiExampleRule.mergeAll)
            }
        }
    }

    private var escapeSection: some View {
        Section(
            content: {
                Picker("转义", selection: $model.escapeMode) {
                    Text("安全（RFC4180，可回导）")
                        .tag(CSVExportOptions.EscapeMode.safeRFC4180)
                    Text("原样（不转义，仅查看）")
                        .tag(CSVExportOptions.EscapeMode.verbatim)
                }
            },
            header: { Text("兼容模式") },
            footer: {
                Text("安全模式使用 UTF-8 BOM + CRLF + RFC4180 引号转义，"
                    + "可被导入向导无损回读。原样模式按库内原文直出，"
                    + "含逗号/换行的字段将无法回导。")
            }
        )
    }

    private var exportButtonSection: some View {
        Section {
            Button {
                Task { await model.runExport() }
            } label: {
                if model.isExporting {
                    HStack {
                        ProgressView()
                        Text("正在导出…")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("导出").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isExporting || model.includedTemplates.isEmpty)
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let summary = model.lastSummary {
            Section("导出结果") {
                LabeledContent("导出行数", value: "\(summary.exportedRows)")
                if summary.skippedByCardType > 0 {
                    LabeledContent(
                        "按卡类型跳过", value: "\(summary.skippedByCardType)"
                    )
                }
                if summary.droppedExamples > 0 {
                    LabeledContent(
                        "丢弃的附加例句", value: "\(summary.droppedExamples)"
                    )
                }
                if summary.lossyRows > 0 {
                    LabeledContent(
                        "原样模式有损行", value: "\(summary.lossyRows)"
                    )
                }
                LabeledContent(
                    "文件大小",
                    value: ByteCountFormatter.string(
                        fromByteCount: summary.byteCount,
                        countStyle: .file
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = model.errorMessage {
            Section {
                Text(message).foregroundStyle(.red)
            }
        }
    }
}

@MainActor
@Observable
final class VocabularyExportViewModel {
    private let database: OboeDatabase
    private let deckProvider: @Sendable () async throws -> [DeckSummary]
    private let exportDirectory: URL
    private let fileManager: FileManager

    var deckID: UUID?
    var decks: [DeckSummary] = []
    var delimiterIsTSV = false
    var includeHeader = true
    var includedTemplates: Set<CardTemplateKind> = [
        .vocabularyJapaneseToChinese,
        .vocabularyChineseToJapanese,
        .vocabularyListening
    ]
    var multiExampleRule: CSVExportOptions.MultiExampleRule = .primaryOnly
    var escapeMode: CSVExportOptions.EscapeMode = .safeRFC4180

    private(set) var isExporting = false
    private(set) var lastSummary: CSVExportSummary?
    private(set) var exportedFileURL: URL?
    var errorMessage: String?

    init(
        database: OboeDatabase,
        deckProvider: @escaping @Sendable () async throws -> [DeckSummary],
        exportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.deckProvider = deckProvider
        self.fileManager = fileManager
        self.exportDirectory = exportDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("OboeVocabularyExport", isDirectory: true)
    }

    func loadDecks() async {
        decks = (try? await deckProvider()) ?? []
    }

    func runExport() async {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            try fileManager.createDirectory(
                at: exportDirectory, withIntermediateDirectories: true
            )
            let ext = delimiterIsTSV ? "tsv" : "csv"
            let url = exportDirectory.appendingPathComponent(
                "vocabulary-\(ISO8601DateFormatter.compact()).\(ext)"
            )
            let options = CSVExportOptions(
                deckID: deckID,
                includedCardTemplates: includedTemplates.isEmpty
                    ? nil : includedTemplates,
                multiExampleRule: multiExampleRule,
                escapeMode: escapeMode,
                delimiter: delimiterIsTSV ? "\t" : ",",
                includeHeader: includeHeader
            )
            let summary = try await CSVExporter(database: database)
                .export(to: url, options: options)
            lastSummary = summary
            exportedFileURL = url
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

private extension ISO8601DateFormatter {
    static func compact() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay,
                                   .withTime, .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "")
    }
}
