import Foundation
import GRDB
import OboeDomain

public final class GRDBJLPTLibraryRepository: JLPTLibraryRepository, JLPTEnrichmentSource, @unchecked Sendable {
    private let database: DatabaseQueue
    /// 词库 schema v2 列探测（T12）：v1 库没有音调/例句中文列，
    /// 对应字段统一读出 nil，SQL 也不引用不存在的列。
    private let hasPitchColumns: Bool
    private let hasExampleTranslation: Bool

    public init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.foreignKeysEnabled = true
        configuration.label = "Oboe built-in JLPT library"
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        let flags = try queue.read { db in
            let vocabColumns = try db.tableExists("vocab")
                ? Set(db.columns(in: "vocab").map(\.name))
                : []
            let exampleColumns = try db.tableExists("vocab_examples")
                ? Set(db.columns(in: "vocab_examples").map(\.name))
                : []
            return (
                vocabColumns.isSuperset(of: [
                    "pitch_accent", "pitch_source", "pitch_source_ref",
                ]),
                exampleColumns.contains("translation_zh")
            )
        }
        hasPitchColumns = flags.0
        hasExampleTranslation = flags.1
        database = queue
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

    public func vocabularyRefs(levels: [JLPTLevel]) async throws -> [JLPTVocabularyRef] {
        guard !levels.isEmpty else { return [] }
        let placeholders = levels.map { _ in "?" }.joined(separator: ",")
        return try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, level FROM vocab
                    WHERE level IN (\(placeholders))
                    ORDER BY level DESC, sort_order, id
                    """,
                arguments: StatementArguments(levels.map(\.rawValue))
            )
            return try rows.map { row in
                let rawLevel: String = row["level"]
                guard let level = JLPTLevel(rawValue: rawLevel) else {
                    throw JLPTLibraryDatabaseError.invalidLevel(rawLevel)
                }
                return JLPTVocabularyRef(id: row["id"], level: level)
            }
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
            let pitchColumns = hasPitchColumns
                ? ", pitch_accent, pitch_source, pitch_source_ref"
                : ""
            let previewTranslation = hasExampleTranslation
                ? """
                    , (SELECT translation_zh FROM vocab_examples e
                       WHERE e.vocab_id = vocab.id
                       ORDER BY sort_order, id LIMIT 1) AS example_translation_zh
                    """
                : ""
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, level, headword, reading, meaning_zh, meaning_en_json,
                           part_of_speech, frequency_rank, data_flags\(pitchColumns),
                           (SELECT id FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_id,
                           (SELECT japanese FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_japanese,
                           (SELECT english FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_english,
                           (SELECT sort_order FROM vocab_examples e WHERE e.vocab_id = vocab.id
                            ORDER BY sort_order, id LIMIT 1) AS example_sort_order\(previewTranslation)
                    FROM vocab
                    WHERE \(predicate)
                    ORDER BY \(Self.orderClause(for: sort))
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            let hasMore = rows.count > limit
            let items = try rows.prefix(limit).map {
                try decodeVocabulary($0, examples: [decodePreviewExample($0)].compactMap { $0 })
            }
            return JLPTLibraryPage(
                items: items,
                nextOffset: hasMore ? offset + items.count : nil
            )
        }
    }

    public func vocabulary(id: String) async throws -> BuiltinJLPTVocabulary? {
        try await database.read { db in
            let pitchColumns = hasPitchColumns
                ? ", pitch_accent, pitch_source, pitch_source_ref"
                : ""
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, level, headword, reading, meaning_zh, meaning_en_json,
                           part_of_speech, frequency_rank, data_flags\(pitchColumns)
                    FROM vocab WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            let translationColumn = hasExampleTranslation ? ", translation_zh" : ""
            let exampleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, japanese, english, sort_order\(translationColumn)
                    FROM vocab_examples WHERE vocab_id = ?
                    ORDER BY sort_order, id
                    """,
                arguments: [id]
            )
            let examples = exampleRows.map(decodeExample)
            return try decodeVocabulary(row, examples: examples)
        }
    }

    // MARK: - JLPTEnrichmentSource（设计 §7.4）

    public var offersEnrichmentData: Bool {
        hasPitchColumns || hasExampleTranslation
    }

    /// 批量取数：只返回词库中真实存在的条目；sourceRef 缺失时
    /// 结果中对应缺项，由调度侧记为安全跳过。
    public func enrichmentEntries(
        for sourceRefs: [String]
    ) async throws -> [String: BuiltinJLPTEnrichmentEntry] {
        let unique = Array(Set(sourceRefs))
        guard !unique.isEmpty else { return [:] }
        return try await database.read { db in
            var entries: [String: BuiltinJLPTEnrichmentEntry] = [:]
            // 分块规避 SQLite 变量上限（服务批 ≤300，此处再加保险）。
            for start in stride(from: 0, to: unique.count, by: 400) {
                let chunk = Array(unique[start..<min(start + 400, unique.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let arguments = StatementArguments(chunk)

                let pitchSelect = hasPitchColumns ? ", pitch_accent" : ""
                var pitchByID: [String: PitchAccent] = [:]
                var existingIDs = Set<String>()
                let vocabRows = try Row.fetchAll(
                    db,
                    sql: "SELECT id\(pitchSelect) FROM vocab WHERE id IN (\(placeholders))",
                    arguments: arguments
                )
                for row in vocabRows {
                    let id: String = row["id"]
                    existingIDs.insert(id)
                    if hasPitchColumns,
                       let raw: Int = row["pitch_accent"],
                       let pitch = PitchAccent(rawValue: raw) {
                        pitchByID[id] = pitch
                    }
                }

                var examplesByID: [String: [BuiltinJLPTExample]] = [:]
                if hasExampleTranslation {
                    let exampleRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, vocab_id, japanese, english, translation_zh, sort_order
                            FROM vocab_examples
                            WHERE vocab_id IN (\(placeholders))
                            ORDER BY vocab_id, sort_order, id
                            """,
                        arguments: arguments
                    )
                    for row in exampleRows {
                        let vocabID: String = row["vocab_id"]
                        examplesByID[vocabID, default: []].append(
                            BuiltinJLPTExample(
                                id: row["id"],
                                japanese: row["japanese"],
                                english: row["english"],
                                sortOrder: row["sort_order"],
                                translationZH: row["translation_zh"]
                            )
                        )
                    }
                }

                for id in existingIDs {
                    entries[id] = BuiltinJLPTEnrichmentEntry(
                        sourceRef: id,
                        pitchAccent: pitchByID[id],
                        examples: examplesByID[id] ?? []
                    )
                }
            }
            return entries
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

    private func decodeVocabulary(
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
        var pitchAccent: PitchAccent?
        var pitchSource: String?
        var pitchSourceRef: String?
        if hasPitchColumns {
            let rawPitch: Int? = row["pitch_accent"]
            pitchAccent = rawPitch.flatMap { PitchAccent(rawValue: $0) }
            pitchSource = row["pitch_source"]
            pitchSourceRef = row["pitch_source_ref"]
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
            examples: examples,
            pitchAccent: pitchAccent,
            pitchSource: pitchSource,
            pitchSourceRef: pitchSourceRef
        )
    }

    private func decodeExample(_ row: Row) -> BuiltinJLPTExample {
        BuiltinJLPTExample(
            id: row["id"],
            japanese: row["japanese"],
            english: row["english"],
            sortOrder: row["sort_order"],
            translationZH: hasExampleTranslation ? row["translation_zh"] : nil
        )
    }

    private func decodePreviewExample(_ row: Row) -> BuiltinJLPTExample? {
        guard let id: String = row["example_id"],
              let japanese: String = row["example_japanese"] else {
            return nil
        }
        let english: String? = row["example_english"]
        let sortOrder: Int = row["example_sort_order"]
        let translationZH: String? = hasExampleTranslation
            ? row["example_translation_zh"]
            : nil
        return BuiltinJLPTExample(
            id: id,
            japanese: japanese,
            english: english,
            sortOrder: sortOrder,
            translationZH: translationZH
        )
    }
}

public enum JLPTLibraryDatabaseError: Error, Equatable, Sendable {
    case invalidLevel(String)
    case invalidEnglishMeanings
}
