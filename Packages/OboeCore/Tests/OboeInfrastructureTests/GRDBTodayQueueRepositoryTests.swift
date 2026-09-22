import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBTodayQueueRepositoryTests: XCTestCase {
    func testBuildSeparatesNowAndLaterAndAppliesPriority() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let newCard = try await fixture.addCard(deckID: deckID, state: .new, dueAt: now)
        let learningNow = try await fixture.addCard(
            deckID: deckID, state: .learning, dueAt: now.addingTimeInterval(-300)
        )
        let relearningNow = try await fixture.addCard(
            deckID: deckID, state: .relearning, dueAt: now.addingTimeInterval(-200)
        )
        let reviewNow = try await fixture.addCard(
            deckID: deckID, state: .review, dueAt: now.addingTimeInterval(-100)
        )
        let learningLater = try await fixture.addCard(
            deckID: deckID, state: .learning, dueAt: now.addingTimeInterval(300)
        )
        let reviewLater = try await fixture.addCard(
            deckID: deckID, state: .review, dueAt: now.addingTimeInterval(600)
        )
        let tomorrow = try await fixture.addCard(
            deckID: deckID,
            state: .review,
            dueAt: queueLocalDate(2026, 9, 11, 5, 0)
        )

        let plan = try await fixture.build(at: now)

        XCTAssertEqual(plan.availableNow.map(\.cardID), [
            learningNow, relearningNow, reviewNow, newCard
        ])
        XCTAssertEqual(plan.availableLater.map(\.cardID), [learningLater, reviewLater])
        XCTAssertFalse(plan.availableNow.map(\.cardID).contains(tomorrow))
        XCTAssertFalse(plan.availableLater.map(\.cardID).contains(tomorrow))
        XCTAssertEqual(plan.nextAvailableAt, now.addingTimeInterval(300))
        XCTAssertEqual(
            plan.summary,
            TodayStudySummary(
                newCount: 1,
                reviewCount: 2,
                learningCount: 3,
                completedCount: 0
            )
        )
        XCTAssertEqual(plan.summary.remainingCount, 6)
    }

    /// T21: the queue no longer soft-separates siblings — that moved to
    /// display-time `SiblingSelectionPolicy`. `availableNow` is the raw
    /// eligibility order (category priority, then due time), stable across
    /// database reopen.
    func testSiblingCardsKeepRawQueueOrderAndQueueSurvivesReopen() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let sharedNote = try await fixture.addNote(deckID: deckID)
        let firstSibling = try await fixture.addCard(
            noteID: sharedNote,
            template: .vocabularyJapaneseToChinese,
            state: .review,
            dueAt: now.addingTimeInterval(-300)
        )
        let secondSibling = try await fixture.addCard(
            noteID: sharedNote,
            template: .vocabularyChineseToJapanese,
            state: .review,
            dueAt: now.addingTimeInterval(-200)
        )
        let other = try await fixture.addCard(
            deckID: deckID,
            state: .review,
            dueAt: now.addingTimeInterval(-100)
        )
        _ = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(0, at: now, defaultTimeZoneID: "Asia/Shanghai")
        let firstPlan = try await fixture.build(at: now)

        // Raw due order — display-time separation belongs to the session
        // policy, not the queue.
        XCTAssertEqual(firstPlan.availableNow.map(\.cardID), [firstSibling, secondSibling, other])

        try fixture.database.close()
        let reopened = try OboeDatabase(path: fixture.databaseURL.path)
        let reopenedBuilder = BuildTodayPlan(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: reopened),
            queueRepository: GRDBTodayQueueRepository(database: reopened)
        )
        let reopenedPlan = try await reopenedBuilder(
            at: now.addingTimeInterval(1),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(reopenedPlan.availableNow.map(\.cardID), firstPlan.availableNow.map(\.cardID))
        XCTAssertEqual(reopenedPlan.summary, firstPlan.summary)
        try reopened.close()
    }

    /// 同一词的方向卡在 `now` 队列固定按 日→中、中→日、听力 排序
    /// （从易到难），与插入顺序、UUID 和同词内的 dueAt 先后无关。
    func testSameNoteDirectionsOrderEasyToHard() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let note = try await fixture.addNote(deckID: deckID)
        // 故意反序插入：听力先到、日→中最后。
        let listening = try await fixture.addCard(
            noteID: note, template: .vocabularyListening, state: .new, dueAt: now
        )
        let chineseToJapanese = try await fixture.addCard(
            noteID: note, template: .vocabularyChineseToJapanese,
            state: .new, dueAt: now
        )
        let japaneseToChinese = try await fixture.addCard(
            noteID: note, template: .vocabularyJapaneseToChinese,
            state: .new, dueAt: now
        )
        // 另一个词同样入队，验证排序只约束同词内的相对顺序。
        let otherNote = try await fixture.addNote(deckID: deckID)
        _ = try await fixture.addCard(
            noteID: otherNote, template: .vocabularyJapaneseToChinese,
            state: .new, dueAt: now
        )
        _ = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(2, at: now, defaultTimeZoneID: "Asia/Shanghai")

        let plan = try await fixture.build(at: now)

        XCTAssertEqual(
            plan.availableNow.filter { $0.noteID == note }.map(\.cardID),
            [japaneseToChinese, chineseToJapanese, listening],
            "同词方向固定 日→中 → 中→日 → 听力，与插入顺序和 UUID 无关"
        )
        XCTAssertEqual(plan.availableNow.count, 4, "两个词各一个额度，全部方向入队")
    }

    /// T21: `availableLater` is pure due-time order — sibling notes are NOT
    /// swapped there, so `nextAvailableAt` is always the earliest dueAt.
    func testLaterItemsKeepPureDueOrderEvenAcrossSiblingNotes() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let sharedNote = try await fixture.addNote(deckID: deckID)
        let firstSibling = try await fixture.addCard(
            noteID: sharedNote,
            template: .vocabularyJapaneseToChinese,
            state: .learning,
            dueAt: now.addingTimeInterval(600)
        )
        let secondSibling = try await fixture.addCard(
            noteID: sharedNote,
            template: .vocabularyChineseToJapanese,
            state: .learning,
            dueAt: now.addingTimeInterval(300)
        )
        _ = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(0, at: now, defaultTimeZoneID: "Asia/Shanghai")

        let plan = try await fixture.build(at: now)

        XCTAssertEqual(
            plan.availableLater.map(\.cardID), [secondSibling, firstSibling],
            "later 列表保持纯 dueAt 顺序，不做兄弟交换"
        )
        XCTAssertEqual(
            plan.nextAvailableAt, now.addingTimeInterval(300),
            "下一次唤醒必须是最早到期时间"
        )
    }

    func testOnlyLaterItemsMeansCurrentPauseButNotDayCompletion() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let laterCard = try await fixture.addCard(
            deckID: deckID,
            state: .learning,
            dueAt: now.addingTimeInterval(600)
        )
        _ = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(0, at: now, defaultTimeZoneID: "Asia/Shanghai")

        let plan = try await fixture.build(at: now)

        XCTAssertTrue(plan.availableNow.isEmpty)
        XCTAssertEqual(plan.availableLater.map(\.cardID), [laterCard])
        XCTAssertTrue(plan.isCurrentSessionComplete)
        XCTAssertFalse(plan.isDayComplete)
        XCTAssertEqual(plan.nextAvailableAt, now.addingTimeInterval(600))
    }

    func testScoringUsesActiveTaskUpdatesSummaryAndDoesNotDoubleConsumeQuota() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let repeatedCard = try await fixture.addCard(deckID: deckID, state: .new, dueAt: now)
        let completedCard = try await fixture.addCard(
            deckID: deckID, state: .new, dueAt: now.addingTimeInterval(1)
        )
        let unreservedCard = try await fixture.addCard(
            deckID: deckID, state: .new, dueAt: now.addingTimeInterval(2)
        )
        let reservationPlan = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(2, at: now, defaultTimeZoneID: "Asia/Shanghai")
        let studyDay = reservationPlan.studyDay
        _ = try await fixture.build(at: now)
        let reviewRepository = GRDBReviewSubmissionRepository(database: fixture.database)

        let first = try await SubmitReview(
            repository: reviewRepository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: QueueFixedClock(value: now)
        )(
            SubmitReviewRequest(
                eventID: UUID(), cardID: repeatedCard, expectedStateVersion: 0,
                rating: .again, durationMilliseconds: 500,
                studyDay: studyDay.context
            )
        )
        _ = try await SubmitReview(
            repository: reviewRepository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: QueueFixedClock(value: now)
        )(
            SubmitReviewRequest(
                eventID: UUID(), cardID: completedCard, expectedStateVersion: 0,
                rating: .easy, durationMilliseconds: 700,
                studyDay: studyDay.context
            )
        )

        let afterFirstRatings = try await fixture.build(at: now.addingTimeInterval(1))
        XCTAssertEqual(afterFirstRatings.summary.learningCount, 1)
        XCTAssertEqual(afterFirstRatings.summary.completedCount, 1)
        XCTAssertEqual(afterFirstRatings.availableLater.map(\.cardID), [repeatedCard])

        let directSummary = try await GRDBTodayQueueRepository(database: fixture.database)
            .fetchSummary(
                for: afterFirstRatings.studyDay, deckID: nil,
                at: now.addingTimeInterval(1)
            )
        XCTAssertEqual(directSummary, afterFirstRatings.summary)

        let dueAt = first.nextState.scheduling.dueAt
        let atDue = try await fixture.build(at: dueAt)
        XCTAssertEqual(atDue.availableNow.map(\.cardID), [repeatedCard])
        let second = try await SubmitReview(
            repository: reviewRepository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: QueueFixedClock(value: dueAt)
        )(
            SubmitReviewRequest(
                eventID: UUID(), cardID: repeatedCard, expectedStateVersion: 1,
                rating: .again, durationMilliseconds: 400,
                studyDay: studyDay.context
            )
        )
        let quota = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        )(at: dueAt, defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(quota.usedCount, 2)

        let tooEarly = dueAt.addingTimeInterval(1)
        do {
            _ = try await SubmitReview(
                repository: reviewRepository,
                scheduler: SwiftFSRSReviewScheduler(),
                clock: QueueFixedClock(value: tooEarly)
            )(
                SubmitReviewRequest(
                    eventID: UUID(), cardID: repeatedCard, expectedStateVersion: 2,
                    rating: .good, durationMilliseconds: 300,
                    studyDay: studyDay.context
                )
            )
            XCTFail("A future interval must not be reviewed early")
        } catch {
            XCTAssertEqual(
                error as? SubmitReviewError,
                .cardNotDue(until: second.nextState.scheduling.dueAt)
            )
        }

        do {
            _ = try await SubmitReview(
                repository: reviewRepository,
                scheduler: SwiftFSRSReviewScheduler(),
                clock: QueueFixedClock(value: now)
            )(
                SubmitReviewRequest(
                    eventID: UUID(), cardID: unreservedCard, expectedStateVersion: 0,
                    rating: .good, durationMilliseconds: 300,
                    studyDay: studyDay.context
                )
            )
            XCTFail("An unreserved new card must not bypass the plan")
        } catch {
            XCTAssertEqual(error as? SubmitReviewError, .cardNotInStudyPlan)
        }

        do {
            _ = try await SubmitReview(
                repository: reviewRepository,
                scheduler: SwiftFSRSReviewScheduler(),
                clock: QueueFixedClock(value: dueAt.addingTimeInterval(-1))
            )(
                SubmitReviewRequest(
                    eventID: UUID(), cardID: repeatedCard, expectedStateVersion: 2,
                    rating: .good, durationMilliseconds: 300,
                    studyDay: studyDay.context
                )
            )
            XCTFail("A clock rollback must be rejected")
        } catch {
            XCTAssertEqual(
                error as? SubmitReviewError,
                .clockMovedBackward(lastReviewAt: dueAt, attemptedAt: dueAt.addingTimeInterval(-1))
            )
        }
    }

    func testScopedSummarySeparatesDecksAndFollowsCurrentDeck() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckA = try await fixture.addDeck()
        let deckB = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let newA = try await fixture.addCard(deckID: deckA, state: .new, dueAt: now)
        let completedNewA = try await fixture.addCard(
            deckID: deckA, state: .new, dueAt: now.addingTimeInterval(1)
        )
        let learningA = try await fixture.addCard(
            deckID: deckA, state: .learning, dueAt: now.addingTimeInterval(-100)
        )
        let laterA = try await fixture.addCard(
            deckID: deckA, state: .review, dueAt: now.addingTimeInterval(600)
        )
        _ = try await fixture.addCard(
            deckID: deckB, state: .review, dueAt: now.addingTimeInterval(-50)
        )
        let plan = try await fixture.build(at: now)
        let queue = GRDBTodayQueueRepository(database: fixture.database)

        let initialA = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckA, at: now
        )
        XCTAssertEqual(initialA.newCount, 2)
        XCTAssertEqual(initialA.learningCount, 1)
        XCTAssertEqual(initialA.reviewCount, 1)
        XCTAssertEqual(initialA.remainingCount, 4)
        XCTAssertEqual(initialA.completedCount, 0)

        _ = try await SubmitReview(
            repository: GRDBReviewSubmissionRepository(database: fixture.database),
            scheduler: SwiftFSRSReviewScheduler(),
            clock: QueueFixedClock(value: now)
        )(
            SubmitReviewRequest(
                eventID: UUID(), cardID: completedNewA, expectedStateVersion: 0,
                rating: .easy, durationMilliseconds: 500,
                studyDay: plan.studyDay.context
            )
        )

        let global = try await queue.fetchSummary(
            for: plan.studyDay, deckID: nil, at: now.addingTimeInterval(1)
        )
        let scopeA = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckA, at: now.addingTimeInterval(1)
        )
        let scopeB = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckB, at: now.addingTimeInterval(1)
        )
        XCTAssertEqual(global.remainingCount, 4)
        XCTAssertEqual(global.completedCount, 1)
        XCTAssertEqual(scopeA.remainingCount, 3)
        XCTAssertEqual(scopeA.completedCount, 1)
        XCTAssertEqual(scopeB.remainingCount, 1)
        XCTAssertEqual(scopeB.completedCount, 0)
        XCTAssertEqual(
            scopeA.remainingCount + scopeB.remainingCount,
            global.remainingCount
        )

        try await fixture.moveCardToDeck(cardID: newA, deckID: deckB)
        try await fixture.moveCardToDeck(cardID: completedNewA, deckID: deckB)
        let movedA = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckA, at: now.addingTimeInterval(2)
        )
        let movedB = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckB, at: now.addingTimeInterval(2)
        )
        XCTAssertEqual(movedA.remainingCount, 2)
        XCTAssertEqual(movedA.completedCount, 0)
        XCTAssertEqual(movedB.remainingCount, 2)
        XCTAssertEqual(movedB.completedCount, 1)

        try await fixture.setEnabled(false, cardID: laterA)
        let disabledA = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckA, at: now.addingTimeInterval(3)
        )
        XCTAssertEqual(disabledA.remainingCount, 1)
        XCTAssertEqual(disabledA.denominator, 1)
        XCTAssertEqual(disabledA.completionFraction, 0)

        try await fixture.setEnabled(false, cardID: learningA)
        let emptyA = try await queue.fetchSummary(
            for: plan.studyDay, deckID: deckA, at: now.addingTimeInterval(4)
        )
        XCTAssertEqual(emptyA.remainingCount, 0)
        XCTAssertEqual(emptyA.completedCount, 0)
        XCTAssertEqual(emptyA.denominator, 0)
        XCTAssertNil(emptyA.completionFraction)
    }

    func testDisabledAndDeletedCardsAreRemovedWhileReenabledDueCardReturns() async throws {
        let fixture = try await TodayQueueFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let now = queueLocalDate(2026, 9, 10, 12, 0)
        let disabledCard = try await fixture.addCard(
            deckID: deckID, state: .review, dueAt: now.addingTimeInterval(-100)
        )
        let deletedCard = try await fixture.addCard(
            deckID: deckID, state: .learning, dueAt: now.addingTimeInterval(-50)
        )
        let reservedNew = try await fixture.addCard(deckID: deckID, state: .new, dueAt: now)
        let replacementNew = try await fixture.addCard(
            deckID: deckID, state: .new, dueAt: now.addingTimeInterval(1)
        )
        _ = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(1, at: now, defaultTimeZoneID: "Asia/Shanghai")
        let original = try await fixture.build(at: now)
        XCTAssertEqual(
            Set(original.availableNow.map(\.cardID)),
            [disabledCard, deletedCard, reservedNew]
        )

        try await fixture.setEnabled(false, cardID: disabledCard)
        try await fixture.setEnabled(false, cardID: reservedNew)
        try await fixture.deleteNote(containing: deletedCard)
        let reconciled = try await fixture.build(at: now.addingTimeInterval(1))
        XCTAssertEqual(reconciled.availableNow.map(\.cardID), [replacementNew])
        let taskState = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM daily_tasks WHERE card_id = ? AND cancelled_at_ms IS NOT NULL",
                    arguments: [DatabaseValueCodec.encode(disabledCard)]
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM daily_tasks WHERE card_id = ?",
                    arguments: [DatabaseValueCodec.encode(deletedCard)]
                ) ?? -1
            )
        }
        XCTAssertEqual(taskState.0, 1)
        XCTAssertEqual(taskState.1, 0)

        try await fixture.setEnabled(true, cardID: disabledCard)
        let restored = try await fixture.build(at: now.addingTimeInterval(2))
        XCTAssertEqual(restored.availableNow.map(\.cardID), [disabledCard, replacementNew])
    }
}

private struct QueueFixedClock: SchedulingClock {
    let value: Date
    func now() -> Date { value }
}

private func queueLocalDate(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}

private final class TodayQueueFixture: @unchecked Sendable {
    let directoryURL: URL
    let databaseURL: URL
    let database: OboeDatabase
    let profileID: UUID
    private var sequence = 0

    private init(directoryURL: URL, databaseURL: URL, database: OboeDatabase, profileID: UUID) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.database = database
        self.profileID = profileID
    }

    static func make() async throws -> TodayQueueFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-P10b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let database = try OboeDatabase(path: databaseURL.path)
        let profileID = UUID()
        let profile = SchedulerProfile.standard
        let parameters = String(decoding: try JSONEncoder().encode(profile.parameters), as: UTF8.self)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID), profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision, parameters,
                    profile.targetRetention, profile.maximumIntervalDays
                ]
            )
        }
        return TodayQueueFixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            profileID: profileID
        )
    }

    func addDeck() async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'Queue', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
        return id
    }

    func addNote(deckID: UUID) async throws -> UUID {
        sequence += 1
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, '含义', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(deckID),
                    "Queue \(sequence)", sequence, sequence
                ]
            )
            try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
        }
        return id
    }

    func addCard(
        deckID: UUID,
        state: SchedulingState,
        dueAt: Date
    ) async throws -> UUID {
        let noteID = try await addNote(deckID: deckID)
        return try await addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            state: state,
            dueAt: dueAt
        )
    }

    func addCard(
        noteID: UUID,
        template: CardTemplateKind,
        state: SchedulingState,
        dueAt: Date
    ) async throws -> UUID {
        let id = UUID()
        let firstStudiedAt: Int64? = state == .new ? nil : try DatabaseValueCodec.encode(dueAt.addingTimeInterval(-86_400))
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, ?, ?, ?, 1, 5, 1, 0, 1, 1, 0, ?, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(noteID),
                    template.rawValue, state.rawValue,
                    try DatabaseValueCodec.encode(dueAt), firstStudiedAt,
                    firstStudiedAt, SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return id
    }

    func build(at instant: Date) async throws -> TodayPlan {
        try await BuildTodayPlan(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database)
        )(at: instant, defaultTimeZoneID: "Asia/Shanghai")
    }

    func moveCardToDeck(cardID: UUID, deckID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET deck_id = ? WHERE id = (SELECT note_id FROM cards WHERE id = ?)",
                arguments: [DatabaseValueCodec.encode(deckID), DatabaseValueCodec.encode(cardID)]
            )
            // 移动语义 = 成员关系折叠为目标牌组（home∈membership）。
            if try db.tableExists("note_decks") {
                try db.execute(
                    sql: """
                        DELETE FROM note_decks
                        WHERE note_id = (SELECT note_id FROM cards WHERE id = ?)
                        """,
                    arguments: [DatabaseValueCodec.encode(cardID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        VALUES ((SELECT note_id FROM cards WHERE id = ?), ?, 1)
                        """,
                    arguments: [DatabaseValueCodec.encode(cardID), DatabaseValueCodec.encode(deckID)]
                )
            }
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

    func deleteNote(containing cardID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = (SELECT note_id FROM cards WHERE id = ?)",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
