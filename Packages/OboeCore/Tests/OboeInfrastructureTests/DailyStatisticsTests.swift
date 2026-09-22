import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.5.5 每日统计（30 天窗口 + streak）核心测试。
final class DailyStatisticsTests: XCTestCase {
    private var fixture: DailyStatisticsDatabaseFixture?

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    private func repository() -> GRDBStudyHistoryRepository {
        GRDBStudyHistoryRepository(database: fixture!.database)
    }

    /// 零记录日补齐、固定 30 行、新日期在前。
    func testWindowAlwaysReturnsThirtyDaysWithZeroFill() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make(dayCount: 40) { f in
            try await f.addLog(daysAgo: 0, rating: .good)
            try await f.addLog(daysAgo: 5, rating: .hard)
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.days.count, 30)
        XCTAssertEqual(
            snapshot.days.map(\.localDate),
            (0..<30).map { fixture!.localDate(daysAgo: $0) }
        )
        XCTAssertEqual(snapshot.days[0].answerCount, 1)
        XCTAssertEqual(snapshot.days[5].answerCount, 1)
        XCTAssertEqual(snapshot.days[1].answerCount, 0)
        XCTAssertEqual(snapshot.days[29].answerCount, 0)
        XCTAssertEqual(snapshot.currentStreak, 1)
    }

    /// 首学按 Note 去重、复习按 card_key 去重、回答数逐事件累计、
    /// 用时求和、评分四档分布。
    func testAggregationSemantics() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // 同一 Note 两个方向的首学 → newLearned 1、answer 2。
            try await f.addLog(daysAgo: 0, rating: .good, wasFirstStudy: true,
                               durationMilliseconds: 1_000)
            try await f.addLog(daysAgo: 0, rating: .again, wasFirstStudy: true,
                               durationMilliseconds: 2_000)
            // 同一卡两次复习评分 → reviewedCard 1、answer +2。
            try await f.addLog(daysAgo: 0, rating: .hard,
                               durationMilliseconds: 3_000)
            try await f.addLog(daysAgo: 0, rating: .easy,
                               durationMilliseconds: 4_000)
            // 另一张卡一次复习。
            try await f.addLog(
                daysAgo: 0,
                cardID: f.exclusiveCardID,
                noteID: f.exclusiveNoteID,
                deckID: f.deckBID,
                rating: .good,
                durationMilliseconds: 5_000
            )
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        let today = snapshot.days[0]
        XCTAssertEqual(today.newLearnedCount, 1)
        XCTAssertEqual(today.reviewedCardCount, 2)
        XCTAssertEqual(today.answerCount, 5)
        XCTAssertEqual(today.durationMilliseconds, 15_000)
        XCTAssertEqual(
            today.ratings,
            RatingDistribution(again: 1, hard: 1, good: 2, easy: 1)
        )
    }

    /// 撤销日志不参与统计，也不延续 streak。
    func testUndoneLogsAreExcluded() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0, rating: .good)
            try await f.addLog(
                daysAgo: 1,
                rating: .good,
                undoneAt: DailyStatisticsDatabaseFixture.now
            )
            try await f.addLog(daysAgo: 2, rating: .good)
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.days[0].answerCount, 1)
        XCTAssertEqual(snapshot.days[1].answerCount, 0)
        XCTAssertEqual(snapshot.days[2].answerCount, 1)
        // 昨天「无有效评分」→ 断档，streak 只算今天。
        XCTAssertEqual(snapshot.currentStreak, 1)
    }

    /// 今天已学：streak 从今天起算，跨过零日记为断档。
    func testStreakCountsFromTodayWhenTodayStudied() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            for ago in [0, 1, 2, 4, 5] {
                try await f.addLog(daysAgo: ago)
            }
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.currentStreak, 3)
    }

    /// 今天未学但昨天已学：保留截至昨天的连续天数（首次学习前不归零）。
    func testStreakGraceWhenTodayNotYetStudied() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            for ago in [1, 2, 3] {
                try await f.addLog(daysAgo: ago)
            }
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.currentStreak, 3)
    }

    /// 今昨均无有效评分 → 0。
    func testStreakZeroWhenTodayAndYesterdayMissing() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 2)
            try await f.addLog(daysAgo: 3)
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.currentStreak, 0)
    }

    /// 全库无任何评分 → 30 行全零、streak 0。
    func testEmptyDatabaseYieldsZeroedWindow() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { _ in }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.days.count, 30)
        XCTAssertTrue(snapshot.days.allSatisfy { !$0.hasActivity })
        XCTAssertEqual(snapshot.currentStreak, 0)
        XCTAssertEqual(snapshot.activeDayCount, 0)
    }

    /// 跨 04:00：子夜后（01:00 本地）的评分仍归属前一学习日。
    func testLogAfterMidnightCountsTowardPreviousStudyDay() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // days[0] = 今天学习日 [今04:00, 明04:00)；01:00 次日凌晨的
            // 评分落在其尾部。
            let lateNight = f.days[0].studyDay.endsAt.addingTimeInterval(-3 * 3_600)
            try await f.addLog(daysAgo: 0, reviewedAt: lateNight)
            // 相对地，days[1] 的起点附近（昨日 05:00）属于昨天。
            let earlyMorning = f.days[1].studyDay.startsAt.addingTimeInterval(3_600)
            try await f.addLog(daysAgo: 1, reviewedAt: earlyMorning)
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.days[0].answerCount, 1)
        XCTAssertEqual(snapshot.days[1].answerCount, 1)
        XCTAssertEqual(snapshot.currentStreak, 2)
    }

    /// DST：America/New_York 2026-03-08 02:00 拨快；跨切换日的学习日
    /// 长度 23 小时，窗口与 streak 仍须按学习日切分。
    func testDSTTransitionKeepsStreakAndWindow() async throws {
        // 2026-03-10 12:00（纽约本地）= 切换后第一个学习日的中段。
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = nyCalendar.date(
            from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)
        )!
        fixture = try await DailyStatisticsDatabaseFixture.make(
            timeZoneID: "America/New_York",
            now: now
        ) { f in
            // daysAgo=1 是跨 DST 切换的学习日（03-07 04:00 EST →
            // 03-08 04:00 EDT，23 小时）。
            for ago in [0, 1, 2] {
                try await f.addLog(daysAgo: ago)
            }
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.days.count, 30)
        XCTAssertEqual(snapshot.currentStreak, 3)
        XCTAssertEqual(snapshot.days[1].answerCount, 1)
    }

    /// 共享 Note 在两个牌组中都可见，但每条日志只统计一次。
    func testSharedNoteLogsAreNotDuplicatedByMembership() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            // sharedNote 属于 A+B：同一卡的两条日志只能各计一次。
            try await f.addLog(daysAgo: 0, deckID: f.deckAID)
            try await f.addLog(daysAgo: 0, deckID: f.deckBID)
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.days[0].answerCount, 2)
        XCTAssertEqual(snapshot.days[0].reviewedCardCount, 1)
        XCTAssertEqual(snapshot.currentStreak, 1)
    }

    /// 无日志的 study_day 行（当天打开了 App 但没学）计为零日，
    /// 同样造成 streak 断档。
    func testStudyDayWithoutLogsBreaksStreak() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make { f in
            try await f.addLog(daysAgo: 0)
            // daysAgo=1 有 study_day 行但无日志。
            try await f.addLog(daysAgo: 2)
        }
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        XCTAssertEqual(snapshot.currentStreak, 1)
        XCTAssertEqual(snapshot.days[1].answerCount, 0)
    }

    /// 耗时门控：60 个学习日 × 50 条日志（共 3000 行）内单次范围
    /// 读取须快速完成（宽松门限只防退化，不充当基准测试）。
    func testRangeQueryPerformanceGate() async throws {
        fixture = try await DailyStatisticsDatabaseFixture.make(dayCount: 60) { f in
            for ago in 0..<60 {
                for index in 0..<50 {
                    try await f.addLog(
                        daysAgo: ago,
                        rating: ReviewRating(rawValue: index % 4 + 1)!,
                        durationMilliseconds: 500
                    )
                }
            }
        }
        let start = Date()
        let snapshot = try await repository().fetchDailyStatistics(
            endingAt: fixture!.days[0].studyDay,
            dayCount: 30
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(snapshot.days[0].answerCount, 50)
        XCTAssertEqual(snapshot.currentStreak, 60)
        XCTAssertLessThan(elapsed, 2.0, "范围聚合耗时 \(elapsed)s 超出门限")
    }
}
