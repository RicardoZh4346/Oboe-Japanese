import Foundation
import XCTest
@testable import OboeDomain

/// Service-level contract tests with a stub repository — cache keys, epoch
/// invalidation, filter/count consistency and detail semantics, no SQLite.
final class AdaptiveCardServiceTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testSnapshotCacheHitsWithinSameGenerationAndBucket() async throws {
        let repository = StubAdaptiveRepository()
        let service = AdaptiveCardService(repository: repository)

        _ = try await service.snapshot(scope: .all, at: Self.now)
        _ = try await service.snapshot(scope: .all, at: Self.now)

        XCTAssertEqual(repository.snapshotCalls, 1)
        XCTAssertEqual(repository.dataVersionCalls, 2)
    }

    func testDataVersionChangeRefetchesAutomatically() async throws {
        let repository = StubAdaptiveRepository()
        let service = AdaptiveCardService(repository: repository)

        _ = try await service.snapshot(scope: .all, at: Self.now)
        repository.dataVersion += 1
        _ = try await service.snapshot(scope: .all, at: Self.now)

        XCTAssertEqual(repository.snapshotCalls, 2)
    }

    func testInvalidateForcesRefetchAndAdvancesEpoch() async throws {
        let repository = StubAdaptiveRepository()
        let service = AdaptiveCardService(repository: repository)

        let first = try await service.snapshot(scope: .all, at: Self.now)
        await service.invalidate()
        let second = try await service.snapshot(scope: .all, at: Self.now)

        XCTAssertEqual(repository.snapshotCalls, 2)
        XCTAssertGreaterThan(second.generation.epoch, first.generation.epoch)
    }

    func testFiltersAndCountsDeriveFromTheSameItems() async throws {
        let repository = StubAdaptiveRepository()
        repository.records = [
            StubAdaptiveRepository.record(statusSeed: .leech),
            StubAdaptiveRepository.record(statusSeed: .warning),
            StubAdaptiveRepository.record(statusSeed: .normal),
            StubAdaptiveRepository.record(statusSeed: .leech, isEnabled: false)
        ]
        let service = AdaptiveCardService(repository: repository)
        let snapshot = try await service.snapshot(scope: .all, at: Self.now)

        XCTAssertEqual(snapshot.leechCount, 1)
        XCTAssertEqual(snapshot.items(matching: .leech).count, 1)
        XCTAssertEqual(snapshot.items(matching: .warning).count, 1)
        XCTAssertEqual(snapshot.items(matching: .suspended).count, 1)
        XCTAssertEqual(
            snapshot.items(matching: .suspended).first?.assessment.status,
            .leech
        )

        let page = snapshot.page(.leech, offset: 0, limit: 10)
        XCTAssertEqual(page.totalCount, 1)
    }

    func testDetailNilForMissingCardAndSamplesCappedToWindow() async throws {
        let repository = StubAdaptiveRepository()
        var record = StubAdaptiveRepository.record(statusSeed: .normal)
        // 15 valid samples → detail keeps only the 10-sample recent window.
        record = StubAdaptiveRepository.record(
            statusSeed: .normal,
            sampleCount: 15
        )
        repository.records = [record]
        let service = AdaptiveCardService(repository: repository)

        let missing = try await service.detail(cardID: UUID(), at: Self.now)
        XCTAssertNil(missing)
        let found = try await service.detail(
            cardID: record.evidence.cardID,
            at: Self.now
        )
        let detail = try XCTUnwrap(found)
        XCTAssertEqual(detail.recentSamples.count, 10)
        XCTAssertEqual(detail.item.cardID, record.evidence.cardID)
    }
}

// MARK: - Stub

final class StubAdaptiveRepository: AdaptiveRepository, @unchecked Sendable {
    var dataVersion = 1
    var dataVersionCalls = 0
    var snapshotCalls = 0
    var evidenceCalls = 0
    var scopeHistory: [AdaptiveScope] = []
    var records: [AdaptiveCardRecord] = []

    func fetchDataVersion() async throws -> Int {
        dataVersionCalls += 1
        return dataVersion
    }

    func fetchSnapshot(scope: AdaptiveScope) async throws -> AdaptiveEvidenceSnapshot {
        snapshotCalls += 1
        scopeHistory.append(scope)
        return AdaptiveEvidenceSnapshot(
            scope: scope,
            dataVersion: dataVersion,
            records: records
        )
    }

    func fetchEvidence(cardID: UUID) async throws -> AdaptiveCardRecord? {
        evidenceCalls += 1
        return records.first { $0.evidence.cardID == cardID }
    }

    /// Builds a record whose assessment lands on the requested status under
    /// the standard policy: leech via lapses≥6, warning via lapses≥3, normal
    /// otherwise. `sampleCount` pads Good due reviews (capped for warning and
    /// neutral for the others).
    static func record(
        statusSeed: AdaptiveCardStatus,
        isEnabled: Bool = true,
        sampleCount: Int = 0
    ) -> AdaptiveCardRecord {
        let cardID = UUID()
        let noteID = UUID()
        let profileID = UUID()
        let base = Date(timeIntervalSince1970: 1_788_000_000)

        let lapses: Int
        switch statusSeed {
        case .leech: lapses = 6
        case .warning: lapses = 3
        case .normal: lapses = 0
        }

        var samples: [AdaptiveReviewSample] = []
        for index in 0..<sampleCount {
            let reviewedAt = base.addingTimeInterval(
                TimeInterval(-(index + 1) * 86_400)
            )
            let snapshot = ReviewSchedulingSnapshot(
                scheduling: SchedulingCard(
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 5.0,
                    difficulty: 5.0,
                    repetitions: index,
                    lapses: 0,
                    state: .review
                ),
                firstStudiedAt: base.addingTimeInterval(-90 * 86_400),
                stateVersion: index,
                algorithmVersion: "fsrs-test",
                profileID: profileID
            )
            samples.append(
                AdaptiveReviewSample(
                    logID: UUID(),
                    rating: .good,
                    reviewedAt: reviewedAt,
                    wasFirstStudy: false,
                    contentVersion: 1,
                    previousState: snapshot,
                    nextState: snapshot
                )
            )
        }

        let evidence = AdaptiveCardEvidence(
            cardID: cardID,
            noteID: noteID,
            deckID: UUID(),
            templateKind: .vocabularyJapaneseToChinese,
            isEnabled: isEnabled,
            scheduling: SchedulingCard(
                dueAt: base.addingTimeInterval(86_400),
                stability: 5.0,
                difficulty: 5.0,
                repetitions: 8,
                lapses: lapses,
                state: .review
            ),
            firstStudiedAt: base.addingTimeInterval(-90 * 86_400),
            samples: samples
        )
        return AdaptiveCardRecord(
            evidence: evidence,
            headword: "単語",
            noteContentVersion: 1
        )
    }
}
