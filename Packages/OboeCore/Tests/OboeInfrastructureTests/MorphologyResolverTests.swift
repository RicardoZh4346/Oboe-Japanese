import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// `GRDBMorphologyCandidateResolver` 单元测试（内存最小词典）。
/// 覆盖：exact 通道无 POS 门、derived 通道 POS 门控、(cost, rank, entryID)
/// 排序、≤5 截断、OOV 空数组、输入顺序保留、IN-chunk、无逐 token SQL。
final class MorphologyResolverTests: XCTestCase {

    /// 语义化迷你词典：动词/助词/名词混合 + 歧义条目。
    private func makeResolver() throws -> (GRDBMorphologyCandidateResolver, DatabaseQueue) {
        let entries: [MorphologyTestSupport.TestEntry] = [
            .init(id: 1, forms: ["食べる"], readings: ["たべる"], pos: ["v1", "vt"], rank: 1),
            .init(id: 2, forms: ["知る"], readings: ["しる"], pos: ["v5r", "vt"], rank: 1),
            .init(id: 3, forms: ["汁"], readings: ["しる"], pos: ["n"], rank: 1),
            .init(id: 4, forms: ["する"], readings: ["する"], pos: ["vs-i"], rank: 1),
            .init(id: 5, forms: ["して"], readings: ["して"], pos: ["conj"], rank: 3),
            .init(id: 6, forms: ["高い"], readings: ["たかい"], pos: ["adj-i"], rank: 1),
            .init(id: 7, forms: ["私"], readings: ["わたし", "わたくし"], pos: ["n", "pn"], rank: 1),
            .init(id: 8, forms: ["私"], readings: ["わたくし"], pos: ["n"], rank: 2),
            .init(id: 9, forms: ["休む"], readings: ["やすむ"], pos: ["v5m", "vi"], rank: 2),
            // rank NULL 排在 rank 非空之后
            .init(id: 10, forms: ["仕事"], readings: ["しごと"], pos: ["n"], rank: nil),
            .init(id: 11, forms: ["仕事"], readings: ["しごと"], pos: ["n", "vs"], rank: 5),
        ]
        let queue = try MorphologyTestSupport.makeDictionary(entries: entries)
        return (GRDBMorphologyCandidateResolver(reader: queue, datasetVersion: "test-v1"), queue)
    }

    private func span(
        _ surface: String,
        deinflect: [(lemma: String, pos: [JapanesePartOfSpeech], cost: Int, reasons: [String])] = []
    ) -> SpanCandidates {
        SpanCandidates(
            surface: surface,
            normalizedForms: [SearchTextNormalizer.normalize(surface)],
            deinflections: deinflect.map {
                DeinflectionCandidate(
                    surface: surface, lemma: $0.lemma,
                    admissiblePOS: Set($0.pos), reasons: $0.reasons, cost: $0.cost)
            }
        )
    }

    // MARK: - exact 通道

    func testIdentityHitBypassesPOSGate() async throws {
        // identity 候选（reasons 为空）走 exact 通道——即便 admissiblePOS
        // 是活用类全集也命中名词。
        let resolver = try makeResolver().0
        let results = try await resolver.resolveCandidates([span("私")])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.cost == 0 })
        XCTAssertTrue(candidates.contains { $0.entryID == 7 })
        XCTAssertTrue(candidates.contains { $0.entryID == 8 })
        // 歧义保留：单候选升级 resolved 由 service 侧判定，resolver 全量返回。
        XCTAssertEqual(candidates.first?.lemma, "私")
    }

    func testReadingChannelIdentityHit() async throws {
        // 假名写形 exact 命中 readings 通道。
        let resolver = try makeResolver().0
        let results = try await resolver.resolveCandidates([span("わたし")])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertTrue(candidates.contains { $0.entryID == 7 })
        XCTAssertTrue(candidates.contains { $0.reasons.contains("exact.identity.reading") })
    }

    // MARK: - derived 通道 POS 门控

    func testDerivedCandidatesRequirePOSOverlap() async throws {
        let resolver = try makeResolver().0
        // 「してしまった」deinflect 出 しる（v5r 活用推定）——
        // 知る(v5r) POS 相交命中；汁(n) 不相交被门掉。
        let results = try await resolver.resolveCandidates([
            span("してしまった", deinflect: [
                (lemma: "しる", pos: [.v5r], cost: 1, reasons: ["v5r.te-shimau"]),
            ])
        ])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertTrue(candidates.contains { $0.entryID == 2 })
        XCTAssertFalse(candidates.contains { $0.entryID == 3 },
                       "n-only entry must be POS-gated for v5r candidates")
    }

    func testDerivedCandidateV1Chain() async throws {
        let resolver = try makeResolver().0
        let results = try await resolver.resolveCandidates([
            span("食べていた", deinflect: [
                (lemma: "食べる", pos: [.v1], cost: 1, reasons: ["v1.teita"]),
            ])
        ])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertEqual(candidates.first?.lemma, "食べる")
        XCTAssertEqual(candidates.first?.entryID, 1)
        // derived 通道 posCodes 是 entryPOS ∩ admissiblePOS 的交集。
        XCTAssertEqual(candidates.first?.posCodes.sorted(), ["v1"])
    }

    func testVariantFoldedDerivedLemma() async throws {
        let resolver = try makeResolver().0
        // 髙かった → deinflect → 髙い → variant 折叠补充 高い 候选。
        let results = try await resolver.resolveCandidates([
            span("髙かった", deinflect: [
                (lemma: "高い", pos: [.adjI], cost: 1,
                 reasons: ["adj-i.katta", "variant.fold"]),
            ])
        ])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertTrue(candidates.contains { $0.entryID == 6 && $0.lemma == "高い" })
    }

    // MARK: - 排序 / 截断 / OOV

    func testOrderingCostThenRankThenEntryID() async throws {
        let resolver = try makeResolver().0
        // 私: entry7(rank1) < entry8(rank2)；cost 相同按 rank。
        let results = try await resolver.resolveCandidates([span("私")])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertEqual(candidates.map(\.entryID), [7, 8])
    }

    func testOrderingRankNullSortsLast() async throws {
        let resolver = try makeResolver().0
        let results = try await resolver.resolveCandidates([span("仕事")])
        let candidates = try XCTUnwrap(results.first)
        XCTAssertEqual(candidates.map(\.entryID), [11, 10],
                       "rank NULL 应排在 rank 非空之后")
    }

    func testOutOfVocabularyReturnsEmpty() async throws {
        let resolver = try makeResolver().0
        let results = try await resolver.resolveCandidates([span("グスコーブドリ")])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first ?? [], [])
    }

    func testSpanOrderPreservedAndCapFive() async throws {
        let resolver = try makeResolver().0
        let results = try await resolver.resolveCandidates([
            span("グスコーブドリ"),   // OOV
            span("食べる"),           // exact
            span("わたし"),           // readings
        ])
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results[0].isEmpty)
        XCTAssertFalse(results[1].isEmpty)
        XCTAssertFalse(results[2].isEmpty)
        XCTAssertLessThanOrEqual(results[1].count, MorphologyCandidate.maximumRetained)
    }

    // MARK: - IN-chunk / 查询计数（§17 无逐 token SQL）

    func testBatchQueryCountIsSingleDigit() async throws {
        let counter = SQLTraceCounter()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                if case let .statement(statement) = event {
                    counter.record(statement.sql)
                }
            }
        }
        let rawEntries: [MorphologyTestSupport.TestEntry] = [
            .init(id: 1, forms: ["食べる"], readings: ["たべる"], pos: ["v1"], rank: 1),
            .init(id: 2, forms: ["私"], readings: ["わたし"], pos: ["n"], rank: 1),
            .init(id: 3, forms: ["行く"], readings: ["いく"], pos: ["v5k-s"], rank: 1),
        ]
        // 先建库，再换带 trace 的配置重开内存库——直接在 trace 配置下建。
        let queue = try DatabaseQueue(configuration: config)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE dictionary_metadata(key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO dictionary_metadata(key, value)
                    VALUES ('schema_version','1'),('dataset_version','test-v1');
                CREATE TABLE entries(
                    id INTEGER PRIMARY KEY, primary_form TEXT NOT NULL,
                    common_rank INTEGER);
                CREATE TABLE forms(
                    id INTEGER PRIMARY KEY,
                    entry_id INTEGER NOT NULL,
                    text TEXT NOT NULL, normalized_text TEXT NOT NULL);
                CREATE TABLE readings(
                    id INTEGER PRIMARY KEY,
                    entry_id INTEGER NOT NULL,
                    reading TEXT NOT NULL, normalized_reading TEXT NOT NULL);
                CREATE TABLE senses(
                    id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL);
                CREATE TABLE sense_pos(
                    id INTEGER PRIMARY KEY,
                    sense_id INTEGER NOT NULL, code TEXT NOT NULL);
                """)
            for entry in rawEntries {
                try db.execute(
                    sql: "INSERT INTO entries(id, primary_form, common_rank) VALUES (?,?,?)",
                    arguments: [entry.id, entry.forms.first ?? "", entry.rank])
                for form in entry.forms {
                    try db.execute(
                        sql: "INSERT INTO forms(entry_id, text, normalized_text) VALUES (?,?,?)",
                        arguments: [entry.id, form, SearchTextNormalizer.normalize(form)])
                }
                for reading in entry.readings {
                    try db.execute(
                        sql: "INSERT INTO readings(entry_id, reading, normalized_reading) VALUES (?,?,?)",
                        arguments: [entry.id, reading, SearchTextNormalizer.normalize(reading)])
                }
                try db.execute(sql: "INSERT INTO senses(entry_id) VALUES (?)",
                               arguments: [entry.id])
                for code in entry.pos {
                    try db.execute(
                        sql: "INSERT INTO sense_pos(sense_id, code) VALUES (?,?)",
                        arguments: [db.lastInsertedRowID, code])
                }
            }
        }
        counter.record("")  // 标记建库结束位置
        let setupMark = counter.count
        let resolver = GRDBMorphologyCandidateResolver(
            reader: queue, datasetVersion: "test-v1")

        // 一个块级批：20 个 span（模拟一段落的多 token×多 span 枚举）。
        let spans = [
            span("私"), span("食べる"),
            span("食べていた", deinflect: [
                (lemma: "食べる", pos: [.v1], cost: 1, reasons: ["v1.teita"])]),
            span("行かなかった", deinflect: [
                (lemma: "行く", pos: [.v5kS], cost: 1, reasons: ["v5k-s.nai-past"])]),
        ] + (0..<16).map { _ in span("グスコーブドリ\(UUID().uuidString)") }
        _ = try await resolver.resolveCandidates(spans)

        // 查询集：forms + readings（候选键 IN）+ entries + sense_pos
        // + readings-by-entry（回填）——与 span 数无关，≤ 5 条 SELECT。
        let selectCount = counter.count - setupMark
        XCTAssertLessThan(selectCount, 10,
            "per-span SQL 禁止：\(selectCount) 条（应有界常数）; sqls: \(counter.statements)")
        XCTAssertGreaterThanOrEqual(selectCount, 5)
        XCTAssertEqual(counter.count(matching: "FROM forms"), 1)
        XCTAssertGreaterThanOrEqual(counter.count(matching: "FROM readings"), 1)
        XCTAssertEqual(counter.count(matching: "FROM entries"), 1)
        XCTAssertEqual(counter.count(matching: "FROM senses"), 1)
    }

    func testINChunkingSplitsOverChunkSize() async throws {
        // 候选键集合超过 inChunkSize(400) → forms/readings 查询分多块。
        let counter = SQLTraceCounter()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { event in
                if case let .statement(statement) = event {
                    counter.record(statement.sql)
                }
            }
        }
        let queue = try DatabaseQueue(configuration: config)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE dictionary_metadata(key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO dictionary_metadata(key, value)
                    VALUES ('schema_version','1'),('dataset_version','test-v1');
                CREATE TABLE entries(
                    id INTEGER PRIMARY KEY, primary_form TEXT NOT NULL,
                    common_rank INTEGER);
                CREATE TABLE forms(
                    id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL,
                    text TEXT NOT NULL, normalized_text TEXT NOT NULL);
                CREATE TABLE readings(
                    id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL,
                    reading TEXT NOT NULL, normalized_reading TEXT NOT NULL);
                CREATE TABLE senses(
                    id INTEGER PRIMARY KEY, entry_id INTEGER NOT NULL);
                CREATE TABLE sense_pos(
                    id INTEGER PRIMARY KEY,
                    sense_id INTEGER NOT NULL, code TEXT NOT NULL);
                """)
        }
        let setupMark = counter.count
        let resolver = GRDBMorphologyCandidateResolver(
            reader: queue, datasetVersion: "test-v1")
        // 300 个 span × 3 个 distinct lemma keys ≈ 900 keys > 400。
        let spans = (0..<300).map { index in
            SpanCandidates(
                surface: "ヌル\(index)",
                normalizedForms: [
                    "ぬる\(index)", "nul\(index)a", "nul\(index)b",
                ],
                deinflections: []
            )
        }
        _ = try await resolver.resolveCandidates(spans)
        let formsQueries = counter.count(matching: "FROM forms") - 0
        XCTAssertGreaterThanOrEqual(formsQueries - 0, 3,
            "900 keys / 400 per chunk → ≥3 个 forms 块；实际 \(formsQueries)")
        XCTAssertLessThan(formsQueries, 10)
        _ = setupMark
    }

    // MARK: - 数据集版本

    func testDatasetVersionProvider() async throws {
        let resolver = try makeResolver().0
        let version = try await resolver.morphologyDatasetVersion()
        XCTAssertEqual(version, "test-v1")
    }
}
