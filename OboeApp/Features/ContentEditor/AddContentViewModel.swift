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
}

@MainActor
@Observable
final class AddContentViewModel {
    private let deckService: DeckManagementService
    private let vocabularyService: VocabularyService
    private let grammarService: GrammarService
    private let knowledgePointService: KnowledgePointService
    private let contentCardService: ContentCardService
    private let aiCardGenerationService: AICardGenerationService
    private let sentenceAnalysisService: SentenceAnalysisService
    private let sentenceAnalysisCardCreationService: SentenceAnalysisCardCreationService
    private let studyService: StudySessionService?
    private var didLoad = false
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationGate = AIGenerationRequestGate()
    @ObservationIgnored private var nextInputVersion = 0
    @ObservationIgnored private var sentenceAnalysisTask: Task<Void, Never>?
    @ObservationIgnored private var sentenceAnalysisGate = AIGenerationRequestGate()
    @ObservationIgnored private var nextSentenceInputVersion = 0
    @ObservationIgnored private var isRestoringSentenceDraft = false
    private let inboxService: InboxService?

    var kind = AddContentKind.vocabulary
    var captureSession: CaptureEditorSession?
    /// true when the capture session runs in manual edit (直接加入学习) — the AI
    /// generation section is hidden until the user switches to assisted mode.
    var captureIsManualEdit = false
    var captureStaleNotice: String?
    var decks: [DeckSummary] = []
    /// 归属（home）牌组；`vocabularyDeckIDs` 为全部成员牌组，始终包含 home。
    var vocabularyDeckID: UUID?
    var vocabularyDeckIDs: Set<UUID> = []
    var vocabularyForm = VocabularyFormData()
    var vocabularyDraftID: UUID?
    var vocabularyStatusMessage: String?
    var grammarDeckID: UUID?
    var grammarDeckIDs: Set<UUID> = []
    var grammarForm = GrammarFormData()
    var grammarDraftID: UUID?
    var grammarStatusMessage: String?
    var vocabularyTagsText = ""
    var grammarTagsText = ""
    /// 建卡不再有方向选择（v0.4 按词计额度）：词汇固定三方向、语法固定单
    /// 方向，全部默认开启；既有单词的方向管理仍在笔记详情页。
    var grammarFormToExplanation = true
    var vocabularyAIInput = ""
    var vocabularyAIContext = ""
    var grammarAIInput = ""
    var grammarAIContext = ""
    var generatedCandidate: AICardDraftCandidate?
    var aiGenerationStatusMessage: String?
    var aiGenerationErrorMessage: String?
    var isGenerating = false
    var sentenceAnalysisInput = ""
    var sentenceAnalysisResult: SentenceAnalysisResult?
    var sentenceAnalysisDraftID: UUID?
    var sentenceAnalysisProviderID: String?
    var sentenceAnalysisModelID: String?
    var sentenceAnalysisStatusMessage: String?
    var sentenceAnalysisDraftStatusMessage: String?
    var sentenceAnalysisErrorMessage: String?
    var isAnalyzingSentence = false
    var selectedSentenceAnalysisItemIDs = Set<UUID>()
    var sentenceCardDrafts: [SentenceAnalysisCardDraft] = []
    var sentenceCardDuplicates: [UUID: [KnowledgePointSummary]] = [:]
    var sentenceAnalysisDeckID: UUID?
    var sentenceAnalysisDeckIDs: Set<UUID> = []
    var sentenceCardStatusMessage: String?
    /// 当前主牌组（`load` 时读取）：新选择默认把主牌组作为 home。
    var primaryDeckID: UUID?
    /// v0.5.5 牌组详情进入的添加流：该牌组是必选成员，不能被移除；
    /// home 默认为它（用户仍可把 home 切到其他成员）。
    let requiredDeckID: UUID?
    var errorMessage: String?
    var isLoading = true
    var isSaving = false
    var isCommitting = false
    var duplicates: [KnowledgePointSummary] = []

    var currentStatusMessage: String? {
        switch kind {
        case .vocabulary: vocabularyStatusMessage
        case .grammar: grammarStatusMessage
        case .sentenceAnalysis: sentenceAnalysisDraftStatusMessage
        }
    }

    var hasCurrentDraft: Bool {
        switch kind {
        case .vocabulary: vocabularyDraftID != nil
        case .grammar: grammarDraftID != nil
        case .sentenceAnalysis: sentenceAnalysisDraftID != nil
        }
    }

    var duplicateQuery: DuplicateQuery {
        switch kind {
        case .vocabulary:
            DuplicateQuery(
                kind: kind,
                headword: vocabularyForm.headword,
                reading: vocabularyForm.reading
            )
        case .grammar:
            DuplicateQuery(kind: kind, headword: grammarForm.grammarForm, reading: "")
        case .sentenceAnalysis:
            DuplicateQuery(kind: kind, headword: "", reading: "")
        }
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
        capture: CaptureEditorSession? = nil
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
        inboxService = capture?.inboxService
        captureSession = capture
        if let capture {
            captureIsManualEdit = capture.context.mode == .manualEdit
            kind = Self.kind(for: capture.context.mode)
        }
    }

    var isCaptureSession: Bool { captureSession != nil }

    var captureMode: CaptureProcessingMode {
        switch kind {
        case .vocabulary:
            captureIsManualEdit ? .manualEdit : .vocabularyGeneration
        case .grammar:
            captureIsManualEdit ? .manualEdit : .grammarGeneration
        case .sentenceAnalysis:
            .sentenceAnalysis
        }
    }

    private static func kind(for mode: CaptureProcessingMode) -> AddContentKind {
        switch mode {
        case .vocabularyGeneration, .manualEdit: .vocabulary
        case .grammarGeneration: .grammar
        case .sentenceAnalysis: .sentenceAnalysis
        }
    }

    /// The source fragment currently being worked on, used to record the
    /// selection range inside the captured text when it survives verbatim.
    private var captureFragment: String {
        switch kind {
        case .vocabulary:
            captureIsManualEdit ? vocabularyForm.headword : vocabularyAIInput
        case .grammar:
            captureIsManualEdit ? grammarForm.grammarForm : grammarAIInput
        case .sentenceAnalysis:
            sentenceAnalysisInput
        }
    }

    private var captureTargetDeckID: UUID? {
        switch kind {
        case .vocabulary: vocabularyDeckID
        case .grammar: grammarDeckID
        case .sentenceAnalysis: sentenceAnalysisDeckID
        }
    }

    private var captureTargetDeckIDs: Set<UUID> {
        switch kind {
        case .vocabulary: vocabularyDeckIDs
        case .grammar: grammarDeckIDs
        case .sentenceAnalysis: sentenceAnalysisDeckIDs
        }
    }

    /// 当前类型的多牌组选择（home + 成员集合）。赋值时归一化并持久化
    /// 到 capture 续编载荷。
    var currentMembershipSelection: DeckMembershipSelection {
        get {
            switch kind {
            case .vocabulary:
                DeckMembershipSelection(
                    homeDeckID: vocabularyDeckID,
                    deckIDs: vocabularyDeckIDs
                )
            case .grammar:
                DeckMembershipSelection(
                    homeDeckID: grammarDeckID,
                    deckIDs: grammarDeckIDs
                )
            case .sentenceAnalysis:
                DeckMembershipSelection(
                    homeDeckID: sentenceAnalysisDeckID,
                    deckIDs: sentenceAnalysisDeckIDs
                )
            }
        }
        set {
            let normalized = newValue.normalized(
                decks: decks,
                preferredHomeID: primaryDeckID
            )
            applyMembership(enforcingRequiredDeck(normalized), for: kind)
            persistCaptureResume()
        }
    }

    /// 牌组详情进入时当前牌组不可移除：归一化后强制补回成员关系；
    /// home 为空时默认取当前牌组。
    private func enforcingRequiredDeck(
        _ selection: DeckMembershipSelection
    ) -> DeckMembershipSelection {
        guard let requiredDeckID,
              decks.contains(where: { $0.id == requiredDeckID }) else {
            return selection
        }
        var result = selection
        result.deckIDs.insert(requiredDeckID)
        if result.homeDeckID == nil {
            result.homeDeckID = requiredDeckID
        }
        return result
    }

    private func applyMembership(
        _ selection: DeckMembershipSelection,
        for kind: AddContentKind
    ) {
        switch kind {
        case .vocabulary:
            vocabularyDeckID = selection.homeDeckID
            vocabularyDeckIDs = selection.deckIDs
        case .grammar:
            grammarDeckID = selection.homeDeckID
            grammarDeckIDs = selection.deckIDs
        case .sentenceAnalysis:
            sentenceAnalysisDeckID = selection.homeDeckID
            sentenceAnalysisDeckIDs = selection.deckIDs
        }
    }

    /// 新建内容的默认选择：来源牌组（requiredDeckID）→ 主牌组 → 列表
    /// 首个牌组，依次回退。
    private func defaultMembership() -> DeckMembershipSelection {
        let preferred = requiredDeckID.flatMap { id in
            decks.contains(where: { $0.id == id }) ? id : nil
        } ?? primaryDeckID.flatMap { id in
            decks.contains(where: { $0.id == id }) ? id : nil
        } ?? decks.first?.id
        guard let fallback = preferred else {
            return DeckMembershipSelection()
        }
        return DeckMembershipSelection(single: fallback)
    }

    /// 牌组列表或选择集变化后调用：剔除失效牌组、补齐默认选择。
    private func normalizeMemberships() {
        for kind in AddContentKind.allCases {
            let current: DeckMembershipSelection
            switch kind {
            case .vocabulary:
                current = DeckMembershipSelection(
                    homeDeckID: vocabularyDeckID,
                    deckIDs: vocabularyDeckIDs
                )
            case .grammar:
                current = DeckMembershipSelection(
                    homeDeckID: grammarDeckID,
                    deckIDs: grammarDeckIDs
                )
            case .sentenceAnalysis:
                current = DeckMembershipSelection(
                    homeDeckID: sentenceAnalysisDeckID,
                    deckIDs: sentenceAnalysisDeckIDs
                )
            }
            var normalized = current.normalized(
                decks: decks,
                preferredHomeID: primaryDeckID
            )
            if normalized.deckIDs.isEmpty {
                normalized = defaultMembership()
            }
            applyMembership(enforcingRequiredDeck(normalized), for: kind)
        }
    }

    /// Hint shown when the fragment exceeds the current kind's AI input limit;
    /// the user must trim the selection instead of a silent cut. Manual-edit
    /// sessions hold user content (headword/grammar form), not AI input —
    /// their length is governed by form validation, not this limit.
    var captureInputLimitNotice: String? {
        guard isCaptureSession, !captureIsManualEdit else { return nil }
        let trimmed = captureFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .vocabulary, .grammar:
            guard trimmed.count > 200 else { return nil }
            return "片段超过 AI 输入上限（200 字），请删减后再生成。"
        case .sentenceAnalysis:
            guard trimmed.count > 1_000 else { return nil }
            return "片段超过分析上限（1,000 字），请删减后再分析。"
        }
    }

    /// 词汇固定创建全部三个方向。UI 测试可用
    /// `OBOE_UI_TEST_VOCABULARY_DIRECTIONS`（逗号分隔的 rawValue）收窄方向集，
    /// 以便只需少量卡片的复习机制测试保持确定性。
    var vocabularyDirections: Set<VocabularyCardDirection> {
        if let raw = ProcessInfo.processInfo.environment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] {
            let parsed = raw.split(separator: ",")
                .compactMap { VocabularyCardDirection(rawValue: String($0)) }
            if !parsed.isEmpty { return Set(parsed) }
        }
        return Set(VocabularyCardDirection.allCases)
    }

    var canCommit: Bool {
        guard !isLoading, !isSaving, !isCommitting else { return false }
        switch kind {
        case .vocabulary:
            return vocabularyDeckID.map({ vocabularyDeckIDs.contains($0) }) == true
                && (try? vocabularyForm.validatedContent()) != nil
                && tagsAreValid(vocabularyTagsText)
        case .grammar:
            return grammarDeckID.map({ grammarDeckIDs.contains($0) }) == true
                && (try? grammarForm.validatedContent()) != nil
                && tagsAreValid(grammarTagsText)
        case .sentenceAnalysis:
            return sentenceAnalysisDeckID.map({ sentenceAnalysisDeckIDs.contains($0) }) == true
                && !sentenceCardDraftsForCommit.isEmpty
                && (try? sentenceAnalysisCardCreationService.validate(
                    sentenceCardDraftsForCommit
                )) != nil
        }
    }

    var canGenerate: Bool {
        guard kind != .sentenceAnalysis, !isLoading, !isGenerating else { return false }
        return !currentAIInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canAnalyzeSentence: Bool {
        guard kind == .sentenceAnalysis, !isLoading, !isAnalyzingSentence else { return false }
        return (try? SentenceAnalysisDecoder.validated(
            SentenceAnalysisInput(sentence: sentenceAnalysisInput)
        )) != nil
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

    private func persistCaptureMode() {
        guard let capture = captureSession else { return }
        let mode = captureMode
        guard capture.context.mode != mode else { return }
        Task {
            do {
                captureSession?.context = try await capture.inboxService.beginProcessing(
                    itemID: capture.inboxItemID,
                    mode: mode
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Persists the versioned resume payload (selection range, deck, directions,
    /// chosen analysis items and their edits) so the session survives exit.
    func persistCaptureResume() {
        guard let capture = captureSession else { return }
        let payload = currentCapturePayload(
            pendingOperationID: capture.payload?.pendingOperationID
        )
        captureSession?.payload = payload
        Task {
            do {
                captureSession?.context = try await capture.inboxService.saveResumePayload(
                    inboxItemID: capture.inboxItemID,
                    payload: payload
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func currentCapturePayload(pendingOperationID: UUID?) -> CaptureResumePayload {
        CaptureResumePayload(
            selection: captureSelectionRange(),
            targetDeckID: captureTargetDeckID,
            targetDeckIDs: captureTargetDeckIDs,
            vocabularyDirections: vocabularyDirections,
            grammarFormToExplanation: grammarFormToExplanation,
            selectedAnalysisItemIDs: selectedSentenceAnalysisItemIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            editedCardDrafts: sentenceCardDrafts,
            analysisContentRevision: sentenceAnalysisResult == nil
                ? nil : captureSession?.context.contentRevision,
            pendingOperationID: pendingOperationID
        )
    }

    /// The idempotency key for the formal save: created once, persisted into the
    /// resume payload *before* the commit so a crash/lost-response retry replays
    /// the same operation and gets the stored receipt back instead of a second
    /// note.
    private func makeCaptureCommitContext() async throws -> CaptureCommitContext? {
        guard let capture = captureSession else { return nil }
        let operationID: UUID
        if let existing = capture.payload?.pendingOperationID {
            operationID = existing
        } else {
            operationID = UUID()
            let payload = currentCapturePayload(pendingOperationID: operationID)
            captureSession?.payload = payload
            captureSession?.context = try await capture.inboxService.saveResumePayload(
                inboxItemID: capture.inboxItemID,
                payload: payload
            )
        }
        return CaptureCommitContext(
            operationID: operationID,
            processingContextID: captureSession?.context.id,
            inboxItemID: capture.inboxItemID,
            expectedContentRevision: captureSession?.context.contentRevision
                ?? capture.context.contentRevision,
            sourceText: capture.context.inputText
        )
    }

    /// Capture commits record where the content came from: manual edit counts
    /// as manual input, assisted generation and sentence analysis count as AI.
    private var captureCommitOrigin: ContentOrigin {
        guard isCaptureSession else { return .manual }
        return captureIsManualEdit ? .manual : .ai
    }

    /// After a capture commit lands (item already transitioned to processed
    /// inside the same transaction), the pending operation is consumed.
    private func clearPendingCaptureOperation() {
        guard let capture = captureSession else { return }
        let payload = currentCapturePayload(pendingOperationID: nil)
        captureSession?.payload = payload
        Task {
            _ = try? await capture.inboxService.saveResumePayload(
                inboxItemID: capture.inboxItemID,
                payload: payload
            )
        }
    }

    private func captureSelectionRange() -> CaptureTextSelection? {
        guard let context = captureSession?.context else { return nil }
        let fragment = captureFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty,
              let range = context.inputText.range(of: fragment),
              let lower = range.lowerBound.samePosition(in: context.inputText.utf16),
              let upper = range.upperBound.samePosition(in: context.inputText.utf16) else {
            return nil
        }
        let offset = context.inputText.utf16.distance(
            from: context.inputText.utf16.startIndex,
            to: lower
        )
        return CaptureTextSelection(
            utf16Offset: offset,
            utf16Length: context.inputText.utf16.distance(from: lower, to: upper)
        )
    }

    /// Links the freshly saved draft to the processing context so resume finds
    /// it by ID and the normal latest-draft slot stays untouched.
    private func attachCaptureDraft(_ draftID: UUID) {
        guard let capture = captureSession else { return }
        Task {
            do {
                captureSession?.context = try await capture.inboxService.attachDraft(
                    inboxItemID: capture.inboxItemID,
                    draftID: draftID
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func detachCaptureDraft() {
        guard let capture = captureSession else { return }
        Task {
            do {
                captureSession?.context = try await capture.inboxService.attachDraft(
                    inboxItemID: capture.inboxItemID,
                    draftID: nil
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var sentenceCardDraftsForCommit: [SentenceAnalysisCardDraft] {
        sentenceCardDrafts.filter { draft in
            sentenceCardDuplicates[draft.id, default: []].isEmpty
                || draft.createDespiteDuplicate
        }
    }

    func sentenceCardDraftBinding(
        fallback: SentenceAnalysisCardDraft
    ) -> Binding<SentenceAnalysisCardDraft> {
        Binding(
            get: { [weak self] in
                self?.sentenceCardDrafts.first(where: { $0.id == fallback.id }) ?? fallback
            },
            set: { [weak self] updated in
                guard let self,
                      let index = sentenceCardDrafts.firstIndex(where: { $0.id == fallback.id })
                else { return }
                sentenceCardDrafts[index] = updated
            }
        )
    }

    func setSentenceCardSelection(itemID: UUID, selected: Bool) {
        guard let result = sentenceAnalysisResult else { return }
        guard selected != selectedSentenceAnalysisItemIDs.contains(itemID) else { return }
        if !selected {
            selectedSentenceAnalysisItemIDs.remove(itemID)
            sentenceCardDrafts.removeAll { $0.id == itemID }
            sentenceCardDuplicates[itemID] = nil
            sentenceCardStatusMessage = nil
            persistCaptureResume()
            return
        }
        selectedSentenceAnalysisItemIDs.insert(itemID)
        do {
            let generated = try sentenceAnalysisCardCreationService.makeDrafts(
                from: result,
                selectedItemIDs: selectedSentenceAnalysisItemIDs
            )
            let current = Dictionary(uniqueKeysWithValues: sentenceCardDrafts.map { ($0.id, $0) })
            sentenceCardDrafts = generated.map { current[$0.id] ?? $0 }
            sentenceCardStatusMessage = "已选择 \(sentenceCardDrafts.count) 项；转换未发起新的 AI 请求。"
            Task { await checkSentenceCardDuplicate(itemID: itemID, immediately: true) }
            persistCaptureResume()
        } catch {
            selectedSentenceAnalysisItemIDs.remove(itemID)
            errorMessage = error.localizedDescription
        }
    }

    func checkSentenceCardDuplicate(itemID: UUID, immediately: Bool = false) async {
        guard let draft = sentenceCardDrafts.first(where: { $0.id == itemID }) else { return }
        let kind = draft.kind
        let headword = draft.headword
        let reading = draft.reading
        do {
            if !immediately {
                try await Task.sleep(for: .milliseconds(250))
            }
            let matches = try await knowledgePointService.fetchDuplicates(
                kind: kind,
                headword: headword,
                reading: reading
            )
            guard let current = sentenceCardDrafts.first(where: { $0.id == itemID }),
                  current.kind == kind,
                  current.headword == headword,
                  current.reading == reading else { return }
            sentenceCardDuplicates[itemID] = matches
        } catch is CancellationError {
            // A later edit supersedes this local lookup.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sentenceCardDraftDidChange(itemID: UUID) {
        sentenceCardStatusMessage = nil
        Task { await checkSentenceCardDuplicate(itemID: itemID) }
    }

    func commitSentenceCards() async {
        guard kind == .sentenceAnalysis, canCommit else { return }
        isCommitting = true
        defer { isCommitting = false }
        do {
            let capture = try await makeCaptureCommitContext()
            let drafts = sentenceCardDraftsForCommit
            let result = try await sentenceAnalysisCardCreationService.commit(
                deckID: sentenceAnalysisDeckID,
                deckIDs: sentenceAnalysisDeckIDs,
                drafts: drafts,
                capture: capture
            )
            let savedIDs = Set(drafts.map(\.id))
            selectedSentenceAnalysisItemIDs.subtract(savedIDs)
            sentenceCardDrafts.removeAll { savedIDs.contains($0.id) }
            for id in savedIDs {
                sentenceCardDuplicates[id] = nil
            }
            sentenceCardStatusMessage = "已原子保存 \(result.noteIDs.count) 个知识点，生成 \(result.cardCount) 张卡片。"
            clearPendingCaptureOperation()
        } catch {
            errorMessage = Self.commitMessage(for: error)
        }
    }

    private func resetSentenceCardSelection() {
        selectedSentenceAnalysisItemIDs = []
        sentenceCardDrafts = []
        sentenceCardDuplicates = [:]
        sentenceCardStatusMessage = nil
    }

    func startGeneration() {
        guard kind != .sentenceAnalysis, canGenerate else { return }
        nextInputVersion += 1
        let requestID = UUID()
        let input = AICardGenerationInput(
            requestID: requestID,
            inputVersion: nextInputVersion,
            kind: kind == .vocabulary ? .vocabulary : .grammar,
            text: currentAIInput,
            context: currentAIContext
        )
        do {
            _ = try AICardOutputDecoder.validated(input)
        } catch {
            aiGenerationErrorMessage = error.localizedDescription
            return
        }

        generationTask?.cancel()
        generationGate.begin(requestID)
        isGenerating = true
        aiGenerationStatusMessage = nil
        aiGenerationErrorMessage = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate = try await aiCardGenerationService.generate(
                    input,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                guard generationGate.finish(requestID) else { return }
                generatedCandidate = candidate
                aiGenerationStatusMessage = "已生成独立候选；当前表单尚未改变。"
                isGenerating = false
                generationTask = nil
            } catch {
                guard generationGate.finish(requestID) else { return }
                isGenerating = false
                generationTask = nil
                if error is CancellationError || error as? AIConnectionError == .cancelled {
                    aiGenerationStatusMessage = "生成已取消，原始输入已保留。"
                } else {
                    aiGenerationErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelGeneration(silently: Bool = false) {
        guard isGenerating || generationTask != nil else { return }
        generationTask?.cancel()
        generationTask = nil
        generationGate.cancel()
        isGenerating = false
        if !silently {
            aiGenerationStatusMessage = "生成已取消，原始输入已保留。"
        }
    }

    func sentenceAnalysisInputDidChange() {
        guard !isRestoringSentenceDraft else { return }
        if isAnalyzingSentence {
            cancelSentenceAnalysis(silently: true)
            sentenceAnalysisStatusMessage = "输入已改变，旧请求已取消。"
        }
        let currentSentence = sentenceAnalysisInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let result = sentenceAnalysisResult, result.sentence != currentSentence {
            sentenceAnalysisResult = nil
            sentenceAnalysisProviderID = nil
            sentenceAnalysisModelID = nil
            resetSentenceCardSelection()
            sentenceAnalysisStatusMessage = "输入已修改，请重新分析。"
        }
        sentenceAnalysisErrorMessage = nil
    }

    func startSentenceAnalysis() {
        guard canAnalyzeSentence else { return }
        nextSentenceInputVersion += 1
        let requestID = UUID()
        let input: SentenceAnalysisInput
        do {
            input = try SentenceAnalysisDecoder.validated(
                SentenceAnalysisInput(
                    requestID: requestID,
                    inputVersion: nextSentenceInputVersion,
                    sentence: sentenceAnalysisInput
                )
            )
        } catch {
            sentenceAnalysisErrorMessage = error.localizedDescription
            return
        }

        sentenceAnalysisTask?.cancel()
        sentenceAnalysisGate.begin(requestID)
        isAnalyzingSentence = true
        sentenceAnalysisStatusMessage = nil
        sentenceAnalysisErrorMessage = nil
        sentenceAnalysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate = try await sentenceAnalysisService.analyze(
                    input,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                guard sentenceAnalysisGate.finish(requestID) else { return }
                isAnalyzingSentence = false
                sentenceAnalysisTask = nil
                sentenceAnalysisResult = candidate.result
                sentenceAnalysisProviderID = candidate.providerID
                sentenceAnalysisModelID = candidate.modelID
                resetSentenceCardSelection()
                sentenceAnalysisStatusMessage = "分析完成；原文定位已在本机核验。"
                do {
                    let draft = try await sentenceAnalysisService.saveDraft(
                        id: sentenceAnalysisDraftID,
                        sentence: input.sentence,
                        result: candidate.result,
                        providerID: candidate.providerID,
                        modelID: candidate.modelID
                    )
                    sentenceAnalysisDraftID = draft.id
                    attachCaptureDraft(draft.id)
                    sentenceAnalysisDraftStatusMessage = "分析结果已保存为本地草稿"
                } catch {
                    sentenceAnalysisErrorMessage = "分析完成，但无法保存草稿：\(error.localizedDescription)"
                }
                persistCaptureResume()
            } catch {
                guard sentenceAnalysisGate.finish(requestID) else { return }
                isAnalyzingSentence = false
                sentenceAnalysisTask = nil
                if error is CancellationError || error as? AIConnectionError == .cancelled {
                    sentenceAnalysisStatusMessage = "分析已取消，原始输入已保留。"
                } else {
                    sentenceAnalysisErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelSentenceAnalysis(silently: Bool = false) {
        guard isAnalyzingSentence || sentenceAnalysisTask != nil else { return }
        sentenceAnalysisTask?.cancel()
        sentenceAnalysisTask = nil
        sentenceAnalysisGate.cancel()
        isAnalyzingSentence = false
        if !silently {
            sentenceAnalysisStatusMessage = "分析已取消，原始输入已保留。"
        }
    }

    func continueManually() {
        aiGenerationErrorMessage = nil
        aiGenerationStatusMessage = "可继续在下方手动填写；AI 输入仍已保留。"
    }

    func applyGeneratedCandidate() async -> Bool {
        guard let candidate = generatedCandidate, !isSaving, !isCommitting else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            switch candidate.payload {
            case let .vocabulary(form):
                guard kind == .vocabulary else { return false }
                vocabularyForm = form
                let draft = try await vocabularyService.saveDraft(
                    id: vocabularyDraftID,
                    deckID: vocabularyDeckID,
                    deckIDs: vocabularyDeckIDs,
                    formData: form
                )
                vocabularyDraftID = draft.id
                attachCaptureDraft(draft.id)
                vocabularyStatusMessage = "AI 候选已采用并保存为本地草稿"
            case let .grammar(form):
                guard kind == .grammar else { return false }
                grammarForm = form
                let draft = try await grammarService.saveDraft(
                    id: grammarDraftID,
                    deckID: grammarDeckID,
                    deckIDs: grammarDeckIDs,
                    formData: form
                )
                grammarDraftID = draft.id
                attachCaptureDraft(draft.id)
                grammarStatusMessage = "AI 候选已采用并保存为本地草稿"
            }
            generatedCandidate = nil
            aiGenerationStatusMessage = "已采用候选；请继续核对、修改并确认正式保存。"
            aiGenerationErrorMessage = nil
            persistCaptureResume()
            return true
        } catch {
            aiGenerationErrorMessage = "无法保存 AI 草稿：\(error.localizedDescription)"
            return false
        }
    }

    private var currentAIInput: String {
        switch kind {
        case .vocabulary: vocabularyAIInput
        case .grammar: grammarAIInput
        case .sentenceAnalysis: sentenceAnalysisInput
        }
    }

    private var currentAIContext: String {
        switch kind {
        case .vocabulary: vocabularyAIContext
        case .grammar: grammarAIContext
        case .sentenceAnalysis: ""
        }
    }

    var commitAvailabilityMessage: String {
        if decks.isEmpty { return "请先在牌组页创建目标牌组。" }
        return "确认后会原子保存正文、例句、标签和卡片（词汇固定生成全部三个方向）；卡片暂不提供评分或下次复习时间。"
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
                try await restoreVocabularyDraft()
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

    /// Restores a capture session: the linked draft by ID (never the global
    /// latest slot), payload-level user choices, or a fresh fragment prefill.
    /// Stale analysis data is dropped with a visible notice.
    private func restoreCaptureSession(_ session: CaptureEditorSession) async throws {
        let context = session.context
        if let payload = session.payload {
            // 方向不再可选：忽略旧草稿载荷中的方向子集，固定全部方向。
            grammarFormToExplanation = true
            applyCaptureDeckSelection(
                homeDeckID: payload.targetDeckID,
                deckIDs: payload.targetDeckIDs
            )
        }
        normalizeMemberships()

        if session.isAnalysisStale {
            captureStaleNotice = "原文已修改，之前的分析结果已失效，请重新分析。"
            prefillCaptureFragment(context.inputText)
            return
        }

        if let draftID = context.draftID,
           try await restoreCaptureDraft(id: draftID) {
            if kind == .sentenceAnalysis, let payload = session.payload {
                restoreSentenceSelection(from: payload)
            }
            return
        }
        prefillCaptureFragment(captureFragmentText(from: session) ?? context.inputText)
    }

    /// 恢复续编载荷中的牌组选择：已删除的牌组被剔除，home 不在成员中时
    /// 回退主牌组或首个有效成员；载荷为空则保持现状由归一化补默认值。
    private func applyCaptureDeckSelection(homeDeckID: UUID?, deckIDs: Set<UUID>) {
        let selection = DeckMembershipSelection(
            homeDeckID: homeDeckID,
            deckIDs: deckIDs
        ).normalized(decks: decks, preferredHomeID: primaryDeckID)
        let enforced = enforcingRequiredDeck(selection)
        guard !enforced.deckIDs.isEmpty else { return }
        applyMembership(enforced, for: kind)
    }

    /// The fragment recorded as a UTF-16 selection range inside the captured
    /// text, when it still survives verbatim.
    private func captureFragmentText(from session: CaptureEditorSession) -> String? {
        guard let selection = session.payload?.selection else { return nil }
        let text = session.context.inputText
        guard let start = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: selection.utf16Offset,
            limitedBy: text.utf16.endIndex
        ), let end = text.utf16.index(
            start,
            offsetBy: selection.utf16Length,
            limitedBy: text.utf16.endIndex
        ), let fragment = String(text.utf16[start..<end]) else { return nil }
        return fragment
    }

    private func prefillCaptureFragment(_ fragment: String) {
        switch kind {
        case .vocabulary:
            if captureIsManualEdit {
                vocabularyForm.headword = fragment
            } else {
                vocabularyAIInput = fragment
            }
        case .grammar:
            if captureIsManualEdit {
                grammarForm.grammarForm = fragment
            } else {
                grammarAIInput = fragment
            }
        case .sentenceAnalysis:
            sentenceAnalysisInput = fragment
        }
    }

    /// Loads the context-linked draft by ID. Returns false when the link is
    /// stale (draft deleted) or the kind does not match; manual-edit sessions
    /// may point at either a vocabulary or a grammar draft.
    private func restoreCaptureDraft(id: UUID) async throws -> Bool {
        switch kind {
        case .vocabulary:
            if let draft = try await vocabularyService.fetchDraft(id: id) {
                vocabularyDraftID = draft.id
                restoreDeckSelection(draft.deckID, draft.deckIDs, for: .vocabulary)
                vocabularyForm = draft.formData
                vocabularyStatusMessage = "已恢复处理中的草稿"
                return true
            }
            if captureIsManualEdit,
               let draft = try await grammarService.fetchDraft(id: id) {
                kind = .grammar
                grammarDraftID = draft.id
                restoreDeckSelection(draft.deckID, draft.deckIDs, for: .grammar)
                grammarForm = draft.formData
                grammarStatusMessage = "已恢复处理中的草稿"
                return true
            }
            return false
        case .grammar:
            guard let draft = try await grammarService.fetchDraft(id: id) else { return false }
            grammarDraftID = draft.id
            restoreDeckSelection(draft.deckID, draft.deckIDs, for: .grammar)
            grammarForm = draft.formData
            grammarStatusMessage = "已恢复处理中的草稿"
            return true
        case .sentenceAnalysis:
            guard let draft = try await sentenceAnalysisService.fetchDraft(id: id) else {
                return false
            }
            isRestoringSentenceDraft = true
            sentenceAnalysisDraftID = draft.id
            sentenceAnalysisInput = draft.sentence
            sentenceAnalysisResult = draft.result
            sentenceAnalysisProviderID = draft.providerID
            sentenceAnalysisModelID = draft.modelID
            sentenceAnalysisDraftStatusMessage = "已恢复处理中的分析草稿"
            isRestoringSentenceDraft = false
            return true
        }
    }

    /// Re-selects persisted analysis items and overlays edited card drafts on
    /// top of freshly generated ones.
    private func restoreSentenceSelection(from payload: CaptureResumePayload) {
        guard let result = sentenceAnalysisResult else { return }
        let validIDs = Set(result.items.map(\.id))
        let selected = Set(payload.selectedAnalysisItemIDs).intersection(validIDs)
        guard !selected.isEmpty else { return }
        do {
            let generated = try sentenceAnalysisCardCreationService.makeDrafts(
                from: result,
                selectedItemIDs: selected
            )
            let edits = Dictionary(
                uniqueKeysWithValues: payload.editedCardDrafts.map { ($0.id, $0) }
            )
            sentenceCardDrafts = generated.map { edits[$0.id] ?? $0 }
            selectedSentenceAnalysisItemIDs = selected
            sentenceCardStatusMessage = "已恢复 \(sentenceCardDrafts.count) 项选择。"
            for draft in sentenceCardDrafts {
                Task { await checkSentenceCardDuplicate(itemID: draft.id, immediately: true) }
            }
        } catch {
            selectedSentenceAnalysisItemIDs = []
            sentenceCardDrafts = []
        }
    }

    func saveCurrentDraft() async {
        guard !isSaving else {
            return
        }
        isSaving = true
        defer { isSaving = false }

        do {
            switch kind {
            case .vocabulary:
                let draft = try await vocabularyService.saveDraft(
                    id: vocabularyDraftID,
                    deckID: vocabularyDeckID,
                    deckIDs: vocabularyDeckIDs,
                    formData: vocabularyForm
                )
                vocabularyDraftID = draft.id
                attachCaptureDraft(draft.id)
                vocabularyStatusMessage = "草稿已保存"
            case .grammar:
                let draft = try await grammarService.saveDraft(
                    id: grammarDraftID,
                    deckID: grammarDeckID,
                    deckIDs: grammarDeckIDs,
                    formData: grammarForm
                )
                grammarDraftID = draft.id
                attachCaptureDraft(draft.id)
                grammarStatusMessage = "草稿已保存"
            case .sentenceAnalysis:
                let currentSentence = sentenceAnalysisInput.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let result = sentenceAnalysisResult?.sentence == currentSentence
                    ? sentenceAnalysisResult
                    : nil
                let draft = try await sentenceAnalysisService.saveDraft(
                    id: sentenceAnalysisDraftID,
                    sentence: currentSentence,
                    result: result,
                    providerID: result == nil ? nil : sentenceAnalysisProviderID,
                    modelID: result == nil ? nil : sentenceAnalysisModelID
                )
                sentenceAnalysisDraftID = draft.id
                attachCaptureDraft(draft.id)
                sentenceAnalysisDraftStatusMessage = "分析草稿已保存"
            }
            persistCaptureResume()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearCurrentDraft() async {
        do {
            switch kind {
            case .vocabulary:
                guard let vocabularyDraftID else { return }
                try await vocabularyService.deleteDraft(id: vocabularyDraftID)
                self.vocabularyDraftID = nil
                detachCaptureDraft()
                vocabularyForm = VocabularyFormData()
                applyMembership(defaultMembership(), for: .vocabulary)
                vocabularyStatusMessage = "草稿已清除"
            case .grammar:
                guard let grammarDraftID else { return }
                try await grammarService.deleteDraft(id: grammarDraftID)
                self.grammarDraftID = nil
                detachCaptureDraft()
                grammarForm = GrammarFormData()
                applyMembership(defaultMembership(), for: .grammar)
                grammarStatusMessage = "草稿已清除"
            case .sentenceAnalysis:
                guard let sentenceAnalysisDraftID else { return }
                try await sentenceAnalysisService.deleteDraft(id: sentenceAnalysisDraftID)
                self.sentenceAnalysisDraftID = nil
                detachCaptureDraft()
                sentenceAnalysisInput = ""
                sentenceAnalysisResult = nil
                sentenceAnalysisProviderID = nil
                sentenceAnalysisModelID = nil
                resetSentenceCardSelection()
                sentenceAnalysisStatusMessage = nil
                sentenceAnalysisDraftStatusMessage = "分析草稿已清除"
            }
            persistCaptureResume()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func commitCurrentContent() async {
        guard canCommit else { return }
        isCommitting = true
        defer { isCommitting = false }

        do {
            let capture = try await makeCaptureCommitContext()
            let result: ContentCommitResult
            switch kind {
            case .vocabulary:
                result = try await contentCardService.commitVocabulary(
                    draftID: vocabularyDraftID,
                    deckID: vocabularyDeckID,
                    formData: vocabularyForm,
                    directions: vocabularyDirections,
                    rawTagNames: parsedTags(vocabularyTagsText),
                    origin: captureCommitOrigin,
                    capture: capture,
                    deckIDs: vocabularyDeckIDs
                )
                vocabularyDraftID = nil
                vocabularyForm = VocabularyFormData()
                vocabularyTagsText = ""
                vocabularyStatusMessage = "已正式保存，生成 \(result.cardCount) 张卡片"
            case .grammar:
                result = try await contentCardService.commitGrammar(
                    draftID: grammarDraftID,
                    deckID: grammarDeckID,
                    formData: grammarForm,
                    includesDirection: grammarFormToExplanation,
                    rawTagNames: parsedTags(grammarTagsText),
                    origin: captureCommitOrigin,
                    capture: capture,
                    deckIDs: grammarDeckIDs
                )
                grammarDraftID = nil
                grammarForm = GrammarFormData()
                grammarTagsText = ""
                grammarFormToExplanation = true
                grammarStatusMessage = "已正式保存，生成 \(result.cardCount) 张卡片"
            case .sentenceAnalysis:
                return
            }
            clearPendingCaptureOperation()
            duplicates = []
        } catch {
            errorMessage = Self.commitMessage(for: error)
        }
    }

    func checkDuplicates(immediately: Bool = false) async {
        let query = duplicateQuery
        guard !query.headword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            duplicates = []
            return
        }
        do {
            if !immediately {
                try await Task.sleep(for: .milliseconds(250))
            }
            let result = try await knowledgePointService.fetchDuplicates(
                kind: query.kind == .vocabulary ? .vocabulary : .grammar,
                headword: query.headword,
                reading: query.reading
            )
            guard query == duplicateQuery else { return }
            duplicates = result
        } catch is CancellationError {
            // A later field value supersedes this lookup.
        } catch {
            guard query == duplicateQuery else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 恢复草稿中的多牌组选择：过滤已删除牌组；草稿没有有效成员时不动
    /// 当前选择（由 `normalizeMemberships` 兜底默认值）。
    private func restoreDeckSelection(
        _ homeDeckID: UUID?,
        _ deckIDs: Set<UUID>,
        for kind: AddContentKind
    ) {
        let selection = DeckMembershipSelection(
            homeDeckID: homeDeckID,
            deckIDs: deckIDs
        ).normalized(decks: decks, preferredHomeID: primaryDeckID)
        let enforced = enforcingRequiredDeck(selection)
        guard !enforced.deckIDs.isEmpty else { return }
        applyMembership(enforced, for: kind)
    }

    private func restoreVocabularyDraft() async throws {
        if let draft = try await vocabularyService.fetchLatestDraft() {
            vocabularyDraftID = draft.id
            restoreDeckSelection(draft.deckID, draft.deckIDs, for: .vocabulary)
            vocabularyForm = draft.formData
            vocabularyStatusMessage = "已恢复上次草稿"
        }
    }

    private func restoreGrammarDraft() async throws {
        if let draft = try await grammarService.fetchLatestDraft() {
            grammarDraftID = draft.id
            restoreDeckSelection(draft.deckID, draft.deckIDs, for: .grammar)
            grammarForm = draft.formData
            grammarStatusMessage = "已恢复上次草稿"
        }
    }

    private func restoreSentenceAnalysisDraft() async throws {
        guard let draft = try await sentenceAnalysisService.fetchLatestDraft() else { return }
        isRestoringSentenceDraft = true
        sentenceAnalysisDraftID = draft.id
        sentenceAnalysisInput = draft.sentence
        sentenceAnalysisResult = draft.result
        sentenceAnalysisProviderID = draft.providerID
        sentenceAnalysisModelID = draft.modelID
        sentenceAnalysisDraftStatusMessage = "已恢复上次分析草稿"
        isRestoringSentenceDraft = false
    }

    private func parsedTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func tagsAreValid(_ text: String) -> Bool {
        parsedTags(text).allSatisfy { (try? KnowledgeTagName(validating: $0)) != nil }
    }

    private static func commitMessage(for error: Error) -> String {
        switch error {
        case ContentCardError.deckRequired:
            "请选择目标牌组。"
        case ContentCardError.cardDirectionRequired, VocabularyValidationError.cardDirectionRequired:
            "请至少选择一个卡片方向。"
        case ContentCardError.deckNotFound:
            "目标牌组已不存在，请重新选择。"
        case ContentCardError.knowledgePointNotFound:
            "知识点已不存在。"
        case ContentCardError.invalidTemplateForKnowledgePoint:
            "卡片方向与知识点类型不匹配。"
        case VocabularyValidationError.headwordRequired:
            "请填写日语词形。"
        case VocabularyValidationError.meaningRequired, GrammarValidationError.meaningRequired:
            "请填写中文释义。"
        case VocabularyValidationError.exampleJapaneseRequired,
             GrammarValidationError.exampleJapaneseRequired:
            "填写例句翻译时也需要日语例句。"
        case GrammarValidationError.grammarFormRequired:
            "请填写语法形式。"
        case InboxError.commitPayloadConflict:
            "本次提交的内容与已提交的不一致，请重新开始处理。"
        case InboxError.revisionConflict:
            "原文已被修改，请重新处理这条内容。"
        case InboxError.invalidStatusTransition:
            "这条内容的处理状态已变化，请返回列表刷新。"
        case InboxError.itemNotFound:
            "这条内容已不存在。"
        default:
            error.localizedDescription
        }
    }
}
