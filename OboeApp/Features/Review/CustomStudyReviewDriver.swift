import Foundation
import Observation
import OboeDomain

/// S09 专项学习会话状态（设计 §7.2/§7.4）：冻结队列、练习计数与
/// 撤销锚点全部按 session 生命周期走；`ReviewViewModel` 以计算属性
/// 原样转发，与 normal 队列共存互不干扰。
@MainActor
@Observable
final class CustomStudyCoordinator {
    /// 已加载的 active 会话；队列来自启动时冻结的 `queue.cardIDs`，
    /// 删除/停用的卡在呈现时跳过，队列本身不重复扩张。
    var session: CustomStudySession?
    var remainingCardIDs: [UUID] = []
    /// scheduled 模式的提交需要真实学习日——会话首次加载时构建今日
    /// 计划（§7.3：首学额度仍按 Note 去重，由提交策略保障）。
    var studyDay: StudyDay?
    var presentedCount = 0
    var againCount = 0
    /// practice：最近一次未撤销 attempt 的 eventID；
    /// scheduled：复用 `lastSubmission`。两者都只允许撤销「上一次」。
    var lastPracticeEventID: UUID?
    var lastPracticeCardID: UUID?
    var isFinished = false
}

extension ReviewViewModel {
    var isCustomSession: Bool { scope.customSessionID != nil }
    var isPracticeOnlySession: Bool { scope.customMode == .practiceOnly }

    var customSession: CustomStudySession? {
        get { custom.session }
        set { custom.session = newValue }
    }
    var customRemainingCount: Int { custom.remainingCardIDs.count }
    var customPresentedCount: Int {
        get { custom.presentedCount }
        set { custom.presentedCount = newValue }
    }
    var customAgainCount: Int {
        get { custom.againCount }
        set { custom.againCount = newValue }
    }
    var customIsFinished: Bool {
        get { custom.isFinished }
        set { custom.isFinished = newValue }
    }
    /// practice 卡面不显示 FSRS 间隔（§7.4：四档只表示掌握程度）。
    var showsIntervals: Bool { !isPracticeOnlySession }
    /// practice 只计练习摘要；scheduled 计正式提交数。
    var customCompletedCount: Int {
        get { custom.presentedCount }
        set { custom.presentedCount = newValue }
    }

    /// 队列推进（专项路径）：会话惰性加载一次，之后按冻结序逐张
    /// 呈现；取不到的卡（删除/停用）静默跳过。`preservingCurrentCard`
    /// 在专项里只用于内容刷新——不改队列位置。
    func customLoadNextCard(preservingCurrentCard: Bool = false) async {
        guard let repository = customStudyRepository else {
            loadErrorMessage = "专项学习暂不可用。"
            isLoading = false
            return
        }
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
            if custom.session == nil {
                guard let sessionID = scope.customSessionID,
                      let session = try await repository.fetchSession(id: sessionID) else {
                    custom.isFinished = true
                    loadErrorMessage = "这次专项学习已不存在。"
                    return
                }
                custom.session = session
                custom.remainingCardIDs = session.queue.cardIDs
                if session.mode == .scheduled, custom.studyDay == nil {
                    let plan = try await service.buildTodayPlan(
                        defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                    )
                    custom.studyDay = plan.studyDay
                }
            }
            guard custom.session?.status == .active else {
                custom.isFinished = true
                card = nil
                return
            }

            if preservingCurrentCard, !hasCommittedCurrentCard,
               let current = card {
                do {
                    let refreshed = try await service.loadReviewCard(
                        cardID: current.content.cardID
                    )
                    card = refreshed
                } catch {
                    card = nil
                }
            }

            if !preservingCurrentCard || card == nil || hasCommittedCurrentCard {
                var freshCard: LoadedReviewCard?
                while freshCard == nil, !custom.remainingCardIDs.isEmpty {
                    let cardID = custom.remainingCardIDs.removeFirst()
                    freshCard = try? await service.loadReviewCard(cardID: cardID)
                }
                card = freshCard
                if freshCard != nil {
                    let preferences = (try? await speechPreferencesService.load(
                        defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                    )) ?? .defaults
                    speechPreferences = preferences
                    adaptivePreferences = (try? await adaptivePreferencesService.load(
                        defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                    )) ?? .defaults
                    recallAttempt = freshCard.map {
                        RecallAttempt(
                            cardID: $0.content.cardID,
                            contentVersion: $0.content.contentVersion,
                            template: $0.content.templateKind,
                            preferences: adaptivePreferences
                        )
                    }
                    presentationID = UUID()
                    speechService.stop()
                    answerRevealedAt = nil
                    pendingSubmission = nil
                    submissionErrorMessage = nil
                    hasCommittedCurrentCard = false
                    listeningPromptRequestID = nil
                    listeningPromptStatus = .idle
                    listeningPromptCompleted = false
                    leechReminderStatus = nil
                    playAutomatically(onAnswer: false)
                }
            }

            if card == nil {
                custom.isFinished = true
                if let session = custom.session, session.status == .active {
                    custom.session = CustomStudySession(
                        id: session.id,
                        filter: session.filter,
                        mode: session.mode,
                        status: .finished,
                        queue: session.queue,
                        startedAt: session.startedAt,
                        finishedAt: Date()
                    )
                    try? await repository.updateSessionStatus(
                        id: session.id,
                        to: .finished,
                        finishedAt: Date()
                    )
                }
            }
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    /// 评分（专项路径）：practice → `practice_attempts`（不碰 FSRS/
    /// review_logs/额度）；scheduled → `service.submit` + `.customScheduled`
    /// 事务策略（§7.3：session/队列成员/generation 由持久层校验）。
    func customSubmit(_ rating: ReviewRating) async {
        guard pendingSubmission == nil, !isLoading, !isMutating,
              !hasCommittedCurrentCard, let card, isAnswerVisible,
              let repository = customStudyRepository,
              let session = custom.session, session.status == .active else {
            return
        }
        speechService.stop()
        let duration = max(
            0,
            Int(Date().timeIntervalSince(answerRevealedAt ?? Date()) * 1_000)
        )
        let eventID = UUID()
        pendingSubmission = PendingSubmission(
            eventID: eventID,
            rating: rating,
            durationMilliseconds: duration,
            card: card,
            studyDay: custom.studyDay
        )
        guard recallAttempt?.beginSubmission(eventID: eventID) == true else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        submissionErrorMessage = nil
        do {
            switch session.mode {
            case .practiceOnly:
                let attempt = try await repository.recordPracticeAttempt(
                    PracticeAttempt(
                        id: UUID(),
                        eventID: eventID,
                        sessionID: session.id,
                        cardKey: card.content.cardID,
                        noteID: card.content.noteID,
                        rating: rating,
                        answeredAt: Date(),
                        durationMilliseconds: duration,
                        contentVersion: card.content.contentVersion
                    )
                )
                custom.lastPracticeEventID = attempt.eventID
                custom.lastPracticeCardID = attempt.cardKey
                custom.presentedCount += 1
                if rating == .again { custom.againCount += 1 }
            case .scheduled:
                guard let studyDay = custom.studyDay else {
                    throw CustomStudyDriverError.missingStudyDay
                }
                let submitted = try await service.submit(
                    card: card,
                    rating: rating,
                    studyDay: studyDay,
                    eventID: eventID,
                    durationMilliseconds: duration,
                    scopeDeckID: scope.deckID,
                    policy: .customScheduled(sessionID: session.id)
                )
                lastSubmission = LastSubmission(
                    eventID: submitted.eventID,
                    studyDay: studyDay,
                    cardID: card.content.cardID
                )
                custom.lastPracticeCardID = nil
                custom.lastPracticeEventID = nil
                custom.presentedCount += 1
            }
            hasCommittedCurrentCard = true
            completedSubmissionCount += 1
            pendingSubmission = nil
            await customLoadNextCard()
        } catch {
            recallAttempt?.submissionFailed(eventID: eventID)
            submissionErrorMessage = customSubmissionMessage(for: error)
        }
    }

    /// 撤销（专项路径）：practice 只置 `undone_at` 并把卡放回队首；
    /// scheduled 走正式撤销（origin 校验 + 状态版本，§7.3）后同样回队首。
    func customUndoLastSubmission() async {
        guard !isMutating, !isLoading,
              let repository = customStudyRepository else { return }
        speechService.stop()
        isUndoing = true
        defer { isUndoing = false }
        undoErrorMessage = nil
        do {
            switch custom.session?.mode {
            case .practiceOnly:
                guard let eventID = custom.lastPracticeEventID,
                      let cardID = custom.lastPracticeCardID else { return }
                _ = try await repository.undoPracticeAttempt(
                    eventID: eventID,
                    undoneAt: Date()
                )
                custom.remainingCardIDs.insert(cardID, at: 0)
                custom.lastPracticeEventID = nil
                custom.lastPracticeCardID = nil
                custom.presentedCount = max(0, custom.presentedCount - 1)
            case .scheduled:
                guard let lastSubmission else { return }
                _ = try await service.undoLastReview(
                    eventID: lastSubmission.eventID,
                    studyDay: lastSubmission.studyDay
                )
                custom.remainingCardIDs.insert(lastSubmission.cardID, at: 0)
                self.lastSubmission = nil
                custom.presentedCount = max(0, custom.presentedCount - 1)
            case nil:
                return
            }
            custom.isFinished = false
            hasCommittedCurrentCard = false
            await customLoadNextCard()
        } catch {
            undoErrorMessage = "撤销失败：\(error.localizedDescription)。请重试。"
        }
    }

    /// 完成页「再来一轮」：同 filter 新会话（新冻结队列/新 id）。
    /// 原 sessionID 保留在 scope（scene 缓存身份不变），这里直接换
    /// coordinator 内的 session 对象。
    func restartCustomSession() async {
        guard let repository = customStudyRepository,
              let service = customStudyService,
              let old = custom.session else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let context = CustomStudyQueueContext(now: Date())
            let cardIDs = try await repository.buildQueue(
                filter: old.filter,
                context: context
            )
            let queue = CustomStudyQueue.ordered(
                cardIDs: cardIDs,
                order: old.filter.order,
                randomSeed: old.filter.randomSeed,
                generatedAt: Date()
            )
            let session = try service.makeSession(
                filter: old.filter,
                queue: queue,
                mode: old.mode,
                now: Date()
            )
            try await repository.createSession(session)
            custom.session = session
            custom.remainingCardIDs = session.queue.cardIDs
            custom.presentedCount = 0
            custom.againCount = 0
            custom.lastPracticeEventID = nil
            custom.lastPracticeCardID = nil
            custom.isFinished = false
            lastSubmission = nil
            await customLoadNextCard()
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    private func customSubmissionMessage(for error: Error) -> String {
        switch error {
        case CustomStudyRepositoryError.sessionNotFound:
            return "这次专项学习已不存在，请返回重新开始。"
        case CustomStudyRepositoryError.sessionNotEligibleForScheduledSubmission:
            return "这次专项学习已结束，不能继续评分。"
        case CustomStudyRepositoryError.cardNotInSessionQueue:
            return "这张卡不在本次专项队列中，已刷新。"
        case CustomStudyRepositoryError.conflictingEventID:
            return "评分提交冲突，请重试。"
        case CustomStudyDriverError.missingStudyDay:
            return "学习日未就绪，请重试。"
        default:
            if let error = error as? SubmitReviewError {
                return switch error {
                case .stateVersionConflict: "卡片已在其他位置更新，已重新载入。"
                case .cardDisabled, .cardNotFound: "卡片已停用或删除，已刷新。"
                default: "评分未保存，请重试。"
                }
            }
            return "评分未保存：\(error.localizedDescription)。请重试。"
        }
    }
}

enum CustomStudyDriverError: Error {
    case missingStudyDay
}
