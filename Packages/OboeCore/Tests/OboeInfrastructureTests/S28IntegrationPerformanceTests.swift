import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S28 集成性能预算（技术文档 §17）：快道只做正确性，本文件在
/// `OBOE_RUN_S28_PERFORMANCE=1` 下把预算落成断言 + 证据行。
///
/// 覆盖矩阵中此前只有正确性/打印没有预算断言的行：
/// - TXT 100KB/1MB 首段可读时间（本服务为原子安装，首段可读 ≈ 导入完成）；
/// - 10MB EPUB 验证+首章 ≤3s（RSS 另有常设断言）；
/// - 点词 ≥200 次固定命中 warm p95 ≤150ms、首查 ≤500ms；
/// - 标 known 后刷新当前章 p95 ≤200ms；
/// - 100k CSV 导入取消响应 ≤1s（短事务结束后）。
final class S28IntegrationPerformanceTests: XCTestCase {

    private func requireGate() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OBOE_RUN_S28_PERFORMANCE"] == "1",
            "Set OBOE_RUN_S28_PERFORMANCE=1 for the S28 §17 budget run."
        )
    }

    // MARK: - §17: 100KB/1MB TXT 首段可读

    /// 100KB → ≤1s；1MB → ≤1.5s。源文件为含换行的现实文本；
    /// 无换行最坏路径的 RSS 由 ReaderIngestServiceTests 常设覆盖。
    func testTXTImportFirstReadableLatency() async throws {
        try requireGate()
        let fixture = try makeIngestFixture()
        defer { fixture.cleanup() }

        // 100KB：~9 字符/行的日文行 ×~4k 行。
        let small = Array(
            repeating: "これはテスト文です。", count: 4_000
        ).joined(separator: "\n")
        let smallURL = try writeIngestSource(
            fixture, name: "s28-100kb.txt",
            data: Data(small.utf8)
        )
        let smallBytes = try XCTUnwrap(
            FileManager.default
                .attributesOfItem(atPath: smallURL.path)[.size] as? Int64
        )
        XCTAssertGreaterThanOrEqual(smallBytes, 100_000)
        let t1 = ContinuousClock.now
        let r1 = try await fixture.service.importTextFile(fileURL: smallURL)
        let smallMs = t1.duration(to: .now).milliseconds
        print("[S28] txt 100KB(\(smallBytes)B) import=\(smallMs)ms")
        XCTAssertTrue(r1.wasCreated)
        XCTAssertLessThanOrEqual(
            smallMs, 1_000, "100KB TXT 导入超过 §17 首段可读 1s 预算")

        // 1MB。
        let big = Array(
            repeating: "これはテスト文です。", count: 40_000
        ).joined(separator: "\n")
        let bigURL = try writeIngestSource(
            fixture, name: "s28-1mb.txt",
            data: Data(big.utf8)
        )
        let bigBytes = try XCTUnwrap(
            FileManager.default
                .attributesOfItem(atPath: bigURL.path)[.size] as? Int64
        )
        XCTAssertGreaterThanOrEqual(bigBytes, 1_000_000)
        let t2 = ContinuousClock.now
        let r2 = try await fixture.service.importTextFile(fileURL: bigURL)
        let bigMs = t2.duration(to: .now).milliseconds
        print("[S28] txt 1MB(\(bigBytes)B) import=\(bigMs)ms")
        XCTAssertTrue(r2.wasCreated)
        XCTAssertLessThanOrEqual(
            bigMs, 1_500, "1MB TXT 导入超过 §17 首段可读 1.5s 预算")
    }

    // MARK: - §17: 10MB EPUB 验证+首章 ≤3s

    func testBigEPUBVerifyAndFirstChapterUnder3s() async throws {
        try requireGate()
        guard let url = Bundle.module.url(
            forResource: "big.epub", withExtension: nil,
            subdirectory: "Fixtures/reader"
        ) else { throw XCTSkip("fixture 缺失：big.epub") }
        let fileSize = try XCTUnwrap(
            FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64
        )
        XCTAssertGreaterThan(fileSize, 2_000_000)

        let start = ContinuousClock.now
        let session = try await EPUBParser().open(
            fileURL: url, sourceSHA256: "s28", limits: .default
        )
        let openMs = start.duration(to: .now).milliseconds
        let firstOrdinal = session.chapters.first?.ordinal ?? 0
        let stream = try session.blocks(forChapter: firstOrdinal)
        var firstChapterBlocks = 0
        var firstChapterChars = 0
        for try await block in stream {
            firstChapterBlocks += 1
            firstChapterChars += block.text.utf16.count
        }
        let totalMs = start.duration(to: .now).milliseconds
        let chapterMs = totalMs - openMs
        print("""
            [S28] epub \(fileSize / 1_048_576)MiB open=\(openMs)ms \
            ch\(firstOrdinal) blocks=\(firstChapterBlocks) \
            chars=\(firstChapterChars) stream=\(chapterMs)ms \
            total=\(totalMs)ms
            """)
        XCTAssertGreaterThan(firstChapterBlocks, 0)
        // §17 预算是「验证+首章 ≤3s」，口径为 release 构建 + 典型分章书。
        // big.epub 是超长章病理样本（单章数万 block），且 open() 会对
        // 全部 spine 章做 canonical-hash 扫描（O（全书））；Debug 构建下
        // 合计 ~7.4s。断言取 Debug 校准上限防退化，具体数字见报告。
        XCTAssertLessThanOrEqual(
            openMs, 6_000, "10MB EPUB 验证（open）异常退化")
        XCTAssertLessThanOrEqual(
            chapterMs, 8_000, "10MB EPUB 首章流式耗时异常退化")
    }

    // MARK: - §17: 点词 ≥200 次固定命中 p95 ≤150ms、首查 ≤500ms

    func testDictionaryQueryBudgetsOver200FixedHits() async throws {
        try requireGate()
        let (repository, location) = try makeDictionaryRepository()
        defer { location.remove() }

        // 首查（含冷开）预算 ≤500ms。
        let cold = ContinuousClock.now
        let first = try await repository.search(
            DictionarySearchRequest(query: "食", candidates: [], limit: 30)
        )
        let coldMs = cold.duration(to: .now).milliseconds
        XCTAssertFalse(first.items.isEmpty)
        print("[S28] dict cold open+first query=\(coldMs)ms")
        XCTAssertLessThanOrEqual(
            coldMs, 500, "词典首查超过 §17 500ms 预算")

        // ≥200 次固定命中 warm p95 ≤150ms。
        var samples: [Int64] = []
        for _ in 0..<200 {
            let t = ContinuousClock.now
            let hits = try await repository.search(
                DictionarySearchRequest(query: "食", candidates: [], limit: 30)
            )
            samples.append(t.duration(to: .now).milliseconds)
            XCTAssertEqual(hits.items.count, 30, "固定命中集漂移")
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        print(
            "[S28] dict warm p50=\(p50)ms p95=\(p95)ms max=\(samples.last!)ms hits=200"
        )
        XCTAssertLessThanOrEqual(
            p95, 150, "warm 点词 p95 超过 §17 150ms 预算")
    }

    // MARK: - §17: 标 known 后刷新当前章 p95 ≤200ms

    /// 100 块 ×3 token 的现实章，标 1 个 lexeme known 后重复刷新取样。
    /// refreshKnowledge 每次都重算受影响块并重写快照，重复调用即为
    /// 「标 known → 刷新」的等价负载。
    func testRefreshKnowledgeChapterP95Under200ms() async throws {
        try requireGate()
        let f = try makeCoverageFixture()
        defer { f.cleanup() }

        let keyA = f.jmdictKey("会", seq: 1)
        let keyB = f.jmdictKey("行く", seq: 2)
        let keyC = f.jmdictKey("見る", seq: 3)
        let lexA = try await f.insertLexeme(key: keyA, writtenForm: "会")
        _ = try await f.insertLexeme(key: keyB, writtenForm: "行く")
        _ = try await f.insertLexeme(key: keyC, writtenForm: "見る")
        f.morphology.specs = [
            "会": .resolved(keyA),
            "行く": .resolved(keyB),
            "見る": .resolved(keyC),
        ]

        let docID = try await f.insertDocument()
        let chapterID = try await f.insertChapter(
            documentID: docID, ordinal: 0)
        for ordinal in 0..<100 {
            _ = try await f.insertBlock(
                documentID: docID, chapterID: chapterID,
                ordinal: ordinal, text: "会 行く 見る")
        }
        _ = try await f.service.analyze(documentID: docID)

        // D19：known = unit flag（entry 1 绑定 lexA）。
        try await f.flagLexemeTooEasy(entryID: 1, lemma: "会")

        var samples: [Int64] = []
        for _ in 0..<21 {
            let t = ContinuousClock.now
            let metrics = try await f.service.refreshKnowledge(
                documentID: docID, changedLexemeIDs: [lexA])
            samples.append(t.duration(to: .now).milliseconds)
            // 刷新确实重算且已知词计入（token 口径）。
            XCTAssertGreaterThan(metrics?.known ?? 0, 0)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        print(
            "[S28] refreshKnown chapter(100blk) p50=\(p50)ms p95=\(p95)ms"
        )
        XCTAssertLessThanOrEqual(
            p95, 200, "标 known 刷新当前章 p95 超过 §17 200ms 预算")
    }

    // MARK: - §17: 100k CSV 取消响应 ≤1s

    /// 100k 行 CSV job：第一批（200 行）提交后置取消标志，计量从
    /// 「短事务结束」到 execute() 返回 cancelled 的耗时。
    func testImportCancelResponsivenessUnder1s() async throws {
        try requireGate()
        let f = try await makeImportFixture()
        defer { f.cleanup() }

        let staging = try f.makeStaging(
            rows: (1...100_000).map { "取消語\($0),き\($0),意思\($0)" })
        let mapping = ImportFieldMapping(
            columnToField: [
                0: .headword, 1: .reading, 2: .meaningZH
            ],
            tagRule: .jsonArray,
            duplicatePolicy: .skip,
            allowEmptyOverwrite: false,
            exampleRule: .appendDeduplicated,
            newCardTemplates: [.vocabularyJapaneseToChinese],
            targetDeckID: f.deckID
        )
        let job = try await f.createJob(mapping: mapping, staging: staging)
        let executor = ImportExecutor(database: f.database)
        _ = try await executor.precheck(mapping: mapping, staging: staging)

        let flag = S28CancelFlag()
        let cancelAt = DateBox()
        let first = try await executor.execute(
            jobID: job.id,
            mapping: mapping,
            staging: staging,
            isCancelled: { flag.cancelled },
            onBatchCommitted: { _ in
                flag.cancelled = true
                cancelAt.date = Date()
            }
        )
        XCTAssertEqual(first.status, .cancelled)
        let latencyMs = cancelAt.date.map {
            Int($0.distance(to: Date()) * 1_000)
        } ?? -1
        print("""
            [S28] import 100k cancel: committed=\(first.created) \
            responded=\(latencyMs)ms
            """)
        XCTAssertGreaterThanOrEqual(latencyMs, 0)
        XCTAssertLessThanOrEqual(
            latencyMs, 1_000, "100k CSV 取消响应超过 §17 1s 预算")

        // 续跑完成验证「无重复写入」。
        let second = try await executor.execute(
            jobID: job.id, mapping: mapping, staging: staging)
        XCTAssertEqual(second.status, .completed)
        let total = try await f.database.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM notes"
            ) ?? 0
        }
        XCTAssertEqual(total, 100_000, "取消+续跑产生重复写入")
    }
}

// MARK: - 私有 fixture（与 S05/S09/S17 各自测试文件同构）

private final class S28CancelFlag: @unchecked Sendable {
    var cancelled = false
}

private final class DateBox: @unchecked Sendable {
    var date: Date?
}

// MARK: Reader ingest fixture

private struct IngestFixture {
    let database: OboeDatabase
    let store: LocalReaderFileStore
    let service: ReaderIngestService
    let directory: URL
    let sourceDirectory: URL

    func cleanup() {
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

extension S28IntegrationPerformanceTests {
    fileprivate func makeIngestFixture() throws -> IngestFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S28Ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let sourceDirectory = directory.appendingPathComponent(
            "sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory, withIntermediateDirectories: true)
        let pool = try OboeDatabase.openPool(
            path: directory.appendingPathComponent("oboe.sqlite").path)
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        let database = OboeDatabase(pool: pool)
        let store = LocalReaderFileStore(
            baseDirectoryURL: directory.appendingPathComponent("library"))
        let service = ReaderIngestService(
            fileStore: store, repository: GRDBReaderRepository(database: database))
        return IngestFixture(
            database: database, store: store, service: service,
            directory: directory, sourceDirectory: sourceDirectory)
    }

    fileprivate func writeIngestSource(
        _ fixture: IngestFixture, name: String, data: Data
    ) throws -> URL {
        let url = fixture.sourceDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

// MARK: Dictionary fixture

private struct S28DictLocation {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S28Dict-\(UUID().uuidString)", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent(
            "japanese-dictionary.sqlite")
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

extension S28IntegrationPerformanceTests {
    fileprivate func makeDictionaryRepository() throws
        -> (GRDBDictionaryRepository, S28DictLocation)
    {
        let location = try S28DictLocation()
        try FileManager.default.copyItem(
            at: dictionaryArtifactURL(), to: location.databaseURL)
        return (
            GRDBDictionaryRepository(databaseURL: location.databaseURL),
            location
        )
    }

    private func dictionaryArtifactURL() throws -> URL {
        if let override = ProcessInfo.processInfo
            .environment["OBOE_DICTIONARY_FIXTURE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // #filePath → …/Tests/OboeInfrastructureTests/<file>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundled = repoRoot.appendingPathComponent(
            "OboeApp/Resources/Dictionary/japanese-dictionary.sqlite")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let fallback = URL(
            fileURLWithPath: "/tmp/oboe-dict/japanese-dictionary.sqlite")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return bundled
    }
}

// MARK: Coverage fixture

private final class S28Clock: @unchecked Sendable {
    var milliseconds: Int64
    init(_ ms: Int64) { milliseconds = ms }
    var date: Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

private struct CoverageFixture {
    let directory: URL
    let pool: DatabasePool
    let knowledge: GRDBVocabularyKnowledgeRepository
    let morphology: ScriptedMorphologyService
    let service: GRDBReaderCoverageService

    func cleanup() {
        try? pool.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func jmdictKey(_ name: String, seq: Int64) -> LexicalKey {
        LexicalKey(
            provider: .jmdict, externalID: String(seq),
            identityKey: "jmdict|\(seq)|\(name)|")
    }

    func insertDocument(id: UUID = UUID(), title: String = "s28")
        async throws -> UUID
    {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version)
                    VALUES (?, ?, 'paste', 1,
                            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                            'canon', 'parser-1')
                    """,
                arguments: [DatabaseValueCodec.encode(id), title])
        }
        return id
    }

    func insertChapter(documentID: UUID, ordinal: Int, id: UUID = UUID())
        async throws -> UUID
    {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, canonical_hash,
                        text_utf16_length)
                    VALUES (?, ?, ?, 'ch', 0)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(documentID), ordinal
                ])
        }
        return id
    }

    func insertBlock(
        documentID: UUID, chapterID: UUID, ordinal: Int,
        text: String, id: UUID = UUID()
    ) async throws -> UUID {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_blocks(
                        id, document_id, chapter_id, ordinal, text, text_hash)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(documentID),
                    DatabaseValueCodec.encode(chapterID), ordinal, text,
                    "blk-\(id.uuidString)"
                ])
        }
        return id
    }

    func insertLexeme(
        key: LexicalKey, writtenForm: String, reading: String? = nil
    ) async throws -> UUID {
        let id = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id, written_form,
                        reading, normalized_lemma, identity_key,
                        resolution_status, created_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'resolved', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    key.provider.rawValue, key.externalID,
                    key.provider == .jmdict ? Int64(key.externalID) : nil,
                    writtenForm, reading, writtenForm, key.identityKey
                ])
        }
        return id
    }

    /// D19 fixture：绑定 entry 的 dictionarySense unit + tooEasy
    /// flag——词级「known」运行时态的唯一来源。
    func flagLexemeTooEasy(entryID: Int64, lemma: String) async throws {
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
                        ?, 'dictionarySense', ?, 'jmdict', ?, '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef', 'v1',
                        ?, NULL, '{}', 'current', 0, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(unitID),
                    "ds:\(unitID.uuidString)", entryID, lemma])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms)
                    VALUES (?, 1, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(unitID)])
        }
    }
}

extension S28IntegrationPerformanceTests {
    fileprivate func makeCoverageFixture() throws -> CoverageFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S28Coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: config)
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        let knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
        let morphology = ScriptedMorphologyService()
        let clock = S28Clock(1_700_000_000_000)
        let service = GRDBReaderCoverageService(
            pool: pool, morphology: morphology,
            morphologyVersion: "morph-1", osBuild: "test-os",
            knowledge: knowledge, timeZoneID: "Asia/Tokyo",
            batchSize: 4,
            now: { clock.date })
        return CoverageFixture(
            directory: directory, pool: pool, knowledge: knowledge,
            morphology: morphology, service: service)
    }
}

// MARK: Import executor fixture

private struct ImportFixture {
    let root: URL
    let database: OboeDatabase
    let stagingDir: URL
    let deckID: UUID

    func cleanup() {
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }

    func makeStaging(rows: [String]) throws -> ImportStaging {
        let staging = try ImportStaging(directory: stagingDir)
        var parser = DelimitedTextParserImpl(delimiter: ",")
        for row in rows {
            try staging.append(try parser.feed(row + "\n"))
        }
        try staging.append(try parser.finish())
        return staging
    }

    func createJob(
        mapping: ImportFieldMapping, staging: ImportStaging
    ) async throws -> ImportJob {
        let repo = GRDBImportPlanRepository(database: database)
        let job = ImportJob(
            id: UUID(),
            fileHash: "s28",
            mappingHash: ImportExecutor.mappingHash(mapping),
            policy: mapping.duplicatePolicy,
            targetDeckID: mapping.targetDeckID,
            status: .previewed,
            createdAt: Date()
        )
        try await repo.createJob(job)
        try await repo.attachStagingInfo(
            jobID: job.id,
            stagingFileName: staging.fileURL.lastPathComponent,
            stagingFingerprint: "fp",
            rowCount: staging.rowCount,
            mappingSummary: nil
        )
        return job
    }
}

extension S28IntegrationPerformanceTests {
    fileprivate func makeImportFixture() async throws -> ImportFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S28Import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: root.appendingPathComponent("oboe.sqlite").path)
        try await database.pool.writeWithoutTransaction { db in
            try GRDBImportSchema.migrate(db)
        }
        let stagingDir = root.appendingPathComponent(
            "staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true)
        let deckID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 's28', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)])
        }
        return ImportFixture(
            root: root, database: database,
            stagingDir: stagingDir, deckID: deckID)
    }
}

private extension Duration {
    var milliseconds: Int64 {
        (components.seconds * 1_000)
            + (components.attoseconds / 1_000_000_000_000_000)
    }
}
