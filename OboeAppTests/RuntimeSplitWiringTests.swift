import Foundation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture
import Testing
@testable import Oboe

/// S01 运行期拆分契约测试：controller 只做编排，具体职责在
/// `App/Runtime/` 各 runtime。钉住：start 发布、服务构建失败、
/// 恢复快照成功/回退、enrichment 取消等待、capture drain/计数、
/// journal 恢复失败的显式错误状态。
/// 套件内共享进程级环境变量（`OBOE_UI_TEST_*`）——并行执行时
/// setenv/unsetenv 会串台，序列化是唯一正确语义。
@MainActor
@Suite(.serialized)
struct RuntimeSplitWiringTests {

    // MARK: - 环境脚手架

    private struct UITestEnvironment {
        let databaseID: UUID
        let baseURL: URL
        let queueURL: URL
        let imageURL: URL

        init() {
            databaseID = UUID()
            baseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Oboe-UITests", isDirectory: true)
                .appendingPathComponent(databaseID.uuidString, isDirectory: true)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("oboe-runtime-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
            queueURL = root.appendingPathComponent("CaptureQueue", isDirectory: true)
            imageURL = root.appendingPathComponent("InboxImages", isDirectory: true)
            setenv("OBOE_UI_TEST_DATABASE_ID", databaseID.uuidString, 1)
            setenv("OBOE_UI_TEST_CAPTURE_QUEUE", queueURL.path, 1)
            setenv("OBOE_UI_TEST_IMAGE_STORE", imageURL.path, 1)
            setenv("OBOE_UI_TEST_JLPT_ENRICHMENT_DISABLED", "1", 1)
        }

        func tearDown() {
            unsetenv("OBOE_UI_TEST_DATABASE_ID")
            unsetenv("OBOE_UI_TEST_CAPTURE_QUEUE")
            unsetenv("OBOE_UI_TEST_IMAGE_STORE")
            unsetenv("OBOE_UI_TEST_JLPT_ENRICHMENT_DISABLED")
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(
                at: queueURL.deletingLastPathComponent()
            )
        }
    }

    private func makeStartedController(
        _ env: UITestEnvironment
    ) async throws -> AppRuntimeController {
        let controller = AppRuntimeController()
        await controller.start()
        return controller
    }

    // MARK: - start / publish

    @Test
    func startPublishesReadyContainer() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let controller = try await makeStartedController(env)
        guard case .ready = controller.phase else {
            Issue.record("expected .ready, got \(controller.phase)")
            return
        }
        #expect(controller.databaseGeneration == 1)
        #expect(controller.studySessionService != nil)
        #expect(controller.currentContainer != nil)
    }

    @Test
    func containerFactoryFailsWhenLibraryMissing() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: env.baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: env.baseURL.appendingPathComponent(
                "Snapshots", isDirectory: true
            )
        )
        let database = try await lifecycle.open()
        let built = AppFeatureContainerFactory.makeServices(
            database: database,
            generation: 1,
            baseURL: env.baseURL,
            bootstrap: AppBootstrapEnvironment(),
            adaptiveInvalidationCenter: AdaptiveInvalidationCenter(),
            jlptLibraryURLOverride: URL(fileURLWithPath: "/nonexistent/jlpt.sqlite")
        )
        #expect(built == nil)
    }

    @Test
    func containerFactoryBuildsCompleteServices() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: env.baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: env.baseURL.appendingPathComponent(
                "Snapshots", isDirectory: true
            )
        )
        let database = try await lifecycle.open()
        let built = AppFeatureContainerFactory.makeServices(
            database: database,
            generation: 1,
            baseURL: env.baseURL,
            bootstrap: AppBootstrapEnvironment(),
            adaptiveInvalidationCenter: AdaptiveInvalidationCenter()
        )
        #expect(built != nil)
        #expect(built?.container.generation == 1)
        #expect(built?.runtime.jlptEnrichmentService != nil)
    }

    // MARK: - 快照恢复

    @Test
    func snapshotRestoreRepublishesWithNewGeneration() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let controller = try await makeStartedController(env)
        guard case .ready = controller.phase else {
            Issue.record("expected .ready before restore")
            return
        }
        let generationBefore = controller.databaseGeneration

        let snapshot = try #require(
            try await controller.operations.createLocalSnapshot()
        )
        try await controller.operations.restoreLocalSnapshot(snapshot)

        guard case .ready = controller.phase else {
            Issue.record("expected .ready after restore, got \(controller.phase)")
            return
        }
        #expect(controller.databaseGeneration > generationBefore)
    }

    @Test
    func failedSnapshotRestoreFallsBackToCurrentContainer() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let controller = try await makeStartedController(env)
        guard case .ready(let original) = controller.phase else {
            Issue.record("expected .ready before restore")
            return
        }

        let garbageURL = env.baseURL.appendingPathComponent("garbage.sqlite")
        try "not a database".write(to: garbageURL, atomically: true, encoding: .utf8)
        let bogus = DatabaseSnapshot(url: garbageURL, reason: .restoration, createdAt: Date())

        do {
            try await controller.operations.restoreLocalSnapshot(bogus)
            Issue.record("expected restoreLocalSnapshot to throw")
        } catch {
            // 预期抛出；回退路径应重新发布仍打开的当前库。
        }

        guard case .ready(let republished) = controller.phase else {
            Issue.record("expected .ready after failed restore, got \(controller.phase)")
            return
        }
        // 回退重新发布：generation 递增，容器是新对象但服务完整。
        #expect(republished.generation > original.generation)
        #expect(controller.studySessionService != nil)
    }

    // MARK: - Enrichment runtime

    private struct StubEnrichmentSource: JLPTEnrichmentSource {
        let offersEnrichmentData = true
        func enrichmentEntries(
            for sourceRefs: [String]
        ) async throws -> [String: BuiltinJLPTEnrichmentEntry] {
            try await Task.sleep(for: .milliseconds(50))
            return [:]
        }
    }

    private struct StubEnrichmentStore: JLPTEnrichmentStore {
        let candidateCount: Int
        func enrichmentCandidates() async throws -> [JLPTEnrichmentCandidate] {
            (0..<candidateCount).map { index in
                JLPTEnrichmentCandidate(
                    noteID: UUID(),
                    sourceRef: "ref-\(index)",
                    reading: nil,
                    needsPitchAccent: false
                )
            }
        }
        func applyEnrichment(
            _ writes: [JLPTEnrichmentWrite]
        ) async throws -> JLPTEnrichmentBatchResult {
            try await Task.sleep(for: .milliseconds(20))
            return JLPTEnrichmentBatchResult()
        }
    }

    @Test
    func enrichmentRejectsStaleGenerationAndRunsForCurrent() async throws {
        let runtime = EnrichmentRuntime()
        var statuses: [JLPTEnrichmentStatus] = []
        runtime.statusHandler = { statuses.append($0) }
        let service = JLPTLibraryEnrichmentService(
            source: StubEnrichmentSource(),
            store: StubEnrichmentStore(candidateCount: 10)
        )

        // 世代不一致：拒绝调度（服务仍绑着旧库）。
        runtime.servicePublished(generation: 1)
        runtime.schedule(service: service, currentDatabaseGeneration: 2)
        #expect(statuses.isEmpty)

        // 世代一致：进入 running。
        runtime.schedule(service: service, currentDatabaseGeneration: 1)
        #expect(statuses == [.running(processed: 0, total: 0)])
        await runtime.cancelAndWait()
    }

    @Test
    func enrichmentCancelAndWaitActuallyStopsTask() async throws {
        let runtime = EnrichmentRuntime()
        var statuses: [JLPTEnrichmentStatus] = []
        runtime.statusHandler = { statuses.append($0) }
        // 大批量候选保证 cancel 命中在途工作。
        let service = JLPTLibraryEnrichmentService(
            source: StubEnrichmentSource(),
            store: StubEnrichmentStore(candidateCount: 100_000),
            batchSize: 10
        )
        runtime.servicePublished(generation: 1)
        runtime.schedule(service: service, currentDatabaseGeneration: 1)
        #expect(statuses == [.running(processed: 0, total: 0)])

        await runtime.cancelAndWait()
        #expect(statuses.last == .idle)

        // 取消后允许再次调度（任务真正退出，不是只翻转布尔值）。
        runtime.schedule(service: service, currentDatabaseGeneration: 1)
        #expect(statuses.last == .running(processed: 0, total: 0))
        await runtime.cancelAndWait()
    }

    // MARK: - Capture runtime

    @Test
    func captureDrainImportsAndReportsContinueItem() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: env.baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: env.baseURL.appendingPathComponent(
                "Snapshots", isDirectory: true
            )
        )
        let database = try await lifecycle.open()
        let inbox = InboxService(repository: GRDBInboxRepository(database: database))
        let store = AppGroupCaptureStore(queueDirectoryURL: env.queueURL)
        let coordinator = CaptureImportCoordinator(inboxService: inbox, store: store)
        let runtime = CaptureRuntime()

        _ = try store.publish(CaptureEnvelope(
            captureID: UUID(), text: "普通保存", createdAt: Date()
        ))
        _ = try store.publish(CaptureEnvelope(
            captureID: UUID(), text: "继续在应用内处理",
            createdAt: Date(), requestedAction: .continueInApp
        ))
        #expect(runtime.pendingFileCount(using: store) == 2)

        let continueID = await runtime.drainPendingCaptures(using: coordinator)
        #expect(continueID != nil)
        #expect(runtime.pendingFileCount(using: store) == 0)
    }

    @Test
    func capturePauseAndWaitBlocksDrain() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: env.baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: env.baseURL.appendingPathComponent(
                "Snapshots", isDirectory: true
            )
        )
        let database = try await lifecycle.open()
        let inbox = InboxService(repository: GRDBInboxRepository(database: database))
        let store = AppGroupCaptureStore(queueDirectoryURL: env.queueURL)
        let coordinator = CaptureImportCoordinator(inboxService: inbox, store: store)
        let runtime = CaptureRuntime()

        _ = try store.publish(CaptureEnvelope(
            captureID: UUID(), text: "暂停时不应被消费", createdAt: Date()
        ))
        await runtime.pauseAndWait(using: coordinator)
        let itemID = await runtime.drainPendingCaptures(using: coordinator)
        #expect(itemID == nil)
        // 文件仍在磁盘——新 coordinator 恢复后可继续导入。
        #expect(runtime.pendingFileCount(using: store) == 1)
    }

    // MARK: - Backup runtime / journal 错误状态

    @Test
    func corruptSwapJournalThrowsExplicitly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oboe-journal-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("RestoreJournals", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "corrupt{".write(
            to: root.appendingPathComponent("RestoreJournals/attachment-swap.json"),
            atomically: true, encoding: .utf8
        )
        let runtime = BackupRuntime(baseURL: root)
        #expect(throws: (any Error).self) {
            try runtime.recoverInterruptedSwap()
        }
    }

    @Test
    func startFailsExplicitlyOnCorruptSwapJournal() async throws {
        let env = UITestEnvironment()
        defer { env.tearDown() }
        try FileManager.default.createDirectory(
            at: env.baseURL.appendingPathComponent("RestoreJournals", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "corrupt{".write(
            to: env.baseURL.appendingPathComponent("RestoreJournals/attachment-swap.json"),
            atomically: true, encoding: .utf8
        )
        let controller = AppRuntimeController()
        await controller.start()
        guard case .failed(let message) = controller.phase else {
            Issue.record("expected .failed, got \(controller.phase)")
            return
        }
        #expect(message.contains("附件"))
    }
}
