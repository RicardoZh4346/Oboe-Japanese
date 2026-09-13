import Foundation

public enum SchedulingState: Int, CaseIterable, Codable, Hashable, Sendable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

public enum ReviewRating: Int, CaseIterable, Codable, Hashable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

public struct SchedulingCard: Codable, Equatable, Hashable, Sendable {
    public let dueAt: Date
    public let stability: Double
    public let difficulty: Double
    public let elapsedDays: Double
    public let scheduledDays: Double
    public let learningStep: Int
    public let repetitions: Int
    public let lapses: Int
    public let state: SchedulingState
    public let lastReviewAt: Date?

    public init(
        dueAt: Date,
        stability: Double = 0,
        difficulty: Double = 0,
        elapsedDays: Double = 0,
        scheduledDays: Double = 0,
        learningStep: Int = 0,
        repetitions: Int = 0,
        lapses: Int = 0,
        state: SchedulingState = .new,
        lastReviewAt: Date? = nil
    ) {
        self.dueAt = dueAt
        self.stability = stability
        self.difficulty = difficulty
        self.elapsedDays = elapsedDays
        self.scheduledDays = scheduledDays
        self.learningStep = learningStep
        self.repetitions = repetitions
        self.lapses = lapses
        self.state = state
        self.lastReviewAt = lastReviewAt
    }
}

public enum RetentionPreset: Int, CaseIterable, Codable, Hashable, Sendable {
    case light = 85
    case standard = 90
    case intensive = 95

    public var targetRetention: Double {
        Double(rawValue) / 100
    }
}

public struct SchedulerProfile: Codable, Equatable, Sendable {
    public static let fsrs6DefaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133,
        0.8334, 3.0194, 0.001, 1.8722, 0.1666,
        0.796, 1.4835, 0.0614, 0.2629, 1.6483,
        0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
        0.1542
    ]

    public static let standard = SchedulerProfile(preset: .standard)

    public let configurationVersion: String
    public let targetRetention: Double
    public let maximumIntervalDays: Double
    public let parameters: [Double]
    public let learningSteps: [String]
    public let relearningSteps: [String]

    public init(
        preset: RetentionPreset,
        configurationVersion: String? = nil,
        maximumIntervalDays: Double = 36_500,
        parameters: [Double] = SchedulerProfile.fsrs6DefaultParameters,
        learningSteps: [String] = ["1m", "10m"],
        relearningSteps: [String] = ["10m"]
    ) {
        self.configurationVersion = configurationVersion
            ?? "fsrs-6.0-default-r\(preset.rawValue)-v1"
        self.targetRetention = preset.targetRetention
        self.maximumIntervalDays = maximumIntervalDays
        self.parameters = parameters
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
    }

    public init(
        configurationVersion: String,
        targetRetention: Double,
        maximumIntervalDays: Double,
        parameters: [Double],
        learningSteps: [String] = ["1m", "10m"],
        relearningSteps: [String] = ["10m"]
    ) {
        self.configurationVersion = configurationVersion
        self.targetRetention = targetRetention
        self.maximumIntervalDays = maximumIntervalDays
        self.parameters = parameters
        self.learningSteps = learningSteps
        self.relearningSteps = relearningSteps
    }
}

public struct ReviewChoice: Codable, Equatable, Hashable, Sendable {
    public let rating: ReviewRating
    public let card: SchedulingCard
    public let reviewedAt: Date
    public let configurationVersion: String

    public init(
        rating: ReviewRating,
        card: SchedulingCard,
        reviewedAt: Date,
        configurationVersion: String
    ) {
        self.rating = rating
        self.card = card
        self.reviewedAt = reviewedAt
        self.configurationVersion = configurationVersion
    }

    public var dueAt: Date { card.dueAt }
}

public struct ReviewChoices: Codable, Equatable, Sendable {
    public let again: ReviewChoice
    public let hard: ReviewChoice
    public let good: ReviewChoice
    public let easy: ReviewChoice

    public init(
        again: ReviewChoice,
        hard: ReviewChoice,
        good: ReviewChoice,
        easy: ReviewChoice
    ) {
        self.again = again
        self.hard = hard
        self.good = good
        self.easy = easy
    }

    public subscript(rating: ReviewRating) -> ReviewChoice {
        switch rating {
        case .again: again
        case .hard: hard
        case .good: good
        case .easy: easy
        }
    }
}

public protocol ReviewScheduler: Sendable {
    func preview(
        card: SchedulingCard,
        at reviewTime: Date,
        profile: SchedulerProfile
    ) throws -> ReviewChoices
}
