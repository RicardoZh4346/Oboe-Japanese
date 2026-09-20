import Foundation

/// Week boundary for the two-endpoint trend comparison (design §12.1).
/// The week runs Monday 04:00 → Monday 04:00 in the LEARNING time zone —
/// the same 04:00 rollover the study day uses, so a late Sunday session
/// still belongs to the week it felt like.
public enum AdaptiveTrendWeek {
    /// Most recent Monday-04:00 (learning-TZ wall clock) at or before
    /// `instant` — the start of the comparison week containing `instant`.
    /// When `instant` is itself Monday before 04:00 the previous week's
    /// boundary is returned — the new week has not started yet.
    public static func start(
        atOrBefore instant: Date,
        timeZoneID: String
    ) throws -> Date {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.weekday, .hour, .minute, .second],
            from: instant
        )
        if components.weekday == 2,
           components.hour == StudyDayBoundaryCalculator.rolloverHour,
           components.minute == 0,
           components.second == 0 {
            return instant
        }
        guard let boundary = calendar.nextDate(
            after: instant,
            matching: DateComponents(hour: StudyDayBoundaryCalculator.rolloverHour, weekday: 2),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .backward
        ) else {
            throw StudyDayPlanningError.invalidStudyDayBoundary
        }
        return boundary
    }
}

/// Two-endpoint weekly leech comparison (design §12.1). Every number is
/// recomputed from valid review logs at BOTH ends — week start t0 and now
/// t1 — over the CURRENT set of live cards. It is an honest "两端对比",
/// not a claim about every card that was ever leech inside the week.
public struct AdaptiveTrendReport: Equatable, Sendable {
    /// t0 — the learning-TZ Monday 04:00 the comparison starts from.
    public let weekStart: Date
    /// t1 — generation time.
    public let generatedAt: Date
    public let timeZoneID: String
    public let policyVersion: String
    public let generation: AdaptiveDatabaseGeneration
    /// Live cards analysed — the fixed set both ends are computed over;
    /// deleted cards leave the comparison entirely.
    public let analyzedCardCount: Int
    /// |S0| — cards assessed leech at the week-start endpoint.
    public let weekStartLeechCount: Int
    /// |S1| — cards assessed leech right now.
    public let currentLeechCount: Int
    /// |S0 ∪ S1| — "本周易错卡": cards leech at either end. NOT a claim
    /// that the union covers every card that was briefly leech mid-week.
    public let weekLeechCount: Int
    /// |S1 − S0| — "新出现": leech now but not at week start; never
    /// claimed as a lifetime first appearance.
    public let newlyAppearedCount: Int
    /// |S0 ∩ S1| — "仍经常遗忘": leech at both ends.
    public let stillLeechCount: Int
    /// "已恢复稳定": exited leech WITH recovery evidence at t1 — three
    /// recent due-review successes plus enough stability, per the same
    /// classifier. Suspending or deleting a card never counts here.
    public let recoveredStableCount: Int
    /// "状态改善": exited leech without recovery evidence — e.g. trigger
    /// windows aged out. A separate bucket so recovery stays meaningful.
    public let improvedCount: Int
    /// Currently suspended cards inside the analysed set — reported on
    /// its own line; suspension is ignored by classification and is
    /// therefore never mistaken for recovery.
    public let suspendedCount: Int

    public init(
        weekStart: Date,
        generatedAt: Date,
        timeZoneID: String,
        policyVersion: String,
        generation: AdaptiveDatabaseGeneration,
        analyzedCardCount: Int,
        weekStartLeechCount: Int,
        currentLeechCount: Int,
        weekLeechCount: Int,
        newlyAppearedCount: Int,
        stillLeechCount: Int,
        recoveredStableCount: Int,
        improvedCount: Int,
        suspendedCount: Int
    ) {
        self.weekStart = weekStart
        self.generatedAt = generatedAt
        self.timeZoneID = timeZoneID
        self.policyVersion = policyVersion
        self.generation = generation
        self.analyzedCardCount = analyzedCardCount
        self.weekStartLeechCount = weekStartLeechCount
        self.currentLeechCount = currentLeechCount
        self.weekLeechCount = weekLeechCount
        self.newlyAppearedCount = newlyAppearedCount
        self.stillLeechCount = stillLeechCount
        self.recoveredStableCount = recoveredStableCount
        self.improvedCount = improvedCount
        self.suspendedCount = suspendedCount
    }
}

/// One assessed snapshot per cache key — same invalidation contract as
/// `AdaptiveSnapshotCache`: any commit (review, undo, rating, delete,
/// enable/disable, study-day change) moves `data_version`, a database
/// replacement moves the epoch, and the learning time zone sits in the
/// key so a settings change never serves a stale boundary.
final class AdaptiveTrendCache: @unchecked Sendable {
    struct Key: Hashable {
        let scope: AdaptiveScope
        let policyVersion: String
        let generation: AdaptiveDatabaseGeneration
        let bucket: Int
        let timeZoneID: String
    }

    private let lock = NSLock()
    private var storage: [Key: AdaptiveTrendReport] = [:]

    func value(for key: Key) -> AdaptiveTrendReport? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func store(_ report: AdaptiveTrendReport, for key: Key) {
        lock.lock()
        storage[key] = report
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
    }
}

/// Trend use case (design §12): rebuilds each card's scheduling state and
/// valid samples at both week ends from review logs, then classifies with
/// the SAME `LeechClassifier`. No history table, no backfilling — a card's
/// state at t is the `nextState` of its last valid log at or before t.
public struct AdaptiveTrendService: Sendable {
    private let repository: any AdaptiveRepository
    private let classifier: LeechClassifier
    private let invalidation: AdaptiveInvalidationCenter
    private let cache: AdaptiveTrendCache
    private let timeBucketSeconds: TimeInterval

    /// Share `invalidation` with `AdaptiveCardService` so one restore-time
    /// `invalidate()` drops both caches.
    public init(
        repository: any AdaptiveRepository,
        policy: AdaptivePolicy = .standard,
        invalidation: AdaptiveInvalidationCenter = AdaptiveInvalidationCenter(),
        timeBucketSeconds: TimeInterval = 60
    ) {
        self.repository = repository
        self.classifier = LeechClassifier(policy: policy)
        self.invalidation = invalidation
        self.cache = AdaptiveTrendCache()
        self.timeBucketSeconds = max(1, timeBucketSeconds)
    }

    public var policyVersion: String { classifier.policy.version }

    /// Two-endpoint report for `scope`. `learningTimeZoneID` is the stored
    /// study setting, resolved by the caller — the week boundary is defined
    /// in that zone, never in the device zone.
    public func report(
        scope: AdaptiveScope = .all,
        at now: Date,
        learningTimeZoneID: String
    ) async throws -> AdaptiveTrendReport {
        let weekStart = try AdaptiveTrendWeek.start(
            atOrBefore: now,
            timeZoneID: learningTimeZoneID
        )
        let epoch = await invalidation.epoch
        let dataVersion = try await repository.fetchDataVersion()
        let key = AdaptiveTrendCache.Key(
            scope: scope,
            policyVersion: classifier.policy.version,
            generation: AdaptiveDatabaseGeneration(
                dataVersion: dataVersion,
                epoch: epoch
            ),
            bucket: bucket(for: now),
            timeZoneID: learningTimeZoneID
        )
        if let cached = cache.value(for: key) {
            return cached
        }

        let evidence = try await repository.fetchSnapshot(scope: scope)
        let report = makeReport(
            at: now,
            weekStart: weekStart,
            timeZoneID: learningTimeZoneID,
            epoch: epoch,
            records: evidence.records,
            dataVersion: evidence.dataVersion
        )
        // Key by the generation captured inside the read that produced the
        // data — a commit may have landed since the prefetch probe.
        cache.store(
            report,
            for: AdaptiveTrendCache.Key(
                scope: scope,
                policyVersion: classifier.policy.version,
                generation: report.generation,
                bucket: bucket(for: now),
                timeZoneID: learningTimeZoneID
            )
        )
        return report
    }

    /// Drops cached reports; the shared epoch is bumped by
    /// `AdaptiveCardService.invalidate()` after a database replacement.
    public func invalidateCache() {
        cache.removeAll()
    }

    public func currentEpoch() async -> UInt64 {
        await invalidation.epoch
    }

    // MARK: - Reconstruction

    private func bucket(for now: Date) -> Int {
        Int(now.timeIntervalSince1970 / timeBucketSeconds)
    }

    private func makeReport(
        at now: Date,
        weekStart: Date,
        timeZoneID: String,
        epoch: UInt64,
        records: [AdaptiveCardRecord],
        dataVersion: Int
    ) -> AdaptiveTrendReport {
        var leechAtStart = Set<UUID>()
        var leechNow = Set<UUID>()
        var recoveredNow = Set<UUID>()
        var suspendedCount = 0

        for record in records {
            let cardID = record.evidence.cardID
            if !record.evidence.isEnabled { suspendedCount += 1 }

            if let atStart = reconstruct(record: record, at: weekStart),
               classifier.assess(evidence: atStart, at: weekStart).status == .leech {
                leechAtStart.insert(cardID)
            }
            if let atNow = reconstruct(record: record, at: now) {
                let assessment = classifier.assess(evidence: atNow, at: now)
                if assessment.status == .leech {
                    leechNow.insert(cardID)
                }
                if assessment.isRecovered {
                    recoveredNow.insert(cardID)
                }
            }
        }

        let exits = leechAtStart.subtracting(leechNow)
        let recoveredStable = exits.intersection(recoveredNow).count
        return AdaptiveTrendReport(
            weekStart: weekStart,
            generatedAt: now,
            timeZoneID: timeZoneID,
            policyVersion: classifier.policy.version,
            generation: AdaptiveDatabaseGeneration(
                dataVersion: dataVersion,
                epoch: epoch
            ),
            analyzedCardCount: records.count,
            weekStartLeechCount: leechAtStart.count,
            currentLeechCount: leechNow.count,
            weekLeechCount: leechAtStart.union(leechNow).count,
            newlyAppearedCount: leechNow.subtracting(leechAtStart).count,
            stillLeechCount: leechAtStart.intersection(leechNow).count,
            recoveredStableCount: recoveredStable,
            improvedCount: exits.count - recoveredStable,
            suspendedCount: suspendedCount
        )
    }

    /// The card's world at `endpoint`: valid samples at or before it, and
    /// the scheduling snapshot the newest of them left behind. `nil` when
    /// no valid log exists yet — the card had not started, never a leech.
    /// Historical stability/difficulty/lapses come from the snapshot;
    /// current values are never backfilled (design §12.2).
    private func reconstruct(
        record: AdaptiveCardRecord,
        at endpoint: Date
    ) -> AdaptiveCardEvidence? {
        let evidence = record.evidence
        let samples = evidence.samples.filter { $0.reviewedAt <= endpoint }
        guard let newest = samples.first else { return nil }
        return AdaptiveCardEvidence(
            cardID: evidence.cardID,
            noteID: evidence.noteID,
            deckID: evidence.deckID,
            templateKind: evidence.templateKind,
            isEnabled: evidence.isEnabled,
            scheduling: newest.nextState.scheduling,
            firstStudiedAt: newest.nextState.firstStudiedAt,
            samples: samples
        )
    }
}
