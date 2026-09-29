import Foundation
import XCTest
@testable import OboeDomain

/// S11 前置（角色 E）：Job/block/selection/resolution/receipt 领域模型
/// 与状态机测试。
/// 依据：contracts-frozen rev2 §4.1–§4.3、技术文档 §9/§11、D10/D11。
///
/// §4.1 转移表 → 测试对照：
/// - Job 合法全集（含 partiallyCompleted 三去向、paused 出入、
///   非终态→cancelled/failed）→ testJobTransitionTableAcceptsAllLegalEdges
/// - Job 非法全集（100 对全矩阵拒绝非表项，含 completed→analyzing、
///   cancelled→恢复、终态再变）→ testJobTransitionTableRejectsIllegalEdges
/// - Block 合法/非法 → testBlockTransitionTableAcceptsAllLegalEdges /
///   testBlockTransitionTableRejectsIllegalEdges
/// - paused→analyzing 续跑 + resumeReason 生命周期 →
///   testPausedResumeClearsReasonAndRejectsDirectReentry
/// - cancelled 语义（epoch+1、不可恢复、终态）→ testCancelSemantics
/// - 恢复协议（§9.1.5 块级分类）→ testResumeAction* / testResumeTarget*
/// - actionKey/selectionRevision → testActionKey* / testSelectionRevision*
final class AIStudyJobModelsTests: XCTestCase {

    // MARK: - fixtures

    private func makeJob(
        status: AIStudyJobStatus = .pending,
        epoch: Int64 = 0,
        selectionRevision: Int64 = 0,
        resumeReason: AIStudyResumeReason? = nil
    ) -> AIStudyJob {
        AIStudyJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
            documentID: UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!,
            studyDeckID: UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!,
            scope: .chapters(["ch1", "ch2"]),
            inputFingerprint: "fp-1",
            contentRevision: 7,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: "anthropic",
                model: "claude-test",
                responseMode: "promptedJSON",
                promptVersion: "study-v1",
                policyVersion: "policy-v1"
            ),
            model: "claude-test",
            pipelineVersion: "pipe-v1",
            promptVersion: "study-v1",
            policyVersion: "policy-v1",
            status: status,
            epoch: epoch,
            selectionRevision: selectionRevision,
            resumeReason: resumeReason,
            createdAtMs: 1_000,
            updatedAtMs: 1_000,
            processedBlocks: 3,
            appliedUnits: 2,
            confirmedUnits: 4,
            failedBlocks: 1
        )
    }

    private func makeBlock(
        status: AIStudyBlockStatus = .pending,
        jobID: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
        subblockKey: String = "scope#r0-100",
        resultID: UUID? = nil,
        nextRetryAtMs: Int64? = nil,
        leaseEpoch: Int64? = nil
    ) -> AIStudyJobBlock {
        AIStudyJobBlock(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
            jobID: jobID,
            locatorJSON: #"{"chapter":"ch1","block":0}"#,
            sourceHash: "sh-1",
            subblockKey: subblockKey,
            candidateSetHash: "csh-1",
            requestHash: "rh-1",
            status: status,
            attemptCount: 0,
            nextRetryAtMs: nextRetryAtMs,
            leaseEpoch: leaseEpoch,
            resultID: resultID
        )
    }

    // MARK: - §4.1 Job 转移表：合法全集

    /// §4.1 表逐行——所有合法转移接受（含 partiallyCompleted 三去向、
    /// paused 三个入口、非终态→cancelled/failed 全覆盖）。
    func testJobTransitionTableAcceptsAllLegalEdges() {
        let legal: Set<[AIStudyJobStatus]> = [
            [.pending, .analyzing],
            [.analyzing, .waitingForAI],
            [.waitingForAI, .awaitingConfirmation],
            [.awaitingConfirmation, .applying],
            [.applying, .completed],
            [.applying, .partiallyCompleted],
            [.waitingForAI, .partiallyCompleted],
            // partiallyCompleted 三去向（重试失败块/查看结果/继续应用）
            [.partiallyCompleted, .waitingForAI],
            [.partiallyCompleted, .awaitingConfirmation],
            [.partiallyCompleted, .applying],
            // paused 出入（§4.1：analyzing|waitingForAI|applying→paused→analyzing）
            [.analyzing, .paused],
            [.waitingForAI, .paused],
            [.applying, .paused],
            [.paused, .analyzing],
        ]
        for edge in legal {
            XCTAssertTrue(
                AIStudyJobStateMachine.canTransition(from: edge[0], to: edge[1]),
                "应允许 \(edge[0])→\(edge[1])"
            )
        }
        // 任意非终态 → cancelled / failed
        for status in AIStudyJobStatus.allCases
        where !AIStudyJobStateMachine.terminalJobStates.contains(status) {
            XCTAssertTrue(
                AIStudyJobStateMachine.canTransition(from: status, to: .cancelled),
                "非终态 \(status) 应可 cancelled")
            XCTAssertTrue(
                AIStudyJobStateMachine.canTransition(from: status, to: .failed),
                "非终态 \(status) 应可 failed")
        }
    }

    /// 全矩阵拒绝非表项：completed→analyzing、cancelled→恢复、
    /// 终态再变、跳级、逆向等 100 对全检。
    func testJobTransitionTableRejectsIllegalEdges() {
        // 显式枚举合法 (from,to) 对，其余一律拒绝。
        var legal = Set<UInt64>()
        func allow(_ from: AIStudyJobStatus, _ to: AIStudyJobStatus) {
            legal.insert(pairKey(from, to))
        }
        allow(.pending, .analyzing)
        allow(.analyzing, .waitingForAI)
        allow(.waitingForAI, .awaitingConfirmation)
        allow(.awaitingConfirmation, .applying)
        allow(.applying, .completed)
        allow(.applying, .partiallyCompleted)
        allow(.waitingForAI, .partiallyCompleted)
        allow(.partiallyCompleted, .waitingForAI)
        allow(.partiallyCompleted, .awaitingConfirmation)
        allow(.partiallyCompleted, .applying)
        allow(.analyzing, .paused)
        allow(.waitingForAI, .paused)
        allow(.applying, .paused)
        allow(.paused, .analyzing)
        for status in AIStudyJobStatus.allCases
        where !AIStudyJobStateMachine.terminalJobStates.contains(status) {
            allow(status, .cancelled)
            allow(status, .failed)
        }

        for from in AIStudyJobStatus.allCases {
            for to in AIStudyJobStatus.allCases {
                let expected = legal.contains(pairKey(from, to))
                XCTAssertEqual(
                    AIStudyJobStateMachine.canTransition(from: from, to: to),
                    expected,
                    "\(from)→\(to) 判定与表不符"
                )
            }
        }

        // 点名断言（需求示例）
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .completed, to: .analyzing))
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .cancelled, to: .analyzing), "cancelled 不可恢复")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .failed, to: .waitingForAI), "终态不可再变")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .pending, to: .applying), "不可跳级")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .paused, to: .waitingForAI), "paused 只能经 analyzing 续跑")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .awaitingConfirmation, to: .paused), "确认中无 paused 入边")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .partiallyCompleted, to: .completed), "不可直接置 completed")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            from: .pending, to: .pending), "自环非法")
    }

    private func pairKey(
        _ from: AIStudyJobStatus, _ to: AIStudyJobStatus
    ) -> UInt64 {
        let states = Array(AIStudyJobStatus.allCases)
        let a = UInt64(states.firstIndex(of: from)!)
        let b = UInt64(states.firstIndex(of: to)!)
        return a * 64 + b
    }

    // MARK: - §4.1 Block 转移表

    func testBlockTransitionTableAcceptsAllLegalEdges() {
        let legal: [AIStudyBlockStatus: Set<AIStudyBlockStatus>] = [
            .pending: [.analyzing, .cancelled],
            .analyzing: [.readyForAI, .failed, .cancelled],
            .readyForAI: [.requesting, .failed, .cancelled],
            .requesting: [.resolved, .retryScheduled, .failed, .cancelled],
            .retryScheduled: [.readyForAI, .failed, .cancelled],
            .resolved: [.awaitingConfirmation, .applying, .cancelled],
            .awaitingConfirmation: [.applying, .cancelled],
            .applying: [.applied, .failed, .cancelled],
            .applied: [],
            .failed: [.analyzing, .readyForAI, .cancelled],
            .cancelled: [],
        ]
        for from in AIStudyBlockStatus.allCases {
            for to in AIStudyBlockStatus.allCases {
                XCTAssertEqual(
                    AIStudyJobStateMachine.canTransition(blockFrom: from, to: to),
                    legal[from]?.contains(to) ?? false,
                    "block \(from)→\(to) 判定与表不符"
                )
            }
        }
    }

    func testBlockTransitionTableRejectsIllegalEdges() {
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .applied, to: .requesting), "终态不可再变")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .cancelled, to: .analyzing))
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .pending, to: .requesting), "未定稿不可派发")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .requesting, to: .applied), "未经确认/应用不可 applied")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .resolved, to: .analyzing), "已解析结果不重回分析")
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .awaitingConfirmation, to: .requesting))
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(
            blockFrom: .applied, to: .cancelled), "applied 终态不可取消")
    }

    // MARK: - transition() 附带语义

    /// →cancelled：epoch+1（§9.2 使在途写失效）、resumeReason 保持、
    /// 之后一切转移拒绝（canResume false、已提交不回滚）。
    func testCancelSemantics() throws {
        var job = makeJob(status: .waitingForAI, epoch: 3,
                          resumeReason: .manualPause)
        try AIStudyJobStateMachine.transition(&job, to: .cancelled, atMs: 2_000)
        XCTAssertEqual(job.status, .cancelled)
        XCTAssertEqual(job.epoch, 4, "取消必须递增 epoch（迟到写核对失效）")
        XCTAssertEqual(job.updatedAtMs, 2_000)
        XCTAssertFalse(AIStudyJobStateMachine.canResume(job))
        XCTAssertFalse(AIStudyJobStateMachine.isActive(job))
        XCTAssertThrowsError(
            try AIStudyJobStateMachine.transition(&job, to: .analyzing, atMs: 3_000)
        ) { error in
            XCTAssertEqual(
                error as? AIStudyJobTransitionError,
                .illegalJobTransition(from: .cancelled, to: .analyzing))
        }
    }

    /// paused→analyzing 唯一续跑边 + resumeReason 生命周期：
    /// 入 paused 记原因，出 paused 清原因；paused 不可直接回
    /// waitingForAI/applying（按持久化阶段续跑，不机械续旧态）。
    func testPausedResumeClearsReasonAndRejectsDirectReentry() throws {
        var job = makeJob(status: .waitingForAI)
        try AIStudyJobStateMachine.transition(
            &job, to: .paused, atMs: 1_500, resumeReason: .backgroundPause)
        XCTAssertEqual(job.resumeReason, .backgroundPause)
        XCTAssertTrue(AIStudyJobStateMachine.canResume(job))
        XCTAssertTrue(AIStudyJobStateMachine.isActive(job), "paused 非终态=活跃")

        try AIStudyJobStateMachine.transition(&job, to: .analyzing, atMs: 2_500)
        XCTAssertNil(job.resumeReason, "续跑后原因已消费")

        // 恢复目标由块 checkpoint 决定而非旧 job 态。
        var job2 = makeJob(status: .applying)
        try AIStudyJobStateMachine.transition(
            &job2, to: .paused, atMs: 1_500, resumeReason: .manualPause)
        XCTAssertFalse(AIStudyJobStateMachine.canTransition(job2, to: .applying))
        try AIStudyJobStateMachine.transition(&job2, to: .analyzing, atMs: 2_500)
        XCTAssertEqual(job2.status, .analyzing)
    }

    /// Block transition context：派发写 lease/attempt、离开 requesting
    /// 清 lease、resolved 落 resultID+双层子状态。
    func testBlockTransitionContextSideEffects() throws {
        var block = makeBlock(status: .readyForAI)
        try AIStudyJobStateMachine.transition(&block, to: .requesting, context: .init(
            leaseEpoch: 9, incrementAttemptCount: true))
        XCTAssertEqual(block.status, .requesting)
        XCTAssertEqual(block.attemptCount, 1)
        XCTAssertEqual(block.leaseEpoch, 9)

        let resultID = UUID()
        try AIStudyJobStateMachine.transition(&block, to: .resolved, context: .init(
            resultID: resultID,
            lexicalStatus: .partial,
            translationStatus: .done))
        XCTAssertEqual(block.resultID, resultID)
        XCTAssertNil(block.leaseEpoch, "离开 requesting 运行 lease 作废")
        XCTAssertEqual(block.lexicalStatus, .partial)
        XCTAssertEqual(block.translationStatus, .done)
    }

    /// 退避路径：requesting→retryScheduled 记 nextRetryAtMs+errorCode；
    /// 到期 retryScheduled→readyForAI→requesting 清等待与旧错误码。
    func testBlockRetryScheduleSideEffects() throws {
        var block = makeBlock(status: .requesting, leaseEpoch: 5)
        try AIStudyJobStateMachine.transition(&block, to: .retryScheduled, context: .init(
            nextRetryAtMs: 60_000, lastErrorCode: "http429"))
        XCTAssertNil(block.leaseEpoch)
        XCTAssertEqual(block.nextRetryAtMs, 60_000)
        XCTAssertEqual(block.lastErrorCode, "http429")

        try AIStudyJobStateMachine.transition(&block, to: .readyForAI)
        try AIStudyJobStateMachine.transition(&block, to: .requesting, context: .init(
            leaseEpoch: 6, incrementAttemptCount: true))
        XCTAssertNil(block.nextRetryAtMs, "新尝试清等待标记")
        XCTAssertNil(block.lastErrorCode, "新尝试不背旧错误码")
        XCTAssertEqual(block.attemptCount, 1)
    }

    // MARK: - 恢复协议（§9.1.5/D10）块级分类

    /// requesting 且 resultID 已持久化 → 用已存结果推进，绝不重回网络。
    func testResumeActionRequestingWithResultNeverReRequests() {
        var block = makeBlock(status: .requesting)
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(for: block, nowMs: 0),
            .dispatchRequest, "无持久化结果=未知窗口，允许重试（D10）")
        block.resultID = UUID()
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(for: block, nowMs: 0),
            .usePersistedResult, "有持久化结果绝不重发（D10）")
    }

    /// applied 幂等跳过；cancelled 不恢复；failed 等显式重试。
    func testResumeActionTerminalAndExplicitStates() {
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .applied), nowMs: 0),
            .skip, "applied 块幂等跳过")
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .cancelled), nowMs: 0),
            .dropped)
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .failed), nowMs: 0),
            .needsExplicitRetry, "failed 不自动重试")
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .resolved), nowMs: 0),
            .usePersistedResult, "resolved 结果已存，不重发")
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .awaitingConfirmation), nowMs: 0),
            .presentForConfirmation)
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .applying), nowMs: 0),
            .resumeApply, "应用中断靠 receipt replay 继续")
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .pending), nowMs: 0),
            .analyze)
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(
                for: makeBlock(status: .analyzing), nowMs: 0),
            .analyze)
    }

    /// retryScheduled：未到期 → waitForRetry(untilMs)；到期 → dispatch。
    func testResumeActionRetryScheduledHonorsBackoff() {
        let block = makeBlock(status: .retryScheduled, nextRetryAtMs: 10_000)
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(for: block, nowMs: 5_000),
            .waitForRetry(untilMs: 10_000), "未到期不 busy loop")
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(for: block, nowMs: 10_000),
            .dispatchRequest, "到期可派发")
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeAction(for: block, nowMs: 11_000),
            .dispatchRequest)
    }

    /// resumeTarget：有网络/分析遗留 → analyze；仅待确认 → awaitConfirmation；
    /// 仅应用中 → apply；全终态/Job 终态 → finished。
    /// 已存结果块不重回网络是 `.analyze` 内块级语义（usePersistedResult）。
    func testResumeTargetAggregation() {
        let jobID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
        var job = makeJob(status: .paused, resumeReason: .backgroundPause)

        // 混合：一块 requesting（无结果）+ 一块待确认 → 最早阶段 analyze
        var blocks = [
            makeBlock(status: .requesting, jobID: jobID, subblockKey: "k1"),
            makeBlock(status: .awaitingConfirmation, jobID: jobID, subblockKey: "k2"),
        ]
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: blocks),
            .analyze)

        // requesting 但有结果 → 仍是 analyze（消费已存结果推进，不重发）
        blocks[0].resultID = UUID()
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: blocks),
            .analyze)

        // 只剩待确认 → awaitConfirmation
        blocks = [makeBlock(status: .awaitingConfirmation, jobID: jobID)]
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: blocks),
            .awaitConfirmation)

        // 只剩应用中 → apply
        blocks = [makeBlock(status: .applying, jobID: jobID)]
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: blocks),
            .apply)

        // 全部 applied/cancelled → finished
        blocks = [
            makeBlock(status: .applied, jobID: jobID, subblockKey: "k1"),
            makeBlock(status: .cancelled, jobID: jobID, subblockKey: "k2"),
        ]
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: blocks),
            .finished)

        // 他 Job 的块不计入
        let foreign = makeBlock(
            status: .requesting,
            jobID: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff")!)
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: [foreign]),
            .finished)

        // cancelled Job 无可恢复工作（canResume false 一致）
        job.status = .cancelled
        XCTAssertEqual(
            AIStudyJobStateMachine.resumeTarget(for: job, blocks: blocks),
            .finished)
    }

    // MARK: - actionKey / selectionRevision

    /// actionKey 稳定：同输入同 key；六分量任一变化 → 分键
    /// （含 rebuildIntent 显式重建分键，§5 生命周期语义）。
    func testActionKeyStableAndComponentSensitive() {
        let doc = UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!
        let base = AIStudyActionKey(
            documentID: doc, contentRevision: 7, unitKey: "jmdict:sense-v1:1:abc",
            selectionRevision: 3, actionType: .createNote, rebuildIntent: .none)
        let same = AIStudyActionKey(
            documentID: doc, contentRevision: 7, unitKey: "jmdict:sense-v1:1:abc",
            selectionRevision: 3, actionType: .createNote, rebuildIntent: .none)
        XCTAssertEqual(base.canonicalKey, same.canonicalKey, "同输入必须同 key")
        XCTAssertTrue(base.canonicalKey.hasPrefix("aisk1:"))
        XCTAssertEqual(base.canonicalKey.count, "aisk1:".count + 64)

        // 重建意图分键：旧 receipt replay 不顶替「当前仍存在」证据（§5）
        let rebuild = AIStudyActionKey(
            documentID: doc, contentRevision: 7, unitKey: "jmdict:sense-v1:1:abc",
            selectionRevision: 3, actionType: .createNote,
            rebuildIntent: .explicitRebuild)
        XCTAssertNotEqual(base.canonicalKey, rebuild.canonicalKey)

        // 其余分量逐一扰动
        XCTAssertNotEqual(
            base.canonicalKey,
            AIStudyActionKey(documentID: UUID(), contentRevision: 7,
                unitKey: "jmdict:sense-v1:1:abc", selectionRevision: 3,
                actionType: .createNote).canonicalKey)
        XCTAssertNotEqual(
            base.canonicalKey,
            AIStudyActionKey(documentID: doc, contentRevision: 8,
                unitKey: "jmdict:sense-v1:1:abc", selectionRevision: 3,
                actionType: .createNote).canonicalKey)
        XCTAssertNotEqual(
            base.canonicalKey,
            AIStudyActionKey(documentID: doc, contentRevision: 7,
                unitKey: "jmdict:sense-v1:1:abd", selectionRevision: 3,
                actionType: .createNote).canonicalKey)
        XCTAssertNotEqual(
            base.canonicalKey,
            AIStudyActionKey(documentID: doc, contentRevision: 7,
                unitKey: "jmdict:sense-v1:1:abc", selectionRevision: 4,
                actionType: .createNote).canonicalKey,
            "selectionRevision 单调递增 → 新 revision 新 key")
        XCTAssertNotEqual(
            base.canonicalKey,
            AIStudyActionKey(documentID: doc, contentRevision: 7,
                unitKey: "jmdict:sense-v1:1:abc", selectionRevision: 3,
                actionType: .reuseNote).canonicalKey)
    }

    /// selectionRevision 单调语义：job 当前 revision 是应用锚，
    /// 确认批次 +1 不回退；apply 命令按当前锚复核。
    func testSelectionRevisionMonotonicAnchors() {
        let job = makeJob(status: .applying, epoch: 2,
                          selectionRevision: 3)
        XCTAssertEqual(
            AIStudyJobStateMachine.nextSelectionRevision(for: job), 4)

        let matching = AIStudyApplyCommand(
            jobID: job.id, selectionRevision: 3, operationID: UUID(),
            payloadHash: "ph", expectedGeneration: 1, jobEpoch: 2,
            documentRevision: 7, unitKey: "u1",
            targetDeckID: UUID(), directions: [.japaneseToChinese])
        XCTAssertTrue(matching.anchorsMatch(job))

        // 选择 revision 漂移（另一窗口先确认）→ 失配拒绝盲写
        var drifted = job
        drifted.selectionRevision = 4
        XCTAssertFalse(matching.anchorsMatch(drifted))
        // epoch 漂移（取消后）→ 失配
        drifted.selectionRevision = 3
        drifted.epoch = 3
        XCTAssertFalse(matching.anchorsMatch(drifted))
        // 文档 revision 漂移（内容过期）→ 失配
        drifted.epoch = 2
        drifted.contentRevision = 8
        XCTAssertFalse(matching.anchorsMatch(drifted))
    }

    // MARK: - Codable round-trip（v25 列投影编码稳定）

    func testModelsCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let job = makeJob(status: .partiallyCompleted,
                          resumeReason: .contentStale)
        XCTAssertEqual(
            try decoder.decode(AIStudyJob.self, from: encoder.encode(job)),
            job)

        var block = makeBlock(status: .requesting,
                              resultID: UUID(),
                              nextRetryAtMs: 5_000,
                              leaseEpoch: 4)
        block.lexicalStatus = AIStudyLexicalStatus.partial
        block.translationStatus = AIStudyTranslationStatus.notRequested
        XCTAssertEqual(
            try decoder.decode(AIStudyJobBlock.self, from: encoder.encode(block)),
            block)

        let selection = AIStudyJobSelection(
            jobID: job.id, unitKey: "jmdict:sense-v1:1:abc",
            selectionRevision: 2, decision: .create,
            proposedAction: .createNote(directions: [
                .japaneseToChinese, .listening,
            ]),
            evidenceRevision: 9,
            appliedReceiptID: UUID())
        XCTAssertEqual(
            try decoder.decode(AIStudyJobSelection.self,
                               from: encoder.encode(selection)),
            selection)

        let resolution = AIStudyResolutionRecord(
            id: UUID(), jobID: job.id, jobBlockID: block.id,
            documentID: job.documentID, locatorJSON: #"{"b":0}"#,
            tokenKey: "t0123456789ab", requestHash: "rh-1",
            selectedEntryID: 10001, selectedSenseID: 3,
            selectedDatasetVersion: "2026.09.24-1", unitID: UUID(),
            confidence: 0.97, status: .aiResolved,
            reasonCode: nil, origin: .ai, revision: 2, createdAtMs: 42)
        XCTAssertEqual(
            try decoder.decode(AIStudyResolutionRecord.self,
                               from: encoder.encode(resolution)),
            resolution)
        // 行 → 领域 projection
        XCTAssertEqual(resolution.resolution.selected?.entryID, 10001)
        XCTAssertEqual(resolution.resolution.status, AIStudyResolutionStatus.aiResolved)
        XCTAssertEqual(resolution.resolution.origin, AIStudyResolutionOrigin.ai)

        let receipt = AIStudyReceipt(
            operationID: UUID(), actionKey: "aisk1:xyz",
            payloadHash: "ph", outcomeJSON: #"{"applied":1}"#,
            committedAtMs: 9_999)
        XCTAssertEqual(
            try decoder.decode(AIStudyReceipt.self,
                               from: encoder.encode(receipt)),
            receipt)

        // 枚举 wire 值稳定（CHECK 约束冻结集）
        XCTAssertEqual(
            String(data: try encoder.encode(AIStudyJobStatus.waitingForAI),
                   encoding: .utf8),
            "\"waitingForAI\"")
        XCTAssertEqual(
            String(data: try encoder.encode(AISelectionDecision.tooEasy),
                   encoding: .utf8),
            "\"tooEasy\"")
        XCTAssertEqual(
            String(data: try encoder.encode(AIStudyBlockStatus.retryScheduled),
                   encoding: .utf8),
            "\"retryScheduled\"")
    }

    /// scope 编码：集合语义（章节序无关）、scope_json kind 判别、
    /// round-trip 保真。
    func testScopeCodableNormalizedEncoding() throws {
        // .sortedKeys：字节级相等断言只在排序键编码下确定；
        // 裸 JSONEncoder 的 keyed-container 键序不稳定（此测试曾
        // 因 kind/chapterKeys 序抖动 flaky 失败）。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        // 集合语义：不同序编码同形
        let a = AIStudyScope.chapters(["b", "a"])
        let b = AIStudyScope.chapters(["a", "b"])
        XCTAssertEqual(
            try encoder.encode(a), try encoder.encode(b),
            "章节集序无关——编码必须规范一致")
        XCTAssertEqual(
            try decoder.decode(AIStudyScope.self, from: encoder.encode(b)),
            .chapters(["a", "b"]))

        let ranges = AIStudyScope.blockRanges([
            AIStudyScopeRange(locatorKey: "k2", startUTF16: 100, lengthUTF16: 50),
            AIStudyScopeRange(startUTF16: 0, lengthUTF16: 90),
        ])
        let decoded = try decoder.decode(
            AIStudyScope.self, from: encoder.encode(ranges))
        XCTAssertEqual(decoded.canonicalElements, ranges.canonicalElements)
        XCTAssertEqual(decoded, .blockRanges([
            AIStudyScopeRange(startUTF16: 0, lengthUTF16: 90),
            AIStudyScopeRange(locatorKey: "k2", startUTF16: 100, lengthUTF16: 50),
        ]))

        XCTAssertEqual(
            try decoder.decode(AIStudyScope.self,
                               from: encoder.encode(AIStudyScope.fullDocument)),
            .fullDocument)
    }

    /// scopeHash 范围敏感：同范围同 hash（任意输入序），章节集/区间
    /// 任一分量不同 → 不同 hash；kind 不同 → 不同 hash。
    func testScopeHashSensitiveToRange() {
        XCTAssertEqual(
            AIStudyScope.chapters(["b", "a"]).scopeHash,
            AIStudyScope.chapters(["a", "b"]).scopeHash,
            "同章节集不同输入序 → 同 hash")
        XCTAssertEqual(
            AIStudyScope.chapters(["a", "b", "a"]).scopeHash,
            AIStudyScope.chapters(["a", "b"]).scopeHash,
            "重复元素去重 → 同 hash")
        XCTAssertNotEqual(
            AIStudyScope.chapters(["a", "b"]).scopeHash,
            AIStudyScope.chapters(["a", "c"]).scopeHash,
            "章节集不同 → 不同 hash")
        XCTAssertNotEqual(
            AIStudyScope.fullDocument.scopeHash,
            AIStudyScope.chapters(["a", "b"]).scopeHash)

        let r1 = AIStudyScope.blockRanges([
            AIStudyScopeRange(startUTF16: 0, lengthUTF16: 90)])
        let r2 = AIStudyScope.blockRanges([
            AIStudyScopeRange(startUTF16: 0, lengthUTF16: 91)])
        XCTAssertNotEqual(r1.scopeHash, r2.scopeHash, "区间不同 → 不同 hash")
        XCTAssertEqual(
            AIStudyScope.blockRanges([
                AIStudyScopeRange(startUTF16: 0, lengthUTF16: 90),
                AIStudyScopeRange(startUTF16: 100, lengthUTF16: 50),
            ]).scopeHash,
            AIStudyScope.blockRanges([
                AIStudyScopeRange(startUTF16: 100, lengthUTF16: 50),
                AIStudyScopeRange(startUTF16: 0, lengthUTF16: 90),
            ]).scopeHash)
        XCTAssertEqual(AIStudyScope.fullDocument.scopeHash.count, 64,
                       "fullDocument 也是非空稳定 hash")
    }

    // MARK: - providerSnapshot 无秘密字段（wire §2.1/§4.4）

    /// 反射断言：快照类型不声明任何 Key/endpoint/secret/token/
    /// credential 成员——类型层面杜绝秘密入快照/入备份。
    func testProviderSnapshotDeclaresNoSecrets() {
        let snapshot = AIStudyProviderSnapshot(
            providerKind: "gemini", model: "g-1",
            responseMode: "promptedJSON", promptVersion: "v1",
            policyVersion: "p1")
        let forbidden = [
            "apikey", "api_key", "endpoint", "secret",
            "token", "password", "credential", "bearer",
        ]
        var members: [String] = []
        for child in Mirror(reflecting: snapshot).children {
            members.append(child.label ?? "?")
            let label = (child.label ?? "").lowercased()
            for word in forbidden {
                XCTAssertFalse(
                    label.contains(word),
                    "providerSnapshot 成员 \(child.label ?? "?") 命中禁词 \(word)")
            }
            XCTAssertTrue(child.value is String, "快照成员应全为非敏感 String")
        }
        XCTAssertEqual(
            Set(members),
            ["providerKind", "model", "responseMode",
             "promptVersion", "policyVersion"],
            "快照字段集冻结——新增字段需重新评估秘密边界")
    }

    // MARK: - isActive / terminalStates / canResume

    func testActivityAndTerminalSemantics() {
        XCTAssertEqual(
            AIStudyJobStateMachine.terminalJobStates,
            [.completed, .cancelled, .failed])
        XCTAssertEqual(
            AIStudyJobStateMachine.terminalBlockStates,
            [.applied, .cancelled])

        for status in AIStudyJobStatus.allCases {
            let job = makeJob(status: status)
            XCTAssertEqual(
                AIStudyJobStateMachine.isActive(job),
                !AIStudyJobStateMachine.terminalJobStates.contains(status),
                "isActive=非终态（部分唯一索引领域判据）")
            XCTAssertEqual(
                AIStudyJobStateMachine.canResume(job),
                status == .paused,
                "仅 paused 可 resume")
        }
        // partiallyCompleted 是活跃非终态（可续跑三去向）
        XCTAssertTrue(AIStudyJobStateMachine.isActive(
            makeJob(status: .partiallyCompleted)))
        XCTAssertFalse(AIStudyJobStateMachine.canResume(
            makeJob(status: .partiallyCompleted)))
    }
}
