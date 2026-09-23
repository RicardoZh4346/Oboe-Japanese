import Foundation
import Observation
import OboeDomain

/// PR3 split: 最终提交与错误归一化的状态，
/// 由 `AddContentViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class AddContentCommitCoordinator {
    var isSaving = false
    var isCommitting = false
    var duplicates: [KnowledgePointSummary] = []
    /// 「加入当前牌组」正在处理中的重复项：驱动行内禁用态并防重入，
    /// 重复点击只生效一次（幂等）。
    var joiningDuplicateNoteIDs: Set<UUID> = []
}

extension AddContentViewModel {
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

    var commitAvailabilityMessage: String {
        if decks.isEmpty { return "请先在牌组页创建目标牌组。" }
        return "确认后会原子保存正文、例句、标签和卡片（词汇固定生成全部三个方向）；卡片暂不提供评分或下次复习时间。"
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

    /// v0.5.5 第五步：重复项是否已是当前（required）牌组成员。
    /// 已是成员的行只保留「打开查看」与正式保存时的二次确认另建义项。
    func isCurrentDeckMember(_ item: KnowledgePointSummary) -> Bool {
        guard let requiredDeckID else { return false }
        return item.deckIDs.contains(requiredDeckID)
    }

    /// 能否对重复项展示「加入当前牌组」：仅从牌组详情进入的添加流
    ///（requiredDeckID 非空）且该 Note 尚未是当前牌组成员。
    func canJoinCurrentDeck(_ item: KnowledgePointSummary) -> Bool {
        requiredDeckID != nil && !isCurrentDeckMember(item)
    }

    /// v0.5.5 第五步：把重复提示中的已有 Note 追加进当前牌组。
    /// 走现有 membership 原子替换接口，只追加成员关系并保留原 home
    /// deck——卡片、FSRS 状态与复习日志都挂在 Note 上，不复制也不重置；
    /// 每日新词额度归属不变，用户可在详情页「管理牌组」另行切换 home。
    /// 返回 true 表示成员关系已就位（含已是成员的幂等结果），由调用方
    /// 退出添加流、返回牌组详情。
    @discardableResult
    func addDuplicateToCurrentDeck(noteID: UUID) async -> Bool {
        guard let requiredDeckID,
              !joiningDuplicateNoteIDs.contains(noteID) else { return false }
        joiningDuplicateNoteIDs.insert(noteID)
        defer { joiningDuplicateNoteIDs.remove(noteID) }
        do {
            guard let existing = try await knowledgePointService.fetchMembership(
                noteID: noteID
            ) else {
                errorMessage = "这个知识点已不存在。"
                return false
            }
            // 幂等：已是成员时不再写库，直接按成功处理。
            if existing.deckIDs.contains(requiredDeckID) {
                return true
            }
            var deckIDs = existing.deckIDs
            deckIDs.insert(requiredDeckID)
            _ = try await knowledgePointService.replaceMembership(
                noteID: noteID,
                deckIDs: deckIDs,
                homeDeckID: existing.homeDeckID
            )
            return true
        } catch {
            errorMessage = Self.membershipMessage(for: error)
            return false
        }
    }

    private static func membershipMessage(for error: Error) -> String {
        switch error {
        case NoteDeckMembershipError.noteNotFound:
            "这个知识点已不存在。"
        case NoteDeckMembershipError.deckNotFound(_):
            "目标牌组已不存在，请返回牌组列表刷新后重试。"
        case NoteDeckMembershipError.atLeastOneDeckRequired,
             NoteDeckMembershipError.homeDeckMustBeMember:
            "牌组成员关系无效，请重试。"
        case NoteDeckMembershipError.cannotRemoveLastMembership,
             NoteDeckMembershipError.cannotRemoveHomeMembership:
            "当前成员关系不允许移除。"
        default:
            error.localizedDescription
        }
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
