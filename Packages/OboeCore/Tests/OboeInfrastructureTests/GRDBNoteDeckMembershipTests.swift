import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T04：membership repository 与牌组统计（设计 §4.2–§4.8）。
final class GRDBNoteDeckMembershipTests: XCTestCase {
    // MARK: - fetch / replace membership

    func testFetchDeckMembershipReturnsHomeAndMemberSet() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBKnowledgePointRepository(database: fixture.database)

        let shared = try await repository.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(shared?.homeDeckID, fixture.deckAID)
        XCTAssertEqual(shared?.deckIDs, [fixture.deckAID, fixture.deckBID])

        let exclusive = try await repository.fetchDeckMembership(noteID: fixture.exclusiveNote.noteID)
        XCTAssertEqual(exclusive?.homeDeckID, fixture.deckBID)
        XCTAssertEqual(exclusive?.deckIDs, [fixture.deckBID])

        let missing = try await repository.fetchDeckMembership(noteID: UUID())
        XCTAssertNil(missing)
    }

    func testReplaceMembershipUpdatesMembersAndHomeAtomically() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBKnowledgePointRepository(database: fixture.database)
        let newHome = fixture.deckBID
        let at = MultiDeckDatabaseFixture.baseDate.addingTimeInterval(3_600)

        // 共享 Note {A,B} home=A → 替换为 {B} home=B。
        let membership = try await repository.replaceDeckMembership(
            noteID: fixture.sharedNote.noteID,
            deckIDs: [newHome],
            homeDeckID: newHome,
            at: at
        )
        XCTAssertEqual(membership.deckIDs, [newHome])
        XCTAssertEqual(membership.homeDeckID, newHome)

        let persisted = try await repository.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(persisted?.deckIDs, [newHome])
        XCTAssertEqual(persisted?.homeDeckID, newHome)

        // notes.deck_id 与 updated_at_ms 已更新。
        let (homeValue, updatedValue) = try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT deck_id, updated_at_ms FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.sharedNote.noteID)]
            )
            return (row?["deck_id"] as String?, row?["updated_at_ms"] as Int64?)
        }
        XCTAssertEqual(try homeValue.map(DatabaseValueCodec.decodeUUID), newHome)
        XCTAssertEqual(updatedValue, try DatabaseValueCodec.encode(at))
    }

    func testReplaceMembershipRejectsUnknownDeckWithoutPartialChange() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBKnowledgePointRepository(database: fixture.database)
        let unknown = UUID()

        do {
            _ = try await repository.replaceDeckMembership(
                noteID: fixture.sharedNote.noteID,
                deckIDs: [fixture.deckAID, unknown],
                homeDeckID: fixture.deckAID,
                at: Date()
            )
            XCTFail("expected deckNotFound")
        } catch let error as NoteDeckMembershipError {
            XCTAssertEqual(error, .deckNotFound(unknown))
        }

        // 原子性：成员关系与 home 均未被修改。
        let persisted = try await repository.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(persisted?.deckIDs, [fixture.deckAID, fixture.deckBID])
        XCTAssertEqual(persisted?.homeDeckID, fixture.deckAID)
    }

    func testReplaceMembershipValidatesNoteAndInvariant() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBKnowledgePointRepository(database: fixture.database)

        await XCTAssertThrowsMembershipError(
            try await repository.replaceDeckMembership(
                noteID: UUID(),
                deckIDs: [fixture.deckAID],
                homeDeckID: fixture.deckAID,
                at: Date()
            ),
            equals: .noteNotFound
        )
        // 空成员集合 → 拒绝删除最后一个 membership。
        await XCTAssertThrowsMembershipError(
            try await repository.replaceDeckMembership(
                noteID: fixture.sharedNote.noteID,
                deckIDs: [],
                homeDeckID: fixture.deckAID,
                at: Date()
            ),
            equals: .atLeastOneDeckRequired
        )
        // home 不在成员集合中 → 拒绝移除 home membership。
        await XCTAssertThrowsMembershipError(
            try await repository.replaceDeckMembership(
                noteID: fixture.sharedNote.noteID,
                deckIDs: [fixture.deckBID],
                homeDeckID: fixture.deckAID,
                at: Date()
            ),
            equals: .homeDeckMustBeMember
        )
    }

    func testAddingSecondDeckDoesNotDuplicateCardsOrReviewLogs() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBKnowledgePointRepository(database: fixture.database)
        let noteID = fixture.exclusiveNote.noteID

        let countsBefore = try await cardAndLogCounts(noteID: noteID, in: fixture)
        let membership = try await repository.replaceDeckMembership(
            noteID: noteID,
            deckIDs: [fixture.deckAID, fixture.deckBID],
            homeDeckID: fixture.deckBID,
            at: Date()
        )
        XCTAssertEqual(membership.deckIDs, [fixture.deckAID, fixture.deckBID])

        let countsAfter = try await cardAndLogCounts(noteID: noteID, in: fixture)
        XCTAssertEqual(countsAfter.cards, countsBefore.cards)
        XCTAssertEqual(countsAfter.logs, countsBefore.logs)
        // Card 归属不变：cards 表没有 deck 维度，共享不产生新行。
        XCTAssertEqual(countsAfter.cards, 3)
    }

    // MARK: - move facade

    func testMoveKnowledgePointCollapsesMembershipToDestination() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBKnowledgePointRepository(database: fixture.database)

        // 共享 Note {A,B} → move 到 B：成员折叠为 {B}，home=B。
        let result = try await repository.moveKnowledgePoint(
            noteID: fixture.sharedNote.noteID,
            to: fixture.deckBID,
            at: Date()
        )
        XCTAssertEqual(result, .moved(cardCount: 3))
        let persisted = try await repository.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(persisted?.deckIDs, [fixture.deckBID])
        XCTAssertEqual(persisted?.homeDeckID, fixture.deckBID)

        // 已在目标（唯一成员且 home=目标）→ alreadyInDestination。
        let again = try await repository.moveKnowledgePoint(
            noteID: fixture.sharedNote.noteID,
            to: fixture.deckBID,
            at: Date()
        )
        XCTAssertEqual(again, .alreadyInDestination)

        // 目标不存在 / Note 不存在。
        let missingDestination = try await repository.moveKnowledgePoint(
            noteID: fixture.exclusiveNote.noteID,
            to: UUID(),
            at: Date()
        )
        XCTAssertEqual(missingDestination, .destinationNotFound)
        let missingNote = try await repository.moveKnowledgePoint(
            noteID: UUID(),
            to: fixture.deckAID,
            at: Date()
        )
        XCTAssertEqual(missingNote, .noteNotFound)
    }

    // MARK: - 牌组统计与列表

    func testDeckSummariesCountSharedNotesInEachMemberDeck() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBDeckRepository(database: fixture.database)

        let summaries = try await repository.fetchDeckSummaries()
        let deckA = try XCTUnwrap(summaries.first { $0.id == fixture.deckAID })
        let deckB = try XCTUnwrap(summaries.first { $0.id == fixture.deckBID })
        // shared{A,B} 在两个牌组各计一次；exclusive{B} 只计 B。
        XCTAssertEqual(deckA.noteCount, 1)
        XCTAssertEqual(deckA.cardCount, 3)
        XCTAssertEqual(deckB.noteCount, 2)
        XCTAssertEqual(deckB.cardCount, 6)
    }

    func testContentListsFilterByMembershipAndExposeDeckIDs() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)
        let vocabulary = GRDBVocabularyRepository(database: fixture.database)

        let deckASummaries = try await knowledge.fetchKnowledgePointSummaries(deckID: fixture.deckAID)
        XCTAssertEqual(deckASummaries.map(\.id), [fixture.sharedNote.noteID])
        XCTAssertEqual(deckASummaries.first?.deckIDs, [fixture.deckAID, fixture.deckBID])
        XCTAssertEqual(deckASummaries.first?.deckID, fixture.deckAID)

        let deckBSummaries = try await knowledge.fetchKnowledgePointSummaries(deckID: fixture.deckBID)
        XCTAssertEqual(
            Set(deckBSummaries.map(\.id)),
            [fixture.sharedNote.noteID, fixture.exclusiveNote.noteID]
        )
        let exclusiveSummary = deckBSummaries.first { $0.id == fixture.exclusiveNote.noteID }
        XCTAssertEqual(exclusiveSummary?.deckIDs, [fixture.deckBID])

        let vocabularyA = try await vocabulary.fetchVocabularySummaries(deckID: fixture.deckAID)
        XCTAssertEqual(vocabularyA.map(\.id), [fixture.sharedNote.noteID])
        XCTAssertEqual(vocabularyA.first?.deckIDs, [fixture.deckAID, fixture.deckBID])

        let vocabularyB = try await vocabulary.fetchVocabularySummaries(deckID: fixture.deckBID)
        XCTAssertEqual(vocabularyB.count, 2)

        // 详情读取装载成员集合。
        let note = try await vocabulary.fetchVocabulary(id: fixture.sharedNote.noteID)
        XCTAssertEqual(note?.deckID, fixture.deckAID)
        XCTAssertEqual(note?.deckIDs, [fixture.deckAID, fixture.deckBID])
    }

    func testFavoritesAndSearchReturnSharedNoteOncePerDeck() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)
        _ = try await knowledge.setFavorite(
            noteID: fixture.sharedNote.noteID,
            isFavorite: true,
            at: Date()
        )

        // 收藏是全局视图：共享 Note 只出现一次，且带完整成员集合。
        let favorites = try await knowledge.fetchFavoriteSummaries()
        XCTAssertEqual(favorites.map(\.id), [fixture.sharedNote.noteID])
        XCTAssertEqual(favorites.first?.deckIDs, [fixture.deckAID, fixture.deckBID])

        // 搜索按成员关系过滤，共享 Note 在两个牌组内各自命中一次。
        let search = GRDBKnowledgeSearchRepository(database: fixture.database)
        let deckAHits = try await search.search(
            normalizedQuery: "共有",
            deckID: fixture.deckAID,
            limit: 50,
            offset: 0
        )
        XCTAssertEqual(deckAHits.items.map(\.id), [fixture.sharedNote.noteID])
        let deckBHits = try await search.search(
            normalizedQuery: "共有",
            deckID: fixture.deckBID,
            limit: 50,
            offset: 0
        )
        XCTAssertEqual(deckBHits.items.map(\.id), [fixture.sharedNote.noteID])
        let globalHits = try await search.search(
            normalizedQuery: "共有",
            deckID: nil,
            limit: 50,
            offset: 0
        )
        XCTAssertEqual(globalHits.items.map(\.id), [fixture.sharedNote.noteID])
        XCTAssertEqual(globalHits.items.first?.deckIDs, [fixture.deckAID, fixture.deckBID])
    }

    // MARK: - 牌组删除语义

    func testDeleteDeckIfEmptyUsesMembershipCounts() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBDeckRepository(database: fixture.database)

        // 牌组 A 有一个成员（共享 Note）→ notEmpty。
        let result = try await repository.deleteDeckIfEmpty(id: fixture.deckAID)
        XCTAssertEqual(result, .notEmpty(noteCount: 1, cardCount: 3))

        // 空牌组直接删除。
        let emptyDeckID = UUID()
        _ = try await repository.createDeck(id: emptyDeckID, name: "空", at: Date())
        let deleted = try await repository.deleteDeckIfEmpty(id: emptyDeckID)
        XCTAssertEqual(deleted, .deleted)
    }

    func testDeleteContentsRemovesExclusiveNotesAndRehomesSharedNotes() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let deckRepository = GRDBDeckRepository(database: fixture.database)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)

        // 造一个 home=B、成员 {B,C} 的共享 Note，验证重选 home。
        let deckCID = UUID()
        _ = try await deckRepository.createDeck(id: deckCID, name: "第三组", at: Date())
        let rehomedNoteID = UUID()
        try await fixture.insertNote(
            rehomedNoteID,
            deckID: fixture.deckBID,
            headword: "重定向",
            reading: nil,
            meaningZH: "重定向"
        )
        _ = try await knowledge.replaceDeckMembership(
            noteID: rehomedNoteID,
            deckIDs: [fixture.deckBID, deckCID],
            homeDeckID: fixture.deckBID,
            at: Date()
        )

        let result = try await deckRepository.deleteDeck(
            id: fixture.deckBID,
            strategy: .deleteContents,
            at: Date()
        )
        guard case let .deleted(impact) = result else {
            return XCTFail("expected deleted, got \(result)")
        }
        // B 原有成员：shared{A,B}、exclusive{B}、rehomed{B,C}。
        XCTAssertEqual(impact.noteCount, 3)
        XCTAssertEqual(impact.exclusiveNoteCount, 1)
        XCTAssertEqual(impact.sharedNoteCount, 2)

        // 独占 Note 连卡删除；共享 Note 保留且移除 B 成员关系。
        let exclusiveGone = try await knowledge.fetchDeckMembership(
            noteID: fixture.exclusiveNote.noteID
        )
        XCTAssertNil(exclusiveGone)
        let exclusiveCards = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.exclusiveNote.noteID)]
            )
        }
        XCTAssertEqual(exclusiveCards, 0)

        let shared = try await knowledge.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(shared?.deckIDs, [fixture.deckAID])
        XCTAssertEqual(shared?.homeDeckID, fixture.deckAID)
        let sharedCards = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.sharedNote.noteID)]
            )
        }
        XCTAssertEqual(sharedCards, 3)

        // home=被删牌组的共享 Note 重选 home：按 sort_order 选剩余成员 C。
        let rehomed = try await knowledge.fetchDeckMembership(noteID: rehomedNoteID)
        XCTAssertEqual(rehomed?.deckIDs, [deckCID])
        XCTAssertEqual(rehomed?.homeDeckID, deckCID)

        // 牌组已删除；A 是主牌组不受影响，B 非主牌组。
        let deckBExists = try await deckRepository.deckExists(id: fixture.deckBID)
        XCTAssertFalse(deckBExists)
    }

    func testMoveContentsMigratesEveryMemberAndClearsPrimaryDeck() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let deckRepository = GRDBDeckRepository(database: fixture.database)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)

        // 把 exclusiveNote 也加进 A，制造 home≠源牌组的成员。
        _ = try await knowledge.replaceDeckMembership(
            noteID: fixture.exclusiveNote.noteID,
            deckIDs: [fixture.deckAID, fixture.deckBID],
            homeDeckID: fixture.deckBID,
            at: Date()
        )

        // A 是主牌组；移动 A 的全部成员到 B 后删除 A。
        let result = try await deckRepository.deleteDeck(
            id: fixture.deckAID,
            strategy: .moveContents(to: fixture.deckBID),
            at: Date()
        )
        guard case let .deleted(impact) = result else {
            return XCTFail("expected deleted, got \(result)")
        }
        XCTAssertEqual(impact.noteCount, 2)

        // shared（home=A）重定向 home 到 B，成员 {B}。
        let shared = try await knowledge.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(shared?.deckIDs, [fixture.deckBID])
        XCTAssertEqual(shared?.homeDeckID, fixture.deckBID)
        // exclusive 本来就是 B 成员 → 幂等，成员 {B}、home 不变。
        let exclusive = try await knowledge.fetchDeckMembership(noteID: fixture.exclusiveNote.noteID)
        XCTAssertEqual(exclusive?.deckIDs, [fixture.deckBID])
        XCTAssertEqual(exclusive?.homeDeckID, fixture.deckBID)

        // A 的成员行被移除；主牌组指针清空。
        let orphanMemberships = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM note_decks WHERE deck_id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.deckAID)]
            )
        }
        XCTAssertEqual(orphanMemberships, 0)
        let primary = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT primary_deck_id FROM app_settings WHERE id = 1"
            )
        }
        XCTAssertNil(primary)
        let deckAExists = try await deckRepository.deckExists(id: fixture.deckAID)
        XCTAssertFalse(deckAExists)
    }

    // MARK: - 今日队列与复习内容

    func testTodaySummaryFiltersByMembershipWithoutDuplicating() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let queue = GRDBTodayQueueRepository(database: fixture.database)
        let fetchedStudyDay = try await planning.fetchStudyDay(
            containing: MultiDeckDatabaseFixture.baseDate
        )
        let studyDay = try XCTUnwrap(fetchedStudyDay)

        // 牌组 A 今日：sharedNote 一组新词（两个方向卡只计一个新词额度）。
        let deckA = try await queue.fetchSummary(
            for: studyDay,
            deckID: fixture.deckAID,
            at: MultiDeckDatabaseFixture.baseDate
        )
        XCTAssertEqual(deckA.newCount, 1)

        // 牌组 B 今日：shared + exclusive 两组新词。
        let deckB = try await queue.fetchSummary(
            for: studyDay,
            deckID: fixture.deckBID,
            at: MultiDeckDatabaseFixture.baseDate
        )
        XCTAssertEqual(deckB.newCount, 2)

        // 全局：两个 Note 各一次（共享不重复）。
        let global = try await queue.fetchSummary(
            for: studyDay,
            deckID: nil,
            at: MultiDeckDatabaseFixture.baseDate
        )
        XCTAssertEqual(global.newCount, 2)
    }

    func testReviewCardContentLoadsMembership() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBReviewCardContentRepository(database: fixture.database)

        let content = try await repository.fetchReviewCardContent(
            cardID: fixture.sharedNote.cardID(.vocabularyJapaneseToChinese)
        )
        XCTAssertEqual(content?.deckID, fixture.deckAID)
        XCTAssertEqual(content?.deckIDs, [fixture.deckAID, fixture.deckBID])
    }

    // MARK: - 新建事务写全部成员

    func testCommitWritesEveryMembershipDeck() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBContentCardRepository(database: fixture.database)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)

        let commit = try VocabularyContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: fixture.deckAID,
            content: VocabularyFormData(headword: "新語", meaningZH: "新词").validatedContent(),
            tags: [],
            cards: [NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)],
            schedulerProfileID: UUID(),
            createdAt: Date(),
            deckIDs: [fixture.deckAID, fixture.deckBID]
        )
        let result = try await repository.commitVocabulary(commit, capture: nil)
        XCTAssertTrue(result.wasCreated)

        let membership = try await knowledge.fetchDeckMembership(noteID: commit.noteID)
        XCTAssertEqual(membership?.homeDeckID, fixture.deckAID)
        XCTAssertEqual(membership?.deckIDs, [fixture.deckAID, fixture.deckBID])

        // 新建 Note 在成员牌组内可见，全局只计一次。
        let deckA = try await knowledge.fetchKnowledgePointSummaries(deckID: fixture.deckAID)
        XCTAssertTrue(deckA.contains { $0.id == commit.noteID })
        let deckB = try await knowledge.fetchKnowledgePointSummaries(deckID: fixture.deckBID)
        XCTAssertTrue(deckB.contains { $0.id == commit.noteID })
    }

    func testCommitRejectsUnknownMemberDeckAtomically() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBContentCardRepository(database: fixture.database)
        let unknown = UUID()

        let commit = try VocabularyContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: fixture.deckAID,
            content: VocabularyFormData(headword: "新語", meaningZH: "新词").validatedContent(),
            tags: [],
            cards: [NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)],
            schedulerProfileID: UUID(),
            createdAt: Date(),
            deckIDs: [fixture.deckAID, unknown]
        )
        do {
            _ = try await repository.commitVocabulary(commit, capture: nil)
            XCTFail("expected deckNotFound")
        } catch let error as ContentCardError {
            XCTAssertEqual(error, .deckNotFound)
        }

        // 原子性：Note 与任何成员行都不存在。
        let noteCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(commit.noteID)]
            )
        }
        XCTAssertEqual(noteCount, 0)
        let memberCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM note_decks WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(commit.noteID)]
            )
        }
        XCTAssertEqual(memberCount, 0)
    }

    // MARK: - T06：删除影响预览与事务完整性

    func testPreviewDeletionImpactSeparatesExclusiveAndShared() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBDeckRepository(database: fixture.database)

        // 牌组 B：成员 = shared{A,B} + exclusive{B} → 独占 1（3 卡）、
        // 共享 1；cardCount 含共享 Note 的卡（6）。
        let impactB = try await repository.previewDeletionImpact(id: fixture.deckBID)
        XCTAssertEqual(impactB?.noteCount, 2)
        XCTAssertEqual(impactB?.cardCount, 6)
        XCTAssertEqual(impactB?.exclusiveNoteCount, 1)
        XCTAssertEqual(impactB?.exclusiveCardCount, 3)
        XCTAssertEqual(impactB?.sharedNoteCount, 1)
        XCTAssertEqual(impactB?.reviewLogCount, 2)

        // 牌组 A：仅 shared{A,B} 一个成员 → 全共享、无独占。
        let impactA = try await repository.previewDeletionImpact(id: fixture.deckAID)
        XCTAssertEqual(impactA?.noteCount, 1)
        XCTAssertEqual(impactA?.exclusiveNoteCount, 0)
        XCTAssertEqual(impactA?.exclusiveCardCount, 0)
        XCTAssertEqual(impactA?.sharedNoteCount, 1)

        // 不存在的牌组 → nil。
        let missing = try await repository.previewDeletionImpact(id: UUID())
        XCTAssertNil(missing)
    }

    func testDeleteContentsRollsBackOnMidTransactionFailure() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBDeckRepository(database: fixture.database)

        // 注入故障：删除 note_decks 行时中断，使 deleteContents 事务
        // 在中途失败。
        try await fixture.database.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_membership_delete
                BEFORE DELETE ON note_decks
                BEGIN
                    SELECT RAISE(ABORT, 'injected membership delete failure');
                END;
                """)
        }

        do {
            _ = try await repository.deleteDeck(
                id: fixture.deckBID,
                strategy: .deleteContents,
                at: Date()
            )
            XCTFail("injected failure must abort the deletion")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("injected membership delete failure")
            )
        }

        // 原子性：牌组、全部 Note、成员行与卡片保持原样。
        let deckBStillExists = try await repository.deckExists(id: fixture.deckBID)
        XCTAssertTrue(deckBStillExists)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)
        let shared = try await knowledge.fetchDeckMembership(noteID: fixture.sharedNote.noteID)
        XCTAssertEqual(shared?.deckIDs, [fixture.deckAID, fixture.deckBID])
        XCTAssertEqual(shared?.homeDeckID, fixture.deckAID)
        let exclusive = try await knowledge.fetchDeckMembership(
            noteID: fixture.exclusiveNote.noteID
        )
        XCTAssertEqual(exclusive?.deckIDs, [fixture.deckBID])
        let noteCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")
        }
        XCTAssertEqual(noteCount, 2)
        let cardCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards")
        }
        XCTAssertEqual(cardCount, 6)
    }

    // MARK: - T05：额度归属与历史归因

    func testQueueItemsCarryMembershipAndStayUniqueGlobally() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let queue = GRDBTodayQueueRepository(database: fixture.database)
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let fetchedDay = try await planning.fetchStudyDay(
            containing: MultiDeckDatabaseFixture.baseDate
        )
        let studyDay = try XCTUnwrap(fetchedDay)

        let plan = try await queue.buildQueue(
            for: studyDay,
            at: MultiDeckDatabaseFixture.baseDate
        )
        let allItems = plan.availableNow + plan.availableLater
        // 全局队列按 cardID 唯一：共享 Note 不因 {A,B} 成员出现两份。
        XCTAssertEqual(Set(allItems.map(\.cardID)).count, allItems.count)
        // 共享 Note 的队列项携带完整成员集合。
        let sharedItems = allItems.filter { $0.noteID == fixture.sharedNote.noteID }
        XCTAssertFalse(sharedItems.isEmpty)
        for item in sharedItems {
            XCTAssertEqual(item.deckID, fixture.deckAID)
            XCTAssertEqual(item.deckIDs, [fixture.deckAID, fixture.deckBID])
        }
    }

    func testAllocationDeckPrefersPrimaryMembershipOverHome() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)
        let fetchedDay = try await planning.fetchStudyDay(
            containing: MultiDeckDatabaseFixture.baseDate
        )
        let studyDay = try XCTUnwrap(fetchedDay)

        // 给共享 Note 增加第三个成员牌组 C——仍只占一个新词额度。
        let deckCID = UUID()
        _ = try await GRDBDeckRepository(database: fixture.database)
            .createDeck(id: deckCID, name: "第三组", at: Date())
        _ = try await knowledge.replaceDeckMembership(
            noteID: fixture.sharedNote.noteID,
            deckIDs: [fixture.deckAID, fixture.deckBID, deckCID],
            homeDeckID: fixture.deckAID,
            at: Date()
        )

        // 主牌组 = B：sharedNote 是 B 成员 → 额度归属 B（即使 home=A）。
        _ = try await planning.updatePrimaryDeck(fixture.deckBID)
        let plan = try await planning.persistAndReconcileNewCards(
            studyDay,
            at: MultiDeckDatabaseFixture.baseDate
        )
        let sharedCardIDs = Set(fixture.sharedNote.cards.values)
        let sharedReservations = plan.reservations.filter {
            sharedCardIDs.contains($0.cardID)
        }
        XCTAssertFalse(sharedReservations.isEmpty)
        XCTAssertEqual(Set(sharedReservations.map(\.deckID)), [fixture.deckBID])
        // 两个 Note 合计占两个额度，与成员牌组数无关。
        XCTAssertEqual(plan.reservedNoteCount, 2)
        XCTAssertEqual(
            Set(plan.reservations.map(\.deckID)),
            [fixture.deckBID]
        )

        // 主牌组清空后自动默认回落到排序最前的 A（sort_order 最小）：
        // shared 是 A 成员 → 额度归 A；exclusive 只属于 B → 归 home B。
        _ = try await planning.updatePrimaryDeck(nil)
        let replanned = try await planning.persistAndReconcileNewCards(
            studyDay,
            at: MultiDeckDatabaseFixture.baseDate
        )
        for reservation in replanned.reservations {
            if sharedCardIDs.contains(reservation.cardID) {
                XCTAssertEqual(reservation.deckID, fixture.deckAID)
            } else {
                XCTAssertEqual(reservation.deckID, fixture.deckBID)
            }
        }
    }

    func testNewCardQuotaCountsNoteOnceAcrossThreeDecks() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)
        let fetchedDay = try await planning.fetchStudyDay(
            containing: MultiDeckDatabaseFixture.baseDate
        )
        let studyDay = try XCTUnwrap(fetchedDay)

        let deckCID = UUID()
        _ = try await GRDBDeckRepository(database: fixture.database)
            .createDeck(id: deckCID, name: "第三组", at: Date())
        _ = try await knowledge.replaceDeckMembership(
            noteID: fixture.sharedNote.noteID,
            deckIDs: [fixture.deckAID, fixture.deckBID, deckCID],
            homeDeckID: fixture.deckAID,
            at: Date()
        )

        // 额度=1（额度取自 proposedStudyDay.newCardLimit）：只有一个
        // Note 获准入，且其全部方向一起入场。
        let limitedDay = studyDay.replacingNewCardLimit(1)
        let plan = try await planning.persistAndReconcileNewCards(
            limitedDay,
            at: MultiDeckDatabaseFixture.baseDate
        )
        let liveAdmissions = try await fixture.database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT cards.note_id, COUNT(*) AS card_count
                    FROM daily_tasks
                    JOIN cards ON cards.id = daily_tasks.card_id
                    WHERE daily_tasks.study_day_id = ?
                      AND daily_tasks.category_at_admission = 'new'
                      AND daily_tasks.cancelled_at_ms IS NULL
                    GROUP BY cards.note_id
                    """,
                arguments: [DatabaseValueCodec.encode(studyDay.id)]
            ).map { row in
                (
                    noteID: try DatabaseValueCodec.decodeUUID(row["note_id"] as String),
                    cardCount: row["card_count"] as Int
                )
            }
        }
        XCTAssertEqual(liveAdmissions.count, 1)
        // 主牌组 A 优先：sharedNote（A 成员）胜出，两个未学方向成组。
        let winner = try XCTUnwrap(liveAdmissions.first)
        XCTAssertEqual(winner.noteID, fixture.sharedNote.noteID)
        XCTAssertEqual(winner.cardCount, 2)
        XCTAssertEqual(plan.reservedNoteCount, 1)
    }

    func testReviewAttributionUsesScopeDeckWhenMember() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let queue = GRDBTodayQueueRepository(database: fixture.database)
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let submission = GRDBReviewSubmissionRepository(database: fixture.database)
        let fetchedDay = try await planning.fetchStudyDay(
            containing: MultiDeckDatabaseFixture.baseDate
        )
        let studyDay = try XCTUnwrap(fetchedDay)
        // buildQueue 把到期复习卡补进当日任务（提交守卫要求）。
        _ = try await queue.buildQueue(
            for: studyDay,
            at: MultiDeckDatabaseFixture.baseDate
        )

        let useCase = SubmitReview(
            repository: submission,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: MultiDeckFixedClock(value: MultiDeckDatabaseFixture.baseDate)
        )
        // sharedNote 的 ja→zh 复习卡从牌组 B scope 提交 → 归因 B（成员）。
        let cardID = fixture.sharedNote.cardID(.vocabularyJapaneseToChinese)
        let log = try await useCase(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: cardID,
                expectedStateVersion: 2,
                rating: .good,
                durationMilliseconds: 1_000,
                studyDay: StudyDayContext(id: studyDay.id),
                scopeDeckID: fixture.deckBID
            )
        )
        XCTAssertEqual(log.deckIDAtReview, fixture.deckBID)

        // 非成员 scope 回退 home：exclusiveNote 的 zh→ja 新卡用未知牌组提交。
        let exclusiveCardID = fixture.exclusiveNote.cardID(.vocabularyChineseToJapanese)
        let fallbackLog = try await useCase(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: exclusiveCardID,
                expectedStateVersion: 0,
                rating: .good,
                durationMilliseconds: 1_000,
                studyDay: StudyDayContext(id: studyDay.id),
                scopeDeckID: UUID()
            )
        )
        XCTAssertEqual(fallbackLog.deckIDAtReview, fixture.deckBID)

        // 一次评分只产生一条日志；重复 eventID 幂等返回同一日志。
        let duplicate = try await useCase(
            SubmitReviewRequest(
                eventID: log.eventID,
                cardID: cardID,
                expectedStateVersion: 3,
                rating: .easy,
                durationMilliseconds: 1_000,
                studyDay: StudyDayContext(id: studyDay.id),
                scopeDeckID: fixture.deckAID
            )
        )
        XCTAssertEqual(duplicate.id, log.id)
        let logCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE note_id = ? AND study_day_id = ?",
                arguments: [
                    DatabaseValueCodec.encode(fixture.sharedNote.noteID),
                    DatabaseValueCodec.encode(studyDay.id)
                ]
            )
        }
        XCTAssertEqual(logCount, 1)

        // 切换 home 不改已有日志归因。
        _ = try await GRDBKnowledgePointRepository(database: fixture.database)
            .replaceDeckMembership(
                noteID: fixture.sharedNote.noteID,
                deckIDs: [fixture.deckAID, fixture.deckBID],
                homeDeckID: fixture.deckBID,
                at: Date()
            )
        let persisted = try await submission.fetchSubmittedReview(eventID: log.eventID)
        XCTAssertEqual(persisted?.deckIDAtReview, fixture.deckBID)
    }

    func testTodayStatsUseMembershipWhileCompletionUsesAttribution() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let history = GRDBStudyHistoryRepository(database: fixture.database)
        let queue = GRDBTodayQueueRepository(database: fixture.database)
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let submission = GRDBReviewSubmissionRepository(database: fixture.database)
        let fetchedDay = try await planning.fetchStudyDay(
            containing: MultiDeckDatabaseFixture.baseDate
        )
        let studyDay = try XCTUnwrap(fetchedDay)
        _ = try await queue.buildQueue(
            for: studyDay,
            at: MultiDeckDatabaseFixture.baseDate
        )

        // 从牌组 B scope 复习共享 Note。
        _ = try await SubmitReview(
            repository: submission,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: MultiDeckFixedClock(value: MultiDeckDatabaseFixture.baseDate)
        )(
            SubmitReviewRequest(
                eventID: UUID(),
                cardID: fixture.sharedNote.cardID(.vocabularyJapaneseToChinese),
                expectedStateVersion: 2,
                rating: .good,
                durationMilliseconds: 1_000,
                studyDay: StudyDayContext(id: studyDay.id),
                scopeDeckID: fixture.deckBID
            )
        )

        // 今日任务按成员计数：sharedNote 的任务同时计入 A 与 B——
        // 到期复习卡一张、未学方向按词计一个额度；B 另有 exclusive 一词。
        let stats = try await history.fetchTodayStatistics(studyDayID: studyDay.id)
        let deckA = stats.tasks(for: fixture.deckAID)
        let deckB = stats.tasks(for: fixture.deckBID)
        XCTAssertEqual(deckA.reviewCount, 1)
        XCTAssertEqual(deckB.reviewCount, 1)
        XCTAssertEqual(deckA.newCount, 1)  // shared 的两个未学方向按词计 1
        XCTAssertEqual(deckB.newCount, 2)  // shared + exclusive

        // 完成统计按日志归因：归 B 的复习只在 B 出现。
        let completionB = try await history.fetchCompletionStatistics(
            studyDayID: studyDay.id,
            deckID: fixture.deckBID
        )
        XCTAssertEqual(completionB.reviewedCardCount, 1)
        XCTAssertEqual(completionB.answerCount, 1)
        let completionA = try await history.fetchCompletionStatistics(
            studyDayID: studyDay.id,
            deckID: fixture.deckAID
        )
        XCTAssertEqual(completionA.reviewedCardCount, 0)
        XCTAssertEqual(completionA.answerCount, 0)
    }

    // MARK: - Helpers

    private func cardAndLogCounts(
        noteID: UUID,
        in fixture: MultiDeckDatabaseFixture
    ) async throws -> (cards: Int, logs: Int) {
        try await fixture.database.pool.read { db in
            let cards = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) ?? 0
            let logs = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) ?? 0
            return (cards, logs)
        }
    }

    private struct MultiDeckFixedClock: SchedulingClock {
        let value: Date
        func now() -> Date { value }
    }

    private func XCTAssertThrowsMembershipError<T>(
        _ expression: @autoclosure () async throws -> T,
        equals expected: NoteDeckMembershipError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as NoteDeckMembershipError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
