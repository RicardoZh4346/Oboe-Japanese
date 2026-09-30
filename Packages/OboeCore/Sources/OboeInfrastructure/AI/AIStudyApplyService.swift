import CryptoKit
import Foundation
import GRDB
import OboeDomain
import os

/// v0.7.5 S13（前置·角色 C）：AI Study **应用层**——把已确认的
/// `ai_study_selections`（immutable revision）逐 unit 落到学习数据。
///
/// 依据：contracts-frozen rev2 §4.2（selection/revision）、§4.3
/// （receipt/actionKey/幂等三层）、§5（删除与生命周期）、§7
/// （应用事务顺序）、§8.2（来源去重键）、§9（Job 结算/终态）、
/// §10（预览后竞态：重读当前数据、不盲写）、§11（命令字段与
/// fallback）。技术文档 §7/§9/§11；decisions D10/D12/D14/D17。
///
/// # 架构（与其他 GRDB* 仓储同构）
///
/// - `GRDBAIStudyApplyService.applyUnit(..., in db:)`：
///   **单 unit 一次写事务**的静态事务内形态——receipt replay 检查 →
///   重读当前数据复核 → 业务写入 → receipt + `applied_receipt_id`
///   回填同 commit。本类型不自开事务，调用方 `pool.write` 包裹。
/// - `AIStudyApplyService.applyConfirmedJob(jobID:)`：Job 编排——
///   状态复核 → `awaitingConfirmation/partiallyCompleted → applying`
///   → 逐 unit 独立短事务（一 unit 失败不拖跨 unit）→ 所有者块
///   推进 `.applied` → `applying → completed|partiallyCompleted`。
///
/// # 事务/幂等要点
///
/// - **一 unit 一事务**：Note/Card/membership/unit link/来源/receipt
///   全部同 commit；任一步失败整事务回滚，不留半截应用（§7）。
///   receipt 与业务副作用同 commit——不存在「业务已提交、receipt
///   未落」的崩溃窗口；重放安全性由三层幂等共同保证：
///   1. `selection.applied_receipt_id` 非空 → 直接返回历史结果；
///   2. `action_key` 命中同 payload receipt → replay，零写入；
///   3. 业务唯一约束兜底收敛（link `note_id` UNIQUE、`note_decks`
///      PK、`study_dedup_key` 部分唯一、`cards` (note,template)），
///      即便 receipt 缺失，重跑也收敛到既有行不复制。
/// - **重读不盲写**（§10）：unit/Note/链接/membership/牌组全部在
///   事务内重读当前状态，预览快照只作输入提示不作真值。
/// - **不复活已删内容**（§5 + 用户删除卡方向语义）：unit 曾挂过
///   Note（`noteLinked`/`noteUnlinked` 事件留史——unit 不随 Note
///   删除陪葬）而当前零链接 = 用户已删学习对象；常规应用落
///   `skippedDeletedEvidence` 不写任何数据；显式重建走
///   `AIStudyRebuildIntent.explicitRebuild` 分键另起 receipt。
/// - **epoch/状态复核**：每个 unit 事务内重读 Job——status 必须仍
///   为 `.applying`、epoch 必须仍是入口观察值（取消 bump epoch
///   后迟到写被拒，§9.2）；文档 `content_revision` 与 Job 锚定值
///   不符 → Job 落 `paused(.contentStale)`（§5 旧选择不自动继续）。
///
/// # 不在这里做的事
///
/// - 不写 review_logs / FSRS state / daily_tasks（复习统计零副作用）。
/// - `reader_study_occurrences` 只回写 `unit_id` 链接（随
///   resolution.unit_id 同事务落值——S20 Coverage v2 分母所依）；
///   状态/锚点归 finalize 管。
/// - 不删 Note/Card——「删除」永远只由用户动作产生。
///
/// # 装配分工（物化接缝）
///
/// 新建 Note 需要的词典/内容证据不来自数据库——来自**装配层**注入的
/// `AIStudyApplyUnitSourceProvider`：事务外把 resolution 三分量
/// （entry/sense/datasetVersion）物化成 `DictionarySenseBinding` +
/// `VocabularyFormData` 输入。`DictionaryAIStudyUnitSourceProvider`
/// 是默认实现（`DictionaryRepository` + 指纹复算消歧）；测试可用
/// 字典 stub 直供。locator/原文句在 unit 事务内从 `reader_blocks`
/// 按 (document_id, locator_json|text_hash) 弱引用重链（D12）。
public enum GRDBAIStudyApplyService {

    // MARK: - unit 应用（事务内形态）

    /// 单个 unit 的完整应用事务。**不自开事务**——调用方
    /// `pool.write` 包裹；抛错则整事务回滚（receipt/selection 回填
    /// 一并撤销），由调用方记 `.failed` outcome。
    ///
    /// 幂等链（§4.3）：
    /// 1. `selection.appliedReceiptID` 已回填 → 不重写，返回
    ///    `.alreadyApplied`（receipt 可解出则带回原结果）；
    /// 2. `action_key` 命中 receipt：payload 一致 → `.replayed`；
    ///    不一致 → `AIStudyApplyError.receiptConflict`；
    /// 3. 否则执行决策 → 写业务 → `recordReceipt` +
    ///    `markSelectionApplied` 同 commit。
    @discardableResult
    public static func applyUnit(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        source: AIStudyApplyUnitSource?,
        rebuildIntent: AIStudyRebuildIntent = .none,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> AIStudyApplyUnitOutcome {
        // §11.1 复核：Job 仍处于应用阶段且未换世代——取消/暂停后
        // 迟到的 unit 写一律拒。
        try revalidateJobState(context: context, in: db)
        // §11.1 复核：文档内容修订与 Job 锚定一致（§5 过期不盲写）。
        try revalidateDocument(context: context, in: db)

        let action = try resolvedAction(for: selection)
        let actionKey = AIStudyActionKey(
            documentID: context.documentID,
            contentRevision: context.contentRevision,
            unitKey: selection.unitKey,
            selectionRevision: selection.selectionRevision,
            actionType: action.type,
            rebuildIntent: rebuildIntent
        ).canonicalKey
        let payloadHash = payloadHash(
            context: context, selection: selection,
            action: action, rebuildIntent: rebuildIntent)

        // 幂等 1：selection 已带 receipt——分批应用/崩溃恢复重入
        // 的正式跳过点（D10：已应用绝不重复写）。
        if let receiptID = selection.appliedReceiptID {
            var outcome = try GRDBAIStudyJobStore.fetchReceipt(
                operationID: receiptID, in: db)
                .flatMap(decodeOutcome) ?? AIStudyApplyUnitOutcome(
                    unitKey: selection.unitKey, kind: .alreadyApplied,
                    actionType: action.type)
            outcome.kind = .alreadyApplied
            outcome.receiptOperationID = receiptID
            return outcome
        }

        // 幂等 2：action_key replay——同 payload 返回历史结果；
        // 异 payload 拒绝（§4.3 第三层）。
        if let existing = try GRDBAIStudyJobStore.fetchReceipt(
            actionKey: actionKey, in: db) {
            guard existing.payloadHash == payloadHash else {
                throw AIStudyApplyError.receiptConflict(actionKey)
            }
            var outcome = decodeOutcome(existing)
                ?? AIStudyApplyUnitOutcome(
                    unitKey: selection.unitKey, kind: .replayed,
                    actionType: action.type)
            outcome.kind = .replayed
            outcome.receiptOperationID = existing.operationID
            return outcome
        }

        // 业务执行——每条路径返回部分填充的 outcome。
        var outcome: AIStudyApplyUnitOutcome
        switch action.kind {
        case .recordSkip:
            // skip/pending：只落 receipt 锚，零学习数据（§11.7）。
            outcome = AIStudyApplyUnitOutcome(
                unitKey: selection.unitKey, kind: .recordedSkip,
                actionType: .recordSkip)
        case .setTooEasy:
            outcome = try applyTooEasy(
                context: context, selection: selection, source: source,
                atMilliseconds: atMilliseconds, in: db)
        case .reuseNote(let noteID, let membershipDeck):
            outcome = try applyReuse(
                context: context, selection: selection, source: source,
                noteID: noteID, membershipDeckID: membershipDeck,
                atMilliseconds: atMilliseconds, in: db)
        case .createNote(let directions):
            outcome = try applyCreate(
                context: context, selection: selection, source: source,
                directions: directions, rebuildIntent: rebuildIntent,
                atMilliseconds: atMilliseconds, in: db)
        }

        // resolution → unit 弱引用回填（§6 v25 `unit_id`：应用后落值）。
        if let unitID = outcome.unitID {
            try backfillResolutionUnitIDs(
                unitID: unitID, context: context,
                selection: selection, in: db)
        }

        // 幂等 3：receipt + selection 回填同 commit——operationID
        // 每次尝试新随机（receipt 行只记「当时提交过」，§5）。
        let receiptID = UUID()
        outcome.receiptOperationID = receiptID
        let outcomeJSON = String(
            decoding: try encoder.encode(outcome), as: UTF8.self)
        try GRDBAIStudyJobStore.recordReceipt(
            AIStudyReceipt(
                operationID: receiptID, actionKey: actionKey,
                payloadHash: payloadHash, outcomeJSON: outcomeJSON,
                committedAtMs: atMilliseconds),
            in: db)
        try GRDBAIStudyJobStore.markSelectionApplied(
            jobID: context.jobID, unitKey: selection.unitKey,
            selectionRevision: selection.selectionRevision,
            receiptID: receiptID, expectedEpoch: context.jobEpoch,
            atMs: atMilliseconds, in: db)
        return outcome
    }

    // MARK: - 事务内复核（§11.1）

    /// Job status+epoch 复核：取消（epoch+1）/暂停/结算后迟到的
    /// unit 事务一律拒——已提交内容保留、未提交整体回滚。
    static func revalidateJobState(
        context: AIStudyApplyUnitContext, in db: Database
    ) throws {
        guard let job = try GRDBAIStudyJobStore.fetchJob(
            id: context.jobID, in: db) else {
            throw AIStudyApplyError.jobNotFound(context.jobID)
        }
        guard job.status == .applying, job.epoch == context.jobEpoch else {
            throw AIStudyApplyError.jobStateChanged(
                expectedEpoch: context.jobEpoch,
                foundStatus: job.status, foundEpoch: job.epoch)
        }
    }

    /// 文档 content_revision 复核：与 Job 锚定不一致 → 旧选择
    /// stale（§5），不自动应用——调用方落 `paused(.contentStale)`。
    static func revalidateDocument(
        context: AIStudyApplyUnitContext, in db: Database
    ) throws {
        guard let revision = try Int64.fetchOne(
            db,
            sql: """
                SELECT content_revision FROM reader_documents WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(context.documentID)]
        ) else {
            throw AIStudyApplyError.documentMissing(context.documentID)
        }
        guard revision == context.contentRevision else {
            throw AIStudyApplyError.staleDocumentRevision(
                expected: context.contentRevision, found: revision)
        }
    }

    // MARK: - decision → 执行动作

    /// `decision` 是用户可见结论，`proposedAction` 是参数化动作载荷；
    /// 两者分列但应用以**动作**为准（§4.2）。action 缺省时按
    /// decision 推默认：tooEasy/skip/pending 无参可推；
    /// reuse/create 缺载荷 → `invalidSelection`（没有参数不能猜）。
    static func resolvedAction(
        for selection: AIStudyJobSelection
    ) throws -> (kind: ResolvedActionKind, type: AIStudyActionType) {
        switch selection.proposedAction {
        case .reuseNote(let noteID, let deck):
            return (.reuseNote(noteID: noteID, membershipDeck: deck),
                    .reuseNote)
        case .createNote(let directions):
            return (.createNote(directions: directions), .createNote)
        case .setTooEasy:
            return (.setTooEasy, .setTooEasy)
        case .recordSkip, .pending:
            return (.recordSkip, .recordSkip)
        case nil:
            switch selection.decision {
            case .tooEasy: return (.setTooEasy, .setTooEasy)
            case .skip, .pending: return (.recordSkip, .recordSkip)
            case .reuse, .create:
                throw AIStudyApplyError.invalidSelection(
                    "decision=\(selection.decision.rawValue) 缺 "
                        + "proposedAction 载荷")
            }
        }
    }

    enum ResolvedActionKind {
        case reuseNote(noteID: UUID, membershipDeck: UUID?)
        case createNote(directions: Set<VocabularyCardDirection>)
        case setTooEasy
        case recordSkip
    }

    /// 同 action_key 的 payload 指纹（§4.3「同 payload replay / 异
    /// payload 拒绝」）：动作参数全量进 hash——同 unit 同 revision
    /// 的「复用 NoteA」与「复用 NoteB」是不同动作必须冲突。
    static func payloadHash(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        action: (kind: ResolvedActionKind, type: AIStudyActionType),
        rebuildIntent: AIStudyRebuildIntent
    ) -> String {
        var detail: String
        switch action.kind {
        case .reuseNote(let noteID, let deck):
            detail = "reuse:\(noteID.uuidString.lowercased()):"
                + (deck?.uuidString.lowercased() ?? "-")
        case .createNote(let directions):
            detail = "create:"
                + directions.map(\.rawValue).sorted().joined(separator: ",")
        case .setTooEasy: detail = "tooEasy"
        case .recordSkip: detail = "skip"
        }
        return sha256Hex(
            "aisa1|\(context.jobID.uuidString.lowercased())"
                + "|\(context.documentID.uuidString.lowercased())"
                + "|\(context.contentRevision)|\(selection.unitKey)"
                + "|\(selection.selectionRevision)"
                + "|\(action.type.rawValue)|\(rebuildIntent.rawValue)"
                + "|\(detail)")
    }

    // MARK: - unit 解析

    /// `unit_key` → unit 行。identity key 解析与
    /// `DictionarySenseBinding.identityKey`/`LearningUnitWriteBridge`
    /// 的格式约定一一对应（§1.1）。
    ///
    /// - 既有行命中直接返回（identity_key 全库唯一——同 key 同义项）。
    /// - `jmdict:sense-v1:`：entryID/指纹从 key 解析；lemma 优先取
    ///   `source.headword`，其次调用方给的 fallback（复用 Note 的
    ///   headword）；bindingStatus=.current。
    /// - `jmdict:sense-iso-v1:`（隔离 key）：entryID/senseID/
    ///   datasetVersion 从 key 尾段解析；指纹只能由物化 binding
    ///   供给——缺证据不猜测（D-隔离语义）。
    /// - `local-note:`/`legacy-*`/未知前缀：不能凭 key 建 unit，
    ///   只能等既有行命中——否则 `unitKeyNotResolvable`。
    static func resolveUnit(
        unitKey: String,
        source: AIStudyApplyUnitSource?,
        fallbackLemma: String?,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> (unit: LearningUnit, created: Bool) {
        if let unit = try GRDBLearningUnitRepository.fetchUnit(
            identityKey: unitKey, in: db) {
            return (unit, false)
        }
        switch UnitKeyIdentity.parse(unitKey) {
        case .dictionarySense(let entryID, let fingerprint):
            guard let binding = source?.binding else {
                // key 自带指纹可建 unit；但无 binding 时 lemma 只能
                // 靠 source.headword/fallback——都没有则证据不足。
                guard let lemma = source?.headword ?? fallbackLemma,
                      !lemma.isEmpty else {
                    throw AIStudyApplyError.unitEvidenceMissing(unitKey)
                }
                let unit = try GRDBLearningUnitRepository
                    .resolveOrCreateUnit(
                        identityKind: .dictionarySense,
                        identityKey: unitKey,
                        lemma: lemma,
                        reading: source?.reading,
                        provider: "jmdict", entryID: entryID,
                        fingerprint: fingerprint,
                        fingerprintVersion: SemanticFingerprint
                            .semanticFingerprintVersion,
                        bindingStatus: .current,
                        atMilliseconds: atMilliseconds, in: db)
                return (unit, true)
            }
            // 有词典证据：指纹必须复算一致——不符 = 快照漂移/绑定
            // 竞态（§10：提示局部刷新并重新确认，不盲写）。
            guard binding.identityKey == unitKey else {
                throw AIStudyApplyError.unitBindingConflict(
                    unitKey: unitKey, bindingKey: binding.identityKey)
            }
            guard let lemma = source?.headword ?? fallbackLemma,
                  !lemma.isEmpty else {
                throw AIStudyApplyError.unitEvidenceMissing(unitKey)
            }
            let unit = try GRDBLearningUnitRepository
                .resolveOrCreateUnit(
                    identityKind: .dictionarySense,
                    identityKey: unitKey,
                    lemma: lemma,
                    reading: source?.reading,
                    provider: "jmdict", entryID: entryID,
                    fingerprint: fingerprint,
                    fingerprintVersion: SemanticFingerprint
                        .semanticFingerprintVersion,
                    senseSnapshotJSON: binding.senseSnapshotJSON,
                    bindingStatus: .current,
                    atMilliseconds: atMilliseconds, in: db)
            try GRDBLearningUnitRepository.upsertAlias(
                LearningUnitDictionaryAlias(
                    unitID: unit.id,
                    provider: "jmdict",
                    datasetVersion: binding.datasetVersion,
                    entryID: binding.entryID,
                    senseID: binding.senseID,
                    fingerprint: binding.fingerprint,
                    status: .current),
                resolvedAtMs: atMilliseconds, in: db)
            return (unit, true)
        case .dictionarySenseIsolated(let dataset, let entryID, let senseID):
            // 隔离 key 不含指纹——只能由物化 binding 提供；unit 落
            // needsConfirmation（不冒充 current 绑定，§1.1 隔离语义）。
            guard let binding = source?.binding else {
                throw AIStudyApplyError.unitEvidenceMissing(unitKey)
            }
            guard let lemma = source?.headword ?? fallbackLemma,
                  !lemma.isEmpty else {
                throw AIStudyApplyError.unitEvidenceMissing(unitKey)
            }
            let unit = try GRDBLearningUnitRepository
                .resolveOrCreateUnit(
                    identityKind: .dictionarySense,
                    identityKey: unitKey,
                    lemma: lemma,
                    reading: source?.reading,
                    provider: "jmdict", entryID: entryID,
                    fingerprint: binding.fingerprint,
                    fingerprintVersion: SemanticFingerprint
                        .semanticFingerprintVersion,
                    senseSnapshotJSON: binding.senseSnapshotJSON,
                    bindingStatus: .needsConfirmation,
                    atMilliseconds: atMilliseconds, in: db)
            _ = (dataset, entryID, senseID) // key 解析仅用于身份/审计
            return (unit, true)
        case .localNote, .legacy, .unresolvable:
            throw AIStudyApplyError.unitKeyNotResolvable(unitKey)
        }
    }

    // MARK: - reuse 应用

    /// `reuseNote(noteID:addMembershipTo:)`（§11.4）：
    /// - Note 已删 → **不复制、不落数据**（§11.5/§10），settle 为
    ///   `skippedNoteMissing`（仍写 receipt 锚——选择已消费）。
    /// - Note 已链接本 unit → 幂等收敛（必要时 secondary 提正）；
    ///   链接他 unit → `noteBoundElsewhere`（一 Note 一 unit，不抢）。
    /// - unit 缺失时按 unitKey 重建（lemma 回退到 Note headword）。
    /// - membership 幂等追加；来源按 dedup key 幂等补记。
    static func applyReuse(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        source: AIStudyApplyUnitSource?,
        noteID: UUID,
        membershipDeckID: UUID?,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> AIStudyApplyUnitOutcome {
        var outcome = AIStudyApplyUnitOutcome(
            unitKey: selection.unitKey, kind: .reusedNote,
            actionType: .reuseNote, noteID: noteID)
        guard let note = try fetchVocabularyNote(noteID: noteID, in: db)
        else {
            // 预览后被用户删除——§11.5 fallback：不复制直接跳过。
            outcome.kind = .skippedNoteMissing
            outcome.errorCode = AIStudyApplyError.noteMissing(noteID).code
            return outcome
        }

        let resolved = try resolveUnit(
            unitKey: selection.unitKey, source: source,
            fallbackLemma: note.headword,
            atMilliseconds: atMilliseconds, in: db)
        let unit = resolved.unit
        outcome.unitID = unit.id
        if resolved.created {
            try insertUnitEvent(
                unitID: unit.id, kind: .created,
                afterJSON: unitSnapshotJSON(unit),
                atMilliseconds: atMilliseconds, in: db)
        }

        // 链接复核（§10 重读当前状态）。
        let links = try GRDBLearningUnitRepository.fetchLinks(
            unitID: unit.id, in: db)
        let hasPrimary = links.contains { $0.role == .primary }
        if let existing = try GRDBLearningUnitRepository.fetchLink(
            noteID: noteID, in: db) {
            if existing.unitID != unit.id {
                throw AIStudyApplyError.noteBoundElsewhere(
                    noteID: noteID, unitID: existing.unitID)
            }
            if existing.role == .legacySecondary, !hasPrimary {
                // 空 primary 位 + 确认复用 → 提升正主（§7 提升语义）。
                let promoted = try GRDBLearningUnitRepository
                    .promoteSecondaryToPrimary(unitID: unit.id, in: db)
                outcome.linkRole = promoted.role.rawValue
            } else {
                outcome.linkRole = existing.role.rawValue
            }
        } else {
            let role: LearningUnitNoteLinkRole =
                hasPrimary ? .legacySecondary : .primary
            let link = try GRDBLearningUnitRepository.linkNote(
                unitID: unit.id, noteID: noteID, role: role,
                origin: .aiPipeline,
                atMilliseconds: atMilliseconds, in: db)
            outcome.linkRole = link.role.rawValue
            try insertUnitEvent(
                unitID: unit.id, kind: .noteLinked,
                afterJSON: linkSnapshotJSON(
                    noteID: noteID, role: role, origin: .aiPipeline),
                atMilliseconds: atMilliseconds, in: db)
        }

        // membership：复用不改 home/FSRS，只按确认追加成员（幂等）。
        if let deckID = membershipDeckID {
            guard try deckExists(deckID, in: db) else {
                throw AIStudyApplyError.deckMissing(deckID)
            }
            try GRDBContentCardRepository.insertHomeMembership(
                noteID: noteID, deckID: deckID,
                atMilliseconds: atMilliseconds, in: db)
            outcome.membershipAdded = db.changesCount > 0
        }

        // 来源：AI 作业 provenance 按规范 dedup key 补记（§8.2）——
        // 命中同位置既有行则跳过，不产生重复来源。
        try insertSourceContextIfAbsent(
            context: context, selection: selection, source: source,
            noteID: noteID, unitID: unit.id,
            atMilliseconds: atMilliseconds, in: db)
        return outcome
    }

    // MARK: - create 应用

    /// `createNote(directions:)`（§11.5 + D17 方向快照）：
    /// - unit 已有 primary → **不复制卡**：降级复用既有 primary
    ///   （membership + 来源 dedup），outcome `reusedExistingPrimary`；
    ///   无 primary 有 secondary → 提正后同样降级复用。
    /// - unit 零链接但留 `noteLinked/noteUnlinked` 事件 = 用户删除
    ///   证据（§5）：常规应用 `skippedDeletedEvidence` 零写入；
    ///   `explicitRebuild` 分键才真建。
    /// - 需要 `source.binding`（装配方已验证的当前快照义项）且
    ///   `binding.identityKey == unitKey`——不符 `unitBindingConflict`
    ///   （词典快照漂移 → 局部刷新重新确认，§10）。
    /// - Note/Card/membership/unit link 经共享 commit 路径同事务
    ///   （`GRDBContentWriteExecutor.commitVocabulary`）——不开小灶。
    static func applyCreate(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        source: AIStudyApplyUnitSource?,
        directions: Set<VocabularyCardDirection>,
        rebuildIntent: AIStudyRebuildIntent,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> AIStudyApplyUnitOutcome {
        var outcome = AIStudyApplyUnitOutcome(
            unitKey: selection.unitKey, kind: .createdNote,
            actionType: .createNote)
        let keyIdentity = UnitKeyIdentity.parse(selection.unitKey)

        // unit 预解析/预检（commit 内 ensureUnit 会按同一 key 再命中）。
        // dictionarySense：resolve-or-create（既有行命中无需证据）；
        // local/legacy：只读既有行——其身份绑在特定 Note 上不能重
        // 建，新 Note 由 commit 获得自己的自然 local-unit 绑定；
        // iso/unresolvable：create 无法物化到同 key unit → 冲突/不可解。
        var unit: LearningUnit?
        switch keyIdentity {
        case .dictionarySense:
            let resolved = try resolveUnit(
                unitKey: selection.unitKey, source: source,
                fallbackLemma: nil,
                atMilliseconds: atMilliseconds, in: db)
            unit = resolved.unit
            if resolved.created {
                try insertUnitEvent(
                    unitID: resolved.unit.id, kind: .created,
                    afterJSON: unitSnapshotJSON(resolved.unit),
                    atMilliseconds: atMilliseconds, in: db)
            }
        case .dictionarySenseIsolated:
            // 隔离 key ≠ binding.identityKey——快照歧义本就要局部
            // 刷新重新确认（§10），不在应用层猜测合并。
            throw AIStudyApplyError.unitBindingConflict(
                unitKey: selection.unitKey,
                bindingKey: source?.binding?.identityKey ?? "")
        case .localNote, .legacy:
            unit = try GRDBLearningUnitRepository.fetchUnit(
                identityKey: selection.unitKey, in: db)
        case .unresolvable:
            throw AIStudyApplyError.unitKeyNotResolvable(
                selection.unitKey)
        }

        // 当前状态复核（§10）：既有 primary 复用不复制卡——
        // membership + 来源 dedup 照常，方向/Note 一行不增；
        // secondary 提正后同样降级复用。降级路径不需要 binding
        // ——复用的是既有 Note 而非词典证据。
        if let unit {
            let links = try GRDBLearningUnitRepository.fetchLinks(
                unitID: unit.id, in: db)
            if let primary = links.first(where: { $0.role == .primary }) {
                outcome.kind = .reusedExistingPrimary
                outcome.unitID = unit.id
                outcome.noteID = primary.noteID
                outcome.linkRole = primary.role.rawValue
                try addStudyDeckMembership(
                    context: context, noteID: primary.noteID,
                    outcome: &outcome,
                    atMilliseconds: atMilliseconds, in: db)
                try insertSourceContextIfAbsent(
                    context: context, selection: selection,
                    source: source, noteID: primary.noteID,
                    unitID: unit.id,
                    atMilliseconds: atMilliseconds, in: db)
                return outcome
            }
            if links.contains(where: { $0.role == .legacySecondary }) {
                let promoted = try GRDBLearningUnitRepository
                    .promoteSecondaryToPrimary(
                        unitID: unit.id, in: db)
                outcome.kind = .promotedAndReused
                outcome.unitID = unit.id
                outcome.noteID = promoted.noteID
                outcome.linkRole = promoted.role.rawValue
                try addStudyDeckMembership(
                    context: context, noteID: promoted.noteID,
                    outcome: &outcome,
                    atMilliseconds: atMilliseconds, in: db)
                try insertSourceContextIfAbsent(
                    context: context, selection: selection,
                    source: source, noteID: promoted.noteID,
                    unitID: unit.id,
                    atMilliseconds: atMilliseconds, in: db)
                return outcome
            }
            // 零链接 + 曾挂过 Note = 用户已删学习对象（§5：unit 不
            // 陪葬、事件留史）——常规应用不复活，显式重建另键。
            if rebuildIntent == .none,
               try unitHasLinkHistory(unitID: unit.id, in: db) {
                outcome.kind = .skippedDeletedEvidence
                outcome.unitID = unit.id
                outcome.errorCode = "deletedEvidence"
                return outcome
            }
        }

        // 真创建路径：dictionarySense 需要物化 binding 且复算一致；
        // local/legacy → nil binding（自然 local-unit 绑定）。
        let binding: DictionarySenseBinding?
        if case .dictionarySense = keyIdentity {
            guard let provided = source?.binding else {
                throw AIStudyApplyError.unitEvidenceMissing(
                    selection.unitKey)
            }
            guard provided.identityKey == selection.unitKey else {
                throw AIStudyApplyError.unitBindingConflict(
                    unitKey: selection.unitKey,
                    bindingKey: provided.identityKey)
            }
            binding = provided
        } else {
            binding = nil
        }

        // 牌组：Job 锚定的文章绑定牌组；缺失则懒补绑定（D14 首次
        // 「准备」应已建——这里是防御路径，同事务写回 Job 冗余列）。
        let deckID = try requireStudyDeck(context: context, in: db)

        // 内容：物化 source > unit 快照 > resolution/块 ——
        // headword/meaning 必填：物化缺失、unit 快照也无货时落
        // `unitEvidenceMissing`（比裸校验错误更可分支）。
        let headword = source?.headword ?? unit?.lemma ?? ""
        guard !headword.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw AIStudyApplyError.unitEvidenceMissing(
                selection.unitKey)
        }
        let reading = source?.reading ?? unit?.reading
        let meaning = source?.meaningZH
            ?? unit.flatMap(glossesFromSnapshot)
            ?? ""
        guard !meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw AIStudyApplyError.unitEvidenceMissing(
                selection.unitKey)
        }
        let sentence = source?.sourceSentence
            ?? readerBlockSentence(context: context,
                                   selection: selection, in: db)
        let form = VocabularyFormData(
            headword: headword, reading: reading ?? "",
            meaningZH: meaning,
            partOfSpeech: source?.partOfSpeech ?? "",
            exampleJapanese: sentence ?? "")
        let content = try form.validatedContent()

        let orderedDirections = directions.isEmpty
            ? Set(VocabularyCardDirection.allCases) : directions
        let commit = VocabularyContentCommit(
            noteID: UUID(), exampleID: UUID(), draftID: nil,
            deckID: deckID, content: content, tags: [],
            cards: orderedDirections.map(\.templateKind)
                .sorted { $0.rawValue < $1.rawValue }
                .map { NewCardSeed(id: UUID(), templateKind: $0) },
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970:
                Double(atMilliseconds) / 1_000),
            origin: .ai,
            deckIDs: [deckID],
            dictionaryBinding: binding)
        let result = try GRDBContentWriteExecutor.commitVocabulary(
            commit, capture: nil, in: db)

        // 链接 origin 归位：commit 内 ensureUnit 按 .ai →
        // automaticHighConfidence 落；AI 应用事务的规范 origin 是
        // aiPipeline（§6 link origin 冻结词汇）。
        try db.execute(
            sql: """
                UPDATE learning_unit_note_links SET origin = 'aiPipeline'
                WHERE note_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(result.noteID)])

        outcome.noteID = result.noteID
        outcome.cardCount = result.cardCount
        let linked = try GRDBLearningUnitRepository.fetchLink(
            noteID: result.noteID, in: db)
        outcome.unitID = linked?.unitID ?? unit?.id
        // dictionarySense 路径 unit 一定与选择 key 同址；local/legacy
        // 新 Note 落自己的自然 local-unit（linked.unitID 真值）。
        outcome.linkRole = linked?.role.rawValue
        outcome.membershipAdded = true
        if let linked {
            try insertUnitEvent(
                unitID: linked.unitID, kind: .noteLinked,
                afterJSON: linkSnapshotJSON(
                    noteID: result.noteID, role: linked.role,
                    origin: .aiPipeline),
                atMilliseconds: atMilliseconds, in: db)
        }
        try insertSourceContextIfAbsent(
            context: context, selection: selection, source: source,
            noteID: result.noteID, unitID: outcome.unitID,
            atMilliseconds: atMilliseconds, in: db)
        return outcome
    }

    // MARK: - tooEasy 应用

    /// `setTooEasy`（§2.2）：重读 flag → CAS 置位 + `tooEasySet`
    /// 事件（共享仓储路径）——不动 FSRS/复习日志/cards.is_enabled。
    /// flag 已是 true → 幂等收敛不写第二条事件。
    static func applyTooEasy(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        source: AIStudyApplyUnitSource?,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> AIStudyApplyUnitOutcome {
        var outcome = AIStudyApplyUnitOutcome(
            unitKey: selection.unitKey, kind: .tooEasySet,
            actionType: .setTooEasy)
        let resolved = try resolveUnit(
            unitKey: selection.unitKey, source: source,
            fallbackLemma: nil,
            atMilliseconds: atMilliseconds, in: db)
        outcome.unitID = resolved.unit.id
        if resolved.created {
            try insertUnitEvent(
                unitID: resolved.unit.id, kind: .created,
                afterJSON: unitSnapshotJSON(resolved.unit),
                atMilliseconds: atMilliseconds, in: db)
        }
        let flag = try GRDBLearningUnitRepository.fetchFlag(
            unitID: resolved.unit.id, in: db)
        if flag?.tooEasy == true { return outcome } // 幂等收敛
        _ = try GRDBLearningUnitRepository.setFlagTooEasy(
            unitID: resolved.unit.id, value: true,
            expectedRevision: flag?.revision ?? 0,
            operationID: UUID(),
            atMilliseconds: atMilliseconds, in: db)
        return outcome
    }

    // MARK: - 来源记录（§8.2 规范 dedup key）

    /// `source_contexts.study_dedup_key` 组分（§4.4/§8.2）：
    /// `noteID + documentID + sourceHash + locator + unitID + kind`。
    /// 规范化后整组进 SHA-256——同词不同句（locator 异）、同句
    /// 不同 unit、同 unit 不同 kind 各自成键；同位置同 unit 重跑
    /// 命中既有行不再写。
    static func studyDedupKey(
        noteID: UUID, documentID: UUID, sourceHash: String,
        locator: String, unitID: UUID, kind: String
    ) -> String {
        "sdup1:" + sha256Hex(
            "sd1|\(noteID.uuidString.lowercased())"
                + "|\(documentID.uuidString.lowercased())"
                + "|\(sourceHash)|\(locator)"
                + "|\(unitID.uuidString.lowercased())|\(kind)")
    }

    /// 来源证据：选择锚定的 resolution → 所属块 → locator/hash；
    /// `ReaderLocation` best-effort 解码（planner 的 locator_json
    /// 与 Reader 定位同构时落 `reader_location` 列）。
    static func evidenceAnchor(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection
    ) -> (locator: String, sourceHash: String,
          location: ReaderLocation?) {
        let resolutions = matchedResolutions(
            context: context, selection: selection)
        let resolution = resolutions.first
        let block = resolution?.jobBlockID
            .flatMap { id in context.blocks.first { $0.id == id } }
        let locator = resolution?.locatorJSON ?? block?.locatorJSON ?? ""
        let sourceHash = block?.sourceHash ?? ""
        let location = try? JSONDecoder().decode(
            ReaderLocation.self, from: Data(locator.utf8))
        return (locator, sourceHash, location)
    }

    /// reader_blocks 重链（locator_json 优先，text_hash 兜底）——
    /// 取 token 所在的**包含句**（`AIStudySentenceSegments` 确定性
    /// 句界），不把整段进例句；锚点缺失/句界异常时回退块级有界
    /// 裁剪。单个「句子」本身超长（无标点长文）时以 token 位置
    /// 为中心开窗，保证例句有界且词出现在上下文里。
    static func readerBlockSentence(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        in db: Database
    ) -> String? {
        let anchor = evidenceAnchor(
            context: context, selection: selection)
        guard !anchor.locator.isEmpty || !anchor.sourceHash.isEmpty
        else { return nil }
        let row = try? Row.fetchOne(
            db,
            sql: """
                SELECT text FROM reader_blocks
                WHERE document_id = ?
                  AND (locator_json = ? OR text_hash = ?)
                ORDER BY (locator_json = ?) DESC
                LIMIT 1
                """,
            arguments: [
                DatabaseValueCodec.encode(context.documentID),
                anchor.locator, anchor.sourceHash, anchor.locator,
            ])
        guard let text: String = row.flatMap({ $0["text"] }),
              !text.isEmpty else { return nil }
        let limit = SourceContextDraft.maximumSurroundingCharacters
        guard let offset = anchor.location?.utf16Offset else {
            return String(text.prefix(limit))
        }
        let units = Array(text.utf16)
        guard offset >= 0, offset <= units.count else {
            return String(text.prefix(limit))
        }
        // 单句硬上限——超过则以 token 为中心开窗。
        let sentenceWindowCap = 480
        for range in AIStudySentenceSegments.ranges(of: text)
        where range.contains(offset) {
            if range.count <= sentenceWindowCap {
                return String(decoding: units[range], as: UTF16.self)
            }
            // 长句/无标点段：以 token 为基准取前后窗。
            let spanStart = max(range.lowerBound,
                                offset - sentenceWindowCap / 2)
            let spanEnd = min(range.upperBound,
                              spanStart + sentenceWindowCap)
            return String(
                decoding: units[spanStart..<spanEnd], as: UTF16.self)
        }
        return String(text.prefix(limit))
    }

    /// 来源写入：dedup key 命中即跳（幂等第四层）；`isPrimary` 依
    /// 「有来源时最多一个 primary」——Note 已有来源则非 primary。
    /// `GRDBSourceContextRepository.insert` 未覆盖 dedup 列，此处在
    /// 同事务直写（白名单列与 v15 schema 1:1 + v24 dedup 列）。
    static func insertSourceContextIfAbsent(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        source: AIStudyApplyUnitSource?,
        noteID: UUID,
        unitID: UUID?,
        atMilliseconds: Int64,
        in db: Database
    ) throws {
        guard let unitID else { return }
        let anchor = evidenceAnchor(
            context: context, selection: selection)
        let kind = "aiStudyApply"
        let dedupKey = studyDedupKey(
            noteID: noteID, documentID: context.documentID,
            sourceHash: anchor.sourceHash, locator: anchor.locator,
            unitID: unitID, kind: kind)
        let exists = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM source_contexts
                    WHERE study_dedup_key = ?)
                """,
            arguments: [dedupKey]) ?? false
        guard !exists else { return }

        let hasContexts = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM source_contexts WHERE note_id = ?)
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]) ?? false
        let sentence = source?.sourceSentence
            ?? readerBlockSentence(
                context: context, selection: selection, in: db)
        let readerLocationJSON = anchor.location.flatMap {
            try? String(
                decoding: JSONEncoder().encode($0), as: UTF8.self)
        }
        try db.execute(
            sql: """
                INSERT INTO source_contexts(
                    id, note_id, source_type, original_sentence,
                    surrounding_text, source_title, source_url, source_app,
                    image_reference, dictionary_entry_id,
                    dictionary_version, dictionary_sense_key,
                    selected_gloss_language, reader_document_id,
                    reader_chapter_id, reader_location, selected_surface,
                    is_primary, created_at_ms, study_dedup_key
                ) VALUES (?, ?, 'reader', ?, NULL, NULL, NULL, NULL,
                          NULL, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(UUID()),
                DatabaseValueCodec.encode(noteID),
                sentence,
                source?.binding?.entryID,
                source?.binding?.datasetVersion,
                source?.binding.map { String($0.senseID) },
                source?.glossLanguage,
                DatabaseValueCodec.encode(context.documentID),
                readerLocationJSON,
                nil as String?, // selected_surface：键空间暂不携带
                !hasContexts,
                atMilliseconds,
                dedupKey,
            ])
    }

    // MARK: - 共享小工具

    /// 文章绑定牌组：`reader_documents.study_deck_id` 为真值；
    /// 缺失时懒建（同事务）并把 Job 冗余列补写——无牌组不能落
    /// membership/commit（`requireDeck` 会拒）。
    static func requireStudyDeck(
        context: AIStudyApplyUnitContext, in db: Database
    ) throws -> UUID {
        let deckID = try GRDBReaderStudyDeckService.ensureStudyDeck(
            documentID: context.documentID, in: db)
        try db.execute(
            sql: """
                UPDATE ai_study_jobs SET study_deck_id = ?
                WHERE id = ? AND study_deck_id IS NULL
                """,
            arguments: [
                DatabaseValueCodec.encode(deckID),
                DatabaseValueCodec.encode(context.jobID),
            ])
        return deckID
    }

    /// 牌组存在性复核（membership/创建前置——缺组落 `.deckMissing`
    /// 而非裸 `ContentCardError`）。
    static func deckExists(_ deckID: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
            arguments: [DatabaseValueCodec.encode(deckID)]) ?? false
    }

    /// 降级复用路径的 study deck membership 追加（幂等）。
    static func addStudyDeckMembership(
        context: AIStudyApplyUnitContext,
        noteID: UUID,
        outcome: inout AIStudyApplyUnitOutcome,
        atMilliseconds: Int64,
        in db: Database
    ) throws {
        let deckID = try requireStudyDeck(context: context, in: db)
        try GRDBContentCardRepository.insertHomeMembership(
            noteID: noteID, deckID: deckID,
            atMilliseconds: atMilliseconds, in: db)
        outcome.membershipAdded = db.changesCount > 0
    }

    /// unit 的链接史（删除证据）：`learning_unit_events` 的
    /// unit_id/unit_id_snapshot 双列都查——unit 不随 Note 删除陪葬，
    /// 事件留史是「曾挂过 Note」的权威凭证。
    static func unitHasLinkHistory(
        unitID: UUID, in db: Database
    ) throws -> Bool {
        try GRDBLearningUnitRepository.fetchEvents(
            unitID: unitID, in: db
        ).contains { $0.kind == .noteLinked || $0.kind == .noteUnlinked }
    }

    /// selection.unitKey → resolution 匹配：entryID 三分量同值，
    /// `evidenceRevision` 优先（§4.2 锚定语义），次取该 entry 的
    /// 最高 revision。
    static func matchedResolutions(
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection
    ) -> [AIStudyResolutionRecord] {
        guard let entryID = UnitKeyIdentity.parse(
            selection.unitKey).entryID else { return [] }
        let candidates = context.resolutions.filter {
            $0.resolution.selected?.entryID == entryID
        }
        let anchored = candidates.filter {
            $0.revision == selection.evidenceRevision
        }
        return (anchored.isEmpty ? candidates : anchored)
            .sorted { $0.revision > $1.revision }
    }

    /// `ai_study_resolutions.unit_id` 弱引用回填（§6 v25：应用后
    /// 落值；`unit_id IS NULL` 守卫使重放/局部补写幂等）。
    ///
    /// S20：同事务把同一 unit 落回 `reader_study_occurrences.unit_id`
    /// ——occurrence `resolution_id` 由 finalize 指向本 resolution；
    /// 该列是 Coverage v2 分母（unit_id 非空的已解析 occurrence 的
    /// distinct unit）的唯一来源，缺它快照恒为空分母。无 `IS NULL`
    /// 守卫：重放同值覆盖无害，resolution 换绑时跟随最新证据（unit
    /// 删除由 SET NULL 弱引用自动释放）。
    static func backfillResolutionUnitIDs(
        unitID: UUID,
        context: AIStudyApplyUnitContext,
        selection: AIStudyJobSelection,
        in db: Database
    ) throws {
        for resolution in matchedResolutions(
            context: context, selection: selection) {
            try db.execute(
                sql: """
                    UPDATE ai_study_resolutions SET unit_id = ?
                    WHERE id = ? AND unit_id IS NULL
                    """,
                arguments: [
                    DatabaseValueCodec.encode(unitID),
                    DatabaseValueCodec.encode(resolution.id),
                ])
            try db.execute(
                sql: """
                    UPDATE reader_study_occurrences SET unit_id = ?
                    WHERE resolution_id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(unitID),
                    DatabaseValueCodec.encode(resolution.id),
                ])
        }
    }

    /// 词汇 Note 行读（复用资格复核 + headword/reading 回退）。
    static func fetchVocabularyNote(
        noteID: UUID, in db: Database
    ) throws -> (headword: String, reading: String?)? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT kind, headword, reading FROM notes WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(noteID)]) else {
            return nil
        }
        let kind: String = row["kind"]
        guard kind == "vocabulary" else {
            throw AIStudyApplyError.noteNotVocabulary(noteID)
        }
        return (row["headword"], row["reading"])
    }

    /// unit 快照 JSON（`sense_snapshot_json.glosses_en` 回退取义——
    /// 物化 source 缺失时的最后内容来源；不回退任何译文）。
    static func glossesFromSnapshot(unit: LearningUnit) -> String? {
        guard let json = unit.senseSnapshotJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let glosses = dict["glosses_en"] as? [String],
              !glosses.isEmpty else { return nil }
        return glosses.joined(separator: "; ")
    }

    // MARK: - 事件/快照（审计留史）

    static func insertUnitEvent(
        unitID: UUID,
        kind: LearningUnitEventKind,
        afterJSON: String?,
        atMilliseconds: Int64,
        in db: Database
    ) throws {
        try GRDBLearningUnitRepository.insertEvent(
            LearningUnitEventRecord(
                id: UUID(), operationID: UUID(),
                unitID: unitID, unitIDSnapshot: unitID,
                kind: kind, afterJSON: afterJSON,
                createdAtMs: atMilliseconds),
            in: db)
    }

    static func unitSnapshotJSON(_ unit: LearningUnit) -> String {
        // 与 flagSnapshotJSON 同款的紧凑 JSON——审计可读即可。
        "{\"identityKey\":\"\(unit.identityKey)\""
            + ",\"bindingStatus\":\"\(unit.bindingStatus.rawValue)\"}"
    }

    static func linkSnapshotJSON(
        noteID: UUID,
        role: LearningUnitNoteLinkRole,
        origin: LearningUnitNoteLinkOrigin
    ) -> String {
        "{\"noteID\":\"\(noteID.uuidString.lowercased())\""
            + ",\"role\":\"\(role.rawValue)\""
            + ",\"origin\":\"\(origin.rawValue)\"}"
    }

    // MARK: - receipt outcome 编解码

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func decodeOutcome(
        _ receipt: AIStudyReceipt
    ) -> AIStudyApplyUnitOutcome? {
        try? decoder.decode(
            AIStudyApplyUnitOutcome.self,
            from: Data(receipt.outcomeJSON.utf8))
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - unitKey 身份解析（§1.1 键空间）

/// `selection.unit_key` 的稳定键解析——与
/// `DictionarySenseBinding.identityKey`/S05 隔离 key/本地键的格式
/// 约定一一对应。解析只做形式识别，不作内容信任。
enum UnitKeyIdentity {
    /// `jmdict:sense-v1:<entryID>:<fingerprint>`。
    case dictionarySense(entryID: Int64, fingerprint: String)
    /// `jmdict:sense-iso-v1:<datasetVersion>:<entryID>:<senseID>`
    /// （同 entry 歧义的隔离键——身份可解、指纹缺省需物化）。
    case dictionarySenseIsolated(
        datasetVersion: String, entryID: Int64, senseID: Int64)
    /// `local-note:<uuid>`——每 Note 专属的本地 unit。
    case localNote(noteID: UUID)
    /// `legacy-note:`/`legacy-key:`——回填期临时身份。
    case legacy
    /// 未知前缀/形态不符——只能等既有 unit 命中，不能建。
    case unresolvable

    var entryID: Int64? {
        switch self {
        case .dictionarySense(let entryID, _): return entryID
        case .dictionarySenseIsolated(_, let entryID, _): return entryID
        case .localNote, .legacy, .unresolvable: return nil
        }
    }

    static func parse(_ unitKey: String) -> UnitKeyIdentity {
        if unitKey.hasPrefix("jmdict:sense-v1:") {
            let tail = String(
                unitKey.dropFirst("jmdict:sense-v1:".count))
            let parts = tail.split(separator: ":")
            guard parts.count == 2,
                  let entryID = Int64(parts[0]) else {
                return .unresolvable
            }
            return .dictionarySense(
                entryID: entryID, fingerprint: String(parts[1]))
        }
        if unitKey.hasPrefix("jmdict:sense-iso-v1:") {
            let tail = String(
                unitKey.dropFirst("jmdict:sense-iso-v1:".count))
            // 尾两段是 entryID/senseID；中段 datasetVersion 可含
            // 任意字符（含「:」从右往左解析免疫）。
            guard let last = tail.lastIndex(of: ":"),
                  let senseID = Int64(tail[tail.index(after: last)...]),
                  let mid = tail[..<last].lastIndex(of: ":"),
                  let entryID = Int64(tail[tail.index(after: mid)..<last])
            else { return .unresolvable }
            return .dictionarySenseIsolated(
                datasetVersion: String(tail[..<mid]),
                entryID: entryID, senseID: senseID)
        }
        if unitKey.hasPrefix("local-note:") {
            let tail = String(unitKey.dropFirst("local-note:".count))
            return UUID(uuidString: tail)
                .map(UnitKeyIdentity.localNote) ?? .unresolvable
        }
        if unitKey.hasPrefix("legacy-note:")
            || unitKey.hasPrefix("legacy-key:") {
            return .legacy
        }
        return .unresolvable
    }
}



// MARK: - 领域值类型（跨层共享）

/// unit 应用的事务上下文——Job 级不变量的一次性快照。epoch/状态
/// 复核以**事务内重读**为准，本结构只携带锚定期望值。
public struct AIStudyApplyUnitContext: Equatable, Sendable {
    public var jobID: UUID
    public var documentID: UUID
    /// Job 锚定的 `reader_documents.content_revision`（§11.1 复核）。
    public var contentRevision: Int64
    /// Job epoch 期望值（§9.2：取消 +1 后旧世代写被拒）。
    public var jobEpoch: Int64
    /// Job 行冗余的研究牌组（真值在 `reader_documents` 列，
    /// 事务内懒取——本字段仅为便捷提示）。
    public var studyDeckID: UUID?
    /// Job 的块投影（locator/sourceHash 证据链）。
    public var blocks: [AIStudyJobBlock]
    /// Job 的 resolution 行（unit 映射/回填锚）。
    public var resolutions: [AIStudyResolutionRecord]

    public init(
        jobID: UUID,
        documentID: UUID,
        contentRevision: Int64,
        jobEpoch: Int64,
        studyDeckID: UUID? = nil,
        blocks: [AIStudyJobBlock] = [],
        resolutions: [AIStudyResolutionRecord] = []
    ) {
        self.jobID = jobID
        self.documentID = documentID
        self.contentRevision = contentRevision
        self.jobEpoch = jobEpoch
        self.studyDeckID = studyDeckID
        self.blocks = blocks
        self.resolutions = resolutions
    }
}

/// 物化接缝输出——装配层把「当前数据库」不可得的证据（词典快照
/// 义项、headword/reading/释义、原文句）在事务外备好。
///
/// 应用层承诺：**binding 已用当前词典快照验算**（指纹复算一致）；
/// `binding.identityKey` 必须与 selection.unitKey 相等才允许写
/// dictionarySense unit，否则 `unitBindingConflict`（§10）。
public struct AIStudyApplyUnitSource: Equatable, Sendable {
    /// `DictionarySenseBinding.from(sense:entryID:datasetVersion:)`
    /// 产物——指纹 + 有界义项快照（unit 创建/alias/来源签名共用）。
    public var binding: DictionarySenseBinding?
    /// 新建/回退 unit 的词头（缺省回退 unit.lemma / Note headword）。
    public var headword: String?
    public var reading: String?
    /// zh→en 回退后的释义文本（`preferredGlosses` 已选语言）。
    public var meaningZH: String?
    /// `preferredGlosses` 实际语言（"zho"/"eng"）——sourceContext
    /// `selected_gloss_language` 落值，英语兜底不冒充中文。
    public var glossLanguage: String?
    /// POS code 摘要（sense.posCodes 拼接）。
    public var partOfSpeech: String?
    /// 原文句（装配层可选——缺省时应用层按 locator 重链
    /// `reader_blocks`）。
    public var sourceSentence: String?

    public init(
        binding: DictionarySenseBinding? = nil,
        headword: String? = nil,
        reading: String? = nil,
        meaningZH: String? = nil,
        glossLanguage: String? = nil,
        partOfSpeech: String? = nil,
        sourceSentence: String? = nil
    ) {
        self.binding = binding
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.glossLanguage = glossLanguage
        self.partOfSpeech = partOfSpeech
        self.sourceSentence = sourceSentence
    }
}

/// 物化接缝（§11「物化器」）：事务外把 selection 需要的证据
/// 物化成 `AIStudyApplyUnitSource`；返回 nil = 无证据可用
/// （reuse 仍可凭既有 unit/Note 推进，create 落
/// `unitEvidenceMissing`）。
public protocol AIStudyApplyUnitSourceProvider: Sendable {
    func unitSource(
        for selection: AIStudyJobSelection,
        job: AIStudyJob,
        resolutions: [AIStudyResolutionRecord],
        blocks: [AIStudyJobBlock]
    ) async throws -> AIStudyApplyUnitSource?
}

/// 默认物化器：`DictionaryRepository` + 指纹复算——unitKey 内
/// entryID 锁定候选 resolution，`evidenceRevision` 锚定同 entry
/// 多 revision，再按 binding 指纹与 key 指纹一致性消歧。
public struct DictionaryAIStudyUnitSourceProvider:
    AIStudyApplyUnitSourceProvider {
    private let repository: any DictionaryRepository

    public init(repository: any DictionaryRepository) {
        self.repository = repository
    }

    public func unitSource(
        for selection: AIStudyJobSelection,
        job: AIStudyJob,
        resolutions: [AIStudyResolutionRecord],
        blocks: [AIStudyJobBlock]
    ) async throws -> AIStudyApplyUnitSource? {
        let identity = UnitKeyIdentity.parse(selection.unitKey)
        guard let entryID = identity.entryID else {
            return nil // 非词典键——无词典证据可物化
        }
        guard let entry = try await repository.entry(id: entryID)
        else { return nil }
        let dataset = try await repository.metadata().datasetVersion

        // unitKey 精确定位 sense：v1 键含指纹——复算每个 sense 指纹
        // 命中即该义项；iso 键含 senseID 直取。
        let senses: [DictionarySense]
        switch identity {
        case .dictionarySense(_, let fingerprint):
            senses = entry.senses.filter {
                SemanticFingerprint.compute(
                    entryID: entryID, sense: $0) == fingerprint
            }
        case .dictionarySenseIsolated(_, _, let senseID):
            senses = entry.senses.filter { $0.id == senseID }
        case .localNote, .legacy, .unresolvable:
            senses = []
        }
        // resolution 锚定复核：同 entry 多个 resolution 时取
        // evidenceRevision 所指；sense 定位失败但 resolution 给出
        // senseID 时以它为准（指纹复算仍由 binding 把关）。
        let anchored = resolutions
            .filter { $0.resolution.selected?.entryID == entryID }
            .sorted { lhs, rhs in
                let lHit = lhs.revision == selection.evidenceRevision
                let rHit = rhs.revision == selection.evidenceRevision
                if lHit != rHit { return lHit }
                return lhs.revision > rhs.revision
            }
        let anchor = anchored.first
        let sense = senses.first
            ?? anchor.flatMap { record in
                record.selectedSenseID.flatMap { id in
                    entry.senses.first { $0.id == id }
                }
            }
        guard let sense else { return nil }

        let binding = try DictionarySenseBinding.from(
            sense: sense, entryID: entryID, datasetVersion: dataset)
        let preferred = sense.preferredGlosses()
        return AIStudyApplyUnitSource(
            binding: binding,
            headword: entry.primaryForm,
            reading: entry.readings.first?.reading,
            meaningZH: preferred.map {
                $0.glosses.map(\.text).joined(separator: "; ")
            },
            glossLanguage: preferred?.language,
            partOfSpeech: sense.posCodes.joined(separator: ";"))
    }
}

// MARK: - outcome / error / report

/// unit 应用结果类别——receipt `outcome_json` 与返回值共用同一
/// Codable 形态（重放解码即得历史结果）。
public enum AIStudyApplyUnitOutcomeKind: String, Codable, Sendable {
    /// 新建 Note + 卡 + membership + unit link。
    case createdNote
    /// 复用确认的既有 Note（含链接/membership/来源补记）。
    case reusedNote
    /// create 降级：unit 已有 primary，复用不复制。
    case reusedExistingPrimary
    /// create 降级：secondary 提正后复用。
    case promotedAndReused
    /// tooEasy 已置（flag+事件）。
    case tooEasySet
    /// skip/pending 锚点——只落 receipt。
    case recordedSkip
    /// 复用目标 Note 预览后被删——不落数据（§11.5 fallback）。
    case skippedNoteMissing
    /// 有删除证据——常规应用不复活已删学习对象（§5）。
    case skippedDeletedEvidence
    /// selection 已带 applied_receipt_id——重入跳过。
    case alreadyApplied
    /// action_key receipt 重放——返回历史结果零写入。
    case replayed
    /// 应用失败（receipt 未落，可重试）。
    case failed
    /// Job 中途失活——该 unit 未尝试。
    case aborted
}

/// 单 unit 应用结果（调用方/测试逐 unit 检查）。
public struct AIStudyApplyUnitOutcome: Codable, Equatable, Sendable {
    public var unitKey: String
    public var kind: AIStudyApplyUnitOutcomeKind
    /// receipt 锚定的动作类型（§4.3 actionType 分量）。
    public var actionType: AIStudyActionType?
    public var unitID: UUID?
    public var noteID: UUID?
    /// `learning_unit_note_links.role` 落值。
    public var linkRole: String?
    /// 本次新建的卡数（复用/skip 恒 0）。
    public var cardCount: Int
    /// 本次是否新增了 note_decks 行。
    public var membershipAdded: Bool
    /// 错误归类码（`AIStudyApplyError.code`；失败/skipped* 落值）。
    public var errorCode: String?
    /// 错误细节（诊断文案——不进判定，只供展示/日志）。
    public var errorDescription: String?
    /// receipt operation_id（弱引用凭据）。
    public var receiptOperationID: UUID?

    public init(
        unitKey: String,
        kind: AIStudyApplyUnitOutcomeKind,
        actionType: AIStudyActionType? = nil,
        unitID: UUID? = nil,
        noteID: UUID? = nil,
        linkRole: String? = nil,
        cardCount: Int = 0,
        membershipAdded: Bool = false,
        errorCode: String? = nil,
        errorDescription: String? = nil,
        receiptOperationID: UUID? = nil
    ) {
        self.unitKey = unitKey
        self.kind = kind
        self.actionType = actionType
        self.unitID = unitID
        self.noteID = noteID
        self.linkRole = linkRole
        self.cardCount = cardCount
        self.membershipAdded = membershipAdded
        self.errorCode = errorCode
        self.errorDescription = errorDescription
        self.receiptOperationID = receiptOperationID
    }

    /// 已结算（含 replay/有意跳过）——失败仅 `.failed`/`.aborted`。
    public var isSettled: Bool {
        kind != .failed && kind != .aborted
    }
}

/// Job 级应用报告。
public struct AIStudyApplyReport: Equatable, Sendable {
    public var jobID: UUID
    /// 应用入口时 Job 的 status（诊断快照）。
    public var entryStatus: AIStudyJobStatus
    /// 收尾后 Job 的 status（completed/partiallyCompleted/paused/
    /// cancelled…以库中实值为准）。
    public var finalStatus: AIStudyJobStatus
    /// 当前 selection revision 逐 unit 结果（unit_key 序）。
    public var units: [AIStudyApplyUnitOutcome]

    public init(
        jobID: UUID,
        entryStatus: AIStudyJobStatus,
        finalStatus: AIStudyJobStatus,
        units: [AIStudyApplyUnitOutcome]
    ) {
        self.jobID = jobID
        self.entryStatus = entryStatus
        self.finalStatus = finalStatus
        self.units = units
    }

    public var failedUnits: [AIStudyApplyUnitOutcome] {
        units.filter { !$0.isSettled }
    }
}

/// 应用层结构化错误（§10/§11 必须可编程分支，不靠字符串匹配）。
public enum AIStudyApplyError: Error, Equatable, Sendable {
    case jobNotFound(UUID)
    /// Job 不在可应用状态（非 awaitingConfirmation/applying/
    /// partiallyCompleted；completed 走幂等报告路径不报错）。
    case jobNotAppliable(status: AIStudyJobStatus)
    /// unit 事务内复核：Job 被暂停/取消/结算——epoch/状态漂移。
    case jobStateChanged(
        expectedEpoch: Int64,
        foundStatus: AIStudyJobStatus,
        foundEpoch: Int64)
    /// 文档行不存在（弱引用失效——§5 missingSource 语义）。
    case documentMissing(UUID)
    /// `reader_documents.content_revision` 与 Job 锚定不符（§5
    /// 内容过期——旧选择不自动继续）。
    case staleDocumentRevision(expected: Int64, found: Int64)
    /// decision/proposedAction 不自洽或缺必要载荷。
    case invalidSelection(String)
    /// unitKey 无既有 unit 且按键空间规则不能创建（local/legacy/
    /// 未知前缀）。
    case unitKeyNotResolvable(String)
    /// 需要物化证据（binding/lemma）但 source/provider 未供给。
    case unitEvidenceMissing(String)
    /// binding 复算的 identityKey 与 selection.unitKey 不符——
    /// 快照漂移/绑定竞态（§10 局部刷新重新确认，不盲写）。
    case unitBindingConflict(unitKey: String, bindingKey: String)
    /// 复用目标 Note 不存在（settle-skip 的归类码也用它）。
    case noteMissing(UUID)
    /// Note 存在但非 vocabulary——不可链接 unit。
    case noteNotVocabulary(UUID)
    /// Note 已绑定到另一 unit——不抢不合并（D02）。
    case noteBoundElsewhere(noteID: UUID, unitID: UUID)
    /// membership 目标牌组不存在。
    case deckMissing(UUID)
    /// action_key 命中异 payload receipt——拒绝（§4.3）。
    case receiptConflict(String)
    /// 底层持久化/领域错误的兜底归类（保留原始描述供诊断）。
    case storage(String)

    /// outcome.errorCode 的稳定归类码（测试/遥测按键，不靠文案）。
    public var code: String {
        switch self {
        case .jobNotFound: return "jobNotFound"
        case .jobNotAppliable: return "jobNotAppliable"
        case .jobStateChanged: return "jobStateChanged"
        case .documentMissing: return "documentMissing"
        case .staleDocumentRevision: return "staleDocumentRevision"
        case .invalidSelection: return "invalidSelection"
        case .unitKeyNotResolvable: return "unitKeyNotResolvable"
        case .unitEvidenceMissing: return "unitEvidenceMissing"
        case .unitBindingConflict: return "unitBindingConflict"
        case .noteMissing: return "noteMissing"
        case .noteNotVocabulary: return "noteNotVocabulary"
        case .noteBoundElsewhere: return "noteBoundElsewhere"
        case .deckMissing: return "deckMissing"
        case .receiptConflict: return "receiptConflict"
        case .storage: return "storage"
        }
    }
}

// MARK: - Job 编排（实例包装）

/// AI Study 应用服务——`DatabasePool` 上的 Job 级编排。每个 unit
/// 独立短事务：一 unit 失败不拖跨 unit，逐条 outcome 可检查。
public struct AIStudyApplyService: Sendable {
    private let pool: DatabasePool
    private let unitSources: any AIStudyApplyUnitSourceProvider
    private let now: @Sendable () -> Date

    public init(
        pool: DatabasePool,
        unitSources: any AIStudyApplyUnitSourceProvider,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pool = pool
        self.unitSources = unitSources
        self.now = now
    }

    public init(
        database: OboeDatabase,
        unitSources: any AIStudyApplyUnitSourceProvider,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(pool: database.pool, unitSources: unitSources, now: now)
    }

    private var nowMs: Int64 {
        Int64(now().timeIntervalSince1970 * 1_000)
    }

    /// 应用已确认 Job 的当前 selection revision。
    ///
    /// - awaitingConfirmation/partiallyCompleted → applying 推进；
    /// - applying（崩溃恢复重入）→ 直接续跑未结算 unit；
    /// - completed → 幂等报告（只读重建 outcome，零写入）；
    /// - 其余状态 → `jobNotAppliable`。
    ///
    /// 收尾：`applying → completed`（全 unit 结算且无失败块）；
    /// 有失败 unit/失败块 → `partiallyCompleted`（§9 非终态可续）；
    /// 文档 revision 漂移 → `paused(.contentStale)`；文档缺失 →
    /// `paused(.missingSource)`；Job 中途被取消/暂停 → 保留现态。
    @discardableResult
    public func applyConfirmedJob(
        jobID: UUID,
        rebuildIntent: AIStudyRebuildIntent = .none
    ) async throws -> AIStudyApplyReport {
        // 1) Job 复核 + 进入 applying（epoch-guarded，同 store API）。
        let entry = try await pool.write { db -> AIStudyJob in
            guard let job = try GRDBAIStudyJobStore.fetchJob(
                id: jobID, in: db) else {
                throw AIStudyApplyError.jobNotFound(jobID)
            }
            switch job.status {
            case .awaitingConfirmation, .partiallyCompleted:
                return try GRDBAIStudyJobStore.transitionJob(
                    id: jobID, to: .applying,
                    expectedEpoch: job.epoch, atMs: nowMs, in: db)
            case .applying:
                return job // 崩溃恢复重入：直接续跑
            case .completed:
                return job // 幂等报告路径（外层只读）
            default:
                throw AIStudyApplyError.jobNotAppliable(
                    status: job.status)
            }
        }

        if entry.status == .completed {
            let units = try await replayedOutcomes(jobID: jobID)
            return AIStudyApplyReport(
                jobID: jobID, entryStatus: .completed,
                finalStatus: .completed, units: units)
        }

        // 2) 装载 Job 上下文（一次读事务：当前 revision selections
        //    + blocks + resolutions——证据链一次性入快照）。
        let bundle = try await pool.read { db -> (
            context: AIStudyApplyUnitContext,
            selections: [AIStudyJobSelection]
        ) in
            let selections = try GRDBAIStudyJobStore.fetchSelections(
                jobID: jobID, in: db
            ).filter { $0.selectionRevision == entry.selectionRevision }
                .sorted { $0.unitKey < $1.unitKey }
            let context = AIStudyApplyUnitContext(
                jobID: jobID, documentID: entry.documentID,
                contentRevision: entry.contentRevision,
                jobEpoch: entry.epoch,
                studyDeckID: entry.studyDeckID,
                blocks: try GRDBAIStudyJobStore.fetchBlocks(
                    jobID: jobID, in: db),
                resolutions: try GRDBAIStudyJobStore.fetchResolutions(
                    jobID: jobID, in: db))
            return (context, selections)
        }
        let context = bundle.context

        // 3) 逐 unit 独立短事务。
        var outcomes: [AIStudyApplyUnitOutcome] = []
        var abortError: AIStudyApplyError?
        for selection in bundle.selections {
            if abortError != nil {
                outcomes.append(AIStudyApplyUnitOutcome(
                    unitKey: selection.unitKey, kind: .aborted,
                    errorCode: abortError?.code))
                continue
            }
            let source = try? await unitSources.unitSource(
                for: selection, job: entry,
                resolutions: context.resolutions,
                blocks: context.blocks)
            do {
                let outcome = try await pool.write { db in
                    try GRDBAIStudyApplyService.applyUnit(
                        context: context, selection: selection,
                        source: source,
                        rebuildIntent: rebuildIntent,
                        atMilliseconds: nowMs, in: db)
                }
                outcomes.append(outcome)
            } catch let error as AIStudyApplyError {
                switch error {
                case .jobStateChanged:
                    abortError = error
                case .documentMissing, .staleDocumentRevision:
                    // 文档证据失效——剩余 unit 必然同样失败，
                    // 提前收束（outcome 记 aborted）。
                    abortError = error
                default:
                    break
                }
                outcomes.append(AIStudyApplyUnitOutcome(
                    unitKey: selection.unitKey, kind: .failed,
                    actionType: nil,
                    errorCode: error.code,
                    errorDescription: String(describing: error)))
            } catch {
                outcomes.append(AIStudyApplyUnitOutcome(
                    unitKey: selection.unitKey, kind: .failed,
                    errorCode: AIStudyApplyError.storage("").code,
                    errorDescription: String(describing: error)))
            }
        }

        // 4) 收尾：所有者块推进 applied + Job 终态迁移（同事务）。
        //    捕获值先落成 let——@Sendable 闭包不能捕获 inout/var。
        let abortReason = abortError
        let hasUnitFailures = outcomes.contains { !$0.isSettled }
        let finalStatus = try await pool.write { db -> AIStudyJobStatus in
            guard let job = try GRDBAIStudyJobStore.fetchJob(
                id: jobID, in: db) else {
                throw AIStudyApplyError.jobNotFound(jobID)
            }
            guard job.status == .applying,
                  job.epoch == context.jobEpoch else {
                return job.status // 中途被取消/暂停——保留现态
            }
            if case .documentMissing = abortReason {
                return (try GRDBAIStudyJobStore.transitionJob(
                    id: jobID, to: .paused,
                    expectedEpoch: job.epoch, atMs: nowMs,
                    resumeReason: .missingSource, in: db)).status
            }
            if case .staleDocumentRevision = abortReason {
                return (try GRDBAIStudyJobStore.transitionJob(
                    id: jobID, to: .paused,
                    expectedEpoch: job.epoch, atMs: nowMs,
                    resumeReason: .contentStale, in: db)).status
            }
            try advanceOwnerBlocks(
                context: context,
                selectionRevision: entry.selectionRevision,
                atMs: nowMs, in: db)
            let failedBlocks = try GRDBAIStudyJobStore.fetchBlocks(
                jobID: jobID, in: db
            ).contains { $0.status == .failed }
            let target: AIStudyJobStatus =
                (hasUnitFailures || failedBlocks)
                ? .partiallyCompleted : .completed
            return (try GRDBAIStudyJobStore.transitionJob(
                id: jobID, to: target,
                expectedEpoch: job.epoch, atMs: nowMs, in: db)).status
        }

        // S20：应用收尾即落整文档 Coverage v2 快照（best-effort——
        // 快照是历史留痕，失败只记日志绝不推翻已提交的应用；
        // 入口 `.completed` 的只读重放路径不落——零写入契约）。
        // 文档已删（missingSource）时投影必败，跳过不刷日志噪声。
        if case .documentMissing = abortError {
            // 文档缺失——无投影对象，快照留待下次有效应用。
        } else {
            await recordCoverageSnapshot(
                jobID: jobID, documentID: entry.documentID)
        }

        return AIStudyApplyReport(
            jobID: jobID, entryStatus: entry.status,
            finalStatus: finalStatus, units: outcomes)
    }

    /// v26 快照 best-effort 写入（S20 集成点）：独立短事务，
    /// 失败经 `snapshotLogger` 记录后继续——度量行绝不当业务
    /// 失败的乘数。版本分量取 Job 冻结 manifest（快照归因到
    /// 产出它的分析上下文）；manifest 缺席降级 "unknown"——
    /// 保留快照行不丢历史，版本字段如实标记来源缺失。
    private func recordCoverageSnapshot(
        jobID: UUID, documentID: UUID
    ) async {
        do {
            try await pool.write { db in
                let manifest = try Data.fetchOne(
                    db,
                    sql: """
                        SELECT manifest FROM ai_study_job_manifests
                        WHERE job_id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(jobID)]
                ).flatMap { try? AIStudyJobManifest.decode($0) }
                try GRDBReaderCoverageSnapshotStore
                    .recordDocumentSnapshot(
                        documentID: documentID,
                        dictionaryVersion:
                            manifest?.dictionaryDatasetVersion
                                ?? "unknown",
                        morphologyVersion: manifest?.morphologyVersion
                            ?? "unknown",
                        at: now(), in: db)
            }
        } catch {
            Self.snapshotLogger.error(
                "coverage snapshot skipped for job \(jobID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// S20 快照失败的统一日志点（与 preparation 侧同纪律）。
    private static let snapshotLogger = Logger(
        subsystem: "com.oboe.infra",
        category: "ai-study-coverage")

    /// completed Job 的幂等报告——只读重建逐 unit 结果（receipt
    /// outcomeJSON 优先，缺失退化为 alreadyApplied）。
    private func replayedOutcomes(
        jobID: UUID
    ) async throws -> [AIStudyApplyUnitOutcome] {
        try await pool.read { db in
            guard let job = try GRDBAIStudyJobStore.fetchJob(
                id: jobID, in: db) else {
                throw AIStudyApplyError.jobNotFound(jobID)
            }
            return try GRDBAIStudyJobStore.fetchSelections(
                jobID: jobID, in: db
            ).filter { $0.selectionRevision == job.selectionRevision }
                .sorted { $0.unitKey < $1.unitKey }
                .map { selection in
                    var outcome = selection.appliedReceiptID
                        .flatMap { id in
                            try? GRDBAIStudyJobStore.fetchReceipt(
                                operationID: id, in: db)
                        }
                        .flatMap(GRDBAIStudyApplyService.decodeOutcome)
                        ?? AIStudyApplyUnitOutcome(
                            unitKey: selection.unitKey,
                            kind: .alreadyApplied)
                    outcome.kind = .alreadyApplied
                    outcome.receiptOperationID =
                        selection.appliedReceiptID
                    return outcome
                }
        }
    }

    /// 所有者块推进：`resolved/awaitingConfirmation/applying` 且
    /// 其映射 unit 的当前选择全部已结算 → `.applied`（§4.1 块终
    /// 态）。无映射选择的块不动（其产出未被选择消费——归 S15
    /// 确认侧管辖）。
    private func advanceOwnerBlocks(
        context: AIStudyApplyUnitContext,
        selectionRevision: Int64,
        atMs: Int64,
        in db: Database
    ) throws {
        let selections = try GRDBAIStudyJobStore.fetchSelections(
            jobID: context.jobID, in: db
        ).filter { $0.selectionRevision == selectionRevision }
        let appliedKeys = Set(
            selections
                .filter { $0.appliedReceiptID != nil }
                .map(\.unitKey))
        // block → 相关 unitKey：resolution.selected.entryID ↔
        // unitKey entryID 分量（与 matchedResolutions 同解析）。
        var unitKeysByBlock: [UUID: Set<String>] = [:]
        for selection in selections {
            guard let entryID = UnitKeyIdentity.parse(
                selection.unitKey).entryID else { continue }
            for resolution in context.resolutions
            where resolution.jobBlockID != nil
                && resolution.resolution.selected?.entryID == entryID {
                unitKeysByBlock[resolution.jobBlockID!, default: []]
                    .insert(selection.unitKey)
            }
        }
        for block in context.blocks {
            guard let keys = unitKeysByBlock[block.id],
                  !keys.isEmpty,
                  keys.isSubset(of: appliedKeys) else { continue }
            var current = try GRDBAIStudyJobStore.fetchBlock(
                id: block.id, in: db) ?? block
            if current.status == .resolved {
                current = try GRDBAIStudyJobStore.transitionBlock(
                    id: current.id, to: .awaitingConfirmation,
                    expectedJobEpoch: context.jobEpoch,
                    atMs: atMs, in: db)
            }
            if current.status == .awaitingConfirmation {
                current = try GRDBAIStudyJobStore.transitionBlock(
                    id: current.id, to: .applying,
                    expectedJobEpoch: context.jobEpoch,
                    atMs: atMs, in: db)
            }
            if current.status == .applying {
                _ = try GRDBAIStudyJobStore.transitionBlock(
                    id: current.id, to: .applied,
                    expectedJobEpoch: context.jobEpoch,
                    atMs: atMs, in: db)
            }
        }
    }
}


