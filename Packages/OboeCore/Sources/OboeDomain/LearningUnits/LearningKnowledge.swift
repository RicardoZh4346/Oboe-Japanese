import Foundation

/// v0.7.5 S07（角色 C 纯函数部分）：Learning Unit 三态知识状态、
/// Too Easy 命令/撤销值类型与调度资格纯函数。
/// 依据：contracts-frozen §2、decisions D04/D13/D15、技术文档 §12。
///
/// 本文件只有纯函数与值类型——不 import GRDB/网络/SwiftUI；事件
/// 落库、事务与 receipt 由仓储层（S08 起）按这些值执行。
///
/// 与旧 `VocabularyKnowledgeState`（known/ignored/learning/unknown）
/// 并存不替换：旧 enum 保留仅供 v8 解码与审计（D19），运行态一律
/// 走本文件的三态。

// MARK: - 三态（contracts §2.1）

/// Learning Unit 的运行态知识状态：
/// `unknown | learning | mastered`。
///
/// FSRS stability 不参与判定；OOV/未消歧 occurrence 在 UI 显示
/// unknown + 「待确认」标记，不是第四种状态。
public enum LearningKnowledgeState: String, Codable, CaseIterable, Sendable {
    case unknown
    case learning
    case mastered
}

/// 三态真值表的唯一实现点（contracts §2.1、技术文档 §12.1）：
/// `tooEasy → mastered`；否则任一有效词汇 Note 关联 → `learning`；
/// 否则 → `unknown`。仓储与 UI 共用，不允许第二份判定逻辑。
public enum LearningKnowledgeResolver {
    public static func state(
        tooEasy: Bool,
        hasVocabularyNoteLink: Bool
    ) -> LearningKnowledgeState {
        if tooEasy { return .mastered }
        return hasVocabularyNoteLink ? .learning : .unknown
    }
}

// MARK: - flag / 事件 值类型（contracts §6 v23 行投影）

/// `learning_unit_flags` 行投影：PK unit_id；`revision` 每次写入 +1
/// 作乐观并发版本（CAS）；时间为毫秒整数（contracts 通用约束）。
/// 无 Note 的 unit 同样允许有 flag 行（§2.2）。
public struct LearningUnitFlag: Codable, Equatable, Sendable {
    public let unitID: UUID
    public let tooEasy: Bool
    public let revision: Int64
    public let updatedAtMs: Int64

    public init(
        unitID: UUID,
        tooEasy: Bool,
        revision: Int64,
        updatedAtMs: Int64
    ) {
        self.unitID = unitID
        self.tooEasy = tooEasy
        self.revision = revision
        self.updatedAtMs = updatedAtMs
    }

    /// 应用 `SetLearningUnitTooEasy` 的纯迁移：unitID 与
    /// `expectedFlagRevision` 相符 → `revision + 1` 的新 flag；
    /// 不符 → nil（调用方按冲突错误处理，绝不覆盖，§2.2）。
    /// 本函数不写 ReviewLog、不动 stability/due/firstStudiedAt、
    /// 不批量改 cards.is_enabled——副作用都在命令事务层。
    public func applying(
        _ command: TooEasyCommand,
        updatedAtMs: Int64
    ) -> LearningUnitFlag? {
        guard command.unitID == unitID,
              command.expectedFlagRevision == revision
        else { return nil }
        return LearningUnitFlag(
            unitID: unitID,
            tooEasy: command.value,
            revision: revision + 1,
            updatedAtMs: updatedAtMs
        )
    }

    /// 应用 Too Easy 撤销的纯迁移：flag 仍是原操作产生的版本
    /// （`expectedFlagRevision` = 原操作 afterRevision）才还原为
    /// `beforeValue`；否则 nil——不覆盖另一窗口的新设置（§12.3）。
    public func applyingUndo(
        _ command: TooEasyUndoCommand,
        updatedAtMs: Int64
    ) -> LearningUnitFlag? {
        guard command.unitID == unitID,
              command.expectedFlagRevision == revision
        else { return nil }
        return LearningUnitFlag(
            unitID: unitID,
            tooEasy: command.beforeValue,
            revision: revision + 1,
            updatedAtMs: updatedAtMs
        )
    }
}

/// `learning_unit_events.kind`（contracts §6 v23）：审计事件最小集。
public enum LearningUnitEventKind: String, Codable, CaseIterable, Sendable {
    /// unit 创建（含导入重建的出生事件）。
    case created
    /// v0.7.5 迁移回填产生的 unit（D03/D04）；迁移证据另存
    /// `learning_unit_migration_items`，不参与运行态。
    case migrated
    /// tooEasy 被设置/清除（value 见 payload）。
    case tooEasySet
    /// Too Easy 撤销——独立事件，不复用 FSRS review undo（§12.3）。
    case tooEasyUndone
    /// Note→unit 关联建立（primary/legacy_secondary 角色见 payload）。
    case noteLinked
    /// Note→unit 关联解除。
    case noteUnlinked
}

/// `learning_unit_events` 行投影（§6）：审计留史。
/// unit 删除后 `unitID` SET NULL，`unitIDSnapshot` 永不为空留史。
public struct LearningUnitEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let unitID: UUID?
    public let unitIDSnapshot: UUID
    public let kind: LearningUnitEventKind
    /// 幂等键 UNIQUE——同 operationID 重放不产生第二行（§4.3）。
    public let operationID: UUID
    /// 事件负载 hash（§6 payload_hash），审计对账用。
    public let payloadHash: String?
    /// 毫秒整数时间。
    public let occurredAtMs: Int64

    public init(
        id: UUID,
        unitID: UUID?,
        unitIDSnapshot: UUID,
        kind: LearningUnitEventKind,
        operationID: UUID,
        payloadHash: String?,
        occurredAtMs: Int64
    ) {
        self.id = id
        self.unitID = unitID
        self.unitIDSnapshot = unitIDSnapshot
        self.kind = kind
        self.operationID = operationID
        self.payloadHash = payloadHash
        self.occurredAtMs = occurredAtMs
    }
}

// MARK: - Too Easy 命令（contracts §2.2、技术文档 §12.3）

/// `SetLearningUnitTooEasy(unitID, value, expectedFlagRevision,
/// operationID)`——不可变命令值类型，纯值不含 db。
///
/// 事务语义（由仓储层执行）：写 `learning_unit_flags`（too_easy、
/// revision+1）+ `learning_unit_events` + receipt；禁止写
/// ReviewLog、改 stability/due/firstStudiedAt、批量改
/// cards.is_enabled。
public struct TooEasyCommand: Equatable, Sendable {
    public let unitID: UUID
    public let value: Bool
    /// CAS：必须等于 `learning_unit_flags.revision` 当前值；
    /// 不符 → 冲突错误，不覆盖。
    public let expectedFlagRevision: Int64
    /// 幂等键：同 ID 同 payload 重放返回历史 receipt；同 ID
    /// 不同 payload 必须拒绝（§4.3 幂等三层）。
    public let operationID: UUID

    public init(
        unitID: UUID,
        value: Bool,
        expectedFlagRevision: Int64,
        operationID: UUID
    ) {
        self.unitID = unitID
        self.value = value
        self.expectedFlagRevision = expectedFlagRevision
        self.operationID = operationID
    }

    /// 本命令落库时产生的 unit event 种类。
    public var eventKind: LearningUnitEventKind { .tooEasySet }

    /// CAS 预检：当前 flag 属于该 unit 且 revision 相符。
    public func revisionMatches(current flag: LearningUnitFlag) -> Bool {
        flag.unitID == unitID && flag.revision == expectedFlagRevision
    }
}

/// Too Easy 撤销命令（§2.2/§12.3）：独立命令，凭 `eventID` +
/// before/after revision 作 CAS——只有 flag 仍是本操作产生的版本
/// 才还原，防止覆盖另一个窗口的新设置。
///
/// Undo 不调用 FSRS review undo；撤销命令自身的 `operationID`
/// 不复用原操作的 operationID。
public struct TooEasyUndoCommand: Equatable, Sendable {
    public let unitID: UUID
    /// 触发本次 tooEasy 变更的 `learning_unit_events.id`。
    public let eventID: UUID
    /// 原操作前的 tooEasy 值——撤销恢复目标。
    public let beforeValue: Bool
    /// CAS：必须等于 `learning_unit_flags.revision` 当前值（即原
    /// 操作的 afterRevision）。
    public let expectedFlagRevision: Int64
    /// 撤销命令自身的幂等键。
    public let operationID: UUID

    public init(
        unitID: UUID,
        eventID: UUID,
        beforeValue: Bool,
        expectedFlagRevision: Int64,
        operationID: UUID
    ) {
        self.unitID = unitID
        self.eventID = eventID
        self.beforeValue = beforeValue
        self.expectedFlagRevision = expectedFlagRevision
        self.operationID = operationID
    }

    /// 本命令落库时产生的 unit event 种类。
    public var eventKind: LearningUnitEventKind { .tooEasyUndone }

    /// CAS 预检：flag 仍停在原操作产生的版本。
    public func revisionMatches(current flag: LearningUnitFlag) -> Bool {
        flag.unitID == unitID && flag.revision == expectedFlagRevision
    }
}

// MARK: - 调度资格（contracts §2.3、技术文档 §12.2、D15）

/// 调度资格唯一规则的纯函数实现——读路径（Today/Deck/Custom
/// 构建与计数、新词预约）与写路径（commitReview 事务内复核、
/// frozen queue 恢复复核）必须共用本入口，不允许第二份实现。
///
/// Too Easy 不实现成批量 `is_enabled = 0`：停用状态属于用户
/// 原本的卡方向管理，与 flag 正交（§12.2）。
public enum SchedulingEligibility {
    /// 受 tooEasy flag 影响的 vocabulary 三方向模板（冻结集合）：
    /// `vocabularyJapaneseToChinese`、`vocabularyChineseToJapanese`、
    /// `vocabularyListening`。`sentenceCloze` 与
    /// `grammarFormToExplanation` 不在其中，不受影响。
    public static let vocabularyTemplateKinds: Set<CardTemplateKind> = [
        .vocabularyJapaneseToChinese,
        .vocabularyChineseToJapanese,
        .vocabularyListening,
    ]

    /// `scheduledEligible(card) =
    ///   card.isEnabled
    ///   AND NOT (card.templateKind ∈ vocabulary 三方向
    ///            AND card.note.unit.tooEasy)`（contracts §2.3）。
    ///
    /// - Parameter unitTooEasy: `card.note` 所属 unit 的 flag。
    ///   非三方向模板忽略该参数（Cloze/Grammar 恒按 isEnabled 判定）。
    public static func isScheduledEligible(
        templateKind: CardTemplateKind,
        isEnabled: Bool,
        unitTooEasy: Bool
    ) -> Bool {
        isEnabled
            && !(vocabularyTemplateKinds.contains(templateKind) && unitTooEasy)
    }

    /// tooEasy unit 的词汇卡在指定会话模式下的资格（D15）：
    /// - `scheduled`：强制排除——恒 false（includeMastered 不适用）。
    /// - `practiceOnly`：默认排除；显式 `includeMastered` 才纳入，
    ///   纳入后仍只写 practice_attempts，不改 FSRS。
    ///
    /// 非 tooEasy 卡与非三方向卡不经本判定（见 `isEligible`）。
    public static func isPracticeEligible(
        mode: CustomStudyMode,
        includeMastered: Bool
    ) -> Bool {
        switch mode {
        case .scheduled: false
        case .practiceOnly: includeMastered
        }
    }

    /// 会话模式下的完整卡片资格：
    /// `isEnabled && (非受影响卡 || isPracticeEligible 放行)`。
    ///
    /// Custom build/count/frozen queue 恢复、scheduled 模式提交复核
    /// 共用；打开既有 session 与提交时按同一入口复核（D15）。
    /// `mode == .scheduled` 时等价于 `isScheduledEligible`
    /// （includeMastered 被忽略）。
    public static func isEligible(
        templateKind: CardTemplateKind,
        isEnabled: Bool,
        unitTooEasy: Bool,
        mode: CustomStudyMode,
        includeMastered: Bool
    ) -> Bool {
        guard isEnabled else { return false }
        guard vocabularyTemplateKinds.contains(templateKind), unitTooEasy
        else { return true }
        return isPracticeEligible(mode: mode, includeMastered: includeMastered)
    }
}
