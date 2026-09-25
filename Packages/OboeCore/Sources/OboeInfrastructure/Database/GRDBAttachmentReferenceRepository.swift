import Foundation
import GRDB
import OboeDomain

/// 统一附件引用查询（D09，设计 §6.3）的 GRDB 实现。
///
/// 当前并集 = `inbox_items.image_reference ∪ source_contexts.image_reference`
/// （空串与 NULL 不计）。「已持久化且持图的草稿」暂无覆盖：现行
/// `drafts.payload_json` / `inbox_processing_contexts.resume_payload_json`
/// 格式里没有图片引用字段，草稿只能经其存活的 inbox item 持图——该
/// 不变量由协议文档声明。待续编 payload 引入来源草稿的
/// `imageReference` 后，需在本实现扩展第三分量并产出 `.draft` owner。
public struct GRDBAttachmentReferenceRepository: AttachmentReferenceRepository,
    Sendable
{
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func referencedResourceIDs() async throws -> Set<String> {
        try await pool.read { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT image_reference FROM inbox_items
                        WHERE image_reference IS NOT NULL
                          AND image_reference <> ''
                        UNION
                        SELECT image_reference FROM source_contexts
                        WHERE image_reference IS NOT NULL
                          AND image_reference <> ''
                        """
                )
            )
        }
    }

    public func isReferenced(_ resourceID: String) async throws -> Bool {
        guard !resourceID.isEmpty else { return false }
        return try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM inbox_items WHERE image_reference = ?
                    ) OR EXISTS(
                        SELECT 1 FROM source_contexts WHERE image_reference = ?
                    )
                    """,
                arguments: [resourceID, resourceID]
            ) ?? false
        }
    }

    /// owner 反查：`.inboxItem` 先于 `.sourceContext`，各自按
    /// `(created_at_ms, id)` 升序，删除对话框的展示顺序稳定。
    /// `.draft` 当前永不产出（见类型文档的覆盖说明）。
    public func referencingOwners(
        of resourceID: String
    ) async throws -> [AttachmentReferenceOwner] {
        guard !resourceID.isEmpty else { return [] }
        return try await pool.read { db in
            var owners: [AttachmentReferenceOwner] = []
            owners += try Self.fetchIDs(
                in: db,
                table: "inbox_items",
                resourceID: resourceID
            ).map(AttachmentReferenceOwner.inboxItem)
            owners += try Self.fetchIDs(
                in: db,
                table: "source_contexts",
                resourceID: resourceID
            ).map(AttachmentReferenceOwner.sourceContext)
            return owners
        }
    }

    /// 两张表的 `id` 列都是 UUID 文本；`table` 只接受本文件内的字面量，
    /// 不接受外部输入（拼接进 SQL）。
    private static func fetchIDs(
        in db: Database,
        table: String,
        resourceID: String
    ) throws -> [UUID] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id FROM \(table)
                WHERE image_reference = ?
                ORDER BY created_at_ms, id
                """,
            arguments: [resourceID]
        ).compactMap { row -> UUID? in
            let value: String = row["id"]
            return try? DatabaseValueCodec.decodeUUID(value)
        }
    }
}
