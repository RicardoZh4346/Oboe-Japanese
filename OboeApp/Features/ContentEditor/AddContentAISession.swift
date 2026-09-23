import Observation
import OboeDomain
import SwiftUI

/// PR3 split: AI 生成、取消与候选应用的会话状态，
/// 由 `AddContentViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class AddContentAISession {
    var vocabularyAIInput = ""
    var vocabularyAIContext = ""
    var grammarAIInput = ""
    var grammarAIContext = ""
    var generatedCandidate: AICardDraftCandidate?
    var aiGenerationStatusMessage: String?
    var aiGenerationErrorMessage: String?
    var isGenerating = false
    @ObservationIgnored var generationTask: Task<Void, Never>?
    @ObservationIgnored var generationGate = AIGenerationRequestGate()
    @ObservationIgnored var nextInputVersion = 0
}

extension AddContentViewModel {
    var canGenerate: Bool {
        guard kind != .sentenceAnalysis, !isLoading, !isGenerating else { return false }
        return !currentAIInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
}
