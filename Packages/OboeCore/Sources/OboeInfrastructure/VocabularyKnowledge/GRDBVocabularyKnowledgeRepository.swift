import Foundation
import GRDB
import OboeDomain

/// v18 `VocabularyKnowledgeRepository` 的 GRDB 实现 +
/// `VocabularyKnowledgeLinking` 关联查询。
///
/// 幂等模型（§11.2 + 冻结协议注释）：
/// - 知识域内部操作的 operation_id 由语义指纹确定性派生
///   （`deterministicOperationID`）——同一逻辑操作重复发起必然命中
///   同一 receipt 行；
/// - 写前检查：receipt 存在 **且** 当前存储态已等于请求态 → 纯回放，
///   直接返回该 receipt UUID，不写任何行、不新增事件；
/// - receipt 存在但存储态已漂移 → 正常执行写，
///   `ON CONFLICT DO UPDATE` 让 receipt 指向最新结果。
///
/// 事件映射（`ReaderActivityKind` 冻结枚举只有 5 态）：
/// - `userConfirmed` 关联 → `linkedExistingNote`；
/// - backfill/自动关联、unlink → **不写事件**（枚举无对应 case——
///   不臆造扩展值；这些操作只有 receipt 行）。
///
/// D19（v0.7.5）运行态真值切换：
/// - 词级知识态唯一来源 = learning-unit flags/links
///   （`wordKnowledgeStates`：词条绑定 current 义项 ∪
///   note 链路载体 → 逐 unit 三态 → 最小值聚合）；
/// - `vocabulary_knowledge_overrides` 仅供 v8 导入/兼容审计——
///   本类型不读不写（`setOverride`/`addToLearning` 已删除，
///   `lexeme_note_links` 仍随挖词镜像写入以供 v8 导出与审计）；
/// - 词级「已知/重置」写路径 =
///   `GRDBLearningUnitRepository.setWordTooEasy`。
public final class GRDBVocabularyKnowledgeRepository: VocabularyKnowledgeRepository,
    VocabularyKnowledgeLinking, @unchecked Sendable {

    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }



    // MARK: - 读

    public func state(lexemeID: UUID) async throws -> VocabularyKnowledgeState {
        try await pool.read { db in
            try Self.wordKnowledgeStates(
                lexemeIDs: [lexemeID], in: db)[lexemeID] ?? .unknown
        }
    }

    /// 知识态变更流（同池 unit flag/link/事件写提交即 ping）——
    /// Reader 着色/词典会话等消费方据此重取 `states()`。转发
    /// `GRDBLearningUnitRepository.observeChanges`（同 DatabasePool）。
    public func knowledgeChanges() -> AsyncThrowingStream<Void, Error> {
        GRDBLearningUnitRepository(pool: pool).observeChanges()
    }

    public func fetchLexeme(key: LexicalKey) async throws -> Lexeme? {
        try await pool.read { db in
            try Self.fetchLexemeRow(identityKey: key.identityKey, in: db)
                .map(Self.decodeLexeme)
        }
    }

    /// 批量 fetch——覆盖率/渲染路径的 only 通道；IN 分块与
    /// `GRDBMorphologyCandidateResolver` 同尺寸（400），绝不逐 key SQL。
    public func resolveLexemes(
        keys: [LexicalKey]
    ) async throws -> [LexicalKey: Lexeme] {
        let wanted = Dictionary(
            keys.map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !wanted.isEmpty else { return [:] }
        return try await pool.read { db in
            var result: [LexicalKey: Lexeme] = [:]
            for chunk in Array(wanted.keys).chunked(400) {
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, provider, external_id, entry_id,
                               written_form, reading, normalized_lemma,
                               pos_family, identity_key,
                               dictionary_version_at_resolution,
                               resolution_status, created_at_ms
                        FROM lexemes WHERE identity_key IN (\(placeholders))
                        """,
                    arguments: StatementArguments(Array(chunk))
                ) {
                    let lexeme = try Self.decodeLexeme(row)
                    if let key = wanted[lexeme.key.identityKey] {
                        result[key] = lexeme
                    }
                }
            }
            return result
        }
    }

    /// S09 批量状态解析：覆盖率/渲染路径的批量读口。
    ///
    /// D19（v0.7.5）：词级知识态唯一真值 = learning unit flags/links，
    /// `vocabulary_knowledge_overrides` 仅供 v8 导入/兼容审计，
    /// 运行态永不读取。词级聚合规则（word-level merge）：
    /// - unit 集合 = 该 lexeme 词条绑定的 `current` dictionarySense
    ///   units（`lexeme_dictionary_bindings.status='current'` 优先，
    ///   回退 `lexemes.entry_id`）∪ 经 `lexeme_note_links →
    ///   learning_unit_note_links` 触达的学习载体单元
    ///   （localNote/legacyUnresolved/已绑义项）；
    /// - 逐 unit 按 `LearningKnowledgeResolver` 求三态后取
    ///   最小值聚合：任一 unknown → 词级 unknown；否则任一
    ///   learning → learning；全部 mastered → known；
    /// - 零 unit → unknown；ignored 运行态不再产生（D04）。
    ///
    /// 两次 chunked IN 查询解析全部 id，不逐 lexeme SQL。返回只含
    /// 已入库 lexeme 的项——未入库/无 unit 由调用方按 unknown 处理。
    public func states(
        lexemeIDs: [UUID]
    ) async throws -> [UUID: VocabularyKnowledgeState] {
        let uniqueIDs = Array(Set(lexemeIDs))
        guard !uniqueIDs.isEmpty else { return [:] }
        return try await pool.read { db in
            try Self.wordKnowledgeStates(lexemeIDs: uniqueIDs, in: db)
        }
    }

    /// 词级聚合的唯一实现点（覆盖率/着色/词典徽章/统计共用）。
    /// 返回字典覆盖所有传入 id（含 unknown）——调用方无需补默认。
    static func wordKnowledgeStates(
        lexemeIDs: [UUID], in db: Database
    ) throws -> [UUID: VocabularyKnowledgeState] {
        let uniqueIDs = Array(Set(lexemeIDs))
        guard !uniqueIDs.isEmpty else { return [:] }
        var best: [UUID: Int] = [:]
        best.reserveCapacity(uniqueIDs.count)
        for chunk in uniqueIDs.map(DatabaseValueCodec.encode).chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            // 两个 UNION 支路各绑定一份 lexeme id 列表。
            let args = StatementArguments(Array(chunk) + Array(chunk))
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT x.lexeme_id AS lexeme_id, x.unit_id AS unit_id,
                           COALESCE(f.too_easy, 0) AS too_easy,
                           EXISTS(
                               SELECT 1 FROM learning_unit_note_links nl
                               JOIN notes n ON n.id = nl.note_id
                                    AND n.kind = 'vocabulary'
                               WHERE nl.unit_id = x.unit_id
                           ) AS linked
                    FROM (
                        SELECT l.id AS lexeme_id, u.id AS unit_id
                        FROM lexemes l
                        JOIN lexical_learning_units u
                          ON u.identity_kind = 'dictionarySense'
                         AND u.binding_status = 'current'
                         AND u.dictionary_entry_id = COALESCE(
                               (SELECT b.entry_id
                                  FROM lexeme_dictionary_bindings b
                                 WHERE b.lexeme_id = l.id
                                   AND b.status = 'current'),
                               l.entry_id)
                        WHERE l.id IN (\(placeholders))
                        UNION
                        SELECT x.lexeme_id, ul.unit_id
                        FROM lexeme_note_links x
                        JOIN learning_unit_note_links ul
                          ON ul.note_id = x.note_id
                        WHERE x.lexeme_id IN (\(placeholders))
                    ) x
                    LEFT JOIN learning_unit_flags f ON f.unit_id = x.unit_id
                    """,
                arguments: args
            ) {
                let lexemeRaw: String = row["lexeme_id"]
                let tooEasy: Int = row["too_easy"]
                let linked: Bool = row["linked"]
                guard let lexemeID =
                        try? DatabaseValueCodec.decodeUUID(lexemeRaw)
                else { continue }
                let unitState = LearningKnowledgeResolver.state(
                    tooEasy: tooEasy != 0,
                    hasVocabularyNoteLink: linked)
                let rank: Int = switch unitState {
                case .unknown: 0
                case .learning: 1
                case .mastered: 2
                }
                best[lexemeID] = min(best[lexemeID] ?? 2, rank)
            }
        }
        var result: [UUID: VocabularyKnowledgeState] = [:]
        result.reserveCapacity(uniqueIDs.count)
        for id in uniqueIDs {
            switch best[id] {
            case .some(2): result[id] = .known
            case .some(1): result[id] = .learning
            default: result[id] = .unknown
            }
        }
        return result
    }

    // MARK: - 写（关联）

    /// D19（v0.7.5）：`setOverride`/`addToLearning` 已删除——
    /// `vocabulary_knowledge_overrides` 仅供 v8 导入与兼容审计，
    /// 运行态写一律走 learning-unit flags（词级「已知/重置」=
    /// `GRDBLearningUnitRepository.setWordTooEasy`）。历史 receipt
    /// （`knowledge_override`/`knowledge_add_to_learning`）仍可经
    /// `knowledgeReceipt` 回查。


    public func linkNote(
        lexemeID: UUID,
        noteID: UUID,
        origin: LexemeNoteLink.AssociationOrigin
    ) async throws {
        let operationID = GRDBReaderActivityStore.deterministicOperationID(
            "knowledge_link", DatabaseValueCodec.encode(lexemeID),
            DatabaseValueCodec.encode(noteID), origin.rawValue)
        let payloadHash = GRDBReaderActivityStore.payloadHash(
            "knowledge_link|\(lexemeID.uuidString.lowercased())"
                + "|\(noteID.uuidString.lowercased())|\(origin.rawValue)")
        try await pool.write { db in
            guard try Self.lexemeExists(lexemeID: lexemeID, in: db) else {
                throw VocabularyKnowledgeError.lexemeNotFound(lexemeID)
            }
            guard try Self.noteExists(noteID: noteID, in: db) else {
                throw VocabularyKnowledgeError.noteNotFound(noteID)
            }
            let existingOrigin = try String.fetchOne(
                db,
                sql: """
                    SELECT association_origin FROM lexeme_note_links
                    WHERE lexeme_id = ? AND note_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            // 回放：receipt 在 + 关联已是同来源 → 幂等返回。
            if existingOrigin == origin.rawValue,
               try GRDBReaderActivityStore.fetchReceipt(
                   operationID: operationID, in: db) != nil {
                return
            }
            let nowMs = try DatabaseValueCodec.encode(Date())
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin,
                        confidence, created_at_ms
                    ) VALUES (?, ?, ?, NULL, ?)
                    ON CONFLICT(lexeme_id, note_id) DO UPDATE SET
                        association_origin = excluded.association_origin
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID),
                    origin.rawValue,
                    nowMs
                ]
            )
            var eventID: UUID?
            if origin == .userConfirmed {
                eventID = try Self.insertKnowledgeEvent(
                    kind: .linkedExistingNote,
                    operationID: GRDBReaderActivityStore.deterministicOperationID(
                        "knowledge_link_event", operationID.uuidString.lowercased(),
                        String(nowMs)),
                    lexemeID: lexemeID, noteID: noteID,
                    at: Date(timeIntervalSince1970: Double(nowMs) / 1_000),
                    in: db
                )
            }
            let resultJSON = Self.jsonObject([
                "lexeme_id": lexemeID.uuidString.lowercased(),
                "note_id": noteID.uuidString.lowercased(),
                "origin": origin.rawValue,
                "previous_origin": existingOrigin ?? NSNull(),
                "event_id": eventID.map { $0.uuidString.lowercased() } ?? NSNull(),
            ])
            try GRDBReaderActivityStore.recordReceipt(
                operationID: operationID, kind: "knowledge_link",
                payloadHash: payloadHash, resultJSON: resultJSON,
                at: Date(timeIntervalSince1970: Double(nowMs) / 1_000),
                in: db
            )
        }
    }

    public func unlinkNote(lexemeID: UUID, noteID: UUID) async throws {
        let operationID = GRDBReaderActivityStore.deterministicOperationID(
            "knowledge_unlink", DatabaseValueCodec.encode(lexemeID),
            DatabaseValueCodec.encode(noteID))
        let payloadHash = GRDBReaderActivityStore.payloadHash(
            "knowledge_unlink|\(lexemeID.uuidString.lowercased())"
                + "|\(noteID.uuidString.lowercased())")
        try await pool.write { db in
            let existed = try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM lexeme_note_links
                        WHERE lexeme_id = ? AND note_id = ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID)
                ]
            ) ?? false
            if !existed,
               try GRDBReaderActivityStore.fetchReceipt(
                   operationID: operationID, in: db) != nil {
                return  // 回放：已解除过
            }
            try db.execute(
                sql: """
                    DELETE FROM lexeme_note_links
                    WHERE lexeme_id = ? AND note_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            let resultJSON = Self.jsonObject([
                "lexeme_id": lexemeID.uuidString.lowercased(),
                "note_id": noteID.uuidString.lowercased(),
                "removed": existed,
            ])
            try GRDBReaderActivityStore.recordReceipt(
                operationID: operationID, kind: "knowledge_unlink",
                payloadHash: payloadHash, resultJSON: resultJSON,
                at: Date(), in: db
            )
        }
    }

    // MARK: - 关联查询

    public func linksForNote(noteID: UUID) async throws -> [LexemeNoteLink] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT lexeme_id, note_id, association_origin, created_at_ms
                    FROM lexeme_note_links WHERE note_id = ?
                    ORDER BY created_at_ms, lexeme_id
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            ).map(Self.decodeLink)
        }
    }

    public func linkedNoteIDs(lexemeID: UUID) async throws -> [UUID] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT note_id FROM lexeme_note_links
                    WHERE lexeme_id = ? ORDER BY created_at_ms, note_id
                    """,
                arguments: [DatabaseValueCodec.encode(lexemeID)]
            ).compactMap {
                try? DatabaseValueCodec.decodeUUID($0["note_id"])
            }
        }
    }

    public func knowledgeReceipt(
        operationID: UUID
    ) async throws -> KnowledgeOperationReceipt? {
        try await pool.read { db in
            try GRDBReaderActivityStore.fetchKnowledgeReceipt(
                operationID: operationID, in: db)
        }
    }

    // MARK: - lexeme upsert

    /// identity_key 命中即返回既有行（不重建 UUID——§6.3 稳定主键）；
    /// 未命中按 `seed` 插入。并发同 key 写由 DatabasePool 串行化 +
    /// UNIQUE 兜底；冲突重读一次返回既有行。
    public func resolveLexeme(key: LexicalKey, seed: Lexeme) async throws -> Lexeme {
        try await pool.write { db in
            if let row = try Self.fetchLexemeRow(
                identityKey: key.identityKey, in: db) {
                return try Self.decodeLexeme(row)
            }
            do {
                try db.execute(
                    sql: """
                        INSERT INTO lexemes(
                            id, provider, external_id, entry_id,
                            written_form, reading, normalized_lemma,
                            pos_family, identity_key,
                            dictionary_version_at_resolution,
                            resolution_status, created_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(seed.id),
                        seed.key.provider.rawValue,
                        seed.key.externalID,
                        seed.key.provider == .jmdict
                            ? Int64(seed.key.externalID) : nil,
                        seed.writtenForm,
                        seed.reading,
                        seed.normalizedLemma,
                        seed.posFamily,
                        key.identityKey,
                        seed.dictionaryVersionAtResolution,
                        seed.resolutionStatus.rawValue,
                        try DatabaseValueCodec.encode(seed.createdAt)
                    ]
                )
                return seed
            } catch {
                if let row = try Self.fetchLexemeRow(
                    identityKey: key.identityKey, in: db) {
                    return try Self.decodeLexeme(row)
                }
                throw error
            }
        }
    }

    // MARK: - 内部

    private static func insertKnowledgeEvent(
        kind: ReaderActivityKind,
        operationID: UUID,
        lexemeID: UUID,
        noteID: UUID?,
        at date: Date,
        in db: Database
    ) throws -> UUID? {
        let snapshot = jsonObject([
            "written_form": (try? String.fetchOne(
                db,
                sql: "SELECT written_form FROM lexemes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(lexemeID)]
            )) ?? NSNull()
        ])
        return try GRDBReaderActivityStore.insertEvent(
            ReaderActivityEvent(
                id: UUID(),
                operationID: operationID,
                kind: kind,
                lexemeID: lexemeID,
                noteID: noteID,
                documentID: nil,
                snapshotJSON: snapshot,
                createdAt: date,
                undoneAt: nil
            ),
            in: db
        )
    }

    private static func lexemeExists(lexemeID: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM lexemes WHERE id = ?)",
            arguments: [DatabaseValueCodec.encode(lexemeID)]
        ) ?? false
    }

    private static func noteExists(noteID: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ?)",
            arguments: [DatabaseValueCodec.encode(noteID)]
        ) ?? false
    }

    private static func fetchLexemeRow(
        identityKey: String,
        in db: Database
    ) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, provider, external_id, entry_id,
                       written_form, reading, normalized_lemma,
                       pos_family, identity_key,
                       dictionary_version_at_resolution,
                       resolution_status, created_at_ms
                FROM lexemes WHERE identity_key = ?
                """,
            arguments: [identityKey]
        )
    }

    private static func decodeLexeme(_ row: Row) throws -> Lexeme {
        let providerRaw: String = row["provider"]
        guard let provider = LexicalKey.Provider(rawValue: providerRaw) else {
            throw VocabularyKnowledgeError.inconsistentStorage(
                "lexemes.provider=\(providerRaw)")
        }
        let statusRaw: String = row["resolution_status"]
        guard let status = TokenResolutionStatus(rawValue: statusRaw) else {
            throw VocabularyKnowledgeError.inconsistentStorage(
                "lexemes.resolution_status=\(statusRaw)")
        }
        return Lexeme(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            key: LexicalKey(
                provider: provider,
                externalID: row["external_id"],
                identityKey: row["identity_key"]
            ),
            writtenForm: row["written_form"],
            reading: row["reading"],
            normalizedLemma: row["normalized_lemma"],
            posFamily: row["pos_family"],
            dictionaryVersionAtResolution: row["dictionary_version_at_resolution"],
            resolutionStatus: status,
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: row["created_at_ms"])
        )
    }

    private static func decodeLink(_ row: Row) throws -> LexemeNoteLink {
        let originRaw: String = row["association_origin"]
        guard let origin = LexemeNoteLink.AssociationOrigin(rawValue: originRaw) else {
            throw VocabularyKnowledgeError.inconsistentStorage(
                "lexeme_note_links.association_origin=\(originRaw)")
        }
        return LexemeNoteLink(
            lexemeID: try DatabaseValueCodec.decodeUUID(row["lexeme_id"]),
            noteID: try DatabaseValueCodec.decodeUUID(row["note_id"]),
            origin: origin,
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: row["created_at_ms"])
        )
    }

    static func jsonObject(_ pairs: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: pairs, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
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

