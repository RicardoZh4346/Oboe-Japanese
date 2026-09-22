import Observation
import OboeDomain
import OboeInfrastructure
import OboeSharedCapture
import OSLog
import SwiftUI

@main
struct OboeApp: App {
    @State private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(dependencies: dependencies)
                .modifier(UITestTraitOverrideModifier())
                .task {
                    await dependencies.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await dependencies.drainSharedCaptures() }
                    case .background:
                        Task { await dependencies.createDailySnapshotIfNeeded() }
                    default:
                        break
                    }
                }
        }
    }
}

/// DEBUG-only UI-test trait override (T14): `OBOE_UI_TEST_DYNAMIC_TYPE`
/// forces a Dynamic Type size (e.g. `ax5`) so layout/accessibility-size
/// branches can be exercised in simulator UI tests without changing
/// persisted settings. Reduce Motion is a read-only trait and stays on the
/// real-device checklist (T28). The override is a no-op in release builds
/// and when the variable is absent or unrecognized.
private struct UITestTraitOverrideModifier: ViewModifier {
    #if DEBUG
    private static var dynamicTypeSize: DynamicTypeSize? {
        switch ProcessInfo.processInfo.environment["OBOE_UI_TEST_DYNAMIC_TYPE"] {
        case "extraLarge", "xl": return .xLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1", "ax1": return .accessibility1
        case "accessibility3", "ax3": return .accessibility3
        case "accessibility5", "ax5": return .accessibility5
        default: return nil
        }
    }

    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if let size = Self.dynamicTypeSize {
            content.environment(\.dynamicTypeSize, size)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

@MainActor
@Observable
final class AppDependencies {
    private let baseURL: URL
    private let databaseLifecycle: OboeDatabaseLifecycle
    let speechService: any SpeechService
    private var didStart = false

    private(set) var deckManagementService: DeckManagementService?
    private(set) var vocabularyService: VocabularyService?
    private(set) var grammarService: GrammarService?
    private(set) var knowledgePointService: KnowledgePointService?
    private(set) var knowledgeSearchService: KnowledgeSearchService?
    private(set) var contentCardService: ContentCardService?
    private(set) var studySessionService: StudySessionService?
    private(set) var studyHistoryService: StudyHistoryService?
    private(set) var appearancePreferencesService: AppearancePreferencesService?
    private(set) var speechPreferencesService: SpeechPreferencesService?
    /// Shared invalidation token for every `AdaptiveCardService` rebuild —
    /// bumping it after a database replacement guarantees snapshots read from
    /// the old file can never reach the new view tree (design §4.3).
    private let adaptiveInvalidationCenter = AdaptiveInvalidationCenter()
    private(set) var adaptiveCardService: AdaptiveCardService?
    private(set) var adaptivePreferencesService: AdaptivePreferencesService?
    private(set) var aiConfigurationService: AIConfigurationService?
    private(set) var aiConnectionTestService: AIConnectionTestService?
    private(set) var aiCardGenerationService: AICardGenerationService?
    private(set) var sentenceAnalysisService: SentenceAnalysisService?
    private(set) var sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService?
    /// T07 AI repair session service — user-triggered analysis only; the
    /// draft store keeps explanations and candidates resumable.
    private(set) var aiRepairService: AIRepairService?
    private(set) var portableBackupExporter: PortableBackupExporter?
    private(set) var portableBackupRestorationPreparer: PortableBackupRestorationPreparer?
    private(set) var jlptProgressService: JLPTProgressService?
    private(set) var jlptLibraryService: JLPTLibraryService?
    private(set) var jlptImporter: (any JLPTImporting)?
    /// T12 已导入 JLPT 内容的幂等回填（设计 §7.4）。服务随数据库
    /// 重建；任务句柄保证启动/进入词库/恢复等触发合并为同一次运行。
    private(set) var jlptEnrichmentService: JLPTLibraryEnrichmentService?
    private(set) var jlptEnrichmentStatus: JLPTEnrichmentStatus = .idle
    private var jlptEnrichmentTask: Task<Void, Never>?
    /// `configureServices` 完成时的 `databaseGeneration`——恢复流程中
    /// 服务已换新但操作标记未复位时仍允许调度，世代不一致（服务还
    /// 绑着旧库）则拒绝。
    private var jlptEnrichmentServiceGeneration = -1
    private(set) var inboxService: InboxService?
    /// On-device OCR — independent of the database, so it survives restores.
    /// UI tests substitute a deterministic stub via `OBOE_UI_TEST_OCR_STUB`.
    let ocrService: any OCRRecognizing
    private(set) var captureImportCoordinator: CaptureImportCoordinator?
    private var captureQueueStore: (any CaptureQueueStoring)?
    /// Controlled local storage for Inbox image attachments — lives outside
    /// the database file so a restore sweep never touches the files, while
    /// `onItemDeleted` and the orphan sweep keep the directory honest.
    private(set) var inboxImageStore: InboxImageStore?
    private(set) var launchErrorMessage: String?
    private(set) var isLoading = true
    private(set) var isDatabaseOperationInProgress = false
    private(set) var databaseGeneration = 0
    private(set) var appearancePreference = AppAppearance.system

    init() {
        let baseURL = Self.applicationDataURL()
        self.baseURL = baseURL
        #if DEBUG
        if let stubMode = ProcessInfo.processInfo.environment["OBOE_UI_TEST_SPEECH_STUB"],
           let mode = UITestStubSpeechService.Mode(rawValue: stubMode) {
            speechService = UITestStubSpeechService(mode: mode)
        } else if ProcessInfo.processInfo.environment["OBOE_UI_TEST_SPEECH_UNAVAILABLE"] != nil {
            speechService = UITestUnavailableSpeechService()
        } else {
            speechService = SystemJapaneseSpeechService()
        }
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_OCR_STUB"] != nil {
            ocrService = UITestStubOCRService()
        } else {
            ocrService = VisionOCRService()
        }
        #else
        speechService = SystemJapaneseSpeechService()
        ocrService = VisionOCRService()
        #endif
        databaseLifecycle = OboeDatabaseLifecycle(
            databaseURL: baseURL.appendingPathComponent("oboe.sqlite"),
            snapshotDirectoryURL: baseURL.appendingPathComponent("Snapshots", isDirectory: true)
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
            let database = try await databaseLifecycle.open()
            configureServices(database: database)
            #if DEBUG
            // UI-test seam: fabricate the post-restore pending-import state so
            // the awaiting-import notice path can be exercised end to end.
            // Must run before the first await after configureServices — a
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
            if ProcessInfo.processInfo.environment["OBOE_UI_TEST_AI_ENABLED"] != nil,
               let aiConfigurationService {
                var draft = AIConfigurationDraft.deepSeekDefault
                draft.isEnabled = true
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
            try? await aiRepairService?.restoreDraftsForLaunch()
            await drainSharedCaptures()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            launchErrorMessage = "无法打开本地数据库：\(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Shared-queue consumption is triggered by hints (cold start, returning
    /// to foreground, entering the Inbox) — the pending directory is the
    /// source of truth, and the coordinator coalesces duplicate drains.
    /// While `sharedCapturesAwaitingImport` is set, files left at a restore
    /// boundary wait for an explicit user choice instead of auto-replaying.
    func drainSharedCaptures() async {
        guard !isDatabaseOperationInProgress,
              sharedCapturesAwaitingImport == nil else { return }
        guard let report = try? await captureImportCoordinator?.drainPendingCaptures()
        else { return }
        if let latest = report.imported.last(where: {
            $0.requestedAction == .continueInApp
        }) {
            pendingContinueItemID = latest.itemID
        }
    }

    /// Inbox item imported with `continueInApp`, offered on the landing tab —
    /// tapped or dismissed only by the user, never auto-navigating.
    private(set) var pendingContinueItemID: UUID?

    /// Share files still pending at a restore boundary. Recorded so old
    /// files never silently replay into the fresh database — the Inbox
    /// notice lets the user import them explicitly.
    private(set) var sharedCapturesAwaitingImport: Int?

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
              let service = jlptEnrichmentService else { return }
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

    /// Synchronous on purpose: it must run in the same un-interleaved stretch
    /// as `configureServices`, so no drain can slip between building the
    /// coordinator and recording the boundary count (an actor hop here would
    /// reopen that window).
    /// Reclaims attachment files no Inbox row references — abandoned picks,
    /// items removed before the cleanup hook existed, restore-orphaned
    /// resources. A creation-time buffer protects files still being attached.
    private func sweepOrphanedInboxImages() async {
        guard let inboxImageStore, let inboxService else { return }
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
        let count = try? captureQueueStore?.pendingFileURLs().count
        sharedCapturesAwaitingImport = (count ?? 0) > 0 ? count : nil
    }

    /// Files still waiting in the shared queue. Nil when the App Group
    /// container is unavailable — callers must not misreport that as zero.
    func pendingSharedCaptureCount() -> Int? {
        try? captureQueueStore?.pendingFileURLs().count
    }

    func applyPreparedRestoration(_ preparation: PreparedRestoration) async throws {
        guard !isDatabaseOperationInProgress else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        isDatabaseOperationInProgress = true
        defer { isDatabaseOperationInProgress = false }
        await suspendBeforeDatabaseReplacement()
        do {
            let database = try await replaceDatabase(with: preparation.temporaryDatabaseURL)
            configureServices(database: database)
            refreshAwaitingSharedCaptures()
            try await reloadAppearancePreference()
            try? await aiRepairService?.restoreDraftsForLaunch()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            if let restoredCurrent = await databaseLifecycle.currentDatabase() {
                configureServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
            } else {
                await captureImportCoordinator?.resume()
            }
            throw error
        }
    }

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
            configureServices(database: database)
            refreshAwaitingSharedCaptures()
            try await reloadAppearancePreference()
            try? await aiRepairService?.restoreDraftsForLaunch()
            await sweepOrphanedInboxImages()
            scheduleJLPTEnrichment()
        } catch {
            if let restoredCurrent = await databaseLifecycle.currentDatabase() {
                configureServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
            } else {
                await captureImportCoordinator?.resume()
            }
            throw error
        }
    }

    func createDailySnapshotIfNeeded() async {
        guard !isDatabaseOperationInProgress else { return }
        _ = try? await createLocalSnapshot()
    }

    func setAppearancePreference(_ appearance: AppAppearance) async throws {
        guard let appearancePreferencesService else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        appearancePreference = try await appearancePreferencesService.set(appearance)
    }

    private func reloadAppearancePreference() async throws {
        guard let appearancePreferencesService else {
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
    /// disk and the coordinator rebuilt by `configureServices` resumes them.
    private func suspendBeforeDatabaseReplacement() async {
        databaseGeneration &+= 1
        // Epoch bump before the swap: any adaptive snapshot still in flight
        // from the outgoing database is tagged with a dead generation.
        await adaptiveCardService?.invalidate()
        // Enrichment writes go through the outgoing pool — cancel and wait
        // so no batch can land on a closed database mid-swap.
        jlptEnrichmentTask?.cancel()
        await jlptEnrichmentTask?.value
        jlptEnrichmentTask = nil
        jlptEnrichmentStatus = .idle
        await captureImportCoordinator?.pauseAndWait()
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

    private func configureServices(database: OboeDatabase) {
        deckManagementService = DeckManagementService(
            repository: GRDBDeckRepository(database: database)
        )
        vocabularyService = VocabularyService(
            repository: GRDBVocabularyRepository(database: database)
        )
        grammarService = GrammarService(
            repository: GRDBGrammarRepository(database: database)
        )
        knowledgePointService = KnowledgePointService(
            repository: GRDBKnowledgePointRepository(database: database)
        )
        knowledgeSearchService = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )
        let inboxRepository = GRDBInboxRepository(database: database)
        let imageStore = Self.resolveInboxImageStore(baseURL: baseURL)
        inboxImageStore = imageStore
        let inbox = InboxService(
            repository: inboxRepository,
            onItemDeleted: { reference in
                // Attachment cleanup is best-effort: the Inbox row is gone
                // either way, and a stray file is reclaimed by the next
                // orphan sweep rather than failing the delete.
                try? imageStore.delete(reference)
            }
        )
        inboxService = inbox
        let queueStore = Self.resolveCaptureQueueStore()
        captureQueueStore = queueStore
        captureImportCoordinator = CaptureImportCoordinator(
            inboxService: inbox,
            store: queueStore
        )
        contentCardService = ContentCardService(
            repository: GRDBContentCardRepository(database: database)
        )
        if let libraryURL = Bundle.main.url(
            forResource: "jlpt-library",
            withExtension: "sqlite",
            subdirectory: "JLPT"
        ) ?? Bundle.main.url(forResource: "jlpt-library", withExtension: "sqlite"),
           let repository = try? GRDBJLPTLibraryRepository(databaseURL: libraryURL) {
            jlptLibraryService = JLPTLibraryService(repository: repository)
            jlptImporter = GRDBJLPTImporter(database: database)
            jlptProgressService = JLPTProgressService(
                libraryRepository: repository,
                associationRepository: GRDBJLPTNoteAssociationRepository(database: database),
                adaptiveRepository: GRDBAdaptiveRepository(database: database)
            )
            jlptEnrichmentService = JLPTLibraryEnrichmentService(
                source: repository,
                store: GRDBJLPTEnrichmentRepository(database: database)
            )
        } else {
            jlptProgressService = nil
            jlptLibraryService = nil
            jlptImporter = nil
            jlptEnrichmentService = nil
            launchErrorMessage = "无法载入内置 JLPT 词库。"
        }
        studySessionService = Self.makeStudySessionService(database: database)
        studyHistoryService = StudyHistoryService(
            repository: GRDBStudyHistoryRepository(database: database)
        )
        appearancePreferencesService = AppearancePreferencesService(
            repository: GRDBAppearancePreferencesRepository(database: database)
        )
        speechPreferencesService = SpeechPreferencesService(
            repository: GRDBSpeechPreferencesRepository(database: database)
        )
        adaptivePreferencesService = AdaptivePreferencesService(
            repository: GRDBAdaptivePreferencesRepository(database: database)
        )
        adaptiveCardService = AdaptiveCardService(
            repository: GRDBAdaptiveRepository(database: database),
            invalidation: adaptiveInvalidationCenter
        )
        let credentialStore: any AICredentialStore
        let connectionClient: any AIConnectionClient
        let cardGenerationClient: any AICardGenerationClient
        let sentenceAnalysisClient: any SentenceAnalysisClient
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"] != nil {
            credentialStore = UITestAICredentialStore()
            connectionClient = UITestAIConnectionClient()
            cardGenerationClient = UITestAICardGenerationClient()
            sentenceAnalysisClient = UITestSentenceAnalysisClient()
        } else {
            credentialStore = KeychainAICredentialStore()
            connectionClient = ChatCompletionsAIConnectionClient()
            cardGenerationClient = ChatCompletionsAICardGenerationClient()
            sentenceAnalysisClient = ChatCompletionsSentenceAnalysisClient()
        }
        #else
        credentialStore = KeychainAICredentialStore()
        connectionClient = ChatCompletionsAIConnectionClient()
        cardGenerationClient = ChatCompletionsAICardGenerationClient()
        sentenceAnalysisClient = ChatCompletionsSentenceAnalysisClient()
        #endif
        let aiRepository = GRDBAIConfigurationRepository(database: database)
        aiConfigurationService = AIConfigurationService(
            repository: aiRepository,
            credentialStore: credentialStore
        )
        aiConnectionTestService = AIConnectionTestService(
            repository: aiRepository,
            credentialStore: credentialStore,
            client: connectionClient
        )
        aiCardGenerationService = AICardGenerationService(
            repository: aiRepository,
            credentialStore: credentialStore,
            client: cardGenerationClient
        )
        sentenceAnalysisService = SentenceAnalysisService(
            configurationRepository: aiRepository,
            credentialStore: credentialStore,
            client: sentenceAnalysisClient,
            draftRepository: GRDBSentenceAnalysisDraftRepository(database: database)
        )
        sentenceAnalysisCardCreationService = SentenceAnalysisCardCreationService(
            repository: GRDBSentenceAnalysisCardRepository(database: database)
        )
        let repairClient: any AIRepairClient
        #if DEBUG
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"] != nil {
            repairClient = UITestAIRepairClient()
        } else {
            repairClient = ChatCompletionsAIRepairClient()
        }
        #else
        repairClient = ChatCompletionsAIRepairClient()
        #endif
        if let adaptiveCardService {
            aiRepairService = AIRepairService(
                draftStore: GRDBAIRepairDraftRepository(database: database),
                commitStore: GRDBAIRepairCommitRepository(database: database),
                configurationRepository: aiRepository,
                credentialStore: credentialStore,
                client: repairClient,
                vocabularyRepository: GRDBVocabularyRepository(database: database),
                grammarRepository: GRDBGrammarRepository(database: database),
                contentCardRepository: GRDBContentCardRepository(database: database),
                adaptiveCardService: adaptiveCardService
            )
        } else {
            aiRepairService = nil
        }
        portableBackupExporter = PortableBackupExporter(
            database: database,
            workingDirectoryURL: baseURL.appendingPathComponent("Exports", isDirectory: true)
        )
        portableBackupRestorationPreparer = PortableBackupRestorationPreparer(
            currentDatabase: database,
            workingDirectoryURL: baseURL.appendingPathComponent(
                "RestorePreparation",
                isDirectory: true
            ),
            inboxImageResourceExists: { reference in
                imageStore.exists(reference)
            }
        )
        databaseGeneration &+= 1
        jlptEnrichmentServiceGeneration = databaseGeneration
    }

    /// UI tests inject an isolated queue directory; production resolves the
    /// shared App Group container. A nil store means the group entitlement is
    /// absent (e.g. unsigned builds) — the coordinator reports that honestly.
    nonisolated private static func resolveCaptureQueueStore() -> (any CaptureQueueStoring)? {
        if let override = ProcessInfo.processInfo.environment["OBOE_UI_TEST_CAPTURE_QUEUE"],
           !override.isEmpty {
            return AppGroupCaptureStore(
                queueDirectoryURL: URL(fileURLWithPath: override, isDirectory: true)
            )
        }
        return AppGroupCaptureStore()
    }

    /// Image attachments live in the app's own container (not the App Group —
    /// extensions never touch them). UI tests redirect the root via env.
    nonisolated private static func resolveInboxImageStore(
        baseURL: URL
    ) -> InboxImageStore {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["OBOE_UI_TEST_IMAGE_STORE"],
           !override.isEmpty {
            return InboxImageStore(
                rootDirectoryURL: URL(fileURLWithPath: override, isDirectory: true)
            )
        }
        #endif
        return InboxImageStore(
            rootDirectoryURL: baseURL.appendingPathComponent(
                "InboxImages",
                isDirectory: true
            )
        )
    }

    nonisolated private static func makeStudySessionService(
        database: OboeDatabase
    ) -> StudySessionService {
        let submissionRepository = makeSubmissionRepository(database: database)
        return StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: makeReviewContentRepository(database: database),
            submissionRepository: submissionRepository,
            undoRepository: GRDBReviewSubmissionRepository(database: database),
            scheduler: SwiftFSRSReviewScheduler()
        )
    }

    nonisolated private static func makeReviewContentRepository(
        database: OboeDatabase
    ) -> any ReviewCardContentRepository {
        let base = GRDBReviewCardContentRepository(database: database)
        #if DEBUG
        if let identifier = ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"],
           UUID(uuidString: identifier) != nil,
           let raw = ProcessInfo.processInfo.environment["OBOE_UI_TEST_REVIEW_LOAD_DELAY"],
           let delay = Double(raw), delay.isFinite, delay >= 0 {
            let failures = Int(
                ProcessInfo.processInfo.environment["OBOE_UI_TEST_REVIEW_LOAD_FAILURES"] ?? "0"
            ) ?? 0
            return UITestDelayedReviewContentRepository(
                base: base, delay: delay, remainingFailures: failures
            )
        }
        #endif
        return base
    }

    nonisolated private static func makeSubmissionRepository(
        database: OboeDatabase
    ) -> any ReviewSubmissionRepository {
        let base = GRDBReviewSubmissionRepository(database: database)
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["OBOE_UI_TEST_SUBMIT_FAILURES"],
           let failures = Int(raw), failures > 0 {
            return UITestFlakySubmissionRepository(base: base, remainingFailures: failures)
        }
        #endif
        return base
    }

    private static func applicationDataURL() -> URL {
        if let identifier = ProcessInfo.processInfo.environment["OBOE_UI_TEST_DATABASE_ID"],
           let uuid = UUID(uuidString: identifier) {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Oboe-UITests", isDirectory: true)
                .appendingPathComponent(uuid.uuidString, isDirectory: true)
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport.appendingPathComponent("Oboe", isDirectory: true)
    }
}

#if DEBUG
private actor UITestDelayedReviewContentRepository: ReviewCardContentRepository {
    private let base: any ReviewCardContentRepository
    private let delay: Double
    private var remainingFailures: Int
    private var hasLoaded = false

    init(base: any ReviewCardContentRepository, delay: Double, remainingFailures: Int) {
        self.base = base
        self.delay = delay
        self.remainingFailures = remainingFailures
    }

    func fetchReviewCardContent(cardID: UUID) async throws -> ReviewCardContent? {
        if hasLoaded {
            try await Task.sleep(for: .seconds(delay))
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw NSError(
                    domain: "OboeUITest",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "测试注入的下一张载入失败"]
                )
            }
        }
        hasLoaded = true
        return try await base.fetchReviewCardContent(cardID: cardID)
    }
}

/// UI tests run as unsigned simulator builds, where Keychain access can fail with
/// a missing-entitlement error. Release composition always uses Keychain.
private actor UITestAICredentialStore: AICredentialStore {
    private var credentials: [AICredentialReference: String] = [:]

    func readCredential(for reference: AICredentialReference) -> String? {
        credentials[reference]
    }

    func saveCredential(_ credential: String, for reference: AICredentialReference) {
        credentials[reference] = credential
    }

    func deleteCredential(for reference: AICredentialReference) {
        credentials.removeValue(forKey: reference)
    }
}

private struct UITestAIConnectionClient: AIConnectionClient {
    func testConnection(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> AIConnectionTestResult {
        AIConnectionTestResult(
            serviceName: configuration.serviceName,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode
        )
    }
}

private struct UITestAICardGenerationClient: AICardGenerationClient {
    func generate(
        input: AICardGenerationInput,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        try await Task.sleep(for: .seconds(5))
        switch input.kind {
        case .vocabulary:
            return #"{"schemaVersion":2,"kind":"vocabulary","headword":"食べる","reading":"たべる","meaningZH":"吃","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N5","examples":[{"japanese":"毎朝パンを食べます。","translationZH":"我每天早上吃面包。"}],"notes":"","warnings":[]}"#
        case .grammar:
            return #"{"schemaVersion":2,"kind":"grammar","grammarForm":"～たことがある","meaningZH":"曾经……过","usage":"表示过去的经历","connection":"动词た形＋ことがある","jlpt":"N4","examples":[{"japanese":"日本へ行ったことがあります。","translationZH":"我去过日本。"}],"notes":"","warnings":[]}"#
        }
    }
}

/// Deterministic repair analysis for UI tests (T07): a short delay keeps the
/// analyzing state observable so cancel can be exercised end to end.
/// `OBOE_UI_TEST_AI_REPAIR_FAIL=1` simulates a transport failure instead.
private struct UITestAIRepairClient: AIRepairClient {
    func analyze(
        context: AIRepairRequestContext,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_AI_REPAIR_FAIL"] != nil {
            throw AIConnectionError.serviceUnavailable(statusCode: 503)
        }
        try await Task.sleep(for: .milliseconds(3_000))
        return #"{"schemaVersion":2,"problemTypes":["similar_words_confusion","example_too_complex"],"summary":"这张卡可能因近形词混淆而难记，例句也偏复杂。","suggestions":[{"type":"add_disambiguation","title":"补充辨析说明","reason":"与近形词区分度不足","replacement":{"notes":"注意与「受け取る」区分：受ける偏被动接受。"}},{"type":"split_card","title":"拆为两张卡","reason":"义项跨语境，合并回忆目标过宽","splitNotes":[{"kind":"vocabulary","headword":"受ける","reading":"うける","meaningZH":"接受（考试、治疗等）","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N3","usage":null,"connection":null,"notes":null,"examples":[{"japanese":"試験を受ける","translationZH":"参加考试"}]},{"kind":"vocabulary","headword":"受ける","reading":"うける","meaningZH":"遭受（损失、攻击等）","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N3","usage":null,"connection":null,"notes":null,"examples":[{"japanese":"被害を受ける","translationZH":"遭受损失"}]}]}]}"#
    }
}

private struct UITestSentenceAnalysisClient: SentenceAnalysisClient {
    func analyze(
        input: SentenceAnalysisInput,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        return #"{"schemaVersion":2,"sentence":"日本に行ったことがありますか。","translationZH":"你去过日本吗？","explanationZH":"询问对方是否有去日本的经历。","items":[{"kind":"particle","surface":"に","canonicalForm":"に","reading":"に","meaningZH":"向、到","roleZH":"表示移动的目的地","spans":[{"text":"に","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"に","reading":"","meaningZH":"表示移动目的地","partsOfSpeech":[],"pitchAccent":null,"usage":"接在地点后","connection":"地点＋に","notes":""}},{"kind":"vocabulary","surface":"行った","canonicalForm":"行く","reading":"いく","meaningZH":"去","roleZH":"动词「行く」的过去式","spans":[{"text":"行った","occurrence":1}],"cardDraft":{"kind":"vocabulary","headword":"行く","reading":"いく","meaningZH":"去","partsOfSpeech":["五段动词","自动词"],"pitchAccent":0,"usage":"","connection":"","notes":""}},{"kind":"grammar","surface":"～たことがある","canonicalForm":"～たことがある","reading":"","meaningZH":"曾经……过","roleZH":"表示过去经历","spans":[{"text":"行った","occurrence":1},{"text":"ことがあります","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"～たことがある","reading":"","meaningZH":"曾经……过","partsOfSpeech":[],"pitchAccent":null,"usage":"表示过去经历","connection":"动词た形＋ことがある","notes":""}},{"kind":"expression","surface":"未对齐项目","canonicalForm":"未对齐项目","reading":"","meaningZH":"即使定位失败，解释仍然可读","roleZH":"验证安全降级","spans":[{"text":"存在しない","occurrence":1}],"cardDraft":null}],"warnings":["请核对语境后再用于学习"]}"#
    }
}

/// Deterministic OCR for UI tests — real Vision output varies by simulator
/// build, so the scripted blocks keep the selection/edit/save flow stable.
/// `OBOE_UI_TEST_OCR_FAIL=1` simulates a recognition failure instead;
/// `OBOE_UI_TEST_OCR_LONG=1` returns a block over the Inbox length limit.
private struct UITestStubOCRService: OCRRecognizing {
    func recognize(imageData: Data) async throws -> OCRResult {
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_OCR_FAIL"] != nil {
            throw OCRError.recognitionFailed("测试注入的识别失败")
        }
        if ProcessInfo.processInfo.environment["OBOE_UI_TEST_OCR_LONG"] != nil {
            return OCRResult(
                blocks: [
                    OCRTextBlock(
                        id: 0,
                        text: String(repeating: "あ", count: InboxText.maximumCharacterCount + 1),
                        confidence: 0.9,
                        boundingBox: OCRBoundingBox(x: 0.1, y: 0.1, width: 0.8, height: 0.2)
                    ),
                ],
                recognizedLanguages: ["ja-JP"]
            )
        }
        return OCRResult(
            blocks: [
                OCRTextBlock(
                    id: 0,
                    text: "今日はいい天気です",
                    confidence: 0.96,
                    boundingBox: OCRBoundingBox(x: 0.1, y: 0.1, width: 0.8, height: 0.2)
                ),
                OCRTextBlock(
                    id: 1,
                    text: "駅まで歩きます",
                    confidence: 0.42,
                    boundingBox: OCRBoundingBox(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
                ),
            ],
            recognizedLanguages: ["ja-JP"]
        )
    }
}

/// Simulates a device without a Japanese voice so UI tests can cover the
/// speech-unavailable and speech-error review states.
private final class UITestUnavailableSpeechService: SpeechService {
    let availability: JapaneseSpeechAvailability = .unavailable

    @discardableResult
    func speakWithEvents(_ texts: [String], onEvent: @escaping SpeechEventHandler) -> UUID {
        let requestID = UUID()
        onEvent(.failed(requestID: requestID, error: .voiceUnavailable))
        return requestID
    }

    func stop() {}
}

/// T18 seam (`OBOE_UI_TEST_SPEECH_STUB=ok|fail|pending`): deterministic
/// playback events that don't depend on the simulator's voice install or
/// real TTS timing. `ok` completes shortly after start; `fail` reports
/// `audioSessionUnavailable`; `pending` starts but never finishes.
@MainActor
private final class UITestStubSpeechService: SpeechService {
    enum Mode: String {
        case ok, fail, pending
    }

    private let mode: Mode
    private var inFlight: (id: UUID, onEvent: SpeechEventHandler)?

    init(mode: Mode) {
        self.mode = mode
    }

    var availability: JapaneseSpeechAvailability {
        .available(voiceName: "UITestStubVoice")
    }

    @discardableResult
    func speakWithEvents(_ texts: [String], onEvent: @escaping SpeechEventHandler) -> UUID {
        cancelInFlight()
        let requestID = UUID()
        inFlight = (requestID, onEvent)
        Task { @MainActor in
            guard self.inFlight?.id == requestID else { return }
            onEvent(.started(requestID: requestID))
            switch self.mode {
            case .ok:
                try? await Task.sleep(for: .milliseconds(250))
                guard self.inFlight?.id == requestID else { return }
                self.inFlight = nil
                onEvent(.completed(requestID: requestID))
            case .fail:
                guard self.inFlight?.id == requestID else { return }
                self.inFlight = nil
                onEvent(.failed(requestID: requestID, error: .audioSessionUnavailable))
            case .pending:
                break
            }
        }
        return requestID
    }

    /// Matches the real service: an interrupted request reports `.cancelled`
    /// so a backgrounded/pending playback never reads as failure or success.
    func stop() {
        cancelInFlight()
    }

    private func cancelInFlight() {
        guard let inFlight else { return }
        self.inFlight = nil
        inFlight.onEvent(.cancelled(requestID: inFlight.id))
    }
}

/// Fails the first `remainingFailures` commit attempts with a recoverable
/// error, then forwards everything to the real repository.
private actor UITestFlakySubmissionRepository: ReviewSubmissionRepository {
    private let base: any ReviewSubmissionRepository
    private var remainingFailures: Int

    init(base: any ReviewSubmissionRepository, remainingFailures: Int) {
        self.base = base
        self.remainingFailures = remainingFailures
    }

    func fetchSubmittedReview(eventID: UUID) async throws -> ReviewLogRecord? {
        try await base.fetchSubmittedReview(eventID: eventID)
    }

    func fetchReviewContext(cardID: UUID) async throws -> ReviewSubmissionContext? {
        try await base.fetchReviewContext(cardID: cardID)
    }

    func commitReview(_ mutation: ReviewSubmissionMutation) async throws -> ReviewLogRecord {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw NSError(
                domain: "OboeUITest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "测试注入的保存失败"]
            )
        }
        return try await base.commitReview(mutation)
    }
}
#endif
