import Foundation

public struct StudyDayContext: Codable, Equatable, Hashable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

public struct SubmitReviewRequest: Equatable, Sendable {
    public let eventID: UUID
    public let cardID: UUID
    public let expectedStateVersion: Int
    public let rating: ReviewRating
    public let durationMilliseconds: Int
    public let studyDay: StudyDayContext

    public init(
        eventID: UUID,
        cardID: UUID,
        expectedStateVersion: Int,
        rating: ReviewRating,
        durationMilliseconds: Int,
        studyDay: StudyDayContext
    ) {
        self.eventID = eventID
        self.cardID = cardID
        self.expectedStateVersion = expectedStateVersion
        self.rating = rating
        self.durationMilliseconds = durationMilliseconds
        self.studyDay = studyDay
    }
}

public struct ReviewSchedulingSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let scheduling: SchedulingCard
    public let firstStudiedAt: Date?
    public let stateVersion: Int
    public let algorithmVersion: String
    public let profileID: UUID

    public init(
        schemaVersion: Int = ReviewSchedulingSnapshot.currentSchemaVersion,
        scheduling: SchedulingCard,
        firstStudiedAt: Date?,
        stateVersion: Int,
        algorithmVersion: String,
        profileID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.scheduling = scheduling
        self.firstStudiedAt = firstStudiedAt
        self.stateVersion = stateVersion
        self.algorithmVersion = algorithmVersion
        self.profileID = profileID
    }
}

public struct ReviewLogRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let eventID: UUID
    public let cardID: UUID?
    public let cardKey: UUID
    public let noteID: UUID
    public let deckIDAtReview: UUID
    public let reviewedAt: Date
    public let studyDayID: UUID
    public let wasFirstStudy: Bool
    public let rating: ReviewRating
    public let previousState: ReviewSchedulingSnapshot
    public let nextState: ReviewSchedulingSnapshot
    public let durationMilliseconds: Int
    public let contentVersion: Int
    public let profileID: UUID
    public let algorithmVersion: String
    public let undoneAt: Date?

    public init(
        id: UUID,
        eventID: UUID,
        cardID: UUID?,
        cardKey: UUID,
        noteID: UUID,
        deckIDAtReview: UUID,
        reviewedAt: Date,
        studyDayID: UUID,
        wasFirstStudy: Bool,
        rating: ReviewRating,
        previousState: ReviewSchedulingSnapshot,
        nextState: ReviewSchedulingSnapshot,
        durationMilliseconds: Int,
        contentVersion: Int,
        profileID: UUID,
        algorithmVersion: String,
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.cardID = cardID
        self.cardKey = cardKey
        self.noteID = noteID
        self.deckIDAtReview = deckIDAtReview
        self.reviewedAt = reviewedAt
        self.studyDayID = studyDayID
        self.wasFirstStudy = wasFirstStudy
        self.rating = rating
        self.previousState = previousState
        self.nextState = nextState
        self.durationMilliseconds = durationMilliseconds
        self.contentVersion = contentVersion
        self.profileID = profileID
        self.algorithmVersion = algorithmVersion
        self.undoneAt = undoneAt
    }
}

public struct ReviewSubmissionContext: Equatable, Sendable {
    public let card: PersistedSchedulingCard
    public let profile: SchedulerProfile
    public let deckID: UUID
    public let contentVersion: Int
    public let algorithmVersion: String

    public init(
        card: PersistedSchedulingCard,
        profile: SchedulerProfile,
        deckID: UUID,
        contentVersion: Int,
        algorithmVersion: String
    ) {
        self.card = card
        self.profile = profile
        self.deckID = deckID
        self.contentVersion = contentVersion
        self.algorithmVersion = algorithmVersion
    }
}

public struct ReviewSubmissionMutation: Equatable, Sendable {
    public let request: SubmitReviewRequest
    public let noteID: UUID
    public let deckIDAtReview: UUID
    public let reviewedAt: Date
    public let wasFirstStudy: Bool
    public let previousState: ReviewSchedulingSnapshot
    public let nextState: ReviewSchedulingSnapshot
    public let contentVersion: Int

    public init(
        request: SubmitReviewRequest,
        noteID: UUID,
        deckIDAtReview: UUID,
        reviewedAt: Date,
        wasFirstStudy: Bool,
        previousState: ReviewSchedulingSnapshot,
        nextState: ReviewSchedulingSnapshot,
        contentVersion: Int
    ) {
        self.request = request
        self.noteID = noteID
        self.deckIDAtReview = deckIDAtReview
        self.reviewedAt = reviewedAt
        self.wasFirstStudy = wasFirstStudy
        self.previousState = previousState
        self.nextState = nextState
        self.contentVersion = contentVersion
    }
}

public protocol ReviewSubmissionRepository: Sendable {
    func fetchSubmittedReview(eventID: UUID) async throws -> ReviewLogRecord?
    func fetchReviewContext(cardID: UUID) async throws -> ReviewSubmissionContext?
    func commitReview(_ mutation: ReviewSubmissionMutation) async throws -> ReviewLogRecord
}

public enum SubmitReviewError: Error, Equatable, Sendable {
    case cardNotFound
    case cardDisabled
    case invalidDuration
    case stateVersionConflict(expected: Int, actual: Int)
    case staleReviewContext
    case invalidPersistedRating(Int)
    case studyDayNotActive
    case cardNotInStudyPlan
    case cardNotDue(until: Date)
    case clockMovedBackward(lastReviewAt: Date, attemptedAt: Date)
}

public struct SubmitReview: Sendable {
    private let repository: any ReviewSubmissionRepository
    private let scheduler: any ReviewScheduler
    private let clock: any SchedulingClock

    public init(
        repository: any ReviewSubmissionRepository,
        scheduler: any ReviewScheduler,
        clock: any SchedulingClock = SystemSchedulingClock()
    ) {
        self.repository = repository
        self.scheduler = scheduler
        self.clock = clock
    }

    public func callAsFunction(_ request: SubmitReviewRequest) async throws -> ReviewLogRecord {
        if let existing = try await repository.fetchSubmittedReview(eventID: request.eventID) {
            return existing
        }
        guard request.durationMilliseconds >= 0 else {
            throw SubmitReviewError.invalidDuration
        }
        guard let context = try await repository.fetchReviewContext(cardID: request.cardID) else {
            throw SubmitReviewError.cardNotFound
        }
        guard context.card.isEnabled else {
            throw SubmitReviewError.cardDisabled
        }
        guard context.card.stateVersion == request.expectedStateVersion else {
            throw SubmitReviewError.stateVersionConflict(
                expected: request.expectedStateVersion,
                actual: context.card.stateVersion
            )
        }

        let reviewedAt = clock.now()
        if let lastReviewAt = context.card.scheduling.lastReviewAt,
           reviewedAt < lastReviewAt {
            throw SubmitReviewError.clockMovedBackward(
                lastReviewAt: lastReviewAt,
                attemptedAt: reviewedAt
            )
        }
        if context.card.scheduling.state != .new,
           context.card.scheduling.dueAt > reviewedAt {
            throw SubmitReviewError.cardNotDue(until: context.card.scheduling.dueAt)
        }
        let choice = try scheduler.preview(
            card: context.card.scheduling,
            at: reviewedAt,
            profile: context.profile
        )[request.rating]
        let wasFirstStudy = context.card.firstStudiedAt == nil
        let firstStudiedAt = context.card.firstStudiedAt ?? reviewedAt
        let previousState = ReviewSchedulingSnapshot(
            scheduling: context.card.scheduling,
            firstStudiedAt: context.card.firstStudiedAt,
            stateVersion: context.card.stateVersion,
            algorithmVersion: context.card.algorithmVersion,
            profileID: context.card.profileID
        )
        let nextState = ReviewSchedulingSnapshot(
            scheduling: choice.card,
            firstStudiedAt: firstStudiedAt,
            stateVersion: context.card.stateVersion + 1,
            algorithmVersion: context.algorithmVersion,
            profileID: context.card.profileID
        )
        return try await repository.commitReview(
            ReviewSubmissionMutation(
                request: request,
                noteID: context.card.noteID,
                deckIDAtReview: context.deckID,
                reviewedAt: reviewedAt,
                wasFirstStudy: wasFirstStudy,
                previousState: previousState,
                nextState: nextState,
                contentVersion: context.contentVersion
            )
        )
    }
}
