import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

final class GRDBStudySessionServiceTests: XCTestCase {
    func testReviewContentMapsAllThreeTypedTemplates() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let vocabularyNote = try await fixture.addVocabularyNote()
        let grammarNote = try await fixture.addGrammarNote()
        let japaneseToChinese = try await fixture.addCard(
            noteID: vocabularyNote,
            template: .vocabularyJapaneseToChinese
        )
        let chineseToJapanese = try await fixture.addCard(
            noteID: vocabularyNote,
            template: .vocabularyChineseToJapanese
        )
        let grammar = try await fixture.addCard(
            noteID: grammarNote,
            template: .grammarFormToExplanation
        )
        let repository = GRDBReviewCardContentRepository(database: fixture.database)

        let fetchedForward = try await repository.fetchReviewCardContent(cardID: japaneseToChinese)
        let forward = try XCTUnwrap(fetchedForward)
        XCTAssertEqual(forward.templateKind, .vocabularyJapaneseToChinese)
        XCTAssertEqual(forward.headword, "食べる")
        XCTAssertEqual(forward.reading, "たべる")
        XCTAssertEqual(forward.meaningZH, "吃")
        XCTAssertEqual(forward.partOfSpeech, "动词")
        XCTAssertEqual(forward.exampleJapanese, "魚を食べる。")
        XCTAssertEqual(forward.exampleTranslationZH, "吃鱼。")

        let fetchedReverse = try await repository.fetchReviewCardContent(cardID: chineseToJapanese)
        let reverse = try XCTUnwrap(fetchedReverse)
        XCTAssertEqual(reverse.templateKind, .vocabularyChineseToJapanese)
        XCTAssertEqual(reverse.noteID, forward.noteID)

        let fetchedGrammar = try await repository.fetchReviewCardContent(cardID: grammar)
        let grammarContent = try XCTUnwrap(fetchedGrammar)
        XCTAssertEqual(grammarContent.templateKind, .grammarFormToExplanation)
        XCTAssertEqual(grammarContent.headword, "〜たことがある")
        XCTAssertEqual(grammarContent.connection, "动词た形")
        XCTAssertEqual(grammarContent.usage, "表示过去的经历")

        try await fixture.setEnabled(false, cardID: grammar)
        let disabled = try await repository.fetchReviewCardContent(cardID: grammar)
        XCTAssertNil(disabled)
    }

    func testReviewReloadCarriesNoteContentVersionWithoutChangingScheduling() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteID = try await fixture.addVocabularyNote()
        let cardID = try await fixture.addCard(noteID: noteID, template: .vocabularyChineseToJapanese)
        let service = fixture.makeService()
        _ = try await service.buildTodayPlan(defaultTimeZoneID: "Asia/Shanghai")
        let original = try await service.loadReviewCard(cardID: cardID)
        XCTAssertEqual(original.content.contentVersion, 1)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET content_version = content_version + 1, meaning_zh = ? WHERE id = ?",
                arguments: ["吃；食用", DatabaseValueCodec.encode(noteID)]
            )
        }
        let reloaded = try await service.loadReviewCard(cardID: cardID)
        XCTAssertEqual(reloaded.content.contentVersion, 2)
        XCTAssertEqual(reloaded.content.meaningZH, "吃；食用")
        XCTAssertEqual(reloaded.stateVersion, original.stateVersion)
        let logs = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs")
        }
        XCTAssertEqual(logs, 0)
    }

    func testManualCardPlanPreviewSubmitAndReopenCompletesRealFlow() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteID = try await fixture.addVocabularyNote()
        let cardID = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese
        )
        let service = fixture.makeService()

        let initialPlan = try await service.buildTodayPlan(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(initialPlan.availableNow.map(\.cardID), [cardID])
        XCTAssertEqual(initialPlan.summary.newCount, 1)

        let card = try await service.loadReviewCard(cardID: cardID)
        XCTAssertEqual(card.content.headword, "食べる")
        XCTAssertEqual(card.stateVersion, 0)
        XCTAssertEqual(Set(ReviewRating.allCases.map { card.choices[$0].rating }), Set(ReviewRating.allCases))

        _ = try await service.submit(
            card: card,
            rating: .easy,
            studyDay: initialPlan.studyDay,
            eventID: UUID(),
            durationMilliseconds: 800
        )
        let completedPlan = try await service.buildTodayPlan(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertTrue(completedPlan.availableNow.isEmpty)
        XCTAssertTrue(completedPlan.availableLater.isEmpty)
        XCTAssertEqual(completedPlan.summary.completedCount, 1)
        XCTAssertTrue(completedPlan.isDayComplete)

        try fixture.database.close()
        let reopened = try OboeDatabase(path: fixture.databaseURL.path)
        let reopenedService = fixture.makeService(database: reopened)
        let reopenedPlan = try await reopenedService.buildTodayPlan(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(reopenedPlan.summary, completedPlan.summary)
        XCTAssertTrue(reopenedPlan.isDayComplete)
        try reopened.close()
    }

    func testFetchScopeSummarySeparatesDeckProgressFromGlobal() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let deckB = try await fixture.addDeck()
        let noteA = try await fixture.addVocabularyNote()
        let cardA = try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyJapaneseToChinese
        )
        let noteB = try await fixture.addVocabularyNote(deckID: deckB)
        let cardB = try await fixture.addCard(
            noteID: noteB,
            template: .vocabularyJapaneseToChinese
        )
        let service = fixture.makeService()

        let plan = try await service.buildTodayPlan(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(Set(plan.availableNow.map(\.cardID)), [cardA, cardB])

        let beforeA = try await service.fetchScopeSummary(
            studyDay: plan.studyDay, deckID: fixture.deckID
        )
        XCTAssertEqual(beforeA.remainingCount, 1)
        XCTAssertEqual(beforeA.completedCount, 0)

        let card = try await service.loadReviewCard(cardID: cardA)
        _ = try await service.submit(
            card: card,
            rating: .easy,
            studyDay: plan.studyDay,
            eventID: UUID(),
            durationMilliseconds: 600
        )

        let afterA = try await service.fetchScopeSummary(
            studyDay: plan.studyDay, deckID: fixture.deckID
        )
        XCTAssertEqual(afterA.remainingCount, 0)
        XCTAssertEqual(afterA.completedCount, 1)
        let afterB = try await service.fetchScopeSummary(
            studyDay: plan.studyDay, deckID: deckB
        )
        XCTAssertEqual(afterB.remainingCount, 1)
        XCTAssertEqual(afterB.completedCount, 0)
        let global = try await service.fetchScopeSummary(
            studyDay: plan.studyDay, deckID: nil
        )
        XCTAssertEqual(global.remainingCount, 1)
        XCTAssertEqual(global.completedCount, 1)
    }

    // MARK: - T22 会话回归矩阵

    func testAgainOnNewCardMovesToLaterAndReturnsAfterDueAt() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteA = try await fixture.addVocabularyNote()
        let cardA = try await fixture.addCard(
            noteID: noteA, template: .vocabularyJapaneseToChinese
        )
        let noteB = try await fixture.addVocabularyNote()
        let cardB = try await fixture.addCard(
            noteID: noteB, template: .vocabularyJapaneseToChinese
        )
        let driver = try await fixture.makeDriver()

        // Again on a fresh card enters learning step 0 (+1m) — future due.
        let loaded = try await fixture.service.loadReviewCard(cardID: cardA)
        let expected = loaded.choices[.again].card
        let log = try await driver.submit(card: loaded, rating: .again)
        XCTAssertEqual(log.nextState.scheduling, expected)
        XCTAssertEqual(log.nextState.scheduling.state, .learning)
        XCTAssertEqual(
            log.nextState.scheduling.dueAt.timeIntervalSince(fixture.now),
            60, accuracy: 0.5
        )

        // Not yet due: parked in availableLater, never re-presented; the
        // wake-up time is the earliest real dueAt.
        try await driver.refresh()
        XCTAssertFalse(driver.nowCardIDs.contains(cardA))
        XCTAssertEqual(driver.laterCardIDs, [cardA])
        XCTAssertEqual(
            driver.plan.nextAvailableAt?.timeIntervalSince(fixture.now) ?? -1,
            60, accuracy: 0.5
        )
        XCTAssertEqual(driver.plan.summary.learningCount, 1)
        XCTAssertEqual(driver.plan.summary.newCount, 1)
        XCTAssertTrue(driver.nowCardIDs.contains(cardB))

        // Once due, the learning card is admitted back into availableNow.
        fixture.clock.advance(by: 61)
        try await driver.refresh()
        XCTAssertEqual(driver.nowItem(for: cardA)?.category, .learning)
        XCTAssertTrue(driver.laterCardIDs.isEmpty)
    }

    func testLearningCardGraduatesThroughStepsThenLeavesQueue() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteID = try await fixture.addVocabularyNote()
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        let driver = try await fixture.makeDriver()

        // Good on a new card advances to learning step 1 (+10m).
        var loaded = try await fixture.service.loadReviewCard(cardID: cardID)
        var log = try await driver.submit(card: loaded, rating: .good)
        XCTAssertEqual(log.nextState.scheduling.state, .learning)
        XCTAssertEqual(log.nextState.scheduling.learningStep, 1)
        try await driver.refresh()
        XCTAssertFalse(driver.nowCardIDs.contains(cardID))

        fixture.clock.advance(by: 601)
        try await driver.refresh()
        XCTAssertEqual(driver.nowItem(for: cardID)?.category, .learning)

        // Good on the last step graduates to review with a multi-day due —
        // beyond the study-day end, so the card leaves the queue entirely.
        loaded = try await fixture.service.loadReviewCard(cardID: cardID)
        log = try await driver.submit(card: loaded, rating: .good)
        XCTAssertEqual(log.nextState.scheduling.state, .review)
        XCTAssertGreaterThan(log.nextState.scheduling.dueAt, driver.plan.studyDay.endsAt)
        try await driver.refresh()
        XCTAssertFalse(driver.nowCardIDs.contains(cardID))
        XCTAssertFalse(driver.laterCardIDs.contains(cardID))
        XCTAssertTrue(driver.plan.isDayComplete)
    }

    func testAgainOnReviewCardEntersRelearningAndRecovers() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteID = try await fixture.addVocabularyNote()
        let cardID = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(
                dueAt: fixture.now,
                stability: 20,
                difficulty: 5,
                scheduledDays: 20,
                repetitions: 10,
                lapses: 1,
                state: .review,
                lastReviewAt: fixture.now.addingTimeInterval(-30 * 86_400)
            ),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )
        let driver = try await fixture.makeDriver()
        XCTAssertEqual(driver.nowItem(for: cardID)?.category, .review)

        // Again on a review card enters relearning (+10m), lapse recorded.
        var loaded = try await fixture.service.loadReviewCard(cardID: cardID)
        var log = try await driver.submit(card: loaded, rating: .again)
        XCTAssertEqual(log.nextState.scheduling.state, .relearning)
        XCTAssertEqual(
            log.nextState.scheduling.dueAt.timeIntervalSince(fixture.now),
            600, accuracy: 0.5
        )
        XCTAssertEqual(log.nextState.scheduling.lapses, 2)
        try await driver.refresh()
        XCTAssertTrue(driver.laterCardIDs.contains(cardID))
        XCTAssertFalse(driver.nowCardIDs.contains(cardID))

        // After the step elapses it returns as relearning, then graduates.
        fixture.clock.advance(by: 601)
        try await driver.refresh()
        XCTAssertEqual(driver.nowItem(for: cardID)?.category, .relearning)
        loaded = try await fixture.service.loadReviewCard(cardID: cardID)
        log = try await driver.submit(card: loaded, rating: .good)
        XCTAssertEqual(log.nextState.scheduling.state, .review)
        try await driver.refresh()
        XCTAssertFalse(driver.nowCardIDs.contains(cardID))
        XCTAssertFalse(driver.laterCardIDs.contains(cardID))
    }

    func testSessionLoopSeparatesSameNoteThreeDirectionsAcrossRefreshes() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let base = fixture.now
        let noteA = try await fixture.addVocabularyNote()
        // Admission orders new cards by dueAt — pin the order so the queue
        // reads A1, A2, B1, A3 and the second pick is a same-note conflict.
        let cardA1 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(dueAt: base.addingTimeInterval(-400)),
            firstStudiedAt: nil
        )
        let cardA2 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyChineseToJapanese,
            scheduling: SchedulingCard(dueAt: base.addingTimeInterval(-300)),
            firstStudiedAt: nil
        )
        let noteB = try await fixture.addVocabularyNote()
        let cardB1 = try await fixture.addCard(
            noteID: noteB, template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(dueAt: base.addingTimeInterval(-200)),
            firstStudiedAt: nil
        )
        let cardA3 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyListening,
            scheduling: SchedulingCard(dueAt: base.addingTimeInterval(-100)),
            firstStudiedAt: nil
        )
        let driver = try await fixture.makeDriver()
        // 按词收录：note A 的三个方向作为一组连续入队，note B 在后。
        XCTAssertEqual(driver.plan.availableNow.map(\.cardID),
                       [cardA1, cardA2, cardA3, cardB1])

        // Drive the whole session through the policy: every presented card
        // is submitted Easy (graduates, drains the queue) and the plan is
        // rebuilt between picks exactly like the real session.
        var presentedCards: [UUID] = []
        while let item = try await driver.presentNext() {
            presentedCards.append(item.cardID)
            let loaded = try await fixture.service.loadReviewCard(cardID: item.cardID)
            let log = try await driver.submit(card: loaded, rating: .easy)
            // Baseline: submitted snapshot is exactly the previewed choice.
            XCTAssertEqual(log.nextState.scheduling, loaded.choices[.easy].card)
        }
        // A2 conflicts with last-presented note A and defers once to B1;
        // the debt is repaid immediately after, then A3 presents normally.
        XCTAssertEqual(presentedCards, [cardA1, cardB1, cardA2, cardA3])
        XCTAssertTrue(driver.plan.isDayComplete)
    }

    func testRelearningSiblingYieldsAtMostOnceThenIsRepaid() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let base = fixture.now
        let noteA = try await fixture.addVocabularyNote()
        // A1 learning due first, A2 relearning due second — both priority 0.
        let cardA1 = try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(
                dueAt: base,
                stability: 0.5,
                difficulty: 6,
                learningStep: 1,
                repetitions: 1,
                state: .learning,
                lastReviewAt: base.addingTimeInterval(-600)
            ),
            firstStudiedAt: base.addingTimeInterval(-86_400)
        )
        let cardA2 = try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyChineseToJapanese,
            scheduling: SchedulingCard(
                dueAt: base.addingTimeInterval(30),
                stability: 2,
                difficulty: 7,
                repetitions: 6,
                lapses: 2,
                state: .relearning,
                lastReviewAt: base.addingTimeInterval(-300)
            ),
            firstStudiedAt: base.addingTimeInterval(-86_400)
        )
        let noteB = try await fixture.addVocabularyNote()
        let cardB1 = try await fixture.addCard(
            noteID: noteB,
            template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(
                dueAt: base.addingTimeInterval(60),
                stability: 0.5,
                difficulty: 6,
                learningStep: 1,
                repetitions: 1,
                state: .learning,
                lastReviewAt: base.addingTimeInterval(-600)
            ),
            firstStudiedAt: base.addingTimeInterval(-86_400)
        )
        let driver = try await fixture.makeDriver()
        // Cards due at/after `now` are due within the day — but A2/B1 are
        // future-due relative to `now`, so they park in later until due.
        // Advance so all three are now-eligible.
        fixture.clock.advance(by: 61)
        try await driver.refresh()
        XCTAssertEqual(driver.plan.availableNow.map(\.cardID), [cardA1, cardA2, cardB1])

        // Present A1 (note A) and submit — the queue rebuilds to [A2, B1].
        // A2 is the relearning sibling at queue head: it yields exactly once
        // to B1, then is repaid on the next pick even though presenting it
        // recreates a same-note adjacency debt-free.
        let first = try await driver.presentNext()
        XCTAssertEqual(first?.cardID, cardA1)
        let loadedA1 = try await fixture.service.loadReviewCard(cardID: cardA1)
        _ = try await driver.submit(card: loadedA1, rating: .easy)
        XCTAssertEqual(driver.plan.availableNow.map(\.cardID), [cardA2, cardB1])

        let second = try await driver.presentNext()
        XCTAssertEqual(second?.cardID, cardB1, "A2 yields exactly once to the other note")
        let loadedB1 = try await fixture.service.loadReviewCard(cardID: cardB1)
        _ = try await driver.submit(card: loadedB1, rating: .easy)

        let third = try await driver.presentNext()
        XCTAssertEqual(third?.cardID, cardA2, "debt repaid on the next pick — at most one deferral")
    }

    func testUnadmittedNewCardBeyondDailyLimitCannotBeSpacer() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        // 按词计额度：limit 1 只收录 note A（其两个方向一起入队）；note B
        // 的词未占名额，其方向卡绝不能当同笔记间隔卡。
        _ = try await fixture.service.setDailyNewCardLimit(
            1, defaultTimeZoneID: "Asia/Shanghai"
        )
        let noteA = try await fixture.addVocabularyNote()
        let cardA1 = try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(dueAt: fixture.now.addingTimeInterval(-200)),
            firstStudiedAt: nil
        )
        let cardA2 = try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyChineseToJapanese,
            scheduling: SchedulingCard(dueAt: fixture.now.addingTimeInterval(-100)),
            firstStudiedAt: nil
        )
        let noteB = try await fixture.addVocabularyNote()
        let cardB1 = try await fixture.addCard(
            noteID: noteB,
            template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(dueAt: fixture.now),
            firstStudiedAt: nil
        )
        let driver = try await fixture.makeDriver()

        // B1 所属的词未占名额：不出现在 now/later/汇总。
        XCTAssertEqual(Set(driver.plan.availableNow.map(\.cardID)), [cardA1, cardA2])
        XCTAssertFalse(driver.laterCardIDs.contains(cardB1))
        XCTAssertEqual(driver.plan.summary.newCount, 1)

        // A1 提交后，A2 是同笔记冲突且没有其他已收录词可间隔——直接呈现，
        // 绝不会饿死在从未收录的 B1 后面。
        let first = try await driver.presentNext()
        XCTAssertEqual(first?.cardID, cardA1)
        let loaded = try await fixture.service.loadReviewCard(cardID: cardA1)
        _ = try await driver.submit(card: loaded, rating: .easy)
        let second = try await driver.presentNext()
        XCTAssertEqual(second?.cardID, cardA2)
        let loadedA2 = try await fixture.service.loadReviewCard(cardID: cardA2)
        _ = try await driver.submit(card: loadedA2, rating: .easy)
        let exhausted = try await driver.presentNext()
        XCTAssertNil(exhausted)
    }

    func testStudyDayRolloverAtFourAMRebuildsQueueAndKeepsHistory() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteA = try await fixture.addVocabularyNote()
        let cardA1 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyJapaneseToChinese
        )
        let cardA2 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyChineseToJapanese
        )
        // 03:30 on 9/11 still belongs to study day 9/10.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        fixture.clock.set(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 9, day: 11,
            hour: 3, minute: 30
        ))!)
        let driver = try await fixture.makeDriver()
        let dayOne = driver.plan.studyDay
        XCTAssertEqual(dayOne.localDate, "2026-09-10")

        let loaded = try await fixture.service.loadReviewCard(cardID: cardA1)
        let log = try await driver.submit(card: loaded, rating: .easy)
        XCTAssertEqual(log.studyDayID, dayOne.id)
        let dueAfterEasy = log.nextState.scheduling.dueAt

        // Past 04:00 the queue rebuilds under a new study day; yesterday's
        // log and snapshot are untouched, the unrated sibling re-admits.
        fixture.clock.set(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 9, day: 11,
            hour: 4, minute: 30
        ))!)
        try await driver.refresh()
        let dayTwo = driver.plan.studyDay
        XCTAssertEqual(dayTwo.localDate, "2026-09-11")
        XCTAssertNotEqual(dayTwo.id, dayOne.id)
        XCTAssertEqual(driver.plan.availableNow.map(\.cardID), [cardA2])
        XCTAssertEqual(driver.plan.summary.newCount, 1)
        XCTAssertEqual(driver.plan.summary.completedCount, 0)
        let snapshot = try await fixture.fetchCardSnapshot(cardID: cardA1)
        XCTAssertEqual(
            snapshot.dueAt.timeIntervalSince(dueAfterEasy), 0, accuracy: 0.001
        )
        XCTAssertEqual(snapshot.state, log.nextState.scheduling.state)
        XCTAssertEqual(snapshot.stability, log.nextState.scheduling.stability, accuracy: 1e-8)
        XCTAssertEqual(snapshot.repetitions, log.nextState.scheduling.repetitions)
        let logCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs")
        }
        XCTAssertEqual(logCount, 1)
    }

    func testSuspendAndReEnableRemovesAndRestoresCardInSession() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteA = try await fixture.addVocabularyNote()
        let cardA = try await fixture.addCard(
            noteID: noteA, template: .vocabularyJapaneseToChinese
        )
        let noteB = try await fixture.addVocabularyNote()
        let cardB = try await fixture.addCard(
            noteID: noteB, template: .vocabularyJapaneseToChinese
        )
        let driver = try await fixture.makeDriver()
        XCTAssertEqual(Set(driver.plan.availableNow.map(\.cardID)), [cardA, cardB])

        // Suspending cancels the admission and removes the card from both
        // lists — it can never be selected while disabled.
        try await fixture.setEnabled(false, cardID: cardA)
        try await driver.refresh()
        XCTAssertEqual(driver.plan.availableNow.map(\.cardID), [cardB])
        XCTAssertFalse(driver.laterCardIDs.contains(cardA))
        XCTAssertEqual(driver.plan.summary.newCount, 1)

        // Re-enabling restores the same-day admission (uncancel path).
        try await fixture.setEnabled(true, cardID: cardA)
        try await driver.refresh()
        XCTAssertEqual(Set(driver.plan.availableNow.map(\.cardID)), [cardA, cardB])
        let loaded = try await fixture.service.loadReviewCard(cardID: cardA)
        let log = try await driver.submit(card: loaded, rating: .easy)
        XCTAssertEqual(log.nextState.scheduling.state, .review)
    }

    func testAllFourRatingsPersistExactlyThePreviewedSnapshots() async throws {
        for rating in ReviewRating.allCases {
            let fixture = try await StudySessionFixture.make()
            defer { fixture.remove() }
            let noteID = try await fixture.addVocabularyNote()
            let cardID = try await fixture.addCard(
                noteID: noteID, template: .vocabularyJapaneseToChinese
            )
            let driver = try await fixture.makeDriver()
            let loaded = try await fixture.service.loadReviewCard(cardID: cardID)
            let expected = loaded.choices[rating].card
            let log = try await driver.submit(
                card: loaded, rating: rating, eventID: UUID()
            )
            XCTAssertEqual(
                log.nextState.scheduling, expected,
                "\(rating): submitted snapshot must equal the previewed choice"
            )
            let persisted = try await fixture.fetchCardSnapshot(cardID: cardID)
            XCTAssertEqual(persisted, expected, "\(rating): persisted card state")
        }
    }

    func testDuplicateEventIDInsideSessionWritesOneLogAndKeepsState() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        let noteID = try await fixture.addVocabularyNote()
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        let driver = try await fixture.makeDriver()
        let loaded = try await fixture.service.loadReviewCard(cardID: cardID)
        let eventID = UUID()
        let first = try await driver.submit(card: loaded, rating: .easy, eventID: eventID)
        // A retry with the same event returns the original log — no second
        // row, no state drift.
        let second = try await driver.submit(
            card: loaded, rating: .good, eventID: eventID
        )
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.rating, .easy)
        let logCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs")
        }
        XCTAssertEqual(logCount, 1)
        let persisted = try await fixture.fetchCardSnapshot(cardID: cardID)
        XCTAssertEqual(persisted, first.nextState.scheduling)
    }

    func testUndoInsideSessionRestoresCardAndQueueWithBaselineSnapshot() async throws {
        let fixture = try await StudySessionFixture.make()
        defer { fixture.remove() }
        // Pin admission order by dueAt so A1 is deterministically the head.
        let noteA = try await fixture.addVocabularyNote()
        let cardA1 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(dueAt: fixture.now.addingTimeInterval(-300)),
            firstStudiedAt: nil
        )
        let cardA2 = try await fixture.addCard(
            noteID: noteA, template: .vocabularyChineseToJapanese,
            scheduling: SchedulingCard(dueAt: fixture.now.addingTimeInterval(-200)),
            firstStudiedAt: nil
        )
        let noteB = try await fixture.addVocabularyNote()
        let cardB1 = try await fixture.addCard(
            noteID: noteB, template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(dueAt: fixture.now.addingTimeInterval(-100)),
            firstStudiedAt: nil
        )
        let driver = try await fixture.makeDriver()
        let baseline = try await fixture.fetchCardSnapshot(cardID: cardA1)

        // Present A1, submit, then undo — the card returns to the queue and
        // is re-presented first (undo priority clears the sibling debt).
        let first = try await driver.presentNext()
        XCTAssertEqual(first?.cardID, cardA1)
        let loaded = try await fixture.service.loadReviewCard(cardID: cardA1)
        let log = try await driver.submit(card: loaded, rating: .easy)
        try await driver.undo(eventID: log.eventID)

        let restored = try await fixture.fetchCardSnapshot(cardID: cardA1)
        XCTAssertEqual(restored, baseline)
        try await driver.refresh()
        XCTAssertEqual(Set(driver.plan.availableNow.map(\.cardID)),
                       [cardA1, cardA2, cardB1])
        let rePresented = try await driver.presentNext()
        XCTAssertEqual(rePresented?.cardID, cardA1,
                       "undone card re-presents ahead of sibling separation")
    }
}

/// T22 session driver: mirrors `ReviewViewModel`'s selection loop over the
/// real `StudySessionService` — deck-scope filter, session skip set, undo
/// priority, then the pure sibling-selection policy with carried debt.
/// Every pick is followed by a real load; submissions rebuild the plan
/// exactly like the UI session (no next-card caching).
private final class SessionDriver {
    let service: StudySessionService
    let defaultTimeZoneID: String
    var deckScope: UUID?
    private(set) var plan: TodayPlan
    private(set) var lastPresentedNoteID: UUID?
    private var deferredCardID: UUID?
    private var undoPreferredCardID: UUID?
    private var skippedCardIDs: Set<UUID> = []

    init(service: StudySessionService, plan: TodayPlan, deckScope: UUID? = nil, timeZoneID: String = "Asia/Shanghai") {
        self.service = service
        self.plan = plan
        self.deckScope = deckScope
        self.defaultTimeZoneID = timeZoneID
    }

    var nowCardIDs: [UUID] { scoped(plan.availableNow).map(\.cardID) }
    var laterCardIDs: [UUID] { scoped(plan.availableLater).map(\.cardID) }

    func nowItem(for cardID: UUID) -> TodayQueueItem? {
        scoped(plan.availableNow).first { $0.cardID == cardID }
    }

    func refresh() async throws {
        plan = try await service.buildTodayPlan(defaultTimeZoneID: defaultTimeZoneID)
    }

    /// Picks and loads the next card exactly as the session does: scope +
    /// skip filtering, undo priority, then the sibling policy. Records the
    /// presented note only for a genuinely presented card.
    @discardableResult
    func presentNext() async throws -> TodayQueueItem? {
        let pool = scoped(plan.availableNow)
            .filter { !skippedCardIDs.contains($0.cardID) }
        var workingDebt = deferredCardID
        if let undoID = undoPreferredCardID,
           pool.contains(where: { $0.cardID == undoID }) {
            workingDebt = nil
            let selected = pool.first { $0.cardID == undoID }!
            undoPreferredCardID = nil
            deferredCardID = nil
            lastPresentedNoteID = selected.noteID
            return selected
        }
        undoPreferredCardID = nil
        guard let selection = SiblingSelectionPolicy.selectNext(
            among: pool,
            lastPresentedNoteID: lastPresentedNoteID,
            deferredCardID: workingDebt
        ) else {
            deferredCardID = workingDebt
            return nil
        }
        deferredCardID = selection.deferredCardID
        lastPresentedNoteID = selection.selected.noteID
        return selection.selected
    }

    @discardableResult
    func submit(
        card: LoadedReviewCard,
        rating: ReviewRating,
        eventID: UUID = UUID()
    ) async throws -> ReviewLogRecord {
        let log = try await service.submit(
            card: card,
            rating: rating,
            studyDay: plan.studyDay,
            eventID: eventID,
            durationMilliseconds: 500
        )
        try await refresh()
        return log
    }

    func undo(eventID: UUID) async throws {
        let log = try await service.undoLastReview(eventID: eventID, studyDay: plan.studyDay)
        undoPreferredCardID = log.cardID
        deferredCardID = nil
    }

    private func scoped(_ items: [TodayQueueItem]) -> [TodayQueueItem] {
        guard let deckScope else { return items }
        return items.filter { $0.deckID == deckScope }
    }
}

private final class StudySessionClock: SchedulingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Date) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

private final class StudySessionFixture: @unchecked Sendable {
    let directoryURL: URL
    let databaseURL: URL
    let database: OboeDatabase
    let deckID: UUID
    let profileID: UUID
    let now: Date
    let clock: StudySessionClock

    private init(
        directoryURL: URL,
        databaseURL: URL,
        database: OboeDatabase,
        deckID: UUID,
        profileID: UUID,
        now: Date,
        clock: StudySessionClock
    ) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.database = database
        self.deckID = deckID
        self.profileID = profileID
        self.now = now
        self.clock = clock
    }

    static func make() async throws -> StudySessionFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-P11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let database = try OboeDatabase(path: databaseURL.path)
        let deckID = UUID()
        let profileID = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 9,
            day: 10,
            hour: 12
        ))!
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P11', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters,
                    profile.targetRetention,
                    profile.maximumIntervalDays
                ]
            )
        }
        return StudySessionFixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            deckID: deckID,
            profileID: profileID,
            now: now,
            clock: StudySessionClock(now)
        )
    }

    func addDeck() async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P11-B', 1, 1, 1)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
        return id
    }

    func addVocabularyNote(deckID: UUID? = nil) async throws -> UUID {
        let noteID = UUID()
        let exampleID = UUID()
        let deckID = deckID ?? self.deckID
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, notes, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', '动词',
                              '常用他动词', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
            try db.execute(
                sql: "INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order) VALUES (?, ?, '魚を食べる。', '吃鱼。', 0)",
                arguments: [
                    DatabaseValueCodec.encode(exampleID),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
        }
        return noteID
    }

    func addGrammarNote() async throws -> UUID {
        let noteID = UUID()
        let exampleID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh, usage, connection,
                        notes, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'grammar', '〜たことがある', '曾经做过',
                              '表示过去的经历', '动词た形', '不能用于刚刚发生的事情', 1, 2, 2)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
            try db.execute(
                sql: "INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order) VALUES (?, ?, '日本へ行ったことがある。', '去过日本。', 0)",
                arguments: [
                    DatabaseValueCodec.encode(exampleID),
                    DatabaseValueCodec.encode(noteID)
                ]
            )
        }
        return noteID
    }

    func addCard(noteID: UUID, template: CardTemplateKind) async throws -> UUID {
        try await addCard(
            noteID: noteID,
            template: template,
            scheduling: SchedulingCard(dueAt: now),
            firstStudiedAt: nil
        )
    }

    func addCard(
        noteID: UUID,
        template: CardTemplateKind,
        scheduling: SchedulingCard,
        firstStudiedAt: Date?
    ) async throws -> UUID {
        let cardID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                              0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    scheduling.state.rawValue,
                    try DatabaseValueCodec.encode(scheduling.dueAt),
                    try scheduling.lastReviewAt.map { try DatabaseValueCodec.encode($0) },
                    scheduling.stability,
                    scheduling.difficulty,
                    scheduling.repetitions,
                    scheduling.lapses,
                    scheduling.scheduledDays,
                    scheduling.elapsedDays,
                    scheduling.learningStep,
                    try firstStudiedAt.map { try DatabaseValueCodec.encode($0) },
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return cardID
    }

    func fetchCardSnapshot(cardID: UUID) async throws -> SchedulingCard {
        try await database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, due_at_ms, last_review_at_ms, stability, difficulty,
                           reps, lapses, scheduled_days, elapsed_days, learning_step
                    FROM cards WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
            guard let row else { throw StudySessionError.cardUnavailable }
            let stateValue: Int = row["state"]
            let lastReview: Int64? = row["last_review_at_ms"]
            return try SchedulingCard(
                dueAt: DatabaseValueCodec.decodeDate(milliseconds: row["due_at_ms"]),
                stability: row["stability"],
                difficulty: row["difficulty"],
                elapsedDays: row["elapsed_days"],
                scheduledDays: row["scheduled_days"],
                learningStep: row["learning_step"],
                repetitions: row["reps"],
                lapses: row["lapses"],
                state: XCTUnwrap(SchedulingState(rawValue: stateValue)),
                lastReviewAt: lastReview.map {
                    DatabaseValueCodec.decodeDate(milliseconds: $0)
                }
            )
        }
    }

    func setEnabled(_ enabled: Bool, cardID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = ? WHERE id = ?",
                arguments: [enabled, DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    var service: StudySessionService { makeService() }

    func makeDriver(deckScope: UUID? = nil) async throws -> SessionDriver {
        let plan = try await makeService().buildTodayPlan(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        return SessionDriver(service: makeService(), plan: plan, deckScope: deckScope)
    }

    func makeService(database: OboeDatabase? = nil) -> StudySessionService {
        let database = database ?? self.database
        return StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: GRDBReviewCardContentRepository(database: database),
            submissionRepository: GRDBReviewSubmissionRepository(database: database),
            undoRepository: GRDBReviewSubmissionRepository(database: database),
            scheduler: SwiftFSRSReviewScheduler(clock: clock),
            clock: clock
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
