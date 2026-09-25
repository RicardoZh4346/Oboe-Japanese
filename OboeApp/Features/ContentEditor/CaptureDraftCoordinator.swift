import Observation
import OboeDomain
import SwiftUI

/// PR3 split: capture resume 与草稿附着/解除的会话状态，
/// 由 `AddContentViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class CaptureDraftCoordinator {
    var captureSession: CaptureEditorSession?
    /// true when the capture session runs in manual edit (直接加入学习) — the AI
    /// generation section is hidden until the user switches to assisted mode.
    var captureIsManualEdit = false
    var captureStaleNotice: String?
    let inboxService: InboxService?

    init(inboxService: InboxService?) {
        self.inboxService = inboxService
    }
}

extension AddContentViewModel {
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

    static func kind(for mode: CaptureProcessingMode) -> AddContentKind {
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

    func persistCaptureMode() {
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
            pendingOperationID: pendingOperationID,
            sourceDraft: sourceContextDraft
        )
    }

    /// The idempotency key for the formal save: created once, persisted into the
    /// resume payload *before* the commit so a crash/lost-response retry replays
    /// the same operation and gets the stored receipt back instead of a second
    /// note.
    func makeCaptureCommitContext() async throws -> CaptureCommitContext? {
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
    var captureCommitOrigin: ContentOrigin {
        guard isCaptureSession else { return .manual }
        return captureIsManualEdit ? .manual : .ai
    }

    /// After a capture commit lands (item already transitioned to processed
    /// inside the same transaction), the pending operation is consumed.
    func clearPendingCaptureOperation() {
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
    func attachCaptureDraft(_ draftID: UUID) {
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

    func detachCaptureDraft() {
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

    /// Restores a capture session: the linked draft by ID (never the global
    /// latest slot), payload-level user choices, or a fresh fragment prefill.
    /// Stale analysis data is dropped with a visible notice.
    func restoreCaptureSession(_ session: CaptureEditorSession) async throws {
        let context = session.context
        if let payload = session.payload {
            // 方向不再可选：忽略旧草稿载荷中的方向子集，固定全部方向。
            grammarFormToExplanation = true
            applyCaptureDeckSelection(
                homeDeckID: payload.targetDeckID,
                deckIDs: payload.targetDeckIDs
            )
        }
        // S07：续编载荷里的来源草稿优先；没有则从条目事实现造
        // （句子字段取选择片段或整段输入——选词制卡时原句即捕获文本）。
        sourceContextDraft = session.payload?.sourceDraft
            ?? Self.captureSourceDraft(
                item: session.item,
                fragment: captureFragmentText(from: session)
                    ?? context.inputText
            )
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

    /// S07：从收集条目事实构建来源草稿。`paste` 映射为 `manual`（设计
    /// §6.1 口径）；无 item（旧测试会话）返回 nil，不编造来源。
    nonisolated static func captureSourceDraft(
        item: InboxItem?,
        fragment: String?
    ) -> SourceContextDraft? {
        guard let item else { return nil }
        let type: SourceContextType = switch item.sourceType {
        case .share: .share
        case .ocr: .ocr
        case .manual, .paste: .manual
        }
        return SourceContextDraft(
            sourceType: type,
            originalSentence: fragment,
            sourceURL: item.sourceURL,
            sourceApp: item.sourceApp,
            imageReference: item.imageReference
        )
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
}
