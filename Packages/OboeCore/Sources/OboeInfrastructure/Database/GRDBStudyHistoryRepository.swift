import Foundation
import GRDB
import OboeDomain

public struct GRDBStudyHistoryRepository: StudyHistoryRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func fetchTodayStatistics(studyDayID: UUID) async throws -> TodayReviewStatistics {
        try await pool.read { db in
            let studyDayIDValue = DatabaseValueCodec.encode(studyDayID)
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS answer_count,
                           COUNT(DISTINCT CASE WHEN was_first_study = 1 THEN note_id END)
                               AS new_learned_count,
                           COALESCE(SUM(CASE WHEN was_first_study = 0 THEN 1 ELSE 0 END), 0)
                               AS review_answer_count,
                           COALESCE(SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END), 0) AS again_count,
                           COALESCE(SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END), 0) AS hard_count,
                           COALESCE(SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END), 0) AS good_count,
                           COALESCE(SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END), 0) AS easy_count
                    FROM review_logs
                    WHERE study_day_id = ? AND undone_at_ms IS NULL
                    """,
                arguments: [studyDayIDValue]
            )
            // 按成员关系分组：共享 Note 的今日任务在其所属的每个牌组
            // 各计一次（设计 §4.5）；历史归因仍走 deck_id_at_review。
            let deckCounts = try Row.fetchAll(
                db,
                sql: """
                    SELECT nd.deck_id,
                           COUNT(DISTINCT CASE
                               WHEN daily_tasks.category_at_admission = 'new'
                               THEN cards.note_id END) AS new_count,
                           SUM(CASE WHEN daily_tasks.category_at_admission != 'new'
                               THEN 1 ELSE 0 END) AS review_count
                    FROM daily_tasks
                    JOIN cards ON cards.id = daily_tasks.card_id
                    JOIN note_decks nd ON nd.note_id = cards.note_id
                    WHERE daily_tasks.study_day_id = ?
                      AND daily_tasks.cancelled_at_ms IS NULL
                      AND cards.is_enabled = 1
                    GROUP BY nd.deck_id
                    ORDER BY nd.deck_id
                    """,
                arguments: [studyDayIDValue]
            ).map { row in
                try DeckTodayTaskCount(
                    deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
                    newCount: row["new_count"],
                    reviewCount: row["review_count"]
                )
            }
            return TodayReviewStatistics(
                newLearnedCount: row?["new_learned_count"] ?? 0,
                reviewAnswerCount: row?["review_answer_count"] ?? 0,
                answerCount: row?["answer_count"] ?? 0,
                ratings: RatingDistribution(
                    again: row?["again_count"] ?? 0,
                    hard: row?["hard_count"] ?? 0,
                    good: row?["good_count"] ?? 0,
                    easy: row?["easy_count"] ?? 0
                ),
                deckTaskCounts: deckCounts
            )
        }
    }

    public func fetchCompletionStatistics(
        studyDayID: UUID,
        deckID: UUID?
    ) async throws -> StudyCompletionStatistics {
        try await pool.read { db in
            var sql = """
                SELECT card_key,
                       MAX(was_first_study) AS had_first_study,
                       COUNT(*) AS card_answer_count,
                       SUM(CASE WHEN rating = 1 THEN 1 ELSE 0 END) AS again_count,
                       SUM(CASE WHEN rating = 2 THEN 1 ELSE 0 END) AS hard_count,
                       SUM(CASE WHEN rating = 3 THEN 1 ELSE 0 END) AS good_count,
                       SUM(CASE WHEN rating = 4 THEN 1 ELSE 0 END) AS easy_count
                FROM review_logs
                WHERE study_day_id = ? AND undone_at_ms IS NULL
                """
            var values: [any DatabaseValueConvertible] = [
                DatabaseValueCodec.encode(studyDayID)
            ]
            if let deckID {
                sql += "\nAND deck_id_at_review = ?"
                values.append(DatabaseValueCodec.encode(deckID))
            }
            sql += "\nGROUP BY card_key"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(values))
            var newLearnedCardCount = 0
            var reviewedCardCount = 0
            var answerCount = 0
            var ratings = RatingDistribution(again: 0, hard: 0, good: 0, easy: 0)
            for row in rows {
                let hadFirstStudy: Int = row["had_first_study"]
                if hadFirstStudy == 1 {
                    newLearnedCardCount += 1
                } else {
                    reviewedCardCount += 1
                }
                answerCount += row["card_answer_count"]
                ratings = RatingDistribution(
                    again: ratings.again + (row["again_count"] as Int),
                    hard: ratings.hard + (row["hard_count"] as Int),
                    good: ratings.good + (row["good_count"] as Int),
                    easy: ratings.easy + (row["easy_count"] as Int)
                )
            }
            return StudyCompletionStatistics(
                newLearnedCardCount: newLearnedCardCount,
                reviewedCardCount: reviewedCardCount,
                answerCount: answerCount,
                ratings: ratings
            )
        }
    }

    public func fetchCardHistories(noteID: UUID) async throws -> [CardReviewHistory] {
        try await pool.read { db in
            let noteIDValue = DatabaseValueCodec.encode(noteID)
            let cardRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, template_kind
                    FROM cards
                    WHERE note_id = ?
                    ORDER BY template_kind, id
                    """,
                arguments: [noteIDValue]
            )
            let logRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, card_key, rating, reviewed_at_ms, duration_ms,
                           was_first_study, next_state_json, undone_at_ms,
                           content_version, algorithm_version
                    FROM review_logs
                    WHERE note_id = ?
                    ORDER BY reviewed_at_ms DESC, id DESC
                    """,
                arguments: [noteIDValue]
            )
            var entriesByCard: [UUID: [ReviewHistoryEntry]] = [:]
            for row in logRows {
                let cardKey = try DatabaseValueCodec.decodeUUID(row["card_key"])
                let ratingValue: Int = row["rating"]
                guard let rating = ReviewRating(rawValue: ratingValue) else {
                    throw SubmitReviewError.invalidPersistedRating(ratingValue)
                }
                let nextState: ReviewSchedulingSnapshot = try Self.decode(
                    ReviewSchedulingSnapshot.self,
                    from: row["next_state_json"]
                )
                let undoneAtMilliseconds: Int64? = row["undone_at_ms"]
                entriesByCard[cardKey, default: []].append(
                    ReviewHistoryEntry(
                        id: try DatabaseValueCodec.decodeUUID(row["id"]),
                        rating: rating,
                        reviewedAt: DatabaseValueCodec.decodeDate(
                            milliseconds: row["reviewed_at_ms"]
                        ),
                        durationMilliseconds: row["duration_ms"],
                        wasFirstStudy: row["was_first_study"],
                        nextDueAt: nextState.scheduling.dueAt,
                        undoneAt: undoneAtMilliseconds.map(DatabaseValueCodec.decodeDate),
                        contentVersion: row["content_version"],
                        algorithmVersion: row["algorithm_version"]
                    )
                )
            }
            return try cardRows.map { row in
                let cardID = try DatabaseValueCodec.decodeUUID(row["id"])
                let templateValue: String = row["template_kind"]
                guard let template = CardTemplateKind(rawValue: templateValue) else {
                    throw DatabaseValueCodecError.invalidCardTemplate(templateValue)
                }
                return CardReviewHistory(
                    cardID: cardID,
                    templateKind: template,
                    entries: entriesByCard[cardID] ?? []
                )
            }
        }
    }

    /// v0.5.5 每日统计（设计 §5）：同一次读事务内完成窗口聚合与
    /// streak 探测。窗口按 `studyDay` 的学习时区逐日回退生成
    /// `local_date` 序列；聚合按 `local_date` 分组——跨时区切换留下
    /// 的同 local_date 学习日自然并入同一桶，且每条 review_log 只
    /// 属一个 study_day，不会被多牌组或双时区行放大。
    public func fetchDailyStatistics(
        endingAt studyDay: StudyDay,
        dayCount: Int
    ) async throws -> StudyStatisticsSnapshot {
        let localDates = try Self.localDates(endingAt: studyDay, dayCount: dayCount)
        return try await pool.read { db in
            let placeholders = localDates.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT sd.local_date AS local_date,
                           COUNT(rl.id) AS answer_count,
                           COUNT(DISTINCT CASE WHEN rl.was_first_study = 1
                               THEN rl.note_id END) AS new_learned_count,
                           COUNT(DISTINCT CASE WHEN rl.was_first_study = 0
                               THEN rl.card_key END) AS reviewed_card_count,
                           COALESCE(SUM(rl.duration_ms), 0) AS duration_ms,
                           COALESCE(SUM(CASE WHEN rl.rating = 1 THEN 1 ELSE 0 END), 0)
                               AS again_count,
                           COALESCE(SUM(CASE WHEN rl.rating = 2 THEN 1 ELSE 0 END), 0)
                               AS hard_count,
                           COALESCE(SUM(CASE WHEN rl.rating = 3 THEN 1 ELSE 0 END), 0)
                               AS good_count,
                           COALESCE(SUM(CASE WHEN rl.rating = 4 THEN 1 ELSE 0 END), 0)
                               AS easy_count
                    FROM study_days sd
                    JOIN review_logs rl
                      ON rl.study_day_id = sd.id AND rl.undone_at_ms IS NULL
                    WHERE sd.local_date IN (\(placeholders))
                    GROUP BY sd.local_date
                    """,
                arguments: StatementArguments(localDates)
            )
            var statisticsByDate: [String: DailyStudyStatistics] = [:]
            for row in rows {
                let localDate: String = row["local_date"]
                statisticsByDate[localDate] = DailyStudyStatistics(
                    localDate: localDate,
                    newLearnedCount: row["new_learned_count"],
                    reviewedCardCount: row["reviewed_card_count"],
                    answerCount: row["answer_count"],
                    durationMilliseconds: row["duration_ms"],
                    ratings: RatingDistribution(
                        again: row["again_count"],
                        hard: row["hard_count"],
                        good: row["good_count"],
                        easy: row["easy_count"]
                    )
                )
            }
            let days = localDates.map { date in
                statisticsByDate[date] ?? DailyStudyStatistics(
                    localDate: date,
                    newLearnedCount: 0,
                    reviewedCardCount: 0,
                    answerCount: 0,
                    durationMilliseconds: 0,
                    ratings: RatingDistribution(again: 0, hard: 0, good: 0, easy: 0)
                )
            }
            let streak = try Self.currentStreak(
                endingAt: studyDay,
                windowLocalDates: localDates,
                in: db
            )
            return StudyStatisticsSnapshot(currentStreak: streak, days: days)
        }
    }

    /// 生成以 `studyDay.localDate` 结尾、长度为 `dayCount` 的本地日期
    /// 序列（新日期在前）。使用学习日携带的时区，而非设备当前时区。
    private static func localDates(
        endingAt studyDay: StudyDay,
        dayCount: Int
    ) throws -> [String] {
        guard dayCount > 0 else {
            throw StudyDayPlanningError.invalidStudyDayBoundary
        }
        let calendar = try gregorianCalendar(timeZoneID: studyDay.timeZoneID)
        var cursor = try parseLocalDate(studyDay.localDate, timeZoneID: studyDay.timeZoneID)
        var dates = [studyDay.localDate]
        while dates.count < dayCount {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                throw StudyDayPlanningError.invalidStudyDayBoundary
            }
            cursor = previous
            dates.append(formatLocalDate(cursor, calendar: calendar))
        }
        return dates
    }

    /// 连续学习天数（设计 §4.3）：今天已学→从今天向前连计；今天未学
    /// 但昨天已学→从昨天起连计（宽限当天首次学习前的归零闪烁）；
    /// 今昨都无→0。streak 可能长于窗口，故用独立的「有有效评分的
    /// local_date 集合」向前逐日走查，直至遇到断档。
    private static func currentStreak(
        endingAt studyDay: StudyDay,
        windowLocalDates: [String],
        in db: Database
    ) throws -> Int {
        let studiedDates = Set(
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT sd.local_date
                    FROM study_days sd
                    WHERE sd.local_date <= ?
                      AND EXISTS (
                          SELECT 1 FROM review_logs rl
                          WHERE rl.study_day_id = sd.id AND rl.undone_at_ms IS NULL
                      )
                    """,
                arguments: [studyDay.localDate]
            )
        )
        guard !studiedDates.isEmpty else { return 0 }
        let calendar = try gregorianCalendar(timeZoneID: studyDay.timeZoneID)
        var cursor = try parseLocalDate(
            studyDay.localDate,
            timeZoneID: studyDay.timeZoneID
        )
        if !studiedDates.contains(formatLocalDate(cursor, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  studiedDates.contains(formatLocalDate(yesterday, calendar: calendar))
            else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while studiedDates.contains(formatLocalDate(cursor, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return streak
    }

    private static func gregorianCalendar(timeZoneID: String) throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func parseLocalDate(
        _ localDate: String,
        timeZoneID: String
    ) throws -> Date {
        let calendar = try gregorianCalendar(timeZoneID: timeZoneID)
        let parts = localDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = calendar.date(
                  from: DateComponents(year: year, month: month, day: day)
              ) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return date
    }

    private static func formatLocalDate(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
}
