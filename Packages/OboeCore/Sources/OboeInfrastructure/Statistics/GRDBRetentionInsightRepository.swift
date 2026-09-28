import Foundation
import GRDB
import OboeDomain

/// v0.7.0 S21：保持率分组明细 + 逐日评分序列的只读查询。
///
/// 与 S20 `GRDBStatisticsRepository` 的关系：同一个口径家族，
/// 本类把冻结单值展开成 UI 需要的分组/序列（契约增量，不改
/// `StatisticsRepository` 协议）。
///
/// 口径纪律：
/// - 目标/实测 SQL 片段直接复用 S20 内部静态 SQL（同模块 internal 访问），
///   保证 `insight` 与 `retentionStats` 数字逐位一致。
/// - 预测路径用 Domain `RetentionCurveMath`（锁定 FSRS-6 公式
///   `R=(1+FACTOR·t/S)^DECAY`，`DECAY=-w[20]`，w.count==21 即 v6）；
///   与 S20 引擎路径的逐位一致性由 `RetentionInsightTests` 断言。
/// - new card：`state=0` 的启用卡只计入 `newCardCount`，不进任何
///   预测分母；启用非 new 但无 `last_review_at`/S≤0 的卡计入
///   `cardCount` 但不计入 `predictableCardCount`（profile 切片可见
///   「有 N 张卡无预测」）。
/// - 短间隔（<86400s）实测样本由 `actualRetentionSQL` 谓词结构性排除；
///   practice_attempts 物理独立表，天然隔离。
public struct GRDBRetentionInsightRepository: Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    // MARK: - 保持率明细（三口径 + profile 分组）

    /// 逐卡取启用非 new 卡 + profile 参数；`last_review_at_ms`/`stability`
    /// 原样带出，合格性在 Swift 侧判定（保持 SQL 简单、谓词单一来源）。
    static let profileCandidatesSQL = """
        SELECT c.profile_id, c.stability, c.last_review_at_ms,
               p.configuration_version, p.parameters_json, p.desired_retention
        FROM cards c
        JOIN scheduler_profiles p ON p.id = c.profile_id
        WHERE c.is_enabled = 1 AND c.state != 0
        ORDER BY p.configuration_version, c.profile_id
        """

    static let newCardCountSQL = """
        SELECT COUNT(*) FROM cards WHERE is_enabled = 1 AND state = 0
        """

    /// `asOf` 语义与 `retentionStats(asOf:)` 相同：预测按 `asOf` 时刻算，
    /// 实测窗口取 `starts_at_ms <= asOf` 的最近 30 个学习日。
    public func retentionInsight(asOf date: Date) async throws -> RetentionInsight {
        try await pool.read { db in
            let asOfMs = try DatabaseValueCodec.encode(date)

            var target = try Double.fetchOne(
                db, sql: GRDBStatisticsRepository.targetRetentionSQL
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

            let actualRow = try Row.fetchOne(
                db,
                sql: GRDBStatisticsRepository.actualRetentionSQL,
                arguments: [asOfMs]
            )
            let sampleCount: Int = actualRow?["sample_count"] ?? 0
            let passCount: Int = actualRow?["pass_count"] ?? 0
            let actual = sampleCount > 0
                ? Double(passCount) / Double(sampleCount)
                : nil

            let newCardCount: Int = try Int.fetchOne(
                db, sql: Self.newCardCountSQL
            ) ?? 0

            // per-profile 聚合（profile 保序稳定：configuration_version, id）。
            struct Accumulator {
                var configurationVersion = ""
                var targetRetention = 0.0
                var cardCount = 0
                var predictableCount = 0
                var recallSum = 0.0
            }
            var byProfile: [UUID: Accumulator] = [:]
            var order: [UUID] = []
            var globalSum = 0.0
            var globalCount = 0

            let rows = try Row.fetchAll(db, sql: Self.profileCandidatesSQL)
            for row in rows {
                let profileID = try DatabaseValueCodec.decodeUUID(
                    row["profile_id"]
                )
                if byProfile[profileID] == nil {
                    byProfile[profileID] = Accumulator(
                        configurationVersion: row["configuration_version"],
                        targetRetention: row["desired_retention"]
                    )
                    order.append(profileID)
                }
                byProfile[profileID]!.cardCount += 1

                let parametersJSON: String = row["parameters_json"]
                let parameters = (try? JSONDecoder().decode(
                    [Double].self, from: Data(parametersJSON.utf8)
                )) ?? []
                guard let lastReviewMs: Int64 = row["last_review_at_ms"] else {
                    continue // 无复习史（learning/review 卡亦可如此）
                }
                let stability: Double = row["stability"]
                guard stability > 0 else { continue }

                let lastReview = DatabaseValueCodec.decodeDate(
                    milliseconds: lastReviewMs
                )
                let elapsed = RetentionCurveMath.elapsedWholeDays(
                    from: lastReview, to: date
                )
                guard let r = RetentionCurveMath.predictedRecall(
                    elapsedDays: Double(elapsed),
                    stability: stability,
                    parameters: parameters
                ) else { continue } // 非 v6 参数向量——保守跳过

                byProfile[profileID]!.predictableCount += 1
                byProfile[profileID]!.recallSum += r
                globalSum += r
                globalCount += 1
            }

            let profiles = order.map { id -> ProfileRetentionSlice in
                let acc = byProfile[id]!
                return ProfileRetentionSlice(
                    profileID: id,
                    configurationVersion: acc.configurationVersion,
                    cardCount: acc.cardCount,
                    predictableCardCount: acc.predictableCount,
                    targetRetention: acc.targetRetention,
                    predictedRecall: acc.predictableCount > 0
                        ? acc.recallSum / Double(acc.predictableCount)
                        : nil
                )
            }

            return RetentionInsight(
                targetRetention: target
                    ?? RetentionPreset.standard.targetRetention,
                actualSampleCount: sampleCount,
                actualRetention: actual,
                predictedRecall: globalCount > 0
                    ? globalSum / Double(globalCount)
                    : nil,
                profiles: profiles,
                totalEnabledNonNewCardCount: rows.count,
                newCardCount: newCardCount
            )
        }
    }

    // MARK: - 逐学习日评分序列（趋势图 7/30/90 学习日切换）

    /// 窗口 = 含参考日在内的最近 `dayCount` 个**已落库**学习日
    /// （`study_days` 只有开过 App 的日子有行——同 S20 窗口口径）。
    /// 零记录日保留为全 0 行；`studyDayID` 同样接受 id 或 local_date。
    static let dailyMetricsSQL = """
        SELECT sd.id AS study_day_id,
               sd.local_date AS local_date,
               sd.starts_at_ms AS starts_at_ms,
               COUNT(rl.id) AS rated_count,
               COALESCE(SUM(CASE WHEN rl.rating >= 2 THEN 1 ELSE 0 END), 0)
                   AS pass_count,
               COUNT(DISTINCT CASE WHEN rl.was_first_study = 1
                   THEN rl.note_id END) AS new_learned_count,
               AVG(CASE WHEN rl.duration_ms > 0
                   THEN rl.duration_ms END) AS avg_duration_ms
        FROM (
            SELECT id, local_date, starts_at_ms FROM study_days
            WHERE starts_at_ms <= (
                SELECT starts_at_ms FROM study_days
                WHERE id = ? OR local_date = ?
                ORDER BY starts_at_ms DESC LIMIT 1
            )
            ORDER BY starts_at_ms DESC
            LIMIT ?
        ) sd
        LEFT JOIN review_logs rl
            ON rl.study_day_id = sd.id AND rl.undone_at_ms IS NULL
        GROUP BY sd.id
        ORDER BY sd.starts_at_ms ASC, sd.id ASC
        """

    /// `dayCount` 上限钉死在契约范围内（7/30/90 之外无 UI 诉求；
    /// 传更大值也只是返回更多行，不截断语义）。
    public func dailyMetrics(
        endingAtStudyDayID: String,
        dayCount: Int
    ) async throws -> [DailyMetricPoint] {
        try await pool.read { db in
            // 先解析参考行（未知 ID → studyDayNotFound，与 S20 一致）。
            _ = try Self.resolveReferenceDate(
                endingAtStudyDayID, in: db
            )
            return try Row.fetchAll(
                db,
                sql: Self.dailyMetricsSQL,
                arguments: [
                    endingAtStudyDayID.lowercased(), endingAtStudyDayID,
                    max(1, dayCount)
                ]
            ).map { row in
                DailyMetricPoint(
                    studyDayID: row["study_day_id"],
                    localDate: row["local_date"],
                    effectiveRatingCount: row["rated_count"],
                    passCount: row["pass_count"],
                    newLearnedCount: row["new_learned_count"],
                    averageDurationMilliseconds: row["avg_duration_ms"]
                )
            }
        }
    }

    /// 参考学习日必须存在（未知入参不静默归零）。
    private static func resolveReferenceDate(
        _ studyDayID: String,
        in db: Database
    ) throws {
        let exists = try Row.fetchOne(
            db,
            sql: """
                SELECT 1 FROM study_days
                WHERE id = ? OR local_date = ?
                LIMIT 1
                """,
            arguments: [studyDayID.lowercased(), studyDayID]
        ) != nil
        if !exists {
            throw StatisticsQueryError.studyDayNotFound(studyDayID)
        }
    }
}
