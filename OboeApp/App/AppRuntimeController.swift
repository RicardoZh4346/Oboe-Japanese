import Observation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture
import SwiftUI

/// 运行期控制器（技术文档 §10）：只负责 start、phase、generation、
/// 数据库替换编排、ready 发布与 scene 可见状态。具体职责收敛到
/// `App/Runtime/` 下的 Database/Backup/Capture/Enrichment/Appearance
/// runtime 与 `AppFeatureContainerFactory`——这里不直接实现。
///
/// Feature 服务先在 `AppFeatureContainerFactory.makeServices` 内全部
/// 构造完，再随 `phase = .ready(container)` 一次性非可选发布——UI
/// 不会看到半初始化状态。
@MainActor
@Observable
final class AppRuntimeController {
    private let baseURL: URL
    private let databaseRuntime: DatabaseRuntime
    private let backupRuntime: BackupRuntime
    private let captureRuntime = CaptureRuntime()
    private let enrichmentRuntime = EnrichmentRuntime()
    /// S11 统一备份导入（AirDrop/外部 URL/Settings 共用）：冷启动
    /// URL 暂存、串行校验、preview/确认/恢复由根视图驱动。
    let backupImport = BackupImportCoordinator()
    private let appearanceRuntime = AppearanceRuntime()
    private let bootstrap = AppBootstrapEnvironment()
    private var didStart = false

    /// 数据库绑定服务就绪后一次性发布；数据库替换后旧容器整体作废，
    /// 新容器随递增的 `generation` 原子替换。
    private(set) var phase: AppRuntimePhase = .launching
    private(set) var isDatabaseOperationInProgress = false
    private(set) var databaseGeneration = 0
    private(set) var appearancePreference = AppAppearance.system
    private(set) var jlptEnrichmentStatus: JLPTEnrichmentStatus = .idle

    /// Inbox item imported with `continueInApp`, offered on the landing tab —
    /// tapped or dismissed only by the user, never auto-navigating.
    private(set) var pendingContinueItemID: UUID?

    /// Share files still pending at a restore boundary. Recorded so old
    /// files never silently replay into the fresh database — the Inbox
    /// notice lets the user import them explicitly.
    private(set) var sharedCapturesAwaitingImport: Int?

    /// Shared invalidation token for every `AdaptiveCardService` rebuild —
    /// bumping it after a database replacement guarantees snapshots read from
    /// the old file can never reach the new view tree (design §4.3).
    private let adaptiveInvalidationCenter = AdaptiveInvalidationCenter()

    /// controller 自用的运行期句柄：与 `phase.ready` 容器同批构造、
    /// 同批发布，专供替换安全与后台调度使用，不暴露给 Feature。
    private var runtimeServices: RuntimeServices?

    /// DEBUG 种子窗口：已构造完成但尚未发布为 `.ready` 的容器。
    /// 种子（多为多步写库）必须在首个视图 `load()` 之前跑完，
    /// 否则视图会对中间态取快照且不刷新。
    private var stagedContainer: AppFeatureContainer?
    private var stagedGeneration = 0

    /// DEBUG 测试 seam 访问器：seed 扩展经此触达当前容器的服务。
    /// 与对外容器语义一致——服务要么存在，要么整个容器尚未发布。
    var currentContainer: AppFeatureContainer? {
        if case .ready(let container) = phase { return container }
        return stagedContainer
    }

    var studySessionService: StudySessionService? {
        currentContainer?.today.studyService
    }

    var adaptivePreferencesService: AdaptivePreferencesService? {
        currentContainer?.today.adaptivePreferencesService
    }

    var aiConfigurationService: AIConfigurationService? {
        currentContainer?.settings.aiConfigurationService
    }

    /// 根组合以外允许触达的运行期操作集合——Feature 只拿到这组具名
    /// 闭包，不再持有整个 controller。
    var operations: AppRuntimeOperations {
        AppRuntimeOperations(
            drainSharedCaptures: { await self.drainSharedCaptures() },
            clearPendingContinueItem: { await self.clearPendingContinueItem() },
            importAwaitingSharedCaptures: { await self.importAwaitingSharedCaptures() },
            scheduleJLPTEnrichment: { self.scheduleJLPTEnrichment() },
            applyPreparedRestoration: { try await self.applyPreparedRestoration($0) },
            localSnapshots: { try await self.localSnapshots() },
            createLocalSnapshot: { try await self.createLocalSnapshot() },
            restoreLocalSnapshot: { try await self.restoreLocalSnapshot($0) },
            pendingSharedCaptureCount: { self.pendingSharedCaptureCount() },
            setAppearancePreference: { try await self.setAppearancePreference($0) },
            currentAppearancePreference: { self.appearancePreference },
            submitBackupFile: { url in
                Task { @MainActor in self.backupImport.submit(url) }
            }
        )
    }

    init() {
        let baseURL = AppBootstrapEnvironment.applicationDataURL()
        self.baseURL = baseURL
        databaseRuntime = DatabaseRuntime(baseURL: baseURL)
        backupRuntime = BackupRuntime(baseURL: baseURL)
        enrichmentRuntime.statusHandler = { [weak self] status in
            self?.jlptEnrichmentStatus = status
        }
    }

    func start() async {
        guard !didStart else {
            return
        }
        didStart = true

        do {
            #if DEBUG
            // T16 UI-test seam: stage a v0.4-shaped (schema v12) file so the
            // real open path exercises the v13 migration + pre-migration
            // snapshot before launch-time enrichment backfills NULL fields.
            try stageLegacySchemaV12DatabaseIfRequested()
            #endif
            // 附件 swap journal 收敛失败是显式错误状态（§8.4）：无法证明
            // 附件目录一致时不允许吞错继续写入。
            do {
                _ = try backupRuntime.recoverInterruptedSwap()
            } catch {
                phase = .failed(
                    message: "无法修复上次中断的附件恢复：\(error.localizedDescription)"
                )
                return
            }
            let database = try await databaseRuntime.open()
            #if DEBUG
            // 先装配不发布：UI 测试种子（waiting/complete 等多步写库）
            // 必须跑在首个视图 `load()` 之前，否则视图会快照中间态。
            guard stageServices(database: database) else {
                phase = .failed(message: "无法载入内置 JLPT 词库。")
                return
            }
            #else
            publishServices(database: database)
            #endif
            #if DEBUG
            // UI-test seam: fabricate the post-restore pending-import state so
            // the awaiting-import notice path can be exercised end to end.
            // Must run before the first await after publishServices — a
            // queued drain task must never see the flag still unset.
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_AWAITING_IMPORT"] != nil {
                refreshAwaitingSharedCaptures()
            }
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_ADAPTIVE_SEED"] != nil {
                try? await seedAdaptiveUITestData(database: database)
            }
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_LISTENING_SEED"] != nil {
                try? await seedListeningUITestData(database: database)
            }
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_SIBLING_SEED"] != nil {
                try? await seedSiblingUITestData(database: database)
            }
            // T25 seam: builtin-JLPT leech fixture for the weak list.
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_JLPT_WEAK_SEED"] != nil {
                try? await seedJLPTWeakUITestData(database: database)
            }
            // v0.5.5 seam: five-state Today fixture (empty deck / ready /
            // waiting / complete —「无牌组」由空库直接覆盖).
            if let todaySeed = ProcessInfo.processInfo.environment["OBOE_UI_TEST_TODAY_SEED"] {
                try? await seedTodayUITestData(database: database, mode: todaySeed)
            }
            // T07 UI-test seam: persist an enabled configuration + stub
            // credential so repair analysis runs without typing through
            // Settings (the credential lives only in the UITest store).
            // 只预置凭据：供「获取模型→选择→保存并测试」的 UI 测试跳过
            // SecureField 输入，路径与真实 Key 完全一致。重存当前持久化
            // 草稿本身——测试内 terminate 后用同一数据库重启时，内存态
            // UITestAICredentialStore 是新的，此分支只补齐 Key，不覆盖
            // 已保存的启用状态与模型选择。
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_AI_KEY"] != nil,
               let aiConfigurationService,
               let persisted = try? await aiConfigurationService.load(
                   defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
               ) {
                _ = try? await aiConfigurationService.save(
                    AIConfigurationDraft(configuration: persisted.configuration),
                    apiKey: "ui-test-key",
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
            }
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_AI_ENABLED"] != nil,
               let aiConfigurationService {
                var draft = AIConfigurationDraft.deepSeekDefault
                draft.isEnabled = true
                draft.modelID = "ui-test-model"
                _ = try? await aiConfigurationService.save(
                    draft,
                    apiKey: "ui-test-key",
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
            }
            // v0.5.5 seam: typed-recall 偏好覆盖（PREF=1/on 显式开、
            // =0/off 显式关）。必须在所有数据种子之后——种子可能先物化
            // app_settings 行，覆盖再走真实 service 的 UPDATE。
            await applyAdaptivePreferenceUITestOverrides()
            // 种子全部落地后才切 ready——首个界面加载看到的就是
            // 种子终态。
            commitStagedServices()
            #endif
            try await reloadAppearancePreference()
            #if DEBUG
            // UI-test seam: force dark appearance for layout verification
            // without touching the persisted preference.
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_APPEARANCE_DARK"] != nil {
                appearancePreference = .dark
            }
            #endif
            // T06/T07 resume sweep: analyzing drafts revert to retryable and
            // vanished targets become blocked — never auto-requests anything.
            try? await runtimeServices?.aiRepairService.restoreDraftsForLaunch()
            // S09：上个运行期遗留的 active 专项会话标 interrupted——
            // 本版不承诺跨运行期续同一 UI（§7.2）。
            try? await runtimeServices?.customStudyRepository
                .interruptActiveSessions(at: Date())
            await drainSharedCaptures()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            phase = .failed(message: "无法打开本地数据库：\(error.localizedDescription)")
        }
    }

    /// Shared-queue consumption is triggered by hints (cold start, returning
    /// to foreground, entering the Inbox) — the pending directory is the
    /// source of truth, and the coordinator coalesces duplicate drains.
    /// While `sharedCapturesAwaitingImport` is set, files left at a restore
    /// boundary wait for an explicit user choice instead of auto-replaying.
    func drainSharedCaptures() async {
        guard !isDatabaseOperationInProgress,
              sharedCapturesAwaitingImport == nil,
              let coordinator = runtimeServices?.captureImportCoordinator else { return }
        if let itemID = await captureRuntime.drainPendingCaptures(using: coordinator) {
            pendingContinueItemID = itemID
        }
    }

    func clearPendingContinueItem() {
        pendingContinueItemID = nil
    }

    /// The user chose to import the files recorded at the restore boundary.
    func importAwaitingSharedCaptures() async {
        sharedCapturesAwaitingImport = nil
        await drainSharedCaptures()
    }

    /// T12 幂等回填调度（设计 §7.4）：启动、进入词库、备份恢复后触发，
    /// 全部合并到同一次后台运行。失败不阻塞主界面——状态经
    /// `jlptEnrichmentStatus` 暴露给词库页做可重试提示。
    func scheduleJLPTEnrichment() {
        enrichmentRuntime.schedule(
            service: runtimeServices?.jlptEnrichmentService,
            currentDatabaseGeneration: databaseGeneration
        )
    }

    private func sweepOrphanedInboxImages() async {
        guard let attachmentReferences = runtimeServices?.attachmentReferenceRepository,
              let inboxImageStore = runtimeServices?.inboxImageStore else { return }
        await captureRuntime.sweepOrphanedInboxImages(
            attachmentReferences: attachmentReferences,
            inboxImageStore: inboxImageStore
        )
    }

    private func refreshAwaitingSharedCaptures() {
        let count = captureRuntime.pendingFileCount(
            using: runtimeServices?.captureQueueStore
        )
        sharedCapturesAwaitingImport = (count ?? 0) > 0 ? count : nil
    }

    /// Files still waiting in the shared queue. Nil when the App Group
    /// container is unavailable — callers must not misreport that as zero.
    func pendingSharedCaptureCount() -> Int? {
        captureRuntime.pendingFileCount(using: runtimeServices?.captureQueueStore)
    }

    func applyPreparedRestoration(_ preparation: PreparedRestoration) async throws {
        guard !isDatabaseOperationInProgress else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        isDatabaseOperationInProgress = true
        defer { isDatabaseOperationInProgress = false }
        await suspendBeforeDatabaseReplacement()
        var installedAttachmentsJournal: AttachmentRestoreJournal?
        do {
            // v7 提交序列（设计 §11.3）：quiesce → swap 附件 → 换库 → 收尾。
            // 附件先于库安装，库替换失败时按 journal 回滚目录，保证两侧一致。
            if let stagedURL = preparation.stagedAttachmentsDirectoryURL {
                installedAttachmentsJournal = try backupRuntime.installStagedAttachments(
                    from: stagedURL,
                    targetURL: AppBootstrapEnvironment.inboxImagesDirectoryURL(
                        baseURL: baseURL
                    )
                )
            }
            let database = try await replaceDatabase(with: preparation.temporaryDatabaseURL)
            publishServices(database: database)
            refreshAwaitingSharedCaptures()
            try await reloadAppearancePreference()
            if let journal = installedAttachmentsJournal {
                try? backupRuntime.completeSwap(journal: journal)
            }
            try? await runtimeServices?.aiRepairService.restoreDraftsForLaunch()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            if let journal = installedAttachmentsJournal {
                backupRuntime.rollbackSwap(journal: journal)
            }
            if let restoredCurrent = await databaseRuntime.currentDatabase() {
                publishServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
            } else {
                await runtimeServices?.captureImportCoordinator.resume()
            }
            throw error
        }
    }

    /// S11：preview 确认/取消/应用失败后的 staging 清理——与 Settings
    /// 旧 `discardPreparedRestoration` 同一语义。
    private func discardPreparedRestoration(
        _ preparation: PreparedRestoration
    ) async throws {
        try await currentContainer?
            .settings.restorationPreparer.discard(preparation)
    }

    func localSnapshots() async throws -> [DatabaseSnapshot] {
        try await databaseRuntime.snapshots()
    }

    @discardableResult
    func createLocalSnapshot() async throws -> DatabaseSnapshot? {
        try await databaseRuntime.createDailySnapshotIfNeeded(hasChanges: true)
    }

    func restoreLocalSnapshot(_ snapshot: DatabaseSnapshot) async throws {
        guard !isDatabaseOperationInProgress else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        isDatabaseOperationInProgress = true
        defer { isDatabaseOperationInProgress = false }
        await suspendBeforeDatabaseReplacement()
        do {
            let database = try await replaceDatabase(with: snapshot.url)
            publishServices(database: database)
            refreshAwaitingSharedCaptures()
            try await reloadAppearancePreference()
            try? await runtimeServices?.aiRepairService.restoreDraftsForLaunch()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            if let restoredCurrent = await databaseRuntime.currentDatabase() {
                publishServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
            } else {
                await runtimeServices?.captureImportCoordinator.resume()
            }
            throw error
        }
    }

    func createDailySnapshotIfNeeded() async {
        guard !isDatabaseOperationInProgress else { return }
        _ = try? await createLocalSnapshot()
    }

    func setAppearancePreference(_ appearance: AppAppearance) async throws {
        guard let appearancePreferencesService =
                runtimeServices?.appearancePreferencesService else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        appearancePreference = try await appearanceRuntime.set(
            appearance,
            using: appearancePreferencesService
        )
    }

    private func reloadAppearancePreference() async throws {
        guard let appearancePreferencesService =
                runtimeServices?.appearancePreferencesService else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        appearancePreference = try await appearanceRuntime.load(
            using: appearancePreferencesService
        )
    }

    /// Before the database is swapped underneath running work: bump the
    /// generation so the view tree tears down (cancels editor/processing/AI
    /// tasks bound to the previous services), then pause the shared-queue
    /// importer and wait out its in-flight drain — pending files survive on
    /// disk and the coordinator rebuilt by `publishServices` resumes them.
    private func suspendBeforeDatabaseReplacement() async {
        databaseGeneration &+= 1
        // Epoch bump before the swap: any adaptive snapshot still in flight
        // from the outgoing database is tagged with a dead generation.
        await runtimeServices?.adaptiveCardService.invalidate()
        // Enrichment writes go through the outgoing pool — cancel and wait
        // so no batch can land on a closed database mid-swap.
        await enrichmentRuntime.cancelAndWait()
        if let coordinator = runtimeServices?.captureImportCoordinator {
            await captureRuntime.pauseAndWait(using: coordinator)
        }
        await Task.yield()
    }

    private func replaceDatabase(with sourceURL: URL) async throws -> OboeDatabase {
        try await databaseRuntime.replaceDatabase(with: sourceURL) { database in
            let service = AppFeatureContainerFactory.makeStudySessionService(
                database: database
            )
            _ = try await service.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
        }
    }

    /// 构造并暂存服务但不发布：返回 false 即构建失败（内置 JLPT 词库
    /// 缺失）。`stagedContainer` 对 DEBUG 种子访问器可见，对视图不可见。
    @discardableResult
    private func stageServices(database: OboeDatabase) -> Bool {
        let generation = databaseGeneration &+ 1
        guard let built = AppFeatureContainerFactory.makeServices(
            database: database,
            generation: generation,
            baseURL: baseURL,
            bootstrap: bootstrap,
            adaptiveInvalidationCenter: adaptiveInvalidationCenter
        ) else {
            return false
        }
        runtimeServices = built.runtime
        stagedContainer = built.container
        stagedGeneration = generation
        return true
    }

    /// 将暂存容器发布为 `.ready`。仅在 `stageServices` 成功后调用。
    private func commitStagedServices() {
        guard let stagedContainer else { return }
        databaseGeneration = stagedGeneration
        enrichmentRuntime.servicePublished(generation: stagedGeneration)
        phase = .ready(stagedContainer)
        backupImport.configure(
            preparer: stagedContainer.settings.restorationPreparer,
            apply: { [weak self] preparation in
                guard let self else { return }
                try await self.applyPreparedRestoration(preparation)
            },
            discard: { [weak self] preparation in
                guard let self else { return }
                try await self.discardPreparedRestoration(preparation)
            }
        )
        self.stagedContainer = nil
    }

    /// 服务全部构造成功后一次性发布容器。世代先取号再发布：构建失败
    /// 进入 `.failed`，世代保持原值（suspend 阶段已递增过，旧树已死）。
    private func publishServices(database: OboeDatabase) {
        guard stageServices(database: database) else {
            phase = .failed(message: "无法载入内置 JLPT 词库。")
            return
        }
        commitStagedServices()
    }
}
