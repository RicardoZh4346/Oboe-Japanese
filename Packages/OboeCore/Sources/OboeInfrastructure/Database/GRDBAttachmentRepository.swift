import Foundation
import GRDB
import OboeDomain

/// `attachments` 表（schema v14）的 GRDB 实现。
/// 只管元数据：附件字节仍在 `InboxImageStore` 等受控存储里，
/// `image_reference` 维持宽松引用（无 FK），由孤儿清理/备份流程协调。
public struct GRDBAttachmentRepository: AttachmentRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func upsert(_ attachment: StoredAttachment) async throws {
        try Self.validate(attachment)
        try await pool.write { db in
            try Self.upsert(attachment, in: db)
        }
    }

    public func fetch(id: String) async throws -> StoredAttachment? {
        try await pool.read { db in
            try Self.fetchRow(id: id, in: db).map(Self.decode)
        }
    }

    public func fetch(ids: Set<String>) async throws -> [StoredAttachment] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { db in
            try Self.fetchRows(ids: ids, in: db).map(Self.decode)
        }
    }

    public func fetchAll() async throws -> [StoredAttachment] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, relative_path, mime_type, byte_count, sha256,
                           pixel_width, pixel_height, created_at_ms
                    FROM attachments ORDER BY id
                    """
            ).map(Self.decode)
        }
    }

    /// 返回是否真的删掉了行（重复删除返回 false 而不是报错）。
    public func delete(id: String) async throws -> Bool {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM attachments WHERE id = ?",
                arguments: [id]
            )
            return db.changesCount > 0
        }
    }

    public func referencingInboxItemIDs(attachmentID: String) async throws -> [UUID] {
        try await pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM inbox_items
                    WHERE image_reference = ?
                    ORDER BY created_at_ms, id
                    """,
                arguments: [attachmentID]
            ).compactMap { UUID(uuidString: $0) }
        }
    }

    public func referencedAttachmentIDs() async throws -> Set<String> {
        try await pool.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT image_reference
                        FROM inbox_items
                        WHERE image_reference IS NOT NULL
                        """
                )
            )
        }
    }

    public func unreferencedAttachmentIDs() async throws -> Set<String> {
        try await pool.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM attachments
                        WHERE NOT EXISTS (
                            SELECT 1 FROM inbox_items
                            WHERE image_reference = attachments.id
                        )
                        """
                )
            )
        }
    }

    // MARK: - 共享实现（备份恢复管线在写事务里复用）

    /// 字段级校验：id 走与 image_reference 相同的受控字符集；
    /// sha256 必须是小写 64 位十六进制；尺寸/字节非负由 CHECK 兜底，
    /// 这里提前拦截给出领域错误而非裸 SQLite 报错。
    static func validate(_ attachment: StoredAttachment) throws {
        do {
            try InboxImageStore.validateResourceID(attachment.id)
        } catch {
            throw AttachmentError.invalidResourceID(attachment.id)
        }
        guard !attachment.relativePath.isEmpty,
              !attachment.relativePath.hasPrefix("/"),
              !attachment.relativePath.contains(".."),
              !attachment.relativePath.contains("\\") else {
            throw AttachmentError.invalidRelativePath(attachment.relativePath)
        }
        guard PortableBackupPackageFormat.isLowercaseSHA256Hex(attachment.sha256),
              attachment.byteCount >= 0,
              (attachment.pixelWidth ?? 1) > 0,
              (attachment.pixelHeight ?? 1) > 0,
              !attachment.mimeType.isEmpty else {
            throw AttachmentError.metadataConflict(attachment.id)
        }
    }

    /// 同 id 已存在且不可变元数据一致 → no-op（恢复/重复登记的幂等路径）；
    /// 不一致说明同 id 指向了不同字节——数据漂移，抛 metadataConflict。
    static func upsert(_ attachment: StoredAttachment, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO attachments(
                    id, relative_path, mime_type, byte_count, sha256,
                    pixel_width, pixel_height, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [
                attachment.id,
                attachment.relativePath,
                attachment.mimeType,
                attachment.byteCount,
                attachment.sha256,
                attachment.pixelWidth,
                attachment.pixelHeight,
                DatabaseValueCodec.encode(attachment.createdAt)
            ]
        )
        guard db.changesCount == 0 else { return }
        guard let existing = try fetchRow(id: attachment.id, in: db) else { return }
        let existingSHA: String = existing["sha256"]
        let existingPath: String = existing["relative_path"]
        let existingMIME: String = existing["mime_type"]
        let existingBytes: Int64 = existing["byte_count"]
        let existingWidth: Int? = existing["pixel_width"]
        let existingHeight: Int? = existing["pixel_height"]
        guard existingSHA == attachment.sha256,
              existingPath == attachment.relativePath,
              existingMIME == attachment.mimeType,
              existingBytes == attachment.byteCount,
              existingWidth == attachment.pixelWidth,
              existingHeight == attachment.pixelHeight else {
            throw AttachmentError.metadataConflict(attachment.id)
        }
    }

    /// 备份恢复导入路径用的轻量插入：descriptor + 包导出时间。
    /// 与 upsert 同语义（幂等、冲突报错）。
    static func insert(
        descriptor: AttachmentDescriptor,
        createdAtMilliseconds: Int64,
        in db: Database
    ) throws {
        try upsert(
            StoredAttachment(
                descriptor: descriptor,
                createdAt: DatabaseValueCodec.decodeDate(
                    milliseconds: createdAtMilliseconds
                )
            ),
            in: db
        )
    }

    static func fetchRow(id: String, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, relative_path, mime_type, byte_count, sha256,
                       pixel_width, pixel_height, created_at_ms
                FROM attachments WHERE id = ?
                """,
            arguments: [id]
        )
    }

    static func fetchRows(ids: Set<String>, in db: Database) throws -> [Row] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, relative_path, mime_type, byte_count, sha256,
                       pixel_width, pixel_height, created_at_ms
                FROM attachments WHERE id IN (\(placeholders)) ORDER BY id
                """,
            arguments: StatementArguments(Array(ids.sorted()))
        )
    }

    static func decode(_ row: Row) throws -> StoredAttachment {
        let createdAtMilliseconds: Int64 = row["created_at_ms"]
        return StoredAttachment(
            id: row["id"],
            relativePath: row["relative_path"],
            mimeType: row["mime_type"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            pixelWidth: row["pixel_width"],
            pixelHeight: row["pixel_height"],
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: createdAtMilliseconds)
        )
    }
}
