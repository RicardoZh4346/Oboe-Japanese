import Foundation

/// `source_contexts` 表的持久层契约（v15，设计 §6.1/§6.2）。
///
/// 写入语义：
/// - 调用方（capture commit / 句析批量制卡）先用 `SourceContextService`
///   把 `SourceContextDraft` 装配成 `SourceContext`，再在 commit 事务内
///   写入；同一 `operationID` 的重试由 commit receipt 幂等层负责，本协议
///   不感知 operationID。
/// - 「有来源时最多一个 primary」由部分唯一索引
///   `source_contexts_one_primary` 兜底；冲突映射为
///   `SourceContextError.primaryConflict`；note 不存在的外键失败映射为
///   `SourceContextError.missingNote`。
public protocol SourceContextRepository: Sendable {
    /// 写入一条已装配好的来源。`isPrimary = true` 且同 Note 已有 primary
    /// 时抛 `SourceContextError.primaryConflict`——先降级（service 的
    /// `resolvePrimary`）或显式 `setPrimary` 切换。
    func insert(_ context: SourceContext) async throws

    /// 句析批量制卡：同一写事务内逐条写入，任一失败整批回滚。错误映射
    /// 与 `insert` 相同（以失败行的 noteID 报告）。
    func insertAll(_ contexts: [SourceContext]) async throws

    func fetch(id: UUID) async throws -> SourceContext?

    /// 同 Note 的全部来源，按 `(created_at_ms, id)` 升序——与
    /// `source_contexts_on_note` 索引同序，Review 背面按此展示。
    func fetchForNote(noteID: UUID) async throws -> [SourceContext]

    /// 该 Note 当前唯一 primary；无来源或全部非 primary 时返回 nil。
    func fetchPrimary(noteID: UUID) async throws -> SourceContext?

    /// 显式切换主来源：同一事务内先把该 Note 其它行的 `is_primary`
    /// 清零再置目标行为 1，避免部分唯一索引瞬时冲突。目标行不存在或不
    /// 属于该 Note 时抛 `SourceContextRepositoryError.contextNotFound`
    /// 并整体回滚（原 primary 保持不变）。
    func setPrimary(contextID: UUID, noteID: UUID) async throws

    /// 删除一条来源；返回是否真的删掉了行（重复删除返回 false 而不是
    /// 报错，与 `AttachmentRepository.delete` 同语义）。
    func delete(id: UUID) async throws -> Bool

    /// source_contexts 侧持有的非空图片引用集合——统一附件引用查询的
    /// 一个分量（D09），孤儿清理的 keep set 输入。
    func fetchImageReferences() async throws -> Set<String>
}

/// 仓储层自身的失败语义；`SourceContextError`（冻结类型）只覆盖写入冲突
/// 两类，运行期查询失败单独归这里。
public enum SourceContextRepositoryError: Error, Equatable, Sendable {
    /// `setPrimary` 目标行不存在，或行存在但不属于给定 Note。
    case contextNotFound(contextID: UUID, noteID: UUID)
    /// 已持久化字段无法解码（如 source_type 落库值非法）——数据损坏
    /// 信号，不静默吞掉。
    case invalidPersistedValue(field: String)
}
