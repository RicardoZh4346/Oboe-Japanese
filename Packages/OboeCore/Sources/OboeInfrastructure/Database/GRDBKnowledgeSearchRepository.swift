import Foundation
import GRDB
import OboeDomain

public struct GRDBKnowledgeSearchRepository: KnowledgeSearchRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func search(
        normalizedQuery: String,
        deckID: UUID?,
        limit: Int,
        offset: Int
    ) async throws -> KnowledgeSearchPage {
        guard limit > 0, offset >= 0 else {
            return KnowledgeSearchPage(items: [], nextOffset: nil)
        }
        let containsPattern = Self.likePattern(for: normalizedQuery, prefixOnly: false)
        let prefixPattern = Self.likePattern(for: normalizedQuery, prefixOnly: true)
        return try await pool.read { db in
            var deckClause = ""
            var arguments: [DatabaseValueConvertible?] = [
                containsPattern, containsPattern, containsPattern
            ]
            if let deckID {
                deckClause = "AND notes.deck_id = ?"
                arguments.append(DatabaseValueCodec.encode(deckID))
            }
            arguments.append(normalizedQuery)
            arguments.append(normalizedQuery)
            arguments.append(prefixPattern)
            arguments.append(prefixPattern)
            arguments.append(prefixPattern)
            arguments.append(limit + 1)
            arguments.append(offset)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT notes.id, notes.deck_id, notes.kind, notes.headword,
                           notes.reading, notes.meaning_zh, notes.usage, notes.is_favorite
                    FROM search_documents
                    JOIN notes ON notes.id = search_documents.note_id
                    WHERE (
                        search_documents.normalized_headword LIKE ? ESCAPE '\\'
                        OR search_documents.normalized_reading LIKE ? ESCAPE '\\'
                        OR search_documents.normalized_meaning LIKE ? ESCAPE '\\'
                    )
                    \(deckClause)
                    ORDER BY CASE
                        WHEN search_documents.normalized_headword = ? THEN 0
                        WHEN search_documents.normalized_reading = ? THEN 1
                        WHEN search_documents.normalized_headword LIKE ? ESCAPE '\\'
                          OR search_documents.normalized_reading LIKE ? ESCAPE '\\'
                          OR search_documents.normalized_meaning LIKE ? ESCAPE '\\' THEN 2
                        ELSE 3
                    END,
                    notes.id
                    LIMIT ? OFFSET ?
                    """,
                arguments: StatementArguments(arguments)
            )
            let hasMore = rows.count > limit
            let items = try rows.prefix(limit).map(Self.decodeSummary)
            return KnowledgeSearchPage(
                items: items,
                nextOffset: hasMore ? offset + items.count : nil
            )
        }
    }

    private static func likePattern(for query: String, prefixOnly: Bool) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return prefixOnly ? "\(escaped)%" : "%\(escaped)%"
    }

    private static func decodeSummary(_ row: Row) throws -> KnowledgePointSummary {
        let kindValue: String = row["kind"]
        guard let kind = KnowledgePointKind(rawValue: kindValue) else {
            throw GRDBKnowledgePointRepositoryError.invalidKnowledgePointKind(kindValue)
        }
        let id: String = row["id"]
        let deckID: String = row["deck_id"]
        return KnowledgePointSummary(
            id: try DatabaseValueCodec.decodeUUID(id),
            deckID: try DatabaseValueCodec.decodeUUID(deckID),
            kind: kind,
            headword: row["headword"],
            reading: row["reading"],
            meaningZH: row["meaning_zh"],
            usage: row["usage"],
            isFavorite: (row["is_favorite"] as Int) != 0
        )
    }
}
