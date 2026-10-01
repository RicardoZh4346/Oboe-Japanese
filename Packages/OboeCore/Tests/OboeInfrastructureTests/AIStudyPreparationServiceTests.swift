import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S15：准备编排服务验收——预检/范围解析、Job+manifest
/// 原子创建、确定性 replan、确认前零业务写、选择落库与陈旧
/// 防线、端到端摘要。
final class AIStudyPreparationServiceTests: XCTestCase {

    // MARK: - 环境

    private struct Environment {
        let pool: DatabasePool
        let store: GRDBAIStudyJobStore
        let service: AIStudyPreparationService
        let document: ReaderDocumentMetadata
        let chapters: [ReaderChapterMetadata]
        let blocksByChapter: [UUID: [ReaderBlock]]
        let dictionary: StubDictionary
    }

    private let documentID = UUID()
    private let chapterAID = UUID()
    private let chapterBID = UUID()
    private let blockA0 = UUID()
    private let blockA1 = UUID()
    private let blockB0 = UUID()

    /// 全文：chA 两块「猫が好き。」「犬も好き。」、chB 一块「鳥だ。」
    private func makeEnvironment(
        chapterCount: Int = 2,
        chapterABlockTexts: [String] = ["猫が好き。", "犬も好き。"]
    ) async throws -> Environment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AIStudyPrep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
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
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: configuration)
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)

        let document = ReaderDocumentMetadata(
            id: documentID, title: "テスト読物", format: .paste,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, sourceFileName: nil,
            sourceSHA256: String(repeating: "0", count: 64),
            canonicalTextHash: "canon-1", parserVersion: "parser-1",
            contentRevision: 1, progressBasisPoints: 0,
            availability: .available)
        var chapters: [ReaderChapterMetadata] = [
            ReaderChapterMetadata(
                id: chapterAID, documentID: documentID, ordinal: 0,
                title: "第一章", sourceLocator: nil,
                canonicalHash: "ch-a",
                textUTF16Length: 10),
        ]
        var blocks: [UUID: [ReaderBlock]] = [
            chapterAID: zip(
                [blockA0, blockA1] + chapterABlockTexts.dropFirst(2).map { _ in UUID() }, chapterABlockTexts
            ).enumerated().map { ordinal, pair in
                ReaderBlock(
                    id: pair.0, documentID: documentID,
                    chapterID: chapterAID, ordinal: ordinal,
                    text: pair.1, textHash: "bh-a\(ordinal)",
                    locatorJSON: nil)
            },
        ]
        if chapterCount > 1 {
            chapters.append(ReaderChapterMetadata(
                id: chapterBID, documentID: documentID, ordinal: 1,
                title: "第二章", sourceLocator: nil,
                canonicalHash: "ch-b", textUTF16Length: 4))
            blocks[chapterBID] = [
                ReaderBlock(
                    id: blockB0, documentID: documentID,
                    chapterID: chapterBID, ordinal: 0,
                    text: "鳥だ。", textHash: "bh-b0",
                    locatorJSON: nil),
            ]
        }
        let insertedChapters = chapters
        let insertedBlocks = blocks
        let seededDocumentID = documentID
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, content_revision, availability)
                    VALUES (?, 'テスト読物', 'paste', 1, ?, 'canon-1',
                            'parser-1', 1, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(seededDocumentID),
                    String(repeating: "0", count: 64),
                ])
            for chapter in insertedChapters {
                try db.execute(
                    sql: """
                        INSERT INTO reader_chapters(
                            id, document_id, ordinal, title,
                            canonical_hash, text_utf16_length)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(chapter.id),
                        DatabaseValueCodec.encode(seededDocumentID),
                        chapter.ordinal, chapter.title,
                        chapter.canonicalHash, chapter.textUTF16Length,
                    ])
                for block in insertedBlocks[chapter.id] ?? [] {
                    try db.execute(
                        sql: """
                            INSERT INTO reader_blocks(
                                id, document_id, chapter_id, ordinal,
                                text, text_hash)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(block.id),
                            DatabaseValueCodec.encode(seededDocumentID),
                            DatabaseValueCodec.encode(chapter.id),
                            block.ordinal, block.text, block.textHash,
                        ])
                }
            }
        }

        let dictionary = StubDictionary()
        dictionary.stubbedEntries[100] = Self.makeEntry(
            id: 100, form: "猫", reading: "ねこ", senseID: 101,
            gloss: "cat")
        dictionary.stubbedEntries[200] = Self.makeEntry(
            id: 200, form: "好き", reading: "すき", senseID: 201,
            gloss: "like")
        dictionary.stubbedEntries[300] = Self.makeEntry(
            id: 300, form: "犬", reading: "いぬ", senseID: 301,
            gloss: "dog")
        dictionary.stubbedEntries[400] = Self.makeEntry(
            id: 400, form: "鳥", reading: "とり", senseID: 401,
            gloss: "bird")

        let store = GRDBAIStudyJobStore(pool: pool)
        let service = AIStudyPreparationService(
            pool: pool,
            reader: StubReader(
                document: document, chapters: chapters,
                blocks: blocks),
            morphology: StubMorphology(),
            dictionary: dictionary,
            jobStore: store,
            jlptIndexProvider: {
                AIStudyJLPTReferenceIndex(rows: [
                    .init(headword: "猫", reading: "ねこ", level: .n5),
                ])
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        return Environment(
            pool: pool, store: store, service: service,
            document: document, chapters: chapters,
            blocksByChapter: blocks, dictionary: dictionary)
    }

    private static func makeEntry(
        id: Int64, form: String, reading: String,
        senseID: Int64, gloss: String
    ) -> DictionaryEntry {
        makeEntry(
            id: id, form: form, reading: reading,
            senses: [(id: senseID, gloss: gloss)])
    }

    /// 多义项版本（义项扩展测试用）——每 (id, gloss) 一个 sense。
    private static func makeEntry(
        id: Int64, form: String, reading: String,
        senses: [(id: Int64, gloss: String)]
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: id, primaryForm: form, commonRank: nil,
            forms: [DictionaryForm(
                id: id * 10, text: form,
                formType: "standard", priority: nil)],
            readings: [DictionaryReading(
                id: id * 10 + 1, reading: reading, noKanji: false,
                restrictedFormIDs: [], restrictedForms: [])],
            senses: senses.enumerated().map { order, sense in
                DictionarySense(
                    id: sense.id, order: order + 1,
                    posCodes: ["n"], tags: [],
                    glosses: [DictionaryGloss(
                        language: "eng", text: sense.gloss,
                        order: 1, sourceID: "test",
                        isMachineGenerated: false)])
            })
    }

    private func provider(_ state: AIStudyProviderReadiness.State)
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

    private func countRows(_ table: String, in pool: DatabasePool)
        async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: - 预检

    /// 全书范围：3 块/2 章、估算计数、provider 就绪回显。
    func testPreflightWholeBook() async throws {
        let env = try await makeEnvironment()
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        XCTAssertTrue(report.canStart)
        XCTAssertEqual(report.estimate.chapterCount, 2)
        XCTAssertEqual(report.estimate.blockCount, 3)
        XCTAssertEqual(report.provider.state, .ready)
        XCTAssertNil(report.activeJob)
    }

    /// currentText 锚定当前块；锚缺失 → emptyScope。
    func testPreflightCurrentTextAndEmptyScope() async throws {
        let env = try await makeEnvironment()
        let scoped = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(
                choice: .currentText, blockID: blockA0),
            provider: provider(.ready))
        XCTAssertEqual(scoped.estimate.blockCount, 1)

        let empty = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(
                choice: .currentText, blockID: UUID()),
            provider: provider(.ready))
        XCTAssertTrue(empty.issues.contains(.emptyScope))
        XCTAssertFalse(empty.canStart)
    }

    /// 文档缺失 → 直接抛 documentMissing。
    func testPreflightMissingDocumentThrows() async throws {
        let env = try await makeEnvironment()
        await XCTAssertAsyncThrowsError(
            try await env.service.preflight(
                documentID: UUID(),
                request: AIStudyScopeRequest(choice: .wholeBook),
                provider: provider(.ready))
        ) { error in
            guard case AIStudyPreparationService.PreparationError
                .documentMissing = error else {
                return XCTFail("期望 documentMissing，得 \(error)")
            }
        }
    }

    /// 「未处理章节」：第一章已产出非 pending occurrence →
    /// 只剩第二章入范围。
    func testPreflightUnprocessedChapters() async throws {
        let env = try await makeEnvironment()
        // 为第一章种一条已解析 occurrence（当前 revision 口径）。
        let docID = documentID
        try await env.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_study_occurrences(
                        id, document_id, content_revision,
                        locator_json, block_source_hash,
                        tokenizer_version, start_utf16, length_utf16,
                        resolution_status)
                    VALUES (?, ?, 1,
                            '{"chapterOrdinal":0}', 'bh-a0',
                            'tv', 0, 1, 'aiResolved')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(docID),
                ])
        }
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(
                choice: .unprocessedChapters),
            provider: provider(.ready))
        XCTAssertEqual(report.estimate.chapterCount, 1)
        XCTAssertEqual(report.estimate.blockCount, 1)
    }

    // MARK: - 准备（确认前零业务写）

    /// prepare：Job+manifest+occurrence 锚点+token 缓存落库；
    /// notes/cards/deck_memberships 仍为空。
    func testPrepareWritesEvidenceButNoBusinessObjects() async throws {
        let env = try await makeEnvironment()
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)

        let stored = try await env.store.fetchJob(id: job.id)
        XCTAssertEqual(stored?.status, .pending)
        XCTAssertNotNil(stored?.studyDeckID,
                        "文章牌组在 Job 事务内绑定")
        let manifest = try await env.service.loadManifest(jobID: job.id)
        XCTAssertEqual(manifest?.documentID, documentID)
        XCTAssertEqual(manifest?.blocks.count, 3)
        XCTAssertEqual(manifest?.formatVersion,
                       AIStudyPreparation.manifestFormatVersion)

        // 证据写：occurrence pending 锚点 + token 缓存。
        let occurrences = try await countRows(
            "reader_study_occurrences", in: env.pool)
        XCTAssertGreaterThan(occurrences, 0)
        let cached = try await countRows(
            "reader_token_cache", in: env.pool)
        XCTAssertEqual(cached, 3)

        // 业务对象零写。
        for table in ["notes", "cards", "note_decks"] {
            let count = try await countRows(table, in: env.pool)
            XCTAssertEqual(count, 0, "\(table) 在确认前必须为空")
        }
        // 块行由 Runner 的 planner 装块——prepare 不预建。
        let blocks = try await env.store.fetchBlocks(jobID: job.id)
        XCTAssertTrue(blocks.isEmpty)
    }

    /// manifest replan 确定性：两次 plannedBlocks 的
    /// requestHash/subblockKey 集合逐字节一致。
    func testPlannedBlocksDeterministic() async throws {
        let env = try await makeEnvironment()
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)

        let first = try await env.service.plannedBlocks(for: job)
        let second = try await env.service.plannedBlocks(for: job)
        XCTAssertEqual(
            first.map { $0.block.subblockKey },
            second.map { $0.block.subblockKey })
        XCTAssertEqual(
            first.map { $0.request.requestHash },
            second.map { $0.request.requestHash })
        XCTAssertEqual(
            Set(first.map { $0.request.requestHash }).count,
            first.count, "每块唯一请求")
    }

    /// 预检阻断仍调用 prepare → precheckFailed。
    func testPrepareRejectsFailedPrecheck() async throws {
        let env = try await makeEnvironment()
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(
                choice: .currentText, blockID: UUID()),
            provider: provider(.ready))
        await XCTAssertAsyncThrowsError(
            try await env.service.prepare(
                documentID: documentID, report: report,
                configuration: report.provider.resolved!)
        ) { error in
            guard case AIStudyPreparationService.PreparationError
                .precheckFailed = error else {
                return XCTFail("期望 precheckFailed，得 \(error)")
            }
        }
    }

    // MARK: - 端到端：分析 → 预览 → 确认 → 应用 → 摘要

    /// 全链路：Runner 跑完 → finalizeResults → buildPreview →
    /// recordSelections（仍零业务写）→ applyConfirmedJob →
    /// 新建 Note + membership + summary 计数。
    func testEndToEndConfirmApplies() async throws {
        let env = try await makeEnvironment(chapterCount: 1)
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)

        // Runner：manifest replan + 假 transport（每块返回全 resolved）。
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

        var preview = try await env.service.buildPreview(
            jobID: job.id)
        XCTAssertEqual(preview.resolvedBlockCount, 2)
        XCTAssertEqual(preview.failedBlockCount, 0)
        XCTAssertEqual(preview.items.count, 3,
                       "猫/犬/好き 三 unit 聚合（好き 跨块合并）")
        XCTAssertEqual(
            preview.items.first(where: { $0.headword == "猫" })?
                .jlptLevel, .n5)

        // 策略：全部 → 每 item 决策就位。
        AIStudySelectionStrategy.all.apply(
            to: &preview.items,
            studyDeckID: settled?.studyDeckID,
            directions: [.japaneseToChinese])
        _ = try await env.service.recordSelections(
            jobID: job.id, preview: preview,
            items: preview.items,
            correctedPending: preview.pending)

        // 确认完成但应用前——业务对象仍零写。
        for table in ["notes", "cards", "note_decks"] {
            let count = try await countRows(table, in: env.pool)
            XCTAssertEqual(count, 0, "\(table) 在 apply 前必须为空")
        }

        let applier = AIStudyApplyService(
            pool: env.pool,
            unitSources: DictionaryAIStudyUnitSourceProvider(
                repository: env.dictionary))
        let applyReport = try await applier.applyConfirmedJob(
            jobID: job.id)
        XCTAssertEqual(applyReport.finalStatus, .completed)

        let noteCount = try await countRows("notes", in: env.pool)
        XCTAssertEqual(noteCount, 3)
        let memberships = try await countRows(
            "note_decks", in: env.pool)
        XCTAssertEqual(memberships, 3)
        let cards = try await countRows("cards", in: env.pool)
        XCTAssertEqual(cards, 3, "directions 日→中 一方向一卡")

        let summary = try await env.service.summary(
            jobID: job.id, report: applyReport,
            unselectedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.status, .completed)
        XCTAssertEqual(summary.createdNoteCount, 3)
        XCTAssertEqual(summary.createdCardCount, 3)
        XCTAssertNotNil(summary.studyDeckID)
        XCTAssertNotNil(summary.deckName)
    }

    /// 同一候选词有多个合法义项时，仅保存 AI 根据上下文选中的义项。
    func testBuildPreviewUsesOnlySelectedContextualSense() async throws {
        let env = try await makeEnvironment(
            chapterCount: 1,
            chapterABlockTexts: ["多義が好き。", "犬も好き。"])
        env.dictionary.stubbedEntries[500] = Self.makeEntry(
            id: 500, form: "多義", reading: "たぎ", senses: [
                (id: 501, gloss: "meaning A"),
                (id: 502, gloss: "meaning B"),
                (id: 503, gloss: "meaning C"),
            ])
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)
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
        try await env.service.finalizeResults(jobID: job.id)

        let preview = try await env.service.buildPreview(jobID: job.id)
        let selected = preview.items.filter { $0.entryID == 500 }
        XCTAssertEqual(selected.count, 1,
                       "单个选定义项只产生一行")
        let item = try XCTUnwrap(selected.first)
        XCTAssertEqual(
            item.mergedSenseIDs, [501],
            "只冻结句中选择的义项")
        XCTAssertEqual(item.senseID, 501,
                       "unitKey 锚定实际选择的义项")
        XCTAssertTrue(
            item.glossSummary != nil && item.firstSentence != nil)
        // 动作与卡面都不能带入未选中的其它候选释义。
        var appliedItems = preview.items
        AIStudySelectionStrategy.all.apply(
            to: &appliedItems, studyDeckID: nil,
            directions: [.japaneseToChinese])
        let applied = try XCTUnwrap(
            appliedItems.first { $0.entryID == 500 })
        if case .createNote(_, let senseIDs) = applied.proposedAction {
            XCTAssertEqual(senseIDs, [501])
        } else {
            XCTFail("选定义项的默认动作应是 createNote")
        }
        _ = try await env.service.recordSelections(
            jobID: job.id, preview: preview, items: appliedItems,
            correctedPending: preview.pending)
        let applier = AIStudyApplyService(pool: env.pool,
            unitSources: DictionaryAIStudyUnitSourceProvider(repository: env.dictionary))
        let result = try await applier.applyConfirmedJob(jobID: job.id)
        XCTAssertTrue(result.failedUnits.isEmpty, "\(result.failedUnits)")
        let meaning = try await env.pool.read { db in
            try String.fetchOne(db, sql: "SELECT meaning_zh FROM notes WHERE headword = '多義'")
        }
        XCTAssertEqual(meaning, "meaning A")

        // 同块其它解析照常；总条目 = 所选义项 + 好き + 犬 = 3。
        XCTAssertEqual(preview.items.count, 3)
        // pending 里是 が/も 类无候选 unresolved（原设计）；已选定
        // entry 的 token 绝不留在待确认队列。
        XCTAssertFalse(preview.pending.contains {
            $0.surface == "多義"
        })
    }

    func testDifferentContextualSensesCreateSeparateNotesAndKeepEvidence() async throws {
        let env = try await makeEnvironment(chapterCount: 1,
            chapterABlockTexts: ["多義が好き。", "多義も好き。", "多義だ。"])
        env.dictionary.stubbedEntries[500] = Self.makeEntry(id: 500, form: "多義", reading: "たぎ",
            senses: [(501, "meaning A"), (502, "meaning B"), (503, "unused meaning C")])
        let report = try await env.service.preflight(documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook), provider: provider(.ready))
        let job = try await env.service.prepare(documentID: documentID, report: report,
            configuration: report.provider.resolved!)
        let service = env.service
        let runner = AIStudyRunner(store: env.store,
            planner: { try await service.plannedBlocks(for: $0) },
            sendRequest: { Self.successResult(for: $0, contextualSenses: true) })
        try await runner.start(jobID: job.id)
        await runner.waitUntilSettled(jobID: job.id)
        try await service.finalizeResults(jobID: job.id)
        let preview = try await service.buildPreview(jobID: job.id)
        let polysemous = preview.items.filter { $0.entryID == 500 }
        XCTAssertEqual(Set(polysemous.map(\.senseID)), [501, 502])
        XCTAssertEqual(Set(polysemous.map(\.unitKey)).count, 2)
        XCTAssertEqual(polysemous.first { $0.senseID == 501 }?.occurrenceCount, 2)
        XCTAssertEqual(polysemous.first { $0.senseID == 502 }?.occurrenceCount, 1)
        XCTAssertEqual(polysemous.first { $0.senseID == 501 }?.firstSentence, "多義が好き。")
        XCTAssertEqual(polysemous.first { $0.senseID == 502 }?.firstSentence, "多義も好き。")
        var items = preview.items
        AIStudySelectionStrategy.all.apply(to: &items, studyDeckID: nil,
            directions: Set(VocabularyCardDirection.allCases))
        _ = try await service.recordSelections(jobID: job.id, preview: preview, items: items,
            correctedPending: preview.pending)
        let applier = AIStudyApplyService(pool: env.pool,
            unitSources: DictionaryAIStudyUnitSourceProvider(repository: env.dictionary))
        let applied = try await applier.applyConfirmedJob(jobID: job.id)
        XCTAssertTrue(applied.failedUnits.isEmpty, "\(applied.failedUnits)")
        try await env.pool.read { db in
            let notes = try Row.fetchAll(db, sql: """
                SELECT n.meaning_zh, e.japanese, e.translation_zh,
                       (SELECT COUNT(*) FROM cards c WHERE c.note_id = n.id) AS card_count
                FROM notes n JOIN examples e ON e.note_id = n.id
                WHERE n.headword = '多義' ORDER BY n.meaning_zh
                """)
            XCTAssertEqual(notes.count, 2)
            for (index, row) in notes.enumerated() {
                let meaning: String = row["meaning_zh"]
                let sentence: String = row["japanese"]
                let translation: String = row["translation_zh"]
                let cardCount: Int = row["card_count"]
                XCTAssertEqual(meaning, index == 0 ? "meaning A" : "meaning B")
                XCTAssertEqual(sentence, index == 0 ? "多義が好き。" : "多義も好き。")
                XCTAssertEqual(translation, "句译-\(sentence)")
                XCTAssertEqual(cardCount, 3)
            }
        }
        try await env.pool.read { db in
            let mapped = try Row.fetchAll(db, sql: """
                SELECT r.selected_sense_id, r.unit_id, o.unit_id AS occurrence_unit_id
                FROM ai_study_resolutions r JOIN reader_study_occurrences o ON o.resolution_id = r.id
                WHERE r.job_id = ? AND r.selected_entry_id = 500
                """, arguments: [DatabaseValueCodec.encode(job.id)])
            XCTAssertEqual(mapped.count, 3)
            var units: [Int64: String] = [:]
            for row in mapped {
                let sense: Int64 = row["selected_sense_id"]
                let unit: String? = row["unit_id"]
                let occurrenceUnit: String? = row["occurrence_unit_id"]
                XCTAssertNotNil(unit)
                XCTAssertEqual(unit, occurrenceUnit)
                if let previous = units[sense] { XCTAssertEqual(previous, unit) }
                units[sense] = unit
            }
            XCTAssertNotEqual(units[501], units[502])
        }
        // 同任务重放不复制任何 Note/Card。
        _ = try await applier.applyConfirmedJob(jobID: job.id)
        let noteCount = try await countRows("notes", in: env.pool)
        let cardCount = try await countRows("cards", in: env.pool)
        XCTAssertEqual(noteCount, 3)
        XCTAssertEqual(cardCount, 9)
    }

    /// 歧义未决仍走 pending——扩展不适用于未选定 entry 的记录。
    func testBuildPreviewUnresolvedStillPending() async throws {
        let env = try await makeEnvironment(
            chapterCount: 1,
            chapterABlockTexts: ["多義が好き。", "犬も好き。"])
        env.dictionary.stubbedEntries[500] = Self.makeEntry(
            id: 500, form: "多義", reading: "たぎ", senses: [
                (id: 501, gloss: "meaning A"),
                (id: 502, gloss: "meaning B"),
            ])
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)
        let service = env.service
        let runner = AIStudyRunner(
            store: env.store,
            planner: { job in
                try await service.plannedBlocks(for: job)
            },
            sendRequest: { request in
                // 全 unresolved——读音未定不得扩展。
                let base = Self.successResult(for: request)
                let block = request.blocks[0]
                return AIStudyResolverResult(
                    outcome: ValidatedBlockOutcome(
                        blockKey: block.blockKey,
                        lexicalStatus: .unresolved,
                        translationStatus: .notRequested,
                        translation: nil, envelopeRejection: nil,
                        resolutions: base.outcome.resolutions.map {
                            AIStudyResolution(
                                tokenKey: $0.tokenKey, selected: nil,
                                confidence: nil, status: .unresolved,
                                reasonCode: .noCandidate, origin: .ai)
                        },
                        targetTokenCount: block.tokens.count,
                        aiResolvedCount: 0, lowConfidenceCount: 0,
                        unresolvedTokenCount: block.tokens.count,
                        droppedUnknownTokenCount: 0,
                        duplicateTokenCount: 0, malformedItemCount: 0,
                        invalidItemCount: 0),
                    requestHash: base.requestHash,
                    requestID: base.requestID,
                    providerKind: base.providerKind,
                    model: base.model,
                    promptVersion: base.promptVersion,
                    responseMode: base.responseMode,
                    suggestedRetryAfter: nil,
                    responseBytes: base.responseBytes)
            })
        try await runner.start(jobID: job.id)
        await runner.waitUntilSettled(jobID: job.id)
        try await env.service.finalizeResults(jobID: job.id)

        let preview = try await env.service.buildPreview(jobID: job.id)
        XCTAssertTrue(preview.items.isEmpty,
                      "读音未定的记录不产生义项扩展")
        XCTAssertFalse(preview.pending.isEmpty)
    }

    /// C5：低置信行的 AI 选定透传进 pending item 的
    /// `aiSuggested`——预览层暴露「采纳 AI 建议」入口；
    /// unresolved（无选定）行的 `aiSuggested` 为 nil。
    func testLowConfidencePendingCarriesAISuggestion() async throws {
        try await verifyLowConfidenceSelection(changeSuggestedSense: false)
    }

    func testLowConfidenceUserCanChooseDifferentSense() async throws {
        try await verifyLowConfidenceSelection(changeSuggestedSense: true)
    }

    private func verifyLowConfidenceSelection(changeSuggestedSense: Bool) async throws {
        let env = try await makeEnvironment(
            chapterCount: 1,
            chapterABlockTexts: ["多義が好き。", "犬も好き。"])
        env.dictionary.stubbedEntries[500] = Self.makeEntry(
            id: 500, form: "多義", reading: "たぎ", senses: [
                (id: 501, gloss: "meaning A"),
                (id: 502, gloss: "meaning B"),
            ])
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)
        let service = env.service
        let runner = AIStudyRunner(
            store: env.store,
            planner: { job in
                try await service.plannedBlocks(for: job)
            },
            sendRequest: { request in
                let base = Self.successResult(for: request)
                let block = request.blocks[0]
                var lowCount = 0
                let resolutions = base.outcome.resolutions.map { res in
                    // 带选定的降格为 lowConfidence（<0.50 阈值），
                    // 无选定的保持 unresolved。
                    if res.selected != nil {
                        lowCount += 1
                        return AIStudyResolution(
                            tokenKey: res.tokenKey,
                            selected: res.selected,
                            confidence: 0.3,
                            status: .lowConfidence,
                            reasonCode: .belowConfidenceThreshold,
                            origin: .ai,
                            sentenceTranslation: res.sentenceTranslation)
                    }
                    return res
                }
                return AIStudyResolverResult(
                    outcome: ValidatedBlockOutcome(
                        blockKey: block.blockKey,
                        lexicalStatus: .partial,
                        translationStatus: .notRequested,
                        translation: nil, envelopeRejection: nil,
                        resolutions: resolutions,
                        targetTokenCount: block.tokens.count,
                        aiResolvedCount: 0,
                        lowConfidenceCount: lowCount,
                        unresolvedTokenCount:
                            block.tokens.count - lowCount,
                        droppedUnknownTokenCount: 0,
                        duplicateTokenCount: 0,
                        malformedItemCount: 0, invalidItemCount: 0),
                    requestHash: base.requestHash,
                    requestID: base.requestID,
                    providerKind: base.providerKind,
                    model: base.model,
                    promptVersion: base.promptVersion,
                    responseMode: base.responseMode,
                    suggestedRetryAfter: nil,
                    responseBytes: base.responseBytes)
            })
        try await runner.start(jobID: job.id)
        await runner.waitUntilSettled(jobID: job.id)
        try await env.service.finalizeResults(jobID: job.id)

        var preview = try await env.service.buildPreview(jobID: job.id)
        XCTAssertTrue(preview.items.isEmpty,
                      "全部低置信——无自动入选项")
        let suggested = preview.pending.filter { $0.aiSuggested != nil }
        XCTAssertFalse(suggested.isEmpty,
                       "低置信带选定的行必须暴露 AI 建议")
        for item in suggested {
            let candidate = try XCTUnwrap(item.aiSuggested)
            XCTAssertTrue(item.alternatives.contains {
                $0.entryID == candidate.entryID
                    && $0.senseID == candidate.senseID
            }, "aiSuggested 必须落在合法候选集内")
        }
        // unresolved（が/も 类无候选）行无建议可给。
        for item in preview.pending where item.aiSuggested == nil {
            XCTAssertEqual(item.status, .unresolved)
        }
        let progress = try await env.store.activeJobProgress()[documentID]
        XCTAssertEqual(progress?.confirmedUnits, 0)
        XCTAssertEqual(progress?.pendingUnits, preview.pending.count)
        // 模拟 UI 一键采纳，再走真实 Dictionary provider + SQLite 应用。
        for index in preview.pending.indices {
            guard let candidate = preview.pending[index].aiSuggested else { continue }
            preview.pending[index].correctedSelection = AIStudySelection(
                provider: "jmdict", entryID: candidate.entryID,
                senseID: changeSuggestedSense && candidate.entryID == 500 ? 502 : candidate.senseID,
                datasetVersion: "ds-test")
        }
        _ = try await env.service.recordSelections(
            jobID: job.id, preview: preview, items: preview.items,
            correctedPending: preview.pending)
        let selectionCount = try await countRows("ai_study_selections", in: env.pool)
        XCTAssertEqual(selectionCount, 3, "多義/好き/犬必须保存为三条选择")
        let applier = AIStudyApplyService(
            pool: env.pool,
            unitSources: DictionaryAIStudyUnitSourceProvider(repository: env.dictionary))
        let applied = try await applier.applyConfirmedJob(jobID: job.id)
        XCTAssertTrue(applied.failedUnits.isEmpty, "失败结果：\(applied.failedUnits)")
        let notes = try await countRows("notes", in: env.pool)
        XCTAssertEqual(notes, 3)
        let cards = try await countRows("cards", in: env.pool)
        XCTAssertEqual(cards, 3 * VocabularyCardDirection.allCases.count)
        let remaining = try await env.store.activeJobProgress()[documentID]
        XCTAssertNil(remaining, "全部应用后不再出现活跃分析行")
        let userResolutions = try await env.pool.read { db in
            try GRDBAIStudyJobStore.fetchResolutions(jobID: job.id, in: db).filter { $0.origin == .user }
        }
        XCTAssertTrue(userResolutions.allSatisfy {
            $0.jobBlockID != nil && $0.sentenceTranslation ==
                (changeSuggestedSense && $0.selectedEntryID == 500 ? nil : "测试句译")
        })
        let meaning = try await env.pool.read { db in
            try String.fetchOne(db, sql: "SELECT meaning_zh FROM notes WHERE headword = '多義'")
        }
        XCTAssertEqual(meaning, changeSuggestedSense ? "meaning B" : "meaning A")
        // 同词在两块出现也都挂到最终制卡的 unit，修正计数不会留旧 pending。
        let dangling = try await env.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reader_study_occurrences WHERE resolution_status = 'userConfirmed' AND unit_id IS NULL")
        }
        XCTAssertEqual(dangling, 0)


    }

    private func lowConfidenceFixture() async throws -> (Environment, AIStudyJob, AIStudyPreview) {
        let env = try await makeEnvironment(chapterCount: 1)
        let report = try await env.service.preflight(documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook), provider: provider(.ready))
        let job = try await env.service.prepare(documentID: documentID,
            report: report, configuration: report.provider.resolved!)
        let service = env.service
        let runner = AIStudyRunner(store: env.store,
            planner: { try await service.plannedBlocks(for: $0) },
            sendRequest: { Self.successResult(for: $0) })
        try await runner.start(jobID: job.id)
        await runner.waitUntilSettled(jobID: job.id)
        try await service.finalizeResults(jobID: job.id)
        try await env.pool.write { db in
            try db.execute(sql: "UPDATE ai_study_resolutions SET status = 'lowConfidence'")
        }
        return (env, job, try await service.buildPreview(jobID: job.id))
    }

    func testPendingProgressTracksLatestResolutionAndObservation() async throws {
        let (env, job, preview) = try await lowConfidenceFixture()
        let stream = env.store.observeActiveJobProgress()
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?[documentID]?.pendingUnits, preview.pending.count)
        let pending = try XCTUnwrap(preview.pending.first { $0.aiSuggested != nil })
        let previous = try await env.pool.read { db in
            try GRDBAIStudyJobStore.fetchResolutions(jobID: job.id, in: db).first { $0.id == pending.resolutionID }
        }
        let old = try XCTUnwrap(previous)
        let replacement = AIStudyResolutionRecord(id: UUID(), jobID: old.jobID,
            jobBlockID: old.jobBlockID, documentID: old.documentID,
            locatorJSON: old.locatorJSON, tokenKey: old.tokenKey,
            requestHash: old.requestHash, selectedEntryID: old.selectedEntryID,
            selectedSenseID: old.selectedSenseID,
            selectedDatasetVersion: old.selectedDatasetVersion,
            confidence: old.confidence, status: .userConfirmed, origin: .user,
            revision: old.revision + 1, createdAtMs: old.createdAtMs)
        // 不写 Job 行：观察必须跟踪 resolutions 表本身。
        try await env.pool.write { db in
            try GRDBAIStudyJobStore.insertResolution(replacement, documentID: job.documentID, in: db)
        }
        let update = try await iterator.next()
        XCTAssertEqual(update?[documentID]?.pendingUnits, preview.pending.count - 1)
        XCTAssertEqual(update?[documentID]?.confirmedUnits, 0)
    }

    func testConfirmationRejectsMissingManifestWithoutWrites() async throws {
        let (env, job, preview) = try await lowConfidenceFixture()
        try await env.pool.write { db in
            try db.execute(sql: "DELETE FROM ai_study_job_manifests")
        }
        do {
            _ = try await env.service.recordSelections(jobID: job.id, preview: preview,
                items: preview.items, correctedPending: preview.pending)
            XCTFail("缺少快照必须显式失败")
        } catch let error as AIStudyPreparationService.PreparationError {
            XCTAssertEqual(error, .manifestMissing(jobID: job.id))
        }
        let selections = try await countRows("ai_study_selections", in: env.pool)
        XCTAssertEqual(selections, 0)
        let notes = try await countRows("notes", in: env.pool)
        XCTAssertEqual(notes, 0)
    }

    func testCorrectionRejectsCandidateBorrowedFromAnotherToken() async throws {
        let (env, job, snapshot) = try await lowConfidenceFixture()
        var preview = snapshot
        let index = try XCTUnwrap(preview.pending.firstIndex { $0.aiSuggested?.entryID == 100 })
        preview.pending[index].correctedSelection = AIStudySelection(provider: "jmdict",
            entryID: 300, senseID: 301, datasetVersion: "ds-test")
        // 犬在 manifest 中存在，但不属于猫的候选集，不能借用。
        do {
            _ = try await env.service.recordSelections(jobID: job.id, preview: preview,
                items: preview.items, correctedPending: preview.pending)
            XCTFail("跨 token 候选必须拒绝")
        } catch let error as AIStudyPreparationService.PreparationError {
            XCTAssertEqual(error, .invalidCorrection(tokenKey: preview.pending[index].tokenKey))
        }
        let selections = try await countRows("ai_study_selections", in: env.pool)
        XCTAssertEqual(selections, 0)
    }

    /// 已取消 Job 拒绝确认（jobNotConfirmable）。
    func testRecordSelectionsRejectsCancelledJob() async throws {
        let env = try await makeEnvironment(chapterCount: 1)
        let report = try await env.service.preflight(
            documentID: documentID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: provider(.ready))
        let job = try await env.service.prepare(
            documentID: documentID, report: report,
            configuration: report.provider.resolved!)
        // 直接推进到 awaitingConfirmation 再取消（每步重读 epoch）。
        func transition(to status: AIStudyJobStatus) async throws {
            try await env.pool.write { db in
                let current = try GRDBAIStudyJobStore
                    .fetchJob(id: job.id, in: db)
                XCTAssertNotNil(current)
                try GRDBAIStudyJobStore.transitionJob(
                    id: job.id, to: status,
                    expectedEpoch: current?.epoch ?? -1,
                    atMs: 2, in: db)
            }
        }
        try await transition(to: .analyzing)
        try await transition(to: .waitingForAI)
        try await transition(to: .awaitingConfirmation)
        try await transition(to: .cancelled)
        let preview = try await env.service.buildPreview(
            jobID: job.id)
        await XCTAssertAsyncThrowsError(
            try await env.service.recordSelections(
                jobID: job.id, preview: preview,
                items: preview.items,
                correctedPending: preview.pending)
        ) { error in
            guard case AIStudyPreparationService.PreparationError
                .jobNotConfirmable = error else {
                return XCTFail("期望 jobNotConfirmable，得 \(error)")
            }
        }
    }

    /// manifest 表存在（v27 迁移登记）。
    func testManifestTableMigrated() async throws {
        let env = try await makeEnvironment()
        let exists = try await env.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table'
                      AND name = 'ai_study_job_manifests'
                    """)
        }
        XCTAssertEqual(exists, "ai_study_job_manifests")
    }

    // MARK: - 桩件

    /// 内存 Reader 源（fetch* 直给）。
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

    /// 确定性分词桩：按文本模板发词，候选挂 entryID。
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
                let segment = String(unit)
                var rest = segment[...]
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
                    } else if rest.hasPrefix("多義") {
                        push("多義", .lexical, entryID: 500)
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

    /// 词典桩：entries 命中 stubbedEntries。
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

    /// 假 resolver 结果：把请求内每块的首个带候选 token 解析到
    /// 其候选 (entryID, senseID)，其余 unresolved——成果与请求
    /// 自洽（tokenKey 取 `AIStudyToken.tokenID`）。
    private static func successResult(
        for request: AIStudyRequest, contextualSenses: Bool = false
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
                        senseID: contextualSenses && candidate.entryID == 500 && block.targetText.contains("も") ? 502 : sense.senseID,
                        datasetVersion: request.metadata
                            .dictionaryDatasetVersion),
                    confidence: 0.92,
                    status: .aiResolved,
                    reasonCode: nil, origin: .ai,
                    sentenceTranslation: contextualSenses ? "句译-\(block.targetText)" : "测试句译"))
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
}
