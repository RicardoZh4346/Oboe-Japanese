import Foundation
import GRDB
import OboeDomain

public struct GRDBStudyDayPlanningRepository: StudyDayPlanningRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func loadOrCreateSettings(
        defaultTimeZoneID: String
    ) async throws -> StudyPlanningSettings {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await pool.write { db in
            try AppSettingsRowDefaults.insertIfMissing(
                in: db, learningTimeZoneID: defaultTimeZoneID
            )
            return try Self.fetchSettings(in: db)
        }
    }

    public func updateDailyNewCardLimit(_ limit: Int) async throws -> StudyPlanningSettings {
        guard limit >= 0 else {
            throw StudyDayPlanningError.invalidNewCardLimit(limit)
        }
        return try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET daily_new_card_limit = ? WHERE id = 1",
                arguments: [limit]
            )
            return try Self.fetchSettings(in: db)
        }
    }

    public func updateLearningTimeZoneID(
        _ timeZoneID: String
    ) async throws -> StudyPlanningSettings {
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        return try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET learning_time_zone_id = ? WHERE id = 1",
                arguments: [timeZoneID]
            )
            return try Self.fetchSettings(in: db)
        }
    }

    public func updatePrimaryDeck(_ deckID: UUID?) async throws -> StudyPlanningSettings {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET primary_deck_id = ? WHERE id = 1",
                arguments: [deckID.map(DatabaseValueCodec.encode)]
            )
            return try Self.fetchSettings(in: db)
        }
    }

    public func updateRetentionPreset(
        _ preset: RetentionPreset
    ) async throws -> StudyPlanningSettings {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET retention_preset = ? WHERE id = 1",
                arguments: [preset.rawValue]
            )
            let profileID = try GRDBSchedulerProfileStore.ensureProfile(
                preset: preset,
                createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                in: db
            )
            try db.execute(
                sql: """
                    UPDATE cards
                    SET profile_id = ?, algorithm_version = ?
                    WHERE profile_id != ? OR algorithm_version != ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion
                ]
            )
            return try Self.fetchSettings(in: db)
        }
    }

    public func fetchStudyDay(containing instant: Date) async throws -> StudyDay? {
        let milliseconds = try DatabaseValueCodec.encode(instant)
        return try await pool.read { db in
            try Self.fetchStudyDay(containing: milliseconds, in: db)
        }
    }

    public func fetchLatestStudyDay(
        endingAtOrBefore instant: Date
    ) async throws -> StudyDay? {
        let milliseconds = try DatabaseValueCodec.encode(instant)
        return try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM study_days
                    WHERE ends_at_ms <= ?
                    ORDER BY ends_at_ms DESC
                    LIMIT 1
                    """,
                arguments: [milliseconds]
            ) else {
                return nil
            }
            return try Self.decodeStudyDay(row)
        }
    }

    public func persistAndReconcileNewCards(
        _ proposedStudyDay: StudyDay,
        at instant: Date
    ) async throws -> DailyNewCardPlan {
        guard proposedStudyDay.newCardLimit >= 0 else {
            throw StudyDayPlanningError.invalidNewCardLimit(proposedStudyDay.newCardLimit)
        }
        let now = try DatabaseValueCodec.encode(instant)
        return try await pool.write { db in
            var studyDay: StudyDay
            if let active = try Self.fetchStudyDay(containing: now, in: db) {
                studyDay = active.replacingNewCardLimit(proposedStudyDay.newCardLimit)
            } else {
                guard proposedStudyDay.startsAt <= instant,
                      instant < proposedStudyDay.endsAt else {
                    throw StudyDayPlanningError.invalidStudyDayBoundary
                }
                try Self.insertStudyDay(proposedStudyDay, in: db)
                guard let persisted = try Self.fetchStudyDay(
                    localDate: proposedStudyDay.localDate,
                    timeZoneID: proposedStudyDay.timeZoneID,
                    in: db
                ), persisted.startsAt <= instant, instant < persisted.endsAt else {
                    throw StudyDayPlanningError.invalidPersistedStudyDay
                }
                studyDay = persisted.replacingNewCardLimit(proposedStudyDay.newCardLimit)
            }
            try db.execute(
                sql: "UPDATE study_days SET new_limit = ? WHERE id = ?",
                arguments: [
                    studyDay.newCardLimit,
                    DatabaseValueCodec.encode(studyDay.id)
                ]
            )

            let studyDayID = DatabaseValueCodec.encode(studyDay.id)
            try db.execute(
                sql: """
                    UPDATE daily_tasks SET cancelled_at_ms = ?
                    WHERE study_day_id = ? AND cancelled_at_ms IS NULL
                      AND EXISTS (
                          SELECT 1 FROM cards
                          WHERE cards.id = daily_tasks.card_id AND cards.is_enabled = 0
                      )
                    """,
                arguments: [now, studyDayID]
            )
            // 额度按“词”计（笔记），不按卡：一个词的全部未学方向一起占一个
            // 名额。已开始（今日有 first-study 日志）的词不占名额——其剩余方向
            // 免费保留在队列里，直到学完；跨日未学完的词次日重新占一个名额，
            // 迁移补齐的方向卡也按此节奏自然进入每日额度。
            let usedCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT note_id)
                    FROM review_logs
                    WHERE study_day_id = ?
                      AND was_first_study = 1
                      AND undone_at_ms IS NULL
                    """,
                arguments: [studyDayID]
            ) ?? 0
            let reservationCapacity = max(0, studyDay.newCardLimit - usedCount)
            let primaryDeckID = try Self.fetchPrimaryDeckID(in: db)

            // Rebalance: unstudied 'new' reservations re-enter the candidate
            // pool so every reconcile recomputes the share for the current
            // candidate set — the primary deck claims slots first, the rest is
            // dealt round-robin. A deck added after today's plan (or starved
            // by an earlier allocation) wins back slots from decks holding
            // surplus unstudied reservations; earliest-admitted cards are
            // kept first.
            let candidates = try Self.newCardCandidates(
                studyDayID: studyDay.id,
                primaryDeckID: primaryDeckID,
                in: db
            )
            let selection = Self.selectNotes(
                candidates,
                capacity: reservationCapacity,
                primaryDeckID: primaryDeckID
            )
            let selected = selection.cards
            let selectedIDs = Set(selected.map(\.cardID))
            for (offset, candidate) in selected.enumerated() where !candidate.hasLiveAdmission {
                if candidate.existingAdmissionMilliseconds != nil {
                    try db.execute(
                        sql: """
                            UPDATE daily_tasks SET cancelled_at_ms = NULL
                            WHERE study_day_id = ? AND card_id = ?
                            """,
                        arguments: [
                            studyDayID,
                            DatabaseValueCodec.encode(candidate.cardID)
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO daily_tasks(
                                study_day_id, card_id, category_at_admission, admitted_at_ms
                            ) VALUES (?, ?, 'new', ?)
                            """,
                        arguments: [
                            studyDayID,
                            DatabaseValueCodec.encode(candidate.cardID),
                            now + Int64(offset)
                        ]
                    )
                }
            }
            for candidate in candidates
            where candidate.hasLiveAdmission && !selectedIDs.contains(candidate.cardID) {
                try db.execute(
                    sql: """
                        UPDATE daily_tasks SET cancelled_at_ms = ?
                        WHERE study_day_id = ? AND card_id = ?
                        """,
                    arguments: [
                        now,
                        studyDayID,
                        DatabaseValueCodec.encode(candidate.cardID)
                    ]
                )
            }

            return DailyNewCardPlan(
                studyDay: studyDay,
                usedCount: usedCount,
                reservedNoteCount: selection.reservedNoteCount,
                reservations: try Self.fetchUnstudiedReservations(
                    studyDayID: studyDay.id,
                    in: db
                )
            )
        }
    }

    private static func fetchSettings(in db: Database) throws -> StudyPlanningSettings {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT learning_time_zone_id, daily_new_card_limit, retention_preset
                FROM app_settings WHERE id = 1
                """
        ) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        let timeZoneID: String = row["learning_time_zone_id"]
        let limit: Int = row["daily_new_card_limit"]
        let retentionRawValue: Int = row["retention_preset"]
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        guard limit >= 0 else {
            throw StudyDayPlanningError.invalidNewCardLimit(limit)
        }
        guard let retentionPreset = RetentionPreset(rawValue: retentionRawValue) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return StudyPlanningSettings(
            learningTimeZoneID: timeZoneID,
            dailyNewCardLimit: limit,
            retentionPreset: retentionPreset,
            primaryDeckID: try fetchPrimaryDeckID(in: db)
        )
    }

    /// 有效主牌组：显式设置且引用仍存在时用它；否则自动回落到牌组排序
    /// （sort_order/created_at_ms/id，与牌组列表一致）的第一个。只有完全
    /// 没有牌组时才返回 nil——有牌组时主牌组永远有效（v0.5 自动默认）。
    private static func fetchPrimaryDeckID(in db: Database) throws -> UUID? {
        if let raw: String = try Row.fetchOne(
            db,
            sql: "SELECT primary_deck_id FROM app_settings WHERE id = 1"
        ).map({ $0["primary_deck_id"] as String? }) ?? nil,
           let stored = UUID(uuidString: raw),
           try Int.fetchOne(
               db,
               sql: "SELECT COUNT(*) FROM decks WHERE id = ?",
               arguments: [DatabaseValueCodec.encode(stored)]
           ) == 1 {
            return stored
        }
        return try Row.fetchOne(
            db,
            sql: """
                SELECT id FROM decks
                ORDER BY sort_order, created_at_ms, id
                LIMIT 1
                """
        ).map { try DatabaseValueCodec.decodeUUID($0["id"]) }
    }

    private static func insertStudyDay(_ studyDay: StudyDay, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO study_days(
                    id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(local_date, time_zone_id) DO NOTHING
                """,
            arguments: [
                DatabaseValueCodec.encode(studyDay.id),
                studyDay.localDate,
                studyDay.timeZoneID,
                try DatabaseValueCodec.encode(studyDay.startsAt),
                try DatabaseValueCodec.encode(studyDay.endsAt),
                studyDay.newCardLimit
            ]
        )
    }

    private static func fetchStudyDay(
        containing milliseconds: Int64,
        in db: Database
    ) throws -> StudyDay? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM study_days
                WHERE starts_at_ms <= ? AND ? < ends_at_ms
                ORDER BY starts_at_ms DESC
                LIMIT 1
                """,
            arguments: [milliseconds, milliseconds]
        ) else {
            return nil
        }
        return try decodeStudyDay(row)
    }

    private static func fetchStudyDay(
        localDate: String,
        timeZoneID: String,
        in db: Database
    ) throws -> StudyDay? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM study_days WHERE local_date = ? AND time_zone_id = ?",
            arguments: [localDate, timeZoneID]
        ) else {
            return nil
        }
        return try decodeStudyDay(row)
    }

    private static func decodeStudyDay(_ row: Row) throws -> StudyDay {
        let startsAt = DatabaseValueCodec.decodeDate(milliseconds: row["starts_at_ms"])
        let endsAt = DatabaseValueCodec.decodeDate(milliseconds: row["ends_at_ms"])
        let limit: Int = row["new_limit"]
        guard startsAt < endsAt, limit >= 0 else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return try StudyDay(
            id: DatabaseValueCodec.decodeUUID(row["id"]),
            localDate: row["local_date"],
            timeZoneID: row["time_zone_id"],
            startsAt: startsAt,
            endsAt: endsAt,
            newCardLimit: limit
        )
    }

    private static func fetchUnstudiedReservations(
        studyDayID: UUID,
        in db: Database
    ) throws -> [NewCardReservation] {
        let encodedStudyDayID = DatabaseValueCodec.encode(studyDayID)
        let primaryDeckValue = try fetchPrimaryDeckID(in: db)
            .map(DatabaseValueCodec.encode)
        return try Row.fetchAll(
            db,
            sql: """
                SELECT daily_tasks.card_id,
                       CASE WHEN ? IS NOT NULL AND EXISTS (
                           SELECT 1 FROM note_decks nd
                           WHERE nd.note_id = notes.id AND nd.deck_id = ?
                       ) THEN ? ELSE notes.deck_id END AS allocation_deck_id,
                       daily_tasks.admitted_at_ms
                FROM daily_tasks
                JOIN cards ON cards.id = daily_tasks.card_id
                JOIN notes ON notes.id = cards.note_id
                WHERE daily_tasks.study_day_id = ?
                  AND daily_tasks.category_at_admission = 'new'
                  AND daily_tasks.cancelled_at_ms IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM review_logs
                      WHERE review_logs.study_day_id = daily_tasks.study_day_id
                        AND review_logs.card_key = daily_tasks.card_id
                        AND review_logs.was_first_study = 1
                        AND review_logs.undone_at_ms IS NULL
                  )
                ORDER BY daily_tasks.admitted_at_ms, daily_tasks.card_id
                """,
            arguments: [
                primaryDeckValue, primaryDeckValue, primaryDeckValue,
                encodedStudyDayID
            ]
        ).map { row in
            try NewCardReservation(
                cardID: DatabaseValueCodec.decodeUUID(row["card_id"]),
                deckID: DatabaseValueCodec.decodeUUID(row["allocation_deck_id"]),
                admittedAt: DatabaseValueCodec.decodeDate(milliseconds: row["admitted_at_ms"])
            )
        }
    }

    /// All unstudied new cards eligible for today's quota, including cards
    /// already holding a live 'new' reservation (`hasLiveAdmission`). The
    /// quota unit is the NOTE: `noteID` groups a word's direction cards and
    /// `noteStartedToday` marks notes already counted in `usedCount` — their
    /// remaining direction cards ride along without consuming another slot.
    ///
    /// 每个候选 Note 只有一个 `allocationDeckID`（设计 §4.6）：属于当前
    /// 主牌组时用主牌组，否则用 home 牌组。牌组排序按分配牌组进行，
    /// 使 `deckRank` 能为同一分配牌组内的轮转打破平局；同一牌组内，
    /// 曾入队（无论是否取消）的卡先于从未入队的卡。
    private static func newCardCandidates(
        studyDayID: UUID,
        primaryDeckID: UUID?,
        in db: Database
    ) throws -> [NewCardCandidate] {
        let studyDayIDValue = DatabaseValueCodec.encode(studyDayID)
        let primaryDeckValue = primaryDeckID.map(DatabaseValueCodec.encode)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT candidates.card_id,
                       candidates.note_id,
                       candidates.allocation_deck_id,
                       candidates.card_due_at_ms,
                       candidates.existing_admitted_at_ms,
                       candidates.has_live_admission,
                       candidates.note_started_today
                FROM (
                    SELECT cards.id AS card_id,
                           cards.note_id AS note_id,
                           CASE WHEN ? IS NOT NULL AND EXISTS (
                               SELECT 1 FROM note_decks nd
                               WHERE nd.note_id = notes.id AND nd.deck_id = ?
                           ) THEN ? ELSE notes.deck_id END AS allocation_deck_id,
                           cards.due_at_ms AS card_due_at_ms,
                           daily_tasks.admitted_at_ms AS existing_admitted_at_ms,
                           CASE WHEN daily_tasks.card_id IS NOT NULL
                                 AND daily_tasks.cancelled_at_ms IS NULL
                                THEN 1 ELSE 0 END AS has_live_admission,
                           CASE WHEN EXISTS (
                               SELECT 1 FROM review_logs
                               WHERE review_logs.study_day_id = ?
                                 AND review_logs.note_id = notes.id
                                 AND review_logs.was_first_study = 1
                                 AND review_logs.undone_at_ms IS NULL
                           ) THEN 1 ELSE 0 END AS note_started_today,
                           CASE cards.template_kind
                               WHEN 'vocabulary_ja_zh' THEN 0
                               WHEN 'vocabulary_zh_ja' THEN 1
                               WHEN 'vocabulary_listening' THEN 2
                               ELSE 3 END AS template_rank
                    FROM cards
                    JOIN notes ON notes.id = cards.note_id
                    LEFT JOIN daily_tasks
                      ON daily_tasks.study_day_id = ? AND daily_tasks.card_id = cards.id
                    WHERE cards.is_enabled = 1
                      AND cards.state = 0
                      AND cards.first_studied_at_ms IS NULL
                      AND (daily_tasks.card_id IS NULL
                           OR daily_tasks.cancelled_at_ms IS NOT NULL
                           OR daily_tasks.category_at_admission = 'new')
                ) candidates
                JOIN decks ON decks.id = candidates.allocation_deck_id
                ORDER BY decks.sort_order, decks.created_at_ms, decks.id,
                         CASE WHEN candidates.existing_admitted_at_ms IS NULL
                              THEN 1 ELSE 0 END,
                         candidates.existing_admitted_at_ms,
                         candidates.card_due_at_ms,
                         candidates.template_rank,
                         candidates.card_id
                """,
            arguments: [
                primaryDeckValue, primaryDeckValue, primaryDeckValue,
                studyDayIDValue, studyDayIDValue
            ]
        )
        return try rows.enumerated().map { index, row in
            NewCardCandidate(
                cardID: try DatabaseValueCodec.decodeUUID(row["card_id"]),
                noteID: try DatabaseValueCodec.decodeUUID(row["note_id"]),
                allocationDeckID: try DatabaseValueCodec.decodeUUID(row["allocation_deck_id"]),
                deckRank: index,
                existingAdmissionMilliseconds: row["existing_admitted_at_ms"],
                hasLiveAdmission: (row["has_live_admission"] as Int) == 1,
                noteStartedToday: (row["note_started_today"] as Int) == 1
            )
        }
    }

    /// Deal `capacity` NOTE picks across decks. Notes already studied today
    /// keep all their remaining direction cards for free (they consumed their
    /// slot at first study). When a primary deck is set its unstarted notes
    /// claim slots first (in candidate order); every leftover slot is dealt
    /// round-robin — always taking from the deck holding the fewest picks so
    /// far (earliest `deckRank` wins ties). Selecting a note admits every
    /// eligible direction card it owns. Live reservations inside `candidates`
    /// are counted like any other pick, so repeated calls converge to the
    /// same share of the quota.
    private static func selectNotes(
        _ candidates: [NewCardCandidate],
        capacity: Int,
        primaryDeckID: UUID?
    ) -> (cards: [NewCardCandidate], reservedNoteCount: Int) {
        var freeCards: [NewCardCandidate] = []
        var noteOrder: [UUID] = []
        var cardsByNote: [UUID: [NewCardCandidate]] = [:]
        for candidate in candidates {
            if candidate.noteStartedToday {
                freeCards.append(candidate)
                continue
            }
            if cardsByNote[candidate.noteID] == nil {
                noteOrder.append(candidate.noteID)
            }
            cardsByNote[candidate.noteID, default: []].append(candidate)
        }
        let notes = noteOrder.compactMap { cardsByNote[$0] }
        var selectedNotes: [[NewCardCandidate]] = []
        var remainder: [(deckID: UUID, deckRank: Int, cards: [NewCardCandidate])] =
            notes.map { cards in
                (
                    deckID: cards[0].allocationDeckID,
                    deckRank: cards[0].deckRank,
                    cards: cards
                )
            }
        // 主牌组成员的 Note 以主牌组为 allocationDeckID，自然先分配。
        if let primaryDeckID {
            selectedNotes = remainder
                .filter { $0.deckID == primaryDeckID }
                .prefix(capacity)
                .map(\.cards)
            remainder = remainder.filter { $0.deckID != primaryDeckID }
        }
        var queues = Dictionary(grouping: remainder, by: \.deckID)
        var allocationCounts: [UUID: Int] = [:]
        while selectedNotes.count < capacity {
            let availableDecks = queues.compactMap {
                deckID, entries -> (UUID, Int, Int)? in
                guard let first = entries.first else { return nil }
                return (deckID, allocationCounts[deckID, default: 0], first.deckRank)
            }
            guard let nextDeck = availableDecks.min(by: { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 < rhs.2
            })?.0,
            var queue = queues[nextDeck], !queue.isEmpty else {
                break
            }
            selectedNotes.append(queue.removeFirst().cards)
            queues[nextDeck] = queue
            allocationCounts[nextDeck, default: 0] += 1
        }
        return (freeCards + selectedNotes.flatMap { $0 }, selectedNotes.count)
    }
}

private struct NewCardCandidate: Sendable {
    let cardID: UUID
    let noteID: UUID
    /// 额度归属牌组：Note 是主牌组成员时为主牌组，否则为 home
    /// （设计 §4.6）。多牌组 Note 只进入一个轮转队列。
    let allocationDeckID: UUID
    let deckRank: Int
    let existingAdmissionMilliseconds: Int64?
    let hasLiveAdmission: Bool
    let noteStartedToday: Bool
}
