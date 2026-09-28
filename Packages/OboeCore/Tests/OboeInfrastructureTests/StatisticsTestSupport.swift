import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S20 统计测试对 `DailyStatisticsDatabaseFixture` 的扩展：不改原文件，
/// 单独加 Note/Card/删除/practice/批量日志的种子手段。所有写路径直接
/// 走 SQL（统计层只读，测试夹具负责把「发生过的事」摆出来）。
extension DailyStatisticsDatabaseFixture {

    /// 追加一个 Note（`memberDeckIDs` 缺省 = home deck 单独成员）。
    @discardableResult
    func addNote(
        id: UUID = UUID(),
        kind: String = "vocabulary",
        headword: String = "词语",
        deckID: UUID? = nil,
        memberDeckIDs: [UUID]? = nil
    ) async throws -> UUID {
        let home = deckID ?? deckAID
        let members = memberDeckIDs ?? [home]
        let nowMs = try DatabaseValueCodec.encode(Self.now)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, 'よみ', '释义', 'manual', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(home),
                    kind, headword, nowMs, nowMs
                ]
            )
            for member in members {
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(id),
                        DatabaseValueCodec.encode(member),
                        nowMs
                    ]
                )
            }
        }
        return id
    }

    /// 追加一张卡，调度字段全部可控（state: 0 new / 1 learning /
    /// 2 review / 3 relearning）。
    @discardableResult
    func addCard(
        id: UUID = UUID(),
        noteID: UUID,
        templateKind: String = "vocabulary_ja_zh",
        isEnabled: Bool = true,
        state: Int = 2,
        dueAt: Date,
        lastReviewAt: Date? = nil,
        stability: Double = 10,
        difficulty: Double = 5,
        scheduledDays: Double = 0,
        profileID: UUID? = nil
    ) async throws -> UUID {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step,
                        first_studied_at_ms, state_version, algorithm_version,
                        profile_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, 0, 0, ?, 3, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(noteID),
                    templateKind,
                    isEnabled,
                    state,
                    try DatabaseValueCodec.encode(dueAt),
                    try lastReviewAt.map(DatabaseValueCodec.encode),
                    stability,
                    difficulty,
                    scheduledDays,
                    try lastReviewAt.map(DatabaseValueCodec.encode), // first_studied_at ≈ 首评
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID ?? self.profileID)
                ]
            )
        }
        return id
    }

    /// 删除 Note：级联删 cards/note_decks，`review_logs.card_id` 被
    /// SET NULL、`card_key`/`note_id` 原样保留（orphan 历史场景）。
    func deleteNote(_ noteID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
    }

    /// 单独删除一张卡（Note 保留）——「删卡日志仍按历史 noteID 计」场景。
    func deleteCard(_ cardID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    /// 自定义快照的日志写入：`previousScheduling`/`nextScheduling` 显式
    /// 可控（实测保持率需要 prev.state / prev.lastReviewAt 的不同组合）。
    /// 返回 eventID 供 `scheduled_review_origins` 登记用。
    @discardableResult
    func addLogDetailed(
        daysAgo: Int,
        cardKey: UUID,
        cardID: UUID? = nil,
        noteID: UUID,
        deckID: UUID? = nil,
        rating: ReviewRating = .good,
        wasFirstStudy: Bool = false,
        durationMilliseconds: Int = 900,
        reviewedAt: Date? = nil,
        previousScheduling: SchedulingCard,
        nextScheduling: SchedulingCard? = nil,
        undoneAt: Date? = nil,
        eventID: UUID = UUID()
    ) async throws -> UUID {
        guard days.indices.contains(daysAgo) else {
            XCTFail("daysAgo \(daysAgo) 超出夹具天数")
            return eventID
        }
        let day = days[daysAgo].studyDay
        let reviewedAt = reviewedAt ?? day.startsAt.addingTimeInterval(43_200)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let previous = ReviewSchedulingSnapshot(
            scheduling: previousScheduling,
            firstStudiedAt: previousScheduling.lastReviewAt,
            stateVersion: 3,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        let next = ReviewSchedulingSnapshot(
            scheduling: nextScheduling ?? previousScheduling,
            firstStudiedAt: previous.firstStudiedAt,
            stateVersion: 4,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
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
                    DatabaseValueCodec.encode(eventID),
                    try cardID.map(DatabaseValueCodec.encode),
                    DatabaseValueCodec.encode(cardKey),
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID ?? deckAID),
                    try DatabaseValueCodec.encode(reviewedAt),
                    DatabaseValueCodec.encode(day.id),
                    wasFirstStudy,
                    rating.rawValue,
                    String(decoding: try encoder.encode(previous), as: UTF8.self),
                    String(decoding: try encoder.encode(next), as: UTF8.self),
                    durationMilliseconds,
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    try undoneAt.map(DatabaseValueCodec.encode)
                ]
            )
        }
        return eventID
    }

    /// practiceOnly 会话 + 若干 `practice_attempts`——断言它们对所有
    /// 正式统计零影响。
    @discardableResult
    func addPracticeSession(
        mode: String = "practiceOnly",
        attempts: [(cardKey: UUID, noteID: UUID, rating: ReviewRating)] = []
    ) async throws -> UUID {
        let sessionID = UUID()
        let nowMs = try DatabaseValueCodec.encode(Self.now)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO custom_study_sessions(
                        id, filter_json, mode, status, started_at_ms,
                        finished_at_ms, queue_json
                    ) VALUES (?, '{}', ?, 'finished', ?, ?, '[]')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(sessionID),
                    mode, nowMs - 3_600_000, nowMs
                ]
            )
            for (cardKey, noteID, rating) in attempts {
                try db.execute(
                    sql: """
                        INSERT INTO practice_attempts(
                            id, event_id, session_id, card_key, note_id,
                            rating, answered_at_ms, duration_ms, content_version,
                            undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 800, 1, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(sessionID),
                        DatabaseValueCodec.encode(cardKey),
                        DatabaseValueCodec.encode(noteID),
                        rating.rawValue,
                        nowMs - 1_800_000
                    ]
                )
            }
        }
        return sessionID
    }

    /// 给一条正式 review_log 补 `scheduled_review_origins` 登记
    /// （customScheduled 模式的正式提交——仍应计入统计）。
    func addScheduledOrigin(eventID: UUID, sessionID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduled_review_origins(
                        event_id, session_id, submission_kind
                    ) VALUES (?, ?, 'customScheduled')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(eventID),
                    DatabaseValueCodec.encode(sessionID)
                ]
            )
        }
    }

    /// 追加一个自定义 scheduler profile（多 profile 加权场景）。
    func addSchedulerProfile(
        id: UUID = UUID(),
        desiredRetention: Double,
        parameters: [Double] = SchedulerProfile.fsrs6DefaultParameters
    ) async throws -> UUID {
        let nowMs = try DatabaseValueCodec.encode(Self.now)
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(parameters),
            as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 36500, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    "fsrs-6.0-custom-r\(Int(desiredRetention * 100))-\(id.uuidString.prefix(8))",
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parametersJSON,
                    desiredRetention,
                    nowMs
                ]
            )
        }
        return id
    }

    /// 100k 压测：单事务批量灌 `totalCount` 条 review_logs。
    /// `card_id` 写 NULL（卡已删形态）以同时构造 orphan 历史；
    /// `card_key`/`note_id` 从给定池轮换。快照 JSON 复用同一段合法串。
    func bulkInsertLogs(
        totalCount: Int,
        cardKeyPool: [UUID],
        noteIDPool: [UUID]
    ) async throws {
        guard !cardKeyPool.isEmpty, !noteIDPool.isEmpty else {
            XCTFail("批量灌库需要非空 card/note 池")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: Self.now,
                stability: 3, difficulty: 8,
                elapsedDays: 5, scheduledDays: 10,
                repetitions: 3, lapses: 0,
                state: .review,
                // 距最早的窗口内学习日（day29）也满足 ≥1 日间隔——
                // now−40d 保证 30 日窗口内所有行都是合格保持率样本。
                lastReviewAt: Self.now.addingTimeInterval(-40 * 86_400)
            ),
            firstStudiedAt: Self.now.addingTimeInterval(-40 * 86_400),
            stateVersion: 3,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
        let snapshotJSON = String(
            decoding: try encoder.encode(snapshot),
            as: UTF8.self
        )
        let insertSQL = """
            INSERT INTO review_logs(
                id, event_id, card_id, card_key, note_id, deck_id_at_review,
                reviewed_at_ms, study_day_id, was_first_study, rating,
                previous_state_json, next_state_json, duration_ms,
                content_version, profile_id, algorithm_version, undone_at_ms
            ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 0, ?, ?, ?, 900, 1, ?, ?, NULL)
            """
        try await database.pool.write { [days] db in
            // 同一连接内 SQL 串相同 → GRDB 自动复用 prepared statement，
            // 100k 行单事务落库约秒级。
            for index in 0..<totalCount {
                let day = days[index % days.count].studyDay
                // 评分按「日内序号」而非 index%4：index%40 与 index%4
                // 相关会让每个学习日只剩单一评分，窗口内分布失真。
                let rating = (index / days.count) % 4 + 1
                try db.execute(
                    sql: insertSQL,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(cardKeyPool[index % cardKeyPool.count]),
                        DatabaseValueCodec.encode(noteIDPool[index % noteIDPool.count]),
                        DatabaseValueCodec.encode(deckAID),
                        try DatabaseValueCodec.encode(
                            day.startsAt.addingTimeInterval(43_200)
                        ),
                        DatabaseValueCodec.encode(day.id),
                        rating,
                        snapshotJSON,
                        snapshotJSON,
                        DatabaseValueCodec.encode(profileID),
                        SwiftFSRSReviewScheduler.algorithmVersion
                    ]
                )
            }
        }
    }
}
