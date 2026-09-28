import CryptoKit
import Foundation
import GRDB
import Observation
import OboeDomain
import OboeInfrastructure

/// v0.7.0 S18：CSV/TSV 导入向导的 ViewModel（§10 两段式流程）。
///
/// 状态机（单向推进，可 cancel/reset）：
///
/// ```
/// idle ──pickFile──▶ intaking ─▶ chooseEncoding? ─▶ chooseDelimiter?
///                                  │                    │
///                                  ▼                    ▼
///               mapping ◀── samplePreview ── (用户确认分隔符/编码后)
///                 │
///                 ▼ runPrecheck（全文件→staging→dry-run，不写业务库）
///               reviewing ◀── 失败回 mapping（改映射重跑 precheck）
///                 │
///                 ▼ confirmExecute（import_jobs + 分批提交）
///               executing ──cancel──▶ cancelled（可 resume）
///                 │                     │
///                 ▼                     ▼ resumeInterrupted
///               summary ◀──────── 执行结束（completed/cancelled/failed）
/// ```
///
/// 崩溃恢复：intake 副本 + staging 文件都在受控目录；
/// `discoverResumableJobs` 列出 interrupted/cancelled 的 job，
/// 按 `staging_file_name` 重定位 staging，`resume(job:)` 直接续跑。
///
/// 测试注入点：`database` + `deckProvider` + `stagingDirectory` +
/// `sampleByteLimit`。
@MainActor
@Observable
final class ImportWizardViewModel {

    // MARK: - 状态

    enum Step: Equatable {
        case idle
        case intaking
        /// 编码检测未确定 → 用户选择（候选已排序）。
        case chooseEncoding(candidates: [ImportTextEncoding])
        /// 分隔符置信不足 → 用户选择。
        case chooseDelimiter(candidates: [DelimiterCandidate])
        /// 字段映射（含样本预览）。
        case mapping
        /// 全文件 staging + dry-run 预检中。
        case prechecking
        /// 预检结果审阅（含错误行报告）。
        case reviewing
        /// 执行中（可取消）。
        case executing
        /// 终态摘要。
        case summary
        /// 不可恢复错误。
        case failed(reason: String)
    }

    private(set) var step: Step = .idle
    private(set) var errorMessage: String?

    // MARK: intake 产物

    /// security-scope 拷贝出的私有文件（读源只在拷贝窗口）。
    private(set) var stagedFileURL: URL?
    private(set) var sourceFileName: String?
    private(set) var fileHash: String?
    private(set) var fileByteCount: Int?
    /// 检测期已确定的编码/需要跳过的 BOM 字节数。
    private(set) var detectedEncoding: ImportTextEncoding?
    private(set) var bomBytes = 0
    private(set) var detectedDelimiter: Character?

    // MARK: 样本与映射

    /// 预览样本（前几 KiB 解析出的前 N 行——不承诺总行数）。
    private(set) var sampleRows: [ImportLogicalRow] = []
    /// 列数 = 样本众数列数（fallback 最大列数）。
    private(set) var columnCount = 0
    /// column → field（0 起始列号）。
    var columnToField: [Int: VocabularyImportField] = [:]
    var hasHeaderRow = false
    var tagRule: ImportFieldMapping.TagRule = .jsonArray
    var duplicatePolicy: DuplicatePolicy = .update
    var allowEmptyOverwrite = false
    var exampleRule: ImportFieldMapping.ExampleRule = .appendDeduplicated
    var newCardTemplates: Set<CardTemplateKind> = [
        .vocabularyJapaneseToChinese, .vocabularyChineseToJapanese
    ]
    var targetDeckID: UUID?
    private(set) var decks: [DeckSummary] = []

    // MARK: staging / precheck / execute

    private var staging: ImportStaging?
    /// 已按「跳过表头」过滤后的数据行数（plan 行数）。
    private(set) var stagedRowCount = 0
    private(set) var precheckSummary: ImportPrecheckSummary?
    private var currentJobID: UUID?
    private(set) var executionSummary: ImportExecutionSummary?
    /// 执行进度：已提交行数 / 总行数。
    private(set) var committedProgress: (done: Int, total: Int)?
    /// 协作取消标志（execute 的 isCancelled 探针读它）。
    private let cancelFlag = CancelProbe()
    private var runningTask: Task<Void, Never>?

    // MARK: 依赖

    private let database: OboeDatabase
    private let deckProvider: @Sendable () async throws -> [DeckSummary]
    private let stagingDirectory: URL
    private let fileManager: FileManager
    /// S24 恢复屏障闸门：execute/resume 登记后恢复窗口内即被取消抽干。
    private let workGate: RestorationWorkGate?
    /// 检测/预览采样上限（字节）。
    let sampleByteLimit: Int

    init(
        database: OboeDatabase,
        deckProvider: @escaping @Sendable () async throws -> [DeckSummary],
        stagingDirectory: URL? = nil,
        fileManager: FileManager = .default,
        workGate: RestorationWorkGate? = nil,
        sampleByteLimit: Int = 64 * 1024
    ) {
        self.database = database
        self.deckProvider = deckProvider
        self.stagingDirectory = stagingDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("OboeImportWizard", isDirectory: true)
        self.fileManager = fileManager
        self.workGate = workGate
        self.sampleByteLimit = sampleByteLimit
    }

    /// S24：把执行任务登记进恢复闸门。闸门已关 → enroll 返回 nil 且
    /// 任务被取消（execute 首个池写即抛 CancellationError）→ 收敛
    /// 为可见失败而非静默卡在 executing。任务结束自动退籍。
    private func enrollWithWorkGate(_ task: Task<Void, Never>) {
        guard let workGate else { return }
        Task { [weak self] in
            guard let token = await workGate.enroll(task) else {
                await task.value
                if self?.step == .executing {
                    self?.fail("正在恢复备份，导入已中止。")
                }
                return
            }
            await task.value
            await workGate.release(token)
        }
    }

    // MARK: - Step 1：intake（拷贝 + hash + 检测）

    /// fileImporter 回调入口：security scope 只在拷贝窗口持有。
    func pickFile(_ sourceURL: URL) async {
        guard step != .executing else { return }
        reset()
        step = .intaking
        errorMessage = nil
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            // S28：拷贝 + 全量 SHA-256 是 O(文件大小) 的同步 I/O——离开
            // MainActor 执行（§17「活跃 UI 可交互」）。security scope
            // 是本进程级资源，detached 内的拷贝仍在持 scope 的窗口内。
            // FileManager 非 Sendable：闭包内新建实例，不跨域发送。
            let stagingDirectory = self.stagingDirectory
            let (copy, hashAndPrefix) = try await Task.detached(
                priority: .userInitiated
            ) {
                let fileManager = FileManager()
                let copy = try Self.copyToStagingArea(
                    sourceURL, fileManager: fileManager,
                    stagingDirectory: stagingDirectory
                )
                return (copy, try Self.hashAndPrefix(of: copy))
            }.value
            stagedFileURL = copy
            sourceFileName = sourceURL.lastPathComponent
            fileHash = hashAndPrefix.hash
            fileByteCount = hashAndPrefix.byteCount
            switch ImportEncodingDetector.detect(prefix: hashAndPrefix.prefix) {
            case let .detected(encoding, bomBytes, _):
                detectedEncoding = encoding
                self.bomBytes = bomBytes
                try await detectDelimiterAndPreview(encoding: encoding)
            case let .undetermined(candidates):
                step = .chooseEncoding(candidates: candidates)
            }
        } catch let error as ImportParseError {
            fail(Self.describeParseError(error))
        } catch {
            fail("无法读取文件：\(error.localizedDescription)")
        }
    }

    /// undetermined 编码的用户选择。
    func chooseEncoding(_ encoding: ImportTextEncoding) async {
        guard case .chooseEncoding = step else { return }
        detectedEncoding = encoding
        bomBytes = 0
        do {
            try await detectDelimiterAndPreview(encoding: encoding)
        } catch let error as ImportParseError {
            fail(Self.describeParseError(error))
        } catch {
            fail("编码 \(encoding.rawValue) 解码失败：\(error.localizedDescription)")
        }
    }

    /// needsUserChoice 分隔符的用户选择。
    func chooseDelimiter(_ delimiter: Character) async {
        guard case .chooseDelimiter = step else { return }
        detectedDelimiter = delimiter
        guard let encoding = detectedEncoding else {
            fail("内部错误：分隔符已选但编码缺失")
            return
        }
        do {
            try await loadSamplePreview(encoding: encoding, delimiter: delimiter)
            step = .mapping
        } catch let error as ImportParseError {
            fail(Self.describeParseError(error))
        } catch {
            fail("样本解析失败：\(error.localizedDescription)")
        }
    }

    private func detectDelimiterAndPreview(
        encoding: ImportTextEncoding
    ) async throws {
        guard let file = stagedFileURL else { return }
        let sample = try decodePrefix(of: file, encoding: encoding)
        switch DelimiterDetector.detect(in: sample) {
        case let .confident(delimiter, _):
            detectedDelimiter = delimiter
            try await loadSamplePreview(encoding: encoding, delimiter: delimiter)
            step = .mapping
        case let .needsUserChoice(candidates):
            step = .chooseDelimiter(candidates: candidates)
        }
    }

    private func loadSamplePreview(
        encoding: ImportTextEncoding, delimiter: Character
    ) async throws {
        guard let file = stagedFileURL else { return }
        let text = try decodePrefix(of: file, encoding: encoding)
        var parser = DelimitedTextParserImpl(delimiter: delimiter)
        var rows = try parser.feed(text)
        rows += (try? parser.finish()) ?? []
        sampleRows = rows
        // 众数列数：样本里出现次数最多的字段数。
        var histogram: [Int: Int] = [:]
        for row in rows { histogram[row.fields.count, default: 0] += 1 }
        columnCount = histogram.max { $0.value < $1.value }?.key
            ?? rows.map(\.fields.count).max() ?? 0
        // 表头启发：首行全是已知字段名/中文表头词则默认勾表头。
        hasHeaderRow = Self.looksLikeHeader(rows.first?.fields ?? [])
        autoGuessMapping()
        decks = (try? await deckProvider()) ?? []
        if targetDeckID == nil { targetDeckID = decks.first?.id }
    }

    // MARK: - Step 2：映射

    /// 中文表头词 → 字段（含英文/日文别名）。
    static let headerAliases: [String: VocabularyImportField] = {
        var map: [String: VocabularyImportField] = [:]
        let pairs: [(VocabularyImportField, [String])] = [
            (.headword, ["单词", "表记", "headword", "word", "単語", "見出し"]),
            (.reading, ["读音", "読み", "reading", "kana", "よみ"]),
            (.meaningZH, ["释义", "意思", "meaning", "意味", "訳"]),
            (.partOfSpeech, ["词性", "品詞", "pos", "partofspeech", "part_of_speech"]),
            (.pitchAccent, ["音调", "アクセント", "pitch", "pitchaccent", "pitch_accent"]),
            (.jlpt, ["jlpt", "等级", "レベル"]),
            (.exampleJapanese, ["例句", "例文", "example", "例"]),
            (.exampleTranslationZH, ["例句翻译", "例句释义", "translation", "例文訳"]),
            (.tags, ["标签", "tags", "tag", "タグ"]),
            (.notes, ["备注", "notes", "note", "メモ"])
        ]
        for (field, names) in pairs {
            for name in names { map[name.lowercased()] = field }
        }
        return map
    }()

    /// 表头启发：全部单元格命中别名表即视作表头。
    static func looksLikeHeader(_ fields: [String]) -> Bool {
        guard !fields.isEmpty else { return false }
        let hits = fields.filter {
            headerAliases[$0.trimmingCharacters(in: .whitespaces).lowercased()] != nil
        }
        return hits.count == fields.count
    }

    /// 表头命中 → 按表头建映射；否则若列数 == 10 按契约列序默认映射。
    private func autoGuessMapping() {
        columnToField = [:]
        guard let first = sampleRows.first else { return }
        if hasHeaderRow {
            for (index, cell) in first.fields.enumerated() {
                let key = cell.trimmingCharacters(in: .whitespaces).lowercased()
                if let field = Self.headerAliases[key] {
                    columnToField[index] = field
                }
            }
        } else if columnCount == VocabularyImportField.allCases.count {
            for (index, field) in CSVExporter.fieldOrder.enumerated() {
                columnToField[index] = field
            }
        }
    }

    /// 把 `field` 指派到 `column`（一对一：旧列上的同字段先清掉）。
    func assignField(_ field: VocabularyImportField?, toColumn column: Int) {
        let collisions = columnToField
            .filter { $0.value == field && $0.key != column }
            .map(\.key)
        for key in collisions { columnToField.removeValue(forKey: key) }
        columnToField[column] = field
    }

    var mappedHeadwordAssigned: Bool {
        columnToField.values.contains(.headword)
    }

    var canRunPrecheck: Bool {
        mappedHeadwordAssigned && targetDeckID != nil && detectedDelimiter != nil
            && !newCardTemplates.isEmpty
    }

    func mapping() -> ImportFieldMapping? {
        guard let targetDeckID else { return nil }
        return ImportFieldMapping(
            columnToField: columnToField,
            tagRule: tagRule,
            duplicatePolicy: duplicatePolicy,
            allowEmptyOverwrite: allowEmptyOverwrite,
            exampleRule: exampleRule,
            newCardTemplates: newCardTemplates.sorted { $0.rawValue < $1.rawValue },
            targetDeckID: targetDeckID
        )
    }

    // MARK: - Step 3：staging + dry-run

    /// 全文件解析 → staging（跳过表头行）→ precheck。任何解析错误
    /// 落到 `.failed`（行级 invalid 是 verdict，不炸流程；解析层错误才炸）。
    func runPrecheck() async {
        guard let mapping = mapping(),
              let encoding = detectedEncoding,
              let delimiter = detectedDelimiter,
              let file = stagedFileURL else {
            errorMessage = "请先完成字段映射并选择目标牌组。"
            return
        }
        step = .prechecking
        errorMessage = nil
        do {
            // S28：全文件 解码→解析→staging 落盘 是 O(行数) 的同步
            // CPU+I/O——离开 MainActor（§17「活跃 UI 可交互」）。
            // ImportStaging 是 @unchecked Sendable（内部 DatabaseQueue
            // 串行化），detached 返回后交回本 actor 持有。
            let bomBytes = self.bomBytes
            let hasHeaderRow = self.hasHeaderRow
            let stagingDirectory = self.stagingDirectory
            let staging = try await Task.detached(priority: .userInitiated) {
                try Self.buildStaging(
                    file: file, encoding: encoding, bomBytes: bomBytes,
                    delimiter: delimiter, hasHeaderRow: hasHeaderRow,
                    stagingDirectory: stagingDirectory
                )
            }.value
            self.staging = staging
            stagedRowCount = staging.rowCount

            let executor = ImportExecutor(database: database)
            precheckSummary = try await executor.precheck(
                mapping: mapping, staging: staging
            )
            step = .reviewing
        } catch let error as ImportParseError {
            fail(Self.describeParseError(error))
        } catch {
            fail("预检失败：\(error.localizedDescription)")
        }
    }

    /// 追加解析行；首个逻辑记录 + hasHeaderRow → 跳过（保留原行号
    /// 供错误报告与文件行号对齐）。
    nonisolated private static func appendRows(
        _ rows: [ImportLogicalRow],
        hasHeaderRow: Bool,
        skipFirst isFirst: inout Bool,
        to staging: ImportStaging
    ) throws {
        guard !rows.isEmpty else { return }
        var toAppend = rows
        if isFirst {
            isFirst = false
            if hasHeaderRow { toAppend = Array(rows.dropFirst()) }
        }
        try staging.append(toAppend)
    }

    /// 全文件 → staging SQLite 的同步构建。调用方须放在 detached
    /// 任务里（body 为纯 CPU+I/O，无任何 actor 状态）。
    nonisolated private static func buildStaging(
        file: URL,
        encoding: ImportTextEncoding,
        bomBytes: Int,
        delimiter: Character,
        hasHeaderRow: Bool,
        stagingDirectory: URL
    ) throws -> ImportStaging {
        let staging = try ImportStaging(directory: stagingDirectory)
        var decoder = IncrementalTextDecoder(encoding: encoding, bomBytes: bomBytes)
        var parser = DelimitedTextParserImpl(delimiter: delimiter)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var isFirstRecord = true
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            let text = try decoder.decode(chunk)
            if !text.isEmpty {
                let rows = try parser.feed(text)
                try appendRows(
                    rows, hasHeaderRow: hasHeaderRow,
                    skipFirst: &isFirstRecord, to: staging
                )
            }
        }
        let tail = try decoder.finish()
        if !tail.isEmpty {
            try appendRows(
                try parser.feed(tail), hasHeaderRow: hasHeaderRow,
                skipFirst: &isFirstRecord, to: staging
            )
        }
        try appendRows(
            try parser.finish(), hasHeaderRow: hasHeaderRow,
            skipFirst: &isFirstRecord, to: staging
        )
        return staging
    }

    /// 回到映射（改映射后需重跑 precheck——staging 重建）。
    func backToMapping() {
        guard step == .reviewing else { return }
        try? staging?.discard()
        staging = nil
        precheckSummary = nil
        stagedRowCount = 0
        step = .mapping
    }

    // MARK: - Step 4：执行

    /// 确认执行：建 job → attach staging → execute（批边界取消探针
    /// + 每批进度回调）。UI 侧「取消」置 `cancelFlag`。
    func confirmExecute() {
        guard step == .reviewing,
              let mapping = mapping(),
              let staging else { return }
        cancelFlag.reset()
        committedProgress = (0, stagedRowCount)
        step = .executing
        runningTask = Task { [weak self] in
            guard let self else { return }
            let repo = GRDBImportPlanRepository(database: self.database)
            let job = ImportJob(
                id: UUID(),
                fileHash: self.fileHash ?? "",
                mappingHash: ImportExecutor.mappingHash(mapping),
                policy: mapping.duplicatePolicy,
                targetDeckID: mapping.targetDeckID,
                status: .previewed,
                createdAt: Date()
            )
            do {
                try await repo.createJob(job)
                self.currentJobID = job.id
                try await repo.attachStagingInfo(
                    jobID: job.id,
                    stagingFileName: staging.fileURL.lastPathComponent,
                    stagingFingerprint: self.fileHash ?? "",
                    rowCount: staging.rowCount,
                    mappingSummary: Self.describeMapping(mapping)
                )
                let executor = ImportExecutor(database: self.database)
                let flag = self.cancelFlag
                let summary = try await executor.execute(
                    jobID: job.id,
                    mapping: mapping,
                    staging: staging,
                    isCancelled: { flag.cancelled },
                    onBatchCommitted: { done in
                        Task { @MainActor in
                            self.committedProgress = (done, self.stagedRowCount)
                        }
                    }
                )
                self.executionSummary = summary
                self.step = .summary
            } catch is CancellationError {
                self.step = .summary
            } catch let error as ImportExecutorError {
                self.fail(Self.describeExecutorError(error))
            } catch {
                self.fail("执行失败：\(error.localizedDescription)")
            }
        }
        if let task = runningTask { enrollWithWorkGate(task) }
    }

    /// 取消执行（批边界生效——已提交批保留，可在摘要页看到提交数）。
    func cancelExecution() {
        cancelFlag.cancel()
    }

    // MARK: - 崩溃/取消续跑

    /// 可续跑 job 列表（interrupted/cancelled + staging 文件仍在）。
    func discoverResumableJobs() async -> [GRDBImportPlanRepository.JobDetail] {
        // 计划库无 list API —— 直查（读侧）。
        let idStrings = (try? await database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM import_jobs
                    WHERE status IN ('interrupted', 'cancelled', 'previewed', 'running')
                    ORDER BY updated_at_ms DESC
                    """
            )
        }) ?? []
        var details: [GRDBImportPlanRepository.JobDetail] = []
        let repo = GRDBImportPlanRepository(database: database)
        for raw in idStrings {
            guard let id = try? DatabaseValueCodec.decodeUUID(raw),
                  let detail = try? await repo.fetchJobDetail(id: id),
                  let fileName = detail.stagingFileName else { continue }
            let candidate = stagingDirectory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                details.append(detail)
            }
        }
        return details
    }

    /// 续跑既有 job：按 `staging_file_name` 重定位 staging（受控目录
    /// 内，不用绝对路径）。mappingHash 用 job 持久化的构造对应 mapping
    /// 需要用户确认映射一致——本实现要求调用方传入当时 mapping
    /// （S18 视图层从 `mapping_summary` 展示并复选）。
    func resume(
        jobID: UUID,
        mapping: ImportFieldMapping,
        stagingFileName: String
    ) {
        do {
            let staging = try ImportStaging(
                directory: stagingDirectory, fileName: stagingFileName
            )
            self.staging = staging
            stagedRowCount = staging.rowCount
            currentJobID = jobID
            cancelFlag.reset()
            committedProgress = nil
            step = .executing
            runningTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let executor = ImportExecutor(database: self.database)
                    let flag = self.cancelFlag
                    let summary = try await executor.execute(
                        jobID: jobID,
                        mapping: mapping,
                        staging: staging,
                        isCancelled: { flag.cancelled },
                        onBatchCommitted: { done in
                            Task { @MainActor in
                                self.committedProgress = (done, self.stagedRowCount)
                            }
                        }
                    )
                    self.executionSummary = summary
                    self.step = .summary
                } catch let error as ImportExecutorError {
                    self.fail(Self.describeExecutorError(error))
                } catch {
                    self.fail("续跑失败：\(error.localizedDescription)")
                }
            }
            if let task = runningTask { enrollWithWorkGate(task) }
        } catch {
            fail("无法重开 staging：\(error.localizedDescription)")
        }
    }

    // MARK: - 工具

    /// 完全复位（放弃 staging 与 intake 副本）。
    func reset() {
        runningTask?.cancel()
        runningTask = nil
        cancelFlag.reset()
        try? staging?.discard()
        staging = nil
        if let file = stagedFileURL {
            try? fileManager.removeItem(at: file)
        }
        stagedFileURL = nil
        sourceFileName = nil
        fileHash = nil
        fileByteCount = nil
        detectedEncoding = nil
        detectedDelimiter = nil
        bomBytes = 0
        sampleRows = []
        columnCount = 0
        columnToField = [:]
        hasHeaderRow = false
        precheckSummary = nil
        executionSummary = nil
        committedProgress = nil
        stagedRowCount = 0
        currentJobID = nil
        errorMessage = nil
        step = .idle
    }

    nonisolated private static func copyToStagingArea(
        _ sourceURL: URL, fileManager: FileManager, stagingDirectory: URL
    ) throws -> URL {
        try fileManager.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true
        )
        let ext = sourceURL.pathExtension.isEmpty ? "csv" : sourceURL.pathExtension
        let destination = stagingDirectory
            .appendingPathComponent("intake-\(UUID().uuidString).\(ext)")
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    nonisolated private static func hashAndPrefix(
        of url: URL
    ) throws -> (hash: String, prefix: [UInt8], byteCount: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var prefix: [UInt8] = []
        var total = 0
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
            total += chunk.count
            if prefix.count < 4096 {
                let need = 4096 - prefix.count
                prefix.append(contentsOf: chunk.prefix(need))
            }
        }
        let hex = digest.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return (hex, prefix, total)
    }

    /// 解码文件前缀样本（BOM 跳过、严格校验）。
    private func decodePrefix(
        of url: URL, encoding: ImportTextEncoding
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var decoder = IncrementalTextDecoder(
            encoding: encoding, bomBytes: bomBytes
        )
        var collected = ""
        var remaining = sampleByteLimit
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(remaining, 64 * 1024))
                ?? Data()
            if chunk.isEmpty { break }
            collected += try decoder.decode(chunk)
            remaining -= chunk.count
        }
        collected += try decoder.finish()
        return collected
    }

    private func fail(_ message: String) {
        errorMessage = message
        step = .failed(reason: message)
    }

    // MARK: - 描述

    static func describeParseError(_ error: ImportParseError) -> String {
        switch error {
        case let .malformedRow(row, lines, reason):
            "第 \(row) 行（原始行 \(lines.lowerBound)–\(lines.upperBound)）格式错误：\(reason)"
        case .undeterminedEncoding:
            "无法确定文本编码，请手动选择。"
        case let .invalidEncoding(offset, reason):
            "编码解码失败（字节偏移 \(offset)）：\(reason)"
        case let .limitExceeded(metric, limit):
            "超出导入上限：\(metric) > \(limit)"
        case .cancelled:
            "已取消。"
        }
    }

    static func describeExecutorError(_ error: ImportExecutorError) -> String {
        switch error {
        case .jobNotFound: "导入任务不存在。"
        case .jobNotRunnable(let status): "任务状态 \(status.rawValue) 不可执行。"
        case .mappingHashMismatch: "字段映射已变更，请重新预检。"
        case .precheckRequired: "请先完成预检再执行。"
        }
    }

    static func describeMapping(_ mapping: ImportFieldMapping) -> String {
        let pairs = mapping.columnToField
            .sorted { $0.key < $1.key }
            .map { "列\($0.key + 1)→\($0.value.rawValue)" }
            .joined(separator: ", ")
        return "\(pairs) | 重复:\(mapping.duplicatePolicy.rawValue)"
    }
}

/// 跨并发送性边界的协作取消探针。
final class CancelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }
    func reset() {
        lock.lock()
        _cancelled = false
        lock.unlock()
    }
}

