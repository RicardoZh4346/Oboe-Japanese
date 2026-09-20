import XCTest
@testable import OboeDomain

/// Contract tests for the JLPT word-level classifier (design §11.2):
/// five mutually exclusive buckets plus the suspended/not-started
/// auxiliary flags. Card-level leech/warning status arrives already
/// classified by `LeechClassifier` — these tests verify word
/// aggregation, never re-derive card rules.
final class JLPTWordClassifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func card(
        id: UUID = UUID(),
        template: CardTemplateKind = .vocabularyJapaneseToChinese,
        enabled: Bool = true,
        status: AdaptiveCardStatus = .normal,
        state: SchedulingState = .new,
        stability: Double = 0,
        studied: Bool = false,
        lastRating: ReviewRating? = nil,
        lastRatingAt: Date? = nil,
        lastAgainAt: Date? = nil
    ) -> JLPTCardProgressInput {
        JLPTCardProgressInput(
            cardID: id,
            templateKind: template,
            isEnabled: enabled,
            adaptiveStatus: status,
            state: state,
            stability: stability,
            hasStudied: studied,
            lastEffectiveRating: lastRating,
            lastEffectiveRatingAt: lastRatingAt,
            lastAgainAt: lastAgainAt
        )
    }

    /// 满足「较稳定」全部条件的启用卡。
    private func stableCard(
        stability: Double = 25,
        lastRating: ReviewRating = .good,
        lastAgainAt: Date? = nil,
        status: AdaptiveCardStatus = .normal
    ) -> JLPTCardProgressInput {
        card(
            status: status,
            state: .review,
            stability: stability,
            studied: true,
            lastRating: lastRating,
            lastRatingAt: now.addingTimeInterval(-day),
            lastAgainAt: lastAgainAt
        )
    }

    private func classify(
        _ cards: [JLPTCardProgressInput],
        policy: JLPTProgressPolicy = .standard
    ) -> JLPTWordStatus {
        JLPTWordClassifier.classify(cards: cards, at: now, policy: policy)
    }

    // MARK: - 桶 1：未加入

    func testNoCardsIsNotAdded() {
        let status = classify([])
        XCTAssertEqual(status.bucket, .notAdded)
        XCTAssertFalse(status.isSuspended)
        XCTAssertFalse(status.isNotStarted)
    }

    // MARK: - 桶 5：学习中（含未开始）

    func testAllNewEnabledIsLearningNotStarted() {
        let status = classify([card(), card()])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertFalse(status.isSuspended)
        XCTAssertTrue(status.isNotStarted)
    }

    func testLearningWithoutRecentAgainWhenLastAgainTooOld() {
        // 末次有效评分是 Again 但已是 8 天前 —— 超出「近 7 日」，
        // 不够稳定（lastRating 非 Good/Easy），落回学习中。
        let status = classify([
            card(
                state: .review, stability: 30, studied: true,
                lastRating: .again,
                lastRatingAt: now.addingTimeInterval(-8 * day),
                lastAgainAt: now.addingTimeInterval(-8 * day)
            )
        ])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertFalse(status.isNotStarted)
    }

    // MARK: - 桶 2：经常遗忘

    func testAnyEnabledLeechIsFrequentlyForgotten() {
        let status = classify([
            stableCard(),
            card(
                status: .leech, state: .review, stability: 30,
                studied: true, lastRating: .easy,
                lastRatingAt: now.addingTimeInterval(-day)
            )
        ])
        XCTAssertEqual(status.bucket, .frequentlyForgotten)
    }

    func testSuspendedLeechDoesNotTriggerFrequentlyForgotten() {
        // 「任一启用 Card」——暂停卡不计入 leech 桶。
        let status = classify([
            card(enabled: false, status: .leech, studied: true),
            stableCard()
        ])
        XCTAssertEqual(status.bucket, .stable)
    }

    // MARK: - 桶 3：近期遗忘

    func testRecentAgainIsRecentlyForgotten() {
        let status = classify([
            stableCard(),
            card(
                state: .learning, stability: 0.5, studied: true,
                lastRating: .again,
                lastRatingAt: now.addingTimeInterval(-2 * day),
                lastAgainAt: now.addingTimeInterval(-2 * day)
            )
        ])
        XCTAssertEqual(status.bucket, .recentlyForgotten)
    }

    func testAgainExactlyAtWindowBoundaryIsRecent() {
        // 「近 7 日」含边界：恰好 7 天前仍属近期。
        let status = classify([
            card(
                state: .relearning, studied: true,
                lastRating: .again,
                lastRatingAt: now.addingTimeInterval(-7 * day),
                lastAgainAt: now.addingTimeInterval(-7 * day)
            )
        ])
        XCTAssertEqual(status.bucket, .recentlyForgotten)
    }

    func testLeechBeatsRecentAgain() {
        // 桶序互斥：leech 优先于近期遗忘。
        let status = classify([
            card(
                status: .leech, state: .learning, studied: true,
                lastRating: .again,
                lastRatingAt: now.addingTimeInterval(-day),
                lastAgainAt: now.addingTimeInterval(-day)
            )
        ])
        XCTAssertEqual(status.bucket, .frequentlyForgotten)
    }

    func testAgainFollowedByGoodIsNotRecentButBlocksStable() {
        // 最近有效评分 Good（非 Again）→ 不是近期遗忘；
        // 但 3 天内有 Again → 不满足「近 7 日无 Again」→ 学习中。
        let status = classify([
            stableCard(lastAgainAt: now.addingTimeInterval(-3 * day))
        ])
        XCTAssertEqual(status.bucket, .learning)
    }

    // MARK: - 桶 4：较稳定

    func testStableWhenAllEnabledQualify() {
        let status = classify([stableCard(stability: 21), stableCard(stability: 400)])
        XCTAssertEqual(status.bucket, .stable)
    }

    func testStabilityBoundaryAt21Days() {
        XCTAssertEqual(classify([stableCard(stability: 21)]).bucket, .stable)
        XCTAssertEqual(
            classify([stableCard(stability: 20.9)]).bucket, .learning,
            "stability 略低于阈值即回落学习中"
        )
    }

    func testNewEnabledDirectionRegressesStableWordToLearning() {
        // 「新增未学听力方向把该词从较稳定转回学习中」：
        // 聚合按全部启用方向，new 卡不满足稳定条件。
        let status = classify([stableCard(), card()])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertFalse(status.isNotStarted, "已学卡存在 → 不是未开始")
    }

    func testSuspendedNewDirectionDoesNotRegressStableWord() {
        let status = classify([stableCard(), card(enabled: false)])
        XCTAssertEqual(status.bucket, .stable)
    }

    func testWarningCardBlocksStable() {
        let status = classify([stableCard(status: .warning)])
        XCTAssertEqual(status.bucket, .learning, "warning 不满足『不是 warning/leech』")
    }

    // MARK: - 辅助状态：已暂停 / 未开始

    func testAllSuspendedStudiedIsLearningSuspended() {
        let status = classify([
            card(enabled: false, state: .review, stability: 30,
                 studied: true, lastRating: .good,
                 lastRatingAt: now.addingTimeInterval(-day))
        ])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertTrue(status.isSuspended)
        XCTAssertFalse(status.isNotStarted)
    }

    func testAllSuspendedAllNewIsLearningSuspendedNotStarted() {
        let status = classify([card(enabled: false), card(enabled: false)])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertTrue(status.isSuspended)
        XCTAssertTrue(status.isNotStarted)
    }

    func testMixedSuspendedNewAndEnabledNewKeepsNotStarted() {
        let status = classify([card(enabled: false), card()])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertFalse(status.isSuspended, "存在启用卡 → 非全暂停")
        XCTAssertTrue(status.isNotStarted)
    }

    func testStudiedSuspendedPlusEnabledNewIsNotNotStarted() {
        let status = classify([
            card(enabled: false, state: .review, stability: 30, studied: true,
                 lastRating: .good, lastRatingAt: now.addingTimeInterval(-day)),
            card()
        ])
        XCTAssertEqual(status.bucket, .learning)
        XCTAssertFalse(status.isNotStarted)
    }

    // MARK: - 策略参数集中

    func testPolicyWindowIsConfigurable() {
        let wide = JLPTProgressPolicy(recentAgainDaysWindow: 30)
        let input = card(
            state: .review, stability: 30, studied: true,
            lastRating: .again,
            lastRatingAt: now.addingTimeInterval(-20 * day),
            lastAgainAt: now.addingTimeInterval(-20 * day)
        )
        XCTAssertEqual(classify([input]).bucket, .learning)
        XCTAssertEqual(
            classify([input], policy: wide).bucket, .recentlyForgotten,
            "窗口参数由 policy 控制，不硬编码"
        )
    }

    // MARK: - 确定性

    func testDeterministicForIdenticalInputs() {
        let inputs = [
            stableCard(),
            card(enabled: false),
            card(state: .learning, studied: true,
                 lastRating: .again, lastRatingAt: now, lastAgainAt: now)
        ]
        XCTAssertEqual(classify(inputs), classify(inputs))
    }
}
