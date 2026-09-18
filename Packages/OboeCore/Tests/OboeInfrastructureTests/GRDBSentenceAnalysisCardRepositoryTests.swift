import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBSentenceAnalysisCardRepositoryTests: XCTestCase {
    func testSelectedVocabularyAndGrammarSaveAsOneAIBatch() async throws {
        let location = try SentenceCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        try await database.pool.write { db in try insertSentenceCardDeck(id: deckID, in: db) }
        let repository = GRDBSentenceAnalysisCardRepository(database: database)
        let service = SentenceAnalysisCardCreationService(repository: repository)
        let result = makeInfrastructureSentenceAnalysisResult()
        let drafts = try service.makeDrafts(
            from: result,
            selectedItemIDs: Set(result.items.map(\.id))
        )

        let saved = try await service.commit(deckID: deckID, drafts: drafts)

        XCTAssertEqual(saved.noteIDs.count, 2)
        XCTAssertEqual(saved.cardCount, 2)
        let rows = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT kind, headword, origin FROM notes ORDER BY kind DESC"
            ).map { (
                $0["kind"] as String?, $0["headword"] as String?, $0["origin"] as String?
            ) }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.1), ["行く", "～たことがある"])
        XCTAssertTrue(rows.allSatisfy { $0.2 == "ai" })
        let exampleCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM examples") ?? -1
        }
        XCTAssertEqual(exampleCount, 2)
    }

    func testSecondInsertFailureRollsBackTheEntireBatch() async throws {
        let location = try SentenceCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        try await database.pool.write { db in try insertSentenceCardDeck(id: deckID, in: db) }
        let duplicateNoteID = UUID()
        let first = try makeVocabularyCommit(noteID: duplicateNoteID, deckID: deckID)
        let second = try makeGrammarCommit(noteID: duplicateNoteID, deckID: deckID)

        do {
            _ = try await GRDBSentenceAnalysisCardRepository(database: database)
                .commitSentenceAnalysisCards(
                    SentenceAnalysisCardBatchCommit(
                        deckID: deckID,
                        items: [.vocabulary(first), .grammar(second)]
                    ),
                    capture: nil
                )
            XCTFail("Expected the duplicate note ID to fail")
        } catch {
            // SQLite uniqueness is the deliberate second-item failure.
        }

        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM examples") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduler_profiles") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 0)
    }
}

private struct SentenceCardTestDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBSentenceCardTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func insertSentenceCardDeck(id: UUID, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P20', 0, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id)]
    )
}

private func makeInfrastructureSentenceAnalysisResult() -> SentenceAnalysisResult {
    SentenceAnalysisResult(
        promptVersion: SentenceAnalysisPromptV1.promptVersion,
        schemaVersion: 1,
        sentence: "日本に行ったことがありますか。",
        translationZH: "你去过日本吗？",
        explanationZH: "询问经历。",
        items: [
            SentenceAnalysisItem(
                id: UUID(), kind: .vocabulary, surface: "行っ", canonicalForm: "行く", reading: "いく",
                meaningZH: "去", roleZH: "动词", spans: [], suggestedCard: nil
            ),
            SentenceAnalysisItem(
                id: UUID(), kind: .grammar, surface: "たことがあります", canonicalForm: "～たことがある",
                reading: "", meaningZH: "曾经……过", roleZH: "表示经历", spans: [], suggestedCard: nil
            )
        ],
        warnings: []
    )
}

private func makeVocabularyCommit(noteID: UUID, deckID: UUID) throws -> VocabularyContentCommit {
    VocabularyContentCommit(
        noteID: noteID,
        exampleID: UUID(),
        draftID: nil,
        deckID: deckID,
        content: try VocabularyFormData(headword: "行く", meaningZH: "去").validatedContent(),
        tags: [],
        cards: [NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)],
        schedulerProfileID: UUID(),
        createdAt: Date(timeIntervalSince1970: 100)
    )
}

private func makeGrammarCommit(noteID: UUID, deckID: UUID) throws -> GrammarContentCommit {
    GrammarContentCommit(
        noteID: noteID,
        exampleID: UUID(),
        draftID: nil,
        deckID: deckID,
        content: try GrammarFormData(grammarForm: "～たことがある", meaningZH: "曾经……过").validatedContent(),
        tags: [],
        card: NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation),
        schedulerProfileID: UUID(),
        createdAt: Date(timeIntervalSince1970: 100)
    )
}
