import Foundation
import OboeDomain
import Observation

/// S06 词典搜索视图模型。
///
/// 防抖 / 取消 / 乱序防护的职责拆分（与 `KnowledgeSearchModel` 同构）：
/// - 视图侧用 `.task(id: model.query)` 驱动：query 每次变化 SwiftUI
///   取消旧 task 并重启新 task，进行中的请求随 task 取消一起终止；
/// - VM 内部先 `sleep(debounce)` 实现 ~250ms 防抖，再用单调递增的
///   `generation` 做响应顺序防护：被取消/被取代的请求回来后比对世代号，
///   过期结果直接丢弃；
/// - `debounce` 与 `sleep` 都是注入点——单元测试传 `.zero` + no-op
///   sleep，即可同步、确定性地走完整搜索流程，无需真实等待；
///   `DictionaryQueryService` 本体可注入由 `DictionaryRepository`
///   桩件驱动的真实服务，不额外引入协议。
///
/// 词典包缺失/损坏只收敛为 `isUnavailable`（「词典不可用」可重试态），
/// 不抛错、不影响其他 feature（设计 §3：坏包只影响查词）。
@MainActor
@Observable
final class DictionarySearchViewModel {
    /// 搜索框文本（view 的 `.searchable` 直接绑定）。
    var query = ""
    /// 当前结果页序：命中信息 + 聚合详情（详情缺失时 entry 为 nil）。
    private(set) var items: [DictionarySearchItem] = []
    /// keyset 游标，`hasMore == false` 时为 nil。
    private(set) var nextCursor: DictionarySearchCursor?
    private(set) var hasMore = false
    var isLoading = false
    private(set) var isLoadingMore = false
    /// 词典不可用（包缺失/损坏/schema 不符）——非致命，可重试。
    private(set) var isUnavailable = false
    /// 其他非致命错误（view 以 alert 展示）。
    private(set) var errorMessage: String?
    /// 变形搜索被预算截断：结果可能不全（view 顶部横幅）。
    private(set) var deinflectionTruncated = false
    /// 本页实际生效的规范化查询串（与输入不一致时 view 可提示）。
    private(set) var effectiveQuery = ""

    private let service: DictionaryQueryService
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// 单调递增世代号：每次新搜索 +1，迟到的旧响应据此丢弃。
    private var generation = 0
    /// 当前结果集对应的原始查询：翻页必须重放同一 query（游标语义）。
    private var activeQuery = ""
    private var activeNormalizedQuery = ""
    /// 已展示 entryID 集合：翻页追加时去重，保证不重不漏。
    private var seenEntryIDs = Set<Int64>()

    init(
        service: DictionaryQueryService,
        debounce: Duration = .milliseconds(250),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.service = service
        self.debounce = debounce
        self.sleep = sleep
    }

    /// 当前输入规范化后是否为空（view 据此显示 idle/empty 态）。
    var isQueryEmpty: Bool {
        SearchTextNormalizer.normalize(query).isEmpty
    }

    /// `.task(id: query)` 入口：先防抖，再查第一页。
    func debouncedSearch() async {
        await search(delay: debounce)
    }

    /// 「词典不可用」重试：跳过防抖立即重查当前 query。
    func retry() async {
        await search(delay: .zero)
    }

    /// alert 关闭时清掉非致命错误。
    func clearError() {
        errorMessage = nil
    }

    /// 末行出现时触发的 keyset 翻页：以同一 query 重放 `nextCursor`，
    /// 追加时按 entryID 去重。查询已变化 / 正在加载 / 无游标时为 no-op。
    func loadMore() async {
        guard !activeNormalizedQuery.isEmpty,
              SearchTextNormalizer.normalize(query) == activeNormalizedQuery,
              let cursor = nextCursor,
              hasMore,
              !isLoading,
              !isLoadingMore
        else { return }
        let query = activeQuery
        let currentGeneration = generation
        isLoadingMore = true
        do {
            let outcome = try await service.search(query: query, cursor: cursor)
            guard currentGeneration == generation else { return }
            for item in outcome.items where seenEntryIDs.insert(item.hit.entryID).inserted {
                items.append(item)
            }
            nextCursor = outcome.nextCursor
            hasMore = outcome.hasMore
            deinflectionTruncated = deinflectionTruncated || outcome.deinflectionWasTruncated
            isLoadingMore = false
        } catch is CancellationError {
            if currentGeneration == generation { isLoadingMore = false }
        } catch DictionaryError.invalidCursor {
            // 游标失效不是词典不可用：停在当前页，提示重新搜索。
            guard currentGeneration == generation else { return }
            nextCursor = nil
            hasMore = false
            isLoadingMore = false
            errorMessage = "分页状态已失效，请重新搜索。"
        } catch {
            guard currentGeneration == generation else { return }
            isLoadingMore = false
            handle(error)
        }
    }

    private func search(delay: Duration) async {
        generation += 1
        let currentGeneration = generation
        let query = self.query
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        activeQuery = query
        activeNormalizedQuery = normalizedQuery
        errorMessage = nil
        isUnavailable = false
        isLoadingMore = false

        // 空查询 → idle/empty 态：清空结果，不打查询。
        guard !normalizedQuery.isEmpty else {
            items = []
            seenEntryIDs = []
            nextCursor = nil
            hasMore = false
            deinflectionTruncated = false
            effectiveQuery = ""
            isLoading = false
            return
        }

        isLoading = true
        do {
            try await sleep(delay)
            try Task.checkCancellation()
            let outcome = try await service.search(query: query)
            // 世代校验：期间 query 又改过 → 本响应已被取代，丢弃。
            guard currentGeneration == generation, !Task.isCancelled else { return }
            items = outcome.items
            seenEntryIDs = Set(outcome.items.map(\.hit.entryID))
            nextCursor = outcome.nextCursor
            hasMore = outcome.hasMore
            deinflectionTruncated = outcome.deinflectionWasTruncated
            effectiveQuery = outcome.normalizedQuery
            isLoading = false
        } catch is CancellationError {
            if currentGeneration == generation { isLoading = false }
        } catch {
            guard currentGeneration == generation else { return }
            isLoading = false
            items = []
            seenEntryIDs = []
            nextCursor = nil
            hasMore = false
            deinflectionTruncated = false
            handle(error)
        }
    }

    /// `DictionaryError` → UI 状态映射：包缺失/损坏/版本不符收敛为
    /// 「词典不可用」；游标失效仅提示重搜；其余按普通错误展示。
    private func handle(_ error: Error) {
        switch error {
        case DictionaryError.unavailable, DictionaryError.incompatibleSchema:
            isUnavailable = true
        case DictionaryError.invalidCursor:
            errorMessage = "分页状态已失效，请重新搜索。"
        default:
            errorMessage = error.localizedDescription
        }
    }
}
