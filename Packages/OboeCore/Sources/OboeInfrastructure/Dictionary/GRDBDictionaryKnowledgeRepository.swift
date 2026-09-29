import Foundation
import GRDB
import OboeDomain

/// S19 v22 词典知识仓储（app 库侧）：
/// - `dictionary_artifact_records` 台账：词典产物 checksum/版本
///   核验记录（file_sha256 UNIQUE——同字节产物复验只更新
///   `last_verified_at_ms`）；
/// - `lexeme_dictionary_bindings`：lexeme→entry 分层绑定
///   （match_tier/status/dataset_version），换库重绑的读写面；
/// - `DictionaryEntryKnowledgeStates`：词典搜索命中的知识态批量
///   标注（entry → jmdict lexeme → 真值表）——
///   `DictionaryLookupSession` 的 seam 实现。
///
/// 与词典侧仓储的分界：本类型只写 app 库；词典产物永远只读。
public final class GRDBDictionaryKnowledgeRepository: @unchecked Sendable {

    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    // MARK: - artifact 台账

    /// 记录一次产物核验。同 `file_sha256` 已存在 → 更新版本列与
    /// `last_verified_at_ms`（字节级身份不变语义版本可比换绑判定）。
    @discardableResult
    public func recordArtifactVerification(
        _ descriptor: DictionaryArtifactDescriptor,
        status: ArtifactVerificationStatus,
        at date: Date,
        recordID: UUID = UUID()
    ) async throws -> UUID {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            let encoded = DatabaseValueCodec.encode(recordID)
            try db.execute(
                sql: """
                    INSERT INTO dictionary_artifact_records(
                        id, file_sha256, byte_count, schema_version,
                        dataset_version, dictionary_version,
                        chinese_layer_version, zh_alignment_rate,
                        verification_status,
                        first_seen_at_ms, last_verified_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(file_sha256) DO UPDATE SET
                        dataset_version = excluded.dataset_version,
                        dictionary_version = excluded.dictionary_version,
                        chinese_layer_version = excluded.chinese_layer_version,
                        zh_alignment_rate = excluded.zh_alignment_rate,
                        verification_status = excluded.verification_status,
                        last_verified_at_ms = excluded.last_verified_at_ms
                    """,
                arguments: [
                    encoded, descriptor.fileSHA256, descriptor.byteCount,
                    descriptor.schemaVersion, descriptor.datasetVersion,
                    descriptor.dictionaryVersion,
                    descriptor.chineseLayerVersion, descriptor.zhAlignmentRate,
                    status.rawValue, atMs, atMs,
                ]
            )
            // 冲突时 id 不变：读回真实 id。
            let id: String = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM dictionary_artifact_records
                    WHERE file_sha256 = ?
                    """,
                arguments: [descriptor.fileSHA256]
            )!
            return try DatabaseValueCodec.decodeUUID(id)
        }
    }

    /// 最近一次核验记录（换库检测的参照点）。
    public func latestArtifactRecord() async throws -> ArtifactRecord? {
        try await pool.read { db in
            try Self.fetchArtifactRows(
                db,
                sql: """
                    SELECT * FROM dictionary_artifact_records
                    ORDER BY last_verified_at_ms DESC, id DESC LIMIT 1
                    """)
            .first
        }
    }

    /// 全部核验历史（按核验时间降序）。
    public func artifactHistory() async throws -> [ArtifactRecord] {
        try await pool.read { db in
            try Self.fetchArtifactRows(
                db,
                sql: """
                    SELECT * FROM dictionary_artifact_records
                    ORDER BY last_verified_at_ms DESC, id DESC
                    """)
        }
    }

    // MARK: - 绑定读写

    /// 新解析结果落绑定（新 lexeme 首次解析/用户确认时调用）。
    /// 已存在绑定：更新 entry/tier/status/updated_at，
    /// `resolved_at` 保留首解析时间。
    public func upsertBinding(
        _ record: LexemeBindingRecord
    ) async throws {
        try await pool.write { db in
            try Self.insertBinding(record, in: db)
        }
    }

    public func binding(lexemeID: UUID) async throws -> LexemeBindingRecord? {
        try await pool.read { db in
            try Self.fetchBinding(lexemeID: lexemeID, in: db)
        }
    }

    /// 绑定版本 != 当前 dataset 的页（换库后待重绑集合），
    /// lexeme_id 游标分页。
    public func bindingsNeedingReverify(
        currentDatasetVersion: String,
        after cursor: UUID?,
        limit: Int
    ) async throws -> [BoundLexeme] {
        try await pool.read { db in
            let sql = """
                SELECT b.lexeme_id, b.entry_id, b.match_tier,
                       b.dataset_version, b.status, b.detail,
                       b.resolved_at_ms, b.updated_at_ms,
                       l.written_form, l.reading, l.normalized_lemma
                FROM lexeme_dictionary_bindings b
                JOIN lexemes l ON l.id = b.lexeme_id
                WHERE b.dataset_version != ?
                \(cursor == nil ? "" : "AND b.lexeme_id > ?")
                ORDER BY b.lexeme_id
                LIMIT \(max(1, limit))
                """
            let arguments: StatementArguments = cursor == nil
                ? StatementArguments([currentDatasetVersion])
                : StatementArguments([
                    currentDatasetVersion,
                    DatabaseValueCodec.encode(cursor!),
                ])
            return try Row.fetchAll(db, sql: sql, arguments: arguments)
                .map(Self.decodeBoundLexeme)
        }
    }

    /// 无绑定行的存量 jmdict lexeme（v22 前建立——只能
    /// `verifiedExisting` 核验）。lexeme_id 游标分页。
    public func unboundJMDictLexemes(
        after cursor: UUID?,
        limit: Int
    ) async throws -> [BoundLexeme] {
        try await pool.read { db in
            let sql = """
                SELECT l.id AS lexeme_id, l.entry_id,
                       l.written_form, l.reading, l.normalized_lemma,
                       l.dictionary_version_at_resolution,
                       l.created_at_ms
                FROM lexemes l
                WHERE l.provider = 'jmdict' AND l.entry_id IS NOT NULL
                  AND NOT EXISTS(
                      SELECT 1 FROM lexeme_dictionary_bindings b
                      WHERE b.lexeme_id = l.id)
                \(cursor == nil ? "" : "AND l.id > ?")
                ORDER BY l.id
                LIMIT \(max(1, limit))
                """
            let arguments: StatementArguments = cursor == nil
                ? [] : StatementArguments([DatabaseValueCodec.encode(cursor!)])
            return try Row.fetchAll(db, sql: sql, arguments: arguments)
                .map(Self.decodeUnboundLexeme)
        }
    }

    /// 同事务应用重绑决策：
    /// - `current`：status=current、dataset_version=新版、清 detail；
    /// - `rebound`：binding.entry_id 与 `lexemes.entry_id` 同步换到新
    ///   ent_seq，status=current，detail 记 `rebound:<old>`；
    /// - `stale`/`ambiguous`：保留旧 entry_id 与**旧**
    ///   dataset_version（下一轮换库仍可重试），只标 status+detail。
    /// 调用方须保证该 lexeme 的绑定行已存在（服务侧 upsert 先行）。
    public func applyRebindDecision(
        lexemeID: UUID,
        decision: LexemeRebindDecision,
        newDatasetVersion: String,
        at date: Date
    ) async throws {
        let encoded = DatabaseValueCodec.encode(lexemeID)
        let atMs = try DatabaseValueCodec.encode(date)
        try await pool.write { db in
            switch decision {
            case .current:
                try db.execute(
                    sql: """
                        UPDATE lexeme_dictionary_bindings
                        SET status = 'current', detail = NULL,
                            dataset_version = ?, updated_at_ms = ?
                        WHERE lexeme_id = ?
                        """,
                    arguments: [newDatasetVersion, atMs, encoded])
            case let .rebound(newEntryID):
                let old: Int64? = try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT entry_id FROM lexeme_dictionary_bindings
                        WHERE lexeme_id = ?
                        """,
                    arguments: [encoded])
                try db.execute(
                    sql: """
                        UPDATE lexeme_dictionary_bindings
                        SET entry_id = ?, status = 'current',
                            detail = ?, dataset_version = ?,
                            updated_at_ms = ?
                        WHERE lexeme_id = ?
                        """,
                    arguments: [
                        newEntryID, "rebound:\(old ?? -1)",
                        newDatasetVersion, atMs, encoded,
                    ])
                // 绑定表与 lexemes.entry_id 同事务同步。
                try db.execute(
                    sql: """
                        UPDATE lexemes SET entry_id = ? WHERE id = ?
                        """,
                    arguments: [newEntryID, encoded])
            case let .stale(detail):
                try db.execute(
                    sql: """
                        UPDATE lexeme_dictionary_bindings
                        SET status = 'stale', detail = ?, updated_at_ms = ?
                        WHERE lexeme_id = ?
                        """,
                    arguments: [detail, atMs, encoded])
            case let .ambiguous(candidateIDs):
                // detail 有界：候选 id 列表截断（防极端歧义撑爆列）。
                let detail = "ambiguous:\(candidateIDs.count):"
                    + candidateIDs.prefix(16).map(String.init)
                        .joined(separator: ",")
                try db.execute(
                    sql: """
                        UPDATE lexeme_dictionary_bindings
                        SET status = 'ambiguousAwaiting', detail = ?,
                            updated_at_ms = ?
                        WHERE lexeme_id = ?
                        """,
                    arguments: [detail, atMs, encoded])
            }
        }
    }

    // MARK: - 知识态标注（DictionaryEntryKnowledgeStates）

    /// entry_id 批量 → 知识态：`lexemes.provider='jmdict' AND
    /// entry_id IN (…)` 取 lexeme，再按真值表（override + 有效
    /// vocabulary-note 关联计数）批量解析。无 lexeme 的 entry
    /// 不在结果中（调用方记 unknown）。
    public func knowledgeStates(
        forEntryIDs entryIDs: [Int64]
    ) async throws -> [Int64: VocabularyKnowledgeState] {
        let unique = Array(Set(entryIDs)).sorted()
        guard !unique.isEmpty else { return [:] }
        return try await pool.read { db in
            var lexemeByEntry: [Int64: UUID] = [:]
            for chunk in unique.chunked(400) {
                let p = Self.placeholders(chunk.count)
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, entry_id FROM lexemes
                        WHERE provider = 'jmdict'
                          AND entry_id IN (\(p))
                        """,
                    arguments: StatementArguments(Array(chunk))) {
                    let idString: String = row["id"]
                    if let uuid = try? DatabaseValueCodec.decodeUUID(idString) {
                        // 同 entry 多 lexeme（同形异读各一）取首个——
                        // 标注语义是"该词目有无学习状态"，任一已关联即算。
                        if lexemeByEntry[row["entry_id"]] == nil {
                            lexemeByEntry[row["entry_id"]] = uuid
                        }
                    }
                }
            }
            guard !lexemeByEntry.isEmpty else { return [:] }
            // D19：词级态唯一真值 = learning unit flags/links——
            // `vocabulary_knowledge_overrides` 仅供 v8 导入/兼容
            // 审计，运行态永不读取。
            let states = try GRDBVocabularyKnowledgeRepository
                .wordKnowledgeStates(
                    lexemeIDs: Array(lexemeByEntry.values), in: db)
            var result: [Int64: VocabularyKnowledgeState] = [:]
            for (entryID, lexemeID) in lexemeByEntry {
                result[entryID] = states[lexemeID] ?? .unknown
            }
            return result
        }
    }

    // MARK: - 行解码 / 共享写

    /// 绑定行 upsert（服务在组合事务里复用——resolved_at 只在
    /// 首次插入时写入，冲突更新不回溯）。
    static func insertBinding(
        _ record: LexemeBindingRecord, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO lexeme_dictionary_bindings(
                    lexeme_id, entry_id, match_tier, dataset_version,
                    status, detail, resolved_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(lexeme_id) DO UPDATE SET
                    entry_id = excluded.entry_id,
                    match_tier = excluded.match_tier,
                    dataset_version = excluded.dataset_version,
                    status = excluded.status,
                    detail = excluded.detail,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                DatabaseValueCodec.encode(record.lexemeID),
                record.entryID, record.tier.rawValue, record.datasetVersion,
                record.status.rawValue, record.detail,
                try DatabaseValueCodec.encode(record.resolvedAt),
                try DatabaseValueCodec.encode(record.updatedAt),
            ])
    }

    private static func fetchBinding(
        lexemeID: UUID, in db: Database
    ) throws -> LexemeBindingRecord? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT lexeme_id, entry_id, match_tier, dataset_version,
                       status, detail, resolved_at_ms, updated_at_ms
                FROM lexeme_dictionary_bindings WHERE lexeme_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(lexemeID)])
        guard let row else { return nil }
        return try decodeBinding(row)
    }

    private static func decodeBinding(_ row: Row) throws -> LexemeBindingRecord {
        let lexemeRaw: String = row["lexeme_id"]
        let tierRaw: String = row["match_tier"]
        let statusRaw: String = row["status"]
        guard let tier = DictionaryMatchTier(rawValue: tierRaw),
              let status = LexemeBindingStatus(rawValue: statusRaw)
        else {
            throw VocabularyKnowledgeError.inconsistentStorage(
                "lexeme_dictionary_bindings tier/status: \(tierRaw)/\(statusRaw)")
        }
        return LexemeBindingRecord(
            lexemeID: try DatabaseValueCodec.decodeUUID(lexemeRaw),
            entryID: row["entry_id"],
            tier: tier,
            datasetVersion: row["dataset_version"],
            status: status,
            detail: row["detail"],
            resolvedAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["resolved_at_ms"]),
            updatedAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["updated_at_ms"])
        )
    }

    /// 绑定行 + lexeme 快照（重绑输入）。
    public struct BoundLexeme: Sendable {
        let binding: LexemeBindingRecord
        let writtenForm: String
        let reading: String?
        let normalizedLemma: String
    }

    private static func decodeBoundLexeme(_ row: Row) throws -> BoundLexeme {
        BoundLexeme(
            binding: try decodeBinding(row),
            writtenForm: row["written_form"],
            reading: row["reading"],
            normalizedLemma: row["normalized_lemma"]
        )
    }

    /// 无绑定行的存量 jmdict lexeme——`verifiedExisting` 语义。
    private static func decodeUnboundLexeme(_ row: Row) throws -> BoundLexeme {
        let idRaw: String = row["lexeme_id"]
        let versionAtResolution: String? = row["dictionary_version_at_resolution"]
        return BoundLexeme(
            binding: LexemeBindingRecord(
                lexemeID: try DatabaseValueCodec.decodeUUID(idRaw),
                entryID: row["entry_id"],
                tier: .verifiedExisting,
                datasetVersion: versionAtResolution ?? "",
                status: .current,
                resolvedAt: DatabaseValueCodec.decodeDate(
                    milliseconds: row["created_at_ms"]),
                updatedAt: DatabaseValueCodec.decodeDate(
                    milliseconds: row["created_at_ms"])
            ),
            writtenForm: row["written_form"],
            reading: row["reading"],
            normalizedLemma: row["normalized_lemma"]
        )
    }

    private static func fetchArtifactRows(
        _ db: Database, sql: String
    ) throws -> [ArtifactRecord] {
        try Row.fetchAll(db, sql: sql).map { row in
            let idRaw: String = row["id"]
            let statusRaw: String = row["verification_status"]
            return ArtifactRecord(
                id: try DatabaseValueCodec.decodeUUID(idRaw),
                fileSHA256: row["file_sha256"],
                byteCount: row["byte_count"],
                schemaVersion: row["schema_version"],
                datasetVersion: row["dataset_version"],
                dictionaryVersion: row["dictionary_version"],
                chineseLayerVersion: row["chinese_layer_version"],
                zhAlignmentRate: row["zh_alignment_rate"],
                status: ArtifactVerificationStatus(rawValue: statusRaw)
                    ?? .unreadable,
                firstSeenAt: DatabaseValueCodec.decodeDate(
                    milliseconds: row["first_seen_at_ms"]),
                lastVerifiedAt: DatabaseValueCodec.decodeDate(
                    milliseconds: row["last_verified_at_ms"])
            )
        }
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

// MARK: - 台账/状态值类型

/// `dictionary_artifact_records.verification_status`。
public enum ArtifactVerificationStatus: String, Codable, Sendable {
    case verified
    case checksumMismatch
    case unreadable
}

/// `dictionary_artifact_records` 行投影。
public struct ArtifactRecord: Equatable, Sendable {
    public let id: UUID
    public let fileSHA256: String
    public let byteCount: Int64
    public let schemaVersion: String
    public let datasetVersion: String
    public let dictionaryVersion: String
    public let chineseLayerVersion: String?
    public let zhAlignmentRate: Double?
    public let status: ArtifactVerificationStatus
    public let firstSeenAt: Date
    public let lastVerifiedAt: Date
}

/// S19 会话知识标注 seam——`knowledgeStates(forEntryIDs:)` 即协议方法。
extension GRDBDictionaryKnowledgeRepository: DictionaryEntryKnowledgeStates {}
