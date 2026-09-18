import Foundation
import Observation
import OboeDomain

@MainActor
@Observable
final class ReviewViewModel {
    private struct PendingSubmission {
        let eventID: UUID
        let rating: ReviewRating
        let durationMilliseconds: Int
        let card: LoadedReviewCard
        let studyDay: StudyDay
    }

    private struct LastSubmission {
        let eventID: UUID
        let studyDay: StudyDay
    }

    private let service: StudySessionService
    private let historyService: StudyHistoryService
    private let speechPreferencesService: SpeechPreferencesService
    private let speechService: any SpeechService
    private let scope: StudyScope
    private var answerRevealedAt: Date?
    private var pendingSubmission: PendingSubmission?
    private var lastSubmission: LastSubmission?
    private var dueRefreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private(set) var hasCommittedCurrentCard = false

    var plan: TodayPlan?
    var card: LoadedReviewCard?
    var currentItem: TodayQueueItem?
    var isAnswerVisible = false
    var isLoading = true
    var isSubmitting = false
    var isUndoing = false
    var loadErrorMessage: String?
    var submissionErrorMessage: String?
    var undoErrorMessage: String?
    var speechErrorMessage: String?
    var speechPreferences = SpeechPreferences.defaults
    var scopeSummary: TodayStudySummary?
    var completionStatistics: StudyCompletionStatistics?
    var statisticsErrorMessage: String?

    init(
        service: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        speechService: any SpeechService,
        scope: StudyScope
    ) {
        self.service = service
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.speechService = speechService
        self.scope = scope
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

    var canUndo: Bool { lastSubmission != nil }
    var isMutating: Bool { isSubmitting || isUndoing }
    var isSpeechAvailable: Bool { speechService.availability.isAvailable }
    var submittingRating: ReviewRating? { pendingSubmission?.rating }
    private(set) var completedSubmissionCount = 0

    func refresh(preservingCurrentCard: Bool = false) async {
        guard !isMutating else { return }
        await loadNextCard(preservingCurrentCard: preservingCurrentCard)
    }

    private func loadNextCard(preservingCurrentCard: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        defer {
            isRefreshing = false
            isLoading = false
        }
        if !preservingCurrentCard {
            speechService.stop()
        }
        do {
            let freshPlan = try await service.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            let freshSummary = try? await service.fetchScopeSummary(
                studyDay: freshPlan.studyDay,
                deckID: scope.deckID
            )
            let candidates = scopedNowItems(in: freshPlan)
            let keepsCurrentCard = preservingCurrentCard && !hasCommittedCurrentCard
                && candidates.contains(where: { $0.cardID == currentItem?.cardID })
            let selected = keepsCurrentCard ? currentItem : candidates.first
            let freshCard: LoadedReviewCard?
            let freshPreferences: SpeechPreferences
            if let selected {
                freshCard = try await service.loadReviewCard(cardID: selected.cardID)
                freshPreferences = (try? await speechPreferencesService.load(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )) ?? .defaults
            } else {
                freshCard = nil
                freshPreferences = speechPreferences
            }
            try Task.checkCancellation()

            plan = freshPlan
            scopeSummary = freshSummary
            currentItem = selected
            card = freshCard
            speechPreferences = freshPreferences
            if lastSubmission?.studyDay.id != freshPlan.studyDay.id {
                lastSubmission = nil
            }
            if !keepsCurrentCard {
                isAnswerVisible = false
                answerRevealedAt = nil
                pendingSubmission = nil
                submissionErrorMessage = nil
                hasCommittedCurrentCard = false
            }
            completionStatistics = nil
            statisticsErrorMessage = nil
            loadErrorMessage = nil
            dueRefreshTask?.cancel()
            dueRefreshTask = nil
            if selected != nil {
                if !keepsCurrentCard {
                    playAutomatically(onAnswer: false)
                }
            } else if let nextDue = scopedLaterItems(in: freshPlan).first?.dueAt {
                scheduleDueRefresh(at: nextDue)
            } else {
                await loadCompletionStatistics(for: freshPlan.studyDay)
            }
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = Self.message(for: error)
        }
    }

    func revealAnswer() {
        guard card != nil, !isAnswerVisible, !isLoading, !isMutating,
              !hasCommittedCurrentCard else { return }
        isAnswerVisible = true
        answerRevealedAt = Date()
        playAutomatically(onAnswer: true)
    }

    func submit(_ rating: ReviewRating) async {
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
              !hasCommittedCurrentCard else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        submissionErrorMessage = nil
        do {
            let submitted = try await service.submit(
                card: pendingSubmission.card,
                rating: pendingSubmission.rating,
                studyDay: pendingSubmission.studyDay,
                eventID: pendingSubmission.eventID,
                durationMilliseconds: pendingSubmission.durationMilliseconds
            )
            lastSubmission = LastSubmission(
                eventID: submitted.eventID,
                studyDay: pendingSubmission.studyDay
            )
            hasCommittedCurrentCard = true
            completedSubmissionCount += 1
            await loadNextCard()
        } catch {
            let message = Self.submissionMessage(for: error)
            submissionErrorMessage = message
            if Self.requiresFreshCard(error) {
                self.pendingSubmission = nil
                await loadNextCard(preservingCurrentCard: true)
                submissionErrorMessage = nil
                loadErrorMessage = message
            }
        }
    }

    func undoLastSubmission() async {
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
            self.lastSubmission = nil
            await loadNextCard()
        } catch {
            undoErrorMessage = Self.undoMessage(for: error)
            if error is UndoReviewError {
                self.lastSubmission = nil
            }
        }
    }

    func reloadStatistics() async {
        guard let studyDay = plan?.studyDay else { return }
        await loadCompletionStatistics(for: studyDay)
    }

    func stopWaitingRefresh() {
        dueRefreshTask?.cancel()
        dueRefreshTask = nil
    }

    private func scheduleDueRefresh(at dueAt: Date) {
        dueRefreshTask?.cancel()
        dueRefreshTask = Task { [weak self] in
            guard let self else { return }
            let delay = dueAt.timeIntervalSinceNow
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay + 0.25))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self.dueRefreshTask = nil
            await self.refresh()
        }
    }

    func refreshPreviewPeriodically() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard isAnswerVisible, !isMutating, !isLoading,
                  !hasCommittedCurrentCard, let displayedCard = card else { continue }
            do {
                let refreshedCard = try await service.loadReviewCard(
                    cardID: displayedCard.content.cardID
                )
                guard !isMutating, !isLoading, !hasCommittedCurrentCard,
                      card == displayedCard else { continue }
                card = refreshedCard
            } catch {
                guard !isMutating, !isLoading, !hasCommittedCurrentCard,
                      card == displayedCard else { continue }
                loadErrorMessage = Self.message(for: error)
            }
        }
    }

    func scopedNowItems(in plan: TodayPlan) -> [TodayQueueItem] {
        plan.availableNow.filter { scope.deckID == nil || $0.deckID == scope.deckID }
    }

    func scopedLaterItems(in plan: TodayPlan) -> [TodayQueueItem] {
        plan.availableLater.filter { scope.deckID == nil || $0.deckID == scope.deckID }
    }

    func scopedRemainingCount(in plan: TodayPlan) -> Int {
        scopedNowItems(in: plan).count + scopedLaterItems(in: plan).count
    }

    func playPrimarySpeech() {
        guard let card else { return }
        play([ReviewSpeechPolicy(content: card.content).primaryText])
    }

    func playExampleSpeech() {
        guard let example = card.flatMap({ ReviewSpeechPolicy(content: $0.content).exampleText })
        else { return }
        play([example])
    }

    func stopSpeech() {
        speechService.stop()
    }

    private func loadCompletionStatistics(for studyDay: StudyDay) async {
        do {
            completionStatistics = try await historyService.fetchCompletionStatistics(
                studyDayID: studyDay.id,
                deckID: scope.deckID
            )
            statisticsErrorMessage = nil
        } catch {
            completionStatistics = nil
            statisticsErrorMessage = "统计暂时无法载入，请重试。"
        }
    }

    private func playAutomatically(onAnswer: Bool) {
        guard let card else { return }
        let policy = ReviewSpeechPolicy(content: card.content)
        let texts = onAnswer
            ? policy.automaticAnswerTexts(preferences: speechPreferences)
            : policy.automaticQuestionTexts(preferences: speechPreferences)
        guard !texts.isEmpty else { return }
        play(texts)
    }

    private func play(_ texts: [String]) {
        speechErrorMessage = nil
        speechService.speak(texts) { [weak self] error in
            self?.speechErrorMessage = Self.speechMessage(for: error)
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

    private static func message(for error: Error) -> String {
        if error is StudySessionError {
            return "卡片内容已变化，请刷新今日计划。"
        }
        return error.localizedDescription
    }

    private static func speechMessage(for error: Error) -> String {
        guard let error = error as? JapaneseSpeechError else {
            return "系统语音暂时无法播放，请稍后重试。"
        }
        return switch error {
        case .voiceUnavailable:
            "设备未安装可用的日语语音。请在系统设置的辅助功能“朗读内容”中下载日语声音；学习可继续进行。"
        case .noSpeakableText:
            "当前内容没有可朗读的日语文本。"
        case .audioSessionUnavailable:
            "音频正被其他应用或通话占用，请稍后重试。"
        }
    }
}
