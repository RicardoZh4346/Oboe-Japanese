import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v24 → v25（v0.7.5 S11）：`reader_study_occurrences`、
/// `reader_translation_blocks`、`ai_study_jobs`、`ai_study_job_blocks`、
/// `ai_study_resolutions`、`ai_study_selections`、`ai_study_receipts`、
/// `ai_study_cache`。
///
/// 断言面：建表与索引、枚举 CHECK、唯一性（活跃 Job/当前译文/
/// action_key/块键/resolution 修订/occurrence 锚点/selection PK）、
/// FK CASCADE/SET NULL、json_valid 有界校验、`ai_study_cache`
/// 不入 v9 备份白名单。
final class GRDBAIStudyPipelineSchemaTests: XCTestCase {

    private static let v25ID = "v25_ai_study_pipeline"
    private static let v25Tables = GRDBAIStudyPipelineSchema.tableNames

    // MARK: - 建表 / 升级

    /// 字面空库直接建表成功——八张表与关键索引全部存在。
    func testEmptyDatabaseMigrationCreatesTables() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let pool = try DatabasePool(
            path: location.file.path, configuration: makeConfiguration())
        defer { try? pool.close() }

        var migrator = DatabaseMigrator()
        migrator.registerMigration(
            Self.v25ID, migrate: GRDBAIStudyPipelineSchema.migrate)
        try migrator.migrate(pool)

        try pool.read { db in
            for table in Self.v25Tables {
                XCTAssertTrue(try db.tableExists(table), "\(table) 必须存在")
            }
            for index in [
                "reader_occurrences_by_unit",
                "reader_occurrences_by_document",
                "reader_translation_one_current",
                "reader_translation_by_document",
                "ai_study_jobs_one_active_per_document",
                "ai_study_jobs_by_document",
                "ai_study_blocks_ready",
                "ai_study_resolutions_by_job",
                "ai_study_resolutions_by_document",
                "ai_study_selections_by_job",
                "ai_study_cache_lru",
            ] {
                XCTAssertNotNil(
                    try String.fetchOne(
                        db,
                        sql: """
                            SELECT name FROM sqlite_master
                            WHERE type = 'index' AND name = ?
                            """,
                        arguments: [index]),
                    "\(index) 必须存在")
            }
        }
    }

    /// v24 既有数据升级到 v25 后原样保留；八张新表为空；
    /// integrity + foreign_key_check 干净。
    func testPopulatedV24SurvivesUpgrade() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let deckID = UUID()
        let documentID = UUID()
        let unitID = UUID()

        try stageDatabase(
            at: location.file, through: "v24_reader_study_binding"
        ) { db in
            try Self.insertDeck(id: deckID, in: db)
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertUnit(id: unitID, in: db)
        }

        let database = try openMigratedToV25(at: location.file)
        try database.pool.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT title FROM reader_documents WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(documentID)]),
                "测试文档")
            for table in Self.v25Tables {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM \(table)"), 0,
                    "\(table) 升级后应为空")
            }
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: - 唯一性约束

    /// 同一 document/revision 至多一个活跃 Job；终态后允许再起新 Job。
    func testOneActiveJobPerDocumentRevision() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertJob(
                id: UUID(), documentID: documentID, status: "analyzing",
                in: db)
            XCTAssertThrowsError(try Self.insertJob(
                id: UUID(), documentID: documentID, status: "pending",
                in: db), "同 revision 第二个活跃 Job 必须被拒")
            // 另一 revision 的活跃 Job 允许。
            try Self.insertJob(
                id: UUID(), documentID: documentID, status: "pending",
                contentRevision: 2, in: db)
            // 第一个 Job 转终态后，同 revision 可再起。
            try db.execute(
                sql: """
                    UPDATE ai_study_jobs SET status = 'completed'
                    WHERE status = 'analyzing'
                    """)
            try Self.insertJob(
                id: UUID(), documentID: documentID, status: "pending",
                in: db)
        }
    }

    /// (document_id, locator_key, language) 至多一行 is_current=1；
    /// 旧译文转历史后新译文可接任。
    func testOneCurrentTranslationPerBlockLanguage() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertTranslation(
                id: UUID(), documentID: documentID, revision: 1,
                isCurrent: 1, in: db)
            XCTAssertThrowsError(try Self.insertTranslation(
                id: UUID(), documentID: documentID, revision: 2,
                isCurrent: 1, in: db), "同块同语言第二个 current 必须被拒")
            // 历史行（is_current=0）不冲突。
            try Self.insertTranslation(
                id: UUID(), documentID: documentID, revision: 2,
                isCurrent: 0, in: db)
        }
    }

    /// 译文（document,locator,source_hash,language,revision）唯一；
    /// receipt action_key 全局唯一；块 (job_id,subblock_key) 唯一；
    /// resolution (request_hash,token_key,revision) 唯一；
    /// selection PK(job_id,selection_revision,unit_key) 唯一。
    func testIdempotencyAndIdentityUniques() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()
        let jobID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertJob(
                id: jobID, documentID: documentID, status: "analyzing",
                in: db)

            // translation 五元组唯一。
            try Self.insertTranslation(
                id: UUID(), documentID: documentID, revision: 1,
                isCurrent: 1, in: db)
            XCTAssertThrowsError(try Self.insertTranslation(
                id: UUID(), documentID: documentID, revision: 1,
                isCurrent: 0, in: db), "相同五元组译文必须被拒")

            // receipt action_key 唯一（幂等锚点）。
            try Self.insertReceipt(
                operationID: UUID(), actionKey: "job:x:u1:v1",
                in: db)
            XCTAssertThrowsError(try Self.insertReceipt(
                operationID: UUID(), actionKey: "job:x:u1:v1",
                in: db), "重复 action_key 必须被拒")

            // 块 (job_id, subblock_key) 唯一。
            try Self.insertBlock(
                id: UUID(), jobID: jobID, subblockKey: "b0", in: db)
            XCTAssertThrowsError(try Self.insertBlock(
                id: UUID(), jobID: jobID, subblockKey: "b0",
                in: db), "重复 subblock_key 必须被拒")

            // resolution (request_hash, token_key, revision) 唯一。
            try Self.insertResolution(
                id: UUID(), jobID: jobID, revision: 0, in: db)
            XCTAssertThrowsError(try Self.insertResolution(
                id: UUID(), jobID: jobID, revision: 0,
                in: db), "同 token 同 revision 重复必须被拒")
            try Self.insertResolution(
                id: UUID(), jobID: jobID, revision: 1, in: db)

            // selection 复合主键唯一。
            try Self.insertSelection(
                jobID: jobID, unitKey: "jmdict:sense-v1:0001",
                revision: 1, in: db)
            XCTAssertThrowsError(try Self.insertSelection(
                jobID: jobID, unitKey: "jmdict:sense-v1:0001",
                revision: 1, in: db), "重复选择修订必须被拒")
        }
    }

    /// occurrence 锚点 (document,content_revision,locator,tokenizer,
    /// range) 唯一。
    func testOccurrenceAnchorUnique() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertOccurrence(
                id: UUID(), documentID: documentID, in: db)
            XCTAssertThrowsError(try Self.insertOccurrence(
                id: UUID(), documentID: documentID,
                in: db), "相同锚点 occurrence 必须被拒")
            // 不同 range 允许。
            try Self.insertOccurrence(
                id: UUID(), documentID: documentID, startUTF16: 20,
                in: db)
        }
    }

    // MARK: - 枚举 / CHECK / JSON

    /// Job/块/决策/resolution 枚举与 JSON 列的 CHECK 约束。
    func testEnumAndJSONChecks() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()
        let jobID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertJob(
                id: jobID, documentID: documentID, status: "analyzing",
                in: db)

            // 非法 Job status。
            XCTAssertThrowsError(try db.execute(
                sql: """
                    UPDATE ai_study_jobs SET status = 'bogus'
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)]))

            // 非法块 status。
            XCTAssertThrowsError(try Self.insertBlock(
                id: UUID(), jobID: jobID, subblockKey: "bad",
                status: "bogus", in: db))

            // 非法 decision。
            XCTAssertThrowsError(try Self.insertSelection(
                jobID: jobID, unitKey: "k:bad", revision: 1,
                decision: "bogus", in: db))

            // 非法 resolution status / origin。
            XCTAssertThrowsError(try Self.insertResolution(
                id: UUID(), jobID: jobID, revision: 9,
                status: "bogus", in: db))
            XCTAssertThrowsError(try Self.insertResolution(
                id: UUID(), jobID: jobID, revision: 9,
                origin: "bogus", in: db))

            // confidence 越界。
            XCTAssertThrowsError(try Self.insertResolution(
                id: UUID(), jobID: jobID, revision: 9,
                confidence: 1.5, in: db))

            // scope_json 非 JSON。
            XCTAssertThrowsError(try db.execute(
                sql: """
                    UPDATE ai_study_jobs SET scope_json = 'not-json'
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)]))

            // locator_json 非 JSON（occurrence）。
            XCTAssertThrowsError(try db.execute(
                sql: """
                    INSERT INTO reader_study_occurrences(
                        id, document_id, content_revision, locator_json,
                        block_source_hash, tokenizer_version,
                        start_utf16, length_utf16, resolution_status)
                    VALUES (?, ?, 1, 'not-json', 'h', 'tok-1', 0, 1,
                            'pending')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID)
                ]))
        }
    }

    // MARK: - 外键行为

    /// document 删除级联 occurrences/translations/jobs；job 删除级联
    /// blocks/selections；resolution 的 job/unit 引用 SET NULL 留史。
    func testCascadeAndSetNullBehavior() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()
        let jobID = UUID()
        let blockID = UUID()
        let resolutionID = UUID()
        let unitID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertUnit(id: unitID, in: db)
            try Self.insertJob(
                id: jobID, documentID: documentID, status: "analyzing",
                in: db)
            try Self.insertBlock(
                id: blockID, jobID: jobID, subblockKey: "b0", in: db)
            try Self.insertSelection(
                jobID: jobID, unitKey: "k1", revision: 1, in: db)
            try Self.insertResolution(
                id: resolutionID, jobID: jobID, revision: 0,
                unitID: unitID, in: db)
            try Self.insertOccurrence(
                id: UUID(), documentID: documentID,
                unitID: unitID, in: db)
            try Self.insertTranslation(
                id: UUID(), documentID: documentID, revision: 1,
                isCurrent: 1, in: db)

            // 删 job：blocks/selections 级联，resolution 的 job_id SET NULL。
            try db.execute(
                sql: "DELETE FROM ai_study_jobs WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(jobID)])
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ai_study_job_blocks"), 0)
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ai_study_selections"), 0)
            let resolutionRow = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT job_id, unit_id FROM ai_study_resolutions
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(resolutionID)]))
            XCTAssertNil(resolutionRow["job_id"] as String?)
            XCTAssertEqual(
                resolutionRow["unit_id"] as String?,
                DatabaseValueCodec.encode(unitID),
                "unit 仍在时 unit_id 保持")

            // 删 unit：resolution.unit_id 与 occurrence.unit_id SET NULL。
            try db.execute(
                sql: "DELETE FROM lexical_learning_units WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(unitID)])
            let orphaned = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT unit_id FROM ai_study_resolutions
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(resolutionID)]))
            XCTAssertNil(orphaned["unit_id"] as String?)
            let occurrenceRow = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT unit_id FROM reader_study_occurrences
                    LIMIT 1
                    """))
            XCTAssertNil(occurrenceRow["unit_id"] as String?)

            // 删 document：occurrence/translation 级联，resolution
            // document_id SET NULL 留史。
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(documentID)])
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_study_occurrences"), 0)
            XCTAssertEqual(try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_translation_blocks"), 0)
            let historyRow = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT document_id FROM ai_study_resolutions
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(resolutionID)]))
            XCTAssertNil(historyRow["document_id"] as String?)
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    /// Job.study_deck_id 引用 decks SET NULL——删牌组后 Job 保留。
    func testJobStudyDeckSetNull() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV25(at: location.file)
        let documentID = UUID()
        let deckID = UUID()
        let jobID = UUID()

        try database.pool.write { db in
            try Self.insertDocument(id: documentID, in: db)
            try Self.insertDeck(id: deckID, in: db)
            try Self.insertJob(
                id: jobID, documentID: documentID, status: "analyzing",
                studyDeckID: deckID, in: db)
            try db.execute(
                sql: "DELETE FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)])
            let row = try XCTUnwrap(Row.fetchOne(
                db, sql: """
                    SELECT study_deck_id FROM ai_study_jobs WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)]))
            XCTAssertNil(row["study_deck_id"] as String?)
        }
    }

    // MARK: - 备份白名单

    /// `ai_study_cache` 是本机 LRU 表：存在于 schema 但不入 v9
    /// 白名单；其余七张 v25 表全部在白名单中。
    func testCacheExcludedFromV9Whitelist() throws {
        let backupTables = Set(
            PortableBackupFormatV9.tableSpecifications.map(\.tableName))
        XCTAssertFalse(
            backupTables.contains("ai_study_cache"),
            "ai_study_cache 不得入 v9 白名单")
        for table in Self.v25Tables where table != "ai_study_cache" {
            XCTAssertTrue(
                backupTables.contains(table), "\(table) 必须入 v9 白名单")
        }
    }

    // MARK: - 工具（本文件私有）

    private func makeConfiguration() -> Configuration {
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
        return configuration
    }

    /// v1–v25 全量迁移（v25 已接线到 OboeDatabase）。
    private func openMigratedToV25(at file: URL) throws -> OboeDatabase {
        let pool = try DatabasePool(
            path: file.path, configuration: makeConfiguration())
        try OboeDatabaseSchema
            .makeMigrator(
                applying: OboeDatabaseSchema.migrationIdentifiers)
            .migrate(pool)
        return OboeDatabase(pool: pool)
    }

    private func stageDatabase(
        at file: URL,
        through lastIdentifier: String,
        seed: (Database) throws -> Void
    ) throws {
        let prefix = Array(
            OboeDatabaseSchema.migrationIdentifiers.prefix(
                through: OboeDatabaseSchema.migrationIdentifiers
                    .firstIndex(of: lastIdentifier)!))
        let queue = try DatabaseQueue(
            path: file.path, configuration: makeConfiguration())
        try OboeDatabaseSchema.makeMigrator(applying: prefix)
            .migrate(queue)
        try queue.write(seed)
        try queue.close()
    }

    private struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBAIStudyPipeline-\(UUID().uuidString)",
                isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite"))
    }

    // MARK: - 行插入助手

    private static func insertDeck(id: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order,
                                  created_at_ms, updated_at_ms)
                VALUES (?, ?, 0, 1, 1)
                """,
            arguments: [DatabaseValueCodec.encode(id), "测试牌组"])
    }

    private static func insertDocument(
        id: UUID, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_documents(
                    id, title, format, created_at_ms, source_sha256,
                    canonical_text_hash, parser_version, availability)
                VALUES (?, '测试文档', 'paste', 1,
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        'hash1', 'parser-1', 'available')
                """,
            arguments: [DatabaseValueCodec.encode(id)])
    }

    private static func insertUnit(id: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms)
                VALUES (?, 'localNote', ?, '食べる', 'current', 1, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                "local-note:\(id.uuidString.lowercased())",
            ])
    }

    private static func insertJob(
        id: UUID, documentID: UUID, status: String,
        contentRevision: Int = 1, studyDeckID: UUID? = nil,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_jobs(
                    id, document_id, study_deck_id, scope_json,
                    input_fingerprint, content_revision,
                    provider_snapshot_json, model, pipeline_version,
                    prompt_version, policy_version, status,
                    created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, '{"kind":"fullDocument"}', 'fp', ?,
                        '{"provider":"fake"}', 'fake-model', 'pipe-1',
                        'ai-study-prompt-v1', 'policy-1', ?, 1, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(documentID),
                studyDeckID.map(DatabaseValueCodec.encode),
                contentRevision,
                status,
            ])
    }

    private static func insertBlock(
        id: UUID, jobID: UUID, subblockKey: String,
        status: String = "pending", in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_job_blocks(
                    id, job_id, locator_json, source_hash, subblock_key,
                    candidate_set_hash, request_hash, status)
                VALUES (?, ?, '{"block":0}', 'sh', ?, 'csh', 'rh', ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(jobID),
                subblockKey, status,
            ])
    }

    private static func insertResolution(
        id: UUID, jobID: UUID, revision: Int,
        status: String = "aiResolved", origin: String = "ai",
        confidence: Double? = nil, unitID: UUID? = nil,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_resolutions(
                    id, job_id, locator_json, token_key, request_hash,
                    unit_id, confidence, status, origin, revision,
                    created_at_ms)
                VALUES (?, ?, '{"block":0,"token":0}', 'tok-1', 'rh',
                        ?, ?, ?, ?, ?, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(jobID),
                unitID.map(DatabaseValueCodec.encode),
                confidence, status, origin, revision,
            ])
    }

    private static func insertSelection(
        jobID: UUID, unitKey: String, revision: Int,
        decision: String = "pending", in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_selections(
                    job_id, unit_key, selection_revision, decision)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(jobID), unitKey, revision,
                decision,
            ])
    }

    private static func insertReceipt(
        operationID: UUID, actionKey: String, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO ai_study_receipts(
                    operation_id, action_key, payload_hash,
                    outcome_json, committed_at_ms)
                VALUES (?, ?, 'ph', '{}', 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(operationID), actionKey,
            ])
    }

    private static func insertOccurrence(
        id: UUID, documentID: UUID, startUTF16: Int = 0,
        unitID: UUID? = nil, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_study_occurrences(
                    id, document_id, content_revision, locator_json,
                    block_source_hash, tokenizer_version,
                    start_utf16, length_utf16, unit_id, resolution_status)
                VALUES (?, ?, 1, '{"block":0}', 'bsh', 'tok-1',
                        ?, 3, ?, 'pending')
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(documentID),
                startUTF16,
                unitID.map(DatabaseValueCodec.encode),
            ])
    }

    private static func insertTranslation(
        id: UUID, documentID: UUID, revision: Int, isCurrent: Int,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_translation_blocks(
                    id, document_id, locator_key, locator_json,
                    source_hash, translation_revision, translated_text,
                    language, is_current, created_at_ms)
                VALUES (?, ?, 'blk-0', '{"block":0}', 'src-h', ?,
                        '译文', 'zh-Hans', ?, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(documentID),
                revision, isCurrent,
            ])
    }
}
