import Foundation

/// v0.7.5 S04 工作包：Learning Unit 仓储行模型（`v23_learning_units`
/// 六张表的值投影）。
///
/// 依据：contracts-frozen rev2 §1（身份/key/状态枚举）、§6 v23 表冻结
/// 清单；技术文档 §3/§4；decisions D01/D02/D18/D20。
///
/// 复用（不重定义）：
/// - `LearningUnitDictionaryAlias` — `SemanticFingerprint.swift`（S02-A）。
/// - `LearningUnitFlag` / `LearningUnitEvent` / `LearningUnitEventKind` /
///   `TooEasyCommand` / `TooEasyUndoCommand` — `LearningKnowledge.swift`
///   （S07 纯领域，本文件复用其值类型作为 flags/events 行的领域投影）。
///
/// 本文件补充：unit/link/migration 行模型、事件**全列**记录
/// （含 before/after/undone 审计列，领域 `LearningUnitEvent` 不含）、
/// 各枚举的冻结取值与仓储结构化错误。
///
/// 纯值类型——不 import GRDB。

// MARK: - lexical_learning_units（§6 v23）

/// `identity_kind`（§1.1 身份三层）。
public enum LearningUnitIdentityKind: String, Codable, CaseIterable, Sendable {
    /// 词典义项 unit——identityKey =
    /// `jmdict:sense-v1:<entryID>:<semanticFingerprint>`。
    case dictionarySense
    /// 手动创建、无可靠义项的 Note → `local-note:<noteUUID 小写>`。
    case localNote
    /// 回填期临时投影：`legacy-note:<noteUUID>` / `legacy-key:<key>`。
    case legacyUnresolved
}

/// `binding_status`（§6）：unit 与当前词典快照的绑定态。
public enum LearningUnitBindingStatus: String, Codable, CaseIterable, Sendable {
    /// dictionarySense 且绑定当前快照存在行。
    case current
    /// 歧义/待人工确认（如同 entry 不可区分重复指纹的隔离 key）。
    case needsConfirmation
    /// 义项在快照中消失——保留引用待重绑，不静默换绑。
    case stale
    /// localNote/legacyUnresolved unit——不指向词典快照。
    case legacy
}

/// `lexical_learning_units` 行投影：学习数据的永久身份载体。
/// `id` 备份恢复保留、永不复用；`sense_snapshot_json` 只含有界义项快照
/// （不含正文/Prompt——v9 wire §2.3）。
public struct LearningUnit: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let identityKind: LearningUnitIdentityKind
    /// 全库唯一稳定键（§1.1），冲突即同义项。
    public let identityKey: String
    public let provider: String?
    public let dictionaryEntryID: Int64?
    public let semanticFingerprint: String?
    public let fingerprintVersion: String?
    /// 展示/候选校验用，不进主键。
    public let lemma: String
    public let reading: String?
    /// 有界义项快照（建表 CHECK json_valid + 长度上限）。
    public let senseSnapshotJSON: String?
    public let bindingStatus: LearningUnitBindingStatus
    /// 乐观并发版本（CAS），每次 mutation +1。
    public let revision: Int64
    public let createdAtMs: Int64
    public let updatedAtMs: Int64

    public init(
        id: UUID,
        identityKind: LearningUnitIdentityKind,
        identityKey: String,
        provider: String? = nil,
        dictionaryEntryID: Int64? = nil,
        semanticFingerprint: String? = nil,
        fingerprintVersion: String? = nil,
        lemma: String,
        reading: String? = nil,
        senseSnapshotJSON: String? = nil,
        bindingStatus: LearningUnitBindingStatus,
        revision: Int64 = 0,
        createdAtMs: Int64,
        updatedAtMs: Int64
    ) {
        self.id = id
        self.identityKind = identityKind
        self.identityKey = identityKey
        self.provider = provider
        self.dictionaryEntryID = dictionaryEntryID
        self.semanticFingerprint = semanticFingerprint
        self.fingerprintVersion = fingerprintVersion
        self.lemma = lemma
        self.reading = reading
        self.senseSnapshotJSON = senseSnapshotJSON
        self.bindingStatus = bindingStatus
        self.revision = revision
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }
}

// MARK: - learning_unit_note_links（§6 v23）

/// `role`（契约冻结原文 snake_case）：一 unit 至多一 `primary`
/// （部分唯一索引），可保留多条 `legacySecondary`。
public enum LearningUnitNoteLinkRole: String, Codable, CaseIterable, Sendable {
    case primary
    case legacySecondary = "legacy_secondary"
}

/// `origin`——关联建立来源。取值沿用 `lexeme_note_links.association_origin`
/// 的冻结词汇并补 v0.7.5 两条新通路（contract §6 只要求 enum CHECK，
/// 值集待 M 复核确认）：
/// `manual`（手建词汇 Note）、`automaticHighConfidence`（已验证唯一义项
/// 自动绑定）、`userConfirmed`（用户确认）、`aiPipeline`（AI 制卡应用
/// 事务）、`backfill`（S05 存量回填）、`imported`（CSV/JLPT/备份恢复）。
public enum LearningUnitNoteLinkOrigin: String, Codable, CaseIterable, Sendable {
    case manual
    case automaticHighConfidence
    case userConfirmed
    case aiPipeline
    case backfill
    case imported
}

/// `learning_unit_note_links` 行投影：`note_id` 全表唯一
/// （一 Note 仅一有效 unit），PK(unit_id,note_id)。
public struct LearningUnitNoteLink: Codable, Equatable, Sendable {
    public let unitID: UUID
    public let noteID: UUID
    public let role: LearningUnitNoteLinkRole
    public let origin: LearningUnitNoteLinkOrigin
    public let createdAtMs: Int64

    public init(
        unitID: UUID,
        noteID: UUID,
        role: LearningUnitNoteLinkRole,
        origin: LearningUnitNoteLinkOrigin,
        createdAtMs: Int64
    ) {
        self.unitID = unitID
        self.noteID = noteID
        self.role = role
        self.origin = origin
        self.createdAtMs = createdAtMs
    }
}

// MARK: - learning_unit_events 全列记录（§6 v23）

/// `learning_unit_events` **全列**行投影——在领域
/// `LearningUnitEvent`（LearningKnowledge.swift，S07）之外补齐
/// `before_json`/`after_json`/`undone_at_ms` 审计列，供落库与
/// Undo/对账读取。`kind` 直接复用 `LearningUnitEventKind`（编码值
/// 与建表 CHECK 一一对应）。
public struct LearningUnitEventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 幂等键 UNIQUE——同 operationID 重放不产生第二行（§4.3）。
    public let operationID: UUID
    /// 弱引用：unit 删除后 SET NULL。
    public let unitID: UUID?
    /// 留史快照，永不为空。
    public let unitIDSnapshot: UUID
    public let kind: LearningUnitEventKind
    public let beforeJSON: String?
    public let afterJSON: String?
    /// 事件负载 hash（§4.3 幂等第三层对账）。
    public let payloadHash: String?
    public let createdAtMs: Int64
    public let undoneAtMs: Int64?

    public init(
        id: UUID,
        operationID: UUID,
        unitID: UUID?,
        unitIDSnapshot: UUID,
        kind: LearningUnitEventKind,
        beforeJSON: String? = nil,
        afterJSON: String? = nil,
        payloadHash: String? = nil,
        createdAtMs: Int64,
        undoneAtMs: Int64? = nil
    ) {
        self.id = id
        self.operationID = operationID
        self.unitID = unitID
        self.unitIDSnapshot = unitIDSnapshot
        self.kind = kind
        self.beforeJSON = beforeJSON
        self.afterJSON = afterJSON
        self.payloadHash = payloadHash
        self.createdAtMs = createdAtMs
        self.undoneAtMs = undoneAtMs
    }

    /// 领域投影（`LearningKnowledge.swift` 的审计模型）。
    public var event: LearningUnitEvent {
        LearningUnitEvent(
            id: id,
            unitID: unitID,
            unitIDSnapshot: unitIDSnapshot,
            kind: kind,
            operationID: operationID,
            payloadHash: payloadHash,
            occurredAtMs: createdAtMs
        )
    }
}

// MARK: - learning_unit_dictionary_aliases 行包装

/// `learning_unit_dictionary_aliases` 行投影：`LearningUnitDictionaryAlias`
/// （S02 值类型）+ rev2 新增列 `fingerprint_version`/`resolved_at_ms`。
/// 领域别名类型不含这两列（属落库/重绑层证据），用本包装携带。
public struct LearningUnitAliasBinding: Codable, Equatable, Sendable {
    public let alias: LearningUnitDictionaryAlias
    /// 生成 fingerprint 的算法版本（当前 `sense-fp-1`）。
    public let fingerprintVersion: String
    public let resolvedAtMs: Int64?

    public init(
        alias: LearningUnitDictionaryAlias,
        fingerprintVersion: String,
        resolvedAtMs: Int64? = nil
    ) {
        self.alias = alias
        self.fingerprintVersion = fingerprintVersion
        self.resolvedAtMs = resolvedAtMs
    }
}

// MARK: - learning_unit_migration_items（§6 v23）

/// `learning_unit_migration_items.status`——迁移条目生命周期
/// （contract §6 要求 enum CHECK，值集待 M 复核确认）：
/// `pending` 待回填 → `applied` 已生效 / `needsConfirmation` 待人工 /
/// `skipped` 有意跳过（如 ignored 仅留审计）/ `failed` 出错见
/// `last_error`。
public enum LearningUnitMigrationItemStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case applied
    case needsConfirmation
    case skipped
    case failed
}

/// `learning_unit_migration_items` 行投影：存量迁移审计证据，
/// 不参与三态运行态（§6）。`source_key` 全表唯一——旧数据来源的
/// 稳定键（如 `override:<lexemeID>` / `note:<noteID>`），重复回填
/// 幂等锚点。note/lexeme/unit 引用均可 SET NULL——审计行不随
/// 业务对象删除陪葬（证据已在 `evidence_json` 快照）。
public struct LearningUnitMigrationItem: Codable, Equatable, Sendable {
    public let sourceKey: String
    public let noteID: UUID?
    public let legacyLexemeID: UUID?
    /// 旧运行态快照（`known`/`ignored`/`learning`/`unknown` 等原文）。
    public let oldState: String?
    public let status: LearningUnitMigrationItemStatus
    /// 有界 JSON 证据（建表 CHECK json_valid + 长度上限）。
    public let evidenceJSON: String?
    public let targetUnitID: UUID?
    public let lastError: String?

    public init(
        sourceKey: String,
        noteID: UUID? = nil,
        legacyLexemeID: UUID? = nil,
        oldState: String? = nil,
        status: LearningUnitMigrationItemStatus,
        evidenceJSON: String? = nil,
        targetUnitID: UUID? = nil,
        lastError: String? = nil
    ) {
        self.sourceKey = sourceKey
        self.noteID = noteID
        self.legacyLexemeID = legacyLexemeID
        self.oldState = oldState
        self.status = status
        self.evidenceJSON = evidenceJSON
        self.targetUnitID = targetUnitID
        self.lastError = lastError
    }
}

// MARK: - 仓储结构化错误

/// `GRDBLearningUnitRepository` 的结构化失败原因——primary 冲突等
/// 必须可编程分支，不许靠字符串匹配（§7 写路径不变量）。
public enum LearningUnitRepositoryError: Error, Equatable, Sendable {
    /// unit 不存在。
    case unitNotFound(UUID)
    /// Note 不存在。
    case noteNotFound(UUID)
    /// Note 存在但 `kind != 'vocabulary'`（关联/资格校验失败）。
    case noteNotVocabulary(UUID)
    /// `note_id` 已绑定到**另一个** unit（一 Note 一有效 unit）。
    case noteAlreadyLinked(noteID: UUID, existingUnitID: UUID)
    /// unit 已有 primary link——不自动抢占，调用方决定提升/复用。
    case primaryLinkConflict(unitID: UUID, existingNoteID: UUID)
    /// 无 legacy_secondary 可提升为 primary。
    case noLegacySecondaryToPromote(unitID: UUID)
    /// flag CAS 冲突：期望 revision 与当前不符——不覆盖（§2.2）。
    case flagRevisionConflict(unitID: UUID, expected: Int64, actual: Int64)
    /// operationID 已落库但 payload 不同——拒绝（§4.3 幂等第三层）。
    case operationPayloadConflict(operationID: UUID)
    /// Undo 引用的原事件不存在（或 kind 不符）。
    case eventNotFound(UUID)
    /// Undo 引用的原事件已被撤销过。
    case eventAlreadyUndone(UUID)
    /// 身份参数不自洽（如 dictionarySense 缺 provider/entry/指纹）。
    case invalidUnitIdentity(String)
    /// 读回行与冻结枚举/格式不符。
    case inconsistentStorage(String)
}
