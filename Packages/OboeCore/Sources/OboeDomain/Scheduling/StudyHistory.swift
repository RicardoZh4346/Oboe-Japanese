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

public struct StudyCompletionStatistics: Codable, Equatable, Sendable {
    public let newLearnedCardCount: Int
    public let reviewedCardCount: Int
    public let answerCount: Int
    public let ratings: RatingDistribution

    public init(
        newLearnedCardCount: Int,
        reviewedCardCount: Int,
        answerCount: Int,
        ratings: RatingDistribution
    ) {
        self.newLearnedCardCount = newLearnedCardCount
        self.reviewedCardCount = reviewedCardCount
        self.answerCount = answerCount
        self.ratings = ratings
    }

    public var studiedCardCount: Int { newLearnedCardCount + reviewedCardCount }
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

/// v0.5.5「每日统计」行：一个学习日（按 04:00 边界与学习时区切分，
/// `localDate` 即 `study_days.local_date`）的有效评分聚合。
/// 只统计 `undone_at_ms IS NULL` 的日志；多牌组共享的 Card 按唯一
/// 日志计一次，不随成员关系放大。
public struct DailyStudyStatistics: Equatable, Identifiable, Sendable {
    public let localDate: String
    /// 当日首学的 Note 数（按 note_id 去重，与首页「新词」口径一致）。
    public let newLearnedCount: Int
    /// 当日实际复习过的 Card 数（非首学，按 card_key 去重）。
    public let reviewedCardCount: Int
    /// 当日有效评分事件总数（同一卡重复评分累计）。
    public let answerCount: Int
    public let durationMilliseconds: Int
    public let ratings: RatingDistribution

    public init(
        localDate: String,
        newLearnedCount: Int,
        reviewedCardCount: Int,
        answerCount: Int,
        durationMilliseconds: Int,
        ratings: RatingDistribution
    ) {
        self.localDate = localDate
        self.newLearnedCount = newLearnedCount
        self.reviewedCardCount = reviewedCardCount
        self.answerCount = answerCount
        self.durationMilliseconds = durationMilliseconds
        self.ratings = ratings
    }

    public var id: String { localDate }
    public var hasActivity: Bool { answerCount > 0 }
}

/// 最近 N 个学习日（含今天、新日期在前、固定 N 行零补齐）与连续学习天数。
/// `currentStreak` 按「今天已学则从今天起连续计；今天未学但昨天已学则
/// 保留截至昨天的连续天数」规则派生，不持久化。
public struct StudyStatisticsSnapshot: Equatable, Sendable {
    public let currentStreak: Int
    public let days: [DailyStudyStatistics]

    public init(currentStreak: Int, days: [DailyStudyStatistics]) {
        self.currentStreak = currentStreak
        self.days = days
    }

    public var activeDayCount: Int { days.count { $0.hasActivity } }
}

public protocol StudyHistoryRepository: Sendable {
    func fetchTodayStatistics(studyDayID: UUID) async throws -> TodayReviewStatistics
    func fetchCompletionStatistics(
        studyDayID: UUID,
        deckID: UUID?
    ) async throws -> StudyCompletionStatistics
    func fetchCardHistories(noteID: UUID) async throws -> [CardReviewHistory]
    /// 以 `studyDay`（今天）为终点向前取 `dayCount` 个学习日；
    /// 没有记录的学习日补零，保证返回行数恒定。
    func fetchDailyStatistics(
        endingAt studyDay: StudyDay,
        dayCount: Int
    ) async throws -> StudyStatisticsSnapshot
}

public struct StudyHistoryService: Sendable {
    private let repository: any StudyHistoryRepository

    public init(repository: any StudyHistoryRepository) {
        self.repository = repository
    }

    public func fetchTodayStatistics(studyDayID: UUID) async throws -> TodayReviewStatistics {
        try await repository.fetchTodayStatistics(studyDayID: studyDayID)
    }

    public func fetchCompletionStatistics(
        studyDayID: UUID,
        deckID: UUID? = nil
    ) async throws -> StudyCompletionStatistics {
        try await repository.fetchCompletionStatistics(studyDayID: studyDayID, deckID: deckID)
    }

    public func fetchCardHistories(noteID: UUID) async throws -> [CardReviewHistory] {
        try await repository.fetchCardHistories(noteID: noteID)
    }

    public func fetchDailyStatistics(
        endingAt studyDay: StudyDay,
        dayCount: Int = 30
    ) async throws -> StudyStatisticsSnapshot {
        try await repository.fetchDailyStatistics(endingAt: studyDay, dayCount: dayCount)
    }
}
