import Foundation

/// One valid (non-undone) review log reduced to what the classifier needs.
///
/// Ordering contract (design §4.1): samples are presented most-recent-first by
/// `reviewedAt`, ties broken by `nextState.stateVersion` descending then by
/// `logID` (stable). `LeechClassifier` re-sorts defensively, but repositories
/// must already apply this order at the SQL boundary so same-millisecond
/// windows never silently truncate evidence.
public struct AdaptiveReviewSample: Equatable, Sendable {
    public let logID: UUID
    public let rating: ReviewRating
    public let reviewedAt: Date
    public let wasFirstStudy: Bool
    /// Note content version this rating was made against — detail labels
    /// history per content version (design §4.1); the classifier ignores it.
    public let contentVersion: Int
    public let previousState: ReviewSchedulingSnapshot
    public let nextState: ReviewSchedulingSnapshot

    public init(
        logID: UUID,
        rating: ReviewRating,
        reviewedAt: Date,
        wasFirstStudy: Bool,
        contentVersion: Int = 1,
        previousState: ReviewSchedulingSnapshot,
        nextState: ReviewSchedulingSnapshot
    ) {
        self.logID = logID
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.wasFirstStudy = wasFirstStudy
        self.contentVersion = contentVersion
        self.previousState = previousState
        self.nextState = nextState
    }

    /// A "到期 Review" sample: the card was in `review` state, already due when
    /// rated, and this was not its first study. Learning/relearning steps and
    /// first-study logs never join this subsequence — they neither extend nor
    /// interrupt it (design §4.1).
    public var isDueReview: Bool {
        !wasFirstStudy
            && previousState.scheduling.state == .review
            && previousState.scheduling.dueAt <= reviewedAt
    }

    /// Stable ordering key, most-recent-first. Public so repositories can
    /// apply the same contract at the SQL boundary.
    public static func isOrderedBefore(_ lhs: AdaptiveReviewSample, _ rhs: AdaptiveReviewSample) -> Bool {
        if lhs.reviewedAt != rhs.reviewedAt {
            return lhs.reviewedAt > rhs.reviewedAt
        }
        if lhs.nextState.stateVersion != rhs.nextState.stateVersion {
            return lhs.nextState.stateVersion > rhs.nextState.stateVersion
        }
        return lhs.logID.uuidString < rhs.logID.uuidString
    }
}

/// Per-card evidence the classifier consumes. `samples` must contain only
/// valid logs for `cardID` (undone rows excluded upstream); deleted cards are
/// never assessed because their `card_key` history must not reattach to a
/// later card of the same direction.
public struct AdaptiveCardEvidence: Equatable, Sendable {
    public let cardID: UUID
    public let noteID: UUID
    public let deckID: UUID
    public let templateKind: CardTemplateKind
    public let isEnabled: Bool
    public let scheduling: SchedulingCard
    public let firstStudiedAt: Date?
    public let samples: [AdaptiveReviewSample]

    public init(
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        templateKind: CardTemplateKind,
        isEnabled: Bool,
        scheduling: SchedulingCard,
        firstStudiedAt: Date?,
        samples: [AdaptiveReviewSample]
    ) {
        self.cardID = cardID
        self.noteID = noteID
        self.deckID = deckID
        self.templateKind = templateKind
        self.isEnabled = isEnabled
        self.scheduling = scheduling
        self.firstStudiedAt = firstStudiedAt
        self.samples = samples
    }
}

/// Computed metrics (design §4.2). Everything is derived — never persisted —
/// so an assessment can always be re-explained from the same evidence.
public struct AdaptiveMetrics: Equatable, Sendable {
    /// Current persisted FSRS lapses; read, never recomputed.
    public let lifetimeLapses: Int
    /// Number of valid samples inside the recent window (≤ policy window).
    public let recentCount: Int
    /// Again count inside the recent window.
    public let recentAgainCount: Int
    /// Again count inside the short window (≤ policy short window).
    public let shortWindowAgainCount: Int
    /// Total valid samples for this card.
    public let totalCount: Int
    /// Total valid Again samples.
    public let totalAgainCount: Int
    /// Again / total across all valid samples; `nil` when there are no
    /// samples — "暂无评分" is not 0 %.
    public let againRatio: Double?
    /// Consecutive Again at the head of the due-review subsequence.
    public let dueAgainStreak: Int
    /// Most recent due-review time, if any.
    public let lastDueReviewAt: Date?
    /// Most recent valid Again time (any sample kind), if any.
    public let lastAgainAt: Date?
    /// Explanatory interval around the newest due review: days between the
    /// scheduled due time and the actual review. Negative when rated early.
    public let lastDueIntervalDays: Double?
    /// Current FSRS difficulty; never triggers alone.
    public let difficulty: Double
    /// Current FSRS stability (days).
    public let stability: Double
    /// Consecutive most-recent due reviews rated Good/Easy, capped by the
    /// number of due reviews available.
    public let consecutiveDueSuccesses: Int

    public init(
        lifetimeLapses: Int,
        recentCount: Int,
        recentAgainCount: Int,
        shortWindowAgainCount: Int,
        totalCount: Int,
        totalAgainCount: Int,
        againRatio: Double?,
        dueAgainStreak: Int,
        lastDueReviewAt: Date?,
        lastAgainAt: Date?,
        lastDueIntervalDays: Double?,
        difficulty: Double,
        stability: Double,
        consecutiveDueSuccesses: Int
    ) {
        self.lifetimeLapses = lifetimeLapses
        self.recentCount = recentCount
        self.recentAgainCount = recentAgainCount
        self.shortWindowAgainCount = shortWindowAgainCount
        self.totalCount = totalCount
        self.totalAgainCount = totalAgainCount
        self.againRatio = againRatio
        self.dueAgainStreak = dueAgainStreak
        self.lastDueReviewAt = lastDueReviewAt
        self.lastAgainAt = lastAgainAt
        self.lastDueIntervalDays = lastDueIntervalDays
        self.difficulty = difficulty
        self.stability = stability
        self.consecutiveDueSuccesses = consecutiveDueSuccesses
    }
}
