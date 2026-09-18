import Foundation

public struct ReviewCardContent: Equatable, Sendable {
    public let cardID: UUID
    public let noteID: UUID
    public let deckID: UUID
    public let templateKind: CardTemplateKind
    public let headword: String
    public let reading: String?
    public let meaningZH: String
    public let partOfSpeech: String?
    public let usage: String?
    public let connection: String?
    public let exampleJapanese: String?
    public let exampleTranslationZH: String?
    public let notes: String?

    public init(
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        templateKind: CardTemplateKind,
        headword: String,
        reading: String?,
        meaningZH: String,
        partOfSpeech: String?,
        usage: String?,
        connection: String?,
        exampleJapanese: String?,
        exampleTranslationZH: String?,
        notes: String?
    ) {
        self.cardID = cardID
        self.noteID = noteID
        self.deckID = deckID
        self.templateKind = templateKind
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.usage = usage
        self.connection = connection
        self.exampleJapanese = exampleJapanese
        self.exampleTranslationZH = exampleTranslationZH
        self.notes = notes
    }
}

public struct LoadedReviewCard: Equatable, Sendable {
    public let content: ReviewCardContent
    public let stateVersion: Int
    public let choices: ReviewChoices
    public let loadedAt: Date

    public init(
        content: ReviewCardContent,
        stateVersion: Int,
        choices: ReviewChoices,
        loadedAt: Date
    ) {
        self.content = content
        self.stateVersion = stateVersion
        self.choices = choices
        self.loadedAt = loadedAt
    }
}

public protocol ReviewCardContentRepository: Sendable {
    func fetchReviewCardContent(cardID: UUID) async throws -> ReviewCardContent?
}

public enum StudySessionError: Error, Equatable, Sendable {
    case cardUnavailable
    case inconsistentCardContent
}

public struct StudySessionService: Sendable {
    private let planBuilder: BuildTodayPlan
    private let settingsManager: PrepareStudyDay
    private let queueRepository: any TodayQueueRepository
    private let contentRepository: any ReviewCardContentRepository
    private let submissionRepository: any ReviewSubmissionRepository
    private let undoRepository: any ReviewUndoRepository
    private let scheduler: any ReviewScheduler
    private let clock: any SchedulingClock

    public init(
        studyDayRepository: any StudyDayPlanningRepository,
        queueRepository: any TodayQueueRepository,
        contentRepository: any ReviewCardContentRepository,
        submissionRepository: any ReviewSubmissionRepository,
        undoRepository: any ReviewUndoRepository,
        scheduler: any ReviewScheduler,
        clock: any SchedulingClock = SystemSchedulingClock()
    ) {
        settingsManager = PrepareStudyDay(repository: studyDayRepository)
        planBuilder = BuildTodayPlan(
            studyDayRepository: studyDayRepository,
            queueRepository: queueRepository
        )
        self.queueRepository = queueRepository
        self.contentRepository = contentRepository
        self.submissionRepository = submissionRepository
        self.undoRepository = undoRepository
        self.scheduler = scheduler
        self.clock = clock
    }

    public func buildTodayPlan(defaultTimeZoneID: String) async throws -> TodayPlan {
        try await planBuilder(at: clock.now(), defaultTimeZoneID: defaultTimeZoneID)
    }

    public func fetchScopeSummary(
        studyDay: StudyDay,
        deckID: UUID?
    ) async throws -> TodayStudySummary {
        try await queueRepository.fetchSummary(
            for: studyDay,
            deckID: deckID,
            at: clock.now()
        )
    }

    public func loadLearningSettings(
        defaultTimeZoneID: String
    ) async throws -> StudyPlanningSettings {
        try await settingsManager.loadSettings(defaultTimeZoneID: defaultTimeZoneID)
    }

    public func setDailyNewCardLimit(
        _ limit: Int,
        defaultTimeZoneID: String
    ) async throws -> TodayPlan {
        let plan = try await settingsManager.setDailyNewCardLimit(
            limit,
            at: clock.now(),
            defaultTimeZoneID: defaultTimeZoneID
        )
        return try await queueRepository.buildQueue(for: plan.studyDay, at: clock.now())
    }

    public func setLearningTimeZone(
        _ timeZoneID: String,
        defaultTimeZoneID: String
    ) async throws -> StudyPlanningSettings {
        try await settingsManager.setLearningTimeZone(
            timeZoneID,
            defaultTimeZoneID: defaultTimeZoneID
        )
    }

    public func setRetentionPreset(
        _ preset: RetentionPreset,
        defaultTimeZoneID: String
    ) async throws -> StudyPlanningSettings {
        try await settingsManager.setRetentionPreset(
            preset,
            defaultTimeZoneID: defaultTimeZoneID
        )
    }

    public func loadReviewCard(cardID: UUID) async throws -> LoadedReviewCard {
        async let contextRequest = submissionRepository.fetchReviewContext(cardID: cardID)
        async let contentRequest = contentRepository.fetchReviewCardContent(cardID: cardID)
        guard let context = try await contextRequest,
              context.card.isEnabled,
              let content = try await contentRequest else {
            throw StudySessionError.cardUnavailable
        }
        guard context.card.id == content.cardID,
              context.card.noteID == content.noteID,
              context.card.templateKind == content.templateKind,
              context.deckID == content.deckID else {
            throw StudySessionError.inconsistentCardContent
        }
        let loadedAt = clock.now()
        return LoadedReviewCard(
            content: content,
            stateVersion: context.card.stateVersion,
            choices: try scheduler.preview(
                card: context.card.scheduling,
                at: loadedAt,
                profile: context.profile
            ),
            loadedAt: loadedAt
        )
    }

    public func submit(
        card: LoadedReviewCard,
        rating: ReviewRating,
        studyDay: StudyDay,
        eventID: UUID,
        durationMilliseconds: Int
    ) async throws -> ReviewLogRecord {
        try await SubmitReview(
            repository: submissionRepository,
            scheduler: scheduler,
            clock: clock
        )(
            SubmitReviewRequest(
                eventID: eventID,
                cardID: card.content.cardID,
                expectedStateVersion: card.stateVersion,
                rating: rating,
                durationMilliseconds: durationMilliseconds,
                studyDay: studyDay.context
            )
        )
    }

    public func undoLastReview(
        eventID: UUID,
        studyDay: StudyDay
    ) async throws -> ReviewLogRecord {
        try await UndoReview(repository: undoRepository, clock: clock)(
            UndoReviewRequest(eventID: eventID, studyDay: studyDay.context)
        )
    }
}
