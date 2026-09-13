import Foundation
import GRDB
import OboeDomain

public final class GRDBJLPTLibraryRepository: JLPTLibraryRepository, @unchecked Sendable {
    private let database: DatabaseQueue

    public init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.label = "Oboe built-in JLPT library"
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }

    deinit {
        try? database.close()
    }

    public func levelCounts() async throws -> [JLPTLevel: Int] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT level, COUNT(*) AS count FROM vocab GROUP BY level"
            )
            return Dictionary(uniqueKeysWithValues: try rows.map { row in
                let rawLevel: String = row["level"]
                guard let level = JLPTLevel(rawValue: rawLevel) else {
                    throw JLPTLibraryDatabaseError.invalidLevel(rawLevel)
                }
                let count: Int = row["count"]
                return (level, count)
            })
        }
    }

    public func vocabulary(
        level: JLPTLevel,
        query: String,
        sort: JLPTLibrarySort,
        limit: Int,
        offset: Int
    ) async throws -> JLPTLibraryPage {
        try await database.read { db in
            var arguments: StatementArguments = [level.rawValue]
            var predicate = "level = ?"
            if !query.isEmpty {
                let pattern = "%\(Self.escapeLike(query))%"
                predicate += " AND (normalized_headword LIKE ? ESCAPE '\\'"
                    + " OR normalized_reading LIKE ? ESCAPE '\\'"
                    + " OR COALESCE(normalized_meaning_zh, '') LIKE ? ESCAPE '\\')"
                arguments += [pattern, pattern, pattern]
            }
            arguments += [limit + 1, offset]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, level, headword, reading, meaning_zh, meaning_en_json,
                           part_of_speech, frequency_rank, data_flags,
                           (SELECT id FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_id,
                           (SELECT japanese FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_japanese,
                           (SELECT english FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_english,
                           (SELECT sort_order FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_sort_order
                    FROM vocab
                    WHERE \(predicate)
                    ORDER BY \(Self.orderClause(for: sort))
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            let hasMore = rows.count > limit
            let items = try rows.prefix(limit).map {
                try Self.decodeVocabulary($0, examples: Self.decodePreviewExamples($0))
            }
            return JLPTLibraryPage(
                items: items,
                nextOffset: hasMore ? offset + items.count : nil
            )
        }
    }

    public func vocabulary(id: String) async throws -> BuiltinJLPTVocabulary? {
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, level, headword, reading, meaning_zh, meaning_en_json,
                           part_of_speech, frequency_rank, data_flags
                    FROM vocab WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            let exampleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, japanese, english, sort_order
                    FROM vocab_examples WHERE vocab_id = ?
                    ORDER BY sort_order, id
                    """,
                arguments: [id]
            )
            let examples = exampleRows.map { example in
                BuiltinJLPTExample(
                    id: example["id"],
                    japanese: example["japanese"],
                    english: example["english"],
                    sortOrder: example["sort_order"]
                )
            }
            return try Self.decodeVocabulary(row, examples: examples)
        }
    }

    private static func orderClause(for sort: JLPTLibrarySort) -> String {
        switch sort {
        case .source:
            "sort_order, id"
        case .frequency:
            "frequency_rank IS NULL, frequency_rank, sort_order, id"
        case .kana:
            "normalized_reading, normalized_headword, id"
        }
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func decodeVocabulary(
        _ row: Row,
        examples: [BuiltinJLPTExample] = []
    ) throws -> BuiltinJLPTVocabulary {
        let rawLevel: String = row["level"]
        guard let level = JLPTLevel(rawValue: rawLevel) else {
            throw JLPTLibraryDatabaseError.invalidLevel(rawLevel)
        }
        let meaningsJSON: String = row["meaning_en_json"]
        guard let data = meaningsJSON.data(using: .utf8),
              let meanings = try? JSONDecoder().decode([String].self, from: data) else {
            throw JLPTLibraryDatabaseError.invalidEnglishMeanings
        }
        return BuiltinJLPTVocabulary(
            id: row["id"],
            level: level,
            headword: row["headword"],
            reading: row["reading"],
            meaningZH: row["meaning_zh"],
            meaningsEN: meanings,
            partOfSpeech: row["part_of_speech"],
            frequencyRank: row["frequency_rank"],
            dataFlags: row["data_flags"],
            examples: examples
        )
    }

    private static func decodePreviewExamples(_ row: Row) -> [BuiltinJLPTExample] {
        guard let id: String = row["example_id"],
              let japanese: String = row["example_japanese"] else {
            return []
        }
        let english: String? = row["example_english"]
        let sortOrder: Int = row["example_sort_order"]
        return [BuiltinJLPTExample(
            id: id,
            japanese: japanese,
            english: english,
            sortOrder: sortOrder
        )]
    }
}

public enum JLPTLibraryDatabaseError: Error, Equatable, Sendable {
    case invalidLevel(String)
    case invalidEnglishMeanings
}
