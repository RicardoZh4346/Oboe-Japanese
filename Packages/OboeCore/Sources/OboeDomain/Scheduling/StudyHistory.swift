import Foundation

public struct RatingDistribution: Codable, Equatable, Sendable {
    public let again: Int
    public let hard: Int
    public let good: Int
    public let easy: Int

    public init(again: Int, hard: Int, good: Int, easy: Int) {
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
    }

    public subscript(_ rating: ReviewRating) -> Int {
        switch rating {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }

    public var total: Int { again + hard + good + easy }
}

public struct DeckTodayTaskCount: Codable, Equatable, Identifiable, Sendable {
    public let deckID: UUID
    public let newCount: Int
    public let reviewCount: Int

    public init(deckID: UUID, newCount: Int, reviewCount: Int) {
        self.deckID = deckID
        self.newCount = newCount
        self.reviewCount = reviewCount
    }

    public var id: UUID { deckID }
}

public struct TodayReviewStatistics: Codable, Equatable, Sendable {
    public let newLearnedCount: Int
    public let reviewAnswerCount: Int
    public let answerCount: Int
    public let ratings: RatingDistribution
    public let deckTaskCounts: [DeckTodayTaskCount]

    public init(
        newLearnedCount: Int,
        reviewAnswerCount: Int,
        answerCount: Int,
        ratings: RatingDistribution,
        deckTaskCounts: [DeckTodayTaskCount]
    ) {
        self.newLearnedCount = newLearnedCount
        self.reviewAnswerCount = reviewAnswerCount
        self.answerCount = answerCount
        self.ratings = ratings
        self.deckTaskCounts = deckTaskCounts
    }

    public func tasks(for deckID: UUID) -> DeckTodayTaskCount {
        deckTaskCounts.first { $0.deckID == deckID }
            ?? DeckTodayTaskCount(deckID: deckID, newCount: 0, reviewCount: 0)
    }
}

public struct ReviewHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let rating: ReviewRating
    public let reviewedAt: Date
    public let durationMilliseconds: Int
    public let wasFirstStudy: Bool
    public let nextDueAt: Date
    public let undoneAt: Date?
    public let contentVersion: Int
    public let algorithmVersion: String

    public init(
        id: UUID,
        rating: ReviewRating,
        reviewedAt: Date,
        durationMilliseconds: Int,
        wasFirstStudy: Bool,
        nextDueAt: Date,
        undoneAt: Date?,
        contentVersion: Int,
        algorithmVersion: String
    ) {
        self.id = id
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.durationMilliseconds = durationMilliseconds
        self.wasFirstStudy = wasFirstStudy
        self.nextDueAt = nextDueAt
        self.undoneAt = undoneAt
        self.contentVersion = contentVersion
        self.algorithmVersion = algorithmVersion
    }

    public var isUndone: Bool { undoneAt != nil }
}

public struct CardReviewHistory: Codable, Equatable, Identifiable, Sendable {
    public let cardID: UUID
    public let templateKind: CardTemplateKind
    public let entries: [ReviewHistoryEntry]

    public init(
        cardID: UUID,
        templateKind: CardTemplateKind,
        entries: [ReviewHistoryEntry]
    ) {
        self.cardID = cardID
        self.templateKind = templateKind
        self.entries = entries
    }

    public var id: UUID { cardID }
    public var activeAnswerCount: Int { entries.count { !$0.isUndone } }
    public var lastReviewedAt: Date? {
        entries.first { !$0.isUndone }?.reviewedAt
    }
}

public protocol StudyHistoryRepository: Sendable {
    func fetchTodayStatistics(studyDayID: UUID) async throws -> TodayReviewStatistics
    func fetchCardHistories(noteID: UUID) async throws -> [CardReviewHistory]
}

public struct StudyHistoryService: Sendable {
    private let repository: any StudyHistoryRepository

    public init(repository: any StudyHistoryRepository) {
        self.repository = repository
    }

    public func fetchTodayStatistics(studyDayID: UUID) async throws -> TodayReviewStatistics {
        try await repository.fetchTodayStatistics(studyDayID: studyDayID)
    }

    public func fetchCardHistories(noteID: UUID) async throws -> [CardReviewHistory] {
        try await repository.fetchCardHistories(noteID: noteID)
    }
}
