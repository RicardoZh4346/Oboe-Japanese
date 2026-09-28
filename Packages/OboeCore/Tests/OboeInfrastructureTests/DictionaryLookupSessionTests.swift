import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S19 查询会话测试：跨页不重不漏、知识/词典变化使会话失效、
/// 命中知识态标注、词典文件只读。
final class DictionaryLookupSessionTests: XCTestCase {
    private typealias F = DictionaryS19Fixture
    private typealias E = DictionaryS19Fixture.Entry
    private typealias S = DictionaryS19Fixture.Sense
    private typealias G = DictionaryS19Fixture.Gloss

    private var directory: URL!
    private var dictURL: URL!
    private var pool: DatabasePool!
    private var queryService: DictionaryQueryService!
    private var knowledge: GRDBDictionaryKnowledgeRepository!
    private var invalidation: KnowledgeInvalidationCenter!
    private var knowledgeService: VocabularyKnowledgeService!

    /// 六条前缀「あ」词条 + 一条「事」。
    private static let fixtureEntries: [E] = [
        E(id: 1, primaryForm: "事", forms: ["事"], readings: ["こと"],
          rank: 1,
          senses: [S(pos: ["n"], glosses: [
              G(language: "zho", text: "事情", machine: true)])]),
        E(id: 2, primaryForm: "あか", forms: ["あか"], readings: ["あか"],
          rank: 1,
          senses: [S(pos: ["n"], glosses: [
              G(language: "eng", text: "red")])]),
        E(id: 3, primaryForm: "あき", forms: ["あき"], readings: ["あき"],
          rank: 2,
          senses: [S(pos: ["n"], glosses: [
              G(language: "eng", text: "autumn")])]),
        E(id: 4, primaryForm: "あく", forms: ["あく"], readings: ["あく"],
          rank: 3,
          senses: [S(pos: ["n"], glosses: [
              G(language: "zho", text: "恶")])]),
        E(id: 5, primaryForm: "あけ", forms: ["あけ"], readings: ["あけ"],
          rank: 4,
          senses: [S(pos: ["n"], glosses: [
              G(language: "zho", text: "开")])]),
        E(id: 6, primaryForm: "あこ", forms: ["あこ"], readings: ["あこ"],
          rank: 5,
          senses: [S(pos: ["n"], glosses: [])]),
    ]

    override func setUpWithError() throws {
        directory = F.temporaryDirectory("DictLookupSession")
        dictURL = try F.writeDictionaryFile(
            entries: Self.fixtureEntries, datasetVersion: "v1",
            into: directory)
        pool = try F.makeAppPool(into: directory)
        let repository = GRDBDictionaryRepository(databaseURL: dictURL)
        queryService = DictionaryQueryService(repository: repository)
        knowledge = GRDBDictionaryKnowledgeRepository(pool: pool)
        invalidation = KnowledgeInvalidationCenter()
        let knowledgeRepo = GRDBVocabularyKnowledgeRepository(pool: pool)
        knowledgeService = VocabularyKnowledgeService(
            repository: knowledgeRepo, linking: knowledgeRepo,
            invalidation: invalidation,
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeSession(
        query: String, pageSize: Int = 2,
        withKnowledge: Bool = true
    ) -> DictionaryLookupSession {
        DictionaryLookupSession(
            query: query, pageSize: pageSize,
            queryService: queryService,
            knowledge: withKnowledge ? knowledge : nil,
            invalidation: invalidation)
    }

    // MARK: - 跨页不重不漏

    /// prefix 「あ」共 5 条命中，limit=2 → 3 页；跨页 id 无重复、
    /// 集合完整、前缀段序按 (normalized, id)。
    func testPaginationUniqueAndComplete() async throws {
        let session = makeSession(query: "あ", pageSize: 2)
        var seen: [Int64] = []
        var pages = 0
        while true {
            let page = try await session.nextPage()
            pages += 1
            seen += page.items.map(\.hit.entryID)
            if !page.hasMore { break }
            XCTAssertLessThanOrEqual(pages, 10)
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(Set(seen).count, seen.count, "跨页不得重复")
        XCTAssertEqual(Set(seen), [2, 3, 4, 5, 6], "跨页不得遗漏")
        // 会话终态：继续翻页是幂等空页。
        let tail = try await session.nextPage()
        XCTAssertTrue(tail.items.isEmpty)
        XCTAssertFalse(tail.hasMore)
    }

    // MARK: - 知识态标注 + fallback

    func testItemsCarryKnowledgeAndGloss() async throws {
        // entry 1 → lexeme + known override；entry 2 → 无 lexeme。
        let key = LexicalIdentityKey.jmdict(
            entryID: 1, normalizedForm: "事", reading: "こと")
        let knowledgeRepo = GRDBVocabularyKnowledgeRepository(pool: pool)
        let lexeme = try await knowledgeRepo.resolveLexeme(
            key: key,
            seed: Lexeme(
                id: UUID(), key: key, writtenForm: "事",
                reading: "こと", normalizedLemma: "事", posFamily: "n",
                dictionaryVersionAtResolution: "v1",
                resolutionStatus: .resolved,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = try await knowledgeService.markKnown(lexemeID: lexeme.id)

        let session = makeSession(query: "事")
        let page = try await session.nextPage()
        let hit = try XCTUnwrap(page.items.first { $0.hit.entryID == 1 })
        XCTAssertEqual(hit.knowledgeState, .known)
        // zh gloss 直达 preferred。
        guard case let .preferred(lang, _) = hit.gloss else {
            return XCTFail("entry 1 期望 preferred zh")
        }
        XCTAssertEqual(lang, "zho")
    }

    // MARK: - 会话失效

    /// 会话进行中发生知识写 → 下一页抛 sessionInvalidated
    /// （knowledgeChanged），且失效是终态。
    func testKnowledgeChangeInvalidatesSession() async throws {
        let session = makeSession(query: "あ", pageSize: 2)
        let page1 = try await session.nextPage()
        XCTAssertEqual(page1.items.count, 2)

        // 知识写（override）——经 service 走 invalidation center。
        let key = LexicalIdentityKey.jmdict(
            entryID: 2, normalizedForm: "あか", reading: "あか")
        let knowledgeRepo = GRDBVocabularyKnowledgeRepository(pool: pool)
        let lexeme = try await knowledgeRepo.resolveLexeme(
            key: key,
            seed: Lexeme(
                id: UUID(), key: key, writtenForm: "あか",
                reading: "あか", normalizedLemma: "あか", posFamily: "n",
                dictionaryVersionAtResolution: "v1",
                resolutionStatus: .resolved,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = try await knowledgeService.markKnown(lexemeID: lexeme.id)

        await s19AssertThrowsAsync(try await session.nextPage()) { error in
            XCTAssertEqual(
                error as? DictionaryLookupError,
                .sessionInvalidated(.knowledgeChanged))
        }
        // 终态：再调用抛同一错误。
        await s19AssertThrowsAsync(try await session.nextPage()) { error in
            XCTAssertEqual(
                error as? DictionaryLookupError,
                .sessionInvalidated(.knowledgeChanged))
        }
        let reason = await session.invalidationReason
        XCTAssertEqual(reason, .knowledgeChanged)
    }

    /// 词典 dataset_version 变更 → 会话失效（dictionaryChanged）。
    func testDatasetChangeInvalidatesSession() async throws {
        let session = makeSession(query: "あ", pageSize: 2)
        _ = try await session.nextPage()
        // 模拟换库：测试侧直接改 metadata（仓储本身只读）。
        let writer = try DatabaseQueue(path: dictURL.path)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dictionary_metadata SET value = 'v2'
                    WHERE key = 'dataset_version'
                    """)
        }
        try await writer.close()
        await s19AssertThrowsAsync(try await session.nextPage()) { error in
            XCTAssertEqual(
                error as? DictionaryLookupError,
                .sessionInvalidated(.dictionaryChanged))
        }
    }

    /// 无变化会话照常翻页；无知识 seam 时 state 为 nil。
    func testSessionWithoutKnowledgeSeam() async throws {
        let session = makeSession(query: "事", withKnowledge: false)
        let page = try await session.nextPage()
        XCTAssertEqual(page.items.first?.hit.entryID, 1)
        XCTAssertNil(page.items.first?.knowledgeState)
    }
}
