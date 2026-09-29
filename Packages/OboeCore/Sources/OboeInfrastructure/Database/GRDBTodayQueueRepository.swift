import Foundation
import GRDB
import OboeDomain

public struct GRDBTodayQueueRepository: TodayQueueRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    /// v0.7.5 S16：同 pool 的 learning-unit flag 门面派生点——
    /// Review 会话经 `StudySessionService` 直达 flag CAS/事件 API，
    /// 无需改动依赖装配文件。
    public var learningUnitFlags: GRDBLearningUnitRepository {
        GRDBLearningUnitRepository(pool: pool)
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
                      AND \(SchedulingEligibilitySQL.eligibleCondition)
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
              AND \(SchedulingEligibilitySQL.eligibleCondition)
              AND (
                  (cards.state = 0 AND cards.first_studied_at_ms IS NULL)
                  OR (cards.state != 0 AND cards.due_at_ms < ?)
              )
            """
        var values: [any DatabaseValueConvertible] = [
            DatabaseValueCodec.encode(studyDay.id), end
        ]
        if let deckID {
            // 牌组过滤走 `note_decks` 成员关系；共享 Note 在每个成员
            // 牌组的队列中可见，但 Card 不重复（EXISTS 不放大行数）。
            sql += """

                AND EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = notes.id AND nd.deck_id = ?
                )
                """
            values.append(DatabaseValueCodec.encode(deckID))
        }
        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
        let membershipMap = try GRDBNoteDeckMemberships.fetchDeckIDMap(
            noteIDs: rows.map { $0["note_id"] as String },
            in: db
        )
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
            let noteIDValue: String = row["note_id"]
            let memberDeckIDValues = membershipMap[noteIDValue]
            return try TodayQueueItem(
                cardID: DatabaseValueCodec.decodeUUID(row["card_id"]),
                noteID: DatabaseValueCodec.decodeUUID(noteIDValue),
                deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
                templateKind: template,
                category: category,
                availability: availability,
                dueAt: DatabaseValueCodec.decodeDate(milliseconds: dueAtMilliseconds),
                admittedAt: DatabaseValueCodec.decodeDate(milliseconds: row["admitted_at_ms"]),
                deckIDs: memberDeckIDValues.map { try Set($0.map(DatabaseValueCodec.decodeUUID)) }
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
            sql += """

                AND EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = notes.id AND nd.deck_id = ?
                )
                """
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

/// 契约 §2.2 / D15 排程资格的 SQL 谓词（S08）。
///
/// 语义以 `SchedulingEligibility` 为唯一判定源：三个词汇方向卡若其
/// Note 经 `learning_unit_note_links` 挂到的单元被标 `too_easy = 1`
/// 则失去排程资格；Cloze/Grammar 模板与未挂任何单元的卡不受 flag
/// 影响。SQL 用相关 `NOT EXISTS` 实现文档里「LEFT JOIN 取 flag，
/// 缺失行按 tooEasy = false」的等价语义——子查询只承载资格判断，
/// 不会像真 JOIN 那样放大行数。`is_enabled` 与 tooEasy 是两个独立
/// 维度，各自在原有过滤里保持原样。
enum SchedulingEligibilitySQL {
    /// 词汇方向模板的 SQL 字面量列表，直接以
    /// `SchedulingEligibility.vocabularyTemplateKinds` 的 rawValue 生成。
    static var vocabularyTemplateList: String {
        SchedulingEligibility.vocabularyTemplateKinds
            .map { "'\($0.rawValue)'" }
            .joined(separator: ", ")
    }

    /// 追加到「以 `cards` 为基表别名」的 WHERE 的条件：通过 = 卡仍有
    /// 排程资格（非 tooEasy 词汇卡 / 非词汇模板 / 未挂单元）。
    static var eligibleCondition: String {
        """
        NOT EXISTS (
            SELECT 1
            FROM learning_unit_note_links sched_lul
            JOIN learning_unit_flags sched_luf
              ON sched_luf.unit_id = sched_lul.unit_id
            WHERE sched_lul.note_id = cards.note_id
              AND sched_luf.too_easy = 1
              AND cards.template_kind IN (\(vocabularyTemplateList))
        )
        """
    }
}
