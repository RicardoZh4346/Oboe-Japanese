import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v22 → v23（v0.7.5 S04）：`lexical_learning_units`、
/// `learning_unit_dictionary_aliases`、`learning_unit_note_links`、
/// `learning_unit_flags`、`learning_unit_events`、
/// `learning_unit_migration_items`。
///
/// `v23_learning_units` 的注册由 M 接线到 `OboeDatabase.swift`——本
/// 测试用独立 `DatabaseMigrator` 直接注册 `GRDBLearningUnitSchema.migrate`
/// （与 OboeSchemaV18MigrationTests 同款策略，两种接线状态下都跑通）。
final class GRDBLearningUnitSchemaTests: XCTestCase {

    private static let v23ID = "v23_learning_units"
    private static let v23Tables = GRDBLearningUnitSchema.tableNames

    // MARK: - 空库 / 升级

    /// 字面空库（零迁移基础）直接建表成功——CREATE TABLE 的 FK 引用在
    /// SQLite 建表期不校验父表存在性，FK 在 DML/foreign_key_check 时生效。
    func testEmptyDatabaseMigrationCreatesTables() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let pool = try DatabasePool(
            path: location.file.path, configuration: makeConfiguration())
        defer { try? pool.close() }

        var migrator = DatabaseMigrator()
        migrator.registerMigration(
            Self.v23ID, migrate: GRDBLearningUnitSchema.migrate)
        try migrator.migrate(pool)

        try pool.read { db in
            for table in Self.v23Tables {
                XCTAssertTrue(try db.tableExists(table), "\(table) 必须存在")
            }
            // 关键索引存在。
            for index in [
                "learning_unit_one_primary",
                "learning_unit_notes_by_unit",
                "learning_units_on_binding_status",
                "learning_unit_aliases_on_unit",
                "learning_unit_events_on_unit",
                "learning_unit_migration_items_on_status",
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

    /// v22 既有数据在 v23 后原样保留；六张新表为空；integrity +
    /// foreign_key_check 干净。
    func testPopulatedV22SurvivesUpgrade() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let deckID = UUID()
        let noteID = UUID()
        let lexemeID = UUID()

        try stageDatabase(at: location.file, through: "v22_dictionary_knowledge") { db in
            let nowMs: Int64 = 1_000
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
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id, written_form,
                        normalized_lemma, identity_key, resolution_status,
                        created_at_ms
                    ) VALUES (?, 'jmdict', '10001', 10001, '見る',
                              'みる', 'jmdict|10001|見る|みる', 'resolved', ?)
                    """,
                arguments: [DatabaseValueCodec.encode(lexemeID), nowMs])
        }

        let database = try openMigratedToV23(at: location.file)
        defer { try? database.close() }
        try database.pool.read { db in
            for table in Self.v23Tables {
                XCTAssertTrue(try db.tableExists(table), "\(table) 必须存在")
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0, "\(table) 升级后必须为空")
            }
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT headword FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                "見る")
            let applied = try DatabaseMigrator().appliedIdentifiers(db)
            XCTAssertTrue(applied.contains(Self.v23ID))
            XCTAssertTrue(applied.contains("v22_dictionary_knowledge"))
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

    /// 重复 migrate 语义（选定并说明）：`migrate(_ db:)` **不幂等**——
    /// 与 v17–v22 全部迁移一致，幂等性由 DatabaseMigrator 按标识符去重
    /// 保证。断言：同一 migrator 二次 migrate 为无害 no-op（标识符已
    /// 应用即跳过）；绕过 migrator 直接二次调 `migrate` 抛错。
    func testRepeatedMigrationSemantics() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let pool = try DatabasePool(
            path: location.file.path, configuration: makeConfiguration())
        defer { try? pool.close() }

        var migrator = DatabaseMigrator()
        migrator.registerMigration(
            Self.v23ID, migrate: GRDBLearningUnitSchema.migrate)
        try migrator.migrate(pool)
        // GRDB 语义：已应用标识符跳过——二次 migrate 无副作用不报错。
        try migrator.migrate(pool)

        // 直接二次执行 DDL：非幂等——CREATE TABLE 报已存在（选定行为，
        // 依赖 migrator 去重而非 IF NOT EXISTS，与全部已发布迁移一致）。
        XCTAssertThrowsError(
            try pool.write { db in
                try GRDBLearningUnitSchema.migrate(db)
            })
        try pool.read { db in
            XCTAssertTrue(try db.tableExists("lexical_learning_units"))
        }
    }

    /// schema rollback（D20）：迁移内某步失败整体回滚，不留半迁移。
    /// 注入「建完六表后再执行非法 SQL」的损坏迁移副本验证。
    func testMigrationRollsBackOnError() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let pool = try DatabasePool(
            path: location.file.path, configuration: makeConfiguration())
        defer { try? pool.close() }

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v23_learning_units_broken") { db in
            try GRDBLearningUnitSchema.migrate(db)
            try db.execute(
                sql: "INSERT INTO table_that_does_not_exist VALUES (1)")
        }
        XCTAssertThrowsError(try migrator.migrate(pool))
        try pool.read { db in
            for table in Self.v23Tables {
                XCTAssertFalse(
                    try db.tableExists(table),
                    "\(table) 不应残留——迁移必须整体回滚")
            }
            XCTAssertFalse(try DatabaseMigrator()
                .appliedIdentifiers(db)
                .contains("v23_learning_units_broken"))
        }
    }

    // MARK: - 约束与级联

    /// 冻结枚举/格式 CHECK + UNIQUE + FK 行为全覆盖。
    func testConstraintsAndCascades() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV23(at: location.file)
        defer { try? database.close() }

        let deckID = UUID()
        let noteID = UUID()
        let lexemeID = UUID()
        let unitID = UUID()
        let encode: (UUID) -> String = DatabaseValueCodec.encode
        let fingerprint = String(repeating: "a", count: 64)

        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, content_version,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', '食べる', '吃', 0,
                            'manual', 1, 1, 1)
                    """,
                arguments: [encode(noteID), encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id, written_form,
                        normalized_lemma, identity_key, resolution_status,
                        created_at_ms
                    ) VALUES (?, 'jmdict', '1578850', 1578850, '食べる',
                              'たべる', 'jmdict|1578850|食べる|たべる',
                              'resolved', 1)
                    """,
                arguments: [encode(lexemeID)])
            try db.execute(
                sql: """
                    INSERT INTO lexical_learning_units(
                        id, identity_kind, identity_key, provider,
                        dictionary_entry_id, semantic_fingerprint,
                        fingerprint_version, lemma, reading,
                        sense_snapshot_json, binding_status,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, 'dictionarySense',
                              'jmdict:sense-v1:1578850:\(fingerprint)',
                              'jmdict', 1578850, ?, 'sense-fp-1',
                              '食べる', 'たべる', '{"gloss":"to eat"}',
                              'current', 1, 1)
                    """,
                arguments: [encode(unitID), fingerprint])
        }

        // identity_kind / binding_status / lemma / 一致性 CHECK
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms
                ) VALUES (?, 'bogusKind', 'k-bad-1', 'x', 'current', 1, 1)
                """, arguments: [encode(UUID())])
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms
                ) VALUES (?, 'localNote', 'k-bad-2', 'x', 'bogusStatus', 1, 1)
                """, arguments: [encode(UUID())])
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms
                ) VALUES (?, 'localNote', 'k-bad-3', '   ', 'legacy', 1, 1)
                """, arguments: [encode(UUID())])
        })
        // dictionarySense 缺 provider/entry/fingerprint 三件套被拒
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms
                ) VALUES (?, 'dictionarySense', 'k-bad-4', 'x',
                          'current', 1, 1)
                """, arguments: [encode(UUID())])
        })
        // sense_snapshot_json：非法 JSON 与超界都被拒
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    sense_snapshot_json, binding_status,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'localNote', 'k-bad-5', 'x', '{broken',
                          'legacy', 1, 1)
                """, arguments: [encode(UUID())])
        })
        let oversized = "[" + String(repeating: "0", count: 17 * 1024) + "]"
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexical_learning_units(
                        id, identity_kind, identity_key, lemma,
                        sense_snapshot_json, binding_status,
                        created_at_ms, updated_at_ms
                    ) VALUES (?, 'localNote', 'k-bad-6', 'x', ?,
                              'legacy', 1, 1)
                    """,
                arguments: [encode(UUID()), oversized])
        })
        // identity_key UNIQUE
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms
                ) VALUES (?, 'localNote',
                          'jmdict:sense-v1:1578850:\(fingerprint)',
                          'dup', 'legacy', 1, 1)
                """, arguments: [encode(UUID())])
        })

        // 正常写入 alias / link / flag / event / migration item
        let secondNoteID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, content_version,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', '食べた', '吃了', 0,
                            'manual', 1, 1, 1)
                    """,
                arguments: [encode(secondNoteID), encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_dictionary_aliases(
                        unit_id, provider, dataset_version, entry_id,
                        sense_id, fingerprint, fingerprint_version,
                        status, resolved_at_ms
                    ) VALUES (?, 'jmdict', 'ds-2026-09', 1578850, 7,
                              ?, 'sense-fp-1', 'current', 1)
                    """,
                arguments: [encode(unitID), fingerprint])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'primary', 'userConfirmed', 1)
                    """,
                arguments: [encode(unitID), encode(noteID)])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'legacy_secondary', 'backfill', 2)
                    """,
                arguments: [encode(unitID), encode(secondNoteID)])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms
                    ) VALUES (?, 1, 3, 1)
                    """,
                arguments: [encode(unitID)])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_events(
                        id, operation_id, unit_id, unit_id_snapshot, kind,
                        after_json, payload_hash, created_at_ms
                    ) VALUES (?, ?, ?, ?, 'tooEasySet',
                              '{"revision":3,"tooEasy":true}', 'h1', 1)
                    """,
                arguments: [
                    encode(UUID()), encode(UUID()), encode(unitID),
                    encode(unitID)
                ])
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_migration_items(
                        source_key, note_id, legacy_lexeme_id, old_state,
                        status, evidence_json, target_unit_id
                    ) VALUES ('override:test', ?, ?, 'known',
                              'needsConfirmation', '{"a":1}', ?)
                    """,
                arguments: [encode(noteID), encode(lexemeID), encode(unitID)])
        }

        // alias 四元组 UNIQUE
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_dictionary_aliases(
                        unit_id, provider, dataset_version, entry_id,
                        sense_id, fingerprint, fingerprint_version, status
                    ) VALUES (?, 'jmdict', 'ds-2026-09', 1578850, 7,
                              ?, 'sense-fp-1', 'current')
                    """,
                arguments: [encode(UUID()), fingerprint])
        })
        // alias status 冻结四态：superseded 允许（rev2），bogus 拒绝
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_dictionary_aliases(
                        unit_id, provider, dataset_version, entry_id,
                        sense_id, fingerprint, fingerprint_version, status
                    ) VALUES (?, 'jmdict', 'ds-2026-08', 1578850, 1,
                              ?, 'sense-fp-1', 'superseded')
                    """,
                arguments: [encode(unitID), fingerprint])
        }
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_dictionary_aliases(
                        unit_id, provider, dataset_version, entry_id,
                        sense_id, fingerprint, fingerprint_version, status
                    ) VALUES (?, 'jmdict', 'ds-2026-08', 1578850, 2,
                              ?, 'sense-fp-1', 'bogus')
                    """,
                arguments: [encode(unitID), fingerprint])
        })

        // note_id UNIQUE：同一 note 不许绑第二 unit
        let otherUnitID = UUID()
        try database.pool.write { db in
            try db.execute(sql: """
                INSERT INTO lexical_learning_units(
                    id, identity_kind, identity_key, lemma,
                    binding_status, created_at_ms, updated_at_ms
                ) VALUES (?, 'localNote', 'local-note:other', '他',
                          'legacy', 1, 1)
                """, arguments: [encode(otherUnitID)])
        }
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'primary', 'manual', 3)
                    """,
                arguments: [encode(otherUnitID), encode(noteID)])
        })
        // 一 unit 至多一 primary（部分唯一索引兜底）
        let thirdNoteID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, content_version,
                                      created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', '食べます', '吃(敬)', 0,
                            'manual', 1, 1, 1)
                    """,
                arguments: [encode(thirdNoteID), encode(deckID)])
        }
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'primary', 'manual', 3)
                    """,
                arguments: [encode(unitID), encode(thirdNoteID)])
        })
        // 但第二条 secondary 合法
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'legacy_secondary', 'manual', 4)
                    """,
                arguments: [encode(otherUnitID), encode(thirdNoteID)])
        }
        // 非法 role / origin 拒绝
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms
                    ) VALUES (?, ?, 'primary-ish', 'manual', 5)
                    """,
                arguments: [encode(otherUnitID), encode(UUID())])
        })
        // flags too_easy 0/1
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms
                    ) VALUES (?, 2, 0, 1)
                    """,
                arguments: [encode(otherUnitID)])
        })
        // events operation_id UNIQUE + kind 冻结集
        let dupOp = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_events(
                        id, operation_id, unit_id_snapshot, kind,
                        created_at_ms
                    ) VALUES (?, ?, ?, 'noteLinked', 2)
                    """,
                arguments: [encode(UUID()), encode(dupOp), encode(unitID)])
        }
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_events(
                        id, operation_id, unit_id_snapshot, kind,
                        created_at_ms
                    ) VALUES (?, ?, ?, 'noteUnlinked', 3)
                    """,
                arguments: [encode(UUID()), encode(dupOp), encode(unitID)])
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_events(
                        id, operation_id, unit_id_snapshot, kind,
                        created_at_ms
                    ) VALUES (?, ?, ?, 'bogusKind', 4)
                    """,
                arguments: [
                    encode(UUID()), encode(UUID()), encode(unitID)])
        })
        // migration item：source_key UNIQUE + status enum
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_migration_items(
                        source_key, status
                    ) VALUES ('override:test', 'applied')
                    """)
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_migration_items(
                        source_key, status
                    ) VALUES ('override:other', 'bogus')
                    """)
        })

        // ---- FK 行为 ----
        // 删 Note：link CASCADE、migration note_id SET NULL。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [encode(noteID)])
        }
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM learning_unit_note_links
                        WHERE note_id = ?
                        """,
                    arguments: [encode(noteID)]),
                0, "删 Note 须级联解除关联")
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT note_id, legacy_lexeme_id, target_unit_id
                    FROM learning_unit_migration_items
                    WHERE source_key = 'override:test'
                    """))
            let noteRef: String? = row["note_id"]
            XCTAssertNil(noteRef, "migration 证据不陪葬——note_id SET NULL")
            XCTAssertNotNil(row["legacy_lexeme_id"] as String?)
            XCTAssertNotNil(row["target_unit_id"] as String?)
        }

        // 删 unit：flag/alias/link CASCADE；event unit_id SET NULL 但
        // snapshot 留史；migration target_unit_id SET NULL。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM lexical_learning_units WHERE id = ?",
                arguments: [encode(unitID)])
        }
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM learning_unit_flags"), 0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM learning_unit_dictionary_aliases
                        WHERE unit_id = ?
                        """,
                    arguments: [encode(unitID)]),
                0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM learning_unit_note_links
                        WHERE unit_id = ?
                        """,
                    arguments: [encode(unitID)]),
                0)
            let eventRow = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT unit_id, unit_id_snapshot
                    FROM learning_unit_events
                    WHERE unit_id_snapshot = ?
                    """,
                arguments: [encode(unitID)]))
            let unitRef: String? = eventRow["unit_id"]
            XCTAssertNil(unitRef, "事件 unit_id 应 SET NULL")
            XCTAssertEqual(
                eventRow["unit_id_snapshot"] as String?, encode(unitID),
                "unit_id_snapshot 必须留史")
            let itemRow = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT target_unit_id FROM learning_unit_migration_items
                    WHERE source_key = 'override:test'
                    """))
            XCTAssertNil(
                itemRow["target_unit_id"] as String?,
                "migration target_unit_id 应 SET NULL")
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: - 工具（本文件私有，不改共享 fixture）

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

    /// v1–v22 全量迁移 + 独立 migrator 追加 v23（主 agent 未接线时
    /// 也能跑；接线后同函数行为一致）。
    private func openMigratedToV23(at file: URL) throws -> OboeDatabase {
        let v22All = OboeDatabaseSchema.migrationIdentifiers
        let pool = try DatabasePool(
            path: file.path, configuration: makeConfiguration())
        try OboeDatabaseSchema
            .makeMigrator(applying: v22All)
            .migrate(pool)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(
            Self.v23ID, migrate: GRDBLearningUnitSchema.migrate)
        try migrator.migrate(pool)
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
                "GRDBLearningUnitSchema-\(UUID().uuidString)",
                isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite"))
    }
}
