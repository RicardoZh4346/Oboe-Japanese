import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S18：词汇 CSV/TSV 导出器（§10.4）。
///
/// 只导出契约 10 个内容字段（`VocabularyImportField`）：
/// `headword, reading, meaningZH, partOfSpeech, pitchAccent, jlpt,
/// exampleJapanese, exampleTranslationZH, tags, notes`。
/// **绝不导出任何内部字段**——ID/UUID/deck 成员关系/FSRS 调度
/// （state/due/stability/difficulty/reps/lapses/state_version/
/// profile_id/algorithm_version）/review_logs 一律不出现（计划红线）。
///
/// 只读导出：单 `pool.read` 快照 + `FileHandle` 流式追加，整库不驻留
/// 内存；每 `noteBatchSize` 条 note 一批取 examples/tags。
public struct CSVExportOptions: Equatable, Sendable {
    /// 引号/转义模式。
    public enum EscapeMode: String, Sendable, CaseIterable {
        /// 严格 RFC4180：UTF-8 BOM + CRLF 行终止；字段含分隔符/引号/
        /// CR/LF 时整体加引号、内部 `"` 翻倍。导出文件可被 S16 parser
        /// 与 Excel/Numbers 无损回读（round-trip 保真）。
        case safeRFC4180
        /// 原样：LF 行终止、无 BOM、**不做引号转义**——字段按库内原文
        /// 写出。含分隔符/换行的字段会产生不可回读的行（摘要在
        /// `lossyRows` 计数并告警）；适合纯查看/外部工具。
        case verbatim
    }

    /// 多例句策略：一条 vocabulary Note 可有多行 `examples`。
    public enum MultiExampleRule: String, Sendable, CaseIterable {
        /// 仅导出 sort_order=0 的主例句；被丢弃的例句计入
        /// `droppedExamples`（向导应向用户提示数量）。
        case primaryOnly
        /// 全部例句并入字段：多条按 sort_order 升序以 `\n` 连接
        /// （safeRFC4180 下仍在引号内保真回读为单字段）。
        case mergeAll
    }

    /// 目标牌组过滤；nil = 全部 vocabulary Note。
    public var deckID: UUID?
    /// 卡类型白名单：Note 至少拥有一张该集合内的卡才导出；
    /// nil = 不过滤（等价于「全部导出」）。用于「排除 card 类型」选项：
    /// 比如只导 `vocabulary_ja_zh`/`vocabulary_zh_ja` 即排除仅有听力卡
    /// 的词。grammar/sentence 模板天然不属于 vocabulary，无影响。
    public var includedCardTemplates: Set<CardTemplateKind>?
    /// 多例句策略。
    public var multiExampleRule: MultiExampleRule
    /// 转义模式。
    public var escapeMode: EscapeMode
    /// 分隔符（默认逗号；TSV 传 `"\t"`）。
    public var delimiter: Character
    /// 是否写中文表头（导入向导有「首行表头」开关可跳过）。
    public var includeHeader: Bool

    public init(
        deckID: UUID? = nil,
        includedCardTemplates: Set<CardTemplateKind>? = nil,
        multiExampleRule: MultiExampleRule = .primaryOnly,
        escapeMode: EscapeMode = .safeRFC4180,
        delimiter: Character = ",",
        includeHeader: Bool = true
    ) {
        self.deckID = deckID
        self.includedCardTemplates = includedCardTemplates
        self.multiExampleRule = multiExampleRule
        self.escapeMode = escapeMode
        self.delimiter = delimiter
        self.includeHeader = includeHeader
    }
}

public struct CSVExportSummary: Equatable, Sendable {
    /// 已导出的数据行数（不含表头）。
    public var exportedRows = 0
    /// 因卡类型白名单被跳过的 note 数。
    public var skippedByCardType = 0
    /// primaryOnly 策略下丢弃的非主例句条数（应向用户提示）。
    public var droppedExamples = 0
    /// verbatim 模式下字段含分隔符/换行而未转义（不可回读）的行数。
    public var lossyRows = 0
    /// 写出总字节数。
    public var byteCount: Int64 = 0

    public init() {}
}

public enum CSVExportError: Error, Equatable, Sendable {
    case cannotCreateFile(String)
    case cancelled
}

public final class CSVExporter: Sendable {
    private let pool: DatabasePool

    /// 一批处理的 note 数（examples/tags IN 查询分块粒度）。
    static let noteBatchSize = 400
    /// 进度回调粒度（每 N 行回调一次）。
    static let progressGranularity = 500

    /// 契约字段顺序 = 导出列序（固定，供表头与行生成共用）。
    public static let fieldOrder: [VocabularyImportField] = [
        .headword, .reading, .meaningZH, .partOfSpeech, .pitchAccent,
        .jlpt, .exampleJapanese, .exampleTranslationZH, .tags, .notes
    ]

    /// 中文表头（契约「中文表头或字段名」）。
    public static let headerTitles: [String] = [
        "单词", "读音", "释义", "词性", "音调",
        "JLPT", "例句", "例句翻译", "标签", "备注"
    ]

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    /// 流式导出：单读快照保证一致性（导出期间库被并发改动不撕裂），
    /// `isCancelled` 协作探针在批边界检查。`onProgress` 为同步回调
    /// （在 GRDB 读事务内，不能挂起）。
    @discardableResult
    public func export(
        to fileURL: URL,
        options: CSVExportOptions = CSVExportOptions(),
        isCancelled: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> CSVExportSummary {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw CSVExportError.cannotCreateFile(fileURL.path)
        }
        var summary = CSVExportSummary()
        do {
            if options.escapeMode == .safeRFC4180 {
                try write(Data([0xEF, 0xBB, 0xBF]), to: handle, into: &summary)
            }
            if options.includeHeader {
                try write(
                    encodedLine(Self.headerTitles, options: options)
                        .data(using: .utf8)!,
                    to: handle, into: &summary
                )
            }
            // 读事务内局部累计，避免 @Sendable 闭包捕获 var（写文件
            // 也在同一快照内，整个导出一致）。
            let body = try await pool.read { db in
                try self.exportBody(
                    in: db,
                    handle: handle,
                    options: options,
                    isCancelled: isCancelled,
                    onProgress: onProgress
                )
            }
            summary.exportedRows = body.exportedRows
            summary.skippedByCardType = body.skippedByCardType
            summary.droppedExamples = body.droppedExamples
            summary.lossyRows = body.lossyRows
            summary.byteCount += body.byteCount
            try handle.synchronize()
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return summary
    }

    /// 单快照内的批分页导出主体。
    private func exportBody(
        in db: Database,
        handle: FileHandle,
        options: CSVExportOptions,
        isCancelled: (@Sendable () -> Bool)?,
        onProgress: (@Sendable (Int) -> Void)?
    ) throws -> CSVExportSummary {
        var summary = CSVExportSummary()
        var lastRowID: Int64 = 0
        while true {
            if Task.isCancelled || (isCancelled?() ?? false) {
                throw CSVExportError.cancelled
            }
            let notes = try fetchNotePage(
                after: lastRowID, options: options, in: db
            )
            if notes.isEmpty { break }
            lastRowID = notes.last!.rowid

            let noteIDs = notes.map(\.id)
            let examples = try fetchExamples(noteIDs: noteIDs, in: db)
            let tags = try fetchTags(noteIDs: noteIDs, in: db)
            let cardKinds = try fetchCardKinds(noteIDs: noteIDs, in: db)

            for note in notes {
                if let allowed = options.includedCardTemplates {
                    let kinds = cardKinds[note.id] ?? []
                    if !kinds.contains(where: { allowed.contains($0) }) {
                        summary.skippedByCardType += 1
                        continue
                    }
                }
                let fields = renderFields(
                    note: note,
                    examples: examples[note.id] ?? [],
                    tags: tags[note.id] ?? [],
                    options: options,
                    droppedInto: &summary.droppedExamples
                )
                if options.escapeMode == .verbatim,
                   fields.contains(where: {
                       $0.contains(options.delimiter)
                           || $0.contains("\n") || $0.contains("\r")
                   }) {
                    summary.lossyRows += 1
                }
                let line = encodedLine(fields, options: options)
                try write(line.data(using: .utf8)!, to: handle, into: &summary)
                summary.exportedRows += 1
                if summary.exportedRows % Self.progressGranularity == 0 {
                    onProgress?(summary.exportedRows)
                }
            }
        }
        return summary
    }

    // MARK: - 行渲染

    private struct ExportableNote {
        let rowid: Int64
        let id: String
        var headword: String
        var reading: String?
        var meaningZH: String
        var partOfSpeech: String?
        var pitchAccent: Int?
        var jlpt: String?
        var notes: String?
    }

    /// 10 字段按契约列序渲染；tags 序列化为 JSON array（与导入
    /// `tagRule: .jsonArray` 往返兼容）。
    private func renderFields(
        note: ExportableNote,
        examples: [(japanese: String, translationZH: String?)],
        tags: [String],
        options: CSVExportOptions,
        droppedInto dropped: inout Int
    ) -> [String] {
        var exampleJa = ""
        var exampleZh = ""
        switch options.multiExampleRule {
        case .primaryOnly:
            if let first = examples.first {
                exampleJa = first.japanese
                exampleZh = first.translationZH ?? ""
            }
            dropped += max(0, examples.count - 1)
        case .mergeAll:
            exampleJa = examples.map(\.japanese).joined(separator: "\n")
            exampleZh = examples
                .map { $0.translationZH ?? "" }
                .joined(separator: "\n")
        }
        let tagsJSON = (try? String(
            data: JSONEncoder().encode(tags), encoding: .utf8
        )) ?? "[]"
        return Self.fieldOrder.map { field in
            switch field {
            case .headword: note.headword
            case .reading: note.reading ?? ""
            case .meaningZH: note.meaningZH
            case .partOfSpeech: note.partOfSpeech ?? ""
            case .pitchAccent: note.pitchAccent.map(String.init) ?? ""
            case .jlpt: note.jlpt ?? ""
            case .exampleJapanese: exampleJa
            case .exampleTranslationZH: exampleZh
            case .tags: tagsJSON
            case .notes: note.notes ?? ""
            }
        }
    }

    // MARK: - 转义

    private func lineTerminator(_ options: CSVExportOptions) -> String {
        options.escapeMode == .safeRFC4180 ? "\r\n" : "\n"
    }

    private func encodedLine(_ fields: [String], options: CSVExportOptions) -> String {
        let escaped = fields.map { escapeField($0, options: options) }
        return escaped.joined(separator: String(options.delimiter))
            + lineTerminator(options)
    }

    private func escapeField(_ field: String, options: CSVExportOptions) -> String {
        switch options.escapeMode {
        case .verbatim:
            // 原样：不加引号不翻倍（损失提示在外层计数）。
            return field
        case .safeRFC4180:
            let needsQuotes = field.contains("\"")
                || field.contains(options.delimiter)
                || field.contains("\r")
                || field.contains("\n")
            guard needsQuotes else { return field }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    // MARK: - 查询（批分页）

    private func fetchNotePage(
        after lastRowID: Int64,
        options: CSVExportOptions,
        in db: Database
    ) throws -> [ExportableNote] {
        var arguments: [DatabaseValueConvertible] = []
        var sql = """
            SELECT n.rowid, n.id, n.headword, n.reading, n.meaning_zh,
                   n.part_of_speech, n.pitch_accent, n.jlpt, n.notes
            FROM notes n
            WHERE n.kind = 'vocabulary' AND n.rowid > ?
            """
        arguments.append(lastRowID)
        if let deckID = options.deckID {
            sql += """
                 AND EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = n.id AND nd.deck_id = ?
                )
                """
            arguments.append(DatabaseValueCodec.encode(deckID))
        }
        sql += " ORDER BY n.rowid LIMIT \(Self.noteBatchSize)"
        return try Row.fetchAll(db, sql: sql, arguments: .init(arguments))
            .map { row in
                ExportableNote(
                    rowid: row["rowid"],
                    id: row["id"],
                    headword: row["headword"],
                    reading: row["reading"],
                    meaningZH: row["meaning_zh"],
                    partOfSpeech: row["part_of_speech"],
                    pitchAccent: row["pitch_accent"],
                    jlpt: row["jlpt"],
                    notes: row["notes"]
                )
            }
    }

    private func fetchExamples(
        noteIDs: [String], in db: Database
    ) throws -> [String: [(japanese: String, translationZH: String?)]] {
        guard !noteIDs.isEmpty else { return [:] }
        var result: [String: [(japanese: String, translationZH: String?)]] = [:]
        for chunk in noteIDs.csvChunked(into: 300) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT note_id, japanese, translation_zh
                    FROM examples WHERE note_id IN (\(placeholders))
                    ORDER BY note_id, sort_order, id
                    """,
                arguments: .init(chunk)
            )
            for row in rows {
                let noteID: String = row["note_id"]
                result[noteID, default: []].append(
                    (row["japanese"], row["translation_zh"])
                )
            }
        }
        return result
    }

    private func fetchTags(
        noteIDs: [String], in db: Database
    ) throws -> [String: [String]] {
        guard !noteIDs.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        for chunk in noteIDs.csvChunked(into: 300) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT nt.note_id, t.name
                    FROM note_tags nt JOIN tags t ON t.id = nt.tag_id
                    WHERE nt.note_id IN (\(placeholders))
                    ORDER BY nt.note_id, t.normalized_name
                    """,
                arguments: .init(chunk)
            )
            for row in rows {
                let noteID: String = row["note_id"]
                result[noteID, default: []].append(row["name"])
            }
        }
        return result
    }

    private func fetchCardKinds(
        noteIDs: [String], in db: Database
    ) throws -> [String: [CardTemplateKind]] {
        guard !noteIDs.isEmpty else { return [:] }
        var result: [String: [CardTemplateKind]] = [:]
        for chunk in noteIDs.csvChunked(into: 300) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT note_id, template_kind FROM cards
                    WHERE note_id IN (\(placeholders))
                    """,
                arguments: .init(chunk)
            )
            for row in rows {
                let noteID: String = row["note_id"]
                let raw: String = row["template_kind"]
                if let kind = CardTemplateKind(rawValue: raw) {
                    result[noteID, default: []].append(kind)
                }
            }
        }
        return result
    }

    private func write(
        _ data: Data,
        to handle: FileHandle,
        into summary: inout CSVExportSummary
    ) throws {
        try handle.write(contentsOf: data)
        summary.byteCount += Int64(data.count)
    }
}

private extension Array {
    /// IN 分块（防 SQLite 变量上限）。名字带 csv 前缀，避免与本文件
    /// 外可能存在的同名 fileprivate helper 冲突。
    func csvChunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var index = startIndex
        while index < endIndex {
            let end = index + size > endIndex ? endIndex : index + size
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
