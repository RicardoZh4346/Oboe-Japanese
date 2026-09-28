import Foundation
import GRDB
import OboeDomain

/// v18 `VocabularyKnowledgeRepository` 的 GRDB 实现 +
/// `VocabularyKnowledgeLinking` 原子扩展。
///
/// 幂等模型（§11.2 + 冻结协议注释）：
/// - 知识域内部操作的 operation_id 由语义指纹确定性派生
///   （`deterministicOperationID`）——同一逻辑操作重复发起必然命中
///   同一 receipt 行；
/// - 写前检查：receipt 存在 **且** 当前存储态已等于请求态 → 纯回放，
///   直接返回该 receipt UUID，不写任何行、不新增事件；
/// - receipt 存在但存储态已漂移（例：known→reset→known 的第二次
///   known）→ 正常执行写，`ON CONFLICT DO UPDATE` 让 receipt 指向
///   最新结果。所以「receipt 存在」单独不构成跳过条件，必须结合
///   当前态判断；
/// - `setOverride` 返回值 = 该确定性 receipt UUID（冻结签名约束下
///   能让调用方稳定对齐的 receipt 身份）。
///
/// 事件映射（`ReaderActivityKind` 冻结枚举只有 5 态）：
/// - override=known → `markedKnown`；override 清除（reset）→
///   `resetKnowledge`；`userConfirmed` 关联与「加入学习」→
///   `linkedExistingNote`；
/// - override=ignored、backfill/自动关联、unlink → **不写事件**
///   （枚举无对应 case——不臆造扩展值；这些操作只有 receipt 行，
///   见 s08-lexical-knowledge.md Contract deltas）。
///
/// 有效关联计数：`state()` 只数 `notes.kind = 'vocabulary'` 的 link
/// （§6.3：关联 vocabulary Note 才进入 learning；grammar/cloze
/// Note 的关联存在但不驱动知识态）。
public final class GRDBVocabularyKnowledgeRepository: VocabularyKnowledgeRepository,
    VocabularyKnowledgeLinking, @unchecked Sendable {

    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }



    // MARK: - 读

    public func state(lexemeID: UUID) async throws -> VocabularyKnowledgeState {
        let encoded = DatabaseValueCodec.encode(lexemeID)
        return try await pool.read { db in
            let overrideRaw = try String.fetchOne(
                db,
                sql: """
                    SELECT state FROM vocabulary_knowledge_overrides
                    WHERE lexeme_id = ?
                    """,
                arguments: [encoded]
            )
            let linkedNoteCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM lexeme_note_links l
                    JOIN notes n ON n.id = l.note_id AND n.kind = 'vocabulary'
                    WHERE l.lexeme_id = ?
                    """,
                arguments: [encoded]
            ) ?? 0
            return VocabularyKnowledgeResolver.resolve(
                override: overrideRaw.flatMap(KnowledgeOverride.init(rawValue:)),
                linkedNoteCount: linkedNoteCount
            )
        }
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

    /// S09 批量状态解析：覆盖率/渲染路径的批量读口。两次 chunked
    /// IN 查询（override + 有效关联计数）解析全部 id，不逐 lexeme
    /// SQL。返回只含已入库 lexeme 的项——未入库/无覆盖信息由调用方
    /// 按真值表记 unknown。
    public func states(
        lexemeIDs: [UUID]
    ) async throws -> [UUID: VocabularyKnowledgeState] {
        let uniqueIDs = Array(Set(lexemeIDs))
        guard !uniqueIDs.isEmpty else { return [:] }
        let encoded = uniqueIDs.map(DatabaseValueCodec.encode)
        return try await pool.read { db in
            var overrides: [UUID: KnowledgeOverride] = [:]
            var linkCounts: [UUID: Int] = [:]
            for chunk in encoded.chunked(400) {
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                let args = StatementArguments(Array(chunk))
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT lexeme_id, state FROM vocabulary_knowledge_overrides
                        WHERE lexeme_id IN (\(placeholders))
                        """,
                    arguments: args
                ) {
                    let id: String = row["lexeme_id"]
                    let raw: String = row["state"]
                    if let uuid = try? DatabaseValueCodec.decodeUUID(id),
                       let state = KnowledgeOverride(rawValue: raw) {
                        overrides[uuid] = state
                    }
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT l.lexeme_id, COUNT(*) AS n
                        FROM lexeme_note_links l
                        JOIN notes n ON n.id = l.note_id AND n.kind = 'vocabulary'
                        WHERE l.lexeme_id IN (\(placeholders))
                        GROUP BY l.lexeme_id
                        """,
                    arguments: args
                ) {
                    let id: String = row["lexeme_id"]
                    if let uuid = try? DatabaseValueCodec.decodeUUID(id) {
                        linkCounts[uuid] = row["n"]
                    }
                }
            }
            var result: [UUID: VocabularyKnowledgeState] = [:]
            result.reserveCapacity(uniqueIDs.count)
            for id in uniqueIDs {
                result[id] = VocabularyKnowledgeResolver.resolve(
                    override: overrides[id],
                    linkedNoteCount: linkCounts[id] ?? 0
                )
            }
            return result
        }
    }

    // MARK: - 写（override）

    @discardableResult
    public func setOverride(
        lexemeID: UUID,
        override: KnowledgeOverride?,
        at date: Date
    ) async throws -> UUID {
        let requested = override?.rawValue ?? "reset"
        let operationID = GRDBReaderActivityStore.deterministicOperationID(
            "knowledge_override", DatabaseValueCodec.encode(lexemeID), requested)
        let payloadHash = GRDBReaderActivityStore.payloadHash(
            "knowledge_override|\(lexemeID.uuidString.lowercased())|\(requested)")
        let encodedLexeme = DatabaseValueCodec.encode(lexemeID)
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard try Self.lexemeExists(lexemeID: lexemeID, in: db) else {
                throw VocabularyKnowledgeError.lexemeNotFound(lexemeID)
            }
            let current = try String.fetchOne(
                db,
                sql: """
                    SELECT state FROM vocabulary_knowledge_overrides
                    WHERE lexeme_id = ?
                    """,
                arguments: [encodedLexeme]
            )
            // 纯回放：receipt 在 + 存储态已等于请求态 → 同 receipt，零写入。
            if try GRDBReaderActivityStore.fetchReceipt(
                operationID: operationID, in: db) != nil,
               current == override?.rawValue {
                return operationID
            }
            if let override {
                try db.execute(
                    sql: """
                        INSERT INTO vocabulary_knowledge_overrides(
                            lexeme_id, state, updated_at_ms
                        ) VALUES (?, ?, ?)
                        ON CONFLICT(lexeme_id) DO UPDATE SET
                            state = excluded.state,
                            updated_at_ms = excluded.updated_at_ms
                        """,
                    arguments: [encodedLexeme, override.rawValue, atMs]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM vocabulary_knowledge_overrides
                        WHERE lexeme_id = ?
                        """,
                    arguments: [encodedLexeme]
                )
            }
            // 事件：known→markedKnown，reset→resetKnowledge，
            // ignored→无对应冻结枚举值，只记 receipt。
            var eventID: UUID?
            if let kind = Self.eventKind(forOverride: override) {
                eventID = try Self.insertKnowledgeEvent(
                    kind: kind,
                    operationID: GRDBReaderActivityStore.deterministicOperationID(
                        "knowledge_override_event", operationID.uuidString.lowercased(),
                        String(atMs)),
                    lexemeID: lexemeID, noteID: nil,
                    at: date, in: db
                )
            }
            let resultJSON = Self.jsonObject([
                "lexeme_id": lexemeID.uuidString.lowercased(),
                "state": requested,
                "previous_state": current ?? NSNull(),
                "event_id": eventID.map { $0.uuidString.lowercased() } ?? NSNull(),
            ])
            try GRDBReaderActivityStore.recordReceipt(
                operationID: operationID, kind: "knowledge_override",
                payloadHash: payloadHash, resultJSON: resultJSON,
                at: date, in: db
            )
            return operationID
        }
    }

    // MARK: - 写（关联）

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

    /// 「加入学习」原子提交（§6.3）：同事务清 override + 建关联 +
    /// 事件 + receipt。重复调用（同 lexeme/note/origin）幂等回放。
    @discardableResult
    public func addToLearning(
        lexemeID: UUID,
        noteID: UUID,
        origin: LexemeNoteLink.AssociationOrigin,
        at date: Date
    ) async throws -> UUID {
        let operationID = GRDBReaderActivityStore.deterministicOperationID(
            "knowledge_add_to_learning", DatabaseValueCodec.encode(lexemeID),
            DatabaseValueCodec.encode(noteID), origin.rawValue)
        let payloadHash = GRDBReaderActivityStore.payloadHash(
            "knowledge_add_to_learning|\(lexemeID.uuidString.lowercased())"
                + "|\(noteID.uuidString.lowercased())|\(origin.rawValue)")
        let encodedLexeme = DatabaseValueCodec.encode(lexemeID)
        let encodedNote = DatabaseValueCodec.encode(noteID)
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard try Self.lexemeExists(lexemeID: lexemeID, in: db) else {
                throw VocabularyKnowledgeError.lexemeNotFound(lexemeID)
            }
            guard try Self.noteExists(noteID: noteID, in: db) else {
                throw VocabularyKnowledgeError.noteNotFound(noteID)
            }
            let hadOverride = try String.fetchOne(
                db,
                sql: """
                    SELECT state FROM vocabulary_knowledge_overrides
                    WHERE lexeme_id = ?
                    """,
                arguments: [encodedLexeme]
            )
            let hadLink = try String.fetchOne(
                db,
                sql: """
                    SELECT association_origin FROM lexeme_note_links
                    WHERE lexeme_id = ? AND note_id = ?
                    """,
                arguments: [encodedLexeme, encodedNote]
            )
            if hadOverride == nil, hadLink == origin.rawValue,
               try GRDBReaderActivityStore.fetchReceipt(
                   operationID: operationID, in: db) != nil {
                return operationID  // 纯回放
            }
            try db.execute(
                sql: """
                    DELETE FROM vocabulary_knowledge_overrides
                    WHERE lexeme_id = ?
                    """,
                arguments: [encodedLexeme]
            )
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin,
                        confidence, created_at_ms
                    ) VALUES (?, ?, ?, NULL, ?)
                    ON CONFLICT(lexeme_id, note_id) DO UPDATE SET
                        association_origin = excluded.association_origin
                    """,
                arguments: [encodedLexeme, encodedNote, origin.rawValue, atMs]
            )
            var eventID: UUID?
            if origin == .userConfirmed {
                eventID = try Self.insertKnowledgeEvent(
                    kind: .linkedExistingNote,
                    operationID: GRDBReaderActivityStore.deterministicOperationID(
                        "knowledge_add_event", operationID.uuidString.lowercased(),
                        String(atMs)),
                    lexemeID: lexemeID, noteID: noteID, at: date, in: db
                )
            }
            let resultJSON = Self.jsonObject([
                "lexeme_id": lexemeID.uuidString.lowercased(),
                "note_id": noteID.uuidString.lowercased(),
                "cleared_override": hadOverride ?? NSNull(),
                "previous_origin": hadLink ?? NSNull(),
                "event_id": eventID.map { $0.uuidString.lowercased() } ?? NSNull(),
            ])
            try GRDBReaderActivityStore.recordReceipt(
                operationID: operationID, kind: "knowledge_add_to_learning",
                payloadHash: payloadHash, resultJSON: resultJSON,
                at: date, in: db
            )
            return operationID
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

    private static func eventKind(
        forOverride override: KnowledgeOverride?
    ) -> ReaderActivityKind? {
        switch override {
        case .known: return .markedKnown
        case nil: return .resetKnowledge
        case .ignored: return nil  // 冻结枚举无对应值——见文件头注释
        }
    }

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

