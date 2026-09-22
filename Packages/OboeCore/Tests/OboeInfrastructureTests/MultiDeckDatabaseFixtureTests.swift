import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// T00 baseline: proves the shared multi-deck fixture seeds every scenario the
/// v0.5 tasks rely on, without touching product behavior.
final class MultiDeckDatabaseFixtureTests: XCTestCase {
    func testFixtureSeedsAllBaselineScenarios() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }

        let summary = try await fixture.database.pool.read { db in
            (
                decks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decks") ?? -1,
                notes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                cards: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1,
                logs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? -1,
                admissions: try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM daily_tasks
                        WHERE cancelled_at_ms IS NULL AND category_at_admission = 'new'
                        """
                ) ?? -1
            )
        }
        XCTAssertEqual(summary.decks, 2)
        XCTAssertEqual(summary.notes, 2)
        XCTAssertEqual(summary.cards, 6)
        XCTAssertEqual(summary.logs, 2)
        // 今日 new admission：sharedNote 两个未学方向 + exclusiveNote 三方向。
        XCTAssertEqual(summary.admissions, 5)

        // 主牌组 = deck A。
        let primaryDeck = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT primary_deck_id FROM app_settings WHERE id = 1"
            )
        }
        XCTAssertEqual(primaryDeck, DatabaseValueCodec.encode(fixture.deckAID))

        // 评分历史归因到 deck A，且一次评分只写一条日志。
        let attributions = try await fixture.database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT deck_id_at_review FROM review_logs"
            )
        }
        XCTAssertEqual(attributions, [DatabaseValueCodec.encode(fixture.deckAID)])

        // sharedNote 当前归属 deck A（home）；三方向卡 ID 稳定。
        let sharedDeck = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.sharedNote.noteID)]
            )
        }
        XCTAssertEqual(sharedDeck, DatabaseValueCodec.encode(fixture.deckAID))
        XCTAssertEqual(fixture.sharedNote.cards.count, 3)
        XCTAssertEqual(fixture.sharedNote.membershipDeckIDs, [fixture.deckAID, fixture.deckBID])
        XCTAssertEqual(fixture.exclusiveNote.membershipDeckIDs, [fixture.deckBID])
    }

    func testFixtureMembershipsTrackSchemaAvailability() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }

        try await fixture.database.pool.read { db in
            if try db.tableExists("note_decks") {
                // v13 之后：membershipSpec 已落库，每个 Note 至少一个 membership。
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT note_id, deck_id FROM note_decks ORDER BY note_id, deck_id"
                )
                var memberships: [String: Set<String>] = [:]
                for row in rows {
                    let noteID: String = row["note_id"]
                    memberships[noteID, default: []].insert(row["deck_id"])
                }
                for (noteID, spec) in fixture.membershipSpec {
                    let encoded = DatabaseValueCodec.encode(noteID)
                    XCTAssertEqual(
                        memberships[encoded],
                        Set(spec.deckIDs.map(DatabaseValueCodec.encode))
                    )
                    XCTAssertTrue(spec.deckIDs.contains(spec.homeDeckID))
                }
            } else {
                // v12 基线：note_decks 尚不存在，home deck 由 notes.deck_id 承载。
                XCTAssertEqual(
                    fixture.membershipSpec[fixture.sharedNote.noteID]?.homeDeckID,
                    fixture.deckAID
                )
            }
        }
    }

    func testFixtureForeignKeysAndIntegrityHold() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }

        try await fixture.database.pool.read { db in
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            XCTAssertTrue(violations.isEmpty, "foreign_key_check: \(violations)")
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            XCTAssertEqual(integrity, "ok")
        }
    }
}
