import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v15 commit 集成（设计 §6.2）：SourceContext 与 Note/Card/capture
/// receipt 同事务；同 operationID 重试不生成第二来源；来源内容不同
/// 的重试判 digest 冲突；事务回滚则来源随 Note 一起消失。
final class GRDBSourceContextCommitTests: XCTestCase {

    func testVocabularyCommitPersistsSourceContextInSameTransaction() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let sourceContext = Self.makeSourceContext(
                noteID: UUID(),
                imageReference: "img-src-1"
            )
            var commit = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)
            // 装配来源归属：提交方以新 Note 的 id 装配（service 层同款路径）。
            commit = try Self.vocabularyCommit(
                deckID: deckID,
                noteID: commit.noteID,
                sourceText: context.inputText,
                sourceContext: SourceContext(
                    id: sourceContext.id,
                    noteID: commit.noteID,
                    sourceType: sourceContext.sourceType,
                    originalSentence: sourceContext.originalSentence,
                    surroundingText: sourceContext.surroundingText,
                    sourceTitle: sourceContext.sourceTitle,
                    sourceURL: sourceContext.sourceURL,
                    sourceApp: sourceContext.sourceApp,
                    imageReference: sourceContext.imageReference,
                    dictionaryEntryID: sourceContext.dictionaryEntryID,
                    dictionaryVersion: sourceContext.dictionaryVersion,
                    dictionarySenseKey: sourceContext.dictionarySenseKey,
                    selectedGlossLanguage: sourceContext.selectedGlossLanguage,
                    isPrimary: sourceContext.isPrimary,
                    createdAt: sourceContext.createdAt
                )
            )

            let result = try await repository.commitVocabulary(commit, capture: capture)

            try await database.pool.read { db in
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT source_type, original_sentence, image_reference,
                               dictionary_entry_id, is_primary, note_id
                        FROM source_contexts
                        """
                )
                XCTAssertNotNil(row)
                XCTAssertEqual(row?["source_type"], "ocr")
                XCTAssertEqual(row?["original_sentence"], "今日はいい天気です")
                XCTAssertEqual(row?["image_reference"], "img-src-1")
                XCTAssertEqual(row?["dictionary_entry_id"], 1358280)
                XCTAssertEqual(row?["is_primary"], 1)
                XCTAssertEqual(
                    try row.map { try DatabaseValueCodec.decodeUUID($0["note_id"]) },
                    result.noteID
                )
            }
            let status = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(status, .processed)
        }
    }

    func testIdenticalRetryDoesNotDuplicateSourceContext() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            var commit = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)
            commit = try Self.vocabularyCommit(
                deckID: deckID,
                noteID: commit.noteID,
                sourceText: context.inputText,
                sourceContext: Self.makeSourceContext(noteID: commit.noteID)
            )

            _ = try await repository.commitVocabulary(commit, capture: capture)
            // 丢失响应重试：receipt 回放，source_contexts 不新增行。
            _ = try await repository.commitVocabulary(commit, capture: capture)

            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM source_contexts", arguments: []
                    ),
                    1
                )
            }
            let status = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(status, .processed)
        }
    }

    func testSameOperationIDWithDifferentSourceContextIsRejected() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            var commit = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)
            commit = try Self.vocabularyCommit(
                deckID: deckID,
                noteID: commit.noteID,
                sourceText: context.inputText,
                sourceContext: Self.makeSourceContext(
                    noteID: commit.noteID,
                    originalSentence: "来源句子 A"
                )
            )
            _ = try await repository.commitVocabulary(commit, capture: capture)

            let tampered = try Self.vocabularyCommit(
                deckID: deckID,
                sourceText: context.inputText,
                sourceContext: Self.makeSourceContext(
                    noteID: UUID(),
                    originalSentence: "来源句子 B"
                )
            )
            do {
                _ = try await repository.commitVocabulary(tampered, capture: capture)
                XCTFail("Expected commitPayloadConflict")
            } catch InboxError.commitPayloadConflict(let operationID) {
                XCTAssertEqual(operationID, capture.operationID)
            }
        }
    }

    func testFailedCommitRollsBackSourceContextWithNote() async throws {
        try await withHarness { database, inbox, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            let noteID = UUID()
            let commit = VocabularyContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(
                    headword: "壊れる",
                    meaningZH: "坏掉"
                ).validatedContent(),
                tags: [],
                // grammar 模板 → 中途失败（来源行在 Note 之后插入也被回滚）。
                cards: [NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation)],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_768_000_000),
                origin: .ai,
                sourceText: context.inputText,
                sourceContext: Self.makeSourceContext(noteID: noteID)
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
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM source_contexts", arguments: []
                    ),
                    0
                )
            }
            let status = try await inbox.fetchItem(id: item.id)?.status
            XCTAssertEqual(status, .processing)
        }
    }

    func testSentenceBatchWritesSourceContextForEachNote() async throws {
        try await withHarness { database, _, _, item, context in
            let repository = GRDBSentenceAnalysisCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)
            var vocab = try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText)
            var grammar = try Self.grammarCommit(deckID: deckID, sourceText: context.inputText)
            vocab = try Self.vocabularyCommit(
                deckID: deckID,
                noteID: vocab.noteID,
                sourceText: context.inputText,
                sourceContext: Self.makeSourceContext(noteID: vocab.noteID)
            )
            grammar = try Self.grammarCommit(
                deckID: deckID,
                noteID: grammar.noteID,
                sourceText: context.inputText,
                sourceContext: Self.makeSourceContext(noteID: grammar.noteID)
            )

            let result = try await repository.commitSentenceAnalysisCards(
                SentenceAnalysisCardBatchCommit(
                    deckID: deckID,
                    items: [.vocabulary(vocab), .grammar(grammar)]
                ),
                capture: capture
            )

            XCTAssertEqual(result.noteIDs.count, 2)
            try await database.pool.read { db in
                let noteIDs = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT note_id FROM source_contexts"
                )
                XCTAssertEqual(
                    Set(try noteIDs.map(DatabaseValueCodec.decodeUUID)),
                    Set(result.noteIDs)
                )
            }
        }
    }

    func testCommitWithoutSourceContextLeavesTableEmpty() async throws {
        try await withHarness { database, _, _, item, context in
            let repository = GRDBContentCardRepository(database: database)
            let deckID = UUID()
            try await insertDeck(id: deckID, in: database)
            let capture = Self.capture(itemID: item.id, context: context)

            _ = try await repository.commitVocabulary(
                try Self.vocabularyCommit(deckID: deckID, sourceText: context.inputText),
                capture: capture
            )

            try await database.pool.read { db in
                XCTAssertEqual(
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM source_contexts", arguments: []
                    ),
                    0
                )
            }
        }
    }
}

private extension GRDBSourceContextCommitTests {
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

    static func makeSourceContext(
        noteID: UUID,
        originalSentence: String? = "今日はいい天気です",
        imageReference: String? = nil
    ) -> SourceContext {
        SourceContext(
            id: UUID(),
            noteID: noteID,
            sourceType: .ocr,
            originalSentence: originalSentence,
            surroundingText: "上下文文本",
            sourceTitle: "截图",
            sourceURL: nil,
            sourceApp: "com.example.reader",
            imageReference: imageReference,
            dictionaryEntryID: 1358280,
            dictionaryVersion: "2026.09.24-1",
            dictionarySenseKey: "1358280-1",
            selectedGlossLanguage: "zho",
            isPrimary: true,
            createdAt: Date(timeIntervalSince1970: 1_768_000_000)
        )
    }

    static func vocabularyCommit(
        deckID: UUID,
        noteID: UUID = UUID(),
        sourceText: String? = nil,
        sourceContext: SourceContext? = nil
    ) throws -> VocabularyContentCommit {
        try VocabularyContentCommit(
            noteID: noteID,
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
            origin: .ai,
            sourceText: sourceText,
            sourceContext: sourceContext
        )
    }

    static func grammarCommit(
        deckID: UUID,
        noteID: UUID = UUID(),
        sourceText: String? = nil,
        sourceContext: SourceContext? = nil
    ) throws -> GrammarContentCommit {
        try GrammarContentCommit(
            noteID: noteID,
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
            sourceText: sourceText,
            sourceContext: sourceContext
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
            .appendingPathComponent(
                "GRDBSourceContextCommitTests-\(UUID().uuidString)",
                isDirectory: true
            )
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
