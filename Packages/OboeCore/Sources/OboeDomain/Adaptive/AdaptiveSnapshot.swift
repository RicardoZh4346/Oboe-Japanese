import Foundation

/// Which cards participate in an adaptive query. Today the only axis is the
/// deck; the type is a struct so future scope axes (template kind, tag, ...)
/// can be added without breaking call sites.
public struct AdaptiveScope: Equatable, Hashable, Sendable {
    public let deckID: UUID?

    public init(deckID: UUID? = nil) {
        self.deckID = deckID
    }

    public static let all = AdaptiveScope()
}

/// Shared list filter (design §6). The home entry count, the list page and the
/// detail page all derive from the same snapshot items, so a card can never be
/// counted by one rule and displayed by another.
public enum AdaptiveListFilter: String, CaseIterable, Sendable {
    /// Enabled cards whose assessment is `.leech` — the default list and the
    /// home-entry count.
    case leech
    /// Enabled cards whose assessment is `.warning`.
    case warning
    /// Suspended cards (`isEnabled == false`), regardless of assessment.
    case suspended
}

/// Token identifying the database contents a snapshot was read from:
/// SQLite `PRAGMA data_version` captured inside the same read transaction as
/// the data, plus a process-local epoch bumped by `AdaptiveInvalidationCenter`
/// when the database file is replaced (backup restore). A snapshot whose
/// generation no longer matches the live one is stale and must not be applied
/// to the UI (design §4.3).
public struct AdaptiveDatabaseGeneration: Equatable, Hashable, Sendable {
    public let dataVersion: Int
    public let epoch: UInt64

    public init(dataVersion: Int, epoch: UInt64) {
        self.dataVersion = dataVersion
        self.epoch = epoch
    }
}

/// Raw per-card evidence plus the note display fields every surface needs —
/// fetched inside the same read snapshot as the review samples.
public struct AdaptiveCardRecord: Equatable, Sendable {
    public let evidence: AdaptiveCardEvidence
    public let headword: String
    public let noteContentVersion: Int

    public init(
        evidence: AdaptiveCardEvidence,
        headword: String,
        noteContentVersion: Int
    ) {
        self.evidence = evidence
        self.headword = headword
        self.noteContentVersion = noteContentVersion
    }
}

/// Repository output: one consistent read of every live card in scope.
public struct AdaptiveEvidenceSnapshot: Sendable {
    public let scope: AdaptiveScope
    /// `PRAGMA data_version` observed inside the read transaction — accurate
    /// for exactly the rows returned here.
    public let dataVersion: Int
    public let records: [AdaptiveCardRecord]

    public init(
        scope: AdaptiveScope,
        dataVersion: Int,
        records: [AdaptiveCardRecord]
    ) {
        self.scope = scope
        self.dataVersion = dataVersion
        self.records = records
    }
}

/// One assessed card — the list-row model for the Adaptive center.
public struct AdaptiveCardItem: Equatable, Sendable {
    public let cardID: UUID
    public let noteID: UUID
    public let deckID: UUID
    public let headword: String
    public let templateKind: CardTemplateKind
    public let isEnabled: Bool
    /// Current note content version — detail labels history against it and the
    /// edit/repair flows use it as their expected-version anchor.
    public let noteContentVersion: Int
    public let assessment: AdaptiveAssessment
    public let lastReviewedAt: Date?

    public init(
        cardID: UUID,
        noteID: UUID,
        deckID: UUID,
        headword: String,
        templateKind: CardTemplateKind,
        isEnabled: Bool,
        noteContentVersion: Int,
        assessment: AdaptiveAssessment,
        lastReviewedAt: Date?
    ) {
        self.cardID = cardID
        self.noteID = noteID
        self.deckID = deckID
        self.headword = headword
        self.templateKind = templateKind
        self.isEnabled = isEnabled
        self.noteContentVersion = noteContentVersion
        self.assessment = assessment
        self.lastReviewedAt = lastReviewedAt
    }
}

/// Assessed snapshot shared by the home entry, the list and pagination.
/// `items` covers every live card in scope (enabled and suspended) in stable
/// display order; filtering is applied on top of the same array.
public struct AdaptiveSnapshot: Equatable, Sendable {
    public let scope: AdaptiveScope
    public let generatedAt: Date
    public let policyVersion: String
    public let generation: AdaptiveDatabaseGeneration
    public let items: [AdaptiveCardItem]

    public init(
        scope: AdaptiveScope,
        generatedAt: Date,
        policyVersion: String,
        generation: AdaptiveDatabaseGeneration,
        items: [AdaptiveCardItem]
    ) {
        self.scope = scope
        self.generatedAt = generatedAt
        self.policyVersion = policyVersion
        self.generation = generation
        self.items = items
    }

    /// Home-entry count: enabled leech cards only. A suspended leech does not
    /// nag on the home page.
    public var leechCount: Int {
        items(matching: .leech).count
    }

    public func items(matching filter: AdaptiveListFilter) -> [AdaptiveCardItem] {
        items.filter { filter.matches($0) }
    }

    public func page(
        _ filter: AdaptiveListFilter,
        offset: Int,
        limit: Int
    ) -> AdaptivePage {
        let matching = items(matching: filter)
        let safeOffset = max(0, min(offset, matching.count))
        let end = min(safeOffset + max(0, limit), matching.count)
        return AdaptivePage(
            filter: filter,
            items: Array(matching[safeOffset..<end]),
            offset: safeOffset,
            limit: limit,
            totalCount: matching.count
        )
    }
}

public struct AdaptivePage: Equatable, Sendable {
    public let filter: AdaptiveListFilter
    public let items: [AdaptiveCardItem]
    public let offset: Int
    public let limit: Int
    /// Total matching items independent of the page window — the list header
    /// count and the paged rows always agree.
    public let totalCount: Int

    public init(
        filter: AdaptiveListFilter,
        items: [AdaptiveCardItem],
        offset: Int,
        limit: Int,
        totalCount: Int
    ) {
        self.filter = filter
        self.items = items
        self.offset = offset
        self.limit = limit
        self.totalCount = totalCount
    }

    public var hasMore: Bool {
        offset + items.count < totalCount
    }
}

/// Detail-page model: the same assessed item plus up to the policy's recent
/// window of valid samples — the "最近十次" panel. Each sample keeps its
/// `contentVersion` so history can be labelled against the note version it
/// belonged to (design §4.1).
public struct AdaptiveCardDetail: Equatable, Sendable {
    public let item: AdaptiveCardItem
    public let recentSamples: [AdaptiveReviewSample]

    public init(item: AdaptiveCardItem, recentSamples: [AdaptiveReviewSample]) {
        self.item = item
        self.recentSamples = recentSamples
    }
}

extension AdaptiveListFilter {
    /// The ONE filtering rule — leech/warning look at enabled cards only,
    /// the suspended filter collects every paused card regardless of
    /// assessment. The Adaptive center and the JLPT weak-vocabulary list
    /// share this predicate so a card can never be filtered one way here
    /// and another way there (design §6/§11.2).
    public func matches(isEnabled: Bool, status: AdaptiveCardStatus) -> Bool {
        switch self {
        case .leech:
            return isEnabled && status == .leech
        case .warning:
            return isEnabled && status == .warning
        case .suspended:
            return !isEnabled
        }
    }

    func matches(_ item: AdaptiveCardItem) -> Bool {
        matches(isEnabled: item.isEnabled, status: item.assessment.status)
    }
}

/// Batched read access for the Adaptive center (design §4.3). Implementations
/// must fetch every card's evidence inside a single consistent read — the
/// counts, the list and the detail all come from one snapshot, never from
/// per-row queries (no N+1).
public protocol AdaptiveRepository: Sendable {
    /// Cheap read of `PRAGMA data_version` so callers can consult the snapshot
    /// cache before paying for the full scan.
    func fetchDataVersion() async throws -> Int

    /// Every live card in scope with its note display fields and ALL of its
    /// valid (non-undone) review samples ordered newest-first per
    /// `AdaptiveReviewSample.isOrderedBefore`.
    func fetchSnapshot(scope: AdaptiveScope) async throws -> AdaptiveEvidenceSnapshot

    /// Single-card evidence for the detail page; `nil` when the card no longer
    /// exists (history must not reattach to a later card of the same note).
    func fetchEvidence(cardID: UUID) async throws -> AdaptiveCardRecord?
}
