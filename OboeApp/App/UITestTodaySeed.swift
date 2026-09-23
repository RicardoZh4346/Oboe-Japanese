#if DEBUG
import Foundation
import GRDB
import OboeDomain
import OboeInfrastructure

extension AppRuntimeController {
    /// `OBOE_UI_TEST_TODAY_SEED`：v0.5.5 首页五状态的确定性夹具。
    /// 取值：
    /// - `empty-deck`：一个无任何卡片的主牌组（「这个牌组还没有卡片」）；
    /// - `ready`：主牌组含一张到期复习卡 + 一张新卡（CTA 可点击）；
    /// - `waiting`：今日已无当前可学卡，但有一张本学习日内稍后到期的
    ///   学习卡（「本轮完成 · 稍后还有」）；
    /// - `complete`：今日任务全部完成（一张已评分卡，到期时间推到次日）。
    /// 不取值时由调用方保持空库——「无牌组」态无需任何种子。
    ///
    /// 与旧 seed 不同：这里显式写 `note_decks`——牌组 scope 走成员关系
    /// EXISTS 过滤，缺行的 Note 在主牌组会话中不可见。
    func seedTodayUITestData(database: OboeDatabase, mode: String) async throws {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let profileID = UUID()
        let deckID = UUID()
        let noteID = UUID()
        let secondNoteID = UUID()

        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, '主牌组', 0, ?, ?)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID), nowMs, nowMs]
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
                    nowMs
                ]
            )

            switch mode {
            case "empty-deck":
                break
            case "ready":
                try insertSeededNote(
                    noteID: noteID, deckID: deckID,
                    headword: "読む", reading: "よむ", meaning: "读",
                    at: nowMs, in: db
                )
                // 到期复习卡（已进入今日队列）+ 全新卡（走新词额度入队）。
                try insertSeededCard(
                    cardID: UUID(), noteID: noteID, deckID: deckID,
                    template: "vocabulary_ja_zh", state: 2,
                    dueAtMs: nowMs - 3_600_000,
                    firstStudiedAtMs: nowMs - 20 * 86_400_000,
                    profileID: profileID, at: nowMs, in: db
                )
                try insertSeededNote(
                    noteID: secondNoteID, deckID: deckID,
                    headword: "書く", reading: "かく", meaning: "写",
                    at: nowMs, in: db
                )
                try insertSeededCard(
                    cardID: UUID(), noteID: secondNoteID, deckID: deckID,
                    template: "vocabulary_ja_zh", state: 0,
                    dueAtMs: nowMs,
                    firstStudiedAtMs: nil,
                    profileID: profileID, at: nowMs, in: db
                )
            case "waiting", "complete":
                try insertSeededNote(
                    noteID: noteID, deckID: deckID,
                    headword: "読む", reading: "よむ", meaning: "读",
                    at: nowMs, in: db
                )
                // 「完成」态：已学卡 due 推到学习日之后；「等待」态的占位卡
                // 先同样入库，due 时间在拿到学习日边界后回填。
                try insertSeededCard(
                    cardID: UUID(), noteID: noteID, deckID: deckID,
                    template: "vocabulary_ja_zh", state: 2,
                    dueAtMs: nowMs + 26 * 3_600_000,
                    firstStudiedAtMs: nowMs - 10 * 86_400_000,
                    profileID: profileID, at: nowMs, in: db
                )
            default:
                break
            }
        }

        // 物化今日学习日，让到期卡/新卡进入队列。
        guard let plan = try await studySessionService?.buildTodayPlan(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
        ) else { return }
        let studyDayID = plan.studyDay.id
        let studyDayEndsMs = Int64(plan.studyDay.endsAt.timeIntervalSince1970 * 1000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let previousJSON = String(
            decoding: try encoder.encode(
                ReviewSchedulingSnapshot(
                    scheduling: SchedulingCard(
                        dueAt: now.addingTimeInterval(-86_400),
                        stability: 3.0, difficulty: 8.0,
                        repetitions: 5, lapses: 0, state: .review
                    ),
                    firstStudiedAt: now.addingTimeInterval(-10 * 86_400),
                    stateVersion: 5,
                    algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                    profileID: profileID
                )
            ),
            as: UTF8.self
        )
        let nextJSON = String(
            decoding: try encoder.encode(
                ReviewSchedulingSnapshot(
                    scheduling: SchedulingCard(
                        dueAt: now.addingTimeInterval(4 * 86_400),
                        stability: 4.0, difficulty: 7.5,
                        repetitions: 6, lapses: 0, state: .review
                    ),
                    firstStudiedAt: now.addingTimeInterval(-10 * 86_400),
                    stateVersion: 6,
                    algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                    profileID: profileID
                )
            ),
            as: UTF8.self
        )

        try await database.pool.write { db in
            switch mode {
            case "waiting":
                // 学习中的卡：due 落在本学习日内但晚于现在 → availableLater。
                // 距 04:00 边界不足 2 分钟时退化为无后续任务（调用方不会用
                // 该种子断言等待态）。
                let laterDueMs = min(nowMs + 45 * 60_000, studyDayEndsMs - 60_000)
                guard laterDueMs > nowMs else { return }
                let waitingCardID = UUID()
                try insertSeededCard(
                    cardID: waitingCardID, noteID: noteID, deckID: deckID,
                    template: "vocabulary_zh_ja", state: 1,
                    dueAtMs: laterDueMs,
                    firstStudiedAtMs: nowMs - 3_600_000,
                    profileID: profileID, at: nowMs, in: db
                )
                try db.execute(
                    sql: """
                        INSERT INTO daily_tasks(
                            study_day_id, card_id, category_at_admission, admitted_at_ms
                        ) VALUES (?, ?, 'learning', ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(studyDayID),
                        DatabaseValueCodec.encode(waitingCardID),
                        nowMs - 3_600_000
                    ]
                )
            case "complete":
                // 已评分卡 + 今日入队记录：remaining = 0 且 completed ≥ 1。
                let doneCardID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM cards WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                ).map { try DatabaseValueCodec.decodeUUID($0) }!
                try db.execute(
                    sql: """
                        INSERT INTO daily_tasks(
                            study_day_id, card_id, category_at_admission, admitted_at_ms
                        ) VALUES (?, ?, 'review', ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(studyDayID),
                        DatabaseValueCodec.encode(doneCardID),
                        nowMs - 7_200_000
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO review_logs(
                            id, event_id, card_id, card_key, note_id, deck_id_at_review,
                            reviewed_at_ms, study_day_id, was_first_study, rating,
                            previous_state_json, next_state_json, duration_ms,
                            content_version, profile_id, algorithm_version, undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 12000, 1, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(doneCardID),
                        DatabaseValueCodec.encode(doneCardID),
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                        nowMs - 3_600_000,
                        DatabaseValueCodec.encode(studyDayID),
                        ReviewRating.good.rawValue,
                        previousJSON,
                        nextJSON,
                        DatabaseValueCodec.encode(profileID),
                        SwiftFSRSReviewScheduler.algorithmVersion
                    ]
                )
            default:
                break
            }
        }

        if mode == "waiting" {
            // 重新构建让后到的学习卡进入队列视图。
            _ = try await studySessionService?.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
        }
    }

    nonisolated private func insertSeededNote(
        noteID: UUID,
        deckID: UUID,
        headword: String,
        reading: String,
        meaning: String,
        at nowMs: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    origin, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', ?, ?, ?, 'manual', 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(noteID),
                DatabaseValueCodec.encode(deckID),
                headword, reading, meaning, nowMs, nowMs
            ]
        )
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

    nonisolated private func insertSeededCard(
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        template: String,
        state: Int,
        dueAtMs: Int64,
        firstStudiedAtMs: Int64?,
        profileID: UUID,
        at nowMs: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cards(
                    id, note_id, template_kind, is_enabled, state, due_at_ms,
                    stability, difficulty, reps, lapses, scheduled_days,
                    elapsed_days, learning_step, first_studied_at_ms,
                    state_version, algorithm_version, profile_id
                ) VALUES (?, ?, ?, 1, ?, ?, 4.0, 8.0, 8, 0, 0, 0, 0, ?, 8, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(cardID),
                DatabaseValueCodec.encode(noteID),
                template,
                state,
                dueAtMs,
                firstStudiedAtMs,
                SwiftFSRSReviewScheduler.algorithmVersion,
                DatabaseValueCodec.encode(profileID)
            ]
        )
    }
}
#endif
