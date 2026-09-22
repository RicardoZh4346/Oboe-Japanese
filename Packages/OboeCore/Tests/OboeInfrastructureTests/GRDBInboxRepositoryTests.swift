import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBInboxRepositoryTests: XCTestCase {
    func testInsertAndFetchItemRoundTrip() async throws {
        try await withTemporaryRepository { repository, database in
            let item = Self.makeItem(text: "そんなわけないでしょう。", sourceType: .share, sourceApp: "Safari")
            try await repository.insertItem(item)

            let fetched = try await repository.fetchItem(id: item.id)
            XCTAssertEqual(fetched, item)

            let storedStatus = try await database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT status FROM inbox_items WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(item.id)]
                )
            }
            XCTAssertEqual(storedStatus, "unprocessed")
        }
    }

    func testInsertRejectsNonUnprocessedItem() async throws {
        try await withTemporaryRepository { repository, _ in
            let seed = Self.makeItem()
            let item = InboxItem(
                id: seed.id,
                text: seed.text,
                sourceType: seed.sourceType,
                status: .processing,
                contentRevision: seed.contentRevision,
                sourceApp: nil,
                sourceURL: nil,
                imageReference: nil,
                createdAt: seed.createdAt,
                updatedAt: seed.updatedAt,
                processedAt: nil,
                archivedAt: nil,
                statusBeforeArchive: nil
            )
            await assertThrowsInboxError(
                { try await repository.insertItem(item) },
                equals: .invalidNewItemStatus(.processing)
            )
        }
    }

    func testStatusTransitionsFollowStateMachine() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let now = Date(timeIntervalSince1970: 1_768_000_000)

            let processing = try await repository.markItemProcessing(id: item.id, at: now)
            XCTAssertEqual(processing.status, .processing)

            await assertThrowsInboxError(
                { try await repository.markItemProcessing(id: item.id, at: now) },
                equals: .invalidStatusTransition(from: .processing, to: .processing)
            )

            let abandoned = try await repository.markItemUnprocessed(id: item.id, at: now)
            XCTAssertEqual(abandoned.status, .unprocessed)

            await assertThrowsInboxError(
                { try await repository.markItemProcessed(id: item.id, at: now) },
                equals: .invalidStatusTransition(from: .unprocessed, to: .processed)
            )

            _ = try await repository.markItemProcessing(id: item.id, at: now)
            let processed = try await repository.markItemProcessed(id: item.id, at: now)
            XCTAssertEqual(processed.status, .processed)
            XCTAssertEqual(processed.processedAt, now)
        }
    }

    func testArchiveAndUnarchiveRestorePreviousStatus() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let now = Date(timeIntervalSince1970: 1_768_000_000)

            _ = try await repository.markItemProcessing(id: item.id, at: now)
            _ = try await repository.markItemProcessed(id: item.id, at: now)

            let archiveDate = now.addingTimeInterval(60)
            try await repository.archiveItems(ids: [item.id], at: archiveDate)
            var fetched = try await repository.fetchItem(id: item.id)
            XCTAssertEqual(fetched?.status, .archived)
            XCTAssertEqual(fetched?.archivedAt, archiveDate)
            XCTAssertEqual(fetched?.statusBeforeArchive, .processed)
            XCTAssertEqual(fetched?.processedAt, now)

            let unarchived = try await repository.unarchiveItem(id: item.id, at: now)
            XCTAssertEqual(unarchived.status, .processed)
            XCTAssertNil(unarchived.archivedAt)
            XCTAssertNil(unarchived.statusBeforeArchive)
            XCTAssertEqual(unarchived.processedAt, now)

            await assertThrowsInboxError(
                { try await repository.unarchiveItem(id: item.id, at: now) },
                equals: .itemNotArchived
            )

            fetched = try await repository.fetchItem(id: UUID())
            XCTAssertNil(fetched)
        }
    }

    func testArchiveItemsIsIdempotentAcrossMixedIDs() async throws {
        try await withTemporaryRepository { repository, _ in
            let first = Self.makeItem()
            let second = Self.makeItem()
            let third = Self.makeItem()
            try await repository.insertItem(first)
            try await repository.insertItem(second)
            try await repository.insertItem(third)

            let firstArchive = Date(timeIntervalSince1970: 1_768_000_000)
            try await repository.archiveItems(ids: [third.id], at: firstArchive)

            let secondArchive = firstArchive.addingTimeInterval(60)
            try await repository.archiveItems(
                ids: [first.id, second.id, third.id, UUID()],
                at: secondArchive
            )

            var items: [InboxItem?] = []
            for source in [first, second, third] {
                items.append(try await repository.fetchItem(id: source.id))
            }
            XCTAssertEqual(items[0]?.status, .archived)
            XCTAssertEqual(items[0]?.archivedAt, secondArchive)
            XCTAssertEqual(items[0]?.statusBeforeArchive, .unprocessed)
            XCTAssertEqual(items[1]?.status, .archived)
            XCTAssertEqual(items[1]?.statusBeforeArchive, .unprocessed)
            // 已归档条目保留原有归档标记，不被二次归档覆盖。
            XCTAssertEqual(items[2]?.status, .archived)
            XCTAssertEqual(items[2]?.archivedAt, firstArchive)
            XCTAssertEqual(items[2]?.statusBeforeArchive, .unprocessed)
        }
    }

    func testUpdateTextChecksRevisionAndResetsProcessedToUnprocessed() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let now = Date(timeIntervalSince1970: 1_768_000_000)

            _ = try await repository.markItemProcessing(id: item.id, at: now)
            _ = try await repository.markItemProcessed(id: item.id, at: now)

            await assertThrowsInboxError(
                {
                    try await repository.updateItemText(
                        id: item.id,
                        expectedRevision: 99,
                        text: "しょうがないな。",
                        at: now
                    )
                },
                equals: .revisionConflict(expected: 99, actual: 1)
            )

            let edited = try await repository.updateItemText(
                id: item.id,
                expectedRevision: item.contentRevision,
                text: "しょうがないな。",
                at: now
            )
            XCTAssertEqual(edited.text, "しょうがないな。")
            XCTAssertEqual(edited.contentRevision, item.contentRevision + 1)
            XCTAssertEqual(edited.status, .unprocessed)
            XCTAssertEqual(edited.processedAt, now)
        }
    }

    func testUpdateTextRejectsMissingAndArchivedItems() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let now = Date(timeIntervalSince1970: 1_768_000_000)

            await assertThrowsInboxError(
                {
                    try await repository.updateItemText(
                        id: UUID(),
                        expectedRevision: 1,
                        text: "x",
                        at: now
                    )
                },
                equals: .itemNotFound
            )

            try await repository.archiveItems(ids: [item.id], at: now)
            await assertThrowsInboxError(
                {
                    try await repository.updateItemText(
                        id: item.id,
                        expectedRevision: 1,
                        text: "x",
                        at: now
                    )
                },
                equals: .itemArchived
            )
        }
    }

    func testFetchPageOrdersByCreatedAtThenIDAcrossPages() async throws {
        try await withTemporaryRepository { repository, _ in
            let sharedTimestamp = Date(timeIntervalSince1970: 1_768_000_000)
            let first = Self.makeItem(text: "一", createdAt: sharedTimestamp)
            let second = Self.makeItem(text: "二", createdAt: sharedTimestamp)
            let third = Self.makeItem(text: "三", createdAt: sharedTimestamp)
            for item in [first, second, third] {
                try await repository.insertItem(item)
            }

            let expectedOrder = [first, second, third]
                .sorted { DatabaseValueCodec.encode($0.id) > DatabaseValueCodec.encode($1.id) }

            let firstPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: nil,
                cursor: nil,
                limit: 2
            )
            XCTAssertEqual(firstPage.items.map(\.id), expectedOrder.prefix(2).map(\.id))
            XCTAssertNotNil(firstPage.nextCursor)

            let secondPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: nil,
                cursor: try XCTUnwrap(firstPage.nextCursor),
                limit: 2
            )
            XCTAssertEqual(secondPage.items.map(\.id), [expectedOrder[2].id])
            XCTAssertNil(secondPage.nextCursor)
        }
    }

    func testFetchPageFiltersByStatus() async throws {
        try await withTemporaryRepository { repository, _ in
            let active = Self.makeItem(text: "未处理")
            let archived = Self.makeItem(text: "已归档")
            try await repository.insertItem(active)
            try await repository.insertItem(archived)
            try await repository.archiveItems(ids: [archived.id], at: Date())

            let unprocessedPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: nil,
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(unprocessedPage.items.map(\.id), [active.id])

            let archivedPage = try await repository.fetchPage(
                status: .archived,
                normalizedQuery: nil,
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(archivedPage.items.map(\.id), [archived.id])
        }
    }

    func testSearchMatchesKanaAndNormalization() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem(text: "パンを食べる")
            let other = Self.makeItem(text: "学校に行く")
            try await repository.insertItem(item)
            try await repository.insertItem(other)

            let hiraganaPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: SearchTextNormalizer.normalize("ぱん"),
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(hiraganaPage.items.map(\.id), [item.id])

            let halfWidthPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: SearchTextNormalizer.normalize("ﾊﾟﾝ"),
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(halfWidthPage.items.map(\.id), [item.id])
        }
    }

    func testSearchTreatsWildcardsAsLiterals() async throws {
        try await withTemporaryRepository { repository, _ in
            let percent = Self.makeItem(text: "50%オフ")
            let plain = Self.makeItem(text: "半額セール")
            try await repository.insertItem(percent)
            try await repository.insertItem(plain)

            let percentPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: SearchTextNormalizer.normalize("%"),
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(percentPage.items.map(\.id), [percent.id])

            let underscore = Self.makeItem(text: "A_B")
            let similar = Self.makeItem(text: "AxB")
            try await repository.insertItem(underscore)
            try await repository.insertItem(similar)

            let underscorePage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: SearchTextNormalizer.normalize("_"),
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(underscorePage.items.map(\.id), [underscore.id])

            let backslashPage = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: SearchTextNormalizer.normalize("\\"),
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(backslashPage.items.count, 0)
        }
    }

    func testSearchComposedCharacters() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem(text: "がっこう")
            try await repository.insertItem(item)

            let page = try await repository.fetchPage(
                status: .unprocessed,
                normalizedQuery: SearchTextNormalizer.normalize("か\u{3099}"),
                cursor: nil,
                limit: 50
            )
            XCTAssertEqual(page.items.map(\.id), [item.id])
        }
    }

    func testUnprocessedCountReflectsStatusChanges() async throws {
        try await withTemporaryRepository { repository, _ in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            var count = try await repository.fetchUnprocessedCount()
            XCTAssertEqual(count, 1)

            try await repository.archiveItems(ids: [item.id], at: Date())
            count = try await repository.fetchUnprocessedCount()
            XCTAssertEqual(count, 0)

            let second = Self.makeItem()
            try await repository.insertItem(second)
            _ = try await repository.markItemProcessing(id: second.id, at: Date())
            count = try await repository.fetchUnprocessedCount()
            XCTAssertEqual(count, 0)
        }
    }

    func testDeleteRemovesOwnedDraftsButKeepsSharedAndLearningContent() async throws {
        try await withTemporaryRepository { repository, database in
            let deckID = UUID()
            let noteID = UUID()
            let inboxID = UUID()
            let otherInboxID = UUID()
            let ownDraftID = UUID()
            let sharedDraftID = UUID()
            let normalDraftID = UUID()

            try await database.pool.write { db in
                try Self.insertDeck(id: deckID, name: "学习", in: db)
                try Self.insertNote(id: noteID, deckID: deckID, in: db)
                try Self.insertDraft(in: db, id: DatabaseValueCodec.encode(ownDraftID))
                try Self.insertDraft(in: db, id: DatabaseValueCodec.encode(sharedDraftID))
                try Self.insertDraft(in: db, id: DatabaseValueCodec.encode(normalDraftID))
            }

            try await repository.insertItem(Self.makeItem(id: inboxID))
            try await repository.insertItem(Self.makeItem(id: otherInboxID))
            try await database.pool.write { db in
                try Self.insertContext(
                    in: db,
                    inboxItemID: DatabaseValueCodec.encode(inboxID),
                    draftID: DatabaseValueCodec.encode(ownDraftID)
                )
                try Self.insertContext(
                    in: db,
                    inboxItemID: DatabaseValueCodec.encode(inboxID),
                    draftID: DatabaseValueCodec.encode(sharedDraftID)
                )
                try Self.insertContext(
                    in: db,
                    inboxItemID: DatabaseValueCodec.encode(otherInboxID),
                    draftID: DatabaseValueCodec.encode(sharedDraftID)
                )
            }

            try await repository.deleteItem(id: inboxID)

            let counts = try await database.pool.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")!,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items")!,
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM drafts WHERE id = ?",
                        arguments: [DatabaseValueCodec.encode(ownDraftID)]
                    )!,
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM drafts WHERE id = ?",
                        arguments: [DatabaseValueCodec.encode(sharedDraftID)]
                    )!,
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM drafts WHERE id = ?",
                        arguments: [DatabaseValueCodec.encode(normalDraftID)]
                    )!,
                    try Int.fetchOne(
                        db,
                        sql: """
                            SELECT COUNT(*) FROM inbox_processing_contexts
                            WHERE inbox_item_id = ?
                            """,
                        arguments: [DatabaseValueCodec.encode(inboxID)]
                    )!
                )
            }
            XCTAssertEqual(counts.0, 1)
            XCTAssertEqual(counts.1, 1)
            XCTAssertEqual(counts.2, 0)
            XCTAssertEqual(counts.3, 1)
            XCTAssertEqual(counts.4, 1)
            XCTAssertEqual(counts.5, 0)

            await assertThrowsInboxError(
                { try await repository.deleteItem(id: inboxID) },
                equals: .itemNotFound
            )
        }
    }

    func testImportReceiptIsIdempotentAndSurvivesItemDeletion() async throws {
        try await withTemporaryRepository { repository, _ in
            let captureID = UUID()
            let item = Self.makeItem()
            let receipt = CaptureImportReceipt(
                captureID: captureID,
                payloadHash: "hash-1",
                inboxItemID: item.id,
                importedAt: Date(timeIntervalSince1970: 1_768_000_000)
            )

            let first = try await repository.insertImportedItem(item, receipt: receipt)
            XCTAssertEqual(first, .imported(item))

            let duplicate = try await repository.insertImportedItem(item, receipt: receipt)
            XCTAssertEqual(duplicate, .alreadyImported(inboxItemID: item.id))
            var count = try await repository.fetchUnprocessedCount()
            XCTAssertEqual(count, 1)

            let conflicting = CaptureImportReceipt(
                captureID: captureID,
                payloadHash: "hash-2",
                inboxItemID: item.id,
                importedAt: Date()
            )
            await assertThrowsInboxError(
                { try await repository.insertImportedItem(item, receipt: conflicting) },
                equals: .captureConflict(captureID: captureID)
            )
            count = try await repository.fetchUnprocessedCount()
            XCTAssertEqual(count, 1)

            try await repository.deleteItem(id: item.id)
            let afterDelete = try await repository.insertImportedItem(item, receipt: receipt)
            XCTAssertEqual(afterDelete, .alreadyImported(inboxItemID: nil))
            count = try await repository.fetchUnprocessedCount()
            XCTAssertEqual(count, 0)

            let stored = try await repository.fetchImportReceipt(captureID: captureID)
            XCTAssertEqual(stored?.payloadHash, "hash-1")
            XCTAssertNil(stored?.inboxItemID)
        }
    }

    func testCommitReceiptFetchableByOperationID() async throws {
        try await withTemporaryRepository { repository, database in
            let item = Self.makeItem()
            try await repository.insertItem(item)
            let contextID = UUID()
            let operationID = UUID()
            try await database.pool.write { db in
                try Self.insertContext(
                    in: db,
                    id: DatabaseValueCodec.encode(contextID),
                    inboxItemID: DatabaseValueCodec.encode(item.id)
                )
                try GRDBInboxRepository.insertCommitReceipt(
                    InboxCommitReceipt(
                        operationID: operationID,
                        processingContextID: contextID,
                        payloadHash: "hash-commit",
                        resultJSON: #"{"version":1,"noteIDs":[],"cardCount":0}"#,
                        committedAt: Date(timeIntervalSince1970: 1_768_000_000)
                    ),
                    in: db
                )
            }

            let receipt = try await repository.fetchCommitReceipt(operationID: operationID)
            XCTAssertEqual(receipt?.operationID, operationID)
            XCTAssertEqual(receipt?.processingContextID, contextID)
            XCTAssertEqual(receipt?.payloadHash, "hash-commit")

            try await repository.deleteItem(id: item.id)
            let surviving = try await repository.fetchCommitReceipt(operationID: operationID)
            XCTAssertEqual(surviving?.operationID, operationID)
            XCTAssertNil(surviving?.processingContextID)
        }
    }

    func testProcessingStatusSurvivesDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBInboxRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("oboe.sqlite")
        let item = Self.makeItem()

        do {
            let database = try OboeDatabase(path: fileURL.path)
            let repository = GRDBInboxRepository(database: database)
            try await repository.insertItem(item)
            _ = try await repository.markItemProcessing(
                id: item.id,
                at: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try database.close()
        }

        let reopened = try OboeDatabase(path: fileURL.path)
        let repository = GRDBInboxRepository(database: reopened)
        let fetched = try await repository.fetchItem(id: item.id)
        XCTAssertEqual(fetched?.status, .processing)
        try reopened.close()
    }
}

private extension GRDBInboxRepositoryTests {
    static func makeItem(
        id: UUID = UUID(),
        text: String = "そんなわけないでしょう。",
        sourceType: InboxSourceType = .manual,
        sourceApp: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_768_000_000)
    ) -> InboxItem {
        InboxItem(
            id: id,
            text: text,
            sourceType: sourceType,
            status: .unprocessed,
            contentRevision: 1,
            sourceApp: sourceApp,
            sourceURL: nil,
            imageReference: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
    }

    func withTemporaryRepository(
        _ body: (GRDBInboxRepository, OboeDatabase) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBInboxRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        try await body(GRDBInboxRepository(database: database), database)
    }

    func assertThrowsInboxError(
        _ body: () async throws -> Any,
        equals expected: InboxError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("预期抛出错误，但调用成功返回", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? InboxError, expected, file: file, line: line)
        }
    }

    static func insertDeck(id: UUID, name: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, 0, 1, 1)",
            arguments: [DatabaseValueCodec.encode(id), name]
        )
    }

    static func insertNote(id: UUID, deckID: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    origin, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃', 'manual', 1, 1, 1)
                """,
            arguments: [DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(deckID)]
        )
        try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
    }

    static func insertDraft(in db: Database, id: String) throws {
        try db.execute(
            sql: """
                INSERT INTO drafts(
                    id, draft_kind, payload_version, payload_json, updated_at_ms
                ) VALUES (?, 'vocabulary', 1, '{}', 1)
                """,
            arguments: [id]
        )
    }

    static func insertContext(
        in db: Database,
        id: String = DatabaseValueCodec.encode(UUID()),
        inboxItemID: String,
        draftID: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_processing_contexts(
                    id, inbox_item_id, content_revision, input_text, mode,
                    draft_id, payload_version, resume_payload_json, updated_at_ms
                ) VALUES (?, ?, 1, 'テキスト', 'manual_edit', ?, 1, NULL, 1)
                """,
            arguments: [id, inboxItemID, draftID]
        )
    }
}
