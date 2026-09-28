import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v17 → v18（v0.7.0，设计 §6.3/§11.2/§13）：lexemes、lexeme_note_links、
/// vocabulary_knowledge_overrides、reader_activity_events、
/// reader_mining_receipts、reader_coverage_snapshots。
///
/// `v18_lexical_knowledge` 的注册由主 agent 接线到 `OboeDatabase.swift`
/// ——本测试用独立 `DatabaseMigrator` 直接注册 `GRDBKnowledgeSchema.migrate`，
/// 两种接线状态下都跑通（与 v17 测试同款策略）。
final class OboeSchemaV18MigrationTests: XCTestCase {

    private static let v18ID = "v18_lexical_knowledge"
    private static let v18Tables = [
        "lexemes", "lexeme_note_links", "vocabulary_knowledge_overrides",
        "reader_activity_events", "reader_mining_receipts",
        "reader_coverage_snapshots",
    ]

    // MARK: - 空库 / 升级

    /// v17 既有数据在 v18 后原样保留；六张新表为空；
    /// integrity + foreign_key_check 干净。
    func testPopulatedV17SurvivesUpgrade() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let deckID = UUID()
        let noteID = UUID()

        try stageDatabase(at: location.file, through: "v17_reader_foundation") { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, '测试牌组', 0, ?, ?)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID), nowMs, nowMs])
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, content_version,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', '見る', '看', 0,
                            'manual', 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID), nowMs, nowMs
                ])
        }

        let database = try openMigratedToV18(at: location.file)
        defer { try? database.close() }
        try database.pool.read { db in
            for table in Self.v18Tables {
                XCTAssertTrue(try db.tableExists(table), "\(table) 必须存在")
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0, "\(table) 升级后必须为空")
            }
            // 旧数据保留
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT headword FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                "見る")
            let applied = try DatabaseMigrator()
                .appliedIdentifiers(db)
            XCTAssertTrue(applied.contains(Self.v18ID))
        }
        let integrity = try database.pool.read { db in
            (
                try String.fetchAll(db, sql: "PRAGMA integrity_check"),
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            )
        }
        XCTAssertEqual(integrity.0, ["ok"])
        XCTAssertTrue(integrity.1.isEmpty)
    }

    // MARK: - 约束与级联

    /// identity_key UNIQUE、provider/entry_id 一致性 CHECK、
    /// link 双向 CASCADE、override 随 lexeme 级联、事件弱引用 SET NULL。
    func testConstraintsAndCascades() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV18(at: location.file)
        defer { try? database.close() }

        let deckID = UUID()
        let noteID = UUID()
        let lexemeID = UUID()
        let encode: (UUID) -> String = DatabaseValueCodec.encode

        try database.pool.write { db in
            let nowMs: Int64 = 1_000
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, 'd', 0, ?, ?)
                    """,
                arguments: [encode(deckID), nowMs, nowMs])
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, content_version,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', '食べる', '吃', 0,
                            'manual', 1, ?, ?)
                    """,
                arguments: [encode(noteID), encode(deckID), nowMs, nowMs])
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id, written_form,
                        reading, normalized_lemma, pos_family, identity_key,
                        resolution_status, created_at_ms
                    ) VALUES (?, 'jmdict', '1578850', 1578850, '食べる',
                              'たべる', 'たべる', 'v1', 'jmdict|1578850|たべる|たべる',
                              'resolved', ?)
                    """,
                arguments: [encode(lexemeID), nowMs])
        }

        // identity_key UNIQUE
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id, written_form,
                        normalized_lemma, identity_key, resolution_status,
                        created_at_ms
                    ) VALUES (?, 'jmdict', '1578850', 1578850, '喰べる',
                              'たべる', 'jmdict|1578850|たべる|たべる',
                              'resolved', 1)
                    """,
                arguments: [encode(UUID())])
        })
        // jmdict provider 必须有 entry_id
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, written_form,
                        normalized_lemma, identity_key, resolution_status,
                        created_at_ms
                    ) VALUES (?, 'jmdict', 'x', '詞', 'し',
                              'jmdict|x|し|', 'resolved', 1)
                    """,
                arguments: [encode(UUID())])
        })
        // link 非法 origin 拒绝
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin, created_at_ms
                    ) VALUES (?, ?, 'guessed', 1)
                    """,
                arguments: [encode(lexemeID), encode(noteID)])
        })
        // override 非 known/ignored 拒绝
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO vocabulary_knowledge_overrides(
                        lexeme_id, state, updated_at_ms
                    ) VALUES (?, 'learning', 1)
                    """,
                arguments: [encode(lexemeID)])
        })
        // event 非冻结 kind 拒绝
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_activity_events(
                        id, operation_id, kind, created_at_ms
                    ) VALUES (?, ?, 'markedIgnored', 1)
                    """,
                arguments: [encode(UUID()), encode(UUID())])
        })
        // coverage snapshot upsert key 冲突拒绝
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_coverage_snapshots(
                        id, document_id, scope_key, content_hash,
                        metric_version, morphology_version,
                        known_count, learning_count, unknown_count,
                        ignored_count, unique_numerator, unique_denominator,
                        analyzed_blocks, total_blocks,
                        study_day_id, created_at_ms
                    ) VALUES (?, 'doc-1', 'document', 'h', 'm1', 'morph1',
                              1, 2, 3, 0, 2, 5, 4, 4, 'sd-1', 1)
                    """,
                arguments: [encode(UUID())])
        }
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_coverage_snapshots(
                        id, document_id, scope_key, content_hash,
                        metric_version, morphology_version,
                        known_count, learning_count, unknown_count,
                        ignored_count, unique_numerator, unique_denominator,
                        analyzed_blocks, total_blocks,
                        study_day_id, created_at_ms
                    ) VALUES (?, 'doc-1', 'document', 'h2', 'm1', 'morph1',
                              0, 0, 0, 0, 0, 0, 4, 4, 'sd-1', 2)
                    """,
                arguments: [encode(UUID())])
        })

        // 正常写入 link + override + event
        let eventID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin, created_at_ms
                    ) VALUES (?, ?, 'backfill', 1)
                    """,
                arguments: [encode(lexemeID), encode(noteID)])
            try db.execute(
                sql: """
                    INSERT INTO vocabulary_knowledge_overrides(
                        lexeme_id, state, updated_at_ms
                    ) VALUES (?, 'known', 1)
                    """,
                arguments: [encode(lexemeID)])
            try db.execute(
                sql: """
                    INSERT INTO reader_activity_events(
                        id, operation_id, kind, lexeme_id, note_id,
                        created_at_ms
                    ) VALUES (?, ?, 'markedKnown', ?, ?, 1)
                    """,
                arguments: [
                    encode(eventID), encode(UUID()), encode(lexemeID),
                    encode(noteID)
                ])
        }

        // Note 删除：link 级联失效、lexeme 保留、事件弱引用 SET NULL。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [encode(noteID)])
        }
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexeme_note_links"), 0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lexemes"), 1,
                "Note 删除不陪葬 lexeme")
            // override 随 lexeme（lexeme 还在 → override 还在）
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vocabulary_knowledge_overrides"),
                1)
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT note_id, lexeme_id FROM reader_activity_events"))
            let noteRef: String? = row["note_id"]
            XCTAssertNil(noteRef, "事件 note_id 应 SET NULL")
            XCTAssertNotNil(row["lexeme_id"] as String?)
        }

        // lexeme 删除：link/override 级联、事件 lexeme_id SET NULL。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM lexemes WHERE id = ?",
                arguments: [encode(lexemeID)])
        }
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vocabulary_knowledge_overrides"),
                0)
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT lexeme_id FROM reader_activity_events"))
            XCTAssertNil(row["lexeme_id"] as String?)
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: - 工具

    private func openMigratedToV18(at file: URL) throws -> OboeDatabase {
        // 第一阶段：v17 前缀迁移（已注册的标识符）。
        let v17Prefix = Array(
            OboeDatabaseSchema.migrationIdentifiers.prefix(
                through: OboeDatabaseSchema.migrationIdentifiers
                    .firstIndex(of: "v17_reader_foundation")!))
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
        let pool = try DatabasePool(path: file.path, configuration: config)
        try OboeDatabaseSchema
            .makeMigrator(applying: v17Prefix)
            .migrate(pool)
        // 第二阶段：v18 直接用本文件的 migrator 注册（主 agent 未接线
        // 时也能跑；接线后行为一致——同一 migrate 函数幂等执行）。
        var migrator = DatabaseMigrator()
        migrator.registerMigration(
            Self.v18ID, migrate: GRDBKnowledgeSchema.migrate)
        try migrator.migrate(pool)
        return OboeDatabase(pool: pool)
    }

    private func stageDatabase(
        at file: URL,
        through lastIdentifier: String,
        seed: (Database) throws -> Void
    ) throws {
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
        let prefix = Array(
            OboeDatabaseSchema.migrationIdentifiers.prefix(
                through: OboeDatabaseSchema.migrationIdentifiers
                    .firstIndex(of: lastIdentifier)!))
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        try OboeDatabaseSchema.makeMigrator(applying: prefix).migrate(queue)
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
                "OboeSchemaV18-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite"))
    }
}
