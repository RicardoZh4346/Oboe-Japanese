import OboeDomain
import SwiftUI
import XCTest
@testable import Oboe

/// SceneNavigationState 的 reducer 语义：世代更新清空旧实体引用，
/// 删除牌组清空相关选择，同世代重复通知是 no-op。
@MainActor
final class SceneNavigationStateTests: XCTestCase {
    func testGenerationChangeClearsEntityBoundState() {
        let state = SceneNavigationState()
        let deckID = UUID()
        state.selectedDeck = .deck(deckID)
        state.selectedNoteID = UUID()
        state.selectedInboxItemID = UUID()
        state.todayPath.append(AppRoute.review(StudyScope(deckID: nil, title: "t")))

        state.databaseGenerationDidChange(to: 1)

        XCTAssertNil(state.selectedDeck)
        XCTAssertNil(state.selectedNoteID)
        XCTAssertNil(state.selectedInboxItemID)
        XCTAssertTrue(state.todayPath.isEmpty)
        XCTAssertTrue(state.decksPath.isEmpty)
        XCTAssertTrue(state.settingsPath.isEmpty)
    }

    func testSameGenerationNotificationIsNoOp() {
        let state = SceneNavigationState()
        state.databaseGenerationDidChange(to: 1)
        let deckID = UUID()
        state.selectedDeck = .deck(deckID)

        state.databaseGenerationDidChange(to: 1)

        XCTAssertEqual(state.selectedDeck, .deck(deckID))
    }

    func testDeckDeletionClearsSelectionAndDetail() {
        let state = SceneNavigationState()
        let deckID = UUID()
        state.selectedDeck = .deck(deckID)
        state.selectedNoteID = UUID()

        state.deckWasDeleted(deckID)

        XCTAssertNil(state.selectedDeck)
        XCTAssertNil(state.selectedNoteID)
    }

    func testDeletingOtherDeckKeepsSelection() {
        let state = SceneNavigationState()
        let deckID = UUID()
        state.selectedDeck = .deck(deckID)
        let noteID = UUID()
        state.selectedNoteID = noteID

        state.deckWasDeleted(UUID())

        XCTAssertEqual(state.selectedDeck, .deck(deckID))
        XCTAssertEqual(state.selectedNoteID, noteID)
    }

    func testLibrarySelectionSurvivesDeckDeletion() {
        // sidebar 在内置词库、被删的不是选中牌组：选择与 detail 均保留。
        let state = SceneNavigationState()
        state.selectedDeck = .library
        let noteID = UUID()
        state.selectedNoteID = noteID

        state.deckWasDeleted(UUID())

        XCTAssertEqual(state.selectedDeck, .library)
        XCTAssertEqual(state.selectedNoteID, noteID)
    }

    func testSelectDeckSidebarSwitchesSectionAndClearsNote() {
        // regular sidebar 切牌组：detail 不得残留上一上下文的条目。
        let state = SceneNavigationState()
        state.selectNote(id: UUID(), kind: .vocabulary)
        let deckID = UUID()

        state.selectDeckSidebar(.deck(deckID))

        XCTAssertEqual(state.section, .decks)
        XCTAssertEqual(state.selectedDeck, .deck(deckID))
        XCTAssertNil(state.selectedNoteID)
        XCTAssertNil(state.selectedNoteKind)
    }

    func testSelectNoteRecordsKindForDetailResolution() {
        let state = SceneNavigationState()
        let noteID = UUID()

        state.selectNote(id: noteID, kind: .grammar)

        XCTAssertEqual(state.selectedNoteID, noteID)
        XCTAssertEqual(state.selectedNoteKind, .grammar)
    }

    func testDeckDeletionClearsNoteKind() {
        let state = SceneNavigationState()
        let deckID = UUID()
        state.selectDeckSidebar(.deck(deckID))
        state.selectNote(id: UUID(), kind: .vocabulary)

        state.deckWasDeleted(deckID)

        XCTAssertNil(state.selectedDeck)
        XCTAssertNil(state.selectedNoteID)
        XCTAssertNil(state.selectedNoteKind)
    }
}
