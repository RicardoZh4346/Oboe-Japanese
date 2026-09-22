import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T09: the atomic split commit — one `pool.write` performs the guards
/// (target existence, `content_version`, direction snapshot, deck), every
/// new Note/Example/Card insert, the original card's disposition and the
/// committed-draft receipt. Only "untouched" or "fully committed" states
/// may exist; new cards never inherit scheduling, history or tasks.
final class GRDBAIRepairSplitCommitTests: XCTestCase {
    private var fixture: AdaptiveDatabaseFixture!

    override func setUp() async throws {
        fixture = try await AdaptiveDatabaseFixture.make()
    }

    override func tearDown() async throws {
        fixture.remove()
        fixture = nil
    }

    // MARK: - Happy path

    func testSplitCommitCreatesAllNotesCardsAndReceiptAtomically() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let siblingID = fixture.freshNote.cardID(.vocabularyChineseToJapanese)
        let schedulingBefore = try await schedulingRow(cardID: cardID)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let commits = makeCommits(count: 2, deckID: fixture.deckAID)
        let envelope = committedSplitEnvelope(
            noteID: noteID,
            cardID: cardID,
            commits: commits,
            disposition: .keep,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        try await repository.commitSplitRepair(
            draftID: draftID,
            envelope: envelope,
            provenance: Self.provenance,
            commits: commits,
            originalCardDisposition: .keep,
            updatedAt: Date()
        )

        // 每个新 Note：完整内容、origin=ai、source_ref/source_text NULL、
        // 不收藏、content_version=1。
        for (index, commit) in commits.enumerated() {
            let row = try await noteRow(noteID: commit.noteID)
            XCTAssertEqual(row["headword"], "拆分\(index + 1)")
            XCTAssertEqual(row["pitch_accent"], "0")
            XCTAssertEqual(row["origin"], "ai")
            XCTAssertNil(row["source_ref"])
            XCTAssertNil(row["source_text"])
            XCTAssertEqual(row["is_favorite"], "0")
            XCTAssertEqual(row.contentVersion, 1)
            let examples = try await exampleRows(noteID: commit.noteID)
            XCTAssertEqual(examples.count, 1)
        }
        // 新卡全部 New 状态、独立调度、无历史无每日任务。
        for card in commits.flatMap(\.cards) {
            let cardRow = try await cardRow(cardID: card.id)
            XCTAssertEqual(cardRow["state"], "0")
            XCTAssertEqual(cardRow["reps"], "0")
            XCTAssertEqual(cardRow["lapses"], "0")
            XCTAssertEqual(cardRow["is_enabled"], "1")
            let logCount = try await reviewLogCount(cardID: card.id)
            let taskCount = try await dailyTaskCount(cardID: card.id)
            XCTAssertEqual(logCount, 0)
            XCTAssertEqual(taskCount, 0)
        }
        // 原卡与兄弟卡不受影响。
        let original = try await cardRow(cardID: cardID)
        XCTAssertEqual(original["is_enabled"], "1")
        let schedulingAfter = try await schedulingRow(cardID: cardID)
        XCTAssertEqual(schedulingAfter, schedulingBefore)
        let siblingRow = try await cardRow(cardID: siblingID)
        XCTAssertNotNil(siblingRow["id"])

        // 草稿已提交，回执携带新建 ID 与处置。
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let stored = try await drafts.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .committed)
        XCTAssertEqual(stored?.commitReceipt?.createdNoteIDs, commits.map(\.noteID))
        XCTAssertEqual(
            stored?.commitReceipt?.createdCardIDs,
            commits.flatMap { $0.cards.map(\.id) }
        )
        XCTAssertEqual(stored?.commitReceipt?.originalCardDisposition, .keep)
    }

    func testSplitCommitMixedVocabularyAndGrammarCandidates() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        var commits = makeCommits(count: 3, deckID: fixture.deckAID)
        commits.append(AIRepairSplitNoteCommit(
            noteID: UUID(),
            exampleID: UUID(),
            deckID: fixture.deckAID,
            content: .grammar(ValidatedGrammarContent(
                grammarForm: "〜に対して",
                meaningZH: "对于……",
                usage: nil,
                connection: nil,
                example: nil,
                jlpt: nil,
                notes: nil
            )),
            cards: [NewCardSeed(id: UUID(), templateKind: .grammarFormToExplanation)],
            schedulerProfileID: UUID(),
            createdAt: Date()
        ))
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)
        try await repository.commitSplitRepair(
            draftID: draftID,
            envelope: committedSplitEnvelope(
                noteID: noteID,
                cardID: cardID,
                commits: commits,
                disposition: .keep,
                kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
            ),
            provenance: Self.provenance,
            commits: commits,
            originalCardDisposition: .keep,
            updatedAt: Date()
        )
        // 4 个 Note（3 词汇 + 1 语法）全部落库。
        for commit in commits {
            let created = try await noteRow(noteID: commit.noteID)
            XCTAssertNotNil(created["id"])
        }
        let grammarProbe = try await noteRow(noteID: commits[3].noteID)
        XCTAssertEqual(grammarProbe["kind"], "grammar")
    }

    // MARK: - Original-card disposition

    func testPauseDispositionSuspendsOnlyTargetCardAndCancelsItsTasks() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let siblingID = fixture.freshNote.cardID(.vocabularyChineseToJapanese)
        let schedulingBefore = try await schedulingRow(cardID: cardID)
        // 目标卡与兄弟卡各挂一条待办每日任务。
        try await insertDailyTask(cardID: cardID)
        try await insertDailyTask(cardID: siblingID)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let commits = makeCommits(count: 2, deckID: fixture.deckAID)
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        try await repository.commitSplitRepair(
            draftID: draftID,
            envelope: committedSplitEnvelope(
                noteID: noteID,
                cardID: cardID,
                commits: commits,
                disposition: .pause,
                kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
            ),
            provenance: Self.provenance,
            commits: commits,
            originalCardDisposition: .pause,
            updatedAt: Date()
        )

        // 目标卡：仅 is_enabled 置 0，调度数值原样保留，任务取消。
        let paused = try await cardRow(cardID: cardID)
        XCTAssertEqual(paused["is_enabled"], "0")
        let schedulingAfter = try await schedulingRow(cardID: cardID)
        XCTAssertEqual(schedulingAfter, schedulingBefore)
        let cancelled = try await dailyTaskCancelledAt(cardID: cardID)
        XCTAssertNotNil(cancelled)
        // 兄弟卡：不受影响，任务保留。
        let sibling = try await cardRow(cardID: siblingID)
        XCTAssertEqual(sibling["is_enabled"], "1")
        let siblingCancelled = try await dailyTaskCancelledAt(cardID: siblingID)
        XCTAssertNil(siblingCancelled)
    }

    func testDeleteDispositionRemovesOnlyTargetCard() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let siblingID = fixture.freshNote.cardID(.vocabularyChineseToJapanese)
        // 目标卡挂一条复习日志 + 一条每日任务。
        let log = try await fixture.insertReviewLog(
            cardKey: cardID,
            cardID: cardID,
            noteID: noteID,
            deckID: fixture.deckAID,
            rating: .again,
            reviewedAt: AdaptiveDatabaseFixture.baseDate,
            previousSnapshot: fixture.snapshot(
                state: .review,
                dueAt: AdaptiveDatabaseFixture.baseDate,
                stability: 3,
                difficulty: 5,
                repetitions: 4,
                lapses: 1,
                stateVersion: 4
            ),
            nextSnapshot: fixture.snapshot(
                state: .review,
                dueAt: AdaptiveDatabaseFixture.baseDate,
                stability: 2,
                difficulty: 6,
                repetitions: 5,
                lapses: 2,
                stateVersion: 5
            )
        )
        try await insertDailyTask(cardID: cardID)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let commits = makeCommits(count: 2, deckID: fixture.deckAID)
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        try await repository.commitSplitRepair(
            draftID: draftID,
            envelope: committedSplitEnvelope(
                noteID: noteID,
                cardID: cardID,
                commits: commits,
                disposition: .delete,
                kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
            ),
            provenance: Self.provenance,
            commits: commits,
            originalCardDisposition: .delete,
            updatedAt: Date()
        )

        // 目标卡行删除；Note、兄弟卡、新卡全在。
        let deletedCard = try await cardRow(cardID: cardID)
        XCTAssertNil(deletedCard["id"])
        let survivingNote = try await noteRow(noteID: noteID)
        XCTAssertNotNil(survivingNote["id"])
        let siblingRow = try await cardRow(cardID: siblingID)
        XCTAssertNotNil(siblingRow["id"])
        // 日志按外键 SET NULL 保留 card_key；每日任务级联清理。
        let logRow = try await reviewLogRow(logID: log.id)
        XCTAssertNil(logRow["card_id"])
        XCTAssertEqual(
            logRow["card_key"]?.lowercased(),
            cardID.uuidString.lowercased()
        )
        let remainingTasks = try await dailyTaskCount(cardID: cardID)
        XCTAssertEqual(remainingTasks, 0)
        for commit in commits {
            let created = try await noteRow(noteID: commit.noteID)
            XCTAssertNotNil(created["id"])
        }
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let storedDraft = try await drafts.fetchDraft(id: draftID)
        XCTAssertEqual(storedDraft?.phase, .committed)
    }

    // MARK: - Rollback guarantees

    /// 第二个 Note 写入失败（撞上既有 Note ID）→ 整个事务回滚：
    /// 无新 Note/Card、原卡未动、草稿仍是 committing。
    func testSecondNoteFailureRollsBackEverything() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        var commits = makeCommits(count: 2, deckID: fixture.deckAID)
        commits[1].noteID = fixture.lapsedNote.noteID   // 撞上既有 ID → INSERT 失败
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        await assertThrows {
            try await repository.commitSplitRepair(
                draftID: draftID,
                envelope: committedSplitEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    commits: commits,
                    disposition: .pause,
                    kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
                ),
                provenance: Self.provenance,
                commits: commits,
                originalCardDisposition: .pause,
                updatedAt: Date()
            )
        }

        // 第一个 Note/Card 也被回滚。
        let rolledBackNote = try await noteRow(noteID: commits[0].noteID)
        XCTAssertNil(rolledBackNote["id"])
        for card in commits[0].cards {
            let rolledBackCard = try await cardRow(cardID: card.id)
            XCTAssertNil(rolledBackCard["id"])
        }
        // 原卡未暂停，草稿仍 committing（可重试）。
        let originalCard = try await cardRow(cardID: cardID)
        XCTAssertEqual(originalCard["is_enabled"], "1")
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let storedDraft = try await drafts.fetchDraft(id: draftID)
        XCTAssertEqual(storedDraft?.phase, .committing)
    }

    func testContentVersionMismatchRollsBackAllInserts() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let commits = makeCommits(count: 2, deckID: fixture.deckAID)
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        await assertThrows(
            verifying: { $0 as? AIRepairCommitError == .contentConflict }
        ) {
            try await repository.commitSplitRepair(
                draftID: draftID,
                envelope: committedSplitEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    commits: commits,
                    disposition: .keep,
                    kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese],
                    expectedContentVersion: 99
                ),
                provenance: Self.provenance,
                commits: commits,
                originalCardDisposition: .keep,
                updatedAt: Date()
            )
        }
        for commit in commits {
            let created = try await noteRow(noteID: commit.noteID)
            XCTAssertNil(created["id"])
        }
    }

    /// 方向快照失配（预览后用户改动了方向集合）→ 拒绝且零写入。
    func testDirectionSnapshotMismatchRollsBackAllInserts() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let commits = makeCommits(count: 2, deckID: fixture.deckAID)
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        await assertThrows(
            verifying: { $0 as? AIRepairCommitError == .contentConflict }
        ) {
            try await repository.commitSplitRepair(
                draftID: draftID,
                envelope: committedSplitEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    commits: commits,
                    disposition: .keep,
                    kinds: [.vocabularyJapaneseToChinese]   // 快照缺了兄弟方向
                ),
                provenance: Self.provenance,
                commits: commits,
                originalCardDisposition: .keep,
                updatedAt: Date()
            )
        }
        for commit in commits {
            let created = try await noteRow(noteID: commit.noteID)
            XCTAssertNil(created["id"])
        }
    }

    /// 回执写入失败（DROP drafts）→ 新 Note/Card、原卡处置一并回滚。
    func testReceiptWriteFailureRollsBackNotesAndDisposition() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = UUID()
        let commits = makeCommits(count: 2, deckID: fixture.deckAID)
        try await fixture.database.pool.write { db in
            try db.execute(sql: "DROP TABLE drafts")
        }
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        await assertThrows {
            try await repository.commitSplitRepair(
                draftID: draftID,
                envelope: committedSplitEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    commits: commits,
                    disposition: .delete,
                    kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
                ),
                provenance: Self.provenance,
                commits: commits,
                originalCardDisposition: .delete,
                updatedAt: Date()
            )
        }

        for commit in commits {
            let created = try await noteRow(noteID: commit.noteID)
            XCTAssertNil(created["id"])
        }
        // 删除处置同样回滚：原卡仍在且启用。
        let originalCard = try await cardRow(cardID: cardID)
        XCTAssertEqual(originalCard["is_enabled"], "1")
    }

    func testMissingDeckAbortsBeforeAnyInsert() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        var commits = makeCommits(count: 2, deckID: fixture.deckAID)
        commits[1].deckID = UUID()   // 不存在的牌组
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        await assertThrows(
            verifying: { $0 as? ContentCardError == .deckNotFound }
        ) {
            try await repository.commitSplitRepair(
                draftID: draftID,
                envelope: committedSplitEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    commits: commits,
                    disposition: .keep,
                    kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
                ),
                provenance: Self.provenance,
                commits: commits,
                originalCardDisposition: .keep,
                updatedAt: Date()
            )
        }
        // 第一个候选也被回滚。
        let firstNote = try await noteRow(noteID: commits[0].noteID)
        XCTAssertNil(firstNote["id"])
    }

    /// T07: 拆卡新 Note 携带多牌组成员——每个候选写全部 note_decks 行，
    /// notes.deck_id 指向 home。
    func testSplitCommitWritesAllMembershipDecks() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        let members: Set<UUID> = [fixture.deckAID, fixture.deckBID]
        var commits = makeCommits(count: 2, deckID: fixture.deckAID)
        for index in commits.indices { commits[index].deckIDs = members }
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        try await repository.commitSplitRepair(
            draftID: draftID,
            envelope: committedSplitEnvelope(
                noteID: noteID,
                cardID: cardID,
                commits: commits,
                disposition: .keep,
                kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
            ),
            provenance: Self.provenance,
            commits: commits,
            originalCardDisposition: .keep,
            updatedAt: Date()
        )

        for commit in commits {
            let memberRows = try await fixture.database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT deck_id FROM note_decks WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]
                ).compactMap { try? DatabaseValueCodec.decodeUUID($0["deck_id"]) }
            }
            XCTAssertEqual(Set(memberRows), members)
            let homeDeck: UUID? = try await fixture.database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT deck_id FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(commit.noteID)]
                ).flatMap { try? DatabaseValueCodec.decodeUUID($0) }
            }
            XCTAssertEqual(homeDeck, fixture.deckAID)
        }
    }

    /// T07: 成员牌组在提交前被删除——整单回滚，任何候选都不落库。
    func testSplitCommitMissingMemberDeckAbortsAtomically() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        var commits = makeCommits(count: 2, deckID: fixture.deckAID)
        commits[0].deckIDs = [fixture.deckAID, fixture.deckBID]
        commits[1].deckIDs = [fixture.deckAID, UUID()]  // 第二个候选成员缺失
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        await assertThrows(
            verifying: { $0 as? ContentCardError == .deckNotFound }
        ) {
            try await repository.commitSplitRepair(
                draftID: draftID,
                envelope: committedSplitEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    commits: commits,
                    disposition: .keep,
                    kinds: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
                ),
                provenance: Self.provenance,
                commits: commits,
                originalCardDisposition: .keep,
                updatedAt: Date()
            )
        }
        for commit in commits {
            let created = try await noteRow(noteID: commit.noteID)
            XCTAssertNil(created["id"])
        }
        let noteIDs = commits.map(\.noteID)
        let membershipCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_decks WHERE note_id IN (?, ?)",
                arguments: [
                    DatabaseValueCodec.encode(noteIDs[0]),
                    DatabaseValueCodec.encode(noteIDs[1])
                ]) ?? -1
        }
        XCTAssertEqual(membershipCount, 0)
    }

    // MARK: - Helpers

    private static var provenance: AIRepairDraftProvenance {
        AIRepairDraftProvenance(
            providerID: "custom",
            modelID: "fixture-model",
            promptVersion: "oboe-ai-repair-v2"
        )
    }

    /// 合法候选集合：count 个词汇候选，每候选两个词汇方向。
    private func makeCommits(
        count: Int,
        deckID: UUID
    ) -> [AIRepairSplitNoteCommit] {
        (0..<count).map { index in
            AIRepairSplitNoteCommit(
                noteID: UUID(),
                exampleID: UUID(),
                deckID: deckID,
                content: .vocabulary(ValidatedVocabularyContent(
                    headword: "拆分\(index + 1)",
                    reading: "よみ\(index + 1)",
                    meaningZH: "释义\(index + 1)",
                    partOfSpeech: nil,
                    jlpt: nil,
                    example: VocabularyExampleContent(
                        japanese: "例文\(index + 1)です。",
                        translationZH: nil
                    ),
                    notes: nil,
                    pitchAccent: PitchAccent(rawValue: 0)
                )),
                cards: [
                    NewCardSeed(
                        id: UUID(),
                        templateKind: .vocabularyJapaneseToChinese
                    ),
                    NewCardSeed(
                        id: UUID(),
                        templateKind: .vocabularyChineseToJapanese
                    )
                ],
                schedulerProfileID: UUID(),
                createdAt: Date()
            )
        }
    }

    private func committedSplitEnvelope(
        noteID: UUID,
        cardID: UUID,
        commits: [AIRepairSplitNoteCommit],
        disposition: AIRepairOriginalCardDisposition,
        kinds: [CardTemplateKind],
        expectedContentVersion: Int = 1
    ) -> AIRepairDraftEnvelope {
        let operationID = UUID()
        return AIRepairDraftEnvelope(
            targetNoteID: noteID,
            targetCardID: cardID,
            expectedContentVersion: expectedContentVersion,
            targetCardEnabled: true,
            affectedTemplateKinds: kinds,
            operationID: operationID,
            phase: .committed,
            commitReceipt: AIRepairCommitReceipt(
                operationID: operationID,
                payloadHash: String(repeating: "a", count: 64),
                createdNoteIDs: commits.map(\.noteID),
                createdCardIDs: commits.flatMap { $0.cards.map(\.id) },
                originalCardDisposition: disposition
            )
        )
    }

    /// The state the service leaves behind before attempting the commit:
    /// `.committing` with an operation id assigned.
    private func seedCommittingDraft(
        noteID: UUID,
        cardID: UUID,
        kinds: [CardTemplateKind]
    ) async throws -> UUID {
        let draftID = UUID()
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        try await drafts.saveDraft(
            id: draftID,
            envelope: AIRepairDraftEnvelope(
                targetNoteID: noteID,
                targetCardID: cardID,
                expectedContentVersion: 1,
                targetCardEnabled: true,
                affectedTemplateKinds: kinds,
                operationID: UUID(),
                phase: .committing
            ),
            provenance: Self.provenance,
            updatedAt: Date()
        )
        return draftID
    }

    private func insertDailyTask(cardID: UUID) async throws {
        let studyDayID = fixture.studyDayID
        let pool = fixture.database.pool
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO daily_tasks(
                        study_day_id, card_id, category_at_admission,
                        admitted_at_ms, cancelled_at_ms
                    ) VALUES (?, ?, 'review', ?, NULL)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    DatabaseValueCodec.encode(cardID),
                    try DatabaseValueCodec.encode(AdaptiveDatabaseFixture.baseDate)
                ]
            )
        }
    }

    private func noteRow(noteID: UUID) async throws -> Probe {
        try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, kind, headword, origin, source_ref, source_text,
                           is_favorite, pitch_accent, content_version
                    FROM notes WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            guard let row else { return Probe() }
            return Probe(values: [
                "id": row["id"] as? String,
                "kind": row["kind"] as? String,
                "headword": row["headword"] as? String,
                "origin": row["origin"] as? String,
                "source_ref": row["source_ref"] as? String,
                "source_text": row["source_text"] as? String,
                "is_favorite": (row["is_favorite"] as? Int64).map(String.init),
                "pitch_accent": (row["pitch_accent"] as? Int64).map(String.init),
                "content_version": (row["content_version"] as? Int64).map(String.init)
            ], contentVersion: row["content_version"])
        }
    }

    private func cardRow(cardID: UUID) async throws -> Probe {
        try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, is_enabled, state, reps, lapses, stability
                    FROM cards WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
            guard let row else { return Probe() }
            return Probe(values: [
                "id": row["id"] as? String,
                "is_enabled": (row["is_enabled"] as? Int64).map(String.init),
                "state": (row["state"] as? Int64).map(String.init),
                "reps": (row["reps"] as? Int64).map(String.init),
                "lapses": (row["lapses"] as? Int64).map(String.init)
            ])
        }
    }

    /// Uniform row probe: `values` holds column → stringified value so both
    /// String and Int columns share one subscript; `contentVersion` keeps
    /// its Int form for version assertions.
    private struct Probe {
        var values: [String: String?] = [:]
        var contentVersion: Int? = nil

        subscript(column: String) -> String? {
            values[column] ?? nil
        }
    }

    private func exampleRows(noteID: UUID) async throws -> [String] {
        try await fixture.database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT japanese FROM examples WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
    }

    private func reviewLogRow(logID: UUID) async throws -> Probe {
        try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT card_id, card_key FROM review_logs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(logID)]
            )
            guard let row else { return Probe() }
            return Probe(values: [
                "card_id": row["card_id"] as? String,
                "card_key": row["card_key"] as? String
            ])
        }
    }

    private func reviewLogCount(cardID: UUID) async throws -> Int {
        try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? 0
        }
    }

    private func dailyTaskCount(cardID: UUID) async throws -> Int {
        try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM daily_tasks WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? 0
        }
    }

    private func dailyTaskCancelledAt(cardID: UUID) async throws -> Int64? {
        try await fixture.database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT cancelled_at_ms FROM daily_tasks WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    private func schedulingRow(cardID: UUID) async throws -> [Int64?] {
        try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT stability, difficulty, reps, lapses,
                           scheduled_days, elapsed_days, due_at_ms, state_version
                    FROM cards WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
            guard let row else { return [] }
            return [
                row["stability"] as? Int64,
                row["difficulty"] as? Int64,
                row["reps"] as? Int64,
                row["lapses"] as? Int64,
                row["scheduled_days"] as? Int64,
                row["elapsed_days"] as? Int64,
                row["due_at_ms"] as? Int64,
                row["state_version"] as? Int64
            ]
        }
    }

    private func assertThrows(
        verifying check: (Error) -> Bool = { _ in true },
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            XCTAssertTrue(check(error), "unexpected error: \(error)", file: file, line: line)
        }
    }
}
