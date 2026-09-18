import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T15: capture commits must be atomic (note/cards + receipt + processed flag
/// in one transaction) and idempotent (same operationID replays the stored
/// result; a different payload under the same operationID is a conflict).
final class GRDBCaptureCommitTests: XCTestCase {

    func testVocabularyCommitWritesReceiptMarksProcessedAndPersistsSource() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let commit = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)

            let result = try await repository.commitVocabulary(commit, capture: capture)

            XCTAssertEqual(result.noteID, commit.noteID)
            XCTAssertEqual(result.cardCount, 2)
            let reloaded = try await inbox.fetchItem(id: item.id)
            XCTAssertEqual(reloaded?.status, .processed)
            XCTAssertNotNil(reloaded?.processedAt)

            try await database.pool.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT origin, source_text, source_ref FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]
                )
                XCTAssertEqual(row?["origin"], "ai")
                XCTAssertEqual(row?["source_text"], context.inputText)
                XCTAssertNil(row?["source_ref"] as String?)

                let receipt = try Row.fetchOne(
                    db,
                    sql: "SELECT processing_context_id, payload_hash, result_json FROM inbox_commit_receipts WHERE operation_id = ?",
                    arguments: [DatabaseValueCodec.encode(capture.operationID)]
                )
                XCTAssertEqual(
                    try receipt.map { try DatabaseValueCodec.decodeUUID($0["processing_context_id"]) },
                    context.id
                )
                XCTAssertNotNil(receipt?["payload_hash"] as String?)
                XCTAssertNotNil(receipt?["result_json"] as String?)
            }
        }
    }

    func testIdenticalRetryReplaysReceiptWithoutDuplicating() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let commit = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)

            let first = try await repository.commitVocabulary(commit, capture: capture)
            // Lost response → user retries: identical operationID + content.
            let second = try await repository.commitVocabulary(commit, capture: capture)

            XCTAssertEqual(second.noteID, first.noteID)
            XCTAssertEqual(second.cardCount, first.cardCount)
            XCTAssertFalse(second.wasCreated)

            try await database.pool.read { db in
                let noteCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]
                )
                let cardCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]
                )
                let receiptCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts",
                    arguments: []
                )
                XCTAssertEqual(noteCount, 1)
                XCTAssertEqual(cardCount, 2)
                XCTAssertEqual(receiptCount, 1)
            }
            let statusProcessed = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessed, .processed)
        }
    }

    func testSameOperationIDWithDifferentContentIsRejected() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)

            _ = try await repository.commitVocabulary(
                try Self.vocabularyCommit(deckID: deckID),
                capture: capture
            )
            let tampered = VocabularyContentCommit(
                noteID: UUID(),
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(headword: "別の語", meaningZH: "别的词").validatedContent(),
                tags: [],
                cards: [NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                origin: .ai,
                sourceText: context.inputText
            )

            do {
                _ = try await repository.commitVocabulary(tampered, capture: capture)
                XCTFail("Expected commitPayloadConflict")
            } catch InboxError.commitPayloadConflict(let operationID) {
                XCTAssertEqual(operationID, capture.operationID)
            }
        }
    }

    func testRetryAfterNoteDeletionStillReplaysWithoutRecreating() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let commit = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)

            let first = try await repository.commitVocabulary(commit, capture: capture)
            try await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(first.noteID)]
                )
            }

            let second = try await repository.commitVocabulary(commit, capture: capture)
            XCTAssertEqual(second.noteID, first.noteID)
            XCTAssertFalse(second.wasCreated)
            try await database.pool.read { db in
                let noteCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(first.noteID)]
                )
                XCTAssertEqual(noteCount, 0)
            }
        }
    }

    func testFailedCardInsertRollsBackNoteReceiptAndStatus() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            // Grammar template on a vocabulary commit fails mid-transaction,
            // after the note row was already inserted.
            let commit = VocabularyContentCommit(
                noteID: UUID(),
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(headword: "壊れる", meaningZH: "坏掉").validatedContent(),
                tags: [],
                cards: [NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation)],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                origin: .ai,
                sourceText: context.inputText
            )

            do {
                _ = try await repository.commitVocabulary(commit, capture: capture)
                XCTFail("Expected invalidTemplateForKnowledgePoint")
            } catch ContentCardError.invalidTemplateForKnowledgePoint {}

            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes", arguments: []),
                    0
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards", arguments: []),
                    0
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts", arguments: []),
                    0
                )
            }
            let statusProcessing = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessing, .processing)
        }
    }

    func testSourceRevisionChangedBeforeCommitAbortsEverything() async throws {
        try await withHarness { database, inbox, inboxService, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)

            // The item's text changed after the processing snapshot was taken.
            _ = try await inboxService.updateText(
                id: item.id,
                expectedRevision: context.contentRevision,
                text: "編集されたテキスト"
            )

            do {
                _ = try await repository.commitVocabulary(
                    try Self.vocabularyCommit(deckID: deckID),
                    capture: capture
                )
                XCTFail("Expected revisionConflict")
            } catch InboxError.revisionConflict(let expected, let actual) {
                XCTAssertEqual(expected, context.contentRevision)
                XCTAssertEqual(actual, context.contentRevision + 1)
            }

            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes", arguments: []),
                    0
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts", arguments: []),
                    0
                )
            }
            let statusProcessing = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessing, .processing)
        }
    }

    func testGrammarCommitPersistsOriginAndSourceText() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let commit = GrammarContentCommit(
                noteID: UUID(),
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try GrammarFormData(
                    grammarForm: "〜てしまう",
                    meaningZH: "表示完成或遗憾"
                ).validatedContent(),
                tags: [],
                card: NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation),
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                origin: .manual,
                sourceText: context.inputText
            )

            let result = try await repository.commitGrammar(commit, capture: capture)

            XCTAssertEqual(result.cardCount, 1)
            try await database.pool.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT origin, source_text FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]
                )
                XCTAssertEqual(row?["origin"], "manual")
                XCTAssertEqual(row?["source_text"], context.inputText)
            }
            let statusProcessed = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessed, .processed)
        }
    }

    func testLegacyCommitWithoutCaptureLeavesInboxUntouched() async throws {
        try await withHarness { database, inbox, _, item, _ in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)

            let result = try await repository.commitVocabulary(
                try Self.vocabularyCommit(deckID: deckID, origin: .manual),
                capture: nil
            )

            XCTAssertTrue(result.wasCreated)
            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts", arguments: []),
                    0
                )
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT origin, source_text FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(result.noteID)]
                )
                XCTAssertEqual(row?["origin"], "manual")
                XCTAssertNil(row?["source_text"] as String?)
            }
            let statusProcessing = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessing, .processing)
        }
    }

    func testSentenceBatchSecondItemFailureRollsBackAtomically() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBSentenceAnalysisCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let good = try Self.vocabularyCommit(deckID: deckID)
            let bad = GrammarContentCommit(
                noteID: UUID(),
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try GrammarFormData(
                    grammarForm: "〜てしまう",
                    meaningZH: "完成"
                ).validatedContent(),
                tags: [],
                // Wrong template for grammar — fails after the first note.
                card: NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                origin: .ai,
                sourceText: context.inputText
            )

            do {
                _ = try await repository.commitSentenceAnalysisCards(
                    SentenceAnalysisCardBatchCommit(
                        deckID: deckID,
                        items: [.vocabulary(good), .grammar(bad)]
                    ),
                    capture: capture
                )
                XCTFail("Expected invalidTemplateForKnowledgePoint")
            } catch ContentCardError.invalidTemplateForKnowledgePoint {}

            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes", arguments: []),
                    0
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts", arguments: []),
                    0
                )
            }
            let statusProcessing = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessing, .processing)
        }
    }

    func testSentenceBatchRetryReplaysStoredResult() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBSentenceAnalysisCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let batch = SentenceAnalysisCardBatchCommit(
                deckID: deckID,
                items: [
                    .vocabulary(try Self.vocabularyCommit(deckID: deckID)),
                    .grammar(try Self.grammarCommit(deckID: deckID, sourceText: context.inputText))
                ]
            )

            let first = try await repository.commitSentenceAnalysisCards(batch, capture: capture)
            let second = try await repository.commitSentenceAnalysisCards(batch, capture: capture)

            XCTAssertEqual(second.noteIDs, first.noteIDs)
            XCTAssertEqual(second.cardCount, first.cardCount)
            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes", arguments: []),
                    2
                )
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts", arguments: []),
                    1
                )
            }
            let statusProcessed = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(statusProcessed, .processed)
        }
    }
}

private extension GRDBCaptureCommitTests {
    static func capture(
        itemID: UUID,
        context: InboxProcessingContext,
        operationID: UUID = UUID()
    ) -> CaptureCommitContext {
        CaptureCommitContext(
            operationID: operationID,
            processingContextID: context.id,
            inboxItemID: itemID,
            expectedContentRevision: context.contentRevision,
            sourceText: context.inputText
        )
    }

    static func vocabularyCommit(
        deckID: UUID,
        origin: ContentOrigin = .ai,
        sourceText: String? = nil
    ) throws -> VocabularyContentCommit {
        try VocabularyContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: deckID,
            content: VocabularyFormData(headword: "食べる", meaningZH: "吃").validatedContent(),
            tags: [],
            cards: [
                NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
            ],
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            origin: origin,
            sourceText: sourceText
        )
    }

    static func grammarCommit(
        deckID: UUID,
        sourceText: String?
    ) throws -> GrammarContentCommit {
        try GrammarContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: deckID,
            content: GrammarFormData(
                grammarForm: "〜ばかり",
                meaningZH: "刚刚"
            ).validatedContent(),
            tags: [],
            card: NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation),
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            origin: .ai,
            sourceText: sourceText
        )
    }

    func insertDeck(id: UUID, in database: OboeDatabase) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P08', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
    }

    func withHarness(
        _ body: (
            OboeDatabase,
            GRDBInboxRepository,
            InboxService,
            InboxItem,
            InboxProcessingContext
        ) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GRDBCaptureCommitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        let repository = GRDBInboxRepository(database: database)
        let service = InboxService(repository: repository)
        let item = InboxItem(
            id: UUID(),
            text: "日本に行ったらパンを食べたい。",
            sourceType: .manual,
            status: .unprocessed,
            contentRevision: 1,
            sourceApp: nil,
            sourceURL: nil,
            imageReference: nil,
            createdAt: Date(timeIntervalSince1970: 1_768_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_768_000_000),
            processedAt: nil,
            archivedAt: nil,
            statusBeforeArchive: nil
        )
        try await repository.insertItem(item)
        let context = try await service.beginProcessing(
            itemID: item.id,
            mode: .vocabularyGeneration
        )
        try await body(database, repository, service, item, context)
    }
}
