import Foundation
import XCTest
@testable import OboeDomain
@testable import OboeInfrastructure

/// T26 integration: the two-endpoint report reads a real GRDB database —
/// valid-log filtering (undone excluded), live-card set (deleted card_key
/// history never reattaches), suspend semantics and reopen determinism.
final class GRDBAdaptiveTrendTests: XCTestCase {
    private var fixture: AdaptiveDatabaseFixture!
    private var repository: GRDBAdaptiveRepository!
    private var service: AdaptiveTrendService!
    /// Fixture base (Saturday 2026-08-29 18:40 Asia/Shanghai); week start
    /// in the fixture's learning zone is Monday 2026-08-24 04:00 +08:00 —
    /// every seeded log at ≥6 days before base sits before t0.
    private let now = AdaptiveDatabaseFixture.baseDate
    private let timeZoneID = AdaptiveDatabaseFixture.timeZoneID

    override func setUp() async throws {
        fixture = try await AdaptiveDatabaseFixture.make()
        repository = GRDBAdaptiveRepository(database: fixture.database)
        service = AdaptiveTrendService(repository: repository)
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        repository = nil
        service = nil
    }

    func testWeekStartResolvesInLearningTimeZone() async throws {
        let report = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        // Monday 2026-08-24 04:00 Asia/Shanghai = 2026-08-23T20:00Z.
        XCTAssertEqual(report.weekStart, Date(timeIntervalSince1970: 1_787_515_200))
    }

    func testFixturePopulationMapsToTrendBuckets() async throws {
        let report = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        // Six live cards; only lapsedCard is leech — at both ends (its six
        // Again logs all precede t0). freshNote has no logs, undoneNote's
        // newest Again is undone, the orphaned deleted-card history does
        // not attach to anything.
        XCTAssertEqual(report.analyzedCardCount, 6)
        XCTAssertEqual(report.weekStartLeechCount, 1)
        XCTAssertEqual(report.currentLeechCount, 1)
        XCTAssertEqual(report.stillLeechCount, 1)
        XCTAssertEqual(report.weekLeechCount, 1)
        XCTAssertEqual(report.newlyAppearedCount, 0)
        XCTAssertEqual(report.recoveredStableCount, 0)
        XCTAssertEqual(report.improvedCount, 0)
        XCTAssertEqual(report.suspendedCount, 0)
    }

    func testNewlyAppearedWhenLeechFormsAfterWeekStart() async throws {
        let noteID = UUID()
        try await fixture.insertNote(
            noteID, deckID: fixture.deckAID,
            headword: "新弱", reading: "しんじゃく", meaningZH: "新增弱项"
        )
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        // Six Again logs AFTER t0 (within the last ~4 days before base).
        for index in 0..<6 {
            let reviewedAt = now.addingTimeInterval(TimeInterval(-(index + 1)) * 14_400)
            try await fixture.insertReviewLog(
                cardKey: cardID, cardID: cardID, noteID: noteID,
                deckID: fixture.deckAID,
                rating: .again,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review, dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3, difficulty: 8.8, repetitions: 10 + index,
                    lapses: 5, stateVersion: index * 2
                ),
                nextSnapshot: fixture.snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1, difficulty: 9, repetitions: 11 + index,
                    lapses: 6, stateVersion: index * 2 + 1
                )
            )
        }
        let report = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        XCTAssertEqual(report.weekStartLeechCount, 1)
        XCTAssertEqual(report.currentLeechCount, 2)
        XCTAssertEqual(report.newlyAppearedCount, 1)
        XCTAssertEqual(report.stillLeechCount, 1)
        XCTAssertEqual(report.weekLeechCount, 2)
    }

    func testSuspensionKeepsLeechCountedSeparatelyNotRecovered() async throws {
        let lapsedCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        try await fixture.updateScheduling(
            cardID: lapsedCard,
            state: .review,
            dueAt: now.addingTimeInterval(86_400),
            stability: 4.2, difficulty: 9.1, repetitions: 14, lapses: 6,
            firstStudiedAt: now.addingTimeInterval(-60 * 86_400),
            stateVersion: 14,
            isEnabled: false
        )
        let report = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        XCTAssertEqual(report.suspendedCount, 1)
        XCTAssertEqual(report.stillLeechCount, 1)
        XCTAssertEqual(report.recoveredStableCount, 0)
    }

    func testRecoveredExitNeedsDueSuccessesAndStability() async throws {
        let noteID = UUID()
        try await fixture.insertNote(
            noteID, deckID: fixture.deckAID,
            headword: "回稳", reading: "かいおん", meaningZH: "回稳"
        )
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        // Leech at t0: six pre-t0 Agains leaving lapses 6.
        for index in 0..<6 {
            let reviewedAt = now.addingTimeInterval(TimeInterval(-(8 + index)) * 86_400)
            try await fixture.insertReviewLog(
                cardKey: cardID, cardID: cardID, noteID: noteID,
                deckID: fixture.deckAID,
                rating: .again,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review, dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3, difficulty: 8.8, repetitions: 10 + index,
                    lapses: 5, stateVersion: index * 2
                ),
                nextSnapshot: fixture.snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1, difficulty: 9, repetitions: 11 + index,
                    lapses: 6, stateVersion: index * 2 + 1
                )
            )
        }
        // Recovery after t0: three due-review Goods ending in review state,
        // stability above the bar, no Again afterwards.
        for index in 0..<3 {
            let reviewedAt = now.addingTimeInterval(TimeInterval(-(3 - index)) * 86_400)
            try await fixture.insertReviewLog(
                cardKey: cardID, cardID: cardID, noteID: noteID,
                deckID: fixture.deckAID,
                rating: .good,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review, dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 15, difficulty: 6, repetitions: 16 + index,
                    lapses: 6, stateVersion: 20 + index * 2
                ),
                nextSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(30 * 86_400),
                    stability: 20, difficulty: 6, repetitions: 17 + index,
                    lapses: 6, stateVersion: 20 + index * 2 + 1
                )
            )
        }
        let report = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        XCTAssertEqual(report.weekStartLeechCount, 2)
        XCTAssertEqual(report.currentLeechCount, 1)
        XCTAssertEqual(report.recoveredStableCount, 1)
        XCTAssertEqual(report.improvedCount, 0)
        XCTAssertEqual(report.weekLeechCount, 2)
    }

    func testUndoneLogCannotCreateNewAppearance() async throws {
        let noteID = UUID()
        try await fixture.insertNote(
            noteID, deckID: fixture.deckAID,
            headword: "撤销", reading: "てっかい", meaningZH: "撤销"
        )
        let undoneCard = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        let validCard = try await fixture.addCard(
            noteID: noteID, template: .vocabularyChineseToJapanese
        )
        // Identical post-t0 Again snapshots leaving lapses 6 — one undone.
        let reviewedAt = now.addingTimeInterval(-86_400)
        for (cardID, undone) in [(undoneCard, true), (validCard, false)] {
            try await fixture.insertReviewLog(
                cardKey: cardID, cardID: cardID, noteID: noteID,
                deckID: fixture.deckAID,
                rating: .again,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review, dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3, difficulty: 8.8, repetitions: 10,
                    lapses: 5, stateVersion: 10
                ),
                nextSnapshot: fixture.snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1, difficulty: 9, repetitions: 11,
                    lapses: 6, stateVersion: 11
                ),
                undoneAt: undone ? now : nil
            )
        }
        let report = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        // Only the still-valid sibling contributes a new appearance —
        // the undone log's nextState is never reconstructed from.
        XCTAssertEqual(report.newlyAppearedCount, 1)
        XCTAssertEqual(report.currentLeechCount, 2)
        XCTAssertEqual(report.weekLeechCount, 2)
    }

    func testReportIsDeterministicAcrossDatabaseReopen() async throws {
        let first = try await service.report(at: now, learningTimeZoneID: timeZoneID)
        try fixture.database.close()
        let reopened = try OboeDatabase(path: fixture.databaseURL.path)
        defer { try? reopened.close() }
        let second = try await AdaptiveTrendService(
            repository: GRDBAdaptiveRepository(database: reopened)
        ).report(at: now, learningTimeZoneID: timeZoneID)

        XCTAssertEqual(second.weekStart, first.weekStart)
        XCTAssertEqual(second.analyzedCardCount, first.analyzedCardCount)
        XCTAssertEqual(second.weekStartLeechCount, first.weekStartLeechCount)
        XCTAssertEqual(second.currentLeechCount, first.currentLeechCount)
        XCTAssertEqual(second.weekLeechCount, first.weekLeechCount)
        XCTAssertEqual(second.newlyAppearedCount, first.newlyAppearedCount)
        XCTAssertEqual(second.stillLeechCount, first.stillLeechCount)
        XCTAssertEqual(second.recoveredStableCount, first.recoveredStableCount)
        XCTAssertEqual(second.improvedCount, first.improvedCount)
        XCTAssertEqual(second.suspendedCount, first.suspendedCount)
    }
}
