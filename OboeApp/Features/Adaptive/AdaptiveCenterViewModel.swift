import Foundation
import Observation
import OboeDomain

/// List-page model for the Adaptive center (T03). Home count, filter counts
/// and the paged rows all read the SAME `AdaptiveSnapshot`, so a card can
/// never be counted by one rule and displayed by another.
@MainActor
@Observable
final class AdaptiveCenterViewModel {
    static let pageSize = 20

    private let service: AdaptiveCardService

    private(set) var snapshot: AdaptiveSnapshot?
    var filter: AdaptiveListFilter = .leech
    private(set) var visibleLimit = pageSize
    var isLoading = true
    var loadErrorMessage: String?

    init(service: AdaptiveCardService) {
        self.service = service
    }

    var leechCount: Int { snapshot?.leechCount ?? 0 }
    var warningCount: Int { snapshot?.items(matching: .warning).count ?? 0 }
    var suspendedCount: Int { snapshot?.items(matching: .suspended).count ?? 0 }

    var visibleItems: [AdaptiveCardItem] {
        snapshot?.page(filter, offset: 0, limit: visibleLimit).items ?? []
    }

    var filteredTotal: Int {
        snapshot?.items(matching: filter).count ?? 0
    }

    var hasMore: Bool {
        visibleItems.count < filteredTotal
    }

    func count(for filter: AdaptiveListFilter) -> Int {
        switch filter {
        case .leech: leechCount
        case .warning: warningCount
        case .suspended: suspendedCount
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await service.snapshot(scope: .all, at: Date())
            // A snapshot read before a database replacement carries the old
            // epoch — drop it instead of rendering pre-restore state.
            let epoch = await service.currentEpoch()
            guard fresh.generation.epoch == epoch else {
                return
            }
            snapshot = fresh
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    func selectFilter(_ filter: AdaptiveListFilter) {
        self.filter = filter
        visibleLimit = Self.pageSize
    }

    func loadMore() {
        guard hasMore else { return }
        visibleLimit += Self.pageSize
    }
}

/// Detail-page model — fetches fresh evidence per card so a card deleted
/// since the list was built surfaces as "已删除", never as stale data.
@MainActor
@Observable
final class AdaptiveCardDetailViewModel {
    private let service: AdaptiveCardService
    private let contentCardService: ContentCardService?
    let cardID: UUID

    private(set) var detail: AdaptiveCardDetail?
    var isLoading = true
    var isCardGone = false
    var loadErrorMessage: String?
    var actionErrorMessage: String?
    private(set) var isActionInFlight = false

    init(service: AdaptiveCardService, cardID: UUID, contentCardService: ContentCardService?) {
        self.service = service
        self.cardID = cardID
        self.contentCardService = contentCardService
    }

    var canToggleEnabled: Bool { contentCardService != nil }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await service.detail(cardID: cardID, at: Date())
            detail = fresh
            isCardGone = fresh == nil
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }

    /// Single-card suspend/resume (T04/§5.2) — never routes through the
    /// direction-set API, which would rewrite the note's other directions.
    /// After the write the detail reloads fresh evidence so the page shows
    /// the persisted state, not an optimistic guess.
    func setCardEnabled(_ isEnabled: Bool) async -> Bool {
        guard let contentCardService else { return false }
        isActionInFlight = true
        defer { isActionInFlight = false }
        do {
            _ = try await contentCardService.setCardEnabled(
                cardID: cardID,
                isEnabled: isEnabled
            )
            await load()
            actionErrorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            actionErrorMessage = error.localizedDescription
            return false
        }
    }
}

/// Trend-page model (T26) — resolves the stored learning time zone, then
/// asks the shared trend service for the two-endpoint report. A report
/// read before a database replacement carries the old epoch and is
/// dropped, same contract as the list snapshot.
@MainActor
@Observable
final class AdaptiveTrendViewModel {
    private let trendService: AdaptiveTrendService
    private let learningTimeZoneID: @Sendable () async throws -> String

    private(set) var report: AdaptiveTrendReport?
    var isLoading = true
    var loadErrorMessage: String?

    init(
        trendService: AdaptiveTrendService,
        learningTimeZoneID: @escaping @Sendable () async throws -> String
    ) {
        self.trendService = trendService
        self.learningTimeZoneID = learningTimeZoneID
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let timeZoneID = try await learningTimeZoneID()
            let fresh = try await trendService.report(
                at: Date(),
                learningTimeZoneID: timeZoneID
            )
            let epoch = await trendService.currentEpoch()
            guard fresh.generation.epoch == epoch else {
                return
            }
            report = fresh
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
    }
}
