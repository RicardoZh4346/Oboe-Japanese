import Foundation
import Observation
import OboeDomain

@MainActor
@Observable
final class DeckContentModel {
    private let deckID: UUID
    private let service: KnowledgePointService

    var items: [KnowledgePointSummary] = []
    var isLoading = true
    var errorMessage: String?

    init(deckID: UUID, service: KnowledgePointService) {
        self.deckID = deckID
        self.service = service
    }

    func load() async {
        isLoading = true
        do {
            items = try await service.fetchSummaries(deckID: deckID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
