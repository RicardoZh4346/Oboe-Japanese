import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S09 覆盖率服务测试：双口径精确值、partial/恢复、版本切换、
/// knowledge 按 key 增量、未知词列表、无词/全 OOV 边界。
final class GRDBReaderCoverageServiceTests: XCTestCase {

    /// 可变测试时钟（@Sendable 闭包捕获箱体而非 self）。
    private final class ClockBox: @unchecked Sendable {
        var milliseconds: Int64
        init(_ ms: Int64) { milliseconds = ms }
        func advance(seconds: Int64 = 60) { milliseconds += seconds * 1_000 }
        var date: Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
    }

    private var directory: URL!
    private var pool: DatabasePool!
    private var knowledge: GRDBVocabularyKnowledgeRepository!
    private var morphology: ScriptedMorphologyService!
    private var clock: ClockBox!
    private var service: GRDBReaderCoverageService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Coverage-\(UUID().uuidString)", isDirectory: true)
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
        pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: config)
        // v18 已由主 agent 注册：全量迁移直接落地全部六表。
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        knowledge = GRDBVocabularyKnowledgeRepository(pool: pool)
        morphology = ScriptedMorphologyService()
        clock = ClockBox(1_700_000_000_000)
        service = makeService()
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeService(
        morphologyVersion: String = "morph-1",
        batchSize: Int = 4
    ) -> GRDBReaderCoverageService {
        let clock = clock!
        return GRDBReaderCoverageService(
            pool: pool, morphology: morphology,
            morphologyVersion: morphologyVersion, osBuild: "test-os",
            knowledge: knowledge, timeZoneID: "Asia/Tokyo",
            batchSize: batchSize,
            now: { clock.date })
    }

    // MARK: - fixture helpers

    private func insertDocument(
        id: UUID = UUID(), title: String = "doc"
    ) async throws -> UUID {
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

    private func insertChapter(
        documentID: UUID, ordinal: Int, id: UUID = UUID()
    ) async throws -> UUID {
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

    private func insertBlock(
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

    private func insertLexeme(
        key: LexicalKey,
        writtenForm: String,
        reading: String? = nil
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

    private func insertOverride(lexemeID: UUID, state: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO vocabulary_knowledge_overrides(
                        lexeme_id, state, updated_at_ms)
                    VALUES (?, ?, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(lexemeID), state])
        }
    }

    private func linkVocabularyNote(lexemeID: UUID) async throws {
        let deckID = UUID(); let noteID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        is_favorite, origin, content_version,
                        created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', 'w', NULL, 'm', 0,
                            'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin,
                        confidence, created_at_ms)
                    VALUES (?, ?, 'userConfirmed', NULL, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID)])
        }
    }

    private struct SnapshotColumns: Equatable {
        var created: Int64
        var known, learning, unknown, ignored: Int
        var analyzed, total, uniqueNum, uniqueDen: Int
        var morphologyVersion: String
    }

    private func snapshotRow(
        scope: String, documentID: UUID
    ) async throws -> SnapshotColumns? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT created_at_ms, known_count, learning_count,
                           unknown_count, ignored_count, analyzed_blocks,
                           total_blocks, unique_numerator,
                           unique_denominator, morphology_version
                    FROM reader_coverage_snapshots
                    WHERE document_id = ? AND scope_key = ?
                    ORDER BY created_at_ms DESC LIMIT 1
                    """,
                arguments: [DatabaseValueCodec.encode(documentID), scope]
            ) else { return nil }
            return SnapshotColumns(
                created: row["created_at_ms"],
                known: row["known_count"],
                learning: row["learning_count"],
                unknown: row["unknown_count"],
                ignored: row["ignored_count"],
                analyzed: row["analyzed_blocks"],
                total: row["total_blocks"],
                uniqueNum: row["unique_numerator"],
                uniqueDen: row["unique_denominator"],
                morphologyVersion: row["morphology_version"])
        }
    }

    private func blockRowCount(
        documentID: UUID, morphologyVersion: String? = nil
    ) async throws -> Int {
        try await pool.read { db in
            if let morphologyVersion {
                return try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM reader_coverage_snapshots
                        WHERE document_id = ? AND scope_key LIKE 'block:%'
                          AND morphology_version = ?
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(documentID),
                        morphologyVersion
                    ]) ?? 0
            }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_coverage_snapshots
                    WHERE document_id = ? AND scope_key LIKE 'block:%'
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]) ?? 0
        }
    }

    private func jmdictKey(_ name: String, seq: Int64) -> LexicalKey {
        LexicalKey(
            provider: .jmdict, externalID: String(seq),
            identityKey: "jmdict|\(seq)|\(name)|")
    }

    private func blockScope(_ id: UUID) -> String {
        "block:\(id.uuidString.lowercased())"
    }

    // MARK: - tests

    /// 端到端：2 块文档 → analyze → 快照行回读 + 块行落库。
    func testAnalyzeComputesAndPersists() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        let keyK = jmdictKey("見る", seq: 1)
        let keyL = jmdictKey("食べる", seq: 2)
        let keyU = jmdictKey("読む", seq: 3)
        let keyI = jmdictKey("行く", seq: 4)
        let lexK = try await insertLexeme(key: keyK, writtenForm: "見る")
        let lexL = try await insertLexeme(key: keyL, writtenForm: "食べる")
        _ = try await insertLexeme(key: keyU, writtenForm: "読む")
        let lexI = try await insertLexeme(key: keyI, writtenForm: "行く")
        try await insertOverride(lexemeID: lexK, state: "known")
        try await linkVocabularyNote(lexemeID: lexL)
        try await insertOverride(lexemeID: lexI, state: "ignored")

        morphology.specs = [
            "見る": .resolved(keyK), "食べる": .resolved(keyL),
            "読む": .resolved(keyU), "行く": .resolved(keyI),
            "xyz": .oov, "、": .nonLexical,
        ]
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0,
            text: "見る 食べる 読む")
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 1,
            text: "見る 行く xyz 、")

        let metrics = try await service.analyze(documentID: docID)
        XCTAssertEqual(metrics.known, 2)       // 見る ×2
        XCTAssertEqual(metrics.learning, 1)
        XCTAssertEqual(metrics.unknown, 2)     // 読む + xyz(OOV)
        XCTAssertEqual(metrics.ignored, 1)
        XCTAssertEqual(metrics.eligible, 5)
        XCTAssertEqual(metrics.uniqueKnown, 1) // 見る 去重
        XCTAssertEqual(metrics.outOfVocabulary, 1)
        XCTAssertFalse(metrics.isPartial)

        let docRaw = try await service.documentSnapshot(documentID: docID)
        let doc = try XCTUnwrap(docRaw)
        XCTAssertEqual(doc.analyzedBlocks, 2)
        XCTAssertEqual(doc.totalBlocks, 2)
        XCTAssertFalse(doc.isPartial)
        XCTAssertEqual(doc.known, 2)
        XCTAssertEqual(doc.uniqueNumerator, 2)   // |{見る,食べる}|
        XCTAssertEqual(doc.uniqueDenominator, 4) // +読む,unresolved|xyz
        XCTAssertEqual(doc.studyDayID.count, 10) // yyyy-MM-dd
        XCTAssertEqual(doc.morphologyVersion, "morph-1")
        XCTAssertEqual(doc.dictionaryVersion, "dict-v1")
        let rows = try await blockRowCount(documentID: docID)
        XCTAssertEqual(rows, 2)
    }

    /// D04 样例端到端：534/31/42/12 → 87.97% / 93.08%。
    /// 全部 key distinct（token 口径 == unique 口径）。
    func testD04SampleEndToEnd() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        var specs: [String: ScriptedMorphologyService.Spec] = [:]
        var surfaces: [String] = []
        // 先在 txn 外生成全部 key/词元（@Sendable 闭包不捕获可变 var）。
        struct FixtureRow {
            let surface: String
            let key: LexicalKey
            let lexemeID: UUID
            let noteID: UUID?
            let overrideState: String?
        }
        var fixtureRows: [FixtureRow] = []
        for i in 0..<534 {
            let key = jmdictKey("k\(i)", seq: Int64(10_000 + i))
            fixtureRows.append(FixtureRow(
                surface: "k\(i)", key: key, lexemeID: UUID(),
                noteID: nil, overrideState: "known"))
        }
        for i in 0..<31 {
            let key = jmdictKey("l\(i)", seq: Int64(20_000 + i))
            fixtureRows.append(FixtureRow(
                surface: "l\(i)", key: key, lexemeID: UUID(),
                noteID: UUID(), overrideState: nil))
        }
        for i in 0..<42 {
            let key = jmdictKey("u\(i)", seq: Int64(30_000 + i))
            fixtureRows.append(FixtureRow(
                surface: "u\(i)", key: key, lexemeID: UUID(),
                noteID: nil, overrideState: nil))
        }
        for i in 0..<12 {
            let key = jmdictKey("i\(i)", seq: Int64(40_000 + i))
            fixtureRows.append(FixtureRow(
                surface: "i\(i)", key: key, lexemeID: UUID(),
                noteID: nil, overrideState: "ignored"))
        }
        for row in fixtureRows {
            specs[row.surface] = .resolved(row.key)
            surfaces.append(row.surface)
        }
        let rows = fixtureRows
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES ('dddddddd-0000-4000-8000-000000000000', 'd',
                            0, 1, 1)
                    """)
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO lexemes(
                            id, provider, external_id, entry_id,
                            written_form, normalized_lemma, identity_key,
                            resolution_status, created_at_ms)
                        VALUES (?, 'jmdict', ?, ?, ?, ?, ?, 'resolved', 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(row.lexemeID),
                        row.key.externalID, Int64(row.key.externalID)!,
                        row.surface, row.surface, row.key.identityKey])
                if let overrideState = row.overrideState {
                    try db.execute(
                        sql: """
                            INSERT INTO vocabulary_knowledge_overrides(
                                lexeme_id, state, updated_at_ms)
                            VALUES (?, ?, 1)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(row.lexemeID),
                            overrideState])
                }
                if let noteID = row.noteID {
                    try db.execute(
                        sql: """
                            INSERT INTO notes(
                                id, deck_id, kind, headword, meaning_zh,
                                is_favorite, origin, content_version,
                                created_at_ms, updated_at_ms)
                            VALUES (?,
                                    'dddddddd-0000-4000-8000-000000000000',
                                    'vocabulary', 'w', 'm', 0, 'manual',
                                    1, 1, 1)
                            """,
                        arguments: [DatabaseValueCodec.encode(noteID)])
                    try db.execute(
                        sql: """
                            INSERT INTO lexeme_note_links(
                                lexeme_id, note_id, association_origin,
                                created_at_ms)
                            VALUES (?, ?, 'backfill', 1)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(row.lexemeID),
                            DatabaseValueCodec.encode(noteID)])
                }
            }
        }
        morphology.specs = specs
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0,
            text: surfaces.joined(separator: " "))

        let metrics = try await service.analyze(documentID: docID)
        XCTAssertEqual(metrics.known, 534)
        XCTAssertEqual(metrics.learning, 31)
        XCTAssertEqual(metrics.unknown, 42)
        XCTAssertEqual(metrics.ignored, 12)
        XCTAssertEqual(
            metrics.tokenCoverage ?? 0, 534.0 / 607.0, accuracy: 1e-12)
        XCTAssertEqual(
            metrics.knownOrLearningCoverage ?? 0, 565.0 / 607.0,
            accuracy: 1e-12)
        XCTAssertEqual(
            String(format: "%.2f%%",
                   (metrics.tokenCoverage ?? 0) * 100), "87.97%")
        XCTAssertEqual(
            String(format: "%.2f%%",
                   (metrics.knownOrLearningCoverage ?? 0) * 100), "93.08%")
        // unique == token（全 distinct）：持久化分子分母 565/607。
        let docRaw = try await service.documentSnapshot(documentID: docID)
        let doc = try XCTUnwrap(docRaw)
        XCTAssertEqual(doc.uniqueNumerator, 565)
        XCTAssertEqual(doc.uniqueDenominator, 607)
    }

    /// 取消：已提交批次保留为 partial；恢复后完成且不重复 tokenize。
    func testCancelLeavesPartialThenResume() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        let key = jmdictKey("見る", seq: 1)
        morphology.specs = ["見る": .resolved(key)]
        var blockIDs: [UUID] = []
        for i in 0..<4 {
            blockIDs.append(try await insertBlock(
                documentID: docID, chapterID: chapter, ordinal: i,
                text: "見る"))
        }
        // batchSize=1：每块一事务；第二块 tokenize 抛 CancellationError。
        service = makeService(batchSize: 1)
        morphology.throwOnTokenizeCalls = [2]
        do {
            _ = try await service.analyze(documentID: docID)
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        let partialRaw = try await service.documentSnapshot(documentID: docID)
        let partial = try XCTUnwrap(partialRaw)
        XCTAssertEqual(partial.analyzedBlocks, 1)
        XCTAssertEqual(partial.totalBlocks, 4)
        XCTAssertTrue(partial.isPartial)  // 不冒充全书覆盖

        morphology.throwOnTokenizeCalls = []
        morphology.tokenizedBlockIDs = []
        let done = try await service.analyze(documentID: docID)
        XCTAssertFalse(done.isPartial)
        // 续跑不重 tokenize 已缓存块。
        XCTAssertEqual(
            Set(morphology.tokenizedBlockIDs), Set(blockIDs.dropFirst()))
    }

    /// 版本切换：morphology 版本变 → 缓存 miss 重算；旧版本块行
    /// 清理、旧版本文档行保留为历史（不混入当前快照）。
    func testVersionSwitchInvalidatesAndDoesNotMix() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        let key = jmdictKey("見る", seq: 1)
        morphology.specs = ["見る": .resolved(key)]
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0, text: "見る")
        _ = try await service.analyze(documentID: docID)
        XCTAssertEqual(morphology.tokenizeCallCount, 1)
        let oldRows = try await blockRowCount(
            documentID: docID, morphologyVersion: "morph-1")
        XCTAssertEqual(oldRows, 1)

        // 切换 morphology 版本（词典不变）→ 全量重 tokenize。
        let serviceV2 = makeService(morphologyVersion: "morph-2")
        let metrics = try await serviceV2.analyze(documentID: docID)
        XCTAssertEqual(morphology.tokenizeCallCount, 2)
        XCTAssertEqual(metrics.totalBlocks, 1)
        let v1Rows = try await blockRowCount(
            documentID: docID, morphologyVersion: "morph-1")
        let v2Rows = try await blockRowCount(
            documentID: docID, morphologyVersion: "morph-2")
        XCTAssertEqual(v1Rows, 0)
        XCTAssertEqual(v2Rows, 1)
        let snapRaw = try await serviceV2.documentSnapshot(documentID: docID)
        let snap = try XCTUnwrap(snapRaw)
        XCTAssertEqual(snap.morphologyVersion, "morph-2")
    }

    /// knowledge 变化按 key 更新：只有含变更 lexeme 的块行被重写。
    func testRefreshKnowledgeUpdatesOnlyAffectedBlocks() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        let keyA = jmdictKey("会", seq: 1)
        let keyB = jmdictKey("行く", seq: 2)
        let keyC = jmdictKey("見る", seq: 3)
        let lexA = try await insertLexeme(key: keyA, writtenForm: "会")
        _ = try await insertLexeme(key: keyB, writtenForm: "行く")
        _ = try await insertLexeme(key: keyC, writtenForm: "見る")
        morphology.specs = [
            "会": .resolved(keyA), "行く": .resolved(keyB),
            "見る": .resolved(keyC)]
        let b1 = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0, text: "会")
        let b2 = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 1, text: "行く")
        let b3 = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 2, text: "見る")
        _ = try await service.analyze(documentID: docID)
        let before1 = try await snapshotRow(
            scope: blockScope(b1), documentID: docID)
        let before2 = try await snapshotRow(
            scope: blockScope(b2), documentID: docID)

        clock.advance()
        _ = try await knowledge.setOverride(
            lexemeID: lexA, override: .known, at: Date())
        let metrics = try await service.refreshKnowledge(
            documentID: docID, changedLexemeIDs: [lexA])
        XCTAssertEqual(metrics?.known, 1)

        let after1 = try await snapshotRow(
            scope: blockScope(b1), documentID: docID)
        let after2 = try await snapshotRow(
            scope: blockScope(b2), documentID: docID)
        let after3 = try await snapshotRow(
            scope: blockScope(b3), documentID: docID)
        XCTAssertGreaterThan(
            after1?.created ?? 0, before1?.created ?? 0)  // 受影响重写
        XCTAssertEqual(after2?.created, before2?.created) // 未受影响不动
        XCTAssertEqual(after3?.created, before1?.created)
        XCTAssertEqual(after1?.known, 1)
        let docRaw = try await service.documentSnapshot(documentID: docID)
        let doc = try XCTUnwrap(docRaw)
        XCTAssertEqual(doc.known, 1)
        XCTAssertEqual(doc.unknown, 2)
    }

    /// 未知词列表：unknown 分桶、OOV/待确认标记、分页。
    func testUnknownWordsPaginationAndFlags() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        let keyU = jmdictKey("読む", seq: 3)
        let keyK = jmdictKey("見る", seq: 1)
        let lexK = try await insertLexeme(key: keyK, writtenForm: "見る")
        _ = try await insertLexeme(key: keyU, writtenForm: "読む", reading: "よむ")
        try await insertOverride(lexemeID: lexK, state: "known")
        morphology.specs = [
            "読む": .resolved(keyU), "見る": .resolved(keyK),
            "hello": .oov, "今日": .ambiguous]
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0,
            text: "読む 見る hello hello 今日")

        _ = try await service.analyze(documentID: docID)
        let page = try await service.unknownWords(
            documentID: docID, offset: 0, limit: 10)
        XCTAssertEqual(page.total, 3)  // 読む / hello×2 / 今日
        let forms = page.items.map(\.displayForm)
        XCTAssertTrue(forms.contains("読む"))
        XCTAssertTrue(forms.contains("hello"))
        XCTAssertTrue(forms.contains("今日"))
        XCTAssertFalse(forms.contains("見る"))  // known 不进列表
        let hello = try XCTUnwrap(
            page.items.first { $0.displayForm == "hello" })
        XCTAssertTrue(hello.isOutOfVocabulary)
        XCTAssertEqual(hello.occurrenceCount, 2)
        let kyou = try XCTUnwrap(
            page.items.first { $0.displayForm == "今日" })
        XCTAssertTrue(kyou.isAmbiguous)
        XCTAssertFalse(kyou.isOutOfVocabulary)
        let yomu = try XCTUnwrap(
            page.items.first { $0.displayForm == "読む" })
        XCTAssertEqual(yomu.reading, "よむ")
        XCTAssertNotNil(yomu.lexemeID)
        // 分页
        let p1 = try await service.unknownWords(
            documentID: docID, offset: 0, limit: 2)
        let p2 = try await service.unknownWords(
            documentID: docID, offset: 2, limit: 2)
        XCTAssertEqual(p1.items.count, 2)
        XCTAssertEqual(p2.items.count, 1)
        XCTAssertEqual(p2.total, 3)
    }

    /// 无词文档（全 nonLexical）与全 OOV 文档分开呈现。
    func testNoTokensVsAllOOV() async throws {
        let docA = try await insertDocument(title: "punct")
        let chA = try await insertChapter(documentID: docA, ordinal: 0)
        morphology.specs = ["、": .nonLexical, "。": .nonLexical]
        _ = try await insertBlock(
            documentID: docA, chapterID: chA, ordinal: 0, text: "、 。")
        let mA = try await service.analyze(documentID: docA)
        XCTAssertFalse(mA.hasAnyCountableTokens)
        XCTAssertNil(mA.tokenCoverage)

        let docB = try await insertDocument(title: "latin")
        let chB = try await insertChapter(documentID: docB, ordinal: 0)
        morphology.specs = ["hello": .oov, "world": .oov]
        _ = try await insertBlock(
            documentID: docB, chapterID: chB, ordinal: 0,
            text: "hello world")
        let mB = try await service.analyze(documentID: docB)
        XCTAssertTrue(mB.hasAnyCountableTokens)
        XCTAssertEqual(mB.outOfVocabulary, 2)
        XCTAssertEqual(mB.tokenCoverage ?? -1, 0.0, accuracy: 1e-12)
    }

    /// 章级口径：只聚合该章 payload。
    func testChapterMetrics() async throws {
        let docID = try await insertDocument()
        let ch1 = try await insertChapter(documentID: docID, ordinal: 0)
        let ch2 = try await insertChapter(documentID: docID, ordinal: 1)
        let keyK = jmdictKey("見る", seq: 1)
        let lexK = try await insertLexeme(key: keyK, writtenForm: "見る")
        try await insertOverride(lexemeID: lexK, state: "known")
        morphology.specs = ["見る": .resolved(keyK), "x": .oov]
        _ = try await insertBlock(
            documentID: docID, chapterID: ch1, ordinal: 0, text: "見る x")
        _ = try await insertBlock(
            documentID: docID, chapterID: ch2, ordinal: 0, text: "x x x")
        _ = try await service.analyze(documentID: docID)

        let m1Raw = try await service.chapterMetrics(
            documentID: docID, chapterID: ch1)
        let m1 = try XCTUnwrap(m1Raw)
        XCTAssertEqual(m1.known, 1)
        XCTAssertEqual(m1.unknown, 1)
        let m2Raw = try await service.chapterMetrics(
            documentID: docID, chapterID: ch2)
        let m2 = try XCTUnwrap(m2Raw)
        XCTAssertEqual(m2.known, 0)
        XCTAssertEqual(m2.unknown, 3)
    }

    /// refreshBlocks：只对指定块重取 token，其余块行不动。
    func testRefreshBlocksTargeted() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        morphology.specs = ["a": .oov, "b": .oov, "c": .oov]
        let b1 = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0, text: "a")
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 1, text: "b")
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 2, text: "c")
        _ = try await service.analyze(documentID: docID)
        XCTAssertEqual(morphology.tokenizeCallCount, 3)

        morphology.tokenizedBlockIDs = []
        let newKey = jmdictKey("会", seq: 9)
        morphology.specs["a"] = .resolved(newKey)
        let lexeme = try await insertLexeme(
            key: newKey, writtenForm: "会")
        try await insertOverride(lexemeID: lexeme, state: "known")
        let metrics = try await service.refreshBlocks(
            documentID: docID, blockIDs: [b1])
        XCTAssertEqual(morphology.tokenizedBlockIDs, [b1])
        XCTAssertEqual(metrics?.known, 1)
        XCTAssertEqual(metrics?.unknown, 2)
    }

    /// 重复运行幂等：快照 upsert 不倍增，tokenize 不重复。
    func testAnalyzeIdempotentRerun() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        morphology.specs = ["x": .oov]
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0, text: "x")
        _ = try await service.analyze(documentID: docID)
        _ = try await service.analyze(documentID: docID)
        XCTAssertEqual(morphology.tokenizeCallCount, 1)
        let blockRows = try await blockRowCount(documentID: docID)
        XCTAssertEqual(blockRows, 1)
        let docRows = try await pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_coverage_snapshots
                    WHERE document_id = ? AND scope_key = 'document'
                    """,
                arguments: [DatabaseValueCodec.encode(docID)]) ?? 0
        }
        XCTAssertEqual(docRows, 1)
    }

    /// 从未分析且无缓存 → refreshKnowledge 不凭空建行。
    func testRefreshKnowledgeOnNeverAnalyzedIsNil() async throws {
        let docID = try await insertDocument()
        let chapter = try await insertChapter(documentID: docID, ordinal: 0)
        _ = try await insertBlock(
            documentID: docID, chapterID: chapter, ordinal: 0, text: "x")
        let result = try await service.refreshKnowledge(documentID: docID)
        XCTAssertNil(result)
        let snap = try await service.documentSnapshot(documentID: docID)
        XCTAssertNil(snap)
    }
}

// MARK: - scripted morphology fake

/// 按 surface 查表产出 token 的确定性 fake（空格分词）。
final class ScriptedMorphologyService: JapaneseMorphologyService,
    @unchecked Sendable {
    var implementationVersion = "scripted-1.0.0"
    var dictionaryDatasetVersion: String
    var osBuild = "test-os"
    var morphologyVersion = "morph-1"

    struct Spec: Sendable {
        var status: TokenResolutionStatus
        var key: LexicalKey?
        var tokenClass: ReaderTokenClass
        var candidates: [MorphologyCandidate]

        static func resolved(_ key: LexicalKey) -> Spec {
            Spec(status: .resolved, key: key, tokenClass: .lexical,
                 candidates: [MorphologyCandidate(
                    lemma: "", normalizedForm: "", reading: nil,
                    posCodes: [], entryID: Int64(key.externalID),
                    reasons: [], cost: 0)])
        }
        /// 词典无候选（OOV）。
        static var oov: Spec {
            Spec(status: .unresolved, key: nil, tokenClass: .lexical,
                 candidates: [])
        }
        /// 有候选待确认（ambiguous）。
        static var ambiguous: Spec {
            Spec(status: .ambiguous, key: nil, tokenClass: .lexical,
                 candidates: [MorphologyCandidate(
                    lemma: "x", normalizedForm: "x", reading: nil,
                    posCodes: [], entryID: 1, reasons: [], cost: 0)])
        }
        /// 不计入分母。
        static var nonLexical: Spec {
            Spec(status: .unresolved, key: nil, tokenClass: .nonLexical,
                 candidates: [])
        }
    }

    var specs: [String: Spec] = [:]
    /// 第 N 次 tokenize 调用抛 CancellationError（确定性取消注入）。
    var throwOnTokenizeCalls: Set<Int> = []
    var tokenizedBlockIDs: [UUID] = []
    var tokenizeCallCount = 0

    init(dictionaryVersion: String = "dict-v1") {
        dictionaryDatasetVersion = dictionaryVersion
    }

    func tokenize(_ block: MorphologyBlock) async throws -> [ReaderToken] {
        tokenizeCallCount += 1
        if throwOnTokenizeCalls.contains(tokenizeCallCount) {
            throw CancellationError()
        }
        tokenizedBlockIDs.append(block.blockID)
        var tokens: [ReaderToken] = []
        var utf16Offset = 0
        var index = 0
        for part in block.text.components(separatedBy: " ") {
            let len = part.utf16.count
            defer { utf16Offset += len + 1; index += 1 }
            guard !part.isEmpty else { continue }
            let spec = specs[part] ?? .oov
            tokens.append(ReaderToken(
                surface: part,
                sourceRangeUTF16: utf16Offset..<(utf16Offset + len),
                systemTokenIndexes: index..<(index + 1),
                candidates: spec.candidates,
                tokenClass: spec.tokenClass,
                reading: nil,
                lexicalKey: spec.key,
                resolutionStatus: spec.status,
                provenance: ["scripted"]))
        }
        return tokens
    }
}
