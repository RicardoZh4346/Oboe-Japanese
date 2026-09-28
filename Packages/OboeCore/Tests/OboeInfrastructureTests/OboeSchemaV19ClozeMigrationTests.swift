import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v18/v20 → v19（v0.7.0 S12，设计 §9.1–9.3/§13）：`cloze_definitions` 新表、
/// notes 重建放行 `kind='sentence'` + `origin reader/import` + 条件
/// `meaning_zh` CHECK、cards 重建放行 `sentence_cloze`、`source_contexts`
/// 增 Reader 定位弱引用列、搜索触发器 NULL 安全重写。
///
/// `v19_cloze` 的注册由主 agent 接线到 `OboeDatabase.swift`——本测试用
/// 独立 `DatabaseMigrator` 直接注册 `GRDBClozeSchema.migrate`，两种接线
/// 状态下都跑通（与 v18 测试同款策略）。
final class OboeSchemaV19ClozeMigrationTests: XCTestCase {

    private static let v19ID = "v19_cloze"

    // MARK: - 升级路径

    /// v18 既有库升级：vocabulary/grammar 数据原样保留，
    /// `cloze_definitions` 与 Reader 定位列就位，integrity + FK 检查干净。
    func testPopulatedV18SurvivesUpgrade() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let deckID = UUID()
        let noteID = UUID()
        let contextID = UUID()

        try stageDatabase(at: location.file, through: "v18_lexical_knowledge") { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
            try insertDeck(id: deckID, at: nowMs, in: db)
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
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        source_title, is_primary, created_at_ms
                    ) VALUES (?, ?, 'manual', '昨日映画を見た。',
                              '测试书', 1, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(contextID),
                    DatabaseValueCodec.encode(noteID), nowMs
                ])
        }

        let database = try openMigratedToV19(at: location.file)
        defer { try? database.close() }
        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("cloze_definitions"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloze_definitions"),
                0)
            // 新列就位且旧数据原样保留。
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT original_sentence, reader_document_id,
                           reader_chapter_id, reader_location, selected_surface
                    FROM source_contexts WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(contextID)]))
            XCTAssertEqual(row["original_sentence"], "昨日映画を見た。")
            XCTAssertNil(row["reader_document_id"] as String?)
            XCTAssertNil(row["reader_chapter_id"] as String?)
            XCTAssertNil(row["reader_location"] as String?)
            XCTAssertNil(row["selected_surface"] as String?)
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT headword FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]),
                "見る")
            // 触发器按新名重建（notes DROP 会带走旧触发器）。
            let triggers = try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'trigger' AND tbl_name = 'notes'
                    """)
            XCTAssertTrue(
                triggers.contains("notes_search_documents_after_insert"))
            XCTAssertTrue(
                triggers.contains("notes_search_documents_after_content_update"))
            let applied = try DatabaseMigrator().appliedIdentifiers(db)
            XCTAssertTrue(applied.contains(Self.v19ID))
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

    /// 已跑到 v20 的现存库再补跑 v19（GRDB 只按「是否已应用」判定，
    /// 顺序对已有库无关）——cloze 能力照常就位。
    func testV19AppliesOnDatabaseAlreadyAtV20() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }

        var migrator = DatabaseMigrator()
        migrator.registerMigration(Self.v19ID, migrate: GRDBClozeSchema.migrate)
        try migrator.migrate(database.pool)

        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("cloze_definitions"))
            let applied = try DatabaseMigrator().appliedIdentifiers(db)
            XCTAssertTrue(applied.contains(Self.v19ID))
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: - notes 重建：kind / origin / 条件 meaning CHECK

    /// sentence Note：meaning_zh 可空但禁止空串；vocabulary/grammar
    /// 仍必须非空（旧行为不破）。
    func testConditionalMeaningCheck() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV19(at: location.file)
        defer { try? database.close() }
        let deckID = UUID()

        try database.pool.write { db in
            try insertDeck(id: deckID, at: 1, in: db)
            // sentence + NULL meaning：合法。
            try insertNote(
                kind: "sentence", headword: "昨日映画を見た。",
                meaningZH: nil, origin: "reader",
                deckID: deckID, in: db)
            // sentence + 非空 meaning：合法。
            try insertNote(
                kind: "sentence", headword: "もう一つの例文。",
                meaningZH: "另一个例句。", origin: "import",
                deckID: deckID, in: db)
        }
        // sentence + 空串 meaning：拒绝（可空 ≠ 可空白）。
        XCTAssertThrowsError(try database.pool.write { db in
            try insertNote(
                kind: "sentence", headword: "空释义。",
                meaningZH: "   ", origin: "manual",
                deckID: deckID, in: db)
        })
        // vocabulary/grammar + NULL meaning：拒绝。
        for kind in ["vocabulary", "grammar"] {
            XCTAssertThrowsError(try database.pool.write { db in
                try insertNote(
                    kind: kind, headword: "語",
                    meaningZH: nil, origin: "manual",
                    deckID: deckID, in: db)
            }, "\(kind) NULL meaning 必须被拒")
        }
        // 非法 kind / 非法 origin 仍拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try insertNote(
                kind: "phrase", headword: "x", meaningZH: "y",
                origin: "manual", deckID: deckID, in: db)
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try insertNote(
                kind: "sentence", headword: "x", meaningZH: nil,
                origin: "web", deckID: deckID, in: db)
        })
        // builtin_jlpt 的 source_ref 归属 CHECK 保留。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                      is_favorite, origin, source_ref,
                                      content_version, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 'vocabulary', 'x', 'y', 0,
                            'manual', 'should-not-exist', 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(deckID)
                ])
        })
    }

    /// cards 重建放行 `sentence_cloze`；未知模板依旧拒绝；
    /// `UNIQUE(note_id, template_kind)` 保留（一张 sentence Note
    /// 至多一张 cloze 卡）。
    func testCardsAcceptSentenceClozeTemplate() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV19(at: location.file)
        defer { try? database.close() }
        let deckID = UUID()
        let noteID = UUID()

        try database.pool.write { db in
            try insertDeck(id: deckID, at: 1, in: db)
            try insertNote(
                id: noteID, kind: "sentence", headword: "昨日映画を見た。",
                meaningZH: nil, origin: "reader", deckID: deckID, in: db)
            try insertSchedulerProfile(in: db)
            try insertCard(
                noteID: noteID, templateKind: "sentence_cloze", in: db)
        }
        // 同 note 第二张 sentence_cloze：UNIQUE 冲突。
        XCTAssertThrowsError(try database.pool.write { db in
            try insertCard(
                noteID: noteID, templateKind: "sentence_cloze", in: db)
        })
        // 未注册模板仍拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try insertCard(
                noteID: noteID, templateKind: "sentence_production", in: db)
        })
    }

    /// 搜索触发器 NULL 安全：NULL meaning 的 sentence Note 入/改/删
    /// 不再让 trigger 崩溃（旧 trigger 没有 COALESCE meaning_zh）。
    func testSearchTriggersAreNullSafe() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV19(at: location.file)
        defer { try? database.close() }
        let deckID = UUID()
        let noteID = UUID()

        try database.pool.write { db in
            try insertDeck(id: deckID, at: 1, in: db)
            // INSERT 触发器：NULL meaning 不再崩。
            try insertNote(
                id: noteID, kind: "sentence", headword: "昨日映画を見た。",
                meaningZH: nil, origin: "reader", deckID: deckID, in: db)
        }
        try database.pool.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT normalized_headword, normalized_meaning
                    FROM search_documents WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            XCTAssertEqual(row["normalized_headword"], "昨日映画を見た。")
            XCTAssertEqual(row["normalized_meaning"], "")
        }
        try database.pool.write { db in
            // UPDATE 触发器：改 headword/meaning 同样 NULL 安全。
            try db.execute(
                sql: "UPDATE notes SET meaning_zh = '昨天看了电影。' WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)])
            try db.execute(
                sql: "UPDATE notes SET headword = '昨日映画館に行った。' WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)])
        }
        try database.pool.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT normalized_headword, normalized_meaning
                    FROM search_documents WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]))
            XCTAssertEqual(row["normalized_headword"], "昨日映画館に行った。")
            XCTAssertEqual(row["normalized_meaning"], "昨天看了电影。")
        }
    }

    // MARK: - cloze_definitions 约束与级联

    /// note_id/card_id 双 UNIQUE；source_context 删除 → SET NULL；
    /// Note/Card 删除 → 级联定义消失。
    func testClozeDefinitionConstraintsAndCascades() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV19(at: location.file)
        defer { try? database.close() }
        let deckID = UUID()
        let noteID = UUID()
        let cardID = UUID()
        let clozeID = UUID()
        let contextID = UUID()
        let sentence = "私は昨日映画を見た。"

        try database.pool.write { db in
            try insertDeck(id: deckID, at: 1, in: db)
            try insertNote(
                id: noteID, kind: "sentence", headword: sentence,
                meaningZH: nil, origin: "reader", deckID: deckID, in: db)
            try insertSchedulerProfile(in: db)
            try insertCard(
                id: cardID, noteID: noteID,
                templateKind: "sentence_cloze", in: db)
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        reader_document_id, reader_chapter_id,
                        reader_location, selected_surface,
                        is_primary, created_at_ms
                    ) VALUES (?, ?, 'reader', ?, ?, ?, ?, '見た', 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(contextID),
                    DatabaseValueCodec.encode(noteID), sentence,
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    #"{"version":1,"chapterOrdinal":0,"blockOrdinal":3,"utf16Offset":6,"blockTextHash":"abc","prefix":"私は昨日","suffix":"。","cueStartMilliseconds":null}"#
                ])
            try insertClozeDefinition(
                id: clozeID, noteID: noteID, cardID: cardID,
                sourceContextID: contextID, sentence: sentence,
                utf16Start: 6, utf16Length: 2, in: db)
        }

        // note_id / card_id 双 UNIQUE。
        XCTAssertThrowsError(try database.pool.write { db in
            try insertClozeDefinition(
                id: UUID(), noteID: noteID, cardID: UUID(),
                sourceContextID: nil, sentence: sentence,
                utf16Start: 0, utf16Length: 1, in: db)
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try insertClozeDefinition(
                id: UUID(), noteID: UUID(), cardID: cardID,
                sourceContextID: nil, sentence: sentence,
                utf16Start: 0, utf16Length: 1, in: db)
        })
        // 非 json_valid 的 accepted_answers_json 拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cloze_definitions(
                        id, note_id, card_id, sentence_snapshot, sentence_sha256,
                        range_utf16_start, range_utf16_length, target_surface,
                        accepted_answers_json
                    ) VALUES (?, ?, ?, 'x', ?, 0, 1, 'x', 'not-json')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    String(repeating: "0", count: 64)
                ])
        })
        // sha256 长度 CHECK。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cloze_definitions(
                        id, note_id, card_id, sentence_snapshot, sentence_sha256,
                        range_utf16_start, range_utf16_length, target_surface,
                        accepted_answers_json
                    ) VALUES (?, ?, ?, 'x', 'short', 0, 1, 'x', '["x"]')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID())
                ])
        })

        // 删除来源 → definition 的 source_context_id SET NULL，定义存活。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM source_contexts WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(contextID)])
        }
        try database.pool.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT source_context_id, sentence_snapshot
                    FROM cloze_definitions WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(clozeID)]))
            XCTAssertNil(row["source_context_id"] as String?)
            XCTAssertEqual(row["sentence_snapshot"], sentence)
        }

        // 删除 Note → card 与 definition 级联消失。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)])
        }
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloze_definitions"),
                0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM cards WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(cardID)]),
                0)
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    /// Reader 定位列弱引用：不存在的 document/chapter id 可写（无 FK），
    /// reader_location 必须是合法 JSON。
    func testReaderLocatorColumnsAreWeakReferences() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openMigratedToV19(at: location.file)
        defer { try? database.close() }
        let deckID = UUID()
        let noteID = UUID()

        try database.pool.write { db in
            try insertDeck(id: deckID, at: 1, in: db)
            try insertNote(
                id: noteID, kind: "sentence", headword: "句。",
                meaningZH: nil, origin: "reader", deckID: deckID, in: db)
            // document/chapter 指向不存在的行也合法（弱引用）。
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, reader_document_id,
                        reader_chapter_id, reader_location, selected_surface,
                        is_primary, created_at_ms
                    ) VALUES (?, ?, 'reader', ?, ?, ?, '見た', 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(UUID()),
                    #"{"version":1,"chapterOrdinal":1,"blockOrdinal":0,"utf16Offset":0,"blockTextHash":"h","prefix":"","suffix":"","cueStartMilliseconds":1500}"#
                ])
        }
        // 非法 JSON 拒绝；长度不是 36 的 reader_*_id 拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, reader_location,
                        is_primary, created_at_ms
                    ) VALUES (?, ?, 'reader', 'not-json', 0, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID)
                ])
        })
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, reader_document_id,
                        is_primary, created_at_ms
                    ) VALUES (?, ?, 'reader', 'short', 0, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID)
                ])
        })
    }

    // MARK: - 工具

    private func openMigratedToV19(at file: URL) throws -> OboeDatabase {
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
        // 第一阶段：当前已注册的全部标识符（对已有 staged 库是 no-op，
        // 对空库负责把 v1…v18/v20 建齐）。
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        // 第二阶段：本文件独立注册 v19——主 agent 未接线时也能跑，
        // 接线后 GRDB 检测已应用而跳过，幂等一致。
        var migrator = DatabaseMigrator()
        migrator.registerMigration(Self.v19ID, migrate: GRDBClozeSchema.migrate)
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

    private func insertDeck(id: UUID, at ms: Int64, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                VALUES (?, 'deck', 0, ?, ?)
                """,
            arguments: [DatabaseValueCodec.encode(id), ms, ms])
    }

    private func insertNote(
        id: UUID = UUID(),
        kind: String,
        headword: String,
        meaningZH: String?,
        origin: String,
        deckID: UUID,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO notes(id, deck_id, kind, headword, meaning_zh,
                                  is_favorite, origin, content_version,
                                  created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, 0, ?, 1, 1, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(deckID),
                kind, headword, meaningZH, origin
            ])
    }

    private func insertSchedulerProfile(in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO scheduler_profiles(
                    id, configuration_version, algorithm_version,
                    library_revision, parameters_json, desired_retention,
                    max_interval_days, created_at_ms
                ) VALUES (?, 'test-profile', 'fsrs-5', 'r1', '{}', 0.9, 36500, 1)
                """,
            arguments: [DatabaseValueCodec.encode(Self.testProfileID)]
        )
    }

    private static let testProfileID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111")!

    private func insertCard(
        id: UUID = UUID(),
        noteID: UUID,
        templateKind: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cards(
                    id, note_id, template_kind, is_enabled, state, due_at_ms,
                    stability, difficulty, reps, lapses, scheduled_days,
                    elapsed_days, learning_step, state_version,
                    algorithm_version, profile_id
                ) VALUES (?, ?, ?, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 'fsrs', ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(noteID),
                templateKind,
                DatabaseValueCodec.encode(Self.testProfileID)
            ])
    }

    private func insertClozeDefinition(
        id: UUID,
        noteID: UUID,
        cardID: UUID,
        sourceContextID: UUID?,
        sentence: String,
        utf16Start: Int,
        utf16Length: Int,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO cloze_definitions(
                    id, note_id, card_id, source_context_id, sentence_snapshot,
                    sentence_sha256, range_version, range_utf16_start,
                    range_utf16_length, target_surface, target_lemma,
                    target_reading, accepted_answers_json, hint, content_version
                ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, '見た', '見る', 'みた',
                          '["見た","みた"]', NULL, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(noteID),
                DatabaseValueCodec.encode(cardID),
                sourceContextID.map { DatabaseValueCodec.encode($0) },
                sentence,
                ClozeValidator.snapshotSHA256(sentence),
                utf16Start,
                utf16Length
            ])
    }

    private struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OboeSchemaV19-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite"))
    }
}
