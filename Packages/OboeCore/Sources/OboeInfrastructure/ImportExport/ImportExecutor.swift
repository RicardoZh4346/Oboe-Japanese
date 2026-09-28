import CryptoKit
import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S17：CSV/TSV 导入执行器（§10.2/§10.3）。
///
/// 流程：`precheck`（dry-run，只读业务库 + 把 verdict 写进 staging 的
/// `plan_rows`——业务表零写入）→ `execute`（staging 重放 → 每批 ≤200 行
/// 一次 `pool.write`：行级 SAVEPOINT 隔离领域失败、receipt 与批提交同
/// 事务、批边界取消检查）→ `ImportExecutionSummary`。
///
/// 关键语义：
/// - 重复键：`VocabularyDuplicateKey`（kind + trim(headword) +
///   COALESCE(trim(reading),'')），与 `fetchDuplicateSummaries` 口径一致。
/// - 文件内重复：第一个产出计划目标（create/update/conflict）的行为基准；
///   invalid 行不占位。后续同键行 → `inFileDuplicate(first)`。
/// - 并发防线（§10.3）：update 行在预检记录 `expectedContentVersion`；
///   执行时发现版本漂移 → 该行 failed("contentVersionChanged")，要求重新
///   预览——绝不覆盖较新内容。
/// - 行失败隔离：每行包 SAVEPOINT；领域/校验错误回滚该行并记
///   `action=failed` receipt，批继续；基础设施错误（I/O、约束违例等
///   receipt 写入失败）向上抛出 → 整批回滚 → job=failed（§10.3「数据库级
///   失败回滚整批，允许重试」）。
/// - 续跑/重放：已有 receipt 的行跳过；payload digest 不一致 → 计
///   `digestConflicts`，不改旧 receipt（§10.3 幂等语义）。
/// - 空值：默认「仅映射且非空字段覆盖」；`allowEmptyOverwrite` 显式清空
///   可选列（headword/meaningZH 受 CHECK 约束永不清空）。example 字段
///   永不删除既有例句（replacePrimary 只改写 sort_order=0 主例句，
///   appendDeduplicated 按 (japanese, translationZH) 内容去重追加）。
/// - update/mergeTags 不动 Card/调度字段（只写 notes 列/note_decks/
///   note_tags/examples——D11：Note/Card ID 与全部调度字段保留）。
///
/// 走 `GRDBContentWriteExecutor` 的路径：新建 Note（获得
/// builtin_jlpt 去重、membership、search trigger 等全部既有不变量）。
/// update/mergeTags 是 executor 不支持的读改写——实现为批事务内的
/// 定向 SQL（见报告「Contract deltas」的 `vocabularyUpdate` 提案）。
public enum ImportExecutorError: Error, Equatable, Sendable {
    case jobNotFound
    case jobNotRunnable(status: ImportJobStatus)
    /// 执行用的 mapping 与 job 持久化的 mappingHash 不一致——必须重建 plan。
    case mappingHashMismatch
    /// staging 没有 plan_rows——必须先跑 `precheck`。
    case precheckRequired
}

// MARK: - 映射与行模型

/// 一行映射+字段级校验的产物（S17 内部模型）。
public struct MappedVocabularyRow: Equatable, Sendable {
    /// 映射且非空的字段值（已 trim/规范化）。
    public var headword: String?
    public var reading: String?
    public var meaningZH: String?
    public var partOfSpeech: String?
    public var jlpt: JLPTLevel?
    public var pitchAccent: PitchAccent?
    public var notes: String?
    public var exampleJapanese: String?
    public var exampleTranslationZH: String?
    public var tagNames: [String] = []
    /// 映射但为空的字段（`allowEmptyOverwrite` 时用于清空可选项）。
    public var mappedEmptyFields: Set<VocabularyImportField> = []
    /// 映射到的字段集合（含 empty）。
    public var mappedFields: Set<VocabularyImportField> = []

    /// 重复键所需的 headword/reading（trim 后）。
    public var duplicateKey: VocabularyDuplicateKey? {
        guard let headword else { return nil }
        return VocabularyDuplicateKey(kind: .vocabulary, headword: headword, reading: reading)
    }
}

/// 字段映射 + 单行解析。语法错误（JLPT/音调/tags JSON/例句配对）在此
/// 全部变成 invalid——`validatedContent()` 的必填校验只对 create 生效
/// （update 行允许只更新部分字段）。
enum ImportRowMapper {

    enum MapError: Error, Equatable {
        case missingHeadword
        case invalidJLPT(String)
        case invalidPitchAccent(String)
        case invalidTags(String)
        case invalidTagName(String)
        case validation(VocabularyValidationError)
        case pitchAccentInconsistent
    }

    /// 解析一行 fields → 映射行；不检查 headword/meaning 必填（交给 verdict）。
    static func map(
        fields: [String],
        mapping: ImportFieldMapping
    ) -> Result<MappedVocabularyRow, MapError> {
        var row = MappedVocabularyRow()
        for (column, field) in mapping.columnToField {
            guard column >= 0, column < fields.count else { continue }
            let raw = fields[column].trimmingCharacters(in: .whitespacesAndNewlines)
            row.mappedFields.insert(field)
            if raw.isEmpty {
                row.mappedEmptyFields.insert(field)
                continue
            }
            switch field {
            case .headword: row.headword = raw
            case .reading: row.reading = raw
            case .meaningZH: row.meaningZH = raw
            case .partOfSpeech:
                switch canonicalPartOfSpeech(raw) {
                case let .success(value): row.partOfSpeech = value
                case let .failure(error): return .failure(error)
                }
            case .jlpt:
                let normalized = raw.uppercased()
                guard let level = JLPTLevel(rawValue: normalized) else {
                    return .failure(.invalidJLPT(raw))
                }
                row.jlpt = level
            case .pitchAccent:
                guard let value = Int(raw), let accent = PitchAccent(rawValue: value) else {
                    return .failure(.invalidPitchAccent(raw))
                }
                row.pitchAccent = accent
            case .exampleJapanese: row.exampleJapanese = raw
            case .exampleTranslationZH: row.exampleTranslationZH = raw
            case .notes: row.notes = raw
            case .tags:
                switch parseTags(raw, rule: mapping.tagRule) {
                case let .success(names): row.tagNames = names
                case let .failure(error): return .failure(error)
                }
            }
        }
        // 例句配对：只有翻译没有日文 → invalid（与 validatedContent 同规则）。
        if row.exampleJapanese == nil && row.exampleTranslationZH != nil {
            return .failure(.validation(.exampleJapaneseRequired))
        }
        // 音调需要读音一致：行内 reading 优先，update 时回落既有值在执行层校验。
        if let accent = row.pitchAccent, accent.rawValue > 0,
           let reading = row.reading,
           !accent.isConsistent(withReading: reading) {
            return .failure(.pitchAccentInconsistent)
        }
        return .success(row)
    }

    /// create 路径的完整校验（必填 headword/meaningZH/读音-音调一致性）。
    static func validatedContent(
        _ row: MappedVocabularyRow
    ) -> Result<ValidatedVocabularyContent, MapError> {
        let form = VocabularyFormData(
            headword: row.headword ?? "",
            reading: row.reading ?? "",
            meaningZH: row.meaningZH ?? "",
            partOfSpeech: row.partOfSpeech ?? "",
            jlpt: row.jlpt,
            exampleJapanese: row.exampleJapanese ?? "",
            exampleTranslationZH: row.exampleTranslationZH ?? "",
            notes: row.notes ?? "",
            pitchAccent: row.pitchAccent
        )
        do {
            return .success(try form.validatedContent())
        } catch let error as VocabularyValidationError {
            return .failure(.validation(error))
        } catch {
            return .failure(.validation(.headwordRequired))
        }
    }

    static func makeTags(_ names: [String], makeID: () -> UUID) -> Result<[KnowledgeTag], MapError> {
        var normalized = Set<String>()
        var tags: [KnowledgeTag] = []
        for name in names {
            do {
                let tag = try KnowledgeTagName(validating: name)
                guard normalized.insert(tag.normalizedName).inserted else { continue }
                tags.append(KnowledgeTag(
                    id: makeID(),
                    name: tag.displayName,
                    normalizedName: tag.normalizedName
                ))
            } catch {
                return .failure(.invalidTagName(name))
            }
        }
        return .success(tags)
    }

    private static func parseTags(
        _ raw: String,
        rule: ImportFieldMapping.TagRule
    ) -> Result<[String], MapError> {
        switch rule {
        case .jsonArray:
            guard let data = raw.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                return .failure(.invalidTags("tags JSON array 解析失败"))
            }
            var names: [String] = []
            for element in array {
                guard let string = element as? String else {
                    return .failure(.invalidTags("tags JSON array 含非字符串元素"))
                }
                names.append(string)
            }
            return .success(names)
        case .semicolonList:
            return .success(
                raw.split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            )
        }
    }

    /// POS 受控集合 + 别名映射：命中白名单原子/别名 → canonical " / " 序；
    /// 全部未知且非空 → invalid（§10.2「非法值默认不自动纠正」）。
    private static func canonicalPartOfSpeech(_ raw: String) -> Result<String, MapError> {
        let atoms = raw
            .split(whereSeparator: { "/;、，,".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !atoms.isEmpty else { return .success(raw) }
        var known = Set<VocabularyPartOfSpeech>()
        var unknown: [String] = []
        for atom in atoms {
            if let value = partOfSpeechAliases[atom.lowercased()] ?? VocabularyPartOfSpeech(rawValue: atom) {
                known.insert(value)
            } else {
                unknown.append(atom)
            }
        }
        if known.isEmpty {
            return .failure(.invalidTagName("未知词性: \(atoms.joined(separator: "/"))"))
        }
        // 已知原子按白名单序规范化；未知原子保留原文（与 VocabularyPartOfSpeech.parse 同语义）。
        var parts = VocabularyPartOfSpeech.format(known) ?? ""
        for atom in unknown { parts += " / \(atom)" }
        return .success(parts)
    }

    /// 常见英文/日文别名 → 受控集合原子（确定性小表；未知走 invalid）。
    static let partOfSpeechAliases: [String: VocabularyPartOfSpeech] = [
        "noun": .noun, "n": .noun,
        "pronoun": .pronoun,
        "godan": .godanVerb, "v5": .godanVerb, "五段動詞": .godanVerb, "godan verb": .godanVerb,
        "ichidan": .ichidanVerb, "v1": .ichidanVerb, "一段動詞": .ichidanVerb, "ru-verb": .ichidanVerb,
        "suru": .suruVerb, "する動詞": .suruVerb, "suru verb": .suruVerb,
        "kuru": .kuruVerb, "くる動詞": .kuruVerb, "kuru verb": .kuruVerb,
        "transitive": .transitive, "他動詞": .transitive, "vt": .transitive,
        "intransitive": .intransitive, "自動詞": .intransitive, "vi": .intransitive,
        "i-adjective": .iAdjective, "adj-i": .iAdjective, "い形容詞": .iAdjective, "i-adj": .iAdjective,
        "na-adjective": .naAdjective, "adj-na": .naAdjective, "な形容詞": .naAdjective, "na-adj": .naAdjective,
        "adverb": .adverb, "副詞": .adverb, "adv": .adverb,
        "particle": .particle, "助詞": .particle,
        "auxiliary": .auxiliaryVerb, "auxiliary verb": .auxiliaryVerb, "助動詞": .auxiliaryVerb, "aux": .auxiliaryVerb,
        "conjunction": .conjunction, "接続詞": .conjunction, "conj": .conjunction,
        "interjection": .interjection, "感動詞": .interjection,
        "counter": .counter, "助数詞": .counter,
        "prefix": .prefix, "接頭詞": .prefix,
        "suffix": .suffix, "接尾詞": .suffix,
        "expression": .expression, "表現": .expression, "exp": .expression
    ]
}

// MARK: - 摘要类型

public struct ImportPrecheckSummary: Equatable, Sendable {
    public var totalRows = 0
    public var createCount = 0
    public var updateCount = 0
    public var conflictCount = 0
    public var invalidCount = 0
    public var inFileDuplicateCount = 0
    /// 前 N 条问题明细（invalid/conflict），供预览 UI。
    public var issues: [RowIssue] = []

    public struct RowIssue: Equatable, Sendable {
        public let logicalRow: Int
        public let rawLines: Range<Int>
        public let message: String

        public init(logicalRow: Int, rawLines: Range<Int>, message: String) {
            self.logicalRow = logicalRow
            self.rawLines = rawLines
            self.message = message
        }
    }
}

public struct ImportExecutionSummary: Equatable, Sendable {
    public let jobID: UUID
    public var status: ImportJobStatus
    public var totalRows = 0
    /// 本次运行新提交的 receipt 数 + 运行前已有 receipt 数 = 总行数。
    public var created = 0
    public var updated = 0
    public var mergedTags = 0
    public var skipped = 0
    public var failed = 0
    /// 续跑命中但 payload 不一致的行数（冲突，不改旧 receipt）。
    public var digestConflicts = 0
    /// 明细上限内的失败/跳过明细。
    public var rowDetails: [Detail] = []

    public struct Detail: Equatable, Sendable {
        public let logicalRow: Int
        public let action: ImportRowReceipt.Action
        public let reason: String?

        public init(logicalRow: Int, action: ImportRowReceipt.Action, reason: String?) {
            self.logicalRow = logicalRow
            self.action = action
            self.reason = reason
        }
    }

    public init(jobID: UUID, status: ImportJobStatus) {
        self.jobID = jobID
        self.status = status
    }
}

// MARK: - 执行器

public final class ImportExecutor: Sendable {
    private let pool: DatabasePool
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    /// 摘要/明细的内存上限（行级明细防 100k 行全量驻留）。
    public static let detailRowCap = 500

    public init(
        database: OboeDatabase,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        pool = database.pool
        self.now = now
        self.makeID = makeID
    }

    /// mapping 的确定性指纹（持久化到 import_jobs.mapping_hash；
    /// 映射变更 → hash 变 → 必须重建 plan，§10.3）。
    public static func mappingHash(_ mapping: ImportFieldMapping) -> String {
        let columns = mapping.columnToField
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.rawValue)" }
            .joined(separator: ";")
        let templates = mapping.newCardTemplates
            .map(\.rawValue).sorted().joined(separator: ",")
        let canonical = [
            columns,
            "tag=\(mapping.tagRule.rawValue)",
            "dup=\(mapping.duplicatePolicy.rawValue)",
            "empty=\(mapping.allowEmptyOverwrite)",
            "ex=\(mapping.exampleRule.rawValue)",
            "tmpl=\(templates)",
            "deck=\(mapping.targetDeckID.uuidString.lowercased())"
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 行 payload digest（receipt 幂等键的内容部分）。
    static func payloadDigest(of row: ImportLogicalRow) -> String {
        let payload = row.fields.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - 预检（dry-run）

    /// 全文件预检：只读业务库；verdict 写 staging `plan_rows`。
    /// 绝不写业务表——调用方可对 notes/cards 表计数断言零变更。
    public func precheck(
        mapping: ImportFieldMapping,
        staging: ImportStaging
    ) async throws -> ImportPrecheckSummary {
        try staging.clearPlan()
        var summary = ImportPrecheckSummary()
        var plannedKeys: [VocabularyDuplicateKey: Int] = [:]
        var cursor = try staging.makeReplayCursor()

        while let batch = try cursor.nextBatch() {
            try Task.checkCancellation()
            // 本批候选重复键 → 一次 IN 查询（避免逐行全表扫描）。
            var mappedBatch: [Result<MappedVocabularyRow, ImportRowMapper.MapError>] = []
            var headwords = Set<String>()
            for row in batch {
                let mapped = ImportRowMapper.map(fields: row.fields, mapping: mapping)
                mappedBatch.append(mapped)
                if case let .success(m) = mapped,
                   let key = m.duplicateKey,
                   plannedKeys[key] == nil {
                    headwords.insert(m.headword!)
                }
            }
            let existing = try await fetchVocabularyCandidates(
                headwords: headwords
            )

            var planRows: [ImportStaging.PlanRow] = []
            planRows.reserveCapacity(batch.count)
            for (index, row) in batch.enumerated() {
                summary.totalRows += 1
                let planRow = classify(
                    row: row,
                    mapped: mappedBatch[index],
                    mapping: mapping,
                    plannedKeys: &plannedKeys,
                    existing: existing
                )
                planRows.append(planRow)
                accumulate(&summary, planRow: planRow, row: row)
            }
            try staging.appendPlanRows(planRows)
        }
        return summary
    }

    private struct ExistingVocabularyMatch: Sendable {
        let noteID: UUID
        let contentVersion: Int
        let readingNormalized: String
    }

    /// 按 trim(headword) IN 批量取 vocabulary 候选；按重复键在内存中归组。
    private func fetchVocabularyCandidates(
        headwords: Set<String>
    ) async throws -> [VocabularyDuplicateKey: [ExistingVocabularyMatch]] {
        guard !headwords.isEmpty else { return [:] }
        return try await pool.read { db in
            var result: [VocabularyDuplicateKey: [ExistingVocabularyMatch]] = [:]
            // IN 列表分块，防 SQLite 变量上限（999）——每块 300。
            let chunks = Array(headwords).importChunked(into: 300)
            for chunk in chunks {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, trim(headword) AS hw,
                               COALESCE(trim(reading), '') AS rd,
                               content_version
                        FROM notes
                        WHERE kind = 'vocabulary'
                          AND trim(headword) IN (\(placeholders))
                        ORDER BY created_at_ms, id
                        """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    let headword: String = row["hw"]
                    let reading: String = row["rd"]
                    let key = VocabularyDuplicateKey(
                        kind: .vocabulary,
                        headword: headword,
                        reading: reading
                    )
                    result[key, default: []].append(ExistingVocabularyMatch(
                        noteID: try DatabaseValueCodec.decodeUUID(row["id"]),
                        contentVersion: row["content_version"],
                        readingNormalized: reading
                    ))
                }
            }
            return result
        }
    }

    private func classify(
        row: ImportLogicalRow,
        mapped: Result<MappedVocabularyRow, ImportRowMapper.MapError>,
        mapping: ImportFieldMapping,
        plannedKeys: inout [VocabularyDuplicateKey: Int],
        existing: [VocabularyDuplicateKey: [ExistingVocabularyMatch]]
    ) -> ImportStaging.PlanRow {
        switch mapped {
        case let .failure(error):
            return .init(
                logicalRow: row.logicalRowNumber,
                verdict: "invalid",
                reason: describe(error)
            )
        case let .success(mappedRow):
            guard let key = mappedRow.duplicateKey else {
                return .init(
                    logicalRow: row.logicalRowNumber,
                    verdict: "invalid",
                    reason: describe(.missingHeadword)
                )
            }
            if let first = plannedKeys[key] {
                return .init(
                    logicalRow: row.logicalRowNumber,
                    verdict: "inFileDuplicate",
                    reason: "与第 \(first) 行重复",
                    firstLogicalRow: first
                )
            }
            let matches = existing[key] ?? []
            switch matches.count {
            case 0:
                // create 候选：跑完整必填校验。
                if case let .failure(error) = ImportRowMapper.validatedContent(mappedRow) {
                    return .init(
                        logicalRow: row.logicalRowNumber,
                        verdict: "invalid",
                        reason: describe(error)
                    )
                }
                plannedKeys[key] = row.logicalRowNumber
                return .init(logicalRow: row.logicalRowNumber, verdict: "create")
            case 1:
                let match = matches[0]
                plannedKeys[key] = row.logicalRowNumber
                return .init(
                    logicalRow: row.logicalRowNumber,
                    verdict: "update",
                    targetNoteID: match.noteID,
                    expectedContentVersion: match.contentVersion
                )
            default:
                plannedKeys[key] = row.logicalRowNumber
                return .init(
                    logicalRow: row.logicalRowNumber,
                    verdict: "conflict",
                    reason: "同键命中 \(matches.count) 条既有 Note，待用户选择",
                    candidateNoteIDs: matches.map(\.noteID)
                )
            }
        }
    }

    private func accumulate(
        _ summary: inout ImportPrecheckSummary,
        planRow: ImportStaging.PlanRow,
        row: ImportLogicalRow
    ) {
        switch planRow.verdict {
        case "create": summary.createCount += 1
        case "update": summary.updateCount += 1
        case "conflict":
            summary.conflictCount += 1
            appendIssue(&summary, row: row, message: planRow.reason ?? "conflict")
        case "invalid":
            summary.invalidCount += 1
            appendIssue(&summary, row: row, message: planRow.reason ?? "invalid")
        case "inFileDuplicate": summary.inFileDuplicateCount += 1
        default: break
        }
    }

    private func appendIssue(
        _ summary: inout ImportPrecheckSummary,
        row: ImportLogicalRow,
        message: String
    ) {
        guard summary.issues.count < Self.detailRowCap else { return }
        summary.issues.append(.init(
            logicalRow: row.logicalRowNumber,
            rawLines: row.rawLineRange,
            message: message
        ))
    }

    private func describe(_ error: ImportRowMapper.MapError) -> String {
        switch error {
        case .missingHeadword: "缺少 headword（必填）"
        case let .invalidJLPT(v): "非法 JLPT: \(v)"
        case let .invalidPitchAccent(v): "非法音调: \(v)"
        case let .invalidTags(v): v
        case let .invalidTagName(v): "非法值: \(v)"
        case let .validation(e): "内容校验失败: \(e)"
        case .pitchAccentInconsistent: "音调超出读音 mora 数"
        }
    }

    // MARK: - 执行

    /// 分批提交。`isCancelled` 为协作式取消探针（UI 侧取消 flag），
    /// 与 `Task.isCancelled` 一起在批边界检查。`onBatchCommitted` 在每批
    /// 落库后回调累计 receipt 数（进度展示）。
    ///
    /// 前置：同一 staging 上已跑过 `precheck`（plan_rows 非空）。
    /// job 必须已存在于 import_jobs（状态 previewed/running/interrupted/
    /// cancelled 可进入执行；completed/failed 拒绝）。
    @discardableResult
    public func execute(
        jobID: UUID,
        mapping: ImportFieldMapping,
        staging: ImportStaging,
        isCancelled: (@Sendable () -> Bool)? = nil,
        onBatchCommitted: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> ImportExecutionSummary {
        guard let detail = try await fetchJobDetail(jobID) else {
            throw ImportExecutorError.jobNotFound
        }
        let runnable: Set<ImportJobStatus> = [.previewed, .running, .interrupted, .cancelled]
        guard runnable.contains(detail.job.status) else {
            throw ImportExecutorError.jobNotRunnable(status: detail.job.status)
        }
        guard detail.job.mappingHash == Self.mappingHash(mapping) else {
            throw ImportExecutorError.mappingHashMismatch
        }
        guard try staging.planRowCount() > 0 || staging.rowCount == 0 else {
            throw ImportExecutorError.precheckRequired
        }

        var summary = ImportExecutionSummary(jobID: jobID, status: .running)
        summary.totalRows = staging.rowCount

        // 续跑：已有 receipt 的行号 + digest（100k 条 < 数十 MB，可接受）。
        let existingReceipts = try await fetchReceiptDigests(jobID: jobID)
        var committedCount = existingReceipts.count

        try await setJobStatus(jobID, status: .running)

        var cancelled = false
        var cursor = try staging.makeReplayCursor()
        let receiptIndex = existingReceipts

        while let batch = try cursor.nextBatch() {
            if Task.isCancelled || (isCancelled?() ?? false) {
                cancelled = true
                break
            }
            let planRows = try staging.planRows(
                logicalRows: batch.map(\.logicalRowNumber)
            )
            let timestamp = try DatabaseValueCodec.encode(now())
            let committedBase = committedCount
            let executor = self

            struct BatchOutcome {
                var committedDelta = 0
                var created = 0, updated = 0, mergedTags = 0
                var skipped = 0, failed = 0, digestConflicts = 0
                var details: [ImportExecutionSummary.Detail] = []
            }

            let outcome: BatchOutcome = try await pool.write { db in
                var outcome = BatchOutcome()
                for row in batch {
                    let digest = Self.payloadDigest(of: row)
                    if let priorDigest = receiptIndex[row.logicalRowNumber] {
                        if priorDigest != digest {
                            outcome.digestConflicts += 1
                        }
                        continue // 已提交行跳过（§10.3 幂等回放）
                    }
                    guard let plan = planRows[row.logicalRowNumber] else {
                        continue // plan 缺失的行不算数（防御；precheck 已断言）
                    }
                    let action: ImportRowReceipt.Action
                    var targetNoteID: UUID?
                    var rowDetail: String?
                    do {
                        let applied = try executor.applyRow(
                            row: row,
                            plan: plan,
                            mapping: mapping,
                            job: detail.job,
                            timestamp: timestamp,
                            in: db
                        )
                        action = applied.action
                        targetNoteID = applied.targetNoteID
                        rowDetail = applied.detail
                    } catch {
                        // 领域/行级失败：回滚该行，记 failed receipt，批继续。
                        // （SAVEPOINT 在 applyRow 内部管理——此处 error 已是
                        //   行回滚后的领域错误。）
                        action = .failed
                        rowDetail = String(describing: error)
                    }
                    switch action {
                    case .created: outcome.created += 1
                    case .updated: outcome.updated += 1
                    case .mergedTags: outcome.mergedTags += 1
                    case .skipped: outcome.skipped += 1
                    case .failed: outcome.failed += 1
                    }
                    if rowDetail != nil || action == .failed || action == .skipped {
                        outcome.details.append(.init(
                            logicalRow: row.logicalRowNumber,
                            action: action,
                            reason: rowDetail
                        ))
                    }
                    try GRDBImportPlanRepository.insertReceipt(
                        ImportRowReceipt(
                            jobID: jobID,
                            logicalRowNumber: row.logicalRowNumber,
                            payloadDigest: digest,
                            action: action,
                            targetNoteID: targetNoteID
                        ),
                        detail: rowDetail,
                        createdAtMilliseconds: timestamp,
                        in: db
                    )
                    outcome.committedDelta += 1
                }
                try GRDBImportPlanRepository.setCommittedRows(
                    jobID: jobID,
                    committedRows: committedBase + outcome.committedDelta,
                    updatedAtMilliseconds: timestamp,
                    in: db
                )
                return outcome
            }

            committedCount += outcome.committedDelta
            summary.created += outcome.created
            summary.updated += outcome.updated
            summary.mergedTags += outcome.mergedTags
            summary.skipped += outcome.skipped
            summary.failed += outcome.failed
            summary.digestConflicts += outcome.digestConflicts
            for detailRow in outcome.details where summary.rowDetails.count < Self.detailRowCap {
                summary.rowDetails.append(detailRow)
            }
            await onBatchCommitted?(committedCount)
            if Task.isCancelled || (isCancelled?() ?? false) {
                cancelled = true
                break
            }
        }

        if cancelled {
            summary.status = .cancelled
            try await setJobStatus(jobID, status: .cancelled)
        } else {
            summary.status = .completed
            try await setJobStatus(jobID, status: .completed)
        }
        return summary
    }

    // MARK: - 单行应用（批事务内，SAVEPOINT 隔离）

    private struct RowOutcome {
        let action: ImportRowReceipt.Action
        var targetNoteID: UUID?
        var detail: String?
    }

    private func applyRow(
        row: ImportLogicalRow,
        plan: ImportStaging.PlanRow,
        mapping: ImportFieldMapping,
        job: ImportJob,
        timestamp: Int64,
        in db: Database
    ) throws -> RowOutcome {
        // 行级 SAVEPOINT：领域错误回滚该行已写入的部分，批不炸。
        let savepoint = "import_row_\(row.logicalRowNumber)"
        try db.execute(sql: "SAVEPOINT \(savepoint)")
        do {
            let outcome = try applyRowInner(
                row: row, plan: plan, mapping: mapping,
                job: job, timestamp: timestamp, in: db
            )
            try db.execute(sql: "RELEASE SAVEPOINT \(savepoint)")
            return outcome
        } catch {
            try db.execute(sql: "ROLLBACK TO SAVEPOINT \(savepoint)")
            try db.execute(sql: "RELEASE SAVEPOINT \(savepoint)")
            throw error
        }
    }

    private func applyRowInner(
        row: ImportLogicalRow,
        plan: ImportStaging.PlanRow,
        mapping: ImportFieldMapping,
        job: ImportJob,
        timestamp: Int64,
        in db: Database
    ) throws -> RowOutcome {
        switch plan.verdict {
        case "invalid":
            return RowOutcome(action: .failed, detail: plan.reason ?? "invalid")
        case "inFileDuplicate":
            return RowOutcome(
                action: .skipped,
                detail: plan.reason ?? "in-file duplicate"
            )
        case "conflict":
            // 未消解的冲突在执行期跳过（S18 消解后可改 target 重跑）。
            return RowOutcome(action: .skipped, detail: plan.reason)
        case "create":
            return try applyCreate(row: row, mapping: mapping, job: job, in: db)
        case "update":
            return try applyUpdate(
                row: row, plan: plan, mapping: mapping, job: job,
                timestamp: timestamp, in: db
            )
        default:
            return RowOutcome(action: .failed, detail: "unknown plan verdict")
        }
    }

    // MARK: create

    private func applyCreate(
        row: ImportLogicalRow,
        mapping: ImportFieldMapping,
        job: ImportJob,
        in db: Database
    ) throws -> RowOutcome {
        let mapped = try requireMapped(fields: row.fields, mapping: mapping)
        let content = try ImportRowMapper.validatedContent(mapped).get()
        let tags = try requireTags(mapped)
        let cards = mapping.newCardTemplates
            .sorted { $0.rawValue < $1.rawValue }
            .map { NewCardSeed(id: makeID(), templateKind: $0) }
        let commit = VocabularyContentCommit(
            noteID: makeID(),
            exampleID: makeID(),
            draftID: nil,
            deckID: job.targetDeckID,
            content: content,
            tags: tags,
            cards: cards,
            schedulerProfileID: makeID(),
            createdAt: now(),
            origin: .manual,
            deckIDs: [job.targetDeckID]
        )
        let result = try GRDBContentWriteExecutor.execute(
            .vocabulary(commit),
            capture: nil,
            in: db
        )
        return RowOutcome(action: .created, targetNoteID: result.noteID)
    }

    // MARK: update / mergeTags

    private func applyUpdate(
        row: ImportLogicalRow,
        plan: ImportStaging.PlanRow,
        mapping: ImportFieldMapping,
        job: ImportJob,
        timestamp: Int64,
        in db: Database
    ) throws -> RowOutcome {
        guard let targetID = plan.targetNoteID else {
            return RowOutcome(action: .failed, detail: "conflict unresolved")
        }
        let mapped = try requireMapped(fields: row.fields, mapping: mapping)
        guard let persisted = try fetchVocabularyRow(noteID: targetID, in: db) else {
            return RowOutcome(action: .failed, detail: "note deleted after precheck")
        }
        // §10.3 并发防线：预检快照与当前版本一致才允许覆盖。
        if let expected = plan.expectedContentVersion,
           persisted.contentVersion != expected {
            return RowOutcome(
                action: .failed,
                targetNoteID: targetID,
                detail: "contentVersionChanged(expected \(expected), actual \(persisted.contentVersion))——重新预览"
            )
        }

        switch job.policy {
        case .skip:
            // §10.2 skip：不写内容、不加 membership/tags。
            return RowOutcome(
                action: .skipped,
                targetNoteID: targetID,
                detail: "duplicate policy skip"
            )
        case .mergeTags:
            try attachMembership(noteID: targetID, deckID: job.targetDeckID, at: timestamp, in: db)
            let tags = try requireTags(mapped)
            try mergeTagUnion(tags: tags, noteID: targetID, at: timestamp, in: db)
            return RowOutcome(action: .mergedTags, targetNoteID: targetID)
        case .update:
            let tags = try requireTags(mapped)
            let changed = try applyVocabularyFieldUpdate(
                persisted: persisted,
                mapped: mapped,
                tags: tags,
                mapping: mapping,
                noteID: targetID,
                timestamp: timestamp,
                in: db
            )
            try attachMembership(noteID: targetID, deckID: job.targetDeckID, at: timestamp, in: db)
            if changed {
                try db.execute(
                    sql: """
                        UPDATE notes SET
                            content_version = content_version + 1,
                            updated_at_ms = ?
                        WHERE id = ?
                        """,
                    arguments: [timestamp, DatabaseValueCodec.encode(targetID)]
                )
            }
            return RowOutcome(action: .updated, targetNoteID: targetID)
        }
    }

    /// update 策略的字段级写入：仅映射且非空覆盖；`allowEmptyOverwrite`
    /// 时清可选列；例句按 exampleRule；tags 替换为该行的映射集合。
    /// 返回是否发生了内容变更（决定是否 bump content_version）。
    private func applyVocabularyFieldUpdate(
        persisted: PersistedVocabularySnapshot,
        mapped: MappedVocabularyRow,
        tags: [KnowledgeTag],
        mapping: ImportFieldMapping,
        noteID: UUID,
        timestamp: Int64,
        in db: Database
    ) throws -> Bool {
        var changed = false
        var sets: [String] = []
        var arguments: [DatabaseValueConvertible?] = []

        func offer(_ column: String, _ newValue: String?, _ oldValue: String?) {
            sets.append("\(column) = ?")
            arguments.append(newValue)
            if newValue != oldValue { changed = true }
        }
        func offerInt(_ column: String, _ newValue: Int?, _ oldValue: Int?) {
            sets.append("\(column) = ?")
            arguments.append(newValue)
            if newValue != oldValue { changed = true }
        }

        let allowEmpty = mapping.allowEmptyOverwrite
        // 必填列：仅非空覆盖（CHECK 不允许清空）。
        if let v = mapped.headword { offer("headword", v, persisted.headword) }
        if let v = mapped.meaningZH { offer("meaning_zh", v, persisted.meaningZH) }
        // 可选列：非空覆盖；映射空 + allowEmptyOverwrite → 清空。
        if let v = mapped.reading {
            offer("reading", v, persisted.reading)
        } else if allowEmpty, mapped.mappedEmptyFields.contains(.reading) {
            offer("reading", nil, persisted.reading)
        }
        if let v = mapped.partOfSpeech {
            offer("part_of_speech", v, persisted.partOfSpeech)
        } else if allowEmpty, mapped.mappedEmptyFields.contains(.partOfSpeech) {
            offer("part_of_speech", nil, persisted.partOfSpeech)
        }
        if let v = mapped.jlpt {
            offer("jlpt", v.rawValue, persisted.jlpt)
        } else if allowEmpty, mapped.mappedEmptyFields.contains(.jlpt) {
            offer("jlpt", nil, persisted.jlpt)
        }
        if let v = mapped.pitchAccent {
            // 读音一致性按有效读音复核（行内 reading 或既有值）。
            let effectiveReading = mapped.reading ?? persisted.reading
            guard v.isConsistent(withReading: effectiveReading) else {
                throw ImportApplyError.pitchAccentInconsistent
            }
            offerInt("pitch_accent", v.rawValue, persisted.pitchAccent)
        } else if allowEmpty, mapped.mappedEmptyFields.contains(.pitchAccent) {
            offerInt("pitch_accent", nil, persisted.pitchAccent)
        }
        if let v = mapped.notes {
            offer("notes", v, persisted.notes)
        } else if allowEmpty, mapped.mappedEmptyFields.contains(.notes) {
            offer("notes", nil, persisted.notes)
        }

        if !sets.isEmpty {
            sets.append("updated_at_ms = ?")
            arguments.append(timestamp)
            arguments.append(DatabaseValueCodec.encode(noteID))
            try db.execute(
                sql: "UPDATE notes SET \(sets.joined(separator: ", ")) WHERE id = ?",
                arguments: StatementArguments(arguments)
            )
        }

        // 例句：追加去重 / 替换主例句（都不清空 examples 表）。
        if let japanese = mapped.exampleJapanese {
            switch mapping.exampleRule {
            case .appendDeduplicated:
                let exists = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM examples
                            WHERE note_id = ? AND japanese = ?
                              AND COALESCE(translation_zh, '') = ?
                        )
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        japanese,
                        mapped.exampleTranslationZH ?? ""
                    ]
                ) == true
                if !exists {
                    let maxOrder = try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sort_order), -1) FROM examples WHERE note_id = ?",
                        arguments: [DatabaseValueCodec.encode(noteID)]
                    ) ?? -1
                    try db.execute(
                        sql: """
                            INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(makeID()),
                            DatabaseValueCodec.encode(noteID),
                            japanese,
                            mapped.exampleTranslationZH,
                            maxOrder + 1
                        ]
                    )
                    changed = true
                }
            case .replacePrimary:
                if let primaryID: String = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM examples WHERE note_id = ? ORDER BY sort_order, id LIMIT 1",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                ) {
                    try db.execute(
                        sql: "UPDATE examples SET japanese = ?, translation_zh = ? WHERE id = ?",
                        arguments: [japanese, mapped.exampleTranslationZH, primaryID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                            VALUES (?, ?, ?, ?, 0)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(makeID()),
                            DatabaseValueCodec.encode(noteID),
                            japanese,
                            mapped.exampleTranslationZH
                        ]
                    )
                }
                changed = true
            }
        }

        // tags 属映射字段：update 语义 = 替换为该行的标签集合。
        if mapped.mappedFields.contains(.tags) {
            try replaceTags(noteID: noteID, tags: tags, in: db)
            changed = true
        }
        return changed
    }

    private func attachMembership(
        noteID: UUID,
        deckID: UUID,
        at timestamp: Int64,
        in db: Database
    ) throws {
        try GRDBContentCardRepository.insertHomeMembership(
            noteID: noteID,
            deckID: deckID,
            atMilliseconds: timestamp,
            in: db
        )
    }

    /// mergeTags：标签并集（tags/note_tags 幂等插入），只 bump updated_at。
    private func mergeTagUnion(
        tags: [KnowledgeTag],
        noteID: UUID,
        at timestamp: Int64,
        in db: Database
    ) throws {
        for tag in tags {
            try db.execute(
                sql: """
                    INSERT INTO tags(id, name, normalized_name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(normalized_name) DO NOTHING
                    """,
                arguments: [
                    DatabaseValueCodec.encode(tag.id), tag.name, tag.normalizedName
                ]
            )
            guard let tagID: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE normalized_name = ?",
                arguments: [tag.normalizedName]
            ) else { continue }
            try db.execute(
                sql: """
                    INSERT INTO note_tags(note_id, tag_id)
                    VALUES (?, ?)
                    ON CONFLICT(note_id, tag_id) DO NOTHING
                    """,
                arguments: [DatabaseValueCodec.encode(noteID), tagID]
            )
        }
        try db.execute(
            sql: "UPDATE notes SET updated_at_ms = ? WHERE id = ?",
            arguments: [timestamp, DatabaseValueCodec.encode(noteID)]
        )
    }

    /// update 策略的 tags 替换（delete + insert）。
    private func replaceTags(
        noteID: UUID,
        tags: [KnowledgeTag],
        in db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM note_tags WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        for tag in tags {
            try db.execute(
                sql: """
                    INSERT INTO tags(id, name, normalized_name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(normalized_name) DO NOTHING
                    """,
                arguments: [
                    DatabaseValueCodec.encode(tag.id), tag.name, tag.normalizedName
                ]
            )
            guard let tagID: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE normalized_name = ?",
                arguments: [tag.normalizedName]
            ) else { continue }
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [DatabaseValueCodec.encode(noteID), tagID]
            )
        }
    }

    // MARK: - 读取辅助

    private struct PersistedVocabularySnapshot {
        let headword: String
        let reading: String?
        let meaningZH: String
        let partOfSpeech: String?
        let jlpt: String?
        let notes: String?
        let pitchAccent: Int?
        let contentVersion: Int
    }

    private func fetchVocabularyRow(
        noteID: UUID,
        in db: Database
    ) throws -> PersistedVocabularySnapshot? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT headword, reading, meaning_zh, part_of_speech,
                       jlpt, notes, pitch_accent, content_version
                FROM notes WHERE id = ? AND kind = 'vocabulary'
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        ).map { row in
            PersistedVocabularySnapshot(
                headword: row["headword"],
                reading: row["reading"],
                meaningZH: row["meaning_zh"],
                partOfSpeech: row["part_of_speech"],
                jlpt: row["jlpt"],
                notes: row["notes"],
                pitchAccent: row["pitch_accent"],
                contentVersion: row["content_version"]
            )
        }
    }

    private func requireMapped(
        fields: [String],
        mapping: ImportFieldMapping
    ) throws -> MappedVocabularyRow {
        switch ImportRowMapper.map(fields: fields, mapping: mapping) {
        case let .success(row): return row
        case let .failure(error): throw ImportApplyError.mappingFailed(describe(error))
        }
    }

    private func requireTags(_ mapped: MappedVocabularyRow) throws -> [KnowledgeTag] {
        switch ImportRowMapper.makeTags(mapped.tagNames, makeID: makeID) {
        case let .success(tags): return tags
        case let .failure(error): throw ImportApplyError.mappingFailed(describe(error))
        }
    }

    private func fetchJobDetail(
        _ jobID: UUID
    ) async throws -> GRDBImportPlanRepository.JobDetail? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM import_jobs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(jobID)]
            ) else { return nil }
            guard let job = try GRDBImportPlanRepository.decodeJobRow(row) else {
                return nil
            }
            let stagingFileName: String? = row["staging_file_name"]
            let stagingFingerprint: String? = row["staging_fingerprint"]
            let rowCount: Int? = row["row_count"]
            let committedRows: Int = row["committed_rows"]
            let mappingSummary: String? = row["mapping_summary"]
            let failureReason: String? = row["failure_reason"]
            return GRDBImportPlanRepository.JobDetail(
                job: job,
                stagingFileName: stagingFileName,
                stagingFingerprint: stagingFingerprint,
                rowCount: rowCount,
                committedRows: committedRows,
                mappingSummary: mappingSummary,
                failureReason: failureReason
            )
        }
    }

    private func fetchReceiptDigests(jobID: UUID) async throws -> [Int: String] {
        try await pool.read { db in
            var result: [Int: String] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT logical_row, payload_digest
                    FROM import_row_receipts WHERE job_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)]
            ) {
                result[row["logical_row"]] = row["payload_digest"]
            }
            return result
        }
    }

    private func setJobStatus(_ jobID: UUID, status: ImportJobStatus) async throws {
        try await pool.write { db in
            _ = try GRDBImportPlanRepository.updateJobStatus(
                id: jobID,
                status: status,
                updatedAtMilliseconds: DatabaseValueCodec.encode(Date()),
                in: db
            )
        }
    }
}

/// 行级领域错误（被 SAVEPOINT 隔离、记 failed receipt）。
enum ImportApplyError: Error {
    case validationFailed
    case mappingFailed(String)
    case pitchAccentInconsistent
}

private extension Array {
    /// 命名含 import 前缀：避免与其它 agent 并行落地的同名扩展撞车。
    func importChunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
