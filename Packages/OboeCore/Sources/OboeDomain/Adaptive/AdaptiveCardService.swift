import Foundation

/// Process-local invalidation entry point (design §4.3). Every ordinary write
/// — review, undo, edit, enable/disable, delete, study-day change — already
/// invalidates cached snapshots automatically through `PRAGMA data_version`.
/// The epoch covers the one case data_version cannot: replacing the whole
/// database file during backup restore. Bump it via
/// `AdaptiveCardService.invalidate()` after a restore; snapshots tagged with
/// the old epoch can then never update the UI again.
public actor AdaptiveInvalidationCenter {
    private(set) var epoch: UInt64 = 0

    public init() {}

    public func invalidate() {
        epoch &+= 1
    }
}

/// One assessed snapshot per cache key: scope + policy version + database
/// generation + time bucket (design §4.3). In-memory only — derived results
/// are always rebuildable after restore.
final class AdaptiveSnapshotCache: @unchecked Sendable {
    struct Key: Hashable {
        let scope: AdaptiveScope
        let policyVersion: String
        let generation: AdaptiveDatabaseGeneration
        let bucket: Int
    }

    private let lock = NSLock()
    private var storage: [Key: AdaptiveSnapshot] = [:]

    func value(for key: Key) -> AdaptiveSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func store(_ snapshot: AdaptiveSnapshot, for key: Key) {
        lock.lock()
        storage[key] = snapshot
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

/// Adaptive-center use case (design §3/§4.3): fetches batched evidence through
/// `AdaptiveRepository`, classifies it with `LeechClassifier`, and caches the
/// resulting snapshot. Home count, list and detail all read through this
/// service so every surface derives from identical evidence.
///
/// The service is a pure coordinator: no database access itself, no UI, and
/// `now` is injected at each call so rules stay deterministic.
public struct AdaptiveCardService: Sendable {
    private let repository: any AdaptiveRepository
    private let classifier: LeechClassifier
    private let invalidation: AdaptiveInvalidationCenter
    private let cache: AdaptiveSnapshotCache
    /// Wall-clock granularity of the cache key — repeated reads inside one
    /// bucket reuse the snapshot as long as the data version is unchanged.
    private let timeBucketSeconds: TimeInterval

    /// T26: the two-endpoint trend coordinator sharing this service's
    /// repository, policy and invalidation epoch — one `invalidate()` after
    /// a database replacement retires both caches.
    public let trendService: AdaptiveTrendService

    public init(
        repository: any AdaptiveRepository,
        policy: AdaptivePolicy = .standard,
        invalidation: AdaptiveInvalidationCenter = AdaptiveInvalidationCenter(),
        timeBucketSeconds: TimeInterval = 60
    ) {
        self.repository = repository
        self.classifier = LeechClassifier(policy: policy)
        self.invalidation = invalidation
        self.cache = AdaptiveSnapshotCache()
        self.timeBucketSeconds = max(1, timeBucketSeconds)
        self.trendService = AdaptiveTrendService(
            repository: repository,
            policy: policy,
            invalidation: invalidation,
            timeBucketSeconds: max(1, timeBucketSeconds)
        )
    }

    public var policyVersion: String { classifier.policy.version }

    /// Assessed snapshot for the home entry and list surfaces. Cached by
    /// (scope, policy version, database generation, time bucket); any database
    /// commit — review, undo, edit, enable/disable, delete, new study day —
    /// changes `data_version` and therefore misses automatically.
    public func snapshot(
        scope: AdaptiveScope = .all,
        at now: Date
    ) async throws -> AdaptiveSnapshot {
        let epoch = await invalidation.epoch
        let dataVersion = try await repository.fetchDataVersion()
        let generation = AdaptiveDatabaseGeneration(
            dataVersion: dataVersion,
            epoch: epoch
        )
        let key = AdaptiveSnapshotCache.Key(
            scope: scope,
            policyVersion: classifier.policy.version,
            generation: generation,
            bucket: bucket(for: now)
        )
        if let cached = cache.value(for: key) {
            return cached
        }

        let evidence = try await repository.fetchSnapshot(scope: scope)
        let snapshot = makeSnapshot(
            scope: scope,
            at: now,
            epoch: epoch,
            records: evidence.records,
            dataVersion: evidence.dataVersion
        )
        // A commit could have landed between the prefetch and the heavy read:
        // key by the generation captured inside the read that produced the
        // data, never the earlier probe.
        let accurateKey = AdaptiveSnapshotCache.Key(
            scope: scope,
            policyVersion: classifier.policy.version,
            generation: snapshot.generation,
            bucket: bucket(for: now)
        )
        cache.store(snapshot, for: accurateKey)
        return snapshot
    }

    /// Detail page for one card; `nil` when the card no longer exists so the
    /// UI can drop the entry instead of attaching orphaned history.
    public func detail(
        cardID: UUID,
        at now: Date
    ) async throws -> AdaptiveCardDetail? {
        guard let record = try await repository.fetchEvidence(cardID: cardID) else {
            return nil
        }
        let item = makeItem(record: record, at: now)
        let recent = Array(
            record.evidence.samples.prefix(classifier.policy.recentWindowSize)
        )
        return AdaptiveCardDetail(item: item, recentSamples: recent)
    }

    /// Bumps the invalidation epoch and drops every cached snapshot. Call
    /// after the database file has been replaced (backup restore); in-flight
    /// snapshots keep their old generation and are discarded by the UI.
    public func invalidate() async {
        await invalidation.invalidate()
        cache.removeAll()
        trendService.invalidateCache()
    }

    /// Current generation prefix — the UI compares a snapshot's generation
    /// against it and drops stale results.
    public func currentEpoch() async -> UInt64 {
        await invalidation.epoch
    }

    // MARK: - Private

    private func bucket(for now: Date) -> Int {
        Int(now.timeIntervalSince1970 / timeBucketSeconds)
    }

    private func makeSnapshot(
        scope: AdaptiveScope,
        at now: Date,
        epoch: UInt64,
        records: [AdaptiveCardRecord],
        dataVersion: Int
    ) -> AdaptiveSnapshot {
        let items = records
            .map { makeItem(record: $0, at: now) }
            .sorted(by: Self.displayOrder)
        return AdaptiveSnapshot(
            scope: scope,
            generatedAt: now,
            policyVersion: classifier.policy.version,
            generation: AdaptiveDatabaseGeneration(
                dataVersion: dataVersion,
                epoch: epoch
            ),
            items: items
        )
    }

    private func makeItem(record: AdaptiveCardRecord, at now: Date) -> AdaptiveCardItem {
        let assessment = classifier.assess(evidence: record.evidence, at: now)
        return AdaptiveCardItem(
            cardID: record.evidence.cardID,
            noteID: record.evidence.noteID,
            deckID: record.evidence.deckID,
            headword: record.headword,
            templateKind: record.evidence.templateKind,
            isEnabled: record.evidence.isEnabled,
            noteContentVersion: record.noteContentVersion,
            assessment: assessment,
            lastReviewedAt: record.evidence.samples.first?.reviewedAt
        )
    }

    /// Stable display order: leech first, then warning, then normal; inside a
    /// status the most evidence-backed cards lead (recent Again count, then
    /// lifetime lapses, then most recent activity).
    static func displayOrder(_ lhs: AdaptiveCardItem, _ rhs: AdaptiveCardItem) -> Bool {
        let leftRank = statusRank(lhs.assessment.status)
        let rightRank = statusRank(rhs.assessment.status)
        if leftRank != rightRank { return leftRank < rightRank }
        let l = lhs.assessment.metrics
        let r = rhs.assessment.metrics
        if l.recentAgainCount != r.recentAgainCount {
            return l.recentAgainCount > r.recentAgainCount
        }
        if l.lifetimeLapses != r.lifetimeLapses {
            return l.lifetimeLapses > r.lifetimeLapses
        }
        let leftDate = lhs.lastReviewedAt ?? .distantPast
        let rightDate = rhs.lastReviewedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        if lhs.headword != rhs.headword { return lhs.headword < rhs.headword }
        return lhs.cardID.uuidString < rhs.cardID.uuidString
    }

    private static func statusRank(_ status: AdaptiveCardStatus) -> Int {
        switch status {
        case .leech: 0
        case .warning: 1
        case .normal: 2
        }
    }
}
