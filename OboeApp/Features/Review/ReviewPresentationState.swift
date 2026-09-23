import Foundation
import Observation
import OboeDomain

/// PR3 split: question/answer 展示、输入、提醒与 animation ID 的页面状态，
/// 由 `ReviewViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class ReviewPresentationState {
    var recallAttempt: RecallAttempt?
    var presentationID = UUID()
    var answerRevealedAt: Date?
    /// Answer-face reminder state (T03): set per loaded card, only surfaced
    /// for warning/leech while `leechRemindersEnabled`; the question face
    /// never reads it.
    var leechReminderStatus: AdaptiveCardStatus?
}

extension ReviewViewModel {
    var isAnswerVisible: Bool { recallAttempt.map { $0.phase != .question } ?? false }
    var isTypedRecall: Bool { recallAttempt?.mode == .typedJapanese }
    var canConfirmRecall: Bool {
        recallAttempt?.canConfirm == true && (recallAttempt?.rawInput.count ?? 0) <= 200
    }
    var recallInputError: String? {
        (recallAttempt?.rawInput.count ?? 0) > 200 ? "请将回答控制在 200 字以内。" : nil
    }

    func updateRecallInput(_ input: String) {
        guard !isLoading, !isMutating, !hasCommittedCurrentCard else { return }
        recallAttempt?.updateInput(input)
    }

    var categoryLabel: String {
        switch currentItem?.category {
        case .new: "新卡"
        case .learning: "学习中"
        case .review: "复习"
        case .relearning: "重学"
        case nil: ""
        }
    }

    func revealAnswer() {
        guard let card, !isAnswerVisible, !isLoading, !isMutating,
              !hasCommittedCurrentCard, !mustPlayListeningPromptFirst else { return }
        // T13: comparison is answer-face feedback only. It is computed at
        // confirm time from the current content snapshot and never selects a
        // rating — the four rating buttons remain the only submission path.
        var comparison: RecallComparison?
        if isTypedRecall {
            comparison = AnswerComparator.compare(
                input: recallAttempt?.rawInput ?? "",
                headword: card.content.headword,
                reading: card.content.reading
            )
        }
        guard canConfirmRecall, recallAttempt?.confirmInput(comparison: comparison) == true
        else { return }
        answerRevealedAt = Date()
        playAutomatically(onAnswer: true)
    }
}
