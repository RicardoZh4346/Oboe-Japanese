import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S04：`GRDBLearningUnitRepository` 行为测试——
/// resolve-or-create 幂等、primary 唯一/提升顺序、flag CAS +
/// operation 幂等、alias 歧义不覆盖、事件/迁移条目读写。
///
/// 建库方式：v1–v22 全量迁移 + 独立 `DatabaseMigrator` 直接注册
/// `GRDBLearningUnitSchema.migrate`（M 接线 `OboeDatabase.swift`
/// 前后均可跑，同函数同语义）。
final class GRDBLearningUnitRepositoryTests: XCTestCase {

    private static let v23ID = "v23_learning_units"
    private let encode: (UUID) -> String = DatabaseValueCodec.encode

    // MARK: - resolveOrCreate

    /// 同 key 顺序重复只一行；既有行的 sense_snapshot 不被回写。
    func testResolveOrCreateIdempotentAndNeverRewritesSnapshot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fingerprint = String(repeating: "f", count: 64)
        let key = "jmdict:sense-v1:1578850:\(fingerprint)"

        let created = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .dictionarySense,
                identityKey: key,
                lemma: "食べる", reading: "たべる",
                provider: "jmdict", entryID: 1578850,
                fingerprint: fingerprint,
                fingerprintVersion: "sense-fp-1",
                senseSnapshotJSON: "{\"gloss\":[\"to eat\"]}",
                atMilliseconds: 1_000,
                in: db)
        }
        XCTAssertEqual(created.bindingStatus, .current)
        XCTAssertEqual(created.provider, "jmdict")
        XCTAssertEqual(created.dictionaryEntryID, 1578850)
        XCTAssertEqual(created.revision, 0)

        // 同 key + 不同快照重放：返回同一行，快照不被覆盖。
        let replayed = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .dictionarySense,
                identityKey: key,
                lemma: "食べる(别写)", reading: "たべる",
                provider: "jmdict", entryID: 1578850,
                fingerprint: fingerprint,
                fingerprintVersion: "sense-fp-1",
                senseSnapshotJSON: "{\"gloss\":[\"MUTATED\"]}",
                atMilliseconds: 2_000,
                in: db)
        }
        XCTAssertEqual(replayed.id, created.id)
        XCTAssertEqual(replayed.lemma, "食べる")
        XCTAssertEqual(replayed.createdAtMs, 1_000)

        try fixture.database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexical_learning_units"),
                1, "同 key 重放必须仍只有一行")
            let snapshot: String? = try String.fetchOne(
                db,
                sql: """
                    SELECT sense_snapshot_json FROM lexical_learning_units
                    WHERE id = ?
                    """,
                arguments: [self.encode(created.id)])
            XCTAssertTrue(snapshot?.contains("to eat") == true)
            XCTAssertFalse(snapshot?.contains("MUTATED") == true,
                           "resolveOrCreate 绝不回写已有 sense_snapshot")
        }
    }

    /// 并发同 key：8 个并发任务全部收敛到同一 unit id，库里一行。
    ///（pool.write 为 IMMEDIATE 事务——写者天然串行，DO NOTHING 兜底。）
    func testResolveOrCreateConcurrentSameKey() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fingerprint = String(repeating: "c", count: 64)
        let key = "jmdict:sense-v1:20002:\(fingerprint)"
        let repo = fixture.repository
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let ids: [UUID] = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await repo.resolveOrCreateUnit(
                        identityKind: .dictionarySense,
                        identityKey: key,
                        lemma: "走る", reading: "はしる",
                        provider: "jmdict", entryID: 20002,
                        fingerprint: fingerprint,
                        fingerprintVersion: "sense-fp-1",
                        at: date).id
                }
            }
            var collected: [UUID] = []
            for try await id in group { collected.append(id) }
            return collected
        }
        XCTAssertEqual(ids.count, 8)
        XCTAssertEqual(Set(ids).count, 1, "并发同 key 必须收敛到同一 unit")
        try await fixture.database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexical_learning_units"),
                1)
        }
    }

    /// 非词典 unit 缺省 `legacy`；dictionarySense 三件套缺一抛错。
    func testResolveOrCreateIdentityDefaults() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let local = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .localNote,
                identityKey: "local-note:\(UUID().uuidString.lowercased())",
                lemma: "手作語", reading: nil,
                atMilliseconds: 1,
                in: db)
        }
        XCTAssertEqual(local.bindingStatus, .legacy)
        XCTAssertNil(local.provider)

        let legacy = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .legacyUnresolved,
                identityKey: "legacy-key:abc",
                lemma: "旧词", reading: nil,
                bindingStatus: .needsConfirmation,
                atMilliseconds: 1,
                in: db)
        }
        XCTAssertEqual(legacy.bindingStatus, .needsConfirmation)

        XCTAssertThrowsError(try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .dictionarySense,
                identityKey: "jmdict:sense-v1:1:bad",
                lemma: "x", reading: nil,
                provider: "jmdict", entryID: 1, // 缺 fingerprint
                atMilliseconds: 1,
                in: db)
        }) { error in
            XCTAssertEqual(
                error as? LearningUnitRepositoryError,
                .invalidUnitIdentity(
                    "dictionarySense 需要 provider/entryID/fingerprint"))
        }
    }

    /// fetchUnits 批量（字典返回）+ fetchUnit(identityKey:) 单查。
    func testFetchUnitsBatchAndByKey() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let a = UUID()
        let b = UUID()
        try fixture.database.pool.write { db in
            for (id, key) in [(a, "local-note:a"), (b, "local-note:b")] {
                try GRDBLearningUnitRepository.insertUnit(
                    LearningUnit(
                        id: id, identityKind: .localNote,
                        identityKey: key, lemma: key,
                        bindingStatus: .legacy,
                        createdAtMs: 1, updatedAtMs: 1),
                    in: db)
            }
        }
        try fixture.database.pool.read { db in
            let map = try GRDBLearningUnitRepository.fetchUnits(
                ids: [a, b, UUID()], in: db)
            XCTAssertEqual(map.count, 2)
            XCTAssertEqual(map[a]?.identityKey, "local-note:a")
            XCTAssertNil(
                try GRDBLearningUnitRepository.fetchUnit(
                    identityKey: "local-note:none", in: db))
            XCTAssertEqual(
                try GRDBLearningUnitRepository.fetchUnit(
                    identityKey: "local-note:b", in: db)?.id, b)
        }
    }

    // MARK: - linkNote / promote

    /// 校验顺序与结构化错误：note 存在且 vocabulary、unit 存在、
    /// note_id 单绑、primary 不自动抢占；同三元组幂等。
    func testLinkNoteValidations() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitA = try fixture.makeUnit(identityKey: "local-note:A")
        let unitB = try fixture.makeUnit(identityKey: "local-note:B")
        let vocab = try fixture.makeNote(kind: "vocabulary")
        let grammar = try fixture.makeNote(kind: "grammar")

        let missingUnit = UUID()
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.linkNote(
                    unitID: missingUnit, noteID: vocab, role: .primary,
                    origin: .manual, atMilliseconds: 1, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .unitNotFound(missingUnit))
            }
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.linkNote(
                    unitID: unitA, noteID: UUID(), role: .primary,
                    origin: .manual, atMilliseconds: 1, in: db)
            ) {
                guard case .noteNotFound = ($0 as? LearningUnitRepositoryError) else {
                    return XCTFail("应为 noteNotFound: \($0)")
                }
            }
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.linkNote(
                    unitID: unitA, noteID: grammar, role: .primary,
                    origin: .manual, atMilliseconds: 1, in: db)
            ) {
                guard case .noteNotVocabulary = ($0 as? LearningUnitRepositoryError) else {
                    return XCTFail("应为 noteNotVocabulary: \($0)")
                }
            }
        }

        let link = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitA, noteID: vocab, role: .primary,
                origin: .userConfirmed, atMilliseconds: 1, in: db)
        }
        XCTAssertEqual(link.role, .primary)

        // 幂等：同 (unit,note,role) 返回既有行
        let again = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitA, noteID: vocab, role: .primary,
                origin: .manual, atMilliseconds: 2, in: db)
        }
        XCTAssertEqual(again.createdAtMs, 1)

        // 同 note 绑到另一 unit → noteAlreadyLinked
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.linkNote(
                    unitID: unitB, noteID: vocab,
                    role: .legacySecondary, origin: .manual,
                    atMilliseconds: 3, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .noteAlreadyLinked(
                        noteID: vocab, existingUnitID: unitA))
            }
        }

        // 第二 primary → primaryLinkConflict（不自动抢占）
        let other = try fixture.makeNote(kind: "vocabulary")
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.linkNote(
                    unitID: unitA, noteID: other, role: .primary,
                    origin: .manual, atMilliseconds: 4, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .primaryLinkConflict(
                        unitID: unitA, existingNoteID: vocab))
            }
        }
        // 但 secondary 合法（D02：保留 legacy secondary）
        let secondary = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitA, noteID: other,
                role: .legacySecondary, origin: .backfill,
                atMilliseconds: 4, in: db)
        }
        XCTAssertEqual(secondary.role, .legacySecondary)
    }

    /// 删除 primary 后按「created 最早 + note_id 序最小」提升。
    func testPromoteSecondaryOrdering() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitID = try fixture.makeUnit(identityKey: "local-note:P")
        let primary = try fixture.makeNote(kind: "vocabulary")
        // 两 secondary 同 created_at → UUID 序小者先；再加一个更晚的。
        var secondaries = (0..<3).map { _ in
            try! fixture.makeNote(kind: "vocabulary") }
        secondaries.sort {
            encode($0) < encode($1)
        }
        let earliest = secondaries[0]
        let tie = secondaries[1]
        let latest = secondaries[2]

        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitID, noteID: primary, role: .primary,
                origin: .manual, atMilliseconds: 1, in: db)
            // 乱序插入，created_at 决定顺序而非插入序。
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitID, noteID: latest,
                role: .legacySecondary, origin: .backfill,
                atMilliseconds: 90, in: db)
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitID, noteID: earliest,
                role: .legacySecondary, origin: .backfill,
                atMilliseconds: 50, in: db)
            try GRDBLearningUnitRepository.linkNote(
                unitID: unitID, noteID: tie,
                role: .legacySecondary, origin: .backfill,
                atMilliseconds: 50, in: db)
        }

        // primary 仍在时提升被拒。
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository
                    .promoteSecondaryToPrimary(unitID: unitID, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .primaryLinkConflict(
                        unitID: unitID, existingNoteID: primary))
            }
        }

        // 删 primary → 提升最早（created 50，同刻 UUID 序最小）。
        try fixture.database.pool.write { db in
            XCTAssertTrue(
                try GRDBLearningUnitRepository.unlinkNote(
                    unitID: unitID, noteID: primary, in: db))
            let promoted = try GRDBLearningUnitRepository
                .promoteSecondaryToPrimary(unitID: unitID, in: db)
            XCTAssertEqual(promoted.noteID, earliest)
            XCTAssertEqual(promoted.role, .primary)
        }
        try fixture.database.pool.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT note_id FROM learning_unit_note_links
                        WHERE unit_id = ? AND role = 'primary'
                        """,
                    arguments: [self.encode(unitID)]),
                self.encode(earliest))
        }

        // 再删 → 提升下一个；耗尽 → noLegacySecondaryToPromote。
        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.unlinkNote(
                unitID: unitID, noteID: earliest, in: db)
            let second = try GRDBLearningUnitRepository
                .promoteSecondaryToPrimary(unitID: unitID, in: db)
            XCTAssertEqual(second.noteID, tie)
            try GRDBLearningUnitRepository.unlinkNote(
                unitID: unitID, noteID: tie, in: db)
            let third = try GRDBLearningUnitRepository
                .promoteSecondaryToPrimary(unitID: unitID, in: db)
            XCTAssertEqual(third.noteID, latest)
            try GRDBLearningUnitRepository.unlinkNote(
                unitID: unitID, noteID: latest, in: db)
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository
                    .promoteSecondaryToPrimary(unitID: unitID, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .noLegacySecondaryToPromote(unitID: unitID))
            }
        }
    }

    /// `linkedVocabularyUnitIDs` 只数关联到 vocabulary Note 的行。
    func testLinkedVocabularyUnitIDs() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let linked = try fixture.makeUnit(identityKey: "local-note:L1")
        let unlinked = try fixture.makeUnit(identityKey: "local-note:L2")
        let grammarBound = try fixture.makeUnit(identityKey: "local-note:L3")
        let vocabNote = try fixture.makeNote(kind: "vocabulary")
        let grammarNote = try fixture.makeNote(kind: "grammar")

        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.linkNote(
                unitID: linked, noteID: vocabNote, role: .primary,
                origin: .manual, atMilliseconds: 1, in: db)
            // 非词汇绑定只能绕过校验直插（防御口径：三态不计）。
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'primary', 'manual', 2)
                    """,
                arguments: [self.encode(grammarBound), self.encode(grammarNote)])
        }
        try fixture.database.pool.read { db in
            let set = try GRDBLearningUnitRepository
                .linkedVocabularyUnitIDs(
                    unitIDs: [linked, unlinked, grammarBound], in: db)
            XCTAssertEqual(set, [linked])
        }
    }

    // MARK: - flags / Too Easy

    /// CAS：expected 不符不覆盖；flag 无行按 revision 0 计；
    /// event 含 before/after/payload_hash；同 opID 重放幂等、
    /// 异 payload 拒绝。
    func testSetFlagTooEasyCASIdempotencyAndEvents() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitID = try fixture.makeUnit(identityKey: "local-note:F")
        let op1 = UUID()
        let op2 = UUID()

        // expected=2 但无 flag（当前视 0）→ 冲突不建行
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.setFlagTooEasy(
                    unitID: unitID, value: true, expectedRevision: 2,
                    operationID: op1, atMilliseconds: 1, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .flagRevisionConflict(
                        unitID: unitID, expected: 2, actual: 0))
            }
            XCTAssertNil(
                try GRDBLearningUnitRepository.fetchFlag(
                    unitID: unitID, in: db))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM learning_unit_events"),
                0, "CAS 失败不得留下事件")
        }

        // 正确 CAS：rev 0→1，event 完整落库。
        let flag1 = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID, value: true, expectedRevision: 0,
                operationID: op1, atMilliseconds: 100, in: db)
        }
        XCTAssertEqual(flag1.tooEasy, true)
        XCTAssertEqual(flag1.revision, 1)

        // 同 opID 同 payload 重放：返回既有效果，不新增事件/不改 rev。
        let replay = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID, value: true, expectedRevision: 0,
                operationID: op1, atMilliseconds: 200, in: db)
        }
        XCTAssertEqual(replay.revision, 1)
        try fixture.database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM learning_unit_events"),
                1, "同 operationID 重放不得新增事件")
        }

        // 同 opID 异 payload → operationPayloadConflict。
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.setFlagTooEasy(
                    unitID: unitID, value: false, expectedRevision: 1,
                    operationID: op1, atMilliseconds: 300, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .operationPayloadConflict(operationID: op1))
            }
        }

        // 新 opID 正常推进 rev1→2，before/after 都留史。
        let flag2 = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID, value: false, expectedRevision: 1,
                operationID: op2, atMilliseconds: 400, in: db)
        }
        XCTAssertEqual(flag2.tooEasy, false)
        XCTAssertEqual(flag2.revision, 2)

        try fixture.database.pool.read { db in
            let events = try GRDBLearningUnitRepository.fetchEvents(
                unitID: unitID, in: db)
            XCTAssertEqual(events.count, 2)
            let first = try XCTUnwrap(
                events.first { $0.operationID == op1 })
            XCTAssertEqual(first.kind, .tooEasySet)
            XCTAssertEqual(first.unitID, unitID)
            XCTAssertEqual(first.unitIDSnapshot, unitID)
            XCTAssertNil(first.beforeJSON, "首写无 before")
            XCTAssertEqual(
                first.afterJSON, "{\"revision\":1,\"tooEasy\":true}")
            XCTAssertEqual(first.payloadHash?.count, 64)
            let second = try XCTUnwrap(
                events.first { $0.operationID == op2 })
            XCTAssertEqual(
                second.beforeJSON, "{\"revision\":1,\"tooEasy\":true}")
            XCTAssertEqual(
                second.afterJSON, "{\"revision\":2,\"tooEasy\":false}")
        }
    }

    /// TooEasyUndo：凭 eventID+revision CAS 还原；原事件标记
    /// undone_at_ms；重复撤销拒绝；撤销命令自身幂等。
    func testUndoTooEasy() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitID = try fixture.makeUnit(identityKey: "local-note:U")
        let setOp = UUID()
        let undoOp = UUID()

        let flag1 = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID, value: true, expectedRevision: 0,
                operationID: setOp, atMilliseconds: 100, in: db)
        }
        let setEventID = try fixture.database.pool.read { db in
            try GRDBLearningUnitRepository.fetchEvent(
                operationID: setOp, in: db)!.id
        }

        // 另一窗口先动过 flag（rev2）→ 撤销 CAS 失败不覆盖。
        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID, value: false, expectedRevision: 1,
                operationID: UUID(), atMilliseconds: 200, in: db)
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.undoTooEasy(
                    TooEasyUndoCommand(
                        unitID: unitID, eventID: setEventID,
                        beforeValue: false, expectedFlagRevision: 1,
                        operationID: undoOp),
                    atMilliseconds: 300, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .flagRevisionConflict(
                        unitID: unitID, expected: 1, actual: 2))
            }
        }

        // 用当前 rev2 作 CAS 正常撤销（回到 set 前 tooEasy=false）。
        let undoOp2 = UUID()
        let restored = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.undoTooEasy(
                TooEasyUndoCommand(
                    unitID: unitID, eventID: setEventID,
                    beforeValue: false, expectedFlagRevision: 2,
                    operationID: undoOp2),
                atMilliseconds: 400, in: db)
        }
        XCTAssertEqual(restored.tooEasy, false)
        XCTAssertEqual(restored.revision, 3)
        XCTAssertEqual(flag1.revision, 1)

        // 重放同 undo opID → 幂等返回。
        let replay = try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.undoTooEasy(
                TooEasyUndoCommand(
                    unitID: unitID, eventID: setEventID,
                    beforeValue: false, expectedFlagRevision: 2,
                    operationID: undoOp2),
                atMilliseconds: 500, in: db)
        }
        XCTAssertEqual(replay.revision, 3)

        try fixture.database.pool.read { db in
            let original = try XCTUnwrap(
                try GRDBLearningUnitRepository.fetchEvent(
                    operationID: setOp, in: db))
            XCTAssertEqual(
                original.undoneAtMs, 400, "原事件须标记 undone_at_ms")
            let undoEvents = try GRDBLearningUnitRepository
                .fetchEvents(unitID: unitID, in: db)
                .filter { $0.kind == .tooEasyUndone }
            XCTAssertEqual(undoEvents.count, 1)
            XCTAssertEqual(undoEvents[0].operationID, undoOp2)
        }

        // 已撤销事件再撤销 → eventAlreadyUndone。
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.undoTooEasy(
                    TooEasyUndoCommand(
                        unitID: unitID, eventID: setEventID,
                        beforeValue: false, expectedFlagRevision: 3,
                        operationID: UUID()),
                    atMilliseconds: 600, in: db)
            ) {
                XCTAssertEqual(
                    $0 as? LearningUnitRepositoryError,
                    .eventAlreadyUndone(setEventID))
            }
        }
    }

    /// 无 Note 的 unit 同样允许 tooEasy（§2.2）；删 unit 后 flag
    /// CASCADE、事件 unit_id SET NULL 但 snapshot 留史。
    func testFlagCascadeOnUnitDelete() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitID = try fixture.makeUnit(identityKey: "local-note:D")
        let op = UUID()
        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID, value: true, expectedRevision: 0,
                operationID: op, atMilliseconds: 1, in: db)
        }
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM lexical_learning_units WHERE id = ?",
                arguments: [self.encode(unitID)])
        }
        try fixture.database.pool.read { db in
            XCTAssertNil(
                try GRDBLearningUnitRepository.fetchFlag(
                    unitID: unitID, in: db))
            let event = try XCTUnwrap(
                try GRDBLearningUnitRepository.fetchEvent(
                    operationID: op, in: db))
            XCTAssertNil(event.unitID, "事件弱引用 SET NULL")
            XCTAssertEqual(event.unitIDSnapshot, unitID, "快照留史")
        }
    }

    // MARK: - alias

    /// upsertAlias 三分支：插入 / 同 unit 更新 / 异 unit 冲突降级
    /// needsConfirmation 不覆盖归属。
    func testUpsertAliasOutcomes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitA = try fixture.makeUnit(identityKey: "local-note:AA")
        let unitB = try fixture.makeUnit(identityKey: "local-note:BB")
        let fp = String(repeating: "b", count: 64)

        try fixture.database.pool.write { db in
            let outcome = try GRDBLearningUnitRepository.upsertAlias(
                LearningUnitDictionaryAlias(
                    unitID: unitA, provider: "jmdict",
                    datasetVersion: "ds-1", entryID: 100, senseID: 5,
                    fingerprint: fp, status: .current),
                fingerprintVersion: "sense-fp-1",
                resolvedAtMs: 10, in: db)
            XCTAssertEqual(outcome, .inserted)
        }
        // 同四元组同 unit：更新 status/resolved。
        try fixture.database.pool.write { db in
            let outcome = try GRDBLearningUnitRepository.upsertAlias(
                LearningUnitDictionaryAlias(
                    unitID: unitA, provider: "jmdict",
                    datasetVersion: "ds-1", entryID: 100, senseID: 5,
                    fingerprint: fp, status: .stale),
                fingerprintVersion: "sense-fp-1",
                resolvedAtMs: 20, in: db)
            XCTAssertEqual(outcome, .updated)
        }
        // 同四元组异 unit：不覆盖归属，行标 needsConfirmation。
        try fixture.database.pool.write { db in
            let outcome = try GRDBLearningUnitRepository.upsertAlias(
                LearningUnitDictionaryAlias(
                    unitID: unitB, provider: "jmdict",
                    datasetVersion: "ds-1", entryID: 100, senseID: 5,
                    fingerprint: fp, status: .current),
                fingerprintVersion: "sense-fp-1",
                resolvedAtMs: 30, in: db)
            XCTAssertEqual(
                outcome, .markedNeedsConfirmation(existingUnitID: unitA))
        }
        try fixture.database.pool.read { db in
            let bindings = try GRDBLearningUnitRepository.fetchAliases(
                unitID: unitA, in: db)
            XCTAssertEqual(bindings.count, 1)
            let binding = bindings[0]
            XCTAssertEqual(binding.alias.unitID, unitA,
                           "冲突不得把绑定改判给 unitB")
            XCTAssertEqual(binding.alias.status, .needsConfirmation)
            XCTAssertEqual(binding.alias.datasetVersion, "ds-1")
            XCTAssertEqual(binding.fingerprintVersion, "sense-fp-1")
            XCTAssertEqual(binding.resolvedAtMs, 30)
            XCTAssertTrue(
                try GRDBLearningUnitRepository.fetchAliases(
                    unitID: unitB, in: db).isEmpty,
                "unitB 不得拿到该 alias 行")
        }
    }

    // MARK: - 事件 / 迁移条目

    /// insertEvent 落库 + operation_id UNIQUE；fetchEvent 幂等入口。
    func testInsertEventAndOperationUniqueness() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitID = try fixture.makeUnit(identityKey: "local-note:E")
        let opID = UUID()
        let record = LearningUnitEventRecord(
            id: UUID(), operationID: opID,
            unitID: unitID, unitIDSnapshot: unitID,
            kind: .noteLinked, afterJSON: "{\"role\":\"primary\"}",
            payloadHash: "ph", createdAtMs: 7)
        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.insertEvent(record, in: db)
        }
        try fixture.database.pool.read { db in
            let fetched = try GRDBLearningUnitRepository.fetchEvent(
                operationID: opID, in: db)
            XCTAssertEqual(fetched, record)
            XCTAssertEqual(fetched?.event.operationID, opID)
            XCTAssertEqual(fetched?.event.kind, .noteLinked)
        }
        // 同 operationID 第二行必败（幂等锚点）。
        try fixture.database.pool.write { db in
            XCTAssertThrowsError(
                try GRDBLearningUnitRepository.insertEvent(
                    LearningUnitEventRecord(
                        id: UUID(), operationID: opID,
                        unitID: unitID, unitIDSnapshot: unitID,
                        kind: .noteUnlinked, createdAtMs: 8),
                    in: db))
        }
    }

    /// migration item upsert 幂等 + 状态扫描。
    func testMigrationItemUpsert() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let unitID = try fixture.makeUnit(identityKey: "local-note:M")
        let noteID = try fixture.makeNote(kind: "vocabulary")

        try fixture.database.pool.write { db in
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: "override:\(UUID().uuidString)",
                    noteID: noteID, oldState: "known",
                    status: .needsConfirmation,
                    evidenceJSON: "{\"reason\":\"ambiguous\"}"),
                in: db)
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: "note:\(noteID.uuidString.lowercased())",
                    noteID: noteID, oldState: "learning",
                    status: .applied, targetUnitID: unitID),
                in: db)
            // 同 source_key 重 upsert：更新不新增。
            try GRDBLearningUnitRepository.upsertMigrationItem(
                LearningUnitMigrationItem(
                    sourceKey: "note:\(noteID.uuidString.lowercased())",
                    noteID: noteID, oldState: "learning",
                    status: .applied, targetUnitID: unitID,
                    lastError: nil),
                in: db)
        }
        try fixture.database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM learning_unit_migration_items"),
                2)
            let applied = try GRDBLearningUnitRepository
                .fetchMigrationItems(status: .applied, in: db)
            XCTAssertEqual(applied.count, 1)
            XCTAssertEqual(applied[0].targetUnitID, unitID)
            let pending = try GRDBLearningUnitRepository
                .fetchMigrationItems(status: .needsConfirmation, in: db)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending[0].oldState, "known")
        }
    }

    // MARK: - fixture（本文件私有）

    private struct Fixture {
        let directory: URL
        let database: OboeDatabase
        let repository: GRDBLearningUnitRepository

        func cleanup() {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }

        /// 建 deck+vocabulary/grammar note，返回 noteID。
        func makeNote(
            kind: String, deckID: UUID? = nil
        ) throws -> UUID {
            let noteID = UUID()
            let deck = try deckID ?? ensureDeck()
            try database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, meaning_zh,
                            is_favorite, origin, content_version,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, '詞', '义', 0, 'manual', 1, 1, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(deck),
                        kind,
                    ])
            }
            return noteID
        }

        private func ensureDeck() throws -> UUID {
            try database.pool.write { db in
                if let raw = try String.fetchOne(
                    db, sql: "SELECT id FROM decks LIMIT 1") {
                    return try DatabaseValueCodec.decodeUUID(raw)
                }
                let deckID = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO decks(
                            id, name, sort_order, created_at_ms, updated_at_ms
                        ) VALUES (?, 'd', 0, 1, 1)
                        """,
                    arguments: [DatabaseValueCodec.encode(deckID)])
                return deckID
            }
        }

        /// 直接 resolveOrCreate 造 unit（localNote），返回 id。
        func makeUnit(identityKey: String) throws -> UUID {
            try database.pool.write { db in
                try GRDBLearningUnitRepository.resolveOrCreateUnit(
                    identityKind: .localNote, identityKey: identityKey,
                    lemma: identityKey, reading: nil,
                    atMilliseconds: 1, in: db).id
            }
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBLearningUnitRepo-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("oboe.sqlite")

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
            path: file.path, configuration: configuration)
        do {
            try OboeDatabaseSchema
                .makeMigrator(applying: OboeDatabaseSchema.migrationIdentifiers)
                .migrate(pool)
            var migrator = DatabaseMigrator()
            migrator.registerMigration(
                Self.v23ID, migrate: GRDBLearningUnitSchema.migrate)
            try migrator.migrate(pool)
        } catch {
            try? pool.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let database = OboeDatabase(pool: pool)
        return Fixture(
            directory: directory, database: database,
            repository: GRDBLearningUnitRepository(pool: pool))
    }
}
