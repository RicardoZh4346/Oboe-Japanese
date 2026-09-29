import XCTest
@testable import OboeDomain

/// v0.7.0 S13：Reader→Cloze 创建的领域侧装配测试——`mineCloze`
/// 的写计划装配（来源定位/快照/答案集/牌组）、世代屏障、receipt
/// 回放透传。持久化侧见 `GRDBReaderClozeMiningTests`。
final class ReaderClozeMiningTests: XCTestCase {

    private let sentence = "私は昨日映画を見た。明日も見たい。"
    private let surface = "見た"
    private let clock = Date(timeIntervalSince1970: 1_768_000_000)
    private let generationBox = GenerationBox()
    private var generation: Int {
        get { generationBox.value }
        set { generationBox.value = newValue }
    }

    private func makeService(
        store: StubClozeMiningStore
    ) -> ReaderMiningService {
        let box = generationBox
        let fixedNow = clock
        return ReaderMiningService(
            dictionary: StubDictionaryRepository(),
            knowledge: StubKnowledgeRepository(),
            store: store,
            currentGeneration: { box.value },
            now: { fixedNow },
            makeID: { UUID() }
        )
    }

    private func makeContext() -> ReaderMiningContext {
        ReaderMiningContext(
            documentID: UUID(
                uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            chapterID: UUID(
                uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            location: ReaderLocation(
                chapterOrdinal: 2, blockOrdinal: 5, utf16Offset: 6,
                blockTextHash: "hash", prefix: "私は昨日", suffix: "。"
            ),
            sentence: sentence,
            surroundingText: "前文‖后文",
            selectedSurface: surface,
            sourceTitle: "测试文档"
        )
    }

    private func makeRequest(
        operationID: UUID = UUID(),
        deckID: UUID = UUID(
            uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
        additionalDeckIDs: Set<UUID> = [],
        context: ReaderMiningContext? = nil
    ) throws -> ReaderClozeMiningRequest {
        // 句中「見た」出现两次（見た。/見たい）——取第一处。
        let range = try XCTUnwrap(
            ClozeValidator.surfaceRanges(of: surface, in: sentence).first
        )
        return ReaderClozeMiningRequest(
            operationID: operationID,
            expectedGeneration: generation,
            deckID: deckID,
            additionalDeckIDs: additionalDeckIDs,
            cloze: try ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: range.utf16Start,
                utf16Length: range.utf16Length,
                targetSurface: surface,
                targetLemma: "見る",
                targetReading: "みた",
                acceptedAnswers: ["見た", "みた"],
                hint: "提示"
            ),
            meaningZH: "我昨天看了电影。",
            notes: "备注",
            tags: [KnowledgeTag(
                id: UUID(), name: "N3", normalizedName: "n3")],
            context: context ?? makeContext()
        )
    }

    /// 装配断言：commit 的 origin/deck/卡模板/句快照来源 +
    /// SourceContext 的 reader_* 定位 + 答案集原样保留。
    func testMineClozeAssemblesSentenceCommitWithReaderContext()
        async throws
    {
        let store = StubClozeMiningStore()
        let service = makeService(store: store)
        generation = 7
        let extraDeck = UUID()
        let request = try makeRequest(additionalDeckIDs: [extraDeck])

        let outcome = try await service.mineCloze(request)
        XCTAssertEqual(outcome.cardCount, 1)
        XCTAssertFalse(outcome.wasReplayed)

        let plan = try XCTUnwrap(store.clozePlans.first)
        XCTAssertEqual(plan.operationID, request.operationID)
        XCTAssertEqual(plan.expectedGeneration, 7)
        XCTAssertEqual(plan.documentID, request.context.documentID)
        let commit = plan.commit
        XCTAssertEqual(commit.origin, .reader)
        XCTAssertEqual(commit.sourceText, sentence)
        XCTAssertEqual(commit.deckID, request.deckID)
        XCTAssertEqual(commit.deckIDs, [request.deckID, extraDeck])
        XCTAssertEqual(commit.card.templateKind, .sentenceCloze)
        XCTAssertEqual(commit.cloze, request.cloze)
        XCTAssertEqual(commit.meaningZH, "我昨天看了电影。")
        XCTAssertEqual(commit.notes, "备注")
        XCTAssertEqual(commit.tags.map(\.normalizedName), ["n3"])
        XCTAssertEqual(commit.createdAt, clock)

        // 来源：Reader 定位字段全齐，noteID 指向新 Note，
        // originalSentence 是截取句而非整篇正文。
        let source = try XCTUnwrap(commit.sourceContext)
        XCTAssertEqual(source.noteID, commit.noteID)
        XCTAssertEqual(source.sourceType, .reader)
        XCTAssertEqual(source.originalSentence, sentence)
        XCTAssertEqual(source.surroundingText, "前文‖后文")
        XCTAssertEqual(source.sourceTitle, "测试文档")
        XCTAssertEqual(source.readerDocumentID,
                       request.context.documentID)
        XCTAssertEqual(source.readerChapterID,
                       request.context.chapterID)
        XCTAssertEqual(source.readerLocation, request.context.location)
        XCTAssertEqual(source.selectedSurface, surface)
        XCTAssertTrue(source.isPrimary)

        // definition ↔ card ↔ note 一致（executor 复核的对象）。
        XCTAssertEqual(commit.cloze.sentenceSnapshot, sentence)
        XCTAssertEqual(commit.cloze.targetSurface, surface)
        XCTAssertEqual(commit.cloze.targetLemma, "見る")
        XCTAssertEqual(commit.cloze.targetReading, "みた")
        XCTAssertEqual(commit.cloze.acceptedAnswers, ["見た", "みた"])
    }

    /// receipt 负载确定性：同内容两次装配得同串；blank 换到第二处
    /// 「見た」→ payload 必变（错位重放不得复用 receipt）。
    func testClozePayloadDeterministicAndRangeSensitive() async throws {
        let store = StubClozeMiningStore()
        let service = makeService(store: store)
        generation = 7
        let first = try makeRequest()
        _ = try await service.mineCloze(first)
        // 同内容重装配（新 opID）→ 规范负载相同。
        let second = try makeRequest()
        _ = try await service.mineCloze(second)
        XCTAssertEqual(
            store.clozePlans[0].canonicalPayload,
            store.clozePlans[1].canonicalPayload)

        // 选第二处「見た」→ range 进负载，payload 必变。
        let ranges = ClozeValidator.surfaceRanges(
            of: surface, in: sentence)
        XCTAssertEqual(ranges.count, 2)
        var third = try makeRequest()
        third = ReaderClozeMiningRequest(
            operationID: third.operationID,
            expectedGeneration: third.expectedGeneration,
            deckID: third.deckID,
            cloze: try ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: ranges[1].utf16Start,
                utf16Length: ranges[1].utf16Length,
                targetSurface: surface,
                targetLemma: "見る",
                targetReading: "みた",
                acceptedAnswers: ["見た", "みた"],
                hint: "提示"
            ),
            meaningZH: third.meaningZH,
            notes: third.notes,
            tags: third.tags,
            context: third.context
        )
        _ = try await service.mineCloze(third)
        XCTAssertNotEqual(
            store.clozePlans[0].canonicalPayload,
            store.clozePlans[2].canonicalPayload)
    }

    /// 世代屏障：请求发起世代 ≠ 活世代 → staleGeneration，store
    /// 零调用（不写任何行）。
    func testMineClozeRejectsStaleGeneration() async throws {
        let store = StubClozeMiningStore()
        let service = makeService(store: store)
        generation = 7
        let request = try makeRequest()
        generation = 8
        do {
            _ = try await service.mineCloze(request)
            XCTFail("expected staleGeneration")
        } catch ReaderMiningError.staleGeneration(
            let expected, let current) {
            XCTAssertEqual(expected, 7)
            XCTAssertEqual(current, 8)
        }
        XCTAssertTrue(store.clozePlans.isEmpty)
    }

    /// 回放透传：store 命中既有 receipt（wasReplayed）→ 服务原样
    /// 回传，不重复建卡。
    func testMineClozePassesThroughReplayedOutcome() async throws {
        let store = StubClozeMiningStore()
        store.replayOutcome = ReaderClozeMiningOutcome(
            noteID: UUID(), cardCount: 1, wasReplayed: true)
        let service = makeService(store: store)
        generation = 7
        let outcome = try await service.mineCloze(makeRequest())
        XCTAssertTrue(outcome.wasReplayed)
        XCTAssertEqual(outcome.noteID, store.replayOutcome?.noteID)
    }

    // MARK: - 桩件

    /// 捕获写计划的 mining store 桩：commitCloze 记录 plan 并返回
    /// 固定 outcome；其余方法不承载本测试关注点。
    private final class StubClozeMiningStore: ReaderMiningStore,
        @unchecked Sendable {
        var clozePlans: [ReaderClozeMiningWritePlan] = []
        var replayOutcome: ReaderClozeMiningOutcome?

        func noteSummaries(
            ids: [UUID]
        ) async throws -> [ReaderLinkedNote] { [] }

        func findDuplicateVocabularyNotes(
            headword: String, reading: String?
        ) async throws -> [ReaderLinkedNote] { [] }

        func commit(
            _ plan: ReaderMiningWritePlan,
            currentGeneration: @Sendable () -> Int
        ) async throws -> ReaderMiningOutcome {
            throw ReaderMiningError.noteNotFound(UUID())
        }

        func commitCloze(
            _ plan: ReaderClozeMiningWritePlan,
            currentGeneration: @Sendable () -> Int
        ) async throws -> ReaderClozeMiningOutcome {
            clozePlans.append(plan)
            return replayOutcome ?? ReaderClozeMiningOutcome(
                noteID: plan.commit.noteID,
                cardCount: 1,
                wasReplayed: false
            )
        }
    }

    private final class StubKnowledgeRepository:
        VocabularyKnowledgeRepository, @unchecked Sendable {
        func state(
            lexemeID: UUID
        ) async throws -> VocabularyKnowledgeState { .unknown }
        func linkNote(
            lexemeID: UUID, noteID: UUID,
            origin: LexemeNoteLink.AssociationOrigin
        ) async throws {}
        func unlinkNote(lexemeID: UUID, noteID: UUID) async throws {}
        func fetchLexeme(key: LexicalKey) async throws -> Lexeme? { nil }
        func resolveLexeme(
            key: LexicalKey, seed: Lexeme
        ) async throws -> Lexeme { seed }
        func resolveLexemes(
            keys: [LexicalKey]
        ) async throws -> [LexicalKey: Lexeme] { [:] }
    }

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
        func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
            []
        }
        func entry(id: Int64) async throws -> DictionaryEntry? { nil }
        func sources() async throws -> [DictionarySourceInfo] { [] }
    }
}

/// 可变世代盒——@Sendable 闭包不捕获测试类 self。
private final class GenerationBox: @unchecked Sendable {
    var value = 7
}
