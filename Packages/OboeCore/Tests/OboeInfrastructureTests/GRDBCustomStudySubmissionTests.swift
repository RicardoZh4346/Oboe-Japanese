import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// §7.3 接入（D06）：`.customScheduled(sessionID:)` 提交走正式
/// FSRS/review_logs，但以「session 存在 + mode=scheduled + status
/// =active + 卡∈冻结队列」替换 due/daily_tasks 检查；origin 与
/// review_log 同事务；撤销经 origin 分流，不查 daily_tasks。
final class GRDBCustomStudySubmissionTests: XCTestCase {
    private let reviewedAt = Date(timeIntervalSince1970: 1_768_478_400)

    func testCustomScheduledCommitsWithoutDailyTaskAndRecordsOrigin() async throws {
        let fixture = try await CustomSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let session = try await fixture.makeSession(
            cardIDs: [fixture.cardID],
            mode: .scheduled
        )
        let request = fixture.request(
            eventID: UUID(),
            cardID: fixture.cardID,
            policy: .customScheduled(sessionID: session.id)
        )

        let log = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: CustomStudyFixedClock(value: reviewedAt)
        )(request)

        XCTAssertTrue(log.wasFirstStudy)
        XCTAssertEqual(log.nextState.stateVersion, 1)
        let origin = try await GRDBCustomStudyRepository(database: fixture.database)
            .fetchScheduledOrigin(eventID: request.eventID)
        XCTAssertEqual(
            origin,
            ScheduledReviewOrigin(eventID: request.eventID, sessionID: session.id)
        )
    }

    func testCustomScheduledAllowsEarlyReviewForNotDueCard() async throws {
        // 非 new 卡、due 在未来：.normal 会被 cardNotDue 拒，
        // .customScheduled 凭冻结队列资格放行（§7.3 提前复习）。
        let fixture = try await CustomSubmissionFixture.make(
            reviewedAt: reviewedAt,
            cardState: .review,
            dueAt: reviewedAt.addingTimeInterval(3 * 86_400),
            stateVersion: 4,
            firstStudiedAt: reviewedAt.addingTimeInterval(-86_400)
        )
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let session = try await fixture.makeSession(
            cardIDs: [fixture.cardID],
            mode: .scheduled
        )

        let log = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: CustomStudyFixedClock(value: reviewedAt)
        )(
            fixture.request(
                eventID: UUID(),
                cardID: fixture.cardID,
                expectedStateVersion: 4,
                policy: .customScheduled(sessionID: session.id)
            )
        )

        XCTAssertFalse(log.wasFirstStudy)
        XCTAssertEqual(log.nextState.stateVersion, 5)
    }

    func testCustomScheduledRejectsCardOutsideFrozenQueue() async throws {
        let fixture = try await CustomSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let session = try await fixture.makeSession(
            cardIDs: [fixture.siblingCardID],
            mode: .scheduled
        )

        do {
            _ = try await SubmitReview(
                repository: repository,
                scheduler: SwiftFSRSReviewScheduler(),
                clock: CustomStudyFixedClock(value: reviewedAt)
            )(
                fixture.request(
                    eventID: UUID(),
                    cardID: fixture.cardID,
                    policy: .customScheduled(sessionID: session.id)
                )
            )
            XCTFail("Card outside the frozen queue must be rejected")
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                .cardNotInSessionQueue(
                    cardID: fixture.cardID,
                    sessionID: session.id
                )
            )
        }
    }

    func testCustomScheduledRejectsWrongModeAndNonActiveSessions() async throws {
        let fixture = try await CustomSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let useCase = SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: CustomStudyFixedClock(value: reviewedAt)
        )

        // practiceOnly session——绝不产生正式评分（D06）。
        let practice = try await fixture.makeSession(
            cardIDs: [fixture.cardID],
            mode: .practiceOnly
        )
        do {
            _ = try await useCase(
                fixture.request(
                    eventID: UUID(),
                    cardID: fixture.cardID,
                    policy: .customScheduled(sessionID: practice.id)
                )
            )
            XCTFail("practiceOnly session must be rejected")
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                .sessionNotEligibleForScheduledSubmission(practice.id)
            )
        }

        // finished session——已关闭的 session 不再接受提交。
        let finished = try await fixture.makeSession(
            cardIDs: [fixture.cardID],
            mode: .scheduled
        )
        try await GRDBCustomStudyRepository(database: fixture.database)
            .updateSessionStatus(
                id: finished.id,
                to: .finished,
                finishedAt: reviewedAt
            )
        do {
            _ = try await useCase(
                fixture.request(
                    eventID: UUID(),
                    cardID: fixture.cardID,
                    policy: .customScheduled(sessionID: finished.id)
                )
            )
            XCTFail("finished session must be rejected")
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                .sessionNotEligibleForScheduledSubmission(finished.id)
            )
        }

        // 不存在的 session。
        let missingID = UUID()
        do {
            _ = try await useCase(
                fixture.request(
                    eventID: UUID(),
                    cardID: fixture.cardID,
                    policy: .customScheduled(sessionID: missingID)
                )
            )
            XCTFail("missing session must be rejected")
        } catch {
            XCTAssertEqual(
                error as? CustomStudyRepositoryError,
                .sessionNotFound(missingID)
            )
        }
    }

    func testUndoCustomScheduledReviewDoesNotNeedDailyTask() async throws {
        let fixture = try await CustomSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let session = try await fixture.makeSession(
            cardIDs: [fixture.cardID],
            mode: .scheduled
        )
        let log = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: CustomStudyFixedClock(value: reviewedAt)
        )(
            fixture.request(
                eventID: UUID(),
                cardID: fixture.cardID,
                policy: .customScheduled(sessionID: session.id)
            )
        )
        let undoAt = reviewedAt.addingTimeInterval(1)

        let undone = try await UndoReview(
            repository: repository,
            clock: CustomStudyFixedClock(value: undoAt)
        )(
            UndoReviewRequest(
                eventID: log.eventID,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )

        XCTAssertEqual(undone.undoneAt, undoAt)
        let fetchedCard = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let restored = try XCTUnwrap(fetchedCard)
        XCTAssertEqual(restored.stateVersion, log.previousState.stateVersion)
        XCTAssertEqual(restored.scheduling, log.previousState.scheduling)
        // origin 行保留审计——撤销不抹掉归因。
        let origin = try await GRDBCustomStudyRepository(database: fixture.database)
            .fetchScheduledOrigin(eventID: log.eventID)
        XCTAssertEqual(origin?.sessionID, session.id)
    }

    func testNormalPolicyStillRequiresStudyPlanMembership() async throws {
        // 对照组：同 fixture 下 .normal 走旧检查（无 daily_tasks 行）。
        let fixture = try await CustomSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)

        do {
            _ = try await SubmitReview(
                repository: repository,
                scheduler: SwiftFSRSReviewScheduler(),
                clock: CustomStudyFixedClock(value: reviewedAt)
            )(
                fixture.request(
                    eventID: UUID(),
                    cardID: fixture.cardID,
                    policy: .normal
                )
            )
            XCTFail("normal policy must still require a daily task")
        } catch {
            XCTAssertEqual(error as? SubmitReviewError, .cardNotInStudyPlan)
        }
    }
}

private struct CustomStudyFixedClock: SchedulingClock {
    let value: Date

    func now() -> Date { value }
}

private final class CustomSubmissionFixture: @unchecked Sendable {
    let directoryURL: URL
    let database: OboeDatabase
    let cardRepository: GRDBSchedulingCardRepository
    let customStudyRepository: GRDBCustomStudyRepository
    let deckID: UUID
    let noteID: UUID
    let cardID: UUID
    let siblingCardID: UUID
    let profileID: UUID
    let studyDayID: UUID

    private init(
        directoryURL: URL,
        database: OboeDatabase,
        deckID: UUID,
        noteID: UUID,
        cardID: UUID,
        siblingCardID: UUID,
        profileID: UUID,
        studyDayID: UUID
    ) {
        self.directoryURL = directoryURL
        self.database = database
        cardRepository = GRDBSchedulingCardRepository(database: database)
        customStudyRepository = GRDBCustomStudyRepository(database: database)
        self.deckID = deckID
        self.noteID = noteID
        self.cardID = cardID
        self.siblingCardID = siblingCardID
        self.profileID = profileID
        self.studyDayID = studyDayID
    }

    static func make(
        reviewedAt: Date,
        cardState: SchedulingState = .new,
        dueAt: Date? = nil,
        stateVersion: Int = 0,
        firstStudiedAt: Date? = nil
    ) async throws -> CustomSubmissionFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Oboe-CustomStudy-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        let siblingCardID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let reviewedAtMilliseconds = try DatabaseValueCodec.encode(reviewedAt)
        let dueAtMilliseconds = try DatabaseValueCodec.encode(dueAt ?? reviewedAt)
        let firstStudiedMilliseconds = try firstStudiedAt.map(DatabaseValueCodec.encode)
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P08', 0, ?, ?)",
                arguments: [
                    DatabaseValueCodec.encode(deckID),
                    reviewedAtMilliseconds,
                    reviewedAtMilliseconds
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', 2, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    reviewedAtMilliseconds,
                    reviewedAtMilliseconds
                ]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parametersJSON,
                    profile.targetRetention,
                    profile.maximumIntervalDays,
                    reviewedAtMilliseconds
                ]
            )
            for (id, template) in [
                (cardID, CardTemplateKind.vocabularyJapaneseToChinese),
                (siblingCardID, CardTemplateKind.vocabularyChineseToJapanese)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            last_review_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step,
                            state_version, first_studied_at_ms,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, ?, ?, NULL, 4, 4, 1, 0, 1, 0, 0, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(id),
                        DatabaseValueCodec.encode(noteID),
                        template.rawValue,
                        cardState.rawValue,
                        dueAtMilliseconds,
                        stateVersion,
                        firstStudiedMilliseconds,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-01-15', 'Asia/Shanghai', ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    reviewedAtMilliseconds - 3_600_000,
                    reviewedAtMilliseconds + 82_800_000
                ]
            )
            // 注意：刻意不建 daily_tasks——custom 路径不得依赖计划成员。
        }
        return CustomSubmissionFixture(
            directoryURL: directoryURL,
            database: database,
            deckID: deckID,
            noteID: noteID,
            cardID: cardID,
            siblingCardID: siblingCardID,
            profileID: profileID,
            studyDayID: studyDayID
        )
    }

    func makeSession(
        cardIDs: [UUID],
        mode: CustomStudyMode
    ) async throws -> CustomStudySession {
        let filter = CustomStudyFilter()
        let queue = CustomStudyQueue.ordered(
            cardIDs: cardIDs,
            order: .due,
            randomSeed: nil,
            generatedAt: Date(timeIntervalSince1970: 1_768_478_400)
        )
        let session = try CustomStudyService().makeSession(
            filter: filter,
            queue: queue,
            mode: mode,
            now: Date(timeIntervalSince1970: 1_768_478_400)
        )
        try await customStudyRepository.createSession(session)
        return session
    }

    func request(
        eventID: UUID,
        cardID: UUID,
        expectedStateVersion: Int = 0,
        policy: ReviewSubmissionPolicy
    ) -> SubmitReviewRequest {
        SubmitReviewRequest(
            eventID: eventID,
            cardID: cardID,
            expectedStateVersion: expectedStateVersion,
            rating: .good,
            durationMilliseconds: 900,
            studyDay: StudyDayContext(id: studyDayID),
            policy: policy
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
