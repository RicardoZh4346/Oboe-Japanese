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
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM notes WHERE deck_id = decks.id) AS note_count,
                        (SELECT COUNT(*) FROM cards
                         JOIN notes ON notes.id = cards.note_id
                         WHERE notes.deck_id = decks.id) AS card_count
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
                sql: "DELETE FROM decks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM notes WHERE deck_id = decks.id)",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            return db.changesCount == 1 ? .deleted : .notFound
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
                try db.execute(
                    sql: "UPDATE notes SET deck_id = ?, updated_at_ms = ? WHERE deck_id = ?",
                    arguments: [destinationValue, updatedAtMilliseconds, DatabaseValueCodec.encode(id)]
                )
            case .deleteContents:
                try db.execute(
                    sql: "DELETE FROM notes WHERE deck_id = ?",
                    arguments: [DatabaseValueCodec.encode(id)]
                )
            }

            try db.execute(
                sql: "DELETE FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            return .deleted(impact)
        }
    }

    private static func fetchDeckSummaries(_ db: Database) throws -> [DeckSummary] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    decks.id,
                    decks.name,
                    COUNT(DISTINCT notes.id) AS note_count,
                    COUNT(cards.id) AS card_count
                FROM decks
                LEFT JOIN notes ON notes.deck_id = decks.id
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

    private static func fetchDeletionImpact(id: UUID, in db: Database) throws -> DeckDeletionImpact? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    (SELECT COUNT(*) FROM notes WHERE deck_id = decks.id) AS note_count,
                    (SELECT COUNT(*) FROM cards
                     JOIN notes ON notes.id = cards.note_id
                     WHERE notes.deck_id = decks.id) AS card_count,
                    (SELECT COUNT(*) FROM review_logs
                     WHERE note_id IN (SELECT id FROM notes WHERE deck_id = decks.id)) AS review_log_count
                FROM decks
                WHERE id = ?
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        ) else {
            return nil
        }
        return DeckDeletionImpact(
            noteCount: row["note_count"],
            cardCount: row["card_count"],
            reviewLogCount: row["review_log_count"]
        )
    }
}
