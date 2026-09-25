import Foundation
import Observation
import OboeDomain

@MainActor
@Observable
final class ReviewViewModel {
    let service: StudySessionService
    let historyService: StudyHistoryService
    let speechPreferencesService: SpeechPreferencesService
    let adaptiveCardService: AdaptiveCardService
    let adaptivePreferencesService: AdaptivePreferencesService
    let speechService: any SpeechService
    /// S09：专项学习驱动依赖——normal 队列会话可为 nil（旧构造不变）。
    let customStudyRepository: (any CustomStudyRepository)?
    let customStudyService: CustomStudyService?
    let scope: StudyScope

    /// PR3 split：页面对外状态拆进四个子对象，下列计算属性逐一转发，
    /// 视图与方法签名保持不变。
    private let queue = ReviewQueueCoordinator()
    private let submission = ReviewSubmissionCoordinator()
    private let audio = ReviewAudioController()
    private let presentation = ReviewPresentationState()
    /// S09：专项会话状态（冻结队列/练习计数/撤销锚点）。
    let custom = CustomStudyCoordinator()

    var speechPreferences = SpeechPreferences.defaults
    /// T18: adaptive toggles are loaded alongside recall preferences in
    /// `loadNextCard` — `autoPlayListeningAudio` gates the prompt autoplay.
    var adaptivePreferences = AdaptivePreferences.defaults

    init(
        service: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService,
        speechService: any SpeechService,
        customStudyRepository: (any CustomStudyRepository)? = nil,
        customStudyService: CustomStudyService? = nil,
        scope: StudyScope
    ) {
        self.service = service
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.adaptiveCardService = adaptiveCardService
        self.adaptivePreferencesService = adaptivePreferencesService
        self.speechService = speechService
        self.customStudyRepository = customStudyRepository
        self.customStudyService = customStudyService
        self.scope = scope
    }

    // MARK: - 队列状态（ReviewQueueCoordinator）

    var plan: TodayPlan? {
        get { queue.plan }
        set { queue.plan = newValue }
    }
    var card: LoadedReviewCard? {
        get { queue.card }
        set { queue.card = newValue }
    }
    var currentItem: TodayQueueItem? {
        get { queue.currentItem }
        set { queue.currentItem = newValue }
    }
    var scopeSummary: TodayStudySummary? {
        get { queue.scopeSummary }
        set { queue.scopeSummary = newValue }
    }
    var completionStatistics: StudyCompletionStatistics? {
        get { queue.completionStatistics }
        set { queue.completionStatistics = newValue }
    }
    var statisticsErrorMessage: String? {
        get { queue.statisticsErrorMessage }
        set { queue.statisticsErrorMessage = newValue }
    }
    var isLoading: Bool {
        get { queue.isLoading }
        set { queue.isLoading = newValue }
    }
    var loadErrorMessage: String? {
        get { queue.loadErrorMessage }
        set { queue.loadErrorMessage = newValue }
    }
    var isRefreshing: Bool {
        get { queue.isRefreshing }
        set { queue.isRefreshing = newValue }
    }
    var dueRefreshTask: Task<Void, Never>? {
        get { queue.dueRefreshTask }
        set { queue.dueRefreshTask = newValue }
    }
    var lastPresentedNoteID: UUID? {
        get { queue.lastPresentedNoteID }
        set { queue.lastPresentedNoteID = newValue }
    }
    var lastPresentedNoteIDBeforeCurrent: UUID? {
        get { queue.lastPresentedNoteIDBeforeCurrent }
        set { queue.lastPresentedNoteIDBeforeCurrent = newValue }
    }
    var siblingDeferredCardID: UUID? {
        get { queue.siblingDeferredCardID }
        set { queue.siblingDeferredCardID = newValue }
    }
    var undoPreferredCardID: UUID? {
        get { queue.undoPreferredCardID }
        set { queue.undoPreferredCardID = newValue }
    }

    // MARK: - 提交状态（ReviewSubmissionCoordinator）

    var pendingSubmission: PendingSubmission? {
        get { submission.pendingSubmission }
        set { submission.pendingSubmission = newValue }
    }
    var lastSubmission: LastSubmission? {
        get { submission.lastSubmission }
        set { submission.lastSubmission = newValue }
    }
    var isSubmitting: Bool {
        get { submission.isSubmitting }
        set { submission.isSubmitting = newValue }
    }
    var isUndoing: Bool {
        get { submission.isUndoing }
        set { submission.isUndoing = newValue }
    }
    var submissionErrorMessage: String? {
        get { submission.submissionErrorMessage }
        set { submission.submissionErrorMessage = newValue }
    }
    var undoErrorMessage: String? {
        get { submission.undoErrorMessage }
        set { submission.undoErrorMessage = newValue }
    }
    var hasCommittedCurrentCard: Bool {
        get { submission.hasCommittedCurrentCard }
        set { submission.hasCommittedCurrentCard = newValue }
    }
    var completedSubmissionCount: Int {
        get { submission.completedSubmissionCount }
        set { submission.completedSubmissionCount = newValue }
    }

    // MARK: - 音频状态（ReviewAudioController）

    var listeningPromptStatus: ListeningPromptPlaybackStatus {
        get { audio.listeningPromptStatus }
        set { audio.listeningPromptStatus = newValue }
    }
    var listeningPromptRequestID: UUID? {
        get { audio.listeningPromptRequestID }
        set { audio.listeningPromptRequestID = newValue }
    }
    var listeningPromptCompleted: Bool {
        get { audio.listeningPromptCompleted }
        set { audio.listeningPromptCompleted = newValue }
    }
    var skippedListeningIDs: Set<UUID> {
        get { audio.skippedListeningIDs }
        set { audio.skippedListeningIDs = newValue }
    }
    var listeningSkipNotice: String? {
        get { audio.listeningSkipNotice }
        set { audio.listeningSkipNotice = newValue }
    }
    var speechErrorMessage: String? {
        get { audio.speechErrorMessage }
        set { audio.speechErrorMessage = newValue }
    }

    // MARK: - 展示状态（ReviewPresentationState）

    var recallAttempt: RecallAttempt? {
        get { presentation.recallAttempt }
        set { presentation.recallAttempt = newValue }
    }
    var presentationID: UUID {
        get { presentation.presentationID }
        set { presentation.presentationID = newValue }
    }
    var answerRevealedAt: Date? {
        get { presentation.answerRevealedAt }
        set { presentation.answerRevealedAt = newValue }
    }
    var leechReminderStatus: AdaptiveCardStatus? {
        get { presentation.leechReminderStatus }
        set { presentation.leechReminderStatus = newValue }
    }
}
