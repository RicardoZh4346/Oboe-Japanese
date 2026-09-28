import Foundation

/// S08 增补协议（不动 S02 冻结的 `VocabularyKnowledgeRepository`）：
/// 「加入学习」原子提交与关联查询。GRDB 实现在同一事务里
/// 清 override + 建关联（§6.3：用户在 known/ignored 上加入学习需
/// 同一事务执行）；非原子的仓储实现只须满足冻结协议即可，
/// `VocabularyKnowledgeService` 对无能力实现退化为顺序调用并在
/// 文档中标注非原子。
public protocol VocabularyKnowledgeLinking: Sendable {
    /// 同事务清除 override 并建立关联；返回操作 receipt UUID。
    @discardableResult
    func addToLearning(
        lexemeID: UUID,
        noteID: UUID,
        origin: LexemeNoteLink.AssociationOrigin,
        at date: Date
    ) async throws -> UUID

    /// 某 Note 当前的全部关联（改选 UI / 审计）。
    func linksForNote(noteID: UUID) async throws -> [LexemeNoteLink]

    /// 某 lexeme 当前关联的全部 Note id。
    func linkedNoteIDs(lexemeID: UUID) async throws -> [UUID]

    /// 按 operation_id 查知识域 receipt（`reader_mining_receipts` 行）。
    func knowledgeReceipt(operationID: UUID) async throws -> KnowledgeOperationReceipt?
}

/// `reader_mining_receipts` 行的领域投影（操作级幂等凭据）。
public struct KnowledgeOperationReceipt: Equatable, Sendable {
    public let operationID: UUID
    /// 操作类别（knowledge_override / knowledge_link / …，见仓储）。
    public let kind: String
    /// 操作负载的稳定 hash——同 operationID 不同负载即冲突。
    public let payloadHash: String
    /// JSON 结果快照（事件 id / 前置状态 / 影响计数）。
    public let resultJSON: String
    public let committedAt: Date

    public init(
        operationID: UUID,
        kind: String,
        payloadHash: String,
        resultJSON: String,
        committedAt: Date
    ) {
        self.operationID = operationID
        self.kind = kind
        self.payloadHash = payloadHash
        self.resultJSON = resultJSON
        self.committedAt = committedAt
    }
}

/// 知识写路径错误。
public enum VocabularyKnowledgeError: Error, Equatable, Sendable {
    /// setOverride/link 目标的 lexeme 行不存在。
    case lexemeNotFound(UUID)
    /// linkNote 目标的 Note 不存在（FK 前置校验，给调用方清晰错误）。
    case noteNotFound(UUID)
    /// 同一 operationID 携带不同负载重放——调用方不得复用 receipt。
    case operationPayloadConflict(UUID)
    /// 存储行解码失败（provider/status 等枚举值不在冻结集合）。
    case inconsistentStorage(String)
}

/// 覆盖率/渲染缓存的失效信号（S09 绑定 generation + 该 revision）。
/// 每次知识写（override 变更、关联增删）服务层 bump 一次；S09
/// 的按块状态缓存把 revision 编入缓存键，变化即整块失效。
public actor KnowledgeInvalidationCenter {
    public private(set) var revision: UInt64 = 0
    private var perLexemeRevisions: [UUID: UInt64] = [:]

    public init() {}

    public func invalidate(lexemeID: UUID?) {
        revision &+= 1
        if let lexemeID {
            perLexemeRevisions[lexemeID, default: 0] &+= 1
        }
    }

    /// 指定 lexeme 的写次数；nil 语义上等同全局 revision。
    public func lexemeRevision(_ lexemeID: UUID) -> UInt64 {
        perLexemeRevisions[lexemeID] ?? 0
    }
}

/// S08 知识状态域服务（D05 真值表的唯一编排点）：
/// - 读：`state(of:)` / `states(of:)` 按冻结协议走仓储，未入库的
///   key 一律 unknown——查询路径绝不创建 lexeme 行；
/// - 写：known/ignored/reset → `setOverride`，关联确认/改选 →
///   `linkNote`/`unlinkNote` + `resolveLexeme`；
/// - 「加入学习」优先走 `VocabularyKnowledgeLinking.addToLearning`
///   原子路径；
/// - 每次成功写后向 `KnowledgeInvalidationCenter` 发失效信号。
public struct VocabularyKnowledgeService: Sendable {
    private let repository: any VocabularyKnowledgeRepository
    private let linking: (any VocabularyKnowledgeLinking)?
    private let invalidation: KnowledgeInvalidationCenter
    private let now: @Sendable () -> Date

    public init(
        repository: any VocabularyKnowledgeRepository,
        linking: (any VocabularyKnowledgeLinking)? = nil,
        invalidation: KnowledgeInvalidationCenter = KnowledgeInvalidationCenter(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.linking = linking
        self.invalidation = invalidation
        self.now = now
    }

    /// 状态查询：lexeme 未落库 → unknown（不写任何行）。
    public func state(of key: LexicalKey) async throws -> VocabularyKnowledgeState {
        guard let lexeme = try await repository.fetchLexeme(key: key) else {
            return .unknown
        }
        return try await repository.state(lexemeID: lexeme.id)
    }

    /// 批量状态（S09 覆盖率路径）：一次 `resolveLexemes` + 每命中
    /// 行的 state——仓储实现侧已批量，单 key 未命中计 unknown。
    public func states(
        of keys: [LexicalKey]
    ) async throws -> [LexicalKey: VocabularyKnowledgeState] {
        let lexemes = try await repository.resolveLexemes(keys: keys)
        var result: [LexicalKey: VocabularyKnowledgeState] = [:]
        result.reserveCapacity(keys.count)
        for key in keys {
            guard let lexeme = lexemes[key] else {
                result[key] = .unknown
                continue
            }
            result[key] = try await repository.state(lexemeID: lexeme.id)
        }
        return result
    }

    /// 标为已知。重复调用返回同一 receipt、不新增事件。
    @discardableResult
    public func markKnown(lexemeID: UUID) async throws -> UUID {
        let receipt = try await repository.setOverride(
            lexemeID: lexemeID, override: .known, at: now())
        await invalidation.invalidate(lexemeID: lexemeID)
        return receipt
    }

    /// 标为忽略（不计入覆盖率分母）。
    @discardableResult
    public func markIgnored(lexemeID: UUID) async throws -> UUID {
        let receipt = try await repository.setOverride(
            lexemeID: lexemeID, override: .ignored, at: now())
        await invalidation.invalidate(lexemeID: lexemeID)
        return receipt
    }

    /// 重置人工状态：删除 override 行，由关联重判回 learning/unknown。
    @discardableResult
    public func resetKnowledge(lexemeID: UUID) async throws -> UUID {
        let receipt = try await repository.setOverride(
            lexemeID: lexemeID, override: nil, at: now())
        await invalidation.invalidate(lexemeID: lexemeID)
        return receipt
    }

    /// 歧义确认 / 改选：确保目标 lexeme 存在（`seed` 提供行内容），
    /// 对该 Note 建 `userConfirmed` 关联；`unlinking` 给出要移除的
    /// 旧关联（改选语义——例如从 local 占位 lexeme 改到词典条目）。
    @discardableResult
    public func confirmAssociation(
        key: LexicalKey,
        seed: Lexeme,
        noteID: UUID,
        unlinking replacedLexemeID: UUID? = nil
    ) async throws -> Lexeme {
        let lexeme = try await repository.resolveLexeme(key: key, seed: seed)
        try await repository.linkNote(
            lexemeID: lexeme.id, noteID: noteID, origin: .userConfirmed)
        if let replacedLexemeID, replacedLexemeID != lexeme.id {
            try await repository.unlinkNote(
                lexemeID: replacedLexemeID, noteID: noteID)
            await invalidation.invalidate(lexemeID: replacedLexemeID)
        }
        await invalidation.invalidate(lexemeID: lexeme.id)
        return lexeme
    }

    /// 既有 lexeme 直接关联（挖词/导入路径共用入口）。
    public func linkNote(
        lexemeID: UUID,
        noteID: UUID,
        origin: LexemeNoteLink.AssociationOrigin
    ) async throws {
        try await repository.linkNote(
            lexemeID: lexemeID, noteID: noteID, origin: origin)
        await invalidation.invalidate(lexemeID: lexemeID)
    }

    /// 「加入学习」：清 override + 建关联必须同事务（§6.3）。
    /// 仓储未实现 `VocabularyKnowledgeLinking` 时退化为顺序调用——
    /// 顺序为先建关联后清 override，中途失败至多残留 known/ignored
    /// 显示，不会丢关联（文档化限制）。
    @discardableResult
    public func addToLearning(
        lexemeID: UUID,
        noteID: UUID,
        origin: LexemeNoteLink.AssociationOrigin = .userConfirmed
    ) async throws -> UUID {
        if let linking {
            let receipt = try await linking.addToLearning(
                lexemeID: lexemeID, noteID: noteID,
                origin: origin, at: now())
            await invalidation.invalidate(lexemeID: lexemeID)
            return receipt
        }
        try await repository.linkNote(
            lexemeID: lexemeID, noteID: noteID, origin: origin)
        let receipt = try await repository.setOverride(
            lexemeID: lexemeID, override: nil, at: now())
        await invalidation.invalidate(lexemeID: lexemeID)
        return receipt
    }

    /// 标记前的 lexeme 确保：OOV/未落库候选在 setOverride 前先 upsert
    ///（只建行——不写状态；后续 markKnown/markIgnored 再产事件）。
    public func ensureLexeme(
        key: LexicalKey, seed: Lexeme
    ) async throws -> Lexeme {
        try await repository.resolveLexeme(key: key, seed: seed)
    }

    /// 改选/加入学习前的预览：当前是否被 known/override 覆盖——
    /// UI 据此提示「加入学习将清除 已知/忽略 标记」。
    public func requiresOverrideReset(lexemeID: UUID) async throws -> Bool {
        switch try await repository.state(lexemeID: lexemeID) {
        case .known, .ignored: return true
        case .learning, .unknown: return false
        }
    }
}
