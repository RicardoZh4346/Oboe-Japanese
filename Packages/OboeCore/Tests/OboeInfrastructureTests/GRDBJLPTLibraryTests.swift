import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class GRDBJLPTLibraryTests: XCTestCase {
    func testReadOnlyLibrarySupportsCountsSearchSortPaginationAndDetails() async throws {
        let location = try JLPTTestLocation()
        defer { location.remove() }
        try makeLibrary(at: location.libraryURL)
        let repository = try GRDBJLPTLibraryRepository(databaseURL: location.libraryURL)
        let service = JLPTLibraryService(repository: repository)

        let counts = try await service.levelCounts()
        XCTAssertEqual(counts[.n5], 2)
        XCTAssertEqual(counts[.n4], 1)

        let firstPage = try await service.vocabulary(level: .n5, limit: 1)
        XCTAssertEqual(firstPage.items.map(\.headword), ["食べる"])
        XCTAssertEqual(firstPage.nextOffset, 1)
        XCTAssertEqual(firstPage.items.first?.examples.first?.japanese, "ご飯を食べる。")

        let frequency = try await service.vocabulary(level: .n5, sort: .frequency)
        XCTAssertEqual(frequency.items.map(\.headword), ["食べる", "学校"])
        let search = try await service.vocabulary(level: .n5, query: "学校")
        XCTAssertEqual(search.items.map(\.reading), ["がっこう"])
        let readingSearch = try await service.vocabulary(level: .n5, query: "ガッコウ")
        XCTAssertEqual(readingSearch.items.map(\.headword), ["学校"])
        let chineseSearch = try await service.vocabulary(level: .n5, query: "吃")
        XCTAssertEqual(chineseSearch.items.map(\.headword), ["食べる"])

        let detail = try await service.vocabulary(id: "openjlpt:N5:000001")
        XCTAssertEqual(detail?.meaningsEN, ["to eat"])
        XCTAssertEqual(detail?.examples.count, 2)
        XCTAssertEqual(detail?.examples.last?.english, "I eat breakfast.")
        let missing = try await service.vocabulary(id: "missing")
        XCTAssertNil(missing)
    }

    func testSingleImportIsIdempotentAndPreservesExistingSchedulingProgress() async throws {
        let location = try JLPTTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let importer = GRDBJLPTImporter(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '我的牌组', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        let vocabulary = Self.vocabulary(id: "openjlpt:N5:000001", headword: "食べる")

        let first = try await importer.importVocabulary(
            vocabulary,
            deckID: deckID,
            meaningZH: " 吃 ",
            directions: [.japaneseToChinese, .chineseToJapanese]
        )
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(first.skipped, 0)

        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cards
                    SET state = 2, due_at_ms = 999000, stability = 8.5,
                        difficulty = 4.2, reps = 7, state_version = 7
                    WHERE template_kind = 'vocabulary_zh_ja'
                    """
            )
        }
        let repeated = try await importer.importVocabulary(
            vocabulary,
            deckID: deckID,
            meaningZH: "新释义不应覆盖已有内容",
            directions: [.japaneseToChinese]
        )
        XCTAssertEqual(repeated.imported, 0)
        XCTAssertEqual(repeated.skipped, 1)

        let values = try await database.pool.read { db in
            let card = try Row.fetchOne(
                db,
                sql: """
                    SELECT state, due_at_ms, stability, difficulty, reps, state_version
                    FROM cards WHERE template_kind = 'vocabulary_zh_ja'
                    """
            ).map { (
                $0["state"] as Int?, $0["due_at_ms"] as Int64?, $0["stability"] as Double?,
                $0["difficulty"] as Double?, $0["reps"] as Int?, $0["state_version"] as Int?
            ) }
            return (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try String.fetchOne(db, sql: "SELECT origin FROM notes"),
                try String.fetchOne(db, sql: "SELECT source_ref FROM notes"),
                try String.fetchOne(db, sql: "SELECT meaning_zh FROM notes"),
                card
            )
        }
        XCTAssertEqual(values.0, 1)
        XCTAssertEqual(values.1, 2)
        XCTAssertEqual(values.2, "builtin_jlpt")
        XCTAssertEqual(values.3, vocabulary.id)
        XCTAssertEqual(values.4, "吃")
        XCTAssertEqual(values.5?.0, 2)
        XCTAssertEqual(values.5?.1, 999_000)
        XCTAssertEqual(values.5?.2, 8.5)
        XCTAssertEqual(values.5?.3, 4.2)
        XCTAssertEqual(values.5?.4, 7)
        XCTAssertEqual(values.5?.5, 7)
        let importedCounts = try await importer.importedCounts()
        XCTAssertEqual(importedCounts[.n5], 1)
        let importedRefs = try await importer.importedSourceRefs([vocabulary.id, "missing"])
        XCTAssertEqual(importedRefs, [vocabulary.id])
    }

    /// T07: 单词导入支持多牌组——home 写 notes.deck_id，全部成员写
    /// note_decks；成员牌组缺失时整体失败、无部分写入。
    func testSingleImportWritesEveryMembershipDeck() async throws {
        let location = try JLPTTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let importer = GRDBJLPTImporter(database: database)
        let homeDeck = UUID()
        let memberDeck = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '归属牌组', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(homeDeck)]
            )
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '成员牌组', 1, 1, 1)",
                arguments: [DatabaseValueCodec.encode(memberDeck)]
            )
        }
        let vocabulary = Self.vocabulary(id: "openjlpt:N5:000101", headword: "飲む")

        let result = try await importer.importVocabulary(
            vocabulary,
            deckID: homeDeck,
            deckIDs: [homeDeck, memberDeck],
            meaningZH: "喝",
            directions: [.japaneseToChinese]
        )
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.deckID, homeDeck)

        let rows = try await database.pool.read { db in
            (
                try Row.fetchAll(
                    db,
                    sql: "SELECT deck_id FROM note_decks"
                ).compactMap { try? DatabaseValueCodec.decodeUUID($0["deck_id"]) },
                try String.fetchOne(
                    db,
                    sql: "SELECT deck_id FROM notes WHERE source_ref = ?",
                    arguments: [vocabulary.id]
                ).flatMap { try? DatabaseValueCodec.decodeUUID($0) }
            )
        }
        XCTAssertEqual(Set(rows.0), [homeDeck, memberDeck])
        XCTAssertEqual(rows.1, homeDeck)
    }

    func testSingleImportMissingMemberDeckWritesNothing() async throws {
        let location = try JLPTTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let importer = GRDBJLPTImporter(database: database)
        let homeDeck = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '归属牌组', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(homeDeck)]
            )
        }
        let vocabulary = Self.vocabulary(id: "openjlpt:N5:000102", headword: "見る")

        do {
            _ = try await importer.importVocabulary(
                vocabulary,
                deckID: homeDeck,
                deckIDs: [homeDeck, UUID()],
                meaningZH: "看",
                directions: [.japaneseToChinese]
            )
            XCTFail("Expected missing member deck to abort the import")
        } catch {
            XCTAssertEqual(error as? JLPTImportError, .deckNotFound)
        }
        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_decks") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testLevelImportUsesBatchesWritesIntoExistingDeckAndCanResumeWithoutDuplicates() async throws {
        let location = try JLPTTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let importer = GRDBJLPTImporter(database: database)
        let deckID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'JLPT 目标', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        var words = (0..<80).map { index in
            Self.vocabulary(
                id: String(format: "openjlpt:N5:%06d", index),
                headword: "詞\(index)"
            )
        }
        words.append(BuiltinJLPTVocabulary(
            id: "openjlpt:N5:missing-zh",
            level: .n5,
            headword: "未匹配",
            reading: "みまっち",
            meaningZH: nil,
            meaningsEN: ["unmatched"],
            partOfSpeech: nil,
            frequencyRank: nil,
            dataFlags: 0
        ))
        let progress = ProgressRecorder()

        let first = try await importer.importLevel(
            .n5,
            vocabulary: words,
            deckID: deckID,
            directions: [.japaneseToChinese]
        ) { value in
            await progress.append(value)
        }
        XCTAssertEqual(first.imported, 80)
        XCTAssertEqual(first.failed, 1)
        let processedValues = await progress.values.map(\.processed)
        XCTAssertEqual(processedValues, [75, 81])

        let second = try await importer.importLevel(
            .n5,
            vocabulary: words,
            deckID: deckID,
            directions: [.japaneseToChinese]
        ) { _ in }
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skipped, 80)
        XCTAssertEqual(second.failed, 1)

        let counts = try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks") ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM notes WHERE deck_id = ?",
                    arguments: [DatabaseValueCodec.encode(deckID)]
                ) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM note_decks WHERE deck_id = ?",
                    arguments: [DatabaseValueCodec.encode(deckID)]
                ) ?? -1
            )
        }
        // v0.5.5：不自动建牌组——全库仍只有预先创建的那一个。
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 80)
        XCTAssertEqual(counts.2, 80)
        XCTAssertEqual(counts.3, 80)
    }

    func testLevelImportRejectsMissingDeck() async throws {
        let location = try JLPTTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        let importer = GRDBJLPTImporter(database: database)
        let words = [Self.vocabulary(id: "openjlpt:N5:000001", headword: "食べる")]

        do {
            _ = try await importer.importLevel(
                .n5,
                vocabulary: words,
                deckID: UUID(),
                directions: [.japaneseToChinese]
            ) { _ in }
            XCTFail("Expected missing deck to abort the level import")
        } catch {
            XCTAssertEqual(error as? JLPTImportError, .deckNotFound)
        }
        let noteCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1
        }
        XCTAssertEqual(noteCount, 0)
    }
}

private actor ProgressRecorder {
    private(set) var values: [JLPTImportProgress] = []

    func append(_ value: JLPTImportProgress) {
        values.append(value)
    }
}

private extension GRDBJLPTLibraryTests {
    struct JLPTTestLocation {
        let rootURL: URL
        let libraryURL: URL
        let userDatabaseURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "GRDBJLPTLibraryTests-\(UUID().uuidString)",
                isDirectory: true
            )
            libraryURL = rootURL.appendingPathComponent("library.sqlite")
            userDatabaseURL = rootURL.appendingPathComponent("user.sqlite")
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    static func vocabulary(id: String, headword: String) -> BuiltinJLPTVocabulary {
        BuiltinJLPTVocabulary(
            id: id,
            level: .n5,
            headword: headword,
            reading: "たべる",
            meaningZH: "吃",
            meaningsEN: ["to eat"],
            partOfSpeech: "动词",
            frequencyRank: 1,
            dataFlags: 0,
            examples: [BuiltinJLPTExample(
                id: "\(id):example:0",
                japanese: "ご飯を食べる。",
                english: "Eat a meal.",
                sortOrder: 0
            )]
        )
    }

    func makeLibrary(at url: URL) throws {
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE vocab (
                    id TEXT PRIMARY KEY NOT NULL,
                    level TEXT NOT NULL,
                    headword TEXT NOT NULL,
                    reading TEXT NOT NULL,
                    meaning_zh TEXT,
                    meaning_en_json TEXT NOT NULL,
                    part_of_speech TEXT,
                    frequency_rank INTEGER,
                    normalized_headword TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL,
                    normalized_meaning_zh TEXT,
                    sort_order INTEGER NOT NULL,
                    data_flags INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE vocab_examples (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
                    japanese TEXT NOT NULL,
                    english TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO vocab VALUES
                    ('openjlpt:N5:000001', 'N5', '食べる', 'たべる', '吃',
                     '["to eat"]', '动词', 1, '食べる', 'たべる', '吃', 0, 0),
                    ('openjlpt:N5:000002', 'N5', '学校', 'がっこう', '学校',
                     '["school"]', '名词', 5, '学校', 'がっこう', '学校', 1, 0),
                    ('openjlpt:N4:000001', 'N4', '意見', 'いけん', '意见',
                     '["opinion"]', '名词', 2, '意見', 'いけん', '意见', 0, 0);
                INSERT INTO vocab_examples VALUES
                    ('example-1', 'openjlpt:N5:000001', 'ご飯を食べる。', 'Eat a meal.', 0),
                    ('example-2', 'openjlpt:N5:000001', '朝ご飯を食べる。', 'I eat breakfast.', 1);
                """)
        }
        try database.close()
    }
}
