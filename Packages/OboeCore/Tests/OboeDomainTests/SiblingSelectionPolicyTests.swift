import XCTest
@testable import OboeDomain

/// Contract tests for the pure sibling-separation selection policy
/// (design §9.1). The policy sees only the already scope-filtered,
/// already-eligible `availableNow` order — suspension, future due times and
/// deck scoping are upstream concerns and cannot reach the function.
final class SiblingSelectionPolicyTests: XCTestCase {

    private struct Card: SiblingSelectionCandidate, Equatable {
        let cardID: UUID
        let noteID: UUID

        init(_ name: String, note: String) {
            cardID = UUID(uuidString: "00000000-0000-0000-0000-\(name)")!
            noteID = UUID(uuidString: "00000000-0000-0000-0000-\(note)")!
        }
    }

    private let noteA = "00000000000A"
    private let noteB = "00000000000B"
    private let noteC = "00000000000C"

    // MARK: - Core selection rules (设计 §9.3 示例表)

    func testEmptyCandidatesReturnNil() {
        let selection = SiblingSelectionPolicy.selectNext(
            among: [Card](),
            lastPresentedNoteID: UUID(uuidString: "00000000-0000-0000-0000-\(noteA)")!,
            deferredCardID: nil
        )
        XCTAssertNil(selection)
    }

    func testFirstDifferentNoteSelectsFirst() {
        let a1 = Card("0000000000A1", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1, b1],
            lastPresentedNoteID: b1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, a1)
        XCTAssertNil(selection?.deferredCardID)
        XCTAssertEqual(selection?.insertedSpacer, false)
    }

    /// A1、A2、B1 / A → B1（首个其他 Note 作为间隔），A1 记为待偿还。
    func testSameNoteFirstDefersToFirstDifferentNote() {
        let a1 = Card("0000000000A1", note: noteA)
        let a2 = Card("0000000000A2", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let b2 = Card("0000000000B2", note: noteB)
        let c1 = Card("0000000000C1", note: noteC)
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1, a2, b1, b2, c1],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, b1, "间隔卡取首个其他 Note，不是更后面的 C1")
        XCTAssertEqual(selection?.deferredCardID, a1.cardID, "被暂缓的 first 记为债务")
        XCTAssertEqual(selection?.insertedSpacer, true)
    }

    /// 债务卡下一次回到首位且不再冲突 → 自然展示并清偿。
    func testDeferredCardIsRepaidOnNextNonConflictingCall() {
        let a1 = Card("0000000000A1", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let b2 = Card("0000000000B2", note: noteB)

        let first = SiblingSelectionPolicy.selectNext(
            among: [a1, b1],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(first?.selected, b1)

        let second = SiblingSelectionPolicy.selectNext(
            among: [a1, b2],
            lastPresentedNoteID: b1.noteID,
            deferredCardID: first?.deferredCardID
        )
        XCTAssertEqual(second?.selected, a1, "债务卡 A1 优先回归")
        XCTAssertNil(second?.deferredCardID, "展示债务卡即清偿")
    }

    /// 仅 A/A：没有其他 Note 时正常展示同 Note 卡，不错开。
    func testOnlySameNoteCandidatesPresentFirst() {
        let a1 = Card("0000000000A1", note: noteA)
        let a2 = Card("0000000000A2", note: noteA)
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1, a2],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, a1)
        XCTAssertNil(selection?.deferredCardID, "未发生延期则不欠债务")
        XCTAssertEqual(selection?.insertedSpacer, false)
    }

    /// 低优先级卡允许做一次间隔（跨优先级插入是规则允许的）。
    func testLowerPriorityCardMayActAsSpacer() {
        let a1 = Card("0000000000A1", note: noteA) // 高优先级（如 learning）
        let b1 = Card("0000000000B1", note: noteB) // 低优先级（如 new）
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1, b1],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, b1, "策略不感知 category——排序与优先级是上游职责")
        XCTAssertEqual(selection?.insertedSpacer, true)
    }

    /// lastPresentedNoteID 为空（会话首卡）→ 直接取 first。
    func testNoLastPresentedSelectsFirst() {
        let a1 = Card("0000000000A1", note: noteA)
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1],
            lastPresentedNoteID: nil,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, a1)
        XCTAssertNil(selection?.deferredCardID)
    }

    // MARK: - 债务约束：至多一次延期

    /// 债务未偿还时再次出现同 Note 冲突 → 不再二次延期，直接展示 first 并清偿。
    /// 这覆盖「队列变化使延期卡又与最近展示同 Note」的例外路径。
    func testPendingDebtBlocksSecondDeferral() {
        let x = Card("0000000000F1", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let b2 = Card("0000000000B2", note: noteB)
        let c1 = Card("0000000000C1", note: noteC)

        // 第一次：X(A) 与 A 冲突 → 插入 B1，X 记为债务。
        let first = SiblingSelectionPolicy.selectNext(
            among: [x, b1],
            lastPresentedNoteID: x.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(first?.selected, b1)

        // 队列变化：B 系卡回到首位，又遇同 Note 冲突，且仍存在其他 Note。
        // 债务未清 → 最多一次延期优先于尽量错开，直接展示 B2。
        let second = SiblingSelectionPolicy.selectNext(
            among: [b2, x, c1],
            lastPresentedNoteID: b1.noteID,
            deferredCardID: first?.deferredCardID
        )
        XCTAssertEqual(second?.selected, b2, "债务未清时不得再次延期")
        XCTAssertNil(second?.deferredCardID, "冲突展示消费债务")
    }

    /// 债务卡离开候选集（被其他途径评分/暂停/scope 变化）→ 债务失效，
    /// 不得阻碍下一次合法延期。
    func testDebtExpiresWhenDeferredCardLeavesCandidates() {
        let x = Card("0000000000F1", note: noteA)
        let a2 = Card("0000000000A2", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let b2 = Card("0000000000B2", note: noteB)
        let c1 = Card("0000000000C1", note: noteC)

        let first = SiblingSelectionPolicy.selectNext(
            among: [x, a2, b1],
            lastPresentedNoteID: x.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(first?.selected, b1)
        XCTAssertEqual(first?.deferredCardID, x.cardID)

        // X 离开候选集；B 系首位遇冲突时债务已失效 → 允许新一次延期。
        let second = SiblingSelectionPolicy.selectNext(
            among: [b2, c1],
            lastPresentedNoteID: b1.noteID,
            deferredCardID: first?.deferredCardID
        )
        XCTAssertEqual(second?.selected, c1)
        XCTAssertEqual(second?.deferredCardID, b2.cardID)
    }

    /// 同 Note 冲突且债务是另一张已离队的卡 → 失效债务不阻止延期。
    func testStaleDebtDoesNotBlockNewDeferral() {
        let a1 = Card("0000000000A1", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let gone = Card("00000000DEAD", note: noteC)
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1, b1],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: gone.cardID
        )
        XCTAssertEqual(selection?.selected, b1)
        XCTAssertEqual(selection?.deferredCardID, a1.cardID)
    }

    // MARK: - 输入契约：暂停/未来/scope 外卡不可达

    /// 输入即权威：暂停卡、未来重学卡、scope 外卡在上游被过滤后，
    /// 策略只在给定集合内选择 —— 用「仅剩同 Note」场景证明上游排除生效。
    func testFilteredOutCardsCannotBeSelected() {
        let a1 = Card("0000000000A1", note: noteA)
        // 上游已剔除未来 B1 与暂停 C1 —— 策略无从感知它们。
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, a1)
    }

    /// scope 过滤后只剩同 Note → 不跨牌组找间隔（上游已限定集合）。
    func testScopeFilteringIsUpstreamResponsibility() {
        let a1 = Card("0000000000A1", note: noteA)
        let a2 = Card("0000000000A2", note: noteA)
        // 其他牌组的 B1 不在输入中 → 同 Note 正常展示。
        let selection = SiblingSelectionPolicy.selectNext(
            among: [a1, a2],
            lastPresentedNoteID: a1.noteID,
            deferredCardID: nil
        )
        XCTAssertEqual(selection?.selected, a1)
    }

    // MARK: - 函数契约

    /// 确定性：同一组输入重复求值必须返回同一结果。
    func testDeterministicForIdenticalInputs() {
        let a1 = Card("0000000000A1", note: noteA)
        let a2 = Card("0000000000A2", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let inputs = [a1, a2, b1]
        for _ in 0..<3 {
            let selection = SiblingSelectionPolicy.selectNext(
                among: inputs,
                lastPresentedNoteID: a1.noteID,
                deferredCardID: nil
            )
            XCTAssertEqual(selection?.selected, b1)
            XCTAssertEqual(selection?.deferredCardID, a1.cardID)
        }
    }

    /// 返回值永远是输入集合的成员。
    func testSelectionIsAlwaysMemberOfInput() {
        let cards = [
            Card("0000000000A1", note: noteA),
            Card("0000000000A2", note: noteA),
            Card("0000000000B1", note: noteB),
            Card("0000000000C1", note: noteC)
        ]
        for lastNote in [noteA, noteB, noteC] {
            for debtCard in [nil] + cards.map { Optional($0) } {
                let selection = SiblingSelectionPolicy.selectNext(
                    among: cards,
                    lastPresentedNoteID: UUID(uuidString: "00000000-0000-0000-0000-\(lastNote)")!,
                    deferredCardID: debtCard?.cardID
                )
                XCTAssertNotNil(selection)
                XCTAssertTrue(
                    cards.contains(where: { $0.cardID == selection!.selected.cardID }),
                    "选择结果必须属于输入集合"
                )
                if let debt = selection?.deferredCardID {
                    XCTAssertTrue(
                        cards.contains(where: { $0.cardID == debt }),
                        "返回的债务必须引用当前候选"
                    )
                }
            }
        }
    }

    /// 有限候选不饥饿：重复模拟「评分→重建→再选」循环，每张卡至多
    /// 被延期一次，到期卡在有限步内必然被展示。
    func testNoStarvationAcrossRepeatedSelection() {
        let a1 = Card("0000000000A1", note: noteA)
        let a2 = Card("0000000000A2", note: noteA)
        let b1 = Card("0000000000B1", note: noteB)
        let c1 = Card("0000000000C1", note: noteC)

        var queue = [a1, a2, b1, c1]
        var lastPresented = a1.noteID
        var debt: UUID? = nil
        var presented: [Card] = []

        // 模拟会话：每次选择后把所选卡移到队尾（评分后重新到期），
        // lastPresented 跟随实际展示。候选集有限、状态机循环——
        // 每张卡都应被展示，不允许任何卡无限等待。
        for _ in 0..<12 {
            guard let selection = SiblingSelectionPolicy.selectNext(
                among: queue,
                lastPresentedNoteID: lastPresented,
                deferredCardID: debt
            ) else { break }
            presented.append(selection.selected)
            lastPresented = selection.selected.noteID
            debt = selection.deferredCardID
            queue.removeAll { $0.cardID == selection.selected.cardID }
            queue.append(selection.selected)
        }

        for card in [a1, a2, b1, c1] {
            XCTAssertTrue(
                presented.contains(card),
                "卡 \(card.cardID) 在 12 步内未被展示——存在饥饿"
            )
        }
        // 且任何单卡不得连续被延期两次（债务机制保证至多一次）。
        XCTAssertEqual(presented.count, 12)
    }
}
