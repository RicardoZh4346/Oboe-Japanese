import Foundation
import FSRS
import OboeDomain

public enum SwiftFSRSSchedulerError: Error, Equatable, Sendable {
    case invalidParameterCount(Int)
    case invalidTargetRetention(Double)
    case invalidMaximumInterval(Double)
    case missingChoice(ReviewRating)
    case upstream(String)
}

public struct SwiftFSRSReviewScheduler: ReviewScheduler, Sendable {
    public static let dependencyRevision = "4fbaf20184d62f82a9f44f343337c61a2c5483e9"
    public static let algorithmVersion = "FSRS-6.0"

    private let clock: any SchedulingClock

    public init(clock: any SchedulingClock = SystemSchedulingClock()) {
        self.clock = clock
    }

    public func preview(
        card: SchedulingCard,
        profile: SchedulerProfile
    ) throws -> ReviewChoices {
        try preview(card: card, at: clock.now(), profile: profile)
    }

    public func preview(
        card: SchedulingCard,
        at reviewTime: Date,
        profile: SchedulerProfile
    ) throws -> ReviewChoices {
        guard profile.parameters.count == 21 else {
            throw SwiftFSRSSchedulerError.invalidParameterCount(profile.parameters.count)
        }
        guard profile.targetRetention.isFinite,
              profile.targetRetention > 0,
              profile.targetRetention <= 1 else {
            throw SwiftFSRSSchedulerError.invalidTargetRetention(profile.targetRetention)
        }
        guard profile.maximumIntervalDays.isFinite,
              profile.maximumIntervalDays >= 1 else {
            throw SwiftFSRSSchedulerError.invalidMaximumInterval(profile.maximumIntervalDays)
        }

        let parameters = FSRSParameters(
            requestRetention: profile.targetRetention,
            maximumInterval: profile.maximumIntervalDays,
            w: profile.parameters,
            enableFuzz: false,
            enableShortTerm: true,
            learningSteps: profile.learningSteps,
            relearningSteps: profile.relearningSteps
        )
        let engine = FSRS(parameters: parameters)

        guard engine.version == .v6 else {
            throw SwiftFSRSSchedulerError.invalidParameterCount(engine.parameters.w.count)
        }

        do {
            let preview = try engine.repeat(card: card.fsrsCard, now: reviewTime)
            return try ReviewChoices(
                again: choice(.again, from: preview, reviewedAt: reviewTime, profile: profile),
                hard: choice(.hard, from: preview, reviewedAt: reviewTime, profile: profile),
                good: choice(.good, from: preview, reviewedAt: reviewTime, profile: profile),
                easy: choice(.easy, from: preview, reviewedAt: reviewTime, profile: profile)
            )
        } catch let error as SwiftFSRSSchedulerError {
            throw error
        } catch {
            throw SwiftFSRSSchedulerError.upstream(String(describing: error))
        }
    }

    private func choice(
        _ rating: ReviewRating,
        from preview: IPreview,
        reviewedAt: Date,
        profile: SchedulerProfile
    ) throws -> ReviewChoice {
        guard let item = preview[rating.fsrsRating] else {
            throw SwiftFSRSSchedulerError.missingChoice(rating)
        }
        return ReviewChoice(
            rating: rating,
            card: SchedulingCard(item.card),
            reviewedAt: reviewedAt,
            configurationVersion: profile.configurationVersion
        )
    }
}

private extension SchedulingCard {
    var fsrsCard: Card {
        Card(
            due: dueAt,
            stability: stability,
            difficulty: difficulty,
            elapsedDays: elapsedDays,
            scheduledDays: scheduledDays,
            learningSteps: learningStep,
            reps: repetitions,
            lapses: lapses,
            state: state.fsrsState,
            lastReview: lastReviewAt
        )
    }

    init(_ card: Card) {
        self.init(
            dueAt: card.due,
            stability: card.stability,
            difficulty: card.difficulty,
            elapsedDays: card.elapsedDays,
            scheduledDays: card.scheduledDays,
            learningStep: card.learningSteps,
            repetitions: card.reps,
            lapses: card.lapses,
            state: SchedulingState(card.state),
            lastReviewAt: card.lastReview
        )
    }
}

private extension SchedulingState {
    var fsrsState: CardState {
        switch self {
        case .new: .new
        case .learning: .learning
        case .review: .review
        case .relearning: .relearning
        }
    }

    init(_ state: CardState) {
        switch state {
        case .new: self = .new
        case .learning: self = .learning
        case .review: self = .review
        case .relearning: self = .relearning
        }
    }
}

private extension ReviewRating {
    var fsrsRating: Rating {
        switch self {
        case .again: .again
        case .hard: .hard
        case .good: .good
        case .easy: .easy
        }
    }
}
