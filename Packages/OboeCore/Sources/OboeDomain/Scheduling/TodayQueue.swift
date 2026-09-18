import Foundation

public enum TodayQueueCategory: String, Codable, Equatable, Sendable {
    case new
    case learning
    case review
    case relearning

    public var priority: Int {
        switch self {
        case .learning, .relearning: 0
        case .review: 1
        case .new: 2
        }
    }
}

public enum TodayQueueAvailability: String, Codable, Equatable, Sendable {
    case now
    case later
}

public struct TodayQueueItem: Codable, Equatable, Sendable {
    public let cardID: UUID
    public let noteID: UUID
    public let deckID: UUID
    public let templateKind: CardTemplateKind
    public let category: TodayQueueCategory
    public let availability: TodayQueueAvailability
    public let dueAt: Date
    public let admittedAt: Date

    public init(
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        templateKind: CardTemplateKind,
        category: TodayQueueCategory,
        availability: TodayQueueAvailability,
        dueAt: Date,
        admittedAt: Date
    ) {
        self.cardID = cardID
        self.noteID = noteID
        self.deckID = deckID
        self.templateKind = templateKind
        self.category = category
        self.availability = availability
        self.dueAt = dueAt
        self.admittedAt = admittedAt
    }
}

public struct TodayStudySummary: Codable, Equatable, Sendable {
    public let newCount: Int
    public let reviewCount: Int
    public let learningCount: Int
    public let completedCount: Int

    public init(
        newCount: Int,
        reviewCount: Int,
        learningCount: Int,
        completedCount: Int
    ) {
        self.newCount = newCount
        self.reviewCount = reviewCount
        self.learningCount = learningCount
        self.completedCount = completedCount
    }

    public var remainingCount: Int { newCount + reviewCount + learningCount }
    public var denominator: Int { completedCount + remainingCount }
    public var completionFraction: Double? {
        denominator == 0 ? nil : Double(completedCount) / Double(denominator)
    }
}

public struct TodayPlan: Codable, Equatable, Sendable {
    public let studyDay: StudyDay
    public let availableNow: [TodayQueueItem]
    public let availableLater: [TodayQueueItem]
    public let summary: TodayStudySummary

    public init(
        studyDay: StudyDay,
        availableNow: [TodayQueueItem],
        availableLater: [TodayQueueItem],
        summary: TodayStudySummary
    ) {
        self.studyDay = studyDay
        self.availableNow = availableNow
        self.availableLater = availableLater
        self.summary = summary
    }

    public var nextAvailableAt: Date? { availableLater.first?.dueAt }
    public var isCurrentSessionComplete: Bool { availableNow.isEmpty }
    public var isDayComplete: Bool { summary.remainingCount == 0 }
}

public protocol TodayQueueRepository: Sendable {
    func buildQueue(for studyDay: StudyDay, at instant: Date) async throws -> TodayPlan
    func fetchSummary(
        for studyDay: StudyDay,
        deckID: UUID?,
        at instant: Date
    ) async throws -> TodayStudySummary
}

public struct BuildTodayPlan: Sendable {
    private let prepareStudyDay: PrepareStudyDay
    private let queueRepository: any TodayQueueRepository

    public init(
        studyDayRepository: any StudyDayPlanningRepository,
        queueRepository: any TodayQueueRepository
    ) {
        prepareStudyDay = PrepareStudyDay(repository: studyDayRepository)
        self.queueRepository = queueRepository
    }

    public func callAsFunction(
        at instant: Date,
        defaultTimeZoneID: String
    ) async throws -> TodayPlan {
        let reservationPlan = try await prepareStudyDay(
            at: instant,
            defaultTimeZoneID: defaultTimeZoneID
        )
        return try await queueRepository.buildQueue(
            for: reservationPlan.studyDay,
            at: instant
        )
    }
}
