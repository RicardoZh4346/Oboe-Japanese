import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S13：Reader→Cloze 创建的持久化闭环测试——
/// `commitCloze`（世代屏障 → receipt 回放 → `GRDBContentWriteExecutor
/// .sentence` → `createdCloze` 事件 → `create_cloze` receipt）与
/// 「原文删除仍可复习/编辑」的快照独立性。
///
/// schema 走全量注册迁移（v18 提供 receipts/events，v19 cloze 在
/// `OboeDatabase` 之后独立补注册——与 `GRDBClozeCommitTests` 同法）。
///
/// 共享样例——文件级常量，`pool.write`/`read` 的 @Sendable 闭包内
/// 引用不触发 self 捕获。
private let clozeSentence = "私は昨日映画を見た。"
private let clozeSurface = "見た"
private let clozeClock = Date(timeIntervalSince1970: 1_768_000_000)
private let clozeDocumentID = UUID(
    uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
private let clozeChapterID = UUID(
    uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
private let clozeDeckID = UUID(
    uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

final class GRDBReaderClozeMiningTests: XCTestCase {

    private let generationBox = ClozeGenerationBox()
    private var generation: Int {
        get { generationBox.value }
        set { generationBox.value = newValue }
    }

    private var directory: URL!
    private var pool: DatabasePool!
    private var database: OboeDatabase!
    private var store: GRDBReaderMiningStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ClozeMining-\(UUID().uuidString)", isDirectory: true)
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
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        var clozeMigrator = DatabaseMigrator()
        clozeMigrator.registerMigration(
            "v19_cloze", migrate: GRDBClozeSchema.migrate)
        try clozeMigrator.migrate(pool)
        database = OboeDatabase(pool: pool)
        store = GRDBReaderMiningStore(pool: pool)
        generation = 7
        try insertDeck(id: clozeDeckID)
        try insertReaderDocument()
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - 装配

    private func makeService() -> ReaderMiningService {
        let box = generationBox
        let fixedNow = clozeClock
        return ReaderMiningService(
            dictionary: StubDictionaryRepository(),
            knowledge: GRDBVocabularyKnowledgeRepository(pool: pool),
            store: store,
            currentGeneration: { box.value },
            now: { fixedNow },
            makeID: { UUID() }
        )
    }

    private func makeContext() -> ReaderMiningContext {
        ReaderMiningContext(
            documentID: clozeDocumentID,
            chapterID: clozeChapterID,
            location: ReaderLocation(
                chapterOrdinal: 0, blockOrdinal: 3, utf16Offset: 6,
                blockTextHash: "hash", prefix: "私は昨日", suffix: "。"
            ),
            sentence: clozeSentence,
            surroundingText: "前文‖后文",
            selectedSurface: clozeSurface,
            sourceTitle: "测试书"
        )
    }

    private func makeCloze(rangeStart: Int? = nil) throws
        -> ValidatedClozeContent {
        let nsRange = NSRange(
            clozeSentence.range(of: clozeSurface)!, in: clozeSentence)
        return try ValidatedClozeContent(
            sentenceSnapshot: clozeSentence,
            utf16Start: rangeStart ?? nsRange.location,
            utf16Length: nsRange.length,
            targetSurface: clozeSurface,
            targetLemma: "見る",
            targetReading: "みた",
            acceptedAnswers: ["見た", "みた"],
            hint: "提示"
        )
    }

    private func makeRequest(
        operationID: UUID = UUID(),
        clozeRangeStart: Int? = nil
    ) throws -> ReaderClozeMiningRequest {
        try ReaderClozeMiningRequest(
            operationID: operationID,
            expectedGeneration: generation,
            deckID: clozeDeckID,
            cloze: makeCloze(rangeStart: clozeRangeStart),
            meaningZH: "我昨天看了电影。",
            context: makeContext()
        )
    }

    /// 直接装配写计划（不经 service）——store 层测试用。
    private func makePlan(
        operationID: UUID = UUID(),
        expectedGeneration: Int = 7,
        payload: String = "v13_cloze|test",
        deckID: UUID = clozeDeckID
    ) throws -> ReaderClozeMiningWritePlan {
        let noteID = UUID()
        return ReaderClozeMiningWritePlan(
            operationID: operationID,
            canonicalPayload: payload,
            commit: try SentenceContentCommit(
                noteID: noteID,
                clozeID: UUID(),
                deckID: deckID,
                cloze: makeCloze(),
                card: NewCardSeed(
                    id: UUID(), templateKind: .sentenceCloze),
                schedulerProfileID: UUID(),
                createdAt: clozeClock,
                meaningZH: "我昨天看了电影。",
                origin: .reader,
                sourceText: clozeSentence,
                deckIDs: [deckID],
                sourceContext: SourceContext(
                    id: UUID(),
                    noteID: noteID,
                    sourceType: .reader,
                    originalSentence: clozeSentence,
                    surroundingText: "前文‖后文",
                    sourceTitle: "测试书",
                    sourceURL: nil,
                    sourceApp: nil,
                    imageReference: nil,
                    dictionaryEntryID: nil,
                    dictionaryVersion: nil,
                    dictionarySenseKey: nil,
                    selectedGlossLanguage: nil,
                    isPrimary: true,
                    createdAt: clozeClock,
                    readerDocumentID: clozeDocumentID,
                    readerChapterID: clozeChapterID,
                    readerLocation: makeContext().location,
                    selectedSurface: clozeSurface
                )
            ),
            documentID: clozeDocumentID,
            eventSnapshotJSON: #"{"written_form":"見た"}"#,
            expectedGeneration: expectedGeneration,
            committedAt: clozeClock
        )
    }

    private func insertDeck(id: UUID) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(id)])
        }
    }

    /// reader_documents/reader_chapters 行——`reader_activity_events
    /// .document_id` 的 FK 目标（弱引用；删除后 SET NULL）。
    private func insertReaderDocument() throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version, availability
                    ) VALUES (?, '测试书', 'txt', 1, ?, 'h', 'v1', 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(clozeDocumentID),
                    String(repeating: "a", count: 64)
                ])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title, canonical_hash,
                        text_utf16_length
                    ) VALUES (?, ?, 0, '序章', 'ch', 100)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(clozeChapterID),
                    DatabaseValueCodec.encode(clozeDocumentID)
                ])
        }
    }

    private func rowCount(_ table: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func assertAllClozeMiningTablesEmpty(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for table in ["notes", "cards", "cloze_definitions",
                      "source_contexts", "note_decks",
                      "reader_activity_events",
                      "reader_mining_receipts"] {
            let count = try await rowCount(table)
            XCTAssertEqual(
                0, count,
                "\(table) 必须为 0 行（事务回滚零残留）",
                file: file, line: line)
        }
    }

    // MARK: - 成功路径

    /// 服务端到端：mineCloze 一次提交落齐 sentence Note +
    /// sentence_cloze 卡 + definition + Reader 定位来源 +
    /// createdCloze 事件 + create_cloze receipt。
    func testMineClozePersistsAllRowsAtomically() async throws {
        let service = makeService()
        let outcome = try await service.mineCloze(makeRequest())
        XCTAssertFalse(outcome.wasReplayed)
        XCTAssertEqual(outcome.cardCount, 1)

        try await pool.read { db in
            let note = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, headword, origin, source_text, meaning_zh
                    FROM notes WHERE id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(outcome.noteID)]))
            XCTAssertEqual(note["kind"], "sentence")
            XCTAssertEqual(note["headword"], clozeSentence)
            XCTAssertEqual(note["origin"], "reader")
            XCTAssertEqual(note["source_text"], clozeSentence)
            XCTAssertEqual(note["meaning_zh"], "我昨天看了电影。")

            let definition = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT card_id, source_context_id, sentence_snapshot,
                           range_utf16_start, target_surface,
                           target_lemma, target_reading, hint
                    FROM cloze_definitions WHERE note_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(outcome.noteID)]))
            XCTAssertEqual(definition["sentence_snapshot"], clozeSentence)
            XCTAssertEqual(definition["target_surface"], clozeSurface)
            XCTAssertEqual(definition["target_lemma"], "見る")
            XCTAssertEqual(definition["target_reading"], "みた")
            XCTAssertEqual(definition["hint"], "提示")

            let cardID: String = definition["card_id"]
            let card = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT template_kind, is_enabled FROM cards
                    WHERE id = ? AND note_id = ?
                    """,
                arguments: [
                    cardID,
                    DatabaseValueCodec.encode(outcome.noteID)]))
            XCTAssertEqual(card["template_kind"], "sentence_cloze")

            let contextID: String = definition["source_context_id"]
            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT note_id, source_type, reader_document_id,
                           reader_chapter_id, reader_location,
                           selected_surface, is_primary
                    FROM source_contexts WHERE id = ?
                    """,
                arguments: [contextID]))
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(context["note_id"]),
                outcome.noteID)
            XCTAssertEqual(context["source_type"], "reader")
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(
                    context["reader_document_id"]),
                clozeDocumentID)
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(
                    context["reader_chapter_id"]),
                clozeChapterID)
            XCTAssertNotNil(context["reader_location"] as String?)
            XCTAssertEqual(context["selected_surface"], clozeSurface)
            XCTAssertEqual(context["is_primary"], 1)

            // 事件 + receipt（kind 白名单值已在 v18 注册）。
            let event = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, note_id, document_id, lexeme_id
                    FROM reader_activity_events
                    """))
            XCTAssertEqual(event["kind"], "createdCloze")
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(event["note_id"]),
                outcome.noteID)
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(event["document_id"]),
                clozeDocumentID)
            XCTAssertNil(event["lexeme_id"] as String?)

            let receipt = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, payload_hash, result_json
                    FROM reader_mining_receipts
                    """))
            XCTAssertEqual(receipt["kind"], "create_cloze")
            XCTAssertTrue(
                (receipt["result_json"] as String)
                    .contains(outcome.noteID.uuidString.lowercased()))
            // cloze 不建 lexeme 关联。
            XCTAssertEqual(0, try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lexemes") ?? 0)
            XCTAssertEqual(0, try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM lexeme_note_links") ?? 0)
        }
    }

    /// 同 opID + 同内容重试 → receipt 回放：note 不复制、事件
    /// 不新增、`wasReplayed`。
    func testMineClozeReplaySameOperationID() async throws {
        let service = makeService()
        let request = try makeRequest()
        let first = try await service.mineCloze(request)
        let second = try await service.mineCloze(request)
        XCTAssertFalse(first.wasReplayed)
        XCTAssertTrue(second.wasReplayed)
        XCTAssertEqual(second.noteID, first.noteID)
        let notesCount = try await rowCount("notes")
        let definitionsCount = try await rowCount("cloze_definitions")
        let eventsCount = try await rowCount("reader_activity_events")
        let receiptsCount = try await rowCount("reader_mining_receipts")
        XCTAssertEqual(1, notesCount)
        XCTAssertEqual(1, definitionsCount)
        XCTAssertEqual(1, eventsCount)
        XCTAssertEqual(1, receiptsCount)
    }

    /// 同 opID 换内容（句与 blank 都变——错位重放）→
    /// `operationPayloadConflict`，不写第二行。
    func testMineClozePayloadConflict() async throws {
        let service = makeService()
        let opID = UUID()
        _ = try await service.mineCloze(makeRequest(operationID: opID))
        let shifted = "私は昨日映画を見た。明日も見たい。"
        let secondRange = ClozeValidator.surfaceRanges(
            of: clozeSurface, in: shifted)[1]
        do {
            _ = try await service.mineCloze(
                ReaderClozeMiningRequest(
                    operationID: opID,
                    expectedGeneration: generation,
                    deckID: clozeDeckID,
                    cloze: try ValidatedClozeContent(
                        sentenceSnapshot: shifted,
                        utf16Start: secondRange.utf16Start,
                        utf16Length: secondRange.utf16Length,
                        targetSurface: clozeSurface,
                        targetLemma: "見る",
                        targetReading: "みた",
                        acceptedAnswers: ["見た", "みた"]
                    ),
                    context: makeContext()
                ))
            XCTFail("expected operationPayloadConflict")
        } catch ReaderMiningError.operationPayloadConflict(let id) {
            XCTAssertEqual(id, opID)
        }
        let definitionsCount = try await rowCount("cloze_definitions")
        XCTAssertEqual(1, definitionsCount)
    }

    /// 世代屏障在写事务内复核：store 层直接调 commitCloze，
    /// 活世代 8 ≠ 请求世代 7 → staleGeneration，零写入。
    func testCommitClozeRejectsStaleGenerationInsideTransaction()
        async throws
    {
        let plan = try makePlan(expectedGeneration: 7)
        do {
            _ = try await store.commitCloze(
                plan, currentGeneration: { 8 })
            XCTFail("expected staleGeneration")
        } catch ReaderMiningError.staleGeneration(
            let expected, let current) {
            XCTAssertEqual(expected, 7)
            XCTAssertEqual(current, 8)
        }
        try await assertAllClozeMiningTablesEmpty()
    }

    /// 回滚完整性：牌组不存在 → deckNotFound，全部关联表零残留。
    func testCommitClozeRollsBackOnMissingDeck() async throws {
        let base = try makePlan()
        let missing = UUID()
        let plan = ReaderClozeMiningWritePlan(
            operationID: base.operationID,
            canonicalPayload: base.canonicalPayload,
            commit: SentenceContentCommit(
                noteID: base.commit.noteID,
                clozeID: base.commit.clozeID,
                deckID: missing,  // 不存在的牌组
                cloze: base.commit.cloze,
                card: base.commit.card,
                schedulerProfileID: base.commit.schedulerProfileID,
                createdAt: base.commit.createdAt,
                meaningZH: base.commit.meaningZH,
                origin: .reader,
                sourceText: base.commit.sourceText,
                deckIDs: [missing],
                sourceContext: base.commit.sourceContext
            ),
            documentID: base.documentID,
            eventSnapshotJSON: base.eventSnapshotJSON,
            expectedGeneration: 7,
            committedAt: base.committedAt
        )
        do {
            _ = try await store.commitCloze(
                plan, currentGeneration: { 7 })
            XCTFail("expected deckNotFound")
        } catch {
            XCTAssertEqual(error as? ContentCardError, .deckNotFound)
        }
        try await assertAllClozeMiningTablesEmpty()
    }

    // MARK: - 快照独立性（原文删除后仍可复习/编辑）

    /// 删 reader_documents → source_contexts 弱引用原样保留
    /// （reader_document_id 无 FK）；cloze definition 完整可读，
    /// 复习载荷正面不泄题，编辑路径仍可用；事件行 document_id
    /// SET NULL 但事件本身保留。
    func testReaderDocumentDeletionPreservesCloze() async throws {
        let service = makeService()
        let outcome = try await service.mineCloze(makeRequest())
        let clozeRepository = GRDBClozeRepository(database: database)
        let reviewRepository = GRDBReviewCardContentRepository(
            database: database)
        let readerRepository = GRDBReaderRepository(database: database)

        // 删除原文档——Reader 内部行级联清，弱引用保留。
        try await readerRepository.deleteDocument(id: clozeDocumentID)

        let fetched = try await clozeRepository.fetchDefinition(
            noteID: outcome.noteID)
        let definition = try XCTUnwrap(fetched)
        XCTAssertEqual(definition.sentenceSnapshot, clozeSentence)
        XCTAssertEqual(definition.targetSurface, clozeSurface)
        XCTAssertEqual(definition.acceptedAnswers, ["見た", "みた"])
        // source_context_id 未 SET NULL——来源行还在（无 FK）。
        let sourceContextID = try XCTUnwrap(definition.sourceContextID)
        try await pool.read { db in
            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT reader_document_id, original_sentence,
                           source_title, reader_location
                    FROM source_contexts WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(sourceContextID)]))
            // 弱引用值原样保留——背面仍能展示「来自某文档」的定位
            // 快照，不依赖 Reader 表存活。
            XCTAssertEqual(
                try DatabaseValueCodec.decodeUUID(
                    context["reader_document_id"]),
                clozeDocumentID)
            XCTAssertEqual(context["original_sentence"], clozeSentence)
            XCTAssertNotNil(context["reader_location"] as String?)

            let event = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, note_id, document_id
                    FROM reader_activity_events
                    """))
            XCTAssertEqual(event["kind"], "createdCloze")
            XCTAssertNil(event["document_id"] as String?)
        }

        // 复习载荷仍在；正面遮罩句不含答案本体。
        let cardID = definition.cardID
        let fetchedContent = try await reviewRepository
            .fetchReviewCardContent(cardID: cardID)
        let content = try XCTUnwrap(fetchedContent)
        let cloze = try XCTUnwrap(content.cloze)
        let front = ClozeValidator.maskedSentence(
            cloze.sentenceSnapshot, range: cloze.range, blank: "＿＿")
        XCTAssertFalse(front.contains(clozeSurface))
        XCTAssertTrue(front.contains("＿＿"))

        // 编辑路径仍可用：只改 hint 也走完整校验 + 版本抬升。
        let fixedNow = clozeClock
        let sentenceService = SentenceService(
            repository: clozeRepository, now: { fixedNow })
        var form = SentenceFormData(
            definition: definition, meaningZH: nil, notes: nil)
        form.hint = "新提示"
        let updated = try await sentenceService.updateSentence(
            noteID: outcome.noteID, formData: form)
        XCTAssertEqual(updated?.definition.hint, "新提示")
        XCTAssertEqual(updated?.definition.contentVersion, 2)
    }
}

/// 可变世代盒——@Sendable 闭包不捕获测试类 self。
private final class ClozeGenerationBox: @unchecked Sendable {
    var value = 7
}

/// 本测试用不到的词典桩（mineCloze 不查词典）。
private final class StubDictionaryRepository: DictionaryRepository,
    @unchecked Sendable {
    func metadata() async throws -> DictionaryMetadata {
        DictionaryMetadata(
            schemaVersion: "1", datasetVersion: "ds-1",
            dictionaryVersion: "dv-1")
    }
    func search(
        _ request: DictionarySearchRequest
    ) async throws -> DictionarySearchPage {
        DictionarySearchPage(
            items: [], nextCursor: nil, hasMore: false,
            normalizedQuery: request.normalizedQuery)
    }
    func entries(ids: [Int64]) async throws -> [DictionaryEntry] { [] }
    func entry(id: Int64) async throws -> DictionaryEntry? { nil }
    func sources() async throws -> [DictionarySourceInfo] { [] }
}
