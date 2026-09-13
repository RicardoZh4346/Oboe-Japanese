import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBContentCardRepositoryTests: XCTestCase {
    func testVocabularyCommitAtomicallySavesContentTagsTwoCardsAndConsumesDraft() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let draftID = UUID()
        let noteID = UUID()
        let firstCardID = UUID()
        let secondCardID = UUID()

        try await database.pool.write { db in
            try insertContentCardDeck(id: deckID, in: db)
            try insertContentCardDraft(id: draftID, kind: "vocabulary", in: db)
        }
        let commit = VocabularyContentCommit(
            noteID: noteID,
            exampleID: UUID(),
            draftID: draftID,
            deckID: deckID,
            content: try VocabularyFormData(
                headword: "食べる",
                reading: "たべる",
                meaningZH: "吃",
                partOfSpeech: "一段动词",
                exampleJapanese: "パンを食べます。",
                exampleTranslationZH: "吃面包。"
            ).validatedContent(),
            tags: [KnowledgeTag(id: UUID(), name: "N5", normalizedName: "n5")],
            cards: [
                NewCardSeed(id: firstCardID, templateKind: .vocabularyJapaneseToChinese),
                NewCardSeed(id: secondCardID, templateKind: .vocabularyChineseToJapanese)
            ],
            schedulerProfileID: UUID(),
            createdAt: Date(timeIntervalSince1970: 100)
        )

        let result = try await repository.commitVocabulary(commit)
        XCTAssertEqual(result, ContentCommitResult(noteID: noteID, cardCount: 2))
        let directions = try await repository.fetchCardDirections(noteID: noteID)
        XCTAssertEqual(
            directions,
            [
                CardDirectionState(
                    cardID: firstCardID,
                    templateKind: .vocabularyJapaneseToChinese,
                    isEnabled: true
                ),
                CardDirectionState(
                    cardID: secondCardID,
                    templateKind: .vocabularyChineseToJapanese,
                    isEnabled: true
                )
            ]
        )

        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM examples") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_tags") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drafts") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scheduler_profiles") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(counts.3, 2)
        XCTAssertEqual(counts.4, 0)
        XCTAssertEqual(counts.5, 1)

        try database.close()
        let reopened = try OboeDatabase(path: location.databaseURL.path)
        let summaries = try await GRDBDeckRepository(database: reopened).fetchDeckSummaries()
        XCTAssertEqual(summaries.first?.noteCount, 1)
        XCTAssertEqual(summaries.first?.cardCount, 2)
    }

    func testDirectionDisableRestoreAndRepeatedSelectionPreserveCardIdentityAndProgress() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let noteID = UUID()
        let firstCardID = UUID()
        let secondCardID = UUID()
        try await database.pool.write { db in
            try insertContentCardDeck(id: deckID, in: db)
        }
        _ = try await repository.commitVocabulary(
            VocabularyContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(headword: "見る", meaningZH: "看").validatedContent(),
                tags: [],
                cards: [
                    NewCardSeed(id: firstCardID, templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: secondCardID, templateKind: .vocabularyChineseToJapanese)
                ],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET state = 2, due_at_ms = 999000, stability = 8.5, difficulty = 4.2, reps = 7, state_version = 7 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(secondCardID)]
            )
        }

        let disabled = try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: noteID,
                kind: .vocabulary,
                enabledCards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)
                ],
                schedulerProfileID: UUID(),
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertEqual(disabled.first { $0.cardID == secondCardID }?.isEnabled, false)

        let restored = try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: noteID,
                kind: .vocabulary,
                enabledCards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
                ],
                schedulerProfileID: UUID(),
                updatedAt: Date(timeIntervalSince1970: 300)
            )
        )
        XCTAssertEqual(Set(restored.map(\.cardID)), [firstCardID, secondCardID])
        XCTAssertTrue(restored.allSatisfy(\.isEnabled))

        _ = try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: noteID,
                kind: .vocabulary,
                enabledCards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
                ],
                schedulerProfileID: UUID(),
                updatedAt: Date(timeIntervalSince1970: 400)
            )
        )
        let progress = try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS card_count, state, due_at_ms, stability, difficulty, reps, state_version FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(secondCardID)]
            )
        }
        XCTAssertEqual(progress?["card_count"] as Int?, 1)
        XCTAssertEqual(progress?["state"] as Int?, 2)
        XCTAssertEqual(progress?["due_at_ms"] as Int64?, 999_000)
        XCTAssertEqual(progress?["stability"] as Double?, 8.5)
        XCTAssertEqual(progress?["difficulty"] as Double?, 4.2)
        XCTAssertEqual(progress?["reps"] as Int?, 7)
        XCTAssertEqual(progress?["state_version"] as Int?, 7)

        _ = try await GRDBVocabularyRepository(database: database).updateVocabulary(
            id: noteID,
            content: try VocabularyFormData(headword: "見る", meaningZH: "看；观看").validatedContent(),
            newExampleID: UUID(),
            at: Date(timeIntervalSince1970: 500)
        )
        let IDsAfterEdit = try await repository.fetchCardDirections(noteID: noteID).map(\.cardID)
        XCTAssertEqual(Set(IDsAfterEdit), [firstCardID, secondCardID])
    }

    func testGrammarCommitCreatesOnlyGrammarTemplate() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        try await database.pool.write { db in
            try insertContentCardDeck(id: deckID, in: db)
        }

        let result = try await repository.commitGrammar(
            GrammarContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try GrammarFormData(
                    grammarForm: "～ながら",
                    meaningZH: "一边……一边……",
                    usage: "两个动作同时进行"
                ).validatedContent(),
                tags: [],
                card: NewCardSeed(id: cardID, templateKind: .grammarFormToExplanation),
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertEqual(result.cardCount, 1)
        let directions = try await repository.fetchCardDirections(noteID: noteID)
        XCTAssertEqual(
            directions,
            [CardDirectionState(cardID: cardID, templateKind: .grammarFormToExplanation, isEnabled: true)]
        )
    }

    func testNewCardsUseCurrentlySelectedRetentionProfile() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        let cardID = UUID()
        try await database.pool.write { db in
            try insertContentCardDeck(id: deckID, in: db)
        }
        let settingsRepository = GRDBStudyDayPlanningRepository(database: database)
        _ = try await settingsRepository.loadOrCreateSettings(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        _ = try await settingsRepository.updateRetentionPreset(.light)

        _ = try await GRDBContentCardRepository(database: database).commitVocabulary(
            VocabularyContentCommit(
                noteID: UUID(),
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(
                    headword: "覚える",
                    meaningZH: "记住"
                ).validatedContent(),
                tags: [],
                cards: [
                    NewCardSeed(id: cardID, templateKind: .vocabularyJapaneseToChinese)
                ],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )

        let version = try await database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT scheduler_profiles.configuration_version
                    FROM cards
                    JOIN scheduler_profiles ON scheduler_profiles.id = cards.profile_id
                    WHERE cards.id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
        XCTAssertEqual(version, SchedulerProfile(preset: .light).configurationVersion)
    }

    func testMissingDeckRollsBackWholeCommitAndKeepsDraft() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let draftID = UUID()
        try await database.pool.write { db in
            try insertContentCardDraft(id: draftID, kind: "vocabulary", in: db)
        }
        let commit = VocabularyContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: draftID,
            deckID: UUID(),
            content: try VocabularyFormData(headword: "失敗", meaningZH: "失败").validatedContent(),
            tags: [KnowledgeTag(id: UUID(), name: "回滚", normalizedName: "回滚")],
            cards: [NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)],
            schedulerProfileID: UUID(),
            createdAt: Date()
        )

        do {
            _ = try await repository.commitVocabulary(commit)
            XCTFail("Expected the missing deck commit to fail")
        } catch {
            XCTAssertEqual(error as? ContentCardError, .deckNotFound)
        }
        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drafts") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 1)
    }
}

private struct ContentCardTestDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBContentCardTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func insertContentCardDeck(id: UUID, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'P08', 0, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id)]
    )
}

private func insertContentCardDraft(id: UUID, kind: String, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO drafts(id, draft_kind, payload_version, payload_json, updated_at_ms) VALUES (?, ?, 1, '{}', 1)",
        arguments: [DatabaseValueCodec.encode(id), kind]
    )
}
