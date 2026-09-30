import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S13：Apply 验收——逐 unit 事务、receipt 幂等三层、
/// 不盲写（重读当前数据）、不复活已删内容、Job 结算。
///
/// 覆盖矩阵：
/// - reuse：链接/membership/来源补记；Note 已删 → 跳过；
///   绑定他 unit → 失败；replay 零增量。
/// - create：Note/方向卡/牌组/来源/unit link 全落；既有 primary
///   降级复用；删除证据 → skipped（显式重建另键）；replay 收敛。
/// - tooEasy：flag+事件、幂等、FSRS/复习日志零副作用。
/// - skip/pending：只写 receipt 锚。
/// - Job 结算：completed / partiallyCompleted / 幂等重入。
final class AIStudyApplyServiceTests: XCTestCase {

    // MARK: - reuse

    /// 既有 Note 确认复用：unit link 落 `aiPipeline`、membership
    /// 追加、来源补记、receipt+applied_receipt_id 同事务。
    func testReuseLinksNoteMembershipAndReceipt() async throws {
        let env = try await makeEnvironment()
        let (unitKey, unit) = try await env.makeDictionaryUnit(
            lemma: "食べる", entryID: 100)
        let noteID = try await env.insertBareVocabularyNote(
            headword: "食べる")
        let selection = env.selection(
            unitKey: unitKey, decision: .reuse,
            action: .reuseNote(noteID: noteID,
                               addMembershipTo: env.deckID))
        try await env.insertSelection(selection)

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)

        XCTAssertEqual(report.finalStatus, .completed)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .reusedNote)
        XCTAssertEqual(outcome.unitID, unit.id)
        XCTAssertEqual(outcome.noteID, noteID)
        XCTAssertEqual(outcome.linkRole, "primary")
        XCTAssertTrue(outcome.membershipAdded)
        XCTAssertNotNil(outcome.receiptOperationID)

        try await env.pool.read { db in
            let link = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT role, origin FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            let linkRole: String? = link["role"]
            let linkOrigin: String? = link["origin"]
            XCTAssertEqual(linkRole, "primary")
            XCTAssertEqual(linkOrigin, "aiPipeline")
            XCTAssertTrue(try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM note_decks
                        WHERE note_id = ? AND deck_id = ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(env.deckID),
                ]) ?? false)
            XCTAssertNotNil(try Row.fetchOne(
                db,
                sql: """
                    SELECT id FROM learning_unit_events
                    WHERE unit_id = ? AND kind = 'noteLinked'
                    """,
                arguments: [DatabaseValueCodec.encode(unit.id)]))
            // 来源按 dedup 键落一条（is_primary：本 Note 首个来源）。
            let source = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT is_primary, study_dedup_key, source_type
                    FROM source_contexts WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            let isPrimary: Int? = source["is_primary"]
            let sourceType: String? = source["source_type"]
            let dedupKey: String? = source["study_dedup_key"]
            XCTAssertEqual(isPrimary, 1)
            XCTAssertEqual(sourceType, "reader")
            XCTAssertNotNil(dedupKey)
            XCTAssertNotNil(try Row.fetchOne(
                db,
                sql: """
                    SELECT applied_receipt_id FROM ai_study_selections
                    WHERE job_id = ? AND unit_key = ?
                          AND applied_receipt_id IS NOT NULL
                    """,
                arguments: [
                    DatabaseValueCodec.encode(env.job.id), unitKey]))
        }
    }

    /// 复用重放：再次 apply 整 Job——receipt 命中，链接/成员/来源/
    /// 事件零增量（completed 幂等报告 + 行数不变）。
    func testReuseWholeJobReplayIsNoOp() async throws {
        let env = try await makeEnvironment()
        let (unitKey, _) = try await env.makeDictionaryUnit(
            lemma: "猫", entryID: 101)
        let noteID = try await env.insertBareVocabularyNote(headword: "猫")
        try await env.insertSelection(env.selection(
            unitKey: unitKey, decision: .reuse,
            action: .reuseNote(noteID: noteID,
                               addMembershipTo: env.deckID)))
        _ = try await env.service().applyConfirmedJob(jobID: env.job.id)
        let countsBefore = try await env.counts()

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.entryStatus, .completed)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(report.units.map(\.kind), [.alreadyApplied])
        let countsAfter = try await env.counts()
        XCTAssertEqual(countsAfter, countsBefore)
    }

    /// 预览后用户删了目标 Note——§11.5 fallback：不复制直接跳过，
    /// receipt 锚照落，Job completed。
    func testReuseNoteDeletedAfterPreviewSettlesSkipped() async throws {
        let env = try await makeEnvironment()
        let (unitKey, _) = try await env.makeDictionaryUnit(
            lemma: "走る", entryID: 102)
        let noteID = UUID() // 预览时存在、应用前已被用户删除。
        try await env.insertSelection(env.selection(
            unitKey: unitKey, decision: .reuse,
            action: .reuseNote(noteID: noteID,
                               addMembershipTo: env.deckID)))

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .skippedNoteMissing)
        XCTAssertEqual(outcome.errorCode, "noteMissing")
        XCTAssertNotNil(outcome.receiptOperationID)
        try await env.pool.read { db in
            // Note 不再——零复制零链接；receipt 锚照落（选择已消费）。
            XCTAssertEqual(try env.count(db, table: "notes"), 0)
            XCTAssertEqual(
                try env.count(db, table: "learning_unit_note_links"), 0)
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 1)
        }
    }

    /// Note 已绑定其他 unit → 不抢不合并：unit 失败、Job
    /// partiallyCompleted、receipt 不落（可修复后重跑）。
    func testReuseNoteBoundElsewhereFails() async throws {
        let env = try await makeEnvironment()
        let (unitA, _) = try await env.makeDictionaryUnit(
            lemma: "読む", entryID: 103)
        // 另一 unit + 其 Note（commit 绑定路径直接落链）。
        let otherBinding = try Self.makeBinding(
            entryID: 999, senseID: 1, lemma: "別")
        let noteID = UUID()
        try await env.commitNoteWithBinding(
            noteID: noteID, headword: "別", binding: otherBinding)
        try await env.insertSelection(env.selection(
            unitKey: unitA, decision: .reuse,
            action: .reuseNote(noteID: noteID,
                               addMembershipTo: env.deckID)))

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .partiallyCompleted)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.errorCode, "noteBoundElsewhere")
        try await env.pool.read { db in
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 0)
            XCTAssertNil(try String.fetchOne(
                db,
                sql: """
                    SELECT applied_receipt_id FROM ai_study_selections
                    WHERE job_id = ? AND unit_key = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(env.job.id), unitA]))
        }
    }

    /// unit 已有 primary、复用目标为另一未绑 Note → 落
    /// legacy_secondary（primary 唯一不撞）。
    func testReuseAsSecondaryWhenPrimaryExists() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 104, senseID: 1, lemma: "書く")
        let primaryNote = UUID()
        try await env.commitNoteWithBinding(
            noteID: primaryNote, headword: "書く", binding: binding)
        let secondaryNote = try await env.insertBareVocabularyNote(
            headword: "書く")
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .reuse,
            action: .reuseNote(noteID: secondaryNote,
                               addMembershipTo: env.deckID)))

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .reusedNote)
        XCTAssertEqual(outcome.linkRole, "legacy_secondary")
        try await env.pool.read { db in
            let roles = try String.fetchAll(
                db,
                sql: """
                    SELECT role FROM learning_unit_note_links
                    ORDER BY created_at_ms, note_id
                    """)
            XCTAssertEqual(Set(roles), ["primary", "legacy_secondary"])
            XCTAssertTrue(try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM note_decks
                        WHERE note_id = ? AND deck_id = ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(secondaryNote),
                    DatabaseValueCodec.encode(env.deckID),
                ]) ?? false)
        }
    }

    // MARK: - create

    /// 新建全路径：unit resolve-or-create + Note + 双方向卡 +
    /// 牌组 membership + 来源（reader_location/原句）+ unit link +
    /// resolution 回填 + 块推进 applied + Job completed。
    func testCreateMaterializesEverything() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 200, senseID: 7, lemma: "食べる")
        let selection = env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [
                .japaneseToChinese, .chineseToJapanese]))
        try await env.insertSelection(selection)
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "食べる",
                reading: "たべる", meaningZH: "吃",
                glossLanguage: "zho", partOfSpeech: "v1")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .createdNote)
        XCTAssertEqual(outcome.cardCount, 2)
        XCTAssertTrue(outcome.membershipAdded)
        let noteID = try XCTUnwrap(outcome.noteID)
        let unitID = try XCTUnwrap(outcome.unitID)

        try await env.pool.read { db in
            // Note + 卡（双方向）
            let note = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT headword, reading, meaning_zh, origin, deck_id
                    FROM notes WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            let headword: String? = note["headword"]
            let reading: String? = note["reading"]
            let meaningZH: String? = note["meaning_zh"]
            let origin: String? = note["origin"]
            XCTAssertEqual(headword, "食べる")
            XCTAssertEqual(reading, "たべる")
            XCTAssertEqual(meaningZH, "吃")
            XCTAssertEqual(origin, "ai")
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]), 2)
            // unit + primary link（origin 归位 aiPipeline）
            let unit = try XCTUnwrap(try GRDBLearningUnitRepository
                .fetchUnit(id: unitID, in: db))
            XCTAssertEqual(unit.identityKey, binding.identityKey)
            XCTAssertEqual(unit.identityKind, .dictionarySense)
            let link = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT role, origin FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            let linkRole: String? = link["role"]
            let linkOrigin: String? = link["origin"]
            XCTAssertEqual(linkRole, "primary")
            XCTAssertEqual(linkOrigin, "aiPipeline")
            // 来源：reader_document + reader_location + 原句重链
            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT reader_document_id, reader_location,
                           original_sentence, is_primary,
                           dictionary_entry_id, selected_gloss_language
                    FROM source_contexts WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            let readerDoc: String? = context["reader_document_id"]
            let sentence: String? = context["original_sentence"]
            let locationJSON: String? = context["reader_location"]
            let entryID: Int64? = context["dictionary_entry_id"]
            let glossLanguage: String? = context["selected_gloss_language"]
            XCTAssertEqual(readerDoc, env.documentID.uuidString.lowercased())
            XCTAssertEqual(sentence, "猫は食べるが好きだ。")
            XCTAssertNotNil(locationJSON)
            XCTAssertEqual(entryID, 200)
            XCTAssertEqual(glossLanguage, "zho")
            // resolution.unit_id 回填 + 块推进 applied
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT unit_id FROM ai_study_resolutions
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(
                        env.resolution.id)])?.lowercased(),
                unitID.uuidString.lowercased())
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT status FROM ai_study_job_blocks
                        WHERE id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(env.block.id)]),
                "applied")
            // 事件：created + noteLinked
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM learning_unit_events
                        WHERE unit_id = ?
                        """,
                    arguments: [DatabaseValueCodec.encode(unitID)]), 2)
            // Job 计数投影
            let job = try XCTUnwrap(try GRDBAIStudyJobStore.fetchJob(
                id: env.job.id, in: db))
            XCTAssertEqual(job.status, .completed)
            XCTAssertEqual(job.appliedUnits, 1)
            XCTAssertEqual(job.confirmedUnits, 1)
        }
    }

    /// create 重放：receipt 命中返回历史 outcome，行数零增量。
    func testCreateReplayConverges() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 201, senseID: 1, lemma: "泳ぐ")
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "泳ぐ", meaningZH: "游泳")])

        // 模拟「崩溃恢复」：Job 已落 applying、selection 未应用——
        // 重跑必须收敛而不是第二次建 Note。
        _ = try await service.applyConfirmedJob(jobID: env.job.id)
        let countsBefore = try await env.counts()
        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(report.units.map(\.kind), [.alreadyApplied])
        let countsAfter = try await env.counts()
        XCTAssertEqual(countsAfter, countsBefore)
    }

    /// 崩溃恢复重入：Job 已落 applying 且第一 unit 已提交（receipt +
    /// selection 回填都在），重入后第一 unit 幂等跳过、余量继续建。
    func testResumeFromApplyingAppliesRemainder() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 210, senseID: 1, lemma: "一")
        let skipKey = "jmdict:sense-v1:290:"
            + String(repeating: "f", count: 64)
        let skipSelection = env.selection(
            unitKey: skipKey, decision: .skip, action: .recordSkip)
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        try await env.insertSelection(skipSelection)
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "一", meaningZH: "one")])

        // 真实半成品：Job 已进 applying、skip 已整个提交（同事务
        // 的 receipt+selection 回填），第二个 unit 尚未落库。
        try await env.pool.write { db in
            _ = try GRDBAIStudyJobStore.transitionJob(
                id: env.job.id, to: .applying,
                expectedEpoch: 0, atMs: 1, in: db)
            try GRDBAIStudyApplyService.applyUnit(
                context: AIStudyApplyUnitContext(
                    jobID: env.job.id, documentID: env.documentID,
                    contentRevision: 1, jobEpoch: 0,
                    studyDeckID: env.deckID,
                    blocks: [env.block], resolutions: [env.resolution]),
                selection: skipSelection, source: nil,
                atMilliseconds: 1, in: db)
        }
        let countsBefore = try await env.counts()

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.entryStatus, .applying)
        XCTAssertEqual(report.finalStatus, .completed)
        // unitKey 序：create(210) 在前、skip(290) 在后。
        XCTAssertEqual(
            report.units.map(\.kind), [.createdNote, .alreadyApplied])
        try await env.pool.read { db in
            XCTAssertEqual(try env.count(db, table: "notes"), 1)
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 2)
        }
        let countsAfter = try await env.counts()
        XCTAssertNotEqual(countsAfter, countsBefore)
    }

    /// create 降级：unit 已有 primary（预览后别处已绑）→ 复用不
    /// 复制——零新 Note/卡，membership+来源 dedup 照常。
    func testCreateDegradesToReuseOfExistingPrimary() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 300, senseID: 1, lemma: "聞く")
        let existingNote = UUID()
        try await env.commitNoteWithBinding(
            noteID: existingNote, headword: "聞く", binding: binding)
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.listening])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "聞く", meaningZH: "听")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .reusedExistingPrimary)
        XCTAssertEqual(outcome.noteID, existingNote)
        XCTAssertEqual(outcome.cardCount, 0)
        try await env.pool.read { db in
            XCTAssertEqual(try env.count(db, table: "notes"), 1)
            XCTAssertEqual(try env.count(db, table: "cards"), 1)
            XCTAssertTrue(try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM note_decks
                        WHERE note_id = ? AND deck_id = ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(existingNote),
                    DatabaseValueCodec.encode(env.deckID),
                ]) ?? false)
        }
    }

    /// create 降级：无 primary 但有 legacy_secondary → 提正复用。
    func testCreatePromotesSecondaryWhenNoPrimary() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 301, senseID: 1, lemma: "見る")
        let unit = try await env.insertUnit(
            identityKey: binding.identityKey,
            entryID: 301, fingerprint: binding.fingerprint,
            lemma: "見る")
        let secondaryNote = try await env.insertBareVocabularyNote(
            headword: "見る")
        _ = try await env.pool.write { db in
            try GRDBLearningUnitRepository.linkNote(
                unitID: unit.id, noteID: secondaryNote,
                role: .legacySecondary, origin: .manual,
                atMilliseconds: 1, in: db)
        }
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "見る", meaningZH: "看")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .promotedAndReused)
        XCTAssertEqual(outcome.noteID, secondaryNote)
        try await env.pool.read { db in
            let link = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT role FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(secondaryNote)]))
            XCTAssertEqual(link["role"], "primary")
            XCTAssertEqual(try env.count(db, table: "notes"), 1)
        }
    }

    /// 不复活：unit 曾挂 Note（事件留史）现已零链接 = 用户已删
    /// ——常规应用 skippedDeletedEvidence 零写入；新 revision 的
    /// explicitRebuild 分键才真建。
    func testCreateSkipsDeletedEvidenceUnlessExplicitRebuild() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 302, senseID: 1, lemma: "消える")
        let unit = try await env.insertUnit(
            identityKey: binding.identityKey,
            entryID: 302, fingerprint: binding.fingerprint,
            lemma: "消える")
        try await env.pool.write { db in
            try GRDBLearningUnitRepository.insertEvent(
                LearningUnitEventRecord(
                    id: UUID(), operationID: UUID(),
                    unitID: unit.id, unitIDSnapshot: unit.id,
                    kind: .noteLinked,
                    afterJSON: "{\"noteID\":\"dead\"}",
                    createdAtMs: 1),
                in: db)
        }
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "消える", meaningZH: "消失")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(report.units.map(\.kind), [.skippedDeletedEvidence])
        try await env.pool.read { db in
            XCTAssertEqual(try env.count(db, table: "notes"), 0)
            // receipt 照落——选择已消费，重跑返回历史结果。
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 1)
        }

        // 显式重建：新一轮确认（selection_revision=2）+ rebuildIntent
        // 分键——绕开删除证据守卫，真建 Note/卡/链接。
        try await env.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE ai_study_jobs
                    SET status = 'awaitingConfirmation',
                        selection_revision = 2
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(env.job.id)])
        }
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese]),
            revision: 2))
        let rebuilt = try await service.applyConfirmedJob(
            jobID: env.job.id, rebuildIntent: .explicitRebuild)
        XCTAssertEqual(rebuilt.finalStatus, .completed)
        XCTAssertEqual(rebuilt.units.map(\.kind), [.createdNote])
        try await env.pool.read { db in
            XCTAssertEqual(try env.count(db, table: "notes"), 1)
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 2)
            XCTAssertEqual(
                try env.count(db, table: "learning_unit_note_links"), 1)
        }
    }

    /// 绑定指纹与 unitKey 不符 → unitBindingConflict（快照漂移：
    /// 提示局部刷新重新确认，不盲写）。
    func testCreateBindingConflictFails() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 400, senseID: 1, lemma: "話す")
        // 异义项（gloss 不同）→ 指纹不同 → identityKey 冲突。
        let otherBinding = try Self.makeBinding(
            entryID: 400, senseID: 2, lemma: "話す-sense2")
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: otherBinding, headword: "話す",
                meaningZH: "说")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .partiallyCompleted)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .failed)
        XCTAssertEqual(outcome.errorCode, "unitBindingConflict")
        try await env.pool.read { db in
            XCTAssertEqual(try env.count(db, table: "notes"), 0)
        }
    }

    // MARK: - tooEasy

    /// tooEasy：flag+事件落库、卡状态/复习日志零副作用、重放幂等。
    func testTooEasySetsFlagWithoutTouchingCards() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 500, senseID: 1, lemma: "簡単")
        let noteID = UUID()
        try await env.commitNoteWithBinding(
            noteID: noteID, headword: "簡単", binding: binding)
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .tooEasy,
            action: .setTooEasy))
        // 卡三态快照（Row 非 Sendable——抽标量带出）。
        let cardSnapshotBefore = try await env.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT is_enabled, state, due_at_ms
                    FROM cards ORDER BY id
                    """
            ).map { row -> String in
                let enabled: Int? = row["is_enabled"]
                let state: Int? = row["state"]
                let due: Int64? = row["due_at_ms"]
                return "\(enabled ?? -1)|\(state ?? -1)|\(due ?? -1)"
            }
        }
        let reviewLogCountBefore = try await env.pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM review_logs") ?? 0
        }

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(report.units.map(\.kind), [.tooEasySet])
        let outcome = try XCTUnwrap(report.units.first)
        let unitID = try XCTUnwrap(outcome.unitID)

        try await env.pool.read { db in
            let flag = try XCTUnwrap(
                try GRDBLearningUnitRepository.fetchFlag(
                    unitID: unitID, in: db))
            XCTAssertTrue(flag.tooEasy)
            XCTAssertEqual(flag.revision, 1)
            XCTAssertNotNil(try Row.fetchOne(
                db,
                sql: """
                    SELECT id FROM learning_unit_events
                    WHERE kind = 'tooEasySet'
                    """))
            // 卡与复习日志完全未动。
            let after = try Row.fetchAll(
                db,
                sql: """
                    SELECT is_enabled, state, due_at_ms
                    FROM cards ORDER BY id
                    """
            ).map { row -> String in
                let enabled: Int? = row["is_enabled"]
                let state: Int? = row["state"]
                let due: Int64? = row["due_at_ms"]
                return "\(enabled ?? -1)|\(state ?? -1)|\(due ?? -1)"
            }
            XCTAssertEqual(after, cardSnapshotBefore)
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM review_logs"),
                reviewLogCountBefore)
        }

        // 整 Job 重放——零增量。
        let countsBefore = try await env.counts()
        _ = try await env.service().applyConfirmedJob(jobID: env.job.id)
        let countsAfter = try await env.counts()
        XCTAssertEqual(countsAfter, countsBefore)
    }

    /// unit 不存在 + 词典证据齐备 → tooEasy 也能先建 unit 再置位
    /// （§2.2 有无 Note 均允许）。
    func testTooEasyCreatesUnitWhenMissing() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 501, senseID: 1, lemma: "易しい")
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .tooEasy,
            action: .setTooEasy))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "易しい")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.kind, .tooEasySet)
        let unitID = try XCTUnwrap(outcome.unitID)
        try await env.pool.read { db in
            XCTAssertEqual(
                try GRDBLearningUnitRepository.fetchFlag(
                    unitID: unitID, in: db)?.tooEasy, true)
        }
    }

    // MARK: - skip / pending

    /// skip + pending：只写 receipt 锚 + selection 回填——学习数据
    /// 全表零行。
    func testSkipAndPendingWriteOnlyReceiptAnchors() async throws {
        let env = try await makeEnvironment()
        try await env.insertSelection(env.selection(
            unitKey: "jmdict:sense-v1:600:fp0", decision: .skip,
            action: .recordSkip))
        try await env.insertSelection(env.selection(
            unitKey: "jmdict:sense-v1:601:fp1", decision: .pending,
            action: nil))

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(
            Set(report.units.map(\.kind)), [.recordedSkip])
        XCTAssertTrue(report.units.allSatisfy {
            $0.receiptOperationID != nil
        })
        try await env.pool.read { db in
            for table in ["notes", "cards", "note_decks",
                          "learning_unit_note_links", "learning_unit_flags",
                          "source_contexts", "learning_unit_events",
                          "lexical_learning_units"] {
                XCTAssertEqual(try env.count(db, table: table), 0,
                               "\(table) 必须零写入")
            }
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 2)
        }
    }

    // MARK: - Job 结算 / 幂等

    /// 多 unit 混合：create 成功 + skip + 失败 unit →
    /// partiallyCompleted；失败 unit receipt 不落可重试。
    func testMixedSettleEndsPartiallyCompleted() async throws {
        let env = try await makeEnvironment()
        let good = try Self.makeBinding(
            entryID: 700, senseID: 1, lemma: "良い")
        let otherBinding = try Self.makeBinding(
            entryID: 888, senseID: 1, lemma: "他")
        let boundNote = UUID()
        try await env.commitNoteWithBinding(
            noteID: boundNote, headword: "他", binding: otherBinding)
        let badUnit = try await env.makeDictionaryUnit(
            lemma: "悪い", entryID: 701)

        try await env.insertSelection(env.selection(
            unitKey: good.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        try await env.insertSelection(env.selection(
            unitKey: badUnit.0, decision: .reuse,
            action: .reuseNote(noteID: boundNote,
                               addMembershipTo: nil)))
        let service = env.service(sources: [
            good.identityKey: AIStudyApplyUnitSource(
                binding: good, headword: "良い", meaningZH: "好")])

        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .partiallyCompleted)
        XCTAssertEqual(
            report.units.map(\.kind).sorted { $0.rawValue < $1.rawValue },
            [.createdNote, .failed].sorted { $0.rawValue < $1.rawValue })
        let failed = try XCTUnwrap(
            report.units.first { $0.kind == .failed })
        XCTAssertEqual(failed.errorCode, "noteBoundElsewhere")
        try await env.pool.read { db in
            // 成功 unit 的 receipt 已落；失败 unit 的没写。
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 1)
        }
    }

    /// action_key 命中异 payload receipt → 归类失败、receipt 不顶替。
    func testReceiptPayloadConflictFails() async throws {
        let env = try await makeEnvironment()
        let (unitKey, _) = try await env.makeDictionaryUnit(
            lemma: "衝突", entryID: 800)
        let noteID = try await env.insertBareVocabularyNote(
            headword: "衝突")
        let actionKey = AIStudyActionKey(
            documentID: env.documentID, contentRevision: 1,
            unitKey: unitKey, selectionRevision: 1,
            actionType: .reuseNote).canonicalKey
        _ = try await env.pool.write { db in
            try GRDBAIStudyJobStore.recordReceipt(
                AIStudyReceipt(
                    operationID: UUID(), actionKey: actionKey,
                    payloadHash: "DIFFERENT", outcomeJSON: "{}",
                    committedAtMs: 1),
                in: db)
        }
        try await env.insertSelection(env.selection(
            unitKey: unitKey, decision: .reuse,
            action: .reuseNote(noteID: noteID,
                               addMembershipTo: env.deckID)))

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .partiallyCompleted)
        let outcome = try XCTUnwrap(report.units.first)
        XCTAssertEqual(outcome.errorCode, "receiptConflict")
        try await env.pool.read { db in
            XCTAssertEqual(
                try env.count(db, table: "learning_unit_note_links"), 0)
        }
    }

    /// 同 actionKey 同 payload 的既有 receipt → 返回历史结果零写入
    /// （receipt replay 先于一切业务读）。
    func testReceiptReplayReturnsExistingOutcome() async throws {
        let env = try await makeEnvironment()
        let (unitKey, _) = try await env.makeDictionaryUnit(
            lemma: "鍵", entryID: 801)
        let actionKey = AIStudyActionKey(
            documentID: env.documentID, contentRevision: 1,
            unitKey: unitKey, selectionRevision: 1,
            actionType: .recordSkip).canonicalKey
        let payload = "aisa1|\(env.job.id.uuidString.lowercased())"
            + "|\(env.documentID.uuidString.lowercased())|1|"
            + "\(unitKey)|1|recordSkip|none|skip"
        _ = try await env.pool.write { db in
            try GRDBAIStudyJobStore.recordReceipt(
                AIStudyReceipt(
                    operationID: UUID(), actionKey: actionKey,
                    payloadHash: GRDBAIStudyApplyService.sha256Hex(payload),
                    outcomeJSON: """
                        {"unitKey":"\(unitKey)","kind":"recordedSkip",\
                        "actionType":"recordSkip","cardCount":0,\
                        "membershipAdded":false}
                        """,
                    committedAtMs: 1),
                in: db)
        }
        try await env.insertSelection(env.selection(
            unitKey: unitKey, decision: .skip, action: .recordSkip))

        let report = try await env.service().applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .completed)
        XCTAssertEqual(report.units.map(\.kind), [.replayed])
        try await env.pool.read { db in
            XCTAssertEqual(
                try env.count(db, table: "ai_study_receipts"), 1)
            // replay 命中即返回——selection 不回写 applied_receipt_id。
        }
    }

    /// 复习统计零副作用：全 apply 不碰 review_logs/FSRS。
    func testApplyNeverWritesReviewLogs() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 900, senseID: 1, lemma: "統計")
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "統計", meaningZH: "统计")])
        let before = try await env.pool.read { db in
            (try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM review_logs") ?? 0,
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM daily_tasks") ?? 0)
        }
        _ = try await service.applyConfirmedJob(jobID: env.job.id)
        let after = try await env.pool.read { db in
            (try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM review_logs") ?? 0,
             try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM daily_tasks") ?? 0)
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
    }

    /// 文档 content_revision 漂移 → paused(.contentStale)，
    /// 未结算 unit 记 aborted，旧选择不盲写（§5）。
    func testStaleDocumentPausesApply() async throws {
        let env = try await makeEnvironment()
        let binding = try Self.makeBinding(
            entryID: 950, senseID: 1, lemma: "旧")
        try await env.insertSelection(env.selection(
            unitKey: binding.identityKey, decision: .create,
            action: .createNote(directions: [.japaneseToChinese])))
        let service = env.service(sources: [
            binding.identityKey: AIStudyApplyUnitSource(
                binding: binding, headword: "旧", meaningZH: "old")])
        // 用户编辑了文档——revision +1（确认后内容变了）。
        try await env.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE reader_documents SET content_revision = 2
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(env.documentID)])
        }
        let report = try await service.applyConfirmedJob(
            jobID: env.job.id)
        XCTAssertEqual(report.finalStatus, .paused)
        XCTAssertEqual(report.units.map(\.kind), [.failed])
        XCTAssertEqual(
            report.units.first?.errorCode, "staleDocumentRevision")
        try await env.pool.read { db in
            let job = try XCTUnwrap(try GRDBAIStudyJobStore.fetchJob(
                id: env.job.id, in: db))
            XCTAssertEqual(job.resumeReason, .contentStale)
            XCTAssertEqual(try env.count(db, table: "notes"), 0)
        }
    }

    /// 非法入口：pending/analyzing Job 不可应用。
    func testNonAppliableJobRejected() async throws {
        let env = try await makeEnvironment(
            jobStatus: .pending)
        do {
            _ = try await env.service().applyConfirmedJob(
                jobID: env.job.id)
            XCTFail("pending Job 必须拒绝")
        } catch let error as AIStudyApplyError {
            guard case .jobNotAppliable(.pending) = error else {
                return XCTFail("期望 jobNotAppliable，得 \(error)")
            }
        }
    }

    // MARK: - 例句提取（S22 修复：包含句而非整段）

    /// 多句块：token 锚点 utf16Offset 指向第二句——例句只取
    /// 包含句，不再整段前缀入卡。
    func testReaderBlockSentenceExtractsContainingSentence()
        async throws {
        let env = try await makeEnvironment()
        // 「彼は走った。」6 units，第二句起点 = utf16 offset 6。
        let text = "彼は走った。猫は魚を食べた。空は青い。"
        let tokenLocator = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 10,
            blockTextHash: "bhash", prefix: "を食べ", suffix: "。空")
        let tokenLocatorJSON = String(decoding:
            try JSONEncoder().encode(tokenLocator), as: UTF8.self)
        try await env.pool.write { db in
            try db.execute(
                sql: "UPDATE reader_blocks SET text = ? WHERE document_id = ?",
                arguments: [text,
                            DatabaseValueCodec.encode(env.documentID)])
        }
        let resolution = AIStudyResolutionRecord(
            id: UUID(), jobID: env.job.id, jobBlockID: env.block.id,
            documentID: env.documentID, locatorJSON: tokenLocatorJSON,
            tokenKey: "tok-0", requestHash: "rh-0",
            selectedEntryID: 200, selectedSenseID: 7,
            selectedDatasetVersion: "ds-test",
            confidence: 0.9, status: .aiResolved, origin: .ai,
            revision: 1, createdAtMs: 1)
        let context = AIStudyApplyUnitContext(
            jobID: env.job.id, documentID: env.documentID,
            contentRevision: 1, jobEpoch: env.job.epoch,
            blocks: [env.block], resolutions: [resolution])
        let selection = AIStudyJobSelection(
            jobID: env.job.id,
            unitKey: "jmdict:sense-v1:200:"
                + String(repeating: "f", count: 64),
            selectionRevision: 1, decision: .create,
            evidenceRevision: 1)
        let sentence = try await env.pool.read { db in
            GRDBAIStudyApplyService.readerBlockSentence(
                context: context, selection: selection, in: db)
        }
        XCTAssertEqual(sentence, "猫は魚を食べた。")
    }

    /// 无标点长句（>480 utf16）：以 token 位置为中心开窗——例句
    /// 有界且目标词仍在上下文内。
    func testReaderBlockSentenceBoundsPathologicalSentence()
        async throws {
        let env = try await makeEnvironment()
        let text = String(repeating: "あ", count: 600)
        let tokenLocator = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 400,
            blockTextHash: "bhash", prefix: "", suffix: "")
        let tokenLocatorJSON = String(decoding:
            try JSONEncoder().encode(tokenLocator), as: UTF8.self)
        try await env.pool.write { db in
            try db.execute(
                sql: "UPDATE reader_blocks SET text = ? WHERE document_id = ?",
                arguments: [text,
                            DatabaseValueCodec.encode(env.documentID)])
        }
        let resolution = AIStudyResolutionRecord(
            id: UUID(), jobID: env.job.id, jobBlockID: env.block.id,
            documentID: env.documentID, locatorJSON: tokenLocatorJSON,
            tokenKey: "tok-0", requestHash: "rh-0",
            selectedEntryID: 200, selectedSenseID: 7,
            selectedDatasetVersion: "ds-test",
            confidence: 0.9, status: .aiResolved, origin: .ai,
            revision: 1, createdAtMs: 1)
        let context = AIStudyApplyUnitContext(
            jobID: env.job.id, documentID: env.documentID,
            contentRevision: 1, jobEpoch: env.job.epoch,
            blocks: [env.block], resolutions: [resolution])
        let selection = AIStudyJobSelection(
            jobID: env.job.id,
            unitKey: "jmdict:sense-v1:200:"
                + String(repeating: "f", count: 64),
            selectionRevision: 1, decision: .create,
            evidenceRevision: 1)
        let sentence = try await env.pool.read { db in
            GRDBAIStudyApplyService.readerBlockSentence(
                context: context, selection: selection, in: db)
        }
        let result = try XCTUnwrap(sentence)
        XCTAssertLessThanOrEqual(result.utf16.count, 480)
        XCTAssertTrue(result.contains("あ"))
    }

    /// 锚点缺失（locator/sourceHash 皆空）→ nil——不伪造例句。
    func testReaderBlockSentenceMissingAnchorReturnsNil()
        async throws {
        let env = try await makeEnvironment()
        let resolution = AIStudyResolutionRecord(
            id: UUID(), jobID: env.job.id, jobBlockID: nil,
            documentID: env.documentID, locatorJSON: "",
            tokenKey: "tok-0", requestHash: "rh-0",
            selectedEntryID: 200, selectedSenseID: 7,
            selectedDatasetVersion: "ds-test",
            confidence: 0.9, status: .aiResolved, origin: .ai,
            revision: 1, createdAtMs: 1)
        var orphanBlock = env.block
        orphanBlock.locatorJSON = ""
        orphanBlock.sourceHash = ""
        let context = AIStudyApplyUnitContext(
            jobID: env.job.id, documentID: env.documentID,
            contentRevision: 1, jobEpoch: env.job.epoch,
            blocks: [orphanBlock], resolutions: [resolution])
        let selection = AIStudyJobSelection(
            jobID: env.job.id,
            unitKey: "jmdict:sense-v1:200:"
                + String(repeating: "f", count: 64),
            selectionRevision: 1, decision: .create,
            evidenceRevision: 1)
        let sentence = try await env.pool.read { db in
            GRDBAIStudyApplyService.readerBlockSentence(
                context: context, selection: selection, in: db)
        }
        XCTAssertNil(sentence)
    }

    // MARK: - 环境

    private struct Environment {
        let pool: DatabasePool
        let documentID: UUID
        /// 文章绑定的学习牌组（reader_documents.study_deck_id）。
        let deckID: UUID
        /// 裸 Note 的归属牌组——与文章牌组不同，membership 追加可观察。
        let homeDeckID: UUID
        let chapterID: UUID
        let job: AIStudyJob
        let block: AIStudyJobBlock
        let resolution: AIStudyResolutionRecord
        let locatorJSON: String

        /// 装配物化接缝为 stub 的服务——`sources` 按 unitKey 直供
        /// （env 为值类型保持不可变，测试内显式传字典）。
        func service(
            sources: [String: AIStudyApplyUnitSource] = [:]
        ) -> AIStudyApplyService {
            AIStudyApplyService(
                pool: pool,
                unitSources: StubUnitSourceProvider(sources: sources))
        }

        func selection(
            unitKey: String,
            decision: AISelectionDecision,
            action: AIStudyProposedAction?,
            revision: Int64 = 1
        ) -> AIStudyJobSelection {
            AIStudyJobSelection(
                jobID: job.id, unitKey: unitKey,
                selectionRevision: revision, decision: decision,
                proposedAction: action, evidenceRevision: 1)
        }

        func insertSelection(_ selection: AIStudyJobSelection) async throws {
            try await pool.write { db in
                try GRDBAIStudyJobStore.insertSelection(
                    selection, in: db)
            }
        }

        /// 词典 unit 直插（绕过 binding commit 的链接副作用）。
        @discardableResult
        func insertUnit(
            identityKey: String, entryID: Int64,
            fingerprint: String, lemma: String
        ) async throws -> LearningUnit {
            try await pool.write { db in
                try GRDBLearningUnitRepository.resolveOrCreateUnit(
                    identityKind: .dictionarySense,
                    identityKey: identityKey, lemma: lemma,
                    reading: nil, provider: "jmdict",
                    entryID: entryID, fingerprint: fingerprint,
                    fingerprintVersion: SemanticFingerprint
                        .semanticFingerprintVersion,
                    atMilliseconds: 1, in: db)
            }
        }

        /// dictionarySense unitKey 直造（指纹不参与断言时用伪指纹）。
        func makeDictionaryUnit(
            lemma: String, entryID: Int64
        ) async throws -> (String, LearningUnit) {
            let key = "jmdict:sense-v1:\(entryID):"
                + String(repeating: "f", count: 64)
            let unit = try await insertUnit(
                identityKey: key, entryID: entryID,
                fingerprint: String(repeating: "f", count: 64),
                lemma: lemma)
            return (key, unit)
        }

        /// 不经 unit 链接/membership 的裸词汇 Note（reuse 前置——
        /// 正常路径 commitVocabulary 会自动绑 unit + membership，
        /// 这里要未绑态；归属牌组 homeDeck 区别于文章牌组，
        /// membership 追加可由应用侧真实观察）。
        func insertBareVocabularyNote(
            headword: String
        ) async throws -> UUID {
            let noteID = UUID()
            try await pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, meaning_zh,
                            origin, content_version,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', ?, '释义',
                                  'manual', 1, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(homeDeckID), headword])
            }
            return noteID
        }

        /// 经共享 commit 落 Note+卡+unit link（预置「别处已学」态）。
        func commitNoteWithBinding(
            noteID: UUID, headword: String,
            binding: DictionarySenseBinding
        ) async throws {
            try await pool.write { db in
                let commit = VocabularyContentCommit(
                    noteID: noteID, exampleID: UUID(), draftID: nil,
                    deckID: deckID,
                    content: try VocabularyFormData(
                        headword: headword, meaningZH: "释义"
                    ).validatedContent(),
                    tags: [],
                    cards: [NewCardSeed(
                        id: UUID(),
                        templateKind: .vocabularyJapaneseToChinese)],
                    schedulerProfileID: UUID(),
                    createdAt: Date(timeIntervalSince1970: 1),
                    origin: .reader,
                    deckIDs: [deckID],
                    dictionaryBinding: binding)
                _ = try GRDBContentWriteExecutor.commitVocabulary(
                    commit, capture: nil, in: db)
            }
        }

        /// 行数快照（重放零增量断言）。
        func counts() async throws -> [String: Int] {
            try await pool.read { db in
                var out: [String: Int] = [:]
                for table in [
                    "notes", "cards", "note_decks", "examples",
                    "source_contexts", "lexical_learning_units",
                    "learning_unit_note_links", "learning_unit_flags",
                    "learning_unit_events", "ai_study_receipts",
                    "review_logs",
                ] {
                    out[table] = try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                }
                return out
            }
        }

        func count(_ db: Database, table: String) throws -> Int {
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private struct StubUnitSourceProvider:
        AIStudyApplyUnitSourceProvider {
        let sources: [String: AIStudyApplyUnitSource]
        func unitSource(
            for selection: AIStudyJobSelection,
            job: AIStudyJob,
            resolutions: [AIStudyResolutionRecord],
            blocks: [AIStudyJobBlock]
        ) async throws -> AIStudyApplyUnitSource? {
            sources[selection.unitKey]
        }
    }

    private func makeEnvironment(
        jobStatus: AIStudyJobStatus = .awaitingConfirmation
    ) async throws -> Environment {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AIStudyApply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: configuration)
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)

        let documentID = UUID()
        let deckID = UUID()
        let homeDeckID = UUID()
        let chapterID = UUID()
        let jobID = UUID()
        let locator = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 2,
            blockTextHash: "bhash", prefix: "猫は", suffix: "が好きだ。")
        let locatorJSON = String(
            decoding: try JSONEncoder().encode(locator), as: UTF8.self)
        let block = AIStudyJobBlock(
            id: UUID(), jobID: jobID, locatorJSON: locatorJSON,
            sourceHash: "bhash", subblockKey: "b0",
            candidateSetHash: "csh", requestHash: "rh-0",
            status: .awaitingConfirmation)
        let resolution = AIStudyResolutionRecord(
            id: UUID(), jobID: jobID, jobBlockID: block.id,
            documentID: documentID, locatorJSON: locatorJSON,
            tokenKey: "tok-0", requestHash: "rh-0",
            selectedEntryID: 200, selectedSenseID: 7,
            selectedDatasetVersion: "ds-test",
            confidence: 0.9, status: .aiResolved, origin: .ai,
            revision: 1, createdAtMs: 1)
        let job = AIStudyJob(
            id: jobID, documentID: documentID,
            studyDeckID: deckID,
            scope: .fullDocument, inputFingerprint: "fp",
            contentRevision: 1,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: "fake", model: "m",
                responseMode: "promptedJSON",
                promptVersion: "p", policyVersion: "pol"),
            model: "m", pipelineVersion: "pipe",
            promptVersion: "p", policyVersion: "pol",
            status: jobStatus, epoch: 0, selectionRevision: 1,
            createdAtMs: 1, updatedAtMs: 1)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, content_revision,
                        progress_basis_points, availability
                    ) VALUES (?, '研究対象', 'txt', 1, ?, ?, 'v1',
                              1, 0, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    String(repeating: "a", count: 64),
                    String(repeating: "b", count: 64)])
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, '研究牌组', 0, 1, 1),
                           (?, '归属牌组', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(deckID),
                    DatabaseValueCodec.encode(homeDeckID)])
            try db.execute(
                sql: """
                    UPDATE reader_documents
                    SET study_deck_id = ?,
                        study_deck_name_follows_title = 1
                    WHERE id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(deckID),
                    DatabaseValueCodec.encode(documentID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, title,
                        canonical_hash, text_utf16_length
                    ) VALUES (?, ?, 0, '第一章', 'chash', 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(chapterID),
                    DatabaseValueCodec.encode(documentID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_blocks(
                        id, document_id, chapter_id, ordinal,
                        text, text_hash, locator_json
                    ) VALUES (?, ?, ?, 0, ?, 'bhash', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID),
                    DatabaseValueCodec.encode(chapterID),
                    "猫は食べるが好きだ。", locatorJSON])
            try GRDBAIStudyJobStore.insertJob(job, in: db)
            try GRDBAIStudyJobStore.insertBlock(block, in: db)
            try GRDBAIStudyJobStore.insertResolution(
                resolution, documentID: documentID, in: db)
        }
        return Environment(
            pool: pool, documentID: documentID, deckID: deckID,
            homeDeckID: homeDeckID, chapterID: chapterID, job: job,
            block: block, resolution: resolution,
            locatorJSON: locatorJSON)
    }

    /// 构造与 `identityKey` 自洽的 binding（sense 内容由测试给定，
    /// 指纹经 `SemanticFingerprint.compute` 真算——保证
    /// `binding.identityKey == unitKey`）。
    static func makeBinding(
        entryID: Int64, senseID: Int64, lemma: String
    ) throws -> DictionarySenseBinding {
        let sense = DictionarySense(
            id: senseID, order: 1, posCodes: ["v1"], tags: [],
            glosses: [DictionaryGloss(
                language: "eng", text: "gloss-\(lemma)", order: 1,
                sourceID: "t", isMachineGenerated: false,
                sourceFingerprint: nil)])
        return try DictionarySenseBinding.from(
            sense: sense, entryID: entryID,
            datasetVersion: "ds-test")
    }
}
