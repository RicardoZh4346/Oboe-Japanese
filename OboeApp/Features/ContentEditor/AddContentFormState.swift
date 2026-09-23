import Foundation
import Observation
import OboeDomain

/// PR3 split: 词汇/语法表单、标签、牌组选择与校验的状态，
/// 由 `AddContentViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class AddContentFormState {
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
    var sentenceAnalysisDeckID: UUID?
    var sentenceAnalysisDeckIDs: Set<UUID> = []
    /// 当前主牌组（`load` 时读取）：新选择默认把主牌组作为 home。
    var primaryDeckID: UUID?
}

extension AddContentViewModel {
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
    func enforcingRequiredDeck(
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

    func applyMembership(
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
    func defaultMembership() -> DeckMembershipSelection {
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
    func normalizeMemberships() {
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

    /// 恢复草稿中的多牌组选择：过滤已删除牌组；草稿没有有效成员时不动
    /// 当前选择（由 `normalizeMemberships` 兜底默认值）。
    func restoreDeckSelection(
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

    func restoreVocabularyDraft() async throws {
        if let draft = try await vocabularyService.fetchLatestDraft() {
            vocabularyDraftID = draft.id
            restoreDeckSelection(draft.deckID, draft.deckIDs, for: .vocabulary)
            vocabularyForm = draft.formData
            vocabularyStatusMessage = "已恢复上次草稿"
        }
    }

    func restoreGrammarDraft() async throws {
        if let draft = try await grammarService.fetchLatestDraft() {
            grammarDraftID = draft.id
            restoreDeckSelection(draft.deckID, draft.deckIDs, for: .grammar)
            grammarForm = draft.formData
            grammarStatusMessage = "已恢复上次草稿"
        }
    }

    func parsedTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func tagsAreValid(_ text: String) -> Bool {
        parsedTags(text).allSatisfy { (try? KnowledgeTagName(validating: $0)) != nil }
    }
}
