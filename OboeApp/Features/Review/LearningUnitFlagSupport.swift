import Foundation
import OboeDomain
import OboeInfrastructure

/// v0.7.5 S16：Too Easy UI 的共享支撑面。
///
/// 依赖通路说明：Review/Note 详情/Inspector 的构造点（TodayView、
/// DeckDetailView、ReaderView）与依赖装配文件不在本任务改件范围内，
/// 因此三个界面不新增初始化参数强行穿透——而是经各自既有服务上的
/// GRDB 仓储派生同 pool 的 `GRDBLearningUnitRepository` 门面
/// （`learningUnitFlags`）。派生值与容器 `shared.learningUnits`
/// 指向同一 DatabasePool，语义一致；测试可在 VM 初始化参数中直接
/// 注入内存桩件覆盖派生结果。

// MARK: - 可选能力协议

/// flags/links 变更观察口（§14.3：跨窗口刷新走共享数据观察，
/// 不只靠 onAppear）。独立于 `LearningUnitFlagProviding` 之外——
/// 测试桩件不实现时，消费方静默退化为无观察。
protocol LearningUnitFlagObserving: Sendable {
    /// `learning_unit_flags`/`learning_unit_note_links` 任一行变化
    /// 发出一次 Void ping；调用方重新解析自身上下文的 flag 状态。
    func observeChanges() -> AsyncThrowingStream<Void, Error>
}

/// unit → 全部同 unit 卡 id（复习会话 sibling 驱逐的一次性批量
/// 判定——避免对冻结队列逐卡载入）。
protocol LearningUnitCardMapping: Sendable {
    func fetchLinkedCardIDs(unitID: UUID) async throws -> Set<UUID>
}

extension GRDBLearningUnitRepository: LearningUnitFlagObserving {}
extension GRDBLearningUnitRepository: LearningUnitCardMapping {}

// MARK: - 服务派生通路

extension StudySessionService {
    /// Review 通路：`todayQueueRepository` 与 learning-unit 表同一
    /// DatabasePool——非 GRDB 实现（测试桩）返回 nil，UI 隐藏入口。
    var learningUnitFlags: (any LearningUnitFlagProviding)? {
        (todayQueueRepository as? GRDBTodayQueueRepository)?
            .learningUnitFlags
    }
}

extension VocabularyService {
    /// Note 详情通路：词汇仓储同 pool 派生。
    var learningUnitFlags: (any LearningUnitFlagProviding)? {
        (vocabularyRepository as? GRDBVocabularyRepository)?
            .learningUnitFlags
    }
}

extension ReaderMiningService {
    /// Inspector 通路：mining store 同 pool 派生。
    var learningUnitFlags: (any LearningUnitFlagProviding)? {
        (miningStore as? GRDBReaderMiningStore)?.learningUnitFlags
    }
}

// MARK: - 三态上下文

/// 一个已定位 unit 的展示上下文：flag + 是否有词汇 Note 关联 →
/// `LearningKnowledgeResolver` 真值表三态（§2.1 唯一实现点复用，
/// 不产生第二份判定）。
struct LearningUnitContext: Equatable, Sendable {
    let unit: LearningUnit
    let flag: LearningUnitFlag?
    let hasVocabularyLink: Bool

    var tooEasy: Bool { flag?.tooEasy ?? false }

    var knowledgeState: LearningKnowledgeState {
        LearningKnowledgeResolver.state(
            tooEasy: tooEasy,
            hasVocabularyNoteLink: hasVocabularyLink
        )
    }
}

// MARK: - 共享 flag 操作（CAS / Undo 锚点）

/// Review、Note 详情、Inspector 共用的 Too Easy 操作面——
/// `LearningUnitFlagProviding` 的薄封装，CAS 取期望/事件扫描/
/// 错误映射只有这一份实现。
struct LearningUnitFlagOperator: Sendable {

    /// Undo 凭据：本窗口产生的 tooEasySet 事件 + CAS 期望值。
    struct UndoAnchor: Equatable, Sendable {
        let unitID: UUID
        /// 原 tooEasySet 事件 id（`TooEasyUndoCommand.eventID`）。
        let eventID: UUID
        /// 撤销恢复值（事件 before_json 的 tooEasy；无 before 行 →
        /// false——首个 set 前 flag 不存在，等价 tooEasy=false）。
        let beforeValue: Bool
        /// 事件的 flag 后值 revision——撤销的 expectedFlagRevision。
        let afterRevision: Int64
    }

    /// `learning_unit_events.before/after_json` 的规范负载
    /// （仓储写入的 canonical `{"revision":N,"tooEasy":B}`）。
    private struct FlagSnapshotJSON: Codable {
        let revision: Int64
        let tooEasy: Bool
    }

    let flags: any LearningUnitFlagProviding

    /// noteID → 归属 unit（link 存在但 unit 缺失 → nil——
    /// Note 详情按「未关联」展示，绝不退化到 lemma 级动作）。
    func unit(forNoteID noteID: UUID) async throws -> LearningUnit? {
        guard let link = try await flags.fetchLink(noteID: noteID)
        else { return nil }
        return try await flags.fetchUnits(ids: [link.unitID])[link.unitID]
    }

    /// 一组 Note 归属的 distinct unitIDs——OOV/local 候选与
    /// 「已有 Note」路径的 unit 定位；多于一个 = 歧义，调用方拒绝。
    func unitIDs(linkedToNoteIDs noteIDs: [UUID]) async throws -> Set<UUID> {
        var result = Set<UUID>()
        for noteID in noteIDs {
            if let link = try await flags.fetchLink(noteID: noteID) {
                result.insert(link.unitID)
            }
        }
        return result
    }

    /// unit → 三态上下文（Inspector/详情页共用）。
    func context(for unit: LearningUnit) async throws -> LearningUnitContext {
        let flag = try await flags.fetchFlag(unitID: unit.id)
        let linked = try await flags.linkedVocabularyUnitIDs(
            unitIDs: [unit.id]
        )
        return LearningUnitContext(
            unit: unit,
            flag: flag,
            hasVocabularyLink: linked.contains(unit.id)
        )
    }

    /// noteID → 三态上下文（Note 详情用）。
    func context(forNoteID noteID: UUID) async throws -> LearningUnitContext? {
        guard let unit = try await unit(forNoteID: noteID) else { return nil }
        return try await context(for: unit)
    }

    /// CAS 置位/清除。`expectedFlagRevision` 由当前行读出——并发
    /// 窗口写入时抛 `flagRevisionConflict`，绝不覆盖。值已相符时是
    /// 幂等 no-op（不制造空转事件行）。
    @discardableResult
    func set(
        _ value: Bool,
        unitID: UUID,
        operationID: UUID,
        at date: Date = Date()
    ) async throws -> LearningUnitFlag {
        let current = try await flags.fetchFlag(unitID: unitID)
        if (current?.tooEasy ?? false) == value {
            return current ?? LearningUnitFlag(
                unitID: unitID, tooEasy: value,
                revision: 0, updatedAtMs: 0
            )
        }
        return try await flags.setFlagTooEasy(
            TooEasyCommand(
                unitID: unitID,
                value: value,
                expectedFlagRevision: current?.revision ?? 0,
                operationID: operationID
            ),
            at: date
        )
    }

    /// 撤销锚点：该 unit 最近一条**未撤销**的 tooEasySet 事件；
    /// 且当前 flag 必须仍停在该事件的 after 版本（revision 与值都
    /// 相等）——任一不符即另一窗口/界面已改动，返回 nil 不覆盖。
    func undoAnchor(unitID: UUID) async throws -> UndoAnchor? {
        let events = try await flags.fetchEvents(unitID: unitID)
        guard let event = events
            .filter({ $0.kind == .tooEasySet && $0.undoneAtMs == nil })
            .last,
            let afterJSON = event.afterJSON,
            let after = Self.decodeSnapshot(afterJSON)
        else { return nil }
        let beforeValue = event.beforeJSON
            .flatMap(Self.decodeSnapshot)?.tooEasy ?? false
        guard let flag = try await flags.fetchFlag(unitID: unitID),
              flag.revision == after.revision,
              flag.tooEasy == after.tooEasy
        else { return nil }
        return UndoAnchor(
            unitID: unitID,
            eventID: event.id,
            beforeValue: beforeValue,
            afterRevision: after.revision
        )
    }

    /// 凭锚点撤销——仓储事务内再复核 eventID 未撤销 +
    /// `expectedFlagRevision` 相符，迟到/过期锚点安全失败。
    @discardableResult
    func undo(
        _ anchor: UndoAnchor,
        operationID: UUID = UUID(),
        at date: Date = Date()
    ) async throws -> LearningUnitFlag {
        try await flags.undoTooEasy(
            TooEasyUndoCommand(
                unitID: anchor.unitID,
                eventID: anchor.eventID,
                beforeValue: anchor.beforeValue,
                expectedFlagRevision: anchor.afterRevision,
                operationID: operationID
            ),
            at: date
        )
    }

    private static func decodeSnapshot(_ json: String) -> FlagSnapshotJSON? {
        try? JSONDecoder().decode(
            FlagSnapshotJSON.self, from: Data(json.utf8)
        )
    }

    /// 结构化错误 → UI 文案（三界面统一措辞）。
    static func message(for error: Error) -> String {
        guard let error = error as? LearningUnitRepositoryError else {
            return "操作失败：\(error.localizedDescription)。请重试。"
        }
        return switch error {
        case .flagRevisionConflict:
            "标记状态已在其他位置变更，请查看最新状态后重试。"
        case .unitNotFound:
            "该学习单元已不存在。"
        case .noteNotFound:
            "该笔记已不存在。"
        case .noteNotVocabulary:
            "只有词汇笔记可以标记太简单。"
        case .noteAlreadyLinked:
            "该笔记已关联到其他学习单元。"
        case .primaryLinkConflict:
            "该学习单元已有主关联笔记，不能自动抢占。"
        case .noLegacySecondaryToPromote:
            "没有可提升的次级关联。"
        case .operationPayloadConflict:
            "操作回放冲突——请勿重复提交不同内容。"
        case .eventNotFound, .eventAlreadyUndone:
            "这次标记已不存在或已被撤销。"
        case .invalidUnitIdentity, .inconsistentStorage:
            "学习单元数据异常，无法操作。"
        }
    }
}
