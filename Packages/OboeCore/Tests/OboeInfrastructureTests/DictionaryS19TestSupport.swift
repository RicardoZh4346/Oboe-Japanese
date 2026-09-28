import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S19 测试共享夹具：可写 glosses/overlay/受限表的全形词典库
/// （MorphologyTestSupport.makeDictionary 的超集——质量审计与会话
/// 测试需要 gloss/sense 明细与文件级 checksum）。
enum DictionaryS19Fixture {

    struct Gloss {
        var language: String
        var text: String
        var source: String = "test"
        var machine: Bool = true
    }

    struct Sense {
        var pos: [String] = []
        var glosses: [Gloss] = []
    }

    struct Overlay {
        var language: String
        var text: String
    }

    struct Entry {
        var id: Int64
        var primaryForm: String
        var forms: [String] = []
        var readings: [String] = []
        var rank: Int? = nil
        var senses: [Sense] = [Sense(pos: ["n"], glosses: [Gloss(language: "eng", text: "en")])]
        var overlays: [Overlay] = []
    }

    /// 产物形状的最小全集 schema（repository/inspector/lookup 共检）。
    static func createSchema(_ db: Database, datasetVersion: String) throws {
        try db.execute(sql: """
            CREATE TABLE dictionary_metadata(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE dictionary_sources(
                source_id TEXT PRIMARY KEY, source_name TEXT NOT NULL,
                source_version TEXT NOT NULL, source_url TEXT NOT NULL,
                license TEXT NOT NULL, license_url TEXT NOT NULL,
                retrieved_at TEXT NOT NULL, sha256 TEXT NOT NULL,
                input_bytes INTEGER NOT NULL, attribution TEXT NOT NULL,
                consumed_tables_json TEXT NOT NULL, modifications TEXT NOT NULL);
            CREATE TABLE entries(
                id INTEGER PRIMARY KEY, primary_form TEXT NOT NULL,
                common_rank INTEGER);
            CREATE TABLE forms(
                id INTEGER PRIMARY KEY,
                entry_id INTEGER NOT NULL,
                text TEXT NOT NULL, normalized_text TEXT NOT NULL,
                form_type TEXT NOT NULL DEFAULT 'standard',
                priority INTEGER);
            CREATE INDEX idx_forms_normalized ON forms(normalized_text);
            CREATE TABLE readings(
                id INTEGER PRIMARY KEY,
                entry_id INTEGER NOT NULL,
                reading TEXT NOT NULL, normalized_reading TEXT NOT NULL,
                no_kanji INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX idx_readings_normalized ON readings(normalized_reading);
            CREATE TABLE senses(
                id INTEGER PRIMARY KEY,
                entry_id INTEGER NOT NULL, sense_order INTEGER NOT NULL);
            CREATE TABLE sense_pos(sense_id INTEGER NOT NULL, code TEXT NOT NULL);
            CREATE TABLE sense_tags(
                sense_id INTEGER NOT NULL, category TEXT NOT NULL,
                code TEXT NOT NULL);
            CREATE TABLE glosses(
                sense_id INTEGER NOT NULL, language TEXT NOT NULL,
                text TEXT NOT NULL, gloss_order INTEGER NOT NULL,
                source_id TEXT NOT NULL,
                is_machine_generated INTEGER NOT NULL DEFAULT 0,
                source_fingerprint TEXT);
            CREATE TABLE reading_form_restrictions(
                reading_id INTEGER NOT NULL, form_id INTEGER NOT NULL);
            CREATE TABLE sense_form_restrictions(
                sense_id INTEGER NOT NULL, form_id INTEGER NOT NULL);
            CREATE TABLE sense_reading_restrictions(
                sense_id INTEGER NOT NULL, reading_id INTEGER NOT NULL);
            CREATE TABLE entry_gloss_overlays(
                entry_id INTEGER NOT NULL, language TEXT NOT NULL,
                text TEXT NOT NULL, source_id TEXT NOT NULL);
            """)
        try db.execute(
            sql: """
                INSERT INTO dictionary_metadata(key, value) VALUES
                    ('schema_version','1'), ('dataset_version', ?),
                    ('dictionary_version', ?),
                    ('normalizer','oboe-search-normalizer/1')
                """,
            arguments: [datasetVersion, datasetVersion])
        try db.execute(
            sql: """
                INSERT INTO dictionary_sources(
                    source_id, source_name, source_version, source_url,
                    license, license_url, retrieved_at, sha256,
                    input_bytes, attribution, consumed_tables_json,
                    modifications
                ) VALUES ('test','Test','v1','https://example.test',
                          'CC0','https://example.test/license',
                          '2026-01-01','00',1,'attr','[]','none')
                """)
        // metadata 计数列如实写（审计会比对 entry_count）。
        try db.execute(
            sql: """
                INSERT OR REPLACE INTO dictionary_metadata(key, value)
                VALUES
                    ('entry_count', (SELECT CAST(COUNT(*) AS TEXT) FROM entries)),
                    ('sense_count', (SELECT CAST(COUNT(*) AS TEXT) FROM senses)),
                    ('gloss_count', (SELECT CAST(COUNT(*) AS TEXT) FROM glosses))
                """)
    }

    static func insert(_ entry: Entry, into db: Database) throws {
        try db.execute(
            sql: "INSERT INTO entries(id, primary_form, common_rank) VALUES (?,?,?)",
            arguments: [entry.id, entry.primaryForm, entry.rank])
        for form in entry.forms {
            try db.execute(
                sql: """
                    INSERT INTO forms(entry_id, text, normalized_text)
                    VALUES (?,?,?)
                    """,
                arguments: [entry.id, form,
                            SearchTextNormalizer.normalize(form)])
        }
        for reading in entry.readings {
            try db.execute(
                sql: """
                    INSERT INTO readings(entry_id, reading, normalized_reading)
                    VALUES (?,?,?)
                    """,
                arguments: [entry.id, reading,
                            SearchTextNormalizer.normalize(reading)])
        }
        for (index, sense) in entry.senses.enumerated() {
            try db.execute(
                sql: "INSERT INTO senses(entry_id, sense_order) VALUES (?,?)",
                arguments: [entry.id, index])
            let senseID = db.lastInsertedRowID
            for code in sense.pos {
                try db.execute(
                    sql: "INSERT INTO sense_pos(sense_id, code) VALUES (?,?)",
                    arguments: [senseID, code])
            }
            for (order, gloss) in sense.glosses.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO glosses(
                            sense_id, language, text, gloss_order,
                            source_id, is_machine_generated
                        ) VALUES (?,?,?,?,?,?)
                        """,
                    arguments: [
                        senseID, gloss.language, gloss.text, order,
                        gloss.source, gloss.machine ? 1 : 0,
                    ])
            }
        }
        for overlay in entry.overlays {
            try db.execute(
                sql: """
                    INSERT INTO entry_gloss_overlays(
                        entry_id, language, text, source_id)
                    VALUES (?,?,?,'test')
                    """,
                arguments: [entry.id, overlay.language, overlay.text])
        }
    }

    /// 内存词典库（lookup/审计单元测试）。
    static func makeInMemory(
        entries: [Entry],
        datasetVersion: String = "test-v1"
    ) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try createSchema(db, datasetVersion: datasetVersion)
            for entry in entries { try insert(entry, into: db) }
            try db.execute(
                sql: """
                    UPDATE dictionary_metadata SET value =
                        (SELECT CAST(COUNT(*) AS TEXT) FROM entries)
                    WHERE key = 'entry_count';
                    UPDATE dictionary_metadata SET value =
                        (SELECT CAST(COUNT(*) AS TEXT) FROM senses)
                    WHERE key = 'sense_count';
                    UPDATE dictionary_metadata SET value =
                        (SELECT CAST(COUNT(*) AS TEXT) FROM glosses)
                    WHERE key = 'gloss_count';
                    """)
        }
        return queue
    }

    /// 文件级词典库（只读断言/checksum 与会话测试）。
    /// 返回 (文件 URL, 根目录 URL——调用方负责清理)。
    @discardableResult
    static func writeDictionaryFile(
        entries: [Entry],
        datasetVersion: String = "test-v1",
        into directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test-dict.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try createSchema(db, datasetVersion: datasetVersion)
            for entry in entries { try insert(entry, into: db) }
            try db.execute(
                sql: """
                    UPDATE dictionary_metadata SET value =
                        (SELECT CAST(COUNT(*) AS TEXT) FROM entries)
                    WHERE key = 'entry_count';
                    UPDATE dictionary_metadata SET value =
                        (SELECT CAST(COUNT(*) AS TEXT) FROM senses)
                    WHERE key = 'sense_count';
                    UPDATE dictionary_metadata SET value =
                        (SELECT CAST(COUNT(*) AS TEXT) FROM glosses)
                    WHERE key = 'gloss_count';
                    """)
        }
        try queue.close()
        return url
    }

    /// 建 app 库（全量迁移 + v22 手工注册——与 v18 测试同模式）。
    static func makeAppPool(into directory: URL) throws -> DatabasePool {
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
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("oboe.sqlite").path,
            configuration: config)
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers).migrate(pool)
        var v22 = DatabaseMigrator()
        v22.registerMigration(
            GRDBDictionaryKnowledgeSchema.expectedMigrationIdentifier,
            migrate: GRDBDictionaryKnowledgeSchema.migrate)
        try v22.migrate(pool)
        return pool
    }

    static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)",
                                   isDirectory: true)
    }
}

/// async 断言助手（与既有测试文件内的私有实现同签名，模块内共享）。
func s19AssertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("期望抛错但未抛：\(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
