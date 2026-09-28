import OboeDomain
import OboeInfrastructure
import SwiftUI
import UniformTypeIdentifiers

/// v0.7.0 S18：CSV/TSV 导入向导视图（§10 wizard）。
/// 五步：选文件 →（按需）编码/分隔符确认 → 字段映射 → 预检结果
/// （分类计数 + 错误行报告翻页）→ 执行（取消）→ 摘要。
/// 所有长任务都在 `ImportWizardViewModel`（@MainActor）。
struct ImportWizardView: View {
    @State private var model: ImportWizardViewModel
    @State private var isPickingFile = false
    @State private var showErrorDetail = false

    init(model: ImportWizardViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.step {
                case .idle, .intaking:
                    intakeSection
                case let .chooseEncoding(candidates):
                    encodingChoiceSection(candidates)
                case let .chooseDelimiter(candidates):
                    delimiterChoiceSection(candidates)
                case .mapping:
                    mappingSection
                case .prechecking:
                    ProgressView("正在解析并预检整个文件…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .reviewing:
                    reviewSection
                case .executing:
                    executingSection
                case .summary:
                    summarySection
                case let .failed(reason):
                    failedSection(reason)
                }
            }
            .navigationTitle("导入 CSV / TSV")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.step != .executing {
                        Button("重新开始") { model.reset() }
                            .disabled(model.step == .idle)
                    }
                }
            }
            .fileImporter(
                isPresented: $isPickingFile,
                allowedContentTypes: [
                    .commaSeparatedText, .tabSeparatedText,
                    .plainText, .data
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    if let url = urls.first {
                        Task { await model.pickFile(url) }
                    }
                case let .failure(error):
                    if !(error is CancellationError) {
                        model.reset()
                    }
                }
            }
        }
    }

    // MARK: - 选文件

    private var intakeSection: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)  // 装饰性图标，语义由下方标题承担
            Text("选择要导入的 CSV / TSV 文件")
                .font(.title2)
            Text("支持 UTF-8 / UTF-16，最大 50 MiB / 100,000 行。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isPickingFile = true
            } label: {
                Label("选择文件", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if model.step == .intaking {
                ProgressView("正在读取文件…")
            }
            if let name = model.sourceFileName {
                LabeledContent("文件", value: name)
                if let bytes = model.fileByteCount {
                    LabeledContent(
                        "大小",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(bytes),
                            countStyle: .file
                        )
                    )
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - 编码/分隔符确认

    private func encodingChoiceSection(
        _ candidates: [ImportTextEncoding]
    ) -> some View {
        List {
            Section {
                Text("无法确定文件编码。请选择文本编码：")
                    .foregroundStyle(.secondary)
            }
            Section("候选编码") {
                ForEach(candidates, id: \.rawValue) { encoding in
                    Button {
                        Task { await model.chooseEncoding(encoding) }
                    } label: {
                        HStack {
                            Text(Self.encodingTitle(encoding))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    static func encodingTitle(_ encoding: ImportTextEncoding) -> String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16LE: "UTF-16 小端 (LE)"
        case .utf16BE: "UTF-16 大端 (BE)"
        }
    }

    private func delimiterChoiceSection(
        _ candidates: [DelimiterCandidate]
    ) -> some View {
        List {
            Section {
                Text("分隔符识别置信度不足。请选择：")
                    .foregroundStyle(.secondary)
            }
            Section("候选分隔符") {
                ForEach(candidates, id: \.delimiter) { candidate in
                    Button {
                        Task {
                            await model.chooseDelimiter(candidate.delimiter)
                        }
                    } label: {
                        HStack {
                            Text(Self.delimiterTitle(candidate.delimiter))
                            Spacer()
                            Text(
                                "置信度 \(Int(candidate.confidence * 100))%"
                                    + (candidate.modalFieldCount.map { " · \($0) 列" } ?? "")
                            )
                            .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    static func delimiterTitle(_ delimiter: Character) -> String {
        switch delimiter {
        case ",": "逗号 (CSV)"
        case "\t": "制表符 (TSV)"
        case ";": "分号"
        default: String(delimiter)
        }
    }

    // MARK: - 字段映射

    private var mappingSection: some View {
        List {
            if let name = model.sourceFileName {
                Section("文件") {
                    LabeledContent("文件", value: name)
                    LabeledContent(
                        "检测到", value:
                            "\(Self.encodingTitle(model.detectedEncoding ?? .utf8)) · "
                            + "\(Self.delimiterTitle(model.detectedDelimiter ?? ","))"
                    )
                }
            }
            Section {
                Toggle("首行是表头", isOn: $model.hasHeaderRow)
            } footer: {
                Text("选中后第一行不导入，仅用于识别字段。")
            }
            Section("字段映射（\(model.columnCount) 列）") {
                ForEach(0..<max(model.columnCount, 1), id: \.self) { column in
                    columnMappingRow(column)
                }
            }
            Section("导入选项") {
                Picker("重复处理", selection: $model.duplicatePolicy) {
                    Text("跳过重复").tag(DuplicatePolicy.skip)
                    Text("更新既有条目").tag(DuplicatePolicy.update)
                    Text("合并标签").tag(DuplicatePolicy.mergeTags)
                }
                Picker("标签格式", selection: $model.tagRule) {
                    Text("JSON 数组").tag(ImportFieldMapping.TagRule.jsonArray)
                    Text("分号列表").tag(ImportFieldMapping.TagRule.semicolonList)
                }
                Picker("多例句", selection: $model.exampleRule) {
                    Text("追加去重")
                        .tag(ImportFieldMapping.ExampleRule.appendDeduplicated)
                    Text("替换主例句")
                        .tag(ImportFieldMapping.ExampleRule.replacePrimary)
                }
                Toggle(
                    "允许空值覆盖既有内容",
                    isOn: $model.allowEmptyOverwrite
                )
            }
            Section("新建卡片方向") {
                ForEach(
                    CardTemplateKind.allCases.filter {
                        $0 != .sentenceCloze && $0 != .grammarFormToExplanation
                    },
                    id: \.rawValue
                ) { kind in
                    Toggle(
                        Self.templateTitle(kind),
                        isOn: Binding(
                            get: { model.newCardTemplates.contains(kind) },
                            set: { on in
                                if on {
                                    model.newCardTemplates.insert(kind)
                                } else {
                                    model.newCardTemplates.remove(kind)
                                }
                            }
                        )
                    )
                }
            }
            Section("目标牌组") {
                if model.decks.isEmpty {
                    Text("暂无牌组——请先创建牌组。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "牌组",
                        selection: Binding(
                            get: { model.targetDeckID },
                            set: { model.targetDeckID = $0 }
                        )
                    ) {
                        ForEach(model.decks) { deck in
                            Text(deck.name).tag(deck.id as UUID?)
                        }
                    }
                }
            }
            if !model.sampleRows.isEmpty {
                Section("预览（前 \(min(model.sampleRows.count, 5)) 行）") {
                    ForEach(model.sampleRows.prefix(5), id: \.logicalRowNumber) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(row.logicalRowNumber) 行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.fields.joined(separator: " | "))
                                .font(.callout)
                                .lineLimit(3)
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await model.runPrecheck() }
                } label: {
                    Text("开始预检").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunPrecheck)
                if !model.mappedHeadwordAssigned {
                    Text("必须映射「单词」字段。")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func columnMappingRow(_ column: Int) -> some View {
        let sample = model.sampleRows.first?.fields
        let sampleValue = (sample?.count ?? 0) > column ? sample![column] : ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("第 \(column + 1) 列")
                    .font(.headline)
                Text(sampleValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Picker(
                "字段",
                selection: Binding(
                    get: { model.columnToField[column] },
                    set: { model.assignField($0, toColumn: column) }
                )
            ) {
                Text("（忽略）").tag(VocabularyImportField?.none)
                ForEach(VocabularyImportField.allCases, id: \.self) { field in
                    Text(Self.fieldTitle(field))
                        .tag(VocabularyImportField?.some(field))
                }
            }
            .pickerStyle(.menu)
        }
    }

    static func fieldTitle(_ field: VocabularyImportField) -> String {
        switch field {
        case .headword: "单词"
        case .reading: "读音"
        case .meaningZH: "释义"
        case .partOfSpeech: "词性"
        case .pitchAccent: "音调"
        case .jlpt: "JLPT"
        case .exampleJapanese: "例句"
        case .exampleTranslationZH: "例句翻译"
        case .tags: "标签"
        case .notes: "备注"
        }
    }

    static func templateTitle(_ kind: CardTemplateKind) -> String {
        switch kind {
        case .vocabularyJapaneseToChinese: "日 → 中"
        case .vocabularyChineseToJapanese: "中 → 日"
        case .vocabularyListening: "听力"
        case .grammarFormToExplanation: "语法"
        case .sentenceCloze: "句子挖空"
        }
    }

    // MARK: - 预检审阅

    private var reviewSection: some View {
        List {
            if let summary = model.precheckSummary {
                Section("预检结果（共 \(summary.totalRows) 行）") {
                    verdictRow("新建", count: summary.createCount, color: .green)
                    verdictRow("更新既有", count: summary.updateCount, color: .blue)
                    verdictRow(
                        "冲突（待选择）", count: summary.conflictCount,
                        color: .orange
                    )
                    verdictRow("无效", count: summary.invalidCount, color: .red)
                    verdictRow(
                        "文件内重复",
                        count: summary.inFileDuplicateCount,
                        color: .secondary
                    )
                }
                if !summary.issues.isEmpty {
                    Section("问题行（前 \(summary.issues.count) 条）") {
                        ForEach(summary.issues, id: \.logicalRow) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    "第 \(issue.logicalRow) 行"
                                        + "（原始行 \(issue.rawLines.lowerBound)–\(issue.rawLines.upperBound)）"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(issue.message)
                                    .font(.callout)
                            }
                        }
                    }
                }
                Section {
                    Button("返回映射") { model.backToMapping() }
                    Button {
                        model.confirmExecute()
                    } label: {
                        Text("确认导入").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        summary.createCount + summary.updateCount == 0
                    )
                } footer: {
                    Text("冲突与无效行在导入时将被跳过并记录到回执。")
                }
            }
        }
    }

    private func verdictRow(_ title: String, count: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }

    // MARK: - 执行 / 摘要

    private var executingSection: some View {
        VStack(spacing: 20) {
            Spacer()
            if let progress = model.committedProgress {
                ProgressView(
                    "正在导入 \(progress.done) / \(progress.total) 行…",
                    value: Double(progress.done),
                    total: max(1, Double(progress.total))
                )
                .progressViewStyle(.linear)
            } else {
                ProgressView("正在导入…")
            }
            Button("取消", role: .destructive) {
                model.cancelExecution()
            }
            Spacer()
        }
        .padding()
    }

    private var summarySection: some View {
        List {
            if let summary = model.executionSummary {
                Section("导入摘要（状态：\(statusTitle(summary.status))）") {
                    verdictRow("新建", count: summary.created, color: .green)
                    verdictRow("更新", count: summary.updated, color: .blue)
                    verdictRow("合并标签", count: summary.mergedTags, color: .teal)
                    verdictRow("跳过", count: summary.skipped, color: .secondary)
                    verdictRow("失败", count: summary.failed, color: .red)
                    if summary.digestConflicts > 0 {
                        verdictRow(
                            "续跑冲突",
                            count: summary.digestConflicts,
                            color: .purple
                        )
                    }
                }
                if !summary.rowDetails.isEmpty {
                    Section("行明细（前 \(summary.rowDetails.count) 条）") {
                        ForEach(summary.rowDetails, id: \.logicalRow) { detail in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("第 \(detail.logicalRow) 行 · \(detail.action.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let reason = detail.reason {
                                    Text(reason).font(.callout)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button("完成") { model.reset() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func statusTitle(_ status: ImportJobStatus) -> String {
        switch status {
        case .previewed: "预览"
        case .running: "执行中"
        case .cancelled: "已取消"
        case .interrupted: "中断（可续跑）"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }

    private func failedSection(_ reason: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)  // 装饰性图标，语义由「导入未完成」承担
            Text("导入未完成")
                .font(.title3)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("重新开始") { model.reset() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
    }
}
