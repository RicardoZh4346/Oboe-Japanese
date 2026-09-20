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

        let result = try await repository.commitVocabulary(commit, capture: nil)
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
            ),
            capture: nil
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
        let progress = try await database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS card_count, state, due_at_ms, stability, difficulty, reps, state_version FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(secondCardID)]
            ).map { row in
                (
                    cardCount: row["card_count"] as Int?,
                    state: row["state"] as Int?,
                    dueAt: row["due_at_ms"] as Int64?,
                    stability: row["stability"] as Double?,
                    difficulty: row["difficulty"] as Double?,
                    reps: row["reps"] as Int?,
                    stateVersion: row["state_version"] as Int?
                )
            }
        }
        XCTAssertEqual(progress?.cardCount, 1)
        XCTAssertEqual(progress?.state, 2)
        XCTAssertEqual(progress?.dueAt, 999_000)
        XCTAssertEqual(progress?.stability, 8.5)
        XCTAssertEqual(progress?.difficulty, 4.2)
        XCTAssertEqual(progress?.reps, 7)
        XCTAssertEqual(progress?.stateVersion, 7)

        _ = try await GRDBVocabularyRepository(database: database).updateVocabulary(
            id: noteID,
            content: try VocabularyFormData(headword: "見る", meaningZH: "看；观看").validatedContent(),
            newExampleID: UUID(),
            at: Date(timeIntervalSince1970: 500)
        )
        let IDsAfterEdit = try await repository.fetchCardDirections(noteID: noteID).map(\.cardID)
        XCTAssertEqual(Set(IDsAfterEdit), [firstCardID, secondCardID])
    }

    /// T15/§8: one note can hold all three vocabulary directions. Each card
    /// owns a full independent scheduling row — writing one direction's FSRS
    /// state never touches its siblings.
    func testVocabularyCommitCreatesAllThreeDirectionsWithIndependentScheduling() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let noteID = UUID()
        let jaZhID = UUID()
        let zhJaID = UUID()
        let listeningID = UUID()
        try await database.pool.write { db in
            try insertContentCardDeck(id: deckID, in: db)
        }

        let result = try await repository.commitVocabulary(
            VocabularyContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(
                    headword: "聞く",
                    reading: "きく",
                    meaningZH: "听；问"
                ).validatedContent(),
                tags: [],
                cards: [
                    NewCardSeed(id: jaZhID, templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: zhJaID, templateKind: .vocabularyChineseToJapanese),
                    NewCardSeed(id: listeningID, templateKind: .vocabularyListening)
                ],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            capture: nil
        )

        XCTAssertEqual(result.cardCount, 3)
        let directions = try await repository.fetchCardDirections(noteID: noteID)
        XCTAssertEqual(
            Set(directions.map(\.templateKind)),
            [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese, .vocabularyListening]
        )
        XCTAssertTrue(directions.allSatisfy(\.isEnabled))

        // New direction cards start as state=New with zero progress.
        let listeningProbe = try await schedulingRow(cardID: listeningID, in: database)
        XCTAssertEqual(
            listeningProbe,
            SchedulingProbe(
                state: 0, dueAt: 100_000, stability: 0, difficulty: 0,
                reps: 0, lapses: 0, firstStudiedAt: nil, stateVersion: 0
            ),
            "a freshly created direction card starts as New"
        )

        // Writing one direction's FSRS fields leaves the siblings untouched.
        let jaZhBefore = try await schedulingRow(cardID: jaZhID, in: database)
        let zhJaBefore = try await schedulingRow(cardID: zhJaID, in: database)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cards SET state = 2, stability = 6.5, difficulty = 4.0,
                           reps = 5, lapses = 1, state_version = 3
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(listeningID)]
            )
        }
        let updatedStability = try await database.pool.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT stability FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(listeningID)]
            )
        }
        XCTAssertEqual(updatedStability, 6.5)
        let jaZhAfter = try await schedulingRow(cardID: jaZhID, in: database)
        let zhJaAfter = try await schedulingRow(cardID: zhJaID, in: database)
        XCTAssertEqual(
            jaZhAfter, jaZhBefore,
            "ja→zh scheduling is unaffected by the listening card's progress"
        )
        XCTAssertEqual(
            zhJaAfter, zhJaBefore,
            "zh→ja scheduling is unaffected by the listening card's progress"
        )
    }

    /// T15/§8: toggling the listening direction off and on again reuses the
    /// same Card.id and keeps its scheduling — the replacement's disable step
    /// must cover `vocabulary_listening`, not just the two original templates.
    func testListeningDirectionDisableAndReenableReusesCardIDAndProgress() async throws {
        let location = try ContentCardTestDatabaseLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBContentCardRepository(database: database)
        let deckID = UUID()
        let noteID = UUID()
        let jaZhID = UUID()
        let zhJaID = UUID()
        let listeningID = UUID()
        try await database.pool.write { db in
            try insertContentCardDeck(id: deckID, in: db)
        }
        _ = try await repository.commitVocabulary(
            VocabularyContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try VocabularyFormData(headword: "聞く", meaningZH: "听").validatedContent(),
                tags: [],
                cards: [
                    NewCardSeed(id: jaZhID, templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: zhJaID, templateKind: .vocabularyChineseToJapanese),
                    NewCardSeed(id: listeningID, templateKind: .vocabularyListening)
                ],
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            capture: nil
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cards SET state = 2, due_at_ms = 999000, stability = 8.5,
                           difficulty = 4.2, reps = 7, state_version = 7
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(listeningID)]
            )
        }
        let progressBefore = try await schedulingRow(cardID: listeningID, in: database)

        // Drop the listening direction — it must be the one that disables.
        let trimmed = try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: noteID,
                kind: .vocabulary,
                enabledCards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese)
                ],
                schedulerProfileID: UUID(),
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertEqual(
            trimmed.first { $0.templateKind == .vocabularyListening },
            CardDirectionState(
                cardID: listeningID,
                templateKind: .vocabularyListening,
                isEnabled: false
            ),
            "disabling must reach the listening card too"
        )
        XCTAssertTrue(
            trimmed.filter { $0.templateKind != .vocabularyListening }.allSatisfy(\.isEnabled)
        )

        // Re-enable: the ON CONFLICT clause revives the same row — same id,
        // same scheduling, no duplicate card.
        let restored = try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: noteID,
                kind: .vocabulary,
                enabledCards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese),
                    NewCardSeed(id: UUID(), templateKind: .vocabularyListening)
                ],
                schedulerProfileID: UUID(),
                updatedAt: Date(timeIntervalSince1970: 300)
            )
        )
        let listeningState = try XCTUnwrap(
            restored.first { $0.templateKind == .vocabularyListening }
        )
        XCTAssertEqual(listeningState.cardID, listeningID)
        XCTAssertTrue(listeningState.isEnabled)
        XCTAssertEqual(restored.count, 3)
        let restoredProbe = try await schedulingRow(cardID: listeningID, in: database)
        XCTAssertEqual(
            restoredProbe,
            progressBefore,
            "re-enable preserves the listening card's scheduling"
        )
    }

    /// T15: the repository whitelist is kind-scoped — a listening seed can
    /// never land on a grammar note, and the note's cards stay untouched.
    func testGrammarNoteRejectsVocabularyListeningTemplate() async throws {
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
        _ = try await repository.commitGrammar(
            GrammarContentCommit(
                noteID: noteID,
                exampleID: UUID(),
                draftID: nil,
                deckID: deckID,
                content: try GrammarFormData(
                    grammarForm: "～ながら",
                    meaningZH: "一边……一边……"
                ).validatedContent(),
                tags: [],
                card: NewCardSeed(id: cardID, templateKind: .grammarFormToExplanation),
                schedulerProfileID: UUID(),
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            capture: nil
        )

        do {
            _ = try await repository.replaceEnabledCardDirections(
                CardDirectionReplacement(
                    noteID: noteID,
                    kind: .grammar,
                    enabledCards: [
                        NewCardSeed(id: UUID(), templateKind: .vocabularyListening)
                    ],
                    schedulerProfileID: UUID(),
                    updatedAt: Date(timeIntervalSince1970: 200)
                )
            )
            XCTFail("a vocabulary template on a grammar note must be rejected")
        } catch {
            XCTAssertEqual(error as? ContentCardError, .invalidTemplateForKnowledgePoint)
        }
        let directions = try await repository.fetchCardDirections(noteID: noteID)
        XCTAssertEqual(
            directions,
            [CardDirectionState(cardID: cardID, templateKind: .grammarFormToExplanation, isEnabled: true)]
        )
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
            ),
            capture: nil
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
            ),
            capture: nil
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

    /// T04/§5.2: the single-card suspend command writes only `is_enabled`
    /// on the target card and applies the existing daily_tasks cancellation
    /// rule to that card alone — sibling direction, scheduling fields and
    /// history are all untouched.
    func testSetCardEnabledSuspendsOnlyTargetCardCancelsItsTasksAndPreservesProgress() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBContentCardRepository(database: fixture.database)
        let targetCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        let siblingCard = fixture.lapsedNote.cardID(.vocabularyChineseToJapanese)
        let suspendedAt = AdaptiveDatabaseFixture.baseDate.addingTimeInterval(60)

        try await fixture.database.pool.write { db in
            for cardID in [targetCard, siblingCard] {
                try db.execute(
                    sql: """
                        INSERT INTO daily_tasks(
                            study_day_id, card_id, category_at_admission, admitted_at_ms
                        ) VALUES (?, ?, 'review', ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(fixture.studyDayID),
                        DatabaseValueCodec.encode(cardID),
                        DatabaseValueCodec.encode(AdaptiveDatabaseFixture.baseDate)
                    ]
                )
            }
        }
        let before = try await schedulingRow(cardID: targetCard, in: fixture.database)

        let suspended = try await repository.setCardEnabled(
            cardID: targetCard,
            isEnabled: false,
            at: suspendedAt
        )
        XCTAssertEqual(
            suspended,
            CardDirectionState(
                cardID: targetCard,
                templateKind: .vocabularyJapaneseToChinese,
                isEnabled: false
            )
        )

        let after = try await schedulingRow(cardID: targetCard, in: fixture.database)
        XCTAssertEqual(after, before, "suspend must not rewrite scheduling progress")

        let taskStates = try await fixture.database.pool.read { db in
            (
                try Int64.fetchOne(
                    db,
                    sql: "SELECT cancelled_at_ms FROM daily_tasks WHERE card_id = ?",
                    arguments: [DatabaseValueCodec.encode(targetCard)]
                ),
                try Int64.fetchOne(
                    db,
                    sql: "SELECT cancelled_at_ms FROM daily_tasks WHERE card_id = ?",
                    arguments: [DatabaseValueCodec.encode(siblingCard)]
                ),
                try Bool.fetchOne(
                    db,
                    sql: "SELECT is_enabled FROM cards WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(siblingCard)]
                )
            )
        }
        XCTAssertEqual(taskStates.0, try DatabaseValueCodec.encode(suspendedAt))
        XCTAssertNil(taskStates.1, "the sibling direction's task stays pending")
        XCTAssertEqual(taskStates.2, true, "the sibling direction stays enabled")

        // Re-enable reuses the same Card.id and scheduling — no new row.
        let restored = try await repository.setCardEnabled(
            cardID: targetCard,
            isEnabled: true,
            at: suspendedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(restored.cardID, targetCard)
        XCTAssertTrue(restored.isEnabled)
        let restoredRow = try await schedulingRow(cardID: targetCard, in: fixture.database)
        XCTAssertEqual(restoredRow, before)
        let cancelledStill = try await fixture.database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT cancelled_at_ms FROM daily_tasks WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(targetCard)]
            )
        }
        XCTAssertNotNil(
            cancelledStill,
            "re-enabling never un-cancels today's task — PrepareStudyDay decides re-admission"
        )
        let logCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE card_key = ? AND undone_at_ms IS NULL",
                arguments: [DatabaseValueCodec.encode(targetCard)]
            )
        }
        XCTAssertEqual(logCount, 5, "suspend/resume keeps the card's review history")
    }

    func testSetCardEnabledRejectsMissingCard() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBContentCardRepository(database: fixture.database)

        do {
            _ = try await repository.setCardEnabled(
                cardID: UUID(),
                isEnabled: false,
                at: AdaptiveDatabaseFixture.baseDate
            )
            XCTFail("A missing card must be rejected")
        } catch {
            XCTAssertEqual(error as? ContentCardError, .cardNotFound)
        }
    }

    /// T04/§5.3: deleting a single Card removes only that row — the Note,
    /// the sibling direction and the orphaned `card_key` history all stay.
    /// Re-enabling the direction afterwards yields a NEW Card.id with no
    /// reattached history.
    func testDeleteCardKeepsNoteSiblingsAndOrphansHistory() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBContentCardRepository(database: fixture.database)
        let adaptiveRepository = GRDBAdaptiveRepository(database: fixture.database)
        let targetCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        let siblingCard = fixture.lapsedNote.cardID(.vocabularyChineseToJapanese)

        try await repository.deleteCard(cardID: targetCard)

        let persisted = try await fixture.database.pool.read { db in
            (
                noteCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(fixture.lapsedNote.noteID)]
                ) ?? -1,
                remainingCards: try String.fetchAll(
                    db,
                    sql: "SELECT id FROM cards WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(fixture.lapsedNote.noteID)]
                ),
                orphanLogCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM review_logs WHERE card_key = ? AND card_id IS NULL",
                    arguments: [DatabaseValueCodec.encode(targetCard)]
                ) ?? -1
            )
        }
        XCTAssertEqual(persisted.noteCount, 1, "deleting the card must not delete the note")
        XCTAssertEqual(
            persisted.remainingCards,
            [DatabaseValueCodec.encode(siblingCard)],
            "the sibling direction survives"
        )
        XCTAssertEqual(persisted.orphanLogCount, 5, "history stays as orphaned card_key rows")

        // Deleting the NOTE's last card still leaves the note behind.
        try await repository.deleteCard(cardID: siblingCard)
        let noteStillThere = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.lapsedNote.noteID)]
            ) ?? -1
        }
        XCTAssertEqual(noteStillThere, 1, "the last card's delete keeps the note")

        // Re-enabling the direction creates a fresh Card.id — old history
        // must not reattach to it.
        _ = try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: fixture.lapsedNote.noteID,
                kind: .vocabulary,
                enabledCards: [
                    NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese)
                ],
                schedulerProfileID: UUID(),
                updatedAt: AdaptiveDatabaseFixture.baseDate.addingTimeInterval(120)
            )
        )
        let directions = try await repository.fetchCardDirections(noteID: fixture.lapsedNote.noteID)
        let rebuilt = try XCTUnwrap(
            directions.first { $0.templateKind == .vocabularyJapaneseToChinese }
        )
        XCTAssertNotEqual(rebuilt.cardID, targetCard)
        let evidence = try await adaptiveRepository.fetchEvidence(cardID: rebuilt.cardID)
        XCTAssertEqual(evidence?.evidence.samples ?? [], [], "rebuilt card starts with clean history")
    }

    func testDeleteCardRejectsMissingCard() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }
        let repository = GRDBContentCardRepository(database: fixture.database)

        do {
            try await repository.deleteCard(cardID: UUID())
            XCTFail("A missing card must be rejected")
        } catch {
            XCTAssertEqual(error as? ContentCardError, .cardNotFound)
        }
    }

    /// T04: editing note content bumps `content_version` while every card
    /// and its history survive — the detail page re-reads both (§5.2).
    func testEditBumpsContentVersionPreservesCardsAndHistory() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }
        let cardID = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)

        let updated = try await GRDBVocabularyRepository(database: fixture.database).updateVocabulary(
            id: fixture.lapsedNote.noteID,
            content: try VocabularyFormData(
                headword: "難しい",
                reading: "むずかしい",
                meaningZH: "困难；艰难"
            ).validatedContent(),
            newExampleID: UUID(),
            at: AdaptiveDatabaseFixture.baseDate.addingTimeInterval(60)
        )

        XCTAssertEqual(updated?.contentVersion, 2)
        let persisted = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(fixture.lapsedNote.noteID)]
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM review_logs WHERE card_key = ? AND undone_at_ms IS NULL",
                    arguments: [DatabaseValueCodec.encode(cardID)]
                ) ?? -1
            )
        }
        XCTAssertEqual(persisted.0, 2, "edit keeps both direction cards")
        XCTAssertEqual(persisted.1, 5, "edit keeps the review history")

        // The adaptive detail now reports the bumped note version while the
        // samples keep the version they were recorded against (v1 badge).
        let evidence = try await GRDBAdaptiveRepository(database: fixture.database)
            .fetchEvidence(cardID: cardID)
        XCTAssertEqual(evidence?.noteContentVersion, 2)
        XCTAssertEqual(Set(evidence?.evidence.samples.map(\.contentVersion) ?? []), [1])
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
            _ = try await repository.commitVocabulary(commit, capture: nil)
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

/// Scheduling columns a suspend/resume must leave byte-identical.
private struct SchedulingProbe: Equatable {
    let state: Int
    let dueAt: Int64
    let stability: Double
    let difficulty: Double
    let reps: Int
    let lapses: Int
    let firstStudiedAt: Int64?
    let stateVersion: Int
}

private func schedulingRow(
    cardID: UUID,
    in database: OboeDatabase
) async throws -> SchedulingProbe? {
    try await database.pool.read { db in
        try Row.fetchOne(
            db,
            sql: """
                SELECT state, due_at_ms, stability, difficulty, reps, lapses,
                       first_studied_at_ms, state_version
                FROM cards WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(cardID)]
        ).map { row in
            SchedulingProbe(
                state: row["state"],
                dueAt: row["due_at_ms"],
                stability: row["stability"],
                difficulty: row["difficulty"],
                reps: row["reps"],
                lapses: row["lapses"],
                firstStudiedAt: row["first_studied_at_ms"],
                stateVersion: row["state_version"]
            )
        }
    }
}
