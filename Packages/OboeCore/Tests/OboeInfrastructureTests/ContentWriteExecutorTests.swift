import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S03：共用内容写入器——批量原子性、operationID+digest 回放、
/// 来源插入后注入失败的整体回滚。
final class ContentWriteExecutorTests: XCTestCase {

    // MARK: - 批量原子性

    /// 批中第三条命令引用了不存在的牌组 → 整个 `apply` 回滚，
    /// 前两条的 Note/Card/membership 一行都不留（S03/S17：
    /// 批失败不得记成部分成功）。
    func testBatchFailureRollsBackEntireBatch() async throws {
        let location = try WriterTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let missingDeckID = UUID()
        try await database.pool.write { db in
            try insertWriterDeck(id: deckID, in: db)
        }

        let operations = [
            ContentWriteOperation(command: .vocabulary(Self.vocabularyCommit(deckID: deckID, headword: "食べる"))),
            ContentWriteOperation(command: .vocabulary(Self.vocabularyCommit(deckID: deckID, headword: "飲む"))),
            ContentWriteOperation(command: .vocabulary(Self.vocabularyCommit(deckID: missingDeckID, headword: "読む")))
        ]
        do {
            _ = try await repository.apply(operations)
            XCTFail("批内含坏命令必须抛错")
        } catch {
            XCTAssertEqual(error as? ContentCardError, .deckNotFound)
        }

        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_decks") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduler_profiles") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        // scheduler_profiles 也在同一事务里——回滚后不得残留。
        XCTAssertEqual(counts.3, 0)
    }

    func testBatchSuccessAppliesAllCommands() async throws {
        let location = try WriterTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try insertWriterDeck(id: deckID, in: db)
        }

        let results = try await repository.apply([
            ContentWriteOperation(command: .vocabulary(Self.vocabularyCommit(deckID: deckID, headword: "食べる"))),
            ContentWriteOperation(command: .grammar(Self.grammarCommit(deckID: deckID)))
        ])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].cardCount, 2)
        XCTAssertEqual(results[1].cardCount, 1)

        let noteCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes")
        }
        XCTAssertEqual(noteCount, 2)
    }

    // MARK: - operationID + digest 回放

    /// 同 operationID + 同内容 digest → 返回已存结果、不重复写；
    /// 同 operationID + 不同内容 → commitPayloadConflict。
    func testCaptureOperationReplayAndPayloadConflict() async throws {
        let location = try WriterTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let inbox = GRDBInboxRepository(database: database)
        let deckID = UUID()
        let itemID = UUID()
        let operationID = UUID()
        try await database.pool.write { db in
            try insertWriterDeck(id: deckID, in: db)
            try insertWriterInboxItem(id: itemID, in: db)
        }
        let capture = CaptureCommitContext(
            operationID: operationID,
            processingContextID: nil,
            inboxItemID: itemID,
            expectedContentRevision: 1,
            sourceText: "テキスト"
        )
        let commit = Self.vocabularyCommit(deckID: deckID, headword: "食べる")

        let first = try await repository.commitVocabulary(commit, capture: capture)
        XCTAssertEqual(first.noteID, commit.noteID)
        XCTAssertTrue(first.wasCreated)

        // 同 operationID + 同内容 → 回放，不新增行。
        let replay = try await repository.commitVocabulary(commit, capture: capture)
        XCTAssertEqual(replay.noteID, commit.noteID)
        XCTAssertFalse(replay.wasCreated)

        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        let itemStatus = try await inbox.fetchItem(id: itemID)?.status
        XCTAssertEqual(itemStatus, .processed)

        // 同 operationID + 不同内容 → 冲突拒绝。
        do {
            _ = try await repository.commitVocabulary(
                Self.vocabularyCommit(deckID: deckID, headword: "飲む"),
                capture: capture
            )
            XCTFail("payload 冲突必须拒绝")
        } catch {
            guard case InboxError.commitPayloadConflict = error else {
                return XCTFail("期望 commitPayloadConflict，实际 \(error)")
            }
        }
    }

    /// 来源插入后注入失败（capture revision 过期为最后一步）→
    /// Note/Card/成员/来源/ receipt 全部回滚，无半截提交。
    func testFailureAfterSourceInsertRollsBackNoteAndCards() async throws {
        let location = try WriterTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let itemID = UUID()
        try await database.pool.write { db in
            try insertWriterDeck(id: deckID, in: db)
            try insertWriterInboxItem(id: itemID, in: db)
        }
        // 真实 revision=1，capture 快照=2 → recordCaptureCommit 的
        // requireCurrentRevision 在来源写入之后抛错。
        let capture = CaptureCommitContext(
            operationID: UUID(),
            processingContextID: nil,
            inboxItemID: itemID,
            expectedContentRevision: 2,
            sourceText: "テキスト"
        )
        var commit = Self.vocabularyCommit(deckID: deckID, headword: "見る")
        commit = VocabularyContentCommit(
            noteID: commit.noteID,
            exampleID: commit.exampleID,
            draftID: commit.draftID,
            deckID: commit.deckID,
            content: commit.content,
            tags: commit.tags,
            cards: commit.cards,
            schedulerProfileID: commit.schedulerProfileID,
            createdAt: commit.createdAt,
            origin: commit.origin,
            sourceContext: SourceContext(
                id: UUID(),
                noteID: commit.noteID,
                sourceType: .reader,
                originalSentence: "彼は映画を見た。",
                surroundingText: nil,
                sourceTitle: "测试",
                sourceURL: nil,
                sourceApp: nil,
                imageReference: nil,
                dictionaryEntryID: nil,
                dictionaryVersion: nil,
                dictionarySenseKey: nil,
                selectedGlossLanguage: nil,
                isPrimary: true,
                createdAt: commit.createdAt
            )
        )
        do {
            _ = try await repository.commitVocabulary(commit, capture: capture)
            XCTFail("revision 冲突必须抛错")
        } catch {
            guard case InboxError.revisionConflict = error else {
                return XCTFail("期望 revisionConflict，实际 \(error)")
            }
        }
        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_decks") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_contexts") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_commit_receipts") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(counts.4, 0)
    }

    // MARK: - helpers

    private static func vocabularyCommit(
        deckID: UUID,
        headword: String
    ) -> VocabularyContentCommit {
        let noteID = UUID()
        return VocabularyContentCommit(
            noteID: noteID,
            exampleID: UUID(),
            draftID: nil,
            deckID: deckID,
            content: try! VocabularyFormData(
                headword: headword,
                meaningZH: "释义"
            ).validatedContent(),
            tags: [],
            cards: [
                NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
            ],
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_768_000_000)
        )
    }

    private static func grammarCommit(deckID: UUID) -> GrammarContentCommit {
        GrammarContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: deckID,
            content: try! GrammarFormData(
                grammarForm: "〜たことがある",
                meaningZH: "曾经做过"
            ).validatedContent(),
            tags: [],
            card: NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation),
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_768_000_000)
        )
    }
}

private struct WriterTestDatabaseLocation {
    let directoryURL: URL
    var databaseURL: URL { directoryURL.appendingPathComponent("db.sqlite") }

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func insertWriterDeck(id: UUID, in db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
            VALUES (?, '牌组', 0, 1, 1)
            """,
        arguments: [DatabaseValueCodec.encode(id)]
    )
}

private func insertWriterInboxItem(id: UUID, in db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO inbox_items(
                id, text, source_type, status, content_revision,
                created_at_ms, updated_at_ms
            ) VALUES (?, 'テキスト', 'share', 'processing', 1, 1, 1)
            """,
        arguments: [DatabaseValueCodec.encode(id)]
    )
}
