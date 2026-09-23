import Foundation
import Observation
import OboeDomain

/// PR3 split: 计划刷新、scope 过滤、Sibling policy 与「下一张」选择的状态，
/// 由 `ReviewViewModel` 以计算属性原样转发，行为不变。
@MainActor
@Observable
final class ReviewQueueCoordinator {
    var plan: TodayPlan?
    var card: LoadedReviewCard?
    var currentItem: TodayQueueItem?
    var scopeSummary: TodayStudySummary?
    var completionStatistics: StudyCompletionStatistics?
    var statisticsErrorMessage: String?
    var isLoading = true
    var loadErrorMessage: String?
    var isRefreshing = false
    var dueRefreshTask: Task<Void, Never>?

    // MARK: - T21 sibling separation memory (设计 §9)

    /// Note of the most recently presented question face — the policy's
    /// `lastPresentedNoteID`. Updated when a NEW card commits (never on a
    /// preserved refresh), and rolled back when the current card is
    /// listening-skipped: a card whose audio never produced a valid
    /// question does not count as presented (§9.2).
    var lastPresentedNoteID: UUID?
    /// Value of `lastPresentedNoteID` before the current card committed —
    /// the rollback source for a listening skip.
    var lastPresentedNoteIDBeforeCurrent: UUID?
    /// At-most-once deferral debt carried between selections (T20 policy).
    var siblingDeferredCardID: UUID?
    /// §9.2: after a successful undo the undone card re-presents ahead of
    /// the policy pick, provided it is still an eligible candidate.
    var undoPreferredCardID: UUID?
}

extension ReviewViewModel {
    func refresh(preservingCurrentCard: Bool = false) async {
        guard !isMutating else { return }
        await loadNextCard(preservingCurrentCard: preservingCurrentCard)
    }

    func loadNextCard(preservingCurrentCard: Bool = false) async {
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
        plan.availableNow.filter { item in
            scope.deckID.map { item.deckIDs.contains($0) } ?? true
        }
    }

    func scopedLaterItems(in plan: TodayPlan) -> [TodayQueueItem] {
        plan.availableLater.filter { item in
            scope.deckID.map { item.deckIDs.contains($0) } ?? true
        }
    }

    func scopedRemainingCount(in plan: TodayPlan) -> Int {
        scopedNowItems(in: plan).count + scopedLaterItems(in: plan).count
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

    private static func message(for error: Error) -> String {
        if error is StudySessionError {
            return "卡片内容已变化，请刷新今日计划。"
        }
        return error.localizedDescription
    }
}
