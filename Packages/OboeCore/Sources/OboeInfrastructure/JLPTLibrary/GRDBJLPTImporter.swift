import Foundation
import GRDB
import OboeDomain

public struct GRDBJLPTImporter: JLPTImporting, Sendable {
    private static let batchSize = 75
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func importedCounts() async throws -> [JLPTLevel: Int] {
        try await pool.read { db in
            var result: [JLPTLevel: Int] = [:]
            for level in JLPTLevel.allCases {
                result[level] = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM notes
                        WHERE origin = 'builtin_jlpt' AND source_ref LIKE ?
                        """,
                    arguments: ["openjlpt:\(level.rawValue):%"]
                ) ?? 0
            }
            return result
        }
    }

    public func importedSourceRefs(_ sourceRefs: [String]) async throws -> Set<String> {
        let uniqueRefs = Array(Set(sourceRefs))
        guard !uniqueRefs.isEmpty else { return [] }
        return try await pool.read { db in
            let placeholders = Array(repeating: "?", count: uniqueRefs.count).joined(separator: ",")
            let values = try String.fetchAll(
                db,
                sql: """
                    SELECT source_ref FROM notes
                    WHERE origin = 'builtin_jlpt'
                      AND source_ref IN (\(placeholders))
                    """,
                arguments: StatementArguments(uniqueRefs)
            )
            return Set(values)
        }
    }

    public func importVocabulary(
        _ vocabulary: BuiltinJLPTVocabulary,
        deckID: UUID,
        deckIDs: Set<UUID>? = nil,
        meaningZH: String,
        directions: Set<VocabularyCardDirection>
    ) async throws -> JLPTImportResult {
        let meaning = meaningZH.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !meaning.isEmpty else { throw JLPTImportError.chineseMeaningRequired }
        guard !directions.isEmpty else { throw JLPTImportError.directionRequired }
        let membership = (deckIDs ?? []).union([deckID])
        return try await pool.write { db in
            for memberDeckID in membership {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                    arguments: [DatabaseValueCodec.encode(memberDeckID)]
                ) == true else {
                    throw JLPTImportError.deckNotFound
                }
            }
            let inserted = try Self.insert(
                vocabulary,
                deckID: deckID,
                deckIDs: membership,
                meaningZH: meaning,
                directions: directions,
                timestamp: try DatabaseValueCodec.encode(Date()),
                in: db
            )
            return JLPTImportResult(
                deckID: deckID,
                imported: inserted ? 1 : 0,
                skipped: inserted ? 0 : 1,
                failed: 0
            )
        }
    }

    public func importLevel(
        _ level: JLPTLevel,
        vocabulary: [BuiltinJLPTVocabulary],
        deckID: UUID,
        deckIDs: Set<UUID>? = nil,
        directions: Set<VocabularyCardDirection>,
        progress: @escaping @Sendable (JLPTImportProgress) async -> Void
    ) async throws -> JLPTImportResult {
        guard !directions.isEmpty else { throw JLPTImportError.directionRequired }
        // v0.5.5：批量导入只写入既有牌组，不再创建「JLPT Nx」牌组。
        let membership = (deckIDs ?? []).union([deckID])
        try await pool.read { db in
            for memberDeckID in membership {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM decks WHERE id = ?)",
                    arguments: [DatabaseValueCodec.encode(memberDeckID)]
                ) == true else {
                    throw JLPTImportError.deckNotFound
                }
            }
        }
        var imported = 0
        var skipped = 0
        var failed = 0

        for start in stride(from: 0, to: vocabulary.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let end = min(start + Self.batchSize, vocabulary.count)
            let batch = Array(vocabulary[start..<end])
            let outcome = try await pool.write { db in
                let timestamp = try DatabaseValueCodec.encode(Date())
                var batchImported = 0
                var batchSkipped = 0
                var batchFailed = 0
                for item in batch {
                    guard item.level == level,
                          let meaning = item.meaningZH?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !meaning.isEmpty else {
                        batchFailed += 1
                        continue
                    }
                    if try Self.insert(
                        item,
                        deckID: deckID,
                        deckIDs: membership,
                        meaningZH: meaning,
                        directions: directions,
                        timestamp: timestamp,
                        in: db
                    ) {
                        batchImported += 1
                    } else {
                        batchSkipped += 1
                    }
                }
                return (batchImported, batchSkipped, batchFailed)
            }
            imported += outcome.0
            skipped += outcome.1
            failed += outcome.2
            await progress(JLPTImportProgress(
                processed: end,
                total: vocabulary.count,
                imported: imported,
                skipped: skipped,
                failed: failed
            ))
        }
        return JLPTImportResult(
            deckID: deckID,
            imported: imported,
            skipped: skipped,
            failed: failed
        )
    }

    private static func insert(
        _ vocabulary: BuiltinJLPTVocabulary,
        deckID: UUID,
        deckIDs: Set<UUID>? = nil,
        meaningZH: String,
        directions: Set<VocabularyCardDirection>,
        timestamp: Int64,
        in db: Database
    ) throws -> Bool {
        if try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM notes
                    WHERE origin = 'builtin_jlpt' AND source_ref = ?
                )
                """,
            arguments: [vocabulary.id]
        ) == true {
            return false
        }

        let noteID = UUID()
        let noteIDValue = DatabaseValueCodec.encode(noteID)
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    part_of_speech, jlpt, origin, source_ref, pitch_accent,
                    content_version, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', ?, ?, ?, ?, ?, 'builtin_jlpt', ?, ?, 1, ?, ?)
                """,
            arguments: [
                noteIDValue,
                DatabaseValueCodec.encode(deckID),
                vocabulary.headword,
                vocabulary.reading,
                meaningZH,
                vocabulary.partOfSpeech,
                vocabulary.level.rawValue,
                vocabulary.id,
                vocabulary.pitchAccent?.rawValue,
                timestamp,
                timestamp
            ]
        )
        for memberDeckID in (deckIDs ?? [deckID]).union([deckID]) {
            try GRDBContentCardRepository.insertHomeMembership(
                noteID: noteID,
                deckID: memberDeckID,
                atMilliseconds: timestamp,
                in: db
            )
        }

        for example in vocabulary.examples.prefix(3) {
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    noteIDValue,
                    example.japanese,
                    example.translationZH,
                    example.sortOrder
                ]
            )
        }

        let profileID = try GRDBSchedulerProfileStore.ensureConfiguredProfile(
            candidateID: UUID(),
            createdAtMilliseconds: timestamp,
            in: db
        )
        for direction in directions.sorted(by: { $0.rawValue < $1.rawValue }) {
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days, elapsed_days,
                        learning_step, state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    noteIDValue,
                    direction.templateKind.rawValue,
                    timestamp,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return true
    }
}
