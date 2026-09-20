import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T02 repository/service verification on real SQLite (plan: 提交→查询→撤销→
/// 重算、删除后同方向重建不继承、同毫秒窗口、查询一致性、分页总数、无 N+1、
/// 缓存与失效入口、scope 与启停过滤）。
final class GRDBAdaptiveRepositoryTests: XCTestCase {
    private var fixture: AdaptiveDatabaseFixture!

    override func setUp() async throws {
        fixture = try await AdaptiveDatabaseFixture.make()
    }

    override func tearDown() {
        fixture.remove()
        fixture = nil
    }

    private func makeRepository(
        queryObserver: (@Sendable () -> Void)? = nil
    ) -> GRDBAdaptiveRepository {
        GRDBAdaptiveRepository(database: fixture.database, queryObserver: queryObserver)
    }

    private func makeService(
        repository: GRDBAdaptiveRepository? = nil
    ) -> AdaptiveCardService {
        AdaptiveCardService(repository: repository ?? makeRepository())
    }

    // MARK: - Evidence coverage

    func testSnapshotCoversEveryLiveCardWithTraceableEvidence() async throws {
        let snapshot = try await makeRepository().fetchSnapshot(scope: .all)

        // fresh 2 + lapsed 2 + undone 1 + otherDeck 1 = 6 live cards.
        XCTAssertEqual(snapshot.records.count, 6)

        let lapsed = try XCTUnwrap(snapshot.records.first {
            $0.evidence.cardID == fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        })
        XCTAssertEqual(lapsed.evidence.samples.count, 5)
        XCTAssertEqual(lapsed.evidence.scheduling.lapses, 6)
        XCTAssertEqual(lapsed.headword, "難しい")
        XCTAssertEqual(lapsed.noteContentVersion, 1)
        XCTAssertEqual(lapsed.evidence.deckID, fixture.deckAID)

        let undone = try XCTUnwrap(snapshot.records.first {
            $0.evidence.cardID == fixture.undoneNote.cardID(.vocabularyJapaneseToChinese)
        })
        // Newest Again was undone — only the two Good logs remain.
        XCTAssertEqual(undone.evidence.samples.count, 2)
        XCTAssertTrue(undone.evidence.samples.allSatisfy { $0.rating == .good })

        // The deleted direction's orphaned card_key history must not attach to
        // any live card: total attached samples stay at 5+2=7, orphan excluded.
        XCTAssertFalse(snapshot.records.contains {
            $0.evidence.cardID == fixture.deletedCardKey
        })
        XCTAssertEqual(
            snapshot.records.reduce(0) { $0 + $1.evidence.samples.count },
            7
        )
    }

    /// T04: the single-card suspend command must move a leech card out of
    /// the enabled-leech count and into the suspended filter, and resuming
    /// must bring the same Card.id back — page counts and list membership
    /// stay consistent because every surface reads the same snapshot (§5.2).
    func testSuspendAndResumeFlowThroughTheSameSnapshot() async throws {
        let service = makeService()
        let contentRepository = GRDBContentCardRepository(database: fixture.database)
        let leechCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)

        let before = try await service.snapshot(scope: .all, at: AdaptiveDatabaseFixture.baseDate)
        XCTAssertEqual(before.leechCount, 1)

        _ = try await contentRepository.setCardEnabled(
            cardID: leechCard,
            isEnabled: false,
            at: AdaptiveDatabaseFixture.baseDate.addingTimeInterval(60)
        )
        let suspended = try await service.snapshot(scope: .all, at: AdaptiveDatabaseFixture.baseDate)
        XCTAssertEqual(suspended.leechCount, 0, "a suspended leech leaves the home count")
        XCTAssertEqual(suspended.items(matching: .leech).count, 0)
        XCTAssertEqual(
            suspended.items(matching: .suspended).map(\.cardID),
            [leechCard],
            "the same Card.id appears under the suspended filter"
        )
        // Suspension is not a status reset: the assessment evidence is intact.
        let suspendedItem = try XCTUnwrap(suspended.items(matching: .suspended).first)
        XCTAssertEqual(suspendedItem.assessment.status, .leech)
        XCTAssertEqual(suspendedItem.assessment.metrics.lifetimeLapses, 6)

        _ = try await contentRepository.setCardEnabled(
            cardID: leechCard,
            isEnabled: true,
            at: AdaptiveDatabaseFixture.baseDate.addingTimeInterval(120)
        )
        let resumed = try await service.snapshot(scope: .all, at: AdaptiveDatabaseFixture.baseDate)
        XCTAssertEqual(resumed.leechCount, 1)
        XCTAssertEqual(resumed.items(matching: .suspended).count, 0)
        XCTAssertEqual(resumed.items(matching: .leech).first?.cardID, leechCard)
    }

    func testServiceAssessmentsAreDeterministicAndExplainable() async throws {
        let snapshot = try await makeService().snapshot(
            scope: .all,
            at: AdaptiveDatabaseFixture.baseDate
        )

        XCTAssertEqual(snapshot.items.count, 6)
        XCTAssertEqual(snapshot.policyVersion, AdaptivePolicy.standard.version)
        XCTAssertEqual(snapshot.leechCount, 1)

        let lapsed = try XCTUnwrap(snapshot.items.first {
            $0.cardID == fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        })
        XCTAssertEqual(lapsed.assessment.status, .leech)
        // lapses=6 (A), five consecutive due Again reviews (C), high difficulty
        // with a fresh Again (D). B needs a full 10-sample window — only 5 logs.
        XCTAssertEqual(
            Set(lapsed.assessment.triggers),
            [.lifetimeLapses, .dueAgainStreak, .persistentDifficulty]
        )
        XCTAssertEqual(lapsed.assessment.metrics.recentAgainCount, 5)

        for cardID in [
            fixture.freshNote.cardID(.vocabularyJapaneseToChinese),
            fixture.undoneNote.cardID(.vocabularyJapaneseToChinese),
            fixture.otherDeckNote.cardID(.vocabularyJapaneseToChinese)
        ] {
            let item = try XCTUnwrap(snapshot.items.first { $0.cardID == cardID })
            XCTAssertEqual(item.assessment.status, .normal)
            XCTAssertTrue(item.assessment.triggers.isEmpty)
        }

        // No samples → "暂无评分", not 0%.
        let fresh = try XCTUnwrap(snapshot.items.first {
            $0.cardID == fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        })
        XCTAssertNil(fresh.assessment.metrics.againRatio)
    }

    // MARK: - Commit → query → undo → recompute

    func testCommitUndoRecomputeFlow() async throws {
        let service = makeService()
        let now = AdaptiveDatabaseFixture.baseDate
        let cardID = fixture.undoneNote.cardID(.vocabularyJapaneseToChinese)

        // Two valid Good logs — normal.
        var snapshot = try await service.snapshot(scope: .all, at: now)
        XCTAssertEqual(
            try item(in: snapshot, cardID: cardID).assessment.status,
            .normal
        )

        // Commit three consecutive due-Review Agains → C rule fires.
        var stateVersion = 20
        var logIDs: [UUID] = []
        for offset in 0..<3 {
            let reviewedAt = now.addingTimeInterval(TimeInterval(-(offset + 1) * 86_400))
            let log = try await fixture.insertReviewLog(
                cardKey: cardID,
                cardID: cardID,
                noteID: fixture.undoneNote.noteID,
                deckID: fixture.deckAID,
                rating: .again,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 4.0,
                    difficulty: 6.0,
                    repetitions: 5,
                    lapses: 1,
                    stateVersion: stateVersion
                ),
                nextSnapshot: fixture.snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1.0,
                    difficulty: 6.5,
                    repetitions: 6,
                    lapses: 2,
                    stateVersion: stateVersion + 1
                )
            )
            logIDs.append(log.id)
            stateVersion += 2
        }
        snapshot = try await service.snapshot(scope: .all, at: now)
        var cardItem = try item(in: snapshot, cardID: cardID)
        XCTAssertEqual(cardItem.assessment.status, .leech)
        XCTAssertTrue(cardItem.assessment.triggers.contains(.dueAgainStreak))
        XCTAssertEqual(cardItem.assessment.metrics.dueAgainStreak, 3)

        // Undo all three → recompute back to normal.
        try await markUndone(logIDs: logIDs)
        snapshot = try await service.snapshot(scope: .all, at: now)
        cardItem = try item(in: snapshot, cardID: cardID)
        XCTAssertEqual(cardItem.assessment.status, .normal)
        XCTAssertEqual(cardItem.assessment.metrics.dueAgainStreak, 0)
        XCTAssertEqual(cardItem.assessment.metrics.totalCount, 2)
    }

    // MARK: - Deleted card history isolation

    func testRecreatedCardDoesNotInheritDeletedHistory() async throws {
        let service = makeService()
        let now = AdaptiveDatabaseFixture.baseDate
        let cardID = fixture.lapsedNote.cardID(.vocabularyChineseToJapanese)

        // Give the card some history, then delete the row itself.
        _ = try await fixture.insertReviewLog(
            cardKey: cardID,
            cardID: cardID,
            noteID: fixture.lapsedNote.noteID,
            deckID: fixture.deckAID,
            rating: .again,
            reviewedAt: now.addingTimeInterval(-86_400),
            previousSnapshot: fixture.snapshot(
                state: .review,
                dueAt: now.addingTimeInterval(-2 * 86_400),
                stability: 2.0,
                difficulty: 7.0,
                repetitions: 4,
                lapses: 3,
                stateVersion: 4
            ),
            nextSnapshot: fixture.snapshot(
                state: .relearning,
                dueAt: now.addingTimeInterval(-86_400 + 600_000),
                stability: 1.0,
                difficulty: 7.2,
                repetitions: 5,
                lapses: 4,
                stateVersion: 5
            )
        )
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
        let newCardID = try await fixture.addCard(
            noteID: fixture.lapsedNote.noteID,
            template: .vocabularyChineseToJapanese
        )
        XCTAssertNotEqual(newCardID, cardID)

        let snapshot = try await service.snapshot(scope: .all, at: now)
        let recreated = try item(in: snapshot, cardID: newCardID)
        XCTAssertEqual(recreated.assessment.status, .normal)
        XCTAssertEqual(recreated.assessment.metrics.totalCount, 0)

        // The old card is gone entirely; its orphaned samples attach nowhere.
        XCTAssertNil(snapshot.items.first { $0.cardID == cardID })
        let orphanStillLogged = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM review_logs
                    WHERE card_key = ? AND undone_at_ms IS NULL
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
        XCTAssertEqual(orphanStillLogged, 1)
    }

    // MARK: - Same-millisecond ordering

    func testSameMillisecondSamplesSortByStateVersionThenLogID() async throws {
        let repository = makeRepository()
        let now = AdaptiveDatabaseFixture.baseDate
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let reviewedAt = now.addingTimeInterval(-86_400)

        var logIDs: [UUID] = []
        for stateVersion in [3, 9, 5] {
            let log = try await fixture.insertReviewLog(
                cardKey: cardID,
                cardID: cardID,
                noteID: fixture.freshNote.noteID,
                deckID: fixture.deckAID,
                rating: .good,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3.0,
                    difficulty: 5.0,
                    repetitions: stateVersion,
                    lapses: 0,
                    stateVersion: stateVersion
                ),
                nextSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(3 * 86_400),
                    stability: 4.0,
                    difficulty: 5.0,
                    repetitions: stateVersion + 1,
                    lapses: 0,
                    stateVersion: stateVersion
                )
            )
            logIDs.append(log.id)
        }

        let fetched = try await repository.fetchEvidence(cardID: cardID)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.evidence.samples.count, 3)
        // Same reviewedAt → nextState.stateVersion DESC.
        XCTAssertEqual(
            record.evidence.samples.map { $0.nextState.stateVersion },
            [9, 5, 3]
        )
    }

    // MARK: - Consistency & generation

    func testSnapshotGenerationTracksCommitsAndStaysConsistent() async throws {
        let repository = makeRepository()
        let before = try await repository.fetchSnapshot(scope: .all)
        let directVersion = try await repository.fetchDataVersion()
        XCTAssertEqual(before.dataVersion, directVersion)

        // One atomic commit: new card state AND a new log together.
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let reviewedAt = AdaptiveDatabaseFixture.baseDate
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET state_version = 42 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
        _ = try await fixture.insertReviewLog(
            cardKey: cardID,
            cardID: cardID,
            noteID: fixture.freshNote.noteID,
            deckID: fixture.deckAID,
            rating: .easy,
            reviewedAt: reviewedAt,
            previousSnapshot: fixture.snapshot(
                state: .review,
                dueAt: reviewedAt.addingTimeInterval(-86_400),
                stability: 3.0,
                difficulty: 4.0,
                repetitions: 6,
                lapses: 0,
                stateVersion: 41
            ),
            nextSnapshot: fixture.snapshot(
                state: .review,
                dueAt: reviewedAt.addingTimeInterval(10 * 86_400),
                stability: 12.0,
                difficulty: 4.0,
                repetitions: 7,
                lapses: 0,
                stateVersion: 42
            )
        )

        let after = try await repository.fetchSnapshot(scope: .all)
        XCTAssertNotEqual(after.dataVersion, before.dataVersion)
        let record = try XCTUnwrap(after.records.first {
            $0.evidence.cardID == cardID
        })
        // Both halves of the commit visible together — never one without the other.
        XCTAssertEqual(record.evidence.samples.count, 1)
        XCTAssertEqual(
            record.evidence.samples.first?.nextState.stateVersion,
            42
        )
    }

    // MARK: - Scope & suspension filters

    func testScopeLimitsCardsToTheSelectedDeck() async throws {
        let service = makeService()
        let now = AdaptiveDatabaseFixture.baseDate

        let deckB = try await service.snapshot(
            scope: AdaptiveScope(deckID: fixture.deckBID),
            at: now
        )
        XCTAssertEqual(deckB.items.count, 1)
        XCTAssertEqual(
            deckB.items.first?.cardID,
            fixture.otherDeckNote.cardID(.vocabularyJapaneseToChinese)
        )
        XCTAssertEqual(deckB.leechCount, 0)

        let deckA = try await service.snapshot(
            scope: AdaptiveScope(deckID: fixture.deckAID),
            at: now
        )
        XCTAssertEqual(deckA.items.count, 5)
        XCTAssertEqual(deckA.leechCount, 1)
    }

    func testSuspendedCardsLeaveTheLeechFilter() async throws {
        let service = makeService()
        let now = AdaptiveDatabaseFixture.baseDate
        let cardID = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)

        try await fixture.updateScheduling(
            cardID: cardID,
            state: .review,
            dueAt: now.addingTimeInterval(86_400),
            stability: 4.2,
            difficulty: 9.1,
            repetitions: 14,
            lapses: 6,
            firstStudiedAt: now.addingTimeInterval(-60 * 86_400),
            stateVersion: 14,
            isEnabled: false
        )

        let snapshot = try await service.snapshot(scope: .all, at: now)
        XCTAssertEqual(snapshot.leechCount, 0)
        XCTAssertTrue(snapshot.items(matching: .leech).isEmpty)

        let suspended = snapshot.items(matching: .suspended)
        XCTAssertEqual(suspended.count, 1)
        XCTAssertEqual(suspended.first?.cardID, cardID)
        // Suspended cards still carry their real assessment — the detail page
        // can explain why the card was paused.
        XCTAssertEqual(suspended.first?.assessment.status, .leech)
    }

    // MARK: - Pagination

    func testPageReportsTotalIndependentOfWindow() async throws {
        let service = makeService()
        let now = AdaptiveDatabaseFixture.baseDate
        // Seed extra warning cards so pagination has multiple pages.
        for index in 0..<4 {
            let noteID = UUID()
            try await fixture.insertNote(
                noteID,
                deckID: fixture.deckAID,
                headword: "警\(index)",
                reading: nil,
                meaningZH: "warning\(index)"
            )
            let cardID = try await fixture.addCard(
                noteID: noteID,
                template: .vocabularyJapaneseToChinese
            )
            try await fixture.updateScheduling(
                cardID: cardID,
                state: .review,
                dueAt: now.addingTimeInterval(86_400),
                stability: 3.0,
                difficulty: 5.0,
                repetitions: 8,
                lapses: 3,
                firstStudiedAt: now.addingTimeInterval(-40 * 86_400),
                stateVersion: 8
            )
        }
        let snapshot = try await service.snapshot(scope: .all, at: now)

        let firstPage = snapshot.page(.warning, offset: 0, limit: 2)
        XCTAssertEqual(firstPage.items.count, 2)
        XCTAssertEqual(firstPage.totalCount, 4)
        XCTAssertTrue(firstPage.hasMore)

        let lastPage = snapshot.page(.warning, offset: 2, limit: 2)
        XCTAssertEqual(lastPage.items.count, 2)
        XCTAssertFalse(lastPage.hasMore)

        // Pages partition the full filtered list without repeats.
        let combined = firstPage.items + lastPage.items
        XCTAssertEqual(
            Set(combined.map(\.cardID)),
            Set(snapshot.items(matching: .warning).map(\.cardID))
        )

        // Overshooting offset clamps instead of crashing.
        let beyond = snapshot.page(.warning, offset: 99, limit: 2)
        XCTAssertTrue(beyond.items.isEmpty)
        XCTAssertEqual(beyond.totalCount, 4)
    }

    // MARK: - No N+1

    func testSnapshotIssuesConstantQueryCountRegardlessOfCardCount() async throws {
        // Add 60 more cards so the card set is well above one page of rows.
        for index in 0..<30 {
            let noteID = UUID()
            try await fixture.insertNote(
                noteID,
                deckID: fixture.deckAID,
                headword: "多\(index)",
                reading: nil,
                meaningZH: "many\(index)"
            )
            _ = try await fixture.addCard(
                noteID: noteID,
                template: .vocabularyJapaneseToChinese
            )
            _ = try await fixture.addCard(
                noteID: noteID,
                template: .vocabularyChineseToJapanese
            )
        }

        let counter = StatementCounter()
        let repository = makeRepository(queryObserver: { counter.increment() })
        let snapshot = try await repository.fetchSnapshot(scope: .all)
        XCTAssertEqual(snapshot.records.count, 66)

        // 1 cards query + ceil(66/400) = 1 log query — constant for any card
        // count below the 400-key chunk size, and linear in chunks above it.
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - Cache & invalidation

    func testCacheReusesSnapshotUntilDataChanges() async throws {
        let counter = StatementCounter()
        let repository = makeRepository(queryObserver: { counter.increment() })
        let service = makeService(repository: repository)
        let now = AdaptiveDatabaseFixture.baseDate

        _ = try await service.snapshot(scope: .all, at: now)
        counter.reset()

        // Warm hit: only the cheap data_version probe runs — the heavy scan
        // does not repeat inside the same time bucket.
        let cached = try await service.snapshot(scope: .all, at: now)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(cached.leechCount, 1)

        // Any commit bumps data_version → automatic miss.
        _ = try await fixture.insertReviewLog(
            cardKey: fixture.freshNote.cardID(.vocabularyJapaneseToChinese),
            cardID: fixture.freshNote.cardID(.vocabularyJapaneseToChinese),
            noteID: fixture.freshNote.noteID,
            deckID: fixture.deckAID,
            rating: .good,
            reviewedAt: now,
            previousSnapshot: fixture.snapshot(
                state: .new,
                dueAt: now,
                stability: 0,
                difficulty: 0,
                repetitions: 0,
                lapses: 0,
                stateVersion: 0
            ),
            nextSnapshot: fixture.snapshot(
                state: .learning,
                dueAt: now.addingTimeInterval(600_000),
                stability: 0.5,
                difficulty: 5.0,
                repetitions: 1,
                lapses: 0,
                stateVersion: 1
            ),
            wasFirstStudy: true
        )
        _ = try await service.snapshot(scope: .all, at: now)
        // probe(1) + cards(1) + logs(1) — full rescan after the commit.
        XCTAssertEqual(counter.value, 1 + 3)
    }

    func testInvalidateBumpsEpochAndDropsCache() async throws {
        let counter = StatementCounter()
        let repository = makeRepository(queryObserver: { counter.increment() })
        let service = makeService(repository: repository)
        let now = AdaptiveDatabaseFixture.baseDate

        let first = try await service.snapshot(scope: .all, at: now)
        let epochBefore = await service.currentEpoch()

        await service.invalidate()
        counter.reset()

        let second = try await service.snapshot(scope: .all, at: now)
        XCTAssertNotEqual(second.generation, first.generation)
        let epochAfter = await service.currentEpoch()
        XCTAssertGreaterThan(epochAfter, epochBefore)
        // Same data_version but a new epoch → full rescan happened.
        XCTAssertEqual(second.generation.dataVersion, first.generation.dataVersion)
        // probe(1) + cards(1) + logs(1) — counter was reset after invalidate.
        XCTAssertEqual(counter.value, 3)
    }

    // MARK: - Detail

    func testDetailReturnsItemAndRecentWindowSamples() async throws {
        let service = makeService()
        let now = AdaptiveDatabaseFixture.baseDate
        let cardID = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)

        let found = try await service.detail(cardID: cardID, at: now)
        let detail = try XCTUnwrap(found)
        XCTAssertEqual(detail.item.cardID, cardID)
        XCTAssertEqual(detail.item.headword, "難しい")
        XCTAssertEqual(detail.item.assessment.status, .leech)
        // 5 seeded logs — under the 10-sample recent window.
        XCTAssertEqual(detail.recentSamples.count, 5)
        XCTAssertTrue(detail.recentSamples.allSatisfy { $0.contentVersion == 1 })
        XCTAssertTrue(detail.recentSamples.allSatisfy { $0.rating == .again })
    }

    func testDetailForUnknownCardReturnsNil() async throws {
        let service = makeService()
        let detail = try await service.detail(
            cardID: UUID(),
            at: AdaptiveDatabaseFixture.baseDate
        )
        XCTAssertNil(detail)
    }

    // MARK: - Helpers

    private func item(
        in snapshot: AdaptiveSnapshot,
        cardID: UUID
    ) throws -> AdaptiveCardItem {
        try XCTUnwrap(snapshot.items.first { $0.cardID == cardID })
    }

    private func markUndone(logIDs: [UUID]) async throws {
        try await fixture.database.pool.write { db in
            for logID in logIDs {
                try db.execute(
                    sql: """
                        UPDATE review_logs SET undone_at_ms = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        try DatabaseValueCodec.encode(Date()),
                        DatabaseValueCodec.encode(logID)
                    ]
                )
            }
        }
    }
}

/// Thread-safe counter for the repository's per-statement test hook.
final class StatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}
