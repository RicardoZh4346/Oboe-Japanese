import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBStudyDayPlanningRepositoryTests: XCTestCase {
    func testFourAMBoundaryAndDSTUseCalendarDays() throws {
        let calculator = StudyDayBoundaryCalculator()
        let shanghai = "Asia/Shanghai"
        let beforeRollover = localDate(2026, 9, 10, 3, 59, timeZoneID: shanghai)
        let atRollover = localDate(2026, 9, 10, 4, 0, timeZoneID: shanghai)

        let beforeDay = try calculator.studyDay(
            containing: beforeRollover,
            timeZoneID: shanghai,
            newCardLimit: 10
        )
        let nextDay = try calculator.studyDay(
            containing: atRollover,
            timeZoneID: shanghai,
            newCardLimit: 10
        )

        XCTAssertEqual(beforeDay.localDate, "2026-09-09")
        XCTAssertEqual(beforeDay.endsAt, atRollover)
        XCTAssertEqual(nextDay.localDate, "2026-09-10")
        XCTAssertEqual(nextDay.startsAt, atRollover)

        let newYork = "America/New_York"
        let spring = try calculator.studyDay(
            containing: localDate(2026, 3, 7, 12, 0, timeZoneID: newYork),
            timeZoneID: newYork,
            newCardLimit: 10
        )
        let fall = try calculator.studyDay(
            containing: localDate(2026, 10, 31, 12, 0, timeZoneID: newYork),
            timeZoneID: newYork,
            newCardLimit: 10
        )
        XCTAssertEqual(spring.endsAt.timeIntervalSince(spring.startsAt), 23 * 3_600)
        XCTAssertEqual(fall.endsAt.timeIntervalSince(fall.startsAt), 25 * 3_600)
    }

    func testTimeZoneChangeAppliesNextStudyDayWithoutOverlapAndPersists() async throws {
        let fixture = try await StudyPlanFixture.make()
        defer { fixture.remove() }
        let repository = GRDBStudyDayPlanningRepository(database: fixture.database)
        let prepare = PrepareStudyDay(repository: repository)
        let instant = localDate(2026, 9, 10, 12, 0, timeZoneID: "Asia/Shanghai")

        let first = try await prepare(at: instant, defaultTimeZoneID: "Asia/Shanghai")
        _ = try await prepare.setLearningTimeZone(
            "Asia/Tokyo",
            defaultTimeZoneID: "Asia/Shanghai"
        )
        let beforeEnd = try await prepare(
            at: first.studyDay.endsAt.addingTimeInterval(-1),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        let transitioned = try await prepare(
            at: first.studyDay.endsAt,
            defaultTimeZoneID: "Asia/Shanghai"
        )

        XCTAssertEqual(beforeEnd.studyDay.id, first.studyDay.id)
        XCTAssertEqual(beforeEnd.studyDay.timeZoneID, "Asia/Shanghai")
        XCTAssertNotEqual(transitioned.studyDay.id, first.studyDay.id)
        XCTAssertEqual(transitioned.studyDay.timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(transitioned.studyDay.startsAt, first.studyDay.endsAt)
        XCTAssertGreaterThan(transitioned.studyDay.endsAt, transitioned.studyDay.startsAt)

        try fixture.database.close()
        let reopened = try OboeDatabase(path: fixture.databaseURL.path)
        let persisted = try await GRDBStudyDayPlanningRepository(database: reopened)
            .fetchStudyDay(containing: first.studyDay.endsAt)
        XCTAssertEqual(persisted, transitioned.studyDay)
        try reopened.close()
    }

    func testRetentionChangeCreatesImmutableProfileAndOnlyChangesFutureScheduling() async throws {
        let fixture = try await StudyPlanFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck(sortOrder: 0)
        let cardIDs = try await fixture.addVocabulary(
            deckID: deckID,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 0
        )
        let cardID = try XCTUnwrap(cardIDs.first)
        let repository = GRDBStudyDayPlanningRepository(database: fixture.database)
        _ = try await repository.loadOrCreateSettings(defaultTimeZoneID: "Asia/Shanghai")
        let before = try await fixture.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT due_at_ms, state_version, profile_id FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ).map { ($0["due_at_ms"] as Int64?, $0["state_version"] as Int?, $0["profile_id"] as String?) }
        }

        let settings = try await repository.updateRetentionPreset(.intensive)

        XCTAssertEqual(settings.retentionPreset, .intensive)
        let after = try await fixture.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT due_at_ms, state_version, profile_id FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ).map { ($0["due_at_ms"] as Int64?, $0["state_version"] as Int?, $0["profile_id"] as String?) }
        }
        XCTAssertEqual(after?.0, before?.0)
        XCTAssertEqual(after?.1, before?.1)
        XCTAssertNotEqual(after?.2, before?.2)

        let loadedContext = try await GRDBReviewSubmissionRepository(database: fixture.database)
            .fetchReviewContext(cardID: cardID)
        let context = try XCTUnwrap(loadedContext)
        XCTAssertEqual(context.profile.targetRetention, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(
            context.profile.configurationVersion,
            SchedulerProfile(preset: .intensive).configurationVersion
        )
        let profileCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduler_profiles") ?? 0
        }
        XCTAssertEqual(profileCount, 2, "旧配置必须保留以解释历史评分")
    }

    func testLimitZeroDecreaseIncreaseAndReopenKeepStableReservations() async throws {
        let fixture = try await StudyPlanFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck(sortOrder: 0)
        for index in 0..<5 {
            _ = try await fixture.addVocabulary(
                deckID: deckID,
                templates: [.vocabularyJapaneseToChinese],
                sequence: index
            )
        }
        let instant = localDate(2026, 9, 10, 12, 0, timeZoneID: "Asia/Shanghai")
        let prepare = PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        )

        let zero = try await prepare.setDailyNewCardLimit(
            0,
            at: instant,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(zero.reservedCount, 0)
        XCTAssertEqual(zero.availableCount, 0)

        let four = try await prepare.setDailyNewCardLimit(
            4,
            at: instant,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        let originalOrder = four.reservations.map(\.cardID)
        XCTAssertEqual(originalOrder.count, 4)

        let one = try await prepare.setDailyNewCardLimit(
            1,
            at: instant.addingTimeInterval(10),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(one.reservations.map(\.cardID), Array(originalOrder.prefix(1)))

        let three = try await prepare.setDailyNewCardLimit(
            3,
            at: instant.addingTimeInterval(20),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(three.reservations.map(\.cardID), Array(originalOrder.prefix(3)))

        try fixture.database.close()
        let reopened = try OboeDatabase(path: fixture.databaseURL.path)
        let reopenedPlan = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: reopened)
        )(at: instant.addingTimeInterval(30), defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(reopenedPlan.reservations, three.reservations)
        try reopened.close()
    }

    func testGlobalReservationRoundRobinsDecksAndCountsTwoDirectionsSeparately() async throws {
        let fixture = try await StudyPlanFixture.make()
        defer { fixture.remove() }
        let firstDeck = try await fixture.addDeck(sortOrder: 0)
        let secondDeck = try await fixture.addDeck(sortOrder: 1)
        let dualCards = try await fixture.addVocabulary(
            deckID: firstDeck,
            templates: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese],
            sequence: 0
        )
        _ = try await fixture.addVocabulary(
            deckID: firstDeck,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 1
        )
        _ = try await fixture.addVocabulary(
            deckID: secondDeck,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 2
        )
        _ = try await fixture.addVocabulary(
            deckID: secondDeck,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 3
        )
        let instant = localDate(2026, 9, 10, 12, 0, timeZoneID: "Asia/Shanghai")
        let plan = try await PrepareStudyDay(
            repository: GRDBStudyDayPlanningRepository(database: fixture.database)
        ).setDailyNewCardLimit(4, at: instant, defaultTimeZoneID: "Asia/Shanghai")

        XCTAssertEqual(plan.reservedCount, 4)
        XCTAssertEqual(plan.availableCount, 0)
        XCTAssertEqual(plan.reservations.map(\.deckID), [
            firstDeck, secondDeck, firstDeck, secondDeck
        ])
        XCTAssertEqual(Set(plan.reservations.map(\.cardID)).intersection(dualCards).count, 2)
    }

    func testNewContentFillsRemainingSlotAndDeletingStudiedCardDoesNotRefundQuota() async throws {
        let fixture = try await StudyPlanFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck(sortOrder: 0)
        let firstNote = try await fixture.addVocabulary(
            deckID: deckID,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 0
        )
        let instant = localDate(2026, 9, 10, 12, 0, timeZoneID: "Asia/Shanghai")
        let repository = GRDBStudyDayPlanningRepository(database: fixture.database)
        let prepare = PrepareStudyDay(repository: repository)
        let initial = try await prepare.setDailyNewCardLimit(
            2,
            at: instant,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(initial.reservedCount, 1)
        XCTAssertEqual(initial.availableCount, 1)

        let secondCards = try await fixture.addVocabulary(
            deckID: deckID,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 1
        )
        let filled = try await prepare(
            at: instant.addingTimeInterval(1),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(filled.reservedCount, 2)
        XCTAssertEqual(filled.availableCount, 0)

        let thirdCards = try await fixture.addVocabulary(
            deckID: deckID,
            templates: [.vocabularyJapaneseToChinese],
            sequence: 2
        )
        let studiedCardID = try XCTUnwrap(firstNote.first)
        try await fixture.insertReviewLog(
            cardID: studiedCardID,
            studyDayID: filled.studyDay.id,
            wasFirstStudy: true,
            at: instant.addingTimeInterval(2)
        )
        try await fixture.insertReviewLog(
            cardID: studiedCardID,
            studyDayID: filled.studyDay.id,
            wasFirstStudy: false,
            at: instant.addingTimeInterval(3)
        )
        try await fixture.deleteNote(containing: studiedCardID)

        let afterDeletion = try await prepare(
            at: instant.addingTimeInterval(4),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(afterDeletion.usedCount, 1)
        XCTAssertEqual(afterDeletion.reservedCount, 1)
        XCTAssertEqual(afterDeletion.reservations.map(\.cardID), secondCards)
        XCTAssertTrue(Set(afterDeletion.reservations.map(\.cardID)).isDisjoint(with: thirdCards))
        XCTAssertEqual(afterDeletion.availableCount, 0)

        let loweredBelowUsed = try await prepare.setDailyNewCardLimit(
            0,
            at: instant.addingTimeInterval(5),
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(loweredBelowUsed.usedCount, 1)
        XCTAssertEqual(loweredBelowUsed.reservedCount, 0)
        XCTAssertEqual(loweredBelowUsed.availableCount, 0)
    }
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    timeZoneID: String
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneID)!
    return calendar.date(
        from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

private final class StudyPlanFixture: @unchecked Sendable {
    let directoryURL: URL
    let databaseURL: URL
    let database: OboeDatabase
    let profileID: UUID
    private let baseMilliseconds: Int64 = 1_778_457_600_000

    private init(
        directoryURL: URL,
        databaseURL: URL,
        database: OboeDatabase,
        profileID: UUID
    ) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.database = database
        self.profileID = profileID
    }

    static func make() async throws -> StudyPlanFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-P10a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let database = try OboeDatabase(path: databaseURL.path)
        let profileID = UUID()
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        try await database.pool.write { db in
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
        return StudyPlanFixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            profileID: profileID
        )
    }

    func addDeck(sortOrder: Int) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    "Deck \(sortOrder)",
                    sortOrder,
                    baseMilliseconds + Int64(sortOrder),
                    baseMilliseconds + Int64(sortOrder)
                ]
            )
        }
        return id
    }

    func addVocabulary(
        deckID: UUID,
        templates: [CardTemplateKind],
        sequence: Int
    ) async throws -> [UUID] {
        let noteID = UUID()
        let cardIDs = templates.map { _ in UUID() }
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, '含义', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    "词 \(sequence)",
                    baseMilliseconds + Int64(sequence),
                    baseMilliseconds + Int64(sequence)
                ]
            )
            for (index, template) in templates.enumerated() {
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
                        DatabaseValueCodec.encode(cardIDs[index]),
                        DatabaseValueCodec.encode(noteID),
                        template.rawValue,
                        baseMilliseconds + Int64(sequence * 10 + index),
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
        }
        return cardIDs
    }

    func insertReviewLog(
        cardID: UUID,
        studyDayID: UUID,
        wasFirstStudy: Bool,
        at instant: Date
    ) async throws {
        try await database.pool.write { db in
            let noteID: String = try String.fetchOne(
                db,
                sql: "SELECT note_id FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )!
            let deckID: String = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [noteID]
            )!
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study, rating,
                        previous_state_json, next_state_json, duration_ms, content_version,
                        profile_id, algorithm_version
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 3, '{}', '{}', 1, 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(cardID),
                    noteID,
                    deckID,
                    try DatabaseValueCodec.encode(instant),
                    DatabaseValueCodec.encode(studyDayID),
                    wasFirstStudy,
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion
                ]
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
