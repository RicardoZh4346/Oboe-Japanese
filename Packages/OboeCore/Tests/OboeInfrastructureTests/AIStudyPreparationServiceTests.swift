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
                [blockA0, blockA1], chapterABlockTexts
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

    /// S22 义项扩展：选定 entry 的合法义项集整体成卡——entry 500
    /// 三义项 → 三条 unit item（决议只选了首义项），同块 好き
    /// 一条，共 4；聚合键去重，无重复 unit，零 pending。
    func testBuildPreviewExpandsAllAdmissibleSenses() async throws {
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
        let expanded = preview.items.filter { $0.entryID == 500 }
        XCTAssertEqual(expanded.count, 3,
                       "选定 entry 的全部合法义项应整体成卡")
        XCTAssertEqual(
            Set(expanded.map(\.senseID)), [501, 502, 503])
        XCTAssertEqual(Set(expanded.map(\.unitKey)).count, 3,
                       "unitKey 按义项指纹区分——不塌缩不重复")
        XCTAssertTrue(expanded.allSatisfy {
            $0.glossSummary != nil && $0.firstSentence != nil
        })
        // 同块其它解析照常；总条目 = 3 义项 + 好き + 犬 = 5。
        XCTAssertEqual(preview.items.count, 5)
        // pending 里是 が/も 类无候选 unresolved（原设计）；已选定
        // entry 的 token 绝不留在待确认队列。
        XCTAssertFalse(preview.pending.contains {
            $0.surface == "多義"
        })
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
}
