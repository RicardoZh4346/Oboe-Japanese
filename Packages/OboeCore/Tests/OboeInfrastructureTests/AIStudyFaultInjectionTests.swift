import Foundation
import GRDB
import os
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S21 —— G 独立验证：故障注入与恢复正确性补网。
///
/// 只补 `AIStudyRunnerTests`/`AIStudyApplyServiceTests`/
/// `S24RestoreBarrierTests` 尚未落地的竞态缺口，不重复已覆盖项：
///
/// Runner/store 层
/// - 退避窗口内取消：retryScheduled 块被取消、唤醒作废、不再派发；
/// - Retry-After 精确记账（now+retryAfter×1000）+ runner 端上限钳制；
/// - timeout → retryable 续跑（区别于永久错误一次即 failed）；
/// - 崩溃窗口：`requesting + resultID`（v9 恢复可达）绝不重发；
/// - `requesting + resultID` 不可被死 lease 重领取（store 守卫）；
/// - epoch bump 后 persistOutcome 迟到写被拒；
/// - persistOutcome 同 resultID replay 幂等 / 异 resultID 拒绝；
/// - 持久化 retryScheduled 跨重启到期重发；
/// - replan 幂等（insertBlocksIfAbsent 不翻倍）；
/// - 并发上限钳制 4（maxConcurrentRequests 超界也封顶）。
///
/// Apply 层
/// - 应用中途取消：未结算 unit 记 aborted/failed(jobStateChanged)，
///   已提交 unit 不回滚，Job 保留 cancelled；
/// - applying 且全部 unit 已结算的重入：收尾 → completed + 块 applied。
///
/// Restore 层
/// - v9 备份恢复 aiStudy 运行态归一化：在途 Job → paused(missingSource)、
///   orphan requesting → retryScheduled（清 next_retry）、
///   requesting+result_id 保留、lease_epoch/ai_study_cache 不随迁。
final class AIStudyFaultInjectionTests: XCTestCase {

    // MARK: - Runner：崩溃窗口 / 退避取消 / 恢复派发

    /// §9.1.5 崩溃窗口：requesting 块 resultID 已落库（persistOutcome
    /// 提交后进程死亡 / v9 恢复残留态）。恢复必须走 usePersistedResult
    /// 直接 resolved——同一请求绝不重发（D10），attempt 不涨。
    func testRequestingBlockWithPersistedResultResumesWithoutRefetch()
        async throws
    {
        let env = try await makeRunnerEnvironment()
        let resultID = UUID()
        try await env.pool.write { db in
            var paused = env.job
            paused.status = .paused
            try GRDBAIStudyJobStore.insertJob(paused, in: db)
            try GRDBAIStudyJobStore.insertBlock(
                Self.runnerBlock(
                    jobID: env.job.id, key: "b0", requestHash: "rh-0",
                    status: .requesting, attemptCount: 1,
                    leaseEpoch: 3, resultID: resultID), in: db)
            try GRDBAIStudyJobStore.insertBlock(
                Self.runnerBlock(
                    jobID: env.job.id, key: "b1", requestHash: "rh-1",
                    status: .requesting, attemptCount: 1,
                    leaseEpoch: 3), in: db)
        }
        await env.transport.setHandler { request in
            .success(Self.resolverResult(for: request))
        }

        let runner = env.makeRunner()
        try await runner.resume(jobID: env.job.id)
        await runner.waitUntilSettled(jobID: env.job.id)

        let blocks = try await env.store.fetchBlocks(jobID: env.job.id)
        let b0 = try XCTUnwrap(blocks.first { $0.subblockKey == "b0" })
        XCTAssertEqual(b0.status, .resolved)
        XCTAssertEqual(b0.resultID, resultID, "持久化结果引用保留")
        XCTAssertEqual(b0.attemptCount, 1, "有结果块不重发——attempt 不涨")
        XCTAssertNil(b0.leaseEpoch, "离开 requesting 清运行 lease")
        let b1 = try XCTUnwrap(blocks.first { $0.subblockKey == "b1" })
        XCTAssertEqual(b1.status, .resolved)
        XCTAssertEqual(b1.attemptCount, 2, "死 lease 未知窗口允许重发一次")
        // D10 断言锚点：有结果的块零网络；无结果块只发一次。
        XCTAssertEqual(env.transport.callCount(for: "rh-0"), 0)
        XCTAssertEqual(env.transport.callCount(for: "rh-1"), 1)
        let job = try await env.store.fetchJob(id: env.job.id)
        XCTAssertEqual(job?.status, .awaitingConfirmation)
    }

    /// 退避窗口内取消：retryScheduled 到期前 cancel → 块 cancelled、
    /// Job epoch+1、持久化的退避唤醒作废——观察窗内不重发。
    func testCancelDuringBackoffCancelsBlockAndSilencesRetryWake()
        async throws
    {
        let env = try await makeRunnerEnvironment()
        let fixedNow: Int64 = 1_700_000_000_000
        await env.transport.setHandler { _ in
            throw AIStudyResolverError.rateLimited(retryAfter: 300)
        }
        let runner = env.makeRunner(
            plan: { Self.fixedPlan(jobID: $0, count: 1) },
            nowMs: { fixedNow },
            // 真实挂起——退避唤醒睡得着才能断言「取消作废唤醒」。
            sleep: { ms in
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            })
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: env.job.id)

        try await waitUntil {
            try await env.store.fetchBlocks(jobID: env.job.id)
                .contains { $0.status == .retryScheduled }
        }
        let pending = try await env.store.fetchBlocks(jobID: env.job.id)
        XCTAssertEqual(pending.first?.nextRetryAtMs, fixedNow + 300_000)
        XCTAssertEqual(pending.first?.lastErrorCode, "rateLimited")

        try await runner.cancel(jobID: env.job.id)
        await runner.waitUntilSettled(jobID: env.job.id)

        let job = try await env.store.fetchJob(id: env.job.id)
        XCTAssertEqual(job?.status, .cancelled)
        XCTAssertEqual(job?.epoch, 1, "取消 epoch+1")
        let blocks = try await env.store.fetchBlocks(jobID: env.job.id)
        XCTAssertEqual(blocks.first?.status, .cancelled)
        // 观察窗（唤醒任务已随 runtime 收束取消）：不再派发。
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(env.transport.callCount(for: "rh-0"), 1)
    }

    /// Retry-After 记账精确性：nextRetryAtMs == now + retryAfter×1000
    /// （退避不抖动打折）；超限值被 runner 端上限 86_400s 钳制。
    func testRetryAfterRecordedExactlyAndClampedAtRunnerCap()
        async throws
    {
        for (retryAfter, expectedDelayMs) in
            [(5.0 as TimeInterval, 5_000 as Int64),
             (200_000.0, 86_400_000)]
        {
            let env = try await makeRunnerEnvironment()
            let fixedNow: Int64 = 1_700_000_000_000
            await env.transport.setHandler { _ in
                throw AIStudyResolverError.rateLimited(
                    retryAfter: retryAfter)
            }
            let runner = env.makeRunner(
                plan: { Self.fixedPlan(jobID: $0, count: 1) },
                nowMs: { fixedNow },
                sleep: { ms in
                    try await Task.sleep(
                        nanoseconds: UInt64(max(0, ms)) * 1_000_000)
                })
            _ = try await runner.createJob(env.job)
            try await runner.start(jobID: env.job.id)
            try await waitUntil {
                try await env.store.fetchBlocks(jobID: env.job.id)
                    .contains { $0.status == .retryScheduled }
            }
            let block = try await env.store.fetchBlocks(
                jobID: env.job.id).first
            XCTAssertEqual(
                block?.nextRetryAtMs, fixedNow + expectedDelayMs,
                "retryAfter=\(retryAfter)s 的到期记账")
            try await runner.cancel(jobID: env.job.id)
        }
    }

    /// timeout → `.retryable(.timedOut)` 归类：retryScheduled 续跑
    /// 直至上限封顶 failed（区别于永久错误一次即 failed）。
    func testTimeoutRetriedThenExhausted() async throws {
        let env = try await makeRunnerEnvironment()
        await env.transport.setHandler { request in
            if request.requestHash == "rh-0" {
                throw AIStudyResolverError.retryable(.timedOut)
            }
            return .success(Self.resolverResult(for: request))
        }
        let runner = env.makeRunner(maxAttempts: 2, baseDelayMs: 1)
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: env.job.id)
        await runner.waitUntilSettled(jobID: env.job.id)

        let blocks = try await env.store.fetchBlocks(jobID: env.job.id)
        let failed = try XCTUnwrap(
            blocks.first { $0.subblockKey == "b0" })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastErrorCode, "retryExhausted")
        XCTAssertEqual(failed.attemptCount, 2)
        XCTAssertEqual(env.transport.callCount(for: "rh-0"), 2)
        let resolved = try XCTUnwrap(
            blocks.first { $0.subblockKey == "b1" })
        XCTAssertEqual(resolved.status, .resolved)
        let job = try await env.store.fetchJob(id: env.job.id)
        XCTAssertEqual(job?.status, .partiallyCompleted)
    }

    /// 永久错误（unsupportedConfiguration）一次即 failed——不重试，
    /// 不消耗 attempt 上限之外的派发。
    func testPermanentFailureFailsWithoutRetry() async throws {
        let env = try await makeRunnerEnvironment()
        await env.transport.setHandler { request in
            if request.requestHash == "rh-0" {
                throw AIStudyResolverError.unsupportedConfiguration(
                    "http-400")
            }
            return .success(Self.resolverResult(for: request))
        }
        let runner = env.makeRunner()
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: env.job.id)
        await runner.waitUntilSettled(jobID: env.job.id)

        let blocks = try await env.store.fetchBlocks(jobID: env.job.id)
        let failed = try XCTUnwrap(
            blocks.first { $0.subblockKey == "b0" })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(
            failed.lastErrorCode, "unsupportedConfiguration")
        XCTAssertEqual(failed.attemptCount, 1, "永久错误不重试")
        XCTAssertEqual(env.transport.callCount(for: "rh-0"), 1)
        let job = try await env.store.fetchJob(id: env.job.id)
        XCTAssertEqual(job?.status, .partiallyCompleted)
    }

    /// 持久化退避跨重启：retryScheduled 到期块在新 runner 实例上
    /// resume → 重领取派发 → resolved；attempt 在既有计数上 +1。
    func testRetryScheduledBlockDispatchesWhenDueAfterRestart()
        async throws
    {
        let env = try await makeRunnerEnvironment()
        try await env.pool.write { db in
            var paused = env.job
            paused.status = .paused
            try GRDBAIStudyJobStore.insertJob(paused, in: db)
            try GRDBAIStudyJobStore.insertBlock(
                Self.runnerBlock(
                    jobID: env.job.id, key: "b0", requestHash: "rh-0",
                    status: .retryScheduled, attemptCount: 1,
                    nextRetryAtMs: 1,          // 早已到期
                    lastErrorCode: "rateLimited"), in: db)
        }
        await env.transport.setHandler { request in
            .success(Self.resolverResult(for: request))
        }
        let runner = env.makeRunner()
        try await runner.resume(jobID: env.job.id)
        await runner.waitUntilSettled(jobID: env.job.id)

        let block = try await env.store.fetchBlocks(
            jobID: env.job.id).first
        XCTAssertEqual(block?.status, .resolved)
        XCTAssertEqual(block?.attemptCount, 2)
        XCTAssertNil(block?.lastErrorCode)
        XCTAssertEqual(env.transport.callCount(for: "rh-0"), 1)
        let job = try await env.store.fetchJob(id: env.job.id)
        XCTAssertEqual(job?.status, .awaitingConfirmation)
    }

    /// 并发上限钳制（§9.2 文档最大 4）：maxConcurrentRequests=99
    /// 时实际派发并发 ≤4。
    func testConcurrencyCeilingClampsAtFour() async throws {
        let env = try await makeRunnerEnvironment()
        let jobID = try await env.insertJobWithBlocks(count: 8)
        await env.transport.setHandler { request in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .success(Self.resolverResult(for: request))
        }
        let runner = env.makeRunner(maxConcurrency: 99)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        XCTAssertLessThanOrEqual(
            env.transport.maxInFlight, 4,
            "文档并发上限 4 必须钳制任意配置值")
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(
            blocks.filter { $0.status == .resolved }.count, 8)
    }

    /// 交错完成不重发：flight-A 大结果落库窗口内释放 flight-B；
    /// `resolving` 占有必须防止把仍 requesting 的 waiter 当死 lease
    /// 重复领取。大 resolutions 负载拉长持久化悬挂窗口。
    func testInterleavedCompletionsDoNotDuplicateSend() async throws {
        let env = try await makeRunnerEnvironment()
        _ = try await env.insertJobWithBlocks(count: 2)
        await env.transport.setHandler { request in
            await env.transport.park(request)
        }
        let runner = env.makeRunner()
        try await runner.start(jobID: env.job.id)
        try await waitUntil { env.transport.callCount == 2 }

        // A 先落地（200 条 resolutions 拉长 persist 窗口），
        // 随即释放 B——B 结算时的 pump 不得重领 A 的块。
        env.transport.releaseFirst(
            result: Self.resolverResult(
                for: nil, resolutionCount: 200))
        env.transport.releaseAll(
            result: Self.resolverResult(for: nil))
        await runner.waitUntilSettled(jobID: env.job.id)

        XCTAssertEqual(env.transport.callCount(for: "rh-0"), 1)
        XCTAssertEqual(env.transport.callCount(for: "rh-1"), 1)
        let blocks = try await env.store.fetchBlocks(jobID: env.job.id)
        XCTAssertEqual(Set(blocks.map(\.status)), [.resolved])
        let job = try await env.store.fetchJob(id: env.job.id)
        XCTAssertEqual(job?.status, .awaitingConfirmation)
    }

    // MARK: - Store：epoch/lease/幂等守卫

    /// epoch bump（取消/容器世代）后迟到的结果持久化被拒：
    /// persistOutcome 抛 staleJobEpoch，块态与缓存零写入。
    func testPersistOutcomeRejectedByStaleEpoch() async throws {
        let env = try await makeRunnerEnvironment()
        let block = Self.runnerBlock(
            jobID: env.job.id, key: "b0", requestHash: "rh-0",
            status: .requesting, attemptCount: 1)
        try await env.pool.write { db in
            var running = env.job
            running.status = .waitingForAI
            try GRDBAIStudyJobStore.insertJob(running, in: db)
            try GRDBAIStudyJobStore.insertBlock(block, in: db)
        }
        // 世代 bump：Job → cancelled（epoch 0→1），块仍 requesting。
        _ = try await env.store.transitionJob(
            id: env.job.id, to: .cancelled, expectedEpoch: 0)
        do {
            _ = try await env.store.persistOutcome(
                blockID: block.id, expectedJobEpoch: 0,
                result: Self.cachedResult(requestHash: "rh-0"),
                cacheCapacity: 8)
            XCTFail("旧 epoch 的结果持久化必须被拒")
        } catch let error as AIStudyJobStoreError {
            guard case .staleJobEpoch = error else {
                return XCTFail("期望 staleJobEpoch，得 \(error)")
            }
        }
        // 拒写零副作用：块仍 requesting、无缓存行、无 resolution。
        let stored = try await env.store.fetchBlock(id: block.id)
        XCTAssertEqual(stored?.status, .requesting)
        XCTAssertNil(stored?.resultID)
        let cacheCount = try await env.store.cachedResultCount()
        XCTAssertEqual(cacheCount, 0)
        let resolutions = try await env.store.fetchResolutions(
            jobID: env.job.id)
        XCTAssertTrue(resolutions.isEmpty)
    }

    /// 死 lease 守卫：requesting+resultID 的块既不进 dispatchable
    /// 快照也不可被领取；requesting+nil（真未知窗口）可续约。
    func testClaimGuardsDistinguishDeadLeaseFromPersistedResult()
        async throws
    {
        let env = try await makeRunnerEnvironment()
        let withResult = Self.runnerBlock(
            jobID: env.job.id, key: "b0", requestHash: "rh-0",
            status: .requesting, attemptCount: 1,
            leaseEpoch: 1, resultID: UUID())
        let deadLease = Self.runnerBlock(
            jobID: env.job.id, key: "b1", requestHash: "rh-1",
            status: .requesting, attemptCount: 1, leaseEpoch: 1)
        try await env.pool.write { db in
            var running = env.job
            running.status = .waitingForAI
            try GRDBAIStudyJobStore.insertJob(running, in: db)
            try GRDBAIStudyJobStore.insertBlock(withResult, in: db)
            try GRDBAIStudyJobStore.insertBlock(deadLease, in: db)
        }
        let dispatchable = try await env.store.fetchDispatchableBlocks(
            jobID: env.job.id, nowMs: Int64.max)
        XCTAssertEqual(
            Set(dispatchable.map(\.subblockKey)), ["b1"],
            "requesting+resultID 不得进入可派发快照")
        do {
            _ = try await env.store.claimBlockForDispatch(
                id: withResult.id, leaseEpoch: 2, expectedJobEpoch: 0)
            XCTFail("requesting+resultID 必须拒绝领取")
        } catch let error as AIStudyJobStoreError {
            guard case .blockNotClaimable = error else {
                return XCTFail("期望 blockNotClaimable，得 \(error)")
            }
        }
        // 对照：真死 lease（无结果）可续约，attempt+1。
        let renewed = try await env.store.claimBlockForDispatch(
            id: deadLease.id, leaseEpoch: 2, expectedJobEpoch: 0)
        XCTAssertEqual(renewed.attemptCount, 2)
        XCTAssertEqual(renewed.leaseEpoch, 2)
    }

    /// persistOutcome 幂等：同 resultID replay 直接返回、resolution
    /// 不翻倍；同块异 resultID 一律拒绝。
    func testPersistOutcomeReplayIdempotentAndMismatchRejected()
        async throws
    {
        let env = try await makeRunnerEnvironment()
        let block = Self.runnerBlock(
            jobID: env.job.id, key: "b0", requestHash: "rh-0",
            status: .requesting, attemptCount: 1)
        try await env.pool.write { db in
            var running = env.job
            running.status = .waitingForAI
            try GRDBAIStudyJobStore.insertJob(running, in: db)
            try GRDBAIStudyJobStore.insertBlock(block, in: db)
        }
        let result = Self.cachedResult(requestHash: "rh-0")
        let first = try await env.store.persistOutcome(
            blockID: block.id, expectedJobEpoch: 0,
            result: result, cacheCapacity: 8)
        XCTAssertEqual(first.status, .resolved)
        let resolutionsAfterFirst = try await env.store
            .fetchResolutions(jobID: env.job.id).count

        // replayed completion：同 resultID → 幂等返回。
        let replayed = try await env.store.persistOutcome(
            blockID: block.id, expectedJobEpoch: 0,
            result: result, cacheCapacity: 8)
        XCTAssertEqual(replayed.status, .resolved)
        let resolutionsAfterReplay = try await env.store
            .fetchResolutions(jobID: env.job.id).count
        XCTAssertEqual(
            resolutionsAfterReplay, resolutionsAfterFirst,
            "replay 不得产生新 resolution")

        // 同块异结果：已 resolved 且无 replay 等价性 → 拒绝。
        let different = Self.cachedResult(requestHash: "rh-0")
        XCTAssertNotEqual(different.resultID, result.resultID)
        do {
            _ = try await env.store.persistOutcome(
                blockID: block.id, expectedJobEpoch: 0,
                result: different, cacheCapacity: 8)
            XCTFail("异 resultID 对 resolved 块必须被拒")
        } catch let error as AIStudyJobStoreError {
            guard case .blockNotClaimable = error else {
                return XCTFail("期望 blockNotClaimable，得 \(error)")
            }
        }
    }

    /// replan 幂等：insertBlocksIfAbsent 对已登记 subblock_key
    /// 零插入（崩溃后 replan 不翻倍、不覆盖 checkpoint）。
    func testInsertBlocksIfAbsentIsIdempotentOnReplan() async throws {
        let env = try await makeRunnerEnvironment()
        try await env.store.insertJob(env.job)
        let initial = (0..<2).map {
            Self.runnerBlock(
                jobID: env.job.id, key: "b\($0)",
                requestHash: "rh-\($0)", status: .readyForAI)
        }
        let firstCount = try await env.store.insertBlocksIfAbsent(
            jobID: env.job.id, blocks: initial, expectedEpoch: 0)
        XCTAssertEqual(firstCount, 2)
        // replan：同 subblockKey 新行（新 UUID/新候选 hash）→ 全跳过。
        let replan = (0..<3).map {
            Self.runnerBlock(
                jobID: env.job.id, key: "b\($0)",
                requestHash: "rh-\($0)", status: .readyForAI,
                candidateSetHash: "rehash-\($0)")
        }
        let secondCount = try await env.store.insertBlocksIfAbsent(
            jobID: env.job.id, blocks: replan, expectedEpoch: 0)
        XCTAssertEqual(secondCount, 1, "只新增 b2——既有键不重复插入")
        let blocks = try await env.store.fetchBlocks(jobID: env.job.id)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(
            Set(blocks.map(\.subblockKey)), ["b0", "b1", "b2"])
    }

    // MARK: - Apply：中途取消 / 全结算重入收尾

    /// 应用中途取消：unit 事务复核 epoch → jobStateChanged，
    /// 后续 unit 记 aborted，Job 保留 cancelled——已提交 unit 的
    /// receipt/业务副作用不回滚（取消不陪葬已提交证据）。
    func testCancelMidApplyAbortsRemainingAndPreservesCancelled()
        async throws
    {
        let env = try await makeApplyEnvironment()
        // unitKey 用真实键空间格式（§1.1）——应用层按键序处理。
        let firstKey = "jmdict:sense-v1:100:"
            + String(repeating: "a", count: 64)
        let secondKey = "jmdict:sense-v1:200:"
            + String(repeating: "f", count: 64)
        try await env.insertSelection(
            unitKey: firstKey, decision: .skip, action: .recordSkip)
        try await env.insertSelection(
            unitKey: secondKey, decision: .skip, action: .recordSkip)
        // 物化接缝注入「第二个 unit 前取消 Job」——等价宿主在
        // unit-a 已提交、unit-b 尚未进事务的窗口里点了取消。
        let sources = CancellingUnitSourceProvider(
            pool: env.pool, jobID: env.job.id,
            cancelBeforeUnitKey: secondKey)
        let service = AIStudyApplyService(
            pool: env.pool, unitSources: sources)

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.entryStatus, .applying)
        XCTAssertEqual(report.finalStatus, .cancelled,
                       "取消接管后 Job 保留 cancelled 现态")
        XCTAssertEqual(
            report.units.map(\.unitKey), [firstKey, secondKey])
        XCTAssertEqual(report.units[0].kind, .recordedSkip,
                       "取消前已提交 unit 不回滚")
        XCTAssertEqual(report.units[1].kind, .failed)
        XCTAssertEqual(
            report.units[1].errorCode, "jobStateChanged")
        try await env.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM ai_study_receipts"),
                1, "取消前 unit 的 receipt 已提交保留")
            let status: String? = try String.fetchOne(
                db,
                sql: "SELECT status FROM ai_study_jobs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(env.job.id)])
            XCTAssertEqual(status, "cancelled")
        }
    }

    /// 崩溃窗口：全部 unit 已提交（receipt+applied_receipt_id）
    /// 但 Job 未及收尾停在 applying → 重入只做收尾：
    /// 每 unit 回报 alreadyApplied、Job → completed、所有者块 → applied。
    func testApplyingJobWithAllUnitsSettledFinalizesOnReentry()
        async throws
    {
        let env = try await makeApplyEnvironment(
            jobStatus: .applying)
        // 两个 unit 都锚定 resolution.selectedEntryID=200——
        // advanceOwnerBlocks 据此把宿主块推 applied。
        let keys = [
            "jmdict:sense-v1:200:" + String(repeating: "a", count: 64),
            "jmdict:sense-v1:200:" + String(repeating: "b", count: 64),
        ]
        for key in keys {
            try await env.insertSelection(
                unitKey: key, decision: .skip, action: .recordSkip)
        }
        // 模拟崩溃前完成度：逐 unit 在独立事务里全部落库。
        let context = AIStudyApplyUnitContext(
            jobID: env.job.id, documentID: env.documentID,
            contentRevision: 1, jobEpoch: 0,
            studyDeckID: env.deckID,
            blocks: [env.block], resolutions: [env.resolution])
        try await env.pool.write { db in
            for key in keys {
                _ = try GRDBAIStudyApplyService.applyUnit(
                    context: context,
                    selection: AIStudyJobSelection(
                        jobID: env.job.id, unitKey: key,
                        selectionRevision: 1, decision: .skip,
                        proposedAction: .recordSkip,
                        evidenceRevision: 1),
                    source: nil, atMilliseconds: 1, in: db)
            }
        }

        let report = try await AIStudyApplyService(
            pool: env.pool,
            unitSources: EmptyUnitSourceProvider()
        ).applyConfirmedJob(jobID: env.job.id)

        XCTAssertEqual(report.entryStatus, .applying)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(
            Set(report.units.map(\.kind)), [.alreadyApplied])
        // 零新写：receipt 不翻倍。
        try await env.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM ai_study_receipts"), 2)
            let blockStatus: String? = try String.fetchOne(
                db,
                sql: """
                    SELECT status FROM ai_study_job_blocks
                    WHERE job_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(env.job.id)])
            XCTAssertEqual(blockStatus, "applied",
                           "收尾推进所有者块 → applied")
        }
    }

    // MARK: - v9 备份恢复：aiStudy 运行态归一化

    /// v9 端到端：源库含在途/待确认 Job 与各形态块 → 导出 →
    /// prepare → 预备库中：
    /// - analyzing/waitingForAI/applying Job → paused+missingSource；
    /// - requesting 无结果块 → retryScheduled 且 next_retry 清空；
    /// - requesting+result_id / resolved / pending 原样保留；
    /// - lease_epoch 不导出（落地 NULL）；ai_study_cache 不随迁。
    func testV9RestoreNormalizesAIStudyRuntimeState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S21Fault-v9-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try OboeDatabase(
            path: root.appendingPathComponent("source.sqlite").path)
        let documentID = UUID()
        let waitingJob = Self.backupJob(
            documentID: documentID, revision: 1, status: .waitingForAI)
        let applyingJob = Self.backupJob(
            documentID: documentID, revision: 2, status: .applying)
        let confirmJob = Self.backupJob(
            documentID: documentID, revision: 3,
            status: .awaitingConfirmation)
        let pendingJob = Self.backupJob(
            documentID: documentID, revision: 4, status: .pending)
        let orphanBlock = Self.runnerBlock(
            jobID: waitingJob.id, key: "b-orphan",
            requestHash: "rh-orphan", status: .requesting,
            attemptCount: 1, leaseEpoch: 7, nextRetryAtMs: 999)
        let resultBlock = Self.runnerBlock(
            jobID: waitingJob.id, key: "b-result",
            requestHash: "rh-result", status: .requesting,
            attemptCount: 1, leaseEpoch: 7, resultID: UUID())
        let resolvedBlock = Self.runnerBlock(
            jobID: waitingJob.id, key: "b-done",
            requestHash: "rh-done", status: .resolved,
            attemptCount: 1, resultID: UUID())
        let pendingBlock = Self.runnerBlock(
            jobID: waitingJob.id, key: "b-pending",
            requestHash: "rh-pending", status: .pending)
        try await source.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, availability)
                    VALUES (?, '备份源文档', 'paste', 1, ?, 'h', 'p1',
                            'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    String(repeating: "0", count: 64),
                ])
            for job in [waitingJob, applyingJob, confirmJob, pendingJob] {
                try GRDBAIStudyJobStore.insertJob(job, in: db)
            }
            for block in [orphanBlock, resultBlock, resolvedBlock,
                          pendingBlock] {
                try GRDBAIStudyJobStore.insertBlock(block, in: db)
            }
            // 本机运行态：缓存行 + lease 不应进备份。
            try GRDBAIStudyJobStore.storeCachedResult(
                Self.cachedResult(requestHash: "rh-orphan"),
                capacity: 8, atMs: 1, in: db)
        }
        let package = try await PortableBackupPackageExporter(
            database: source,
            imageStore: InboxImageStore(
                rootDirectoryURL: root.appendingPathComponent("img")),
            workingDirectoryURL: root.appendingPathComponent("exports")
        ).export(appVersion: "test", at: clock, formatVersion: 9)
        try source.close()

        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: root.appendingPathComponent("live.sqlite"),
            snapshotDirectoryURL: root.appendingPathComponent("snaps"))
        let current = try await lifecycle.open()
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: root.appendingPathComponent("prep"))
        let prepared = try await preparer.prepareAutomatically(
            fileURL: package.url)
        XCTAssertEqual(prepared.sourceFormatVersion, 9)

        let restoredPool = try DatabasePool(
            path: prepared.temporaryDatabaseURL.path)
        defer { try? restoredPool.close() }
        try await restoredPool.read { db in
            // 在途 Job → paused + missingSource；等确认/未启动原样。
            for (job, expectStatus) in
                [(waitingJob, "paused"), (applyingJob, "paused"),
                 (confirmJob, "awaitingConfirmation"),
                 (pendingJob, "pending")]
            {
                let row = try XCTUnwrap(try Row.fetchOne(
                    db,
                    sql: """
                        SELECT status, resume_reason FROM ai_study_jobs
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(job.id)]))
                XCTAssertEqual(
                    row["status"] as String?, expectStatus,
                    "\(expectStatus) 期望——job \(job.id)")
                if expectStatus == "paused" {
                    XCTAssertEqual(
                        row["resume_reason"] as String?,
                        "missingSource")
                }
            }
            // orphan requesting → retryScheduled + 到期清空。
            let orphan = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT status, next_retry_at_ms, lease_epoch
                    FROM ai_study_job_blocks WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(
                    orphanBlock.id)]))
            XCTAssertEqual(
                orphan["status"] as String?, "retryScheduled")
            XCTAssertNil(orphan["next_retry_at_ms"] as Int64?)
            XCTAssertNil(orphan["lease_epoch"] as Int64?,
                         "lease_epoch 属运行态红线——不随迁")
            // requesting+result_id 原样保留（续跑走 usePersistedResult）。
            let kept = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT status, result_id FROM ai_study_job_blocks
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(
                    resultBlock.id)]))
            XCTAssertEqual(kept["status"] as String?, "requesting")
            XCTAssertNotNil(kept["result_id"] as String?)
            // resolved/pending 原样保留。
            for (block, expect) in
                [(resolvedBlock, "resolved"), (pendingBlock, "pending")]
            {
                let status: String? = try String.fetchOne(
                    db,
                    sql: """
                        SELECT status FROM ai_study_job_blocks
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(block.id)])
                XCTAssertEqual(status, expect)
            }
            // ai_study_cache 红线：表在但零行随迁。
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM ai_study_cache"), 0)
        }
        try await lifecycle.close()
    }

    // MARK: - 环境构造

    private func makeRunnerEnvironment() async throws -> RunnerEnv {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S21Fault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: configuration)
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)
        let documentID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version, availability)
                    VALUES (?, '测试文档', 'paste', 1, ?, 'hash1',
                            'parser-1', 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    String(repeating: "0", count: 64),
                ])
        }
        let job = AIStudyJob(
            id: UUID(), documentID: documentID,
            scope: .fullDocument, inputFingerprint: "fp",
            contentRevision: 1,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: "fake", model: "fake-model",
                responseMode: "promptedJSON",
                promptVersion: "ai-study-prompt-v1",
                policyVersion: "policy-1"),
            model: "fake-model", pipelineVersion: "pipe-1",
            promptVersion: "ai-study-prompt-v1", policyVersion: "policy-1",
            createdAtMs: 1, updatedAtMs: 1)
        return RunnerEnv(
            pool: pool, store: GRDBAIStudyJobStore(pool: pool),
            transport: FaultTransport(), job: job,
            documentID: documentID)
    }

    /// 应用层最小环境：文档 + 牌组 + Job + awaitingConfirmation 块
    /// + 一条 resolution 证据（与 AIStudyApplyServiceTests 同构裁剪）。
    private func makeApplyEnvironment(
        jobStatus: AIStudyJobStatus = .awaitingConfirmation
    ) async throws -> ApplyEnv {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S21Apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: configuration)
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)

        let documentID = UUID()
        let deckID = UUID()
        let chapterID = UUID()
        let jobID = UUID()
        let locator = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 2,
            blockTextHash: "bhash", prefix: "猫は", suffix: "が好きだ。")
        let locatorJSON = String(
            decoding: try JSONEncoder().encode(locator), as: UTF8.self)
        let block = Self.runnerBlock(
            jobID: jobID, key: "b0", requestHash: "rh-0",
            status: .awaitingConfirmation, locatorJSON: locatorJSON,
            sourceHash: "bhash")
        let resolution = AIStudyResolutionRecord(
            id: UUID(), jobID: jobID, jobBlockID: block.id,
            documentID: documentID, locatorJSON: locatorJSON,
            tokenKey: "tok-0", requestHash: "rh-0",
            selectedEntryID: 200, selectedSenseID: 7,
            selectedDatasetVersion: "ds-test",
            confidence: 0.9, status: .aiResolved, origin: .ai,
            revision: 1, createdAtMs: 1)
        let job = AIStudyJob(
            id: jobID, documentID: documentID, studyDeckID: deckID,
            scope: .fullDocument, inputFingerprint: "fp",
            contentRevision: 1,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: "fake", model: "m",
                responseMode: "promptedJSON",
                promptVersion: "p", policyVersion: "pol"),
            model: "m", pipelineVersion: "pipe",
            promptVersion: "p", policyVersion: "pol",
            status: jobStatus, epoch: 0, selectionRevision: 1,
            createdAtMs: 1, updatedAtMs: 1)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, content_revision,
                        progress_basis_points, availability
                    ) VALUES (?, '研究対象', 'txt', 1, ?, ?, 'v1',
                              1, 0, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    String(repeating: "a", count: 64),
                    String(repeating: "b", count: 64)])
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, '研究牌组', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title,
                        canonical_hash, text_utf16_length
                    ) VALUES (?, ?, 0, '第一章', 'chash', 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_blocks(
                        id, document_id, chapter_id, ordinal,
                        text, text_hash, locator_json
                    ) VALUES (?, ?, ?, 0, ?, 'bhash', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID),
                    DatabaseValueCodec.encode(chapterID),
                    "猫は食べるが好きだ。", locatorJSON])
            try GRDBAIStudyJobStore.insertJob(job, in: db)
            try GRDBAIStudyJobStore.insertBlock(block, in: db)
            try GRDBAIStudyJobStore.insertResolution(
                resolution, documentID: documentID, in: db)
        }
        return ApplyEnv(
            pool: pool, documentID: documentID, deckID: deckID,
            job: job, block: block, resolution: resolution)
    }

    // MARK: - 构造助手

    static func runnerBlock(
        jobID: UUID, key: String, requestHash: String,
        status: AIStudyBlockStatus = .readyForAI,
        attemptCount: Int = 0, leaseEpoch: Int64? = nil,
        nextRetryAtMs: Int64? = nil, resultID: UUID? = nil,
        lastErrorCode: String? = nil,
        locatorJSON: String = "{\"v\":1}", sourceHash: String = "sh",
        candidateSetHash: String = "csh"
    ) -> AIStudyJobBlock {
        AIStudyJobBlock(
            id: UUID(), jobID: jobID,
            locatorJSON: locatorJSON, sourceHash: sourceHash,
            subblockKey: key, candidateSetHash: candidateSetHash,
            requestHash: requestHash, status: status,
            attemptCount: attemptCount, nextRetryAtMs: nextRetryAtMs,
            leaseEpoch: leaseEpoch, resultID: resultID,
            lastErrorCode: lastErrorCode)
    }

    static func fixedPlan(
        jobID: UUID, count: Int
    ) -> [AIStudyRunner.PlannedBlock] {
        (0..<count).map { index in
            plannedBlock(
                for: runnerBlock(
                    jobID: jobID, key: "b\(index)",
                    requestHash: "rh-\(index)",
                    status: .readyForAI),
                jobID: jobID)
        }
    }

    static func plannedBlock(
        for block: AIStudyJobBlock, jobID: UUID
    ) -> AIStudyRunner.PlannedBlock {
        AIStudyRunner.PlannedBlock(
            block: block,
            request: AIStudyRequest(
                requestID: "rq-\(block.requestHash)",
                blocks: [
                    AIStudyBlock(
                        blockKey: block.subblockKey,
                        targetText: "食べる",
                        context: "", targetUTF16Start: 0,
                        targetUTF16Length: 3,
                        tokens: [],
                        candidateSetHash: block.candidateSetHash)
                ],
                metadata: AIStudyRequestMetadata(
                    dictionaryDatasetVersion: "ds-1",
                    morphologyVersion: "m-1",
                    parserVersion: "p-1", osBuild: "os-1",
                    providerKind: "fake",
                    endpointFingerprint: "fake://local",
                    model: "fake-model",
                    responseMode: "promptedJSON",
                    promptVersion: "ai-study-prompt-v1",
                    language: "zho"),
                requestHash: block.requestHash))
    }

    static func resolverResult(
        for request: AIStudyRequest?,
        resolutionCount: Int = 1
    ) -> AIStudyResolverResult {
        let blockKey = request?.blocks.first?.blockKey ?? "b0"
        return AIStudyResolverResult(
            outcome: ValidatedBlockOutcome(
                blockKey: blockKey,
                lexicalStatus: .resolved,
                translationStatus: .done,
                translation: "译文",
                envelopeRejection: nil,
                resolutions: (0..<resolutionCount).map { index in
                    AIStudyResolution(
                        tokenKey: "tok-\(index)",
                        selected: AIStudySelection(
                            provider: "jmdict", entryID: Int64(index),
                            senseID: 1, datasetVersion: "ds-1"),
                        confidence: 0.9, status: .aiResolved,
                        reasonCode: nil, origin: .ai)
                },
                targetTokenCount: resolutionCount,
                aiResolvedCount: resolutionCount,
                lowConfidenceCount: 0, unresolvedTokenCount: 0,
                droppedUnknownTokenCount: 0, duplicateTokenCount: 0,
                malformedItemCount: 0, invalidItemCount: 0),
            requestHash: request?.requestHash ?? "rh-late",
            requestID: request?.requestID ?? "rq-late",
            providerKind: "fake", model: "fake-model",
            promptVersion: "ai-study-prompt-v1",
            responseMode: .promptedJSON,
            suggestedRetryAfter: nil, responseBytes: 64)
    }

    static func cachedResult(requestHash: String) -> AIStudyCachedResult {
        let request = AIStudyRequest(
            requestID: "rq-\(requestHash)",
            blocks: [
                AIStudyBlock(
                    blockKey: "b0", targetText: "食べる", context: "",
                    targetUTF16Start: 0, targetUTF16Length: 3,
                    tokens: [], candidateSetHash: "csh")
            ],
            metadata: AIStudyRequestMetadata(
                dictionaryDatasetVersion: "ds-1",
                morphologyVersion: "m-1", parserVersion: "p-1",
                osBuild: "os-1", providerKind: "fake",
                endpointFingerprint: "fake://local", model: "fake-model",
                responseMode: "promptedJSON",
                promptVersion: "ai-study-prompt-v1", language: "zho"),
            requestHash: requestHash)
        return AIStudyCachedResult(
            result: resolverResult(for: request), resultID: UUID(),
            atMs: 1)
    }

    static func backupJob(
        documentID: UUID, revision: Int64,
        status: AIStudyJobStatus
    ) -> AIStudyJob {
        AIStudyJob(
            id: UUID(), documentID: documentID,
            scope: .fullDocument,
            inputFingerprint: "fp-\(revision)",
            contentRevision: revision,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: "fake", model: "fake-model",
                responseMode: "promptedJSON",
                promptVersion: "ai-study-prompt-v1",
                policyVersion: "policy-1"),
            model: "fake-model", pipelineVersion: "pipe-1",
            promptVersion: "ai-study-prompt-v1", policyVersion: "policy-1",
            status: status, createdAtMs: revision, updatedAtMs: revision)
    }

    private func waitUntil(
        _ predicate: () async throws -> Bool
    ) async throws {
        for _ in 0..<400 {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待条件超时")
    }
}

// MARK: - 测试专用类型（文件私有）

private struct RunnerEnv {
    let pool: DatabasePool
    let store: GRDBAIStudyJobStore
    let transport: FaultTransport
    let job: AIStudyJob
    let documentID: UUID

    func makeRunner(
        plan: @escaping @Sendable (UUID) -> [AIStudyRunner.PlannedBlock]
            = { AIStudyFaultInjectionTests.fixedPlan(jobID: $0, count: 2) },
        maxConcurrency: Int = 2,
        maxAttempts: Int = 4,
        baseDelayMs: Int64 = 10,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { _ in },
        jitter: @escaping @Sendable (Int64) -> Int64 = { $0 }
    ) -> AIStudyRunner {
        let store = self.store
        return AIStudyRunner(
            store: store,
            configuration: AIStudyRunner.Configuration(
                maxConcurrentRequests: maxConcurrency,
                maxAttempts: maxAttempts,
                retryBaseDelayMs: baseDelayMs,
                retryMaxDelayMs: 30_000,
                cacheCapacity: 256),
            planner: { [plan] job in
                // 恢复 replan 同构：已有块按 requestHash 重建载荷。
                let existing =
                    (try? await store.fetchBlocks(jobID: job.id)) ?? []
                if !existing.isEmpty {
                    return existing.map {
                        AIStudyFaultInjectionTests.plannedBlock(
                            for: $0, jobID: job.id)
                    }
                }
                return plan(job.id)
            },
            sendRequest: { [transport] request in
                try await transport.send(request)
            },
            nowMs: nowMs, sleep: sleep, jitter: jitter)
    }

    /// 直接在库内落 Job+块（readyForAI）——等价已创建待驱动。
    func insertJobWithBlocks(count: Int) async throws -> UUID {
        try await pool.write { db in
            try GRDBAIStudyJobStore.insertJob(job, in: db)
            for index in 0..<count {
                try GRDBAIStudyJobStore.insertBlock(
                    AIStudyFaultInjectionTests.runnerBlock(
                        jobID: job.id, key: "b\(index)",
                        requestHash: "rh-\(index)",
                        status: .readyForAI),
                    in: db)
            }
        }
        return job.id
    }
}

/// 手写 transport（与 AIStudyRunnerTests.ScriptedTransport 同构）：
/// handler 注入 + 调用计数 + 最大在途采样 + park/release 手动门。
private final class FaultTransport: @unchecked Sendable {
    typealias Outcome = Result<AIStudyResolverResult, Error>
    typealias Handler =
        @Sendable (AIStudyRequest) async throws -> Outcome

    private struct State {
        var handler: Handler?
        var pendingContinuations:
            [CheckedContinuation<Outcome, Never>] = []
        var counts: [String: Int] = [:]
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var callCount: Int {
        state.withLock { $0.counts.values.reduce(0, +) }
    }
    var maxInFlight: Int {
        state.withLock { $0.maxInFlight }
    }
    func callCount(for requestHash: String) -> Int {
        state.withLock { $0.counts[requestHash] ?? 0 }
    }
    func setHandler(_ handler: @escaping Handler) {
        state.withLock { $0.handler = handler }
    }

    func park(_ request: AIStudyRequest) async -> Outcome {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.pendingContinuations.append(continuation)
            }
        }
    }

    /// 只放行最早驻留的一个请求（交错完成竞态用）。
    func releaseFirst(result: AIStudyResolverResult) {
        let first = state.withLock {
            $0.pendingContinuations.isEmpty
                ? nil : $0.pendingContinuations.removeFirst()
        }
        first?.resume(returning: .success(result))
    }

    func releaseAll(result: AIStudyResolverResult) {
        let continuations = state.withLock {
            let pending = $0.pendingContinuations
            $0.pendingContinuations.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume(returning: .success(result))
        }
    }

    func send(_ request: AIStudyRequest) async throws
        -> AIStudyResolverResult
    {
        let handler = state.withLock {
            $0.counts[request.requestHash, default: 0] += 1
            $0.inFlight += 1
            $0.maxInFlight = max($0.maxInFlight, $0.inFlight)
            return $0.handler
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        guard let handler else {
            throw AIStudyResolverError.retryable(.connectionFailed)
        }
        let outcome = try await handler(request)
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }
}

private struct ApplyEnv {
    let pool: DatabasePool
    let documentID: UUID
    let deckID: UUID
    let job: AIStudyJob
    let block: AIStudyJobBlock
    let resolution: AIStudyResolutionRecord

    func insertSelection(
        unitKey: String, decision: AISelectionDecision,
        action: AIStudyProposedAction?
    ) async throws {
        try await pool.write { db in
            try GRDBAIStudyJobStore.insertSelection(
                AIStudyJobSelection(
                    jobID: job.id, unitKey: unitKey,
                    selectionRevision: 1, decision: decision,
                    proposedAction: action, evidenceRevision: 1),
                in: db)
        }
    }
}

/// 空物化器（skip/receipt-only 路径不需要词典证据）。
private struct EmptyUnitSourceProvider: AIStudyApplyUnitSourceProvider {
    func unitSource(
        for selection: AIStudyJobSelection,
        job: AIStudyJob,
        resolutions: [AIStudyResolutionRecord],
        blocks: [AIStudyJobBlock]
    ) async throws -> AIStudyApplyUnitSource? { nil }
}

/// 物化接缝注入取消：命中 `cancelBeforeUnitKey` 的 unit 在进入
/// 事务前把 Job 转 cancelled（epoch+1）——等价「应用中途取消」。
private final class CancellingUnitSourceProvider:
    AIStudyApplyUnitSourceProvider, @unchecked Sendable
{
    let pool: DatabasePool
    let jobID: UUID
    let cancelBeforeUnitKey: String

    init(pool: DatabasePool, jobID: UUID, cancelBeforeUnitKey: String) {
        self.pool = pool
        self.jobID = jobID
        self.cancelBeforeUnitKey = cancelBeforeUnitKey
    }

    func unitSource(
        for selection: AIStudyJobSelection,
        job: AIStudyJob,
        resolutions: [AIStudyResolutionRecord],
        blocks: [AIStudyJobBlock]
    ) async throws -> AIStudyApplyUnitSource? {
        if selection.unitKey == cancelBeforeUnitKey {
            try await pool.write { db in
                _ = try GRDBAIStudyJobStore.transitionJob(
                    id: jobID, to: .cancelled, expectedEpoch: 0,
                    atMs: 1, in: db)
            }
        }
        return nil
    }
}
