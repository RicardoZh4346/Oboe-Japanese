import Foundation
import GRDB
import OboeDomain

public enum GRDBKnowledgePointRepositoryError: Error, Equatable, Sendable {
    case invalidKnowledgePointKind(String)
}

public struct GRDBKnowledgePointRepository: KnowledgePointRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func fetchKnowledgePointSummaries(deckID: UUID) async throws -> [KnowledgePointSummary] {
        try await pool.read { db in
            try Self.fetchSummaries(
                sql: """
                    SELECT id, deck_id, kind, headword, reading, meaning_zh, usage, is_favorite
                    FROM notes
                    WHERE deck_id = ?
                    ORDER BY created_at_ms, id
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)],
                in: db
            )
        }
    }

    public func fetchFavoriteSummaries() async throws -> [KnowledgePointSummary] {
        try await pool.read { db in
            try Self.fetchSummaries(
                sql: """
                    SELECT id, deck_id, kind, headword, reading, meaning_zh, usage, is_favorite
                    FROM notes
                    WHERE is_favorite = 1
                    ORDER BY updated_at_ms DESC, id
                    """,
                arguments: StatementArguments(),
                in: db
            )
        }
    }

    public func fetchDuplicateSummaries(
        kind: KnowledgePointKind,
        headword: String,
        reading: String?,
        excluding noteID: UUID?
    ) async throws -> [KnowledgePointSummary] {
        try await pool.read { db in
            var sql = """
                SELECT id, deck_id, kind, headword, reading, meaning_zh, usage, is_favorite
                FROM notes
                WHERE kind = ? AND trim(headword) = ?
                """
            var arguments: [DatabaseValueConvertible?] = [kind.rawValue, headword]
            if kind == .vocabulary {
                sql += " AND COALESCE(trim(reading), '') = ?"
                arguments.append(reading ?? "")
            }
            if let noteID {
                sql += " AND id <> ?"
                arguments.append(DatabaseValueCodec.encode(noteID))
            }
            sql += " ORDER BY created_at_ms, id"
            return try Self.fetchSummaries(
                sql: sql,
                arguments: StatementArguments(arguments),
                in: db
            )
        }
    }

    public func fetchMetadata(noteID: UUID) async throws -> KnowledgePointMetadata? {
        try await pool.read { db in
            guard let favorite = try Int.fetchOne(
                db,
                sql: "SELECT is_favorite FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) else {
                return nil
            }

            let tags = try Row.fetchAll(
                db,
                sql: """
                    SELECT tags.id, tags.name, tags.normalized_name
                    FROM tags
                    JOIN note_tags ON note_tags.tag_id = tags.id
                    WHERE note_tags.note_id = ?
                    ORDER BY tags.normalized_name, tags.id
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            ).map(Self.decodeTag)
            return KnowledgePointMetadata(isFavorite: favorite != 0, tags: tags)
        }
    }

    public func setFavorite(noteID: UUID, isFavorite: Bool, at date: Date) async throws -> Bool {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            try db.execute(
                sql: "UPDATE notes SET is_favorite = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [
                    isFavorite ? 1 : 0,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            return db.changesCount > 0
        }
    }

    public func replaceTags(noteID: UUID, tags: [KnowledgeTag], at date: Date) async throws -> Bool {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ?)",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) == true else {
                return false
            }

            try db.execute(
                sql: "DELETE FROM note_tags WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )

            for tag in tags {
                try db.execute(
                    sql: """
                        INSERT INTO tags(id, name, normalized_name)
                        VALUES (?, ?, ?)
                        ON CONFLICT(normalized_name) DO NOTHING
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(tag.id),
                        tag.name,
                        tag.normalizedName
                    ]
                )
                guard let persistedTagID = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM tags WHERE normalized_name = ?",
                    arguments: [tag.normalizedName]
                ) else {
                    continue
                }
                try db.execute(
                    sql: "INSERT INTO note_tags(note_id, tag_id) VALUES (?, ?)",
                    arguments: [DatabaseValueCodec.encode(noteID), persistedTagID]
                )
            }

            try db.execute(
                sql: "UPDATE notes SET updated_at_ms = ? WHERE id = ?",
                arguments: [updatedAtMilliseconds, DatabaseValueCodec.encode(noteID)]
            )
            return true
        }
    }

    public func moveKnowledgePoint(
        noteID: UUID,
        to destinationDeckID: UUID,
        at date: Date
    ) async throws -> KnowledgePointMoveResult {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard let sourceDeckValue = try String.fetchOne(
                db,
                sql: "SELECT deck_id FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) else {
                return .noteNotFound
            }
            let destinationValue = DatabaseValueCodec.encode(destinationDeckID)
            guard sourceDeckValue != destinationValue else {
                return .alreadyInDestination
            }
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                arguments: [destinationValue]
            ) == true else {
                return .destinationNotFound
            }
            let cardCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) ?? 0
            try db.execute(
                sql: "UPDATE notes SET deck_id = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [destinationValue, updatedAtMilliseconds, DatabaseValueCodec.encode(noteID)]
            )
            return .moved(cardCount: cardCount)
        }
    }

    public func fetchDeletionImpact(noteID: UUID) async throws -> KnowledgePointDeletionImpact? {
        try await pool.read { db in
            try Self.fetchDeletionImpact(noteID: noteID, in: db)
        }
    }

    public func deleteKnowledgePoint(noteID: UUID) async throws -> KnowledgePointDeletionResult {
        try await pool.write { db in
            guard let impact = try Self.fetchDeletionImpact(noteID: noteID, in: db) else {
                return .notFound
            }
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            return .deleted(impact)
        }
    }

    private static func fetchSummaries(
        sql: String,
        arguments: StatementArguments,
        in db: Database
    ) throws -> [KnowledgePointSummary] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            let idValue: String = row["id"]
            let deckIDValue: String = row["deck_id"]
            let kindValue: String = row["kind"]
            guard let kind = KnowledgePointKind(rawValue: kindValue) else {
                throw GRDBKnowledgePointRepositoryError.invalidKnowledgePointKind(kindValue)
            }
            let headword: String = row["headword"]
            let reading: String? = row["reading"]
            let meaningZH: String = row["meaning_zh"]
            let usage: String? = row["usage"]
            let favorite: Int = row["is_favorite"]
            return KnowledgePointSummary(
                id: try DatabaseValueCodec.decodeUUID(idValue),
                deckID: try DatabaseValueCodec.decodeUUID(deckIDValue),
                kind: kind,
                headword: headword,
                reading: reading,
                meaningZH: meaningZH,
                usage: usage,
                isFavorite: favorite != 0
            )
        }
    }

    private static func fetchDeletionImpact(
        noteID: UUID,
        in db: Database
    ) throws -> KnowledgePointDeletionImpact? {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ?)",
            arguments: [DatabaseValueCodec.encode(noteID)]
        ) == true else {
            return nil
        }
        let cardCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        ) ?? 0
        let reviewLogCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM review_logs WHERE note_id = ?",
            arguments: [DatabaseValueCodec.encode(noteID)]
        ) ?? 0
        return KnowledgePointDeletionImpact(
            cardCount: cardCount,
            reviewLogCount: reviewLogCount
        )
    }

    private static func decodeTag(_ row: Row) throws -> KnowledgeTag {
        let idValue: String = row["id"]
        let name: String = row["name"]
        let normalizedName: String = row["normalized_name"]
        return KnowledgeTag(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            name: name,
            normalizedName: normalizedName
        )
    }
}
