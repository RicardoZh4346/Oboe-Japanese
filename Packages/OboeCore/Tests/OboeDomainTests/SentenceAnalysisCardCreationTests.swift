import XCTest
@testable import OboeDomain

final class SentenceAnalysisCardCreationTests: XCTestCase {
    func testSelectedVocabularyAndGrammarReuseAnalysisDraftWithoutIncludingOtherItems() throws {
        let repository = RecordingSentenceAnalysisCardRepository()
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeSentenceAnalysisResult()
        let vocabularyID = result.items[1].id
        let grammarID = result.items[2].id

        let drafts = try service.makeDrafts(
            from: result,
            selectedItemIDs: [vocabularyID, grammarID]
        )

        XCTAssertEqual(drafts.map(\.id), [vocabularyID, grammarID])
        XCTAssertEqual(drafts.map(\.kind), [.vocabulary, .grammar])
        XCTAssertEqual(drafts.map(\.headword), ["行く", "～たことがある"])
        XCTAssertEqual(drafts.map(\.exampleJapanese), [result.sentence, result.sentence])
        XCTAssertEqual(drafts.map(\.exampleTranslationZH), [result.translationZH, result.translationZH])
    }

    func testOneInvalidDraftPreventsWholeBatchFromReachingRepository() async throws {
        let repository = RecordingSentenceAnalysisCardRepository()
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeSentenceAnalysisResult()
        var drafts = try service.makeDrafts(
            from: result,
            selectedItemIDs: Set(result.items[1...2].map(\.id))
        )
        drafts[1].meaningZH = ""

        do {
            _ = try await service.commit(deckID: UUID(), drafts: drafts)
            XCTFail("Expected validation to stop the entire batch")
        } catch {
            XCTAssertEqual(error as? GrammarValidationError, .meaningRequired)
        }
        let commitCount = await repository.commitCount()
        XCTAssertEqual(commitCount, 0)
    }

    func testValidBatchCommitsExactlyOnceWithTwoSelectedItems() async throws {
        let repository = RecordingSentenceAnalysisCardRepository()
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeSentenceAnalysisResult()
        let drafts = try service.makeDrafts(
            from: result,
            selectedItemIDs: Set(result.items[1...2].map(\.id))
        )

        let saved = try await service.commit(deckID: UUID(), drafts: drafts)

        XCTAssertEqual(saved.noteIDs.count, 2)
        // 词汇固定创建全部三方向 + 语法一张卡。
        XCTAssertEqual(saved.cardCount, VocabularyCardDirection.allCases.count + 1)
        let commitCount = await repository.commitCount()
        XCTAssertEqual(commitCount, 1)
        let itemKinds = await repository.lastItemKinds()
        XCTAssertEqual(itemKinds, [.vocabulary, .grammar])
    }

    /// T07: 批量建卡的成员集合透传——batch 与每个 commit 携带同一
    /// deckIDs（home ∈ members），仓库据此写全部 `note_decks` 行。
    func testCommitPropagatesMembershipDeckIDsToEveryItem() async throws {
        let repository = RecordingSentenceAnalysisCardRepository()
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeSentenceAnalysisResult()
        let drafts = try service.makeDrafts(
            from: result,
            selectedItemIDs: Set(result.items[1...2].map(\.id))
        )
        let home = UUID()
        let member = UUID()

        _ = try await service.commit(
            deckID: home,
            deckIDs: [home, member],
            drafts: drafts
        )

        let batch = await repository.lastBatch()
        XCTAssertEqual(batch?.deckIDs, [home, member])
        for item in batch?.items ?? [] {
            switch item {
            case let .vocabulary(commit):
                XCTAssertEqual(commit.deckID, home)
                XCTAssertEqual(commit.deckIDs, [home, member])
            case let .grammar(commit):
                XCTAssertEqual(commit.deckID, home)
                XCTAssertEqual(commit.deckIDs, [home, member])
            }
        }
    }

    /// deckIDs 缺省时保持单牌组语义：成员集合恰为 {home}。
    func testCommitWithoutDeckIDsKeepsSingleMembership() async throws {
        let repository = RecordingSentenceAnalysisCardRepository()
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeSentenceAnalysisResult()
        let drafts = try service.makeDrafts(
            from: result,
            selectedItemIDs: [result.items[1].id]
        )
        let home = UUID()

        _ = try await service.commit(deckID: home, drafts: drafts)

        let batch = await repository.lastBatch()
        XCTAssertEqual(batch?.deckIDs, [home])
    }

    func testSelectionAndDirectionGuardsAreEnforcedBeforePersistence() async throws {
        let repository = RecordingSentenceAnalysisCardRepository()
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeSentenceAnalysisResult()

        XCTAssertThrowsError(try service.makeDrafts(from: result, selectedItemIDs: [])) { error in
            XCTAssertEqual(error as? SentenceAnalysisCardCreationError, .selectionRequired)
        }
        XCTAssertThrowsError(try service.makeDrafts(from: result, selectedItemIDs: [UUID()])) { error in
            XCTAssertEqual(error as? SentenceAnalysisCardCreationError, .selectedItemNotFound)
        }

        // 方向字段仅作续编载荷兼容保留：即使旧载荷里方向为空，
        // 提交仍然固定创建全部三个方向。
        var vocabulary = try service.makeDrafts(
            from: result,
            selectedItemIDs: [result.items[1].id]
        )[0]
        vocabulary.vocabularyDirections = []
        let batch = try await service.commit(deckID: UUID(), drafts: [vocabulary])
        XCTAssertEqual(batch.cardCount, VocabularyCardDirection.allCases.count)
        let commitCount = await repository.commitCount()
        XCTAssertEqual(commitCount, 1)
    }
}

private actor RecordingSentenceAnalysisCardRepository: SentenceAnalysisCardRepository {
    private var commits: [SentenceAnalysisCardBatchCommit] = []

    func commitSentenceAnalysisCards(
        _ batch: SentenceAnalysisCardBatchCommit,
        capture: CaptureCommitContext?
    ) async throws -> SentenceAnalysisCardBatchResult {
        commits.append(batch)
        return SentenceAnalysisCardBatchResult(
            noteIDs: batch.items.map(\.noteID),
            cardCount: batch.items.reduce(0) { $0 + $1.cardCount }
        )
    }

    func commitCount() -> Int {
        commits.count
    }

    func lastBatch() -> SentenceAnalysisCardBatchCommit? {
        commits.last
    }

    func lastItemKinds() -> [KnowledgePointKind] {
        (commits.last?.items ?? []).map { item in
            switch item {
            case .vocabulary: .vocabulary
            case .grammar: .grammar
            }
        }
    }
}

private func makeSentenceAnalysisResult() -> SentenceAnalysisResult {
    let sentence = "日本に行ったことがありますか。"
    return SentenceAnalysisResult(
        promptVersion: SentenceAnalysisPromptV2.promptVersion,
        schemaVersion: SentenceAnalysisPromptV2.schemaVersion,
        sentence: sentence,
        translationZH: "你去过日本吗？",
        explanationZH: "询问是否有去日本的经历。",
        items: [
            SentenceAnalysisItem(
                id: UUID(), kind: .particle, surface: "に", canonicalForm: "に", reading: "に",
                meaningZH: "表示目的地", roleZH: "格助词", spans: [], suggestedCard: nil
            ),
            SentenceAnalysisItem(
                id: UUID(), kind: .vocabulary, surface: "行っ", canonicalForm: "行く", reading: "いく",
                meaningZH: "去", roleZH: "动词「行く」的促音便", spans: [],
                suggestedCard: SentenceAnalysisSuggestedCard(
                    kind: .vocabulary, headword: "行く", reading: "いく", meaningZH: "去",
                    partOfSpeech: "五段动词", usage: "", connection: "", notes: ""
                )
            ),
            SentenceAnalysisItem(
                id: UUID(), kind: .grammar, surface: "たことがあります", canonicalForm: "～たことがある",
                reading: "", meaningZH: "曾经……过", roleZH: "表示过去经历", spans: [],
                suggestedCard: SentenceAnalysisSuggestedCard(
                    kind: .grammar, headword: "～たことがある", reading: "", meaningZH: "曾经……过",
                    partOfSpeech: "", usage: "表示过去的经历", connection: "动词た形＋ことがある", notes: ""
                )
            ),
            SentenceAnalysisItem(
                id: UUID(), kind: .expression, surface: "ありますか", canonicalForm: "ありますか",
                reading: "", meaningZH: "有吗", roleZH: "礼貌疑问表达", spans: [], suggestedCard: nil
            )
        ],
        warnings: []
    )
}
