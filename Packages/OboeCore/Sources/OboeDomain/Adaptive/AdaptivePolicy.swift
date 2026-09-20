import Foundation

/// Centralized thresholds for the adaptive (leech) rules, design §4.2.
///
/// Every value here is a product heuristic default — none of them are FSRS
/// algorithm parameters and none may be reinterpreted per page. Production
/// uses `AdaptivePolicy.standard`; tests may inject variants but the rule
/// semantics stay identical. The version string travels with every
/// `AdaptiveAssessment` so cached/UI surfaces can detect a rule change.
public struct AdaptivePolicy: Equatable, Sendable {
    public static let currentVersion = "adaptive-v1"

    /// Rule A: persisted FSRS lapses at or above this value trigger.
    public var lifetimeLapsesThreshold: Int
    /// Rule B window: number of most-recent valid samples inspected.
    public var recentWindowSize: Int
    /// Rule B: Again count inside a full recent window that triggers.
    public var recentWindowAgainThreshold: Int
    /// Rule C: consecutive Again at the head of the due-review subsequence.
    public var dueAgainStreakThreshold: Int
    /// Rule D / warning short window: number of most-recent samples inspected.
    public var shortWindowSize: Int
    /// Rule D / warning: Again count inside a full short window.
    public var shortWindowAgainThreshold: Int
    /// Rule D: current FSRS difficulty at or above this value.
    public var highDifficultyThreshold: Double
    /// "近期" window: days before `now` during which an Again/due review counts
    /// as recent. A time span, not a number of reviews.
    public var recentDaysWindow: Int
    /// Recovery: number of consecutive most-recent due reviews that must all be
    /// Good/Easy.
    public var recoveryDueReviewCount: Int
    /// Recovery: minimum current stability (days) while state is review.
    public var recoveryMinimumStability: Double
    /// Warning: lifetime lapses at or above this value warn without leech.
    public var warningLapsesThreshold: Int
    /// Warning: due-review Again streak that warns without leech.
    public var warningDueAgainStreakThreshold: Int

    public init(
        lifetimeLapsesThreshold: Int = 6,
        recentWindowSize: Int = 10,
        recentWindowAgainThreshold: Int = 5,
        dueAgainStreakThreshold: Int = 3,
        shortWindowSize: Int = 5,
        shortWindowAgainThreshold: Int = 2,
        highDifficultyThreshold: Double = 8.5,
        recentDaysWindow: Int = 30,
        recoveryDueReviewCount: Int = 3,
        recoveryMinimumStability: Double = 14,
        warningLapsesThreshold: Int = 3,
        warningDueAgainStreakThreshold: Int = 2
    ) {
        self.lifetimeLapsesThreshold = lifetimeLapsesThreshold
        self.recentWindowSize = recentWindowSize
        self.recentWindowAgainThreshold = recentWindowAgainThreshold
        self.dueAgainStreakThreshold = dueAgainStreakThreshold
        self.shortWindowSize = shortWindowSize
        self.shortWindowAgainThreshold = shortWindowAgainThreshold
        self.highDifficultyThreshold = highDifficultyThreshold
        self.recentDaysWindow = recentDaysWindow
        self.recoveryDueReviewCount = recoveryDueReviewCount
        self.recoveryMinimumStability = recoveryMinimumStability
        self.warningLapsesThreshold = warningLapsesThreshold
        self.warningDueAgainStreakThreshold = warningDueAgainStreakThreshold
    }

    public static let standard = AdaptivePolicy()

    public var version: String { Self.currentVersion }
}
