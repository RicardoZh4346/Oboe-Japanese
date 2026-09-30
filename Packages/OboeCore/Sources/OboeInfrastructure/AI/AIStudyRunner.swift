import Foundation
import OboeDomain

/// v0.7.5 S12：AI Study Runner——Job 生命周期驱动、有界并发派发、
/// 请求复用缓存、退避/取消/恢复屏障。
/// 依据：技术文档 §8（缓存/幂等三层）、§9.1（恢复协议）、§9.2
/// （并发/退避/取消）；contracts-frozen §4.1–§4.3。
///
/// # 职责边界
///
/// 本 actor 驱动 Job 的 AI 阶段：
/// `pending → analyzing（plan/装块） → waitingForAI（并发派发） →
///  awaitingConfirmation / partiallyCompleted`。
/// 确认/应用事务（S13/S15）与 Reader 接线（M）不在此——Job 停在
/// `awaitingConfirmation`/`partiallyCompleted`/`paused`/`终态`。
///
/// # 关键语义
///
/// - **状态机唯一实现点**：一切 Job/Block 状态写入经
///   `GRDBAIStudyJobStore` + `AIStudyJobStateMachine`——非法转移
///   不写库。
/// - **epoch 屏障**：派发 lease 与全部块写携带观测 epoch；取消时
///   Job epoch+1，迟到响应/迟到的失败落库被 `staleJobEpoch` 拒——
///   进程内 stub 与真 kill 同一屏障。
/// - **请求复用**：派发先查 `ai_study_cache`（命中零网络）；在途
///   相同 `requestHash` 合并为一个网络请求——跨 Job 同样合并
///   （`flights` 是 runner 级共享表）。
/// - **退避**：429 优先 Retry-After，否则 full-jitter 指数退避
///   （2s 起、60s 上限）；`next_retry_at_ms` 持久化，到期重排队，
///   不 busy loop；`attemptCount >= maxAttempts` → `failed`。
/// - **停派**：401/403/402（`authFailed`）停止本 Job 新派发并
///   `paused(missingKey)`——修好 Key 后 `resume` 续跑（D11）。
/// - **取消**：停止派发 + cancel 在途 Task + Job epoch+1 + 非终态
///   块 → cancelled；已提交结果保留，迟到写被 epoch 屏障拒收。
/// - **恢复屏障**：`paused→analyzing` 续跑按 `resumeAction` 逐块
///   分类——有持久化结果的块绝不重发（resolved/usePersistedResult），
///   requesting 无结果的死 lease 续约重发，`retryScheduled` 等到期。
///
/// # 注入点（测试确定性）
///
/// `planner`：Job → 定稿块 + 请求载荷（内存映射，恢复时确定性
/// replan 重建——planner 是纯函数，同输入同 requestHash）。
/// `sendRequest`：`AIStudyRequest → AIStudyResolverResult` 的
/// transport 接缝——测试用手动/脚本化 fake，不走真网络。
/// `nowMs`/`sleep`/`jitter`：时钟、退避唤醒、抖动全部可注入。
public actor AIStudyRunner {

    // MARK: - 配置与类型

    public struct Configuration: Equatable, Sendable {
        /// 并发派发上限（文档 §9.2：默认 2、最大 4）。
        public var maxConcurrentRequests: Int
        /// 每块派发尝试上限（含首次；超过 → `failed`）。
        /// §9.2「本轮最多 4 次自动重试」按 4 次派发总额落地。
        public var maxAttempts: Int
        /// 指数退避基数（ms）。
        public var retryBaseDelayMs: Int64
        /// 指数退避上限（ms）。
        public var retryMaxDelayMs: Int64
        /// `ai_study_cache` 容量上界（LRU 逐出）。
        public var cacheCapacity: Int

        public init(
            maxConcurrentRequests: Int = 2,
            maxAttempts: Int = 4,
            retryBaseDelayMs: Int64 = 2_000,
            retryMaxDelayMs: Int64 = 60_000,
            cacheCapacity: Int = 256
        ) {
            self.maxConcurrentRequests = maxConcurrentRequests
            self.maxAttempts = maxAttempts
            self.retryBaseDelayMs = retryBaseDelayMs
            self.retryMaxDelayMs = retryMaxDelayMs
            self.cacheCapacity = cacheCapacity
        }

        /// 实际并发度（钳制到文档允许域 1...4）。
        var dispatchConcurrency: Int {
            min(4, max(1, maxConcurrentRequests))
        }
    }

    /// planner 定稿产物：`block` 是落库行字段（安装时统一以
    /// `readyForAI` 入库——对应 pending→analyzing→readyForAI 已完成的
    /// 分析态）；`request` 是派发载荷。`block.requestHash` 必须等于
    /// `request.requestHash`。
    public struct PlannedBlock: Sendable {
        public var block: AIStudyJobBlock
        public var request: AIStudyRequest

        public init(block: AIStudyJobBlock, request: AIStudyRequest) {
            self.block = block
            self.request = request
        }
    }

    public enum RunnerError: Error, Equatable, Sendable {
        case jobNotFound(UUID)
        /// 当前状态不可 start/resume（终态、确认中、应用中等）。
        case jobNotRunnable(jobID: UUID, status: AIStudyJobStatus)
        /// planner 产物不一致：`block.requestHash != request.requestHash`。
        case inconsistentPlan(jobID: UUID, subblockKey: String)
    }

    /// `last_error_code` 归因码（自由文本列，供 UI/审计）。
    public enum FailureCode {
        public static let rateLimited = "rateLimited"
        public static let retryExhausted = "retryExhausted"
        public static let authFailed = "authFailed"
        public static let redirectRejected = "redirectRejected"
        public static let unsupportedConfiguration = "unsupportedConfiguration"
        /// planner 未重建该块的请求载荷（内容漂移/重分析缺口）。
        public static let payloadMissing = "payloadMissing"
    }

    // MARK: - 依赖

    private let store: GRDBAIStudyJobStore
    /// Job → 定稿块序列（恢复时确定性 replan 重建载荷）。
    private let planner:
        @Sendable (AIStudyJob) async throws -> [PlannedBlock]
    /// transport 接缝——生产接 `AIStudyResolverClient.resolve`，
    /// 测试接 fake sender。
    private let sendRequest:
        @Sendable (AIStudyRequest) async throws -> AIStudyResolverResult
    private let configuration: Configuration
    private let nowMs: @Sendable () -> Int64
    /// 退避唤醒挂起（毫秒）。生产 = `Task.sleep`；测试注入可控时钟。
    private let sleep: @Sendable (Int64) async throws -> Void
    /// full-jitter 采样：`jitter(bound) ∈ [0, bound]`。
    private let jitter: @Sendable (Int64) -> Int64

    // MARK: - 运行态

    /// 在途 flight 的块级等待者（跨 Job 共享同一 requestHash 时
    /// 一个 waiter 对应一个块）。
    private struct Waiter: Sendable {
        var jobID: UUID
        var blockID: UUID
        /// 领取时观测的 job.epoch——写回屏障。
        var epoch: Int64
    }

    /// 一个在途网络请求（可能携带多个 waiter 块）。
    private struct Flight {
        var requestHash: String
        var waiters: [Waiter]
        var task: Task<Void, Never>
        /// 请求已返回但 waiter 结果尚在落库——合并分支见此
        /// 直接共享结果结算（不重发网络）。
        var outcome:
            Result<AIStudyResolverResult, AIStudyResolverError>?
    }

    /// 单 Job 运行态（driver 生命周期 = start/resume 的一次驱动）。
    private struct JobRuntime {
        /// 代数：cancel/新 drive 递增——迟到唤醒据此作废。
        var generation: Int
        /// 本次驱动观测的 job.epoch。
        var epoch: Int64
        /// 停派标记（authFailed/pause）——pump 不再领取新块。
        var halted = false
        /// 已安排的退避唤醒任务。
        var wakeTask: Task<Void, Never>?
        /// `waitUntilSettled` 的等待者（驱动收束时放行）。
        var settledWaiters: [CheckedContinuation<Void, Never>] = []
        /// pump 串行化（actor 可重入——`await` 悬挂点间另一 pump
        /// 可能进入）；重入者置 `wantsRePump` 由持有者补跑一轮。
        var pumping = false
        var wantsRePump = false
    }

    /// jobID → 运行态。
    private var runtimes: [UUID: JobRuntime] = [:]
    /// requestHash → 在途请求（runner 级共享——跨 Job 合并）。
    private var flights: [String: Flight] = [:]
    /// jobID → requestHash → 请求载荷（analyze/replan 装配）。
    private var payloads: [UUID: [String: AIStudyRequest]] = [:]
    /// flight 已摘除但结果/失败尚未落库的块——`owned` 判定必须
    /// 覆盖它们：flights 移除与 persistOutcome/applyFailure 完成
    /// 之间有悬挂窗口，缺了这层保护，窗口内的 pump 会把仍
    /// `requesting` 的块当死 lease 重复认领（同一网络请求被重发）。
    private var resolving: Set<UUID> = []

    // MARK: - 自适应节流（B8：AIMD + 限流冷却）

    /// 有效派发并发——AIMD：失败减半（下限 1），连续
    /// `successWindow` 次成功 +1（上限 = 配置并发）。runner 级：
    /// provider 是共享资源，限流/超时按整池背压不按 Job。
    private var effectiveConcurrency: Int
    /// AIMD 升档计数窗。
    private var consecutiveSuccesses = 0
    /// 恢复升档所需连续成功数。
    private static let successWindow = 4
    /// runner 级限流冷却截止时刻（ms）：429/Retry-After 命中的
    /// 窗口内所有 Job 停领新块——服务端要求的全局等待期。
    /// 无 Retry-After 时给 10s 默认冷却（块级退避仍各自生效，
    /// 冷却只是派发闸门）。
    private var cooldownUntilMs: Int64 = 0
    private static let defaultRateLimitCooldownMs: Int64 = 10_000

    public init(
        store: GRDBAIStudyJobStore,
        configuration: Configuration = .init(),
        planner: @escaping @Sendable (AIStudyJob) async throws
            -> [PlannedBlock],
        sendRequest: @escaping @Sendable (AIStudyRequest) async throws
            -> AIStudyResolverResult,
        nowMs: @escaping @Sendable () -> Int64
            = { GRDBAIStudyJobStore.nowMilliseconds() },
        sleep: @escaping @Sendable (Int64) async throws -> Void
            = { ms in
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            },
        jitter: @escaping @Sendable (Int64) -> Int64
            = { bound in bound > 0 ? Int64.random(in: 0...bound) : 0 }
    ) {
        self.store = store
        self.configuration = configuration
        self.planner = planner
        self.sendRequest = sendRequest
        self.nowMs = nowMs
        self.sleep = sleep
        self.jitter = jitter
        self.effectiveConcurrency = configuration.dispatchConcurrency
    }

    // MARK: - Job 生命周期入口

    /// 建 Job（pending）。块由 `start` 的 analyze 阶段经 planner
    /// 装配落库——建 Job 与「拿到请求定稿」是两步，崩溃窗口内
    /// 已派发请求必然有已提交 requestHash（§9.1.1）。
    public func createJob(_ job: AIStudyJob) async throws -> AIStudyJob {
        try await store.insertJob(job)
        return job
    }

    /// 启动/续跑：按持久化状态进对应阶段。
    /// `pending/analyzing` → analyze 阶段（replan + 装块）；
    /// `waitingForAI`（如 driver 死亡的同进程重启）→ 直接续派；
    /// `partiallyCompleted` → `waitingForAI`（续跑失败/待重试块，
    /// failed 块不自动重试——见 `retryFailedBlocks`）。
    public func start(jobID: UUID) async throws {
        let job = try await requireJob(jobID)
        switch job.status {
        case .pending, .analyzing, .waitingForAI, .partiallyCompleted:
            break
        default:
            throw RunnerError.jobNotRunnable(
                jobID: jobID, status: job.status)
        }
        guard runtimes[jobID] == nil else { return }
        runtimes[jobID] = JobRuntime(
            generation: 1, epoch: job.epoch)
        await drive(jobID: jobID)
    }

    /// 续跑：`paused → analyzing` 后按块 checkpoint 续跑（§9.1.6）。
    /// 仅 paused 可 resume（`canResume` 唯一判据）。
    public func resume(jobID: UUID) async throws {
        let job = try await requireJob(jobID)
        guard AIStudyJobStateMachine.canResume(job) else {
            throw RunnerError.jobNotRunnable(
                jobID: jobID, status: job.status)
        }
        let updated = try await store.transitionJob(
            id: jobID, to: .analyzing, expectedEpoch: job.epoch)
        runtimes[jobID] = JobRuntime(
            generation: (runtimes[jobID]?.generation ?? 0) + 1,
            epoch: updated.epoch)
        await drive(jobID: jobID)
    }

    /// 暂停：停止新派发、在途结果仍尽力落库（epoch 不变、
    /// 事务内核对通过——§9.2「进后台尽力保存 checkpoint」）。
    /// 合法源态由状态机保证（analyzing/waitingForAI/applying）。
    public func pause(
        jobID: UUID, reason: AIStudyResumeReason = .manualPause
    ) async throws {
        let job = try await requireJob(jobID)
        _ = try await store.transitionJob(
            id: jobID, to: .paused, expectedEpoch: job.epoch,
            resumeReason: reason)
        if var runtime = runtimes[jobID] {
            runtime.halted = true
            runtimes[jobID] = runtime
        }
        await settle(jobID: jobID)
    }

    /// 取消：停止派发 + cancel 在途 Task + epoch+1 + 非终态块
    /// → cancelled。已提交内容保留（cancelled ≠ 全局 rollback）；
    /// 迟到写被 epoch 屏障拒。幂等（终态直接返回）。
    public func cancel(jobID: UUID) async throws {
        guard let job = try await store.fetchJob(id: jobID) else {
            throw RunnerError.jobNotFound(jobID)
        }
        guard AIStudyJobStateMachine.isActive(job) else { return }
        let updated = try await store.transitionJob(
            id: jobID, to: .cancelled, expectedEpoch: job.epoch)
        _ = try await store.cancelUnfinishedBlocks(
            jobID: jobID, expectedJobEpoch: updated.epoch)
        // 剥离本 Job 的 waiter；无人等待的 flight 取消网络 Task。
        for hash in flights.keys {
            guard var flight = flights[hash],
                  flight.waiters.contains(where: { $0.jobID == jobID })
            else { continue }
            flight.waiters.removeAll { $0.jobID == jobID }
            if flight.waiters.isEmpty {
                flight.task.cancel()
                flights.removeValue(forKey: hash)
            } else {
                flights[hash] = flight
            }
        }
        finishRuntime(jobID: jobID)
    }

    /// 显式「重试失败块」（§4.1：failed→analyzing 不自动发生）：
    /// 失败块回 analyzing，Job `partiallyCompleted→waitingForAI`
    /// 续跑；载荷由 drive 内 replan 重建。
    public func retryFailedBlocks(jobID: UUID) async throws {
        let job = try await requireJob(jobID)
        guard AIStudyJobStateMachine.isActive(job) else {
            throw RunnerError.jobNotRunnable(
                jobID: jobID, status: job.status)
        }
        for block in try await store.fetchBlocks(jobID: jobID)
        where block.status == .failed {
            _ = try await store.transitionBlock(
                id: block.id, to: .analyzing, expectedJobEpoch: job.epoch)
        }
        if runtimes[jobID] == nil {
            runtimes[jobID] = JobRuntime(
                generation: 1, epoch: job.epoch)
            await drive(jobID: jobID)
        }
    }

    /// 等待本 Job 驱动收束（无在途、无待派发、无到期重试——
    /// Job 落 awaitingConfirmation/partiallyCompleted/paused/终态）。
    /// 测试与宿主生命周期接线共用。
    public func waitUntilSettled(jobID: UUID) async {
        // 无 runtime = 驱动已收束（或从未启动）——立即返回。
        guard runtimes[jobID] != nil else { return }
        await withCheckedContinuation { continuation in
            runtimes[jobID]?.settledWaiters.append(continuation)
        }
    }

    // MARK: - 驱动核心

    private func requireJob(_ jobID: UUID) async throws -> AIStudyJob {
        guard let job = try await store.fetchJob(id: jobID) else {
            throw RunnerError.jobNotFound(jobID)
        }
        return job
    }

    /// 一次驱动：分析装配 → waitingForAI → pump → 事件接力收尾。
    /// 错误归宿：stale epoch / 非法 Job 转移 = Job 已被暂停/取消/
    /// 终态接管——收尾运行态即可；planner/存储错误 → Job → failed
    /// （不可恢复系统错误，§4.1）。
    private func drive(jobID: UUID) async {
        guard let runtime = runtimes[jobID] else { return }
        do {
            var job = try await requireJob(jobID)
            if job.status == .pending {
                job = try await store.transitionJob(
                    id: jobID, to: .analyzing,
                    expectedEpoch: runtime.epoch)
            }

            switch job.status {
            case .analyzing, .waitingForAI, .partiallyCompleted:
                // (re)plan：planner 确定性——恢复时同输入同
                // requestHash，载荷按键名回填，不覆盖既有 checkpoint。
                let planned = try await planner(job)
                var merged = payloads[jobID] ?? [:]
                var rows: [AIStudyJobBlock] = []
                for item in planned {
                    guard item.block.requestHash
                            == item.request.requestHash else {
                        throw RunnerError.inconsistentPlan(
                            jobID: jobID,
                            subblockKey: item.block.subblockKey)
                    }
                    merged[item.request.requestHash] = item.request
                    var row = item.block
                    row.status = .readyForAI
                    rows.append(row)
                }
                payloads[jobID] = merged
                _ = try await store.insertBlocksIfAbsent(
                    jobID: jobID, blocks: rows,
                    expectedEpoch: runtime.epoch)

                // 阶段推进（状态机唯一通道）。
                switch job.status {
                case .analyzing, .partiallyCompleted:
                    _ = try await store.transitionJob(
                        id: jobID, to: .waitingForAI,
                        expectedEpoch: runtime.epoch)
                default:
                    break
                }
                try await classifyBlocks(
                    jobID: jobID, epoch: runtime.epoch)
                await pump(jobID: jobID)
            case .paused, .awaitingConfirmation, .applying, .completed,
                 .cancelled, .failed:
                // 中途被接管（pause/cancel 与 analyze 竞争）——收尾。
                finishRuntime(jobID: jobID)
            case .pending:
                break   // 不可达：上面已推进
            }
        } catch {
            await handleDriveError(jobID: jobID, error: error)
        }
    }

    /// 恢复协议（§9.1.5）：逐块按 `resumeAction` 分类推进到
    /// pump 可领取的形态。一切写 epoch-guarded。
    private func classifyBlocks(jobID: UUID, epoch: Int64) async throws {
        let blocks = try await store.fetchBlocks(jobID: jobID)
        let now = nowMs()
        let jobPayloads = payloads[jobID] ?? [:]
        for block in blocks {
            switch AIStudyJobStateMachine.resumeAction(
                for: block, nowMs: now) {
            case .usePersistedResult:
                // 有持久化结果绝不重发（D10）：requesting/readyForAI
                // 崩溃窗口的块直接推 resolved（resultID 已落库）。
                switch block.status {
                case .requesting:
                    _ = try? await store.transitionBlock(
                        id: block.id, to: .resolved,
                        expectedJobEpoch: epoch)
                case .readyForAI:
                    _ = try? await store.transitionBlock(
                        id: block.id, to: .requesting,
                        context: AIStudyBlockTransitionContext(
                            leaseEpoch: epoch),
                        expectedJobEpoch: epoch)
                    _ = try? await store.transitionBlock(
                        id: block.id, to: .resolved,
                        expectedJobEpoch: epoch)
                default:
                    break
                }
            case .analyze:
                // pending/analyzing → readyForAI（需载荷）。
                if jobPayloads[block.requestHash] != nil {
                    _ = try? await advanceToReadyForAI(
                        blockID: block.id, epoch: epoch)
                } else {
                    _ = try? await store.transitionBlock(
                        id: block.id, to: .failed,
                        context: AIStudyBlockTransitionContext(
                            lastErrorCode: FailureCode.payloadMissing),
                        expectedJobEpoch: epoch)
                }
            case .dispatchRequest, .waitForRetry,
                 .presentForConfirmation, .resumeApply,
                 .needsExplicitRetry, .skip, .dropped:
                break   // 交给 pump / 确认阶段 / 显式动作
            }
        }
    }

    /// pending/analyzing → readyForAI（链式转移，同事务两次写——
    /// 状态机相邻两跳无捷径边）。
    private func advanceToReadyForAI(
        blockID: UUID, epoch: Int64
    ) async throws {
        guard let block = try await store.fetchBlock(id: blockID)
        else { return }
        if block.status == .pending {
            _ = try await store.transitionBlock(
                id: blockID, to: .analyzing, expectedJobEpoch: epoch)
        }
        _ = try await store.transitionBlock(
            id: blockID, to: .readyForAI, expectedJobEpoch: epoch)
    }

    /// 派发泵入口（串行化）：actor 的 `await` 悬挂允许另一 pump
    /// 重入——重入者只登记 `wantsRePump`，由持有泵者结束前补跑，
    /// 保证任一时刻至多一个派发循环（并发界与在途合并依赖此
    /// 不变式）。
    private func pump(jobID: UUID) async {
        if var runtime = runtimes[jobID] {
            if runtime.pumping {
                runtime.wantsRePump = true
                runtimes[jobID] = runtime
                return
            }
            runtime.pumping = true
            runtime.wantsRePump = false
            runtimes[jobID] = runtime
        }
        while let runtime = runtimes[jobID], runtime.pumping {
            await pumpOnce(jobID: jobID)
            guard var after = runtimes[jobID] else { return }
            if after.wantsRePump {
                after.wantsRePump = false
                runtimes[jobID] = after
                continue
            }
            after.pumping = false
            runtimes[jobID] = after
        }
    }

    /// 单轮派发：容量内领取可派发块。优先级：
    /// 缓存命中（零网络）→ 在途合并（共享 flight）→ 新 flight。
    /// 每次事件（flight 完成/唤醒/显式调用）后由 `pump` 重进。
    private func pumpOnce(jobID: UUID) async {
        guard let runtime = runtimes[jobID], !runtime.halted else {
            await settle(jobID: jobID)
            return
        }
        guard let job = try? await store.fetchJob(id: jobID),
              job.status == .waitingForAI else {
            await settle(jobID: jobID)
            return
        }
        let now = nowMs()
        // 限流冷却窗：provider 要全局等待期间不领新块（在途
        // flight 完成仍各自落库；窗内唤醒到冷却截止时刻）。
        let cooldown = cooldownUntilMs - now
        if cooldown > 0 {
            if var runtime = runtimes[jobID], runtime.wakeTask == nil {
                let generation = runtime.generation
                runtime.wakeTask = Task { [sleep] in
                    try? await sleep(cooldown)
                    await self.wake(
                        jobID: jobID, generation: generation)
                }
                runtimes[jobID] = runtime
            }
            return
        }
        let epoch = runtime.epoch
        while true {
            let inFlight = inFlightCount(for: jobID)
            // AIMD 有效并发：失败退坡时派发面自动收窄。
            var capacity = effectiveConcurrency - inFlight
            guard capacity > 0 else { break }
            guard let dispatchable = try? await store
                .fetchDispatchableBlocks(jobID: jobID, nowMs: now)
            else { break }
            let owned = Set(flights.values.flatMap {
                $0.waiters.map(\.blockID)
            }).union(resolving)
            var progressed = false
            for block in dispatchable where capacity > 0 {
                if owned.contains(block.id) { continue }
                // ① 缓存命中：零网络落结果（§8.2 请求复用）。
                //    词义层失败（截断/畸形）的结果不复用——历史
                //    版本可能写进过这种毒化行。
                if let cached = try? await store.cachedResult(
                    requestHash: block.requestHash),
                   cached.lexicalStatus != .failed,
                   (try? await store.persistOutcome(
                       blockID: block.id,
                       expectedJobEpoch: epoch,
                       result: cached,
                       cacheCapacity: configuration.cacheCapacity,
                       writeCache: false)) != nil {
                    progressed = true
                    continue   // 不占网络并发槽
                }
                // ② 在途合并：同 requestHash 共享一次网络调用。
                if flights[block.requestHash] != nil {
                    if (try? await store.claimBlockForDispatch(
                        id: block.id, leaseEpoch: epoch,
                        expectedJobEpoch: epoch)) != nil {
                        if var flight = flights[block.requestHash] {
                            let waiter = Waiter(
                                jobID: jobID, blockID: block.id,
                                epoch: epoch)
                            if let outcome = flight.outcome {
                                // 结算中的 flight：直接共享已返回的
                                // 结果——零网络，零重发。
                                await settleWaiter(
                                    waiter, result: outcome)
                            } else {
                                flight.waiters.append(waiter)
                                flights[block.requestHash] = flight
                            }
                        } else if let cached = try? await store
                            .cachedResult(
                                requestHash: block.requestHash),
                            cached.lexicalStatus != .failed,
                            (try? await store.persistOutcome(
                                blockID: block.id,
                                expectedJobEpoch: epoch,
                                result: cached,
                                cacheCapacity:
                                    configuration.cacheCapacity,
                                writeCache: false)) != nil {
                            // flight 在 claim 悬挂期整体结算完毕——
                            // 条目摘除时缓存已落，零网络命中。
                        } else if let request =
                            payloads[jobID]?[block.requestHash] {
                            // 结算的是失败：本块从未上过线，按首次
                            // 尝试自派发兜底（防 waiter 丢失挂死）。
                            spawnFlight(
                                requestHash: block.requestHash,
                                request: request, waiter: Waiter(
                                    jobID: jobID, blockID: block.id,
                                    epoch: epoch))
                        } else {
                            _ = try? await store.transitionBlock(
                                id: block.id, to: .failed,
                                context: AIStudyBlockTransitionContext(
                                    lastErrorCode:
                                        FailureCode.payloadMissing),
                                expectedJobEpoch: epoch)
                        }
                        progressed = true
                    }
                    continue
                }
                // ③ 新派发：载荷必须已由 planner 装配。
                guard let request = payloads[jobID]?[block.requestHash]
                else {
                    _ = try? await store.transitionBlock(
                        id: block.id, to: .failed,
                        context: AIStudyBlockTransitionContext(
                            lastErrorCode: FailureCode.payloadMissing),
                        expectedJobEpoch: epoch)
                    progressed = true
                    continue
                }
                guard (try? await store.claimBlockForDispatch(
                    id: block.id, leaseEpoch: epoch,
                    expectedJobEpoch: epoch)) != nil else {
                    continue   // 状态/epoch 已被别处移动——下轮再看
                }
                spawnFlight(
                    requestHash: block.requestHash, request: request,
                    waiter: Waiter(
                        jobID: jobID, blockID: block.id, epoch: epoch))
                capacity -= 1
                progressed = true
            }
            guard progressed else { break }
        }
        await settle(jobID: jobID)
    }

    private func spawnFlight(
        requestHash: String, request: AIStudyRequest, waiter: Waiter
    ) {
        let send = sendRequest
        let task = Task {
            do {
                let result = try await send(request)
                if Task.isCancelled {
                    await self.flightCompleted(
                        requestHash: requestHash,
                        result: .failure(.cancelled))
                } else {
                    await self.flightCompleted(
                        requestHash: requestHash,
                        result: .success(result))
                }
            } catch let error as AIStudyResolverError {
                await self.flightCompleted(
                    requestHash: requestHash, result: .failure(error))
            } catch is CancellationError {
                await self.flightCompleted(
                    requestHash: requestHash,
                    result: .failure(.cancelled))
            } catch {
                // transport 接缝的非契约错误一律按可重试归类
                //（与 client 的兜底分类同档）。
                await self.flightCompleted(
                    requestHash: requestHash,
                    result: .failure(.retryable(.connectionFailed)))
            }
        }
        flights[requestHash] = Flight(
            requestHash: requestHash, waiters: [waiter], task: task,
            outcome: nil)
    }

    /// flight 完成：flight 条目保留至全部 waiter 落库——悬挂
    /// 窗口内合并进来的块直接共享 `outcome` 就地结算；窗口内
    /// pump 也不得把仍 `requesting` 的 waiter 当死 lease 重领
    /// （`resolving` 占有）。全部落定后才摘条目、回 pump 补位。
    private func flightCompleted(
        requestHash: String,
        result: Result<AIStudyResolverResult, AIStudyResolverError>
    ) async {
        guard var flight = flights[requestHash],
              flight.outcome == nil else { return }
        flight.outcome = result
        flights[requestHash] = flight
        recordThrottle(result)
        let waiters = flight.waiters
        resolving.formUnion(waiters.map(\.blockID))
        var affectedJobs = Set<UUID>()
        for waiter in waiters {
            await settleWaiter(waiter, result: result)
            affectedJobs.insert(waiter.jobID)
        }
        // 全部落定后再摘条目——settle/inFlight 以条目在不在
        // 判占有；摘除后的 pump 才看得到真实的「无在途」并收束。
        for waiter in waiters {
            resolving.remove(waiter.blockID)
        }
        flights.removeValue(forKey: requestHash)
        for jobID in affectedJobs {
            await pump(jobID: jobID)
        }
    }

    /// AIMD 节流记录 + 429 冷却窗设置（runner 级）。
    /// 词义层失败（截断/畸形外层拒绝）同样按失败降档——provider
    /// 应答不可用与传输失败对吞吐的含义相同。
    private func recordThrottle(
        _ result: Result<AIStudyResolverResult, AIStudyResolverError>
    ) {
        switch result {
        case .success(let resolverResult):
            if resolverResult.outcome.lexicalStatus == .failed {
                effectiveConcurrency = max(1, effectiveConcurrency / 2)
                consecutiveSuccesses = 0
            } else {
                consecutiveSuccesses += 1
                if consecutiveSuccesses >= Self.successWindow,
                   effectiveConcurrency
                        < configuration.dispatchConcurrency {
                    effectiveConcurrency += 1
                    consecutiveSuccesses = 0
                }
            }
        case .failure(let error):
            consecutiveSuccesses = 0
            effectiveConcurrency = max(1, effectiveConcurrency / 2)
            if case .rateLimited(let retryAfter) = error {
                // 服务端明确给的等待期优先；缺省给 10s 冷却闸
                // （块级 retryScheduled 仍有自己的退避到期时刻）。
                let cooldownMs = retryAfter.map {
                    min(Int64($0 * 1_000),
                        Int64(AIStudyResolverClient
                            .maxRetryAfterInterval) * 1_000)
                } ?? Self.defaultRateLimitCooldownMs
                cooldownUntilMs = max(cooldownUntilMs, nowMs() + cooldownMs)
            }
        }
    }

    /// 单个 waiter 按请求结果落库（成功 → 持久化结果+写缓存；
    /// 失败 → 归类转移）。合并进结算中 flight 的块共用此路径。
    ///
    /// 截断/畸形外层拒绝（`lexicalStatus == .failed`）**不**落
    /// resolved——HTTP 成功但词义全丢，静默收下会造出「已完成
    /// 却零 resolution」的块并毒化 `ai_study_cache`（同 hash
    /// 后续命中直接把失败结果给别的块）。统一走可重试失败档：
    /// 归因码 `envelope.<kind>`，退避重试到 `maxAttempts`。
    private func settleWaiter(
        _ waiter: Waiter,
        result: Result<AIStudyResolverResult, AIStudyResolverError>
    ) async {
        switch result {
        case .success(let resolverResult):
            if resolverResult.outcome.lexicalStatus == .failed {
                let rejection = resolverResult.outcome
                    .envelopeRejection?.rawValue ?? "unknown"
                await applyFailure(
                    waiter: waiter,
                    error: .retryable(.malformedResponse),
                    failureCode: "envelope.\(rejection)")
                return
            }
            let cached = AIStudyCachedResult(
                result: resolverResult, resultID: UUID(), atMs: nowMs())
            _ = try? await store.persistOutcome(
                blockID: waiter.blockID,
                expectedJobEpoch: waiter.epoch,
                result: cached,
                cacheCapacity: configuration.cacheCapacity)
        case .failure(let error):
            await applyFailure(waiter: waiter, error: error)
        }
    }

    /// 失败归类落库（§9.2）：429/Retry-After 与可重试档 →
    /// retryScheduled（bounded attempts → failed）；auth → 停派 +
    /// paused(missingKey)；其余非重试 → failed；cancelled 不写
    /// （epoch 屏障兜底）。
    private func applyFailure(
        waiter: Waiter, error: AIStudyResolverError,
        failureCode: String? = nil
    ) async {
        guard let block = try? await store.fetchBlock(
            id: waiter.blockID), block.status == .requesting
        else { return }
        let now = nowMs()
        switch error {
        case .cancelled:
            break
        case .authFailed:
            _ = try? await store.transitionBlock(
                id: waiter.blockID, to: .failed,
                context: AIStudyBlockTransitionContext(
                    lastErrorCode: FailureCode.authFailed),
                expectedJobEpoch: waiter.epoch)
            if var runtime = runtimes[waiter.jobID], !runtime.halted {
                runtime.halted = true
                runtimes[waiter.jobID] = runtime
                // §9.2：401/403/402 停派——修好凭据后 resume 续跑。
                if let job = try? await store.fetchJob(
                    id: waiter.jobID), job.status == .waitingForAI {
                    _ = try? await store.transitionJob(
                        id: waiter.jobID, to: .paused,
                        expectedEpoch: job.epoch,
                        resumeReason: .missingKey)
                }
            }
        case .rateLimited(let retryAfter):
            let delay = retryDelayMs(
                attempt: block.attemptCount, retryAfter: retryAfter)
            if block.attemptCount >= configuration.maxAttempts {
                _ = try? await store.transitionBlock(
                    id: waiter.blockID, to: .failed,
                    context: AIStudyBlockTransitionContext(
                        lastErrorCode: FailureCode.retryExhausted),
                    expectedJobEpoch: waiter.epoch)
            } else {
                _ = try? await store.transitionBlock(
                    id: waiter.blockID, to: .retryScheduled,
                    context: AIStudyBlockTransitionContext(
                        nextRetryAtMs: now + delay,
                        lastErrorCode: FailureCode.rateLimited),
                    expectedJobEpoch: waiter.epoch)
            }
        case .retryable(let underlying):
            let delay = retryDelayMs(
                attempt: block.attemptCount, retryAfter: nil)
            if block.attemptCount >= configuration.maxAttempts {
                _ = try? await store.transitionBlock(
                    id: waiter.blockID, to: .failed,
                    context: AIStudyBlockTransitionContext(
                        lastErrorCode: failureCode
                            ?? FailureCode.retryExhausted),
                    expectedJobEpoch: waiter.epoch)
            } else {
                _ = try? await store.transitionBlock(
                    id: waiter.blockID, to: .retryScheduled,
                    context: AIStudyBlockTransitionContext(
                        nextRetryAtMs: now + delay,
                        lastErrorCode: failureCode
                            ?? "retryable.\(shortName(underlying))"),
                    expectedJobEpoch: waiter.epoch)
            }
        case .unsupportedConfiguration:
            _ = try? await store.transitionBlock(
                id: waiter.blockID, to: .failed,
                context: AIStudyBlockTransitionContext(
                    lastErrorCode:
                        FailureCode.unsupportedConfiguration),
                expectedJobEpoch: waiter.epoch)
        case .redirectRejected:
            _ = try? await store.transitionBlock(
                id: waiter.blockID, to: .failed,
                context: AIStudyBlockTransitionContext(
                    lastErrorCode: FailureCode.redirectRejected),
                expectedJobEpoch: waiter.epoch)
        }
    }

    /// full-jitter 退避：`min(max, base·2^(attempt-1))` 为帽，
    /// 取 `jitter(cap) ∈ [0,cap]`；Retry-After 优先且不打折
    /// （钳制在 client 同源上限内）。
    private func retryDelayMs(
        attempt: Int, retryAfter: TimeInterval?
    ) -> Int64 {
        if let retryAfter {
            return min(
                Int64(retryAfter * 1_000),
                Int64(AIStudyResolverClient.maxRetryAfterInterval) * 1_000)
        }
        let shift = min(max(attempt - 1, 0), 10)
        let cap = min(
            configuration.retryMaxDelayMs,
            configuration.retryBaseDelayMs * Int64(1 << shift))
        return jitter(cap)
    }

    /// 收束判定：无在途、无可派发、无待重试 → Job 落目标态并
    /// 放行 `waitUntilSettled`。否则登记退避唤醒（不 busy loop）。
    private func settle(jobID: UUID) async {
        guard var runtime = runtimes[jobID] else { return }
        guard let job = try? await store.fetchJob(id: jobID) else {
            finishRuntime(jobID: jobID)
            return
        }
        switch job.status {
        case .paused:
            // 暂停收束：在途结果尽力落库已完成/仍会各自落库；
            // runtime 保留供 settleWaiters，新派发已停。
            finishRuntime(jobID: jobID)
            return
        case .awaitingConfirmation, .applying, .completed,
             .cancelled, .failed:
            finishRuntime(jobID: jobID)
            return
        case .pending, .analyzing, .waitingForAI,
             .partiallyCompleted:
            break
        }

        let now = nowMs()
        let blocks = (try? await store.fetchBlocks(jobID: jobID)) ?? []
        let inFlight = inFlightCount(for: jobID)
        let owned = Set(flights.values.flatMap {
            $0.waiters.map(\.blockID)
        }).union(resolving)
        var outstanding = false          // 现在就能推进的工作
        var sawFailed = false
        var earliestRetry: Int64?
        for block in blocks {
            switch block.status {
            case .pending, .analyzing, .readyForAI:
                outstanding = true
            case .requesting:
                if !owned.contains(block.id) { outstanding = true }
            case .retryScheduled:
                if let due = block.nextRetryAtMs, due > now {
                    earliestRetry = min(earliestRetry ?? .max, due)
                } else {
                    outstanding = true
                }
            case .failed:
                sawFailed = true
            case .resolved, .awaitingConfirmation, .applying,
                 .applied, .cancelled:
                break
            }
        }

        if runtime.halted {
            // 停派（auth/pause 落地中）：无在途即收束放行等待者；
            // 有在途则等结果自然落库后再次 settle。
            if inFlight == 0 { finishRuntime(jobID: jobID) }
            return
        }
        if outstanding || inFlight > 0 {
            runtime.wakeTask?.cancel()
            runtime.wakeTask = nil
            if outstanding, inFlight == 0 {
                // 事件接力空洞防护：存在可派发块却零在途——
                // 状态在悬挂窗口刚腾空（flight 摘除晚于本轮
                // 派发快照），无人再触发 pump → 立即补一轮。
                let generation = runtime.generation
                runtime.wakeTask = Task { [sleep] in
                    try? await sleep(0)
                    await self.wake(
                        jobID: jobID, generation: generation)
                }
            }
            runtimes[jobID] = runtime
            return   // 事件接力：下个完成/唤醒回 pump
        }
        if let wakeAt = earliestRetry {
            // 等最早到期重试——持久化等待，不 busy loop。
            guard runtime.wakeTask == nil else { return }
            let generation = runtime.generation
            let delay = max(0, wakeAt - nowMs())
            runtime.wakeTask = Task { [sleep] in
                try? await sleep(delay)
                await self.wake(jobID: jobID, generation: generation)
            }
            runtimes[jobID] = runtime
            return
        }

        // 收束：有失败 → partiallyCompleted；否则 →
        // awaitingConfirmation（等待确认/应用阶段接管，§10/§11）。
        let target: AIStudyJobStatus =
            sawFailed ? .partiallyCompleted : .awaitingConfirmation
        if job.status != target,
           AIStudyJobStateMachine.canTransition(
               from: job.status, to: target) {
            _ = try? await store.transitionJob(
                id: jobID, to: target, expectedEpoch: job.epoch)
        }
        finishRuntime(jobID: jobID)
    }

    /// 退避唤醒：代数核对（cancel/新驱动后旧唤醒作废）。
    private func wake(jobID: UUID, generation: Int) async {
        guard var runtime = runtimes[jobID],
              runtime.generation == generation else { return }
        runtime.wakeTask = nil
        runtimes[jobID] = runtime
        await pump(jobID: jobID)
    }

    /// 驱动错误归宿：Job 已被合法接管（暂停/取消/终态/epoch
    /// 漂移）→ 收 runtime；其余（planner/存储/系统错误）→
    /// Job `failed`（§4.1 不可恢复系统错误）。
    private func handleDriveError(jobID: UUID, error: Error) async {
        if let storeError = error as? AIStudyJobStoreError {
            switch storeError {
            case .staleJobEpoch, .jobNotFound:
                finishRuntime(jobID: jobID)
                return
            default:
                break
            }
        }
        if error is AIStudyJobTransitionError {
            finishRuntime(jobID: jobID)
            return
        }
        if let job = try? await store.fetchJob(id: jobID),
           AIStudyJobStateMachine.canTransition(
               from: job.status, to: .failed) {
            _ = try? await store.transitionJob(
                id: jobID, to: .failed, expectedEpoch: job.epoch)
        }
        finishRuntime(jobID: jobID)
    }

    /// 收束运行态：停唤醒、放行 settle 等待者、清理载荷与
    /// runtime（后续 start/resume 按持久化状态重建）。
    private func finishRuntime(jobID: UUID) {
        guard var runtime = runtimes[jobID] else { return }
        runtime.wakeTask?.cancel()
        let waiters = runtime.settledWaiters
        runtime.settledWaiters.removeAll()
        runtime.wakeTask = nil
        runtimes[jobID] = runtime
        payloads[jobID] = nil
        runtimes.removeValue(forKey: jobID)
        for waiter in waiters { waiter.resume() }
    }

    private func inFlightCount(for jobID: UUID) -> Int {
        flights.values.reduce(0) {
            $0 + $1.waiters.filter { $0.jobID == jobID }.count
        }
    }

    private func shortName(_ error: AIConnectionError) -> String {
        switch error {
        case .aiDisabled: return "aiDisabled"
        case .modelNotSelected: return "modelNotSelected"
        case .credentialMissing: return "credentialMissing"
        case .invalidCredential: return "invalidCredential"
        case .cancelled: return "cancelled"
        case .timedOut: return "timedOut"
        case .networkUnavailable: return "networkUnavailable"
        case .connectionFailed: return "connectionFailed"
        case .secureConnectionFailed: return "secureConnectionFailed"
        case .redirectRejected: return "redirectRejected"
        case .authenticationFailed: return "authenticationFailed"
        case .insufficientBalance: return "insufficientBalance"
        case .unsupportedConfiguration: return "unsupportedConfiguration"
        case .rateLimited: return "rateLimited"
        case .serviceUnavailable: return "serviceUnavailable"
        case .unexpectedStatus: return "unexpectedStatus"
        case .responseTooLarge: return "responseTooLarge"
        case .malformedResponse: return "malformedResponse"
        case .emptyResponse: return "emptyResponse"
        case .truncatedResponse: return "truncatedResponse"
        case .capabilityMismatch: return "capabilityMismatch"
        }
    }
}
