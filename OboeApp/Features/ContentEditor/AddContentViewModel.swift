import Observation
import OboeDomain
import SwiftUI
import UIKit

enum AddContentKind: String, CaseIterable, Identifiable {
    case vocabulary
    case grammar
    case sentenceAnalysis = "sentence_analysis"

    var id: Self { self }
    var title: String {
        switch self {
        case .vocabulary: "单词"
        case .grammar: "语法"
        case .sentenceAnalysis: "句子分析"
        }
    }
    var draftStatusIdentifier: String { "\(rawValue)-draft-status" }
    var formalSaveIdentifier: String { "\(rawValue)-formal-save-button" }
    var clearDraftIdentifier: String { "\(rawValue)-clear-draft-button" }
    var saveDraftIdentifier: String { "\(rawValue)-save-draft-button" }
}

struct DuplicateQuery: Hashable {
    let kind: AddContentKind
    let headword: String
    let reading: String
}

/// An in-progress capture-processing session handed to the editor. Drafts load
/// and persist through the processing context (by ID) instead of the global
/// latest-draft slots; formal save stays disabled until the atomic commit +
/// receipt path lands.
struct CaptureEditorSession {
    let inboxService: InboxService
    let inboxItemID: UUID
    var context: InboxProcessingContext
    var payload: CaptureResumePayload?
    var isAnalysisStale: Bool
    /// S07：条目来源事实（sourceType/图片/URL/app）——构建 sourceContextDraft
    /// 用；老测试未传时按 nil 处理（来源区退化为无）。
    var item: InboxItem?
}

@MainActor
@Observable
final class AddContentViewModel {
    let deckService: DeckManagementService
    let vocabularyService: VocabularyService
    let grammarService: GrammarService
    let knowledgePointService: KnowledgePointService
    let contentCardService: ContentCardService
    let aiCardGenerationService: AICardGenerationService
    let sentenceAnalysisService: SentenceAnalysisService
    let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    let studyService: StudySessionService?
    private var didLoad = false

    /// PR3 split：页面对外状态拆进五个子对象，下列计算属性逐一转发，
    /// 视图与方法签名保持不变。
    let form = AddContentFormState()
    let aiSession = AddContentAISession()
    let analysisSession = SentenceAnalysisSession()
    let captureCoordinator: CaptureDraftCoordinator
    let commitCoordinator = AddContentCommitCoordinator()

    var kind = AddContentKind.vocabulary
    var decks: [DeckSummary] = []
    /// v0.5.5 牌组详情进入的添加流：该牌组是必选成员，不能被移除；
    /// home 默认为它（用户仍可把 home 切到其他成员）。
    let requiredDeckID: UUID?
    /// S07：词典预填存在时跳过单词草稿恢复（见 init / load()）。
    private let vocabularyPrefill: VocabularyFormData?
    /// S07：随预填/查词入口附带的来源草稿；提交时入 Note 事务，
    /// 取消/清草稿即丢弃，不落库。
    var sourceContextDraft: SourceContextDraft?
    /// S07：已有 Note 加牌组时的来源落库通道；nil（旧测试构造）时
    /// 跳过来源保存，成员关系不受影响。
    let sourceContextRepository: (any SourceContextRepository)?

    /// S07 编辑器内查词选中词条：表单按词条预填（覆盖当前表单值），
    /// 来源草稿在既有 lookup 事实（OCR 原句/图片等）上叠词典快照。
    func applyDictionaryPrefill(
        _ entry: DictionaryEntry,
        datasetVersion: String?
    ) {
        vocabularyForm = DictionaryCardPrefill.vocabularyForm(from: entry)
        sourceContextDraft = DictionaryCardPrefill.sourceContextDraft(
            from: entry,
            datasetVersion: datasetVersion,
            lookup: sourceContextDraft
        )
        persistCaptureResume()
    }
    var errorMessage: String?
    var isLoading = true

    // MARK: - 表单状态（AddContentFormState）

    var vocabularyDeckID: UUID? {
        get { form.vocabularyDeckID }
        set { form.vocabularyDeckID = newValue }
    }
    /// 归属（home）牌组；`vocabularyDeckIDs` 为全部成员牌组，始终包含 home。
    var vocabularyDeckIDs: Set<UUID> {
        get { form.vocabularyDeckIDs }
        set { form.vocabularyDeckIDs = newValue }
    }
    var vocabularyForm: VocabularyFormData {
        get { form.vocabularyForm }
        set { form.vocabularyForm = newValue }
    }
    var vocabularyDraftID: UUID? {
        get { form.vocabularyDraftID }
        set { form.vocabularyDraftID = newValue }
    }
    var vocabularyStatusMessage: String? {
        get { form.vocabularyStatusMessage }
        set { form.vocabularyStatusMessage = newValue }
    }
    var grammarDeckID: UUID? {
        get { form.grammarDeckID }
        set { form.grammarDeckID = newValue }
    }
    var grammarDeckIDs: Set<UUID> {
        get { form.grammarDeckIDs }
        set { form.grammarDeckIDs = newValue }
    }
    var grammarForm: GrammarFormData {
        get { form.grammarForm }
        set { form.grammarForm = newValue }
    }
    var grammarDraftID: UUID? {
        get { form.grammarDraftID }
        set { form.grammarDraftID = newValue }
    }
    var grammarStatusMessage: String? {
        get { form.grammarStatusMessage }
        set { form.grammarStatusMessage = newValue }
    }
    var vocabularyTagsText: String {
        get { form.vocabularyTagsText }
        set { form.vocabularyTagsText = newValue }
    }
    var grammarTagsText: String {
        get { form.grammarTagsText }
        set { form.grammarTagsText = newValue }
    }
    /// 建卡不再有方向选择（v0.4 按词计额度）：词汇固定三方向、语法固定单
    /// 方向，全部默认开启；既有单词的方向管理仍在笔记详情页。
    var grammarFormToExplanation: Bool {
        get { form.grammarFormToExplanation }
        set { form.grammarFormToExplanation = newValue }
    }
    var sentenceAnalysisDeckID: UUID? {
        get { form.sentenceAnalysisDeckID }
        set { form.sentenceAnalysisDeckID = newValue }
    }
    var sentenceAnalysisDeckIDs: Set<UUID> {
        get { form.sentenceAnalysisDeckIDs }
        set { form.sentenceAnalysisDeckIDs = newValue }
    }
    /// 当前主牌组（`load` 时读取）：新选择默认把主牌组作为 home。
    var primaryDeckID: UUID? {
        get { form.primaryDeckID }
        set { form.primaryDeckID = newValue }
    }

    // MARK: - AI 生成会话（AddContentAISession）

    var vocabularyAIInput: String {
        get { aiSession.vocabularyAIInput }
        set { aiSession.vocabularyAIInput = newValue }
    }
    var vocabularyAIContext: String {
        get { aiSession.vocabularyAIContext }
        set { aiSession.vocabularyAIContext = newValue }
    }
    var grammarAIInput: String {
        get { aiSession.grammarAIInput }
        set { aiSession.grammarAIInput = newValue }
    }
    var grammarAIContext: String {
        get { aiSession.grammarAIContext }
        set { aiSession.grammarAIContext = newValue }
    }
    var generatedCandidate: AICardDraftCandidate? {
        get { aiSession.generatedCandidate }
        set { aiSession.generatedCandidate = newValue }
    }
    var aiGenerationStatusMessage: String? {
        get { aiSession.aiGenerationStatusMessage }
        set { aiSession.aiGenerationStatusMessage = newValue }
    }
    var aiGenerationErrorMessage: String? {
        get { aiSession.aiGenerationErrorMessage }
        set { aiSession.aiGenerationErrorMessage = newValue }
    }
    var isGenerating: Bool {
        get { aiSession.isGenerating }
        set { aiSession.isGenerating = newValue }
    }
    var generationTask: Task<Void, Never>? {
        get { aiSession.generationTask }
        set { aiSession.generationTask = newValue }
    }
    var generationGate: AIGenerationRequestGate {
        get { aiSession.generationGate }
        set { aiSession.generationGate = newValue }
    }
    var nextInputVersion: Int {
        get { aiSession.nextInputVersion }
        set { aiSession.nextInputVersion = newValue }
    }

    // MARK: - 句子分析会话（SentenceAnalysisSession）

    var sentenceAnalysisInput: String {
        get { analysisSession.sentenceAnalysisInput }
        set { analysisSession.sentenceAnalysisInput = newValue }
    }
    var sentenceAnalysisResult: SentenceAnalysisResult? {
        get { analysisSession.sentenceAnalysisResult }
        set { analysisSession.sentenceAnalysisResult = newValue }
    }
    var sentenceAnalysisDraftID: UUID? {
        get { analysisSession.sentenceAnalysisDraftID }
        set { analysisSession.sentenceAnalysisDraftID = newValue }
    }
    var sentenceAnalysisProviderID: String? {
        get { analysisSession.sentenceAnalysisProviderID }
        set { analysisSession.sentenceAnalysisProviderID = newValue }
    }
    var sentenceAnalysisModelID: String? {
        get { analysisSession.sentenceAnalysisModelID }
        set { analysisSession.sentenceAnalysisModelID = newValue }
    }
    var sentenceAnalysisStatusMessage: String? {
        get { analysisSession.sentenceAnalysisStatusMessage }
        set { analysisSession.sentenceAnalysisStatusMessage = newValue }
    }
    var sentenceAnalysisDraftStatusMessage: String? {
        get { analysisSession.sentenceAnalysisDraftStatusMessage }
        set { analysisSession.sentenceAnalysisDraftStatusMessage = newValue }
    }
    var sentenceAnalysisErrorMessage: String? {
        get { analysisSession.sentenceAnalysisErrorMessage }
        set { analysisSession.sentenceAnalysisErrorMessage = newValue }
    }
    var isAnalyzingSentence: Bool {
        get { analysisSession.isAnalyzingSentence }
        set { analysisSession.isAnalyzingSentence = newValue }
    }
    var selectedSentenceAnalysisItemIDs: Set<UUID> {
        get { analysisSession.selectedSentenceAnalysisItemIDs }
        set { analysisSession.selectedSentenceAnalysisItemIDs = newValue }
    }
    var sentenceCardDrafts: [SentenceAnalysisCardDraft] {
        get { analysisSession.sentenceCardDrafts }
        set { analysisSession.sentenceCardDrafts = newValue }
    }
    var sentenceCardDuplicates: [UUID: [KnowledgePointSummary]] {
        get { analysisSession.sentenceCardDuplicates }
        set { analysisSession.sentenceCardDuplicates = newValue }
    }
    var sentenceCardStatusMessage: String? {
        get { analysisSession.sentenceCardStatusMessage }
        set { analysisSession.sentenceCardStatusMessage = newValue }
    }
    var sentenceAnalysisTask: Task<Void, Never>? {
        get { analysisSession.sentenceAnalysisTask }
        set { analysisSession.sentenceAnalysisTask = newValue }
    }
    var sentenceAnalysisGate: AIGenerationRequestGate {
        get { analysisSession.sentenceAnalysisGate }
        set { analysisSession.sentenceAnalysisGate = newValue }
    }
    var nextSentenceInputVersion: Int {
        get { analysisSession.nextSentenceInputVersion }
        set { analysisSession.nextSentenceInputVersion = newValue }
    }
    var isRestoringSentenceDraft: Bool {
        get { analysisSession.isRestoringSentenceDraft }
        set { analysisSession.isRestoringSentenceDraft = newValue }
    }

    // MARK: - Capture 续编（CaptureDraftCoordinator）

    var captureSession: CaptureEditorSession? {
        get { captureCoordinator.captureSession }
        set { captureCoordinator.captureSession = newValue }
    }
    /// true when the capture session runs in manual edit (直接加入学习) — the AI
    /// generation section is hidden until the user switches to assisted mode.
    var captureIsManualEdit: Bool {
        get { captureCoordinator.captureIsManualEdit }
        set { captureCoordinator.captureIsManualEdit = newValue }
    }
    var captureStaleNotice: String? {
        get { captureCoordinator.captureStaleNotice }
        set { captureCoordinator.captureStaleNotice = newValue }
    }
    var inboxService: InboxService? {
        captureCoordinator.inboxService
    }

    // MARK: - 提交（AddContentCommitCoordinator）

    var isSaving: Bool {
        get { commitCoordinator.isSaving }
        set { commitCoordinator.isSaving = newValue }
    }
    var isCommitting: Bool {
        get { commitCoordinator.isCommitting }
        set { commitCoordinator.isCommitting = newValue }
    }
    var duplicates: [KnowledgePointSummary] {
        get { commitCoordinator.duplicates }
        set { commitCoordinator.duplicates = newValue }
    }
    /// 「加入当前牌组」正在处理中的重复项：驱动行内禁用态并防重入，
    /// 重复点击只生效一次（幂等）。
    var joiningDuplicateNoteIDs: Set<UUID> {
        get { commitCoordinator.joiningDuplicateNoteIDs }
        set { commitCoordinator.joiningDuplicateNoteIDs = newValue }
    }

    init(
        deckService: DeckManagementService,
        vocabularyService: VocabularyService,
        grammarService: GrammarService,
        knowledgePointService: KnowledgePointService,
        contentCardService: ContentCardService,
        aiCardGenerationService: AICardGenerationService,
        sentenceAnalysisService: SentenceAnalysisService,
        sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService,
        studyService: StudySessionService? = nil,
        requiredDeckID: UUID? = nil,
        capture: CaptureEditorSession? = nil,
        /// S07 词典制卡预填：非 nil 时锁定单词表单为词条值，且不再
        /// 恢复「上次草稿」（用户的显式选择优先于陈旧草稿）。
        vocabularyPrefill: VocabularyFormData? = nil,
        /// S07：查词入口传入的来源草稿（OCR 原句/词典词条快照）。
        sourceContextDraft: SourceContextDraft? = nil,
        sourceContextRepository: (any SourceContextRepository)? = nil
    ) {
        self.deckService = deckService
        self.vocabularyService = vocabularyService
        self.grammarService = grammarService
        self.knowledgePointService = knowledgePointService
        self.contentCardService = contentCardService
        self.aiCardGenerationService = aiCardGenerationService
        self.sentenceAnalysisService = sentenceAnalysisService
        self.sentenceAnalysisCardCreationService = sentenceAnalysisCardCreationService
        self.studyService = studyService
        self.requiredDeckID = requiredDeckID
        captureCoordinator = CaptureDraftCoordinator(inboxService: capture?.inboxService)
        self.vocabularyPrefill = vocabularyPrefill
        self.sourceContextDraft = sourceContextDraft
        self.sourceContextRepository = sourceContextRepository
        captureSession = capture
        if let capture {
            captureIsManualEdit = capture.context.mode == .manualEdit
            kind = Self.kind(for: capture.context.mode)
        }
        if let vocabularyPrefill {
            kind = .vocabulary
            form.vocabularyForm = vocabularyPrefill
        }
    }

    func contentKindDidChange() {
        cancelGeneration(silently: true)
        cancelSentenceAnalysis(silently: true)
        generatedCandidate = nil
        aiGenerationStatusMessage = nil
        aiGenerationErrorMessage = nil
        persistCaptureMode()
        persistCaptureResume()
    }

    /// Switching the capture approach (AI 辅助 / 手动填写) for vocabulary and
    /// grammar kinds updates the persisted context mode.
    func captureApproachDidChange(manual: Bool) {
        guard isCaptureSession, captureIsManualEdit != manual else { return }
        captureIsManualEdit = manual
        cancelGeneration(silently: true)
        persistCaptureMode()
        persistCaptureResume()
    }

    func load() async {
        if didLoad {
            do {
                decks = try await deckService.fetchDecks()
                await loadPrimaryDeckID()
                normalizeMemberships()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        didLoad = true

        do {
            decks = try await deckService.fetchDecks()
            await loadPrimaryDeckID()
            if let captureSession {
                try await restoreCaptureSession(captureSession)
            } else {
                if vocabularyPrefill == nil {
                    try await restoreVocabularyDraft()
                }
                try await restoreGrammarDraft()
                try await restoreSentenceAnalysisDraft()
            }
            normalizeMemberships()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadPrimaryDeckID() async {
        guard let studyService else { return }
        do {
            primaryDeckID = try await studyService.loadLearningSettings(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            ).primaryDeckID
        } catch {
            primaryDeckID = nil
        }
    }

    /// 无牌组时的「创建牌组」入口：建好后刷新列表并归一化选择
    /// （新牌组自动成为默认成员）。
    func createDeck(named name: String) async -> Bool {
        do {
            _ = try await deckService.createDeck(named: name)
            decks = try await deckService.fetchDecks()
            normalizeMemberships()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
