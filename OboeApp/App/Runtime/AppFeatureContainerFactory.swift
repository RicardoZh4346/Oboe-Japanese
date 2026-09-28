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
        /// S11 挖词世代屏障的活读源：恢复时控制器先 bump 世代再换库，
        /// 绑定旧代的服务在写事务内复核到这里的新值而拒写。
        generationSource: DatabaseGenerationSource,
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
        let dictionaryURL = resolveDictionaryURL(override: dictionaryURLOverride)
            ?? baseURL.appendingPathComponent(
                "japanese-dictionary-missing.sqlite"
            )
        let dictionaryRepository = GRDBDictionaryRepository(
            databaseURL: dictionaryURL
        )
        let dictionaryQueryService = DictionaryQueryService(
            repository: dictionaryRepository,
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
            ),
            clozeRepository: GRDBClozeRepository(database: database)
        )

        let customStudyRepository = GRDBCustomStudyRepository(
            database: database
        )

        // S10 Reader 装配：文件仓根目录 = App Support baseURL（内部再分
        // `ReaderFiles/` 与 `ReaderStaging/`）；形态/知识/覆盖率三件套
        // 依赖词典 sqlite——资源缺失时 resolver 懒打开在查询期抛错，
        // Reader 正文阅读不受影响（VM 里着色失败降级纯文本）。
        let readerRepository = GRDBReaderRepository(database: database)
        let readerFileStore = LocalReaderFileStore(baseDirectoryURL: baseURL)
        let readerIngest = ReaderIngestService(
            fileStore: readerFileStore,
            repository: readerRepository
        )
        // S24：恢复屏障闸门（每世代一只，单向关闭）+ 缺原文重链
        // 服务（stage→hash 二段确认→稳定 ID 重建→单事务提交）。
        let workGate = RestorationWorkGate()
        let readerRelinkService = ReaderRelinkService(
            fileStore: readerFileStore,
            repository: readerRepository,
            store: readerRepository
        )
        let morphologyService = NLJapaneseMorphologyService(
            resolver: GRDBMorphologyCandidateResolver(
                databaseURL: dictionaryURL
            )
        )
        let readerKnowledge = GRDBVocabularyKnowledgeRepository(
            pool: database.pool
        )
        let readerCoverage = GRDBReaderCoverageService(
            pool: database.pool,
            morphology: morphologyService,
            knowledge: readerKnowledge
        )
        // S11 挖词闭环：lookup 服务 + 原子写 store + 知识服务。
        // `currentGeneration` 读控制器持有的活世代盒——本批服务绑定的
        // 快照 `generation` 只做请求 expectedGeneration，写事务内与活
        // 值复核，恢复窗口内旧代请求被拒。
        let readerMiningService = ReaderMiningService(
            dictionary: dictionaryRepository,
            deinflector: JapaneseDeinflector(),
            knowledge: readerKnowledge,
            linking: readerKnowledge,
            store: GRDBReaderMiningStore(pool: database.pool),
            currentGeneration: { generationSource.value }
        )
        let readerKnowledgeService = VocabularyKnowledgeService(
            repository: readerKnowledge,
            linking: readerKnowledge
        )
        let miningDependencies = ReaderMiningDependencies(
            service: readerMiningService,
            knowledge: readerKnowledgeService,
            decks: deckManagementService,
            primaryDeckIDProvider: {
                try? await studySessionService.loadLearningSettings(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                ).primaryDeckID
            },
            generation: generation
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
                processingServices: processingServices,
                statisticsSource: AppStatisticsInsightSource(
                    statistics: GRDBStatisticsRepository(database: database),
                    insights: GRDBRetentionInsightRepository(database: database)
                ),
                readerAnalyticsSource: AppReaderAnalyticsSource(
                    repository: GRDBReaderAnalyticsRepository(
                        database: database)
                )
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
                dictionaryQueryService: dictionaryQueryService,
                database: database,
                deckService: deckManagementService,
                workGate: workGate
            ),
            shared: SharedFeatureDependencies(
                speechService: bootstrap.speechService,
                ocrService: bootstrap.ocrService,
                inboxImageStore: imageStore,
                sourceContextRepository: GRDBSourceContextRepository(
                    database: database
                ),
                clozeRepository: GRDBClozeRepository(database: database),
                customStudyRepository: customStudyRepository,
                customStudyService: CustomStudyService()
            ),
            dictionary: DictionaryFeatureDependencies(
                queryService: dictionaryQueryService
            ),
            reader: ReaderFeatureDependencies(
                repository: readerRepository,
                fileStore: readerFileStore,
                ingest: readerIngest,
                coverage: readerCoverage,
                morphology: morphologyService,
                tokenStates: readerKnowledge,
                mining: miningDependencies,
                relink: readerRelinkService,
                workGate: workGate
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
            customStudyRepository: customStudyRepository,
            workGate: workGate
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
