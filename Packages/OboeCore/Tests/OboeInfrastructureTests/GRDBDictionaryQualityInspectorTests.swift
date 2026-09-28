import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S19 质量层测试：中文覆盖率、rejected 审计、checksum 描述、
/// 只读断言（chmod 444 + 无 journal/wal 侧文件 + 字节不变）。
final class GRDBDictionaryQualityInspectorTests: XCTestCase {
    private typealias F = DictionaryS19Fixture
    private typealias E = DictionaryS19Fixture.Entry
    private typealias S = DictionaryS19Fixture.Sense
    private typealias G = DictionaryS19Fixture.Gloss

    private var directory: URL!

    override func setUpWithError() throws {
        directory = F.temporaryDirectory("DictQuality")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// 标准夹具：覆盖/拒绝样本齐全。
    /// - 1: 完整（zh+eng）2: 仅 eng（覆盖缺口非拒绝）
    /// - 3: 无 forms  4: 无 readings  5: 无 senses  6: sense 无 gloss
    /// - 7: forms 全部 normalized_text 为空（不可检索）
    /// - 孤儿行：form/reading/sense 指向不存在的 entry 999。
    private func makeFixtureFile(
        datasetVersion: String = "v2026-a"
    ) throws -> URL {
        let url = try F.writeDictionaryFile(
            entries: [
                E(id: 1, primaryForm: "事", forms: ["事"],
                  readings: ["こと"], rank: 1,
                  senses: [S(pos: ["n"], glosses: [
                      G(language: "zho", text: "事情"),
                      G(language: "eng", text: "thing")])]),
                E(id: 2, primaryForm: "特別", forms: ["特別"],
                  readings: ["とくべつ"], rank: 2,
                  senses: [S(pos: ["adj-na"], glosses: [
                      G(language: "eng", text: "special")])]),
                E(id: 3, primaryForm: "無表記", forms: [],
                  readings: ["むひょうじ"],
                  senses: [S(pos: ["n"], glosses: [
                      G(language: "zho", text: "无表记")])]),
                E(id: 4, primaryForm: "無読", forms: ["無読"],
                  readings: [],
                  senses: [S(pos: ["n"], glosses: [
                      G(language: "eng", text: "no-reading")])]),
                E(id: 5, primaryForm: "無義", forms: ["無義"],
                  readings: ["むぎ"], senses: []),
                E(id: 6, primaryForm: "無釈", forms: ["無釈"],
                  readings: ["むしゃく"],
                  senses: [S(pos: ["n"], glosses: [])]),
                E(id: 7, primaryForm: "不可检", forms: [],
                  readings: ["ふかけん"],
                  senses: [S(pos: ["n"], glosses: [
                      G(language: "zho", text: "不可检索")])]),
            ],
            datasetVersion: datasetVersion, into: directory)
        // entry 7：补一条 normalized_text 为空的 form + 孤儿行。
        let writer = try DatabaseQueue(path: url.path)
        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO forms(entry_id, text, normalized_text)
                    VALUES (7, '〠', '')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO forms(entry_id, text, normalized_text)
                    VALUES (999, 'orphan', 'orphan');
                    INSERT INTO readings(entry_id, reading, normalized_reading)
                    VALUES (999, 'おるふぁん', 'おるふぁん');
                    """)
        }
        try writer.close()
        return url
    }

    // MARK: - 审计：覆盖率 + rejected 分类

    func testAuditChineseCoverageAndRejections() async throws {
        let url = try makeFixtureFile()
        let inspector = GRDBDictionaryQualityInspector(databaseURL: url)
        let report = try await inspector.audit()

        XCTAssertEqual(report.datasetVersion, "v2026-a")
        // entry 级 zh 覆盖：1(zho sense) + 3(zho) + 7(zho) = 3
        XCTAssertEqual(report.chineseCoverage.entryCount, 7)
        XCTAssertEqual(report.chineseCoverage.entriesWithChinese, 3)
        // sense 级：entry1 zh sense + entry3 zh + entry7 zh = 3 / 7 senses
        XCTAssertEqual(report.chineseCoverage.sensesWithChinese, 3)
        XCTAssertEqual(report.chineseCoverage.zhGlossCount, 3)
        XCTAssertGreaterThan(report.chineseCoverage.engGlossCount, 0)

        func cls(_ reason: DictionaryRejectionReason)
            -> RejectedEntryClass? {
            report.rejections.first { $0.reason == reason }
        }
        XCTAssertEqual(cls(.entryWithoutForms)?.count, 1)
        XCTAssertEqual(cls(.entryWithoutForms)?.sampleEntryIDs, [3])
        XCTAssertEqual(cls(.entryWithoutReadings)?.count, 1)
        XCTAssertEqual(cls(.entryWithoutReadings)?.sampleEntryIDs, [4])
        XCTAssertEqual(cls(.entryWithoutSenses)?.count, 1)
        XCTAssertEqual(cls(.entryWithoutSenses)?.sampleEntryIDs, [5])
        // 无 gloss：entry 6（有 sense 零 gloss）；entry 5 无 sense
        // 归 entryWithoutSenses 不重复计。
        XCTAssertEqual(cls(.entryWithoutGlosses)?.count, 1)
        XCTAssertEqual(cls(.entryWithoutGlosses)?.sampleEntryIDs, [6])
        // entry 7：唯一 form 的 normalized_text 为空。
        XCTAssertEqual(cls(.unsearchableForms)?.count, 1)
        XCTAssertEqual(cls(.unsearchableForms)?.sampleEntryIDs, [7])
        // 孤儿行 3 行（form+reading+reading——form1+reading2…
        // 实际插了 1 form + 1 reading → 2 行）。
        XCTAssertEqual(cls(.orphanedRows)?.count, 2)
        XCTAssertEqual(cls(.orphanedRows)?.sampleEntryIDs, [999])
    }

    // MARK: - checksum / 版本描述

    func testArtifactDescriptorChecksumAndVersion() async throws {
        let url = try makeFixtureFile()
        let inspector = GRDBDictionaryQualityInspector(databaseURL: url)
        let descriptor = try await inspector.artifactDescriptor()
        let digest = try ReaderHashing.digestFile(at: url)
        XCTAssertEqual(descriptor.fileSHA256, digest.sha256)
        XCTAssertEqual(descriptor.byteCount, digest.byteCount)
        XCTAssertEqual(descriptor.datasetVersion, "v2026-a")
        XCTAssertEqual(descriptor.schemaVersion, "1")
        // 文件未被读取路径改动——digest 重算仍一致。
        _ = try await inspector.audit()
        let after = try ReaderHashing.digestFile(at: url)
        XCTAssertEqual(after.sha256, digest.sha256, "读路径不得改文件")
    }

    // MARK: - 只读断言（词典文件不受用户操作影响）

    /// 文件 chmod 0444 后质量层/仓储/解析器所有读路径仍工作，
    /// 且不产生 journal/wal 侧文件——只读打开的硬证据。
    func testReadOnlyOnImmutableFile() async throws {
        let url = try makeFixtureFile()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        let before = try ReaderHashing.digestFile(at: url)

        let inspector = GRDBDictionaryQualityInspector(databaseURL: url)
        _ = try await inspector.audit()
        let descriptor = try await inspector.artifactDescriptor()
        XCTAssertEqual(descriptor.fileSHA256, before.sha256)

        // 只读仓库 + 形态解析器在同一 ro 文件上全部读通。
        let repository = GRDBDictionaryRepository(databaseURL: url)
        _ = try await repository.metadata()
        let page = try await repository.search(
            DictionarySearchRequest(query: "事"))
        XCTAssertFalse(page.items.isEmpty)
        let resolver = GRDBMorphologyCandidateResolver(databaseURL: url)
        let candidates = try await resolver.resolveCandidates([
            SpanCandidates(surface: "事", normalizedForms: ["事"],
                           deinflections: [])
        ])
        XCTAssertFalse(candidates.isEmpty)

        // 无 journal/wal/shm 侧文件——写事务才会产生这些。
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: directory.path)
        XCTAssertEqual(
            siblings.filter { $0 != "test-dict.sqlite" }, [],
            "只读连接不得产生 journal/wal 侧文件：\(siblings)")
        let after = try ReaderHashing.digestFile(at: url)
        XCTAssertEqual(after.sha256, before.sha256)
    }

    /// 词典文件在知识写（override/link）后字节不变——
    /// 「词典只读不被用户 ranking 修改」的端到端断言。
    func testKnowledgeWritesNeverTouchDictionaryFile() async throws {
        let dictURL = try makeFixtureFile()
        let pool = try F.makeAppPool(into: directory)
        let dictDigest = try ReaderHashing.digestFile(at: dictURL)

        let knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
        // 建 lexeme 绑定到 entry 1，再写 override——全程不改词典文件。
        let key = LexicalIdentityKey.jmdict(
            entryID: 1, normalizedForm: "事", reading: "こと")
        let lexeme = try await knowledge.resolveLexeme(
            key: key,
            seed: Lexeme(
                id: UUID(), key: key, writtenForm: "事", reading: "こと",
                normalizedLemma: "事", posFamily: "n",
                dictionaryVersionAtResolution: "v2026-a",
                resolutionStatus: .resolved,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = try await knowledge.setOverride(
            lexemeID: lexeme.id, override: .known,
            at: Date(timeIntervalSince1970: 1_700_000_001))
        let dictAfter = try ReaderHashing.digestFile(at: dictURL)
        XCTAssertEqual(dictAfter.sha256, dictDigest.sha256)
        XCTAssertEqual(dictAfter.byteCount, dictDigest.byteCount)
    }

    // MARK: - DictionaryTieredLookup 实现

    func testTieredLookupChannelsAndOrdering() async throws {
        let queue = try F.makeInMemory(entries: [
            E(id: 10, primaryForm: "事", forms: ["事"],
              readings: ["こと"], rank: 5),
            E(id: 11, primaryForm: "事", forms: ["事"],
              readings: ["じ", "こと"], rank: 2),   // 同形 rank 更前
            E(id: 12, primaryForm: "コト", forms: ["コト"],
              readings: ["こと"], rank: 1),  // 读音通道命中「こと」
        ])
        let lookup = GRDBDictionaryQualityInspector(
            reader: queue, datasetVersion: "test-v2")

        let forms = try await lookup.formMatches(normalizedKey: "事")
        XCTAssertEqual(forms.map(\.entryID), [11, 10],
                       "命中按 (rank, id) 升序")
        let readings = try await lookup.readingMatches(normalizedKey: "こと")
        XCTAssertEqual(readings.map(\.entryID), [12, 11, 10],
                       "命中按 (rank, id) 升序")

        // lemmaMatches：一次调用批量取两个 key 的双通道。
        let grouped = try await lookup.lemmaMatches(
            normalizedKeys: ["事", "とくべつ"])
        XCTAssertEqual(grouped["事"]?.map(\.entryID), [11, 10])
        XCTAssertNil(grouped["とくべつ"],
                     "无命中 key 不出现在结果")

        let surfaces = try await lookup.entrySurfaces(entryIDs: [10, 999])
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertTrue(surfaces[10]?.normalizedForms.contains("事") ?? false)
        XCTAssertTrue(surfaces[10]?.normalizedReadings.contains("こと") ?? false)
        let version = try await lookup.datasetVersion()
        XCTAssertEqual(version, "test-v2")
    }
}
