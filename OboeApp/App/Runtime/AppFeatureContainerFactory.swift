import Foundation
import OboeDomain
import OboeInfrastructure

/// Feature 容器工厂（技术文档 §10）：在局部变量里把一整代数据库
/// 绑定服务构造完整后一次性返回——调用方（controller）只发布成功值，
/// UI 永远看不到半初始化状态。返回 nil 即构建失败（内置 JLPT 词库
/// 缺失），由调用方转入 `.failed`。
enum AppFeatureContainerFactory {

    /// 词库资源解析点：生产走 Bundle 查找，测试可注入缺失/错位路径
    /// 验证「服务构建失败 → .failed」边界，而不污染打包资源。
    static func resolveLibraryURL(
        override: URL? = nil
    ) -> URL? {
        if let override { return override }
        return Bundle.main.url(
            forResource: "jlpt-library",
            withExtension: "sqlite",
            subdirectory: "JLPT"
        ) ?? Bundle.main.url(forResource: "jlpt-library", withExtension: "sqlite")
    }

    /// 词典资源解析点（S06）：与 JLPT 相同的子目录优先查找。资源缺失
    /// 返回 nil——词典服务仍照常构造（懒打开），由查询期错误收敛，
    /// 不做 fatal（坏包只影响查词）。
    static func resolveDictionaryURL(
        override: URL? = nil
    ) -> URL? {
        if let override { return override }
        return Bundle.main.url(
            forResource: "japanese-dictionary",
            withExtension: "sqlite",
            subdirectory: "Dictionary"
        ) ?? Bundle.main.url(
            forResource: "japanese-dictionary",
            withExtension: "sqlite"
        )
    }

    static func makeServices(
        database: OboeDatabase,
        generation: Int,
        baseURL: URL,
        bootstrap: AppBootstrapEnvironment,
        adaptiveInvalidationCenter: AdaptiveInvalidationCenter,
        jlptLibraryURLOverride: URL? = nil,
        dictionaryURLOverride: URL? = nil
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
        let attachmentReferences = GRDBAttachmentReferenceRepository(database: database)
        let imageStore = AppBootstrapEnvironment.resolveInboxImageStore(baseURL: baseURL)
        let inbox = InboxService(
            repository: inboxRepository,
            onItemDeleted: { reference in
                // D09（设计 §6.3）：只删最后一个引用——Inbox 行已删，
                // 但 source_contexts 仍引用时文件必须保留。查询失败按
                // 保守策略跳过删除，留待下次孤儿 sweep。
                // Attachment cleanup is best-effort: the Inbox row is gone
                // either way, and a stray file is reclaimed by the next
                // orphan sweep rather than failing the delete.
                guard let stillReferenced = try? await attachmentReferences
                    .isReferenced(reference), !stillReferenced else { return }
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
        guard let libraryURL = resolveLibraryURL(override: jlptLibraryURLOverride),
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
        let studySessionService = makeStudySessionService(database: database)
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
        // S06：词典服务无条件构造——资源缺失/损坏在查询期抛错，
        // UI 收敛为「词典不可用」，不阻断其他 feature。
        let dictionaryQueryService = DictionaryQueryService(
            repository: GRDBDictionaryRepository(
                databaseURL: resolveDictionaryURL(override: dictionaryURLOverride)
                    ?? baseURL.appendingPathComponent(
                        "japanese-dictionary-missing.sqlite"
                    )
            ),
            deinflector: JapaneseDeinflector()
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
            studyService: studySessionService,
            dictionaryQueryService: dictionaryQueryService,
            sourceContextRepository: GRDBSourceContextRepository(
                database: database
            )
        )

        let customStudyRepository = GRDBCustomStudyRepository(
            database: database
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
                restorationPreparer: portableBackupRestorationPreparer,
                dictionaryQueryService: dictionaryQueryService
            ),
            shared: SharedFeatureDependencies(
                speechService: bootstrap.speechService,
                ocrService: bootstrap.ocrService,
                inboxImageStore: imageStore,
                sourceContextRepository: GRDBSourceContextRepository(
                    database: database
                ),
                customStudyRepository: customStudyRepository,
                customStudyService: CustomStudyService()
            ),
            dictionary: DictionaryFeatureDependencies(
                queryService: dictionaryQueryService
            )
        )
        let runtime = RuntimeServices(
            adaptiveCardService: adaptiveCardService,
            aiRepairService: aiRepairService,
            appearancePreferencesService: appearancePreferencesService,
            attachmentReferenceRepository: attachmentReferences,
            captureImportCoordinator: captureImportCoordinator,
            captureQueueStore: queueStore,
            inboxService: inbox,
            inboxImageStore: imageStore,
            jlptEnrichmentService: jlptEnrichmentService,
            customStudyRepository: customStudyRepository
        )
        return BuiltServices(container: container, runtime: runtime)
    }

    static func makeStudySessionService(
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
