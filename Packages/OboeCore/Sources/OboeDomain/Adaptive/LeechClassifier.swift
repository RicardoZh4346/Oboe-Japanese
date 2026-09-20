import Foundation

/// Final per-card adaptive status (design §4.2).
public enum AdaptiveCardStatus: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case leech
}

/// Which rule fired. Kept coarse on purpose — the numbers that explain a
/// trigger live in `AdaptiveMetrics` so every state can be traced back to
/// evidence instead of re-interpreted per page.
public enum AdaptiveTrigger: String, Codable, Equatable, Sendable, CaseIterable {
    /// A: lifetime lapses ≥ threshold.
    case lifetimeLapses
    /// B: full recent window with too many Again.
    case recentAgainBurst
    /// C: consecutive Again at the head of due reviews, last one recent.
    case dueAgainStreak
    /// D: high difficulty plus a short-window failure pattern.
    case persistentDifficulty
}

public struct AdaptiveAssessment: Equatable, Sendable {
    public let status: AdaptiveCardStatus
    /// All rule conditions satisfied by the evidence, even when recovery
    /// currently overrides them — recovery is reported separately.
    public let triggers: [AdaptiveTrigger]
    public let metrics: AdaptiveMetrics
    /// True when recovery evidence holds: recent due reviews all Good/Easy,
    /// the card is back in review with enough stability, and no valid Again
    /// happened since. Reported as "近期表现改善", never as mastery.
    public let isRecovered: Bool
    public let policyVersion: String

    public init(
        status: AdaptiveCardStatus,
        triggers: [AdaptiveTrigger],
        metrics: AdaptiveMetrics,
        isRecovered: Bool,
        policyVersion: String
    ) {
        self.status = status
        self.triggers = triggers
        self.metrics = metrics
        self.isRecovered = isRecovered
        self.policyVersion = policyVersion
    }
}

/// Pure-function leech classifier (design §4). Deterministic for identical
/// evidence: no database access, no UI, `now` injected.
public struct LeechClassifier: Sendable {
    public let policy: AdaptivePolicy

    public init(policy: AdaptivePolicy = .standard) {
        self.policy = policy
    }

    public func assess(
        evidence: AdaptiveCardEvidence,
        at now: Date
    ) -> AdaptiveAssessment {
        let samples = evidence.samples.sorted(by: AdaptiveReviewSample.isOrderedBefore)
        let metrics = Self.metrics(
            for: evidence,
            samples: samples,
            policy: policy
        )
        let triggers = Self.triggers(
            metrics: metrics,
            policy: policy,
            at: now
        )
        let recovered = Self.hasRecoveryEvidence(
            evidence: evidence,
            samples: samples,
            policy: policy
        )

        let status: AdaptiveCardStatus
        if !triggers.isEmpty, !recovered {
            status = .leech
        } else if !recovered, Self.hasWarningEvidence(metrics: metrics, policy: policy) {
            status = .warning
        } else {
            status = .normal
        }
        return AdaptiveAssessment(
            status: status,
            triggers: triggers,
            metrics: metrics,
            isRecovered: recovered,
            policyVersion: policy.version
        )
    }

    // MARK: - Metrics

    static func metrics(
        for evidence: AdaptiveCardEvidence,
        samples: [AdaptiveReviewSample],
        policy: AdaptivePolicy
    ) -> AdaptiveMetrics {
        let recent = samples.prefix(policy.recentWindowSize)
        let recentAgain = recent.filter { $0.rating == .again }.count
        let short = samples.prefix(policy.shortWindowSize)
        let shortAgain = short.filter { $0.rating == .again }.count
        let totalAgain = samples.count { $0.rating == .again }
        let lastAgainAt = samples.first { $0.rating == .again }?.reviewedAt

        let dueReviews = samples.filter(\.isDueReview)
        var streak = 0
        for sample in dueReviews {
            guard sample.rating == .again else { break }
            streak += 1
        }
        var consecutiveSuccesses = 0
        for sample in dueReviews {
            guard sample.rating == .good || sample.rating == .easy else { break }
            consecutiveSuccesses += 1
        }
        let lastDue = dueReviews.first
        let lastDueIntervalDays = lastDue.map {
            $0.reviewedAt.timeIntervalSince($0.previousState.scheduling.dueAt) / 86_400
        }

        return AdaptiveMetrics(
            lifetimeLapses: evidence.scheduling.lapses,
            recentCount: recent.count,
            recentAgainCount: recentAgain,
            shortWindowAgainCount: shortAgain,
            totalCount: samples.count,
            totalAgainCount: totalAgain,
            againRatio: samples.isEmpty ? nil : Double(totalAgain) / Double(samples.count),
            dueAgainStreak: streak,
            lastDueReviewAt: lastDue?.reviewedAt,
            lastAgainAt: lastAgainAt,
            lastDueIntervalDays: lastDueIntervalDays,
            difficulty: evidence.scheduling.difficulty,
            stability: evidence.scheduling.stability,
            consecutiveDueSuccesses: consecutiveSuccesses
        )
    }

    // MARK: - Triggers A/B/C/D

    static func triggers(
        metrics: AdaptiveMetrics,
        policy: AdaptivePolicy,
        at now: Date
    ) -> [AdaptiveTrigger] {
        var triggers: [AdaptiveTrigger] = []

        if metrics.lifetimeLapses >= policy.lifetimeLapsesThreshold {
            triggers.append(.lifetimeLapses)
        }
        if metrics.recentCount == policy.recentWindowSize,
           metrics.recentAgainCount >= policy.recentWindowAgainThreshold {
            triggers.append(.recentAgainBurst)
        }
        if metrics.dueAgainStreak >= policy.dueAgainStreakThreshold,
           isRecent(metrics.lastDueReviewAt, at: now, policy: policy) {
            triggers.append(.dueAgainStreak)
        }
        if metrics.difficulty >= policy.highDifficultyThreshold,
           metrics.recentCount >= policy.shortWindowSize,
           metrics.shortWindowAgainCount >= policy.shortWindowAgainThreshold,
           isRecent(metrics.lastAgainAt, at: now, policy: policy) {
            triggers.append(.persistentDifficulty)
        }
        return triggers
    }

    // MARK: - Warning

    static func hasWarningEvidence(
        metrics: AdaptiveMetrics,
        policy: AdaptivePolicy
    ) -> Bool {
        metrics.lifetimeLapses >= policy.warningLapsesThreshold
            || (metrics.recentCount >= policy.shortWindowSize
                && metrics.shortWindowAgainCount >= policy.shortWindowAgainThreshold)
            || metrics.dueAgainStreak >= policy.warningDueAgainStreakThreshold
    }

    // MARK: - Recovery

    /// The newest `recoveryDueReviewCount` due reviews must all be Good/Easy,
    /// the card must currently be in review with enough stability, and no
    /// valid Again of any kind may exist after the earliest of those due
    /// reviews (array order defines "after"). A new Again therefore voids the
    /// evidence and lets triggers fire again — relapse is supported.
    static func hasRecoveryEvidence(
        evidence: AdaptiveCardEvidence,
        samples: [AdaptiveReviewSample],
        policy: AdaptivePolicy
    ) -> Bool {
        let dueReviews = samples.filter(\.isDueReview)
        guard dueReviews.count >= policy.recoveryDueReviewCount else {
            return false
        }
        let window = dueReviews.prefix(policy.recoveryDueReviewCount)
        guard window.allSatisfy({ $0.rating == .good || $0.rating == .easy }) else {
            return false
        }
        guard evidence.scheduling.state == .review,
              evidence.scheduling.stability >= policy.recoveryMinimumStability else {
            return false
        }
        guard let earliest = window.last,
              let earliestIndex = samples.firstIndex(where: { $0.logID == earliest.logID }) else {
            return false
        }
        return !samples[..<earliestIndex].contains { $0.rating == .again }
    }

    static func isRecent(
        _ date: Date?,
        at now: Date,
        policy: AdaptivePolicy
    ) -> Bool {
        guard let date else { return false }
        return date >= now.addingTimeInterval(-TimeInterval(policy.recentDaysWindow) * 86_400)
    }
}
