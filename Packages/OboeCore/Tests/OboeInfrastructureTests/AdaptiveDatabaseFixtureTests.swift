import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T00 baseline: proves the shared adaptive fixture seeds every scenario the
/// v0.4 tasks rely on, without touching product behavior.
final class AdaptiveDatabaseFixtureTests: XCTestCase {
    func testFixtureSeedsAllBaselineScenarios() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }

        let summary = try await fixture.database.pool.read { db in
            (
                decks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks") ?? -1,
                notes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                cards: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                logs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? -1,
                undone: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM review_logs WHERE undone_at_ms IS NOT NULL"
                ) ?? -1,
                orphaned: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM review_logs WHERE card_id IS NULL"
                ) ?? -1
            )
        }
        XCTAssertEqual(summary.decks, 2)
        XCTAssertEqual(summary.notes, 4)
        XCTAssertEqual(summary.cards, 6)
        XCTAssertEqual(summary.logs, 9)
        XCTAssertEqual(summary.undone, 1)
        XCTAssertEqual(summary.orphaned, 1)

        // 无日志新卡：fresh note 的两个方向都没有 review_logs。
        let freshLogCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM review_logs
                    WHERE card_key IN (?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(
                        fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
                    ),
                    DatabaseValueCodec.encode(
                        fixture.freshNote.cardID(.vocabularyChineseToJapanese)
                    )
                ]
            )
        }
        XCTAssertEqual(freshLogCount, 0)

        // 累计遗忘卡：lapses=6 且带到期 Review 连续 Again 证据。
        let lapsedCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        let (lapses, lapsedLogCount) = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT lapses FROM cards WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(lapsedCard)]
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM review_logs
                        WHERE card_key = ? AND undone_at_ms IS NULL AND rating = 1
                        """,
                    arguments: [DatabaseValueCodec.encode(lapsedCard)]
                ) ?? -1
            )
        }
        XCTAssertEqual(lapses, 6)
        XCTAssertEqual(lapsedLogCount, 5)
    }

    func testFixtureForeignKeysAndIntegrityHold() async throws {
        let fixture = try await AdaptiveDatabaseFixture.make()
        defer { fixture.remove() }

        try await fixture.database.pool.read { db in
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            XCTAssertTrue(violations.isEmpty, "foreign_key_check: \(violations)")
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            XCTAssertEqual(integrity, "ok")
        }
    }
}
