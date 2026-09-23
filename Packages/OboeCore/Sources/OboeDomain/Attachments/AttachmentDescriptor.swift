import Foundation

/// 便携备份 v7（设计 §11.1）：附件元数据描述符。
/// `id` 是受控资源 ID（与 `inbox_items.image_reference` 相同的契约：
/// [A-Za-z0-9_-]{1,128}），`relativePath` 是包内相对路径
/// （形如 `attachments/<id>.<ext>`），`sha256` 是小写十六进制摘要。
public struct AttachmentDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let relativePath: String
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        id: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        sha256: String,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// `attachments` 表一行的领域形态：descriptor 元数据 + 登记时间。
/// createdAt 只存在于本地库，不进入备份 manifest（行语义是本地登记时间）。
public struct StoredAttachment: Equatable, Sendable {
    public let id: String
    public let relativePath: String
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let createdAt: Date

    public init(
        id: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        sha256: String,
        pixelWidth: Int?,
        pixelHeight: Int?,
        createdAt: Date
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
    }

    public init(descriptor: AttachmentDescriptor, createdAt: Date) {
        self.init(
            id: descriptor.id,
            relativePath: descriptor.relativePath,
            mimeType: descriptor.mimeType,
            byteCount: descriptor.byteCount,
            sha256: descriptor.sha256,
            pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight,
            createdAt: createdAt
        )
    }

    /// 备份/校验语义下的元数据视图（丢弃本地登记时间）。
    public var descriptor: AttachmentDescriptor {
        AttachmentDescriptor(
            id: id,
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: byteCount,
            sha256: sha256,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

public enum AttachmentError: Error, Equatable, Sendable {
    /// 资源 ID 或相对路径不符合受控契约（字符集/长度/结构）。
    case invalidResourceID(String)
    case invalidRelativePath(String)
    /// 同 id 重复登记但不可变元数据不一致（sha256/mime/大小冲突）。
    case metadataConflict(String)
}

/// 附件元数据仓库。只保存元数据，不碰字节——文件读写仍归
/// `InboxImageStore` 等受控存储。同步/去重/孤儿清理都读这张表。
public protocol AttachmentRepository: Sendable {
    /// 登记一条附件元数据。同 id 且不可变字段一致的重复写入是 no-op；
    /// 不一致说明数据漂移，抛 `metadataConflict`。
    func upsert(_ attachment: StoredAttachment) async throws
    func fetch(id: String) async throws -> StoredAttachment?
    /// 批量按 id 查询；返回值只含命中行（缺失 id 不出现在结果里）。
    func fetch(ids: Set<String>) async throws -> [StoredAttachment]
    func fetchAll() async throws -> [StoredAttachment]
    func delete(id: String) async throws -> Bool
    /// 反查：哪些 inbox item 的 `image_reference` 指向该附件。
    func referencingInboxItemIDs(attachmentID: String) async throws -> [UUID]
    /// 当前被 inbox_items 引用的附件 id 集合（孤儿清理的 keep set）。
    func referencedAttachmentIDs() async throws -> Set<String>
    /// 已登记但未被任何 inbox item 引用的附件 id。
    func unreferencedAttachmentIDs() async throws -> Set<String>
}
