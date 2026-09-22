import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T08: the atomic in-place repair commit — one transaction performs the
/// content-version-guarded note update, the primary-example/index sync and
/// the committed-draft receipt upsert. Conflicts and any failure roll back
/// everything, so only "untouched" or "fully committed" states exist.
final class GRDBAIRepairCommitRepositoryTests: XCTestCase {
    private var fixture: AdaptiveDatabaseFixture!

    override func setUp() async throws {
        fixture = try await AdaptiveDatabaseFixture.make()
    }

    override func tearDown() async throws {
        fixture.remove()
        fixture = nil
    }

    // MARK: - Happy path

    func testCommitUpdatesGuardedFieldsExampleIndexAndDraftAtomically() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let schedulingBefore = try await schedulingRow(cardID: cardID)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID
        )

        let content = ValidatedVocabularyContent(
            headword: "新規",
            reading: "しんき",
            meaningZH: "全新的",
            partOfSpeech: "形容词",
            jlpt: .n4,
            example: VocabularyExampleContent(
                japanese: "新規会員を募集する。",
                translationZH: "招募新会员"
            ),
            notes: "修订备注",
            pitchAccent: PitchAccent(rawValue: 2)
        )
        let envelope = committedEnvelope(
            noteID: noteID,
            cardID: cardID,
            expectedContentVersion: 1
        )
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        try await repository.commitInPlaceRepair(
            draftID: draftID,
            envelope: envelope,
            provenance: Self.provenance,
            content: .vocabulary(content),
            newExampleID: UUID(),
            updatedAt: Date()
        )

        // Note row: patched fields + version bump only.
        let note = try await noteRow(noteID: noteID)
        XCTAssertEqual(note["meaning_zh"] as? String, "全新的")
        XCTAssertEqual(note["part_of_speech"] as? String, "形容词")
        XCTAssertEqual(note["jlpt"] as? String, JLPTLevel.n4.rawValue)
        XCTAssertEqual(note["notes"] as? String, "修订备注")
        XCTAssertEqual(note.pitchAccent, 2)
        XCTAssertEqual(note.contentVersion, 2)

        // Example index: exactly one primary example with the new content.
        let examples = try await exampleRows(noteID: noteID)
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples.first?["japanese"] as? String, "新規会員を募集する。")
        XCTAssertEqual(examples.first?["translation_zh"] as? String, "招募新会员")

        // Search index trigger fired on the guarded update.
        let normalized = try await normalizedMeaning(noteID: noteID)
        XCTAssertEqual(normalized, SearchTextNormalizer.normalize("全新的"))

        // Draft row committed with the receipt inside the same transaction.
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let stored = try await drafts.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .committed)
        XCTAssertEqual(stored?.commitReceipt, envelope.commitReceipt)

        // Scheduling state is untouched — FSRS and review history never move.
        let schedulingAfter = try await schedulingRow(cardID: cardID)
        XCTAssertEqual(schedulingAfter, schedulingBefore)
    }

    func testCommitGrammarContentUpdatesUsageConnection() async throws {
        let noteID = UUID()
        try await fixture.insertNote(
            noteID,
            deckID: fixture.deckAID,
            kind: "grammar",
            headword: "〜によって",
            reading: nil,
            meaningZH: "由于……"
        )
        let cardID = try await fixture.addCard(
            noteID: noteID,
            template: .grammarFormToExplanation
        )
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID,
            kinds: [.grammarFormToExplanation]
        )

        let content = ValidatedGrammarContent(
            grammarForm: "〜によって",
            meaningZH: "根据……不同而不同",
            usage: "接在名词后",
            connection: "〜による",
            example: GrammarExampleContent(
                japanese: "人によって考え方が違う。",
                translationZH: "想法因人而异"
            ),
            jlpt: nil,
            notes: nil
        )
        let envelope = committedEnvelope(
            noteID: noteID,
            cardID: cardID,
            expectedContentVersion: 1
        )
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        try await repository.commitInPlaceRepair(
            draftID: draftID,
            envelope: envelope,
            provenance: Self.provenance,
            content: .grammar(content),
            newExampleID: UUID(),
            updatedAt: Date()
        )

        let note = try await noteRow(noteID: noteID)
        XCTAssertEqual(note["meaning_zh"] as? String, "根据……不同而不同")
        XCTAssertEqual(note["usage"] as? String, "接在名词后")
        XCTAssertEqual(note["connection"] as? String, "〜による")
        XCTAssertEqual(note.contentVersion, 2)
        let examples = try await exampleRows(noteID: noteID)
        XCTAssertEqual(examples.count, 1)
        XCTAssertEqual(examples.first?["japanese"] as? String, "人によって考え方が違う。")
    }

    // MARK: - Conflicts and rollback

    func testContentVersionMismatchAbortsEntireTransaction() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID
        )
        // 预览期间手工编辑令版本前进 —— 守卫更新命中零行。
        let envelope = committedEnvelope(
            noteID: noteID,
            cardID: cardID,
            expectedContentVersion: 99
        )
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)

        do {
            try await repository.commitInPlaceRepair(
                draftID: draftID,
                envelope: envelope,
                provenance: Self.provenance,
                content: .vocabulary(Self.vocabularyContent()),
                newExampleID: UUID(),
                updatedAt: Date()
            )
            XCTFail("expected contentConflict")
        } catch {
            XCTAssertEqual(error as? AIRepairCommitError, .contentConflict)
        }

        // 笔记与草稿都保持提交前状态 —— 事务整体回滚。
        let note = try await noteRow(noteID: noteID)
        XCTAssertEqual(note.contentVersion, 1)
        XCTAssertEqual(note["meaning_zh"] as? String, "新的")
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let stored = try await drafts.fetchDraft(id: draftID)
        XCTAssertEqual(stored?.phase, .committing)
        XCTAssertNil(stored?.commitReceipt)
    }

    func testReceiptWriteFailureRollsBackNoteUpdate() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID
        )
        // 让回执写入必然失败：删除 drafts 表。笔记更新先执行，随后草稿
        // upsert 抛错 —— 整个事务回滚，笔记保持原状。
        try await fixture.database.pool.write { db in
            try db.execute(sql: "DROP TABLE drafts")
        }

        let repository = GRDBAIRepairCommitRepository(database: fixture.database)
        do {
            try await repository.commitInPlaceRepair(
                draftID: draftID,
                envelope: committedEnvelope(
                    noteID: noteID,
                    cardID: cardID,
                    expectedContentVersion: 1
                ),
                provenance: Self.provenance,
                content: .vocabulary(Self.vocabularyContent()),
                newExampleID: UUID(),
                updatedAt: Date()
            )
            XCTFail("expected receipt write failure")
        } catch {
            XCTAssertFalse(error is AIRepairCommitError)
        }

        let note = try await noteRow(noteID: noteID)
        XCTAssertEqual(note.contentVersion, 1)
        XCTAssertEqual(note["meaning_zh"], "新的")
        let examples = try await exampleRows(noteID: noteID)
        XCTAssertTrue(examples.isEmpty)
    }

    func testClearedExampleAndUnpatchedFieldsPreserved() async throws {
        let noteID = fixture.freshNote.noteID
        let cardID = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let draftID = try await seedCommittingDraft(
            noteID: noteID,
            cardID: cardID
        )
        // example == nil → 清空例句；未列入补丁的字段原样保留。
        let content = ValidatedVocabularyContent(
            headword: "新規",
            reading: nil,
            meaningZH: "新的",
            partOfSpeech: nil,
            jlpt: nil,
            example: nil,
            notes: nil
        )
        let repository = GRDBAIRepairCommitRepository(database: fixture.database)
        try await repository.commitInPlaceRepair(
            draftID: draftID,
            envelope: committedEnvelope(
                noteID: noteID,
                cardID: cardID,
                expectedContentVersion: 1
            ),
            provenance: Self.provenance,
            content: .vocabulary(content),
            newExampleID: UUID(),
            updatedAt: Date()
        )
        let note = try await noteRow(noteID: noteID)
        XCTAssertNil(note["reading"])
        XCTAssertEqual(note.contentVersion, 2)
        let examples = try await exampleRows(noteID: noteID)
        XCTAssertTrue(examples.isEmpty)
    }

    // MARK: - Helpers

    private static var provenance: AIRepairDraftProvenance {
        AIRepairDraftProvenance(
            providerID: "custom",
            modelID: "fixture-model",
            promptVersion: "oboe-ai-repair-v2"
        )
    }

    private static func vocabularyContent() -> ValidatedVocabularyContent {
        ValidatedVocabularyContent(
            headword: "新規",
            reading: "しんき",
            meaningZH: "全新的",
            partOfSpeech: "形容词",
            jlpt: .n4,
            example: VocabularyExampleContent(
                japanese: "新規会員を募集する。",
                translationZH: "招募新会员"
            ),
            notes: "修订备注"
        )
    }

    private func committedEnvelope(
        noteID: UUID,
        cardID: UUID,
        expectedContentVersion: Int
    ) -> AIRepairDraftEnvelope {
        let operationID = UUID()
        return AIRepairDraftEnvelope(
            targetNoteID: noteID,
            targetCardID: cardID,
            expectedContentVersion: expectedContentVersion,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            operationID: operationID,
            phase: .committed,
            commitReceipt: AIRepairCommitReceipt(
                operationID: operationID,
                payloadHash: String(repeating: "a", count: 64),
                originalCardDisposition: .keep
            )
        )
    }

    /// The state the service leaves behind before attempting the commit:
    /// `.committing` with an operation id assigned.
    private func seedCommittingDraft(
        noteID: UUID,
        cardID: UUID,
        kinds: [CardTemplateKind] = [.vocabularyJapaneseToChinese]
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

    private struct NoteProbe: Equatable {
        var headword: String?
        var reading: String?
        var meaningZH: String?
        var partOfSpeech: String?
        var jlpt: String?
        var notes: String?
        var usage: String?
        var connection: String?
        var pitchAccent: Int?
        var contentVersion: Int?

        subscript(column: String) -> String? {
            switch column {
            case "headword": headword
            case "reading": reading
            case "meaning_zh": meaningZH
            case "part_of_speech": partOfSpeech
            case "jlpt": jlpt
            case "notes": notes
            case "usage": usage
            case "connection": connection
            default: nil
            }
        }
    }

    private func noteRow(noteID: UUID) async throws -> NoteProbe {
        try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT headword, reading, meaning_zh, part_of_speech,
                           jlpt, notes, usage, connection, pitch_accent,
                           content_version
                    FROM notes WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            guard let row else { return NoteProbe() }
            return NoteProbe(
                headword: row["headword"],
                reading: row["reading"],
                meaningZH: row["meaning_zh"],
                partOfSpeech: row["part_of_speech"],
                jlpt: row["jlpt"],
                notes: row["notes"],
                usage: row["usage"],
                connection: row["connection"],
                pitchAccent: row["pitch_accent"],
                contentVersion: row["content_version"]
            )
        }
    }

    private struct ExampleProbe: Equatable {
        var japanese: String?
        var translationZH: String?
        var sortOrder: Int?

        subscript(column: String) -> String? {
            switch column {
            case "japanese": japanese
            case "translation_zh": translationZH
            default: nil
            }
        }
    }

    private func exampleRows(noteID: UUID) async throws -> [ExampleProbe] {
        try await fixture.database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, japanese, translation_zh, sort_order
                    FROM examples WHERE note_id = ?
                    ORDER BY sort_order, id
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            ).map { row in
                ExampleProbe(
                    japanese: row["japanese"],
                    translationZH: row["translation_zh"],
                    sortOrder: row["sort_order"]
                )
            }
        }
    }

    private func normalizedMeaning(noteID: UUID) async throws -> String? {
        try await fixture.database.pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT normalized_meaning FROM search_documents WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            return row?["normalized_meaning"] as? String
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
}
