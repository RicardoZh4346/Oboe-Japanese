import Foundation
import GRDB
import XCTest
import OboeDomain
import OboeInfrastructure
@testable import Oboe

/// v0.7.5 S15 Reader 流程模型测试：预检加载（provider 三态）、
/// 接管 Job → 预览、策略/改判/选择落库、确认 → 摘要导航。
/// 用真实 GRDB 栈 + 内存 stub（reader/morphology/dictionary/
/// credential/config）——不触网络（resolver 永不派发）。
@MainActor
final class ReaderAIStudyFlowModelTests: XCTestCase {

    // MARK: - 环境

    private struct Environment {
        let pool: DatabasePool
        let store: GRDBAIStudyJobStore
        let preparation: AIStudyPreparationService
        let applier: AIStudyApplyService
        let dependencies: ReaderAIStudyDependencies
        let dictionary: StubDictionary
        let credentials: FakeCredentialStore
        let aiRepository: FakeAIConfigurationRepository
    }

    private let documentID = UUID()
    private let chapterID = UUID()
    private let blockID0 = UUID()
    private let blockID1 = UUID()

    /// 单文档单章两块「猫が好き。」「犬も好き。」。
    private func makeEnvironment(
        aiEnabled: Bool = true,
        modelID: String? = "model-1",
        hasKey: Bool = true
    ) async throws -> Environment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReaderAIStudy-\(UUID().uuidString)", isDirectory: true)
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
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers
        ).migrate(pool)

        let document = ReaderDocumentMetadata(
            id: documentID, title: "テスト読物", format: .paste,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, sourceFileName: nil,
            sourceSHA256: String(repeating: "0", count: 64),
            canonicalTextHash: "canon", parserVersion: "parser-1",
            contentRevision: 1, progressBasisPoints: 0,
            availability: .available)
        let chapter = ReaderChapterMetadata(
            id: chapterID, documentID: documentID, ordinal: 0,
            title: "第一章", sourceLocator: nil,
            canonicalHash: "ch", textUTF16Length: 10)
        let blocks = [
            ReaderBlock(
                id: blockID0, documentID: documentID,
                chapterID: chapterID, ordinal: 0,
                text: "猫が好き。", textHash: "bh-0", locatorJSON: nil),
            ReaderBlock(
                id: blockID1, documentID: documentID,
                chapterID: chapterID, ordinal: 1,
                text: "犬も好き。", textHash: "bh-1", locatorJSON: nil),
        ]
        let docID = documentID
        let seededChapterID = chapterID
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, content_revision, availability)
                    VALUES (?, 'テスト読物', 'paste', 1, ?, 'canon',
                            'parser-1', 1, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(docID),
                    String(repeating: "0", count: 64),
                ])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title,
                        canonical_hash, text_utf16_length)
                    VALUES (?, ?, 0, '第一章', 'ch', 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(seededChapterID),
                    DatabaseValueCodec.encode(docID),
                ])
            for block in blocks {
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal,
                            text, text_hash)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(block.id),
                        DatabaseValueCodec.encode(docID),
                        DatabaseValueCodec.encode(seededChapterID),
                        block.ordinal, block.text, block.textHash,
                    ])
            }
        }

        let dictionary = StubDictionary()
        dictionary.stubbedEntries[100] = Self.makeEntry(
            id: 100, form: "猫", reading: "ねこ", senseID: 101)
        dictionary.stubbedEntries[200] = Self.makeEntry(
            id: 200, form: "好き", reading: "すき", senseID: 201)
        dictionary.stubbedEntries[300] = Self.makeEntry(
            id: 300, form: "犬", reading: "いぬ", senseID: 301)

        let store = GRDBAIStudyJobStore(pool: pool)
        let preparation = AIStudyPreparationService(
            pool: pool,
            reader: StubReader(
                document: document, chapters: [chapter],
                blocks: [chapterID: blocks]),
            morphology: StubMorphology(),
            dictionary: dictionary,
            jobStore: store,
            jlptIndexProvider: {
                AIStudyJLPTReferenceIndex(rows: [
                    .init(headword: "猫", reading: "ねこ", level: .n5),
                ])
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let applier = AIStudyApplyService(
            pool: pool,
            unitSources: DictionaryAIStudyUnitSourceProvider(
                repository: dictionary))
        let credentials = FakeCredentialStore(
            value: hasKey ? "sk-test" : nil)
        let aiRepository = FakeAIConfigurationRepository(
            configuration: AIConfiguration(
                isEnabled: aiEnabled,
                serviceKind: .deepSeek,
                serviceName: "DeepSeek",
                baseURL: URL(string: "https://api.deepseek.com")!,
                modelID: modelID,
                responseFormatMode: .promptedJSON,
                credentialReference: AICredentialReference(
                    id: UUID(), serviceKind: .deepSeek,
                    host: "api.deepseek.com")))
        let dependencies = ReaderAIStudyDependencies(
            store: store,
            applier: applier,
            candidatePlanner: AIStudyCandidatePlanner(
                senseSource: DictionaryRepositorySenseSource(
                    repository: dictionary)),
            resolver: AIStudyResolverClient(),
            aiConfiguration: AIConfigurationService(
                repository: aiRepository, credentialStore: credentials),
            credentialStore: credentials,
            units: GRDBLearningUnitRepository(pool: pool),
            dictionary: dictionary,
            preparation: preparation,
            studyDestination: nil,
            deckDestination: nil)
        return Environment(
            pool: pool, store: store, preparation: preparation,
            applier: applier, dependencies: dependencies,
            dictionary: dictionary, credentials: credentials,
            aiRepository: aiRepository)
    }

    private static func makeEntry(
        id: Int64, form: String, reading: String, senseID: Int64
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
                    language: "eng", text: "gloss-\(id)", order: 1,
                    sourceID: "test", isMachineGenerated: false)])])
    }

    private func makeModel(
        _ env: Environment, chapterCount: Int = 1
    ) -> ReaderAIStudyFlowModel {
        ReaderAIStudyFlowModel(
            context: .init(
                documentID: documentID,
                documentTitle: "テスト読物",
                currentChapterID: chapterID,
                currentBlockID: blockID0,
                chapterCount: chapterCount),
            dependencies: env.dependencies)
    }

    /// 假 resolver 成果：每块带候选 token → aiResolved，其余
    /// unresolved（成果与请求自洽）。
    private static func result(
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
                    confidence: 0.92, status: .aiResolved,
                    reasonCode: nil, origin: .ai))
                resolvedCount += 1
            } else {
                resolutions.append(AIStudyResolution(
                    tokenKey: token.tokenID, selected: nil,
                    confidence: nil, status: .unresolved,
                    reasonCode: .noCandidate, origin: .ai))
            }
        }
        return AIStudyResolverResult(
            outcome: ValidatedBlockOutcome(
                blockKey: block.blockKey,
                lexicalStatus: .resolved,
                translationStatus: .done,
                translation: "译文", envelopeRejection: nil,
                resolutions: resolutions,
                targetTokenCount: block.tokens.count,
                aiResolvedCount: resolvedCount,
                lowConfidenceCount: 0,
                unresolvedTokenCount:
                    block.tokens.count - resolvedCount,
                droppedUnknownTokenCount: 0, duplicateTokenCount: 0,
                malformedItemCount: 0, invalidItemCount: 0),
            requestHash: request.requestHash,
            requestID: request.requestID,
            providerKind: "stub", model: "stub-model",
            promptVersion: request.metadata.promptVersion,
            responseMode: .promptedJSON,
            suggestedRetryAfter: nil, responseBytes: 64)
    }

    /// 准备 Job 并把所有计划块推进到 resolved，Job 落
    /// awaitingConfirmation（模拟 Runner 跑完，无网络）。
    private func makeAwaitingJob(
        _ env: Environment
    ) async throws -> AIStudyJob {
        let docID = documentID
        let report = try await env.preparation.preflight(
            documentID: docID,
            request: AIStudyScopeRequest(choice: .wholeBook),
            provider: AIStudyProviderReadiness(
                state: .ready, isEnabled: true,
                serviceName: "DeepSeek", serviceKind: .deepSeek,
                modelID: "model-1",
                resolved: ResolvedAIConfiguration(
                    isEnabled: true, serviceKind: .deepSeek,
                    serviceName: "DeepSeek",
                    baseURL: URL(
                        string: "https://api.deepseek.com")!,
                    modelID: "model-1",
                    responseFormatMode: .promptedJSON,
                    credentialReference: AICredentialReference(
                        id: UUID(), serviceKind: .deepSeek,
                        host: "api.deepseek.com"))))
        let job = try await env.preparation.prepare(
            documentID: docID, report: report,
            configuration: report.provider.resolved!)
        let planned = try await env.preparation.plannedBlocks(for: job)
        // 结果预建——`pool.write` 闭包非隔离同步，不能调 MainActor
        // 静态方法。
        let outcomes: [(blockID: UUID, result: AIStudyCachedResult)] =
            planned.map {
                ($0.block.id, AIStudyCachedResult(
                    result: Self.result(for: $0.request),
                    resultID: UUID(), atMs: 10))
            }
        try await env.pool.write { db in
            let current = try GRDBAIStudyJobStore.fetchJob(
                id: job.id, in: db)
            try GRDBAIStudyJobStore.insertBlocksIfAbsent(
                jobID: job.id,
                blocks: planned.map {
                    var block = $0.block
                    block.status = .readyForAI
                    return block
                },
                expectedEpoch: current?.epoch ?? 0, in: db)
            for outcome in outcomes {
                _ = try GRDBAIStudyJobStore.persistOutcome(
                    blockID: outcome.blockID,
                    expectedJobEpoch: current?.epoch ?? 0,
                    result: outcome.result,
                    cacheCapacity: 64, atMs: 10, in: db)
            }
            for status in [
                AIStudyJobStatus.analyzing,
                .waitingForAI, .awaitingConfirmation,
            ] {
                let jobNow = try GRDBAIStudyJobStore.fetchJob(
                    id: job.id, in: db)
                try GRDBAIStudyJobStore.transitionJob(
                    id: job.id, to: status,
                    expectedEpoch: jobNow?.epoch ?? 0,
                    atMs: 20, in: db)
            }
        }
        return try await env.store.fetchJob(id: job.id)!
    }

    private func countRows(_ table: String, in pool: DatabasePool)
        async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: - 测试

    /// 初始态：preflight 相位、自动应用默认关、单章默认当前章。
    func testInitialDefaults() async throws {
        let env = try await makeEnvironment()
        let model = makeModel(env)
        XCTAssertEqual(model.phase, .preflight)
        XCTAssertFalse(model.automaticApply)
        XCTAssertEqual(model.scopeChoice, .currentChapter)
        XCTAssertNil(model.currentJobID)
    }

    /// provider 就绪（enabled+model+key）→ preflight 可开始。
    func testPreflightReadyProvider() async throws {
        let env = try await makeEnvironment()
        let model = makeModel(env)
        await model.loadPreflight()
        XCTAssertEqual(model.report?.provider.state, .ready)
        XCTAssertTrue(model.report?.canStart == true)
        XCTAssertTrue(model.canStart)
    }

    /// provider disabled → canStart false；missingKey 仍可开始
    /// （派发期 paused 语义由 Runner 承担）。
    func testPreflightProviderStates() async throws {
        let disabled = try await makeEnvironment(aiEnabled: false)
        let disabledModel = makeModel(disabled)
        await disabledModel.loadPreflight()
        XCTAssertEqual(
            disabledModel.report?.provider.state, .disabled)
        XCTAssertFalse(disabledModel.canStart)

        let missingKey = try await makeEnvironment(hasKey: false)
        let keyModel = makeModel(missingKey)
        await keyModel.loadPreflight()
        XCTAssertEqual(
            keyModel.report?.provider.state, .missingKey)
        XCTAssertTrue(keyModel.canStart,
                      "missingKey 可开始——派发期落 paused(missingKey)")
    }

    /// 范围切换：wholeBook 覆盖 2 块。
    func testScopeWholeBookEstimate() async throws {
        let env = try await makeEnvironment()
        let model = makeModel(env, chapterCount: 2)
        model.scopeChoice = .wholeBook
        await model.loadPreflight()
        XCTAssertEqual(model.report?.estimate.blockCount, 2)
        XCTAssertEqual(model.report?.estimate.chapterCount, 1)
    }

    /// 无 Job 取消 → 直接 cancelled。
    func testCancelWithoutJob() async throws {
        let env = try await makeEnvironment()
        let model = makeModel(env)
        await model.cancel()
        XCTAssertEqual(model.phase, .cancelled)
    }

    /// 接管 awaitingConfirmation Job → 预览相位 + 推荐决策就位。
    func testAdoptAwaitingJobLoadsPreview() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        let model = makeModel(env)
        await model.adopt(job: job)
        XCTAssertEqual(model.phase, .preview)
        let preview = model.preview
        XCTAssertNotNil(preview)
        XCTAssertEqual(preview?.items.count, 3,
                       "猫/犬/好き unit 聚合")
        let counts = model.previewCounts
        XCTAssertGreaterThan(counts.created, 0)
        XCTAssertGreaterThan(counts.pending, 0,
                             "无候选 token 进待确认桶")
    }

    /// 单项决策 + 待确认改判：state 正确反射。
    func testSetDecisionAndCorrectPending() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        let model = makeModel(env)
        await model.adopt(job: job)
        guard let preview = model.preview,
              let first = preview.items.first else {
            return XCTFail("预览项缺失")
        }
        model.setDecision(for: first.id, decision: .skip)
        XCTAssertEqual(model.preview?.items
            .first(where: { $0.id == first.id })?.decision, .skip)

        guard let pending = model.preview?.pending.first else {
            return XCTFail("待确认项缺失")
        }
        let alternative = AIStudyPreviewPendingItem.Alternative(
            entryID: 300, senseID: 301, lemma: "犬",
            glossSummary: nil)
        model.correctPending(pending.id, to: alternative)
        let corrected = model.preview?.pending
            .first(where: { $0.id == pending.id })
        XCTAssertEqual(corrected?.correctedSelection?.entryID, 300)
        model.correctPending(pending.id, to: nil)
        XCTAssertNil(model.preview?.pending
            .first(where: { $0.id == pending.id })?
            .correctedSelection)
    }

    /// 真实建卡→删除→再分析：预览新增，但删除保护不能在摘要中消失。
    func testDeletedContentRebuildsByDefaultAfterConfirm() async throws {
        let env = try await makeEnvironment()
        let first = makeModel(env)
        await first.adopt(job: try await makeAwaitingJob(env))
        await first.confirm()
        XCTAssertEqual(first.summary?.createdNoteCount, 3)
        try await env.pool.write { db in
            try db.execute(sql: "DELETE FROM notes")
        }
        let diagnostics = try await env.preparation.applicationDiagnostics(jobID: try XCTUnwrap(first.currentJobID))
        XCTAssertTrue(diagnostics.contains("结果=createdNote"))
        XCTAssertTrue(diagnostics.contains("原提交卡数=3 当前卡数=0"), "删除后历史提交与当前卡数都可追溯")
        let second = makeModel(env)
        await second.adopt(job: try await makeAwaitingJob(env))
        XCTAssertEqual(second.deletedCreateCount, 3)
        XCTAssertTrue(second.canConfirm, "确认生成默认允许重新创建，无需开关")
        await second.confirm()
        XCTAssertEqual(second.summary?.createdNoteCount, 3)
        XCTAssertEqual(second.summary?.createdCardCount, 9)
        XCTAssertEqual(second.summary?.deletedContentCount, 0)
    }

    func testCreateDecisionRebuildsIfDeletedAfterPreview() async throws {
        let env = try await makeEnvironment()
        let first = makeModel(env)
        await first.adopt(job: try await makeAwaitingJob(env))
        await first.confirm()
        let second = makeModel(env)
        await second.adopt(job: try await makeAwaitingJob(env))
        for item in second.preview?.items ?? [] {
            second.setDecision(for: item.unitKey, decision: .create)
        }
        XCTAssertEqual(second.deletedCreateCount, 0, "预览时仍有链接")
        try await env.pool.write { db in try db.execute(sql: "DELETE FROM notes") }
        await second.confirm()
        XCTAssertEqual(second.summary?.createdNoteCount, 3)
        XCTAssertEqual(second.summary?.createdCardCount, 9)
    }

    func testDeletedContentIsCountedAndCanRetryFromSummary() async throws {
        let env = try await makeEnvironment()
        let first = makeModel(env)
        await first.adopt(job: try await makeAwaitingJob(env))
        await first.confirm()
        try await env.pool.write { db in try db.execute(sql: "DELETE FROM notes") }
        let job = try await makeAwaitingJob(env)
        let preview = try await env.preparation.buildPreview(jobID: job.id)
        var items = preview.items
        AIStudySelectionStrategy.all.apply(to: &items, studyDeckID: job.studyDeckID,
            directions: Set(VocabularyCardDirection.allCases))
        _ = try await env.preparation.recordSelections(jobID: job.id, preview: preview,
            items: items, correctedPending: preview.pending)
        let report = try await env.applier.applyConfirmedJob(jobID: job.id)
        let summary = try await env.preparation.summary(jobID: job.id, report: report,
            unselectedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.deletedContentCount, 3)
        XCTAssertEqual(summary.skippedCount, 3)
        XCTAssertEqual(summary.status, .partiallyCompleted)
        let retry = makeModel(env)
        let retryJob = try await env.store.fetchJob(id: job.id)
        await retry.adopt(job: try XCTUnwrap(retryJob))
        await retry.confirm()
        XCTAssertEqual(retry.summary?.createdCardCount, 9)
    }

    func testMissingNoteFailureIsNotDoubleCountedAsSkip() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        let report = AIStudyApplyReport(jobID: job.id, entryStatus: .applying,
            finalStatus: .partiallyCompleted, units: [
                .init(unitKey: "failed", kind: .failed, errorCode: "noteMissing"),
                .init(unitKey: "skip", kind: .skippedNoteMissing, errorCode: "noteMissing")
            ])
        let summary = try await env.preparation.summary(jobID: job.id, report: report,
            unselectedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.failedUnitCount, 1)
        XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(summary.alreadyAppliedCount, 0)
    }

    func testReceiptReplayIsVisibleAndDoesNotCountOldCardsAsNew() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        let model = makeModel(env)
        await model.adopt(job: job)
        await model.confirm()
        let replay = try await env.applier.applyConfirmedJob(jobID: job.id)
        let summary = try await env.preparation.summary(jobID: job.id, report: replay,
            unselectedCount: 0, pendingCount: 0)
        XCTAssertEqual(summary.createdNoteCount, 0)
        XCTAssertEqual(summary.createdCardCount, 0)
        XCTAssertEqual(summary.alreadyAppliedCount, 3)
    }

    /// 确认 → 选择 revision 落库 → 应用 → 摘要（含牌组导航锚）。
    func testConfirmAppliesAndSummarizes() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        let model = makeModel(env)
        await model.adopt(job: job)
        await model.confirm()
        XCTAssertEqual(model.phase, .summary)
        XCTAssertEqual(model.summary?.status, .completed)
        XCTAssertEqual(model.summary?.createdNoteCount, 3)
        XCTAssertNotNil(model.studyDeckID,
                        "摘要导航锚=文章牌组")
        let noteCount = try await countRows("notes", in: env.pool)
        XCTAssertEqual(noteCount, 3)
        let membershipCount = try await countRows(
            "note_decks", in: env.pool)
        XCTAssertEqual(membershipCount, 3)
        // 选择落库（当前 revision 行数 = 3 unit + pending 未选不算）。
        let selections = try await env.pool.read { db in
            try GRDBAIStudyJobStore.fetchSelections(
                jobID: job.id, in: db)
        }
        XCTAssertEqual(selections.count, 3)
    }

    func testAcceptingSuggestionsCreatesCardsInChosenDirection() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        try await env.pool.write { db in
            try db.execute(sql: "UPDATE ai_study_resolutions SET status = 'lowConfidence'")
        }
        let model = makeModel(env)
        await model.adopt(job: job)
        XCTAssertFalse(model.canConfirm)
        XCTAssertEqual(model.acceptAllAISuggestions(), 4)
        XCTAssertTrue(model.canConfirm)
        model.directionPreset = .japaneseToChinese
        await model.confirm()
        XCTAssertEqual(model.phase, .summary)
        XCTAssertEqual(model.summary?.createdNoteCount, 3)
        XCTAssertEqual(model.summary?.createdCardCount, 3)
        XCTAssertTrue(model.applyFailures.isEmpty)
    }

    /// Job epoch 在确认前漂移 → stalePreview → 回预览相位并提示。
    func testStalePreviewRejectedOnConfirm() async throws {
        let env = try await makeEnvironment()
        let job = try await makeAwaitingJob(env)
        let model = makeModel(env)
        await model.adopt(job: job)
        // 漂移 epoch：在库内推进到 partiallyCompleted（同 epoch
        // 语义，selection 锚仍当前 revision——改用直接 epoch bump）。
        try await env.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE ai_study_jobs SET epoch = epoch + 1
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(job.id)])
        }
        await model.confirm()
        XCTAssertEqual(model.phase, .preview)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - 桩件

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
                entryID: Int64? = nil
            ) {
                let length = surface.utf16.count
                tokens.append(ReaderToken(
                    surface: surface,
                    sourceRangeUTF16: offset..<(offset + length),
                    systemTokenIndexes:
                        systemIndex..<(systemIndex + 1),
                    candidates: entryID.map { id in
                        [MorphologyCandidate(
                            lemma: surface, normalizedForm: surface,
                            reading: nil, posCodes: ["n"],
                            entryID: id, reasons: [], cost: 0)]
                    } ?? [],
                    tokenClass: tokenClass, reading: nil,
                    lexicalKey: nil, resolutionStatus: .resolved,
                    provenance: ["stub"]))
                offset += length
                systemIndex += 1
            }
            var rest = Substring(text)
            while !rest.isEmpty {
                if rest.hasPrefix("猫") {
                    push("猫", .lexical, entryID: 100)
                    rest = rest.dropFirst(1)
                } else if rest.hasPrefix("犬") {
                    push("犬", .lexical, entryID: 300)
                    rest = rest.dropFirst(1)
                } else if rest.hasPrefix("好き") {
                    push("好き", .lexical, entryID: 200)
                    rest = rest.dropFirst(2)
                } else if rest.hasPrefix("。") {
                    push("。", .nonLexical)
                    rest = rest.dropFirst(1)
                } else if rest.hasPrefix("が") || rest.hasPrefix("も") {
                    push(String(rest.prefix(1)), .auxiliary)
                    rest = rest.dropFirst(1)
                } else {
                    push(String(rest.prefix(1)), .nonLexical)
                    rest = rest.dropFirst(1)
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

    private actor FakeAIConfigurationRepository:
        AIConfigurationRepository {
        var configuration: AIConfiguration

        init(configuration: AIConfiguration) {
            self.configuration = configuration
        }

        func loadOrCreateAIConfiguration(
            defaultTimeZoneID: String
        ) async throws -> AIConfiguration { configuration }

        func saveAIConfiguration(
            _ configuration: AIConfiguration
        ) async throws {}
    }

    private struct FakeCredentialStore: AICredentialStore {
        let value: String?

        func readCredential(
            for reference: AICredentialReference
        ) async throws -> String? { value }
        func saveCredential(
            _ credential: String,
            for reference: AICredentialReference
        ) async throws {}
        func deleteCredential(
            for reference: AICredentialReference
        ) async throws {}
    }
}
