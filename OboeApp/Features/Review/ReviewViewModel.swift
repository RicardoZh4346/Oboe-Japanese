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
        /// T21: undo re-presents the undone card before the sibling policy
        /// runs — needs to know which card the submission belonged to.
        let cardID: UUID
    }

    private let service: StudySessionService
    private let historyService: StudyHistoryService
    private let speechPreferencesService: SpeechPreferencesService
    private let adaptiveCardService: AdaptiveCardService
    private let adaptivePreferencesService: AdaptivePreferencesService
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
    private(set) var recallAttempt: RecallAttempt?
    private(set) var presentationID = UUID()
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
    var isLoading = true
    var isSubmitting = false
    var isUndoing = false
    var loadErrorMessage: String?
    var submissionErrorMessage: String?
    var undoErrorMessage: String?
    var speechErrorMessage: String?
    var speechPreferences = SpeechPreferences.defaults
    /// T18: adaptive toggles are loaded alongside recall preferences in
    /// `loadNextCard` — `autoPlayListeningAudio` gates the prompt autoplay.
    private(set) var adaptivePreferences = AdaptivePreferences.defaults
    /// Answer-face reminder state (T03): set per loaded card, only surfaced
    /// for warning/leech while `leechRemindersEnabled`; the question face
    /// never reads it.
    var leechReminderStatus: AdaptiveCardStatus?
    var scopeSummary: TodayStudySummary?
    var completionStatistics: StudyCompletionStatistics?
    var statisticsErrorMessage: String?

    // MARK: - T18 listening playback & session skip (设计 §8.3)

    /// Listening prompt playback for the CURRENT `presentationID` only.
    private(set) var listeningPromptStatus: ListeningPromptPlaybackStatus = .idle
    private var listeningPromptRequestID: UUID?
    /// One completed prompt per presentation gates reveal/confirm — a
    /// listening card that never produced audio must not be rated.
    private(set) var listeningPromptCompleted = false
    /// Session-scoped skip set (memory only): cards whose prompt audio is
    /// unplayable are not re-picked this round, so failures can't loop. A new
    /// session (new view model) re-checks every card.
    private(set) var skippedListeningIDs: Set<UUID> = []
    /// Lightweight notice shown after a skip; cleared by the explicit retry.
    private(set) var listeningSkipNotice: String?

    // MARK: - T21 sibling separation memory (设计 §9)

    /// Note of the most recently presented question face — the policy's
    /// `lastPresentedNoteID`. Updated when a NEW card commits (never on a
    /// preserved refresh), and rolled back when the current card is
    /// listening-skipped: a card whose audio never produced a valid
    /// question does not count as presented (§9.2).
    private var lastPresentedNoteID: UUID?
    /// Value of `lastPresentedNoteID` before the current card committed —
    /// the rollback source for a listening skip.
    private var lastPresentedNoteIDBeforeCurrent: UUID?
    /// At-most-once deferral debt carried between selections (T20 policy).
    private var siblingDeferredCardID: UUID?
    /// §9.2: after a successful undo the undone card re-presents ahead of
    /// the policy pick, provided it is still an eligible candidate.
    private var undoPreferredCardID: UUID?

    init(
        service: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService,
        speechService: any SpeechService,
        scope: StudyScope
    ) {
        self.service = service
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.adaptiveCardService = adaptiveCardService
        self.adaptivePreferencesService = adaptivePreferencesService
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
            // T18: session-skipped listening cards stay due but are never
            // re-picked this round — a failing card cannot loop forever.
            let candidates = scopedNowItems(in: freshPlan)
                .filter { !skippedListeningIDs.contains($0.cardID) }
            let keepsCurrentCard = preservingCurrentCard && !hasCommittedCurrentCard
                && candidates.contains(where: { $0.cardID == currentItem?.cardID })
            var selected: TodayQueueItem?
            var freshCard: LoadedReviewCard?
            if keepsCurrentCard, let current = currentItem {
                selected = current
                freshCard = try await service.loadReviewCard(cardID: current.cardID)
            } else {
                // T21 (设计 §9.1): the display order is decided by the pure
                // sibling-selection policy over the scope-filtered,
                // skip-filtered candidates — the queue's raw order is the
                // priority order, and one deferral debt is carried between
                // picks. Every pick is still load-prechecked (T18 §8.3): a
                // listening card that can never produce audio this session
                // is skipped without being presented.
                var pool = candidates
                var workingDebt = siblingDeferredCardID
                // §9.2: a successful undo re-presents the undone card first
                // when it is still eligible — ahead of the policy pick and
                // with the separation debt cleared.
                if let undoID = undoPreferredCardID,
                   let index = pool.firstIndex(where: { $0.cardID == undoID }) {
                    workingDebt = nil
                    let candidate = pool.remove(at: index)
                    let loaded = try await service.loadReviewCard(cardID: candidate.cardID)
                    if loaded.content.templateKind == .vocabularyListening,
                       listeningPromptUnavailableReason(for: loaded.content) != nil {
                        skippedListeningIDs.insert(candidate.cardID)
                        listeningSkipNotice = "音频暂不可用，已跳过这张听力卡。"
                    } else {
                        selected = candidate
                        freshCard = loaded
                    }
                }
                undoPreferredCardID = nil
                while selected == nil,
                      let selection = SiblingSelectionPolicy.selectNext(
                          among: pool,
                          lastPresentedNoteID: lastPresentedNoteID,
                          deferredCardID: workingDebt
                      ) {
                    // The deferral decision stands even when the spacer's
                    // load fails — the deferred card yielded its turn once,
                    // so it cannot be deferred a second time by the repick.
                    workingDebt = selection.deferredCardID
                    pool.removeAll { $0.cardID == selection.selected.cardID }
                    let loaded = try await service.loadReviewCard(cardID: selection.selected.cardID)
                    if loaded.content.templateKind == .vocabularyListening,
                       listeningPromptUnavailableReason(for: loaded.content) != nil {
                        skippedListeningIDs.insert(selection.selected.cardID)
                        listeningSkipNotice = "音频暂不可用，已跳过这张听力卡。"
                        continue
                    }
                    selected = selection.selected
                    freshCard = loaded
                }
                siblingDeferredCardID = workingDebt
            }
            let freshPreferences: SpeechPreferences
            let freshReminder: AdaptiveCardStatus?
            let recallPreferences: AdaptivePreferences
            if let selected {
                freshPreferences = (try? await speechPreferencesService.load(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )) ?? .defaults
                freshReminder = await loadLeechReminder(cardID: selected.cardID)
                recallPreferences = (try? await adaptivePreferencesService.load(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )) ?? .defaults
            } else {
                freshPreferences = speechPreferences
                freshReminder = nil
                recallPreferences = adaptivePreferences
            }
            try Task.checkCancellation()

            plan = freshPlan
            scopeSummary = freshSummary
            currentItem = selected
            let contentChanged = recallAttempt?.contentVersion != freshCard?.content.contentVersion
            if keepsCurrentCard, let freshCard, recallAttempt != nil {
                recallAttempt?.reloadContent(version: freshCard.content.contentVersion)
            } else {
                recallAttempt = freshCard.map {
                    RecallAttempt(cardID: $0.content.cardID,
                                  contentVersion: $0.content.contentVersion,
                                  template: $0.content.templateKind,
                                  preferences: recallPreferences)
                }
            }
            card = freshCard
            speechPreferences = freshPreferences
            adaptivePreferences = recallPreferences
            leechReminderStatus = freshReminder
            if lastSubmission?.studyDay.id != freshPlan.studyDay.id {
                lastSubmission = nil
            }
            if !keepsCurrentCard || contentChanged {
                presentationID = UUID()
                speechService.stop()
                answerRevealedAt = nil
                pendingSubmission = nil
                submissionErrorMessage = nil
                hasCommittedCurrentCard = false
                listeningPromptRequestID = nil
                listeningPromptStatus = .idle
                listeningPromptCompleted = false
            }
            // T21: record the presentation AFTER the pick consumed the old
            // `lastPresentedNoteID`. A preserved refresh is not a new
            // presentation (§9.2) and does not touch the memory.
            if !keepsCurrentCard, let selected {
                lastPresentedNoteIDBeforeCurrent = lastPresentedNoteID
                lastPresentedNoteID = selected.noteID
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
            } else if skippedListeningIDs.isEmpty {
                await loadCompletionStatistics(for: freshPlan.studyDay)
            }
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = Self.message(for: error)
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
        guard recallAttempt?.beginSubmission(eventID: pendingSubmission.eventID) == true else { return }
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
                studyDay: pendingSubmission.studyDay,
                cardID: pendingSubmission.card.content.cardID
            )
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
                if recallAttempt?.contentVersion != refreshedCard.content.contentVersion {
                    recallAttempt?.reloadContent(version: refreshedCard.content.contentVersion)
                    presentationID = UUID()
                    pendingSubmission = nil
                    answerRevealedAt = nil
                    submissionErrorMessage = nil
                    speechService.stop()
                    listeningPromptRequestID = nil
                    listeningPromptStatus = .idle
                    listeningPromptCompleted = false
                }
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

    /// T17/T18: the listening question-face prompt — reading (or headword
    /// when no reading), never the example sentence. Manual replay is always
    /// allowed regardless of the autoplay preference. A question-face
    /// failure skips the card for this session; an answer-face playback
    /// (word/example buttons) uses the legacy error-only path and never
    /// skips — see `play(_:)`.
    func playListeningPrompt() {
        // No `!isLoading` here: autoplay fires from inside loadNextCard while
        // the flag is still set — the guard would silently swallow it.
        guard let card,
              card.content.templateKind == .vocabularyListening,
              let prompt = ReviewSpeechPolicy(content: card.content).listeningPromptText,
              !isMutating, !hasCommittedCurrentCard
        else { return }
        let cardID = card.content.cardID
        // A prompt that can never play is a skip on the question face — the
        // load-time pre-check normally prevents reaching this path — but on
        // the answer face it's just a replay failure (设计 §8.3).
        if let reason = listeningPromptUnavailableReason(for: card.content) {
            if isAnswerVisible {
                speechErrorMessage = Self.speechMessage(for: reason)
            } else {
                skipCurrentListeningCard(cardID: cardID, reason: reason)
            }
            return
        }
        let presentation = presentationID
        listeningPromptStatus = .playing
        listeningPromptRequestID = speechService.speakWithEvents([prompt]) {
            [weak self] event in
            self?.handleListeningPromptEvent(
                event, presentation: presentation, cardID: cardID
            )
        }
    }

    /// T18 (设计 §8.3): events carry presentationToken + requestID — a late
    /// callback from a superseded request or a previous card can never skip
    /// or mutate the card currently on screen.
    private func handleListeningPromptEvent(
        _ event: SpeechPlaybackEvent,
        presentation: UUID,
        cardID: UUID
    ) {
        guard presentation == presentationID,
              card?.content.cardID == cardID,
              event.requestID == listeningPromptRequestID else { return }
        switch event {
        case .started:
            listeningPromptStatus = .playing
        case .completed:
            listeningPromptStatus = .played
            listeningPromptCompleted = true
        case .cancelled:
            // Interruption/route change/page exit: not a failure — stay on
            // the card and let the user replay. `listeningPromptCompleted`
            // is left untouched so a cancelled first play still gates.
            listeningPromptStatus = .idle
        case let .failed(_, error):
            listeningPromptStatus = .idle
            if isAnswerVisible {
                // 设计 §8.3: only QUESTION-face failure skips the card. A
                // failed replay on the answer face is a plain speech error —
                // the completed recall is never discarded.
                speechErrorMessage = Self.speechMessage(for: error)
            } else {
                skipCurrentListeningCard(cardID: cardID, reason: error)
            }
        }
    }

    /// T18: question-face audio failure — mark the card skipped for this
    /// session, surface a light notice, and advance to the next candidate.
    /// No rating, no FSRS write, no daily_tasks cancellation.
    private func skipCurrentListeningCard(cardID: UUID, reason: JapaneseSpeechError) {
        guard card?.content.cardID == cardID,
              card?.content.templateKind == .vocabularyListening,
              skippedListeningIDs.insert(cardID).inserted else { return }
        speechService.stop()
        listeningSkipNotice = "音频暂不可用，已跳过这张听力卡。"
        // T21 (§9.2): a skipped card never produced a valid question — roll
        // back its presentation so it does not pollute sibling memory.
        lastPresentedNoteID = lastPresentedNoteIDBeforeCurrent
        Task {
            // A card-preserving refresh may be in flight — its early-return
            // guard would swallow this advance, leaving a failed card stuck
            // on screen. Wait it out, then re-pick with the skip applied.
            while self.isRefreshing {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
            }
            await self.loadNextCard()
        }
    }

    /// T18: "重试音频卡" — explicit clear-and-recheck. A fresh session does
    /// this implicitly since the skip set is memory-only.
    func retrySkippedListeningCards() {
        guard !skippedListeningIDs.isEmpty, !isMutating else { return }
        skippedListeningIDs.removeAll()
        listeningSkipNotice = nil
        Task { await loadNextCard() }
    }

    /// Skipped listening cards still due in this scope — surfaced as
    /// "剩余 X 张听力卡暂无法播放" instead of a false completion state.
    var scopedSkippedListeningCount: Int {
        guard let plan else { return skippedListeningIDs.count }
        let inScope = Set(
            (plan.availableNow + plan.availableLater)
                .filter { scope.deckID == nil || $0.deckID == scope.deckID }
                .map(\.cardID)
        )
        return skippedListeningIDs.intersection(inScope).count
    }

    /// T18 load-time pre-check reasons: no voice, or no prompt text at all.
    private func listeningPromptUnavailableReason(
        for content: ReviewCardContent
    ) -> JapaneseSpeechError? {
        if !speechService.availability.isAvailable { return .voiceUnavailable }
        let prompt = ReviewSpeechPolicy(content: content).listeningPromptText
        if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .noSpeakableText
        }
        return nil
    }

    /// T18: a listening card whose prompt never completed playback this
    /// presentation cannot be revealed or confirmed — no audio, no answer.
    /// With no voice the card is skipped at load, so the gate only applies
    /// while playback is actually possible.
    var mustPlayListeningPromptFirst: Bool {
        card?.content.templateKind == .vocabularyListening
            && !isAnswerVisible
            && !listeningPromptCompleted
            && isSpeechAvailable
    }

    func playExampleSpeech() {
        guard let example = card.flatMap({ ReviewSpeechPolicy(content: $0.content).exampleText })
        else { return }
        play([example])
    }

    func stopSpeech() {
        speechService.stop()
    }

    /// Adaptive lookup is deliberately non-fatal (T03): a classification or
    /// preferences failure simply yields no reminder — review flow and
    /// scheduling stay untouched.
    private func loadLeechReminder(cardID: UUID) async -> AdaptiveCardStatus? {
        do {
            async let preferencesRequest = adaptivePreferencesService.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            async let detailRequest = adaptiveCardService.detail(cardID: cardID, at: Date())
            guard (try await preferencesRequest).leechRemindersEnabled else { return nil }
            guard let status = (try await detailRequest)?.item.assessment.status else {
                return nil
            }
            return status == .leech || status == .warning ? status : nil
        } catch {
            return nil
        }
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
        // T18: the listening prompt rides its own `autoPlayListeningAudio`
        // channel — at most once per presentationToken, driven only from the
        // fresh-selection path so body re-computes and card-preserving
        // refreshes never replay.
        if !onAnswer, card.content.templateKind == .vocabularyListening {
            guard adaptivePreferences.autoPlayListeningAudio else { return }
            playListeningPrompt()
            return
        }
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
