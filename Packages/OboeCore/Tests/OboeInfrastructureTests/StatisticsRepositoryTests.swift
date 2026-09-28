import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S20：`GRDBStatisticsRepository`（Statistics 2.0 契约）口径测试。
/// 复用 `DailyStatisticsDatabaseFixture`（35 个连续学习日 + 共享牌组
/// Note）；`StatisticsTestSupport.swift` 提供 Note/Card/删除/practice/
/// 批量日志的种子手段。
final class StatisticsRepositoryTests: XCTestCase {
    private var fixture: DailyStatisticsDatabaseFixture?

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    private var f: DailyStatisticsDatabaseFixture { fixture! }

    private func repository() -> GRDBStatisticsRepository {
        GRDBStatisticsRepository(database: f.database)
    }

    /// 今天学习日 id（UUID 文本——契约的 String 入参）。
    private var todayID: String { f.days[0].studyDay.id.uuidString }

    // MARK: - 今日复习 / 新学 / 成功率 / 时长

    /// 有效评分计数 + 非首学 card_key 去重；undo 与首学不计入后者。
    func testTodayReviewStats() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // 同卡两次非首学评分 → effective 2、distinct 1。
            try await f.addLog(daysAgo: 0, rating: .good)
            try await f.addLog(daysAgo: 0, rating: .again)
            // 另一张卡（共享 Note 在 deckB 视角下同卡）一次首学 → distinct 不变。
            try await f.addLog(
                daysAgo: 0,
                cardID: f.exclusiveCardID,
                noteID: f.exclusiveNoteID,
                deckID: f.deckBID,
                rating: .easy,
                wasFirstStudy: true
            )
            // 已撤销评分不计。
            try await f.addLog(
                daysAgo: 0,
                rating: .hard,
                undoneAt: DailyStatisticsDatabaseFixture.now
            )
        }
        let stats = try await repository().todayReviewStats(studyDayID: todayID)
        XCTAssertEqual(stats.effectiveRatingCount, 3)
        XCTAssertEqual(stats.distinctCardCount, 1)
    }

    /// local_date 形式入参与 UUID id 等价（跨时区合并语义一致）。
    func testTodayReviewStatsAcceptsLocalDate() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0, rating: .good)
        }
        let byID = try await repository().todayReviewStats(studyDayID: todayID)
        let byDate = try await repository().todayReviewStats(
            studyDayID: f.localDate(daysAgo: 0)
        )
        XCTAssertEqual(byID, byDate)
    }

    /// 新学按 note_id 去重并细分 kind；grammar 桶独立计数。
    func testNewLearnedStatsSplitByKind() async throws {
        var grammarNoteID: UUID!
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // vocabulary：sharedNote 与 exclusiveNote 各一次首学 → 2。
            try await f.addLog(daysAgo: 0, rating: .good, wasFirstStudy: true)
            try await f.addLog(
                daysAgo: 0,
                cardID: f.exclusiveCardID,
                noteID: f.exclusiveNoteID,
                deckID: f.deckBID,
                rating: .hard,
                wasFirstStudy: true
            )
            // grammar Note + 卡 + 首学日志。
            grammarNoteID = try await f.addNote(kind: "grammar", headword: "〜によって")
            let grammarCardID = try await f.addCard(
                noteID: grammarNoteID,
                templateKind: "grammar_form_explanation",
                dueAt: DailyStatisticsDatabaseFixture.now
            )
            try await f.addLogDetailed(
                daysAgo: 0,
                cardKey: grammarCardID,
                cardID: grammarCardID,
                noteID: grammarNoteID,
                rating: .good,
                wasFirstStudy: true,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    state: .new
                )
            )
        }
        let stats = try await repository().newLearnedStats(studyDayID: todayID)
        // vocab 桶：sharedNote + exclusiveNote 各 1 = 2；grammar = 1。
        XCTAssertEqual(stats.vocabulary, 2)
        XCTAssertEqual(stats.grammar, 1)
        XCTAssertEqual(stats.sentence, 0) // 'sentence' kind 由 v19 迁移引入
        XCTAssertEqual(stats.total, 3)
        XCTAssertNotNil(grammarNoteID)
    }

    /// 已删 Note 的首学日志仍计入 total（orphan 兜底 vocabulary 桶——
    /// kind 不可恢复，见报告 Contract deltas）。
    func testNewLearnedStatsKeepsOrphanNote() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            let orphanNote = try await f.addNote(kind: "grammar", headword: "已删语法")
            let orphanCard = try await f.addCard(
                noteID: orphanNote,
                templateKind: "grammar_form_explanation",
                dueAt: DailyStatisticsDatabaseFixture.now
            )
            try await f.addLogDetailed(
                daysAgo: 0,
                cardKey: orphanCard,
                cardID: orphanCard,
                noteID: orphanNote,
                rating: .good,
                wasFirstStudy: true,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    state: .new
                )
            )
            try await f.addLog(daysAgo: 0, rating: .good, wasFirstStudy: true)
            try await f.deleteNote(orphanNote)
        }
        let stats = try await repository().newLearnedStats(studyDayID: todayID)
        // grammar Note 已删 → orphan 落入 vocabulary 兜底桶；total 仍计 2。
        XCTAssertEqual(stats.vocabulary, 2)
        XCTAssertEqual(stats.grammar, 0)
        XCTAssertEqual(stats.total, 2)
    }

    /// 已删卡（Note 保留）的首学日志按 note_id join 仍能分出 kind。
    func testNewLearnedStatsDeletedCardKeepsKind() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            let noteID = try await f.addNote(kind: "grammar", headword: "语法点")
            let cardID = try await f.addCard(
                noteID: noteID,
                templateKind: "grammar_form_explanation",
                dueAt: DailyStatisticsDatabaseFixture.now
            )
            try await f.addLogDetailed(
                daysAgo: 0,
                cardKey: cardID,
                cardID: cardID,
                noteID: noteID,
                rating: .good,
                wasFirstStudy: true,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now,
                    state: .new
                )
            )
            try await f.deleteCard(cardID)
        }
        let stats = try await repository().newLearnedStats(studyDayID: todayID)
        XCTAssertEqual(stats.grammar, 1)
        XCTAssertEqual(stats.total, 1)
    }

    /// 成功率区间 = (Hard+Good+Easy)/全部有效评分；undo 不计；
    /// 跨多日闭区间聚合。
    func testSuccessRateRange() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0, rating: .again)   // fail
            try await f.addLog(daysAgo: 0, rating: .good)    // pass
            try await f.addLog(daysAgo: 1, rating: .hard)    // pass
            try await f.addLog(daysAgo: 1, rating: .easy)    // pass
            try await f.addLog(daysAgo: 2, rating: .again)   // fail
            try await f.addLog(
                daysAgo: 2,
                rating: .good,
                undoneAt: DailyStatisticsDatabaseFixture.now
            ) // undo 不计
            try await f.addLog(daysAgo: 5, rating: .again)   // 区间外
        }
        let stats = try await repository().successRate(
            fromStudyDayID: f.days[2].studyDay.id.uuidString,
            toStudyDayID: f.days[0].studyDay.id.uuidString
        )
        XCTAssertEqual(stats.ratedCount, 5)
        XCTAssertEqual(stats.passCount, 3)
        XCTAssertEqual(stats.rate ?? 0, 0.6, accuracy: 1e-9)
    }

    /// 端点不存在 → 抛 `studyDayNotFound`，不静默归零。
    func testSuccessRateUnknownStudyDayThrows() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { _ in }
        do {
            _ = try await repository().successRate(
                fromStudyDayID: UUID().uuidString,
                toStudyDayID: todayID
            )
            XCTFail("未知 studyDayID 应抛错")
        } catch StatisticsQueryError.studyDayNotFound(let id) {
            XCTAssertEqual(id.count, 36)
        }
    }

    /// 时长：Σduration_ms / duration_ms>0 的评分数；0ms 不进分母。
    func testAverageDurationExcludesZero() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0, durationMilliseconds: 1_000)
            try await f.addLog(daysAgo: 0, durationMilliseconds: 3_000)
            try await f.addLog(daysAgo: 0, durationMilliseconds: 0)
        }
        let stats = try await repository().averageDuration(studyDayID: todayID)
        XCTAssertEqual(stats.totalMilliseconds, 4_000)
        XCTAssertEqual(stats.ratedWithDurationCount, 2)
    }

    // MARK: - 保持率三口径

    /// 实测保持率：prev.state=review 且距上次评分 ≥1 日的有效事件里
    /// 非 Again 比例；近间隔/学习态/首学/undo 全部排除。
    func testActualRetentionSampling() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            let now = DailyStatisticsDatabaseFixture.now
            // 合格样本 ×3：pass2 / fail1。lastReviewAt 必须落在各学习日
            // reviewedAt（日首+12h）的 ≥1 日前——用「该日首 −3d」而非
            // 统一 now−3d，否则早期日的间隔不足 24h 会被口径正确排除。
            func prevReview(daysAgo: Int) -> SchedulingCard {
                SchedulingCard(
                    dueAt: now, stability: 3, difficulty: 8,
                    state: .review,
                    lastReviewAt: f.days[daysAgo].studyDay.startsAt
                        .addingTimeInterval(-3 * 86_400)
                )
            }
            try await f.addLogDetailed(
                daysAgo: 0, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .good, previousScheduling: prevReview(daysAgo: 0)
            )
            try await f.addLogDetailed(
                daysAgo: 1, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .again, previousScheduling: prevReview(daysAgo: 1)
            )
            try await f.addLogDetailed(
                daysAgo: 2, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .easy, previousScheduling: prevReview(daysAgo: 2)
            )
            // 间隔 <1 日 → 排除。
            try await f.addLogDetailed(
                daysAgo: 0, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .again,
                previousScheduling: SchedulingCard(
                    dueAt: now, stability: 3, difficulty: 8,
                    state: .review,
                    lastReviewAt: now.addingTimeInterval(-2 * 3_600)
                )
            )
            // prev.state = learning → 排除。
            try await f.addLogDetailed(
                daysAgo: 0, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .again,
                previousScheduling: SchedulingCard(
                    dueAt: now, stability: 3, difficulty: 8,
                    state: .learning,
                    lastReviewAt: now.addingTimeInterval(-5 * 86_400)
                )
            )
            // was_first_study → 排除。
            try await f.addLogDetailed(
                daysAgo: 0, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .again, wasFirstStudy: true,
                previousScheduling: SchedulingCard(
                    dueAt: now, state: .new
                )
            )
            // 合格但已 undo → 排除。
            try await f.addLogDetailed(
                daysAgo: 0, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .again,
                previousScheduling: prevReview(daysAgo: 0),
                undoneAt: now
            )
            // 窗口外（31 个学习日前）→ 排除。
            try await f.addLogDetailed(
                daysAgo: 31, cardKey: f.sharedCardID, noteID: f.sharedNoteID,
                rating: .again, previousScheduling: prevReview(daysAgo: 31)
            )
        }
        let stats = try await repository().retentionStats(
            asOf: DailyStatisticsDatabaseFixture.now
        )
        XCTAssertEqual(stats.actualSampleCount, 3)
        XCTAssertEqual(stats.actualRetention ?? 0, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(stats.targetRetention, 0.9, accuracy: 1e-9)
    }

    /// 无样本 → actualRetention nil（小样本显示 N，不伪造 0%）。
    func testActualRetentionEmpty() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { _ in }
        let stats = try await repository().retentionStats(
            asOf: DailyStatisticsDatabaseFixture.now
        )
        XCTAssertEqual(stats.actualSampleCount, 0)
        XCTAssertNil(stats.actualRetention)
    }

    /// 预测可回忆率：锁定 FSRS-6 遗忘曲线 R(t,S)=(1+FACTOR·t/(9S))^DECAY
    /// 的库实现；抽样手算交叉验证 + 多卡取均值。
    func testPredictedRecallMatchesFSRSFormula() async throws {
        let now = DailyStatisticsDatabaseFixture.now
        var cardA: UUID!
        var cardB: UUID!
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // 夹具默认卡 state=review/stability=4/lastReview=now-40d 已启用，
            // 但无 last_review_at_ms ——先看字段：fixture 未写 last_review_at_ms。
            cardA = try await f.addCard(
                noteID: f.exclusiveNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-10 * 86_400),
                stability: 10
            )
            cardB = try await f.addCard(
                noteID: f.sharedNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-30 * 86_400),
                stability: 20
            )
            // new 卡不参与预测（无历史）。
            _ = try await f.addCard(
                noteID: f.sharedNoteID,
                templateKind: "vocabulary_listening",
                state: 0,
                dueAt: now
            )
            // 暂停卡不参与。
            _ = try await f.addCard(
                noteID: f.exclusiveNoteID,
                templateKind: "vocabulary_listening",
                isEnabled: false,
                state: 2,
                dueAt: now,
                lastReviewAt: now.addingTimeInterval(-5 * 86_400),
                stability: 10
            )
        }
        let stats = try await repository().retentionStats(asOf: now)
        // 锁定 FSRS-6 实现（swift-fsrs FSRSAlgorithm.forgettingCurve）：
        // R(t,S) = (1 + FACTOR·t/S)^DECAY，DECAY=-w[20]=-0.1542，
        // FACTOR = 0.9^(1/DECAY) - 1，t 取 floor(经过天数)。
        let decay = -0.1542
        let factor = exp(log(0.9) / decay) - 1.0
        func r(_ t: Double, _ s: Double) -> Double {
            pow(1 + factor * t / s, decay)
        }
        let expected = (r(10, 10) + r(30, 20)) / 2
        let predicted = try XCTUnwrap(stats.predictedRecall)
        XCTAssertEqual(predicted, expected, accuracy: 1e-6)
        _ = cardA; _ = cardB
    }

    /// 全部卡都是 new / 无历史 → predictedRecall nil（不显示假数字）。
    func testPredictedRecallNilWithoutHistory() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // 夹具两张默认卡 last_review_at_ms 为 NULL → 无合格预测样本。
            _ = try await f.addCard(
                noteID: f.sharedNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 0,
                dueAt: DailyStatisticsDatabaseFixture.now
            )
        }
        let stats = try await repository().retentionStats(
            asOf: DailyStatisticsDatabaseFixture.now
        )
        XCTAssertNil(stats.predictedRecall)
    }

    /// 多 profile：目标保持率按启用非 new 卡数加权平均。
    func testTargetRetentionWeightedByCardCount() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            let heavy = try await f.addSchedulerProfile(desiredRetention: 0.8)
            // 默认 profile(0.9) 有 2 张启用非 new 卡；新 profile(0.8) 1 张。
            _ = try await f.addCard(
                noteID: f.sharedNoteID,
                templateKind: "vocabulary_zh_ja",
                state: 2,
                dueAt: DailyStatisticsDatabaseFixture.now,
                lastReviewAt: DailyStatisticsDatabaseFixture.now,
                profileID: heavy
            )
        }
        let stats = try await repository().retentionStats(
            asOf: DailyStatisticsDatabaseFixture.now
        )
        // (0.9*2 + 0.8*1) / 3
        XCTAssertEqual(stats.targetRetention, (0.9 * 2 + 0.8) / 3, accuracy: 1e-9)
    }

    // MARK: - 成熟度

    /// mature/young/learning/suspended/new 五桶互斥覆盖。
    func testCardMaturityBuckets() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            let now = DailyStatisticsDatabaseFixture.now
            // 夹具已有 2 张 review 卡（scheduled_days=0 → young）。
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "vocabulary_zh_ja",
                state: 2, dueAt: now, scheduledDays: 30
            ) // mature
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "vocabulary_listening",
                state: 1, dueAt: now
            ) // learning
            _ = try await f.addCard(
                noteID: f.exclusiveNoteID, templateKind: "vocabulary_zh_ja",
                state: 3, dueAt: now
            ) // learning（relearning 并入）
            let suspendedCard = try await f.addCard(
                noteID: f.exclusiveNoteID, templateKind: "vocabulary_listening",
                isEnabled: false, state: 2, dueAt: now, scheduledDays: 30
            ) // suspended（即使满足 mature 阈值也优先暂停桶）
            let newNote = try await f.addNote(headword: "新词")
            _ = try await f.addCard(
                noteID: newNote, templateKind: "vocabulary_ja_zh",
                state: 0, dueAt: now
            ) // new
            _ = suspendedCard
        }
        let stats = try await repository().cardMaturity()
        XCTAssertEqual(stats.mature, 1)
        XCTAssertEqual(stats.youngReview, 2)
        XCTAssertEqual(stats.learning, 2)
        XCTAssertEqual(stats.suspended, 1)
        XCTAssertEqual(stats.newCards, 1)
    }

    // MARK: - Forecast

    /// dueAt 按学习日（04:00 边界）分桶；overdue 单列；共享 Note 不放大。
    func testForecastBucketingAndOverdue() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            let day = f.days[0].studyDay
            // 今天到期（学习日内）→ bucket 0。
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "vocabulary_zh_ja",
                state: 2, dueAt: day.startsAt.addingTimeInterval(3_600)
            )
            // 明天 05:00 本地 → offset 1。
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "vocabulary_listening",
                state: 2, dueAt: day.endsAt.addingTimeInterval(3_600)
            )
            // 学习日开头前 1 小时（今天 03:00，属上一学习日）→ overdue。
            _ = try await f.addCard(
                noteID: f.exclusiveNoteID, templateKind: "vocabulary_zh_ja",
                state: 2, dueAt: day.startsAt.addingTimeInterval(-3_600)
            )
            // 30 天后 → 超出窗口，不进桶不过期。
            _ = try await f.addCard(
                noteID: f.exclusiveNoteID, templateKind: "vocabulary_listening",
                state: 2, dueAt: day.startsAt.addingTimeInterval(31 * 86_400)
            )
            // new / 暂停卡不计。
            let other = try await f.addNote(headword: "别的")
            _ = try await f.addCard(
                noteID: other, state: 0, dueAt: day.startsAt
            )
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "grammar_form_explanation",
                isEnabled: false, state: 2, dueAt: day.startsAt
            )
            // 夹具默认两张卡 due=now-1d → overdue +2。
        }
        let stats = try await repository().forecast(fromStudyDayID: todayID)
        XCTAssertEqual(stats.next7Days.count, 7)
        XCTAssertEqual(stats.next30Days.count, 30)
        XCTAssertEqual(stats.next7Days[0], 1)
        XCTAssertEqual(stats.next7Days[1], 1)
        XCTAssertEqual(stats.next30Days[0], 1)
        XCTAssertEqual(stats.next30Days[1], 1)
        XCTAssertEqual(stats.overdue, 3)
        XCTAssertEqual(stats.next7Days.reduce(0, +), 2)
    }

    /// DST：纽约时区跨切换学习日的分桶仍按日历日推进。
    func testForecastAcrossDST() async throws {
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = nyCalendar.date(
            from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)
        )!
        fixture = try await DailyStatisticsDatabaseFixture.make(
            timeZoneID: "America/New_York",
            now: now
        ) { f in
            // due = 明天本地中午（跨 DST 后），仍应落 offset 1。
            let tomorrow = nyCalendar.date(
                byAdding: .day, value: 1, to: now
            )!
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "vocabulary_zh_ja",
                state: 2, dueAt: tomorrow
            )
        }
        let stats = try await repository().forecast(
            fromStudyDayID: f.days[0].studyDay.id.uuidString
        )
        XCTAssertEqual(stats.next7Days[1], 1)
    }

    /// 参考学习日不存在 → 抛错。
    func testForecastUnknownStudyDayThrows() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { _ in }
        do {
            _ = try await repository().forecast(fromStudyDayID: UUID().uuidString)
            XCTFail("未知 studyDayID 应抛错")
        } catch StatisticsQueryError.studyDayNotFound {
            // 预期
        }
    }

    // MARK: - Weakness

    /// 30 学习日窗口、样本≥3、Again 次数排序、失败率决胜、orphan 占位。
    func testWeaknessRankingAndThresholds() async throws {
        var orphanNote: UUID!
        var coldNote: UUID!
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // sharedNote：5 次评分 4 次 Again → 榜首。
            for _ in 0..<4 {
                try await f.addLog(daysAgo: 0, rating: .again)
            }
            try await f.addLog(daysAgo: 0, rating: .good)
            // coldNote：3 次 2 Again → 其次。
            coldNote = try await f.addNote(headword: "冷僻")
            let coldCard = try await f.addCard(
                noteID: coldNote, dueAt: DailyStatisticsDatabaseFixture.now
            )
            for rating in [ReviewRating.again, .again, .good] {
                try await f.addLogDetailed(
                    daysAgo: 1, cardKey: coldCard, cardID: coldCard,
                    noteID: coldNote, rating: rating,
                    previousScheduling: SchedulingCard(
                        dueAt: DailyStatisticsDatabaseFixture.now, state: .review,
                        lastReviewAt: DailyStatisticsDatabaseFixture.now
                    )
                )
            }
            // orphanNote：删 Note 后仍在榜，headword 占位。
            orphanNote = try await f.addNote(headword: "将删")
            let orphanCard = try await f.addCard(
                noteID: orphanNote, dueAt: DailyStatisticsDatabaseFixture.now
            )
            for rating in [ReviewRating.again, .good, .good] {
                try await f.addLogDetailed(
                    daysAgo: 2, cardKey: orphanCard, cardID: orphanCard,
                    noteID: orphanNote, rating: rating,
                    previousScheduling: SchedulingCard(
                        dueAt: DailyStatisticsDatabaseFixture.now, state: .review,
                        lastReviewAt: DailyStatisticsDatabaseFixture.now
                    )
                )
            }
            try await f.deleteNote(orphanNote)
            // 样本 <3 不进榜。
            let thin = try await f.addNote(headword: "稀疏")
            let thinCard = try await f.addCard(
                noteID: thin, dueAt: DailyStatisticsDatabaseFixture.now
            )
            try await f.addLogDetailed(
                daysAgo: 0, cardKey: thinCard, cardID: thinCard,
                noteID: thin, rating: .again,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now, state: .review,
                    lastReviewAt: DailyStatisticsDatabaseFixture.now
                )
            )
            // 窗口外（31 天前）Again 不计。
            for _ in 0..<5 {
                try await f.addLog(daysAgo: 31, rating: .again)
            }
        }
        let entries = try await repository().weakness(limit: 10)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].noteID, f.sharedNoteID)
        XCTAssertEqual(entries[0].againCount30d, 4)
        XCTAssertEqual(entries[0].totalReviews30d, 5)
        XCTAssertEqual(entries[1].noteID, coldNote)
        XCTAssertEqual(entries[1].headword, "冷僻")
        XCTAssertEqual(entries[2].noteID, orphanNote)
        XCTAssertEqual(entries[2].headword, "（已删除笔记）")
        // limit 生效。
        let top1 = try await repository().weakness(limit: 1)
        XCTAssertEqual(top1.count, 1)
    }

    // MARK: - practice / undo / 边界隔离

    /// practiceOnly：practice_attempts 与 custom_study_sessions 对全部
    /// 正式统计零影响；scheduled 模式的正式评分照常计入。
    func testPracticeIsolation() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0, rating: .good)
            // practice 会话 + 大量 attempts——不应出现在任何正式指标。
            let session = try await f.addPracticeSession(
                attempts: [
                    (f.sharedCardID, f.sharedNoteID, .again),
                    (f.sharedCardID, f.sharedNoteID, .again),
                    (f.exclusiveCardID, f.exclusiveNoteID, .good)
                ]
            )
            // scheduled 模式的正式评分：review_log + origin 登记 → 计入。
            let eventID = try await f.addLogDetailed(
                daysAgo: 0, cardKey: f.sharedCardID, cardID: f.sharedCardID,
                noteID: f.sharedNoteID, rating: .hard,
                previousScheduling: SchedulingCard(
                    dueAt: DailyStatisticsDatabaseFixture.now, state: .review,
                    lastReviewAt: DailyStatisticsDatabaseFixture.now
                        .addingTimeInterval(-3 * 86_400)
                )
            )
            try await f.addScheduledOrigin(eventID: eventID, sessionID: session)
        }
        let repo = repository()
        let today = try await repo.todayReviewStats(studyDayID: todayID)
        XCTAssertEqual(today.effectiveRatingCount, 2) // practice 不计、scheduled 计
        let duration = try await repo.averageDuration(studyDayID: todayID)
        XCTAssertEqual(duration.ratedWithDurationCount, 2)
        let success = try await repo.successRate(
            fromStudyDayID: todayID, toStudyDayID: todayID
        )
        XCTAssertEqual(success.ratedCount, 2)
        let weak = try await repo.weakness(limit: 10)
        XCTAssertTrue(weak.isEmpty) // practice 的 Again 不进榜
    }

    /// 04:00 边界：学习日子夜后的评分归属前一学习日（沿 study_day_id
    /// 历史归属，不按当前时区重分）。
    func testStudyDayBoundaryAttribution() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // days[0].endsAt 前 3h = 次日凌晨 01:00 → 仍属今天。
            let lateNight = f.days[0].studyDay.endsAt.addingTimeInterval(-3 * 3_600)
            try await f.addLog(daysAgo: 0, rating: .good, reviewedAt: lateNight)
            // days[1].startsAt +1h = 昨天 05:00 → 昨天。
            let early = f.days[1].studyDay.startsAt.addingTimeInterval(3_600)
            try await f.addLog(daysAgo: 1, rating: .again, reviewedAt: early)
        }
        let repo = repository()
        let today = try await repo.todayReviewStats(studyDayID: todayID)
        XCTAssertEqual(today.effectiveRatingCount, 1)
        let yesterday = try await repo.todayReviewStats(
            studyDayID: f.days[1].studyDay.id.uuidString
        )
        XCTAssertEqual(yesterday.effectiveRatingCount, 1)
    }

    /// 共享 Note 多 membership：日志按 card_key/note_id 去重，不被
    /// note_decks 行数放大（EXPLAIN 不得出现 note_decks join）。
    func testSharedDeckCountedOnce() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0, deckID: f.deckAID, rating: .good)
            try await f.addLog(daysAgo: 0, deckID: f.deckBID, rating: .good)
            try await f.addLog(
                daysAgo: 0, rating: .again, wasFirstStudy: true
            )
        }
        let repo = repository()
        let today = try await repo.todayReviewStats(studyDayID: todayID)
        XCTAssertEqual(today.effectiveRatingCount, 3)
        let learned = try await repo.newLearnedStats(studyDayID: todayID)
        XCTAssertEqual(learned.vocabulary, 1) // 共享 Note 只计一次
    }

    // MARK: - 100k 查询计划与耗时

    /// 100k review_logs：核心谓词必须走索引（无全表扫 review_logs），
    /// 查询耗时在宽松门限内（防退化，非基准测试）。
    func testQueryPlansAndLatencyAt100kLogs() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make(dayCount: 40) { f in
            let cardKeys = (0..<2_000).map { _ in UUID() }
            var noteIDs = [f.sharedNoteID, f.exclusiveNoteID]
            for _ in 0..<500 {
                noteIDs.append(UUID()) // 大量 orphan note_id（不建 Note 行）
            }
            try await f.bulkInsertLogs(
                totalCount: 100_000,
                cardKeyPool: cardKeys,
                noteIDPool: noteIDs
            )
            // 少量有效卡供 forecast/predicted 走 cards 侧索引。
            _ = try await f.addCard(
                noteID: f.sharedNoteID, templateKind: "vocabulary_zh_ja",
                state: 2, dueAt: DailyStatisticsDatabaseFixture.now,
                lastReviewAt: DailyStatisticsDatabaseFixture.now
                    .addingTimeInterval(-10 * 86_400),
                stability: 10
            )
        }
        let repo = repository()

        // EXPLAIN QUERY PLAN：对所有 SQL 常量跑计划，禁止裸扫 review_logs；
        // cards 聚合全表扫描（maturity）是显式例外——它必须覆盖全部行。
        // 提升为局部值，避免 @Sendable 闭包捕获 self（todayID/f 都是实例成员）。
        let todayID = todayID
        let f = f
        try await f.database.pool.read { db in
            try Self.assertIndexed(
                db,
                sql: GRDBStatisticsRepository.todayReviewStatsSQL,
                arguments: [todayID, todayID],
                table: "review_logs"
            )
            try Self.assertIndexed(
                db,
                sql: GRDBStatisticsRepository.newLearnedStatsSQL,
                arguments: [todayID, todayID],
                table: "review_logs"
            )
            try Self.assertIndexed(
                db,
                sql: GRDBStatisticsRepository.averageDurationSQL,
                arguments: [todayID, todayID],
                table: "review_logs"
            )
            try Self.assertIndexed(
                db,
                sql: GRDBStatisticsRepository.successRateSQL,
                arguments: [f.localDate(daysAgo: 2), f.localDate(daysAgo: 0)],
                table: "review_logs"
            )
            try Self.assertIndexed(
                db,
                sql: GRDBStatisticsRepository.actualRetentionSQL,
                arguments: [try DatabaseValueCodec.encode(
                    DailyStatisticsDatabaseFixture.now
                )],
                table: "review_logs"
            )
            try Self.assertIndexed(
                db,
                sql: GRDBStatisticsRepository.weaknessSQL,
                arguments: [10],
                table: "review_logs"
            )
            // forecast 候选集走 covering index。
            try Self.assertIndexUsed(
                db,
                sql: GRDBStatisticsRepository.forecastCandidatesSQL,
                arguments: [],
                table: "cards"
            )
            try Self.assertIndexUsed(
                db,
                sql: GRDBStatisticsRepository.predictionCandidatesSQL,
                arguments: [],
                table: "cards"
            )
        }

        func timed<T>(_ budget: TimeInterval, _ work: () async throws -> T) async throws -> T {
            let start = Date()
            let value = try await work()
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, budget, "查询耗时 \(elapsed)s 超出门限 \(budget)s")
            return value
        }

        let today = try await timed(1.5) {
            try await repo.todayReviewStats(studyDayID: todayID)
        }
        XCTAssertEqual(today.effectiveRatingCount, 100_000 / 40) // 2500/日
        _ = try await timed(1.5) {
            try await repo.newLearnedStats(studyDayID: todayID)
        }
        _ = try await timed(1.5) {
            try await repo.averageDuration(studyDayID: todayID)
        }
        _ = try await timed(2.0) {
            try await repo.successRate(
                fromStudyDayID: f.days[29].studyDay.id.uuidString,
                toStudyDayID: todayID
            )
        }
        let retention = try await timed(2.5) {
            try await repo.retentionStats(asOf: DailyStatisticsDatabaseFixture.now)
        }
        // 100k 行 prev.state=review、lastReview=now-40d、was_first_study=0
        // → 30 学习日窗口内 75k 条全部是合格样本（≥1 日间隔）。
        XCTAssertEqual(retention.actualSampleCount, 75_000)
        XCTAssertEqual(retention.actualRetention ?? 0, 0.75, accuracy: 0.01)
        let weak = try await timed(2.5) {
            try await repo.weakness(limit: 20)
        }
        XCTAssertFalse(weak.isEmpty)
        let forecast = try await timed(1.5) {
            try await repo.forecast(fromStudyDayID: todayID)
        }
        XCTAssertEqual(forecast.next7Days[0], 1)
    }

    /// 计划断言：目标表必须被 INDEX 命中（SEARCH），不得出现无索引
    /// 全表扫描（`SCAN <table>` 且不带 USING INDEX）。
    private static func assertIndexed(
        _ db: Database,
        sql: String,
        arguments: StatementArguments,
        table: String
    ) throws {
        let details = try planDetails(db, sql: sql, arguments: arguments)
        let scanned = details.contains {
            $0.contains("SCAN \(table)") || $0.contains("SCAN rl")
                || $0.contains("SCAN review_logs")
        }
        let searched = details.contains { $0.contains("SEARCH") }
        XCTAssertFalse(
            scanned,
            "\(table) 出现全表扫描：\n\(details.joined(separator: "\n"))"
        )
        XCTAssertTrue(
            searched,
            "缺少索引搜索：\n\(details.joined(separator: "\n"))"
        )
    }

    private static func assertIndexUsed(
        _ db: Database,
        sql: String,
        arguments: StatementArguments,
        table: String
    ) throws {
        let details = try planDetails(db, sql: sql, arguments: arguments)
        let used = details.contains {
            $0.contains("USING INDEX") || $0.contains("USING COVERING INDEX")
                || $0.contains("USING PRIMARY KEY")
        }
        XCTAssertTrue(
            used,
            "\(table) 未走索引：\n\(details.joined(separator: "\n"))"
        )
    }

    private static func planDetails(
        _ db: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> [String] {
        try Row.fetchAll(
            db,
            sql: "EXPLAIN QUERY PLAN " + sql,
            arguments: arguments
        ).map { row -> String in
            row["detail"]
        }
    }
}
