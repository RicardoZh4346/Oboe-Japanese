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

    /// PR 7：壳层切换/resize 重建视图树时，同 scope 的 Review 会话
    /// 要拿到同一实例——学习进度跨壳层续存。
    func testSessionCacheReturnsSameInstancePerScope() {
        let state = SceneNavigationState()
        let scope = StudyScope(deckID: UUID(), title: "N5")

        let first = state.cachedSession(for: scope) { NSObject() }
        let second = state.cachedSession(for: scope) { NSObject() }

        XCTAssertTrue(first === second)
    }

    func testSessionCacheIsolatesScopes() {
        let state = SceneNavigationState()
        let scopeA = StudyScope(deckID: UUID(), title: "A")
        let scopeB = StudyScope(deckID: UUID(), title: "B")

        let a = state.cachedSession(for: scopeA) { NSObject() }
        let b = state.cachedSession(for: scopeB) { NSObject() }

        XCTAssertFalse(a === b)
    }

    /// 世代变更清空会话缓存——缓存的 model 持有旧容器 service，
    /// 数据库替换后必须丢弃。
    func testGenerationChangeClearsSessionCache() {
        let state = SceneNavigationState()
        let scope = StudyScope(deckID: UUID(), title: "N5")
        let before = state.cachedSession(for: scope) { NSObject() }

        state.databaseGenerationDidChange(to: 1)
        let after = state.cachedSession(for: scope) { NSObject() }

        XCTAssertFalse(before === after)
    }

    /// PR 8：today 是两栏 split；decks/inbox/settings 是三栏 split——
    /// 三栏下 `.doubleColumn` 会折叠 sidebar，必须 `.all`。
    func testSelectTabNormalizesVisibilityPerSection() {
        let state = SceneNavigationState()

        state.selectTab(.inbox)
        XCTAssertEqual(state.splitVisibility, .all)
        XCTAssertEqual(state.preferredCompactColumn, .sidebar)

        state.selectTab(.settings)
        XCTAssertEqual(state.splitVisibility, .all)

        state.selectTab(.today)
        XCTAssertEqual(state.splitVisibility, .doubleColumn)
        XCTAssertEqual(state.preferredCompactColumn, .detail)

        state.selectTab(.decks)
        XCTAssertEqual(state.splitVisibility, .all)
    }

    /// PR 8：regular 下 Inbox 提升为一级 section，行选择写 detail 列。
    func testSelectInboxItemRecordsSelection() {
        let state = SceneNavigationState()
        let itemID = UUID()
        state.selectTab(.inbox)

        state.selectInboxItem(id: itemID)

        XCTAssertEqual(state.section, .inbox)
        XCTAssertEqual(state.selectedInboxItemID, itemID)
    }

    /// 世代变更清空 inbox 选择与设置路由——它们绑定旧实体/旧容器。
    func testGenerationChangeClearsInboxAndSettingsSelection() {
        let state = SceneNavigationState()
        state.selectTab(.inbox)
        state.selectInboxItem(id: UUID())
        state.selectedSettingsRoute = .backup

        state.databaseGenerationDidChange(to: 1)

        XCTAssertNil(state.selectedInboxItemID)
        XCTAssertNil(state.selectedSettingsRoute)
    }

    // MARK: - v0.7.5 S18 跨 Feature 路由

    /// Reader → Deck：openDeck 切到 decks section、选中 sidebar 条目、
    /// 三栏全显（regular），同时向 compact 栈压入 deckID（详情页由
    /// DecksView 的 navigationDestination 解析）。
    func testOpenDeckSelectsSidebarAndPushesPath() {
        let state = SceneNavigationState()
        state.selectNote(id: UUID(), kind: .vocabulary)
        let deckID = UUID()

        state.openDeck(deckID)

        XCTAssertEqual(state.section, .decks)
        XCTAssertEqual(state.selectedDeck, .deck(deckID))
        XCTAssertNil(state.selectedNoteID)
        XCTAssertNil(state.selectedNoteKind)
        XCTAssertEqual(state.splitVisibility, .all)
        XCTAssertEqual(state.preferredCompactColumn, .sidebar)
        XCTAssertEqual(state.decksPath.count, 1)
    }

    /// openDeck 清掉旧栈再压目标——重复跳转不叠加历史深度。
    func testOpenDeckReplacesExistingPath() {
        let state = SceneNavigationState()
        let first = UUID()
        let second = UUID()

        state.openDeck(first)
        state.openDeck(second)

        XCTAssertEqual(state.decksPath.count, 1)
        XCTAssertEqual(state.selectedDeck, .deck(second))
    }

    /// Deck → Reader：openReaderDocument 切到 reader section、记录
    /// detail 列选择、两栏 split，同时向 compact 栈压入 documentID。
    func testOpenReaderDocumentSelectsAndPushesPath() {
        let state = SceneNavigationState()
        state.selectTab(.decks)
        let documentID = UUID()

        state.openReaderDocument(documentID)

        XCTAssertEqual(state.section, .reader)
        XCTAssertEqual(state.selectedReaderDocumentID, documentID)
        XCTAssertEqual(state.splitVisibility, .doubleColumn)
        XCTAssertEqual(state.preferredCompactColumn, .detail)
        XCTAssertEqual(state.readerPath.count, 1)
    }

    /// Reader 区内部点行：只记当前文档，不改 section、不动栈。
    func testSelectReaderDocumentKeepsSectionAndPath() {
        let state = SceneNavigationState()
        state.selectTab(.reader)
        let documentID = UUID()

        state.selectReaderDocument(id: documentID)

        XCTAssertEqual(state.section, .reader)
        XCTAssertEqual(state.selectedReaderDocumentID, documentID)
        XCTAssertTrue(state.readerPath.isEmpty)

        state.selectReaderDocument(id: nil)
        XCTAssertNil(state.selectedReaderDocumentID)
    }

    /// 文档删除：选中的是该文档 → 清空；别的文档 → 保留。
    func testReaderDocumentDeletionClearsOnlyMatchingSelection() {
        let state = SceneNavigationState()
        let documentID = UUID()
        state.selectReaderDocument(id: documentID)

        state.readerDocumentWasDeleted(UUID())
        XCTAssertEqual(state.selectedReaderDocumentID, documentID)

        state.readerDocumentWasDeleted(documentID)
        XCTAssertNil(state.selectedReaderDocumentID)
    }

    /// 世代变更清空 Reader 选择与栈——旧实体引用不得带入新容器。
    func testGenerationChangeClearsReaderState() {
        let state = SceneNavigationState()
        let documentID = UUID()
        state.openReaderDocument(documentID)

        state.databaseGenerationDidChange(to: 1)

        XCTAssertNil(state.selectedReaderDocumentID)
        XCTAssertTrue(state.readerPath.isEmpty)
    }
}
