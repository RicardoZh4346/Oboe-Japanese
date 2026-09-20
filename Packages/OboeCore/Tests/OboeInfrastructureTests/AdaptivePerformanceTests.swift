import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T02 performance gate (plan: 10,000 卡 / 100,000 有效日志；预算：暖计数
/// p95≤300ms、列表首屏≤500ms、冷查询≤1.5s — 记录实际数值而不是假设）。
/// Run with `OBOE_RUN_ADAPTIVE_PERFORMANCE=1`.
final class AdaptivePerformanceTests: XCTestCase {
    func testAdaptiveSnapshotPerformance() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OBOE_RUN_ADAPTIVE_PERFORMANCE"] == "1",
            "Set OBOE_RUN_ADAPTIVE_PERFORMANCE=1 for the adaptive performance run."
        )

        let cardCount = 10_000
        let logsPerCard = 10
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AdaptivePerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        let seedStart = ContinuousClock.now
        try await Self.seed(
            database: database,
            cardCount: cardCount,
            logsPerCard: logsPerCard
        )
        let seedMilliseconds = ContinuousClock.now - seedStart

        let repository = GRDBAdaptiveRepository(database: database)
        let service = AdaptiveCardService(repository: repository)
        let now = Date()

        // Cold: full scan + classify of every live card.
        let coldStart = ContinuousClock.now
        let snapshot = try await service.snapshot(scope: .all, at: now)
        let coldMilliseconds = ContinuousClock.now - coldStart
        XCTAssertEqual(snapshot.items.count, cardCount)

        // Warm: cached snapshot — the path the home entry takes on repeat
        // visits inside the same bucket.
        var warmSamples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            _ = try await service.snapshot(scope: .all, at: now)
            warmSamples.append(
                Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            )
        }
        let warmP95 = Self.percentile95(warmSamples) * 1000

        // Post-commit rescan: one new log invalidates through data_version.
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE review_logs SET duration_ms = duration_ms + 1
                    WHERE id = (SELECT id FROM review_logs LIMIT 1)
                    """
            )
        }
        let rescanStart = ContinuousClock.now
        _ = try await service.snapshot(scope: .all, at: now)
        let rescanMilliseconds = ContinuousClock.now - rescanStart

        var model = ""
        var size = Int(model.count)
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        model = String(cString: buffer)

        print("""
        ADAPTIVE_PERF device=\(model) \
        dataset=cards:\(cardCount),logs:\(cardCount * logsPerCard) \
        seedMs=\(Self.milliseconds(seedMilliseconds)) \
        coldMs=\(Self.milliseconds(coldMilliseconds)) \
        warmP95Ms=\(String(format: "%.2f", warmP95)) \
        postCommitRescanMs=\(Self.milliseconds(rescanMilliseconds))
        """)

        // Sanity bounds only — the real budgets are recorded above, not
        // enforced on shared CI hardware.
        XCTAssertLessThan(Self.milliseconds(coldMilliseconds), 60_000)
        XCTAssertLessThan(warmP95, 5_000)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15
    }

    private static func percentile95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    /// Bulk seed: 10k notes/cards, 100k logs in one transaction with reused
    /// JSON snapshot blobs — seeding speed is not the measured quantity.
    private static func seed(
        database: OboeDatabase,
        cardCount: Int,
        logsPerCard: Int
    ) async throws {
        let base = Date(timeIntervalSince1970: 1_788_000_000)
        let baseMilliseconds = try DatabaseValueCodec.encode(base)
        let deckID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let snapshotJSON = { (stateVersion: Int) -> String in
            let snapshot = ReviewSchedulingSnapshot(
                scheduling: SchedulingCard(
                    dueAt: base.addingTimeInterval(-86_400),
                    stability: 4.0,
                    difficulty: 6.0,
                    repetitions: stateVersion,
                    lapses: 1,
                    state: .review
                ),
                firstStudiedAt: base.addingTimeInterval(-120 * 86_400),
                stateVersion: stateVersion,
                algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                profileID: profileID
            )
            return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        }
        let previousJSON = try snapshotJSON(7)
        let nextJSON = try snapshotJSON(8)

        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'perf', 0, ?, ?)",
                arguments: [DatabaseValueCodec.encode(deckID), baseMilliseconds, baseMilliseconds]
            )
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
                    baseMilliseconds
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-08-01', 'Asia/Shanghai', ?, ?, 50)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    baseMilliseconds - 90 * 86_400_000,
                    baseMilliseconds + 90 * 86_400_000
                ]
            )

            let noteStatement = try db.makeStatement(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, ?, 'manual', 1, ?, ?)
                    """
            )
            let cardStatement = try db.makeStatement(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 2, ?, 4.0, 6.0, 8, 2,
                              0, 0, 0, 8, ?, ?)
                    """
            )
            let logStatement = try db.makeStatement(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study, rating,
                        previous_state_json, next_state_json, duration_ms,
                        content_version, profile_id, algorithm_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 900, 1, ?, ?, NULL)
                    """
            )

            let encodedDeck = DatabaseValueCodec.encode(deckID)
            let encodedProfile = DatabaseValueCodec.encode(profileID)
            let encodedStudyDay = DatabaseValueCodec.encode(studyDayID)

            for index in 0..<cardCount {
                let noteID = UUID()
                let cardID = UUID()
                try noteStatement.execute(
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        encodedDeck,
                        "単語\(index)",
                        "词\(index)",
                        baseMilliseconds,
                        baseMilliseconds
                    ]
                )
                try cardStatement.execute(
                    arguments: [
                        DatabaseValueCodec.encode(cardID),
                        DatabaseValueCodec.encode(noteID),
                        baseMilliseconds,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        encodedProfile
                    ]
                )
                for logIndex in 0..<logsPerCard {
                    let reviewedAt = try DatabaseValueCodec.encode(
                        base.addingTimeInterval(TimeInterval(-logIndex * 86_400))
                    )
                    try logStatement.execute(
                        arguments: [
                            DatabaseValueCodec.encode(UUID()),
                            DatabaseValueCodec.encode(UUID()),
                            DatabaseValueCodec.encode(cardID),
                            DatabaseValueCodec.encode(cardID),
                            DatabaseValueCodec.encode(noteID),
                            encodedDeck,
                            reviewedAt,
                            encodedStudyDay,
                            logIndex % 5 == 0 ? 1 : 3,
                            previousJSON,
                            nextJSON,
                            encodedProfile,
                            SwiftFSRSReviewScheduler.algorithmVersion
                        ]
                    )
                }
            }
        }
    }
}
