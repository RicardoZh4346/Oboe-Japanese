import Foundation
import GRDB
import os
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S12：Runner 验收——杀进程续跑不重发已存块、取消后迟到
/// 写拒收、429 退避上限、401 停派、在途合并、缓存零网络、并发界。
///
/// `ScriptedTransport` 提供手动完成语义：每个请求登记 pending，
/// 测试按序 resolve/throw；`gate` 打开时后续请求驻留等待测试放行。
final class AIStudyRunnerTests: XCTestCase {

    // MARK: - 端到端：跑完一个 Job

    /// 两块全部成功 → Job 落 awaitingConfirmation，块 resolved，
    /// resolution 行落库，请求各发一次。
    func testRunToAwaitingConfirmation() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport

        await transport.setHandler { request in
            .success(Self.resolverResult(for: request))
        }

        let runner = env.makeRunner()
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        let job = try await env.store.fetchJob(id: jobID)
        XCTAssertEqual(job?.status, .awaitingConfirmation)
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(Set(blocks.map(\.status)), [.resolved])
        XCTAssertEqual(transport.callCount, 2)
        let resolutions = try await env.store.fetchResolutions(
            jobID: jobID)
        XCTAssertFalse(resolutions.isEmpty)
    }

    // MARK: - 恢复屏障

    /// §9.1：第一块已 resolved 后驱动中断；新 runner 实例 resume
    /// 只发剩余块——已存结果绝不重发。
    func testResumeDoesNotRefetchSavedBlocks() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport

        // 第一轮：块0成功、块1驻留（gate 卡住）→ Job 停在等待态。
        await transport.setHandler { request in
            if request.requestHash == "rh-0" {
                return .success(Self.resolverResult(for: request))
            }
            return await transport.park(request)
        }
        let runner1 = env.makeRunner()
        _ = try await runner1.createJob(env.job)
        try await runner1.start(jobID: jobID)
        // 等块0落库（轮询 DB——测试时钟不外流 runner 内部事件）。
        try await waitUntil {
            try await env.store.fetchBlocks(jobID: jobID)
                .contains { $0.status == .resolved }
        }

        // 等价 kill：pause 收束 runtime（在途块仍 requesting），
        // 新建 runner 实例模拟新进程。
        try await runner1.pause(jobID: jobID)
        let runner2 = env.makeRunner()
        await transport.setHandler { request in
            .success(Self.resolverResult(for: request))
        }
        try await runner2.resume(jobID: jobID)
        await runner2.waitUntilSettled(jobID: jobID)

        let job = try await env.store.fetchJob(id: jobID)
        XCTAssertEqual(job?.status, .awaitingConfirmation)
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(Set(blocks.map(\.status)), [.resolved])
        // 关键断言：已 resolved 的块未产生第二个网络请求——
        // 同 requestHash 只发一次（rh-0 一次、rh-1 驻留那次 + 续跑
        // 重发一次 = 2 次，块0零重发）。
        XCTAssertEqual(transport.callCount(for: "rh-0"), 1)
        XCTAssertEqual(transport.callCount(for: "rh-1"), 2)
    }

    /// 取消 bump epoch 后，在途响应迟到到达 → 块保持 cancelled，
    /// 不写结果（stale epoch 屏障）。
    func testCancelRejectsLateWrites() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport
        await transport.setHandler { request in
            await transport.park(request)
        }

        let runner = env.makeRunner()
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: jobID)
        try await waitUntil { transport.callCount > 0 }

        try await runner.cancel(jobID: jobID)
        let job = try await env.store.fetchJob(id: jobID)
        XCTAssertEqual(job?.status, .cancelled)
        let epochAfterCancel = job?.epoch

        // 迟到完成：runner 内的 flight 已摘除——完成直接丢弃；
        // 即便落地也被 epoch 屏障拒（store 层断言另行覆盖）。
        await transport.releaseAll(
            result: Self.resolverResult(for: nil))
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(Set(blocks.map(\.status)), [.cancelled])
        XCTAssertTrue(blocks.allSatisfy { $0.resultID == nil })
        XCTAssertEqual(epochAfterCancel, 1, "取消应 epoch+1")
    }

    /// epoch 守卫写入：携带旧 epoch 的 transitionJob 被拒。
    func testStaleEpochWriteRejected() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        try await env.store.insertJob(env.job)
        _ = try await env.store.transitionJob(
            id: jobID, to: .cancelled, expectedEpoch: 0)
        do {
            _ = try await env.store.transitionJob(
                id: jobID, to: .paused, expectedEpoch: 0)
            XCTFail("旧 epoch 写必须被拒")
        } catch let error as AIStudyJobStoreError {
            guard case .staleJobEpoch = error else {
                return XCTFail("期望 staleJobEpoch，得 \(error)")
            }
        }
    }

    // MARK: - 退避 / 停派

    /// 429 带 Retry-After → retryScheduled + nextRetryAtMs 在未来；
    /// 尝试上限耗尽 → failed，Job 落 partiallyCompleted。
    func testRateLimitedBackoffThenFailed() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport
        // 块0 永远 429；块1 成功——失败后 Job 应 partiallyCompleted。
        await transport.setHandler { request in
            if request.requestHash == "rh-0" {
                throw AIStudyResolverError.rateLimited(retryAfter: nil)
            }
            return .success(Self.resolverResult(for: request))
        }

        let runner = env.makeRunner(
            maxAttempts: 2, baseDelayMs: 1_000, jitter: { $0 })
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        let failed = try XCTUnwrap(
            blocks.first { $0.subblockKey == "b0" })
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastErrorCode, "retryExhausted")
        XCTAssertEqual(failed.attemptCount, 2, "2 次派发后封顶")
        let resolved = try XCTUnwrap(
            blocks.first { $0.subblockKey == "b1" })
        XCTAssertEqual(resolved.status, .resolved)
        let job = try await env.store.fetchJob(id: jobID)
        XCTAssertEqual(job?.status, .partiallyCompleted)
    }

    /// 首次 429 → retryScheduled 且 nextRetryAtMs 写入未来时刻；
    /// 到期后重发成功 → resolved。
    func testRetryScheduledThenRecovers() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport
        await transport.setHandler { request in
            if request.requestHash == "rh-0",
               transport.callCount(for: "rh-0") == 1 {
                throw AIStudyResolverError.rateLimited(
                    retryAfter: 0.001)
            }
            return .success(Self.resolverResult(for: request))
        }

        let runner = env.makeRunner()
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(Set(blocks.map(\.status)), [.resolved])
        let job = try await env.store.fetchJob(id: jobID)
        XCTAssertEqual(job?.status, .awaitingConfirmation)
        XCTAssertEqual(transport.callCount(for: "rh-0"), 2)
    }

    /// 401 → 停派：该块 failed(authFailed)，Job paused(missingKey)，
    /// 未派发块保持非 requesting。
    func testAuthFailureHaltsDispatch() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport
        await transport.setHandler { _ in
            throw AIStudyResolverError.authFailed
        }

        let runner = env.makeRunner()
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        let job = try await env.store.fetchJob(id: jobID)
        XCTAssertEqual(job?.status, .paused)
        XCTAssertEqual(job?.resumeReason, .missingKey)
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertTrue(blocks.allSatisfy { $0.status == .failed })
        XCTAssertTrue(
            blocks.allSatisfy { $0.lastErrorCode == "authFailed" })
    }

    // MARK: - 请求复用 / 并发界

    /// 同 requestHash 的两块在途合并——一次网络调用喂两个 waiter。
    func testInFlightMergeSharesOneRequest() async throws {
        let env = try await makeEnvironment(
            plan: { jobID in
                (0..<2).map { index in
                    let block = AIStudyJobBlock(
                        id: UUID(), jobID: jobID,
                        locatorJSON: "{\"block\":\(index)}",
                        sourceHash: "sh-\(index)",
                        subblockKey: "b\(index)",
                        candidateSetHash: "csh",
                        requestHash: "rh-shared")
                    return TestEnvironment.makePlannedBlock(
                        block: block, jobID: jobID)
                }
            })
        let jobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport
        await transport.setHandler { request in
            .success(Self.resolverResult(for: request))
        }

        let runner = env.makeRunner()
        _ = try await runner.createJob(env.job)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        XCTAssertEqual(transport.callCount(for: "rh-shared"), 1)
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(Set(blocks.map(\.status)), [.resolved])
    }

    /// ai_study_cache 命中：新 Job 同 requestHash 零网络。
    func testPersistedCacheHitSkipsNetwork() async throws {
        let env = try await makeEnvironment()
        let firstJobID = try await env.insertJobWithTwoBlocks()
        let transport = env.transport
        await transport.setHandler { request in
            .success(Self.resolverResult(for: request))
        }
        let runner1 = env.makeRunner()
        _ = try await runner1.createJob(env.job)
        try await runner1.start(jobID: firstJobID)
        await runner1.waitUntilSettled(jobID: firstJobID)
        XCTAssertEqual(transport.callCount, 2)

        // 第二个 Job（另一文档修订）同 requestHash——全部走缓存。
        let secondJobID = try await env.insertSecondJob()
        let callsBefore = transport.callCount
        let runner2 = env.makeRunner()
        try await runner2.start(jobID: secondJobID)
        await runner2.waitUntilSettled(jobID: secondJobID)

        XCTAssertEqual(
            transport.callCount - callsBefore, 0,
            "缓存命中必须零网络")
        let blocks = try await env.store.fetchBlocks(
            jobID: secondJobID)
        XCTAssertEqual(Set(blocks.map(\.status)), [.resolved])
    }

    /// 并发界：6 块、上限 2——任一时刻在途 ≤ 2。
    func testConcurrencyBoundRespected() async throws {
        let env = try await makeEnvironment()
        let jobID = try await env.insertJob(withBlockCount: 6)
        let transport = env.transport
        await transport.setHandler { request in
            // 每个请求驻留一小段——让并发上限在采样窗口内生效。
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .success(Self.resolverResult(for: request))
        }

        let runner = env.makeRunner(maxConcurrency: 2)
        try await runner.start(jobID: jobID)
        await runner.waitUntilSettled(jobID: jobID)

        XCTAssertLessThanOrEqual(transport.maxInFlight, 2)
        let blocks = try await env.store.fetchBlocks(jobID: jobID)
        XCTAssertEqual(
            blocks.filter { $0.status == .resolved }.count, 6)
    }

    // MARK: - receipt / store 级不变量

    /// action_key 重放返回既有 receipt——幂等第三层锚点。
    func testReceiptReplayReturnsExisting() async throws {
        let env = try await makeEnvironment()
        _ = try await env.insertJobWithTwoBlocks()
        let opID = UUID()
        let first = try await env.store.recordReceipt(
            AIStudyReceipt(
                operationID: opID, actionKey: "job:x:u1:v1",
                payloadHash: "ph1", outcomeJSON: "{\"ok\":true}",
                committedAtMs: 1))
        let replayed = try await env.store.recordReceipt(
            AIStudyReceipt(
                operationID: UUID(), actionKey: "job:x:u1:v1",
                payloadHash: "ph1", outcomeJSON: "{\"ok\":true}",
                committedAtMs: 2))
        XCTAssertEqual(first.operationID, replayed.operationID)
        XCTAssertEqual(replayed.operationID, opID)
    }

    /// 同 document/revision 第二个活跃 Job 被拒（部分唯一索引）。
    func testActiveJobConflictRejected() async throws {
        let env = try await makeEnvironment()
        _ = try await env.insertJobWithTwoBlocks()
        try await env.store.insertJob(env.job)
        do {
            try await env.store.insertJob(env.job.with(id: UUID()))
            XCTFail("第二个活跃 Job 必须被拒")
        } catch let error as AIStudyJobStoreError {
            guard case .activeJobConflict = error else {
                return XCTFail("期望 activeJobConflict，得 \(error)")
            }
        }
    }

    /// LRU：超过容量逐出最旧访问项。
    func testCacheLRUEviction() async throws {
        let env = try await makeEnvironment()
        let pool = env.pool
        try await pool.write { db in
            for index in 0..<4 {
                try GRDBAIStudyJobStore.storeCachedResult(
                    Self.cachedResult(requestHash: "rh-\(index)"),
                    capacity: 4, atMs: Int64(index), in: db)
            }
            // 访问 rh-0 使其变新（LRU touch）。
            _ = try GRDBAIStudyJobStore.cachedResult(
                requestHash: "rh-0", atMs: 10, in: db)
            try GRDBAIStudyJobStore.storeCachedResult(
                Self.cachedResult(requestHash: "rh-new"),
                capacity: 4, atMs: 11, in: db)
        }
        let count = try await env.store.cachedResultCount()
        XCTAssertEqual(count, 4)
        // rh-1 最旧未访问 → 被逐出；rh-0 保留。
        let evicted = try await env.store.cachedResult(
            requestHash: "rh-1")
        let kept = try await env.store.cachedResult(
            requestHash: "rh-0")
        XCTAssertNil(evicted)
        XCTAssertNotNil(kept)
    }

    // MARK: - 环境

    private func makeEnvironment(
        plan: (@Sendable (UUID) -> [AIStudyRunner.PlannedBlock])? = nil
    ) async throws -> TestEnvironment {
        let location = temporaryDatabaseLocation()
        let pool = try DatabasePool(
            path: location.file.path, configuration: makeConfiguration())
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)
        let store = GRDBAIStudyJobStore(pool: pool)
        let documentID = UUID()
        try await pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
        }
        let job = Self.makeJob(documentID: documentID)
        return TestEnvironment(
            store: store, transport: ScriptedTransport(), job: job,
            documentID: documentID, pool: pool,
            directory: location.directory,
            plan: plan ?? { TestEnvironment.fixedPlan(jobID: $0) })
    }

    static func cachedResult(requestHash: String) -> AIStudyCachedResult {
        var request = AIStudyRequest(
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

    private func makeConfiguration() -> Configuration {
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
        return configuration
    }

    private struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AIStudyRunner-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite"))
    }

    private func waitUntil(
        _ predicate: () async throws -> Bool
    ) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("等待条件超时")
    }

    // MARK: - 构造助手

    static func makeJob(documentID: UUID) -> AIStudyJob {
        AIStudyJob(
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
    }

    static func resolverResult(
        for request: AIStudyRequest?
    ) -> AIStudyResolverResult {
        let blockKey = request?.blocks.first?.blockKey ?? "b0"
        return AIStudyResolverResult(
            outcome: ValidatedBlockOutcome(
                blockKey: blockKey,
                lexicalStatus: .resolved,
                translationStatus: .done,
                translation: "译文",
                envelopeRejection: nil,
                resolutions: [
                    AIStudyResolution(
                        tokenKey: "tok-0",
                        selected: AIStudySelection(
                            provider: "jmdict", entryID: 1,
                            senseID: 1, datasetVersion: "ds-1"),
                        confidence: 0.9, status: .aiResolved,
                        reasonCode: nil, origin: .ai)
                ],
                targetTokenCount: 1, aiResolvedCount: 1,
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

    static func insertDocument(id: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_documents(
                    id, title, format, created_at_ms, source_sha256,
                    canonical_text_hash, parser_version, availability)
                VALUES (?, '测试文档', 'paste', 1,
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        'hash1', 'parser-1', 'available')
                """,
            arguments: [DatabaseValueCodec.encode(id)])
    }
}

// MARK: - 测试环境

private extension AIStudyRunnerTests {
    /// 手写 transport：handler 注入 + call 计数 + 最大在途采样 +
    /// park/releaseAll 手动门。状态经 OSAllocatedUnfairLock 保护
    ///（async 上下文中禁直接用 NSLock）。
    final class ScriptedTransport: @unchecked Sendable {
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

        /// 驻留请求：登记 continuation，等 `releaseAll`。
        func park(_ request: AIStudyRequest) async -> Outcome {
            await withCheckedContinuation { continuation in
                state.withLock {
                    $0.pendingContinuations.append(continuation)
                }
            }
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

    struct TestEnvironment {
        let store: GRDBAIStudyJobStore
        let transport: ScriptedTransport
        let job: AIStudyJob
        let documentID: UUID
        let pool: DatabasePool
        /// 临时库目录（本文件测试不清理目录——与进程同寿的临时目录
        /// 由 OS 回收；保留 URL 仅为调试可读）。
        let directory: URL
        /// Job → 定稿块；默认 `fixedPlan`（rh-0/rh-1）。
        let plan: @Sendable (UUID) -> [AIStudyRunner.PlannedBlock]

        /// 默认 planner：jobID 下既有块按 requestHash 生成固定载荷
        ///（恢复 replan 同构——纯函数同输入同 hash）。
        func makeRunner(
            maxConcurrency: Int = 2,
            maxAttempts: Int = 4,
            baseDelayMs: Int64 = 10,
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
                    // 恢复 replan 语义：按 DB 中已登记的块键重建载荷；
                    // 新 Job 无块 → 由注入 plan 生成。
                    let existing = (try? await store.fetchBlocks(
                        jobID: job.id)) ?? []
                    if !existing.isEmpty {
                        return existing.map { block in
                            Self.makePlannedBlock(
                                block: block, jobID: job.id)
                        }
                    }
                    return plan(job.id)
                },
                sendRequest: { [transport] request in
                    try await transport.send(request)
                },
                nowMs: { Int64(Date().timeIntervalSince1970 * 1_000) },
                sleep: { _ in /* 测试时钟：退避即时唤醒 */ },
                jitter: jitter)
        }

        static func makePlannedBlock(
            block: AIStudyJobBlock, jobID: UUID
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

        static func fixedPlan(jobID: UUID)
            -> [AIStudyRunner.PlannedBlock]
        {
            (0..<2).map { index in
                let block = AIStudyJobBlock(
                    id: UUID(), jobID: jobID,
                    locatorJSON: "{\"block\":\(index)}",
                    sourceHash: "sh-\(index)",
                    subblockKey: "b\(index)",
                    candidateSetHash: "csh-\(index)",
                    requestHash: "rh-\(index)")
                return makePlannedBlock(block: block, jobID: jobID)
            }
        }

        /// Job 行由 runner.createJob 落库；块由 planner 在 drive 内
        /// 装配——这里只返回 ID（语义同「用户点了开始准备」）。
        func insertJobWithTwoBlocks() async throws -> UUID {
            job.id
        }

        /// 六块 plan（并发界用例）——改写 planner 需另建 runner，
        /// 这里直接在库内落块后由 replan 路径拾起。
        func insertJob(withBlockCount count: Int) async throws -> UUID {
            try await pool.write { db in
                try GRDBAIStudyJobStore.insertJob(job, in: db)
                for index in 0..<count {
                    let block = AIStudyJobBlock(
                        id: UUID(), jobID: job.id,
                        locatorJSON: "{\"block\":\(index)}",
                        sourceHash: "sh-\(index)",
                        subblockKey: "b\(index)",
                        candidateSetHash: "csh-\(index)",
                        requestHash: "rh-\(index)",
                        status: .readyForAI)
                    try GRDBAIStudyJobStore.insertBlock(block, in: db)
                }
            }
            return job.id
        }

        var secondJob: AIStudyJob {
            AIStudyJob(
                id: UUID(), documentID: documentID,
                scope: .fullDocument, inputFingerprint: "fp2",
                contentRevision: 2,
                providerSnapshot: job.providerSnapshot,
                model: job.model, pipelineVersion: job.pipelineVersion,
                promptVersion: job.promptVersion,
                policyVersion: job.policyVersion,
                createdAtMs: 2, updatedAtMs: 2)
        }

        func insertSecondJob() async throws -> UUID {
            // 复用 rh-0/rh-1 两块（命中第一 Job 的缓存）。
            let job = secondJob
            try await pool.write { db in
                try GRDBAIStudyJobStore.insertJob(job, in: db)
                for index in 0..<2 {
                    let block = AIStudyJobBlock(
                        id: UUID(), jobID: job.id,
                        locatorJSON: "{\"block\":\(index)}",
                        sourceHash: "sh-\(index)",
                        subblockKey: "b\(index)",
                        candidateSetHash: "csh-\(index)",
                        requestHash: "rh-\(index)",
                        status: .readyForAI)
                    try GRDBAIStudyJobStore.insertBlock(block, in: db)
                }
            }
            return job.id
        }
    }
}

private extension AIStudyJob {
    func with(id: UUID) -> AIStudyJob {
        var copy = self
        copy.id = id
        return copy
    }
}
