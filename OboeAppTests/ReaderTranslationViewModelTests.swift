import Foundation
import GRDB
import XCTest
import OboeDomain
import OboeInfrastructure
@testable import Oboe

/// v0.7.5 S17 译文 VM 测试：章级水合（零网络/不落位）、三模式
/// 渲染态、双语折叠、失败占位→重试、整章补译跳过已覆盖块。
/// 真实 GRDB 栈 + 脚本化 sender——VM 路径永不触网。
@MainActor
final class ReaderTranslationViewModelTests: XCTestCase {
    /// setUp/tearDown 是非隔离重载；测试串行执行，临时目录访问无竞态。
    private nonisolated(unsafe) var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReaderTranslation-\(UUID().uuidString)",
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
        let document: ReaderDocumentMetadata
        let chapterID: UUID
        let blocks: [ReaderBlock]
        let sender: ScriptedSender
        let dependencies: ReaderTranslationDependencies
        let contextThrowing: Bool
    }

    private static let language = "zho"

    /// 单文档单章两块。
    private func makeEnvironment(
        contextAvailable: Bool = true
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

        let documentID = UUID()
        let chapterID = UUID()
        let blockIDs = [UUID(), UUID()]
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version,
                        content_revision, availability)
                    VALUES (?, '测试文档', 'paste', 1,
                            '0000000000000000000000000000000000000000000000000000000000000000',
                            'hash1', 'parser-1', 1, 'available')
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title, source_locator,
                        canonical_hash, text_utf16_length)
                    VALUES (?, ?, 0, '章节', NULL, 'ch-hash', 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID)])
            for (index, id) in blockIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal, text,
                            text_hash, locator_json)
                        VALUES (?, ?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(id),
                        DatabaseValueCodec.encode(documentID),
                        DatabaseValueCodec.encode(chapterID),
                        index,
                        index == 0 ? "猫が好き。" : "犬も好き。",
                        "h-\(index)"])
            }
        }
        let blocks = try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_blocks WHERE document_id = ?
                    ORDER BY ordinal
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ).map { row in
                ReaderBlock(
                    id: try DatabaseValueCodec.decodeUUID(row["id"]),
                    documentID: documentID, chapterID: chapterID,
                    ordinal: row["ordinal"], text: row["text"],
                    textHash: row["text_hash"], locatorJSON: nil)
            }
        }
        let document = ReaderDocumentMetadata(
            id: documentID, title: "测试文档", format: .paste,
            createdAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, sourceFileName: nil,
            sourceSHA256: String(repeating: "0", count: 64),
            canonicalTextHash: "hash1", parserVersion: "parser-1",
            contentRevision: 1, progressBasisPoints: 0,
            availability: .available)

        let sender = ScriptedSender()
        let context: ReaderTranslationOrchestrator.RequestContext = .init(
            resolved: ResolvedAIConfiguration(
                isEnabled: true, serviceKind: .deepSeek,
                serviceName: "Test",
                baseURL: URL(string: "https://api.example.com")!,
                modelID: "m-1", responseFormatMode: .promptedJSON,
                credentialReference: AICredentialReference(
                    id: UUID(), serviceKind: .deepSeek,
                    host: "api.example.com")),
            credential: "sk", dictionaryDatasetVersion: "d1",
            morphologyVersion: "m1", osBuild: "o1")
        let orchestrator = ReaderTranslationOrchestrator(
            pool: pool,
            contextProvider: {
                guard contextAvailable else {
                    throw ReaderTranslationOrchestrator
                        .OrchestratorError.contextUnavailable
                }
                return context
            },
            sender: { request, ctx in
                try await sender.send(request, ctx)
            })
        return Environment(
            pool: pool, document: document, chapterID: chapterID,
            blocks: blocks, sender: sender,
            dependencies: ReaderTranslationDependencies(
                orchestrator: orchestrator, language: Self.language),
            contextThrowing: !contextAvailable)
    }

    /// 脚本化 sender：按序吐结果；无脚本按默认译文生成；
    /// `failNext` 注入下一次错误。
    private final class ScriptedSender: @unchecked Sendable {
        var calls: [AIStudyRequest] = []
        var queued: [Error] = []
        var translation = "译文"

        func send(
            _ request: AIStudyRequest,
            _ context: ReaderTranslationOrchestrator.RequestContext
        ) async throws -> AIStudyResolverResult {
            calls.append(request)
            if !queued.isEmpty { throw queued.removeFirst() }
            return AIStudyResolverResult(
                outcome: ValidatedBlockOutcome(
                    blockKey: request.blocks[0].blockKey,
                    lexicalStatus: .resolved,
                    translationStatus: .done,
                    translation: "\(translation)-\(calls.count)",
                    envelopeRejection: nil, resolutions: [],
                    targetTokenCount: 0, aiResolvedCount: 0,
                    lowConfidenceCount: 0, unresolvedTokenCount: 0,
                    droppedUnknownTokenCount: 0,
                    duplicateTokenCount: 0, malformedItemCount: 0,
                    invalidItemCount: 0),
                requestHash: request.requestHash,
                requestID: request.requestID,
                providerKind: "stub", model: "m-1",
                promptVersion: request.metadata.promptVersion,
                responseMode: .promptedJSON,
                suggestedRetryAfter: nil, responseBytes: 64)
        }
    }

    private func publishTranslation(
        env: Environment, block: ReaderBlock, text: String,
        sourceHash: String? = nil
    ) async throws {
        _ = try await env.pool.write { db in
            try GRDBReaderTranslationStore.publish(
                documentID: env.document.id,
                locatorKey: ReaderTranslationLocator.wholeBlockKey(
                    chapterOrdinal: 0, blockOrdinal: block.ordinal,
                    blockUTF16Length: block.text.utf16.count),
                locatorJSON: ReaderTranslationLocator.locatorJSON(
                    sourceText: block.text,
                    blockTextHash: sourceHash ?? block.textHash,
                    chapterOrdinal: 0, blockOrdinal: block.ordinal,
                    targetRange: 0..<block.text.utf16.count),
                sourceHash: sourceHash ?? block.textHash,
                language: "zho", translatedText: text, in: db)
        }
    }

    // MARK: - 水合

    /// 打开 Reader 的水合路径零网络：refresh 只读本地行。
    func testRefreshHydratesWithoutDispatch() async throws {
        let env = try makeEnvironment()
        try await publishTranslation(
            env: env, block: env.blocks[0], text: "猫の訳")
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        XCTAssertTrue(env.sender.calls.isEmpty, "水合不得派发请求")
        guard case let .complete(text, _) =
                model.outcomes[env.blocks[0].id]
        else { return XCTFail("块 0 应装配出完整译文") }
        XCTAssertEqual(text, "猫の訳")
        XCTAssertEqual(
            model.renderState(for: env.blocks[0].id), .ready)
        XCTAssertEqual(
            model.renderState(for: env.blocks[1].id), .missing)
    }

    /// 内容改动（行 hash ≠ 活块 hash）→ 译文不落位、渲染 missing。
    func testStaleHashNeverRenders() async throws {
        let env = try makeEnvironment()
        try await publishTranslation(
            env: env, block: env.blocks[0], text: "旧源译文",
            sourceHash: "stale-hash")
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        XCTAssertNil(model.outcomes[env.blocks[0].id])
        XCTAssertEqual(
            model.renderState(for: env.blocks[0].id), .missing)
    }

    /// 双语段：ready→text / collapsed→collapsed / missing→missing /
    /// failed→failed / 在途→requesting 一拍平。
    func testBilingualSegmentsAndCollapse() async throws {
        let env = try makeEnvironment()
        try await publishTranslation(
            env: env, block: env.blocks[0], text: "猫の訳")
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        XCTAssertEqual(
            model.segment(for: env.blocks[0].id), .text("猫の訳"))
        XCTAssertEqual(model.segment(for: env.blocks[1].id), .missing)
        XCTAssertEqual(model.bilingualSegments.count, 2)

        model.toggleCollapse(env.blocks[0].id)
        XCTAssertEqual(
            model.segment(for: env.blocks[0].id), .collapsed)
        model.toggleCollapse(env.blocks[0].id)
        XCTAssertEqual(
            model.segment(for: env.blocks[0].id), .text("猫の訳"))
    }

    // MARK: - 显式翻译 / 重译

    /// 单块翻译：成功后 outcomes 更新、旧模式三态不受影响。
    func testTranslateBlockPublishesAndHydrates() async throws {
        let env = try makeEnvironment()
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        await model.translate(env.blocks[0].id)
        XCTAssertEqual(env.sender.calls.count, 1)
        guard case let .complete(text, _) =
                model.outcomes[env.blocks[0].id]
        else { return XCTFail("翻译成功应渲染译文") }
        XCTAssertTrue(text.hasPrefix("译文-"))
        XCTAssertNil(model.failedCodes[env.blocks[0].id])
        // 块 1 仍未译——缺失不静默。
        XCTAssertEqual(
            model.renderState(for: env.blocks[1].id), .missing)
    }

    /// 重译失败：旧译文原样保留 + 块记失败归因（占位/重试提示）。
    func testFailedRetranslateKeepsOldTranslation() async throws {
        let env = try makeEnvironment()
        env.sender.translation = "旧译文"
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        await model.translate(env.blocks[0].id)
        guard case let .complete(old, _) =
                model.outcomes[env.blocks[0].id]
        else { return XCTFail("应先有旧译文") }
        XCTAssertTrue(old.hasPrefix("旧译文"))

        env.sender.queued = [
            AIStudyResolverError.retryable(.connectionFailed),
        ]
        await model.retranslate(env.blocks[0].id)
        // 旧译文仍在（publish 未发生）+ 失败归因在。
        guard case let .complete(kept, _) =
                model.outcomes[env.blocks[0].id]
        else { return XCTFail("失败重译不得丢旧译文") }
        XCTAssertEqual(kept, old)
        XCTAssertEqual(
            model.failedCodes[env.blocks[0].id],
            ReaderTranslationOrchestrator.FailureCode.retryable)

        // 显式重试成功 → 新译文翻转落位、归因清。
        env.sender.translation = "新译文"
        await model.retranslate(env.blocks[0].id)
        guard case let .complete(new, _) =
                model.outcomes[env.blocks[0].id]
        else { return XCTFail("重试成功应落新译文") }
        XCTAssertTrue(new.hasPrefix("新译文"))
        XCTAssertNil(model.failedCodes[env.blocks[0].id])
    }

    /// 整章补译：已覆盖块不重发（§8.2 请求复用 + onlyMissing）。
    func testTranslateChapterSkipsCoveredBlocks() async throws {
        let env = try makeEnvironment()
        try await publishTranslation(
            env: env, block: env.blocks[0], text: "已有译文")
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        await model.translateChapter()
        // 只发块 1。
        XCTAssertEqual(env.sender.calls.count, 1)
        XCTAssertTrue(
            env.sender.calls[0].blocks[0].blockKey.contains(":b:1#"))
        guard case let .complete(text, _) =
                model.outcomes[env.blocks[0].id]
        else { return XCTFail("已覆盖块译文应原样") }
        XCTAssertEqual(text, "已有译文")
    }

    /// AI 未配置：整批 contextUnavailable → 给设置入口提示，
    /// 块级归因记 contextUnavailable。
    func testContextUnavailableSurfaced() async throws {
        let env = try makeEnvironment(contextAvailable: false)
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        await model.translateChapter()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(
            model.failedCodes[env.blocks[0].id],
            ReaderTranslationOrchestrator.FailureCode
                .contextUnavailable)
        XCTAssertTrue(env.sender.calls.isEmpty)
    }

    /// 模式切换是纯视图态：译文数据不丢、渲染态不变（锚定由
    /// view 的 scrollAnchor 承担——VM 侧验证数据面稳定）。
    func testModeSwitchPreservesTranslationState() async throws {
        let env = try makeEnvironment()
        try await publishTranslation(
            env: env, block: env.blocks[0], text: "猫の訳")
        let model = ReaderTranslationViewModel(
            dependencies: env.dependencies)
        await model.refresh(
            document: env.document, chapterOrdinal: 0,
            blocks: env.blocks)
        model.mode = .bilingual
        XCTAssertNotNil(model.outcomes[env.blocks[0].id])
        model.mode = .translatedOnly
        XCTAssertNotNil(model.outcomes[env.blocks[0].id])
        model.mode = .original
        guard case .complete = model.outcomes[env.blocks[0].id]
        else { return XCTFail("模式来回切换不得丢装配结果") }
    }
}
