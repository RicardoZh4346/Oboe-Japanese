import CryptoKit
import Foundation
import GRDB
import OboeDomain

/// `upsertAlias` 结果（结构化，调用方可分支处理歧义绑定）。
public enum LearningUnitAliasUpsertOutcome: Equatable, Sendable {
    /// 新 alias 行已插入。
    case inserted
    /// 同 (provider,dataset,entry,sense) 已绑定**同一** unit——刷新
    /// status/fingerprint/fingerprint_version/resolved_at_ms。
    case updated
    /// 同 (provider,dataset,entry,sense) 已绑定**另一** unit——不抢占
    /// 不覆盖绑定（§3.1「禁止猜测合并」）；既有行 status 降级为
    /// `needsConfirmation` 待人工裁决，unit_id 保持原样。
    case markedNeedsConfirmation(existingUnitID: UUID)
}

/// v0.7.5 S04：`v23_learning_units` 六表的基础仓储
/// （contracts-frozen §1/§2/§6、技术文档 §3/§4/§11/§12、D01/D02）。
///
/// 形态约定（与 `GRDBNoteDeckMemberships` 相同）：全部读写以
/// `static func …(in db: Database)` 事务内形态暴露，供共享执行器在
/// 组合事务内复用（§7「所有词汇写入口经共享 `(in db:)` 事务内路径」）；
/// 实例方法只是 `pool.read/write` 的薄 async 门面。
///
/// 关键语义：
/// - `resolveOrCreateUnit`：`identity_key` 是全库幂等锚点——命中即
///   返回既有行，**绝不 UPDATE** 已有 `sense_snapshot_json` 或身份列；
///   插入用 `ON CONFLICT(identity_key) DO NOTHING`，并发/重试同 key
///   只留一行（pool.write 为 IMMEDIATE 事务，写者天然串行）。
/// - `linkNote`：事务内校验 note 存在且 `kind='vocabulary'`、unit
///   存在；primary 冲突抛 `primaryLinkConflict` 结构化错误——不自动
///   抢占（D02）。`note_id` UNIQUE 由表约束兜底。
/// - `promoteSecondaryToPrimary`：仅在无 primary 时，把
///   `created_at_ms` 最早、`note_id` 字典序最小的 legacy_secondary
///   提为 primary（§3.2 确定性规则）。
/// - `setFlagTooEasy`：flag CAS（revision 不符抛错不覆盖）+ 同事务
///   插 `tooEasySet` event（含 before/after JSON + payload_hash）；
///   `operation_id` 幂等——同 ID 同 payload 返回既有效果，同 ID 异
///   payload 抛 `operationPayloadConflict`（§2.2/§4.3）。
/// - `upsertAlias`：同四元组已绑定其他 unit → 不覆盖，既有行标
///   `needsConfirmation` 返回冲突 outcome。
public struct GRDBLearningUnitRepository: Sendable {
    private let pool: DatabasePool

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    // MARK: - unit 解析（resolve-or-create）

    /// 按 `identity_key` 解析或创建 unit。
    ///
    /// 命中既有行直接返回——重试/并发同 key 不产生第二行，也**不回写**
    /// `sense_snapshot_json`（快照只在创建时写入，更新走专用命令，
    /// S05/S06 接入）。
    ///
    /// - Parameters:
    ///   - identityKind/identityKey: §1.1 三层身份与稳定键。
    ///   - lemma/reading: 展示字段（lemma 非空由表 CHECK 兜底）。
    ///   - provider/entryID/fingerprint/fingerprintVersion:
    ///     dictionarySense 必需（缺一抛 `invalidUnitIdentity`）。
    ///   - senseSnapshotJSON: 有界义项快照（≤16 KiB + json_valid，
    ///     表 CHECK 兜底）；只在创建时写入。
    ///   - bindingStatus: 缺省 `dictionarySense→.current`、
    ///     其余→`.legacy`；隔离 key 场景传 `.needsConfirmation`。
    ///   - atMilliseconds: 毫秒整数时间（created/updated）。
    @discardableResult
    public static func resolveOrCreateUnit(
        identityKind: LearningUnitIdentityKind,
        identityKey: String,
        lemma: String,
        reading: String?,
        provider: String? = nil,
        entryID: Int64? = nil,
        fingerprint: String? = nil,
        fingerprintVersion: String? = nil,
        senseSnapshotJSON: String? = nil,
        bindingStatus: LearningUnitBindingStatus? = nil,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnit {
        if identityKind == .dictionarySense {
            guard provider != nil, entryID != nil, fingerprint != nil else {
                throw LearningUnitRepositoryError.invalidUnitIdentity(
                    "dictionarySense 需要 provider/entryID/fingerprint")
            }
        }
        if let existing = try fetchUnit(identityKey: identityKey, in: db) {
            return existing
        }
        let status = bindingStatus
            ?? (identityKind == .dictionarySense ? .current : .legacy)
        try db.execute(
            sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, provider,
                    dictionary_entry_id, semantic_fingerprint,
                    fingerprint_version, lemma, reading,
                    sense_snapshot_json, binding_status, revision,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(identity_key) DO NOTHING
                """,
            arguments: [
                DatabaseValueCodec.encode(UUID()),
                identityKind.rawValue, identityKey, provider, entryID,
                fingerprint, fingerprintVersion, lemma, reading,
                senseSnapshotJSON, status.rawValue,
                atMilliseconds, atMilliseconds,
            ])
        // 必然存在：自己刚插入，或并发胜出者的行。
        guard let unit = try fetchUnit(identityKey: identityKey, in: db)
        else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "resolveOrCreateUnit: \(identityKey) 插入后读不到")
        }
        return unit
    }

    /// 已知 id 的裸插入（备份恢复/S05 回填保留原 unit UUID——
    /// unitID 永不复用，备份恢复原样带回，v9 wire §2.1）。
    /// 冲突即报错（恢复语义：不重绑身份）。
    public static func insertUnit(
        _ unit: LearningUnit, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, provider,
                    dictionary_entry_id, semantic_fingerprint,
                    fingerprint_version, lemma, reading,
                    sense_snapshot_json, binding_status, revision,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(unit.id),
                unit.identityKind.rawValue, unit.identityKey, unit.provider,
                unit.dictionaryEntryID, unit.semanticFingerprint,
                unit.fingerprintVersion, unit.lemma, unit.reading,
                unit.senseSnapshotJSON, unit.bindingStatus.rawValue,
                unit.revision, unit.createdAtMs, unit.updatedAtMs,
            ])
    }

    // MARK: - unit 读取

    /// 按永久主键读 unit。
    public static func fetchUnit(
        id: UUID, in db: Database
    ) throws -> LearningUnit? {
        try fetchUnits(ids: [id], in: db)[id]
    }

    /// 按 `identity_key` 读 unit（解析入口的命中查询）。
    public static func fetchUnit(
        identityKey: String, in db: Database
    ) throws -> LearningUnit? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, identity_kind, identity_key, provider,
                       dictionary_entry_id, semantic_fingerprint,
                       fingerprint_version, lemma, reading,
                       sense_snapshot_json, binding_status, revision,
                       created_at_ms, updated_at_ms
                FROM lexical_learning_units WHERE identity_key = ?
                """,
            arguments: [identityKey])
        return try row.map(decodeUnit)
    }

    /// 批量读 unit（IN 分块 400，与既有仓储同口径）。
    /// 返回 id → unit 映射；缺失 id 不出现在结果中。
    public static func fetchUnits(
        ids: [UUID], in db: Database
    ) throws -> [UUID: LearningUnit] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        var result: [UUID: LearningUnit] = [:]
        for chunk in unique.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            let arguments = StatementArguments(
                chunk.map(DatabaseValueCodec.encode))
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT id, identity_kind, identity_key, provider,
                           dictionary_entry_id, semantic_fingerprint,
                           fingerprint_version, lemma, reading,
                           sense_snapshot_json, binding_status, revision,
                           created_at_ms, updated_at_ms
                    FROM lexical_learning_units WHERE id IN (\(placeholders))
                    """,
                arguments: arguments) {
                let unit = try decodeUnit(row)
                result[unit.id] = unit
            }
        }
        return result
    }

    // MARK: - Note 关联

    /// 建立 Note→unit 关联。
    ///
    /// 事务内校验顺序：unit 存在 → note 存在且 `kind='vocabulary'` →
    /// `note_id` 未绑定他 unit → role=primary 时 unit 无既有 primary。
    /// 同一 (unit,note,role) 重复调用幂等返回既有 link。
    ///
    /// primary 冲突**不自动抢占**——抛 `primaryLinkConflict` 结构化
    /// 错误，由调用方决定复用/提升（D02）；并发双 primary 由
    /// `learning_unit_one_primary` 部分唯一索引兜底。
    @discardableResult
    public static func linkNote(
        unitID: UUID,
        noteID: UUID,
        role: LearningUnitNoteLinkRole,
        origin: LearningUnitNoteLinkOrigin,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnitNoteLink {
        let unitIDValue = DatabaseValueCodec.encode(unitID)
        let noteIDValue = DatabaseValueCodec.encode(noteID)

        guard try unitExists(unitID, in: db) else {
            throw LearningUnitRepositoryError.unitNotFound(unitID)
        }
        let noteKind = try String.fetchOne(
            db,
            sql: "SELECT kind FROM notes WHERE id = ?",
            arguments: [noteIDValue])
        guard let noteKind else {
            throw LearningUnitRepositoryError.noteNotFound(noteID)
        }
        guard noteKind == "vocabulary" else {
            throw LearningUnitRepositoryError.noteNotVocabulary(noteID)
        }

        if let existing = try fetchLink(noteID: noteID, in: db) {
            if existing.unitID == unitID, existing.role == role {
                return existing // 同 (unit,note,role) 幂等
            }
            throw LearningUnitRepositoryError.noteAlreadyLinked(
                noteID: noteID, existingUnitID: existing.unitID)
        }
        if role == .primary,
           let existingPrimary = try primaryLinkNoteID(
               unitID: unitID, in: db) {
            throw LearningUnitRepositoryError.primaryLinkConflict(
                unitID: unitID, existingNoteID: existingPrimary)
        }

        try db.execute(
            sql: """
                INSERT INTO learning_unit_note_links(
                    unit_id, note_id, role, origin, created_at_ms
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                unitIDValue, noteIDValue, role.rawValue,
                origin.rawValue, atMilliseconds,
            ])
        return LearningUnitNoteLink(
            unitID: unitID, noteID: noteID, role: role,
            origin: origin, createdAtMs: atMilliseconds)
    }

    /// 解除 (unit,note) 关联。返回是否真有行被删。
    /// （「删除 primary 后提升 secondary」流程的删除侧；S05/S16 换绑
    /// 也走此入口。）
    @discardableResult
    public static func unlinkNote(
        unitID: UUID, noteID: UUID, in db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
                DELETE FROM learning_unit_note_links
                WHERE unit_id = ? AND note_id = ?
                """,
            arguments: [
                DatabaseValueCodec.encode(unitID),
                DatabaseValueCodec.encode(noteID),
            ])
        return db.changesCount > 0
    }

    /// 提升最老的 legacy_secondary 为 primary（§3.2 确定性规则：
    /// `created_at_ms` 最早，并列取 `note_id` 字典序最小——编码后
    /// 小写 UUID 文本序与 UUID 序一致）。
    ///
    /// 调用方须先解除旧 primary（`unlinkNote` 或删 Note）；仍有
    /// primary 时抛 `primaryLinkConflict`，无 secondary 可提升时抛
    /// `noLegacySecondaryToPromote`——绝不暗中合并或挑选（D02/D16）。
    @discardableResult
    public static func promoteSecondaryToPrimary(
        unitID: UUID, in db: Database
    ) throws -> LearningUnitNoteLink {
        let unitIDValue = DatabaseValueCodec.encode(unitID)
        if let existingPrimary = try primaryLinkNoteID(
            unitID: unitID, in: db) {
            throw LearningUnitRepositoryError.primaryLinkConflict(
                unitID: unitID, existingNoteID: existingPrimary)
        }
        let candidate = try Row.fetchOne(
            db,
            sql: """
                SELECT unit_id, note_id, role, origin, created_at_ms
                FROM learning_unit_note_links
                WHERE unit_id = ? AND role = 'legacy_secondary'
                ORDER BY created_at_ms ASC, note_id ASC
                LIMIT 1
                """,
            arguments: [unitIDValue])
        guard let candidate else {
            throw LearningUnitRepositoryError.noLegacySecondaryToPromote(
                unitID: unitID)
        }
        let noteIDValue: String = candidate["note_id"]
        try db.execute(
            sql: """
                UPDATE learning_unit_note_links SET role = 'primary'
                WHERE unit_id = ? AND note_id = ?
                """,
            arguments: [unitIDValue, noteIDValue])
        return LearningUnitNoteLink(
            unitID: unitID,
            noteID: try DatabaseValueCodec.decodeUUID(noteIDValue),
            role: .primary,
            origin: try decodeOrigin(candidate["origin"]),
            createdAtMs: candidate["created_at_ms"])
    }

    /// unit 的全部关联（created 升序 + note_id 序，与提升规则同序）。
    public static func fetchLinks(
        unitID: UUID, in db: Database
    ) throws -> [LearningUnitNoteLink] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT unit_id, note_id, role, origin, created_at_ms
                FROM learning_unit_note_links
                WHERE unit_id = ?
                ORDER BY created_at_ms ASC, note_id ASC
                """,
            arguments: [DatabaseValueCodec.encode(unitID)])
        .map(decodeLink)
    }

    /// 某 Note 的唯一有效关联（`note_id` UNIQUE——至多一行）。
    public static func fetchLink(
        noteID: UUID, in db: Database
    ) throws -> LearningUnitNoteLink? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT unit_id, note_id, role, origin, created_at_ms
                FROM learning_unit_note_links
                WHERE note_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(noteID)])
        .map(decodeLink)
    }

    /// 一批 unit 中「有任一有效 Note 关联」的 unit 集合——三态真值表
    /// `hasVocabularyNoteLink` 的批量输入（§2.1，S08 队列拼装共用）。
    /// 只统计关联到 vocabulary Note 的行（防御非词汇绑定）。
    public static func linkedVocabularyUnitIDs(
        unitIDs: [UUID], in db: Database
    ) throws -> Set<UUID> {
        let unique = Array(Set(unitIDs))
        guard !unique.isEmpty else { return [] }
        var result = Set<UUID>()
        for chunk in unique.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            let arguments = StatementArguments(
                chunk.map(DatabaseValueCodec.encode))
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT l.unit_id
                    FROM learning_unit_note_links l
                    JOIN notes n ON n.id = l.note_id
                        AND n.kind = 'vocabulary'
                    WHERE l.unit_id IN (\(placeholders))
                    """,
                arguments: arguments) {
                let raw: String = row["unit_id"]
                result.insert(try DatabaseValueCodec.decodeUUID(raw))
            }
        }
        return result
    }

    // MARK: - flags / Too Easy（§2.2）

    /// 读 flag；无行返回 nil（语义 = revision 0 / tooEasy false）。
    public static func fetchFlag(
        unitID: UUID, in db: Database
    ) throws -> LearningUnitFlag? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT unit_id, too_easy, revision, updated_at_ms
                FROM learning_unit_flags WHERE unit_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(unitID)])
        .map(decodeFlag)
    }

    /// `SetLearningUnitTooEasy` 事务内执行（§2.2）：
    ///
    /// 1. `operation_id` 幂等：已落库事件且 payload 一致 → 返回既有
    ///    flag（零写入重放）；payload 不一致 → `operationPayloadConflict`。
    /// 2. flag CAS：当前 revision（无行按 0 计）!= expectedRevision →
    ///    `flagRevisionConflict` 不覆盖。
    /// 3. 写 flags（revision+1）+ `tooEasySet` event（before/after
    ///    JSON + payload_hash）同 commit。
    ///
    /// 不写 ReviewLog、不动 stability/due/firstStudiedAt、不改
    /// cards.is_enabled（§2.2 禁令）；无 Note 的 unit 同样允许。
    @discardableResult
    public static func setFlagTooEasy(
        unitID: UUID,
        value: Bool,
        expectedRevision: Int64,
        operationID: UUID,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnitFlag {
        let payloadHash = flagPayloadHash(
            kind: "tooEasySet", unitID: unitID, value: value)

        // 幂等第一层：operation 重放。
        if let existing = try fetchEvent(
            operationID: operationID, in: db) {
            guard existing.kind == .tooEasySet,
                  existing.payloadHash == payloadHash else {
                throw LearningUnitRepositoryError
                    .operationPayloadConflict(operationID: operationID)
            }
            guard let flag = try fetchFlag(unitID: unitID, in: db) else {
                throw LearningUnitRepositoryError.inconsistentStorage(
                    "tooEasySet 事件存在但 flag 缺失")
            }
            return flag
        }

        guard try unitExists(unitID, in: db) else {
            throw LearningUnitRepositoryError.unitNotFound(unitID)
        }
        let before = try fetchFlag(unitID: unitID, in: db)
        let beforeRevision = before?.revision ?? 0
        guard beforeRevision == expectedRevision else {
            throw LearningUnitRepositoryError.flagRevisionConflict(
                unitID: unitID,
                expected: expectedRevision,
                actual: beforeRevision)
        }
        let flag = LearningUnitFlag(
            unitID: unitID, tooEasy: value,
            revision: beforeRevision + 1, updatedAtMs: atMilliseconds)
        try upsertFlag(flag, in: db)
        try insertEvent(
            LearningUnitEventRecord(
                id: UUID(), operationID: operationID,
                unitID: unitID, unitIDSnapshot: unitID,
                kind: .tooEasySet,
                beforeJSON: before.map(flagSnapshotJSON),
                afterJSON: flagSnapshotJSON(flag),
                payloadHash: payloadHash,
                createdAtMs: atMilliseconds),
            in: db)
        return flag
    }

    /// `TooEasyCommand` 形参版（S07 命令值类型直传）。
    @discardableResult
    public static func setFlagTooEasy(
        _ command: TooEasyCommand,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnitFlag {
        try setFlagTooEasy(
            unitID: command.unitID,
            value: command.value,
            expectedRevision: command.expectedFlagRevision,
            operationID: command.operationID,
            atMilliseconds: atMilliseconds,
            in: db)
    }

    /// `TooEasyUndoCommand` 事务内执行（§12.3，辅助 API——S07/S08
    /// Undo 栈直接可用）：
    ///
    /// 凭 `eventID` + before/after revision 作 CAS——只有 flag 仍停
    /// 在原操作产生的版本才还原 `beforeValue`，防止覆盖另一窗口的新
    /// 设置。同事务：原事件 `undone_at_ms` 标记 + flag revision+1 +
    /// `tooEasyUndone` 事件；operation_id 幂等同 setFlagTooEasy。
    /// 不调用 FSRS review undo。
    @discardableResult
    public static func undoTooEasy(
        _ command: TooEasyUndoCommand,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> LearningUnitFlag {
        let payloadHash = undoPayloadHash(command)

        if let existing = try fetchEvent(
            operationID: command.operationID, in: db) {
            guard existing.kind == .tooEasyUndone,
                  existing.payloadHash == payloadHash else {
                throw LearningUnitRepositoryError.operationPayloadConflict(
                    operationID: command.operationID)
            }
            guard let flag = try fetchFlag(unitID: command.unitID, in: db)
            else {
                throw LearningUnitRepositoryError.inconsistentStorage(
                    "tooEasyUndone 事件存在但 flag 缺失")
            }
            return flag
        }

        guard try unitExists(command.unitID, in: db) else {
            throw LearningUnitRepositoryError.unitNotFound(command.unitID)
        }
        let original = try Row.fetchOne(
            db,
            sql: """
                SELECT id, undone_at_ms FROM learning_unit_events
                WHERE id = ? AND kind = 'tooEasySet'
                """,
            arguments: [DatabaseValueCodec.encode(command.eventID)])
        guard let original else {
            throw LearningUnitRepositoryError.eventNotFound(command.eventID)
        }
        let undoneAt: Int64? = original["undone_at_ms"]
        guard undoneAt == nil else {
            throw LearningUnitRepositoryError.eventAlreadyUndone(
                command.eventID)
        }
        let before = try fetchFlag(unitID: command.unitID, in: db)
        let beforeRevision = before?.revision ?? 0
        guard beforeRevision == command.expectedFlagRevision else {
            throw LearningUnitRepositoryError.flagRevisionConflict(
                unitID: command.unitID,
                expected: command.expectedFlagRevision,
                actual: beforeRevision)
        }
        let flag = LearningUnitFlag(
            unitID: command.unitID, tooEasy: command.beforeValue,
            revision: beforeRevision + 1, updatedAtMs: atMilliseconds)
        try upsertFlag(flag, in: db)
        try db.execute(
            sql: """
                UPDATE learning_unit_events SET undone_at_ms = ?
                WHERE id = ?
                """,
            arguments: [
                atMilliseconds, DatabaseValueCodec.encode(command.eventID)])
        try insertEvent(
            LearningUnitEventRecord(
                id: UUID(), operationID: command.operationID,
                unitID: command.unitID, unitIDSnapshot: command.unitID,
                kind: .tooEasyUndone,
                beforeJSON: before.map(flagSnapshotJSON),
                afterJSON: flagSnapshotJSON(flag),
                payloadHash: payloadHash,
                createdAtMs: atMilliseconds),
            in: db)
        return flag
    }

    // MARK: - 词级标记（D19）

    /// 词级「已知」写路径的唯一实现点（D19 替代旧
    /// `vocabulary_knowledge_overrides` 行写——该表 v0.7.5 起仅作
    /// v8 导入/兼容审计，运行态不读写）。
    ///
    /// unit 集合 = `wordUnitIDs`——与
    /// `GRDBVocabularyKnowledgeRepository.wordKnowledgeStates`
    /// 同一词→unit 解析规则。逐 unit 读 revision 后 CAS 置位
    /// （单写事务内 DatabasePool 串行化，CAS 是防御性校验而非
    /// 跨事务并发控制）；每个被改 unit 记一条 `tooEasySet` 事件，
    /// child operationID 由 base opID+unitID+value 确定性派生
    /// （SHA-256 → UUID v5 形态）——整体重试对已写 unit 命中
    /// 幂等回放，对未写 unit 正常补写。
    ///
    /// 返回实际发生 flag 变更的 unit 数。0 = 未定位到活 unit 或
    /// 全部已相符——调用方据此提示，绝不臆造义项也不静默成功。
    @discardableResult
    public static func setWordTooEasy(
        lexemeID: UUID,
        value: Bool,
        operationID: UUID,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> Int {
        let unitIDs = try wordUnitIDs(lexemeID: lexemeID, in: db)
            .sorted { $0.uuidString < $1.uuidString }
        var changed = 0
        for unitID in unitIDs {
            let before = try fetchFlag(unitID: unitID, in: db)
            if (before?.tooEasy ?? false) == value { continue }
            let childOpID = deterministicUUID(
                "word_too_easy|\(operationID.uuidString.lowercased())"
                    + "|\(unitID.uuidString.lowercased())|\(value)")
            try setFlagTooEasy(
                unitID: unitID, value: value,
                expectedRevision: before?.revision ?? 0,
                operationID: childOpID,
                atMilliseconds: atMilliseconds, in: db)
            changed += 1
        }
        return changed
    }

    /// 词→unit 解析（D19 唯一口径——
    /// `GRDBVocabularyKnowledgeRepository.wordKnowledgeStates`
    /// 复用同一规则，两侧变更必须同步）：
    /// - 词条绑定义项：`lexeme_dictionary_bindings.status='current'`
    ///   的 entry_id 优先（换库重绑后的活绑定），回退
    ///   `lexemes.entry_id`；取其下全部 `binding_status='current'`
    ///   的 dictionarySense units；
    /// - 学习载体：经 `lexeme_note_links → learning_unit_note_links`
    ///   触达的 unit（localNote/legacyUnresolved/义项——覆盖 OOV
    ///   与未绑定的真实学习关系）；
    /// - `needsConfirmation`/`stale`/`legacy` 绑定态的义项 unit
    ///   不通过第一支路参与（歧义不猜、陈旧不算当前）。
    public static func wordUnitIDs(
        lexemeID: UUID, in db: Database
    ) throws -> Set<UUID> {
        let encoded = DatabaseValueCodec.encode(lexemeID)
        return Set(try Row.fetchAll(
            db,
            sql: """
                SELECT unit_id FROM (
                    SELECT u.id AS unit_id
                    FROM lexemes l
                    JOIN lexical_learning_units u
                      ON u.identity_kind = 'dictionarySense'
                     AND u.binding_status = 'current'
                     AND u.dictionary_entry_id = COALESCE(
                           (SELECT b.entry_id
                              FROM lexeme_dictionary_bindings b
                             WHERE b.lexeme_id = l.id
                               AND b.status = 'current'),
                           l.entry_id)
                    WHERE l.id = ?
                    UNION
                    SELECT ul.unit_id
                    FROM lexeme_note_links x
                    JOIN learning_unit_note_links ul
                      ON ul.note_id = x.note_id
                    WHERE x.lexeme_id = ?
                )
                """,
            arguments: [encoded, encoded]
        ).compactMap { try? DatabaseValueCodec.decodeUUID($0["unit_id"]) })
    }

    /// 确定性 operationID 派生（与 `LearningUnitBackfillService`
    /// 同一 SHA-256 → UUID v5 形态——同种子同 opID，幂等回放
    /// 零新增）。
    private static func deterministicUUID(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 10
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - 事件

    /// 写审计事件（组合事务共用：S05 迁移/S13 应用事务写
    /// created/migrated/noteLinked/noteUnlinked 走此入口）。
    /// `operation_id` UNIQUE 冲突直接抛错——幂等语义由调用方先查
    /// `fetchEvent(operationID:)` 判定。
    public static func insertEvent(
        _ record: LearningUnitEventRecord, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO learning_unit_events(
                    id, operation_id, unit_id, unit_id_snapshot, kind,
                    before_json, after_json, payload_hash,
                    created_at_ms, undone_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(record.id),
                DatabaseValueCodec.encode(record.operationID),
                record.unitID.map(DatabaseValueCodec.encode),
                DatabaseValueCodec.encode(record.unitIDSnapshot),
                record.kind.rawValue,
                record.beforeJSON, record.afterJSON, record.payloadHash,
                record.createdAtMs, record.undoneAtMs,
            ])
    }

    /// 按 operationID 读事件（幂等判定入口）。
    public static func fetchEvent(
        operationID: UUID, in db: Database
    ) throws -> LearningUnitEventRecord? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, operation_id, unit_id, unit_id_snapshot, kind,
                       before_json, after_json, payload_hash,
                       created_at_ms, undone_at_ms
                FROM learning_unit_events WHERE operation_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(operationID)])
        .map(decodeEvent)
    }

    /// unit 的事件史（时间升序）。
    public static func fetchEvents(
        unitID: UUID, in db: Database
    ) throws -> [LearningUnitEventRecord] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, operation_id, unit_id, unit_id_snapshot, kind,
                       before_json, after_json, payload_hash,
                       created_at_ms, undone_at_ms
                FROM learning_unit_events
                WHERE unit_id = ? OR unit_id_snapshot = ?
                ORDER BY created_at_ms ASC, id ASC
                """,
            arguments: [
                DatabaseValueCodec.encode(unitID),
                DatabaseValueCodec.encode(unitID),
            ])
        .map(decodeEvent)
    }

    // MARK: - 词典 alias

    /// upsert 一条 alias 绑定。
    ///
    /// - 同 (provider,dataset,entry,sense) 无行 → 插入（.inserted）。
    /// - 已绑定同一 unit → 刷新 status/fingerprint/fingerprint_version/
    ///   resolved_at_ms（.updated）。
    /// - 已绑定**其他** unit → 不覆盖归属：既有行 status 降级
    ///   `needsConfirmation`（§3.1 歧义不猜测合并），返回
    ///   `.markedNeedsConfirmation(existingUnitID:)`。
    ///
    /// `fingerprintVersion` 缺省 `SemanticFingerprint` 当前版本。
    @discardableResult
    public static func upsertAlias(
        _ alias: LearningUnitDictionaryAlias,
        fingerprintVersion: String = SemanticFingerprint
            .semanticFingerprintVersion,
        resolvedAtMs: Int64? = nil,
        in db: Database
    ) throws -> LearningUnitAliasUpsertOutcome {
        guard try unitExists(alias.unitID, in: db) else {
            throw LearningUnitRepositoryError.unitNotFound(alias.unitID)
        }
        let existing = try Row.fetchOne(
            db,
            sql: """
                SELECT unit_id FROM learning_unit_dictionary_aliases
                WHERE provider = ? AND dataset_version = ?
                  AND entry_id = ? AND sense_id = ?
                """,
            arguments: [
                alias.provider, alias.datasetVersion,
                alias.entryID, alias.senseID,
            ])
        guard let existing else {
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_dictionary_aliases(
                        unit_id, provider, dataset_version, entry_id,
                        sense_id, fingerprint, fingerprint_version,
                        status, resolved_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(alias.unitID),
                    alias.provider, alias.datasetVersion, alias.entryID,
                    alias.senseID, alias.fingerprint, fingerprintVersion,
                    alias.status.rawValue, resolvedAtMs,
                ])
            return .inserted
        }
        let existingUnitRaw: String = existing["unit_id"]
        let existingUnitID = try DatabaseValueCodec.decodeUUID(
            existingUnitRaw)
        if existingUnitID == alias.unitID {
            try db.execute(
                sql: """
                    UPDATE learning_unit_dictionary_aliases
                    SET fingerprint = ?, fingerprint_version = ?,
                        status = ?, resolved_at_ms = ?
                    WHERE provider = ? AND dataset_version = ?
                      AND entry_id = ? AND sense_id = ?
                    """,
                arguments: [
                    alias.fingerprint, fingerprintVersion,
                    alias.status.rawValue, resolvedAtMs,
                    alias.provider, alias.datasetVersion,
                    alias.entryID, alias.senseID,
                ])
            return .updated
        }
        // 歧义：不覆盖绑定，只降级状态待人工确认。
        try db.execute(
            sql: """
                UPDATE learning_unit_dictionary_aliases
                SET status = 'needsConfirmation', resolved_at_ms = ?
                WHERE provider = ? AND dataset_version = ?
                  AND entry_id = ? AND sense_id = ?
                """,
            arguments: [
                resolvedAtMs, alias.provider, alias.datasetVersion,
                alias.entryID, alias.senseID,
            ])
        return .markedNeedsConfirmation(existingUnitID: existingUnitID)
    }

    /// unit 的全部 alias（含行级 fingerprint_version/resolved_at_ms）。
    /// 注意：`superseded` 行解码会抛 `inconsistentStorage`——领域
    /// `LearningUnitDictionaryAlias.Status`（S02 值类型，不归本任务改）
    /// 尚无该 case，重绑落地前需先扩枚举（已记入交接风险）。
    public static func fetchAliases(
        unitID: UUID, in db: Database
    ) throws -> [LearningUnitAliasBinding] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT unit_id, provider, dataset_version, entry_id,
                       sense_id, fingerprint, fingerprint_version,
                       status, resolved_at_ms
                FROM learning_unit_dictionary_aliases
                WHERE unit_id = ?
                ORDER BY provider, dataset_version, entry_id, sense_id
                """,
            arguments: [DatabaseValueCodec.encode(unitID)])
        .map(decodeAliasBinding)
    }

    // MARK: - 迁移条目（S05 回填读写面）

    /// upsert 迁移条目（`source_key` 幂等锚点——重复回填不新增行，
    /// 只更新证据列）。审计表，不参与运行态。
    public static func upsertMigrationItem(
        _ item: LearningUnitMigrationItem, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO learning_unit_migration_items(
                    source_key, note_id, legacy_lexeme_id, old_state,
                    status, evidence_json, target_unit_id, last_error
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_key) DO UPDATE SET
                    note_id = excluded.note_id,
                    legacy_lexeme_id = excluded.legacy_lexeme_id,
                    old_state = excluded.old_state,
                    status = excluded.status,
                    evidence_json = excluded.evidence_json,
                    target_unit_id = excluded.target_unit_id,
                    last_error = excluded.last_error
                """,
            arguments: [
                item.sourceKey,
                item.noteID.map(DatabaseValueCodec.encode),
                item.legacyLexemeID.map(DatabaseValueCodec.encode),
                item.oldState, item.status.rawValue, item.evidenceJSON,
                item.targetUnitID.map(DatabaseValueCodec.encode),
                item.lastError,
            ])
    }

    public static func fetchMigrationItem(
        sourceKey: String, in db: Database
    ) throws -> LearningUnitMigrationItem? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT source_key, note_id, legacy_lexeme_id, old_state,
                       status, evidence_json, target_unit_id, last_error
                FROM learning_unit_migration_items WHERE source_key = ?
                """,
            arguments: [sourceKey])
        .map(decodeMigrationItem)
    }

    /// 按状态批量取迁移条目（S05 回填游标：pending/failed 扫描）。
    public static func fetchMigrationItems(
        status: LearningUnitMigrationItemStatus, in db: Database
    ) throws -> [LearningUnitMigrationItem] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT source_key, note_id, legacy_lexeme_id, old_state,
                       status, evidence_json, target_unit_id, last_error
                FROM learning_unit_migration_items
                WHERE status = ?
                ORDER BY source_key
                """,
            arguments: [status.rawValue])
        .map(decodeMigrationItem)
    }

    // MARK: - async 门面（pool.read/write 薄封装）

    @discardableResult
    public func resolveOrCreateUnit(
        identityKind: LearningUnitIdentityKind,
        identityKey: String,
        lemma: String,
        reading: String?,
        provider: String? = nil,
        entryID: Int64? = nil,
        fingerprint: String? = nil,
        fingerprintVersion: String? = nil,
        senseSnapshotJSON: String? = nil,
        bindingStatus: LearningUnitBindingStatus? = nil,
        at date: Date
    ) async throws -> LearningUnit {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try Self.resolveOrCreateUnit(
                identityKind: identityKind, identityKey: identityKey,
                lemma: lemma, reading: reading, provider: provider,
                entryID: entryID, fingerprint: fingerprint,
                fingerprintVersion: fingerprintVersion,
                senseSnapshotJSON: senseSnapshotJSON,
                bindingStatus: bindingStatus,
                atMilliseconds: atMs, in: db)
        }
    }

    public func fetchUnits(
        ids: [UUID]
    ) async throws -> [UUID: LearningUnit] {
        try await pool.read { db in try Self.fetchUnits(ids: ids, in: db) }
    }

    public func fetchUnit(
        identityKey: String
    ) async throws -> LearningUnit? {
        try await pool.read { db in
            try Self.fetchUnit(identityKey: identityKey, in: db)
        }
    }

    @discardableResult
    public func linkNote(
        unitID: UUID,
        noteID: UUID,
        role: LearningUnitNoteLinkRole,
        origin: LearningUnitNoteLinkOrigin,
        at date: Date
    ) async throws -> LearningUnitNoteLink {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try Self.linkNote(
                unitID: unitID, noteID: noteID, role: role,
                origin: origin, atMilliseconds: atMs, in: db)
        }
    }

    @discardableResult
    public func promoteSecondaryToPrimary(
        unitID: UUID
    ) async throws -> LearningUnitNoteLink {
        try await pool.write { db in
            try Self.promoteSecondaryToPrimary(unitID: unitID, in: db)
        }
    }

    public func fetchFlag(
        unitID: UUID
    ) async throws -> LearningUnitFlag? {
        try await pool.read { db in
            try Self.fetchFlag(unitID: unitID, in: db)
        }
    }

    @discardableResult
    public func setFlagTooEasy(
        _ command: TooEasyCommand, at date: Date
    ) async throws -> LearningUnitFlag {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try Self.setFlagTooEasy(
                command, atMilliseconds: atMs, in: db)
        }
    }

    public func fetchLink(
        noteID: UUID
    ) async throws -> LearningUnitNoteLink? {
        try await pool.read { db in
            try Self.fetchLink(noteID: noteID, in: db)
        }
    }

    public func fetchLinks(
        unitID: UUID
    ) async throws -> [LearningUnitNoteLink] {
        try await pool.read { db in
            try Self.fetchLinks(unitID: unitID, in: db)
        }
    }

    public func linkedVocabularyUnitIDs(
        unitIDs: [UUID]
    ) async throws -> Set<UUID> {
        try await pool.read { db in
            try Self.linkedVocabularyUnitIDs(unitIDs: unitIDs, in: db)
        }
    }

    /// D19 词级标记门面：lexeme 的全部活 unit → tooEasy
    /// （`wordUnitIDs` 规则与 `wordKnowledgeStates` 一致）。
    /// 返回实际发生 flag 变更的 unit 数；0 = 无可标记 unit。
    @discardableResult
    public func setWordTooEasy(
        lexemeID: UUID,
        value: Bool,
        operationID: UUID,
        at date: Date
    ) async throws -> Int {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try Self.setWordTooEasy(
                lexemeID: lexemeID, value: value,
                operationID: operationID,
                atMilliseconds: atMs, in: db)
        }
    }

    @discardableResult
    public func undoTooEasy(
        _ command: TooEasyUndoCommand, at date: Date
    ) async throws -> LearningUnitFlag {
        let atMs = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try Self.undoTooEasy(
                command, atMilliseconds: atMs, in: db)
        }
    }

    public func fetchEvents(
        unitID: UUID
    ) async throws -> [LearningUnitEventRecord] {
        try await pool.read { db in
            try Self.fetchEvents(unitID: unitID, in: db)
        }
    }

    /// v0.7.5 S16：unit 全部关联 Note 的卡 id 集——复习会话的同
    /// unit sibling 驱逐判定（一次 join 查询，避免逐卡载入内容）。
    /// link 表 CHECK 限定 vocabulary Note，故返回的都是词汇方向卡。
    public func fetchLinkedCardIDs(
        unitID: UUID
    ) async throws -> Set<UUID> {
        try await pool.read { db in
            let raw = try String.fetchAll(
                db,
                sql: """
                    SELECT c.id FROM cards c
                    JOIN learning_unit_note_links l
                        ON l.note_id = c.note_id
                    WHERE l.unit_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(unitID)]
            )
            return try Set(raw.map { try DatabaseValueCodec.decodeUUID($0) })
        }
    }

    /// v0.7.5 S16：`learning_unit_flags` / `learning_unit_note_links`
    /// 的变更信号流（§14.3：跨窗口刷新走共享数据观察，不靠
    /// onAppear）。同一 DatabasePool 上的任一写提交（本窗口或其他
    /// scene 共享同一池）即触发一次 Void ping；调用方按自身上下文
    /// 重新解析 flag/link——观察流不携带负载。
    ///
    /// 实现注意：`learning_unit_flags`/`learning_unit_note_links`
    /// 均为 WITHOUT ROWID 表——GRDB 的 `ValueObservation` 经
    /// `sqlite3_update_hook` 收事件，WITHOUT ROWID 表的写不入
    /// `DatabaseEvent` 派发（实测 v7.11：对该类表的 INSERT 不产生
    /// 观察通知）。因此跟踪载荷里并入 `learning_unit_events`（普通
    /// rowid 表）行数：所有 flag/link 生产写路径都在同事务写审计
    /// 事件（`tooEasySet`/`tooEasyUndone`/`noteLinked`/`noteUnlinked`
    /// /`created`/`migrated`），事件行即触发器；dedup 仍以
    /// flags+links+事件计数的真实内容为准，无内容变化不 ping。
    public func observeChanges() -> AsyncThrowingStream<Void, Error> {
        struct ObservedState: Equatable {
            var flags: [LearningUnitFlag]
            var links: [LearningUnitNoteLink]
            var eventCount: Int
        }
        let observation = ValueObservation
            .tracking { db -> ObservedState in
                try ObservedState(
                    flags: Self.fetchAllFlags(in: db),
                    links: Self.fetchAllLinks(in: db),
                    // 读事件表只为把它计入跟踪区域（WITHOUT ROWID 的
                    // flags/links 自身不产生事件派发）——行数进入
                    // dedup 载荷，任何审计写都必然改变它。
                    eventCount: Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM learning_unit_events"
                    ) ?? 0
                )
            }
            .removeDuplicates()
        let values = observation.values(
            in: pool,
            bufferingPolicy: .bufferingNewest(1)
        )
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            let task = Task {
                do {
                    for try await _ in values {
                        guard !Task.isCancelled else { break }
                        continuation.yield(())
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    @discardableResult
    public func upsertAlias(
        _ alias: LearningUnitDictionaryAlias,
        fingerprintVersion: String = SemanticFingerprint
            .semanticFingerprintVersion,
        resolvedAt date: Date? = nil
    ) async throws -> LearningUnitAliasUpsertOutcome {
        let resolvedAtMs = try date.map(DatabaseValueCodec.encode)
        return try await pool.write { db in
            try Self.upsertAlias(
                alias, fingerprintVersion: fingerprintVersion,
                resolvedAtMs: resolvedAtMs, in: db)
        }
    }

    // MARK: - 内部：行解码 / 共享小查询

    /// `observeChanges` 的观察载荷——两张表全量行（去重比较需要
    /// Equatable 值；表规模小，仅在自身表提交时重取）。
    private static func fetchAllFlags(
        in db: Database
    ) throws -> [LearningUnitFlag] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT unit_id, too_easy, revision, updated_at_ms
                FROM learning_unit_flags ORDER BY unit_id
                """)
        .map(decodeFlag)
    }

    private static func fetchAllLinks(
        in db: Database
    ) throws -> [LearningUnitNoteLink] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT unit_id, note_id, role, origin, created_at_ms
                FROM learning_unit_note_links
                ORDER BY unit_id, note_id
                """)
        .map(decodeLink)
    }

    private static func unitExists(
        _ unitID: UUID, in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM lexical_learning_units WHERE id = ?)
                """,
            arguments: [DatabaseValueCodec.encode(unitID)]) == true
    }

    private static func primaryLinkNoteID(
        unitID: UUID, in db: Database
    ) throws -> UUID? {
        let raw = try String.fetchOne(
            db,
            sql: """
                SELECT note_id FROM learning_unit_note_links
                WHERE unit_id = ? AND role = 'primary'
                """,
            arguments: [DatabaseValueCodec.encode(unitID)])
        return try raw.map(DatabaseValueCodec.decodeUUID)
    }

    private static func upsertFlag(
        _ flag: LearningUnitFlag, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO learning_unit_flags(
                    unit_id, too_easy, revision, updated_at_ms
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(unit_id) DO UPDATE SET
                    too_easy = excluded.too_easy,
                    revision = excluded.revision,
                    updated_at_ms = excluded.updated_at_ms
                """,
            arguments: [
                DatabaseValueCodec.encode(flag.unitID), flag.tooEasy,
                flag.revision, flag.updatedAtMs,
            ])
    }

    /// flag 快照 JSON（canonical：键字典序、无空白）——event
    /// before/after_json 负载。
    private static func flagSnapshotJSON(_ flag: LearningUnitFlag) -> String {
        "{\"revision\":\(flag.revision),\"tooEasy\":\(flag.tooEasy)}"
    }

    /// tooEasySet 幂等 payload hash（SHA-256 hex 64）：
    /// 同 operationID 重放凭它判定「同 payload」。
    private static func flagPayloadHash(
        kind: String, unitID: UUID, value: Bool
    ) -> String {
        sha256Hex(
            "\(kind)|\(unitID.uuidString.lowercased())|\(value ? 1 : 0)")
    }

    private static func undoPayloadHash(
        _ command: TooEasyUndoCommand
    ) -> String {
        sha256Hex(
            "tooEasyUndone|\(command.unitID.uuidString.lowercased())"
                + "|\(command.eventID.uuidString.lowercased())"
                + "|\(command.beforeValue ? 1 : 0)")
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func decodeUnit(_ row: Row) throws -> LearningUnit {
        let kindRaw: String = row["identity_kind"]
        let bindingRaw: String = row["binding_status"]
        guard let kind = LearningUnitIdentityKind(rawValue: kindRaw),
              let binding = LearningUnitBindingStatus(rawValue: bindingRaw)
        else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "lexical_learning_units kind/binding: \(kindRaw)/\(bindingRaw)")
        }
        let idRaw: String = row["id"]
        return LearningUnit(
            id: try DatabaseValueCodec.decodeUUID(idRaw),
            identityKind: kind,
            identityKey: row["identity_key"],
            provider: row["provider"],
            dictionaryEntryID: row["dictionary_entry_id"],
            semanticFingerprint: row["semantic_fingerprint"],
            fingerprintVersion: row["fingerprint_version"],
            lemma: row["lemma"],
            reading: row["reading"],
            senseSnapshotJSON: row["sense_snapshot_json"],
            bindingStatus: binding,
            revision: row["revision"],
            createdAtMs: row["created_at_ms"],
            updatedAtMs: row["updated_at_ms"])
    }

    private static func decodeOrigin(
        _ raw: String
    ) throws -> LearningUnitNoteLinkOrigin {
        guard let origin = LearningUnitNoteLinkOrigin(rawValue: raw) else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "learning_unit_note_links origin: \(raw)")
        }
        return origin
    }

    private static func decodeLink(
        _ row: Row
    ) throws -> LearningUnitNoteLink {
        let roleRaw: String = row["role"]
        let originRaw: String = row["origin"]
        let unitRaw: String = row["unit_id"]
        let noteRaw: String = row["note_id"]
        guard let role = LearningUnitNoteLinkRole(rawValue: roleRaw) else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "learning_unit_note_links role: \(roleRaw)")
        }
        return LearningUnitNoteLink(
            unitID: try DatabaseValueCodec.decodeUUID(unitRaw),
            noteID: try DatabaseValueCodec.decodeUUID(noteRaw),
            role: role,
            origin: try decodeOrigin(originRaw),
            createdAtMs: row["created_at_ms"])
    }

    private static func decodeFlag(
        _ row: Row
    ) throws -> LearningUnitFlag {
        let unitRaw: String = row["unit_id"]
        return LearningUnitFlag(
            unitID: try DatabaseValueCodec.decodeUUID(unitRaw),
            tooEasy: row["too_easy"],
            revision: row["revision"],
            updatedAtMs: row["updated_at_ms"])
    }

    private static func decodeEvent(
        _ row: Row
    ) throws -> LearningUnitEventRecord {
        let kindRaw: String = row["kind"]
        guard let kind = LearningUnitEventKind(rawValue: kindRaw) else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "learning_unit_events kind: \(kindRaw)")
        }
        let idRaw: String = row["id"]
        let opRaw: String = row["operation_id"]
        let unitRaw: String? = row["unit_id"]
        let snapshotRaw: String = row["unit_id_snapshot"]
        return LearningUnitEventRecord(
            id: try DatabaseValueCodec.decodeUUID(idRaw),
            operationID: try DatabaseValueCodec.decodeUUID(opRaw),
            unitID: try unitRaw.map(DatabaseValueCodec.decodeUUID),
            unitIDSnapshot: try DatabaseValueCodec.decodeUUID(snapshotRaw),
            kind: kind,
            beforeJSON: row["before_json"],
            afterJSON: row["after_json"],
            payloadHash: row["payload_hash"],
            createdAtMs: row["created_at_ms"],
            undoneAtMs: row["undone_at_ms"])
    }

    private static func decodeAliasBinding(
        _ row: Row
    ) throws -> LearningUnitAliasBinding {
        let statusRaw: String = row["status"]
        let unitRaw: String = row["unit_id"]
        guard let status = LearningUnitDictionaryAlias.Status(
            rawValue: statusRaw) else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "learning_unit_dictionary_aliases status: \(statusRaw)")
        }
        return LearningUnitAliasBinding(
            alias: LearningUnitDictionaryAlias(
                unitID: try DatabaseValueCodec.decodeUUID(unitRaw),
                provider: row["provider"],
                datasetVersion: row["dataset_version"],
                entryID: row["entry_id"],
                senseID: row["sense_id"],
                fingerprint: row["fingerprint"],
                status: status),
            fingerprintVersion: row["fingerprint_version"],
            resolvedAtMs: row["resolved_at_ms"])
    }

    private static func decodeMigrationItem(
        _ row: Row
    ) throws -> LearningUnitMigrationItem {
        let statusRaw: String = row["status"]
        let noteRaw: String? = row["note_id"]
        let lexemeRaw: String? = row["legacy_lexeme_id"]
        let targetRaw: String? = row["target_unit_id"]
        guard let status = LearningUnitMigrationItemStatus(
            rawValue: statusRaw) else {
            throw LearningUnitRepositoryError.inconsistentStorage(
                "learning_unit_migration_items status: \(statusRaw)")
        }
        return LearningUnitMigrationItem(
            sourceKey: row["source_key"],
            noteID: try noteRaw.map(DatabaseValueCodec.decodeUUID),
            legacyLexemeID: try lexemeRaw.map(DatabaseValueCodec.decodeUUID),
            oldState: row["old_state"],
            status: status,
            evidenceJSON: row["evidence_json"],
            targetUnitID: try targetRaw.map(DatabaseValueCodec.decodeUUID),
            lastError: row["last_error"])
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(
                index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
