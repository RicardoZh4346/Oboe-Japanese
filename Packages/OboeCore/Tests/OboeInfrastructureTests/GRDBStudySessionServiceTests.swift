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

    func addVocabularyNote() async throws -> UUID {
        let noteID = UUID()
        let exampleID = UUID()
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
        let cardID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, 0, ?, NULL, 0, 0, 0, 0, 0, 0, 0,
                              NULL, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    try DatabaseValueCodec.encode(now),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return cardID
    }

    func setEnabled(_ enabled: Bool, cardID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = ? WHERE id = ?",
                arguments: [enabled, DatabaseValueCodec.encode(cardID)]
            )
        }
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
