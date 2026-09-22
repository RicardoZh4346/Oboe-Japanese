import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.5.5 每日统计夹具：在临时库中物化一段连续 study_days 与可控的
/// review_logs 分布，覆盖零记录日、撤销日志、04:00 跨界（评分落在
/// 学习日子夜后仍归属前一学习日）与多牌组共享 Note（日志不被成员
/// 关系放大）。
final class DailyStatisticsDatabaseFixture: @unchecked Sendable {
    /// 固定「现在」：2026-09-15T13:33:20+08:00（Asia/Shanghai 无 DST），
    /// 处于 09-15 学习日（04:00–次日 04:00）的中段。
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-15T01:33:20Z
    static let timeZoneID = "Asia/Shanghai"

    struct SeededDay: Sendable {
        let studyDay: StudyDay
        var validLogCount = 0
        var answerCount = 0
        var durationMilliseconds = 0
        var ratings = RatingDistribution(again: 0, hard: 0, good: 0, easy: 0)
        var firstStudyNoteIDs: Set<UUID> = []
        var reviewedCardIDs: Set<UUID> = []

        var newLearnedCount: Int { firstStudyNoteIDs.count }
        var reviewedCardCount: Int { reviewedCardIDs.count }
    }

    let directoryURL: URL
    let database: OboeDatabase
    let profileID = UUID()
    let deckAID = UUID()
    let deckBID = UUID()
    /// days[0] 是「今天」所在学习日，之后逐日向前。
    private(set) var days: [SeededDay] = []
    /// 两个牌组共享的 Note；其日志在两个牌组视角下只计一次。
    let sharedNoteID = UUID()
    let exclusiveNoteID = UUID()
    let sharedCardID = UUID()
    let exclusiveCardID = UUID()

    private init(directoryURL: URL, database: OboeDatabase) {
        self.directoryURL = directoryURL
        self.database = database
    }

    /// `dayCount` 学习日连续回填到今天；`logPlan` 以「距今天的天数」为键
    /// 描述每日日志（缺席即零记录日）。
    static func make(
        dayCount: Int = 35,
        timeZoneID: String = timeZoneID,
        now: Date = now,
        logPlan: (DailyStatisticsDatabaseFixture) async throws -> Void
    ) async throws -> DailyStatisticsDatabaseFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-DailyStats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        let fixture = DailyStatisticsDatabaseFixture(
            directoryURL: directoryURL,
            database: database
        )
        try await fixture.seedSchema(
            dayCount: dayCount,
            timeZoneID: timeZoneID,
            now: now
        )
        try await logPlan(fixture)
        return fixture
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: - Schema seeding

    private func seedSchema(
        dayCount: Int,
        timeZoneID: String,
        now: Date
    ) async throws {
        let calculator = StudyDayBoundaryCalculator()
        var studyDays: [StudyDay] = []
        var day = try calculator.studyDay(
            containing: now,
            timeZoneID: timeZoneID,
            newCardLimit: 10
        )
        studyDays.append(day)
        for _ in 1..<dayCount {
            day = try calculator.studyDay(
                containing: day.startsAt.addingTimeInterval(-1),
                timeZoneID: timeZoneID,
                newCardLimit: 10
            )
            studyDays.append(day)
        }
        days = studyDays.map { SeededDay(studyDay: $0) }

        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let nowMs = try DatabaseValueCodec.encode(now)
        try await database.pool.write { [studyDays] db in
            for (index, deckID) in [deckAID, deckBID].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(deckID),
                        index == 0 ? "主牌组" : "共享牌组",
                        index, nowMs, nowMs
                    ]
                )
            }
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
                    nowMs
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, primary_deck_id
                    ) VALUES (1, 1, ?, 10, ?)
                    """,
                arguments: [timeZoneID, DatabaseValueCodec.encode(deckAID)]
            )
            for day in studyDays {
                try db.execute(
                    sql: """
                        INSERT INTO study_days(
                            id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                        ) VALUES (?, ?, ?, ?, ?, 10)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(day.id),
                        day.localDate,
                        day.timeZoneID,
                        try DatabaseValueCodec.encode(day.startsAt),
                        try DatabaseValueCodec.encode(day.endsAt)
                    ]
                )
            }
            // sharedNote 同时属于 A/B 两个牌组；exclusiveNote 只属于 B。
            for (noteID, deckID, headword) in [
                (sharedNoteID, deckAID, "共有"),
                (exclusiveNoteID, deckBID, "独占")
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', ?, 'よみ', '释义', 'manual', 1, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                        headword, nowMs, nowMs
                    ]
                )
            }
            for (noteID, deckID) in [
                (sharedNoteID, deckAID),
                (sharedNoteID, deckBID),
                (exclusiveNoteID, deckBID)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                        nowMs
                    ]
                )
            }
            for (cardID, noteID) in [
                (sharedCardID, sharedNoteID),
                (exclusiveCardID, exclusiveNoteID)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, first_studied_at_ms,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 2, ?, 4.0, 8.0, 3, 0,
                                  0, 0, 0, ?, 3, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(cardID),
                        DatabaseValueCodec.encode(noteID),
                        nowMs - 86_400_000,
                        nowMs - 40 * 86_400_000,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
        }
    }

    // MARK: - Log seeding

    /// 在 `daysAgo`（0 = 今天）对应的学习日内追加一条评分日志。
    /// `reviewedAt` 缺省取该学习日中点；可显式指定以覆盖 04:00 前后。
    @discardableResult
    func addLog(
        daysAgo: Int,
        cardID: UUID? = nil,
        noteID: UUID? = nil,
        deckID: UUID? = nil,
        rating: ReviewRating = .good,
        wasFirstStudy: Bool = false,
        durationMilliseconds: Int = 900,
        reviewedAt: Date? = nil,
        undoneAt: Date? = nil
    ) async throws {
        guard days.indices.contains(daysAgo) else {
            XCTFail("daysAgo \(daysAgo) 超出夹具天数")
            return
        }
        let day = days[daysAgo].studyDay
        let cardID = cardID ?? sharedCardID
        let noteID = noteID ?? sharedNoteID
        let deckID = deckID ?? deckAID
        let reviewedAt = reviewedAt ?? day.startsAt.addingTimeInterval(43_200)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        @Sendable func snapshot(stateVersion: Int) throws -> String {
            String(
                decoding: try encoder.encode(
                    ReviewSchedulingSnapshot(
                        scheduling: SchedulingCard(
                            dueAt: reviewedAt.addingTimeInterval(86_400),
                            stability: 3.0, difficulty: 8.0,
                            repetitions: 3, lapses: 0, state: .review,
                            lastReviewAt: reviewedAt
                        ),
                        firstStudiedAt: nil,
                        stateVersion: stateVersion,
                        algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                        profileID: profileID
                    )
                ),
                as: UTF8.self
            )
        }
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study, rating,
                        previous_state_json, next_state_json, duration_ms,
                        content_version, profile_id, algorithm_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    try DatabaseValueCodec.encode(reviewedAt),
                    DatabaseValueCodec.encode(day.id),
                    wasFirstStudy,
                    rating.rawValue,
                    try snapshot(stateVersion: 3),
                    try snapshot(stateVersion: 4),
                    durationMilliseconds,
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    try undoneAt.map(DatabaseValueCodec.encode)
                ]
            )
        }
        if undoneAt == nil {
            days[daysAgo].validLogCount += 1
            days[daysAgo].answerCount += 1
            days[daysAgo].durationMilliseconds += durationMilliseconds
            if wasFirstStudy {
                days[daysAgo].firstStudyNoteIDs.insert(noteID)
            } else {
                days[daysAgo].reviewedCardIDs.insert(cardID)
            }
            let ratings = days[daysAgo].ratings
            days[daysAgo].ratings = RatingDistribution(
                again: ratings.again + (rating == .again ? 1 : 0),
                hard: ratings.hard + (rating == .hard ? 1 : 0),
                good: ratings.good + (rating == .good ? 1 : 0),
                easy: ratings.easy + (rating == .easy ? 1 : 0)
            )
        }
    }

    /// 该学习日对应的 `localDate`（「YYYY-MM-DD」）。
    func localDate(daysAgo: Int) -> String {
        days[daysAgo].studyDay.localDate
    }
}
