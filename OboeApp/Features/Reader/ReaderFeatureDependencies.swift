import Foundation
import OboeDomain
import OboeInfrastructure
import SwiftUI

/// S10 Reader Feature 的窄依赖包。协议面只取 UI 层实际用到的方法，
/// ViewModel 测试用内存桩件即可跑通，不依赖 GRDB。
///
/// 装配方（AppFeatureContainerFactory）需要的一组具体类型：
/// `GRDBReaderRepository` / `LocalReaderFileStore` / `ReaderIngestService` /
/// `GRDBReaderCoverageService` / `GRDBVocabularyKnowledgeRepository` /
/// `NLJapaneseMorphologyService` ——extension 声明在本文件底部，
/// 协议成员与现有 public 方法一一对应，不改包内代码。
struct ReaderFeatureDependencies {
    let repository: any ReaderDocumentStore
    let fileStore: any ReaderFileStore
    let ingest: any ReaderImporting
    let coverage: (any ReaderCoverageProviding)?
    let morphology: (any JapaneseMorphologyService)?
    let tokenStates: (any ReaderTokenStateProvider)?
    /// S11 挖词闭环依赖包；nil = 装配缺席（词典资源缺失等）→
    /// token 点击降级为静默，不弹 Inspector。
    var mining: ReaderMiningDependencies?
    /// S24 缺原文重链服务：stage→hash 二段确认→稳定 ID 重建→
    /// 单事务提交。nil = 装配缺席 → 库页隐藏/拒绝重链入口。
    var relink: (any ReaderRelinking)?
    /// S24 恢复屏障闸门：导入/重链/覆盖率长任务登记点；nil
    /// （测试桩）→ 任务直接跑不登记。
    var workGate: RestorationWorkGate?
    /// v0.7.5 AI Study 依赖包（S12 Runner/store + S13 应用 + S09
    /// 候选打包器 + S10 resolver）；nil = 装配缺席 → 隐藏 AI
    /// 学习入口。
    var aiStudy: ReaderAIStudyDependencies?
}

/// v0.7.5 AI Study 的依赖包：UI 只消费窄面——准备/预览/确认经
/// `store` 读写 Job 证据链，`applier` 执行确认后的原子应用，
/// `candidatePlanner`/`resolver`/`aiConfiguration`/`credentialStore`
/// 供准备期建 Job 与 Runner 派发装配，`units` 支撑预览计数与
/// flag 状态。study deck 绑定走 `GRDBReaderStudyDeckService`
/// 静态面（v24），恢复屏障登记走 `workGate`。
struct ReaderAIStudyDependencies {
    /// Job/block/resolution/selection/receipt/cache 持久化（v25）。
    let store: GRDBAIStudyJobStore
    /// S13 应用事务（§4.3 receipt 幂等 + §11 物化接缝——词典
    /// 物化器已注入）。
    let applier: AIStudyApplyService
    /// S09 候选打包器：tokens+candidates → 定稿请求序列。
    let candidatePlanner: AIStudyCandidatePlanner
    /// S10 resolver client：request → 本地校验后结果。
    let resolver: AIStudyResolverClient
    /// AI 连接配置服务（sendRequest 装配读当前配置）。
    let aiConfiguration: AIConfigurationService
    /// 凭据仓（sendRequest 装配读 Key——只在发送时取，不缓存）。
    let credentialStore: any AICredentialStore
    /// unit 仓储（flag/链接/预览期 unit 归属计数）。
    let units: GRDBLearningUnitRepository
    /// 词典仓储（occurrence 物化与 sense 详情批量取）。
    let dictionary: any DictionaryRepository
    /// v0.7.5 S15 准备编排服务（预检/prepare/replan/预览/选择/
    /// 摘要）。`makeServices` 时形态分析/词典服务已就绪但容器
    /// 未完成——由 `readerWithEditorFactory` 合成注入；nil =
    /// 装配缺席（无形态分析）→ AI 入口隐藏。
    var preparation: AIStudyPreparationService?
    /// 摘要页「开始学习」目的地（牌组 id + 标题 → ReviewView）；
    /// 由容器层注入——Reader 依赖包不持有 ReviewView 的服务集。
    var studyDestination:
        (@MainActor (_ deckID: UUID, _ title: String) -> AnyView)?
    /// 摘要页「查看牌组」目的地（牌组详情）。
    var deckDestination: (@MainActor (_ deckID: UUID) -> AnyView)?
}

/// `ReaderDocumentStore` → `AIStudyPreparationService.ReaderSource`
/// 的三方法适配（仓库协议面更宽，此处只投影读取面）。
struct ReaderAIStudyDocumentSource: AIStudyPreparationService.ReaderSource {
    let store: any ReaderDocumentStore

    func fetchDocument(id: UUID) async throws -> ReaderDocumentMetadata? {
        try await store.fetchDocument(id: id)
    }
    func fetchChapters(documentID: UUID) async throws
        -> [ReaderChapterMetadata] {
        try await store.fetchChapters(documentID: documentID)
    }
    func fetchBlocks(documentID: UUID, chapterID: UUID) async throws
        -> [ReaderBlock] {
        try await store.fetchBlocks(
            documentID: documentID, chapterID: chapterID)
    }
}

/// S11 Inspector/挖词的依赖包：服务 + 牌组目录 + 世代快照 +
/// 编辑器装配。`generation` 是容器发布时的快照——请求携带它作
/// `expectedGeneration`，写事务内再对活世代源复核。
struct ReaderMiningDependencies {
    let service: ReaderMiningService
    /// 已知/忽略/重置写路径（S08 服务，事件+receipt 内置）。
    let knowledge: VocabularyKnowledgeService
    /// 目标牌组目录（home/追加牌组选择）。
    let decks: DeckManagementService
    /// 主牌组 id 提供器（默认挖词目标）；nil = 无主牌组概念。
    let primaryDeckIDProvider: (@Sendable () async -> UUID?)?
    /// 容器发布世代（`ReaderMiningRequest.expectedGeneration` 取值）。
    let generation: Int
    /// 「编辑后挖词」的编辑器装配闭包——shell 层在容器就绪后注入
    ///（捕获 Add 域服务集）；第二参为提交成功回调（编辑器词汇提交
    /// 成功后回传 noteID，Inspector 用它补 lexeme 关联）。nil 时
    /// Inspector 隐藏该入口。
    var editorFactory: (
        @MainActor (ReaderEditorDraft, @escaping @MainActor (UUID) -> Void)
            -> AnyView
    )?
}

/// 「编辑后挖词」交现有 `AddContentEditorView` 的载荷：预填表单 +
/// Reader 来源草稿 + 目标牌组 + 提交成功后的 lexeme 关联种子
/// （应用层 `onVocabularyCommitted` hook 消费——编辑器提交走自己的
/// 事务，关联只负责补 lexeme/Note 绑定，不重写来源）。
struct ReaderEditorDraft {
    let form: VocabularyFormData
    let source: SourceContextDraft
    let requiredDeckID: UUID?
    /// 提交成功后要建立的 lexeme 关联；nil = 不补关联。
    let association: Association?

    struct Association {
        let key: LexicalKey
        let seed: Lexeme
    }
}

// MARK: - 窄协议（测试桩件友好）

/// 列表/详情页用到的 Reader 持久化面。
protocol ReaderDocumentStore: Sendable {
    func fetchDocumentSummaries() async throws -> [ReaderDocumentMetadata]
    func fetchDocument(id: UUID) async throws -> ReaderDocumentMetadata?
    func fetchChapters(documentID: UUID) async throws -> [ReaderChapterMetadata]
    func fetchBlocks(documentID: UUID, chapterID: UUID) async throws -> [ReaderBlock]
    func savePosition(_ position: ReaderPosition) async throws
    func fetchPosition(documentID: UUID) async throws -> ReaderPosition?
    func addBookmark(_ bookmark: ReaderBookmark) async throws
    func removeBookmark(id: UUID) async throws
    func fetchBookmarks(documentID: UUID) async throws -> [ReaderBookmark]
    func deleteDocument(id: UUID) async throws
    func updateAvailability(id: UUID, availability: ReaderDocumentAvailability) async throws
    func fetchAssets(documentID: UUID) async throws -> [ReaderAssetRecord]
    func updateAssetState(documentID: UUID, relativePath: String, installState: ReaderAssetInstallState) async throws
    func registerAsset(documentID: UUID, relativePath: String, sourceSHA256: String, installState: ReaderAssetInstallState) async throws
    func touchLastOpened(id: UUID, at date: Date) async throws
    func updateProgress(id: UUID, basisPoints: Int) async throws
    func findDocumentByHash(sourceSHA256: String) async throws -> ReaderDocumentMetadata?
    func findDocumentsByCanonicalHash(_ canonicalTextHash: String) async throws -> [ReaderDocumentMetadata]
}

/// 导入入口（库页「导入文件/粘贴文本」共用）。
protocol ReaderImporting: Sendable {
    func importFile(
        fileURL: URL,
        format: ReaderDocumentFormat,
        encodingOverride: PlainTextEncoding?,
        limits: ReaderParserLimits,
        documentID: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ReaderImportResult

    func importPaste(
        _ text: String,
        limits: ReaderParserLimits,
        documentID: UUID,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ReaderImportResult
}

/// 覆盖率徽章数据口：先读既有快照（无快照的文档显示「未分析」），
/// 「计算覆盖率」动作走 analyze。
protocol ReaderCoverageProviding: Sendable {
    func documentSnapshot(
        documentID: UUID
    ) async throws -> GRDBReaderCoverageService.CoverageSnapshot?
    @discardableResult
    func analyze(documentID: UUID) async throws -> ReaderCoverageMetrics
}

/// S24 缺原文重链接口（库页 relink 入口）：hash 二段确认与稳定 ID
/// 重建都在 `ReaderRelinkService` 内；协议只为收窄签名给测试桩。
protocol ReaderRelinking: Sendable {
    @discardableResult
    func relink(
        documentID: UUID,
        preparedFileURL: URL,
        format: ReaderDocumentFormat?,
        encodingOverride: PlainTextEncoding?,
        limits: ReaderParserLimits,
        displayName: String?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ReaderRelinkOutcome
}

/// token 知识状态批量解析（渲染着色用）：lexicalKey → lexeme → state。
protocol ReaderTokenStateProvider: Sendable {
    func resolveLexemes(keys: [LexicalKey]) async throws -> [LexicalKey: Lexeme]
    func states(lexemeIDs: [UUID]) async throws -> [UUID: VocabularyKnowledgeState]
}

// MARK: - 编辑器装配（容器注入）

extension AppFeatureContainer {
    /// Reader 依赖 + 「编辑后挖词」装配：deps 在 `makeServices` 里构造
    /// 时容器尚未就绪，编辑器服务集只能在 shell 拿到容器后补注入
    /// （闭包捕获本容器——世代替换时整个 view tree 随 `.id(generation)`
    /// 重建，旧闭包随旧树销毁）。@MainActor：editorFactory 闭包只能
    /// 在 UI 线程成形——View.body 本就 MainActor 隔离，零额外约束。
    @MainActor var readerWithEditorFactory: ReaderFeatureDependencies {
        var deps = reader
        deps.mining?.editorFactory = { draft, onCommitted in
            AnyView(ReaderMiningEditorHost(
                draft: draft,
                container: self,
                onCommitted: onCommitted
            ))
        }
        // v0.7.5 S15：准备编排服务 + 摘要导航出口在此合成——
        // `AppFeatureContainerFactory` 只装配基础依赖包，不改动。
        // morphology 缺席（测试容器/精简装配）→ preparation 留 nil，
        // Reader 隐藏 AI 学习入口。
        if var ai = deps.aiStudy,
           let morphology = deps.morphology
                as? AIStudyPreparationService.MorphologySource {
            let jlptLibrary = decks.jlpt.libraryService
            ai.preparation = AIStudyPreparationService(
                pool: ai.store.databasePool,
                reader: ReaderAIStudyDocumentSource(
                    store: deps.repository),
                morphology: morphology,
                dictionary: ai.dictionary,
                jlptIndexProvider: {
                    // 内置 JLPT 词库全量行（5 级分页拉取）——
                    // 参考索引只读，不写用户内容。
                    var rows: [AIStudyJLPTReferenceIndex.Row] = []
                    for level in JLPTLevel.allCases {
                        var offset = 0
                        while true {
                            let page = try await jlptLibrary.vocabulary(
                                level: level, sort: .source,
                                offset: offset, limit: 500)
                            rows += page.items.map {
                                AIStudyJLPTReferenceIndex.Row(
                                    headword: $0.headword,
                                    reading: $0.reading,
                                    level: $0.level)
                            }
                            guard let next = page.nextOffset else {
                                break
                            }
                            offset = next
                        }
                    }
                    return AIStudyJLPTReferenceIndex(rows: rows)
                })
            let deckDeps = decks
            let shared = shared
            let queryService = dictionary.queryService
            ai.studyDestination = { deckID, title in
                AnyView(NavigationStack {
                    ReviewView(
                        service: deckDeps.studyService,
                        historyService: deckDeps.historyService,
                        speechPreferencesService:
                            deckDeps.speechPreferencesService,
                        adaptiveCardService: deckDeps.adaptiveCardService,
                        adaptivePreferencesService:
                            deckDeps.adaptivePreferencesService,
                        aiRepairService: deckDeps.aiRepairService,
                        deckService: deckDeps.deckService,
                        speechService: shared.speechService,
                        sourceContextRepository:
                            shared.sourceContextRepository,
                        inboxImageStore: shared.inboxImageStore,
                        customStudyRepository:
                            shared.customStudyRepository,
                        customStudyService: shared.customStudyService,
                        scope: StudyScope(deckID: deckID, title: title)
                    )
                })
            }
            ai.deckDestination = { deckID in
                AnyView(NavigationStack {
                    DeckDetailView(
                        deckID: deckID,
                        model: DeckListModel(
                            service: deckDeps.deckService,
                            studyService: deckDeps.studyService,
                            historyService: deckDeps.historyService),
                        deckService: deckDeps.deckService,
                        vocabularyService: deckDeps.vocabularyService,
                        grammarService: deckDeps.grammarService,
                        knowledgePointService:
                            deckDeps.knowledgePointService,
                        searchService: deckDeps.searchService,
                        contentCardService: deckDeps.contentCardService,
                        studyService: deckDeps.studyService,
                        historyService: deckDeps.historyService,
                        speechPreferencesService:
                            deckDeps.speechPreferencesService,
                        adaptiveCardService: deckDeps.adaptiveCardService,
                        adaptivePreferencesService:
                            deckDeps.adaptivePreferencesService,
                        aiRepairService: deckDeps.aiRepairService,
                        speechService: shared.speechService,
                        aiCardGenerationService:
                            deckDeps.aiCardGenerationService,
                        sentenceAnalysisService:
                            deckDeps.sentenceAnalysisService,
                        sentenceAnalysisCardCreationService:
                            deckDeps.sentenceAnalysisCardCreationService,
                        sourceContextRepository:
                            shared.sourceContextRepository,
                        clozeRepository: shared.clozeRepository,
                        inboxImageStore: shared.inboxImageStore,
                        dictionaryQueryService: queryService,
                        customStudyRepository:
                            shared.customStudyRepository,
                        customStudyService: shared.customStudyService
                    )
                })
            }
            deps.aiStudy = ai
        }
        return deps
    }
}

// MARK: - 具体类型适配（无扩展成员，仅协议声明）

extension GRDBReaderRepository: ReaderDocumentStore {}
extension ReaderIngestService: ReaderImporting {}
extension ReaderRelinkService: ReaderRelinking {}
extension GRDBReaderCoverageService: ReaderCoverageProviding {}
extension GRDBVocabularyKnowledgeRepository: ReaderTokenStateProvider {}
