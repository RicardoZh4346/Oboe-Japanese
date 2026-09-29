import Foundation
import GRDB
@testable import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S17 译文编排器测试：章级水合（零网络、不匹配原文不落位）、
/// 主动翻译/重译（publish 才翻转 current）、请求复用缓存、
/// relink 重挂（缺原文恢复/序数漂移/同段重复文字）。
final class ReaderTranslationOrchestratorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translation-orchestrator-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 环境

    private struct Environment {
        let pool: DatabasePool
        let documentID: UUID
        let chapterID: UUID
        let blockIDs: [UUID]
    }

    private static let language = "zho"

    /// 一章三块（序数 0/1/2），文本各异；hash 参数可控。
    private func makeEnvironment(
        blockTexts: [String] = ["猫が好き。", "犬も好き。", "同じ文。"],
        blockHashes: [String]? = nil
    ) throws -> Environment {
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
            path: directory
                .appendingPathComponent("db-\(UUID().uuidString).sqlite")
                .path,
            configuration: configuration)
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers
        ).migrate(pool)

        let env = Environment(
            pool: pool, documentID: UUID(), chapterID: UUID(),
            blockIDs: blockTexts.map { _ in UUID() })
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version,
                        content_revision, availability)
                    VALUES (?, '翻译测试', 'paste', 1,
                            '0000000000000000000000000000000000000000000000000000000000000000',
                            'hash1', 'parser-1', 1, 'available')
                    """,
                arguments: [DatabaseValueCodec.encode(env.documentID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title, source_locator,
                        canonical_hash, text_utf16_length)
                    VALUES (?, ?, 0, '章节', NULL, 'ch-hash', 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(env.chapterID),
                    DatabaseValueCodec.encode(env.documentID),
                ])
            for (index, text) in blockTexts.enumerated() {
                let hash = blockHashes?[index] ?? "h-\(index)"
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal, text,
                            text_hash, locator_json)
                        VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(env.blockIDs[index]),
                        DatabaseValueCodec.encode(env.documentID),
                        DatabaseValueCodec.encode(env.chapterID),
                        index, text, hash,
                    ])
            }
        }
        return env
    }

    private func liveBlocks(
        _ env: Environment
    ) async throws -> [ReaderBlock] {
        try await env.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_blocks
                    WHERE document_id = ? ORDER BY ordinal
                    """,
                arguments: [DatabaseValueCodec.encode(env.documentID)]
            ).map { row in
                ReaderBlock(
                    id: try DatabaseValueCodec.decodeUUID(row["id"]),
                    documentID: env.documentID,
                    chapterID: env.chapterID,
                    ordinal: row["ordinal"],
                    text: row["text"],
                    textHash: row["text_hash"],
                    locatorJSON: row["locator_json"])
            }
        }
    }

    /// 测试 fake sender：脚本化结果/错误 + 派发计数（零网络断言）。
    private final class FakeSender: @unchecked Sendable {
        var calls: [AIStudyRequest] = []
        var results: [Result<AIStudyResolverResult, Error>] = []
        var defaultTranslation: String? = "译文"

        func send(
            _ request: AIStudyRequest,
            _ context: ReaderTranslationOrchestrator.RequestContext
        ) async throws -> AIStudyResolverResult {
            calls.append(request)
            if !results.isEmpty {
                switch results.removeFirst() {
                case let .success(result): return result
                case let .failure(error): throw error
                }
            }
            let block = request.blocks[0]
            return AIStudyResolverResult(
                outcome: ValidatedBlockOutcome(
                    blockKey: block.blockKey,
                    lexicalStatus: .resolved,
                    translationStatus: .done,
                    translation: defaultTranslation.map {
                        "\($0)-\(block.blockKey)"
                    },
                    envelopeRejection: nil,
                    resolutions: [],
                    targetTokenCount: 0,
                    aiResolvedCount: 0, lowConfidenceCount: 0,
                    unresolvedTokenCount: 0,
                    droppedUnknownTokenCount: 0,
                    duplicateTokenCount: 0,
                    malformedItemCount: 0, invalidItemCount: 0),
                requestHash: request.requestHash,
                requestID: request.requestID,
                providerKind: "fake-provider",
                model: request.metadata.model,
                promptVersion: request.metadata.promptVersion,
                responseMode: .promptedJSON,
                suggestedRetryAfter: nil, responseBytes: 128)
        }
    }

    private func makeContext(
        model: String = "m-1",
        provider: AIServiceKind = .deepSeek
    ) -> ReaderTranslationOrchestrator.RequestContext {
        ReaderTranslationOrchestrator.RequestContext(
            resolved: ResolvedAIConfiguration(
                isEnabled: true,
                serviceKind: provider,
                serviceName: "Test",
                baseURL: URL(string: "https://api.example.com")!,
                modelID: model,
                responseFormatMode: .promptedJSON,
                credentialReference: AICredentialReference(
                    id: UUID(), serviceKind: provider,
                    host: "api.example.com")),
            credential: "sk-test",
            dictionaryDatasetVersion: "dict-v1",
            morphologyVersion: "morph-v1",
            osBuild: "os-1")
    }

    private func makeOrchestrator(
        env: Environment,
        context: ReaderTranslationOrchestrator.RequestContext? = nil,
        sender: @escaping ReaderTranslationOrchestrator.Sender
    ) -> ReaderTranslationOrchestrator {
        let ctx = context ?? makeContext()
        return ReaderTranslationOrchestrator(
            pool: env.pool,
            contextProvider: { ctx },
            sender: sender)
    }

    private func document(
        _ env: Environment, contentRevision: Int = 1
    ) -> ReaderDocumentMetadata {
        ReaderDocumentMetadata(
            id: env.documentID, title: "翻译测试", format: .paste,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, sourceFileName: nil,
            sourceSHA256: String(repeating: "0", count: 64),
            canonicalTextHash: "hash1", parserVersion: "parser-1",
            contentRevision: contentRevision,
            progressBasisPoints: 0, availability: .available)
    }

    // MARK: - 水合（零网络 / 不落位）

    /// 打开 Reader 的水合路径永不派发网络请求——sender 被调用
    /// 即失败。
    func testHydrateNeverDispatches() async throws {
        let env = try makeEnvironment()
        let orchestrator = makeOrchestrator(env: env) { _, _ in
            XCTFail("水合不得触发网络请求")
            throw AIStudyResolverError.cancelled
        }
        let blocks = try await liveBlocks(env)
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        XCTAssertTrue(hydrated.isEmpty)
    }

    /// 内容改动（活动块 hash ≠ 行 source_hash）→ 译文不落位。
    func testHydrateExcludesRowsOnEditedSource() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        try await env.pool.write { db in
            // 块 0：行 hash 与活块一致 → 可渲染；块 1：行 hash
            // 是改动前的 → 不落位。
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 0,
                    blockUTF16Length: blocks[0].text.utf16.count),
                locatorJSON: ReaderTranslationLocator.locatorJSON(
                    sourceText: blocks[0].text,
                    blockTextHash: blocks[0].textHash,
                    chapterOrdinal: 0, blockOrdinal: 0,
                    targetRange: 0..<blocks[0].text.utf16.count),
                sourceHash: blocks[0].textHash,
                language: Self.language, translatedText: "活译文",
                in: db)
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 1,
                    blockUTF16Length: blocks[1].text.utf16.count),
                locatorJSON: ReaderTranslationLocator.locatorJSON(
                    sourceText: blocks[1].text,
                    blockTextHash: "stale-hash",
                    chapterOrdinal: 0, blockOrdinal: 1,
                    targetRange: 0..<blocks[1].text.utf16.count),
                sourceHash: "stale-hash",
                language: Self.language, translatedText: "旧源译文",
                in: db)
        }
        let orchestrator = makeOrchestrator(env: env) { _, _ in
            XCTFail("水合不得派发")
            throw AIStudyResolverError.cancelled
        }
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(text, _) = hydrated[env.blockIDs[0]]
        else {
            return XCTFail("块 0 应得完整译文，得 \(String(describing: hydrated[env.blockIDs[0]]))")
        }
        XCTAssertEqual(text, "活译文")
        XCTAssertNil(
            hydrated[env.blockIDs[1]],
            "改动后的块不得渲染旧译文")
    }

    /// 同段重复文字：两块文本/哈希全同——各自的译文行按锚点
    /// 序数落到各自块下，不串。
    func testDuplicateSourceTextAnchorsIndependently() async throws {
        let env = try makeEnvironment(
            blockTexts: ["同じ文。", "別の文。", "同じ文。"],
            blockHashes: ["same-h", "other-h", "same-h"])
        let blocks = try await liveBlocks(env)
        try await env.pool.write { db in
            for (ordinal, text) in ["译文-块0", "译文-块2"].enumerated() {
                let blockOrdinal = ordinal == 0 ? 0 : 2
                let block = blocks[blockOrdinal]
                try GRDBReaderTranslationStore.publish(
                    documentID: env.documentID,
                    locatorKey: ReaderTranslationLocator.wholeBlockKey(
                        chapterOrdinal: 0, blockOrdinal: blockOrdinal,
                        blockUTF16Length: block.text.utf16.count),
                    locatorJSON: ReaderTranslationLocator.locatorJSON(
                        sourceText: block.text,
                        blockTextHash: block.textHash,
                        chapterOrdinal: 0, blockOrdinal: blockOrdinal,
                        targetRange: 0..<block.text.utf16.count),
                    sourceHash: block.textHash,
                    language: Self.language, translatedText: text,
                    in: db)
            }
        }
        let orchestrator = makeOrchestrator(env: env) { _, _ in
            XCTFail("水合不得派发")
            throw AIStudyResolverError.cancelled
        }
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(t0, _) = hydrated[env.blockIDs[0]],
              case let .complete(t2, _) = hydrated[env.blockIDs[2]]
        else { return XCTFail("两个重复块应各自落位") }
        XCTAssertEqual(t0, "译文-块0")
        XCTAssertEqual(t2, "译文-块2")
    }

    /// 多 subblock 译文按目标区间排序拼接；缺段 → partial 占位。
    func testSubblockSegmentsAssembleInOrderWithGap() async throws {
        let env = try makeEnvironment(blockTexts: ["甲乙丙丁戊己"])
        let blocks = try await liveBlocks(env)
        let block = blocks[0]
        try await env.pool.write { db in
            // 三段：#r0-2、#r4-6（缺 #r2-4）→ partial；再补 #r2-4 → complete。
            for (range, text) in [
                (0..<2, "一"), (4..<6, "三"),
            ] {
                try GRDBReaderTranslationStore.publish(
                    documentID: env.documentID,
                    locatorKey: ReaderTranslationLocator.key(
                        chapterOrdinal: 0, blockOrdinal: 0,
                        utf16Range: range),
                    locatorJSON: ReaderTranslationLocator.locatorJSON(
                        sourceText: block.text,
                        blockTextHash: block.textHash,
                        chapterOrdinal: 0, blockOrdinal: 0,
                        targetRange: range),
                    sourceHash: block.textHash,
                    language: Self.language, translatedText: text,
                    in: db)
            }
        }
        let orchestrator = makeOrchestrator(env: env) { _, _ in
            XCTFail("水合不得派发")
            throw AIStudyResolverError.cancelled
        }
        var hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .partial(segments, missing) =
                hydrated[env.blockIDs[0]]
        else { return XCTFail("缺段应为 partial") }
        XCTAssertEqual(segments.map(\.range), [0..<2, 4..<6])
        XCTAssertEqual(missing, [2..<4])

        try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: ReaderTranslationLocator.key(
                    chapterOrdinal: 0, blockOrdinal: 0,
                    utf16Range: 2..<4),
                locatorJSON: ReaderTranslationLocator.locatorJSON(
                    sourceText: block.text,
                    blockTextHash: block.textHash,
                    chapterOrdinal: 0, blockOrdinal: 0,
                    targetRange: 2..<4),
                sourceHash: block.textHash,
                language: Self.language, translatedText: "二",
                in: db)
        }
        hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(joined, _) = hydrated[env.blockIDs[0]]
        else { return XCTFail("齐全后应拼成 complete") }
        XCTAssertEqual(joined, "一二三")
    }

    // MARK: - 主动翻译 / 重译

    /// translate：整块一个请求（tokens=[] 纯翻译）、成功 publish、
    /// 行带 provenance；水合可渲染。
    func testTranslatePublishesWithProvenance() async throws {
        let env = try makeEnvironment()
        let sender = FakeSender()
        let orchestrator = makeOrchestrator(
            env: env, context: makeContext(model: "m-9"),
            sender: { request, ctx in try await sender.send(request, ctx) })
        let blocks = try await liveBlocks(env)
        let outcomes = await orchestrator.translate(
            document: document(env),
            targets: [
                .init(block: blocks[0], chapterOrdinal: 0,
                      context: ""),
                .init(block: blocks[1], chapterOrdinal: 0,
                      context: String(blocks[0].text.suffix(400))),
            ],
            language: Self.language,
            onlyMissing: false)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.errorCode == nil })
        XCTAssertEqual(sender.calls.count, 2)
        // 纯翻译契约：tokens 空、wantsTranslation 开。
        XCTAssertTrue(sender.calls.allSatisfy {
            $0.blocks[0].tokens.isEmpty && $0.blocks[0].wantsTranslation
        })
        // locator_key 规范形态 + requestHash 确定性。
        XCTAssertEqual(
            sender.calls[0].blocks[0].blockKey,
            ReaderTranslationLocator.wholeBlockKey(
                chapterOrdinal: 0, blockOrdinal: 0,
                blockUTF16Length: blocks[0].text.utf16.count))
        XCTAssertEqual(
            sender.calls[0].requestHash,
            AIStudyRequestSerializer.requestHash(sender.calls[0]))

        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(text, provenance) =
                hydrated[env.blockIDs[0]]
        else { return XCTFail("应得完整译文") }
        XCTAssertTrue(text.hasPrefix("译文-"))
        XCTAssertEqual(provenance.provider, "fake-provider")
        XCTAssertEqual(provenance.model, "m-9")
        XCTAssertEqual(provenance.promptVersion, AIStudyPrompt.promptVersion)
    }

    /// 部分失败：sender 第二块抛错 → 该块 failedRanges 占位、
    /// 成功块不受影响；无行写入失败块。
    func testTranslatePartialFailureLeavesPlaceholder() async throws {
        let env = try makeEnvironment()
        let sender = FakeSender()
        let orchestrator = makeOrchestrator(env: env) { request, ctx in
            if request.blocks[0].blockKey.contains(":b:1#") {
                throw AIStudyResolverError.retryable(.connectionFailed)
            }
            return try await sender.send(request, ctx)
        }
        let blocks = try await liveBlocks(env)
        let outcomes = await orchestrator.translate(
            document: document(env),
            targets: [
                .init(block: blocks[0], chapterOrdinal: 0),
                .init(block: blocks[1], chapterOrdinal: 0),
            ],
            language: Self.language,
            onlyMissing: false)
        let byID = Dictionary(
            uniqueKeysWithValues: outcomes.map { ($0.blockID, $0) })
        XCTAssertNil(byID[env.blockIDs[0]]?.errorCode)
        XCTAssertEqual(
            byID[env.blockIDs[1]]?.errorCode,
            ReaderTranslationOrchestrator.FailureCode.retryable)
        XCTAssertEqual(
            byID[env.blockIDs[1]]?.failedRanges,
            [0..<blocks[1].text.utf16.count])
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        XCTAssertNotNil(hydrated[env.blockIDs[0]])
        XCTAssertNil(hydrated[env.blockIDs[1]])
    }

    /// 旧译文直到新结果成功后才替换：重译失败 → 旧 current 原样。
    func testRetranslateKeepsOldCurrentOnFailure() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        let sender = FakeSender()
        let orchestrator = makeOrchestrator(env: env) { request, ctx in
            try await sender.send(request, ctx)
        }
        sender.defaultTranslation = "旧译文"
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)

        // 重译失败：authFailed/网络错都不翻转旧译文。
        sender.results = [
            .failure(AIStudyResolverError.retryable(.connectionFailed)),
        ]
        let outcome = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        XCTAssertEqual(
            outcome.errorCode,
            ReaderTranslationOrchestrator.FailureCode.retryable)
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(text, _) = hydrated[env.blockIDs[0]]
        else { return XCTFail("旧译文应仍在") }
        XCTAssertTrue(text.hasPrefix("旧译文"), "旧译文在新结果成功前不丢")

        // 成功后翻转（revision+1、历史留旧）。
        sender.defaultTranslation = "新译文"
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        let hydrated2 = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(text2, _) = hydrated2[env.blockIDs[0]]
        else { return XCTFail("新译文应落位") }
        XCTAssertTrue(text2.hasPrefix("新译文"))
        let history = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchHistory(
                documentID: env.documentID,
                locatorKey: ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 0,
                    blockUTF16Length: blocks[0].text.utf16.count),
                language: Self.language, in: db)
        }
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.map(\.translationRevision), [2, 1])
    }

    /// onlyMissing：已有完整覆盖的块不重发（零请求跳过）。
    func testTranslateOnlyMissingSkipsCoveredBlocks() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        let sender = FakeSender()
        let orchestrator = makeOrchestrator(env: env) { request, ctx in
            try await sender.send(request, ctx)
        }
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        XCTAssertEqual(sender.calls.count, 1)

        let outcomes = await orchestrator.translate(
            document: document(env),
            targets: [
                .init(block: blocks[0], chapterOrdinal: 0),
                .init(block: blocks[1], chapterOrdinal: 0),
            ],
            language: Self.language,
            onlyMissing: true)
        let byID = Dictionary(
            uniqueKeysWithValues: outcomes.map { ($0.blockID, $0) })
        XCTAssertEqual(byID[env.blockIDs[0]]?.skipped, true)
        XCTAssertEqual(byID[env.blockIDs[1]]?.skipped, false)
        XCTAssertEqual(sender.calls.count, 2, "只补发缺口块")
    }

    /// 配置变更不静默覆盖：换 model → 新 requestHash/新修订；
    /// 旧行保留在修订史（provenance 不改写）。
    func testModelChangeCreatesNewRevisionNotOverwrite() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        let sender = FakeSender()
        let orchestrator = makeOrchestrator(env: env) { request, ctx in
            try await sender.send(request, ctx)
        }
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        let firstHash = sender.calls.last?.requestHash

        let orchestrator2 = makeOrchestrator(
            env: env, context: makeContext(model: "m-2"),
            sender: { request, ctx in try await sender.send(request, ctx) })
        _ = await orchestrator2.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        let secondHash = sender.calls.last?.requestHash
        XCTAssertNotEqual(firstHash, secondHash)
        XCTAssertEqual(sender.calls.last?.metadata.model, "m-2")

        let history = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchHistory(
                documentID: env.documentID,
                locatorKey: ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 0,
                    blockUTF16Length: blocks[0].text.utf16.count),
                language: Self.language, in: db)
        }
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].model, "m-2")
        XCTAssertEqual(history[1].model, "m-1", "旧行 provenance 不改写")
    }

    /// 请求复用：ai_study_cache 命中 → 零网络 publish。
    func testCacheHitPublishesWithoutDispatch() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        let sender = FakeSender()
        let orchestrator = makeOrchestrator(env: env) { request, ctx in
            try await sender.send(request, ctx)
        }
        // 第一次实发 → 落库 + 手工补 cache（runner 正常会写）。
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        XCTAssertEqual(sender.calls.count, 1)
        let request = sender.calls[0]
        let cached = AIStudyCachedResult(
            result: AIStudyResolverResult(
                outcome: ValidatedBlockOutcome(
                    blockKey: request.blocks[0].blockKey,
                    lexicalStatus: .resolved,
                    translationStatus: .done,
                    translation: "缓存译文",
                    envelopeRejection: nil, resolutions: [],
                    targetTokenCount: 0, aiResolvedCount: 0,
                    lowConfidenceCount: 0, unresolvedTokenCount: 0,
                    droppedUnknownTokenCount: 0,
                    duplicateTokenCount: 0, malformedItemCount: 0,
                    invalidItemCount: 0),
                requestHash: request.requestHash,
                requestID: request.requestID,
                providerKind: "fake-provider", model: "m-1",
                promptVersion: request.metadata.promptVersion,
                responseMode: .promptedJSON,
                suggestedRetryAfter: nil, responseBytes: 64),
            resultID: UUID(), atMs: 1)
        try await GRDBAIStudyJobStore(pool: env.pool)
            .storeCachedResult(cached, capacity: 8)

        // 不同块同一 requestHash 不会命中——同块同行才同 hash；
        // 用 force（onlyMissing=false）路径验证 cache 命中零网络。
        sender.calls.removeAll()
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[0], chapterOrdinal: 0),
            language: Self.language)
        XCTAssertEqual(sender.calls.count, 0, "缓存命中零网络")
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(text, _) = hydrated[env.blockIDs[0]]
        else { return XCTFail("缓存译文应落位") }
        XCTAssertEqual(text, "缓存译文")
    }

    /// authFailed 停派：第一块 401 → 本批后续不再发。
    func testAuthFailureHaltsBatch() async throws {
        let env = try makeEnvironment()
        let orchestrator = makeOrchestrator(
            env: env,
            sender: { request, _ in
                if request.blocks[0].blockKey.contains(":b:0#") {
                    throw AIStudyResolverError.authFailed
                }
                let block = request.blocks[0]
                return AIStudyResolverResult(
                    outcome: ValidatedBlockOutcome(
                        blockKey: block.blockKey,
                        lexicalStatus: .resolved,
                        translationStatus: .done,
                        translation: "译文", envelopeRejection: nil,
                        resolutions: [], targetTokenCount: 0,
                        aiResolvedCount: 0, lowConfidenceCount: 0,
                        unresolvedTokenCount: 0,
                        droppedUnknownTokenCount: 0,
                        duplicateTokenCount: 0,
                        malformedItemCount: 0, invalidItemCount: 0),
                    requestHash: request.requestHash,
                    requestID: request.requestID,
                    providerKind: "p", model: "m",
                    promptVersion: "p", responseMode: .promptedJSON,
                    suggestedRetryAfter: nil, responseBytes: 1)
            })
        let blocks = try await liveBlocks(env)
        let outcomes = await orchestrator.translate(
            document: document(env),
            targets: blocks.map {
                .init(block: $0, chapterOrdinal: 0)
            },
            language: Self.language,
            onlyMissing: false)
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.contains {
            $0.errorCode
                == ReaderTranslationOrchestrator.FailureCode.authFailed
        })
        // 停派后批次标记 cancelled，不产生新成功行。
        XCTAssertTrue(outcomes.contains {
            $0.errorCode
                == ReaderTranslationOrchestrator.FailureCode.cancelled
        })
    }

    // MARK: - relink 重挂

    /// 缺原文恢复：块行全删后按同序数/hash 重建（新块 ID）——
    /// moves 空（锚点未漂），译文照常渲染。
    func testReanchorAfterMissingSourceRestore() async throws {
        let env = try makeEnvironment()
        var blocks = try await liveBlocks(env)
        let orchestrator = makeOrchestrator(env: env) { request, ctx in
            AIStudyResolverResult(
                outcome: ValidatedBlockOutcome(
                    blockKey: request.blocks[0].blockKey,
                    lexicalStatus: .resolved,
                    translationStatus: .done,
                    translation: "译文", envelopeRejection: nil,
                    resolutions: [], targetTokenCount: 0,
                    aiResolvedCount: 0, lowConfidenceCount: 0,
                    unresolvedTokenCount: 0,
                    droppedUnknownTokenCount: 0,
                    duplicateTokenCount: 0, malformedItemCount: 0,
                    invalidItemCount: 0),
                requestHash: request.requestHash,
                requestID: request.requestID,
                providerKind: "p", model: "m", promptVersion: "p",
                responseMode: .promptedJSON,
                suggestedRetryAfter: nil, responseBytes: 1)
        }
        _ = await orchestrator.retranslate(
            document: document(env),
            target: .init(block: blocks[1], chapterOrdinal: 0),
            language: Self.language)

        // 模拟 v8 恢复态 relink：块行全删 → 同内容重插（新 ID）。
        let oldBlocks = blocks
        blocks = try await env.pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_blocks WHERE document_id = ?",
                arguments: [DatabaseValueCodec.encode(env.documentID)])
            let chapter = ReaderChapterMetadata(
                id: env.chapterID, documentID: env.documentID,
                ordinal: 0, title: "章节", sourceLocator: nil,
                canonicalHash: "ch-hash", textUTF16Length: 10)
            var newBlocks: [ReaderBlock] = []
            for old in oldBlocks {
                newBlocks.append(ReaderBlock(
                    id: UUID(), documentID: env.documentID,
                    chapterID: env.chapterID, ordinal: old.ordinal,
                    text: old.text, textHash: old.textHash,
                    locatorJSON: nil))
            }
            let moves = try ReaderTranslationReanchor.moves(
                documentID: env.documentID,
                chapters: [chapter], blocks: newBlocks, in: db)
            try GRDBReaderTranslationStore.updateLocators(
                documentID: env.documentID, moves: moves, in: db)
            return newBlocks
        }
        // 序数未漂 → 无迁移必要；译文在新块行下照常渲染。
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: blocks)
        guard case let .complete(text, _) = hydrated[blocks[1].id]
        else { return XCTFail("恢复后译文应重锚落位") }
        XCTAssertEqual(text, "译文")
    }

    /// 序数漂移 + 同 hash：行锚到旧序数 → 重挂到新序数。
    func testReanchorMovesRowsOnOrdinalShift() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        // 行锚到 (ch0, b1) hash h-1。
        let locatorJSON = try ReaderTranslationLocator.locatorJSON(
            sourceText: blocks[1].text,
            blockTextHash: blocks[1].textHash,
            chapterOrdinal: 0, blockOrdinal: 1,
            targetRange: 0..<blocks[1].text.utf16.count)
        try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 1,
                    blockUTF16Length: blocks[1].text.utf16.count),
                locatorJSON: locatorJSON,
                sourceHash: blocks[1].textHash,
                language: Self.language, translatedText: "漂移译文",
                in: db)
        }
        // relink 后同文本块出现在序数 2（序数 1 换成别的文本）。
        let chapter = ReaderChapterMetadata(
            id: env.chapterID, documentID: env.documentID,
            ordinal: 0, title: "章节", sourceLocator: nil,
            canonicalHash: "ch-hash", textUTF16Length: 10)
        let newBlocks = [
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 0,
                text: blocks[0].text, textHash: blocks[0].textHash,
                locatorJSON: nil),
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 1,
                text: "新插入段落。", textHash: "h-new",
                locatorJSON: nil),
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 2,
                text: blocks[1].text, textHash: blocks[1].textHash,
                locatorJSON: nil),
        ]
        try await env.pool.write { db in
            let moves = try ReaderTranslationReanchor.moves(
                documentID: env.documentID,
                chapters: [chapter], blocks: newBlocks, in: db)
            XCTAssertEqual(moves.count, 1)
            XCTAssertEqual(
                moves[0].newLocatorKey,
                ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 2,
                    blockUTF16Length: blocks[1].text.utf16.count))
            try GRDBReaderTranslationStore.updateLocators(
                documentID: env.documentID, moves: moves, in: db)
        }
        let orchestrator = makeOrchestrator(env: env) { _, _ in
            XCTFail("不得派发")
            throw AIStudyResolverError.cancelled
        }
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: newBlocks)
        guard case let .complete(text, _) = hydrated[newBlocks[2].id]
        else { return XCTFail("译文应重挂到序数 2 的块") }
        XCTAssertEqual(text, "漂移译文")
    }

    /// 同段重复文字 + 序数漂移：两条同 hash 译文按相对顺序
    /// 各自重挂，不合并不串位。
    func testReanchorPreservesDuplicateOrder() async throws {
        let env = try makeEnvironment(
            blockTexts: ["同じ文。", "別の文。", "同じ文。"],
            blockHashes: ["dup-h", "other-h", "dup-h"])
        let blocks = try await liveBlocks(env)
        try await env.pool.write { db in
            for (blockOrdinal, text) in [(0, "译文A"), (2, "译文B")] {
                let block = blocks[blockOrdinal]
                try GRDBReaderTranslationStore.publish(
                    documentID: env.documentID,
                    locatorKey: ReaderTranslationLocator.wholeBlockKey(
                        chapterOrdinal: 0, blockOrdinal: blockOrdinal,
                        blockUTF16Length: block.text.utf16.count),
                    locatorJSON: ReaderTranslationLocator.locatorJSON(
                        sourceText: block.text,
                        blockTextHash: block.textHash,
                        chapterOrdinal: 0, blockOrdinal: blockOrdinal,
                        targetRange: 0..<block.text.utf16.count),
                    sourceHash: block.textHash,
                    language: Self.language, translatedText: text,
                    in: db)
            }
        }
        // 新块集：dup 文本出现在序数 1 与 3（序数 0/2 换成新文）。
        let chapter = ReaderChapterMetadata(
            id: env.chapterID, documentID: env.documentID,
            ordinal: 0, title: "章节", sourceLocator: nil,
            canonicalHash: "ch-hash", textUTF16Length: 10)
        let newBlocks = [
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 0,
                text: "新文零。", textHash: "h-n0", locatorJSON: nil),
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 1,
                text: "同じ文。", textHash: "dup-h", locatorJSON: nil),
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 2,
                text: "新文二。", textHash: "h-n2", locatorJSON: nil),
            ReaderBlock(
                id: UUID(), documentID: env.documentID,
                chapterID: env.chapterID, ordinal: 3,
                text: "同じ文。", textHash: "dup-h", locatorJSON: nil),
        ]
        try await env.pool.write { db in
            let moves = try ReaderTranslationReanchor.moves(
                documentID: env.documentID,
                chapters: [chapter], blocks: newBlocks, in: db)
            try GRDBReaderTranslationStore.updateLocators(
                documentID: env.documentID, moves: moves, in: db)
        }
        let orchestrator = makeOrchestrator(env: env) { _, _ in
            XCTFail("不得派发")
            throw AIStudyResolverError.cancelled
        }
        let hydrated = try await orchestrator.hydrate(
            documentID: env.documentID, language: Self.language,
            chapterOrdinal: 0, blocks: newBlocks)
        // 相对顺序保持：旧 (b0) → 新序数最小候选 (b1)，旧 (b2) → (b3)。
        guard case let .complete(t1, _) = hydrated[newBlocks[1].id],
              case let .complete(t3, _) = hydrated[newBlocks[3].id]
        else {
            return XCTFail(
                "两条重复译文应各归各位：\(hydrated)")
        }
        XCTAssertEqual(t1, "译文A")
        XCTAssertEqual(t3, "译文B")
    }

    /// 旧 `doc:` 形态 key 在 relink 时迁移到 `tr:` 规范（序数未变
    /// 也要规范化 key——后续 publish 链归一）。
    func testReanchorNormalizesLegacyKeys() async throws {
        let env = try makeEnvironment()
        let blocks = try await liveBlocks(env)
        let legacyKey =
            "doc:\(env.documentID.uuidString.lowercased())"
            + ":rev:1:ch:0:b:1#r0-\(blocks[1].text.utf16.count)"
        try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.documentID,
                locatorKey: legacyKey,
                locatorJSON: ReaderTranslationLocator.locatorJSON(
                    sourceText: blocks[1].text,
                    blockTextHash: blocks[1].textHash,
                    chapterOrdinal: 0, blockOrdinal: 1,
                    targetRange: 0..<blocks[1].text.utf16.count),
                sourceHash: blocks[1].textHash,
                language: Self.language, translatedText: "旧键译文",
                in: db)
        }
        let chapter = ReaderChapterMetadata(
            id: env.chapterID, documentID: env.documentID,
            ordinal: 0, title: "章节", sourceLocator: nil,
            canonicalHash: "ch-hash", textUTF16Length: 10)
        try await env.pool.write { db in
            let moves = try ReaderTranslationReanchor.moves(
                documentID: env.documentID,
                chapters: [chapter], blocks: blocks, in: db)
            XCTAssertEqual(moves.count, 1)
            XCTAssertEqual(moves[0].oldLocatorKey, legacyKey)
            XCTAssertEqual(
                moves[0].newLocatorKey,
                ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: 1,
                    blockUTF16Length: blocks[1].text.utf16.count))
            try GRDBReaderTranslationStore.updateLocators(
                documentID: env.documentID, moves: moves, in: db)
        }
        let current = try await env.pool.read { db in
            try GRDBReaderTranslationStore.fetchCurrent(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(
            current.first?.locatorKey,
            ReaderTranslationLocator.wholeBlockKey(
                chapterOrdinal: 0, blockOrdinal: 1,
                blockUTF16Length: blocks[1].text.utf16.count))
    }
}
