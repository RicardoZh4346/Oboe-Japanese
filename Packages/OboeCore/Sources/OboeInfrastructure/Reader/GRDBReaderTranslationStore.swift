import Foundation
import GRDB

/// `reader_translation_blocks` 的一行（v25，S17 持久化面）。
///
/// `locatorKey`/`locatorJSON`/`sourceHash` 对存储层**不透明**——由
/// 调用方（编排层）从 `reader_blocks`/`ReaderLocation` 约定生成；
/// 存储层只保证唯一性、current 原子翻转与历史保留。
public struct ReaderTranslationRow: Equatable, Sendable {
    public let id: UUID
    public let documentID: UUID
    public let locatorKey: String
    /// 锚点快照（格式相关，不透明）——`ReaderLocation` JSON 或
    /// 编排层自有锚点；重链后由 `updateLocators` 重挂。
    public let locatorJSON: String
    /// 发表时的原文 hash（`reader_blocks.text_hash` 或等价物）——
    /// 渲染侧与活动原文比对，不符即不落位（§译文不出现在不匹配
    /// 原文下）；历史行保留不回写。
    public let sourceHash: String
    public let translationRevision: Int
    public let translatedText: String
    public let language: String
    public let provider: String?
    public let model: String?
    public let promptVersion: String?
    public let requestHash: String?
    public let isCurrent: Bool
    public let createdAt: Date

    public init(
        id: UUID,
        documentID: UUID,
        locatorKey: String,
        locatorJSON: String,
        sourceHash: String,
        translationRevision: Int,
        translatedText: String,
        language: String,
        provider: String?,
        model: String?,
        promptVersion: String?,
        requestHash: String?,
        isCurrent: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.documentID = documentID
        self.locatorKey = locatorKey
        self.locatorJSON = locatorJSON
        self.sourceHash = sourceHash
        self.translationRevision = translationRevision
        self.translatedText = translatedText
        self.language = language
        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
        self.requestHash = requestHash
        self.isCurrent = isCurrent
        self.createdAt = createdAt
    }
}

public enum ReaderTranslationError: Error, Equatable, Sendable {
    /// locator_key / language / translated_text / source_hash 为空或
    /// locator_json 非法 JSON/超长。
    case invalidInput(String)
    /// 同一修订并发写撞 UNIQUE——调用方重读 current 后重试。
    case revisionConflict
}

/// v0.7.5 S17（v25 `reader_translation_blocks` 运行时）：
/// 段落译文历史与 current 指针。
///
/// 语义（技术文档 §4 / S17 规格）：
/// - **一块一译文当前值**：`(document_id, locator_key, language)
///   WHERE is_current=1` 部分唯一由库强约束；`publish` 在同事务内
///   先翻旧 current 再插新行——**旧译文保留到新结果落库**才被替换
///   （结果未到永不丢旧值）；
/// - **历史全留**：同 (locator, sourceHash, language) 的修订链单调
///   +1，不同 sourceHash 另起链（UNIQUE 含 source_hash）；任何
///   历史行不删——原文缺失/恢复后仍可追溯；
/// - **不静默覆盖**：prompt/model/provider 变更只是新修订的
///   provenance，永不改写既有行；
/// - **重挂不改归属**：`updateLocators` 只刷锚点列，不碰
///   sourceHash/current/修订号——译文与原文的匹配判定仍在渲染侧
///   按 sourceHash 比对；
/// - document 删除走 FK CASCADE（行随文档陪葬——译文无独立价值）。
public enum GRDBReaderTranslationStore {
    /// 发表新修订并置为 current（同事务翻旧 current——调用方必须
    /// 只在拿到**校验通过**的新译文后调用，失败路径零写入）。
    ///
    /// `translation_revision` = 同 (document, locatorKey, sourceHash,
    /// language) 链上 max+1（首修订为 1）。
    @discardableResult
    public static func publish(
        documentID: UUID,
        locatorKey: String,
        locatorJSON: String,
        sourceHash: String,
        language: String,
        translatedText: String,
        provider: String? = nil,
        model: String? = nil,
        promptVersion: String? = nil,
        requestHash: String? = nil,
        at date: Date = Date(),
        in db: Database
    ) throws -> ReaderTranslationRow {
        guard !locatorKey.isEmpty else {
            throw ReaderTranslationError.invalidInput("locatorKey")
        }
        guard !sourceHash.isEmpty else {
            throw ReaderTranslationError.invalidInput("sourceHash")
        }
        guard !language.isEmpty else {
            throw ReaderTranslationError.invalidInput("language")
        }
        guard !translatedText.isEmpty,
              translatedText.count <= GRDBAIStudyPipelineSchema.translatedTextMaxLength
        else {
            throw ReaderTranslationError.invalidInput("translatedText")
        }
        guard locatorJSON.count <= 8_192,
              (try? JSONSerialization.jsonObject(with: Data(locatorJSON.utf8))) != nil
        else {
            throw ReaderTranslationError.invalidInput("locatorJSON")
        }

        let documentIDValue = DatabaseValueCodec.encode(documentID)
        let nextRevision = try Self.nextRevision(
            documentID: documentID,
            locatorKey: locatorKey,
            sourceHash: sourceHash,
            language: language,
            in: db
        )

        // 同事务翻旧 current——新行落库前旧译文仍是可渲染值。
        try db.execute(
            sql: """
                UPDATE reader_translation_blocks
                SET is_current = 0
                WHERE document_id = ? AND locator_key = ? AND language = ?
                  AND is_current = 1
                """,
            arguments: [documentIDValue, locatorKey, language]
        )

        let row = ReaderTranslationRow(
            id: UUID(),
            documentID: documentID,
            locatorKey: locatorKey,
            locatorJSON: locatorJSON,
            sourceHash: sourceHash,
            translationRevision: nextRevision,
            translatedText: translatedText,
            language: language,
            provider: provider,
            model: model,
            promptVersion: promptVersion,
            requestHash: requestHash,
            isCurrent: true,
            createdAt: date
        )
        do {
            try db.execute(
                sql: """
                    INSERT INTO reader_translation_blocks (
                        id, document_id, locator_key, locator_json,
                        source_hash, translation_revision, translated_text,
                        language, provider, model, prompt_version,
                        request_hash, is_current, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(row.id),
                    documentIDValue,
                    locatorKey,
                    locatorJSON,
                    sourceHash,
                    nextRevision,
                    translatedText,
                    language,
                    provider,
                    model,
                    promptVersion,
                    requestHash,
                    DatabaseValueCodec.encode(date),
                ]
            )
        } catch let error as DatabaseError
        where error.resultCode == .SQLITE_CONSTRAINT {
            throw ReaderTranslationError.revisionConflict
        }
        return row
    }

    /// 文档当前译文全集（bilingual 模式水合）——按 locatorKey 返回
    /// `is_current=1` 行。渲染侧再按活动原文 hash 过滤（见
    /// `fetchRenderable`）。
    public static func fetchCurrent(
        documentID: UUID,
        language: String? = nil,
        in db: Database
    ) throws -> [ReaderTranslationRow] {
        var sql = """
            SELECT \(Self.columnList)
            FROM reader_translation_blocks
            WHERE document_id = ? AND is_current = 1
            """
        var arguments: StatementArguments = [DatabaseValueCodec.encode(documentID)]
        if let language {
            sql += " AND language = ?"
            arguments += [language]
        }
        sql += " ORDER BY locator_key"
        return try Self.rows(
            Row.fetchAll(db, sql: sql, arguments: arguments)
        )
    }

    /// 某一锚点的修订史（新→旧，含非 current）。
    public static func fetchHistory(
        documentID: UUID,
        locatorKey: String,
        language: String,
        in db: Database
    ) throws -> [ReaderTranslationRow] {
        try Self.rows(
            Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.columnList)
                    FROM reader_translation_blocks
                    WHERE document_id = ? AND locator_key = ? AND language = ?
                    ORDER BY translation_revision DESC
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    locatorKey,
                    language,
                ]
            )
        )
    }

    /// 可渲染当前值：`is_current=1` 且 `source_hash` 仍等于活动原文
    /// hash（`liveSourceHashes[locatorKey]`）——原文缺失或已改的
    /// 锚点不返回（译文不出现在不匹配原文下；历史行原样保留）。
    public static func fetchRenderable(
        documentID: UUID,
        language: String,
        liveSourceHashes: [String: String],
        in db: Database
    ) throws -> [String: ReaderTranslationRow] {
        let current = try fetchCurrent(
            documentID: documentID, language: language, in: db
        )
        var renderable: [String: ReaderTranslationRow] = [:]
        renderable.reserveCapacity(current.count)
        for row in current where liveSourceHashes[row.locatorKey] == row.sourceHash {
            renderable[row.locatorKey] = row
        }
        return renderable
    }

    /// 重挂锚点：原文重链后 locator_key/locator_json 迁移。
    ///
    /// - Parameter moves: `(oldLocatorKey → (newLocatorKey,
    ///   newLocatorJSON))`；只刷锚点列，`source_hash`/`is_current`/
    ///   修订链不动。
    /// - Note: 两锚点合并导致 `(doc, newKey, language) is_current=1`
    ///   冲突时抛 `revisionConflict`——歧义合并不允许静默吞掉。
    public static func updateLocators(
        documentID: UUID,
        moves: [(oldLocatorKey: String, newLocatorKey: String, newLocatorJSON: String)],
        in db: Database
    ) throws {
        let documentIDValue = DatabaseValueCodec.encode(documentID)
        for move in moves {
            guard !move.newLocatorKey.isEmpty,
                  move.newLocatorJSON.count <= 8_192,
                  (try? JSONSerialization.jsonObject(
                      with: Data(move.newLocatorJSON.utf8)
                  )) != nil
            else {
                throw ReaderTranslationError.invalidInput("locatorJSON")
            }
            do {
                try db.execute(
                    sql: """
                        UPDATE reader_translation_blocks
                        SET locator_key = ?, locator_json = ?
                        WHERE document_id = ? AND locator_key = ?
                        """,
                    arguments: [
                        move.newLocatorKey,
                        move.newLocatorJSON,
                        documentIDValue,
                        move.oldLocatorKey,
                    ]
                )
            } catch let error as DatabaseError
        where error.resultCode == .SQLITE_CONSTRAINT {
                throw ReaderTranslationError.revisionConflict
            }
        }
    }

    /// 文档活动原文 hash 快照（渲染/发表前判定用）——
    /// `reader_blocks.id → text_hash`。locator_key 约定为 block id 时
    /// 直接作 `liveSourceHashes` 入参。
    public static func liveBlockSourceHashes(
        documentID: UUID,
        in db: Database
    ) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, text_hash FROM reader_blocks
                WHERE document_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(documentID)]
        )
        var hashes: [String: String] = [:]
        hashes.reserveCapacity(rows.count)
        for row in rows {
            let id = try DatabaseValueCodec.decodeUUID(row["id"])
            hashes[id.uuidString.lowercased()] = row["text_hash"]
        }
        return hashes
    }

    // MARK: - 私有

    private static let columnList = """
        id, document_id, locator_key, locator_json, source_hash,
        translation_revision, translated_text, language, provider,
        model, prompt_version, request_hash, is_current, created_at_ms
        """

    private static func nextRevision(
        documentID: UUID,
        locatorKey: String,
        sourceHash: String,
        language: String,
        in db: Database
    ) throws -> Int {
        let maxRevision: Int? = try Int.fetchOne(
            db,
            sql: """
                SELECT MAX(translation_revision)
                FROM reader_translation_blocks
                WHERE document_id = ? AND locator_key = ?
                  AND source_hash = ? AND language = ?
                """,
            arguments: [
                DatabaseValueCodec.encode(documentID),
                locatorKey,
                sourceHash,
                language,
            ]
        )
        return (maxRevision ?? 0) + 1
    }

    private static func rows(_ rows: [Row]) throws -> [ReaderTranslationRow] {
        try rows.map { row in
            ReaderTranslationRow(
                id: try DatabaseValueCodec.decodeUUID(row["id"]),
                documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
                locatorKey: row["locator_key"],
                locatorJSON: row["locator_json"],
                sourceHash: row["source_hash"],
                translationRevision: row["translation_revision"],
                translatedText: row["translated_text"],
                language: row["language"],
                provider: row["provider"],
                model: row["model"],
                promptVersion: row["prompt_version"],
                requestHash: row["request_hash"],
                isCurrent: row["is_current"] != 0,
                createdAt: DatabaseValueCodec.decodeDate(milliseconds: row["created_at_ms"])
            )
        }
    }
}
