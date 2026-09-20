import Foundation
import GRDB
import OboeDomain

public struct GRDBTodayQueueRepository: TodayQueueRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func buildQueue(for studyDay: StudyDay, at instant: Date) async throws -> TodayPlan {
        let now = try DatabaseValueCodec.encode(instant)
        let end = try DatabaseValueCodec.encode(studyDay.endsAt)
        return try await pool.write { db in
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

            let dueRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT cards.id, cards.state
                    FROM cards
                    LEFT JOIN daily_tasks
                      ON daily_tasks.study_day_id = ? AND daily_tasks.card_id = cards.id
                    WHERE cards.is_enabled = 1
                      AND cards.first_studied_at_ms IS NOT NULL
                      AND cards.state != 0
                      AND cards.due_at_ms < ?
                      AND (daily_tasks.card_id IS NULL OR daily_tasks.cancelled_at_ms IS NOT NULL)
                    ORDER BY
                      CASE cards.state WHEN 1 THEN 0 WHEN 3 THEN 0 ELSE 1 END,
                      cards.due_at_ms, cards.id
                    """,
                arguments: [studyDayID, end]
            )
            for (offset, row) in dueRows.enumerated() {
                let cardID: String = row["id"]
                let stateValue: Int = row["state"]
                let category = try Self.category(stateValue: stateValue)
                if try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM daily_tasks
                            WHERE study_day_id = ? AND card_id = ?
                        )
                        """,
                    arguments: [studyDayID, cardID]
                ) == true {
                    try db.execute(
                        sql: """
                            UPDATE daily_tasks SET cancelled_at_ms = NULL
                            WHERE study_day_id = ? AND card_id = ?
                            """,
                        arguments: [studyDayID, cardID]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO daily_tasks(
                                study_day_id, card_id, category_at_admission, admitted_at_ms
                            ) VALUES (?, ?, ?, ?)
                            """,
                        arguments: [studyDayID, cardID, category.rawValue, now + Int64(offset)]
                    )
                }
            }

            let items = try Self.fetchRemainingItems(
                studyDay: studyDay,
                deckID: nil,
                nowMilliseconds: now,
                in: db
            )
            // T21 (设计 §9): the queue keeps its raw eligibility order —
            // admission/priority for `now`, pure due time for `later`.
            // Sibling separation moved to display-time selection
            // (`SiblingSelectionPolicy` in the session), so a static swap
            // here would double-apply and cannot see the last presented
            // note anyway.
            let availableNow = items
                .filter { $0.availability == .now }
                .sorted(by: Self.nowOrdering)
            let availableLater = items
                .filter { $0.availability == .later }
                .sorted(by: Self.laterOrdering)
            return TodayPlan(
                studyDay: studyDay,
                availableNow: availableNow,
                availableLater: availableLater,
                summary: try Self.fetchSummary(
                    studyDay: studyDay,
                    deckID: nil,
                    items: items,
                    in: db
                )
            )
        }
    }

    public func fetchSummary(
        for studyDay: StudyDay,
        deckID: UUID?,
        at instant: Date
    ) async throws -> TodayStudySummary {
        let now = try DatabaseValueCodec.encode(instant)
        return try await pool.read { db in
            let items = try Self.fetchRemainingItems(
                studyDay: studyDay,
                deckID: deckID,
                nowMilliseconds: now,
                in: db
            )
            return try Self.fetchSummary(
                studyDay: studyDay,
                deckID: deckID,
                items: items,
                in: db
            )
        }
    }

    private static func fetchRemainingItems(
        studyDay: StudyDay,
        deckID: UUID?,
        nowMilliseconds: Int64,
        in db: Database
    ) throws -> [TodayQueueItem] {
        let end = try DatabaseValueCodec.encode(studyDay.endsAt)
        var sql = """
            SELECT cards.id AS card_id, cards.note_id, notes.deck_id,
                   cards.template_kind, cards.state, cards.due_at_ms,
                   cards.first_studied_at_ms, daily_tasks.admitted_at_ms
            FROM daily_tasks
            JOIN cards ON cards.id = daily_tasks.card_id
            JOIN notes ON notes.id = cards.note_id
            WHERE daily_tasks.study_day_id = ?
              AND daily_tasks.cancelled_at_ms IS NULL
              AND cards.is_enabled = 1
              AND (
                  (cards.state = 0 AND cards.first_studied_at_ms IS NULL)
                  OR (cards.state != 0 AND cards.due_at_ms < ?)
              )
            """
        var values: [any DatabaseValueConvertible] = [
            DatabaseValueCodec.encode(studyDay.id), end
        ]
        if let deckID {
            sql += "\nAND notes.deck_id = ?"
            values.append(DatabaseValueCodec.encode(deckID))
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
        return try rows.map { row in
            let stateValue: Int = row["state"]
            let firstStudiedAt: Int64? = row["first_studied_at_ms"]
            let category: TodayQueueCategory = if stateValue == SchedulingState.new.rawValue,
                                                  firstStudiedAt == nil {
                .new
            } else {
                try Self.category(stateValue: stateValue)
            }
            let dueAtMilliseconds: Int64 = row["due_at_ms"]
            let availability: TodayQueueAvailability = category == .new
                || dueAtMilliseconds <= nowMilliseconds ? .now : .later
            let templateValue: String = row["template_kind"]
            guard let template = CardTemplateKind(rawValue: templateValue) else {
                throw DatabaseValueCodecError.invalidCardTemplate(templateValue)
            }
            return try TodayQueueItem(
                cardID: DatabaseValueCodec.decodeUUID(row["card_id"]),
                noteID: DatabaseValueCodec.decodeUUID(row["note_id"]),
                deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
                templateKind: template,
                category: category,
                availability: availability,
                dueAt: DatabaseValueCodec.decodeDate(milliseconds: dueAtMilliseconds),
                admittedAt: DatabaseValueCodec.decodeDate(milliseconds: row["admitted_at_ms"])
            )
        }
    }

    private static func fetchSummary(
        studyDay: StudyDay,
        deckID: UUID?,
        items: [TodayQueueItem],
        in db: Database
    ) throws -> TodayStudySummary {
        var sql = """
            SELECT COUNT(DISTINCT daily_tasks.card_id)
            FROM daily_tasks
            JOIN cards ON cards.id = daily_tasks.card_id
            JOIN notes ON notes.id = cards.note_id
            WHERE daily_tasks.study_day_id = ?
              AND daily_tasks.cancelled_at_ms IS NULL
              AND cards.is_enabled = 1
              AND cards.due_at_ms >= ?
              AND EXISTS (
                  SELECT 1 FROM review_logs
                  WHERE review_logs.study_day_id = daily_tasks.study_day_id
                    AND review_logs.card_key = daily_tasks.card_id
                    AND review_logs.undone_at_ms IS NULL
              )
            """
        var values: [any DatabaseValueConvertible] = [
            DatabaseValueCodec.encode(studyDay.id),
            try DatabaseValueCodec.encode(studyDay.endsAt)
        ]
        if let deckID {
            sql += "\nAND notes.deck_id = ?"
            values.append(DatabaseValueCodec.encode(deckID))
        }
        let completedCount = try Int.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments(values)
        ) ?? 0
        return TodayStudySummary(
            // 新卡额度按“词”计：同一笔记的多个方向合计为一个新词。
            newCount: Set(items.filter { $0.category == .new }.map(\.noteID)).count,
            reviewCount: items.count { $0.category == .review },
            learningCount: items.count { $0.category == .learning || $0.category == .relearning },
            completedCount: completedCount
        )
    }

    private static func category(stateValue: Int) throws -> TodayQueueCategory {
        guard let state = SchedulingState(rawValue: stateValue) else {
            throw DatabaseValueCodecError.invalidSchedulingState(stateValue)
        }
        return switch state {
        case .new: .new
        case .learning: .learning
        case .review: .review
        case .relearning: .relearning
        }
    }

    private static func nowOrdering(_ lhs: TodayQueueItem, _ rhs: TodayQueueItem) -> Bool {
        if lhs.category.priority != rhs.category.priority {
            return lhs.category.priority < rhs.category.priority
        }
        // 同一词的方向卡固定按 日→中、中→日、听力（从易到难），
        // 先于 admittedAt/dueAt/UUID 比较，保证旧预约也按此顺序出现。
        if lhs.noteID == rhs.noteID,
           lhs.templateKind.directionQueueRank != rhs.templateKind.directionQueueRank {
            return lhs.templateKind.directionQueueRank < rhs.templateKind.directionQueueRank
        }
        if lhs.category == .new, rhs.category == .new {
            return lhs.admittedAt == rhs.admittedAt
                ? lhs.cardID.uuidString < rhs.cardID.uuidString
                : lhs.admittedAt < rhs.admittedAt
        }
        return lhs.dueAt == rhs.dueAt
            ? lhs.cardID.uuidString < rhs.cardID.uuidString
            : lhs.dueAt < rhs.dueAt
    }

    private static func laterOrdering(_ lhs: TodayQueueItem, _ rhs: TodayQueueItem) -> Bool {
        if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
        if lhs.category.priority != rhs.category.priority {
            return lhs.category.priority < rhs.category.priority
        }
        return lhs.cardID.uuidString < rhs.cardID.uuidString
    }

}
