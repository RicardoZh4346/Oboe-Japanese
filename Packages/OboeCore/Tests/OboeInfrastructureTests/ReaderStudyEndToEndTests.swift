import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S20 端到端验收（fake AI）：Reader 导入 → AI 准备 →
/// finalize → 预览/选择 → 应用（含 tooEasy/skip）→ 漏斗与
/// Coverage v2 → 快照幂等 → 应用重放 → 文档删除留史 →
/// v9 导出 → 恢复准备 → 新库恢复断言。
///
/// 单用例顺序走完整链路——它是「fake AI 环境可稳定自动跑完整
/// 链路」的最小可复现证明；各阶段断言即 Beta 一致性阻断项的
/// 验收表。
final class ReaderStudyEndToEndTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "reader-study-e2e-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 全链路

    func testReaderToLearningToBackupRestoreLifecycle() async throws {
        let env = try makeEnvironment()

        // —— 1) 导入夹具 + 词典桩 → 预检 ——
        let report = try await env.service.preflight(
            documentID: env.documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: Self.provider(.ready))
        XCTAssertTrue(report.canStart)

        // —— 2) 准备：证据写齐，业务对象零写 ——
        let job = try await env.service.prepare(
            documentID: env.documentID, report: report,
            configuration: report.provider.resolved!)
        let occurrenceCount = try await countRows(
            "reader_study_occurrences", in: env.pool)
        XCTAssertGreaterThan(occurrenceCount, 0)
        for table in ["notes", "cards", "note_decks",
                      "lexical_learning_units", "learning_unit_flags",
                      "learning_unit_note_links", "ai_study_receipts"] {
            let count = try await countRows(table, in: env.pool)
            XCTAssertEqual(count, 0, "\(table) 在确认前必须为空")
        }

        // —— 3) fake AI 跑完 → 收束 finalize ——
        let service = env.service
        let runner = AIStudyRunner(
            store: env.store,
            planner: { job in
                try await service.plannedBlocks(for: job)
            },
            sendRequest: { request in
                Self.successResult(for: request)
            })
        try await runner.start(jobID: job.id)
        await runner.waitUntilSettled(jobID: job.id)
        let settled = try await env.store.fetchJob(id: job.id)
        XCTAssertEqual(settled?.status, .awaitingConfirmation)

        try await env.service.finalizeResults(jobID: job.id)

        // finalize 后：occurrence 全部 aiResolved；S20 best-effort
        // 快照已落第一行（此时 unit 未物化——已解析无 unit 的
        // occurrence 如实计入 pending 桶，不伪造分母）。
        let first = try await env.pool.read { db in
            try GRDBReaderCoverageSnapshotStore.latestSnapshot(
                documentID: env.documentID, in: db)
        }
        let firstSnapshot = try XCTUnwrap(
            first, "finalize 后应已落 Coverage v2 快照")
        XCTAssertEqual(firstSnapshot.metricVersion,
                       ReaderCoverageV2.metricVersion)
        XCTAssertEqual(firstSnapshot.dictionaryVersion, "ds-test")
        XCTAssertEqual(firstSnapshot.morphologyVersion, "stub-morph-1")
        XCTAssertEqual(firstSnapshot.resolvedUnique, 0)
        XCTAssertEqual(firstSnapshot.pendingOccurrences, 4,
                       "猫/犬/好き/好き 四锚点已解析未绑 unit")
        XCTAssertEqual(firstSnapshot.analyzedBlocks, 2)
        XCTAssertEqual(firstSnapshot.totalBlocks, 2)

        // —— 4) 预览 + 三类选择 ——
        var preview = try await env.service.buildPreview(jobID: job.id)
        XCTAssertEqual(preview.items.count, 3,
                       "猫/犬/好き 三 unit 聚合（好き 跨块合并）")
        for index in preview.items.indices {
            switch preview.items[index].headword {
            case "猫":
                preview.items[index].decision = .create
                preview.items[index].proposedAction =
                    .createNote(directions: [.japaneseToChinese])
            case "犬":
                preview.items[index].decision = .tooEasy
                preview.items[index].proposedAction = .setTooEasy
            default:  // 好き
                preview.items[index].decision = .skip
                preview.items[index].proposedAction = .recordSkip
            }
        }
        _ = try await env.service.recordSelections(
            jobID: job.id, preview: preview,
            items: preview.items,
            correctedPending: preview.pending)
        // 确认后/应用前：业务对象仍零写。
        for table in ["notes", "cards", "note_decks",
                      "lexical_learning_units", "ai_study_receipts"] {
            let count = try await countRows(table, in: env.pool)
            XCTAssertEqual(count, 0, "\(table) 在 apply 前必须为空")
        }

        // —— 5) 应用 ——
        let applier = AIStudyApplyService(
            pool: env.pool,
            unitSources: DictionaryAIStudyUnitSourceProvider(
                repository: env.dictionary),
            // 应用晚于准备——与真实时钟同序（快照按 calculated_at
            // 倒序，后写的行才是「最新」）。
            now: { Date(timeIntervalSince1970: 1_800_000_060) })
        let applyReport = try await applier.applyConfirmedJob(
            jobID: job.id)
        XCTAssertEqual(applyReport.finalStatus, .completed)

        for (table, expected) in [
            ("notes", 1), ("cards", 1), ("note_decks", 1),
            ("lexical_learning_units", 2),
            ("learning_unit_note_links", 1),
            ("ai_study_receipts", 3),
        ] as [(String, Int)] {
            let count = try await countRows(table, in: env.pool)
            XCTAssertEqual(count, expected,
                           "\(table)：create+tooEasy 物化两 unit，"
                               + "skip 零学习数据只落 receipt")
        }

        // —— 6) tooEasy → mastered；create → learning ——
        let unitRows = try await env.pool.read { db -> [(UUID, String, Bool)] in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT u.id AS unitID, u.lemma,
                           COALESCE(f.too_easy, 0) AS tooEasy
                    FROM lexical_learning_units u
                    LEFT JOIN learning_unit_flags f
                      ON f.unit_id = u.id
                    ORDER BY u.lemma
                    """
            ).map { row in
                (
                    try DatabaseValueCodec.decodeUUID(row["unitID"]),
                    row["lemma"] as String,
                    (row["tooEasy"] as Int) != 0
                )
            }
        }
        var unitByLemma: [String: (id: UUID, tooEasy: Bool)] = [:]
        for (id, lemma, tooEasy) in unitRows {
            unitByLemma[lemma] = (id, tooEasy)
        }
        let dogUnit = try XCTUnwrap(unitByLemma["犬"])
        let catUnit = try XCTUnwrap(unitByLemma["猫"])
        XCTAssertTrue(dogUnit.tooEasy, "犬 flag.too_easy 置位")
        XCTAssertFalse(catUnit.tooEasy)

        let states = try await GRDBLearningProgressRepository(
            pool: env.pool
        ).knowledgeStates(unitIDs: [dogUnit.id, catUnit.id])
        XCTAssertEqual(states[dogUnit.id], .mastered)
        XCTAssertEqual(states[catUnit.id], .learning)

        // —— 7) 漏斗（当前态口径）——
        let funnel = try await GRDBReaderStudyMetricsRepository(
            pool: env.pool).funnel(documentID: env.documentID)
        XCTAssertEqual(funnel.preparedOccurrences, 6,
                       "coverage 计数含 auxiliary（が/も）——6 锚点")
        XCTAssertEqual(funnel.resolvedOccurrences, 4)
        XCTAssertEqual(funnel.pendingOccurrences, 0)
        XCTAssertEqual(funnel.oovOccurrences, 2,
                       "が/も 无候选 → unresolved 入 OOV 桶")
        XCTAssertEqual(funnel.selectedCreate, 1)
        XCTAssertEqual(funnel.selectedTooEasy, 1)
        XCTAssertEqual(funnel.selectedSkip, 1)
        XCTAssertEqual(funnel.appliedCreate, 1)
        XCTAssertEqual(funnel.appliedTooEasy, 1)
        XCTAssertEqual(funnel.appliedSkip, 1)
        XCTAssertEqual(funnel.completedJobs, 1)

        // —— 8) 应用后快照：unit 链接已回填 → 分母非空 ——
        let snapshotRows = try await env.pool.read { db in
            try GRDBReaderCoverageSnapshotStore.fetchSnapshots(
                snapshotOf: DatabaseValueCodec.encode(env.documentID),
                in: db)
        }
        XCTAssertEqual(snapshotRows.count, 2,
                       "finalize + apply 各落一行（知识语境漂移开新行）")
        let postApply = try XCTUnwrap(
            snapshotRows.first, "最新快照（按时间倒序）")
        XCTAssertEqual(postApply.resolvedUnique, 2,
                       "create/tooEasy 两 unit 的 occurrence 已绑 unit_id")
        XCTAssertEqual(postApply.learningUnique, 1)
        XCTAssertEqual(postApply.masteredUnique, 1)
        XCTAssertEqual(postApply.pendingOccurrences, 2,
                       "好き 两次出现的锚点已解析未物化——如实入待确认")
        XCTAssertEqual(postApply.resolvedUnique,
                       postApply.learningUnique + postApply.masteredUnique,
                       "已解析 2 = 学习中 1 + 已掌握 1 → 覆盖率 100%")

        // 快照写入幂等：同知识语境重算不重插。
        let repeatWrite = try await env.pool.write { db in
            try GRDBReaderCoverageSnapshotStore.recordDocumentSnapshot(
                documentID: env.documentID,
                dictionaryVersion: "ds-test",
                morphologyVersion: "stub-morph-1",
                in: db)
        }
        XCTAssertFalse(repeatWrite.inserted)

        // —— 9) 应用重放：completed Job 只读报告，零重复写 ——
        let replay = try await applier.applyConfirmedJob(jobID: job.id)
        XCTAssertEqual(replay.entryStatus, .completed)
        XCTAssertEqual(replay.finalStatus, .completed)
        for (table, expected) in [
            ("notes", 1), ("cards", 1), ("note_decks", 1),
            ("lexical_learning_units", 2), ("ai_study_receipts", 3),
        ] as [(String, Int)] {
            let count = try await countRows(table, in: env.pool)
            XCTAssertEqual(count, expected,
                           "\(table) 重放不得重复写")
        }

        // —— 10) v9 导出 ——
        let exportsURL = directory.appendingPathComponent(
            "exports", isDirectory: true)
        let export = try await PortableBackupExporter(
            database: env.database,
            workingDirectoryURL: exportsURL
        ).export(appVersion: "0.7.5-e2e",
                 at: Date(timeIntervalSince1970: 1_800_000_000),
                 recordFormatVersion: 9)
        for recordType in ["learningUnit", "learningUnitFlag",
                           "learningUnitNoteLink", "readerStudyOccurrence",
                           "aiStudyJob", "aiStudySelection",
                           "aiStudyReceipt",
                           "readerLearningCoverageSnapshot",
                           "note", "card", "noteDeck"] {
            XCTAssertGreaterThan(
                export.recordCounts[recordType] ?? 0, 0,
                "v9 导出应携带 \(recordType)")
        }

        // —— 11) 恢复准备 → 落到新库 ——
        let current = try OboeDatabase(
            path: directory.appendingPathComponent("current.sqlite").path)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: directory.appendingPathComponent(
                "preparations", isDirectory: true))
        let prepared = try await preparer.prepare(fileURL: export.url)
        XCTAssertEqual(prepared.sourceFormatVersion, 9)

        let restored = try OboeDatabase(
            path: prepared.temporaryDatabaseURL.path)
        let restoredCounts = try await restored.pool.read { db in
            (
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM lexical_learning_units"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM learning_unit_flags"
                        + " WHERE too_easy = 1"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM learning_unit_note_links"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM notes"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM cards"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM note_decks"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM reader_study_occurrences"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM reader_study_occurrences"
                        + " WHERE unit_id IS NOT NULL"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM ai_study_jobs"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM ai_study_selections"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM ai_study_receipts"),
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*)"
                        + " FROM reader_learning_coverage_snapshots")
            )
        }
        XCTAssertEqual(restoredCounts.0, 2)
        XCTAssertEqual(restoredCounts.1, 1, "tooEasy flag 恢复")
        XCTAssertEqual(restoredCounts.2, 1)
        XCTAssertEqual(restoredCounts.3, 1)
        XCTAssertEqual(restoredCounts.4, 3,
                       "恢复后重跑 v12 fillVocabularyDirections——"
                           + "词汇笔记补齐三方向卡")
        XCTAssertEqual(restoredCounts.5, 1)
        XCTAssertEqual(restoredCounts.6, 6,
                       "occurrence 含 auxiliary 锚点（与源库一致）")
        XCTAssertEqual(restoredCounts.7, 2,
                       "猫/犬 occurrence 的 unit 链接随备份走")
        XCTAssertEqual(restoredCounts.8, 1)
        XCTAssertEqual(restoredCounts.9, 3)
        XCTAssertEqual(restoredCounts.10, 3)
        XCTAssertEqual(restoredCounts.11, 2)

        // 恢复库上 Coverage v2 趋势仍可分段读出（同版本三元组一段）。
        let restoredSegments = try await GRDBReaderStudyMetricsRepository(
            database: restored).coverageTrend(documentID: env.documentID)
        XCTAssertEqual(restoredSegments.count, 1)
        XCTAssertEqual(restoredSegments.first?.points.count, 2)
        XCTAssertEqual(restoredSegments.first?.metricVersion,
                       ReaderCoverageV2.metricVersion)
        try restored.close()

        // —— 12) 源库删文档：快照经 snapshot id 留史（D09）——
        try await env.pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(env.documentID)])
        }
        let orphanRows = try await env.pool.read { db in
            try GRDBReaderCoverageSnapshotStore.fetchSnapshots(
                snapshotOf: DatabaseValueCodec.encode(env.documentID),
                in: db)
        }
        XCTAssertEqual(orphanRows.count, 2)
        XCTAssertTrue(orphanRows.allSatisfy { $0.documentID == nil })
        XCTAssertEqual(orphanRows.first?.documentIDSnapshot,
                       DatabaseValueCodec.encode(env.documentID))
        // 活算口径：文档已删 → 空漏斗/无活算；历史快照仍按段读出。
        let metrics = GRDBReaderStudyMetricsRepository(pool: env.pool)
        let deadFunnel = try await metrics.funnel(
            documentID: env.documentID)
        XCTAssertEqual(deadFunnel, ReaderStudyFunnel())
        let deadLive = try await metrics.liveCoverage(
            documentID: env.documentID)
        XCTAssertNil(deadLive)
        let historicalSegments = try await metrics.coverageTrend(
            documentID: env.documentID)
        XCTAssertEqual(historicalSegments.count, 1)
        XCTAssertEqual(historicalSegments.first?.points.count, 2)

        try env.database.close()
        try current.close()
    }

    // MARK: - 夹具

    private struct Environment {
        let database: OboeDatabase
        var pool: DatabasePool { database.pool }
        let store: GRDBAIStudyJobStore
        let service: AIStudyPreparationService
        let dictionary: StubDictionary
        let documentID: UUID
    }

    /// 单章两块「猫が好き。」「犬も好き。」——词元均有候选；
    /// 虚词 auxiliary 也进 occurrence（无候选 → unresolved/OOV
    /// 桶），nonLexical 不进。
    private func makeEnvironment() throws -> Environment {
        let documentID = UUID()
        let chapterID = UUID()
        let block0ID = UUID()
        let block1ID = UUID()
        let blockIDs = [block0ID, block1ID]
        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path)

        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, content_revision, availability)
                    VALUES (?, 'E2E 読物', 'paste', 1,
                            '0000000000000000000000000000000000000000000000000000000000000000',
                            'canon-1', 'parser-1', 1, 'available')
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title, source_locator,
                        canonical_hash, text_utf16_length)
                    VALUES (?, ?, 0, '一章', NULL, 'ch-1', 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID)])
            for (ordinal, text) in ["猫が好き。", "犬も好き。"].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal,
                            text, text_hash, locator_json)
                        VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(blockIDs[ordinal]),
                        DatabaseValueCodec.encode(documentID),
                        DatabaseValueCodec.encode(chapterID),
                        ordinal, text, "bh-\(ordinal)"])
            }
        }

        let blocksByChapter: [UUID: [ReaderBlock]] = [
            chapterID: [
                ReaderBlock(
                    id: block0ID, documentID: documentID,
                    chapterID: chapterID, ordinal: 0,
                    text: "猫が好き。", textHash: "bh-0",
                    locatorJSON: nil),
                ReaderBlock(
                    id: block1ID, documentID: documentID,
                    chapterID: chapterID, ordinal: 1,
                    text: "犬も好き。", textHash: "bh-1",
                    locatorJSON: nil),
            ]
        ]
        let chapters = [
            ReaderChapterMetadata(
                id: chapterID, documentID: documentID, ordinal: 0,
                title: "一章", sourceLocator: nil,
                canonicalHash: "ch-1", textUTF16Length: 10)
        ]
        let document = ReaderDocumentMetadata(
            id: documentID, title: "E2E 読物", format: .paste,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, sourceFileName: nil,
            sourceSHA256: String(repeating: "0", count: 64),
            canonicalTextHash: "canon-1", parserVersion: "parser-1",
            contentRevision: 1, progressBasisPoints: 0,
            availability: .available)

        let dictionary = StubDictionary()
        dictionary.stubbedEntries[100] = Self.makeEntry(
            id: 100, form: "猫", reading: "ねこ",
            senseID: 101, gloss: "cat")
        dictionary.stubbedEntries[200] = Self.makeEntry(
            id: 200, form: "好き", reading: "すき",
            senseID: 201, gloss: "like")
        dictionary.stubbedEntries[300] = Self.makeEntry(
            id: 300, form: "犬", reading: "いぬ",
            senseID: 301, gloss: "dog")

        let store = GRDBAIStudyJobStore(pool: database.pool)
        let service = AIStudyPreparationService(
            pool: database.pool,
            reader: StubReader(
                document: document, chapters: chapters,
                blocks: blocksByChapter),
            morphology: StubMorphology(),
            dictionary: dictionary,
            jobStore: store,
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return Environment(
            database: database, store: store, service: service,
            dictionary: dictionary, documentID: documentID)
    }

    private func countRows(_ table: String, in pool: DatabasePool)
        async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private static func provider(_ state: AIStudyProviderReadiness.State)
        -> AIStudyProviderReadiness {
        let resolved: ResolvedAIConfiguration? =
            state == .disabled || state == .missingModel
                ? nil
                : ResolvedAIConfiguration(
                    isEnabled: true, serviceKind: .deepSeek,
                    serviceName: "DeepSeek",
                    baseURL: URL(string: "https://api.deepseek.com")!,
                    modelID: "model-1",
                    responseFormatMode: .promptedJSON,
                    credentialReference: AICredentialReference(
                        id: UUID(), serviceKind: .deepSeek,
                        host: "api.deepseek.com"))
        return AIStudyProviderReadiness(
            state: state, isEnabled: state != .disabled,
            serviceName: "DeepSeek", serviceKind: .deepSeek,
            modelID: state == .missingModel ? nil : "model-1",
            resolved: resolved)
    }

    private static func makeEntry(
        id: Int64, form: String, reading: String,
        senseID: Int64, gloss: String
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: id, primaryForm: form, commonRank: nil,
            forms: [DictionaryForm(
                id: id * 10, text: form,
                formType: "standard", priority: nil)],
            readings: [DictionaryReading(
                id: id * 10 + 1, reading: reading, noKanji: false,
                restrictedFormIDs: [], restrictedForms: [])],
            senses: [DictionarySense(
                id: senseID, order: 1, posCodes: ["n"], tags: [],
                glosses: [DictionaryGloss(
                    language: "eng", text: gloss, order: 1,
                    sourceID: "test", isMachineGenerated: false)])])
    }

    /// 假 resolver 成果：每块带候选 token 解析到候选义项——
    /// 与 `AIStudyPreparationServiceTests` 同款语义。
    private static func successResult(
        for request: AIStudyRequest
    ) -> AIStudyResolverResult {
        let block = request.blocks[0]
        var resolutions: [AIStudyResolution] = []
        var resolvedCount = 0
        for token in block.tokens {
            if let candidate = token.candidates.first,
               let sense = candidate.senses.first {
                resolutions.append(AIStudyResolution(
                    tokenKey: token.tokenID,
                    selected: AIStudySelection(
                        provider: "jmdict",
                        entryID: candidate.entryID,
                        senseID: sense.senseID,
                        datasetVersion: request.metadata
                            .dictionaryDatasetVersion),
                    confidence: 0.92,
                    status: .aiResolved,
                    reasonCode: nil, origin: .ai))
                resolvedCount += 1
            } else {
                resolutions.append(AIStudyResolution(
                    tokenKey: token.tokenID,
                    selected: nil, confidence: nil,
                    status: .unresolved,
                    reasonCode: .noCandidate, origin: .ai))
            }
        }
        return AIStudyResolverResult(
            outcome: ValidatedBlockOutcome(
                blockKey: block.blockKey,
                lexicalStatus: resolvedCount > 0
                    ? .resolved : .unresolved,
                translationStatus: block.wantsTranslation
                    ? .done : .notRequested,
                translation: block.wantsTranslation
                    ? "译文-\(block.blockKey)" : nil,
                envelopeRejection: nil,
                resolutions: resolutions,
                targetTokenCount: block.tokens.count,
                aiResolvedCount: resolvedCount,
                lowConfidenceCount: 0,
                unresolvedTokenCount:
                    block.tokens.count - resolvedCount,
                droppedUnknownTokenCount: 0,
                duplicateTokenCount: 0,
                malformedItemCount: 0, invalidItemCount: 0),
            requestHash: request.requestHash,
            requestID: request.requestID,
            providerKind: "stub", model: "stub-model",
            promptVersion: request.metadata.promptVersion,
            responseMode: .promptedJSON,
            suggestedRetryAfter: nil, responseBytes: 128)
    }

    // MARK: - 桩件（与 preparation 测试同形，本文件自持有）

    private struct StubReader: AIStudyPreparationService.ReaderSource {
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

    private struct StubMorphology:
        AIStudyPreparationService.MorphologySource {
        let morphologyVersion = "stub-morph-1"
        let osBuild = "stub-os"
        let dictionaryDatasetVersion = "ds-test"

        func tokenize(_ block: MorphologyBlock) async throws
            -> [ReaderToken] {
            Self.tokens(for: block.text)
        }

        static func tokens(for text: String) -> [ReaderToken] {
            var tokens: [ReaderToken] = []
            var offset = 0
            var systemIndex = 0
            func push(
                _ surface: String, _ tokenClass: ReaderTokenClass,
                entryID: Int64? = nil, lemma: String? = nil
            ) {
                let length = surface.utf16.count
                tokens.append(ReaderToken(
                    surface: surface,
                    sourceRangeUTF16: offset..<(offset + length),
                    systemTokenIndexes:
                        systemIndex..<(systemIndex + 1),
                    candidates: entryID.map { id in
                        [MorphologyCandidate(
                            lemma: lemma ?? surface,
                            normalizedForm: lemma ?? surface,
                            reading: nil,
                            posCodes: ["n"], entryID: id,
                            reasons: [], cost: 0)]
                    } ?? [],
                    tokenClass: tokenClass,
                    reading: nil, lexicalKey: nil,
                    resolutionStatus: .resolved,
                    provenance: ["stub"]))
                offset += length
                systemIndex += 1
            }
            for unit in text.split(
                separator: "。", omittingEmptySubsequences: false
            ) {
                var rest = String(unit)[...]
                while !rest.isEmpty {
                    if rest.hasPrefix("猫") {
                        push("猫", .lexical, entryID: 100)
                        rest = rest.dropFirst(1)
                    } else if rest.hasPrefix("犬") {
                        push("犬", .lexical, entryID: 300)
                        rest = rest.dropFirst(1)
                    } else if rest.hasPrefix("鳥") {
                        push("鳥", .lexical, entryID: 400)
                        rest = rest.dropFirst(1)
                    } else if rest.hasPrefix("好き") {
                        push("好き", .lexical, entryID: 200)
                        rest = rest.dropFirst(2)
                    } else if rest.hasPrefix("が")
                                || rest.hasPrefix("も")
                                || rest.hasPrefix("だ") {
                        push(String(rest.prefix(1)), .auxiliary)
                        rest = rest.dropFirst(1)
                    } else if rest.hasPrefix("。") {
                        push("。", .nonLexical)
                        rest = rest.dropFirst(1)
                    } else {
                        push(String(rest.prefix(1)), .nonLexical)
                        rest = rest.dropFirst(1)
                    }
                }
            }
            return tokens
        }
    }

    private final class StubDictionary: DictionaryRepository,
        @unchecked Sendable {
        var stubbedEntries: [Int64: DictionaryEntry] = [:]

        func metadata() async throws -> DictionaryMetadata {
            DictionaryMetadata(
                schemaVersion: "1", datasetVersion: "ds-test",
                dictionaryVersion: "dv-1")
        }
        func search(_ request: DictionarySearchRequest) async throws
            -> DictionarySearchPage {
            DictionarySearchPage(
                items: [], nextCursor: nil, hasMore: false,
                normalizedQuery: request.normalizedQuery)
        }
        func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
            ids.compactMap { stubbedEntries[$0] }
        }
        func entry(id: Int64) async throws -> DictionaryEntry? {
            stubbedEntries[id]
        }
        func sources() async throws -> [DictionarySourceInfo] { [] }
    }
}
