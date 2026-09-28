import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v16 → v17（v0.7.0，设计 §4.1 / §13）：新建 `reader_*` 基础表。
/// 升级必须是纯增量——7 张新表存在且为空、既有数据原样保留；
/// 文档级 FK 级联删除，`positions/bookmarks.chapter_id` 为
/// `SET NULL`；`reader_assets.relative_path` 拒绝绝对路径。
///
/// 注意：`v17_reader_foundation` 的 switch case 已注册，标识符列入
/// `migrationIdentifiers`/`tableNames` 是主 agent 的接线步骤——本文件
/// 通过 `identifiersIncludingV17` 显式追加，两种状态下都能跑通。
final class OboeSchemaV17MigrationTests: XCTestCase {

    /// v16 全量 + v17（若主 agent 已登记则不重复追加）。
    private var identifiersIncludingV17: [String] {
        OboeDatabaseSchema.migrationIdentifiers.contains("v17_reader_foundation")
            ? OboeDatabaseSchema.migrationIdentifiers
            : OboeDatabaseSchema.migrationIdentifiers + ["v17_reader_foundation"]
    }

    func testEmptyDatabaseMigrationCreatesReaderTables() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }

        try stageLegacyDatabase(at: location.file, through: "v16_custom_study") { _ in }

        let database = try openMigratedDatabase(at: location.file)
        defer { try? database.close() }
        try database.pool.read { db in
            for table in [
                "reader_documents", "reader_chapters", "reader_positions",
                "reader_bookmarks", "reader_assets", "reader_blocks",
                "reader_token_cache"
            ] {
                XCTAssertTrue(try db.tableExists(table), "\(table) 必须存在")
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0,
                    "\(table) 升级后必须为空表"
                )
            }
            XCTAssertEqual(
                Set(try db.columns(in: "reader_documents").map(\.name)),
                [
                    "id", "title", "format", "created_at_ms",
                    "last_opened_at_ms", "source_file_name", "source_sha256",
                    "canonical_text_hash", "parser_version", "content_revision",
                    "progress_basis_points", "availability"
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "reader_chapters").map(\.name)),
                [
                    "id", "document_id", "ordinal", "title", "source_locator",
                    "canonical_hash", "text_utf16_length"
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "reader_positions").map(\.name)),
                ["document_id", "chapter_id", "locator_json", "updated_at_ms"]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "reader_bookmarks").map(\.name)),
                [
                    "id", "document_id", "chapter_id", "locator_json",
                    "label", "created_at_ms"
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "reader_assets").map(\.name)),
                ["document_id", "relative_path", "source_sha256", "install_state"]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "reader_blocks").map(\.name)),
                [
                    "id", "document_id", "chapter_id", "ordinal",
                    "text", "text_hash", "locator_json"
                ]
            )
            XCTAssertEqual(
                Set(try db.columns(in: "reader_token_cache").map(\.name)),
                [
                    "block_id", "text_hash", "tokenizer_version",
                    "dictionary_version", "payload"
                ]
            )
            let applied = try OboeDatabaseSchema
                .makeMigrator(applying: identifiersIncludingV17)
                .appliedIdentifiers(db)
            XCTAssertEqual(applied, Set(identifiersIncludingV17))
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

    /// 已建库的 v16 → v17：notes/cards/source_contexts 原样保留，
    /// foreign_key_check 干净（验收 1）。
    func testPopulatedV16DatabaseSurvivesUpgrade() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let deckID = UUID()
        let noteID = UUID()

        try stageLegacyDatabase(
            at: location.file,
            through: "v16_custom_study"
        ) { db in
            try Self.insertDeckAndNote(
                db: db, deckID: deckID, noteID: noteID
            )
            // 预置一条 reader 来源的 SourceContext——文档删除后必须保留
            //（§4.3-5），升级本身也不得触碰。
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, original_sentence,
                        source_title, is_primary, created_at_ms
                    ) VALUES ('ctx-reader-1', ?, 'reader',
                              '吾輩は猫である', '旧书', 1, 7)
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }

        let database = try openMigratedDatabase(at: location.file)
        defer { try? database.close() }
        try database.pool.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT headword FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                ),
                "見る"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT original_sentence FROM source_contexts
                        WHERE id = 'ctx-reader-1'
                        """
                ),
                "吾輩は猫である"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM reader_documents"
                ),
                0
            )
        }
        let foreignKeyRows = try database.pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        }
        XCTAssertTrue(foreignKeyRows.isEmpty, "升级后外键必须一致")
    }

    /// 文档级级联 + 章节级 SET NULL + 约束拒绝（验收 2 的底层语义）。
    func testReaderConstraintsAndCascades() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try openFreshDatabase(at: location.file)
        defer { try? database.close() }
        let documentID = UUID()
        let chapterID = UUID()
        let blockID = UUID()
        let encode: (UUID) -> String = DatabaseValueCodec.encode

        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version
                    ) VALUES (?, '书', 'txt', 1, ?, 'canon', 'txt-1.0')
                    """,
                arguments: [encode(documentID), String(repeating: "a", count: 64)]
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, canonical_hash,
                        text_utf16_length
                    ) VALUES (?, ?, 0, 'ch', 10)
                    """,
                arguments: [encode(chapterID), encode(documentID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_blocks(
                        id, document_id, chapter_id, ordinal, text, text_hash
                    ) VALUES (?, ?, ?, 0, '正文', 'h')
                    """,
                arguments: [encode(blockID), encode(documentID), encode(chapterID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_positions(
                        document_id, chapter_id, locator_json, updated_at_ms
                    ) VALUES (?, ?, '{}', 5)
                    """,
                arguments: [encode(documentID), encode(chapterID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_bookmarks(
                        id, document_id, chapter_id, locator_json,
                        created_at_ms
                    ) VALUES (?, ?, ?, '{}', 6)
                    """,
                arguments: [encode(UUID()), encode(documentID), encode(chapterID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_assets(
                        document_id, relative_path, source_sha256, install_state
                    ) VALUES (?, 'OEBPS/a.png', ?, 'installed')
                    """,
                arguments: [encode(documentID), String(repeating: "b", count: 64)]
            )
            try db.execute(
                sql: """
                    INSERT INTO reader_token_cache(
                        block_id, text_hash, tokenizer_version,
                        dictionary_version, payload
                    ) VALUES (?, 'h', 'tok-1', 'dict-1', X'00')
                    """,
                arguments: [encode(blockID)]
            )
        }

        // UNIQUE(document_id, ordinal) 拒绝重复章序号。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, canonical_hash,
                        text_utf16_length
                    ) VALUES (?, ?, 0, 'ch2', 5)
                    """,
                arguments: [encode(UUID()), encode(documentID)]
            )
        })
        // format CHECK 拒绝未知格式。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version
                    ) VALUES (?, 'x', 'pdf', 1, ?, 'c', 'p')
                    """,
                arguments: [encode(UUID()), String(repeating: "c", count: 64)]
            )
        })
        // progress 越界拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms, source_sha256,
                        canonical_text_hash, parser_version,
                        progress_basis_points
                    ) VALUES (?, 'x', 'txt', 1, ?, 'c', 'p', 10001)
                    """,
                arguments: [encode(UUID()), String(repeating: "d", count: 64)]
            )
        })
        // 资产路径 CHECK：绝对路径与反斜杠拒绝（验收 4 的 DB 层兜底）。
        for badPath in ["/tmp/x.png", "a\\b.png", ""] {
            XCTAssertThrowsError(
                try database.pool.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO reader_assets(
                                document_id, relative_path,
                                source_sha256, install_state
                            ) VALUES (?, ?, ?, 'pending')
                            """,
                        arguments: [
                            encode(documentID), badPath,
                            String(repeating: "e", count: 64)
                        ]
                    )
                },
                "应拒绝路径 \(badPath)"
            )
        }
        // 书签 label 超 200 字拒绝。
        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_bookmarks(
                        id, document_id, chapter_id, locator_json,
                        label, created_at_ms
                    ) VALUES (?, ?, ?, '{}', ?, 6)
                    """,
                arguments: [
                    encode(UUID()), encode(documentID), encode(chapterID),
                    String(repeating: "长", count: 201)
                ]
            )
        })

        // 章节删除：position/bookmark 的 chapter_id SET NULL，块级联，
        // token_cache 随块消失。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_chapters WHERE id = ?",
                arguments: [encode(chapterID)]
            )
        }
        try database.pool.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT chapter_id FROM reader_positions
                    WHERE document_id = ?
                    """,
                arguments: [encode(documentID)]
            ))
            let positionChapter: String? = row["chapter_id"]
            XCTAssertNil(positionChapter)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM reader_blocks"
                ),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM reader_token_cache"
                ),
                0
            )
            let bookmarkRow = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT chapter_id FROM reader_bookmarks
                    WHERE document_id = ?
                    """,
                arguments: [encode(documentID)]
            ))
            let bookmarkChapter: String? = bookmarkRow["chapter_id"]
            XCTAssertNil(bookmarkChapter)
        }

        // 文档级级联：positions/bookmarks/assets 一并消失。
        try database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [encode(documentID)]
            )
        }
        try database.pool.read { db in
            for table in [
                "reader_positions", "reader_bookmarks", "reader_assets",
                "reader_chapters", "reader_blocks", "reader_token_cache"
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db, sql: "SELECT COUNT(*) FROM \(table)"
                    ),
                    0,
                    "\(table) 应随文档级联清空"
                )
            }
            XCTAssertTrue(try Row.fetchAll(
                db, sql: "PRAGMA foreign_key_check"
            ).isEmpty)
        }
    }

    // MARK: - 工具

    /// 以「全量标识符 + v17」开库——等价于主 agent 把标识符接入
    /// `migrationIdentifiers` 后 `OboeDatabase(path:)` 的行为。
    private func openMigratedDatabase(at file: URL) throws -> OboeDatabase {
        let pool = try OboeDatabase.openPool(path: file.path)
        try OboeDatabaseSchema
            .makeMigrator(applying: identifiersIncludingV17)
            .migrate(pool)
        return OboeDatabase(pool: pool)
    }

    private func openFreshDatabase(at file: URL) throws -> OboeDatabase {
        try openMigratedDatabase(at: file)
    }

    private static func insertDeckAndNote(
        db: Database,
        deckID: UUID,
        noteID: UUID
    ) throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms,
                                  updated_at_ms)
                VALUES (?, '测试牌组', 0, ?, ?)
                """,
            arguments: [DatabaseValueCodec.encode(deckID), nowMs, nowMs]
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, meaning_zh, is_favorite,
                    origin, content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '見る', '看', 0,
                          'manual', 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(noteID),
                DatabaseValueCodec.encode(deckID), nowMs, nowMs
            ]
        )
    }

    private struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OboeSchemaV17MigrationTests-\(UUID().uuidString)",
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
