import Foundation
import XCTest
@testable import OboeDomain

/// S06 `DictionaryQueryService` 协调逻辑测试（纯 Domain，无 DB）：
/// 规范化、候选注入（含截断标记跳过）、limit/长度钳制、游标透传、
/// entries(ids:) 详情组装。
final class DictionaryQueryServiceTests: XCTestCase {

    // MARK: - stubs

    private final class StubRepository: DictionaryRepository, @unchecked Sendable {
        var lastRequest: DictionarySearchRequest?
        var searchCalls = 0
        var requestedIDs: [Int64] = []
        var pageResult = DictionarySearchPage(
            items: [], nextCursor: nil, hasMore: false, normalizedQuery: ""
        )
        var entriesResult: [Int64: DictionaryEntry] = [:]
        var metadataResult = DictionaryMetadata(
            schemaVersion: "1", datasetVersion: "test", dictionaryVersion: "test"
        )
        var sourcesResult: [DictionarySourceInfo] = []

        func metadata() async throws -> DictionaryMetadata { metadataResult }

        func search(_ request: DictionarySearchRequest) async throws -> DictionarySearchPage {
            searchCalls += 1
            lastRequest = request
            var page = pageResult
            // 模拟仓储行为：normalizedQuery 回写
            page = DictionarySearchPage(
                items: pageResult.items,
                nextCursor: pageResult.nextCursor,
                hasMore: pageResult.hasMore,
                normalizedQuery: request.normalizedQuery
            )
            return page
        }

        func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
            requestedIDs = ids
            return ids.compactMap { entriesResult[$0] }
        }

        func entry(id: Int64) async throws -> DictionaryEntry? {
            entriesResult[id]
        }

        func sources() async throws -> [DictionarySourceInfo] { sourcesResult }
    }

    private struct StubDeinflector: Deinflecting {
        let produced: [DeinflectionCandidate]
        func candidates(for surface: String) -> [DeinflectionCandidate] { produced }
    }

    private func makeEntry(_ id: Int64) -> DictionaryEntry {
        DictionaryEntry(
            id: id,
            primaryForm: "form\(id)",
            commonRank: nil,
            forms: [],
            readings: [],
            senses: []
        )
    }

    private func makeHit(_ id: Int64, reason: DictionaryMatchReason = .exact) -> DictionaryHit {
        DictionaryHit(
            entryID: id,
            matchedForm: "form\(id)",
            matchedSurfaces: ["form\(id)"],
            channel: .form,
            reason: reason
        )
    }

    // MARK: - 规范化与钳制

    func testQueryIsNormalizedWithSharedNormalizer() async throws {
        let repository = StubRepository()
        let service = DictionaryQueryService(repository: repository)

        _ = try await service.search(query: "  タベル　")
        XCTAssertEqual(repository.lastRequest?.normalizedQuery, "たべる")
        XCTAssertEqual(repository.lastRequest?.query, "  タベル　")

        _ = try await service.search(query: "ＡＢＣ順")
        XCTAssertEqual(repository.lastRequest?.normalizedQuery, "abc順")
    }

    func testLimitClampedToFrozenBounds() async throws {
        let repository = StubRepository()
        let service = DictionaryQueryService(repository: repository)

        _ = try await service.search(query: "食", limit: 0)
        XCTAssertEqual(repository.lastRequest?.limit, 1)
        _ = try await service.search(query: "食", limit: 999)
        XCTAssertEqual(repository.lastRequest?.limit, DictionaryQueryService.maxPageSize)
        _ = try await service.search(query: "食", limit: 30)
        XCTAssertEqual(repository.lastRequest?.limit, 30)
    }

    func testQueryTruncatedAt128Characters() async throws {
        let repository = StubRepository()
        let service = DictionaryQueryService(repository: repository)
        let long = String(repeating: "あ", count: 200)
        _ = try await service.search(query: long)
        XCTAssertEqual(repository.lastRequest?.query.count, 128)
    }

    // MARK: - deinflection 协调

    func testTruncationMarkersSkippedAndFlagSurfaced() async throws {
        let repository = StubRepository()
        let candidate = DeinflectionCandidate(
            surface: "食べなかった",
            lemma: "食べる",
            admissiblePOS: [.v1],
            reasons: ["否定·过去（なかった）"],
            cost: 2
        )
        let marker = DeinflectionCandidate(
            surface: "食べなかった",
            lemma: "",
            admissiblePOS: [],
            reasons: ["search.truncated"],
            cost: .max,
            isTruncationMarker: true
        )
        let service = DictionaryQueryService(
            repository: repository,
            deinflector: StubDeinflector(produced: [candidate, marker])
        )

        let outcome = try await service.search(query: "食べなかった")
        XCTAssertTrue(outcome.deinflectionWasTruncated)
        XCTAssertEqual(repository.lastRequest?.candidates, [candidate],
                       "截断标记不得下传仓储")
    }

    func testNoDeinflectorMeansNoCandidates() async throws {
        let repository = StubRepository()
        let service = DictionaryQueryService(repository: repository)
        let outcome = try await service.search(query: "食べなかった")
        XCTAssertFalse(outcome.deinflectionWasTruncated)
        XCTAssertEqual(repository.lastRequest?.candidates ?? [], [])
    }

    func testCursorPassesThrough() async throws {
        let repository = StubRepository()
        let service = DictionaryQueryService(repository: repository)
        let cursor = DictionarySearchCursor(
            datasetVersion: "v1",
            phase: 2,
            formBound: .init(normalized: "あい", entryID: 42),
            deinflectedOffset: 0
        )
        _ = try await service.search(query: "あ", cursor: cursor)
        XCTAssertEqual(repository.lastRequest?.cursor, cursor)
    }

    // MARK: - 结果组装

    func testOutcomeAttachesEntriesInHitOrder() async throws {
        let repository = StubRepository()
        repository.pageResult = DictionarySearchPage(
            items: [makeHit(20), makeHit(10, reason: .deinflected), makeHit(30, reason: .prefix)],
            nextCursor: DictionarySearchCursor(datasetVersion: "v", phase: 2),
            hasMore: true,
            normalizedQuery: "q"
        )
        repository.entriesResult = [10: makeEntry(10), 20: makeEntry(20), 30: makeEntry(30)]
        let service = DictionaryQueryService(repository: repository)

        let outcome = try await service.search(query: "q")
        // entries(ids:) 收到按命中序排好的去重 id
        XCTAssertEqual(repository.requestedIDs, [20, 10, 30])
        XCTAssertEqual(outcome.items.map { $0.hit.entryID }, [20, 10, 30])
        XCTAssertEqual(outcome.items.map { $0.entry?.id }, [20, 10, 30])
        XCTAssertEqual(outcome.items[1].hit.reason, .deinflected)
        XCTAssertTrue(outcome.hasMore)
        XCTAssertNotNil(outcome.nextCursor)
        XCTAssertEqual(outcome.normalizedQuery, "q")
    }

    func testMissingEntryYieldsNilDetailNotCrash() async throws {
        let repository = StubRepository()
        repository.pageResult = DictionarySearchPage(
            items: [makeHit(1), makeHit(2)],
            nextCursor: nil,
            hasMore: false,
            normalizedQuery: "q"
        )
        repository.entriesResult = [1: makeEntry(1)] // id=2 缺失
        let service = DictionaryQueryService(repository: repository)

        let outcome = try await service.search(query: "q")
        XCTAssertEqual(outcome.items.count, 2)
        XCTAssertEqual(outcome.items[0].entry?.id, 1)
        XCTAssertNil(outcome.items[1].entry)
    }

    func testMetadataAndSourcesPassThrough() async throws {
        let repository = StubRepository()
        repository.metadataResult = DictionaryMetadata(
            schemaVersion: "1", datasetVersion: "2026.09.24-1",
            dictionaryVersion: "2026.09.24-1", entryCount: 218_807
        )
        repository.sourcesResult = [
            DictionarySourceInfo(
                id: "jmdict_e", name: "JMdict (EDRDG)", version: "2026-09-24-daily",
                url: "https://www.edrdg.org", license: "CC-BY-SA-4.0",
                licenseURL: "https://creativecommons.org/licenses/by-sa/4.0/legalcode",
                retrievedAt: "2026-09-24", sha256: "abc", inputBytes: 63_130_780,
                attribution: "attribution", consumedTables: ["entry"], modifications: "none"
            ),
        ]
        let service = DictionaryQueryService(repository: repository)

        let metadata = try await service.metadata()
        XCTAssertEqual(metadata.entryCount, 218_807)
        let sources = try await service.sources()
        XCTAssertEqual(sources.first?.id, "jmdict_e")
        let entry = try await service.entry(id: 5)
        XCTAssertNil(entry)
    }
}
