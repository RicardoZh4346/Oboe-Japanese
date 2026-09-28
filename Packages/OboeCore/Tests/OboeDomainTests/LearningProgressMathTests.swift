import Foundation
import XCTest
@testable import OboeDomain

/// S14 进度纯函数测试：§13.1 公式与边界（contracts §5.1、
/// D08/D13）。核心样例：unit A 三卡 0/0.5/1 → 0.5，unit B 一卡
/// 1 → 1，牌组 = 0.75（DISTINCT unit 平均），不是物理卡均值
/// 0.625。
final class LearningProgressMathTests: XCTestCase {

    private typealias M = LearningProgressMath

    /// 恰好 0.5 进度的 stability：log1p(s) = 0.5·log1p(30)
    /// → s = sqrt(31) − 1。
    private let halfProgressStability = (31.0).squareRoot() - 1

    private func card(
        _ stability: Double?,
        enabled: Bool = true
    ) -> CardProgressResult {
        M.cardProgress(stabilityDays: stability, enabled: enabled)
    }

    // MARK: - cardProgress

    /// 未学习（nil stability）与 stability=0 → 0。
    func testCardProgressUnstudiedIsZero() {
        XCTAssertEqual(card(nil).value, 0)
        XCTAssertEqual(card(0).value, 0)
        XCTAssertFalse(card(nil).isDataAnomalous)
    }

    /// log1p/30 天目标：s=30 → 1；s=sqrt(31)−1 → 0.5；超出目标 clamp 1。
    func testCardProgressLog1pCurve() {
        XCTAssertEqual(
            card(halfProgressStability).value, 0.5, accuracy: 1e-12)
        XCTAssertEqual(card(30).value, 1.0, accuracy: 1e-12)
        XCTAssertEqual(card(300).value, 1.0, accuracy: 1e-12)  // clamp
    }

    /// 负 stability 是有限数 → max(0,·) 归零，不算异常。
    func testCardProgressNegativeStability() {
        let r = card(-5)
        XCTAssertEqual(r.value, 0)
        XCTAssertFalse(r.isDataAnomalous)
        XCTAssertTrue(r.countsTowardUnitMean)
    }

    /// NaN/±inf → 数据异常标记 + value 归零，不传播 NaN（D13）。
    func testCardProgressNonFiniteStability() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let r = card(bad)
            XCTAssertEqual(r.value, 0)
            XCTAssertTrue(r.isDataAnomalous)
            XCTAssertFalse(r.value.isNaN)
        }
    }

    /// 停用卡：value 照算但不计入 unit 均值（D13 active 口径）。
    func testCardProgressDisabledCardNotCounted() {
        let r = card(30, enabled: false)
        XCTAssertEqual(r.value, 1.0, accuracy: 1e-12)
        XCTAssertFalse(r.countsTowardUnitMean)
    }

    // MARK: - unitProgress

    /// 单卡 unit：启用卡均值即该卡进度。
    func testUnitProgressSingleCard() {
        let u = M.unitProgress(tooEasy: false, cardProgresses: [card(30)])
        XCTAssertEqual(u.value, 1.0, accuracy: 1e-12)
        XCTAssertEqual(u.enabledCardCount, 1)
        XCTAssertTrue(u.hasEnabledVocabularyCards)
    }

    /// tooEasy → 恒 1：空卡、有卡、全停用都一样（§13.1 优先级）。
    func testUnitProgressTooEasyAlwaysOne() {
        XCTAssertEqual(
            M.unitProgress(tooEasy: true, cardProgresses: []).value, 1)
        XCTAssertEqual(
            M.unitProgress(
                tooEasy: true,
                cardProgresses: [card(nil), card(nil)]).value, 1)
        let disabledOnly = M.unitProgress(
            tooEasy: true,
            cardProgresses: [card(30, enabled: false)])
        XCTAssertEqual(disabledOnly.value, 1)
    }

    /// 全停用 / 无卡 → 0，且 hasEnabledVocabularyCards=false
    /// （D13「无启用方向」标记依据）。
    func testUnitProgressNoEnabledCards() {
        let none = M.unitProgress(tooEasy: false, cardProgresses: [])
        XCTAssertEqual(none.value, 0)
        XCTAssertFalse(none.hasEnabledVocabularyCards)

        let allDisabled = M.unitProgress(
            tooEasy: false,
            cardProgresses: [card(30, enabled: false),
                             card(30, enabled: false)])
        XCTAssertEqual(allDisabled.value, 0)
        XCTAssertEqual(allDisabled.enabledCardCount, 0)
        XCTAssertFalse(allDisabled.hasEnabledVocabularyCards)
    }

    /// 停用卡不进均值：启用 1.0 + 停用 0.0 → 1，不是 0.5。
    func testUnitProgressExcludesDisabledCards() {
        let u = M.unitProgress(
            tooEasy: false,
            cardProgresses: [card(30), card(nil, enabled: false)])
        XCTAssertEqual(u.value, 1.0, accuracy: 1e-12)
        XCTAssertEqual(u.enabledCardCount, 1)
    }

    /// 方向增删的预期变化（§13.1）：新增未学方向拉低 unit 进度；
    /// 删除方向恢复原值。
    func testUnitProgressDirectionAddAndRemove() {
        let learned = card(30)          // 1.0
        let fresh = card(nil)           // 0.0
        let oneDirection = M.unitProgress(
            tooEasy: false, cardProgresses: [learned])
        XCTAssertEqual(oneDirection.value, 1.0, accuracy: 1e-12)

        let twoDirections = M.unitProgress(
            tooEasy: false, cardProgresses: [learned, fresh])
        XCTAssertEqual(twoDirections.value, 0.5, accuracy: 1e-12)

        let removed = M.unitProgress(
            tooEasy: false, cardProgresses: [learned])
        XCTAssertEqual(removed.value, 1.0, accuracy: 1e-12)
    }

    /// 异常计数上报：含 NaN 卡的 unit 仍给出有限 value，
    /// anomalousCardCount 标出待修复卡数。
    func testUnitProgressReportsAnomalies() {
        let u = M.unitProgress(
            tooEasy: false,
            cardProgresses: [card(30), card(.nan)])
        // NaN 卡 value=0 且计入均值（数据异常不该被悄悄排除而
        // 抬高掌握率）。
        XCTAssertEqual(u.value, 0.5, accuracy: 1e-12)
        XCTAssertEqual(u.anomalousCardCount, 1)
        XCTAssertFalse(u.value.isNaN)
    }

    // MARK: - deckProgress（§13.1 验收样例）

    /// 契约样例：unit A 三卡 0/0.5/1 → 0.5；unit B 一卡 1 → 1；
    /// deck = mean(0.5, 1) = 0.75，而非四张物理卡的 0.625。
    func testDeckProgressContractSample075() {
        let unitA = UUID()
        let unitB = UUID()
        let a = M.unitProgress(
            tooEasy: false,
            cardProgresses: [card(nil), card(halfProgressStability), card(30)])
        XCTAssertEqual(a.value, 0.5, accuracy: 1e-12)
        let b = M.unitProgress(tooEasy: false, cardProgresses: [card(30)])
        XCTAssertEqual(b.value, 1.0, accuracy: 1e-12)

        let deck = M.deckProgress(units: [
            DeckUnitProgressInput(unitID: unitA, progress: a.value),
            DeckUnitProgressInput(unitID: unitB, progress: b.value),
        ])
        XCTAssertEqual(deck ?? -1, 0.75, accuracy: 1e-12)
        XCTAssertNotEqual(deck ?? -1, 0.625, accuracy: 1e-12)
    }

    /// 同 unit 在不同 Note/deck 投影里重复出现 → 只占一票；
    /// unitA 标 tooEasy 后 deck 变 1.0，解除后回 0.75。
    func testDeckProgressDeduplicatesUnit() {
        let unitA = UUID()
        let unitB = UUID()
        // unitA 经两条 Note 出现两次（同值——全局唯一 unitProgress）。
        let deck = M.deckProgress(units: [
            DeckUnitProgressInput(unitID: unitA, progress: 0.5),
            DeckUnitProgressInput(unitID: unitA, progress: 0.5),
            DeckUnitProgressInput(unitID: unitB, progress: 1.0),
        ])
        XCTAssertEqual(deck ?? -1, 0.75, accuracy: 1e-12)

        // tooEasy：unitA → 1；恢复后回到均值。
        let mastered = M.deckProgress(units: [
            DeckUnitProgressInput(
                unitID: unitA,
                progress: M.unitProgress(tooEasy: true, cardProgresses: []).value),
            DeckUnitProgressInput(unitID: unitB, progress: 1.0),
        ])
        XCTAssertEqual(mastered ?? -1, 1.0, accuracy: 1e-12)
    }

    /// 空集 / 全 nil → nil（空 deck、仅 Cloze/Grammar deck 的
    /// 「—」语义）；nil 行被跳过不参与平均。
    func testDeckProgressEmptyAndNilOnly() {
        XCTAssertNil(M.deckProgress(units: []))
        XCTAssertNil(M.deckProgress(units: [
            DeckUnitProgressInput(unitID: UUID(), progress: nil),
            DeckUnitProgressInput(unitID: UUID(), progress: nil),
        ]))
        let mixed = M.deckProgress(units: [
            DeckUnitProgressInput(unitID: UUID(), progress: nil),
            DeckUnitProgressInput(unitID: UUID(), progress: 0.5),
        ])
        XCTAssertEqual(mixed ?? -1, 0.5, accuracy: 1e-12)
    }
}
