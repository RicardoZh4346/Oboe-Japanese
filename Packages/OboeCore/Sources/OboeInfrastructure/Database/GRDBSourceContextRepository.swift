import Foundation
import GRDB
import OboeDomain

/// `source_contexts` 表（schema v15，设计 §6.1）的 GRDB 实现。
///
/// - `id`/`note_id` 走 `DatabaseValueCodec` 的小写 UUID 文本约定，
///   `created_at_ms` 是 epoch 毫秒整数。
/// - `image_reference` 延续宽松引用（无 FK）；指向已删除/未登记附件
///   的行照样可写可读，清理由统一附件引用查询负责。
/// - 「有来源时最多一个 primary」靠部分唯一索引
///   `source_contexts_one_primary`；写路径把 UNIQUE 冲突映射为
///   `SourceContextError.primaryConflict`、note 外键失败映射为
///   `SourceContextError.missingNote`。
/// - `static …(in db:)` 共享实现给 commit 事务（CaptureCommitDigest
///   集成、句析批量制卡）在调用方事务内复用——与
///   `GRDBAttachmentRepository` 的模式一致。
public struct GRDBSourceContextRepository: SourceContextRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func insert(_ context: SourceContext) async throws {
        try await pool.write { db in
            try Self.insert(context, in: db)
        }
    }

    /// 批量写入共用一个写事务：任一行失败整批回滚（GRDB 写闭包抛错
    /// 即回滚），批量制卡不会留下半截来源。
    public func insertAll(_ contexts: [SourceContext]) async throws {
        guard !contexts.isEmpty else { return }
        try await pool.write { db in
            try Self.insertAll(contexts, in: db)
        }
    }

    public func fetch(id: UUID) async throws -> SourceContext? {
        try await pool.read { db in
            try Self.fetchRow(id: id, in: db).map(Self.decode)
        }
    }

    public func fetchForNote(noteID: UUID) async throws -> [SourceContext] {
        try await pool.read { db in
            try Self.fetchRowsForNote(noteID: noteID, in: db).map(Self.decode)
        }
    }

    public func fetchPrimary(noteID: UUID) async throws -> SourceContext? {
        try await pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.columns) FROM source_contexts
                    WHERE note_id = ? AND is_primary = 1
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            ).map(Self.decode)
        }
    }

    /// 主来源切换必须在一个事务内「先清后置」：若先置目标行为 1，
    /// 该 Note 原有 primary 行仍存，部分唯一索引在语句间瞬时成立，
    /// UPDATE 会撞 UNIQUE 约束。先清零旧 primary 再置位才安全。
    /// 任一步失败整事务回滚，原 primary 不丢。
    public func setPrimary(contextID: UUID, noteID: UUID) async throws {
        try await pool.write { db in
            try Self.setPrimary(contextID: contextID, noteID: noteID, in: db)
        }
    }

    public func delete(id: UUID) async throws -> Bool {
        try await pool.write { db in
            try Self.delete(id: id, in: db)
        }
    }

    public func fetchImageReferences() async throws -> Set<String> {
        try await pool.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT image_reference
                        FROM source_contexts
                        WHERE image_reference IS NOT NULL
                          AND image_reference <> ''
                        """
                )
            )
        }
    }

    // MARK: - 共享实现（commit 事务内复用）

    static let columns = """
        id, note_id, source_type, original_sentence, surrounding_text,
        source_title, source_url, source_app, image_reference,
        dictionary_entry_id, dictionary_version, dictionary_sense_key,
        selected_gloss_language, is_primary, created_at_ms
        """

    /// 行级写：在 `db` 事务内执行并把约束失败归一化为
    /// `SourceContextError`——commit 事务复用本函数时同样拿到领域错误
    /// 而不是裸 SQLite 报错。
    static func insert(_ context: SourceContext, in db: Database) throws {
        do {
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        surrounding_text, source_title, source_url, source_app,
                        image_reference, dictionary_entry_id, dictionary_version,
                        dictionary_sense_key, selected_gloss_language,
                        is_primary, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(context.id),
                    DatabaseValueCodec.encode(context.noteID),
                    context.sourceType.rawValue,
                    context.originalSentence,
                    context.surroundingText,
                    context.sourceTitle,
                    context.sourceURL,
                    context.sourceApp,
                    context.imageReference,
                    context.dictionaryEntryID,
                    context.dictionaryVersion,
                    context.dictionarySenseKey,
                    context.selectedGlossLanguage,
                    context.isPrimary,
                    DatabaseValueCodec.encode(context.createdAt)
                ]
            )
        } catch let error as DatabaseError {
            throw mapWriteError(error, noteID: context.noteID)
        }
    }

    static func insertAll(_ contexts: [SourceContext], in db: Database) throws {
        for context in contexts {
            try insert(context, in: db)
        }
    }

    static func setPrimary(contextID: UUID, noteID: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE source_contexts SET is_primary = 0
                WHERE note_id = ? AND is_primary = 1
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
        try db.execute(
            sql: """
                UPDATE source_contexts SET is_primary = 1
                WHERE id = ? AND note_id = ?
                """,
            arguments: [
                DatabaseValueCodec.encode(contextID),
                DatabaseValueCodec.encode(noteID)
            ]
        )
        guard db.changesCount > 0 else {
            throw SourceContextRepositoryError.contextNotFound(
                contextID: contextID,
                noteID: noteID
            )
        }
    }

    static func delete(id: UUID, in db: Database) throws -> Bool {
        try db.execute(
            sql: "DELETE FROM source_contexts WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(id)]
        )
        return db.changesCount > 0
    }

    static func fetchRow(id: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(columns) FROM source_contexts WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(id)]
        )
    }

    static func fetchRowsForNote(noteID: UUID, in db: Database) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT \(columns) FROM source_contexts
                WHERE note_id = ?
                ORDER BY created_at_ms, id
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]
        )
    }

    /// 写入侧错误归一化：部分唯一索引冲突 → primaryConflict（PK 冲突是
    /// `SQLITE_CONSTRAINT_PRIMARYKEY`，扩展码不同，不会误吞）；note
    /// 外键失败 → missingNote；其余 DatabaseError 原样上抛。
    static func mapWriteError(_ error: DatabaseError, noteID: UUID) -> Error {
        switch error.extendedResultCode {
        case .SQLITE_CONSTRAINT_UNIQUE:
            return SourceContextError.primaryConflict(noteID: noteID)
        case .SQLITE_CONSTRAINT_FOREIGNKEY:
            return SourceContextError.missingNote(noteID: noteID)
        default:
            return error
        }
    }

    static func decode(_ row: Row) throws -> SourceContext {
        let idValue: String = row["id"]
        let noteIDValue: String = row["note_id"]
        let sourceTypeValue: String = row["source_type"]
        guard let sourceType = SourceContextType(rawValue: sourceTypeValue) else {
            throw SourceContextRepositoryError.invalidPersistedValue(
                field: "source_type"
            )
        }
        let createdAtMilliseconds: Int64 = row["created_at_ms"]
        let isPrimaryValue: Int = row["is_primary"]
        return SourceContext(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            noteID: try DatabaseValueCodec.decodeUUID(noteIDValue),
            sourceType: sourceType,
            originalSentence: row["original_sentence"],
            surroundingText: row["surrounding_text"],
            sourceTitle: row["source_title"],
            sourceURL: row["source_url"],
            sourceApp: row["source_app"],
            imageReference: row["image_reference"],
            dictionaryEntryID: row["dictionary_entry_id"],
            dictionaryVersion: row["dictionary_version"],
            dictionarySenseKey: row["dictionary_sense_key"],
            selectedGlossLanguage: row["selected_gloss_language"],
            isPrimary: isPrimaryValue == 1,
            createdAt: DatabaseValueCodec.decodeDate(
                milliseconds: createdAtMilliseconds
            )
        )
    }
}
