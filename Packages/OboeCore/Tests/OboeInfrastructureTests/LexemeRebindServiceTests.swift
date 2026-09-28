import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S19 换库重绑端到端：v1 绑定 + v2 词典——只在原匹配层级内调整，
/// 降级/歧义保留旧值并标记，绝不静默换绑。
final class LexemeRebindServiceTests: XCTestCase {
    private typealias F = DictionaryS19Fixture
    private typealias E = DictionaryS19Fixture.Entry
    private typealias S = DictionaryS19Fixture.Sense
    private typealias G = DictionaryS19Fixture.Gloss

    private var directory: URL!
    private var pool: DatabasePool!
    private var repo: GRDBDictionaryKnowledgeRepository!
    private var knowledge: GRDBVocabularyKnowledgeRepository!
    private var service: LexemeRebindService!

    override func setUpWithError() throws {
        directory = F.temporaryDirectory("LexemeRebind")
        pool = try F.makeAppPool(into: directory)
        repo = GRDBDictionaryKnowledgeRepository(pool: pool)
        knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
        service = LexemeRebindService(
            pool: pool,
            now: { Date(timeIntervalSince1970: 1_700_000_100) })
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func jmdictLexeme(
        entryID: Int64, form: String, reading: String? = nil
    ) async throws -> Lexeme {
        let key = LexicalIdentityKey.jmdict(
            entryID: entryID,
            normalizedForm: SearchTextNormalizer.normalize(form),
            reading: reading)
        return try await knowledge.resolveLexeme(
            key: key,
            seed: Lexeme(
                id: UUID(), key: key, writtenForm: form, reading: reading,
                normalizedLemma: SearchTextNormalizer.normalize(form),
                posFamily: nil, dictionaryVersionAtResolution: "v1",
                resolutionStatus: .resolved,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func bind(
        _ lexeme: Lexeme, entryID: Int64,
        tier: DictionaryMatchTier, dataset: String = "v1"
    ) async throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.upsertBinding(LexemeBindingRecord(
            lexemeID: lexeme.id, entryID: entryID, tier: tier,
            datasetVersion: dataset, status: .current,
            resolvedAt: t, updatedAt: t))
    }

    private func lexemeEntryID(_ lexemeID: UUID) async throws -> Int64? {
        try await pool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT entry_id FROM lexemes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(lexemeID)])
        }
    }

    /// v2 词典：entry 200 收 事/こと；201/202 双収 両/りょう
    /// （歧义）；没有 旧词（→stale）；entry 300 保留 古語/こご。
    private func v2Lookup() async throws -> GRDBDictionaryQualityInspector {
        let queue = try F.makeInMemory(entries: [
            E(id: 200, primaryForm: "事", forms: ["事"],
              readings: ["こと"]),
            E(id: 201, primaryForm: "両", forms: ["両"],
              readings: ["りょう"]),
            E(id: 202, primaryForm: "両", forms: ["両"],
              readings: ["りょうご"]),
            E(id: 300, primaryForm: "古語", forms: ["古語"],
              readings: ["こご"]),
            E(id: 400, primaryForm: "たべる", forms: ["食べる"],
              readings: ["たべる"]),
        ], datasetVersion: "v2")
        return GRDBDictionaryQualityInspector(
            reader: queue, datasetVersion: "v2")
    }

    // MARK: - 同层重绑

    /// exactWritten 层：旧 entry 100 消失，表记在新库唯一命中 200 →
    /// rebound（同事务换绑 lexemes.entry_id）。
    func testReboundWithinExactWrittenTier() async throws {
        let lexeme = try await jmdictLexeme(entryID: 100, form: "事")
        try await bind(lexeme, entryID: 100, tier: .exactWritten)
        let summary = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary.datasetVersion, "v2")
        XCTAssertEqual(summary.rebound, 1)
        let binding = try await repo.binding(lexemeID: lexeme.id)
        XCTAssertEqual(binding?.entryID, 200)
        XCTAssertEqual(binding?.status, .current)
        XCTAssertEqual(binding?.datasetVersion, "v2")
        XCTAssertEqual(binding?.detail, "rebound:100")
        let reboundEntry = try await lexemeEntryID(lexeme.id)
        XCTAssertEqual(reboundEntry, 200)
    }

    /// 同层零命中 → stale，保留旧值；dataset_version 停在旧版
    /// （下一轮词典仍重试）。
    func testStaleKeepsOldBinding() async throws {
        let lexeme = try await jmdictLexeme(entryID: 999, form: "旧詞")
        try await bind(lexeme, entryID: 999, tier: .exactWritten)
        let summary = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary.markedStale, 1)
        let binding = try await repo.binding(lexemeID: lexeme.id)
        XCTAssertEqual(binding?.entryID, 999, "stale 必须保留旧 entry")
        XCTAssertEqual(binding?.status, .stale)
        XCTAssertEqual(binding?.datasetVersion, "v1")
        XCTAssertEqual(binding?.detail, "no_same_tier_match")
        let staleEntry = try await lexemeEntryID(lexeme.id)
        XCTAssertEqual(staleEntry, 999)
    }

    /// 同层多候选 → ambiguousAwaiting，不静默换绑。
    func testAmbiguousKeepsOldBinding() async throws {
        let lexeme = try await jmdictLexeme(
            entryID: 111, form: "両", reading: "りょう")
        try await bind(lexeme, entryID: 111, tier: .exactWritten)
        // v2 里 両 有两个候选；读音 りょう 恰能消歧到 201——
        // lexeme 带 reading=りょう → disambiguate → rebound 201。
        let summary = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary.rebound, 1)
        let binding = try await repo.binding(lexemeID: lexeme.id)
        XCTAssertEqual(binding?.entryID, 201)

        // 无读音版本 → ambiguousAwaiting。
        let l2 = try await jmdictLexeme(entryID: 112, form: "両")
        try await bind(l2, entryID: 112, tier: .exactWritten)
        let summary2 = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary2.markedAmbiguous, 1)
        let b2 = try await repo.binding(lexemeID: l2.id)
        XCTAssertEqual(b2?.entryID, 112, "歧义保留旧值")
        XCTAssertEqual(b2?.status, .ambiguousAwaiting)
    }

    /// 幂等：v2 再跑一轮——已确认绑定不再出现在待核验集。
    func testRebindIsIdempotent() async throws {
        let lexeme = try await jmdictLexeme(entryID: 200, form: "事")
        try await bind(lexeme, entryID: 200, tier: .exactWritten)
        _ = try await service.rebind(lookup: v2Lookup())
        let second = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(second.scanned, 0, "已对齐 v2 的绑定不重扫")
        let binding = try await repo.binding(lexemeID: lexeme.id)
        XCTAssertEqual(binding?.status, .current)
    }

    /// deinflected 层：用 normalizedLemma 重放 lemma 命中。
    func testDeinflectedTierRebind() async throws {
        let lexeme = try await jmdictLexeme(
            entryID: 1, form: "食べなかった", reading: "たべなかった")
        try await bind(lexeme, entryID: 1, tier: .deinflected)
        // normalized_lemma 是 食べなかった——v2 无该 form；
        // 但 deinflected 层按 normalizedLemma 重放…
        // 本 lexeme 的 normalizedLemma=食べなかった 在 v2 无命中 → stale。
        let summary = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary.markedStale, 1)

        // lemma 形 lexeme（normalizedLemma=食べる）→ v2 命中 400。
        let l2 = try await jmdictLexeme(
            entryID: 2, form: "食べる", reading: "たべる")
        try await bind(l2, entryID: 2, tier: .deinflected)
        let s2 = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(s2.rebound, 1)
        let b2 = try await repo.binding(lexemeID: l2.id)
        XCTAssertEqual(b2?.entryID, 400)
    }

    /// 存量（无绑定行）jmdict lexeme → verifiedExisting 核验：
    /// 旧 entry 仍在且表面相容 → 补建 current 绑定。
    func testLegacyLexemeVerifiedExisting() async throws {
        let lexeme = try await jmdictLexeme(
            entryID: 300, form: "古語", reading: "こご")
        // 不写绑定行——模拟 v22 前存量。
        let summary = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary.confirmedCurrent, 1)
        let binding = try await repo.binding(lexemeID: lexeme.id)
        XCTAssertEqual(binding?.tier, .verifiedExisting)
        XCTAssertEqual(binding?.status, .current)
        XCTAssertEqual(binding?.datasetVersion, "v2")
        XCTAssertEqual(binding?.entryID, 300)
    }

    /// 存量 lexeme 的 entry 在新库消失 → 建 stale 绑定，保留旧值。
    func testLegacyLexemeStale() async throws {
        let lexeme = try await jmdictLexeme(entryID: 999, form: "絶版")
        let summary = try await service.rebind(lookup: v2Lookup())
        XCTAssertEqual(summary.markedStale, 1)
        let binding = try await repo.binding(lexemeID: lexeme.id)
        XCTAssertEqual(binding?.tier, .verifiedExisting)
        XCTAssertEqual(binding?.status, .stale)
        XCTAssertEqual(binding?.entryID, 999)
        XCTAssertEqual(binding?.detail, "entry_missing")
    }
}
