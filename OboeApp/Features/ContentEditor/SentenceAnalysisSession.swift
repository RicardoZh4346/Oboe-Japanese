import Observation
import OboeDomain
import SwiftUI

/// PR3 split: 句子分析、候选卡选择与重复检查的会话状态，
/// 由 `AddContentViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class SentenceAnalysisSession {
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
    var sentenceCardStatusMessage: String?
    @ObservationIgnored var sentenceAnalysisTask: Task<Void, Never>?
    @ObservationIgnored var sentenceAnalysisGate = AIGenerationRequestGate()
    @ObservationIgnored var nextSentenceInputVersion = 0
    @ObservationIgnored var isRestoringSentenceDraft = false
}

extension AddContentViewModel {
    var canAnalyzeSentence: Bool {
        guard kind == .sentenceAnalysis, !isLoading, !isAnalyzingSentence else { return false }
        return (try? SentenceAnalysisDecoder.validated(
            SentenceAnalysisInput(sentence: sentenceAnalysisInput)
        )) != nil
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

    func resetSentenceCardSelection() {
        selectedSentenceAnalysisItemIDs = []
        sentenceCardDrafts = []
        sentenceCardDuplicates = [:]
        sentenceCardStatusMessage = nil
    }

    /// Re-selects persisted analysis items and overlays edited card drafts on
    /// top of freshly generated ones.
    func restoreSentenceSelection(from payload: CaptureResumePayload) {
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

    func restoreSentenceAnalysisDraft() async throws {
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
}
