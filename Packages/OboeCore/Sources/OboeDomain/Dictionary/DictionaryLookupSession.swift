import Foundation

/// S19：词典查询会话——在 `DictionaryQueryService` 的稳定 keyset
/// 分页之上叠加两件事：
///
/// 1. **知识态标注**：每个命中附带 `VocabularyKnowledgeState`
///    （entry → jmdict lexeme → 真值表状态）与释义 fallback 决议；
/// 2. **会话失效**：每翻一页校验两个新鲜度戳——
///    `KnowledgeInvalidationCenter.revision`（知识写：override/
///    link/unlink 均 bump）与词典 `dataset_version`。任一变化 →
///    会话进入 invalidated 终态并抛 `sessionInvalidated`，调用方
///    丢弃游标重建会话（§「状态变化使进行中查询会话失效重建」）。
///    失效是终态：已失效会话的后续 nextPage 一律抛同一错误。
///
/// 一致性口径：**页边界**——返回的每一页相对其取页时刻的两个戳
/// 一致；页内不追踪进行中变化（标注读与校验非原子，但任一页返回后
/// 若发生过知识写，下一次翻页必然失效）。
///
/// 词典只读约束：本类型只调 `DictionaryRepository` 的只读方法与
/// 知识侧的只读 seam；所有写路径（ranking/知识态）都在 app 库，
/// 绝不触词典库（实现侧 `Configuration.readonly` 强制）。

/// 命中条目的知识态查询 seam（app 库侧实现）。
public protocol DictionaryEntryKnowledgeStates: Sendable {
    /// `lexemes.provider='jmdict'` 按 entry_id 批查知识态；
    /// 无 lexeme 的 entry 不出现在结果（调用方记 unknown）。
    func knowledgeStates(
        forEntryIDs: [Int64]
    ) async throws -> [Int64: VocabularyKnowledgeState]
}

/// 会话单条结果：搜索命中 + 详情 + 知识态 + 释义 fallback 决议。
public struct DictionaryLookupItem: Equatable, Sendable {
    public let hit: DictionaryHit
    public let entry: DictionaryEntry?
    /// 未注入知识 seam 为 nil；注入但无 lexeme 绑定为 `.unknown`。
    public let knowledgeState: VocabularyKnowledgeState?
    /// zh→en→unavailable 决议（entry 缺失时 `.unavailable`）。
    public let gloss: GlossResolution

    public init(
        hit: DictionaryHit,
        entry: DictionaryEntry?,
        knowledgeState: VocabularyKnowledgeState?,
        gloss: GlossResolution
    ) {
        self.hit = hit
        self.entry = entry
        self.knowledgeState = knowledgeState
        self.gloss = gloss
    }
}

/// 会话分页结果（结构与 `DictionarySearchOutcome` 对齐）。
public struct DictionaryLookupPage: Equatable, Sendable {
    public let items: [DictionaryLookupItem]
    public let nextCursor: DictionarySearchCursor?
    public let hasMore: Bool
    public let normalizedQuery: String
    public let deinflectionWasTruncated: Bool

    public init(
        items: [DictionaryLookupItem],
        nextCursor: DictionarySearchCursor?,
        hasMore: Bool,
        normalizedQuery: String,
        deinflectionWasTruncated: Bool
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.normalizedQuery = normalizedQuery
        self.deinflectionWasTruncated = deinflectionWasTruncated
    }
}

public enum SessionInvalidationReason: String, Equatable, Sendable {
    /// override/link/unlink 等知识写使 revision 变化。
    case knowledgeChanged
    /// 词典 dataset_version 变化（换库）。
    case dictionaryChanged
}

public enum DictionaryLookupError: Error, Equatable, Sendable {
    /// 会话已失效——调用方丢弃全部游标与新会话重建。
    case sessionInvalidated(SessionInvalidationReason)
}

public actor DictionaryLookupSession {
    private let queryService: DictionaryQueryService
    private let knowledge: (any DictionaryEntryKnowledgeStates)?
    private let invalidation: KnowledgeInvalidationCenter
    private let query: String
    private let pageSize: Int

    private var cursor: DictionarySearchCursor?
    private var exhausted = false
    private var invalidatedReason: SessionInvalidationReason?

    /// 页边界基线：首页取页时建立，此后每页比对。
    private var baselineDatasetVersion: String?
    private var baselineKnowledgeRevision: UInt64?

    /// - Parameters:
    ///   - queryService: S06 查询协调服务（含 deinflector 接线）。
    ///   - knowledge: 可选知识标注 seam；nil 时 `knowledgeState` 恒 nil。
    ///   - invalidation: 与应用共享的失效中心——写路径必须经
    ///     `VocabularyKnowledgeService`（或其他 bump 同一 center 的
    ///     服务）才会被本会话观测到。
    public init(
        query: String,
        pageSize: Int = DictionaryQueryService.defaultPageSize,
        queryService: DictionaryQueryService,
        knowledge: (any DictionaryEntryKnowledgeStates)? = nil,
        invalidation: KnowledgeInvalidationCenter
    ) {
        self.query = query
        self.pageSize = pageSize
        self.queryService = queryService
        self.knowledge = knowledge
        self.invalidation = invalidation
    }

    /// 失效后为非 nil（诊断用）。
    public var invalidationReason: SessionInvalidationReason? {
        invalidatedReason
    }

    public var isInvalidated: Bool { invalidatedReason != nil }

    /// 取下一页。失效会话抛 `sessionInvalidated`；正常翻到底后返回
    /// 空页（`hasMore=false`），继续调用仍是幂等空页。
    public func nextPage() async throws -> DictionaryLookupPage {
        if let reason = invalidatedReason {
            throw DictionaryLookupError.sessionInvalidated(reason)
        }
        guard !exhausted else {
            return DictionaryLookupPage(
                items: [], nextCursor: nil, hasMore: false,
                normalizedQuery: "", deinflectionWasTruncated: false)
        }
        try await checkFreshness()
        let outcome = try await queryService.search(
            query: query, cursor: cursor, limit: pageSize)
        let entryIDs = outcome.items.map(\.hit.entryID)
        let states: [Int64: VocabularyKnowledgeState]
        if let knowledge {
            states = try await knowledge.knowledgeStates(forEntryIDs: entryIDs)
        } else {
            states = [:]
        }
        cursor = outcome.nextCursor
        exhausted = !outcome.hasMore
        let items = outcome.items.map { item in
            DictionaryLookupItem(
                hit: item.hit,
                entry: item.entry,
                knowledgeState: knowledge == nil
                    ? nil : (states[item.hit.entryID] ?? .unknown),
                gloss: item.entry.map { GlossFallbackResolver.resolve($0) }
                    ?? .unavailable
            )
        }
        return DictionaryLookupPage(
            items: items,
            nextCursor: outcome.nextCursor,
            hasMore: outcome.hasMore,
            normalizedQuery: outcome.normalizedQuery,
            deinflectionWasTruncated: outcome.deinflectionWasTruncated
        )
    }

    /// 页边界新鲜度校验：首页建立基线；后续页比对两个戳。
    private func checkFreshness() async throws {
        let metadata = try await queryService.metadata()
        let revision = await invalidation.revision
        guard let baseVersion = baselineDatasetVersion,
              let baseRevision = baselineKnowledgeRevision
        else {
            baselineDatasetVersion = metadata.datasetVersion
            baselineKnowledgeRevision = revision
            return
        }
        if metadata.datasetVersion != baseVersion {
            invalidatedReason = .dictionaryChanged
            throw DictionaryLookupError.sessionInvalidated(.dictionaryChanged)
        }
        if revision != baseRevision {
            invalidatedReason = .knowledgeChanged
            throw DictionaryLookupError.sessionInvalidated(.knowledgeChanged)
        }
    }
}
