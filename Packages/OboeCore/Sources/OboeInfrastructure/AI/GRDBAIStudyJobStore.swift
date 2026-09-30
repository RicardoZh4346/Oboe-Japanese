import Foundation
import GRDB
import OboeDomain

/// v0.7.5 S12：`ai_study_*` pipeline 表（v25）的 GRDB 持久化门面。
/// 依据：contracts-frozen §4.1–§4.3、§6 v25 冻结表；技术文档
/// §9.1（checkpoint/恢复协议）、§9.2（epoch/lease/退避）。
///
/// # 关键语义
///
/// - **状态机唯一实现点**：所有 Job/Block status 写入前都经
///   `AIStudyJobStateMachine.transition` 在事务内复核——非法转移
///   直接 `throw`，整个事务回滚，绝不落非法状态。
/// - **epoch 乐观锁**：携带 epoch 的写一律在同一 UPDATE 的 WHERE
///   内核对（`WHERE id=? AND epoch=?` / 块表 `EXISTS(job.epoch=?)`）
///   并校验 `changesCount`——取消 bump epoch 后，迟到写被拒绝且
///   回滚已附带的 resolutions/cache 写（同事务）。
/// - **lease 语义**：`lease_epoch` = 领取时刻的 job.epoch。requesting
///   且无 resultID 的块在恢复时被视作「死 lease」重新领取（同状态
///   续约，非状态转移；§9.1.5 未知窗口允许重发）。
/// - **幂等**：resolution `(request_hash, token_key, revision)` 唯一——
///   每次落库取 `MAX(revision)+1`，重分析不覆盖历史；receipt 命中
///   `action_key`/`operation_id` 冲突视为 replay——payload 相同返回
///   既有行，不同抛 `receiptConflict`（§4.3 第三层）。
/// - **缓存**：`ai_study_cache` 存 `AIStudyCachedResult` JSON（校验后
///   结果 + 供给方快照），`last_accessed_at_ms` LRU，容量有界逐出。
/// - **计数列**：job 的 processed/applied/confirmed/failed 四列是
///   派生冗余——每次块转移同事务由块/selection 表重算刷新，
///   恢复后可整体重算修复（§9「分开计数」）。
///
/// 形态约定与 `GRDBLearningUnitRepository` 一致：全部读写以
/// `static func …(in db: Database)` 事务内形态暴露，实例方法只是
/// `pool.read/write` 的薄 async 门面。
public struct GRDBAIStudyJobStore: Sendable {
    private let pool: DatabasePool

    /// 底层连接池——宿主层装配共享同库组件（如
    /// `AIStudyPreparationService`）时使用；不暴露给 UI。
    public var databasePool: DatabasePool { pool }

    public init(pool: DatabasePool) {
        self.pool = pool
    }

    public init(database: OboeDatabase) {
        pool = database.pool
    }
}

/// 持久层错误（状态机非法转移直接抛 `AIStudyJobTransitionError`）。
public enum AIStudyJobStoreError: Error, Equatable, Sendable {
    /// Job 行不存在。
    case jobNotFound(UUID)
    /// 块行不存在。
    case blockNotFound(UUID)
    /// epoch 乐观锁失败：写入方观察到 `expected`，库里已是 `found`——
    /// 取消/重建后旧世代的写在此被拒（§9.2 迟到响应拒写）。
    case staleJobEpoch(jobID: UUID, expected: Int64, found: Int64?)
    /// 块不在可领取派发状态（已被其他路径移动/已有结果）。
    case blockNotClaimable(blockID: UUID, status: AIStudyBlockStatus)
    /// 同一 document/revision 已存在活跃 Job（部分唯一索引语义）。
    case activeJobConflict(documentID: UUID, contentRevision: Int64)
    /// receipt 幂等冲突：action_key/operation_id 命中但 payload 不同
    /// （§4.3：同 ID 异 payload 拒绝）。
    case receiptConflict(String)
    /// 持久化内容违反内部不变量（枚举值/JSON 解码失败等）。
    case inconsistentStorage(String)
}

// MARK: - 缓存负载（ai_study_cache.validated_result_json）

/// `ai_study_cache.validated_result_json` 的负载格式（`aiscache1`）。
///
/// 保存一次请求的**校验后完整产物**：`ValidatedBlockOutcome` 全字段
/// （lexical/translation 子状态、resolutions、诊断计数）+ 请求元数据
/// 供给方快照。缓存命中/在途合并时直接用它持久化块结果，零网络。
///
/// `resultID` 是块行 `result_id` 弱引用的目标——同一请求的所有
/// 消费者共享同一 resultID（缓存键即语义键，D12 弱引用语义）。
public struct AIStudyCachedResult: Codable, Equatable, Sendable {
    public static let formatVersion = "aiscache1"

    /// `AIStudyResolution` 的 Codable 投影（领域类型非 Codable，
    /// 此处为缓存私有编码形态——字段 1:1 对应）。
    public struct Resolution: Codable, Equatable, Sendable {
        public var tokenKey: String
        public var provider: String?
        public var entryID: Int64?
        public var senseID: Int64?
        public var datasetVersion: String?
        public var confidence: Double?
        public var status: AIStudyResolutionStatus
        public var reasonCode: AIStudyReasonCode?
        public var origin: AIStudyResolutionOrigin

        public init(_ resolution: AIStudyResolution) {
            tokenKey = resolution.tokenKey
            provider = resolution.selected?.provider
            entryID = resolution.selected?.entryID
            senseID = resolution.selected?.senseID
            datasetVersion = resolution.selected?.datasetVersion
            confidence = resolution.confidence
            status = resolution.status
            reasonCode = resolution.reasonCode
            origin = resolution.origin
        }

        public var resolution: AIStudyResolution {
            let selection: AIStudySelection?
            if let provider, let entryID, let senseID, let datasetVersion {
                selection = AIStudySelection(
                    provider: provider, entryID: entryID,
                    senseID: senseID, datasetVersion: datasetVersion)
            } else {
                selection = nil
            }
            return AIStudyResolution(
                tokenKey: tokenKey, selected: selection,
                confidence: confidence, status: status,
                reasonCode: reasonCode, origin: origin)
        }
    }

    public var version: String
    /// 弱引用 ID（块 `result_id` 所指）。
    public var resultID: UUID
    public var requestHash: String
    public var requestID: String
    public var blockKey: String
    public var lexicalStatus: AIStudyLexicalStatus
    public var translationStatus: AIStudyTranslationStatus
    public var translation: String?
    /// `AIStudyEnvelopeRejection.rawValue`（该枚举无 Codable）。
    public var envelopeRejection: String?
    public var resolutions: [Resolution]

    // 诊断计数（§3.3 BlockOutcome 全字段——缓存命中要能完整重建）。
    public var targetTokenCount: Int
    public var aiResolvedCount: Int
    public var lowConfidenceCount: Int
    public var unresolvedTokenCount: Int
    public var droppedUnknownTokenCount: Int
    public var duplicateTokenCount: Int
    public var malformedItemCount: Int
    public var invalidItemCount: Int

    // 供给方快照（§7：取请求元数据，不接受自报）。
    public var providerKind: String
    public var model: String
    public var promptVersion: String
    public var responseMode: String
    public var resolvedAtMs: Int64

    public init(
        result: AIStudyResolverResult, resultID: UUID, atMs: Int64
    ) {
        let outcome = result.outcome
        version = Self.formatVersion
        self.resultID = resultID
        requestHash = result.requestHash
        requestID = result.requestID
        blockKey = outcome.blockKey
        lexicalStatus = outcome.lexicalStatus
        translationStatus = outcome.translationStatus
        translation = outcome.translation
        envelopeRejection = outcome.envelopeRejection?.rawValue
        resolutions = outcome.resolutions.map(Resolution.init)
        targetTokenCount = outcome.targetTokenCount
        aiResolvedCount = outcome.aiResolvedCount
        lowConfidenceCount = outcome.lowConfidenceCount
        unresolvedTokenCount = outcome.unresolvedTokenCount
        droppedUnknownTokenCount = outcome.droppedUnknownTokenCount
        duplicateTokenCount = outcome.duplicateTokenCount
        malformedItemCount = outcome.malformedItemCount
        invalidItemCount = outcome.invalidItemCount
        providerKind = result.providerKind
        model = result.model
        promptVersion = result.promptVersion
        responseMode = result.responseMode.rawValue
        resolvedAtMs = atMs
    }

    /// 重建 `ValidatedBlockOutcome`（合并/命中路径写 resolutions 用）。
    public var outcome: ValidatedBlockOutcome {
        ValidatedBlockOutcome(
            blockKey: blockKey,
            lexicalStatus: lexicalStatus,
            translationStatus: translationStatus,
            translation: translation,
            envelopeRejection: envelopeRejection.flatMap(
                AIStudyEnvelopeRejection.init(rawValue:)),
            resolutions: resolutions.map(\.resolution),
            targetTokenCount: targetTokenCount,
            aiResolvedCount: aiResolvedCount,
            lowConfidenceCount: lowConfidenceCount,
            unresolvedTokenCount: unresolvedTokenCount,
            droppedUnknownTokenCount: droppedUnknownTokenCount,
            duplicateTokenCount: duplicateTokenCount,
            malformedItemCount: malformedItemCount,
            invalidItemCount: invalidItemCount)
    }
}

extension GRDBAIStudyJobStore {

    // MARK: - Job 写入

    /// 插入 Job + 初始块（同事务）。块按给定状态原样落库
    /// （插入是创建不是转移；Runner 定稿块以 `readyForAI` 落库，
    /// 对应 pending→analyzing→readyForAI 已完成的分析产物）。
    ///
    /// 同 document/revision 已有活跃 Job → `activeJobConflict`
    /// （先查友好报错，部分唯一索引兜底）。
    public static func insertJob(
        _ job: AIStudyJob,
        blocks: [AIStudyJobBlock] = [],
        in db: Database
    ) throws {
        if try activeJobExists(
            documentID: job.documentID,
            contentRevision: job.contentRevision,
            excluding: nil, in: db
        ) {
            throw AIStudyJobStoreError.activeJobConflict(
                documentID: job.documentID,
                contentRevision: job.contentRevision)
        }
        let scopeJSON = try encodeJSON(job.scope, column: "scope_json")
        let snapshotJSON = try encodeJSON(
            job.providerSnapshot, column: "provider_snapshot_json")
        do {
            try db.execute(
                sql: """
                    INSERT INTO ai_study_jobs(
                        id, document_id, study_deck_id, scope_json,
                        input_fingerprint, content_revision,
                        provider_snapshot_json, model, pipeline_version,
                        prompt_version, policy_version, status,
                        epoch, selection_revision, resume_reason,
                        processed_blocks, applied_units, confirmed_units,
                        failed_blocks, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(job.id),
                    DatabaseValueCodec.encode(job.documentID),
                    job.studyDeckID.map(DatabaseValueCodec.encode),
                    scopeJSON,
                    job.inputFingerprint,
                    job.contentRevision,
                    snapshotJSON,
                    job.model,
                    job.pipelineVersion,
                    job.promptVersion,
                    job.policyVersion,
                    job.status.rawValue,
                    job.epoch,
                    job.selectionRevision,
                    job.resumeReason?.rawValue,
                    job.processedBlocks,
                    job.appliedUnits,
                    job.confirmedUnits,
                    job.failedBlocks,
                    job.createdAtMs,
                    job.updatedAtMs,
                ])
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CONSTRAINT
                && (error.message?.contains(
                    "ai_study_jobs_one_active_per_document") ?? false)
        {
            throw AIStudyJobStoreError.activeJobConflict(
                documentID: job.documentID,
                contentRevision: job.contentRevision)
        }
        for block in blocks {
            try insertBlock(block, in: db)
        }
    }

    /// Job 状态转移（epoch-guarded）：事务内读行 → 状态机复核 →
    /// `UPDATE … WHERE id=? AND epoch=? AND status=?` 校验
    /// changesCount——并发/迟到写在此被拒。
    ///
    /// →cancelled 经状态机自动 epoch+1；→paused 落 resumeReason；
    /// 离开 paused 自动清 resumeReason（状态机语义原样执行）。
    @discardableResult
    public static func transitionJob(
        id: UUID,
        to newStatus: AIStudyJobStatus,
        expectedEpoch: Int64,
        atMs: Int64,
        resumeReason: AIStudyResumeReason? = nil,
        in db: Database
    ) throws -> AIStudyJob {
        guard var job = try fetchJob(id: id, in: db) else {
            throw AIStudyJobStoreError.jobNotFound(id)
        }
        guard job.epoch == expectedEpoch else {
            throw AIStudyJobStoreError.staleJobEpoch(
                jobID: id, expected: expectedEpoch, found: job.epoch)
        }
        let oldStatus = job.status
        try AIStudyJobStateMachine.transition(
            &job, to: newStatus, atMs: atMs, resumeReason: resumeReason)
        try db.execute(
            sql: """
                UPDATE ai_study_jobs SET
                    status = ?, epoch = ?, selection_revision = ?,
                    resume_reason = ?, updated_at_ms = ?
                WHERE id = ? AND epoch = ? AND status = ?
                """,
            arguments: [
                job.status.rawValue, job.epoch, job.selectionRevision,
                job.resumeReason?.rawValue, job.updatedAtMs,
                DatabaseValueCodec.encode(id), expectedEpoch,
                oldStatus.rawValue,
            ])
        guard db.changesCount == 1 else {
            throw AIStudyJobStoreError.staleJobEpoch(
                jobID: id, expected: expectedEpoch, found: nil)
        }
        return job
    }

    /// 派生计数重算刷新（§9 分开计数：四列可重算非真相）：
    /// - processedBlocks = 已结束本轮请求处理的块（resolved /
    ///   awaitingConfirmation / applying / applied / retryScheduled /
    ///   failed——retryScheduled 本轮已出结果，不算未完成）。
    /// - failedBlocks = status='failed'。
    /// - confirmedUnits = selections 中 decision != 'pending' 的
    ///   unit_key 去重数。
    /// - appliedUnits = selections 中 applied_receipt_id 非空的
    ///   unit_key 去重数。
    ///
    /// 在块转移事务内调用保持同事务一致（runner 每步落库后刷新）。
    public static func refreshJobCounters(
        jobID: UUID, atMs: Int64, in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE ai_study_jobs SET
                    processed_blocks = (
                        SELECT COUNT(*) FROM ai_study_job_blocks
                        WHERE job_id = ? AND status IN
                            ('resolved', 'awaitingConfirmation',
                             'applying', 'applied', 'retryScheduled',
                             'failed')),
                    failed_blocks = (
                        SELECT COUNT(*) FROM ai_study_job_blocks
                        WHERE job_id = ? AND status = 'failed'),
                    confirmed_units = (
                        SELECT COUNT(DISTINCT unit_key)
                        FROM ai_study_selections
                        WHERE job_id = ? AND decision != 'pending'),
                    applied_units = (
                        SELECT COUNT(DISTINCT unit_key)
                        FROM ai_study_selections
                        WHERE job_id = ?
                              AND applied_receipt_id IS NOT NULL),
                    updated_at_ms = ?
                WHERE id = ?
                """,
            arguments: [
                DatabaseValueCodec.encode(jobID),
                DatabaseValueCodec.encode(jobID),
                DatabaseValueCodec.encode(jobID),
                DatabaseValueCodec.encode(jobID),
                atMs,
                DatabaseValueCodec.encode(jobID),
            ])
    }

    // MARK: - Job 读取

    public static func fetchJob(
        id: UUID, in db: Database
    ) throws -> AIStudyJob? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, document_id, study_deck_id, scope_json,
                       input_fingerprint, content_revision,
                       provider_snapshot_json, model, pipeline_version,
                       prompt_version, policy_version, status, epoch,
                       selection_revision, resume_reason,
                       processed_blocks, applied_units, confirmed_units,
                       failed_blocks, created_at_ms, updated_at_ms
                FROM ai_study_jobs WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        ).map(decodeJob)
    }

    /// 某 document/revision 的活跃（非终态）Job——部分唯一索引保证
    /// 至多一行。
    public static func fetchActiveJob(
        documentID: UUID, contentRevision: Int64, in db: Database
    ) throws -> AIStudyJob? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT id, document_id, study_deck_id, scope_json,
                       input_fingerprint, content_revision,
                       provider_snapshot_json, model, pipeline_version,
                       prompt_version, policy_version, status, epoch,
                       selection_revision, resume_reason,
                       processed_blocks, applied_units, confirmed_units,
                       failed_blocks, created_at_ms, updated_at_ms
                FROM ai_study_jobs
                WHERE document_id = ? AND content_revision = ?
                      AND status NOT IN ('completed', 'cancelled', 'failed')
                """,
            arguments: [
                DatabaseValueCodec.encode(documentID), contentRevision,
            ]
        ).map(decodeJob)
    }

    // MARK: - Block 写入

    /// 裸插入块行（创建而非转移；供 insertJob / 恢复重建使用）。
    public static func insertBlock(
        _ block: AIStudyJobBlock, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_job_blocks(
                    id, job_id, locator_json, source_hash, subblock_key,
                    candidate_set_hash, request_hash, status,
                    attempt_count, next_retry_at_ms, lease_epoch,
                    result_id, last_error_code)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(block.id),
                DatabaseValueCodec.encode(block.jobID),
                block.locatorJSON,
                block.sourceHash,
                block.subblockKey,
                block.candidateSetHash,
                block.requestHash,
                block.status.rawValue,
                block.attemptCount,
                block.nextRetryAtMs,
                block.leaseEpoch,
                block.resultID.map(DatabaseValueCodec.encode),
                block.lastErrorCode,
            ])
    }

    /// 插入 planner 定稿块：subblock_key 已存在则跳过（恢复重放
    /// plan 不覆盖既有 checkpoint）。返回实际插入的行数。
    /// epoch-guarded：job.epoch 已漂移 → `staleJobEpoch`，整批回滚。
    @discardableResult
    public static func insertBlocksIfAbsent(
        jobID: UUID,
        blocks: [AIStudyJobBlock],
        expectedEpoch: Int64,
        in db: Database
    ) throws -> Int {
        try requireJobEpoch(jobID: jobID, expected: expectedEpoch, in: db)
        let existing = try Set(
            String.fetchAll(
                db,
                sql: """
                    SELECT subblock_key FROM ai_study_job_blocks
                    WHERE job_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)]))
        var inserted = 0
        for block in blocks where !existing.contains(block.subblockKey) {
            try insertBlock(block, in: db)
            inserted += 1
        }
        return inserted
    }

    /// 通用块转移（epoch-guarded）：事务内读块 → 状态机复核 →
    /// guarded UPDATE（同语句核对块旧状态与 job.epoch）→ 刷新计数。
    /// 迟到/非法写：status 漂移或 epoch 漂移 → changesCount=0 →
    /// `staleJobEpoch`；非法转移 → `AIStudyJobTransitionError`。
    @discardableResult
    public static func transitionBlock(
        id: UUID,
        to newStatus: AIStudyBlockStatus,
        context: AIStudyBlockTransitionContext = .init(),
        expectedJobEpoch: Int64,
        atMs: Int64,
        in db: Database
    ) throws -> AIStudyJobBlock {
        guard var block = try fetchBlock(id: id, in: db) else {
            throw AIStudyJobStoreError.blockNotFound(id)
        }
        try requireJobEpoch(
            jobID: block.jobID, expected: expectedJobEpoch, in: db)
        let oldStatus = block.status
        try AIStudyJobStateMachine.transition(
            &block, to: newStatus, context: context)
        try writeBlock(block, from: oldStatus,
                       expectedJobEpoch: expectedJobEpoch, in: db)
        try refreshJobCounters(jobID: block.jobID, atMs: atMs, in: db)
        return block
    }

    /// 派发领取（lease）：把可派发块推进到 requesting 并登记
    /// `lease_epoch`（= 当前 job.epoch）。
    ///
    /// 三种来源：
    /// - `readyForAI` → requesting（attempt+1，§9.1.1 派发前提交 attempt）；
    /// - `retryScheduled`（到期）→ readyForAI → requesting（两跳同
    ///   事务，对外一次领取）；
    /// - `requesting` 且 `result_id` 为空 → **死 lease 续约**：状态
    ///   不变、attempt+1、换新 leaseEpoch（§9.1.5：无持久化结果的
    ///   未知窗口允许重发）。这不是状态转移——lease 是本机并发
    ///   租约，续约不写入新 status。
    ///
    /// `countAttempt=false` 供缓存命中路径使用：解析缓存不算一次
    /// 真实派发（不烧退避额度）。
    @discardableResult
    public static func claimBlockForDispatch(
        id: UUID,
        leaseEpoch: Int64,
        expectedJobEpoch: Int64,
        countAttempt: Bool = true,
        atMs: Int64,
        in db: Database
    ) throws -> AIStudyJobBlock {
        guard var block = try fetchBlock(id: id, in: db) else {
            throw AIStudyJobStoreError.blockNotFound(id)
        }
        try requireJobEpoch(
            jobID: block.jobID, expected: expectedJobEpoch, in: db)
        let oldStatus = block.status
        switch block.status {
        case .readyForAI:
            try AIStudyJobStateMachine.transition(
                &block, to: .requesting,
                context: AIStudyBlockTransitionContext(
                    leaseEpoch: leaseEpoch,
                    incrementAttemptCount: countAttempt))
        case .retryScheduled:
            try AIStudyJobStateMachine.transition(
                &block, to: .readyForAI)
            try AIStudyJobStateMachine.transition(
                &block, to: .requesting,
                context: AIStudyBlockTransitionContext(
                    leaseEpoch: leaseEpoch,
                    incrementAttemptCount: countAttempt))
        case .requesting:
            // 死 lease 续约：仅当无持久化结果（有结果走
            // usePersistedResult，绝不重发，D10）。
            guard block.resultID == nil else {
                throw AIStudyJobStoreError.blockNotClaimable(
                    blockID: id, status: block.status)
            }
            if countAttempt { block.attemptCount += 1 }
            block.leaseEpoch = leaseEpoch
            block.nextRetryAtMs = nil
            block.lastErrorCode = nil
        default:
            throw AIStudyJobStoreError.blockNotClaimable(
                blockID: id, status: block.status)
        }
        try writeBlock(block, from: oldStatus,
                       expectedJobEpoch: expectedJobEpoch, in: db)
        try refreshJobCounters(jobID: block.jobID, atMs: atMs, in: db)
        return block
    }

    /// 持久化校验结果并推进块 → resolved（单事务）：
    /// 1. epoch 核对 + 块状态复核（readyForAI/requesting →
    ///    resolved；已 resolved 幂等返回）；
    /// 2. 写 `ai_study_cache`（result JSON + LRU 逐出）——
    ///    `writeCache=false` 供缓存命中路径（行已存在，只触 LRU）；
    /// 3. 每 token 写 `ai_study_resolutions` 行
    ///    （revision = 同 (requestHash,tokenKey) MAX+1）；
    /// 4. 块 → resolved（resultID/lease 清/错误码清）+ 计数刷新。
    ///
    /// 任一步失败整体回滚——不留半截结果（§9.1.2 事务保存
    /// result/译文/resolutions + checkpoint）。
    @discardableResult
    public static func persistOutcome(
        blockID: UUID,
        expectedJobEpoch: Int64,
        result: AIStudyCachedResult,
        cacheCapacity: Int,
        writeCache: Bool = true,
        atMs: Int64,
        in db: Database
    ) throws -> AIStudyJobBlock {
        guard var block = try fetchBlock(id: blockID, in: db) else {
            throw AIStudyJobStoreError.blockNotFound(blockID)
        }
        try requireJobEpoch(
            jobID: block.jobID, expected: expectedJobEpoch, in: db)

        // 幂等：同结果已落库（replayed completion）→ 直接返回。
        if block.status == .resolved, block.resultID == result.resultID {
            return block
        }

        let oldStatus = block.status
        switch block.status {
        case .readyForAI:
            // 缓存命中短路：过 requesting（不计真实派发 attempt）
            // 再到 resolved。
            try AIStudyJobStateMachine.transition(
                &block, to: .requesting,
                context: AIStudyBlockTransitionContext(
                    leaseEpoch: expectedJobEpoch,
                    incrementAttemptCount: false))
            try AIStudyJobStateMachine.transition(
                &block, to: .resolved,
                context: AIStudyBlockTransitionContext(
                    resultID: result.resultID,
                    lexicalStatus: result.lexicalStatus,
                    translationStatus: result.translationStatus))
        case .requesting:
            try AIStudyJobStateMachine.transition(
                &block, to: .resolved,
                context: AIStudyBlockTransitionContext(
                    resultID: result.resultID,
                    lexicalStatus: result.lexicalStatus,
                    translationStatus: result.translationStatus))
        default:
            throw AIStudyJobStoreError.blockNotClaimable(
                blockID: blockID, status: block.status)
        }
        try writeBlock(block, from: oldStatus,
                       expectedJobEpoch: expectedJobEpoch, in: db)

        if writeCache {
            try storeCachedResult(
                result, capacity: cacheCapacity, atMs: atMs, in: db)
        } else {
            try touchCachedResult(requestHash: result.requestHash,
                                  atMs: atMs, in: db)
        }

        // resolutions 审计行：同 (request_hash, token_key) 单调
        // revision，重分析/合并命中产生新行不覆盖历史。
        for resolution in result.resolutions {
            let revision = try nextResolutionRevision(
                requestHash: result.requestHash,
                tokenKey: resolution.tokenKey, in: db)
            try insertResolution(
                AIStudyResolutionRecord(
                    id: UUID(),
                    jobID: block.jobID,
                    jobBlockID: block.id,
                    documentID: nil,
                    locatorJSON: block.locatorJSON,
                    tokenKey: resolution.tokenKey,
                    requestHash: result.requestHash,
                    selectedEntryID: resolution.entryID,
                    selectedSenseID: resolution.senseID,
                    selectedDatasetVersion: resolution.datasetVersion,
                    unitID: nil,
                    confidence: resolution.confidence,
                    status: resolution.status,
                    reasonCode: resolution.reasonCode,
                    origin: resolution.origin,
                    revision: revision,
                    createdAtMs: atMs),
                documentID: documentID(of: block.jobID, in: db),
                in: db)
        }
        try refreshJobCounters(jobID: block.jobID, atMs: atMs, in: db)
        return block
    }

    /// Job 取消的块级收尾：全部非终态块 → cancelled（同事务，
    /// 逐块过状态机）。已 applied/已 cancelled 不动。
    /// 返回被标记的块数。
    @discardableResult
    public static func cancelUnfinishedBlocks(
        jobID: UUID, expectedJobEpoch: Int64, atMs: Int64, in db: Database
    ) throws -> Int {
        try requireJobEpoch(
            jobID: jobID, expected: expectedJobEpoch, in: db)
        let blocks = try fetchBlocks(jobID: jobID, in: db)
        var marked = 0
        for block in blocks
            where !AIStudyJobStateMachine.terminalBlockStates
                .contains(block.status) {
            var transitioned = block
            let oldStatus = block.status
            try AIStudyJobStateMachine.transition(
                &transitioned, to: .cancelled)
            try writeBlock(transitioned, from: oldStatus,
                           expectedJobEpoch: expectedJobEpoch, in: db)
            marked += 1
        }
        try refreshJobCounters(jobID: jobID, atMs: atMs, in: db)
        return marked
    }

    // MARK: - Block 读取

    /// 块行读取（附缓存命中的 lexical/translation 子状态投影——
    /// v25 不落冗余列，从 `ai_study_cache` 行读取，语义一致）。
    public static func fetchBlock(
        id: UUID, in db: Database
    ) throws -> AIStudyJobBlock? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT b.id, b.job_id, b.locator_json, b.source_hash,
                       b.subblock_key, b.candidate_set_hash,
                       b.request_hash, b.status, b.attempt_count,
                       b.next_retry_at_ms, b.lease_epoch, b.result_id,
                       b.last_error_code,
                       c.validated_result_json AS cached_result_json
                FROM ai_study_job_blocks b
                LEFT JOIN ai_study_cache c
                    ON c.request_hash = b.request_hash
                WHERE b.id = ?
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        ).map(decodeBlock)
    }

    /// Job 全部块（插入序——rowid 即 planner 定稿序）。
    public static func fetchBlocks(
        jobID: UUID, in db: Database
    ) throws -> [AIStudyJobBlock] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT b.id, b.job_id, b.locator_json, b.source_hash,
                       b.subblock_key, b.candidate_set_hash,
                       b.request_hash, b.status, b.attempt_count,
                       b.next_retry_at_ms, b.lease_epoch, b.result_id,
                       b.last_error_code,
                       c.validated_result_json AS cached_result_json
                FROM ai_study_job_blocks b
                LEFT JOIN ai_study_cache c
                    ON c.request_hash = b.request_hash
                WHERE b.job_id = ?
                ORDER BY b.rowid
                """,
            arguments: [DatabaseValueCodec.encode(jobID)]
        ).map(decodeBlock)
    }

    /// 可派发块：`readyForAI` ∪ 到期 `retryScheduled` ∪ 无结果
    /// `requesting`（死 lease 待续约——§9.1.5 未知窗口）。
    /// 调用方按运行期再过滤「已被在途 flight 持有」的块。
    public static func fetchDispatchableBlocks(
        jobID: UUID, nowMs: Int64, in db: Database
    ) throws -> [AIStudyJobBlock] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT b.id, b.job_id, b.locator_json, b.source_hash,
                       b.subblock_key, b.candidate_set_hash,
                       b.request_hash, b.status, b.attempt_count,
                       b.next_retry_at_ms, b.lease_epoch, b.result_id,
                       b.last_error_code,
                       c.validated_result_json AS cached_result_json
                FROM ai_study_job_blocks b
                LEFT JOIN ai_study_cache c
                    ON c.request_hash = b.request_hash
                WHERE b.job_id = ? AND (
                    b.status = 'readyForAI'
                    OR (b.status = 'retryScheduled'
                        AND (b.next_retry_at_ms IS NULL
                             OR b.next_retry_at_ms <= ?))
                    OR (b.status = 'requesting' AND b.result_id IS NULL)
                )
                ORDER BY b.rowid
                """,
            arguments: [DatabaseValueCodec.encode(jobID), nowMs]
        ).map(decodeBlock)
    }

    // MARK: - Resolutions

    /// 裸插入 resolution 行（UNIQUE(request_hash,token_key,revision)
    /// 兜底重复写）。`documentID` 由调用方给（SET NULL 弱引用，
    /// 调用方从 job/document 上下文取）。
    public static func insertResolution(
        _ record: AIStudyResolutionRecord,
        documentID: UUID?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_resolutions(
                    id, job_id, job_block_id, document_id, locator_json,
                    token_key, request_hash, selected_entry_id,
                    selected_sense_id, selected_dataset_version, unit_id,
                    confidence, status, reason_code, origin, revision,
                    created_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(record.id),
                record.jobID.map(DatabaseValueCodec.encode),
                record.jobBlockID.map(DatabaseValueCodec.encode),
                (documentID ?? record.documentID)
                    .map(DatabaseValueCodec.encode),
                record.locatorJSON,
                record.tokenKey,
                record.requestHash,
                record.selectedEntryID,
                record.selectedSenseID,
                record.selectedDatasetVersion,
                record.unitID.map(DatabaseValueCodec.encode),
                record.confidence,
                record.status.rawValue,
                record.reasonCode?.rawValue,
                record.origin.rawValue,
                record.revision,
                record.createdAtMs,
            ])
    }

    /// 同 (request_hash, token_key) 下一 revision（MAX+1）。
    public static func nextResolutionRevision(
        requestHash: String, tokenKey: String, in db: Database
    ) throws -> Int64 {
        try (Int64.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(revision), -1) + 1
                FROM ai_study_resolutions
                WHERE request_hash = ? AND token_key = ?
                """,
            arguments: [requestHash, tokenKey]) ?? 0)
    }

    public static func fetchResolutions(
        jobID: UUID, in db: Database
    ) throws -> [AIStudyResolutionRecord] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, job_id, job_block_id, document_id,
                       locator_json, token_key, request_hash,
                       selected_entry_id, selected_sense_id,
                       selected_dataset_version, unit_id, confidence,
                       status, reason_code, origin, revision,
                       created_at_ms
                FROM ai_study_resolutions
                WHERE job_id = ?
                ORDER BY revision, token_key
                """,
            arguments: [DatabaseValueCodec.encode(jobID)]
        ).map(decodeResolution)
    }

    public static func fetchResolutions(
        requestHash: String, in db: Database
    ) throws -> [AIStudyResolutionRecord] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, job_id, job_block_id, document_id,
                       locator_json, token_key, request_hash,
                       selected_entry_id, selected_sense_id,
                       selected_dataset_version, unit_id, confidence,
                       status, reason_code, origin, revision,
                       created_at_ms
                FROM ai_study_resolutions
                WHERE request_hash = ?
                ORDER BY token_key, revision
                """,
            arguments: [requestHash]
        ).map(decodeResolution)
    }

    // MARK: - Selections

    /// 裸插入 selection 行（PK(job_id,selection_revision,unit_key)
    /// 兜底）。`proposedAction` 序列化为 JSON。
    public static func insertSelection(
        _ selection: AIStudyJobSelection, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_selections(
                    job_id, unit_key, selection_revision, decision,
                    proposed_action, evidence_revision,
                    applied_receipt_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(selection.jobID),
                selection.unitKey,
                selection.selectionRevision,
                selection.decision.rawValue,
                try selection.proposedAction.map {
                    try encodeJSON($0, column: "proposed_action")
                },
                selection.evidenceRevision,
                selection.appliedReceiptID.map(DatabaseValueCodec.encode),
            ])
    }

    /// 确认一批选择：插行 + bump `selection_revision`（epoch-guarded，
    /// 同事务）。`newRevision` 由调用方经
    /// `AIStudyJobStateMachine.nextSelectionRevision` 计算。
    public static func recordSelections(
        jobID: UUID,
        expectedEpoch: Int64,
        selections: [AIStudyJobSelection],
        newRevision: Int64,
        atMs: Int64,
        in db: Database
    ) throws {
        guard let job = try fetchJob(id: jobID, in: db) else {
            throw AIStudyJobStoreError.jobNotFound(jobID)
        }
        guard job.epoch == expectedEpoch else {
            throw AIStudyJobStoreError.staleJobEpoch(
                jobID: jobID, expected: expectedEpoch, found: job.epoch)
        }
        for selection in selections {
            try insertSelection(selection, in: db)
        }
        try db.execute(
            sql: """
                UPDATE ai_study_jobs SET
                    selection_revision = ?, updated_at_ms = ?
                WHERE id = ? AND epoch = ?
                """,
            arguments: [
                newRevision, atMs,
                DatabaseValueCodec.encode(jobID), expectedEpoch,
            ])
        guard db.changesCount == 1 else {
            throw AIStudyJobStoreError.staleJobEpoch(
                jobID: jobID, expected: expectedEpoch, found: nil)
        }
        try refreshJobCounters(jobID: jobID, atMs: atMs, in: db)
    }

    public static func fetchSelections(
        jobID: UUID, in db: Database
    ) throws -> [AIStudyJobSelection] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT job_id, unit_key, selection_revision, decision,
                       proposed_action, evidence_revision,
                       applied_receipt_id
                FROM ai_study_selections
                WHERE job_id = ?
                ORDER BY selection_revision, unit_key
                """,
            arguments: [DatabaseValueCodec.encode(jobID)]
        ).map(decodeSelection)
    }

    /// 回填 selection 的应用凭据（弱引用 receipt）。
    public static func markSelectionApplied(
        jobID: UUID, unitKey: String, selectionRevision: Int64,
        receiptID: UUID, expectedEpoch: Int64, atMs: Int64,
        in db: Database
    ) throws {
        try requireJobEpoch(
            jobID: jobID, expected: expectedEpoch, in: db)
        try db.execute(
            sql: """
                UPDATE ai_study_selections SET applied_receipt_id = ?
                WHERE job_id = ? AND unit_key = ?
                      AND selection_revision = ?
                """,
            arguments: [
                DatabaseValueCodec.encode(receiptID),
                DatabaseValueCodec.encode(jobID),
                unitKey, selectionRevision,
            ])
        try refreshJobCounters(jobID: jobID, atMs: atMs, in: db)
    }

    // MARK: - Receipts（§4.3 幂等第三层）

    /// 记录 receipt：PK/UNIQUE 冲突视为 replay——命中既有行且
    /// payload 一致 → 返回既有行（零写入效果）；payload 不同 →
    /// `receiptConflict`（同 ID/同 actionKey 异 payload 拒绝）。
    @discardableResult
    public static func recordReceipt(
        _ receipt: AIStudyReceipt, in db: Database
    ) throws -> AIStudyReceipt {
        do {
            try db.execute(
                sql: """
                    INSERT INTO ai_study_receipts(
                        operation_id, action_key, payload_hash,
                        outcome_json, committed_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(receipt.operationID),
                    receipt.actionKey,
                    receipt.payloadHash,
                    receipt.outcomeJSON,
                    receipt.committedAtMs,
                ])
            return receipt
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CONSTRAINT {
            // action_key 命中 = 同一逻辑动作的 replay。
            if let existing = try fetchReceipt(
                actionKey: receipt.actionKey, in: db) {
                guard existing.payloadHash == receipt.payloadHash else {
                    throw AIStudyJobStoreError.receiptConflict(
                        receipt.actionKey)
                }
                return existing
            }
            // operation_id 命中但 action_key 不同 = 同 ID 异 payload。
            if let existing = try fetchReceipt(
                operationID: receipt.operationID, in: db) {
                guard existing.payloadHash == receipt.payloadHash,
                      existing.actionKey == receipt.actionKey else {
                    throw AIStudyJobStoreError.receiptConflict(
                        receipt.actionKey)
                }
                return existing
            }
            throw error
        }
    }

    public static func fetchReceipt(
        operationID: UUID, in db: Database
    ) throws -> AIStudyReceipt? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT operation_id, action_key, payload_hash,
                       outcome_json, committed_at_ms
                FROM ai_study_receipts WHERE operation_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(operationID)]
        ).map(decodeReceipt)
    }

    public static func fetchReceipt(
        actionKey: String, in db: Database
    ) throws -> AIStudyReceipt? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT operation_id, action_key, payload_hash,
                       outcome_json, committed_at_ms
                FROM ai_study_receipts WHERE action_key = ?
                """,
            arguments: [actionKey]
        ).map(decodeReceipt)
    }

    // MARK: - Cache（本机 LRU，§8.1 请求复用层）

    /// 缓存读取 + LRU touch。返回 nil = 未命中。
    /// 注意：touch 是写——请在 `pool.write` 内调用。
    public static func cachedResult(
        requestHash: String, atMs: Int64, in db: Database
    ) throws -> AIStudyCachedResult? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT validated_result_json FROM ai_study_cache
                WHERE request_hash = ?
                """,
            arguments: [requestHash])
        else { return nil }
        let json: String = row["validated_result_json"]
        try touchCachedResult(
            requestHash: requestHash, atMs: atMs, in: db)
        guard let data = json.data(using: .utf8),
              let result = try? JSONDecoder()
                .decode(AIStudyCachedResult.self, from: data)
        else {
            throw AIStudyJobStoreError.inconsistentStorage(
                "ai_study_cache 行解码失败: \(requestHash)")
        }
        return result
    }

    /// 缓存写入（同 hash 覆盖）+ LRU 容量逐出（最久未访问先出）。
    public static func storeCachedResult(
        _ result: AIStudyCachedResult,
        capacity: Int,
        atMs: Int64,
        in db: Database
    ) throws {
        let data = try JSONEncoder().encode(result)
        let json = String(decoding: data, as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO ai_study_cache(
                    request_hash, validated_result_json, size_bytes,
                    created_at_ms, last_accessed_at_ms)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(request_hash) DO UPDATE SET
                    validated_result_json = excluded.validated_result_json,
                    size_bytes = excluded.size_bytes,
                    last_accessed_at_ms = excluded.last_accessed_at_ms
                """,
            arguments: [
                result.requestHash, json, data.count, atMs, atMs,
            ])
        // 容量逐出：保留最近访问的 `capacity` 行。
        if capacity > 0 {
            try db.execute(
                sql: """
                    DELETE FROM ai_study_cache
                    WHERE request_hash NOT IN (
                        SELECT request_hash FROM ai_study_cache
                        ORDER BY last_accessed_at_ms DESC, request_hash
                        LIMIT ?)
                    """,
                arguments: [capacity])
        }
    }

    /// LRU touch（命中/复用时刷新访问时刻）。
    public static func touchCachedResult(
        requestHash: String, atMs: Int64, in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE ai_study_cache SET last_accessed_at_ms = ?
                WHERE request_hash = ?
                """,
            arguments: [atMs, requestHash])
    }

    /// 缓存行数（测试/诊断）。
    public static func cachedResultCount(in db: Database) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM ai_study_cache") ?? 0
    }

    // MARK: - 私有：行解码 / 守卫

    private static func encodeJSON<T: Encodable>(
        _ value: T, column: String
    ) throws -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw AIStudyJobStoreError.inconsistentStorage(
                "\(column) 编码失败: \(error)")
        }
    }

    private static func decodeJSON<T: Decodable>(
        _ json: String, as type: T.Type, column: String
    ) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw AIStudyJobStoreError.inconsistentStorage(
                "\(column) 非 UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIStudyJobStoreError.inconsistentStorage(
                "\(column) 解码失败: \(error)")
        }
    }

    /// 活跃 Job 存在性（部分唯一索引语义的友好前置判定）。
    private static func activeJobExists(
        documentID: UUID, contentRevision: Int64,
        excluding jobID: UUID?, in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM ai_study_jobs
                    WHERE document_id = ? AND content_revision = ?
                      AND status NOT IN
                          ('completed', 'cancelled', 'failed')
                      AND id != ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(documentID),
                contentRevision,
                DatabaseValueCodec.encode(jobID ?? UUID()),
            ]) ?? false
    }

    /// epoch 读核（事务内）：漂移 → `staleJobEpoch`。
    private static func requireJobEpoch(
        jobID: UUID, expected: Int64, in db: Database
    ) throws {
        let found = try Int64.fetchOne(
            db,
            sql: "SELECT epoch FROM ai_study_jobs WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(jobID)])
        guard let found else {
            throw AIStudyJobStoreError.jobNotFound(jobID)
        }
        guard found == expected else {
            throw AIStudyJobStoreError.staleJobEpoch(
                jobID: jobID, expected: expected, found: found)
        }
    }

    private static func documentID(
        of jobID: UUID, in db: Database
    ) throws -> UUID? {
        guard let raw = try String.fetchOne(
            db,
            sql: "SELECT document_id FROM ai_study_jobs WHERE id = ?",
            arguments: [DatabaseValueCodec.encode(jobID)])
        else { return nil }
        return try DatabaseValueCodec.decodeUUID(raw)
    }

    /// 块 UPDATE（guarded）：WHERE 携带旧状态 + job.epoch EXISTS 核对。
    private static func writeBlock(
        _ block: AIStudyJobBlock,
        from oldStatus: AIStudyBlockStatus,
        expectedJobEpoch: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE ai_study_job_blocks SET
                    status = ?, attempt_count = ?, next_retry_at_ms = ?,
                    lease_epoch = ?, result_id = ?, last_error_code = ?
                WHERE id = ? AND status = ?
                  AND EXISTS (
                      SELECT 1 FROM ai_study_jobs j
                      WHERE j.id = ai_study_job_blocks.job_id
                            AND j.epoch = ?)
                """,
            arguments: [
                block.status.rawValue,
                block.attemptCount,
                block.nextRetryAtMs,
                block.leaseEpoch,
                block.resultID.map(DatabaseValueCodec.encode),
                block.lastErrorCode,
                DatabaseValueCodec.encode(block.id),
                oldStatus.rawValue,
                expectedJobEpoch,
            ])
        guard db.changesCount == 1 else {
            throw AIStudyJobStoreError.staleJobEpoch(
                jobID: block.jobID, expected: expectedJobEpoch,
                found: nil)
        }
    }

    private static func decodeJob(_ row: Row) throws -> AIStudyJob {
        guard
            let status = AIStudyJobStatus(
                rawValue: row["status"] as String)
        else {
            throw AIStudyJobStoreError.inconsistentStorage(
                "ai_study_jobs.status 非法: \(row["status"] as String)")
        }
        let resumeReasonRaw = row["resume_reason"] as String?
        return AIStudyJob(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            documentID: try DatabaseValueCodec.decodeUUID(
                row["document_id"]),
            studyDeckID: try (row["study_deck_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID),
            scope: try decodeJSON(
                row["scope_json"], as: AIStudyScope.self,
                column: "scope_json"),
            inputFingerprint: row["input_fingerprint"],
            contentRevision: row["content_revision"],
            providerSnapshot: try decodeJSON(
                row["provider_snapshot_json"],
                as: AIStudyProviderSnapshot.self,
                column: "provider_snapshot_json"),
            model: row["model"],
            pipelineVersion: row["pipeline_version"],
            promptVersion: row["prompt_version"],
            policyVersion: row["policy_version"],
            status: status,
            epoch: row["epoch"],
            selectionRevision: row["selection_revision"],
            resumeReason: resumeReasonRaw.flatMap {
                AIStudyResumeReason(rawValue: $0)
            },
            createdAtMs: row["created_at_ms"],
            updatedAtMs: row["updated_at_ms"],
            processedBlocks: row["processed_blocks"],
            appliedUnits: row["applied_units"],
            confirmedUnits: row["confirmed_units"],
            failedBlocks: row["failed_blocks"])
    }

    /// `cached_result_json` 的最小投影（hydrate 子状态用）——
    /// JSONDecoder 容忍额外键。
    private struct CachedProjection: Codable {
        var lexicalStatus: AIStudyLexicalStatus?
        var translationStatus: AIStudyTranslationStatus?
    }

    private static func decodeBlock(_ row: Row) throws -> AIStudyJobBlock {
        guard
            let status = AIStudyBlockStatus(
                rawValue: row["status"] as String)
        else {
            throw AIStudyJobStoreError.inconsistentStorage(
                "ai_study_job_blocks.status 非法: \(row["status"] as String)")
        }
        var lexicalStatus: AIStudyLexicalStatus?
        var translationStatus: AIStudyTranslationStatus?
        if let cachedJSON = row["cached_result_json"] as String?,
           let data = cachedJSON.data(using: .utf8),
           let projection = try? JSONDecoder()
               .decode(CachedProjection.self, from: data) {
            lexicalStatus = projection.lexicalStatus
            translationStatus = projection.translationStatus
        }
        return AIStudyJobBlock(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            jobID: try DatabaseValueCodec.decodeUUID(row["job_id"]),
            locatorJSON: row["locator_json"],
            sourceHash: row["source_hash"],
            subblockKey: row["subblock_key"],
            candidateSetHash: row["candidate_set_hash"],
            requestHash: row["request_hash"],
            status: status,
            attemptCount: row["attempt_count"],
            nextRetryAtMs: row["next_retry_at_ms"],
            leaseEpoch: row["lease_epoch"],
            resultID: try (row["result_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID),
            lastErrorCode: row["last_error_code"],
            lexicalStatus: lexicalStatus,
            translationStatus: translationStatus)
    }

    private static func decodeResolution(
        _ row: Row
    ) throws -> AIStudyResolutionRecord {
        guard
            let status = AIStudyResolutionStatus(
                rawValue: row["status"] as String),
            let origin = AIStudyResolutionOrigin(
                rawValue: row["origin"] as String)
        else {
            throw AIStudyJobStoreError.inconsistentStorage(
                "ai_study_resolutions 枚举非法")
        }
        return AIStudyResolutionRecord(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            jobID: try (row["job_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID),
            jobBlockID: try (row["job_block_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID),
            documentID: try (row["document_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID),
            locatorJSON: row["locator_json"],
            tokenKey: row["token_key"],
            requestHash: row["request_hash"],
            selectedEntryID: row["selected_entry_id"],
            selectedSenseID: row["selected_sense_id"],
            selectedDatasetVersion: row["selected_dataset_version"],
            unitID: try (row["unit_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID),
            confidence: row["confidence"],
            status: status,
            reasonCode: (row["reason_code"] as String?).flatMap {
                AIStudyReasonCode(rawValue: $0)
            },
            origin: origin,
            revision: row["revision"],
            createdAtMs: row["created_at_ms"])
    }

    private static func decodeSelection(
        _ row: Row
    ) throws -> AIStudyJobSelection {
        guard
            let decision = AISelectionDecision(
                rawValue: row["decision"] as String)
        else {
            throw AIStudyJobStoreError.inconsistentStorage(
                "ai_study_selections.decision 非法")
        }
        return AIStudyJobSelection(
            jobID: try DatabaseValueCodec.decodeUUID(row["job_id"]),
            unitKey: row["unit_key"],
            selectionRevision: row["selection_revision"],
            decision: decision,
            proposedAction: try (row["proposed_action"] as String?)
                .map {
                    try decodeJSON(
                        $0, as: AIStudyProposedAction.self,
                        column: "proposed_action")
                },
            evidenceRevision: row["evidence_revision"],
            appliedReceiptID: try (row["applied_receipt_id"] as String?)
                .map(DatabaseValueCodec.decodeUUID))
    }

    private static func decodeReceipt(_ row: Row) throws -> AIStudyReceipt {
        AIStudyReceipt(
            operationID: try DatabaseValueCodec.decodeUUID(
                row["operation_id"]),
            actionKey: row["action_key"],
            payloadHash: row["payload_hash"],
            outcomeJSON: row["outcome_json"],
            committedAtMs: row["committed_at_ms"])
    }
}

// MARK: - async 门面（pool.read/write 薄封装）

extension GRDBAIStudyJobStore {

    public func insertJob(
        _ job: AIStudyJob, blocks: [AIStudyJobBlock] = []
    ) async throws {
        try await pool.write { db in
            try Self.insertJob(job, blocks: blocks, in: db)
        }
    }

    public func fetchJob(id: UUID) async throws -> AIStudyJob? {
        try await pool.read { db in try Self.fetchJob(id: id, in: db) }
    }

    public func fetchActiveJob(
        documentID: UUID, contentRevision: Int64
    ) async throws -> AIStudyJob? {
        try await pool.read { db in
            try Self.fetchActiveJob(
                documentID: documentID,
                contentRevision: contentRevision, in: db)
        }
    }

    @discardableResult
    public func transitionJob(
        id: UUID,
        to newStatus: AIStudyJobStatus,
        expectedEpoch: Int64,
        resumeReason: AIStudyResumeReason? = nil
    ) async throws -> AIStudyJob {
        let atMs = Self.nowMilliseconds()
        return try await pool.write { db in
            try Self.transitionJob(
                id: id, to: newStatus, expectedEpoch: expectedEpoch,
                atMs: atMs, resumeReason: resumeReason, in: db)
        }
    }

    public func insertBlocksIfAbsent(
        jobID: UUID, blocks: [AIStudyJobBlock], expectedEpoch: Int64
    ) async throws -> Int {
        try await pool.write { db in
            try Self.insertBlocksIfAbsent(
                jobID: jobID, blocks: blocks,
                expectedEpoch: expectedEpoch, in: db)
        }
    }

    public func fetchBlock(
        id: UUID
    ) async throws -> AIStudyJobBlock? {
        try await pool.read { db in try Self.fetchBlock(id: id, in: db) }
    }

    public func fetchBlocks(
        jobID: UUID
    ) async throws -> [AIStudyJobBlock] {
        try await pool.read { db in
            try Self.fetchBlocks(jobID: jobID, in: db)
        }
    }

    public func fetchDispatchableBlocks(
        jobID: UUID, nowMs: Int64
    ) async throws -> [AIStudyJobBlock] {
        try await pool.read { db in
            try Self.fetchDispatchableBlocks(
                jobID: jobID, nowMs: nowMs, in: db)
        }
    }

    @discardableResult
    public func transitionBlock(
        id: UUID,
        to newStatus: AIStudyBlockStatus,
        context: AIStudyBlockTransitionContext = .init(),
        expectedJobEpoch: Int64
    ) async throws -> AIStudyJobBlock {
        let atMs = Self.nowMilliseconds()
        return try await pool.write { db in
            try Self.transitionBlock(
                id: id, to: newStatus, context: context,
                expectedJobEpoch: expectedJobEpoch, atMs: atMs, in: db)
        }
    }

    @discardableResult
    public func claimBlockForDispatch(
        id: UUID, leaseEpoch: Int64, expectedJobEpoch: Int64,
        countAttempt: Bool = true
    ) async throws -> AIStudyJobBlock {
        let atMs = Self.nowMilliseconds()
        return try await pool.write { db in
            try Self.claimBlockForDispatch(
                id: id, leaseEpoch: leaseEpoch,
                expectedJobEpoch: expectedJobEpoch,
                countAttempt: countAttempt, atMs: atMs, in: db)
        }
    }

    @discardableResult
    public func persistOutcome(
        blockID: UUID,
        expectedJobEpoch: Int64,
        result: AIStudyCachedResult,
        cacheCapacity: Int,
        writeCache: Bool = true
    ) async throws -> AIStudyJobBlock {
        let atMs = Self.nowMilliseconds()
        return try await pool.write { db in
            try Self.persistOutcome(
                blockID: blockID, expectedJobEpoch: expectedJobEpoch,
                result: result, cacheCapacity: cacheCapacity,
                writeCache: writeCache, atMs: atMs, in: db)
        }
    }

    @discardableResult
    public func cancelUnfinishedBlocks(
        jobID: UUID, expectedJobEpoch: Int64
    ) async throws -> Int {
        let atMs = Self.nowMilliseconds()
        return try await pool.write { db in
            try Self.cancelUnfinishedBlocks(
                jobID: jobID, expectedJobEpoch: expectedJobEpoch,
                atMs: atMs, in: db)
        }
    }

    public func fetchResolutions(
        jobID: UUID
    ) async throws -> [AIStudyResolutionRecord] {
        try await pool.read { db in
            try Self.fetchResolutions(jobID: jobID, in: db)
        }
    }

    public func fetchResolutions(
        requestHash: String
    ) async throws -> [AIStudyResolutionRecord] {
        try await pool.read { db in
            try Self.fetchResolutions(requestHash: requestHash, in: db)
        }
    }

    public func insertSelection(
        _ selection: AIStudyJobSelection
    ) async throws {
        try await pool.write { db in
            try Self.insertSelection(selection, in: db)
        }
    }

    public func fetchSelections(
        jobID: UUID
    ) async throws -> [AIStudyJobSelection] {
        try await pool.read { db in
            try Self.fetchSelections(jobID: jobID, in: db)
        }
    }

    /// receipt 记录/replay（§4.3）。
    @discardableResult
    public func recordReceipt(
        _ receipt: AIStudyReceipt
    ) async throws -> AIStudyReceipt {
        try await pool.write { db in
            try Self.recordReceipt(receipt, in: db)
        }
    }

    public func fetchReceipt(
        operationID: UUID
    ) async throws -> AIStudyReceipt? {
        try await pool.read { db in
            try Self.fetchReceipt(operationID: operationID, in: db)
        }
    }

    public func fetchReceipt(
        actionKey: String
    ) async throws -> AIStudyReceipt? {
        try await pool.read { db in
            try Self.fetchReceipt(actionKey: actionKey, in: db)
        }
    }

    /// 缓存读取 + LRU touch（写事务）。
    public func cachedResult(
        requestHash: String
    ) async throws -> AIStudyCachedResult? {
        let atMs = Self.nowMilliseconds()
        return try await pool.write { db in
            try Self.cachedResult(
                requestHash: requestHash, atMs: atMs, in: db)
        }
    }

    public func storeCachedResult(
        _ result: AIStudyCachedResult, capacity: Int
    ) async throws {
        let atMs = Self.nowMilliseconds()
        try await pool.write { db in
            try Self.storeCachedResult(
                result, capacity: capacity, atMs: atMs, in: db)
        }
    }

    public func cachedResultCount() async throws -> Int {
        try await pool.read { db in try Self.cachedResultCount(in: db) }
    }

    /// 当前毫秒时间（调用方需要注入时间源时用静态方法形态）。
    public static func nowMilliseconds() -> Int64 {
        (try? DatabaseValueCodec.encode(Date())) ?? 0
    }

    // MARK: - 文档级进度投影（S22 库行展示）

    /// 全部活跃 Job 的进度投影（documentID 键）。非终态
    /// （pending…partiallyCompleted）都入投影——partiallyCompleted
    /// 有残余失败块仍是可恢复工作，库行如实显示。
    /// 计数全部取自 `ai_study_jobs` 持久化冗余列 + 块行总数
    /// 子查询——Runner 不在内存态时进度同样可读（后台续跑
    /// 断点续传语义）。
    public func activeJobProgress(
    ) async throws -> [UUID: AIStudyJobProgress] {
        try await pool.read { db in
            try Self.fetchActiveJobProgress(in: db)
        }
    }

    static func fetchActiveJobProgress(
        in db: Database
    ) throws -> [UUID: AIStudyJobProgress] {
        var result: [UUID: AIStudyJobProgress] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT j.id, j.document_id, j.status,
                       j.processed_blocks, j.failed_blocks,
                       j.confirmed_units, j.applied_units,
                       (SELECT COUNT(*) FROM ai_study_job_blocks b
                        WHERE b.job_id = j.id) AS total_blocks
                FROM ai_study_jobs j
                WHERE j.status NOT IN
                      ('completed', 'cancelled', 'failed')
                """
        ) {
            guard let status = AIStudyJobStatus(
                rawValue: row["status"] as String),
                  let documentID = try? DatabaseValueCodec
                      .decodeUUID(row["document_id"]),
                  let jobID = try? DatabaseValueCodec
                      .decodeUUID(row["id"])
            else { continue }
            result[documentID] = AIStudyJobProgress(
                jobID: jobID,
                documentID: documentID,
                status: status,
                processedBlocks: row["processed_blocks"],
                failedBlocks: row["failed_blocks"],
                totalBlocks: row["total_blocks"],
                confirmedUnits: row["confirmed_units"],
                appliedUnits: row["applied_units"])
        }
        return result
    }

    /// 文档级进度观察流——`ai_study_jobs` 行变化（Runner 每块
    /// 收束都 refresh 计数）即重估；`.removeDuplicates()` 保证
    /// 无变化不 ping。同池写（任何 scene/Runner）都会触发。
    public func observeActiveJobProgress(
    ) -> AsyncThrowingStream<[UUID: AIStudyJobProgress], Error> {
        let observation = ValueObservation
            .tracking { db throws -> [UUID: AIStudyJobProgress] in
                try Self.fetchActiveJobProgress(in: db)
            }
            .removeDuplicates()
        let values = observation.values(
            in: pool, bufferingPolicy: .bufferingNewest(1))
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            let task = Task {
                do {
                    for try await update in values {
                        guard !Task.isCancelled else { break }
                        continuation.yield(update)
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
}
