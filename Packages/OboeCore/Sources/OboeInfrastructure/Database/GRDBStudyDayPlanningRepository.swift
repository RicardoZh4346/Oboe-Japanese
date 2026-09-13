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
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, daily_new_card_limit
                    ) VALUES (1, 1, ?, 10)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [defaultTimeZoneID]
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
            let usedCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT card_key)
                    FROM review_logs
                    WHERE study_day_id = ?
                      AND was_first_study = 1
                      AND undone_at_ms IS NULL
                    """,
                arguments: [studyDayID]
            ) ?? 0
            let reservationCapacity = max(0, studyDay.newCardLimit - usedCount)
            var reservations = try Self.fetchUnstudiedReservations(
                studyDayID: studyDay.id,
                in: db
            )

            if reservations.count > reservationCapacity {
                for reservation in reservations.dropFirst(reservationCapacity) {
                    try db.execute(
                        sql: """
                            UPDATE daily_tasks SET cancelled_at_ms = ?
                            WHERE study_day_id = ? AND card_id = ?
                            """,
                        arguments: [
                            now,
                            studyDayID,
                            DatabaseValueCodec.encode(reservation.cardID)
                        ]
                    )
                }
                reservations = Array(reservations.prefix(reservationCapacity))
            }

            let openSlots = max(0, reservationCapacity - reservations.count)
            if openSlots > 0 {
                let selected = try Self.selectNewCards(
                    count: openSlots,
                    studyDayID: studyDay.id,
                    in: db
                )
                for (offset, candidate) in selected.enumerated() {
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
            }

            return DailyNewCardPlan(
                studyDay: studyDay,
                usedCount: usedCount,
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
            retentionPreset: retentionPreset
        )
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
        return try Row.fetchAll(
            db,
            sql: """
                SELECT daily_tasks.card_id, notes.deck_id, daily_tasks.admitted_at_ms
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
            arguments: [encodedStudyDayID]
        ).map { row in
            try NewCardReservation(
                cardID: DatabaseValueCodec.decodeUUID(row["card_id"]),
                deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
                admittedAt: DatabaseValueCodec.decodeDate(milliseconds: row["admitted_at_ms"])
            )
        }
    }

    private static func selectNewCards(
        count: Int,
        studyDayID: UUID,
        in db: Database
    ) throws -> [NewCardCandidate] {
        let studyDayIDValue = DatabaseValueCodec.encode(studyDayID)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT cards.id AS card_id,
                       notes.deck_id AS deck_id,
                       decks.sort_order AS deck_sort_order,
                       decks.created_at_ms AS deck_created_at_ms,
                       cards.due_at_ms AS card_due_at_ms,
                       daily_tasks.admitted_at_ms AS existing_admitted_at_ms
                FROM cards
                JOIN notes ON notes.id = cards.note_id
                JOIN decks ON decks.id = notes.deck_id
                LEFT JOIN daily_tasks
                  ON daily_tasks.study_day_id = ? AND daily_tasks.card_id = cards.id
                WHERE cards.is_enabled = 1
                  AND cards.state = 0
                  AND cards.first_studied_at_ms IS NULL
                  AND (daily_tasks.card_id IS NULL OR daily_tasks.cancelled_at_ms IS NOT NULL)
                ORDER BY decks.sort_order, decks.created_at_ms, decks.id,
                         CASE WHEN daily_tasks.admitted_at_ms IS NULL THEN 1 ELSE 0 END,
                         daily_tasks.admitted_at_ms, cards.due_at_ms, cards.id
                """,
            arguments: [studyDayIDValue]
        )
        let candidates = try rows.enumerated().map { index, row in
            NewCardCandidate(
                cardID: try DatabaseValueCodec.decodeUUID(row["card_id"]),
                deckID: try DatabaseValueCodec.decodeUUID(row["deck_id"]),
                deckRank: index,
                existingAdmissionMilliseconds: row["existing_admitted_at_ms"]
            )
        }
        let allocationRows = try Row.fetchAll(
            db,
            sql: """
                SELECT notes.deck_id, COUNT(*) AS allocation_count
                FROM daily_tasks
                JOIN cards ON cards.id = daily_tasks.card_id
                JOIN notes ON notes.id = cards.note_id
                WHERE daily_tasks.study_day_id = ?
                  AND daily_tasks.category_at_admission = 'new'
                  AND daily_tasks.cancelled_at_ms IS NULL
                GROUP BY notes.deck_id
                """,
            arguments: [studyDayIDValue]
        )
        var allocationCounts: [UUID: Int] = [:]
        for row in allocationRows {
            allocationCounts[try DatabaseValueCodec.decodeUUID(row["deck_id"])] = row["allocation_count"]
        }

        var queues = Dictionary(grouping: candidates, by: \NewCardCandidate.deckID)
        var selected: [NewCardCandidate] = []
        while selected.count < count {
            let availableDecks = queues.compactMap { deckID, cards -> (UUID, Int, Int)? in
                guard let first = cards.first else { return nil }
                return (deckID, allocationCounts[deckID, default: 0], first.deckRank)
            }
            guard let nextDeck = availableDecks.min(by: { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2 < rhs.2
            })?.0,
            var queue = queues[nextDeck], !queue.isEmpty else {
                break
            }
            selected.append(queue.removeFirst())
            queues[nextDeck] = queue
            allocationCounts[nextDeck, default: 0] += 1
        }
        return selected
    }
}

private struct NewCardCandidate: Sendable {
    let cardID: UUID
    let deckID: UUID
    let deckRank: Int
    let existingAdmissionMilliseconds: Int64?
}
