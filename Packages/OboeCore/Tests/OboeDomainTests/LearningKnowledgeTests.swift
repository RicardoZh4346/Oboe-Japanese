import Foundation
import XCTest
@testable import OboeDomain

/// S07 纯领域测试：三态真值表、Too Easy 命令值语义/CAS、
/// 调度资格矩阵（contracts §2、D15、技术文档 §12）。
final class LearningKnowledgeTests: XCTestCase {

    // MARK: - 三态真值表（§2.1：tooEasy → mastered → Note → learning → unknown）

    /// 真值表全部 4 种输入组合。
    func testTruthTableAllCombinations() {
        XCTAssertEqual(
            LearningKnowledgeResolver.state(
                tooEasy: true, hasVocabularyNoteLink: true),
            .mastered)
        XCTAssertEqual(
            LearningKnowledgeResolver.state(
                tooEasy: true, hasVocabularyNoteLink: false),
            .mastered)
        XCTAssertEqual(
            LearningKnowledgeResolver.state(
                tooEasy: false, hasVocabularyNoteLink: true),
            .learning)
        XCTAssertEqual(
            LearningKnowledgeResolver.state(
                tooEasy: false, hasVocabularyNoteLink: false),
            .unknown)
    }

    /// 无 Note 的 unit 也可 tooEasy=true → mastered（§12.1）。
    func testTooEasyWithoutNoteIsMastered() {
        XCTAssertEqual(
            LearningKnowledgeResolver.state(
                tooEasy: true, hasVocabularyNoteLink: false),
            .mastered)
    }

    // MARK: - TooEasyCommand 值语义与 CAS

    /// 命令是不可变值类型：同字段相等、任一字段不同即不等；
    /// 复制修改一个副本不影响原值（命令本身全是 let，不可原地改）。
    func testTooEasyCommandValueSemantics() {
        let unit = UUID()
        let op = UUID()
        let a = TooEasyCommand(
            unitID: unit, value: true,
            expectedFlagRevision: 3, operationID: op)
        let b = TooEasyCommand(
            unitID: unit, value: true,
            expectedFlagRevision: 3, operationID: op)
        XCTAssertEqual(a, b)

        // 同 operationID 不同 payload → 不相等（幂等三层：必须拒绝）。
        let differentPayload = TooEasyCommand(
            unitID: unit, value: false,
            expectedFlagRevision: 3, operationID: op)
        XCTAssertNotEqual(a, differentPayload)
        // 同 payload 不同 operationID → 不相等。
        let differentOp = TooEasyCommand(
            unitID: unit, value: true,
            expectedFlagRevision: 3, operationID: UUID())
        XCTAssertNotEqual(a, differentOp)
        XCTAssertEqual(a.eventKind, .tooEasySet)
    }

    /// flag 应用纯迁移：CAS 通过 → tooEasy 更新、revision+1；
    /// 原 flag 不被修改（值类型拷贝）。
    func testFlagApplyingCommandSuccess() {
        let unit = UUID()
        let flag = LearningUnitFlag(
            unitID: unit, tooEasy: false, revision: 7, updatedAtMs: 100)
        let command = TooEasyCommand(
            unitID: unit, value: true,
            expectedFlagRevision: 7, operationID: UUID())
        XCTAssertTrue(command.revisionMatches(current: flag))

        let next = flag.applying(command, updatedAtMs: 200)
        XCTAssertEqual(
            next,
            LearningUnitFlag(
                unitID: unit, tooEasy: true, revision: 8, updatedAtMs: 200))
        // 原值不变（不可变语义：写路径产出新行投影而非原地改）。
        XCTAssertEqual(flag.tooEasy, false)
        XCTAssertEqual(flag.revision, 7)
    }

    /// CAS 冲突（跨窗口 revision 漂移 / 错 unit）→ nil，不覆盖。
    func testFlagApplyingCommandRevisionConflict() {
        let unit = UUID()
        let flag = LearningUnitFlag(
            unitID: unit, tooEasy: true, revision: 8, updatedAtMs: 200)
        // 期望旧版本 7（另一个窗口已先写）。
        let stale = TooEasyCommand(
            unitID: unit, value: false,
            expectedFlagRevision: 7, operationID: UUID())
        XCTAssertFalse(stale.revisionMatches(current: flag))
        XCTAssertNil(flag.applying(stale, updatedAtMs: 300))

        // 错 unit 直接拒绝。
        let wrongUnit = TooEasyCommand(
            unitID: UUID(), value: false,
            expectedFlagRevision: 8, operationID: UUID())
        XCTAssertNil(flag.applying(wrongUnit, updatedAtMs: 300))
        XCTAssertEqual(flag.revision, 8)
    }

    /// Undo 凭 beforeValue + afterRevision CAS 还原（§12.3）：
    /// flag 仍停在原操作版本 → 恢复 beforeValue 且 revision+1。
    func testUndoCommandRestoresBeforeValue() {
        let unit = UUID()
        let flag = LearningUnitFlag(
            unitID: unit, tooEasy: true, revision: 8, updatedAtMs: 200)
        let undo = TooEasyUndoCommand(
            unitID: unit, eventID: UUID(),
            beforeValue: false,
            expectedFlagRevision: 8, operationID: UUID())
        XCTAssertTrue(undo.revisionMatches(current: flag))
        XCTAssertEqual(undo.eventKind, .tooEasyUndone)

        let restored = flag.applyingUndo(undo, updatedAtMs: 400)
        XCTAssertEqual(
            restored,
            LearningUnitFlag(
                unitID: unit, tooEasy: false, revision: 9, updatedAtMs: 400))
    }

    /// Undo 时另一窗口已写过新 revision → nil，不覆盖新设置。
    func testUndoCommandRevisionConflict() {
        let unit = UUID()
        let flag = LearningUnitFlag(
            unitID: unit, tooEasy: false, revision: 9, updatedAtMs: 500)
        let undo = TooEasyUndoCommand(
            unitID: unit, eventID: UUID(),
            beforeValue: false,
            expectedFlagRevision: 8, operationID: UUID())
        XCTAssertFalse(undo.revisionMatches(current: flag))
        XCTAssertNil(flag.applyingUndo(undo, updatedAtMs: 600))
        XCTAssertEqual(flag.tooEasy, false)
    }

    // MARK: - 调度资格矩阵（§2.3 唯一规则）

    /// 三方向 × enabled × tooEasy 全组合：
    /// eligible = isEnabled AND NOT (vocab 三方向 AND tooEasy)。
    func testScheduledEligibilityMatrixThreeDirections() {
        let directions: [CardTemplateKind] = [
            .vocabularyJapaneseToChinese,
            .vocabularyChineseToJapanese,
            .vocabularyListening,
        ]
        XCTAssertEqual(
            SchedulingEligibility.vocabularyTemplateKinds, Set(directions))

        for kind in directions {
            // 未标 tooEasy：仅由 isEnabled 决定。
            XCTAssertTrue(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: true, unitTooEasy: false))
            XCTAssertFalse(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: false, unitTooEasy: false))
            // tooEasy：启用也排除。
            XCTAssertFalse(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: true, unitTooEasy: true))
            XCTAssertFalse(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: false, unitTooEasy: true))
        }
    }

    /// Cloze/Grammar 不受 tooEasy 影响：只看 isEnabled（§2.3）。
    func testClozeAndGrammarUnaffectedByTooEasy() {
        for kind in [CardTemplateKind.sentenceCloze,
                     .grammarFormToExplanation] {
            XCTAssertTrue(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: true, unitTooEasy: true))
            XCTAssertTrue(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: true, unitTooEasy: false))
            XCTAssertFalse(SchedulingEligibility.isScheduledEligible(
                templateKind: kind, isEnabled: false, unitTooEasy: true))
        }
    }

    /// D15：scheduled 强制排除 tooEasy（includeMastered 也无效）；
    /// practiceOnly 默认排除、显式 includeMastered 纳入。
    func testPracticeOnlyInclusionSemantics() {
        // scheduled：恒排除。
        XCTAssertFalse(SchedulingEligibility.isPracticeEligible(
            mode: .scheduled, includeMastered: false))
        XCTAssertFalse(SchedulingEligibility.isPracticeEligible(
            mode: .scheduled, includeMastered: true))
        // practiceOnly：由 includeMastered 决定。
        XCTAssertFalse(SchedulingEligibility.isPracticeEligible(
            mode: .practiceOnly, includeMastered: false))
        XCTAssertTrue(SchedulingEligibility.isPracticeEligible(
            mode: .practiceOnly, includeMastered: true))
    }

    /// 会话模式完整资格：tooEasy 词汇卡按 D15，其余卡不受 flag
    /// 影响；scheduled 模式下等价于 isScheduledEligible。
    func testSessionEligibilityCombinesModeAndFlag() {
        let vocab = CardTemplateKind.vocabularyListening

        // scheduled + tooEasy：includeMastered 不救命。
        XCTAssertFalse(SchedulingEligibility.isEligible(
            templateKind: vocab, isEnabled: true, unitTooEasy: true,
            mode: .scheduled, includeMastered: true))
        // practiceOnly + tooEasy：默认排除、显式纳入。
        XCTAssertFalse(SchedulingEligibility.isEligible(
            templateKind: vocab, isEnabled: true, unitTooEasy: true,
            mode: .practiceOnly, includeMastered: false))
        XCTAssertTrue(SchedulingEligibility.isEligible(
            templateKind: vocab, isEnabled: true, unitTooEasy: true,
            mode: .practiceOnly, includeMastered: true))
        // tooEasy 但卡被用户停用：任何模式都不进（isEnabled 先行）。
        XCTAssertFalse(SchedulingEligibility.isEligible(
            templateKind: vocab, isEnabled: false, unitTooEasy: true,
            mode: .practiceOnly, includeMastered: true))
        // 非 tooEasy 词汇卡与 Cloze 卡不受 flag 影响。
        XCTAssertTrue(SchedulingEligibility.isEligible(
            templateKind: vocab, isEnabled: true, unitTooEasy: false,
            mode: .scheduled, includeMastered: false))
        XCTAssertTrue(SchedulingEligibility.isEligible(
            templateKind: .sentenceCloze, isEnabled: true,
            unitTooEasy: true,
            mode: .scheduled, includeMastered: false))
    }

    /// scheduled 模式下 `isEligible` 与 `isScheduledEligible` 恒等
    /// （全枚举空间对拍，防止两个入口口径漂移）。
    func testScheduledModeEligibilityMatchesScheduledRule() {
        for kind in CardTemplateKind.allCases {
            for enabled in [true, false] {
                for tooEasy in [true, false] {
                    for includeMastered in [true, false] {
                        XCTAssertEqual(
                            SchedulingEligibility.isEligible(
                                templateKind: kind, isEnabled: enabled,
                                unitTooEasy: tooEasy,
                                mode: .scheduled,
                                includeMastered: includeMastered),
                            SchedulingEligibility.isScheduledEligible(
                                templateKind: kind, isEnabled: enabled,
                                unitTooEasy: tooEasy),
                            "\(kind) enabled=\(enabled) tooEasy=\(tooEasy)")
                    }
                }
            }
        }
    }

    // MARK: - 事件值类型

    /// `learning_unit_events` 投影：unit 删除 SET NULL 后
    /// unitIDSnapshot 仍留史（§6）。
    func testEventSnapshotSurvivesUnitDelete() {
        let unit = UUID()
        let event = LearningUnitEvent(
            id: UUID(), unitID: nil, unitIDSnapshot: unit,
            kind: .tooEasySet, operationID: UUID(),
            payloadHash: "abc", occurredAtMs: 1_000)
        XCTAssertNil(event.unitID)
        XCTAssertEqual(event.unitIDSnapshot, unit)
        XCTAssertEqual(event.kind, .tooEasySet)
    }
}
