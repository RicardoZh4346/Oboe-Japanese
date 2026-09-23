#if DEBUG
import Foundation
import GRDB
import OboeDomain
import OboeInfrastructure

extension AppRuntimeController {
    /// `OBOE_UI_TEST_ADAPTIVE_SEED`: deterministic adaptive fixture for UI
    /// tests (T03) — one deck, one vocabulary note with a leech ja→zh card
    /// (lapses 6, six due-review Agains) and a warning zh→ja card (lapses 3,
    /// due later so it never enters today's queue). Covers the home entry,
    /// list filters, detail page and the answer-face reminder.
    func seedAdaptiveUITestData(database: OboeDatabase) async throws {
        let deckID = UUID()
        let noteID = UUID()
        let leechCardID = UUID()
        let warningCardID = UUID()
        let typedRecallSeed = ProcessInfo.processInfo.environment["OBOE_UI_TEST_TYPED_RECALL_SEED"]
        let typedRecall = typedRecallSeed != nil
        // T14: "long" seeds a verbose zh→ja answer so the answer face must
        // scroll — used by the accessibility-size and long-answer checks.
        let longAnswer = typedRecallSeed == "long"
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayMs = Int64(86_400_000)

        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let profileID = UUID()

        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 0, ?, ?)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID), "自适应测试", nowMs, nowMs]
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
                    longAnswer
                        ? "毎日コツコツと練習を続けることが、上達へのいちばんの近道です"
                        : "受ける",
                    longAnswer
                        ? "まいにちコツコツとれんしゅうをつづけることが、じょうたつへのいちばんのちかみちです"
                        : "うける",
                    longAnswer
                        ? "每天坚持踏实练习，是通往进步最近的道路；请结合自己的实际情况灵活运用。"
                        : "接受；遭受",
                    nowMs,
                    nowMs
                ]
            )
            try insertHomeDeckMembership(
                noteID: noteID,
                deckID: deckID,
                atMs: nowMs,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 2, ?, 4.2, 9.1, 14, 6, 0, 0, 0, ?, 14, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(leechCardID),
                    DatabaseValueCodec.encode(noteID),
                    typedRecall ? nowMs + 2 * dayMs : nowMs - 2 * dayMs,
                    nowMs - 60 * dayMs,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, 'vocabulary_zh_ja', 1, 2, ?, 6.0, 7.0, 9, 3, 0, 0, 0, ?, 9, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(warningCardID),
                    DatabaseValueCodec.encode(noteID),
                    typedRecall ? nowMs - 2 * dayMs : nowMs + 2 * dayMs,
                    nowMs - 45 * dayMs,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }

        // T14 seam 已迁至 applyAdaptivePreferenceUITestOverrides()：
        // `OBOE_UI_TEST_TYPED_RECALL_PREF`（含 =off）在全部种子之后统一
        // 应用——v0.5.5 起该偏好默认开启，需要关闭的用例显式传 off。

        // Materialize today's study day and admit the due leech card into the
        // queue so the answer-face reminder can be exercised end to end.
        guard let plan = try await studySessionService?.buildTodayPlan(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
        ) else { return }
        let studyDayID = plan.studyDay.id

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        func snapshot(
            state: SchedulingState,
            dueAt: Date,
            stability: Double,
            difficulty: Double,
            repetitions: Int,
            lapses: Int,
            stateVersion: Int
        ) throws -> String {
            let snapshot = ReviewSchedulingSnapshot(
                scheduling: SchedulingCard(
                    dueAt: dueAt,
                    stability: stability,
                    difficulty: difficulty,
                    elapsedDays: 0,
                    scheduledDays: 0,
                    learningStep: 0,
                    repetitions: repetitions,
                    lapses: lapses,
                    state: state,
                    lastReviewAt: nil
                ),
                firstStudiedAt: nil,
                stateVersion: stateVersion,
                algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
                profileID: profileID
            )
            return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        }

        // Precompute snapshot JSON on the main actor — the GRDB write closure
        // is @Sendable and cannot call the local function above.
        var previousJSONs: [String] = []
        var nextJSONs: [String] = []
        var reviewedAts: [Date] = []
        for index in 0..<6 {
            let reviewedAt = now.addingTimeInterval(TimeInterval(-(1 + index * 3)) * 86_400)
            reviewedAts.append(reviewedAt)
            previousJSONs.append(try snapshot(
                state: .review,
                dueAt: reviewedAt.addingTimeInterval(-86_400),
                stability: 3.0,
                difficulty: 8.8,
                repetitions: 10 + index,
                lapses: 5,
                stateVersion: index * 2
            ))
            nextJSONs.append(try snapshot(
                state: .relearning,
                dueAt: reviewedAt.addingTimeInterval(600_000),
                stability: 1.0,
                difficulty: 9.0,
                repetitions: 11 + index,
                lapses: 6,
                stateVersion: index * 2 + 1
            ))
        }

        let seededLogTimes = reviewedAts
        let seededPreviousJSONs = previousJSONs
        let seededNextJSONs = nextJSONs
        try await database.pool.write { db in
            for index in 0..<6 {
                let reviewedAt = seededLogTimes[index]
                try db.execute(
                    sql: """
                        INSERT INTO review_logs(
                            id, event_id, card_id, card_key, note_id, deck_id_at_review,
                            reviewed_at_ms, study_day_id, was_first_study, rating,
                            previous_state_json, next_state_json, duration_ms,
                            content_version, profile_id, algorithm_version, undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 900, 1, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(leechCardID),
                        DatabaseValueCodec.encode(leechCardID),
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deckID),
                        DatabaseValueCodec.encode(reviewedAt),
                        DatabaseValueCodec.encode(studyDayID),
                        ReviewRating.again.rawValue,
                        seededPreviousJSONs[index],
                        seededNextJSONs[index],
                        DatabaseValueCodec.encode(profileID),
                        SwiftFSRSReviewScheduler.algorithmVersion
                    ]
                )
            }
        }

        // T26 seam (`OBOE_UI_TEST_TREND_SEED`): a second note whose leech
        // state forms strictly inside the current comparison week — all
        // its Again logs sit after the learning-zone Monday-04:00
        // boundary, so the report counts it under 新出现 while the
        // original card stays 仍经常遗忘. The boundary is computed with
        // the same domain helper and the same stored learning time zone
        // the report itself resolves.
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_TREND_SEED"] != nil {
            let timeZoneID = (try? await studySessionService?.loadLearningSettings(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            ).learningTimeZoneID) ?? TimeZone.autoupdatingCurrent.identifier
            let weekStart = (try? AdaptiveTrendWeek.start(
                atOrBefore: now,
                timeZoneID: timeZoneID
            )) ?? now
            let span = max(1, now.timeIntervalSince(weekStart))
            let trendNoteID = UUID()
            let trendCardID = UUID()

            var trendPreviousJSONs: [String] = []
            var trendNextJSONs: [String] = []
            var trendReviewedAts: [Date] = []
            for index in 0..<6 {
                let reviewedAt = weekStart.addingTimeInterval(
                    span * (0.1 + 0.15 * Double(index))
                )
                trendReviewedAts.append(reviewedAt)
                trendPreviousJSONs.append(try snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3.0,
                    difficulty: 8.8,
                    repetitions: 10 + index,
                    lapses: 5,
                    stateVersion: index * 2
                ))
                trendNextJSONs.append(try snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1.0,
                    difficulty: 9.0,
                    repetitions: 11 + index,
                    lapses: 6,
                    stateVersion: index * 2 + 1
                ))
            }

            let seededTrendTimes = trendReviewedAts
            let seededTrendPreviousJSONs = trendPreviousJSONs
            let seededTrendNextJSONs = trendNextJSONs
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', ?, ?, ?, 'manual', 1, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(trendNoteID),
                        DatabaseValueCodec.encode(deckID),
                        "覚える",
                        "おぼえる",
                        "记住",
                        nowMs,
                        nowMs
                    ]
                )
                try insertHomeDeckMembership(
                    noteID: trendNoteID,
                    deckID: deckID,
                    atMs: nowMs,
                    in: db
                )
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, first_studied_at_ms,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 2, ?, 1.0, 9.0, 16, 6, 0, 0, 0, ?, 16, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(trendCardID),
                        DatabaseValueCodec.encode(trendNoteID),
                        nowMs + 2 * dayMs,
                        nowMs - 30 * dayMs,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
                for index in 0..<6 {
                    try db.execute(
                        sql: """
                            INSERT INTO review_logs(
                                id, event_id, card_id, card_key, note_id, deck_id_at_review,
                                reviewed_at_ms, study_day_id, was_first_study, rating,
                                previous_state_json, next_state_json, duration_ms,
                                content_version, profile_id, algorithm_version, undone_at_ms
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 900, 1, ?, ?, NULL)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(UUID()),
                            DatabaseValueCodec.encode(UUID()),
                            DatabaseValueCodec.encode(trendCardID),
                            DatabaseValueCodec.encode(trendCardID),
                            DatabaseValueCodec.encode(trendNoteID),
                            DatabaseValueCodec.encode(deckID),
                            DatabaseValueCodec.encode(seededTrendTimes[index]),
                            DatabaseValueCodec.encode(studyDayID),
                            ReviewRating.again.rawValue,
                            seededTrendPreviousJSONs[index],
                            seededTrendNextJSONs[index],
                            DatabaseValueCodec.encode(profileID),
                            SwiftFSRSReviewScheduler.algorithmVersion
                        ]
                    )
                }
            }
        }
    }
    /// `OBOE_UI_TEST_LISTENING_SEED`: T17 fixture — one deck with two notes:
    /// 聞く/きく carries a due `vocabulary_listening` card (earliest due, so it
    /// is served first), 食べる/たべる carries a due `vocabulary_zh_ja` card so
    /// the same session exercises the audio face then a visual face.
    func seedListeningUITestData(database: OboeDatabase) async throws {
        let deckID = UUID()
        let listeningNoteID = UUID()
        let visualNoteID = UUID()
        let listeningCardID = UUID()
        let visualCardID = UUID()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayMs = Int64(86_400_000)

        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let profileID = UUID()

        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 0, ?, ?)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID), "听力测试", nowMs, nowMs]
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
            for (noteID, headword, reading, meaning) in [
                (listeningNoteID, "聞く", "きく", "听；询问"),
                (visualNoteID, "食べる", "たべる", "吃")
            ] {
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
                        headword,
                        reading,
                        meaning,
                        nowMs,
                        nowMs
                    ]
                )
                try insertHomeDeckMembership(
                    noteID: noteID,
                    deckID: deckID,
                    atMs: nowMs,
                    in: db
                )
            }
            // T19: an example on the listening note makes the accessibility
            // traversal's "no answer text on the question face" assertion
            // cover all four content classes (headword/reading/meaning/
            // example) — it must never appear until reveal.
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(listeningNoteID),
                    "毎朝ラジオを聞く。",
                    "每天早上听广播。"
                ]
            )
            for (cardID, noteID, template, dueAt) in [
                (listeningCardID, listeningNoteID, "vocabulary_listening", nowMs - 2 * dayMs),
                (visualCardID, visualNoteID, "vocabulary_zh_ja", nowMs - dayMs)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, first_studied_at_ms,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 2, ?, 4.0, 8.0, 8, 0, 0, 0, 0, ?, 8, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(cardID),
                        DatabaseValueCodec.encode(noteID),
                        template,
                        dueAt,
                        nowMs - 40 * dayMs,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
        }

        // Admit the due cards into today's queue so 今日 shows a start entry.
        _ = try await studySessionService?.buildTodayPlan(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
        )

        // T18 seam: `OBOE_UI_TEST_LISTENING_AUTOPLAY_OFF` disables the
        // listening autoplay preference through the real service — the
        // load() first materializes the app_settings row so the UPDATE
        // doesn't silently no-op on a fresh database.
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_LISTENING_AUTOPLAY_OFF"] != nil {
            _ = try? await adaptivePreferencesService?.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            _ = try? await adaptivePreferencesService?.setAutoPlayListeningAudio(false)
        }
        // T19 seam 已迁至 applyAdaptivePreferenceUITestOverrides()：
        // `OBOE_UI_TEST_LISTENING_TYPED_PREF`（含 =off）在全部种子之后
        // 统一应用——v0.5.5 起该偏好默认开启。
    }

    /// `OBOE_UI_TEST_SIBLING_SEED`: sibling-separation fixture for T21 —
    /// deck「错开牌组」holds note A（読む/よむ/读）with listening + ja→zh +
    /// zh→ja cards and note B（書く/かく/写）with one ja→zh card; deck
    /// 「干扰牌组」holds note C（習う）with the globally earliest due card so
    /// deck-scoped sessions prove filtering. Queue order (raw due):
    /// C(-500) → A-listening(-400) → A-ja2zh(-300) → A-zh2ja(-200) → B(-100).
    /// With speech unavailable the listening card precheck-skips; with
    /// `OBOE_UI_TEST_SPEECH_STUB=fail` it presents then fails — exercising
    /// the rollback of `lastPresentedNoteID` on skip (§9.2).
    func seedSiblingUITestData(database: OboeDatabase) async throws {
        let deckAID = UUID()
        let deckBID = UUID()
        let noteAID = UUID()
        let noteBID = UUID()
        let noteCID = UUID()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayMs = Int64(86_400_000)

        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let profileID = UUID()

        try await database.pool.write { db in
            for (deckID, name, order) in [
                (deckAID, "错开牌组", 0),
                (deckBID, "干扰牌组", 1)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(deckID), name, order, nowMs, nowMs
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
            for (noteID, deckID, headword, reading, meaning) in [
                (noteAID, deckAID, "読む", "よむ", "读"),
                (noteBID, deckAID, "書く", "かく", "写"),
                (noteCID, deckBID, "習う", "ならう", "学习")
            ] {
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
                        headword,
                        reading,
                        meaning,
                        nowMs,
                        nowMs
                    ]
                )
                try insertHomeDeckMembership(
                    noteID: noteID,
                    deckID: deckID,
                    atMs: nowMs,
                    in: db
                )
            }
            for (noteID, template, offset) in [
                (noteAID, "vocabulary_listening", -400_000),
                (noteAID, "vocabulary_ja_zh", -300_000),
                (noteAID, "vocabulary_zh_ja", -200_000),
                (noteBID, "vocabulary_ja_zh", -100_000),
                // Globally earliest due — a scoped session must never see it.
                (noteCID, "vocabulary_ja_zh", -500_000)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, first_studied_at_ms,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 2, ?, 4.0, 8.0, 8, 0, 0, 0, 0, ?, 8, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(noteID),
                        template,
                        nowMs + Int64(offset),
                        nowMs - 40 * dayMs,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
        }

        // Admit the due cards into today's queue so 今日 shows start entries.
        _ = try await studySessionService?.buildTodayPlan(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
        )
    }

    /// `OBOE_UI_TEST_JLPT_WEAK_SEED`: T25 fixture — a `builtin_jlpt` note
    /// bound to the real N5 entry 食べる (exact source_ref match) carrying
    /// TWO leech directions (ja→zh lapses 6, zh→ja lapses 7) so the weak
    /// list must show the word once and expand to both directions; plus a
    /// same-headword `manual` note whose leech card proves unassociated
    /// notes never enter the builtin weak list (they stay visible only in
    /// the Adaptive center).
    func seedJLPTWeakUITestData(database: OboeDatabase) async throws {
        let deckID = UUID()
        let builtinNoteID = UUID()
        let manualNoteID = UUID()
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayMs = Int64(86_400_000)

        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        let profileID = UUID()

        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 0, ?, ?)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID), "弱项测试", nowMs, nowMs]
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
            // The builtin note associates to the real library entry 食べる —
            // its id is the bundled vocabulary's stable source_ref.
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, source_ref, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                              'builtin_jlpt',
                              'openjlpt:N5:df220e3db92cd43c596cbf63d8b3435c49df5e8fb4da32b65014ff9ab3c29bbd',
                              1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(builtinNoteID),
                    DatabaseValueCodec.encode(deckID),
                    nowMs,
                    nowMs
                ]
            )
            try insertHomeDeckMembership(
                noteID: builtinNoteID,
                deckID: deckID,
                atMs: nowMs,
                in: db
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                              'manual', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(manualNoteID),
                    DatabaseValueCodec.encode(deckID),
                    nowMs,
                    nowMs
                ]
            )
            try insertHomeDeckMembership(
                noteID: manualNoteID,
                deckID: deckID,
                atMs: nowMs,
                in: db
            )
            for (noteID, template, lapses) in [
                (builtinNoteID, "vocabulary_ja_zh", 6),
                (builtinNoteID, "vocabulary_zh_ja", 7),
                (manualNoteID, "vocabulary_ja_zh", 6)
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, first_studied_at_ms,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 2, ?, 3.0, 8.0, 12, ?, 0, 0, 0, ?, 12, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(noteID),
                        template,
                        nowMs + 30 * dayMs,
                        lapses,
                        nowMs - 60 * dayMs,
                        SwiftFSRSReviewScheduler.algorithmVersion,
                        DatabaseValueCodec.encode(profileID)
                    ]
                )
            }
        }
    }

    /// UI 测试的主动回忆偏好覆盖：v0.5.5 起两个 typed 输入默认开启，
    /// `…_PREF=1` 依然幂等可用，`…_PREF=0/off` 显式关闭——需要 reveal
    /// 流程的既有用例靠后者表达，而非再依赖旧默认。两个开关相互独立。
    /// 须在全部数据种子落库之后调用：先 load 物化 app_settings 行，
    /// 再走真实 service 的 UPDATE（裸 UPDATE 在全新库上会零行命中）。
    func applyAdaptivePreferenceUITestOverrides() async {
        guard adaptivePreferencesService != nil else { return }
        _ = try? await adaptivePreferencesService?.load(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
        )
        let env = ProcessInfo.processInfo.environment
        if let raw = env["OBOE_UI_TEST_TYPED_RECALL_PREF"],
            let enabled = Self.parseToggleFlag(raw) {
            _ = try? await adaptivePreferencesService?
                .setTypedAnswerChineseToJapanese(enabled)
        }
        if let raw = env["OBOE_UI_TEST_LISTENING_TYPED_PREF"],
            let enabled = Self.parseToggleFlag(raw) {
            _ = try? await adaptivePreferencesService?
                .setTypedAnswerListening(enabled)
        }
    }

    /// 识别 UI 测试开关值：`1/true/yes/on` → true，`0/false/no/off` → false；
    /// 其余写法不生效（保持种子默认），避免拼错的值静默翻转行为。
    private static func parseToggleFlag(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// `OBOE_UI_TEST_STAGE_SCHEMA_V12`（T16）：在 `databaseLifecycle.open()`
    /// 之前把 UI 测试库写成 v0.4 形态（迁移仅应用到 v12——无
    /// `note_decks`/`pitch_accent`），随后真实打开路径执行 v13 迁移并
    /// 生成迁移前快照。种子里含一个 `builtin_jlpt` 词（真实 source_ref、
    /// 音调与例句中文译文均缺），启动后的 enrichment 会回填它们，
    /// 供 UI 断言"升级 + 回填 + 回滚"全链路。
    func stageLegacySchemaV12DatabaseIfRequested() throws {
        guard ProcessInfo.processInfo.environment["OBOE_UI_TEST_STAGE_SCHEMA_V12"] != nil,
              let identifier = ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"],
              let uuid = UUID(uuidString: identifier)
        else { return }
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-UITests", isDirectory: true)
            .appendingPathComponent(uuid.uuidString, isDirectory: true)
        let databaseURL = baseURL.appendingPathComponent("oboe.sqlite")
        guard !FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search",
                argumentCount: 1,
                pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0]) else {
                    return nil
                }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
        defer { try? pool.close() }

        let throughV12 = Array(OboeDatabaseSchema.migrationIdentifiers.prefix(
            while: { $0 != "v13_note_deck_membership_and_pitch" }
        ))
        try OboeDatabaseSchema.makeMigrator(applying: throughV12).migrate(pool)
        try pool.write { db in try Self.seedLegacyV12Fixture(in: db) }
    }

    /// v0.4 脱敏副本的合成等价物：1 个牌组；1 条手动词汇（三方向卡 +
    /// 例句 + 一条评分历史）；1 条 `builtin_jlpt` 词（`source_ref` 指向
    /// 内置词库真实条目「あさって」，音调列在 v12 尚不存在、例句中文
    /// 译文为 NULL，供升级后 enrichment 回填）。
    private static func seedLegacyV12Fixture(in db: Database) throws {
        let encode: (UUID) -> String = DatabaseValueCodec.encode
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let deckID = UUID()
        let vocabNoteID = UUID()
        let jlptNoteID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let reviewCardID = UUID()

        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                VALUES (?, '升级牌组', 0, ?, ?)
                """,
            arguments: [encode(deckID), nowMs, nowMs]
        )
        try db.execute(
            sql: """
                INSERT INTO app_settings(id, schema_version, learning_time_zone_id)
                VALUES (1, 12, 'Asia/Shanghai')
                """
        )
        let profile = SchedulerProfile.standard
        try db.execute(
            sql: """
                INSERT INTO scheduler_profiles(
                    id, configuration_version, algorithm_version, library_revision,
                    parameters_json, desired_retention, max_interval_days, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                encode(profileID),
                profile.configurationVersion,
                SwiftFSRSReviewScheduler.algorithmVersion,
                SwiftFSRSReviewScheduler.dependencyRevision,
                String(
                    decoding: try JSONEncoder().encode(profile.parameters),
                    as: UTF8.self
                ),
                profile.targetRetention,
                profile.maximumIntervalDays,
                nowMs
            ]
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    part_of_speech, origin, content_version,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                          '一段动词', 'manual', 1, ?, ?)
                """,
            arguments: [encode(vocabNoteID), encode(deckID), nowMs, nowMs]
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    part_of_speech, jlpt, origin, source_ref, content_version,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', 'あさって', 'あさって', '后天',
                          '名词', 'N5', 'builtin_jlpt',
                          'openjlpt:N5:478754d45e8bd789cd61bcd29de281a97d4f1021655bccffb3392ee51c177f22',
                          1, ?, ?)
                """,
            arguments: [encode(jlptNoteID), encode(deckID), nowMs, nowMs]
        )
        try db.execute(
            sql: """
                INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                VALUES (?, ?, 'りんごを食べる。', '吃苹果。', 0)
                """,
            arguments: [encode(UUID()), encode(vocabNoteID)]
        )
        // 例句日文与内置词库一致、译文留 NULL——enrichment 的匹配键是
        // (note_id, japanese, sort_order)。
        try db.execute(
            sql: """
                INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                VALUES (?, ?, 'あさって来てください。', NULL, 0)
                """,
            arguments: [encode(UUID()), encode(jlptNoteID)]
        )
        for noteID in [vocabNoteID, jlptNoteID] {
            for template in [
                "vocabulary_ja_zh", "vocabulary_zh_ja", "vocabulary_listening"
            ] {
                let cardID = noteID == vocabNoteID && template == "vocabulary_ja_zh"
                    ? reviewCardID : UUID()
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                        """,
                    arguments: [
                        encode(cardID), encode(noteID), template, nowMs,
                        SwiftFSRSReviewScheduler.algorithmVersion, encode(profileID)
                    ]
                )
            }
        }
        try db.execute(
            sql: """
                INSERT INTO study_days(
                    id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                ) VALUES (?, '2026-09-01', 'Asia/Shanghai', 1, 2, 10)
                """,
            arguments: [encode(studyDayID)]
        )
        try db.execute(
            sql: """
                INSERT INTO review_logs(
                    id, event_id, card_id, card_key, note_id, deck_id_at_review,
                    reviewed_at_ms, study_day_id, was_first_study, rating,
                    previous_state_json, next_state_json, duration_ms,
                    content_version, profile_id, algorithm_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 2, '{}', '{}', 1000, 1, ?, 'FSRS-6.0')
                """,
            arguments: [
                encode(UUID()), encode(UUID()), encode(reviewCardID),
                encode(reviewCardID), encode(vocabNoteID), encode(deckID),
                nowMs, encode(studyDayID), encode(profileID)
            ]
        )
    }
}

/// v0.5.5：主牌组 scope 与牌组摘要都以 `note_decks` 为权威成员关系——
/// seed 直插 notes 时必须同步写入 home-deck membership（生产写入路径如此；
/// v12 夹具除外，迁移负责回填）。写在 `pool.write` 闭包内调用，故为自由
/// 函数而非 controller 方法（闭包 @Sendable，不能捕获 self）。
private func insertHomeDeckMembership(
    noteID: UUID,
    deckID: UUID,
    atMs: Int64,
    in db: Database
) throws {
    try db.execute(
        sql: "INSERT INTO note_decks(note_id, deck_id, added_at_ms) VALUES (?, ?, ?)",
        arguments: [
            DatabaseValueCodec.encode(noteID),
            DatabaseValueCodec.encode(deckID),
            atMs
        ]
    )
}
#endif
