import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S21 验收性能实测（需求 §17 / S21 门禁）：在
/// `OBOE_RUN_S21_PERFORMANCE=1` 下跑真实形态分析管线、牌组进度
/// 投影与 coverage 快照投影，打印 `[S21]` 证据行（样本量、计时、
/// RSS 峰值），供 `docs/evidence/v0.7.5/s21-gates.md` 引用。
///
/// 与常设正确性测试的分工：本文件只记录/粗断言性能量级（Debug
/// 校准上限防病态退化），不构成真机/Release 预算判定——真机
/// 数字以 iPhone/iPad 手测为准。
final class AIStudyPerfTests: XCTestCase {

    private func requireGate() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OBOE_RUN_S21_PERFORMANCE"]
                == "1",
            "Set OBOE_RUN_S21_PERFORMANCE=1 for the S21 perf run."
        )
    }

    // MARK: - S21: prepare() 管线吞吐（真 tokenizer+词典+落库）

    /// 100KB 与 1MB 日文文档各跑一次 `preflight + prepare`：
    /// 真实 `NLJapaneseMorphologyService`（随包词典）+ 真实
    /// `GRDBDictionaryRepository` + 真 GRDB 库。记录分块数、
    /// token/occurrence 数、墙钟时间与 RSS 峰值。
    func testPreparePipelineThroughput100KBAnd1MB() async throws {
        try requireGate()
        let dictURL = try XCTUnwrap(
            MorphologyTestSupport.bundledDictionaryURL,
            "bundled dictionary missing")

        for targetBytes in [100_000, 1_000_000] {
            let env = try await makePrepareFixture(
                dictionaryURL: dictURL, targetBytes: targetBytes)
            defer { env.cleanup() }

            let sampler = S21PeakSampler()
            sampler.start()
            let rssBefore = Self.residentSize()

            let preflightStart = ContinuousClock.now
            let report = try await env.service.preflight(
                documentID: env.documentID,
                request: AIStudyScopeRequest(choice: .wholeBook),
                provider: env.provider)
            let preflightMs = preflightStart.duration(to: .now)
                .milliseconds
            XCTAssertTrue(
                report.canStart,
                "preflight 未放行：\(report.issues)")

            let prepareStart = ContinuousClock.now
            do {
                let job = try await env.service.prepare(
                    documentID: env.documentID, report: report,
                    configuration: report.provider.resolved!)
                let prepareMs = prepareStart.duration(to: .now)
                    .milliseconds

                let occurrences = try await env.pool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM reader_study_occurrences
                            """
                    ) ?? 0
                }
                let cachedBlocks = try await env.pool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM reader_token_cache")
                        ?? 0
                }
                let manifest = try await env.service.loadManifest(
                    jobID: job.id)
                let tokenCount = manifest?.blocks.reduce(0) {
                    $0 + $1.tokens.count
                } ?? -1

                let rssAfter = Self.residentSize()
                let rssPeak = sampler.stop()

                print("""
                    [S21] prepare doc=\(targetBytes)B \
                    blocks=\(env.blockCount) utf16=\(env.totalUTF16) \
                    preflight=\(preflightMs)ms prepare=\(prepareMs)ms \
                    tokens=\(tokenCount) occurrences=\(occurrences) \
                    cachedBlocks=\(cachedBlocks) \
                    rssBefore=\(rssBefore / 1_048_576)MiB \
                    rssAfter=\(rssAfter / 1_048_576)MiB \
                    rssPeak=\(rssPeak / 1_048_576)MiB
                    """)
                XCTAssertEqual(job.status, .pending)
                XCTAssertGreaterThan(occurrences, 0)
                XCTAssertEqual(cachedBlocks, env.blockCount)
                // Debug 防退化上限（非预算断言）。
                XCTAssertLessThan(
                    prepareMs,
                    Int64(targetBytes / 100_000 + 1) * 300_000,
                    "prepare() 病态退化")
            } catch AIStudyPreparationService.PreparationError
                .manifestTooLarge(let bytes)
            {
                // 整书量级上限：32MiB manifest 闸门在 tokenize/证据
                // 批量提交之后才触发——被拒时证据行已落库但 Job 未建。
                // 如实记录被拒体量、已提交的残留证据与耗时。
                let prepareMs = prepareStart.duration(to: .now)
                    .milliseconds
                let leftoverOccurrences = try await env.pool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM reader_study_occurrences
                            """
                    ) ?? 0
                }
                let leftoverCached = try await env.pool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM reader_token_cache")
                        ?? 0
                }
                let rssPeak = sampler.stop()
                print("""
                    [S21] prepare doc=\(targetBytes)B REJECTED \
                    manifest=\(bytes)B \
                    cap=\(GRDBAIStudyManifestSchema.manifestMaxBytes)B \
                    blocks=\(env.blockCount) utf16=\(env.totalUTF16) \
                    elapsed=\(prepareMs)ms \
                    leftoverOccurrences=\(leftoverOccurrences) \
                    leftoverCachedBlocks=\(leftoverCached) \
                    rssPeak=\(rssPeak / 1_048_576)MiB
                    """)
                XCTAssertGreaterThan(
                    bytes, GRDBAIStudyManifestSchema.manifestMaxBytes)
            }
        }
    }

    // MARK: - S21: 牌组进度投影（20 deck / 1.5k notes / 3k cards）

    /// §17「可见 20 个 deck 的进度」口径：seed 20 deck、1,500 笔记、
    /// 3,000 卡（每笔记 ja→zh + zh→ja 两向）、1,000 学习单元链接，
    /// `deckProgress(deckIDs:)` 取 21 样本报 p50/p95。
    func testDeckProgressProjection20Decks() async throws {
        try requireGate()
        let env = try await makeDeckFixture(deckCount: 20, notesPerDeck: 75)
        defer { env.cleanup() }

        XCTAssertEqual(env.noteCount, 1_500)
        XCTAssertEqual(env.cardCount, 3_000)
        XCTAssertEqual(env.unitCount, 1_000)

        let repo = GRDBLearningProgressRepository(pool: env.pool)

        // 单测一次 unit 级投影规模（1,000 unit 批量）。
        let unitStart = ContinuousClock.now
        let units = try await repo.unitProgresses(
            unitIDs: env.unitIDs)
        let unitMs = unitStart.duration(to: .now).milliseconds
        XCTAssertEqual(units.count, 1_000)

        var samples: [Int64] = []
        for _ in 0..<21 {
            let t = ContinuousClock.now
            let progress = try await repo.deckProgress(
                deckIDs: env.deckIDs)
            samples.append(t.duration(to: .now).milliseconds)
            XCTAssertEqual(progress.count, 20)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        print("""
            [S21] deckProgress decks=20 notes=\(env.noteCount) \
            cards=\(env.cardCount) units=\(env.unitCount) \
            unitProgresses(1000)=\(unitMs)ms \
            p50=\(p50)ms p95=\(p95)ms max=\(samples.last!)ms
            """)
        // Debug 防退化上限（§17 Release 预算为 p95≤200ms；Debug 下
        // 仅防病态退化，实数记录进报告）。
        XCTAssertLessThanOrEqual(
            p95, 1_000, "deckProgress 20-deck p95 病态退化")
    }

    // MARK: - S21: coverage v2 投影 + 快照写（5k occurrences）

    /// 整文档 coverage v2 活算投影 + `recordDocumentSnapshot`：
    /// 5,000 occurrence / 300 块 / 2,000 已解析 unit（含 500 flags
    /// 供知识指纹）。记录投影与落快照耗时。
    func testCoverageProjectionAndSnapshot5K() async throws {
        try requireGate()
        let env = try await makeCoverageFixture(
            blockCount: 300, occurrenceCount: 5_000, unitCount: 2_000)
        defer { env.cleanup() }

        var projectSamples: [Int64] = []
        var lastResult: ReaderCoverageV2.Result?
        for _ in 0..<11 {
            let t = ContinuousClock.now
            let projection = try await env.pool.read { db in
                try GRDBReaderCoverageSnapshotStore
                    .projectDocumentCoverage(
                        documentID: env.documentID, in: db)
            }
            projectSamples.append(t.duration(to: .now).milliseconds)
            lastResult = projection.result
        }
        projectSamples.sort()
        let result = try XCTUnwrap(lastResult)

        var snapshotSamples: [Int64] = []
        for _ in 0..<5 {
            let t = ContinuousClock.now
            try await env.pool.write { db in
                try GRDBReaderCoverageSnapshotStore
                    .recordDocumentSnapshot(
                        documentID: env.documentID,
                        dictionaryVersion: "ds-perf",
                        morphologyVersion: "morph-perf",
                        in: db)
            }
            snapshotSamples.append(t.duration(to: .now).milliseconds)
        }
        snapshotSamples.sort()

        print("""
            [S21] coverage doc occ=5000 blocks=300 units=2000 \
            resolvedUnique=\(result.resolvedUnique) \
            pending=\(result.pendingOccurrences) oov=\(result.oovOccurrences) \
            project p50=\(projectSamples[projectSamples.count / 2])ms \
            p95=\(projectSamples[
                Int(Double(projectSamples.count) * 0.95) - 1])ms \
            snapshot median=\(snapshotSamples[snapshotSamples.count / 2])ms
            """)
        XCTAssertGreaterThan(result.resolvedUnique, 0)
        XCTAssertLessThanOrEqual(
            projectSamples.last!, 2_000, "coverage 投影病态退化")
    }

    // MARK: - fixture：prepare 管线（真 morphology/dictionary）

    private struct PrepareFixture {
        let directory: URL
        let pool: DatabasePool
        let service: AIStudyPreparationService
        let documentID: UUID
        let blockCount: Int
        let totalUTF16: Int
        let provider: AIStudyProviderReadiness

        func cleanup() {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Stub reader 直接喂元数据，但 tokenize/词典/落库全走真实路径。
    private struct S21StubReader: AIStudyPreparationService.ReaderSource {
        let document: ReaderDocumentMetadata
        let chapters: [ReaderChapterMetadata]
        let blocks: [UUID: [ReaderBlock]]

        func fetchDocument(id: UUID) async throws
            -> ReaderDocumentMetadata? {
            id == document.id ? document : nil
        }

        func fetchChapters(documentID: UUID) async throws
            -> [ReaderChapterMetadata] {
            chapters.filter { $0.documentID == documentID }
        }

        func fetchBlocks(documentID: UUID, chapterID: UUID)
            async throws -> [ReaderBlock] {
            (blocks[chapterID] ?? []).filter {
                $0.documentID == documentID
            }
        }
    }

    private func makePrepareFixture(
        dictionaryURL: URL, targetBytes: Int
    ) async throws -> PrepareFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S21Prep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let pool = try makeMigratedPool(
            at: directory.appendingPathComponent("oboe.sqlite"))

        // 语料：句池轮换 + 计数后缀，块 ~1,500 UTF-16 单元。
        let documentID = UUID()
        let chapterID = UUID()
        let texts = Self.makeCorpusBlocks(
            targetUTF8Bytes: targetBytes, blockUTF16: 1_500)
        let blocks = texts.enumerated().map { ordinal, text in
            ReaderBlock(
                id: UUID(), documentID: documentID, chapterID: chapterID,
                ordinal: ordinal, text: text,
                textHash: "th-\(ordinal)-\(text.utf16.count)",
                locatorJSON: nil)
        }
        let document = ReaderDocumentMetadata(
            id: documentID, title: "S21-\(targetBytes)", format: .paste,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, sourceFileName: nil,
            sourceSHA256: String(repeating: "0", count: 64),
            canonicalTextHash: "canon-s21-\(targetBytes)",
            parserVersion: "parser-1", contentRevision: 1,
            progressBasisPoints: 0, availability: .available)
        let chapter = ReaderChapterMetadata(
            id: chapterID, documentID: documentID, ordinal: 0,
            title: "第一章", sourceLocator: nil,
            canonicalHash: "ch-0",
            textUTF16Length: texts.reduce(0) { $0 + $1.utf16.count })

        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version,
                        content_revision, availability)
                    VALUES (?, ?, 'paste', 1, ?, ?, 'parser-1', 1,
                            'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    document.title,
                    String(repeating: "0", count: 64),
                    document.canonicalTextHash,
                ])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title, canonical_hash,
                        text_utf16_length)
                    VALUES (?, ?, 0, '第一章', 'ch-0', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID),
                    chapter.textUTF16Length,
                ])
            for block in blocks {
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal, text,
                            text_hash)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(block.id),
                        DatabaseValueCodec.encode(documentID),
                        DatabaseValueCodec.encode(chapterID),
                        block.ordinal, block.text, block.textHash,
                    ])
            }
        }

        let morphology = try MorphologyTestSupport.makeService()
        let service = AIStudyPreparationService(
            pool: pool,
            reader: S21StubReader(
                document: document, chapters: [chapter],
                blocks: [chapterID: blocks]),
            morphology: morphology,
            dictionary: GRDBDictionaryRepository(
                databaseURL: dictionaryURL))
        let provider = AIStudyProviderReadiness(
            state: .ready, isEnabled: true,
            serviceName: "DeepSeek", serviceKind: .deepSeek,
            modelID: "model-1",
            resolved: ResolvedAIConfiguration(
                isEnabled: true, serviceKind: .deepSeek,
                serviceName: "DeepSeek",
                baseURL: URL(string: "https://api.deepseek.com")!,
                modelID: "model-1",
                responseFormatMode: .promptedJSON,
                credentialReference: AICredentialReference(
                    id: UUID(), serviceKind: .deepSeek,
                    host: "api.deepseek.com")))
        return PrepareFixture(
            directory: directory, pool: pool, service: service,
            documentID: documentID, blockCount: blocks.count,
            totalUTF16: chapter.textUTF16Length, provider: provider)
    }

    // MARK: - fixture：牌组进度（decks/notes/cards/units/links/flags）

    private struct DeckFixture {
        let directory: URL
        let pool: DatabasePool
        let deckIDs: [UUID]
        let unitIDs: [UUID]
        let noteCount: Int
        let cardCount: Int
        let unitCount: Int

        func cleanup() {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeDeckFixture(
        deckCount: Int, notesPerDeck: Int
    ) async throws -> DeckFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S21Deck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let pool = try makeMigratedPool(
            at: directory.appendingPathComponent("oboe.sqlite"))

        let deckIDs = (0..<deckCount).map { _ in UUID() }
        let profileID = UUID()
        let noteTotal = deckCount * notesPerDeck
        let unitIDs = (0..<1_000).map { _ in UUID() }

        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json,
                        desired_retention, max_interval_days,
                        created_at_ms)
                    VALUES (?, 'cfg-s21', 'fsrs-1', 'rev-1', '{}',
                            0.9, 365, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(profileID)])
            for (index, deckID) in deckIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO decks(
                            id, name, sort_order, created_at_ms,
                            updated_at_ms)
                        VALUES (?, ?, ?, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(deckID),
                        "deck-\(index)", index,
                    ])
            }
            // 单元先于 note 链接建（FK 顺序无关——links 后插）。
            for (i, unitID) in unitIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO lexical_learning_units(
                            id, identity_kind, identity_key, provider,
                            dictionary_entry_id, semantic_fingerprint,
                            fingerprint_version, lemma, reading,
                            binding_status, revision, created_at_ms,
                            updated_at_ms)
                        VALUES (?, 'dictionarySense', ?, 'jmdict', ?, ?,
                                'fpv1', ?, ?, 'current', 0, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(unitID),
                        "jmdict:sense-iso-v1:s21:\(10_000 + i):1",
                        Int64(10_000 + i),
                        String(repeating: "a", count: 61) + String(
                            format: "%03x", i % 4_096).suffix(3),
                        "語\(i)", "ご\(i)",
                    ])
            }
            // 笔记 + membership + 双向卡；前 1,000 条笔记各占一 unit。
            for i in 0..<noteTotal {
                let noteID = UUID()
                let deckID = deckIDs[i / notesPerDeck]
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, meaning_zh,
                            origin, content_version, created_at_ms,
                            updated_at_ms)
                        VALUES (?, ?, 'vocabulary', ?, ?, 'manual', 1,
                                1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                        "語\(i)", "释义\(i)",
                    ])
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id,
                                               added_at_ms)
                        VALUES (?, ?, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                    ])
                for kind in ["vocabulary_ja_zh", "vocabulary_zh_ja"] {
                    try db.execute(
                        sql: """
                            INSERT INTO cards(
                                id, note_id, template_kind, is_enabled,
                                state, due_at_ms, stability, difficulty,
                                reps, lapses, scheduled_days,
                                elapsed_days, learning_step,
                                algorithm_version, profile_id)
                            VALUES (?, ?, ?, ?, 2, 1, ?, 5.0, 5, 0, 10,
                                    10, 0, 'fsrs-1', ?)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(UUID()),
                            DatabaseValueCodec.encode(noteID),
                            kind, i % 17 == 0 ? 0 : 1,
                            Double(10 + i % 50),
                            DatabaseValueCodec.encode(profileID),
                        ])
                }
                if i < unitIDs.count {
                    try db.execute(
                        sql: """
                            INSERT INTO learning_unit_note_links(
                                unit_id, note_id, role, origin,
                                created_at_ms)
                            VALUES (?, ?, 'primary', 'manual', 1)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(unitIDs[i]),
                            DatabaseValueCodec.encode(noteID),
                        ])
                }
            }
            // 200 个 unit 置 tooEasy 旗标，扰动进度分布。
            for i in 0..<200 {
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_flags(
                            unit_id, too_easy, revision, updated_at_ms)
                        VALUES (?, ?, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(unitIDs[i]),
                        i % 5 == 0 ? 1 : 0,
                    ])
            }
        }
        return DeckFixture(
            directory: directory, pool: pool, deckIDs: deckIDs,
            unitIDs: unitIDs, noteCount: noteTotal,
            cardCount: noteTotal * 2, unitCount: unitIDs.count)
    }

    // MARK: - fixture：coverage 投影（occurrences + units + flags）

    private struct CoveragePerfFixture {
        let directory: URL
        let pool: DatabasePool
        let documentID: UUID

        func cleanup() {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeCoverageFixture(
        blockCount: Int, occurrenceCount: Int, unitCount: Int
    ) async throws -> CoveragePerfFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S21Cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let pool = try makeMigratedPool(
            at: directory.appendingPathComponent("oboe.sqlite"))
        let documentID = UUID()
        let chapterID = UUID()
        let unitIDs = (0..<unitCount).map { _ in UUID() }

        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version,
                        content_revision, availability)
                    VALUES (?, 's21-cov', 'paste', 1, ?, 'canon-cov',
                            'parser-1', 1, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    String(repeating: "0", count: 64),
                ])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, canonical_hash,
                        text_utf16_length)
                    VALUES (?, ?, 0, 'ch-0', 0)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID),
                ])
            for ordinal in 0..<blockCount {
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal, text,
                            text_hash)
                        VALUES (?, ?, ?, ?, 'blk', ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(documentID),
                        DatabaseValueCodec.encode(chapterID),
                        ordinal, "bh-\(ordinal)",
                    ])
            }
            for (i, unitID) in unitIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO lexical_learning_units(
                            id, identity_kind, identity_key, provider,
                            dictionary_entry_id, semantic_fingerprint,
                            fingerprint_version, lemma,
                            binding_status, revision, created_at_ms,
                            updated_at_ms)
                        VALUES (?, 'dictionarySense', ?, 'jmdict', ?, ?,
                                'fpv1', ?, 'current', 0, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(unitID),
                        "jmdict:sense-iso-v1:s21c:\(20_000 + i):1",
                        Int64(20_000 + i),
                        String(repeating: "b", count: 61) + String(
                            format: "%03x", i % 4_096).suffix(3),
                        "単語\(i)",
                    ])
            }
            // 知识指纹分量：500 flags。
            for i in 0..<min(500, unitCount) {
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_flags(
                            unit_id, too_easy, revision, updated_at_ms)
                        VALUES (?, ?, 2, 999)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(unitIDs[i]),
                        i % 4 == 0 ? 1 : 0,
                    ])
            }
            // occurrence 分布：~70% aiResolved（指到 unit）、
            // 15% pending、10% unresolved、5% lowConfidence。
            for i in 0..<occurrenceCount {
                let status: String
                let unitID: UUID?
                switch i % 20 {
                case 0..<14:
                    status = "aiResolved"
                    unitID = unitIDs[i % unitCount]
                case 14..<17:
                    status = "pending"; unitID = nil
                case 17..<19:
                    status = "unresolved"; unitID = nil
                default:
                    status = "lowConfidence"; unitID = nil
                }
                try db.execute(
                    sql: """
                        INSERT INTO reader_study_occurrences(
                            id, document_id, content_revision,
                            locator_json, block_source_hash,
                            tokenizer_version, start_utf16, length_utf16,
                            unit_id, resolution_status)
                        VALUES (?, ?, 1, ?, ?, 'tv-s21', ?, 1, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(documentID),
                        """
                        {"chapterOrdinal":0,"blockOrdinal":\(i % blockCount)}
                        """,
                        "bh-\(i % blockCount)",
                        i,
                        unitID.map { DatabaseValueCodec.encode($0) },
                        status,
                    ])
            }
        }
        return CoveragePerfFixture(
            directory: directory, pool: pool, documentID: documentID)
    }

    // MARK: - 语料与公共工具

    /// 句池：覆盖名词/动词活用/助词链/形容词，长度不一；
    /// 轮换拼接并在块内嵌入计数（漢数字），避免完全重复命中
    /// 词库缓存导致失真。
    private static let sentencePool: [String] = [
        "昨日の夕方、駅前の本屋で久しぶりに友人と会った。",
        "彼女は毎朝六時に起きて、公園を三十分ほど走っている。",
        "この料理は思ったより辛くて、水を何杯も飲んでしまった。",
        "新しい辞書を買ったので、早速知らない単語を引いてみた。",
        "雨が降りそうだったから、傘を持って出かけたほうがいい。",
        "子供のころ、祖母の家で過ごした夏休みが懐かしい。",
        "彼は難しい問題をあっという間に解いてしまった。",
        "桜の花が咲く季節になると、町中がにぎやかになる。",
        "その映画は評判が良かったのに、私には少し長すぎた。",
        "電車が遅れたので、約束の時間に間に合わなかった。",
        "先生に教えてもらった勉強法を試してみたいと思う。",
        "最近野菜の値段が上がって、家計が少し苦しくなった。",
        "図書館で借りた本を忘れずに返さなければならない。",
        "妹が犬を飼いたいと言っているが、両親は反対している。",
        "会議で出された提案は、ほとんどの人に支持された。",
        "疲れていたので、夕食を食べずにそのまま寝てしまった。",
        "この道をまっすぐ行くと、右手に大きな病院が見える。",
        "彼女の話し方はとても丁寧で、印象が良かった。",
        "冬の朝は布団から出るのがつらくて仕方がない。",
        "旅行の計画を立てるとき、まず予算を決めることにしている。",
    ]

    /// `targetUTF8Bytes` 以上の UTF-8 体積の日本語語料を
    /// `blockUTF16` 単位の块列に分割して返す。
    private static func makeCorpusBlocks(
        targetUTF8Bytes: Int, blockUTF16: Int
    ) -> [String] {
        var blocks: [String] = []
        var current = ""
        var byteCount = 0
        var index = 0
        while byteCount < targetUTF8Bytes {
            var sentence = sentencePool[index % sentencePool.count]
            if index % 7 == 0 {
                sentence += "（第\(index / 7 + 1)節）"
            }
            current += sentence
            byteCount += sentence.utf8.count
            index += 1
            if current.utf16.count >= blockUTF16 {
                blocks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private func makeMigratedPool(at url: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: url.path, configuration: configuration)
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)
        return pool
    }

    /// 当前进程 RSS（字节）。
    static func residentSize() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) {
                rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

/// 5ms 周期采样 RSS 取峰值（与 StreamingBackupScaleTests 同款）。
private final class S21PeakSampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var lock = NSLock()
    private var peakValue: Int64 = 0

    func start() {
        lock.lock()
        peakValue = 0
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = AIStudyPerfTests.residentSize()
            self.lock.lock()
            self.peakValue = max(self.peakValue, current)
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }
}

private extension Duration {
    var milliseconds: Int64 {
        (components.seconds * 1_000)
            + (components.attoseconds / 1_000_000_000_000_000)
    }
}
