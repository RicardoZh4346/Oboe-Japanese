import Foundation
import GRDB
import FSRS
import OboeDomain

/// 统计查询输入错误（只读层不写库，参数无效即抛）。
public enum StatisticsQueryError: Error, Equatable, Sendable {
    /// `studyDayID` 既不等于任何 `study_days.id` 也不是已落库的
    /// `local_date`（"YYYY-MM-DD"）。
    case studyDayNotFound(String)
}

/// v0.7.0 S20：`StatisticsRepository`（S02 冻结契约）的 GRDB 实现。
///
/// 口径总则（§11.1）：
/// - 「正式评分」= `review_logs` 且 `undone_at_ms IS NULL`；
///   `practice_attempts`/`custom_study_sessions` 物理上是独立表，
///   天然不计入（practice-only 隔离为结构保证，不靠口头约定）。
/// - 共享牌组：聚合按 `study_day`/`card_key`/`note_id` 进行，
///   **不 JOIN `note_decks`**，成员关系不会放大计数。
/// - `review_logs.note_id`/`card_key` 无 FK——Note/Card 删除后历史
///   原样保留（`card_id` 被 SET NULL 不影响 `card_key`）。
/// - `studyDayID` 参数兼容两种写法：`study_days.id`（UUID 文本，大小写
///   不敏感）或 `local_date`（"YYYY-MM-DD"——与每日统计「同 local_date
///   跨时区行并入同桶」的语义一致）。
///
/// 已知口径裁决（见 docs/v0.7/s20-statistics-query.md「Contract deltas」）：
/// - `NewLearnedStats` 三分桶依赖 `notes.kind`；Note 已删时 kind 不可
///   恢复，orphan 首学计入 `vocabulary` 桶以保住「仍计入 total」。
/// - `RetentionStats.targetRetention` 单值化：按启用非 new 卡数加权的
///   profile `desired_retention` 均值；无卡回退 app_settings 配置 preset。
public struct GRDBStatisticsRepository: StatisticsRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    // MARK: - 今日/当日（§11.1「今日复习」「新学」「平均作答时长」）

    /// `review_logs.study_day_id` 的解析片段：入参同时匹配
    /// `study_days.id` 与 `study_days.local_date`。
    private static let studyDayScopeSQL = """
        rl.study_day_id IN (
            SELECT id FROM study_days WHERE id = ? OR local_date = ?
        )
        """

    static let todayReviewStatsSQL = """
        SELECT COUNT(*) AS effective_rating_count,
               COUNT(DISTINCT CASE WHEN rl.was_first_study = 0
                   THEN rl.card_key END) AS distinct_card_count
        FROM review_logs rl
        WHERE rl.undone_at_ms IS NULL
          AND \(studyDayScopeSQL)
        """

    public func todayReviewStats(studyDayID: String) async throws -> TodayReviewStats {
        try await pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: Self.todayReviewStatsSQL,
                arguments: [studyDayID.lowercased(), studyDayID]
            )
            return TodayReviewStats(
                effectiveRatingCount: row?["effective_rating_count"] ?? 0,
                distinctCardCount: row?["distinct_card_count"] ?? 0
            )
        }
    }

    static let newLearnedStatsSQL = """
        SELECT COALESCE(n.kind, 'vocabulary') AS note_kind,
               COUNT(DISTINCT rl.note_id) AS learned_count
        FROM review_logs rl
        LEFT JOIN notes n ON n.id = rl.note_id
        WHERE rl.undone_at_ms IS NULL
          AND rl.was_first_study = 1
          AND \(studyDayScopeSQL)
        GROUP BY note_kind
        """

    public func newLearnedStats(studyDayID: String) async throws -> NewLearnedStats {
        try await pool.read { db in
            var vocabulary = 0
            var grammar = 0
            var sentence = 0
            let rows = try Row.fetchAll(
                db,
                sql: Self.newLearnedStatsSQL,
                arguments: [studyDayID.lowercased(), studyDayID]
            )
            for row in rows {
                let kind: String = row["note_kind"]
                let count: Int = row["learned_count"]
                switch kind {
                case "grammar": grammar = count
                case "sentence": sentence = count
                default: vocabulary = count // 'vocabulary' 与 orphan 兜底桶
                }
            }
            return NewLearnedStats(
                vocabulary: vocabulary,
                grammar: grammar,
                sentence: sentence
            )
        }
    }

    /// 「有有效时长」= `duration_ms > 0`：计时器未起跳的 0ms 评分不进
    /// 分母也不进分子（0 不改变 Σ，过滤只为语义显式）。
    static let averageDurationSQL = """
        SELECT COALESCE(SUM(rl.duration_ms), 0) AS total_ms,
               COUNT(*) AS rated_with_duration_count
        FROM review_logs rl
        WHERE rl.undone_at_ms IS NULL
          AND rl.duration_ms > 0
          AND \(studyDayScopeSQL)
        """

    public func averageDuration(studyDayID: String) async throws -> DurationStats {
        try await pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: Self.averageDurationSQL,
                arguments: [studyDayID.lowercased(), studyDayID]
            )
            return DurationStats(
                totalMilliseconds: row?["total_ms"] ?? 0,
                ratedWithDurationCount: row?["rated_with_duration_count"] ?? 0
            )
        }
    }

    // MARK: - 评分成功率（§11.1「自评」）

    /// 端点先各自解析成 `local_date`（同一 local_date 可能有多时区行，
    /// 取谁不影响区间语义），再按 local_date 闭区间取全部 study_days。
    static let successRateSQL = """
        SELECT COUNT(*) AS rated_count,
               COALESCE(SUM(CASE WHEN rl.rating >= 2 THEN 1 ELSE 0 END), 0)
                   AS pass_count
        FROM review_logs rl
        WHERE rl.undone_at_ms IS NULL
          AND rl.study_day_id IN (
              SELECT id FROM study_days
              WHERE local_date BETWEEN ? AND ?
          )
        """

    public func successRate(
        fromStudyDayID: String,
        toStudyDayID: String
    ) async throws -> SuccessRateStats {
        try await pool.read { db in
            let lower = try Self.resolveLocalDate(of: fromStudyDayID, in: db)
            let upper = try Self.resolveLocalDate(of: toStudyDayID, in: db)
            let lo = min(lower, upper)
            let hi = max(lower, upper)
            let row = try Row.fetchOne(
                db,
                sql: Self.successRateSQL,
                arguments: [lo, hi]
            )
            return SuccessRateStats(
                ratedCount: row?["rated_count"] ?? 0,
                passCount: row?["pass_count"] ?? 0
            )
        }
    }

    // MARK: - 保持率（§11.1 三口径，D09）

    /// 实测窗口：含 `asOf` 所在学习日在内、最近的 ≤30 个已落库学习日。
    /// `study_days` 只在打开过 App 的日子有行——窗口按「行」取而不是
    /// 补日历，与 history 聚合口径一致。
    static let retentionWindowSQL = """
        SELECT id FROM study_days
        WHERE starts_at_ms <= ?
        ORDER BY starts_at_ms DESC
        LIMIT 30
        """

    /// SQL 谓词与 `StatisticsMetricMath.isRetentionSample` 逐条对应：
    /// 非首学 + 评分前 state=review(2) + reviewed_at − prev.lastReviewAt
    /// ≥ 86400_000ms（`lastReviewAt` 为 NULL 时谓词自动为假）。
    static let actualRetentionSQL = """
        SELECT COUNT(*) AS sample_count,
               COALESCE(SUM(CASE WHEN rl.rating != 1 THEN 1 ELSE 0 END), 0)
                   AS pass_count
        FROM review_logs rl
        WHERE rl.undone_at_ms IS NULL
          AND rl.was_first_study = 0
          AND rl.study_day_id IN (\(retentionWindowSQL))
          AND json_extract(rl.previous_state_json, '$.scheduling.state') = 2
          AND rl.reviewed_at_ms
              - json_extract(rl.previous_state_json, '$.scheduling.lastReviewAt')
              >= \(StatisticsMetricMath.minimumRetentionGapMilliseconds)
        """

    /// 目标保持率：启用且非 new 卡按 profile 分组后的卡数加权均值。
    static let targetRetentionSQL = """
        SELECT SUM(b.card_count * p.desired_retention) / SUM(b.card_count)
               AS weighted_retention
        FROM (
            SELECT profile_id, COUNT(*) AS card_count
            FROM cards
            WHERE is_enabled = 1 AND state != 0
            GROUP BY profile_id
        ) b
        JOIN scheduler_profiles p ON p.id = b.profile_id
        """

    /// 预测可回忆率的候选行：启用、非 new、有评分历史且 stability>0。
    static let predictionCandidatesSQL = """
        SELECT c.profile_id, c.stability, c.last_review_at_ms,
               p.parameters_json, p.desired_retention, p.max_interval_days
        FROM cards c
        JOIN scheduler_profiles p ON p.id = c.profile_id
        WHERE c.is_enabled = 1
          AND c.state IN (1, 2, 3)
          AND c.last_review_at_ms IS NOT NULL
          AND c.stability > 0
        """

    public func retentionStats(asOf date: Date) async throws -> RetentionStats {
        try await pool.read { db in
            let asOfMs = try DatabaseValueCodec.encode(date)

            // target：卡数加权 → 无卡回退 app_settings 配置 preset →
            // 再回退 standard（与 ensureConfiguredProfile 同一缺省语义）。
            var target = try Double.fetchOne(
                db,
                sql: Self.targetRetentionSQL
            )
            if target == nil {
                let presetRaw = try Int.fetchOne(
                    db,
                    sql: "SELECT retention_preset FROM app_settings WHERE id = 1"
                )
                target = presetRaw
                    .flatMap(RetentionPreset.init(rawValue:))?
                    .targetRetention
            }

            let row = try Row.fetchOne(
                db,
                sql: Self.actualRetentionSQL,
                arguments: [asOfMs]
            )
            let sampleCount: Int = row?["sample_count"] ?? 0
            let passCount: Int = row?["pass_count"] ?? 0
            let actual = sampleCount > 0
                ? Double(passCount) / Double(sampleCount)
                : nil

            let predicted = try Self.predictedRecall(asOfMs: asOfMs, in: db)
            return RetentionStats(
                targetRetention: target ?? RetentionPreset.standard.targetRetention,
                actualSampleCount: sampleCount,
                actualRetention: actual,
                predictedRecall: predicted
            )
        }
    }

    /// 按 profile 缓存 FSRS-6 引擎，逐卡 `getRetrievability`（锁定
    /// revision 的公共预测接口），取均值。w 长度不是 21 的 profile
    /// 不会被判成 v6——对应卡跳过（见报告「已知限制」）。
    private static func predictedRecall(
        asOfMs: Int64,
        in db: Database
    ) throws -> Double? {
        let asOf = DatabaseValueCodec.decodeDate(milliseconds: asOfMs)
        let rows = try Row.fetchAll(db, sql: predictionCandidatesSQL)
        var engines: [String: FSRS] = [:]
        var sum = 0.0
        var count = 0
        for row in rows {
            let profileID: String = row["profile_id"]
            let parametersJSON: String = row["parameters_json"]
            let desiredRetention: Double = row["desired_retention"]
            let maxInterval: Double = row["max_interval_days"]
            let engine: FSRS
            if let cached = engines[profileID] {
                engine = cached
            } else {
                let parameters = (try? JSONDecoder().decode(
                    [Double].self,
                    from: Data(parametersJSON.utf8)
                )) ?? []
                guard parameters.count == 21 else { continue }
                let built = FSRS(
                    parameters: FSRSParameters(
                        requestRetention: desiredRetention,
                        maximumInterval: maxInterval,
                        w: parameters,
                        enableFuzz: false,
                        enableShortTerm: true,
                        learningSteps: nil,
                        relearningSteps: nil
                    )
                )
                // 「锁定 FSRS-6」：w 长度判定的版本不是 v6 就不预测。
                guard built.version == .v6 else { continue }
                engine = built
                engines[profileID] = built
            }
            let lastReviewMs: Int64 = row["last_review_at_ms"]
            let stability: Double = row["stability"]
            let card = Card(
                due: Date(),
                stability: stability,
                state: .review,
                lastReview: DatabaseValueCodec.decodeDate(milliseconds: lastReviewMs)
            )
            sum += engine.getRetrievability(card: card, now: asOf).number
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }

    // MARK: - 成熟度（§11.1「Mature / Learning」）

    /// 分桶优先级：暂停（is_enabled=0）> new(state=0) >
    /// learning(1/3) > review(2，再按 scheduledDays≥21 分 mature/young)。
    /// 全表聚合——每个口径都要覆盖全部卡，无 WHERE 可走索引。
    static let cardMaturitySQL = """
        SELECT
            COALESCE(SUM(CASE WHEN is_enabled = 0 THEN 1 ELSE 0 END), 0)
                AS suspended,
            COALESCE(SUM(CASE WHEN is_enabled = 1 AND state = 0
                THEN 1 ELSE 0 END), 0) AS new_cards,
            COALESCE(SUM(CASE WHEN is_enabled = 1 AND state IN (1, 3)
                THEN 1 ELSE 0 END), 0) AS learning,
            COALESCE(SUM(CASE WHEN is_enabled = 1 AND state = 2
                AND scheduled_days >= \(CardMaturityStats.matureScheduledDaysThreshold)
                THEN 1 ELSE 0 END), 0) AS mature,
            COALESCE(SUM(CASE WHEN is_enabled = 1 AND state = 2
                AND scheduled_days < \(CardMaturityStats.matureScheduledDaysThreshold)
                THEN 1 ELSE 0 END), 0) AS young_review
        FROM cards
        """

    public func cardMaturity() async throws -> CardMaturityStats {
        try await pool.read { db in
            let row = try Row.fetchOne(db, sql: Self.cardMaturitySQL)
            return CardMaturityStats(
                mature: row?["mature"] ?? 0,
                youngReview: row?["young_review"] ?? 0,
                learning: row?["learning"] ?? 0,
                suspended: row?["suspended"] ?? 0,
                newCards: row?["new_cards"] ?? 0
            )
        }
    }

    // MARK: - Forecast（§11.1「按当前到期时间估计」）

    /// 启用、非 new 卡的到期毫秒数。`state IN (1,2,3)` 让
    /// `cards_on_enabled_state_due` 作为 COVERING INDEX 命中。
    static let forecastCandidatesSQL = """
        SELECT due_at_ms
        FROM cards
        WHERE is_enabled = 1 AND state IN (1, 2, 3)
        """

    public func forecast(fromStudyDayID: String) async throws -> ForecastStats {
        try await pool.read { db in
            let reference = try Self.resolveStudyDay(
                fromStudyDayID,
                in: db
            )
            let rows = try Row.fetchAll(db, sql: Self.forecastCandidatesSQL)
            var next7 = [Int](repeating: 0, count: 7)
            var next30 = [Int](repeating: 0, count: 30)
            var overdue = 0
            for row in rows {
                let dueAtMs: Int64 = row["due_at_ms"]
                let dueAt = DatabaseValueCodec.decodeDate(milliseconds: dueAtMs)
                let offset = try StudyDayBucketMath.dayOffset(
                    of: dueAt,
                    referenceLocalDate: reference.localDate,
                    timeZoneID: reference.timeZoneID
                )
                if offset < 0 {
                    overdue += 1
                } else {
                    if offset < 7 { next7[offset] += 1 }
                    if offset < 30 { next30[offset] += 1 }
                }
            }
            return ForecastStats(
                next7Days: next7,
                next30Days: next30,
                overdue: overdue
            )
        }
    }

    // MARK: - Weakness（§11.1「30 日 Again 排行」）

    /// 窗口 = 最近 30 个已落库学习日；样本 <3 不进榜；
    /// 排序 = Again 次数 ↓、失败率 ↓、总次数 ↓、note_id ↑（稳定决胜）。
    /// orphan Note 的 headword 兜底为占位串——条目保留、样本照计。
    static let weaknessSQL = """
        SELECT rl.note_id AS note_id,
               COALESCE(n.headword, '（已删除笔记）') AS headword,
               COUNT(*) AS total_reviews,
               COALESCE(SUM(CASE WHEN rl.rating = 1 THEN 1 ELSE 0 END), 0)
                   AS again_count
        FROM review_logs rl
        LEFT JOIN notes n ON n.id = rl.note_id
        WHERE rl.undone_at_ms IS NULL
          AND rl.study_day_id IN (
              SELECT id FROM study_days
              ORDER BY starts_at_ms DESC
              LIMIT 30
          )
        GROUP BY rl.note_id
        HAVING COUNT(*) >= \(WeaknessEntry.minimumSampleCount)
        ORDER BY again_count DESC,
                 CAST(again_count AS REAL) / total_reviews DESC,
                 total_reviews DESC,
                 rl.note_id ASC
        LIMIT ?
        """

    public func weakness(limit: Int) async throws -> [WeaknessEntry] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: Self.weaknessSQL,
                arguments: [max(0, limit)]
            ).map { row in
                try WeaknessEntry(
                    noteID: DatabaseValueCodec.decodeUUID(row["note_id"]),
                    headword: row["headword"],
                    againCount30d: row["again_count"],
                    totalReviews30d: row["total_reviews"]
                )
            }
        }
    }

    // MARK: - study_day 解析

    /// `id`（UUID 文本）或 `local_date` 两种输入都接受；多个时区行共享
    /// 同一 local_date 时取最近一行（localDate 相同，仅边界时刻可能不同）。
    private static func resolveStudyDay(
        _ studyDayID: String,
        in db: Database
    ) throws -> (id: String, localDate: String, timeZoneID: String, startsAt: Date) {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, local_date, time_zone_id, starts_at_ms
                FROM study_days
                WHERE id = ? OR local_date = ?
                ORDER BY starts_at_ms DESC
                LIMIT 1
                """,
            arguments: [studyDayID.lowercased(), studyDayID]
        ) else {
            throw StatisticsQueryError.studyDayNotFound(studyDayID)
        }
        return (
            id: row["id"],
            localDate: row["local_date"],
            timeZoneID: row["time_zone_id"],
            startsAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["starts_at_ms"]
            )
        )
    }

    private static func resolveLocalDate(
        of studyDayID: String,
        in db: Database
    ) throws -> String {
        try resolveStudyDay(studyDayID, in: db).localDate
    }
}
