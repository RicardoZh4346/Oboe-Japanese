import XCTest
@testable import OboeDomain

/// T07: 多牌组选择工作状态的归一化与切换规则——home 始终在成员内，
/// 至少保留一个成员，已删除的牌组被剔除。
final class DeckMembershipSelectionTests: XCTestCase {
    private let deckA = DeckSummary(id: UUID(), name: "A", noteCount: 0, cardCount: 0)
    private let deckB = DeckSummary(id: UUID(), name: "B", noteCount: 0, cardCount: 0)
    private let deckC = DeckSummary(id: UUID(), name: "C", noteCount: 0, cardCount: 0)

    private var decks: [DeckSummary] { [deckA, deckB, deckC] }

    func testNormalizeDropsDeletedDecksAndKeepsHomeWhenStillMember() {
        let removed = UUID()
        let selection = DeckMembershipSelection(
            homeDeckID: deckB.id,
            deckIDs: [deckA.id, deckB.id, removed]
        )
        let normalized = selection.normalized(decks: decks)
        XCTAssertEqual(normalized.deckIDs, [deckA.id, deckB.id])
        XCTAssertEqual(normalized.homeDeckID, deckB.id)
    }

    func testNormalizeFallsBackToPreferredPrimaryDeckWhenHomeGone() {
        let selection = DeckMembershipSelection(
            homeDeckID: UUID(),
            deckIDs: [deckA.id, deckB.id]
        )
        let normalized = selection.normalized(decks: decks, preferredHomeID: deckB.id)
        XCTAssertEqual(normalized.homeDeckID, deckB.id)
    }

    func testNormalizeFallsBackToFirstMemberInDeckOrder() {
        let selection = DeckMembershipSelection(
            homeDeckID: UUID(),
            deckIDs: [deckC.id, deckA.id]
        )
        let normalized = selection.normalized(decks: decks)
        XCTAssertEqual(normalized.homeDeckID, deckA.id)
    }

    func testNormalizeEmptySelectionStaysEmpty() {
        let normalized = DeckMembershipSelection(
            homeDeckID: UUID(),
            deckIDs: [UUID()]
        ).normalized(decks: decks)
        XCTAssertTrue(normalized.deckIDs.isEmpty)
        XCTAssertNil(normalized.homeDeckID)
    }

    func testToggleRefusesRemovingLastMember() {
        var selection = DeckMembershipSelection(single: deckA.id)
        XCTAssertFalse(selection.toggle(deckID: deckA.id, decks: decks))
        XCTAssertEqual(selection.deckIDs, [deckA.id])
        XCTAssertEqual(selection.homeDeckID, deckA.id)
    }

    func testToggleRemovingHomeReassignsFirstRemainingMember() {
        var selection = DeckMembershipSelection(
            homeDeckID: deckA.id,
            deckIDs: [deckA.id, deckC.id]
        )
        XCTAssertTrue(selection.toggle(deckID: deckA.id, decks: decks))
        XCTAssertEqual(selection.deckIDs, [deckC.id])
        XCTAssertEqual(selection.homeDeckID, deckC.id)
    }

    func testToggleAddSetsHomeWhenMissing() {
        var selection = DeckMembershipSelection(deckIDs: [deckA.id])
        selection.homeDeckID = nil
        XCTAssertTrue(selection.toggle(deckID: deckB.id, decks: decks))
        XCTAssertEqual(selection.homeDeckID, deckB.id)
    }
}
