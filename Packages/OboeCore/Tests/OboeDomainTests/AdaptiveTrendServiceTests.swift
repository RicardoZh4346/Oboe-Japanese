import Foundation
import XCTest
@testable import OboeDomain

/// T26: two-endpoint weekly trend (design §12). The report fixes the CURRENT
/// live-card set, rebuilds each card's state at week-start t0 and now t1 from
/// valid logs only, and classifies both ends with the same LeechClassifier.
final class AdaptiveTrendServiceTests: XCTestCase {
    /// Wednesday 2026-09-16 12:00 Asia/Shanghai — week start is
    /// Monday 2026-09-14 04:00 +08:00 (2026-09-13T20:00:00Z).
    private let now = Date(timeIntervalSince1970: 1_789_531_200)
    private let timeZoneID = "Asia/Shanghai"
    private var t0: Date!
    private var t1: Date!

    override func setUp() async throws {
        t1 = now
        t0 = try AdaptiveTrendWeek.start(atOrBefore: t1, timeZoneID: timeZoneID)
    }

    // MARK: - Week boundary

    func testWeekStartIsMondayRolloverInLearningTimeZone() throws {
        // 2026-09-16 12:00 +08:00 (Wednesday) → Monday 04:00 same week.
        XCTAssertEqual(
            t0,
            Date(timeIntervalSince1970: 1_789_329_600) // 2026-09-14T04:00+08:00
        )
    }

    func testWeekStartBeforeMondayRolloverBelongsToPreviousWeek() throws {
        // Monday 2026-09-14 03:00 +08:00 → still last week.
        let mondayEarly = Date(timeIntervalSince1970: 1_789_326_000)
        let start = try AdaptiveTrendWeek.start(
            atOrBefore: mondayEarly,
            timeZoneID: timeZoneID
        )
        // Previous Monday 2026-09-07 04:00 +08:00.
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_788_724_800))
    }

    func testWeekStartAtExactBoundaryIsItself() throws {
        let boundary = Date(timeIntervalSince1970: 1_789_329_600)
        let start = try AdaptiveTrendWeek.start(
            atOrBefore: boundary,
            timeZoneID: timeZoneID
        )
        XCTAssertEqual(start, boundary)
    }

    func testWeekStartUsesLearningZoneNotDeviceZone() throws {
        // The same instant is Monday-04:30 in Shanghai but Sunday-13:30 in
        // Los Angeles — the boundaries differ by a week edge.
        let instant = Date(timeIntervalSince1970: 1_789_331_400)
        let shanghai = try AdaptiveTrendWeek.start(
            atOrBefore: instant,
            timeZoneID: "Asia/Shanghai"
        )
        let losAngeles = try AdaptiveTrendWeek.start(
            atOrBefore: instant,
            timeZoneID: "America/Los_Angeles"
        )
        XCTAssertEqual(shanghai, Date(timeIntervalSince1970: 1_789_329_600))
        XCTAssertEqual(losAngeles, Date(timeIntervalSince1970: 1_788_778_800))
        XCTAssertNotEqual(shanghai, losAngeles)
    }

    func testInvalidTimeZoneThrows() {
        XCTAssertThrowsError(
            try AdaptiveTrendWeek.start(atOrBefore: t1, timeZoneID: "Mars/Olympus")
        ) { error in
            XCTAssertEqual(
                error as? StudyDayPlanningError,
                .invalidTimeZone("Mars/Olympus")
            )
        }
    }

    // MARK: - Set membership

    func testStillLeechCountsCardLeechAtBothEnds() async throws {
        let card = makeRecord(samples: leechLogs(daysBeforeT1: [10, 8, 6, 5]))
        let report = try await report(records: [card])
        XCTAssertEqual(report.stillLeechCount, 1)
        XCTAssertEqual(report.weekLeechCount, 1)
        XCTAssertEqual(report.weekStartLeechCount, 1)
        XCTAssertEqual(report.currentLeechCount, 1)
        XCTAssertEqual(report.newlyAppearedCount, 0)
        XCTAssertEqual(report.recoveredStableCount, 0)
        XCTAssertEqual(report.improvedCount, 0)
        XCTAssertEqual(report.analyzedCardCount, 1)
    }

    func testNewlyAppearedCountsOnlyPostStartLeech() async throws {
        let card = makeRecord(samples: leechLogs(daysBeforeT1: [2, 1]))
        let report = try await report(records: [card])
        XCTAssertEqual(report.newlyAppearedCount, 1)
        XCTAssertEqual(report.stillLeechCount, 0)
        XCTAssertEqual(report.weekStartLeechCount, 0)
        XCTAssertEqual(report.currentLeechCount, 1)
        XCTAssertEqual(report.weekLeechCount, 1)
    }

    func testRecoveredStableCountsExitWithRecoveryEvidence() async throws {
        var samples = leechLogs(daysBeforeT1: [9, 8, 7, 6])
        // Three due-review successes AFTER the leech-forming history, ending
        // in review state with enough stability — recovery per the same rule.
        samples = recoveryLogs(daysBeforeT1: [2, 1.5, 1], stability: 20) + samples
        let card = makeRecord(samples: samples)
        let report = try await report(records: [card])
        XCTAssertEqual(report.weekStartLeechCount, 1)
        XCTAssertEqual(report.currentLeechCount, 0)
        XCTAssertEqual(report.recoveredStableCount, 1)
        XCTAssertEqual(report.improvedCount, 0)
        XCTAssertEqual(report.weekLeechCount, 1)
    }

    func testImprovedCountsExitWithoutRecoveryEvidence() async throws {
        // Leech at t0 via the recent-window burst (lapses kept below 6 so
        // rule A never fires); six Good due reviews clear the window at t1,
        // but stability stays under the recovery bar → 状态改善, not 恢复.
        var samples = burstLogs(daysBeforeT1: [12, 11, 10, 9, 8, 7, 6, 5, 4, 3.5])
        samples = recoveryLogs(daysBeforeT1: [2.2, 1.9, 1.6, 1.3, 1.0, 0.7], stability: 8)
            + samples
        let card = makeRecord(samples: samples)
        let report = try await report(records: [card])
        XCTAssertEqual(report.weekStartLeechCount, 1)
        XCTAssertEqual(report.currentLeechCount, 0)
        XCTAssertEqual(report.recoveredStableCount, 0)
        XCTAssertEqual(report.improvedCount, 1)
    }

    func testSuspendedLeechStaysCountedAndIsNotRecovery() async throws {
        let card = makeRecord(
            isEnabled: false,
            samples: leechLogs(daysBeforeT1: [10, 8, 5, 2])
        )
        let report = try await report(records: [card])
        XCTAssertEqual(report.stillLeechCount, 1)
        XCTAssertEqual(report.suspendedCount, 1)
        XCTAssertEqual(report.recoveredStableCount, 0)
    }

    func testRelapseAfterRecoveryCountsAsLeechNotRecovered() async throws {
        var samples = leechLogs(daysBeforeT1: [12, 11, 10, 9])
        samples = recoveryLogs(daysBeforeT1: [2.2, 1.9, 1.6], stability: 20) + samples
        // One fresh Again AFTER the recovery window — relapse, per the same
        // classifier (lapses 6 keeps rule A live → leech at t1).
        samples = [dueLog(.again, daysBeforeT1: 0.5, lapses: 6, stability: 1)] + samples
        let card = makeRecord(samples: samples)
        let report = try await report(records: [card])
        XCTAssertEqual(report.stillLeechCount, 1)
        XCTAssertEqual(report.recoveredStableCount, 0)
    }

    func testCardWithoutValidLogsIsNotStartedAtEitherEnd() async throws {
        let card = makeRecord(samples: [])
        let report = try await report(records: [card])
        XCTAssertEqual(report.analyzedCardCount, 1)
        XCTAssertEqual(report.weekLeechCount, 0)
        XCTAssertEqual(report.weekStartLeechCount, 0)
        XCTAssertEqual(report.currentLeechCount, 0)
    }

    func testReportSummarizesMixedPopulation() async throws {
        let records = [
            makeRecord(samples: leechLogs(daysBeforeT1: [10, 8, 5])),      // still
            makeRecord(samples: leechLogs(daysBeforeT1: [1])),            // new
            makeRecord(samples:
                recoveryLogs(daysBeforeT1: [2, 1.5, 1], stability: 20)
                    + leechLogs(daysBeforeT1: [9, 7, 6])),                // recovered
            makeRecord(isEnabled: false,
                       samples: leechLogs(daysBeforeT1: [10, 6, 2])),     // suspended still
            makeRecord(samples: [])                                        // not started
        ]
        let report = try await report(records: records)
        XCTAssertEqual(report.analyzedCardCount, 5)
        XCTAssertEqual(report.weekStartLeechCount, 3)
        XCTAssertEqual(report.currentLeechCount, 3)
        XCTAssertEqual(report.weekLeechCount, 4)
        XCTAssertEqual(report.stillLeechCount, 2)
        XCTAssertEqual(report.newlyAppearedCount, 1)
        XCTAssertEqual(report.recoveredStableCount, 1)
        XCTAssertEqual(report.improvedCount, 0)
        XCTAssertEqual(report.suspendedCount, 1)
        XCTAssertEqual(report.timeZoneID, timeZoneID)
        XCTAssertEqual(report.policyVersion, AdaptivePolicy.standard.version)
        XCTAssertEqual(report.weekStart, t0)
        XCTAssertEqual(report.generatedAt, t1)
    }

    // MARK: - Cache & invalidation

    func testReportCachesWithinGenerationAndTimeZoneBucket() async throws {
        let repository = StubAdaptiveRepository()
        let service = AdaptiveTrendService(repository: repository)
        _ = try await service.report(at: t1, learningTimeZoneID: timeZoneID)
        _ = try await service.report(at: t1, learningTimeZoneID: timeZoneID)
        XCTAssertEqual(repository.snapshotCalls, 1)
    }

    func testDataVersionAndTimeZoneChangesRefetch() async throws {
        let repository = StubAdaptiveRepository()
        let service = AdaptiveTrendService(repository: repository)
        _ = try await service.report(at: t1, learningTimeZoneID: timeZoneID)
        repository.dataVersion += 1
        _ = try await service.report(at: t1, learningTimeZoneID: timeZoneID)
        _ = try await service.report(at: t1, learningTimeZoneID: "America/Los_Angeles")
        XCTAssertEqual(repository.snapshotCalls, 3)
    }

    func testSharedEpochBounceInvalidatesReport() async throws {
        let repository = StubAdaptiveRepository()
        let invalidation = AdaptiveInvalidationCenter()
        let service = AdaptiveTrendService(
            repository: repository,
            invalidation: invalidation
        )
        let first = try await service.report(at: t1, learningTimeZoneID: timeZoneID)
        await invalidation.invalidate()
        let second = try await service.report(at: t1, learningTimeZoneID: timeZoneID)
        XCTAssertEqual(repository.snapshotCalls, 2)
        XCTAssertGreaterThan(second.generation.epoch, first.generation.epoch)
    }

    // MARK: - Helpers

    private func report(
        records: [AdaptiveCardRecord]
    ) async throws -> AdaptiveTrendReport {
        let repository = StubAdaptiveRepository()
        repository.records = records
        let service = AdaptiveTrendService(repository: repository)
        return try await service.report(at: t1, learningTimeZoneID: timeZoneID)
    }

    private func makeRecord(
        isEnabled: Bool = true,
        samples: [AdaptiveReviewSample]
    ) -> AdaptiveCardRecord {
        AdaptiveCardRecord(
            evidence: AdaptiveCardEvidence(
                cardID: UUID(),
                noteID: UUID(),
                deckID: UUID(),
                templateKind: .vocabularyJapaneseToChinese,
                isEnabled: isEnabled,
                scheduling: samples.first?.nextState.scheduling
                    ?? SchedulingCard(dueAt: t1),
                firstStudiedAt: samples.last?.nextState.firstStudiedAt,
                samples: samples
            ),
            headword: "语",
            noteContentVersion: 1
        )
    }

    private func snapshot(
        state: SchedulingState,
        dueAt: Date,
        stability: Double = 1,
        difficulty: Double = 5,
        lapses: Int = 0,
        stateVersion: Int
    ) -> ReviewSchedulingSnapshot {
        ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: dueAt,
                stability: stability,
                difficulty: difficulty,
                elapsedDays: 0,
                scheduledDays: 0,
                learningStep: 0,
                repetitions: 0,
                lapses: lapses,
                state: state,
                lastReviewAt: nil
            ),
            firstStudiedAt: t0.addingTimeInterval(-90 * 86_400),
            stateVersion: stateVersion,
            algorithmVersion: "fsrs-6-test",
            profileID: UUID()
        )
    }

    /// Due-review sample: previous state review + already due + not first
    /// study. `lapses`/`stability` land in nextState — the reconstruction
    /// surface — so they drive the endpoint classification.
    private func dueLog(
        _ rating: ReviewRating,
        daysBeforeT1: Double,
        lapses: Int,
        stability: Double,
        stateVersion: Int = 1
    ) -> AdaptiveReviewSample {
        let reviewedAt = t1.addingTimeInterval(-daysBeforeT1 * 86_400)
        return AdaptiveReviewSample(
            logID: UUID(),
            rating: rating,
            reviewedAt: reviewedAt,
            wasFirstStudy: false,
            previousState: snapshot(
                state: .review,
                dueAt: reviewedAt.addingTimeInterval(-3_600),
                lapses: max(0, lapses - 1),
                stateVersion: stateVersion
            ),
            nextState: snapshot(
                state: rating == .again ? .relearning : .review,
                dueAt: reviewedAt.addingTimeInterval(86_400),
                stability: stability,
                lapses: lapses,
                stateVersion: stateVersion + 1
            )
        )
    }

    /// Newest-first leech history: every log leaves lapses≥6 so the card is
    /// leech at any endpoint after the oldest of them (rule A), regardless
    /// of how far the endpoint sits from the samples.
    private func leechLogs(daysBeforeT1: [Double]) -> [AdaptiveReviewSample] {
        daysBeforeT1.enumerated().map { index, days in
            dueLog(.again, daysBeforeT1: days, lapses: 6, stability: 1, stateVersion: index * 2)
        }
    }

    /// Ten due-review Agains forming the recent-window burst at t0 while
    /// keeping lapses under the lifetime threshold.
    private func burstLogs(daysBeforeT1: [Double]) -> [AdaptiveReviewSample] {
        daysBeforeT1.enumerated().map { index, days in
            dueLog(.again, daysBeforeT1: days, lapses: 2, stability: 1, stateVersion: index * 2)
        }
    }

    /// Newest-first due-review Good samples ending in review state at the
    /// given stability — the recovery shape (3+ consecutive due successes).
    /// `lapses` stays under the lifetime threshold by default so rule A
    /// cannot keep the card leech on its own.
    private func recoveryLogs(
        daysBeforeT1: [Double],
        stability: Double,
        lapses: Int = 2
    ) -> [AdaptiveReviewSample] {
        daysBeforeT1.enumerated().map { index, days in
            dueLog(.good, daysBeforeT1: days, lapses: lapses, stability: stability, stateVersion: 100 + index * 2)
        }
    }
}
