import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBReviewSubmissionRepositoryTests: XCTestCase {
    private let reviewedAt = Date(timeIntervalSince1970: 1_768_478_400)

    func testSubmitPersistsFirstStudySnapshotsAndLeavesSiblingDirectionUnchanged() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let siblingBefore = try await fixture.cardRepository.fetchCard(id: fixture.siblingCardID)

        let log = try await makeUseCase(repository: repository)(
            fixture.request(eventID: UUID(), cardID: fixture.cardID)
        )

        let fetchedReviewedCard = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let reviewedCard = try XCTUnwrap(fetchedReviewedCard)
        XCTAssertEqual(reviewedCard.stateVersion, 1)
        XCTAssertEqual(reviewedCard.firstStudiedAt, reviewedAt)
        XCTAssertEqual(reviewedCard.scheduling, log.nextState.scheduling)
        XCTAssertEqual(log.previousState.stateVersion, 0)
        XCTAssertEqual(log.previousState.scheduling.state, .new)
        XCTAssertNil(log.previousState.firstStudiedAt)
        XCTAssertEqual(log.nextState.stateVersion, 1)
        XCTAssertTrue(log.wasFirstStudy)
        XCTAssertEqual(log.profileID, fixture.profileID)
        XCTAssertEqual(log.algorithmVersion, SwiftFSRSReviewScheduler.algorithmVersion)
        let siblingAfter = try await fixture.cardRepository.fetchCard(id: fixture.siblingCardID)
        XCTAssertEqual(siblingAfter, siblingBefore)

        do {
            try await fixture.database.pool.write { db in
                try db.execute(
                    sql: "UPDATE scheduler_profiles SET desired_retention = 0.95 WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(fixture.profileID)]
                )
            }
            XCTFail("Persisted scheduler profiles must be immutable")
        } catch {
            XCTAssertTrue(String(describing: error).contains("scheduler profiles are immutable"))
        }
    }

    func testDuplicateEventReturnsOriginalLogAndWritesOnlyOnce() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let eventID = UUID()
        let useCase = makeUseCase(repository: repository)
        let request = fixture.request(eventID: eventID, cardID: fixture.cardID)

        let first = try await useCase(request)
        let duplicate = try await useCase(request)
        let counts = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT state_version FROM cards WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(fixture.cardID)]
                ) ?? -1
            )
        }

        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
    }

    func testLaterReviewDoesNotRepeatFirstStudyMarker() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let useCase = makeUseCase(repository: repository)
        let first = try await useCase(
            fixture.request(eventID: UUID(), cardID: fixture.cardID)
        )
        let second = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: first.nextState.scheduling.dueAt)
        )(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: fixture.cardID,
                expectedStateVersion: 1,
                rating: .again,
                durationMilliseconds: 500,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )

        XCTAssertTrue(first.wasFirstStudy)
        XCTAssertFalse(second.wasFirstStudy)
        XCTAssertEqual(second.previousState.firstStudiedAt, reviewedAt)
        XCTAssertEqual(second.nextState.firstStudiedAt, reviewedAt)
        XCTAssertEqual(second.nextState.stateVersion, 2)
    }

    func testStateVersionConflictDoesNotOverwriteOrLog() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let request = SubmitReviewRequest(
            eventID: UUID(),
            cardID: fixture.cardID,
            expectedStateVersion: 3,
            rating: .good,
            durationMilliseconds: 900,
            studyDay: StudyDayContext(id: fixture.studyDayID)
        )

        do {
            _ = try await makeUseCase(repository: repository)(request)
            XCTFail("A stale state version must be rejected")
        } catch {
            XCTAssertEqual(
                error as? SubmitReviewError,
                .stateVersionConflict(expected: 3, actual: 0)
            )
        }
        let values = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT state_version FROM cards WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(fixture.cardID)]
                ) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? -1
            )
        }
        XCTAssertEqual(values.0, 0)
        XCTAssertEqual(values.1, 0)
    }

    func testInjectedWriteFailureRollsBackCardAndLogTogether() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database) {
            throw InjectedFailure.beforeLogInsert
        }

        do {
            _ = try await makeUseCase(repository: repository)(
                fixture.request(eventID: UUID(), cardID: fixture.cardID)
            )
            XCTFail("Injected failure should escape the transaction")
        } catch {
            XCTAssertEqual(error as? InjectedFailure, .beforeLogInsert)
        }
        let fetchedCard = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let card = try XCTUnwrap(fetchedCard)
        let logCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? -1
        }
        XCTAssertEqual(card.stateVersion, 0)
        XCTAssertNil(card.firstStudiedAt)
        XCTAssertEqual(card.scheduling.state, .new)
        XCTAssertEqual(logCount, 0)
    }

    func testCommittedCardAndLogRemainConsistentAfterReopen() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let eventID = UUID()
        let expected = try await makeUseCase(
            repository: GRDBReviewSubmissionRepository(database: fixture.database)
        )(fixture.request(eventID: eventID, cardID: fixture.cardID))

        try fixture.database.close()
        let reopened = try OboeDatabase(path: fixture.databaseURL.path)
        defer { try? reopened.close() }
        let repository = GRDBReviewSubmissionRepository(database: reopened)
        let storedLog = try await repository.fetchSubmittedReview(eventID: eventID)
        let storedCard = try await GRDBSchedulingCardRepository(database: reopened)
            .fetchCard(id: fixture.cardID)

        XCTAssertEqual(storedLog, expected)
        XCTAssertEqual(storedCard?.scheduling, expected.nextState.scheduling)
        XCTAssertEqual(storedCard?.stateVersion, expected.nextState.stateVersion)
        XCTAssertEqual(storedCard?.firstStudiedAt, expected.nextState.firstStudiedAt)
    }

    func testUndoFirstStudyRestoresCardLogQuotaAndQueue() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let preciseReviewTime = reviewedAt.addingTimeInterval(0.0004)
        let log = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: preciseReviewTime)
        )(
            fixture.request(eventID: UUID(), cardID: fixture.cardID)
        )
        let undoAt = reviewedAt.addingTimeInterval(1)

        let undone = try await UndoReview(
            repository: repository,
            clock: ReviewSubmissionFixedClock(value: undoAt)
        )(
            UndoReviewRequest(
                eventID: log.eventID,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )

        let fetchedRestored = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let restored = try XCTUnwrap(fetchedRestored)
        XCTAssertEqual(undone.undoneAt, undoAt)
        XCTAssertEqual(restored.scheduling, log.previousState.scheduling)
        XCTAssertEqual(restored.firstStudiedAt, log.previousState.firstStudiedAt)
        XCTAssertEqual(restored.stateVersion, log.previousState.stateVersion)

        let dailyPlan = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        )(at: undoAt, defaultTimeZoneID: "Asia/Shanghai")
        let todayPlan = try await GRDBTodayQueueRepository(database: fixture.database)
            .buildQueue(for: dailyPlan.studyDay, at: undoAt)
        XCTAssertEqual(dailyPlan.usedCount, 0)
        XCTAssertTrue(dailyPlan.reservations.contains { $0.cardID == fixture.cardID })
        XCTAssertTrue(todayPlan.availableNow.contains {
            $0.cardID == fixture.cardID && $0.category == .new
        })
        XCTAssertEqual(todayPlan.summary.completedCount, 0)
    }

    func testUndoOrdinaryReviewKeepsFirstStudyUsageAndRestoresPreviousState() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let first = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: reviewedAt)
        )(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: fixture.cardID,
                expectedStateVersion: 0,
                rating: .again,
                durationMilliseconds: 300,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )
        let secondAt = first.nextState.scheduling.dueAt
        let second = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: secondAt)
        )(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: fixture.cardID,
                expectedStateVersion: 1,
                rating: .good,
                durationMilliseconds: 400,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )

        _ = try await UndoReview(
            repository: repository,
            clock: ReviewSubmissionFixedClock(value: secondAt.addingTimeInterval(1))
        )(
            UndoReviewRequest(
                eventID: second.eventID,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )

        let fetchedRestored = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let restored = try XCTUnwrap(fetchedRestored)
        XCTAssertEqual(restored.scheduling, first.nextState.scheduling)
        XCTAssertEqual(restored.stateVersion, first.nextState.stateVersion)
        XCTAssertEqual(restored.firstStudiedAt, first.nextState.firstStudiedAt)
        let dailyPlan = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        )(at: secondAt.addingTimeInterval(1), defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(dailyPlan.usedCount, 1)
    }

    func testUndoRejectsReviewWithSubsequentWrite() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let first = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: reviewedAt)
        )(
            SubmitReviewRequest(
                eventID: UUID(), cardID: fixture.cardID, expectedStateVersion: 0,
                rating: .again, durationMilliseconds: 300,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )
        let secondAt = first.nextState.scheduling.dueAt
        let second = try await SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: secondAt)
        )(
            SubmitReviewRequest(
                eventID: UUID(), cardID: fixture.cardID, expectedStateVersion: 1,
                rating: .good, durationMilliseconds: 400,
                studyDay: StudyDayContext(id: fixture.studyDayID)
            )
        )

        do {
            _ = try await UndoReview(
                repository: repository,
                clock: ReviewSubmissionFixedClock(value: secondAt.addingTimeInterval(1))
            )(
                UndoReviewRequest(
                    eventID: first.eventID,
                    studyDay: StudyDayContext(id: fixture.studyDayID)
                )
            )
            XCTFail("A review with a subsequent active write must not be undone")
        } catch {
            XCTAssertEqual(error as? UndoReviewError, .subsequentReviewExists)
        }
        let fetchedCard = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let card = try XCTUnwrap(fetchedCard)
        XCTAssertEqual(card.scheduling, second.nextState.scheduling)
        let storedFirst = try await repository.fetchSubmittedReview(eventID: first.eventID)
        XCTAssertNil(storedFirst?.undoneAt)
    }

    func testUndoRejectsCrossDayAndDeletedCardWithoutChangingLog() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let first = try await makeUseCase(repository: repository)(
            fixture.request(eventID: UUID(), cardID: fixture.cardID)
        )
        do {
            _ = try await UndoReview(
                repository: repository,
                clock: ReviewSubmissionFixedClock(value: reviewedAt.addingTimeInterval(82_800))
            )(
                UndoReviewRequest(
                    eventID: first.eventID,
                    studyDay: StudyDayContext(id: fixture.studyDayID)
                )
            )
            XCTFail("A previous study day must not be undoable")
        } catch {
            XCTAssertEqual(error as? UndoReviewError, .studyDayNotActive)
        }
        let storedAfterCrossDay = try await repository.fetchSubmittedReview(eventID: first.eventID)
        XCTAssertNil(storedAfterCrossDay?.undoneAt)

        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = 0 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.cardID)]
            )
        }
        do {
            _ = try await UndoReview(
                repository: repository,
                clock: ReviewSubmissionFixedClock(value: reviewedAt.addingTimeInterval(1))
            )(
                UndoReviewRequest(
                    eventID: first.eventID,
                    studyDay: StudyDayContext(id: fixture.studyDayID)
                )
            )
            XCTFail("A disabled card must not be changed by undo")
        } catch {
            XCTAssertEqual(error as? UndoReviewError, .cardDisabled)
        }

        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = 1 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.cardID)]
            )
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.noteID)]
            )
        }
        do {
            _ = try await UndoReview(
                repository: repository,
                clock: ReviewSubmissionFixedClock(value: reviewedAt.addingTimeInterval(1))
            )(
                UndoReviewRequest(
                    eventID: first.eventID,
                    studyDay: StudyDayContext(id: fixture.studyDayID)
                )
            )
            XCTFail("A deleted card must not be recreated by undo")
        } catch {
            XCTAssertEqual(error as? UndoReviewError, .cardNotFound)
        }
        let storedAfterDeletion = try await repository.fetchSubmittedReview(eventID: first.eventID)
        XCTAssertNil(storedAfterDeletion?.undoneAt)
    }

    /// T04/§5.2: suspending a card through the single-card command after it
    /// was rated keeps the original undo error semantics — the suspended
    /// card's review cannot be undone (`cardDisabled`), the log stays valid
    /// and the scheduling state is not rolled back.
    func testSuspendAfterReviewKeepsOriginalUndoErrorSemantics() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let contentRepository = GRDBContentCardRepository(database: fixture.database)
        let first = try await makeUseCase(repository: repository)(
            fixture.request(eventID: UUID(), cardID: fixture.cardID)
        )

        _ = try await contentRepository.setCardEnabled(
            cardID: fixture.cardID,
            isEnabled: false,
            at: reviewedAt.addingTimeInterval(1)
        )

        do {
            _ = try await UndoReview(
                repository: repository,
                clock: ReviewSubmissionFixedClock(value: reviewedAt.addingTimeInterval(2))
            )(
                UndoReviewRequest(
                    eventID: first.eventID,
                    studyDay: StudyDayContext(id: fixture.studyDayID)
                )
            )
            XCTFail("Undoing a suspended card's review must follow the original error semantics")
        } catch {
            XCTAssertEqual(error as? UndoReviewError, .cardDisabled)
        }
        let stored = try await repository.fetchSubmittedReview(eventID: first.eventID)
        XCTAssertNil(stored?.undoneAt, "the rejected undo leaves the log valid")
        let fetchedCard = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let card = try XCTUnwrap(fetchedCard)
        XCTAssertEqual(card.stateVersion, first.nextState.stateVersion)
        XCTAssertEqual(card.scheduling, first.nextState.scheduling)
    }

    func testUndoFailureRollsBackRestoredCardAndLogTogether() async throws {
        let fixture = try await ReviewSubmissionFixture.make(reviewedAt: reviewedAt)
        defer { fixture.remove() }
        let repository = GRDBReviewSubmissionRepository(database: fixture.database)
        let log = try await makeUseCase(repository: repository)(
            fixture.request(eventID: UUID(), cardID: fixture.cardID)
        )
        try await fixture.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_review_undo
                BEFORE UPDATE OF undone_at_ms ON review_logs
                WHEN NEW.undone_at_ms IS NOT NULL
                BEGIN
                    SELECT RAISE(ABORT, 'injected undo failure');
                END;
                """)
        }

        do {
            _ = try await UndoReview(
                repository: repository,
                clock: ReviewSubmissionFixedClock(value: reviewedAt.addingTimeInterval(1))
            )(
                UndoReviewRequest(
                    eventID: log.eventID,
                    studyDay: StudyDayContext(id: fixture.studyDayID)
                )
            )
            XCTFail("The injected failure must escape the undo transaction")
        } catch {
            XCTAssertTrue(String(describing: error).contains("injected undo failure"))
        }
        let fetchedCard = try await fixture.cardRepository.fetchCard(id: fixture.cardID)
        let card = try XCTUnwrap(fetchedCard)
        XCTAssertEqual(card.scheduling, log.nextState.scheduling)
        XCTAssertEqual(card.stateVersion, log.nextState.stateVersion)
        let storedLog = try await repository.fetchSubmittedReview(eventID: log.eventID)
        XCTAssertNil(storedLog?.undoneAt)
    }

    private func makeUseCase(
        repository: GRDBReviewSubmissionRepository
    ) -> SubmitReview {
        SubmitReview(
            repository: repository,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: ReviewSubmissionFixedClock(value: reviewedAt)
        )
    }
}

private enum InjectedFailure: Error, Equatable {
    case beforeLogInsert
}

private struct ReviewSubmissionFixedClock: SchedulingClock {
    let value: Date

    func now() -> Date { value }
}

private final class ReviewSubmissionFixture: @unchecked Sendable {
    let directoryURL: URL
    let databaseURL: URL
    let database: OboeDatabase
    let cardRepository: GRDBSchedulingCardRepository
    let deckID: UUID
    let noteID: UUID
    let cardID: UUID
    let siblingCardID: UUID
    let profileID: UUID
    let studyDayID: UUID

    private init(
        directoryURL: URL,
        databaseURL: URL,
        database: OboeDatabase,
        deckID: UUID,
        noteID: UUID,
        cardID: UUID,
        siblingCardID: UUID,
        profileID: UUID,
        studyDayID: UUID
    ) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.database = database
        cardRepository = GRDBSchedulingCardRepository(database: database)
        self.deckID = deckID
        self.noteID = noteID
        self.cardID = cardID
        self.siblingCardID = siblingCardID
        self.profileID = profileID
        self.studyDayID = studyDayID
    }

    static func make(reviewedAt: Date) async throws -> ReviewSubmissionFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-P09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let database = try OboeDatabase(path: databaseURL.path)
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
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P09', 0, ?, ?)",
                arguments: [DatabaseValueCodec.encode(deckID), reviewedAtMilliseconds, reviewedAtMilliseconds]
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
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(id),
                        DatabaseValueCodec.encode(noteID),
                        template.rawValue,
                        reviewedAtMilliseconds,
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
            try db.execute(
                sql: """
                    INSERT INTO daily_tasks(
                        study_day_id, card_id, category_at_admission, admitted_at_ms
                    ) VALUES (?, ?, 'new', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    DatabaseValueCodec.encode(cardID),
                    reviewedAtMilliseconds
                ]
            )
        }
        return ReviewSubmissionFixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            deckID: deckID,
            noteID: noteID,
            cardID: cardID,
            siblingCardID: siblingCardID,
            profileID: profileID,
            studyDayID: studyDayID
        )
    }

    func request(eventID: UUID, cardID: UUID) -> SubmitReviewRequest {
        SubmitReviewRequest(
            eventID: eventID,
            cardID: cardID,
            expectedStateVersion: 0,
            rating: .good,
            durationMilliseconds: 900,
            studyDay: StudyDayContext(id: studyDayID)
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
