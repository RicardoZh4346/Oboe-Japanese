import Foundation
import GRDB
import OboeDomain

public struct GRDBDeckRepository: DeckRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func deckExists(id: UUID) async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                arguments: [DatabaseValueCodec.encode(id)]
            ) ?? false
        }
    }

    public func fetchDeckSummaries() async throws -> [DeckSummary] {
        try await pool.read(Self.fetchDeckSummaries)
    }

    public func observeDeckSummaries() -> AsyncThrowingStream<[DeckSummary], Error> {
        let observation = ValueObservation.tracking(Self.fetchDeckSummaries)
        let values = observation.values(
            in: pool,
            bufferingPolicy: .bufferingNewest(1)
        )

        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await summaries in values {
                        guard !Task.isCancelled else {
                            break
                        }
                        continuation.yield(summaries)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    public func createDeck(id: UUID, name: String, at date: Date) async throws -> Deck {
        let milliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            let sortOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM decks"
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    name,
                    sortOrder,
                    milliseconds,
                    milliseconds
                ]
            )
            return Deck(
                id: id,
                name: name,
                sortOrder: sortOrder,
                createdAt: DatabaseValueCodec.decodeDate(milliseconds: milliseconds),
                updatedAt: DatabaseValueCodec.decodeDate(milliseconds: milliseconds)
            )
        }
    }

    public func renameDeck(id: UUID, name: String, at date: Date) async throws -> Bool {
        let milliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try db.execute(
                sql: "UPDATE decks SET name = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [name, milliseconds, DatabaseValueCodec.encode(id)]
            )
            return db.changesCount == 1
        }
    }

    public func deleteDeckIfEmpty(id: UUID) async throws -> DeckDeletionResult {
        try await pool.write { db in
            // 空牌组 = `note_decks` 中无任何成员（home deck 也必为成员）。
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM note_decks WHERE deck_id = decks.id) AS note_count,
                        (SELECT COUNT(DISTINCT cards.id) FROM cards
                         JOIN note_decks nd ON nd.note_id = cards.note_id
                         WHERE nd.deck_id = decks.id) AS card_count
                    FROM decks
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            ) else {
                return .notFound
            }

            let noteCount: Int = row["note_count"]
            let cardCount: Int = row["card_count"]
            guard noteCount == 0 && cardCount == 0 else {
                return .notEmpty(noteCount: noteCount, cardCount: cardCount)
            }

            try db.execute(
                sql: "UPDATE app_settings SET primary_deck_id = NULL WHERE primary_deck_id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            try db.execute(
                sql: "DELETE FROM decks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM note_decks WHERE deck_id = decks.id)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            return db.changesCount == 1 ? .deleted : .notFound
        }
    }

    public func previewDeletionImpact(id: UUID) async throws -> DeckDeletionImpact? {
        try await pool.read { db in
            try Self.fetchDeletionImpact(id: id, in: db)
        }
    }

    public func deleteDeck(
        id: UUID,
        strategy: DeckDeletionStrategy,
        at date: Date
    ) async throws -> ManagedDeckDeletionResult {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard let impact = try Self.fetchDeletionImpact(id: id, in: db) else {
                return .sourceNotFound
            }

            switch strategy {
            case let .moveContents(destinationDeckID):
                guard destinationDeckID != id else {
                    return .destinationMatchesSource
                }
                let destinationValue = DatabaseValueCodec.encode(destinationDeckID)
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                    arguments: [destinationValue]
                ) == true else {
                    return .destinationNotFound
                }
                // 1) 给全部源成员补目标成员关系（已是成员的跳过，共享
                //    Note 保持其余成员关系不变）。
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        SELECT note_id, ?, ? FROM note_decks WHERE deck_id = ?
                        ON CONFLICT(note_id, deck_id) DO NOTHING
                        """,
                    arguments: [destinationValue, updatedAtMilliseconds, DatabaseValueCodec.encode(id)]
                )
                // 防御：home=源牌组但缺成员行的 Note 也补目标成员关系。
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        SELECT id, ?, ? FROM notes WHERE deck_id = ?
                        ON CONFLICT(note_id, deck_id) DO NOTHING
                        """,
                    arguments: [destinationValue, updatedAtMilliseconds, DatabaseValueCodec.encode(id)]
                )
                // 2) home=源牌组的 Note 切换 home 到目标牌组。
                try db.execute(
                    sql: "UPDATE notes SET deck_id = ?, updated_at_ms = ? WHERE deck_id = ?",
                    arguments: [destinationValue, updatedAtMilliseconds, DatabaseValueCodec.encode(id)]
                )
                // 3) 移除源牌组全部成员关系。
                try db.execute(
                    sql: "DELETE FROM note_decks WHERE deck_id = ?",
                    arguments: [DatabaseValueCodec.encode(id)]
                )
            case .deleteContents:
                let encodedID = DatabaseValueCodec.encode(id)
                // 1) 删除独占 Note（唯一成员是本牌组，home 必在其中）；
                //    cards/review_logs/note_decks 由外键级联清理。
                try db.execute(
                    sql: """
                        DELETE FROM notes
                        WHERE deck_id = ?
                          AND NOT EXISTS (
                              SELECT 1 FROM note_decks nd
                              WHERE nd.note_id = notes.id AND nd.deck_id <> ?
                          )
                        """,
                    arguments: [encodedID, encodedID]
                )
                // 2) home=源牌组的共享 Note 重新选 home：剩余成员中按
                //    decks.sort_order/created_at_ms/id 排序的第一个。
                try db.execute(
                    sql: """
                        UPDATE notes
                        SET deck_id = (
                            SELECT nd.deck_id FROM note_decks nd
                            JOIN decks d ON d.id = nd.deck_id
                            WHERE nd.note_id = notes.id AND nd.deck_id <> ?
                            ORDER BY d.sort_order, d.created_at_ms, d.id
                            LIMIT 1
                        ),
                        updated_at_ms = ?
                        WHERE deck_id = ?
                        """,
                    arguments: [encodedID, updatedAtMilliseconds, encodedID]
                )
                // 3) 移除源牌组全部成员关系。
                try db.execute(
                    sql: "DELETE FROM note_decks WHERE deck_id = ?",
                    arguments: [encodedID]
                )
            }

            try db.execute(
                sql: "UPDATE app_settings SET primary_deck_id = NULL WHERE primary_deck_id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            try db.execute(
                sql: "DELETE FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            return .deleted(impact)
        }
    }

    /// 牌组摘要按 `note_decks` 成员关系计数：共享 Note/Card 在其所属的
    /// 每个牌组各计一次（设计 §4.5）。
    private static func fetchDeckSummaries(_ db: Database) throws -> [DeckSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    decks.id,
                    decks.name,
                    COUNT(DISTINCT notes.id) AS note_count,
                    COUNT(DISTINCT cards.id) AS card_count
                FROM decks
                LEFT JOIN note_decks nd ON nd.deck_id = decks.id
                LEFT JOIN notes ON notes.id = nd.note_id
                LEFT JOIN cards ON cards.note_id = notes.id
                GROUP BY decks.id
                ORDER BY decks.sort_order, decks.created_at_ms, decks.id
                """
        )
        return try rows.map { row in
            try DeckSummary(
                id: DatabaseValueCodec.decodeUUID(row["id"]),
                name: row["name"],
                noteCount: row["note_count"],
                cardCount: row["card_count"]
            )
        }
    }

    /// 删除影响统计（设计 §4.8）：noteCount/cardCount/reviewLogCount 按
    /// 成员关系去重计数；exclusive/shared 区分 deleteContents 时会真正
    /// 删除的 Note 与仅移除成员关系的共享 Note。
    private static func fetchDeletionImpact(id: UUID, in db: Database) throws -> DeckDeletionImpact? {
        let encodedID = DatabaseValueCodec.encode(id)
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    (SELECT COUNT(*) FROM note_decks WHERE deck_id = decks.id) AS note_count,
                    (SELECT COUNT(DISTINCT cards.id) FROM cards
                     JOIN note_decks nd ON nd.note_id = cards.note_id
                     WHERE nd.deck_id = decks.id) AS card_count,
                    (SELECT COUNT(DISTINCT review_logs.id) FROM review_logs
                     JOIN note_decks nd ON nd.note_id = review_logs.note_id
                     WHERE nd.deck_id = decks.id) AS review_log_count,
                    (SELECT COUNT(*) FROM notes
                     WHERE deck_id = decks.id
                       AND NOT EXISTS (
                           SELECT 1 FROM note_decks nd
                           WHERE nd.note_id = notes.id AND nd.deck_id <> decks.id
                       )) AS exclusive_note_count,
                    (SELECT COUNT(*) FROM cards
                     JOIN notes n ON n.id = cards.note_id
                     WHERE n.deck_id = decks.id
                       AND NOT EXISTS (
                           SELECT 1 FROM note_decks nd
                           WHERE nd.note_id = n.id AND nd.deck_id <> decks.id
                       )) AS exclusive_card_count
                FROM decks
                WHERE id = ?
                """,
            arguments: [encodedID]
        ) else {
            return nil
        }
        let noteCount: Int = row["note_count"]
        let exclusiveCount: Int = row["exclusive_note_count"]
        return DeckDeletionImpact(
            noteCount: noteCount,
            cardCount: row["card_count"],
            reviewLogCount: row["review_log_count"],
            exclusiveNoteCount: exclusiveCount,
            exclusiveCardCount: row["exclusive_card_count"],
            sharedNoteCount: noteCount - exclusiveCount
        )
    }
}
