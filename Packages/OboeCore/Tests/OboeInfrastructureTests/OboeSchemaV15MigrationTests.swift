import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v14 → v15（v0.6.0，设计 §6.1）：新建 `source_contexts` 表。
/// 升级必须是纯增量——表存在、为空、不动既有数据；`image_reference`
/// 延续宽松引用（无 FK）；`note_id` 级联删除；部分唯一索引表达
/// 「有来源时最多一个 primary」，旧 Note 零来源仍合法。
final class OboeSchemaV15MigrationTests: XCTestCase {
    func testV14UpgradeCreatesEmptySourceContextsTable() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let noteID = UUID()

        try stageLegacyDatabase(
            at: location.file,
            through: "v14_attachments"
        ) { db in
            try Self.insertDeckAndNote(db: db, noteID: noteID, sourceText: "旧例句")
        }

        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }
        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("source_contexts"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_contexts"),
                0,
                "升级后 source_contexts 必须为空表"
            )
            let columns = try db.columns(in: "source_contexts").map(\.name)
            XCTAssertEqual(
                Set(columns),
                [
                    "id", "note_id", "source_type", "original_sentence",
                    "surrounding_text", "source_title", "source_url",
                    "source_app", "image_reference", "dictionary_entry_id",
                    "dictionary_version", "dictionary_sense_key",
                    "selected_gloss_language", "is_primary", "created_at_ms"
                ]
            )
            // 旧 source_text 原样保留——升级不产生信息退化。
            let sourceText: String? = try Row.fetchOne(
                db,
                sql: "SELECT source_text FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )?["source_text"]
            XCTAssertEqual(sourceText, "旧例句")
            let applied = try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            XCTAssertEqual(applied, Set(OboeDatabaseSchema.migrationIdentifiers))
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

    func testSourceContextConstraints() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }
        let noteID = UUID()
        let otherNoteID = UUID()

        try database.pool.write { db in
            try Self.insertDeckAndNote(db: db, noteID: noteID, sourceText: nil)
            try Self.insertDeckAndNote(db: db, noteID: otherNoteID, sourceText: nil)
        }

        // 宽松 image_reference：指向不存在附件也允许（清理由引用查询负责）。
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        image_reference, is_primary, created_at_ms
                    ) VALUES ('ctx-1', ?, 'ocr', '今日はいい天気です', 'img-a', 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            // 同一 Note 的非 primary 第二条来源合法。
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, is_primary, created_at_ms
                    ) VALUES ('ctx-2', ?, 'share', 0, 2)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }

        // 第二个 primary 必须被部分唯一索引拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, is_primary, created_at_ms
                    ) VALUES ('ctx-3', ?, 'manual', 1, 3)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }) { error in
            XCTAssertTrue(
                String(describing: error).contains("UNIQUE"),
                "应命中 source_contexts_one_primary 唯一索引，实际：\(error)"
            )
        }
        // 其它 Note 的 primary 不受影响。
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, is_primary, created_at_ms
                    ) VALUES ('ctx-4', ?, 'manual', 1, 4)
                    """,
                arguments: [DatabaseValueCodec.encode(otherNoteID)]
            )
        }
        // 非法 source_type 被 CHECK 拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, is_primary, created_at_ms
                    ) VALUES ('ctx-5', ?, 'web', 0, 5)
                    """,
                arguments: [DatabaseValueCodec.encode(otherNoteID)]
            )
        })

        // note_id 级联删除：删除 Note 后其来源记录随之消失。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
        let remaining = try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM source_contexts ORDER BY id"
            )
        }
        XCTAssertEqual(remaining, ["ctx-4"])
    }

    // MARK: - 工具

    private static func insertDeckAndNote(
        db: Database,
        noteID: UUID,
        sourceText: String?
    ) throws {
        let encode: (UUID) -> String = DatabaseValueCodec.encode
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                VALUES (?, '测试牌组', 0, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [encode(noteID), nowMs, nowMs]
        )
        // note 的 home deck 用 note_id 换出的 deck——一个测试夹具一个 deck。
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, meaning_zh, is_favorite,
                    source_text, origin, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '見る', '看', 0, ?, 'manual', 1, ?, ?)
                """,
            arguments: [encode(noteID), encode(noteID), sourceText, nowMs, nowMs]
        )
    }

    private struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OboeSchemaV15MigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite")
        )
    }

    private func stageLegacyDatabase(
        at file: URL,
        through lastIdentifier: String,
        seed: (Database) throws -> Void
    ) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search",
                argumentCount: 1,
                pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0]) else {
                    return nil
                }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let prefix = Array(
            OboeDatabaseSchema.migrationIdentifiers.prefix(
                through: OboeDatabaseSchema.migrationIdentifiers
                    .firstIndex(of: lastIdentifier)!
            )
        )
        let migrator = OboeDatabaseSchema.makeMigrator(applying: prefix)
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        try migrator.migrate(queue)
        try queue.write(seed)
        try queue.close()
    }
}
