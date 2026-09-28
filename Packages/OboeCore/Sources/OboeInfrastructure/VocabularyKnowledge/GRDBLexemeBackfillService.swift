import Foundation
import GRDB
import OboeDomain

/// 回填使用的词典验证通道：ent_seq → 该条目的表记/读音集合 +
/// primary_form。S08 用它验证 `source_contexts.dictionary_entry_id`
/// 与 Note 的 headword/reading 是否一致（设计 §6.3 回填顺序第一档）。
public struct LexemeEntrySurface: Equatable, Sendable {
    public let entryID: Int64
    public let primaryForm: String
    public let normalizedForms: Set<String>
    public let normalizedReadings: Set<String>

    public init(
        entryID: Int64,
        primaryForm: String,
        normalizedForms: Set<String>,
        normalizedReadings: Set<String>
    ) {
        self.entryID = entryID
        self.primaryForm = primaryForm
        self.normalizedForms = normalizedForms
        self.normalizedReadings = normalizedReadings
    }
}

public protocol LexemeEntryVerifier: Sendable {
    /// 批量取条目表记/读音；不存在的 entryID 不出现在结果里
    /// （词典更新后 entry 撤销即按「验证失败」回落严格匹配档）。
    func entrySurfaces(
        entryIDs: [Int64]
    ) async throws -> [Int64: LexemeEntrySurface]
    /// 词典 dataset 版本（写进 lexeme 的 provenance 列）。
    func datasetVersion() async throws -> String?
}

/// GRDB 实现：查询词典库 forms/readings/entries（同一 schema 形状
/// 与 `GRDBMorphologyCandidateResolver`/`MorphologyTestSupport` 共享）。
public struct GRDBLexemeEntryVerifier: LexemeEntryVerifier {
    private let reader: any DatabaseReader
    private let version: String?

    public init(reader: any DatabaseReader, datasetVersion: String? = nil) {
        self.reader = reader
        self.version = datasetVersion
    }

    public func entrySurfaces(
        entryIDs: [Int64]
    ) async throws -> [Int64: LexemeEntrySurface] {
        let unique = Array(Set(entryIDs)).sorted()
        guard !unique.isEmpty else { return [:] }
        return try await reader.read { db in
            var result: [Int64: LexemeEntrySurface] = [:]
            for chunk in unique.chunked(400) {
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                let args = StatementArguments(Array(chunk))
                var forms: [Int64: Set<String>] = [:]
                var readings: [Int64: Set<String>] = [:]
                var primary: [Int64: String] = [:]
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, primary_form FROM entries
                        WHERE id IN (\(placeholders))
                        """,
                    arguments: args
                ) {
                    primary[row["id"]] = row["primary_form"]
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, normalized_text FROM forms
                        WHERE entry_id IN (\(placeholders))
                        """,
                    arguments: args
                ) {
                    forms[row["entry_id"], default: []]
                        .insert(row["normalized_text"])
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, normalized_reading FROM readings
                        WHERE entry_id IN (\(placeholders))
                        """,
                    arguments: args
                ) {
                    readings[row["entry_id"], default: []]
                        .insert(row["normalized_reading"])
                }
                for entryID in chunk {
                    guard let primaryForm = primary[entryID] else { continue }
                    result[entryID] = LexemeEntrySurface(
                        entryID: entryID,
                        primaryForm: primaryForm,
                        normalizedForms: forms[entryID] ?? [],
                        normalizedReadings: readings[entryID] ?? []
                    )
                }
            }
            return result
        }
    }

    public func datasetVersion() async throws -> String? {
        if let version { return version }
        return try await reader.read { db in
            guard try db.tableExists("dictionary_metadata") else { return nil }
            let rows = try Row.fetchAll(
                db, sql: "SELECT key, value FROM dictionary_metadata")
            var values: [String: String] = [:]
            for row in rows { values[row["key"]] = row["value"] }
            return values["dataset_version"] ?? values["dictionary_version"]
        }
    }
}

/// 一次回填运行的统计快照（receipt 的 result_json 同源字段）。
public struct LexemeBackfillSummary: Equatable, Sendable {
    /// 扫描的 vocabulary Note 总数。
    public var scanned: Int = 0
    /// 新建 jmdict 关联（SourceContext 验证 + 严格唯一候选两档合计）。
    public var linkedJmdict: Int = 0
    /// 落到 local 占位 lexeme（无候选 unresolved / 多候选 ambiguous）。
    public var linkedLocalUnresolved: Int = 0
    public var linkedLocalAmbiguous: Int = 0
    /// 已有 link、本次跳过（幂等证据）。
    public var skippedAlreadyLinked: Int = 0
    /// 扫描期间被删除的 Note。
    public var skippedDeleted: Int = 0
    /// 本次使用的 operation_id（回放时复用）。
    public var operationID: UUID
    /// true = 命中既有 receipt 直接回放，未执行扫描。
    public var replayedReceipt: Bool = false

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

/// S08 旧 Note → lexeme 高置信回填（设计 §6.3「旧 Note 回填」 +
/// 计划 S08 验收）。**不是迁移内步骤**——迁移函数只建表；
/// 回填作为独立幂等服务运行，原因：①严格匹配档要访问独立的词典
/// sqlite，不能在迁移事务里跨界；②可取消/可重跑要求它跑在普通
/// 连接而不是 migration 连接；③分批提交避免长事务。
///
/// 每 Note 决策序（与 §6.3 一致）：
/// 1. `source_contexts.dictionary_entry_id` + 表记/读音验证 → jmdict；
/// 2. headword 严格匹配恰一条词典候选（entry 级去重）→ jmdict；
///    多候选时若 Note 读音能唯一区分 → jmdict（同形异音处理）；
/// 3. 其余 → local lexeme（`unresolved` = 无候选，`.ambiguous` =
///    多候选待用户确认）+ 照常关联——有 Note 即 learning，
///    「待确认」由 lexeme.resolution_status 承载。
///
/// 幂等：已存在 link 的 Note 直接跳过；lexeme 按 identity_key
/// upsert 不重建 UUID；同 operationID 重跑回放 receipt。
/// 批次粒度一事务；取消发生在批间，已提交批次不回滚，重跑续接。
public actor LexemeBackfillService {
    /// 回填规则版本——receipt 与报告引用；规则变更 bump。
    public static let backfillVersion = "v18-backfill-1"
    public static let defaultBatchSize = 200

    private let pool: DatabasePool
    private let resolver: any MorphologyCandidateResolver
    private let verifier: any LexemeEntryVerifier
    private let batchSize: Int
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        pool: DatabasePool,
        resolver: any MorphologyCandidateResolver,
        verifier: any LexemeEntryVerifier,
        batchSize: Int = defaultBatchSize,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.pool = pool
        self.resolver = resolver
        self.verifier = verifier
        self.batchSize = batchSize
        self.now = now
        self.makeID = makeID
    }

    /// 跑一轮回填。`operationID` 为空时生成新 id；传入已完成的
    /// opID 直接回放其 receipt（不扫库）。
    @discardableResult
    public func run(operationID: UUID? = nil) async throws -> LexemeBackfillSummary {
        let opID = operationID ?? makeID()
        // receipt 回放：同 opID 已完成 → 返回存储的结果，不新增写。
        if let receipt = try await pool.read({ db in
            try GRDBReaderActivityStore.fetchKnowledgeReceipt(
                operationID: opID, in: db)
        }), receipt.kind == "lexeme_backfill" {
            var summary = LexemeBackfillSummary(operationID: opID)
            summary.replayedReceipt = true
            return summary
        }

        var summary = LexemeBackfillSummary(operationID: opID)
        let dictionaryVersion = try await verifier.datasetVersion()
        var cursor: String? = nil

        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(after: cursor)
            guard !page.isEmpty else { break }
            cursor = page.last?.id

            // —— 词典侧读取（不进写事务）——
            let surfaces = try await verifier.entrySurfaces(
                entryIDs: page.compactMap(\.contextEntryID))
            let needsStrict = page.filter { note in
                guard let entryID = note.contextEntryID,
                      let surface = surfaces[entryID] else { return true }
                return !Self.verify(
                    note: note, surface: surface)
            }
            let candidateSets = try await resolver.resolveCandidates(
                needsStrict.map {
                    SpanCandidates(
                        surface: $0.headword,
                        normalizedForms: [
                            SearchTextNormalizer.normalize($0.headword)
                        ],
                        deinflections: []
                    )
                })
            let strictResults = Dictionary(
                uniqueKeysWithValues: zip(
                    needsStrict.map(\.id), candidateSets))

            // —— 单事务提交本批 ——
            let atMs = try DatabaseValueCodec.encode(now())
            let batch = try await pool.write { db -> BatchCounts in
                var batch = BatchCounts()
                // 读/写之间被删的 Note 排除（FK 兜底之上的明确语义）。
                let liveIDs = Set(try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM notes
                        WHERE id IN (\(Self.placeholders(page.count)))
                        """,
                    arguments: StatementArguments(page.map(\.id))
                ))
                for note in page where liveIDs.contains(note.id) {
                    if try Self.hasLink(noteID: note.id, in: db) {
                        batch.skippedAlreadyLinked += 1
                        continue
                    }
                    let decision = Self.decide(
                        note: note,
                        contextSurface: note.contextEntryID
                            .flatMap { surfaces[$0] },
                        strictCandidates: strictResults[note.id],
                        dictionaryVersion: dictionaryVersion,
                        at: DatabaseValueCodec.decodeDate(milliseconds: atMs),
                        makeID: makeID
                    )
                    switch decision {
                    case let .jmdict(lexeme, confidence):
                        try Self.upsertLexeme(lexeme, in: db)
                        try Self.insertLink(
                            lexemeID: lexeme.id, noteUUID: note.id,
                            origin: .backfill, confidence: confidence,
                            atMs: atMs, in: db)
                        batch.linkedJmdict += 1
                    case let .local(lexeme, status):
                        try Self.upsertLexeme(lexeme, in: db)
                        try Self.insertLink(
                            lexemeID: lexeme.id, noteUUID: note.id,
                            origin: .backfill, confidence: 0.3,
                            atMs: atMs, in: db)
                        if status == .ambiguous {
                            batch.linkedLocalAmbiguous += 1
                        } else {
                            batch.linkedLocalUnresolved += 1
                        }
                    }
                    batch.scanned += 1
                }
                batch.skippedDeleted = page.count - liveIDs.count
                return batch
            }
            summary.scanned += batch.scanned
            summary.linkedJmdict += batch.linkedJmdict
            summary.linkedLocalUnresolved += batch.linkedLocalUnresolved
            summary.linkedLocalAmbiguous += batch.linkedLocalAmbiguous
            summary.skippedAlreadyLinked += batch.skippedAlreadyLinked
            summary.skippedDeleted += batch.skippedDeleted
        }

        // 完成 receipt（取消路径不写——重跑同 opID 视为续跑而非回放）。
        let resultJSON = GRDBVocabularyKnowledgeRepository.jsonObject([
            "backfill_version": Self.backfillVersion,
            "scanned": summary.scanned,
            "linked_jmdict": summary.linkedJmdict,
            "linked_local_unresolved": summary.linkedLocalUnresolved,
            "linked_local_ambiguous": summary.linkedLocalAmbiguous,
            "skipped_already_linked": summary.skippedAlreadyLinked,
            "skipped_deleted": summary.skippedDeleted,
        ])
        try await pool.write { db in
            try GRDBReaderActivityStore.recordReceipt(
                operationID: opID, kind: "lexeme_backfill",
                payloadHash: GRDBReaderActivityStore.payloadHash(
                    "lexeme_backfill|\(Self.backfillVersion)"),
                resultJSON: resultJSON, at: now(), in: db
            )
        }
        return summary
    }

    // MARK: - 决策

    private enum Decision {
        case jmdict(lexeme: Lexeme, confidence: Double)
        case local(lexeme: Lexeme, status: TokenResolutionStatus)
    }

    /// 单批计数——pool.write 闭包的返回值，避免 @Sendable 闭包
    /// 捕获并修改外层 summary。
    private struct BatchCounts: Sendable {
        var scanned = 0
        var linkedJmdict = 0
        var linkedLocalUnresolved = 0
        var linkedLocalAmbiguous = 0
        var skippedAlreadyLinked = 0
        var skippedDeleted = 0
    }

    private struct NoteRow: Sendable {
        let id: String
        let headword: String
        let reading: String?
        let partOfSpeech: String?
        let contextEntryID: Int64?
        let contextDictionaryVersion: String?
    }

    private static func verify(
        note: NoteRow,
        surface: LexemeEntrySurface
    ) -> Bool {
        let headwordOK = surface.normalizedForms.contains(
            SearchTextNormalizer.normalize(note.headword))
        guard headwordOK else { return false }
        // Note 有读音时读音也必须命中——同形异音的主要防线。
        if let reading = note.reading,
           !SearchTextNormalizer.normalize(reading).isEmpty {
            return surface.normalizedReadings.contains(
                SearchTextNormalizer.normalize(reading))
        }
        return true
    }

    private static func decide(
        note: NoteRow,
        contextSurface: LexemeEntrySurface?,
        strictCandidates: [MorphologyCandidate]?,
        dictionaryVersion: String?,
        at date: Date,
        makeID: @Sendable () -> UUID
    ) -> Decision {
        // 档 1：SourceContext ent_seq 验证通过。
        if let contextSurface,
           verify(note: note, surface: contextSurface) {
            let key = LexicalIdentityKey.jmdict(
                entryID: contextSurface.entryID,
                normalizedForm: SearchTextNormalizer.normalize(
                    contextSurface.primaryForm),
                reading: note.reading
            )
            return .jmdict(
                lexeme: Lexeme(
                    id: makeID(), key: key,
                    writtenForm: contextSurface.primaryForm,
                    reading: note.reading,
                    normalizedLemma: SearchTextNormalizer.normalize(
                        contextSurface.primaryForm),
                    posFamily: note.partOfSpeech,
                    dictionaryVersionAtResolution:
                        note.contextDictionaryVersion ?? dictionaryVersion,
                    resolutionStatus: .resolved,
                    createdAt: date
                ),
                confidence: 1.0
            )
        }

        // 档 2：严格唯一候选（同形异音用 Note 读音消歧）。
        if let strictCandidates {
            let hits = strictCandidates.filter { $0.cost == 0 && $0.entryID != nil }
            var distinct: [Int64: MorphologyCandidate] = [:]
            for hit in hits { distinct[hit.entryID!] = distinct[hit.entryID!] ?? hit }
            var chosen = distinct.count == 1 ? distinct.values.first : nil
            if chosen == nil, distinct.count > 1, let reading = note.reading {
                let norm = SearchTextNormalizer.normalize(reading)
                let byReading = distinct.values.filter {
                    SearchTextNormalizer.normalize($0.reading ?? "") == norm
                }
                if byReading.count == 1 { chosen = byReading.first }
            }
            if let chosen, let entryID = chosen.entryID {
                let key = LexicalIdentityKey.jmdict(
                    entryID: entryID,
                    normalizedForm: chosen.normalizedForm,
                    reading: chosen.reading ?? note.reading
                )
                return .jmdict(
                    lexeme: Lexeme(
                        id: makeID(), key: key,
                        writtenForm: chosen.lemma,
                        reading: chosen.reading ?? note.reading,
                        normalizedLemma: chosen.normalizedForm,
                        posFamily: chosen.posCodes.first ?? note.partOfSpeech,
                        dictionaryVersionAtResolution: dictionaryVersion,
                        resolutionStatus: .resolved,
                        createdAt: date
                    ),
                    confidence: 0.9
                )
            }
            // 多候选 → local + ambiguous（待确认）；无候选 → unresolved。
            let status: TokenResolutionStatus =
                distinct.count > 1 ? .ambiguous : .unresolved
            return .local(
                lexeme: localLexeme(for: note, status: status, at: date, makeID: makeID),
                status: status
            )
        }

        // 档 3（context 验证失败的 note 已经过档 2 严格匹配——
        // 走到这里说明严格匹配也进不了 jmdict，由上面的 local 分支
        // 处理；此 return 只是编译器可见的兜底）。
        return .local(
            lexeme: localLexeme(for: note, status: .unresolved, at: date, makeID: makeID),
            status: .unresolved
        )
    }

    private static func localLexeme(
        for note: NoteRow,
        status: TokenResolutionStatus,
        at date: Date,
        makeID: @Sendable () -> UUID
    ) -> Lexeme {
        let key = LexicalIdentityKey.local(
            writtenForm: note.headword,
            reading: note.reading,
            posFamily: note.partOfSpeech
        )
        return Lexeme(
            id: makeID(), key: key,
            writtenForm: note.headword,
            reading: note.reading,
            normalizedLemma: SearchTextNormalizer.normalize(note.headword),
            posFamily: note.partOfSpeech,
            dictionaryVersionAtResolution: nil,
            resolutionStatus: status,
            createdAt: date
        )
    }

    // MARK: - SQL 细节

    /// 仍无 link 的 vocabulary Note 页（id 游标分页，写前过滤已关联）。
    private func fetchPage(after cursor: String?) async throws -> [NoteRow] {
        try await pool.read { db in
            let sql = """
                SELECT n.id, n.headword, n.reading, n.part_of_speech,
                       (SELECT sc.dictionary_entry_id FROM source_contexts sc
                        WHERE sc.note_id = n.id
                          AND sc.dictionary_entry_id IS NOT NULL
                        ORDER BY sc.is_primary DESC, sc.created_at_ms
                        LIMIT 1) AS dictionary_entry_id,
                       (SELECT sc.dictionary_version FROM source_contexts sc
                        WHERE sc.note_id = n.id
                          AND sc.dictionary_entry_id IS NOT NULL
                        ORDER BY sc.is_primary DESC, sc.created_at_ms
                        LIMIT 1) AS dictionary_version
                FROM notes n
                WHERE n.kind = 'vocabulary'
                    AND NOT EXISTS (
                        SELECT 1 FROM lexeme_note_links l
                        WHERE l.note_id = n.id)
                    \(cursor == nil ? "" : "AND n.id > ?")
                ORDER BY n.id
                LIMIT \(batchSize)
                """
            let arguments: StatementArguments =
                cursor == nil ? [] : StatementArguments([cursor!])
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
                NoteRow(
                    id: $0["id"],
                    headword: $0["headword"],
                    reading: $0["reading"],
                    partOfSpeech: $0["part_of_speech"],
                    contextEntryID: $0["dictionary_entry_id"],
                    contextDictionaryVersion: $0["dictionary_version"]
                )
            }
        }
    }

    private static func hasLink(noteID: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM lexeme_note_links WHERE note_id = ?)
                """,
            arguments: [noteID]
        ) ?? false
    }

    private static func upsertLexeme(_ lexeme: Lexeme, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO lexemes(
                    id, provider, external_id, entry_id,
                    written_form, reading, normalized_lemma, pos_family,
                    identity_key, dictionary_version_at_resolution,
                    resolution_status, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(identity_key) DO NOTHING
                """,
            arguments: [
                DatabaseValueCodec.encode(lexeme.id),
                lexeme.key.provider.rawValue,
                lexeme.key.externalID,
                lexeme.key.provider == .jmdict
                    ? Int64(lexeme.key.externalID) : nil,
                lexeme.writtenForm,
                lexeme.reading,
                lexeme.normalizedLemma,
                lexeme.posFamily,
                lexeme.key.identityKey,
                lexeme.dictionaryVersionAtResolution,
                lexeme.resolutionStatus.rawValue,
                try DatabaseValueCodec.encode(lexeme.createdAt)
            ]
        )
    }

    private static func insertLink(
        lexemeID: UUID,
        noteUUID: String,
        origin: LexemeNoteLink.AssociationOrigin,
        confidence: Double?,
        atMs: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO lexeme_note_links(
                    lexeme_id, note_id, association_origin,
                    confidence, created_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(lexeme_id, note_id) DO NOTHING
                """,
            arguments: [
                DatabaseValueCodec.encode(lexemeID),
                noteUUID,
                origin.rawValue,
                confidence,
                atMs
            ]
        )
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
