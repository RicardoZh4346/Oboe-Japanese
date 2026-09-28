import Foundation
import GRDB
import XCTest
import FSRS
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S21：Retention 适配层测试——锁定 FSRS-6（revision 4fbaf20）
/// 遗忘曲线的参考向量 + 引擎逐位对照、new card 无预测、profile 分组、
/// 短间隔排除、practice 隔离、逐日序列。
///
/// 参考向量由独立实现（Python/math）预算后硬编码：w[20]=0.1542 →
/// DECAY=−0.1542，FACTOR=0.98034649；R(t,S)=(1+FACTOR·t/S)^DECAY，
/// 每层结果按引擎 `toFixedNumber(8)`（`%.8f`）截断。合理性锚点：
/// t=S 时 R≈0.9（desired retention 定义即「S 为 R 跌到 0.9 的间隔」）。
final class RetentionInsightTests: XCTestCase {

    // MARK: - 参考向量 + 引擎对照

    /// 硬编码参考向量：锁定公式 + 默认参数下的固定预测值。
    /// 任何一行的回归都意味着公式/参数/精度截断被改动——升级须连带
    /// metric 语义审查，不允许静默漂移。
    func testPredictedRecallReferenceVectors() throws {
        let w = SchedulerProfile.fsrs6DefaultParameters
        let vectors: [(elapsed: Double, stability: Double, expected: Double)] = [
            (0, 4.0, 1.0),
            (1, 4.0, 0.96676346),
            (3, 4.0, 0.9185229),
            (5, 4.0, 0.88395199),
            (10, 4.0, 0.82613588),
            (30, 4.0, 0.72086694),
            (90, 4.0, 0.61638704),
            (1, 10.0, 0.98568241),
            (5, 10.0, 0.94034429),
            (10, 10.0, 0.9),       // t == S → R = 0.9（构造锚点）
            (30, 10.0, 0.8093881),
            (90, 10.0, 0.70306446),
            (5, 30.0, 0.9769337),
            (30, 30.0, 0.9),
        ]
        for (t, s, expected) in vectors {
            XCTAssertEqual(
                RetentionCurveMath.predictedRecall(
                    elapsedDays: t, stability: s, parameters: w
                ),
                expected,
                "t=\(t) S=\(s) 的锁定预测值回归"
            )
        }
        // DECAY/FACTOR 本身的向量。
        XCTAssertEqual(RetentionCurveMath.decay(parameters: w), -0.1542)
        XCTAssertEqual(RetentionCurveMath.factor(decay: -0.1542), 0.98034649)
    }

    /// Domain 纯实现与锁定引擎公共 API `getRetrievability` 在候选输入
    /// 网格上逐位一致（引擎把 elapsed 压成整天 + toFixed(8)）。
    func testPredictedRecallMatchesLockedEngine() throws {
        let w = SchedulerProfile.fsrs6DefaultParameters
        let engine = FSRS(
            parameters: FSRSParameters(
                requestRetention: 0.9,
                maximumInterval: 36_500,
                w: w,
                enableFuzz: false,
                enableShortTerm: true,
                learningSteps: nil,
                relearningSteps: nil
            )
        )
        XCTAssertEqual(engine.version, .v6)
        let now = DailyStatisticsDatabaseFixture.now
        for stability in stride(from: 0.5, through: 60.0, by: 3.7) {
            for elapsedDays in [0, 1, 2, 7, 15, 30, 90, 365] {
                let lastReview = now.addingTimeInterval(
                    -Double(elapsedDays) * 86_400 - 7_200 // −2h：确保整天数
                )
                let card = Card(
                    due: Date(),
                    stability: stability,
                    state: .review,
                    lastReview: lastReview
                )
                let engineValue = engine.getRetrievability(
                    card: card, now: now
                ).number
                let mathValue = RetentionCurveMath.predictedRecall(
                    elapsedDays: Double(
                        RetentionCurveMath.elapsedWholeDays(
                            from: lastReview, to: now
                        )
                    ),
                    stability: stability,
                    parameters: w
                )
                XCTAssertEqual(
                    mathValue, engineValue,
                    "S=\(stability) t=\(elapsedDays) 引擎/纯函数分叉"
                )
            }
        }
    }

    /// 非 v6 参数向量（w.count != 21）不产出预测。
    func testNonV6ParametersProduceNoPrediction() {
        XCTAssertNil(
            RetentionCurveMath.predictedRecall(
                elapsedDays: 5, stability: 10, parameters: [Double](repeating: 0.5, count: 19)
            )
        )
        XCTAssertNil(RetentionCurveMath.decay(parameters: []))
    }

    /// elapsed 取整天数：23h59m 与 24h 差一档；时钟回拨截断到 0。
    func testElapsedWholeDaysFloorsAndClamps() {
        let now = DailyStatisticsDatabaseFixture.now
        XCTAssertEqual(
            RetentionCurveMath.elapsedWholeDays(
                from: now.addingTimeInterval(-86_399), to: now
            ),
            0
        )
        XCTAssertEqual(
            RetentionCurveMath.elapsedWholeDays(
                from: now.addingTimeInterval(-86_400), to: now
            ),
            1
        )
        XCTAssertEqual(
            RetentionCurveMath.elapsedWholeDays(
                from: now.addingTimeInterval(3_600), to: now
            ),
            0
        )
    }

    // MARK: - 分组明细 vs S20 单值

    /// 同一库上 insight 三口径与契约 `retentionStats` 逐位一致——
    /// Domain 纯函数路径与引擎路径不得漂移。
    func testInsightMatchesContractRetentionStats() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make(
            dayCount: 35
        ) { fixture in
            let now = DailyStatisticsDatabaseFixture.now
            // 两张可预测卡（夹具种子卡无 last_review_at_ms，只进
            // cardCount 不进预测）——S=10/−10d → R=0.9，S=20/−30d。
            _ = try await fixture.addCard(
                noteID: fixture.sharedNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-10 * 86_400 - 7_200),
                stability: 10
            )
            _ = try await fixture.addCard(
                noteID: fixture.exclusiveNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-30 * 86_400 - 7_200),
                stability: 20
            )
            // 一组合格实测样本（review→review，间隔 ≥1 日）。
            var previous = SchedulingCard(
                dueAt: now,
                stability: 4, difficulty: 8,
                repetitions: 4, lapses: 0, state: .review,
                lastReviewAt: now.addingTimeInterval(-10 * 86_400)
            )
            for daysAgo in [3, 2, 1] {
                _ = try await fixture.addLogDetailed(
                    daysAgo: daysAgo,
                    cardKey: fixture.sharedCardID,
                    cardID: fixture.sharedCardID,
                    noteID: fixture.sharedNoteID,
                    rating: .good,
                    previousScheduling: previous,
                    nextScheduling: SchedulingCard(
                        dueAt: now,
                        stability: 8, difficulty: 7,
                        repetitions: 5, lapses: 0, state: .review,
                        lastReviewAt: fixture.days[daysAgo].studyDay.startsAt
                            .addingTimeInterval(43_200)
                    )
                )
                previous = SchedulingCard(
                    dueAt: now,
                    stability: 8, difficulty: 7,
                    repetitions: 5, lapses: 0, state: .review,
                    lastReviewAt: fixture.days[daysAgo].studyDay.startsAt
                        .addingTimeInterval(43_200)
                )
            }
        }
        defer { fixture.remove() }

        let contract = GRDBStatisticsRepository(database: fixture.database)
        let insight = GRDBRetentionInsightRepository(database: fixture.database)
        let stats = try await contract.retentionStats(
            asOf: DailyStatisticsDatabaseFixture.now
        )
        let detail = try await insight.retentionInsight(
            asOf: DailyStatisticsDatabaseFixture.now
        )

        XCTAssertEqual(detail.targetRetention, stats.targetRetention)
        XCTAssertEqual(detail.actualSampleCount, stats.actualSampleCount)
        XCTAssertEqual(detail.actualRetention, stats.actualRetention)
        // 引擎路径与 Domain 纯函数路径的全局预测逐位一致（非 nil）。
        XCTAssertNotNil(stats.predictedRecall)
        XCTAssertEqual(
            detail.predictedRecall, stats.predictedRecall,
            "insight 全局预测与契约路径必须逐位一致"
        )
        // 夹具默认 profile：4 张启用非 new 卡，其中 2 张有历史可预测。
        XCTAssertEqual(detail.profiles.count, 1)
        XCTAssertEqual(detail.profiles[0].cardCount, 4)
        XCTAssertEqual(detail.profiles[0].predictableCardCount, 2)
        XCTAssertEqual(detail.profiles[0].targetRetention, 0.9)
        // newCardCount：夹具无 new 卡。
        XCTAssertEqual(detail.newCardCount, 0)
        XCTAssertEqual(detail.totalEnabledNonNewCardCount, 4)
    }

    /// 多 profile：卡数加权 target + 每 profile 独立预测均值；
    /// 全体预测 = 逐卡等权（不是逐 profile 等权）。
    func testProfileGroupingWeightedAndIndependent() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make { fixture in
            let now = DailyStatisticsDatabaseFixture.now
            let heavyProfile = try await fixture.addSchedulerProfile(
                desiredRetention: 0.85
            )
            // 默认组新增 1 张可预测卡（S=10，−10d → R=0.9 参考向量）；
            // 夹具种子卡 2 张无 last_review → 计入 cardCount 不进预测。
            _ = try await fixture.addCard(
                noteID: fixture.exclusiveNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-10 * 86_400 - 7_200),
                stability: 10
            )
            // heavyProfile：2 张卡（S=4，−1d → R=0.96676346）。
            for kind in ["vocabulary_zh_ja", "vocabulary_listening"] {
                _ = try await fixture.addCard(
                    noteID: fixture.sharedNoteID,
                    templateKind: kind,
                    state: 2,
                    dueAt: now,
                    lastReviewAt: now.addingTimeInterval(-86_400 - 7_200),
                    stability: 4,
                    profileID: heavyProfile
                )
            }
        }
        defer { fixture.remove() }

        let insight = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).retentionInsight(asOf: DailyStatisticsDatabaseFixture.now)

        XCTAssertEqual(insight.profiles.count, 2)
        let heavy = try XCTUnwrap(
            insight.profiles.first { $0.targetRetention == 0.85 }
        )
        let standard = try XCTUnwrap(
            insight.profiles.first { $0.targetRetention == 0.9 }
        )
        XCTAssertEqual(heavy.cardCount, 2)
        XCTAssertEqual(heavy.predictableCardCount, 2)
        XCTAssertEqual(
            try XCTUnwrap(heavy.predictedRecall), 0.96676346, accuracy: 1e-8
        )
        // 默认组：3 张卡（2 种子无历史 + 1 自建可预测 S=10/−10d → 0.9）。
        XCTAssertEqual(standard.cardCount, 3)
        XCTAssertEqual(standard.predictableCardCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(standard.predictedRecall), 0.9, accuracy: 1e-8
        )
        // 全体预测 = 逐卡等权（1×0.9 + 2×0.96676346）/3，
        // 不是逐 profile 等权。
        XCTAssertEqual(
            try XCTUnwrap(insight.predictedRecall),
            (0.9 + 2 * 0.96676346) / 3,
            accuracy: 1e-8
        )
        // target：启用非 new 卡数加权（3×0.9 + 2×0.85)/5 = 0.88。
        XCTAssertEqual(insight.targetRetention, 0.88, accuracy: 1e-8)
        // 分组身份可查：profileID/configurationVersion 都在切片里。
        XCTAssertEqual(heavy.profileID, insight.profiles.first {
            $0.targetRetention == 0.85
        }?.profileID)
        XCTAssertTrue(standard.configurationVersion.hasPrefix("fsrs-6.0"))
    }

    /// new card（state=0）与无复习史卡：不进预测分母；数量如实暴露。
    /// 这是验收项「new card 无预测」——0 不能伪装成「必然遗忘」。
    func testNewCardAndNoHistoryCardsExcludedFromPrediction() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make { fixture in
            let now = DailyStatisticsDatabaseFixture.now
            // 1 张可预测卡（S=10，−10d → R=0.9）作为对照锚点。
            _ = try await fixture.addCard(
                noteID: fixture.exclusiveNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-10 * 86_400 - 7_200),
                stability: 10
            )
            // 2 张 new 卡（同名不同 template 避开唯一约束）。
            for kind in ["vocabulary_zh_ja", "vocabulary_listening"] {
                _ = try await fixture.addCard(
                    noteID: fixture.sharedNoteID,
                    templateKind: kind,
                    state: 0,
                    dueAt: now,
                    lastReviewAt: nil,
                    stability: 0
                )
            }
            // 1 张 learning 卡但无 last_review（迁移残留形态）——
            // 计入 cardCount、不进 predictableCardCount。
            _ = try await fixture.addCard(
                noteID: fixture.sharedNoteID,
                templateKind: "grammar_form_explanation",
                state: 1,
                dueAt: now,
                lastReviewAt: nil,
                stability: 0
            )
        }
        defer { fixture.remove() }

        let insight = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).retentionInsight(asOf: DailyStatisticsDatabaseFixture.now)

        XCTAssertEqual(insight.newCardCount, 2)
        let profile = try XCTUnwrap(insight.profiles.first)
        // 2 种子卡（无历史）+ 1 learning（无历史）+ 1 可预测卡 = 4；
        // 可预测仅 1 张——new 卡完全在 cardCount 之外（state=0）。
        XCTAssertEqual(profile.cardCount, 4)
        XCTAssertEqual(profile.predictableCardCount, 1)
        // 唯一贡献者是 S=10/−10d 卡：0.9 参考向量，
        // 不被 new/无历史卡稀释也不为 0。
        XCTAssertEqual(
            try XCTUnwrap(insight.predictedRecall), 0.9, accuracy: 1e-8
        )
        XCTAssertEqual(profile.predictedRecall, insight.predictedRecall)
    }

    /// 短间隔（同日重评/小时级练习）不混入长期实测：
    /// prev.lastReviewAt 距 reviewedAt <24h → 不是 retention 样本。
    func testShortIntervalReviewsExcludedFromActual() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make { fixture in
            let dayStart = fixture.days[0].studyDay.startsAt
            let noon = dayStart.addingTimeInterval(43_200)
            // 长间隔样本（合格）：prev.lastReviewAt = −3d。
            _ = try await fixture.addLogDetailed(
                daysAgo: 0,
                cardKey: fixture.sharedCardID,
                cardID: fixture.sharedCardID,
                noteID: fixture.sharedNoteID,
                rating: .good,
                reviewedAt: noon,
                previousScheduling: SchedulingCard(
                    dueAt: noon, stability: 4, difficulty: 8,
                    repetitions: 4, lapses: 0, state: .review,
                    lastReviewAt: noon.addingTimeInterval(-3 * 86_400)
                )
            )
            // 短间隔样本（不合格）：同日 23h 前的 lastReviewAt。
            _ = try await fixture.addLogDetailed(
                daysAgo: 0,
                cardKey: fixture.sharedCardID,
                cardID: fixture.sharedCardID,
                noteID: fixture.sharedNoteID,
                rating: .again,
                reviewedAt: noon,
                previousScheduling: SchedulingCard(
                    dueAt: noon, stability: 4, difficulty: 8,
                    repetitions: 4, lapses: 0, state: .review,
                    lastReviewAt: noon.addingTimeInterval(-82_800)
                )
            )
            // learning→ 的评分：prev.state=learning，也非长期样本。
            _ = try await fixture.addLogDetailed(
                daysAgo: 0,
                cardKey: fixture.exclusiveCardID,
                cardID: fixture.exclusiveCardID,
                noteID: fixture.exclusiveNoteID,
                rating: .again,
                reviewedAt: noon,
                previousScheduling: SchedulingCard(
                    dueAt: noon, stability: 0.5, difficulty: 8,
                    repetitions: 1, lapses: 0, state: .learning,
                    lastReviewAt: noon.addingTimeInterval(-2 * 86_400)
                )
            )
        }
        defer { fixture.remove() }

        let insight = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).retentionInsight(asOf: DailyStatisticsDatabaseFixture.now)
        XCTAssertEqual(insight.actualSampleCount, 1)
        XCTAssertEqual(insight.actualRetention, 1.0)
    }

    /// practice_only 会话对 insight 与逐日序列零影响（结构隔离）。
    func testPracticeAttemptsIsolated() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make { fixture in
            _ = try await fixture.addPracticeSession(
                attempts: [
                    (fixture.sharedCardID, fixture.sharedNoteID, .again),
                    (fixture.sharedCardID, fixture.sharedNoteID, .again)
                ]
            )
            _ = try await fixture.addLogDetailed(
                daysAgo: 0,
                cardKey: fixture.sharedCardID,
                cardID: fixture.sharedCardID,
                noteID: fixture.sharedNoteID,
                rating: .good,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    stability: 4, difficulty: 8,
                    repetitions: 4, lapses: 0, state: .review,
                    lastReviewAt: DailyStatisticsDatabaseFixture.now
                        .addingTimeInterval(-3 * 86_400)
                )
            )
        }
        defer { fixture.remove() }

        let insight = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).retentionInsight(asOf: DailyStatisticsDatabaseFixture.now)
        XCTAssertEqual(insight.actualSampleCount, 1)
        XCTAssertEqual(insight.actualRetention, 1.0)

        let series = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).dailyMetrics(
            endingAtStudyDayID: fixture.days[0].studyDay.id.uuidString,
            dayCount: 7
        )
        // study_days.id 落库为小写 UUID 文本（DatabaseValueCodec）。
        let todayID = fixture.days[0].studyDay.id.uuidString.lowercased()
        let today = try XCTUnwrap(series.first { $0.studyDayID == todayID })
        // practice 的 2 次 Again 不进入当日评分。
        XCTAssertEqual(today.effectiveRatingCount, 1)
        XCTAssertEqual(today.passCount, 1)
    }

    // MARK: - 逐日序列（趋势图数据载体）

    /// 7 学习日窗口：含参考日在内取最近 7 个已落库日，零记录日保留，
    /// 按学习日起点时间升序；成功率分母 = 当日有效评分。
    func testDailyMetricsSeriesWindowAndZeroDays() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make { fixture in
            // daysAgo=1：2 次评分（1 pass）+1 次首学。
            _ = try await fixture.addLogDetailed(
                daysAgo: 1,
                cardKey: fixture.sharedCardID,
                cardID: fixture.sharedCardID,
                noteID: fixture.sharedNoteID,
                rating: .good,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    stability: 4, difficulty: 8,
                    repetitions: 4, lapses: 0, state: .review,
                    lastReviewAt: DailyStatisticsDatabaseFixture.now
                        .addingTimeInterval(-4 * 86_400)
                )
            )
            _ = try await fixture.addLogDetailed(
                daysAgo: 1,
                cardKey: fixture.exclusiveCardID,
                cardID: fixture.exclusiveCardID,
                noteID: fixture.exclusiveNoteID,
                rating: .again,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    stability: 4, difficulty: 8,
                    repetitions: 4, lapses: 0, state: .review,
                    lastReviewAt: DailyStatisticsDatabaseFixture.now
                        .addingTimeInterval(-4 * 86_400)
                )
            )
            _ = try await fixture.addLogDetailed(
                daysAgo: 1,
                cardKey: fixture.exclusiveCardID,
                cardID: fixture.exclusiveCardID,
                noteID: fixture.exclusiveNoteID,
                rating: .good,
                wasFirstStudy: true,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    stability: 0, difficulty: 0,
                    repetitions: 0, lapses: 0, state: .new,
                    lastReviewAt: nil
                )
            )
            // daysAgo=2/3 留空 → 零记录日必须保留。
        }
        defer { fixture.remove() }

        let series = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).dailyMetrics(
            endingAtStudyDayID: fixture.localDate(daysAgo: 0),
            dayCount: 7
        )
        XCTAssertEqual(series.count, 7)
        // 时间升序：最后一行是今天（库内 id 为小写 UUID 文本）。
        XCTAssertEqual(
            series.last?.studyDayID,
            fixture.days[0].studyDay.id.uuidString.lowercased()
        )
        let yesterday = try XCTUnwrap(series.first {
            $0.studyDayID
                == fixture.days[1].studyDay.id.uuidString.lowercased()
        })
        XCTAssertEqual(yesterday.effectiveRatingCount, 3)
        XCTAssertEqual(yesterday.passCount, 2)
        XCTAssertEqual(yesterday.newLearnedCount, 1)
        XCTAssertEqual(
            try XCTUnwrap(yesterday.successRate), 2.0 / 3.0, accuracy: 1e-9
        )
        let zeroDay = series.first {
            $0.studyDayID
                == fixture.days[2].studyDay.id.uuidString.lowercased()
        }
        XCTAssertEqual(zeroDay?.effectiveRatingCount, 0)
        XCTAssertNil(zeroDay?.successRate)
        XCTAssertNil(zeroDay?.averageDurationMilliseconds)
    }

    /// 90 日窗口不足 N 个落库日就只回实际行数；未知端点抛错。
    func testDailyMetricsWindowCapsAtSeededDaysAndThrowsOnUnknown() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make(
            dayCount: 12
        ) { _ in }
        defer { fixture.remove() }
        let repo = GRDBRetentionInsightRepository(database: fixture.database)

        let series = try await repo.dailyMetrics(
            endingAtStudyDayID: fixture.localDate(daysAgo: 0), dayCount: 90
        )
        XCTAssertEqual(series.count, 12)

        await XCTAssertAsyncThrowsError(
            try await repo.dailyMetrics(
                endingAtStudyDayID: "not-a-study-day", dayCount: 7
            )
        ) { error in
            XCTAssertEqual(
                error as? StatisticsQueryError,
                .studyDayNotFound("not-a-study-day")
            )
        }
    }

    /// 无复习史库：预测为 nil（不是假数字），profile 分组为空。
    /// 也覆盖「种子卡仍在但无 last_review」场景——它们应显示为
    /// 「有卡无预测」而非 0%。
    func testEmptyLibraryHasNoPrediction() async throws {
        let fixture = try await DailyStatisticsDatabaseFixture.make { fixture in
            _ = try await fixture.addCard(
                noteID: fixture.sharedNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 0,
                dueAt: DailyStatisticsDatabaseFixture.now,
                lastReviewAt: nil,
                stability: 0
            )
        }
        defer { fixture.remove() }

        var insight = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).retentionInsight(asOf: DailyStatisticsDatabaseFixture.now)
        // 种子卡 2 张：state=review 但无 last_review → 有分组行、无预测。
        XCTAssertNil(insight.predictedRecall)
        XCTAssertEqual(insight.profiles.count, 1)
        XCTAssertEqual(insight.profiles[0].cardCount, 2)
        XCTAssertEqual(insight.profiles[0].predictableCardCount, 0)
        XCTAssertNil(insight.profiles[0].predictedRecall)
        XCTAssertEqual(insight.newCardCount, 1)
        XCTAssertNil(insight.actualRetention)
        XCTAssertEqual(insight.actualSampleCount, 0)

        // 再把种子卡删掉 → 完全无非 new 卡：分组为空。
        for card in [fixture.sharedCardID, fixture.exclusiveCardID] {
            try await fixture.deleteCard(card)
        }
        insight = try await GRDBRetentionInsightRepository(
            database: fixture.database
        ).retentionInsight(asOf: DailyStatisticsDatabaseFixture.now)
        XCTAssertNil(insight.predictedRecall)
        XCTAssertTrue(insight.profiles.isEmpty)
        XCTAssertEqual(insight.newCardCount, 1)
        // 无卡时 target 回退 app_settings preset → standard 0.9。
        XCTAssertEqual(insight.targetRetention, 0.9)
    }
}

/// async throws 断言助手（XCTest 无内建 async 版）。
private func XCTAssertAsyncThrowsError(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath, line: UInt = #line,
    _ verify: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("预期抛错但成功返回", file: file, line: line)
    } catch {
        verify(error)
    }
}
