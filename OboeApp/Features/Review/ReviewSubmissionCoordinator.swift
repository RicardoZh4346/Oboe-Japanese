import Foundation
import Observation
import OboeDomain

struct PendingSubmission {
    let eventID: UUID
    let rating: ReviewRating
    let durationMilliseconds: Int
    let card: LoadedReviewCard
    /// normal 路径恒非 nil；practiceOnly 专项没有学习日——nil 时
    /// custom 提交走 `practice_attempts`，不进 `SubmitReview`。
    let studyDay: StudyDay?
}

struct LastSubmission {
    let eventID: UUID
    let studyDay: StudyDay
    /// T21: undo re-presents the undone card before the sibling policy
    /// runs — needs to know which card the submission belonged to.
    let cardID: UUID
}

/// S16（技术文档 §12.3）：Review 撤销栈的类型化动作——
/// `review` 走 FSRS 撤销；`tooEasy` 走 flag CAS 撤销，两者
/// 在栈内严格隔离，绝不互相调用。
enum ReviewUndoAction: Equatable, Sendable {
    case review(eventID: UUID)
    case tooEasy(eventID: UUID)

    var isReview: Bool {
        if case .review = self { return true }
        return false
    }
    var isTooEasy: Bool {
        if case .tooEasy = self { return true }
        return false
    }
}

/// PR3 split: 提交、重试、撤销与 pending/last submission 状态，
/// 由 `ReviewViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class ReviewSubmissionCoordinator {
    var pendingSubmission: PendingSubmission?
    var lastSubmission: LastSubmission?
    var isSubmitting = false
    var isUndoing = false
    var submissionErrorMessage: String?
    var undoErrorMessage: String?
    var hasCommittedCurrentCard = false
    var completedSubmissionCount = 0
    /// S16：typed undo 栈（栈底→栈顶 = 旧→新）。`review` 语义仍是
    /// 「只能撤上一次」——压栈前先清既有 review 条目；`tooEasy`
    /// 条目按各自事件独立存活（各自横幅窗口过期即失效）。
    var undoActions: [ReviewUndoAction] = []
}

extension ReviewViewModel {
    var canUndo: Bool {
        // S16：Too Easy 横幅窗口期内的锚点也是可撤动作。
        let liveTooEasyUndo = tooEasy.pendingUndo != nil
            && tooEasy.pendingUndo!.expiresAt > Date()
        return isCustomSession
            ? (custom.lastPracticeEventID != nil || lastSubmission != nil
               || liveTooEasyUndo)
            : (lastSubmission != nil || liveTooEasyUndo)
    }
    var isMutating: Bool { isSubmitting || isUndoing }
    var submittingRating: ReviewRating? { pendingSubmission?.rating }

    func submit(_ rating: ReviewRating) async {
        if isCustomSession {
            await customSubmit(rating)
            return
        }
        guard pendingSubmission == nil, !isLoading, !isMutating,
              !hasCommittedCurrentCard, let card,
              let studyDay = plan?.studyDay,
              isAnswerVisible else {
            return
        }
        speechService.stop()
        let duration = max(0, Int(Date().timeIntervalSince(answerRevealedAt ?? Date()) * 1_000))
        pendingSubmission = PendingSubmission(
            eventID: UUID(),
            rating: rating,
            durationMilliseconds: duration,
            card: card,
            studyDay: studyDay
        )
        await retrySubmission()
    }

    func retrySubmission() async {
        guard let pendingSubmission, !isMutating, !isLoading,
              !hasCommittedCurrentCard,
              let studyDay = pendingSubmission.studyDay else { return }
        guard recallAttempt?.beginSubmission(eventID: pendingSubmission.eventID) == true else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        submissionErrorMessage = nil
        do {
            let submitted = try await service.submit(
                card: pendingSubmission.card,
                rating: pendingSubmission.rating,
                studyDay: studyDay,
                eventID: pendingSubmission.eventID,
                durationMilliseconds: pendingSubmission.durationMilliseconds,
                scopeDeckID: scope.deckID
            )
            lastSubmission = LastSubmission(
                eventID: submitted.eventID,
                studyDay: studyDay,
                cardID: pendingSubmission.card.content.cardID
            )
            // S16：typed 栈——语义仍是「只能撤最近一次评分」，压栈前
            // 先清旧 review 条目；tooEasy 条目按自身窗口独立存活。
            submission.undoActions.removeAll { $0.isReview }
            submission.undoActions.append(.review(eventID: submitted.eventID))
            hasCommittedCurrentCard = true
            completedSubmissionCount += 1
            await loadNextCard()
        } catch {
            recallAttempt?.submissionFailed(eventID: pendingSubmission.eventID)
            let message = Self.submissionMessage(for: error)
            submissionErrorMessage = message
            if Self.requiresFreshCard(error) {
                self.pendingSubmission = nil
                await loadNextCard()
                submissionErrorMessage = nil
                loadErrorMessage = message
            }
        }
    }

    /// S16 全局撤销入口（toolbar/菜单）：按 `undoActions` 栈顶类型
    /// 分发——`tooEasy` 条目不触发 FSRS 撤销，反之亦然。栈为空
    /// （老路径/异常态）时回退旧 `undoLastSubmission` 语义。
    func undoLatestAction() async {
        while let top = submission.undoActions.last {
            switch top {
            case .tooEasy(let eventID):
                if tooEasy.pendingUndo?.eventID == eventID,
                   tooEasy.pendingUndo!.expiresAt > Date() {
                    await undoTooEasyFlag()
                    return
                }
                submission.undoActions.removeLast()
            case .review:
                submission.undoActions.removeLast()
                await undoLastSubmission()
                return
            }
        }
        await undoLastSubmission()
    }

    func undoLastSubmission() async {
        if isCustomSession {
            await customUndoLastSubmission()
            return
        }
        guard let lastSubmission, !isMutating, !isLoading else { return }
        speechService.stop()
        isUndoing = true
        defer { isUndoing = false }
        undoErrorMessage = nil
        do {
            _ = try await service.undoLastReview(
                eventID: lastSubmission.eventID,
                studyDay: lastSubmission.studyDay
            )
            submission.undoActions.removeAll {
                $0 == .review(eventID: lastSubmission.eventID)
            }
            // T21 (§9.2): re-present the undone card ahead of the policy
            // pick and clear the separation debt.
            undoPreferredCardID = lastSubmission.cardID
            siblingDeferredCardID = nil
            self.lastSubmission = nil
            await loadNextCard()
        } catch {
            undoErrorMessage = Self.undoMessage(for: error)
            if error is UndoReviewError {
                self.lastSubmission = nil
            }
        }
    }

    private static func requiresFreshCard(_ error: Error) -> Bool {
        guard let error = error as? SubmitReviewError else { return false }
        return switch error {
        case .stateVersionConflict, .studyDayNotActive, .cardNotInStudyPlan,
             .cardNotDue, .clockMovedBackward, .cardDisabled, .cardNotFound:
            true
        default:
            false
        }
    }

    private static func submissionMessage(for error: Error) -> String {
        guard let error = error as? SubmitReviewError else {
            return "评分未保存：\(error.localizedDescription)。请重试。"
        }
        return switch error {
        case .stateVersionConflict: "卡片已在其他位置更新，已重新载入。"
        case .studyDayNotActive: "学习日已经变化，已刷新今日计划。"
        case .cardNotInStudyPlan: "卡片已不在当前计划中，已刷新。"
        case let .cardNotDue(until): "这张卡尚未到期（\(StudyTimeText.until(until))后）。"
        case .clockMovedBackward: "系统时间早于上次评分，请校正时间后再试。"
        case .cardDisabled, .cardNotFound: "卡片已停用或删除，已刷新。"
        default: "评分未保存，请重试。"
        }
    }

    private static func undoMessage(for error: Error) -> String {
        guard let error = error as? UndoReviewError else {
            return "撤销失败：\(error.localizedDescription)。请重试。"
        }
        return switch error {
        case .reviewNotFound, .alreadyUndone: "这次评分已不存在或已被撤销。"
        case .studyDayMismatch, .studyDayNotActive: "学习日已经变化，不能撤销昨天的评分。"
        case .cardNotFound: "卡片已经删除，无法恢复评分前状态。"
        case .cardDisabled: "卡片已经停用，无法撤销这次评分。"
        case .cardNotInStudyPlan: "卡片已不在当前学习计划中，无法撤销。"
        case .subsequentReviewExists: "这张卡已有后续评分，不能撤销较早记录。"
        case .stateConflict: "卡片状态已发生变化，未执行撤销。"
        }
    }
}
