import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S08 旧 Note → lexeme 高置信回填（设计 §6.3）：
/// SourceContext ent_seq 验证 → 严格唯一候选 → 读音消歧 →
/// local 占位。幂等、分批、可取消、跑完写 receipt。
final class GRDBLexemeBackfillTests: XCTestCase {

    private var directory: URL!
    private var pool: DatabasePool!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: config)
        try OboeDatabaseSchema.makeMigrator(applying:
            OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        var v18 = DatabaseMigrator()
        v18.registerMigration(
            "v18_lexical_knowledge", migrate: GRDBKnowledgeSchema.migrate)
        try v18.migrate(pool)
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - helpers

    private func insertVocabularyNote(
        headword: String,
        reading: String? = nil,
        pos: String? = nil,
        contextEntryID: Int64? = nil,
        contextDictVersion: String? = nil
    ) async throws -> UUID {
        let deckID = UUID()
        let noteID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading,
                        part_of_speech, meaning_zh, is_favorite, origin,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, ?, ?, 'm', 0,
                              'manual', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    headword, reading, pos
                ])
            if let contextEntryID {
                try db.execute(
                    sql: """
                        INSERT INTO source_contexts(
                            id, note_id, source_type, is_primary,
                            dictionary_entry_id, dictionary_version,
                            created_at_ms
                        ) VALUES (?, ?, 'dictionary', 1, ?, ?, 1)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(UUID()),
                        DatabaseValueCodec.encode(noteID),
                        contextEntryID, contextDictVersion
                    ])
            }
        }
        return noteID
    }

    private func makeService(
        dictQueue: DatabaseQueue,
        batchSize: Int = 200
    ) -> LexemeBackfillService {
        LexemeBackfillService(
            pool: pool,
            resolver: GRDBMorphologyCandidateResolver(
                reader: dictQueue, datasetVersion: "test-dict"),
            verifier: GRDBLexemeEntryVerifier(
                reader: dictQueue, datasetVersion: "test-dict"),
            batchSize: batchSize,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeID: { UUID() }
        )
    }

    private struct LinkRow {
        let noteID: UUID
        let provider: String
        let entryID: Int64?
        let origin: String
        let status: String
        let confidence: Double?
    }

    private func linkRows() async throws -> [LinkRow] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT l.note_id, x.provider, x.entry_id,
                           l.association_origin, x.resolution_status,
                           l.confidence
                    FROM lexeme_note_links l
                    JOIN lexemes x ON x.id = l.lexeme_id
                    ORDER BY l.created_at_ms, l.note_id
                    """
            ).map { row in
                LinkRow(
                    noteID: try DatabaseValueCodec.decodeUUID(row["note_id"]),
                    provider: row["provider"],
                    entryID: row["entry_id"],
                    origin: row["association_origin"],
                    status: row["resolution_status"],
                    confidence: row["confidence"]
                )
            }
        }
    }

    // MARK: - tests

    /// 档 1：source_contexts.dictionary_entry_id + 表记/读音验证 →
    /// jmdict lexeme + backfill 关联。
    func testSourceContextVerifiedLink() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 42, forms: ["食べる"], readings: ["たべる"],
                  pos: ["v1"], rank: 1)
        ])
        defer { try? dict.close() }
        let noteID = try await insertVocabularyNote(
            headword: "食べる", reading: "たべる",
            contextEntryID: 42, contextDictVersion: "ctx-v")
        let summary = try await makeService(dictQueue: dict).run()
        XCTAssertEqual(summary.scanned, 1)
        XCTAssertEqual(summary.linkedJmdict, 1)

        let rows = try await linkRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].noteID, noteID)
        XCTAssertEqual(rows[0].provider, "jmdict")
        XCTAssertEqual(rows[0].entryID, 42)
        XCTAssertEqual(rows[0].origin, "backfill")
        XCTAssertEqual(rows[0].status, "resolved")
        // 词典版本优先取 context 快照
        let versionAtResolution = try await pool.read { db -> String? in
            let row = try Row.fetchOne(db, sql: """
                SELECT dictionary_version_at_resolution FROM lexemes
                JOIN lexeme_note_links l ON l.lexeme_id = lexemes.id
                WHERE l.note_id = ?
                """, arguments: [DatabaseValueCodec.encode(noteID)])
            return row?["dictionary_version_at_resolution"]
        }
        XCTAssertEqual(versionAtResolution, "ctx-v")
    }

    /// 档 2：无 source_context，headword 严格唯一候选 → jmdict。
    func testStrictUniqueMatch() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 7, forms: ["見る"], readings: ["みる"],
                  pos: ["v1"], rank: 1)
        ])
        defer { try? dict.close() }
        let noteID = try await insertVocabularyNote(headword: "見る")
        let summary = try await makeService(dictQueue: dict).run()
        XCTAssertEqual(summary.linkedJmdict, 1)
        let rows = try await linkRows()
        XCTAssertEqual(rows[0].noteID, noteID)
        XCTAssertEqual(rows[0].entryID, 7)
    }

    /// 同形异音：两个 entry 共享表记，Note 读音消歧 → 正确 entry；
    /// 无读音 → local ambiguous + 照常关联（待确认语义由
    /// resolution_status 承载）。
    func testHomophoneReadingDisambiguation() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 10, forms: ["今日"], readings: ["きょう"],
                  pos: ["n"], rank: 1),
            .init(id: 11, forms: ["今日"], readings: ["こんにち"],
                  pos: ["n"], rank: 2),
        ])
        defer { try? dict.close() }
        let withReading = try await insertVocabularyNote(
            headword: "今日", reading: "こんにち")
        let withoutReading = try await insertVocabularyNote(headword: "今日")
        let summary = try await makeService(dictQueue: dict).run()
        XCTAssertEqual(summary.scanned, 2)
        XCTAssertEqual(summary.linkedJmdict, 1)
        XCTAssertEqual(summary.linkedLocalAmbiguous, 1)

        let rows = try await linkRows()
        let jRow = try XCTUnwrap(rows.first { $0.noteID == withReading })
        XCTAssertEqual(jRow.entryID, 11, "读音应选中 こんにち 的条目")
        let lRow = try XCTUnwrap(rows.first { $0.noteID == withoutReading })
        XCTAssertEqual(lRow.provider, "local")
        XCTAssertEqual(lRow.status, "ambiguous")

        // ambiguous 仍然 learning——有有效关联。
        let repo = GRDBVocabularyKnowledgeRepository(pool: pool)
        let localLexemeID = try await pool.read { db -> UUID in
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT lexeme_id FROM lexeme_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(withoutReading)]))
            return try DatabaseValueCodec.decodeUUID(row["lexeme_id"])
        }
        let localState = try await repo.state(lexemeID: localLexemeID)
        XCTAssertEqual(localState, .learning)
    }

    /// 档 3：词典无候选 → local unresolved + 关联（learning）。
    func testOOVFallsToLocalUnresolved() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 1, forms: ["走る"], readings: ["はしる"],
                  pos: ["v5r"], rank: 1)
        ])
        defer { try? dict.close() }
        let noteID = try await insertVocabularyNote(
            headword: "グスコーブドリ", reading: "ぐすこーぶどり")
        let summary = try await makeService(dictQueue: dict).run()
        XCTAssertEqual(summary.linkedLocalUnresolved, 1)
        let rows = try await linkRows()
        XCTAssertEqual(rows[0].noteID, noteID)
        XCTAssertEqual(rows[0].provider, "local")
        XCTAssertEqual(rows[0].status, "unresolved")
        XCTAssertEqual(rows[0].entryID, nil)
    }

    /// SourceContext 的 entryID 存在但读音不匹配 → 验证失败，
    /// 落严格匹配档（词典严格单候选则 jmdict，否则 local）。
    func testContextEntryIDMismatchFallsThrough() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 20, forms: ["橋"], readings: ["はし"], pos: ["n"], rank: 1),
            .init(id: 21, forms: ["箸"], readings: ["はし"], pos: ["n"], rank: 1),
        ])
        defer { try? dict.close() }
        // context 指向 橋(20)，但 Note 表记是 箸 → 验证失败；
        // 严格匹配 箸 唯一命中 21 → jmdict 21。
        let noteID = try await insertVocabularyNote(
            headword: "箸", reading: "はし", contextEntryID: 20)
        let summary = try await makeService(dictQueue: dict).run()
        XCTAssertEqual(summary.linkedJmdict, 1)
        let rows = try await linkRows()
        XCTAssertEqual(rows[0].entryID, 21)
    }

    /// 幂等：重跑不重复建 link/lexeme；已有 link 的 Note 计入
    /// skipped；同 opID 重跑直接回放 receipt。
    func testIdempotentRerunAndReceipt() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 30, forms: ["読む"], readings: ["よむ"],
                  pos: ["v5m"], rank: 1)
        ])
        defer { try? dict.close() }
        try await insertVocabularyNote(headword: "読む")
        let service = makeService(dictQueue: dict)
        let s1 = try await service.run()
        XCTAssertEqual(s1.linkedJmdict, 1)
        let lexemeCount1 = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lexemes")
        }
        // 新 opID 重跑：NOT EXISTS 预过滤 → 该 Note 根本不进 page。
        let s2 = try await service.run()
        XCTAssertEqual(s2.scanned, 0)
        XCTAssertEqual(s2.linkedJmdict, 0)
        let lexemeCount2 = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lexemes")
        }
        XCTAssertEqual(lexemeCount1, lexemeCount2)
        let linkRowCount1 = try await linkRows().count
        XCTAssertEqual(linkRowCount1, 1)
        // 同 opID 回放 → replayedReceipt。
        let s3 = try await service.run(operationID: s1.operationID)
        XCTAssertTrue(s3.replayedReceipt)
        // receipt 存在
        let receiptKind = try await pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT kind FROM reader_mining_receipts
                    WHERE operation_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(s1.operationID)])
        }
        XCTAssertEqual(receiptKind, "lexeme_backfill")
    }

    /// 取消：预取消的 Task 立即抛 CancellationError，不写任何行。
    func testCancellationBeforeFirstBatch() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 40, forms: ["見る"], readings: ["みる"],
                  pos: ["v1"], rank: 1)
        ])
        defer { try? dict.close() }
        try await insertVocabularyNote(headword: "見る")
        let service = makeService(dictQueue: dict)
        let task = Task {
            try await service.run()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消应抛出")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let linkRowCount2 = try await linkRows().count
        XCTAssertEqual(linkRowCount2, 0)
    }

    /// 分批：batchSize=1 强制多批；批间取消 → 已提交批保留，
    /// 续跑补齐（幂等续接证据）。
    func testBatchedCommitAndResume() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 50, forms: ["走る"], readings: ["はしる"],
                  pos: ["v5r"], rank: 1),
            .init(id: 51, forms: ["泳ぐ"], readings: ["およぐ"],
                  pos: ["v5g"], rank: 1),
            .init(id: 52, forms: ["読む"], readings: ["よむ"],
                  pos: ["v5m"], rank: 1),
        ])
        defer { try? dict.close() }
        try await insertVocabularyNote(headword: "走る")
        try await insertVocabularyNote(headword: "泳ぐ")
        try await insertVocabularyNote(headword: "読む")

        // 第一轮：verifier 包装——第一批后 cancel 当前 task。
        let cancellingVerifier = CancellingVerifier(
            wrapped: GRDBLexemeEntryVerifier(
                reader: dict, datasetVersion: "test-dict"),
            cancelAfterCalls: 1)
        let service = LexemeBackfillService(
            pool: pool,
            resolver: GRDBMorphologyCandidateResolver(
                reader: dict, datasetVersion: "test-dict"),
            verifier: cancellingVerifier,
            batchSize: 1)
        do {
            _ = try await service.run()
            XCTFail("应在第二批前取消")
        } catch is CancellationError {
        }
        let firstCommitted = try await linkRows().count
        XCTAssertEqual(firstCommitted, 1, "第一批应已提交")

        // 续跑（新服务实例、不取消）→ 补齐剩余。
        let s2 = try await makeService(dictQueue: dict, batchSize: 1).run()
        XCTAssertEqual(s2.linkedJmdict, 2)
        let linkRowCount3 = try await linkRows().count
        XCTAssertEqual(linkRowCount3, 3)
    }

    /// 并发：两个 run 并发执行不撕数据——actor 串行化后第二个
    /// 看到的是已提交结果（幂等）。
    func testConcurrentRunsAreSafe() async throws {
        let dict = try MorphologyTestSupport.makeDictionary(entries: [
            .init(id: 60, forms: ["行く"], readings: ["いく"],
                  pos: ["v5k-s"], rank: 1)
        ])
        defer { try? dict.close() }
        try await insertVocabularyNote(headword: "行く")
        let service = makeService(dictQueue: dict)
        async let r1 = service.run()
        async let r2 = service.run()
        let (s1, s2) = try await (r1, r2)
        // 串行化：一个真跑一个空扫（NOT EXISTS 预过滤），总量正确。
        XCTAssertEqual(s1.linkedJmdict + s2.linkedJmdict, 1)
        let linkRowCount4 = try await linkRows().count
        XCTAssertEqual(linkRowCount4, 1)
    }
}

/// 调用第 N 次 `entrySurfaces` 后取消当前 Task——用于覆盖
/// 「批间取消」路径。
private final class CancellingVerifier: LexemeEntryVerifier, @unchecked Sendable {
    let wrapped: GRDBLexemeEntryVerifier
    let cancelAfterCalls: Int
    private var calls = 0
    private let lock = NSLock()

    init(wrapped: GRDBLexemeEntryVerifier, cancelAfterCalls: Int) {
        self.wrapped = wrapped
        self.cancelAfterCalls = cancelAfterCalls
    }

    func entrySurfaces(
        entryIDs: [Int64]
    ) async throws -> [Int64: LexemeEntrySurface] {
        let shouldCancel = lock.withLock {
            calls += 1
            return calls > cancelAfterCalls
        }
        if shouldCancel {
            // 无 handle 可握——用 while 轮询 currentTask cancel 不可行；
            // 直接抛 CancellationError 等价批间取消点语义。
            throw CancellationError()
        }
        return try await wrapped.entrySurfaces(entryIDs: entryIDs)
    }

    func datasetVersion() async throws -> String? {
        try await wrapped.datasetVersion()
    }
}
