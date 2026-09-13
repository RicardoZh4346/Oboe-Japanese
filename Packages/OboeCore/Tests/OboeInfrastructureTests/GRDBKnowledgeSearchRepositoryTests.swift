import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class GRDBKnowledgeSearchRepositoryTests: XCTestCase {
    func testNormalizerUnifiesWidthCaseAndKanaWithoutDroppingDakuten() {
        XCTAssertEqual(SearchTextNormalizer.normalize(" ＡＢＣ "), "abc")
        XCTAssertEqual(SearchTextNormalizer.normalize("ｶﾞｯﾂ"), "がっつ")
        XCTAssertEqual(SearchTextNormalizer.normalize("ガッツ"), "がっつ")
        XCTAssertEqual(SearchTextNormalizer.normalize("がっつ"), "がっつ")
        XCTAssertNotEqual(
            SearchTextNormalizer.normalize("か"),
            SearchTextNormalizer.normalize("が")
        )
    }

    func testSearchMatchesJapaneseKanaHalfWidthChineseAndLiteralWildcardsWithStableRanking() async throws {
        let fixture = try SearchTestFixture()
        defer { fixture.remove() }
        let database = try OboeDatabase(path: fixture.databaseURL.path)
        let firstDeckID = uuid(100)
        let secondDeckID = uuid(200)
        try await database.pool.write { db in
            try insertDeck(firstDeckID, name: "第一组", in: db)
            try insertDeck(secondDeckID, name: "第二组", in: db)
            try insertNote(uuid(1), deckID: firstDeckID, headword: "食", reading: "しょく", meaning: "食", in: db)
            try insertNote(uuid(2), deckID: firstDeckID, headword: "食べる", reading: "たべる", meaning: "吃", in: db)
            try insertNote(uuid(3), deckID: firstDeckID, headword: "朝食", reading: "ちょうしょく", meaning: "早餐", in: db)
            try insertNote(uuid(4), deckID: secondDeckID, headword: "食堂", reading: "しょくどう", meaning: "食堂", in: db)
            try insertNote(uuid(5), deckID: firstDeckID, headword: "片仮名", reading: "カタカナ", meaning: "片假名", in: db)
            try insertNote(uuid(6), deckID: firstDeckID, headword: "ﾃｽﾄ", reading: "てすと", meaning: "测试", in: db)
            try insertNote(uuid(7), deckID: firstDeckID, headword: "%_", reading: nil, meaning: "百分号下划线", in: db)
            try insertNote(uuid(8), deckID: firstDeckID, headword: "其他", reading: nil, meaning: "普通内容", in: db)
        }
        let service = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )

        let food = try await service.search("食")
        XCTAssertEqual(food.items.map(\.headword), ["食", "食べる", "食堂", "朝食"])
        XCTAssertEqual(Set(food.items.map(\.id)).count, food.items.count)
        let deckFood = try await service.search("食", deckID: firstDeckID)
        XCTAssertEqual(deckFood.items.map(\.headword), ["食", "食べる", "朝食"])
        let hiragana = try await service.search("かた")
        let halfWidthKana = try await service.search("ｶﾀ")
        let fullWidthKana = try await service.search("テスト")
        let chinese = try await service.search("测试")
        let literalWildcards = try await service.search("%_")
        XCTAssertEqual(hiragana.items.map(\.headword), ["片仮名"])
        XCTAssertEqual(halfWidthKana.items.map(\.headword), ["片仮名"])
        XCTAssertEqual(fullWidthKana.items.map(\.headword), ["ﾃｽﾄ"])
        XCTAssertEqual(chinese.items.map(\.headword), ["ﾃｽﾄ"])
        XCTAssertEqual(literalWildcards.items.map(\.headword), ["%_"])
    }

    func testIndexBackfillsAndTracksInsertUpdateDelete() async throws {
        let fixture = try SearchTestFixture()
        defer { fixture.remove() }
        let database = try OboeDatabase(path: fixture.databaseURL.path)
        let deckID = uuid(100)
        let noteID = uuid(1)
        try await database.pool.write { db in
            try insertDeck(deckID, name: "索引", in: db)
            try insertNote(noteID, deckID: deckID, headword: "ガラス", reading: "ガラス", meaning: "玻璃", in: db)
        }
        let service = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )
        let beforeUpdate = try await service.search("がら")
        XCTAssertEqual(beforeUpdate.items.map(\.id), [noteID])

        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET headword = '硝子', reading = 'しょうじ', meaning_zh = '玻璃制品' WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
        let oldTerm = try await service.search("がら")
        let newReading = try await service.search("しょう")
        let newMeaning = try await service.search("制品")
        XCTAssertTrue(oldTerm.items.isEmpty)
        XCTAssertEqual(newReading.items.map(\.id), [noteID])
        XCTAssertEqual(newMeaning.items.map(\.id), [noteID])

        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
        let afterDelete = try await service.search("しょう")
        XCTAssertTrue(afterDelete.items.isEmpty)
        let indexCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents")
        }
        XCTAssertEqual(indexCount, 0)
    }

    func testSearchPaginatesAtFiftyWithoutDuplicatingKnowledgePoints() async throws {
        let fixture = try SearchTestFixture()
        defer { fixture.remove() }
        let database = try OboeDatabase(path: fixture.databaseURL.path)
        let deckID = uuid(100)
        try await database.pool.write { db in
            try insertDeck(deckID, name: "分页", in: db)
            for index in 1...51 {
                try insertNote(
                    uuid(index),
                    deckID: deckID,
                    headword: "项目\(index)共同词",
                    reading: nil,
                    meaning: "分页",
                    in: db
                )
            }
        }
        let service = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )

        let first = try await service.search("共同")
        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(first.nextOffset, 50)
        let second = try await service.search("共同", offset: try XCTUnwrap(first.nextOffset))
        XCTAssertEqual(second.items.count, 1)
        XCTAssertNil(second.nextOffset)
        XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
    }

    func testTenThousandKnowledgePointContainsSearchP95StaysBelowTarget() async throws {
        let fixture = try SearchTestFixture()
        defer { fixture.remove() }
        let database = try OboeDatabase(path: fixture.databaseURL.path)
        let deckID = uuid(100)
        try await database.pool.write { db in
            try insertDeck(deckID, name: "性能", in: db)
            for index in 1...10_000 {
                try insertNote(
                    UUID(),
                    deckID: deckID,
                    headword: "性能词条\(index)",
                    reading: "せいのう\(index)",
                    meaning: index == 9_999 ? "唯一目标针" : "普通释义\(index)",
                    in: db
                )
            }
        }
        let service = KnowledgeSearchService(
            repository: GRDBKnowledgeSearchRepository(database: database)
        )
        _ = try await service.search("不存在的预热查询")
        var durations: [TimeInterval] = []
        for _ in 0..<20 {
            let started = Date.timeIntervalSinceReferenceDate
            let page = try await service.search("目标针")
            durations.append(Date.timeIntervalSinceReferenceDate - started)
            XCTAssertEqual(page.items.count, 1)
        }
        let sorted = durations.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(String(format: "P15_SEARCH_10K_P95_MS=%.3f", p95 * 1_000))
        XCTAssertLessThan(p95, 0.2, "10k knowledge-point search p95 was \(p95)s")
    }
}

private struct SearchTestFixture {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GRDBKnowledgeSearchRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        databaseURL = rootURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func insertDeck(_ id: UUID, name: String, in db: Database) throws {
    try db.execute(
        sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, ?, 0, 1, 1)",
        arguments: [DatabaseValueCodec.encode(id), name]
    )
}

private func insertNote(
    _ id: UUID,
    deckID: UUID,
    headword: String,
    reading: String?,
    meaning: String,
    in db: Database
) throws {
    try db.execute(
        sql: """
            INSERT INTO notes(
                id, deck_id, kind, headword, reading, meaning_zh,
                origin, content_version, created_at_ms, updated_at_ms
            ) VALUES (?, ?, 'vocabulary', ?, ?, ?, 'manual', 1, 1, 1)
            """,
        arguments: [DatabaseValueCodec.encode(id), DatabaseValueCodec.encode(deckID), headword, reading, meaning]
    )
}
