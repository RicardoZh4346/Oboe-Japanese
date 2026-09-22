import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class P22bPerformanceTests: XCTestCase {
    func testStandardDatasetMeetsReleasePerformanceTargets() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OBOE_RUN_P22B_PERFORMANCE"] == "1",
            "Set OBOE_RUN_P22B_PERFORMANCE=1 for the release performance run."
        )

        let fixture = try P22bPerformanceFixture()
        defer { fixture.remove() }
        try await fixture.seed()

        let counts = try await fixture.counts()
        XCTAssertEqual(counts.notes, 10_000)
        XCTAssertEqual(counts.cards, 20_000)
        XCTAssertEqual(counts.reviewLogs, 100_000)
        print("P22B_DATASET=notes:\(counts.notes),cards:\(counts.cards),review_logs:\(counts.reviewLogs)")
        try await fixture.exportIfRequested()

        let coldStartP95 = try await percentile95(samples: 10) {
            let database = try OboeDatabase(path: fixture.databaseURL.path)
            let service = fixture.makeStudySessionService(database: database)
            _ = try await service.buildTodayPlan(defaultTimeZoneID: fixture.timeZoneID)
            try database.close()
        }

        let database = try OboeDatabase(path: fixture.databaseURL.path)
        defer { try? database.close() }
        let session = fixture.makeStudySessionService(database: database)
        let history = GRDBStudyHistoryRepository(database: database)
        let decks = GRDBDeckRepository(database: database)
        let search = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )
        let initialPlan = try await session.buildTodayPlan(
            defaultTimeZoneID: fixture.timeZoneID
        )
        XCTAssertEqual(initialPlan.availableNow.count, fixture.dueCardCount)

        let homeQueryP95 = try await percentile95(samples: 20) {
            let plan = try await session.buildTodayPlan(
                defaultTimeZoneID: fixture.timeZoneID
            )
            async let deckSummaries = decks.fetchDeckSummaries()
            async let statistics = history.fetchTodayStatistics(studyDayID: plan.studyDay.id)
            _ = try await (deckSummaries, statistics)
        }

        _ = try await search.search("不存在的预热查询")
        let searchP95 = try await percentile95(samples: 20) {
            let page = try await search.search("唯一目标针")
            XCTAssertEqual(page.items.count, 1)
        }

        var plan = initialPlan
        var ratingDurations: [TimeInterval] = []
        for _ in 0..<20 {
            let item = try XCTUnwrap(plan.availableNow.first)
            let card = try await session.loadReviewCard(cardID: item.cardID)
            let started = ContinuousClock.now
            _ = try await session.submit(
                card: card,
                rating: .easy,
                studyDay: plan.studyDay,
                eventID: UUID(),
                durationMilliseconds: 500
            )
            plan = try await session.buildTodayPlan(defaultTimeZoneID: fixture.timeZoneID)
            if let next = plan.availableNow.first {
                _ = try await session.loadReviewCard(cardID: next.cardID)
            }
            ratingDurations.append(seconds(since: started))
        }
        let ratingToNextP95 = percentile95(ratingDurations)

        printMetric("P22B_BACKEND_COLD_START_P95_MS", coldStartP95)
        printMetric("P22B_HOME_QUERY_P95_MS", homeQueryP95)
        printMetric("P22B_SEARCH_P95_MS", searchP95)
        printMetric("P22B_RATING_TO_NEXT_P95_MS", ratingToNextP95)

        XCTAssertLessThan(coldStartP95, 2.0)
        XCTAssertLessThan(homeQueryP95, 0.2)
        XCTAssertLessThan(searchP95, 0.2)
        XCTAssertLessThan(ratingToNextP95, 0.1)
    }
}

private struct P22bPerformanceFixture {
    let directoryURL: URL
    let databaseURL: URL
    let now = Date(timeIntervalSince1970: 1_789_344_000)
    let timeZoneID = "Asia/Shanghai"
    let dueCardCount = 200

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "P22bPerformanceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func seed() async throws {
        let database = try OboeDatabase(path: databaseURL.path)
        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, daily_new_card_limit
                    ) VALUES (1, 1, ?, 10)
                    """,
                arguments: [timeZoneID]
            )
            let deckID = performanceUUID(1)
            let profileID = try GRDBSchedulerProfileStore.ensureProfile(
                preset: .standard,
                candidateID: performanceUUID(2),
                createdAtMilliseconds: nowMilliseconds,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, 'P22b 标准数据集', 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(deckID), nowMilliseconds, nowMilliseconds
                ]
            )

            for noteIndex in 0..<10_000 {
                let noteID = performanceUUID(10_000 + noteIndex)
                let meaning = noteIndex == 9_999 ? "唯一目标针" : "常用释义\(noteIndex)"
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', ?, ?, ?, 'manual', 1, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID), DatabaseValueCodec.encode(deckID),
                        "性能词条\(noteIndex)", "せいのう\(noteIndex)", meaning,
                        nowMilliseconds, nowMilliseconds
                    ]
                )
                try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
                for direction in 0..<2 {
                    let cardIndex = noteIndex * 2 + direction
                    let cardID = performanceUUID(30_000 + cardIndex)
                    let dueAt = cardIndex < dueCardCount
                        ? nowMilliseconds - Int64(dueCardCount - cardIndex) * 1_000
                        : nowMilliseconds + 7 * 86_400_000
                    let template = direction == 0
                        ? CardTemplateKind.vocabularyJapaneseToChinese.rawValue
                        : CardTemplateKind.vocabularyChineseToJapanese.rawValue
                    try db.execute(
                        sql: """
                            INSERT INTO cards(
                                id, note_id, template_kind, is_enabled, state, due_at_ms,
                                last_review_at_ms, stability, difficulty, reps, lapses,
                                scheduled_days, elapsed_days, learning_step,
                                first_studied_at_ms, state_version, algorithm_version, profile_id
                            ) VALUES (?, ?, ?, 1, 2, ?, ?, 30, 5, 5, 0, 30, 30, 0, ?, 5, ?, ?)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(cardID), DatabaseValueCodec.encode(noteID),
                            template, dueAt, nowMilliseconds - 30 * 86_400_000,
                            nowMilliseconds - 30 * 86_400_000,
                            SwiftFSRSReviewScheduler.algorithmVersion,
                            DatabaseValueCodec.encode(profileID)
                        ]
                    )
                }
            }

            let historicalStudyDayID = performanceUUID(60_000)
            let historicalStart: Int64 = 1_735_689_600_000
            let snapshots = try performanceReviewSnapshots(
                profileID: profileID,
                now: now
            )
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2025-01-01', ?, ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(historicalStudyDayID), timeZoneID,
                    historicalStart, historicalStart + 86_400_000
                ]
            )
            for logIndex in 0..<100_000 {
                let cardIndex = logIndex % 20_000
                let noteIndex = cardIndex / 2
                let cardID = performanceUUID(30_000 + cardIndex)
                try db.execute(
                    sql: """
                        INSERT INTO review_logs(
                            id, event_id, card_id, card_key, note_id, deck_id_at_review,
                            reviewed_at_ms, study_day_id, was_first_study, rating,
                            previous_state_json, next_state_json, duration_ms,
                            content_version, profile_id, algorithm_version, undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 500, 1, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(performanceUUID(100_000 + logIndex)),
                        DatabaseValueCodec.encode(performanceUUID(300_000 + logIndex)),
                        DatabaseValueCodec.encode(cardID), DatabaseValueCodec.encode(cardID),
                        DatabaseValueCodec.encode(performanceUUID(10_000 + noteIndex)),
                        DatabaseValueCodec.encode(deckID), historicalStart + Int64(logIndex),
                        DatabaseValueCodec.encode(historicalStudyDayID), (logIndex % 4) + 1,
                        snapshots.previous, snapshots.next,
                        DatabaseValueCodec.encode(profileID),
                        SwiftFSRSReviewScheduler.algorithmVersion
                    ]
                )
            }
        }
        try database.close()
    }

    func counts() async throws -> (notes: Int, cards: Int, reviewLogs: Int) {
        let database = try OboeDatabase(path: databaseURL.path)
        defer { try? database.close() }
        return try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? 0
            )
        }
    }

    func exportIfRequested() async throws {
        guard let rawPath = ProcessInfo.processInfo.environment["OBOE_P22B_EXPORT_DIRECTORY"],
              !rawPath.isEmpty else { return }
        let outputURL = URL(fileURLWithPath: rawPath, isDirectory: true)
        let database = try OboeDatabase(path: databaseURL.path)
        defer { try? database.close() }
        let export = try await PortableBackupExporter(
            database: database,
            workingDirectoryURL: outputURL
        ).export(appVersion: "0.1.0-p22b", at: now)
        let size = try FileManager.default.attributesOfItem(atPath: export.url.path)[.size]
            as? NSNumber
        print("P22B_PORTABLE_DATASET=\(export.url.path),bytes:\(size?.intValue ?? 0)")
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: database,
            workingDirectoryURL: directoryURL.appendingPathComponent(
                "RestoreValidation",
                isDirectory: true
            )
        )
        let preparation = try await preparer.prepare(fileURL: export.url)
        guard preparation.backup.noteCount == 10_000,
              preparation.backup.cardCount == 20_000,
              preparation.backup.reviewCount == 100_000 else {
            throw P22bPerformanceFixtureError.invalidPortableDataset
        }
        try await preparer.discard(preparation)
        print("P22B_PORTABLE_DATASET_RESTORE_PREPARATION=passed")
    }

    func makeStudySessionService(database: OboeDatabase) -> StudySessionService {
        let submissions = GRDBReviewSubmissionRepository(database: database)
        return StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: GRDBReviewCardContentRepository(database: database),
            submissionRepository: submissions,
            undoRepository: submissions,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: P22bFixedClock(value: now)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct P22bFixedClock: SchedulingClock {
    let value: Date

    func now() -> Date { value }
}

private enum P22bPerformanceFixtureError: Error {
    case invalidPortableDataset
}

private func performanceUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func performanceReviewSnapshots(
    profileID: UUID,
    now: Date
) throws -> (previous: String, next: String) {
    let firstStudiedAt = now.addingTimeInterval(-365 * 86_400)
    let previous = ReviewSchedulingSnapshot(
        scheduling: SchedulingCard(
            dueAt: now.addingTimeInterval(-86_400),
            stability: 30,
            difficulty: 5,
            elapsedDays: 30,
            scheduledDays: 30,
            repetitions: 4,
            state: .review,
            lastReviewAt: now.addingTimeInterval(-30 * 86_400)
        ),
        firstStudiedAt: firstStudiedAt,
        stateVersion: 4,
        algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
        profileID: profileID
    )
    let next = ReviewSchedulingSnapshot(
        scheduling: SchedulingCard(
            dueAt: now.addingTimeInterval(30 * 86_400),
            stability: 30,
            difficulty: 5,
            elapsedDays: 30,
            scheduledDays: 30,
            repetitions: 5,
            state: .review,
            lastReviewAt: now
        ),
        firstStudiedAt: firstStudiedAt,
        stateVersion: 5,
        algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
        profileID: profileID
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return (
        String(decoding: try encoder.encode(previous), as: UTF8.self),
        String(decoding: try encoder.encode(next), as: UTF8.self)
    )
}

private func percentile95(
    samples: Int,
    operation: () async throws -> Void
) async throws -> TimeInterval {
    var durations: [TimeInterval] = []
    for _ in 0..<samples {
        let started = ContinuousClock.now
        try await operation()
        durations.append(seconds(since: started))
    }
    return percentile95(durations)
}

private func percentile95(_ durations: [TimeInterval]) -> TimeInterval {
    let sorted = durations.sorted()
    return sorted[Int(Double(sorted.count - 1) * 0.95)]
}

private func seconds(since started: ContinuousClock.Instant) -> TimeInterval {
    let duration = started.duration(to: .now)
    return Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
}

private func printMetric(_ name: String, _ seconds: TimeInterval) {
    print(String(format: "%@=%.3f", name, seconds * 1_000))
}
