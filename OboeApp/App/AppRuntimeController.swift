import Observation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture
import OSLog
import SwiftUI

/// 运行期控制器：只负责启动、数据库替换和可观察运行态。Feature 服务
/// 先在 `makeServices` 内全部构造完，再随 `phase = .ready(container)`
/// 一次性非可选发布——UI 不会看到半初始化状态。
@MainActor
@Observable
final class AppRuntimeController {
    private let baseURL: URL
    private let databaseLifecycle: OboeDatabaseLifecycle
    /// v7 附件交换日志：恢复提交窗口期崩溃时据此把 InboxImages 收敛回
    /// 一致状态（设计 §11.3 阶段 9）。
    private let attachmentJournalStore: AttachmentRestoreJournalStore
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
    private var jlptEnrichmentTask: Task<Void, Never>?
    /// `makeServices` 完成时的 `databaseGeneration`——恢复流程中
    /// 服务已换新但操作标记未复位时仍允许调度，世代不一致（服务还
    /// 绑着旧库）则拒绝。
    private var jlptEnrichmentServiceGeneration = -1

    /// controller 自用的运行期句柄：与 `phase.ready` 容器同批构造、
    /// 同批发布，专供替换安全与后台调度使用，不暴露给 Feature。
    private var runtimeServices: RuntimeServices?

    /// DEBUG 种子窗口：已构造完成但尚未发布为 `.ready` 的容器。
    /// 种子（多为多步写库）必须在首个视图 `load()` 之前跑完，
    /// 否则视图会对中间态取快照且不刷新。
    private var stagedContainer: AppFeatureContainer?
    private var stagedGeneration = 0

    private struct RuntimeServices {
        let adaptiveCardService: AdaptiveCardService
        let aiRepairService: AIRepairService
        let appearancePreferencesService: AppearancePreferencesService
        let captureImportCoordinator: CaptureImportCoordinator
        let captureQueueStore: (any CaptureQueueStoring)?
        let inboxService: InboxService
        let inboxImageStore: InboxImageStore
        let jlptEnrichmentService: JLPTLibraryEnrichmentService
    }

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
            currentAppearancePreference: { self.appearancePreference }
        )
    }

    init() {
        let baseURL = AppBootstrapEnvironment.applicationDataURL()
        self.baseURL = baseURL
        databaseLifecycle = OboeDatabaseLifecycle(
            databaseURL: baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: baseURL.appendingPathComponent("Snapshots", isDirectory: true)
        )
        attachmentJournalStore = AttachmentRestoreJournalStore(
            fileURL: baseURL.appendingPathComponent(
                "RestoreJournals/attachment-swap.json",
                isDirectory: false
            )
        )
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
            recoverInterruptedAttachmentSwap()
            let database = try await databaseLifecycle.open()
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
              sharedCapturesAwaitingImport == nil else { return }
        guard let report = try? await runtimeServices?.captureImportCoordinator
            .drainPendingCaptures()
        else { return }
        if let latest = report.imported.last(where: {
            $0.requestedAction == .continueInApp
        }) {
            pendingContinueItemID = latest.itemID
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
    /// `jlptEnrichmentStatus` 暴露给词库页做可重试提示；日志只记计数
    /// 与错误类别，不含用户正文。
    func scheduleJLPTEnrichment() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_JLPT_ENRICHMENT_DISABLED"] != nil {
            return
        }
        #endif
        guard jlptEnrichmentTask == nil,
              jlptEnrichmentServiceGeneration == databaseGeneration,
              let service = runtimeServices?.jlptEnrichmentService else { return }
        jlptEnrichmentStatus = .running(processed: 0, total: 0)
        jlptEnrichmentTask = Task {
            defer { jlptEnrichmentTask = nil }
            do {
                let report = try await service.enrich { progress in
                    await MainActor.run { [weak self] in
                        self?.jlptEnrichmentStatus = .running(
                            processed: progress.processed,
                            total: progress.total
                        )
                    }
                }
                jlptEnrichmentStatus = .idle
                Self.enrichmentLogger.log(
                    "JLPT enrichment finished: candidates=\(report.candidateCount, privacy: .public) pitch=\(report.pitchFilled, privacy: .public) examples=\(report.examplesFilled, privacy: .public) missing=\(report.missingEntries, privacy: .public) skippedInconsistent=\(report.pitchSkippedInconsistent, privacy: .public)"
                )
            } catch is CancellationError {
                jlptEnrichmentStatus = .idle
            } catch {
                jlptEnrichmentStatus = .failed(message: error.localizedDescription)
                Self.enrichmentLogger.error(
                    "JLPT enrichment failed: \(String(describing: type(of: error)), privacy: .public)"
                )
            }
        }
    }

    private static let enrichmentLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oboe.app",
        category: "JLPTEnrichment"
    )

    /// Reclaims attachment files no Inbox row references — abandoned picks,
    /// items removed before the cleanup hook existed, restore-orphaned
    /// resources. A creation-time buffer protects files still being attached.
    private func sweepOrphanedInboxImages() async {
        guard let inboxImageStore = runtimeServices?.inboxImageStore,
              let inboxService = runtimeServices?.inboxService else { return }
        guard let referenced = try? await inboxService.fetchImageReferences(),
              let orphans = try? inboxImageStore.orphanedResourceIDs(
                  keeping: referenced,
                  olderThan: 60
              ) else { return }
        for resourceID in orphans {
            try? inboxImageStore.delete(resourceID)
        }
    }

    private func refreshAwaitingSharedCaptures() {
        let count = try? runtimeServices?.captureQueueStore?.pendingFileURLs().count
        sharedCapturesAwaitingImport = (count ?? 0) > 0 ? count : nil
    }

    /// Files still waiting in the shared queue. Nil when the App Group
    /// container is unavailable — callers must not misreport that as zero.
    func pendingSharedCaptureCount() -> Int? {
        try? runtimeServices?.captureQueueStore?.pendingFileURLs().count
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
                installedAttachmentsJournal = try installStagedAttachments(
                    from: stagedURL
                )
            }
            let database = try await replaceDatabase(with: preparation.temporaryDatabaseURL)
            publishServices(database: database)
            refreshAwaitingSharedCaptures()
            try await reloadAppearancePreference()
            if let journal = installedAttachmentsJournal {
                try? AttachmentDirectorySwap.completeSwap(
                    journal: journal,
                    journalStore: attachmentJournalStore
                )
            }
            try? await runtimeServices?.aiRepairService.restoreDraftsForLaunch()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            if let journal = installedAttachmentsJournal {
                rollbackAttachmentSwap(journal: journal)
            }
            if let restoredCurrent = await databaseLifecycle.currentDatabase() {
                publishServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
            } else {
                await runtimeServices?.captureImportCoordinator.resume()
            }
            throw error
        }
    }

    /// 附件目录原子替换：现有目录移到 aside，staged 目录 rename 就位，
    /// 每个阶段都写 journal——进程在窗口期被杀由下次启动的
    /// `recoverInterruptedAttachmentSwap` 收敛。
    private func installStagedAttachments(
        from stagedURL: URL
    ) throws -> AttachmentRestoreJournal {
        let targetURL = AppBootstrapEnvironment.inboxImagesDirectoryURL(
            baseURL: baseURL
        )
        let asideURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".rollback-\(targetURL.lastPathComponent)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        return try AttachmentDirectorySwap.installStagedDirectory(
            stagedURL: stagedURL,
            at: targetURL,
            asideURL: asideURL,
            journalStore: attachmentJournalStore
        )
    }

    /// 库替换失败后的同步回滚：新目录挪走、aside 移回原位、清 journal。
    /// 只能用于"install 已返回但库还没换"的窗口——completeSwap 之后旧目录
    /// 已删，journal 语义不再可回滚。
    private func rollbackAttachmentSwap(journal: AttachmentRestoreJournal) {
        let fileManager = FileManager.default
        let targetURL = URL(fileURLWithPath: journal.targetPath)
        let trashURL = targetURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".swap-rollback-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        if fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.moveItem(at: targetURL, to: trashURL)
        }
        if !journal.oldPath.isEmpty {
            let asideURL = URL(fileURLWithPath: journal.oldPath)
            if fileManager.fileExists(atPath: asideURL.path) {
                try? fileManager.moveItem(at: asideURL, to: targetURL)
            }
        }
        try? fileManager.removeItem(at: trashURL)
        try? attachmentJournalStore.clear()
    }

    /// 启动期恢复：上次恢复若在附件 swap 窗口期被杀，按 journal 把
    /// InboxImages 收敛到一致状态。必须在打开数据库之前运行——镜像
    /// 服务一启动就可能读附件目录。
    private func recoverInterruptedAttachmentSwap() {
        do {
            let installed = try AttachmentDirectorySwap.recoverInterruptedSwap(
                journalStore: attachmentJournalStore
            )
            if let installed {
                Self.swapLogger.notice(
                    "Recovered interrupted attachment swap: installedStaged=\(installed, privacy: .public)"
                )
            }
        } catch {
            Self.swapLogger.error(
                "Attachment swap recovery failed: \(String(describing: type(of: error)), privacy: .public)"
            )
        }
    }

    private static let swapLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oboe.app",
        category: "AttachmentSwap"
    )

    func localSnapshots() async throws -> [DatabaseSnapshot] {
        try await databaseLifecycle.snapshotService.snapshots()
    }

    @discardableResult
    func createLocalSnapshot() async throws -> DatabaseSnapshot? {
        try await databaseLifecycle.createDailySnapshotIfNeeded(
            hasChanges: true
        )
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
            if let restoredCurrent = await databaseLifecycle.currentDatabase() {
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
        appearancePreference = try await appearancePreferencesService.set(appearance)
    }

    private func reloadAppearancePreference() async throws {
        guard let appearancePreferencesService =
                runtimeServices?.appearancePreferencesService else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        appearancePreference = try await appearancePreferencesService.load(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
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
        jlptEnrichmentTask?.cancel()
        await jlptEnrichmentTask?.value
        jlptEnrichmentTask = nil
        jlptEnrichmentStatus = .idle
        await runtimeServices?.captureImportCoordinator.pauseAndWait()
        await Task.yield()
    }

    private func replaceDatabase(with sourceURL: URL) async throws -> OboeDatabase {
        try await databaseLifecycle.replaceDatabase(with: sourceURL) { database in
            let service = Self.makeStudySessionService(database: database)
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
        guard let built = makeServices(database: database, generation: generation) else {
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
        jlptEnrichmentServiceGeneration = stagedGeneration
        phase = .ready(stagedContainer)
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

    private struct BuiltServices {
        let container: AppFeatureContainer
        let runtime: RuntimeServices
    }

    /// 所有数据库绑定服务都在局部变量构造完整后才返回；返回 nil 即
    /// 构建失败（内置 JLPT 词库缺失），由调用方转入 `.failed`。
    private func makeServices(
        database: OboeDatabase,
        generation: Int
    ) -> BuiltServices? {
        let deckManagementService = DeckManagementService(
            repository: GRDBDeckRepository(database: database)
        )
        let vocabularyService = VocabularyService(
            repository: GRDBVocabularyRepository(database: database)
        )
        let grammarService = GrammarService(
            repository: GRDBGrammarRepository(database: database)
        )
        let knowledgePointService = KnowledgePointService(
            repository: GRDBKnowledgePointRepository(database: database)
        )
        let knowledgeSearchService = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )
        let inboxRepository = GRDBInboxRepository(database: database)
        let imageStore = AppBootstrapEnvironment.resolveInboxImageStore(baseURL: baseURL)
        let inbox = InboxService(
            repository: inboxRepository,
            onItemDeleted: { reference in
                // Attachment cleanup is best-effort: the Inbox row is gone
                // either way, and a stray file is reclaimed by the next
                // orphan sweep rather than failing the delete.
                try? imageStore.delete(reference)
            }
        )
        let queueStore = AppBootstrapEnvironment.resolveCaptureQueueStore()
        let captureImportCoordinator = CaptureImportCoordinator(
            inboxService: inbox,
            store: queueStore
        )
        let contentCardService = ContentCardService(
            repository: GRDBContentCardRepository(database: database)
        )
        guard let libraryURL = Bundle.main.url(
            forResource: "jlpt-library",
            withExtension: "sqlite",
            subdirectory: "JLPT"
        ) ?? Bundle.main.url(forResource: "jlpt-library", withExtension: "sqlite"),
           let jlptLibraryRepository = try? GRDBJLPTLibraryRepository(databaseURL: libraryURL)
        else {
            return nil
        }
        let jlptLibraryService = JLPTLibraryService(repository: jlptLibraryRepository)
        let jlptImporter = GRDBJLPTImporter(database: database)
        let jlptProgressService = JLPTProgressService(
            libraryRepository: jlptLibraryRepository,
            associationRepository: GRDBJLPTNoteAssociationRepository(database: database),
            adaptiveRepository: GRDBAdaptiveRepository(database: database)
        )
        let jlptEnrichmentService = JLPTLibraryEnrichmentService(
            source: jlptLibraryRepository,
            store: GRDBJLPTEnrichmentRepository(database: database)
        )
        let studySessionService = Self.makeStudySessionService(database: database)
        let studyHistoryService = StudyHistoryService(
            repository: GRDBStudyHistoryRepository(database: database)
        )
        let appearancePreferencesService = AppearancePreferencesService(
            repository: GRDBAppearancePreferencesRepository(database: database)
        )
        let speechPreferencesService = SpeechPreferencesService(
            repository: GRDBSpeechPreferencesRepository(database: database)
        )
        let adaptivePreferencesService = AdaptivePreferencesService(
            repository: GRDBAdaptivePreferencesRepository(database: database)
        )
        let adaptiveCardService = AdaptiveCardService(
            repository: GRDBAdaptiveRepository(database: database),
            invalidation: adaptiveInvalidationCenter
        )
        let credentialStore = AppBootstrapEnvironment.makeAICredentialStore()
        let aiRepository = GRDBAIConfigurationRepository(database: database)
        let aiConfigurationService = AIConfigurationService(
            repository: aiRepository,
            credentialStore: credentialStore
        )
        let aiConnectionTestService = AIConnectionTestService(
            repository: aiRepository,
            credentialStore: credentialStore,
            client: AppBootstrapEnvironment.makeAIConnectionClient()
        )
        let aiModelCatalogService = AIModelCatalogService(
            repository: aiRepository,
            credentialStore: credentialStore,
            client: AppBootstrapEnvironment.makeModelCatalogClient()
        )
        let aiCardGenerationService = AICardGenerationService(
            repository: aiRepository,
            credentialStore: credentialStore,
            client: AppBootstrapEnvironment.makeAICardGenerationClient()
        )
        let sentenceAnalysisService = SentenceAnalysisService(
            configurationRepository: aiRepository,
            credentialStore: credentialStore,
            client: AppBootstrapEnvironment.makeSentenceAnalysisClient(),
            draftRepository: GRDBSentenceAnalysisDraftRepository(database: database)
        )
        let sentenceAnalysisCardCreationService = SentenceAnalysisCardCreationService(
            repository: GRDBSentenceAnalysisCardRepository(database: database)
        )
        let aiRepairService = AIRepairService(
            draftStore: GRDBAIRepairDraftRepository(database: database),
            commitStore: GRDBAIRepairCommitRepository(database: database),
            configurationRepository: aiRepository,
            credentialStore: credentialStore,
            client: AppBootstrapEnvironment.makeAIRepairClient(),
            vocabularyRepository: GRDBVocabularyRepository(database: database),
            grammarRepository: GRDBGrammarRepository(database: database),
            contentCardRepository: GRDBContentCardRepository(database: database),
            adaptiveCardService: adaptiveCardService
        )
        let portableBackupExporter = PortableBackupPackageExporter(
            database: database,
            imageStore: imageStore,
            workingDirectoryURL: baseURL.appendingPathComponent("Exports", isDirectory: true)
        )
        let portableBackupRestorationPreparer = PortableBackupRestorationPreparer(
            currentDatabase: database,
            workingDirectoryURL: baseURL.appendingPathComponent(
                "RestorePreparation",
                isDirectory: true
            ),
            inboxImageResourceExists: { reference in
                imageStore.exists(reference)
            }
        )
        let processingServices = InboxProcessingServices(
            deckService: deckManagementService,
            vocabularyService: vocabularyService,
            grammarService: grammarService,
            knowledgePointService: knowledgePointService,
            contentCardService: contentCardService,
            aiCardGenerationService: aiCardGenerationService,
            sentenceAnalysisService: sentenceAnalysisService,
            sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
            historyService: studyHistoryService,
            speechService: bootstrap.speechService,
            studyService: studySessionService
        )

        let container = AppFeatureContainer(
            generation: generation,
            today: TodayFeatureDependencies(
                studyService: studySessionService,
                historyService: studyHistoryService,
                deckService: deckManagementService,
                speechPreferencesService: speechPreferencesService,
                adaptiveCardService: adaptiveCardService,
                adaptivePreferencesService: adaptivePreferencesService,
                aiRepairService: aiRepairService,
                inboxService: inbox,
                processingServices: processingServices
            ),
            decks: DeckFeatureDependencies(
                deckService: deckManagementService,
                vocabularyService: vocabularyService,
                grammarService: grammarService,
                knowledgePointService: knowledgePointService,
                searchService: knowledgeSearchService,
                contentCardService: contentCardService,
                studyService: studySessionService,
                historyService: studyHistoryService,
                speechPreferencesService: speechPreferencesService,
                adaptivePreferencesService: adaptivePreferencesService,
                adaptiveCardService: adaptiveCardService,
                aiRepairService: aiRepairService,
                aiCardGenerationService: aiCardGenerationService,
                sentenceAnalysisService: sentenceAnalysisService,
                sentenceAnalysisCardCreationService: sentenceAnalysisCardCreationService,
                jlpt: JLPTFeatureDependencies(
                    progressService: jlptProgressService,
                    libraryService: jlptLibraryService,
                    importer: jlptImporter
                )
            ),
            settings: SettingsFeatureDependencies(
                studyService: studySessionService,
                speechPreferencesService: speechPreferencesService,
                adaptivePreferencesService: adaptivePreferencesService,
                aiConfigurationService: aiConfigurationService,
                aiConnectionTestService: aiConnectionTestService,
                aiModelCatalogService: aiModelCatalogService,
                speechService: bootstrap.speechService,
                exporter: portableBackupExporter,
                restorationPreparer: portableBackupRestorationPreparer
            ),
            shared: SharedFeatureDependencies(
                speechService: bootstrap.speechService,
                ocrService: bootstrap.ocrService,
                inboxImageStore: imageStore
            )
        )
        let runtime = RuntimeServices(
            adaptiveCardService: adaptiveCardService,
            aiRepairService: aiRepairService,
            appearancePreferencesService: appearancePreferencesService,
            captureImportCoordinator: captureImportCoordinator,
            captureQueueStore: queueStore,
            inboxService: inbox,
            inboxImageStore: imageStore,
            jlptEnrichmentService: jlptEnrichmentService
        )
        return BuiltServices(container: container, runtime: runtime)
    }

    nonisolated private static func makeStudySessionService(
        database: OboeDatabase
    ) -> StudySessionService {
        let submissionRepository = AppBootstrapEnvironment.makeSubmissionRepository(
            base: GRDBReviewSubmissionRepository(database: database)
        )
        return StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: AppBootstrapEnvironment.makeReviewContentRepository(
                base: GRDBReviewCardContentRepository(database: database)
            ),
            submissionRepository: submissionRepository,
            undoRepository: GRDBReviewSubmissionRepository(database: database),
            scheduler: SwiftFSRSReviewScheduler()
        )
    }
}
