import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI

@main
struct OboeApp: App {
    @State private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView(dependencies: dependencies)
                .task {
                    await dependencies.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    Task { await dependencies.createDailySnapshotIfNeeded() }
                }
        }
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
    private(set) var aiConfigurationService: AIConfigurationService?
    private(set) var aiConnectionTestService: AIConnectionTestService?
    private(set) var aiCardGenerationService: AICardGenerationService?
    private(set) var sentenceAnalysisService: SentenceAnalysisService?
    private(set) var sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService?
    private(set) var portableBackupExporter: PortableBackupExporter?
    private(set) var portableBackupRestorationPreparer: PortableBackupRestorationPreparer?
    private(set) var jlptLibraryService: JLPTLibraryService?
    private(set) var jlptImporter: (any JLPTImporting)?
    private(set) var launchErrorMessage: String?
    private(set) var isLoading = true
    private(set) var isDatabaseOperationInProgress = false
    private(set) var databaseGeneration = 0
    private(set) var appearancePreference = AppAppearance.system

    init() {
        let baseURL = Self.applicationDataURL()
        self.baseURL = baseURL
        speechService = SystemJapaneseSpeechService()
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
            let database = try await databaseLifecycle.open()
            configureServices(database: database)
            try await reloadAppearancePreference()
        } catch {
            launchErrorMessage = "无法打开本地数据库：\(error.localizedDescription)"
        }
        isLoading = false
    }

    func applyPreparedRestoration(_ preparation: PreparedRestoration) async throws {
        guard !isDatabaseOperationInProgress else {
            throw OboeDatabaseLifecycleError.operationInProgress
        }
        isDatabaseOperationInProgress = true
        defer { isDatabaseOperationInProgress = false }
        do {
            let database = try await replaceDatabase(with: preparation.temporaryDatabaseURL)
            configureServices(database: database)
            try await reloadAppearancePreference()
        } catch {
            if let restoredCurrent = await databaseLifecycle.currentDatabase() {
                configureServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
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
        do {
            let database = try await replaceDatabase(with: snapshot.url)
            configureServices(database: database)
            try await reloadAppearancePreference()
        } catch {
            if let restoredCurrent = await databaseLifecycle.currentDatabase() {
                configureServices(database: restoredCurrent)
                try? await reloadAppearancePreference()
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
        } else {
            jlptLibraryService = nil
            jlptImporter = nil
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
        portableBackupExporter = PortableBackupExporter(
            database: database,
            workingDirectoryURL: baseURL.appendingPathComponent("Exports", isDirectory: true)
        )
        portableBackupRestorationPreparer = PortableBackupRestorationPreparer(
            currentDatabase: database,
            workingDirectoryURL: baseURL.appendingPathComponent(
                "RestorePreparation",
                isDirectory: true
            )
        )
        databaseGeneration &+= 1
    }

    nonisolated private static func makeStudySessionService(
        database: OboeDatabase
    ) -> StudySessionService {
        let submissionRepository = GRDBReviewSubmissionRepository(database: database)
        return StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: GRDBReviewCardContentRepository(database: database),
            submissionRepository: submissionRepository,
            undoRepository: submissionRepository,
            scheduler: SwiftFSRSReviewScheduler()
        )
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
            return #"{"schemaVersion":1,"kind":"vocabulary","headword":"食べる","reading":"たべる","meaningZH":"吃","partOfSpeech":"一段动词","jlpt":"N5","examples":[{"japanese":"毎朝パンを食べます。","translationZH":"我每天早上吃面包。"}],"notes":"","warnings":[]}"#
        case .grammar:
            return #"{"schemaVersion":1,"kind":"grammar","grammarForm":"～たことがある","meaningZH":"曾经……过","usage":"表示过去的经历","connection":"动词た形＋ことがある","jlpt":"N4","examples":[{"japanese":"日本へ行ったことがあります。","translationZH":"我去过日本。"}],"notes":"","warnings":[]}"#
        }
    }
}

private struct UITestSentenceAnalysisClient: SentenceAnalysisClient {
    func analyze(
        input: SentenceAnalysisInput,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        return #"{"schemaVersion":1,"sentence":"日本に行ったことがありますか。","translationZH":"你去过日本吗？","explanationZH":"询问对方是否有去日本的经历。","items":[{"kind":"particle","surface":"に","canonicalForm":"に","reading":"に","meaningZH":"向、到","roleZH":"表示移动的目的地","spans":[{"text":"に","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"に","reading":"に","meaningZH":"表示移动目的地","partOfSpeech":"","usage":"接在地点后","connection":"地点＋に","notes":""}},{"kind":"vocabulary","surface":"行った","canonicalForm":"行く","reading":"いく","meaningZH":"去","roleZH":"动词「行く」的过去式","spans":[{"text":"行った","occurrence":1}],"cardDraft":{"kind":"vocabulary","headword":"行く","reading":"いく","meaningZH":"去","partOfSpeech":"五段动词","usage":"","connection":"","notes":""}},{"kind":"grammar","surface":"～たことがある","canonicalForm":"～たことがある","reading":"","meaningZH":"曾经……过","roleZH":"表示过去经历","spans":[{"text":"行った","occurrence":1},{"text":"ことがあります","occurrence":1}],"cardDraft":{"kind":"grammar","headword":"～たことがある","reading":"","meaningZH":"曾经……过","partOfSpeech":"","usage":"表示过去经历","connection":"动词た形＋ことがある","notes":""}},{"kind":"expression","surface":"未对齐项目","canonicalForm":"未对齐项目","reading":"","meaningZH":"即使定位失败，解释仍然可读","roleZH":"验证安全降级","spans":[{"text":"存在しない","occurrence":1}],"cardDraft":null}],"warnings":["请核对语境后再用于学习"]}"#
    }
}
#endif
