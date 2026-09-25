import Foundation

/// SourceContext 写入路径的纯领域协调（设计 §6.1/§6.2）：不持 DB 依赖，
/// 负责 draft → record 的装配与主来源规则。持久化由
/// `SourceContextRepository` 在调用方事务内完成。
///
/// 主来源规则（冻结语义）：第一版写一条主来源；向已有 primary 的 Note
/// 追加新来源时新来源**默认降级**为非 primary——用户显式选择才经
/// `SourceContextRepository.setPrimary` 切换。
public struct SourceContextService: Sendable {
    public init() {}

    /// 把入口（OCR/Share/Dictionary/manual）构造的 draft 装配成可持久化
    /// 的 `SourceContext`：先 `normalized()`（修剪空白、空串归 nil、
    /// surrounding 截断到有界上限），再由调用方赋予 id/noteID/createdAt。
    ///
    /// 注意：本方法**不**做主来源降级——同 Note 已有 primary 时直接用
    /// `isPrimary = true` 的 draft 装配会撞部分唯一索引；追加来源的
    /// 路径应先过 `resolvePrimary` 或用 `makeContext(from:existing:...)`。
    public func makeContext(
        from draft: SourceContextDraft,
        noteID: UUID,
        now: Date,
        makeID: () -> UUID = { UUID() }
    ) -> SourceContext {
        let normalized = draft.normalized()
        return SourceContext(
            id: makeID(),
            noteID: noteID,
            sourceType: normalized.sourceType,
            originalSentence: normalized.originalSentence,
            surroundingText: normalized.surroundingText,
            sourceTitle: normalized.sourceTitle,
            sourceURL: normalized.sourceURL,
            sourceApp: normalized.sourceApp,
            imageReference: normalized.imageReference,
            dictionaryEntryID: normalized.dictionaryEntryID,
            dictionaryVersion: normalized.dictionaryVersion,
            dictionarySenseKey: normalized.dictionarySenseKey,
            selectedGlossLanguage: normalized.selectedGlossLanguage,
            isPrimary: normalized.isPrimary,
            createdAt: now
        )
    }

    /// 追加来源的完整装配：先按既有来源集合做主来源降级，再装配。
    public func makeContext(
        from draft: SourceContextDraft,
        existing: [SourceContext],
        noteID: UUID,
        now: Date,
        makeID: () -> UUID = { UUID() }
    ) -> SourceContext {
        makeContext(
            from: resolvePrimary(existing: existing, newDraft: draft),
            noteID: noteID,
            now: now,
            makeID: makeID
        )
    }

    /// 主来源裁决：Note 已有 primary 时把 `isPrimary = true` 的新 draft
    /// 降级为非 primary；否则原样返回。显式替换主来源不走这里——由
    /// `setPrimary` 在事务内切换（先清后置，唯一索引不瞬时冲突）。
    public func resolvePrimary(
        existing: [SourceContext],
        newDraft: SourceContextDraft
    ) -> SourceContextDraft {
        guard newDraft.isPrimary,
              existing.contains(where: { $0.isPrimary }) else {
            return newDraft
        }
        var resolved = newDraft
        resolved.isPrimary = false
        return resolved
    }

    /// 一组来源持有的非空图片引用集合（统一附件引用查询的领域侧输入）。
    public func imageReferences(in contexts: [SourceContext]) -> Set<String> {
        Set(
            contexts.compactMap(\.imageReference).filter { !$0.isEmpty }
        )
    }
}
