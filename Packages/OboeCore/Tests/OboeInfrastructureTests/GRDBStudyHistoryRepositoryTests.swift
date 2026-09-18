import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBStudyHistoryRepositoryTests: XCTestCase {
    func testTodayStatisticsExcludeUndoAndKeepCountsAfterContentDeletion() async throws {
        let fixture = try await StudyHistoryFixture.make()
        defer { fixture.remove() }
        let repository = GRDBStudyHistoryRepository(database: fixture.database)

        let statistics = try await repository.fetchTodayStatistics(
            studyDayID: fixture.studyDayID
        )

        XCTAssertEqual(statistics.newLearnedCount, 1)
        XCTAssertEqual(statistics.reviewAnswerCount, 1)
        XCTAssertEqual(statistics.answerCount, 2)
        XCTAssertEqual(statistics.ratings.again, 1)
        XCTAssertEqual(statistics.ratings.hard, 0)
        XCTAssertEqual(statistics.ratings.good, 1)
        XCTAssertEqual(statistics.ratings.easy, 0)
        XCTAssertEqual(statistics.ratings.total, 2)
        XCTAssertEqual(
            statistics.tasks(for: fixture.deckID),
            DeckTodayTaskCount(deckID: fixture.deckID, newCount: 1, reviewCount: 1)
        )

        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.noteID)]
            )
        }
        let afterDeletion = try await repository.fetchTodayStatistics(
            studyDayID: fixture.studyDayID
        )
        XCTAssertEqual(afterDeletion.newLearnedCount, 1)
        XCTAssertEqual(afterDeletion.reviewAnswerCount, 1)
        XCTAssertEqual(afterDeletion.answerCount, 2)
        XCTAssertEqual(afterDeletion.ratings, statistics.ratings)
        XCTAssertTrue(afterDeletion.deckTaskCounts.isEmpty)
    }

    func testCardHistoryGroupsDirectionsAndRetainsUndoneAuditEntry() async throws {
        let fixture = try await StudyHistoryFixture.make()
        defer { fixture.remove() }
        let repository = GRDBStudyHistoryRepository(database: fixture.database)

        let histories = try await repository.fetchCardHistories(noteID: fixture.noteID)

        XCTAssertEqual(histories.count, 2)
        let forward = try XCTUnwrap(histories.first {
            $0.cardID == fixture.forwardCardID
        })
        XCTAssertEqual(forward.templateKind, .vocabularyJapaneseToChinese)
        XCTAssertEqual(forward.entries.count, 3)
        XCTAssertEqual(forward.activeAnswerCount, 2)
        XCTAssertEqual(forward.lastReviewedAt, fixture.baseDate.addingTimeInterval(130))
        XCTAssertEqual(forward.entries.map(\.rating), [.good, .good, .again])
        XCTAssertEqual(forward.entries.map(\.isUndone), [false, true, false])
        XCTAssertEqual(forward.entries.last?.wasFirstStudy, true)

        let reverse = try XCTUnwrap(histories.first {
            $0.cardID == fixture.reverseCardID
        })
        XCTAssertEqual(reverse.templateKind, .vocabularyChineseToJapanese)
        XCTAssertTrue(reverse.entries.isEmpty)
        XCTAssertEqual(reverse.activeAnswerCount, 0)
        XCTAssertNil(reverse.lastReviewedAt)
    }

    func testCompletionStatisticsDeduplicateCardsAndScopeByDeckAtReview() async throws {
        let fixture = try await StudyHistoryFixture.make()
        defer { fixture.remove() }
        let repository = GRDBStudyHistoryRepository(database: fixture.database)
        let deckB = try await fixture.addDeck()

        try await fixture.addReviewLog(
            cardID: fixture.forwardCardID, noteID: fixture.noteID,
            deckID: fixture.deckID, rating: .easy, wasFirstStudy: false,
            at: fixture.baseDate.addingTimeInterval(200)
        )
        let cardB = try await fixture.addCard(inDeck: deckB)
        try await fixture.addReviewLog(
            cardID: cardB.cardID, noteID: cardB.noteID,
            deckID: deckB, rating: .hard, wasFirstStudy: false,
            at: fixture.baseDate.addingTimeInterval(210)
        )
        let movedCard = try await fixture.addCard(inDeck: deckB)
        try await fixture.addReviewLog(
            cardID: movedCard.cardID, noteID: movedCard.noteID,
            deckID: fixture.deckID, rating: .again, wasFirstStudy: false,
            at: fixture.baseDate.addingTimeInterval(220)
        )

        let global = try await repository.fetchCompletionStatistics(
            studyDayID: fixture.studyDayID, deckID: nil
        )
        XCTAssertEqual(global.newLearnedCardCount, 1)
        XCTAssertEqual(global.reviewedCardCount, 2)
        XCTAssertEqual(global.studiedCardCount, 3)
        XCTAssertEqual(global.answerCount, 5)
        XCTAssertEqual(
            global.ratings,
            RatingDistribution(again: 2, hard: 1, good: 1, easy: 1)
        )

        let scopeA = try await repository.fetchCompletionStatistics(
            studyDayID: fixture.studyDayID, deckID: fixture.deckID
        )
        XCTAssertEqual(scopeA.newLearnedCardCount, 1)
        XCTAssertEqual(scopeA.reviewedCardCount, 1)
        XCTAssertEqual(scopeA.answerCount, 4)
        XCTAssertEqual(
            scopeA.ratings,
            RatingDistribution(again: 2, hard: 0, good: 1, easy: 1)
        )

        let scopeB = try await repository.fetchCompletionStatistics(
            studyDayID: fixture.studyDayID, deckID: deckB
        )
        XCTAssertEqual(scopeB.newLearnedCardCount, 0)
        XCTAssertEqual(scopeB.reviewedCardCount, 1)
        XCTAssertEqual(scopeB.answerCount, 1)
        XCTAssertEqual(
            scopeB.ratings,
            RatingDistribution(again: 0, hard: 1, good: 0, easy: 0)
        )

        let emptyDeck = try await fixture.addDeck()
        let empty = try await repository.fetchCompletionStatistics(
            studyDayID: fixture.studyDayID, deckID: emptyDeck
        )
        XCTAssertEqual(empty, StudyCompletionStatistics(
            newLearnedCardCount: 0,
            reviewedCardCount: 0,
            answerCount: 0,
            ratings: RatingDistribution(again: 0, hard: 0, good: 0, easy: 0)
        ))
    }
}

private final class StudyHistoryFixture: @unchecked Sendable {
    let directoryURL: URL
    let database: OboeDatabase
    let deckID: UUID
    let noteID: UUID
    let forwardCardID: UUID
    let reverseCardID: UUID
    let studyDayID: UUID
    let profileID: UUID
    let baseDate: Date

    private init(
        directoryURL: URL,
        database: OboeDatabase,
        deckID: UUID,
        noteID: UUID,
        forwardCardID: UUID,
        reverseCardID: UUID,
        studyDayID: UUID,
        profileID: UUID,
        baseDate: Date
    ) {
        self.directoryURL = directoryURL
        self.database = database
        self.deckID = deckID
        self.noteID = noteID
        self.forwardCardID = forwardCardID
        self.reverseCardID = reverseCardID
        self.studyDayID = studyDayID
        self.profileID = profileID
        self.baseDate = baseDate
    }

    static func make() async throws -> StudyHistoryFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-P12b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        let deckID = UUID()
        let noteID = UUID()
        let forwardCardID = UUID()
        let reverseCardID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_768_478_400)
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let newState = SchedulingCard(dueAt: baseDate)
        let learningState = SchedulingCard(
            dueAt: baseDate.addingTimeInterval(60),
            stability: 0.2,
            difficulty: 7,
            elapsedDays: 0,
            scheduledDays: 0,
            learningStep: 1,
            repetitions: 1,
            state: .learning,
            lastReviewAt: baseDate.addingTimeInterval(10)
        )
        let reviewState = SchedulingCard(
            dueAt: baseDate.addingTimeInterval(86_400),
            stability: 2.5,
            difficulty: 6,
            elapsedDays: 0,
            scheduledDays: 1,
            repetitions: 2,
            state: .review,
            lastReviewAt: baseDate.addingTimeInterval(130)
        )
        let beforeFirst = ReviewSchedulingSnapshot(
            scheduling: newState,
            firstStudiedAt: nil,
            stateVersion: 0,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        let afterFirst = ReviewSchedulingSnapshot(
            scheduling: learningState,
            firstStudiedAt: baseDate.addingTimeInterval(10),
            stateVersion: 1,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        let afterGood = ReviewSchedulingSnapshot(
            scheduling: reviewState,
            firstStudiedAt: baseDate.addingTimeInterval(10),
            stateVersion: 2,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P12b', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', 1, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID), DatabaseValueCodec.encode(deckID)]
            )
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
            for (id, template, state) in [
                (forwardCardID, CardTemplateKind.vocabularyJapaneseToChinese, learningState),
                (reverseCardID, CardTemplateKind.vocabularyChineseToJapanese, reviewState)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            last_review_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(noteID),
                        template.rawValue, state.state.rawValue,
                        try DatabaseValueCodec.encode(state.dueAt),
                        try state.lastReviewAt.map(DatabaseValueCodec.encode),
                        state.stability, state.difficulty, state.repetitions, state.lapses,
                        state.scheduledDays, state.elapsedDays, state.learningStep,
                        try DatabaseValueCodec.encode(baseDate.addingTimeInterval(10)),
                        id == forwardCardID ? 1 : 2,
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
                    try DatabaseValueCodec.encode(baseDate),
                    try DatabaseValueCodec.encode(baseDate.addingTimeInterval(86_400))
                ]
            )
            for (id, category, offset) in [
                (forwardCardID, "new", 0),
                (reverseCardID, "review", 1)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO daily_tasks(
                            study_day_id, card_id, category_at_admission, admitted_at_ms
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(studyDayID), DatabaseValueCodec.encode(id),
                        category, try DatabaseValueCodec.encode(baseDate) + Int64(offset)
                    ]
                )
            }
            try insertLog(
                db: db, cardID: forwardCardID, noteID: noteID, deckID: deckID,
                studyDayID: studyDayID, profileID: profileID,
                at: baseDate.addingTimeInterval(10), rating: .again,
                wasFirstStudy: true, previous: beforeFirst, next: afterFirst
            )
            try insertLog(
                db: db, cardID: forwardCardID, noteID: noteID, deckID: deckID,
                studyDayID: studyDayID, profileID: profileID,
                at: baseDate.addingTimeInterval(70), rating: .good,
                wasFirstStudy: false, previous: afterFirst, next: afterGood,
                undoneAt: baseDate.addingTimeInterval(80)
            )
            try insertLog(
                db: db, cardID: forwardCardID, noteID: noteID, deckID: deckID,
                studyDayID: studyDayID, profileID: profileID,
                at: baseDate.addingTimeInterval(130), rating: .good,
                wasFirstStudy: false, previous: afterFirst, next: afterGood
            )
        }
        return StudyHistoryFixture(
            directoryURL: directoryURL,
            database: database,
            deckID: deckID,
            noteID: noteID,
            forwardCardID: forwardCardID,
            reverseCardID: reverseCardID,
            studyDayID: studyDayID,
            profileID: profileID,
            baseDate: baseDate
        )
    }

    func addDeck() async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P12b-B', 1, 1, 1)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
        return id
    }

    func addCard(inDeck deckID: UUID) async throws -> (cardID: UUID, noteID: UUID) {
        let noteID = UUID()
        let cardID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '読む', '读', 1, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID), DatabaseValueCodec.encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, 2, ?, ?, 2.5, 6, 2, 0, 1, 0, 0, ?, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID), DatabaseValueCodec.encode(noteID),
                    CardTemplateKind.vocabularyJapaneseToChinese.rawValue,
                    try DatabaseValueCodec.encode(baseDate.addingTimeInterval(86_400)),
                    try DatabaseValueCodec.encode(baseDate),
                    try DatabaseValueCodec.encode(baseDate),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return (cardID, noteID)
    }

    func addReviewLog(
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        rating: ReviewRating,
        wasFirstStudy: Bool,
        at date: Date,
        undoneAt: Date? = nil
    ) async throws {
        let snapshot = ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: date.addingTimeInterval(86_400),
                stability: 2.5,
                difficulty: 6,
                scheduledDays: 1,
                repetitions: 2,
                state: .review,
                lastReviewAt: date
            ),
            firstStudiedAt: baseDate,
            stateVersion: 1,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        try await database.pool.write { db in
            try Self.insertLog(
                db: db, cardID: cardID, noteID: noteID, deckID: deckID,
                studyDayID: studyDayID, profileID: profileID,
                at: date, rating: rating, wasFirstStudy: wasFirstStudy,
                previous: snapshot, next: snapshot, undoneAt: undoneAt
            )
        }
    }

    private static func insertLog(
        db: Database,
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        studyDayID: UUID,
        profileID: UUID,
        at date: Date,
        rating: ReviewRating,
        wasFirstStudy: Bool,
        previous: ReviewSchedulingSnapshot,
        next: ReviewSchedulingSnapshot,
        undoneAt: Date? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try db.execute(
            sql: """
                INSERT INTO review_logs(
                    id, event_id, card_id, card_key, note_id, deck_id_at_review,
                    reviewed_at_ms, study_day_id, was_first_study, rating,
                    previous_state_json, next_state_json, duration_ms, content_version,
                    profile_id, algorithm_version, undone_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 500, 1, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(UUID()), DatabaseValueCodec.encode(UUID()),
                DatabaseValueCodec.encode(cardID), DatabaseValueCodec.encode(cardID),
                DatabaseValueCodec.encode(noteID), DatabaseValueCodec.encode(deckID),
                try DatabaseValueCodec.encode(date), DatabaseValueCodec.encode(studyDayID),
                wasFirstStudy, rating.rawValue,
                String(decoding: try encoder.encode(previous), as: UTF8.self),
                String(decoding: try encoder.encode(next), as: UTF8.self),
                DatabaseValueCodec.encode(profileID), SwiftFSRSReviewScheduler.algorithmVersion,
                try undoneAt.map(DatabaseValueCodec.encode)
            ]
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
