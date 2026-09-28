import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// v0.7.0 S14：sentence_cloze 卡穿过既有模板无关复习管线的端到端
/// 回归（设计 §9.3 + cloze-impact-review §4–§7）。
///
/// 断言矩阵：
/// - 队列/额度：新卡按 Note 级额度入 `daily_tasks`，多牌组不重复；
/// - payload：`cloze` 定义随行，正面遮罩句不泄题（含重复表记场景）；
/// - 正式评分：四档共用 SubmitReview——独立 FSRS 写、definition
///   不变、eventID 幂等、undo 全量恢复并回到队列；
/// - Custom Study：practiceOnly 零调度写（整行快照比对）+ 不写
///   review_logs；scheduled 走正式提交 + 同事务 origin 登记，且不需
///   daily_tasks 成员资格；
/// - 管理面：搜索/收藏/移动/牌组明细/整 Note 删除级联 + 历史锚点
///   `review_logs.card_key` 留存、单卡删除守卫。
final class GRDBClozeReviewIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_768_478_400)
    private let timeZoneID = "Asia/Shanghai"
    private let sentence = "彼は昨日映画を見た。"
    private let target = "見た"

    // MARK: - 队列与新学额度

    /// 新 cloze 卡经 `persistAndReconcileNewCards` 入队（category=.new，
    /// 模板无关），summary 的 newCount 按 Note 计数=1；停用后不再入队。
    func testClozeNewCardEntersTodayQueueAndConsumesNewQuota() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (noteID, cardID) = try await fixture.commitCloze(
            deckID: deck, at: now
        )

        let plan = try await fixture.buildPlan(at: now)

        let item = try XCTUnwrap(
            plan.availableNow.first { $0.cardID == cardID }
        )
        XCTAssertEqual(item.noteID, noteID)
        XCTAssertEqual(item.templateKind, .sentenceCloze)
        XCTAssertEqual(item.category, .new)
        XCTAssertEqual(item.deckIDs, [deck])
        XCTAssertEqual(plan.summary.newCount, 1)
        XCTAssertEqual(plan.summary.completedCount, 0)

        // 停用后重建队列：卡片消失、额度空出。
        try await fixture.setCardEnabled(cardID, false)
        let rebuilt = try await fixture.buildPlan(at: now.addingTimeInterval(1))
        XCTAssertFalse(rebuilt.availableNow.contains { $0.cardID == cardID })
        XCTAssertEqual(rebuilt.summary.newCount, 0)
    }

    /// 多牌组成员 Note 的 cloze 卡只入队一次；牌组 scope 过滤走
    /// `deckIDs` 成员关系——两个成员牌组各自看到它，非成员牌组看不到。
    func testMultiDeckMembershipDoesNotDuplicateQueueEntry() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deckA = try await fixture.addDeck()
        let deckB = try await fixture.addDeck()
        let outsider = try await fixture.addDeck()
        let (_, cardID) = try await fixture.commitCloze(
            deckID: deckA,
            deckIDs: [deckA, deckB],
            at: now
        )

        let plan = try await fixture.buildPlan(at: now)
        let matches = plan.availableNow.filter { $0.cardID == cardID }
        XCTAssertEqual(matches.count, 1, "多牌组不得重复入队")
        XCTAssertEqual(matches[0].deckIDs, [deckA, deckB])

        let studyDay = plan.studyDay
        let scopeA = try await fixture.queue.fetchSummary(
            for: studyDay, deckID: deckA, at: now
        )
        let scopeB = try await fixture.queue.fetchSummary(
            for: studyDay, deckID: deckB, at: now
        )
        let scopeOut = try await fixture.queue.fetchSummary(
            for: studyDay, deckID: outsider, at: now
        )
        XCTAssertEqual(scopeA.newCount, 1)
        XCTAssertEqual(scopeB.newCount, 1)
        XCTAssertEqual(scopeOut.newCount, 0)
    }

    // MARK: - 复习 payload 与正面不泄题

    /// `fetchReviewCardContent` 把 cloze 定义挂进 payload；正面渲染
    /// 路径（StudyCardView.questionText 的输入）得到的遮罩句不含答案，
    /// headword（原句快照）仅留给背面。
    func testReviewPayloadCarriesClozeAndMaskedPromptHidesAnswer() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (noteID, cardID) = try await fixture.commitCloze(
            deckID: deck,
            acceptedAnswers: ["見た", "みた"],
            hint: "过去式",
            at: now
        )

        let content = try await fixture.reviewContent
            .fetchReviewCardContent(cardID: cardID)
        let payload = try XCTUnwrap(content)
        XCTAssertEqual(payload.noteID, noteID)
        XCTAssertEqual(payload.templateKind, .sentenceCloze)
        XCTAssertEqual(payload.headword, sentence) // 原句只在背面出现
        XCTAssertEqual(payload.contentVersion, 1)
        let cloze = try XCTUnwrap(payload.cloze)
        XCTAssertEqual(cloze.sentenceSnapshot, sentence)
        XCTAssertEqual(cloze.targetSurface, target)
        XCTAssertEqual(cloze.targetReading, "みた")
        XCTAssertEqual(cloze.targetLemma, "見る")
        XCTAssertEqual(cloze.acceptedAnswers, ["見た", "みた"])
        XCTAssertEqual(cloze.hint, "过去式")
        XCTAssertFalse(cloze.sentenceSHA256.isEmpty)

        // 正面 prompt = maskedSentence：挖空位被占位符替换，答案不见。
        let prompt = ClozeValidator.maskedSentence(
            cloze.sentenceSnapshot,
            range: cloze.range,
            blank: String(repeating: "＿", count: max(cloze.targetSurface.count, 1))
        )
        // blank 宽度 = targetSurface.count（見た = 2 Character）。
        XCTAssertEqual(prompt, "彼は昨日映画を＿＿。")
        XCTAssertFalse(prompt.contains(target))
        XCTAssertFalse(prompt.contains("みた"))

        // RecallMode 恒为输入型；语音门关闭正面朗读。
        XCTAssertEqual(
            RecallMode.resolve(template: payload.templateKind, preferences: .defaults),
            .typedJapanese
        )
        let speech = ReviewSpeechPolicy(content: payload)
        XCTAssertFalse(speech.exposesJapaneseOnQuestion)
        XCTAssertNil(speech.listeningPromptText)
        XCTAssertTrue(speech.exposesPrimaryOnAnswer)
    }

    /// §9.2：句中同一表记出现多次时只遮所选那一处——其余出现位
    /// 保留原文（这正是“按 range 遮罩、不做全局替换”的语义）。
    func testMaskedSentenceBlanksOnlyTheSelectedOccurrence() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let duplicate = "猫が鳴いた、犬も鳴いた。"
        // 遮第二处「鳴いた」。
        let (noteID, cardID) = try await fixture.commitCloze(
            deckID: deck,
            sentence: duplicate,
            target: "鳴いた",
            occurrenceIndex: 1,
            at: now
        )

        let payload = try await fixture.reviewContent
            .fetchReviewCardContent(cardID: cardID)
        let cloze = try XCTUnwrap(payload?.cloze)
        XCTAssertEqual(cloze.noteID, noteID)
        let prompt = ClozeValidator.maskedSentence(
            cloze.sentenceSnapshot, range: cloze.range, blank: "＿＿＿"
        )
        XCTAssertEqual(prompt, "猫が鳴いた、犬も＿＿＿。")
        XCTAssertTrue(prompt.contains("鳴いた"), "未选中的出现位保持可见")

        // definition 缺失（损坏路径）→ 仓储拒绝加载而不是裸放原句。
        try await fixture.deleteClozeDefinitionRow(noteID: noteID)
        do {
            _ = try await fixture.reviewContent.fetchReviewCardContent(cardID: cardID)
            XCTFail("缺失 cloze 定义的 sentenceCloze 卡必须被拒绝")
        } catch {
            // 任意领域错误均可——关键是不返回泄题 payload。
        }
    }

    // MARK: - 正式评分（四档共用 SubmitReview）

    /// .normal 正式提交：cloze 卡写自己的 FSRS 行（stateVersion+1、
    /// firstStudiedAt 落地），同库兄弟词汇卡纹丝不动；
    /// cloze_definitions 行完全不变；eventID 重放返回同一日志。
    func testFormalReviewMutatesOnlyClozeCardSchedulingAndIsIdempotent() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (noteID, cardID) = try await fixture.commitCloze(
            deckID: deck, at: now
        )
        let siblingCardID = try await fixture.addVocabularyCard(
            deckID: deck, at: now
        )
        let plan = try await fixture.buildPlan(at: now)
        let submit = SubmitReview(
            repository: fixture.submission,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ClozeFixedClock(value: now)
        )
        let definitionBefore = try await fixture.clozes.fetchDefinition(noteID: noteID)
        let siblingBefore = try await fixture.scheduling.fetchCard(id: siblingCardID)
        let clozeBefore = try await fixture.scheduling.fetchCard(id: cardID)

        let eventID = UUID()
        let log = try await submit(
            SubmitReviewRequest(
                eventID: eventID, cardID: cardID,
                expectedStateVersion: 0, rating: .good,
                durationMilliseconds: 1_200,
                studyDay: plan.studyDay.context
            )
        )
        XCTAssertTrue(log.wasFirstStudy)
        XCTAssertEqual(log.cardKey, cardID)
        XCTAssertEqual(log.cardID, cardID)
        XCTAssertEqual(log.noteID, noteID)
        XCTAssertEqual(log.deckIDAtReview, deck)
        XCTAssertEqual(log.contentVersion, 1)
        XCTAssertEqual(log.previousState.scheduling, clozeBefore?.scheduling)
        XCTAssertEqual(log.nextState.stateVersion, 1)

        // cloze 卡独立 FSRS 状态推进；兄弟卡原样（独立 Card state）。
        let clozeAfter = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(clozeAfter?.stateVersion, 1)
        XCTAssertEqual(clozeAfter?.firstStudiedAt, now)
        XCTAssertNotEqual(clozeAfter?.scheduling.state, .new)
        let siblingAfter = try await fixture.scheduling.fetchCard(id: siblingCardID)
        XCTAssertEqual(siblingAfter, siblingBefore)
        // 评分不动内容层：definition 全字段不变。
        let definitionAfter = try await fixture.clozes.fetchDefinition(noteID: noteID)
        XCTAssertEqual(definitionAfter, definitionBefore)

        // eventID 幂等：重放返回同一日志，不产生第二条 review_log，
        // 卡也不再推进。
        let replayed = try await submit(
            SubmitReviewRequest(
                eventID: eventID, cardID: cardID,
                expectedStateVersion: 0, rating: .easy,
                durationMilliseconds: 9_999,
                studyDay: plan.studyDay.context
            )
        )
        XCTAssertEqual(replayed, log)
        let logCount = try await fixture.countRows("review_logs")
        XCTAssertEqual(logCount, 1)
        let cardAfterReplay = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(cardAfterReplay?.stateVersion, 1)
    }

    /// undo：FSRS 全字段 + firstStudiedAt + stateVersion 回到提交前
    /// 快照；卡重新出现在队列；二次撤销报 alreadyUndone。
    func testUndoRestoresFullPriorStateAndRepresentsCardInQueue() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (_, cardID) = try await fixture.commitCloze(deckID: deck, at: now)
        let plan = try await fixture.buildPlan(at: now)
        let submit = SubmitReview(
            repository: fixture.submission,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ClozeFixedClock(value: now)
        )
        let undo = UndoReview(
            repository: fixture.submission,
            clock: ClozeFixedClock(value: now.addingTimeInterval(60))
        )
        let before = try await fixture.scheduling.fetchCard(id: cardID)

        let log = try await submit(
            SubmitReviewRequest(
                eventID: UUID(), cardID: cardID,
                expectedStateVersion: 0, rating: .hard,
                durationMilliseconds: 800,
                studyDay: plan.studyDay.context
            )
        )
        // 提交后该卡退出剩余队列（state!=0 且 due 在未来）。
        let afterSubmit = try await fixture.queue.buildQueue(
            for: plan.studyDay, at: now
        )
        XCTAssertFalse(afterSubmit.availableNow.contains { $0.cardID == cardID })

        let undone = try await undo(
            UndoReviewRequest(eventID: log.eventID, studyDay: plan.studyDay.context)
        )
        XCTAssertEqual(undone.undoneAt, now.addingTimeInterval(60))
        let restoredCard = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(
            restoredCard,
            before,
            "撤销必须逐字段恢复完整调度快照"
        )

        // 回到队列（re-presentation），额度计数回到未学。
        let restored = try await fixture.queue.buildQueue(
            for: plan.studyDay, at: now.addingTimeInterval(60)
        )
        XCTAssertTrue(restored.availableNow.contains { $0.cardID == cardID })
        let summaryAfterUndo = try await fixture.queue.fetchSummary(
            for: plan.studyDay, deckID: nil, at: now.addingTimeInterval(60)
        )
        XCTAssertEqual(summaryAfterUndo.completedCount, 0)

        do {
            _ = try await undo(
                UndoReviewRequest(eventID: log.eventID, studyDay: plan.studyDay.context)
            )
            XCTFail("重复撤销必须拒绝")
        } catch {
            XCTAssertEqual(error as? UndoReviewError, .alreadyUndone)
        }
    }

    // MARK: - Custom Study 隔离

    /// practiceOnly：attempt 落 `practice_attempts`，但 Card 行逐字段
    /// 不变、review_logs 零行、definition 不动、队列位置原样。
    func testPracticeOnlyLeavesSchedulingUntouchedFieldByField() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (noteID, cardID) = try await fixture.commitCloze(deckID: deck, at: now)
        let plan = try await fixture.buildPlan(at: now)
        let session = try await fixture.makeSession(
            cardIDs: [cardID], mode: .practiceOnly
        )
        let cardBefore = try await fixture.scheduling.fetchCard(id: cardID)
        let definitionBefore = try await fixture.clozes.fetchDefinition(noteID: noteID)

        let attempt = PracticeAttempt(
            id: UUID(), eventID: UUID(), sessionID: session.id,
            cardKey: cardID, noteID: noteID, rating: .again,
            answeredAt: now, durationMilliseconds: 900,
            contentVersion: 1
        )
        try await fixture.custom.recordPracticeAttempt(attempt)

        let cardAfterAttempt = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(
            cardAfterAttempt,
            cardBefore,
            "practiceOnly 不得改任何调度字段"
        )
        let reviewLogCount = try await fixture.countRows("review_logs")
        XCTAssertEqual(reviewLogCount, 0)
        let definitionAfterAttempt = try await fixture.clozes
            .fetchDefinition(noteID: noteID)
        XCTAssertEqual(definitionAfterAttempt, definitionBefore)
        // 队列位置不变：practice 不消费新学预约。
        let afterPractice = try await fixture.queue.buildQueue(
            for: plan.studyDay, at: now.addingTimeInterval(1)
        )
        XCTAssertTrue(afterPractice.availableNow.contains { $0.cardID == cardID })
        let storedAttempt = try await fixture.custom
            .fetchAttempt(eventID: attempt.eventID)
        XCTAssertNil(storedAttempt?.undoneAt)

        // practice 撤销同样只标 undone_at，调度继续原样。
        let undoneAttempt = try await fixture.custom.undoPracticeAttempt(
            eventID: attempt.eventID, undoneAt: now.addingTimeInterval(120)
        )
        XCTAssertNotNil(undoneAttempt.undoneAt)
        let cardAfterUndo = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(cardAfterUndo, cardBefore)
        let reviewLogCountAfterUndo = try await fixture.countRows("review_logs")
        XCTAssertEqual(reviewLogCountAfterUndo, 0)
    }

    /// scheduled 专项：cloze 卡在没有 daily_tasks 成员资格的情况下
    /// 也能走正式提交（新学额度=0 已把 admission 关死），review_log
    /// 与 scheduled_review_origins 同事务落地。
    func testCustomScheduledSubmissionWithoutDailyTaskRecordsOrigin() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (_, cardID) = try await fixture.commitCloze(deckID: deck, at: now)
        // 学习日存在但额度为 0——cloze 卡没有任何 daily_tasks 行。
        _ = try await PrepareStudyDay(repository: fixture.planning)
            .setDailyNewCardLimit(0, at: now, defaultTimeZoneID: timeZoneID)
        let studyDayRow = try await fixture.planning.fetchStudyDay(containing: now)
        let studyDay = try XCTUnwrap(studyDayRow)
        let taskRows = try await fixture.dailyTaskRows(cardID: cardID)
        XCTAssertEqual(taskRows, 0)

        let session = try await fixture.makeSession(
            cardIDs: [cardID], mode: .scheduled
        )
        let submit = SubmitReview(
            repository: fixture.submission,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ClozeFixedClock(value: now)
        )
        let log = try await submit(
            SubmitReviewRequest(
                eventID: UUID(), cardID: cardID,
                expectedStateVersion: 0, rating: .easy,
                durationMilliseconds: 500,
                studyDay: studyDay.context,
                policy: .customScheduled(sessionID: session.id)
            )
        )
        XCTAssertTrue(log.wasFirstStudy)
        let origin = try await fixture.custom.fetchScheduledOrigin(eventID: log.eventID)
        XCTAssertEqual(
            origin,
            ScheduledReviewOrigin(eventID: log.eventID, sessionID: session.id)
        )
        let taskRowsAfter = try await fixture.dailyTaskRows(cardID: cardID)
        XCTAssertEqual(taskRowsAfter, 0)

        // 对照：同卡同策略但不在冻结队列 → 事务层拒绝。
        let other = try await fixture.commitCloze(
            deckID: deck, sentence: "別の文を書いた。", target: "書いた",
            at: now
        )
        let outsiderSession = try await fixture.makeSession(
            cardIDs: [cardID], mode: .scheduled
        )
        do {
            _ = try await submit(
                SubmitReviewRequest(
                    eventID: UUID(), cardID: other.cardID,
                    expectedStateVersion: 0, rating: .good,
                    durationMilliseconds: 500,
                    studyDay: studyDay.context,
                    policy: .customScheduled(sessionID: outsiderSession.id)
                )
            )
            XCTFail("冻结队列外的 cloze 卡必须被拒")
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                .cardNotInSessionQueue(
                    cardID: other.cardID,
                    sessionID: outsiderSession.id
                )
            )
        }
    }

    // MARK: - 管理面：删除级联 / 守卫 / 搜索 / 收藏 / 移动

    /// 整 Note 删除级联：cards、cloze_definitions、source_contexts、
    /// daily_tasks、note_decks 全部消失；review_logs 行保留但
    /// card_id 置空（card_key 锚点留存历史）。单卡删除仍被拒。
    func testDeleteNoteCascadesEverythingAndKeepsReviewHistory() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let noteID = UUID()
        let cardID = UUID()
        let sourceContext = SourceContext(
            id: UUID(), noteID: noteID, sourceType: .reader,
            originalSentence: sentence, surroundingText: nil,
            sourceTitle: "测试文档", sourceURL: nil, sourceApp: nil,
            imageReference: nil, dictionaryEntryID: nil,
            dictionaryVersion: nil, dictionarySenseKey: nil,
            selectedGlossLanguage: nil, isPrimary: true,
            createdAt: now,
            readerDocumentID: UUID(), readerChapterID: nil,
            readerLocation: nil, selectedSurface: target
        )
        let (committedNoteID, committedCardID) = try await fixture.commitCloze(
            deckID: deck,
            noteID: noteID, cardID: cardID,
            sourceContext: sourceContext,
            at: now
        )
        XCTAssertEqual(committedNoteID, noteID)
        XCTAssertEqual(committedCardID, cardID)
        let primarySource = try await fixture.sources.fetchPrimary(noteID: noteID)
        XCTAssertNotNil(primarySource)

        // 单卡删除守卫：cloze 卡不可脱离 Note 单独删。
        do {
            try await fixture.cards.deleteCard(cardID: cardID)
            XCTFail("sentence_cloze 卡必须拒绝单卡删除")
        } catch {
            XCTAssertEqual(
                error as? ContentCardError,
                .clozeDeletionRequiresNoteDelete
            )
        }

        // 先产出一条正式历史，再整 Note 删除。
        let plan = try await fixture.buildPlan(at: now)
        let submit = SubmitReview(
            repository: fixture.submission,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ClozeFixedClock(value: now)
        )
        let log = try await submit(
            SubmitReviewRequest(
                eventID: UUID(), cardID: cardID,
                expectedStateVersion: 0, rating: .good,
                durationMilliseconds: 700,
                studyDay: plan.studyDay.context
            )
        )

        let result = try await fixture.knowledge.deleteKnowledgePoint(noteID: noteID)
        XCTAssertEqual(
            result,
            .deleted(KnowledgePointDeletionImpact(cardCount: 1, reviewLogCount: 1))
        )
        for table in [
            "notes", "cards", "cloze_definitions",
            "source_contexts", "note_decks", "daily_tasks"
        ] {
            let remaining = try await fixture.countRows(
                table, noteID: noteID, cardID: cardID
            )
            XCTAssertEqual(remaining, 0, "\(table) 必须级联清空")
        }
        // review_logs 历史保留：card_id SET NULL，card_key 仍是原卡。
        let reviewLogCount = try await fixture.countRows("review_logs")
        XCTAssertEqual(reviewLogCount, 1)
        let stored = try await fixture.submission.fetchSubmittedReview(
            eventID: log.eventID
        )
        XCTAssertNil(stored?.cardID)
        XCTAssertEqual(stored?.cardKey, cardID)
        XCTAssertEqual(stored?.noteID, noteID)
    }

    /// 搜索索引、收藏、牌组明细与移动对 sentence Note 一视同仁。
    func testSearchFavoriteMoveAndDeckListingCoverSentenceNotes() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deckA = try await fixture.addDeck()
        let deckB = try await fixture.addDeck()
        let (noteID, cardID) = try await fixture.commitCloze(
            deckID: deckA,
            meaningZH: "我昨天看了电影。",
            at: now
        )

        // 搜索：normalized_headword 承载原句快照，LIKE 命中子串。
        let page = try await fixture.search.search(
            normalizedQuery: SearchTextNormalizer.normalize("映画"),
            deckID: nil, limit: 20, offset: 0
        )
        let hit = try XCTUnwrap(page.items.first { $0.id == noteID })
        XCTAssertEqual(hit.kind, .sentence)
        XCTAssertEqual(hit.headword, sentence)
        // deck scope 过滤走 note_decks。
        let scopedMiss = try await fixture.search.search(
            normalizedQuery: SearchTextNormalizer.normalize("映画"),
            deckID: deckB, limit: 20, offset: 0
        )
        XCTAssertFalse(scopedMiss.items.contains { $0.id == noteID })

        // 收藏。
        let favorited = try await fixture.knowledge.setFavorite(
            noteID: noteID, isFavorite: true, at: now
        )
        XCTAssertTrue(favorited)
        let favorites = try await fixture.knowledge.fetchFavoriteSummaries()
        XCTAssertTrue(favorites.contains { $0.id == noteID && $0.kind == .sentence })

        // 牌组明细列得出 sentence Note。
        let deckASummaries = try await fixture.knowledge
            .fetchKnowledgePointSummaries(deckID: deckA)
        XCTAssertTrue(deckASummaries.contains { $0.id == noteID })

        // 移动：成员关系折叠到 deckB，home 随行——A 的队列额度空出、
        // B 接管这条新卡（daily_tasks 行保留，scope 视图按成员关系算）。
        _ = try await fixture.buildPlan(at: now)
        let move = try await fixture.knowledge.moveKnowledgePoint(
            noteID: noteID, to: deckB, at: now.addingTimeInterval(30)
        )
        XCTAssertEqual(move, .moved(cardCount: 1))
        let deckBSummaries = try await fixture.knowledge
            .fetchKnowledgePointSummaries(deckID: deckB)
        XCTAssertTrue(deckBSummaries.contains { $0.id == noteID })
        let deckASummariesAfter = try await fixture.knowledge
            .fetchKnowledgePointSummaries(deckID: deckA)
        XCTAssertFalse(deckASummariesAfter.contains { $0.id == noteID })
        let studyDayRow = try await fixture.planning.fetchStudyDay(containing: now)
        let studyDay = try XCTUnwrap(studyDayRow)
        let scopeB = try await fixture.queue.fetchSummary(
            for: studyDay, deckID: deckB, at: now
        )
        let scopeA = try await fixture.queue.fetchSummary(
            for: studyDay, deckID: deckA, at: now
        )
        XCTAssertEqual(scopeB.newCount, 1)
        XCTAssertEqual(scopeA.newCount, 0)

        // 搜索跟着成员关系走：deckB 现在能搜到，deckA 搜不到。
        let scopedHit = try await fixture.search.search(
            normalizedQuery: SearchTextNormalizer.normalize("映画"),
            deckID: deckB, limit: 20, offset: 0
        )
        XCTAssertTrue(scopedHit.items.contains { $0.id == noteID })
        // 移动不改 Card 身份——同一张卡继续在队列与复习中流转。
        let movedCard = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(movedCard?.noteID, noteID)
    }

    /// S13→S14 衔接：编辑抬升 notes.content_version 后，复习 payload
    /// 立即反映新版本，Card 调度行不受编辑影响。
    func testClozeEditFlowsIntoReviewPayloadWithoutTouchingSchedule() async throws {
        let fixture = try await ClozeReviewFixture.make()
        defer { fixture.remove() }
        let deck = try await fixture.addDeck()
        let (noteID, cardID) = try await fixture.commitCloze(deckID: deck, at: now)
        let cardBefore = try await fixture.scheduling.fetchCard(id: cardID)

        _ = try await fixture.clozes.updateSentence(
            noteID: noteID,
            update: try SentenceContentUpdate(
                cloze: ValidatedClozeContent(
                    sentenceSnapshot: sentence,
                    utf16Start: ClozeValidator.surfaceRanges(
                        of: target, in: sentence
                    )[0].utf16Start,
                    utf16Length: ClozeValidator.surfaceRanges(
                        of: target, in: sentence
                    )[0].utf16Length,
                    targetSurface: target,
                    targetLemma: "見る",
                    targetReading: "みた",
                    acceptedAnswers: ["見た", "みた"],
                    hint: "过去式"
                ),
                meaningZH: "我昨天看了电影。",
                notes: nil,
                expectedContentVersion: 1
            ),
            at: now.addingTimeInterval(10)
        )

        let payload = try await fixture.reviewContent
            .fetchReviewCardContent(cardID: cardID)
        XCTAssertEqual(payload?.contentVersion, 2)
        XCTAssertEqual(payload?.cloze?.contentVersion, 2)
        XCTAssertEqual(payload?.cloze?.hint, "过去式")
        XCTAssertEqual(payload?.meaningZH, "我昨天看了电影。")
        let cardAfterEdit = try await fixture.scheduling.fetchCard(id: cardID)
        XCTAssertEqual(
            cardAfterEdit,
            cardBefore,
            "内容编辑不得触碰调度状态"
        )
    }
}

// MARK: - 夹具

private struct ClozeFixedClock: SchedulingClock {
    let value: Date
    func now() -> Date { value }
}

private final class ClozeReviewFixture: @unchecked Sendable {
    let directoryURL: URL
    let database: OboeDatabase
    let cards: GRDBContentCardRepository
    let scheduling: GRDBSchedulingCardRepository
    let reviewContent: GRDBReviewCardContentRepository
    let submission: GRDBReviewSubmissionRepository
    let queue: GRDBTodayQueueRepository
    let planning: GRDBStudyDayPlanningRepository
    let custom: GRDBCustomStudyRepository
    let search: GRDBKnowledgeSearchRepository
    let knowledge: GRDBKnowledgePointRepository
    let clozes: GRDBClozeRepository
    let sources: GRDBSourceContextRepository

    private init(directoryURL: URL, database: OboeDatabase) {
        self.directoryURL = directoryURL
        self.database = database
        cards = GRDBContentCardRepository(database: database)
        scheduling = GRDBSchedulingCardRepository(database: database)
        reviewContent = GRDBReviewCardContentRepository(database: database)
        submission = GRDBReviewSubmissionRepository(database: database)
        queue = GRDBTodayQueueRepository(database: database)
        planning = GRDBStudyDayPlanningRepository(database: database)
        custom = GRDBCustomStudyRepository(database: database)
        search = GRDBKnowledgeSearchRepository(database: database)
        knowledge = GRDBKnowledgePointRepository(database: database)
        clozes = GRDBClozeRepository(database: database)
        sources = GRDBSourceContextRepository(database: database)
    }

    static func make() async throws -> ClozeReviewFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Oboe-S14-Cloze-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        // v19 已注册时 GRDB 跳过；独立跑时补注册（与 commit 测试同策略）。
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v19_cloze", migrate: GRDBClozeSchema.migrate)
        try migrator.migrate(database.pool)
        return ClozeReviewFixture(directoryURL: directoryURL, database: database)
    }

    func addDeck() async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'S14', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
        return id
    }

    /// 真实 `commitSentence` 路径：Note + 卡 + definition 原子落库。
    @discardableResult
    func commitCloze(
        deckID: UUID,
        deckIDs: Set<UUID>? = nil,
        noteID: UUID = UUID(),
        cardID: UUID = UUID(),
        sentence: String = "彼は昨日映画を見た。",
        target: String = "見た",
        occurrenceIndex: Int = 0,
        // nil → [target]：acceptedAnswers 必须含 targetSurface。
        acceptedAnswers: [String]? = nil,
        hint: String? = nil,
        meaningZH: String? = nil,
        sourceContext: SourceContext? = nil,
        at createdAt: Date
    ) async throws -> (noteID: UUID, cardID: UUID) {
        let range = ClozeValidator.surfaceRanges(of: target, in: sentence)[occurrenceIndex]
        let commit = try SentenceContentCommit(
            noteID: noteID,
            clozeID: UUID(),
            deckID: deckID,
            cloze: ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: range.utf16Start,
                utf16Length: range.utf16Length,
                targetSurface: target,
                targetLemma: "見る",
                targetReading: "みた",
                acceptedAnswers: acceptedAnswers ?? [target],
                hint: hint
            ),
            card: NewCardSeed(id: cardID, templateKind: .sentenceCloze),
            schedulerProfileID: UUID(),
            createdAt: createdAt,
            meaningZH: meaningZH,
            origin: .reader,
            deckIDs: deckIDs,
            sourceContext: sourceContext
        )
        _ = try await cards.commitSentence(commit, capture: nil)
        return (noteID, cardID)
    }

    /// 兄弟词汇卡：同库对照组（调度行独立验证用）。profile 复用
    /// `commitSentence` 已建的 configured profile——configuration_version
    /// 有 UNIQUE 约束，不能重复插。
    func addVocabularyCard(deckID: UUID, at instant: Date) async throws -> UUID {
        let noteID = UUID()
        let cardID = UUID()
        let ms = try DatabaseValueCodec.encode(instant)
        try await database.pool.write { db in
            guard let profileIDValue: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM scheduler_profiles ORDER BY created_at_ms, id LIMIT 1"
            ) else {
                throw ClozeError.inconsistentCardLink
            }
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID), ms, ms
                ]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step,
                        state_version, first_studied_at_ms,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, 0, ?, NULL, 0, 0, 0, 0, 0, 0, 0, 0, NULL, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    CardTemplateKind.vocabularyJapaneseToChinese.rawValue,
                    ms,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    profileIDValue
                ]
            )
        }
        return cardID
    }

    /// PrepareStudyDay + buildQueue：等同 App 打开复习页的路径——
    /// 学习日创建与 new 卡 admission（daily_tasks）都在这一步完成。
    func buildPlan(at instant: Date) async throws -> TodayPlan {
        try await BuildTodayPlan(
            studyDayRepository: planning,
            queueRepository: queue
        )(at: instant, defaultTimeZoneID: "Asia/Shanghai")
    }

    func makeSession(
        cardIDs: [UUID],
        mode: CustomStudyMode
    ) async throws -> CustomStudySession {
        let session = try CustomStudyService().makeSession(
            filter: CustomStudyFilter(),
            queue: CustomStudyQueue.ordered(
                cardIDs: cardIDs, order: .due,
                randomSeed: nil, generatedAt: Date(timeIntervalSince1970: 1_768_478_400)
            ),
            mode: mode,
            now: Date(timeIntervalSince1970: 1_768_478_400)
        )
        try await custom.createSession(session)
        return session
    }

    func setCardEnabled(_ cardID: UUID, _ enabled: Bool) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = ? WHERE id = ?",
                arguments: [enabled, DatabaseValueCodec.encode(cardID)]
            )
            if !enabled {
                try db.execute(
                    sql: """
                        UPDATE daily_tasks
                        SET cancelled_at_ms = COALESCE(cancelled_at_ms, 1)
                        WHERE card_id = ? AND cancelled_at_ms IS NULL
                        """,
                    arguments: [DatabaseValueCodec.encode(cardID)]
                )
            }
        }
    }

    /// 删除 definition 行模拟损坏数据（fetchReviewCardContent 必须拒绝）。
    func deleteClozeDefinitionRow(noteID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM cloze_definitions WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
    }

    /// 行数统计：默认整表；给 noteID/cardID 时按相关列过滤
    /// （notes/notes 关联表各自取合适列）。
    func countRows(
        _ table: String,
        noteID: UUID? = nil,
        cardID: UUID? = nil
    ) async throws -> Int {
        try await database.pool.read { db in
            var sql = "SELECT COUNT(*) FROM \(table)"
            var arguments = StatementArguments()
            if let noteID, table == "notes" {
                sql += " WHERE id = ?"
                arguments = [DatabaseValueCodec.encode(noteID)]
            } else if let noteID, table == "note_decks" || table == "source_contexts" || table == "cloze_definitions" {
                sql += " WHERE note_id = ?"
                arguments = [DatabaseValueCodec.encode(noteID)]
            } else if let cardID, table == "cards" || table == "daily_tasks" {
                sql += " WHERE \(table == "cards" ? "id" : "card_id") = ?"
                arguments = [DatabaseValueCodec.encode(cardID)]
            }
            return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
        }
    }

    func dailyTaskRows(cardID: UUID) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM daily_tasks WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? 0
        }
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
