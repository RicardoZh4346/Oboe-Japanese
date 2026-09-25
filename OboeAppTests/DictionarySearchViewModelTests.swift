import OboeDomain
import XCTest
@testable import Oboe

/// S06 `DictionarySearchViewModel` 语义测试：空查询短路、不可用降级、
/// keyset 翻页去重、被取代响应按世代号丢弃。
///
/// 仓储侧用 `DictionaryRepository` 桩件驱动真实
/// `DictionaryQueryService`；VM 的 `debounce`/`sleep` 注入点让测试
/// 同步走完整流程，不做真实等待。
@MainActor
final class DictionarySearchViewModelTests: XCTestCase {
    func testEmptyQuerySkipsSearchAndClears() async {
        let repository = StubDictionaryRepository()
        await repository.setEntries([7: makeEntry(7)])
        await repository.setSearchHandler { _ in
            DictionarySearchPage(
                items: [makeHit(7)],
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: "たべる"
            )
        }
        let model = makeModel(repository)
        model.query = "食べる"
        await model.debouncedSearch()
        XCTAssertEqual(model.items.count, 1)

        model.query = ""
        await model.debouncedSearch()

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.nextCursor)
        let requestCount = await repository.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSearchPopulatesItemsAndPaginationState() async {
        let repository = StubDictionaryRepository()
        await repository.setEntries([7: makeEntry(7)])
        let cursor = DictionarySearchCursor(datasetVersion: "test", phase: 0)
        await repository.setSearchHandler { _ in
            DictionarySearchPage(
                items: [makeHit(7)],
                nextCursor: cursor,
                hasMore: true,
                normalizedQuery: "たべる"
            )
        }
        let model = makeModel(repository)
        model.query = "食べる"

        await model.debouncedSearch()

        XCTAssertEqual(model.items.map(\.hit.entryID), [7])
        XCTAssertEqual(model.items.first?.entry?.id, 7)
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.nextCursor, cursor)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isUnavailable)
    }

    func testUnavailableErrorMapsToRetryableState() async {
        let repository = StubDictionaryRepository()
        await repository.setSearchHandler { _ in
            throw DictionaryError.unavailable("missing sqlite")
        }
        let model = makeModel(repository)
        model.query = "食べる"

        await model.debouncedSearch()

        XCTAssertTrue(model.isUnavailable)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testRetryRecoversFromUnavailable() async {
        let repository = StubDictionaryRepository()
        await repository.setSearchHandler { _ in
            throw DictionaryError.unavailable("missing sqlite")
        }
        let model = makeModel(repository)
        model.query = "食べる"
        await model.debouncedSearch()
        XCTAssertTrue(model.isUnavailable)

        await repository.setSearchHandler { _ in
            DictionarySearchPage(
                items: [makeHit(3)],
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: "たべる"
            )
        }
        await model.retry()

        XCTAssertFalse(model.isUnavailable)
        XCTAssertEqual(model.items.map(\.hit.entryID), [3])
    }

    func testLoadMoreAppendsNextPageWithoutDuplicates() async {
        let repository = StubDictionaryRepository()
        let cursor = DictionarySearchCursor(datasetVersion: "test", phase: 0)
        await repository.setSearchHandler { request in
            if request.cursor == nil {
                return DictionarySearchPage(
                    items: [makeHit(1), makeHit(2)],
                    nextCursor: cursor,
                    hasMore: true,
                    normalizedQuery: "たべる"
                )
            }
            // 仓储层按 entry 去重；VM 再对页边界重叠兜底去重。
            return DictionarySearchPage(
                items: [makeHit(2), makeHit(3)],
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: "たべる"
            )
        }
        let model = makeModel(repository)
        model.query = "食べる"
        await model.debouncedSearch()

        await model.loadMore()

        XCTAssertEqual(model.items.map(\.hit.entryID), [1, 2, 3])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.nextCursor)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testSupersededResponseIsDiscarded() async {
        let repository = StubDictionaryRepository()
        let gate = SearchGate()
        await repository.setSearchHandler { request in
            if request.query == "遅い" {
                await gate.wait()
                return DictionarySearchPage(
                    items: [makeHit(1)],
                    nextCursor: nil,
                    hasMore: false,
                    normalizedQuery: "おそい"
                )
            }
            return DictionarySearchPage(
                items: [makeHit(2)],
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: "はやい"
            )
        }
        let model = makeModel(repository)

        model.query = "遅い"
        async let superseded: Void = model.debouncedSearch()
        // 等第一个请求真正进入仓储，再发起取代它的搜索。
        var spins = 0
        while await repository.requestCount() == 0, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        let requestCount = await repository.requestCount()
        XCTAssertEqual(requestCount, 1)

        model.query = "速い"
        await model.debouncedSearch()
        XCTAssertEqual(model.items.map(\.hit.entryID), [2])

        await gate.open()
        await superseded
        // 迟到的旧响应不得覆盖新结果。
        XCTAssertEqual(model.items.map(\.hit.entryID), [2])
        let finalCount = await repository.requestCount()
        XCTAssertEqual(finalCount, 2)
    }

    // MARK: - 测试基建

    private func makeModel(
        _ repository: StubDictionaryRepository
    ) -> DictionarySearchViewModel {
        DictionarySearchViewModel(
            service: DictionaryQueryService(repository: repository),
            debounce: .zero,
            sleep: { _ in }
        )
    }
}

private func makeHit(_ id: Int64, form: String = "食べる") -> DictionaryHit {
    DictionaryHit(
        entryID: id,
        matchedForm: form,
        matchedSurfaces: [form],
        channel: .form,
        reason: .exact
    )
}

private func makeEntry(_ id: Int64, form: String = "食べる") -> DictionaryEntry {
    DictionaryEntry(
        id: id,
        primaryForm: form,
        commonRank: nil,
        forms: [],
        readings: [],
        senses: []
    )
}

/// 单槽闸门：持有 `wait` 调用直至 `open`。
private actor SearchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// `DictionaryRepository` 桩件：按请求分发到可替换 handler，
/// entries/metadata/sources 走可配置静态数据。
private actor StubDictionaryRepository: DictionaryRepository {
    private var requests: [DictionarySearchRequest] = []
    private var entriesByID: [Int64: DictionaryEntry] = [:]
    private var searchHandler:
        @Sendable (DictionarySearchRequest) async throws -> DictionarySearchPage

    init() {
        searchHandler = { _ in
            DictionarySearchPage(
                items: [],
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: ""
            )
        }
    }

    func requestCount() -> Int { requests.count }

    func setEntries(_ entries: [Int64: DictionaryEntry]) {
        entriesByID = entries
    }

    func setSearchHandler(
        _ handler: @escaping @Sendable (DictionarySearchRequest) async throws -> DictionarySearchPage
    ) {
        searchHandler = handler
    }

    func metadata() async throws -> DictionaryMetadata {
        DictionaryMetadata(
            schemaVersion: "1",
            datasetVersion: "test",
            dictionaryVersion: "test"
        )
    }

    func search(_ request: DictionarySearchRequest) async throws -> DictionarySearchPage {
        requests.append(request)
        return try await searchHandler(request)
    }

    func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
        ids.compactMap { entriesByID[$0] }
    }

    func entry(id: Int64) async throws -> DictionaryEntry? {
        entriesByID[id]
    }

    func sources() async throws -> [DictionarySourceInfo] { [] }
}
