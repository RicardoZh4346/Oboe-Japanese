import Foundation

/// 引用一个受控附件资源的持久化所有者（D09，设计 §6.3）。删除确认
/// 对话框与孤儿 sweep 用它区分「谁还在引用这张图」。
public enum AttachmentReferenceOwner: Equatable, Sendable {
    /// `inbox_items.image_reference`。
    case inboxItem(UUID)
    /// `source_contexts.image_reference`（v15）。
    case sourceContext(UUID)
    /// 已持久化且持图的草稿（预留——当前 schema 尚无草稿侧图片引用
    /// 列/字段，实现暂时不会产出该 case；见协议文档的覆盖说明）。
    case draft(UUID)
}

/// 统一附件引用查询（D09，设计 §6.3）：回答「这个资源 ID 还被谁引用」。
/// Inbox 删除回调、启动 orphan sweep、export snapshot 清单、restore
/// 引用预检都改走这里的集合，而不是只看 `inbox_items`。
///
/// 当前覆盖：`inbox_items.image_reference ∪ source_contexts.image_reference`。
///
/// 草稿覆盖的现状（缺口，随 commit 集成补齐）：`drafts.payload_json`
/// 与 `inbox_processing_contexts.resume_payload_json` 的现行格式里
/// 没有图片引用字段，因此「已持久化且持图的草稿」目前只能通过其存活
/// 的 inbox item 持图（`inbox_processing_contexts.draft_id` →
/// `inbox_items.image_reference`）——§6.3 允许的不变量：草稿持图期间
/// 宿主 inbox item 必须存活，删除该 item 后草稿不再计为图片所有者。
/// 一旦续编 payload/draft payload 引入 `imageReference` 字段，本协议
/// 实现必须扩展并集（新增列或 payload 扫描），`.draft` owner 随之启用。
public protocol AttachmentReferenceRepository: Sendable {
    /// 当前被任何持久化所有者引用的资源 ID 集合——孤儿清理的 keep set。
    /// 空串与 NULL 引用不计入。
    func referencedResourceIDs() async throws -> Set<String>

    /// 单个资源是否仍被引用。
    func isReferenced(_ resourceID: String) async throws -> Bool

    /// 反查所有者列表，供删除对话框与孤儿 sweep 区分来源类型。顺序
    /// 稳定：先 `.inboxItem` 再 `.sourceContext`，各自按
    /// `(created_at_ms, id)` 升序。
    func referencingOwners(of resourceID: String) async throws
        -> [AttachmentReferenceOwner]
}
