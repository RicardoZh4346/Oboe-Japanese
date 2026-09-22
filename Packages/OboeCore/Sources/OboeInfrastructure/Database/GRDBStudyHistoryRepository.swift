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

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
}
