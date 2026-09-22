import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBContentLifecycleRepositoryTests: XCTestCase {
    func testDuplicateLookupRequiresSameTypeHeadwordAndVocabularyReading() async throws {
        let location = try LifecycleTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        let firstID = UUID()
        let duplicateID = UUID()
        let differentReadingID = UUID()
        let grammarID = UUID()

        try await database.pool.write { db in
            try insertLifecycleDeck(id: deckID, name: "重复", sortOrder: 0, in: db)
            try insertLifecycleNote(
                id: firstID,
                deckID: deckID,
                kind: "vocabulary",
                headword: "生",
                reading: "なま",
                in: db
            )
            try insertLifecycleNote(
                id: duplicateID,
                deckID: deckID,
                kind: "vocabulary",
                headword: "生",
                reading: "なま",
                in: db
            )
            try insertLifecycleNote(
                id: differentReadingID,
                deckID: deckID,
                kind: "vocabulary",
                headword: "生",
                reading: "せい",
                in: db
            )
            try insertLifecycleNote(
                id: grammarID,
                deckID: deckID,
                kind: "grammar",
                headword: "生",
                reading: nil,
                in: db
            )
        }

        let service = KnowledgePointService(repository: GRDBKnowledgePointRepository(database: database))
        let vocabularyDuplicates = try await service.fetchDuplicates(
            kind: .vocabulary,
            headword: "  生  ",
            reading: " なま ",
            excluding: firstID
        )
        XCTAssertEqual(vocabularyDuplicates.map(\.id), [duplicateID])

        let grammarDuplicates = try await service.fetchDuplicates(
            kind: .grammar,
            headword: " 生 ",
            reading: "不会参与匹配"
        )
        XCTAssertEqual(grammarDuplicates.map(\.id), [grammarID])
        let emptyHeadwordDuplicates = try await service.fetchDuplicates(
            kind: .vocabulary,
            headword: "",
            reading: "なま"
        )
        XCTAssertEqual(emptyHeadwordDuplicates, [])
    }

    func testMovingKnowledgePointKeepsCardsTasksAndImmutableReviewIdentity() async throws {
        let location = try LifecycleTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let sourceDeckID = UUID()
        let destinationDeckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let reviewLogID = UUID()

        try await database.pool.write { db in
            try insertLifecycleDeck(id: sourceDeckID, name: "来源", sortOrder: 0, in: db)
            try insertLifecycleDeck(id: destinationDeckID, name: "目标", sortOrder: 1, in: db)
            try insertLifecyclePrerequisites(profileID: profileID, studyDayID: studyDayID, in: db)
            try insertLifecycleNote(
                id: noteID,
                deckID: sourceDeckID,
                kind: "vocabulary",
                headword: "移す",
                reading: "うつす",
                in: db
            )
            try insertLifecycleCardAndHistory(
                cardID: cardID,
                noteID: noteID,
                deckIDAtReview: sourceDeckID,
                profileID: profileID,
                studyDayID: studyDayID,
                reviewLogID: reviewLogID,
                in: db
            )
        }

        let repository = GRDBKnowledgePointRepository(database: database)
        let result = try await repository.moveKnowledgePoint(
            noteID: noteID,
            to: destinationDeckID,
            at: Date(timeIntervalSince1970: 5)
        )
        XCTAssertEqual(result, .moved(cardCount: 1))

        let state = try await database.pool.read { db in
            let noteDeck: String? = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            let cardNote: String? = try String.fetchOne(
                db,
                sql: "SELECT note_id FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
            let taskCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_tasks") ?? 0
            let log = try Row.fetchOne(
                db,
                sql: "SELECT card_id, card_key, note_id, deck_id_at_review FROM review_logs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(reviewLogID)]
            ).map { (
                $0["card_id"] as String?, $0["card_key"] as String?,
                $0["note_id"] as String?, $0["deck_id_at_review"] as String?
            ) }
            return (noteDeck, cardNote, taskCount, log)
        }
        XCTAssertEqual(state.0, DatabaseValueCodec.encode(destinationDeckID))
        XCTAssertEqual(state.1, DatabaseValueCodec.encode(noteID))
        XCTAssertEqual(state.2, 1)
        XCTAssertEqual(state.3?.0, DatabaseValueCodec.encode(cardID))
        XCTAssertEqual(state.3?.1, DatabaseValueCodec.encode(cardID))
        XCTAssertEqual(state.3?.2, DatabaseValueCodec.encode(noteID))
        XCTAssertEqual(state.3?.3, DatabaseValueCodec.encode(sourceDeckID))
    }

    func testDeletingKnowledgePointCascadesBodyAndKeepsMinimalReviewLog() async throws {
        let location = try LifecycleTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()
        let reviewLogID = UUID()
        let exampleID = UUID()
        let tagID = UUID()

        try await database.pool.write { db in
            try insertLifecycleDeck(id: deckID, name: "删除正文", sortOrder: 0, in: db)
            try insertLifecyclePrerequisites(profileID: profileID, studyDayID: studyDayID, in: db)
            try insertLifecycleNote(
                id: noteID,
                deckID: deckID,
                kind: "vocabulary",
                headword: "消す",
                reading: "けす",
                in: db
            )
            try insertLifecycleCardAndHistory(
                cardID: cardID,
                noteID: noteID,
                deckIDAtReview: deckID,
                profileID: profileID,
                studyDayID: studyDayID,
                reviewLogID: reviewLogID,
                in: db
            )
            try db.execute(
                sql: "INSERT INTO examples(id, note_id, japanese, sort_order) VALUES (?, ?, '例文', 0)",
                arguments: [DatabaseValueCodec.encode(exampleID), DatabaseValueCodec.encode(noteID)]
            )
            try db.execute(
                sql: "INSERT INTO tags(id, name, normalized_name) VALUES (?, '删除', '删除')",
                arguments: [DatabaseValueCodec.encode(tagID)]
            )
            try db.execute(
                sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                arguments: [DatabaseValueCodec.encode(noteID), DatabaseValueCodec.encode(tagID)]
            )
        }

        let repository = GRDBKnowledgePointRepository(database: database)
        let impact = try await repository.fetchDeletionImpact(noteID: noteID)
        XCTAssertEqual(impact, KnowledgePointDeletionImpact(cardCount: 1, reviewLogCount: 1))
        let deletion = try await repository.deleteKnowledgePoint(noteID: noteID)
        XCTAssertEqual(
            deletion,
            .deleted(KnowledgePointDeletionImpact(cardCount: 1, reviewLogCount: 1))
        )

        let state = try await database.pool.read { db in
            let bodyCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM notes) +
                        (SELECT COUNT(*) FROM examples) +
                        (SELECT COUNT(*) FROM note_tags) +
                        (SELECT COUNT(*) FROM cards) +
                        (SELECT COUNT(*) FROM daily_tasks) +
                        (SELECT COUNT(*) FROM search_documents)
                    """
            ) ?? -1
            let tagCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") ?? 0
            let log = try Row.fetchOne(
                db,
                sql: "SELECT card_id, card_key, note_id, deck_id_at_review FROM review_logs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(reviewLogID)]
            ).map { (
                $0["card_id"] as String?, $0["card_key"] as String?,
                $0["note_id"] as String?, $0["deck_id_at_review"] as String?
            ) }
            return (bodyCount, tagCount, log)
        }
        XCTAssertEqual(state.0, 0)
        XCTAssertEqual(state.1, 1, "未关联标签保留，之后仍可复用")
        XCTAssertNil(state.2?.0)
        XCTAssertEqual(state.2?.1, DatabaseValueCodec.encode(cardID))
        XCTAssertEqual(state.2?.2, DatabaseValueCodec.encode(noteID))
        XCTAssertEqual(state.2?.3, DatabaseValueCodec.encode(deckID))
        let missingDeletion = try await repository.deleteKnowledgePoint(noteID: noteID)
        XCTAssertEqual(missingDeletion, .notFound)
    }

    func testNonEmptyDeckDeletionSupportsMoveOrExplicitContentDeletion() async throws {
        let location = try LifecycleTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let moveSourceID = UUID()
        let deleteSourceID = UUID()
        let destinationID = UUID()
        let moveNoteID = UUID()
        let deleteNoteID = UUID()
        let moveCardID = UUID()
        let deleteCardID = UUID()
        let profileID = UUID()
        let studyDayID = UUID()

        try await database.pool.write { db in
            try insertLifecycleDeck(id: moveSourceID, name: "移动后删除", sortOrder: 0, in: db)
            try insertLifecycleDeck(id: deleteSourceID, name: "连内容删除", sortOrder: 1, in: db)
            try insertLifecycleDeck(id: destinationID, name: "目标", sortOrder: 2, in: db)
            try insertLifecyclePrerequisites(profileID: profileID, studyDayID: studyDayID, in: db)
            try insertLifecycleNote(id: moveNoteID, deckID: moveSourceID, kind: "vocabulary", headword: "移動", reading: "いどう", in: db)
            try insertLifecycleNote(id: deleteNoteID, deckID: deleteSourceID, kind: "grammar", headword: "～ずに", reading: nil, in: db)
            try insertLifecycleCardAndHistory(
                cardID: moveCardID,
                noteID: moveNoteID,
                deckIDAtReview: moveSourceID,
                profileID: profileID,
                studyDayID: studyDayID,
                reviewLogID: UUID(),
                in: db
            )
            try insertLifecycleCardAndHistory(
                cardID: deleteCardID,
                noteID: deleteNoteID,
                deckIDAtReview: deleteSourceID,
                profileID: profileID,
                studyDayID: studyDayID,
                reviewLogID: UUID(),
                in: db
            )
        }

        let repository = GRDBDeckRepository(database: database)
        let matchingDestination = try await repository.deleteDeck(
            id: moveSourceID,
            strategy: .moveContents(to: moveSourceID),
            at: Date()
        )
        XCTAssertEqual(matchingDestination, .destinationMatchesSource)
        let invalidDestination = try await repository.deleteDeck(
            id: moveSourceID,
            strategy: .moveContents(to: UUID()),
            at: Date()
        )
        XCTAssertEqual(invalidDestination, .destinationNotFound)
        let sourceStillExists = try await repository.deckExists(id: moveSourceID)
        XCTAssertTrue(sourceStillExists)

        let moveDeletion = try await repository.deleteDeck(
            id: moveSourceID,
            strategy: .moveContents(to: destinationID),
            at: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(
            moveDeletion,
            .deleted(DeckDeletionImpact(noteCount: 1, cardCount: 1, reviewLogCount: 1))
        )
        let contentDeletion = try await repository.deleteDeck(
            id: deleteSourceID,
            strategy: .deleteContents,
            at: Date(timeIntervalSince1970: 21)
        )
        XCTAssertEqual(
            contentDeletion,
            .deleted(DeckDeletionImpact(noteCount: 1, cardCount: 1, reviewLogCount: 1))
        )

        let state = try await database.pool.read { db in
            let movedDeck: String? = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(moveNoteID)]
            )
            let movedCardCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(moveCardID)]
            ) ?? 0
            let deletedNoteCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deleteNoteID)]
            ) ?? 0
            let deletedCardCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deleteCardID)]
            ) ?? 0
            let deletedLog = try Row.fetchOne(
                db,
                sql: "SELECT card_id, card_key, note_id, deck_id_at_review FROM review_logs WHERE card_key = ?",
                arguments: [DatabaseValueCodec.encode(deleteCardID)]
            ).map { (
                $0["card_id"] as String?, $0["card_key"] as String?,
                $0["note_id"] as String?, $0["deck_id_at_review"] as String?
            ) }
            let movedHistoryDeck: String? = try String.fetchOne(
                db,
                sql: "SELECT deck_id_at_review FROM review_logs WHERE card_key = ?",
                arguments: [DatabaseValueCodec.encode(moveCardID)]
            )
            return (movedDeck, movedCardCount, deletedNoteCount, deletedCardCount, deletedLog, movedHistoryDeck)
        }
        XCTAssertEqual(state.0, DatabaseValueCodec.encode(destinationID))
        XCTAssertEqual(state.1, 1)
        XCTAssertEqual(state.2, 0)
        XCTAssertEqual(state.3, 0)
        XCTAssertNil(state.4?.0)
        XCTAssertEqual(state.4?.1, DatabaseValueCodec.encode(deleteCardID))
        XCTAssertEqual(state.4?.2, DatabaseValueCodec.encode(deleteNoteID))
        XCTAssertEqual(state.4?.3, DatabaseValueCodec.encode(deleteSourceID))
        XCTAssertEqual(state.5, DatabaseValueCodec.encode(moveSourceID))
    }
}

private struct LifecycleTestDatabaseLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBContentLifecycleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func insertLifecycleDeck(id: UUID, name: String, sortOrder: Int, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, ?, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id), name, sortOrder]
    )
}

private func insertLifecycleNote(
    id: UUID,
    deckID: UUID,
    kind: String,
    headword: String,
    reading: String?,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO notes(
                id, deck_id, kind, headword, reading, meaning_zh,
                origin, content_version, created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, '含义', 'manual', 1, 1, 1)
            """,
        arguments: [
            DatabaseValueCodec.encode(id),
            DatabaseValueCodec.encode(deckID),
            kind,
            headword,
            reading
        ]
    )
    try insertHomeMembershipIfSupported(noteID: id, deckID: deckID, in: db)
}

private func insertLifecyclePrerequisites(
    profileID: UUID,
    studyDayID: UUID,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO scheduler_profiles(
                id, configuration_version, algorithm_version, library_revision,
                parameters_json, desired_retention, max_interval_days, created_at_ms
            ) VALUES (?, ?, 'FSRS-6.0', 'test', '[]', 0.9, 36500, 1)
            """,
        arguments: [DatabaseValueCodec.encode(profileID), "lifecycle-\(profileID.uuidString)"]
    )
    try db.execute(
        sql: """
            INSERT INTO study_days(
                id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
            ) VALUES (?, '2026-09-10', 'Asia/Shanghai', 1, 2, 10)
            """,
        arguments: [DatabaseValueCodec.encode(studyDayID)]
    )
}

private func insertLifecycleCardAndHistory(
    cardID: UUID,
    noteID: UUID,
    deckIDAtReview: UUID,
    profileID: UUID,
    studyDayID: UUID,
    reviewLogID: UUID,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO cards(
                id, note_id, template_kind, is_enabled, state, due_at_ms,
                stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                learning_step, state_version, algorithm_version, profile_id
            ) VALUES (?, ?, ?, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'FSRS-6.0', ?)
            """,
        arguments: [
            DatabaseValueCodec.encode(cardID),
            DatabaseValueCodec.encode(noteID),
            "vocabulary_ja_zh",
            DatabaseValueCodec.encode(profileID)
        ]
    )
    try db.execute(
        sql: "INSERT INTO daily_tasks(study_day_id, card_id, category_at_admission, admitted_at_ms) VALUES (?, ?, 'new', 1)",
        arguments: [DatabaseValueCodec.encode(studyDayID), DatabaseValueCodec.encode(cardID)]
    )
    try db.execute(
        sql: """
            INSERT INTO review_logs(
                id, event_id, card_id, card_key, note_id, deck_id_at_review,
                reviewed_at_ms, study_day_id, was_first_study, rating,
                previous_state_json, next_state_json, duration_ms, content_version,
                profile_id, algorithm_version
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1, 3, '{}', '{}', 100, 1, ?, 'FSRS-6.0')
            """,
        arguments: [
            DatabaseValueCodec.encode(reviewLogID),
            DatabaseValueCodec.encode(UUID()),
            DatabaseValueCodec.encode(cardID),
            DatabaseValueCodec.encode(cardID),
            DatabaseValueCodec.encode(noteID),
            DatabaseValueCodec.encode(deckIDAtReview),
            DatabaseValueCodec.encode(studyDayID),
            DatabaseValueCodec.encode(profileID)
        ]
    )
}
