import Foundation

/// 词典查询协调服务（S06 / 技术文档 §3、§4.4）。
///
/// 纯协调层，不直接访问数据库：
/// 1. 构造 `DictionarySearchRequest`（截断 128 字符、clamp limit、
///    由 `SearchTextNormalizer` 算 normalizedQuery——与产物 normalized_*
///    列同一算法 `oboe-search-normalizer/1`）；
/// 2. 若注入 `Deinflecting`，先取候选、**跳过 `isTruncationMarker`**
///    标记条，其余候选（含零成本原形）随请求下传；是否截断透传给 UI；
/// 3. `repository.search` 一次性返回 exact → deinflected → prefix 的
///    稳定页序（候选存在性、JMdict POS 交集过滤、entry 去重由仓储完成）；
/// 4. 用 `entries(ids:)` 按页命中批量取详情组装结果。
///
/// 取消/乱序防抖由调用方（UI）负责；本服务无状态、可重入。
public struct DictionaryQueryService: Sendable {
    /// 默认页大小（§4.4：30）
    public static let defaultPageSize = DictionarySearchRequest.defaultLimit
    /// 最大页大小（§4.4：100）
    public static let maxPageSize = DictionarySearchRequest.maxLimit

    private let repository: any DictionaryRepository
    private let deinflector: (any Deinflecting)?

    /// - Parameters:
    ///   - repository: 只读词典仓储
    ///   - deinflector: 可选变形还原器；nil 时退化为纯字面搜索
    public init(
        repository: any DictionaryRepository,
        deinflector: (any Deinflecting)? = nil
    ) {
        self.repository = repository
        self.deinflector = deinflector
    }

    /// 用户查询入口：query 为原始输入（Kanji/Kana/变形后的活用语均可），
    /// cursor 为上一页 `nextCursor`（词典版本变化后由仓储自动重置回第一页）。
    /// - Returns: 命中 + 详情 + 翻页状态
    public func search(
        query: String,
        cursor: DictionarySearchCursor? = nil,
        limit: Int = DictionaryQueryService.defaultPageSize
    ) async throws -> DictionarySearchOutcome {
        var candidates: [DeinflectionCandidate] = []
        var deinflectionWasTruncated = false
        if let deinflector {
            let produced = deinflector.candidates(for: query)
            deinflectionWasTruncated = produced.contains(where: \.isTruncationMarker)
            candidates = produced.filter { !$0.isTruncationMarker }
        }
        let request = DictionarySearchRequest(
            query: query,
            candidates: candidates,
            limit: limit,
            cursor: cursor
        )
        let page = try await repository.search(request)
        // 批量取详情：按页内命中顺序排好 id 传入（entries(ids:) 保序语义）。
        var seen = Set<Int64>()
        let ids = page.items.map(\.entryID).filter { seen.insert($0).inserted }
        let details = try await repository.entries(ids: ids)
        let detailByID = Dictionary(
            details.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return DictionarySearchOutcome(
            items: page.items.map { hit in
                DictionarySearchItem(hit: hit, entry: detailByID[hit.entryID])
            },
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            normalizedQuery: page.normalizedQuery,
            deinflectionWasTruncated: deinflectionWasTruncated
        )
    }

    /// 词条详情（详情页/制卡预填用）。
    public func entry(id: Int64) async throws -> DictionaryEntry? {
        try await repository.entry(id: id)
    }

    /// 词典元数据（兼容性探测/调试页用）。
    public func metadata() async throws -> DictionaryMetadata {
        try await repository.metadata()
    }

    /// Sources/Licenses 事实源。
    public func sources() async throws -> [DictionarySourceInfo] {
        try await repository.sources()
    }
}

/// 服务层单条结果：命中信息 + 聚合详情（详情缺失时 entry 为 nil，
/// 例如并发换库导致的不一致——调用方按"该条不可用"处理，不崩溃）。
public struct DictionarySearchItem: Equatable, Sendable {
    public let hit: DictionaryHit
    public let entry: DictionaryEntry?

    public init(hit: DictionaryHit, entry: DictionaryEntry?) {
        self.hit = hit
        self.entry = entry
    }
}

/// 服务层搜索结果。
public struct DictionarySearchOutcome: Equatable, Sendable {
    /// 页序与 `DictionarySearchPage` 一致：
    /// 规范化精确（reason `.exact`/`.normalized`）→ 变形还原
    /// （`.deinflected`，`hit.reasonChain`/`matchedLemma` 可展示）→
    /// 规范化前缀（`.prefix`）。同一 entry 全局只出现一次。
    public let items: [DictionarySearchItem]
    public let nextCursor: DictionarySearchCursor?
    public let hasMore: Bool
    /// 实际生效的规范化查询串
    public let normalizedQuery: String
    /// 变形搜索是否因预算耗尽被截断（UI 可提示"结果可能不全"）
    public let deinflectionWasTruncated: Bool

    public init(
        items: [DictionarySearchItem],
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
