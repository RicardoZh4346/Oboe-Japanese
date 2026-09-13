import Foundation
import XCTest
@testable import OboeDomain

final class DeckManagementServiceTests: XCTestCase {
    func testDeckNameTrimsWhitespaceAndRejectsInvalidValues() throws {
        XCTAssertEqual(try DeckName(validating: "  N5 单词  ").value, "N5 单词")
        XCTAssertThrowsError(try DeckName(validating: " \n ")) { error in
            XCTAssertEqual(error as? DeckNameValidationError, .empty)
        }
        XCTAssertThrowsError(try DeckName(validating: "第一行\n第二行")) { error in
            XCTAssertEqual(
                error as? DeckNameValidationError,
                .containsLineBreakOrControlCharacter
            )
        }
        XCTAssertThrowsError(
            try DeckName(validating: String(repeating: "日", count: DeckName.maximumLength + 1))
        ) { error in
            XCTAssertEqual(
                error as? DeckNameValidationError,
                .tooLong(maximum: DeckName.maximumLength)
            )
        }
    }

    func testServiceValidatesAndSuppliesStableCreationValues() async throws {
        let repository = DeckRepositorySpy()
        let id = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let date = Date(timeIntervalSince1970: 1_768_478_400.123)
        let service = DeckManagementService(
            repository: repository,
            now: { date },
            makeID: { id }
        )

        let deck = try await service.createDeck(named: "  日语基础  ")

        XCTAssertEqual(deck.id, id)
        XCTAssertEqual(deck.name, "日语基础")
        XCTAssertEqual(deck.createdAt, date)
        let capturedName = await repository.lastCreatedName
        XCTAssertEqual(capturedName, "日语基础")
    }
}

private actor DeckRepositorySpy: DeckRepository {
    var lastCreatedName: String?

    func deckExists(id: UUID) async throws -> Bool { false }

    func fetchDeckSummaries() async throws -> [DeckSummary] { [] }

    nonisolated func observeDeckSummaries() -> AsyncThrowingStream<[DeckSummary], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }

    func createDeck(id: UUID, name: String, at date: Date) async throws -> Deck {
        lastCreatedName = name
        return Deck(id: id, name: name, sortOrder: 0, createdAt: date, updatedAt: date)
    }

    func renameDeck(id: UUID, name: String, at date: Date) async throws -> Bool { true }

    func deleteDeckIfEmpty(id: UUID) async throws -> DeckDeletionResult { .deleted }

    func deleteDeck(
        id: UUID,
        strategy: DeckDeletionStrategy,
        at date: Date
    ) async throws -> ManagedDeckDeletionResult {
        .deleted(DeckDeletionImpact(noteCount: 0, cardCount: 0, reviewLogCount: 0))
    }
}
