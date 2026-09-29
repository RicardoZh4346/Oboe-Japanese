import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S19 v22 仓储测试：schema、artifact 台账幂等、绑定读写、
/// entry 级知识态标注。
final class GRDBDictionaryKnowledgeRepositoryTests: XCTestCase {
    private typealias F = DictionaryS19Fixture

    private var directory: URL!
    private var pool: DatabasePool!
    private var repository: GRDBDictionaryKnowledgeRepository!
    private var knowledge: GRDBVocabularyKnowledgeRepository!

    override func setUpWithError() throws {
        directory = F.temporaryDirectory("DictKnowledgeRepo")
        pool = try F.makeAppPool(into: directory)
        repository = GRDBDictionaryKnowledgeRepository(pool: pool)
        knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - helpers

    private func descriptor(
        sha: String = String(repeating: "a", count: 64),
        dataset: String = "v2026-a"
    ) -> DictionaryArtifactDescriptor {
        DictionaryArtifactDescriptor(
            fileSHA256: sha, byteCount: 1024,
            schemaVersion: "1", datasetVersion: dataset,
            dictionaryVersion: dataset, chineseLayerVersion: "zh-v1",
            zhAlignmentRate: 0.99)
    }

    private func jmdictLexeme(
        entryID: Int64, form: String = "事", reading: String? = "こと"
    ) async throws -> Lexeme {
        let key = LexicalIdentityKey.jmdict(
            entryID: entryID,
            normalizedForm: SearchTextNormalizer.normalize(form),
            reading: reading)
        let seed = Lexeme(
            id: UUID(), key: key, writtenForm: form, reading: reading,
            normalizedLemma: SearchTextNormalizer.normalize(form),
            posFamily: "n", dictionaryVersionAtResolution: "v2026-a",
            resolutionStatus: .resolved,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        return try await knowledge.resolveLexeme(key: key, seed: seed)
    }

    private func binding(
        lexemeID: UUID, entryID: Int64,
        tier: DictionaryMatchTier = .exactWritten,
        dataset: String = "v2026-a",
        status: LexemeBindingStatus = .current
    ) -> LexemeBindingRecord {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        return LexemeBindingRecord(
            lexemeID: lexemeID, entryID: entryID, tier: tier,
            datasetVersion: dataset, status: status,
            resolvedAt: t, updatedAt: t)
    }

    // MARK: - schema

    func testSchemaCreatesTablesAndEnforcesConstraints() async throws {
        try await pool.read { db in
            XCTAssertTrue(try db.tableExists("dictionary_artifact_records"))
            XCTAssertTrue(try db.tableExists("lexeme_dictionary_bindings"))
        }
        let lexeme = try await jmdictLexeme(entryID: 1)
        // 非法 tier / status 被 CHECK 拒绝。
        try await pool.write { db in
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO lexeme_dictionary_bindings(
                        lexeme_id, entry_id, match_tier, dataset_version,
                        status, resolved_at_ms, updated_at_ms)
                    VALUES (?, 1, 'bogusTier', 'v', 'current', 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(lexeme.id)]))
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO lexeme_dictionary_bindings(
                        lexeme_id, entry_id, match_tier, dataset_version,
                        status, resolved_at_ms, updated_at_ms)
                    VALUES (?, 1, 'exactWritten', 'v', 'bogus', 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(lexeme.id)]))
        }
        // lexeme 删除 → 绑定 CASCADE。
        try await repository.upsertBinding(
            binding(lexemeID: lexeme.id, entryID: 1))
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM lexemes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(lexeme.id)])
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lexeme_dictionary_bindings")
            XCTAssertEqual(count, 0)
        }
    }

    // MARK: - artifact 台账

    func testArtifactRecordUpsertByChecksum() async throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = try await repository.recordArtifactVerification(
            descriptor(), status: .verified, at: t0)
        // 同 sha 再验：同 id、first_seen 不变、last_verified 更新。
        let secondID = try await repository.recordArtifactVerification(
            descriptor(dataset: "v2026-a2"), status: .verified,
            at: t0.addingTimeInterval(60))
        XCTAssertEqual(firstID, secondID)
        let record = try await repository.latestArtifactRecord()
        XCTAssertEqual(record?.datasetVersion, "v2026-a2")
        XCTAssertEqual(record?.firstSeenAt, t0)
        XCTAssertEqual(
            record?.lastVerifiedAt, t0.addingTimeInterval(60))
        // 不同 sha → 新行。
        _ = try await repository.recordArtifactVerification(
            descriptor(sha: String(repeating: "b", count: 64)),
            status: .checksumMismatch, at: t0.addingTimeInterval(120))
        let history = try await repository.artifactHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.status, .checksumMismatch)
    }

    // MARK: - 绑定读写与重绑决策落库

    func testBindingUpsertAndRebindDecisionPaths() async throws {
        let lexeme = try await jmdictLexeme(entryID: 100)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.upsertBinding(
            binding(lexemeID: lexeme.id, entryID: 100))
        var stored = try await repository.binding(lexemeID: lexeme.id)
        XCTAssertEqual(stored?.entryID, 100)
        XCTAssertEqual(stored?.tier, .exactWritten)
        XCTAssertEqual(stored?.status, .current)

        // rebound：同事务更新绑定 + lexemes.entry_id。
        try await repository.applyRebindDecision(
            lexemeID: lexeme.id, decision: .rebound(entryID: 200),
            newDatasetVersion: "v2026-b", at: t.addingTimeInterval(1))
        stored = try await repository.binding(lexemeID: lexeme.id)
        XCTAssertEqual(stored?.entryID, 200)
        XCTAssertEqual(stored?.status, .current)
        XCTAssertEqual(stored?.datasetVersion, "v2026-b")
        XCTAssertEqual(stored?.detail, "rebound:100")
        let entryID: Int64? = try await pool.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT entry_id FROM lexemes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(lexeme.id)])
        }
        XCTAssertEqual(entryID, 200, "rebound 必须同步 lexemes.entry_id")

        // stale：保留 entry_id 与旧 dataset_version（可重试）。
        try await repository.applyRebindDecision(
            lexemeID: lexeme.id, decision: .stale(detail: "no_same_tier_match"),
            newDatasetVersion: "v2026-c", at: t.addingTimeInterval(2))
        stored = try await repository.binding(lexemeID: lexeme.id)
        XCTAssertEqual(stored?.entryID, 200, "stale 保留旧绑定值")
        XCTAssertEqual(stored?.status, .stale)
        XCTAssertEqual(stored?.datasetVersion, "v2026-b",
                       "stale 不刷新确认版本——留待下轮重试")
        XCTAssertEqual(stored?.detail, "no_same_tier_match")

        // ambiguousAwaiting 同理保留旧值。
        try await repository.applyRebindDecision(
            lexemeID: lexeme.id, decision: .ambiguous(candidateEntryIDs: [200, 201]),
            newDatasetVersion: "v2026-d", at: t.addingTimeInterval(3))
        stored = try await repository.binding(lexemeID: lexeme.id)
        XCTAssertEqual(stored?.entryID, 200)
        XCTAssertEqual(stored?.status, .ambiguousAwaiting)
        XCTAssertTrue(stored?.detail?.hasPrefix("ambiguous:2:") ?? false)
    }

    func testBindingsNeedingReverifyPaginatesByDatasetVersion() async throws {
        let l1 = try await jmdictLexeme(entryID: 1, form: "甲", reading: "こう")
        let l2 = try await jmdictLexeme(entryID: 2, form: "乙", reading: "おつ")
        let l3 = try await jmdictLexeme(entryID: 3, form: "丙", reading: "へい")
        try await repository.upsertBinding(
            binding(lexemeID: l1.id, entryID: 1, dataset: "old"))
        try await repository.upsertBinding(
            binding(lexemeID: l2.id, entryID: 2, dataset: "old"))
        try await repository.upsertBinding(
            binding(lexemeID: l3.id, entryID: 3, dataset: "current"))
        let page = try await repository.bindingsNeedingReverify(
            currentDatasetVersion: "current", after: nil, limit: 10)
        XCTAssertEqual(
            Set(page.map(\.binding.lexemeID)), Set([l1.id, l2.id]))
        // unbound：l1/l2 已有绑定；新建无绑定 lexeme 才出现。
        let l4 = try await jmdictLexeme(entryID: 4, form: "丁", reading: "てい")
        let unbound = try await repository.unboundJMDictLexemes(
            after: nil, limit: 10)
        XCTAssertEqual(unbound.map(\.binding.lexemeID), [l4.id])
        XCTAssertEqual(unbound.first?.binding.tier, .verifiedExisting)
    }

    // MARK: - entry 级知识态标注

    func testKnowledgeStatesForEntryIDs() async throws {
        _ = try await jmdictLexeme(entryID: 42, form: "事")
        let states0 = try await repository.knowledgeStates(forEntryIDs: [42])
        XCTAssertEqual(states0[42], .unknown,
                       "无 unit flag/关联的 lexeme 记 unknown")
        // D19：known = 绑定 entry 的 current unit 上 tooEasy flag。
        let unitID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexical_learning_units(
                        id, identity_kind, identity_key, provider,
                        dictionary_entry_id, semantic_fingerprint,
                        fingerprint_version, lemma, reading,
                        sense_snapshot_json, binding_status,
                        revision, created_at_ms, updated_at_ms)
                    VALUES (
                        ?, 'dictionarySense', ?, 'jmdict', 42, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef', 'v1',
                        '事', NULL, '{}', 'current', 0, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(unitID),
                    "ds:\(unitID.uuidString)"])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms)
                    VALUES (?, 1, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(unitID)])
        }
        let states = try await repository.knowledgeStates(
            forEntryIDs: [42, 999])
        XCTAssertEqual(states[42], .known)
        XCTAssertNil(states[999], "无 lexeme 的 entry 不在结果")
    }
}
