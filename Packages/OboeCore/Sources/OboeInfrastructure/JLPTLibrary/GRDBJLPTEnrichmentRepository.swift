import Foundation
import GRDB
import OboeDomain

/// 用户库侧 enrichment 存取（设计 §7.4）。
///
/// 写入纪律：
/// - `notes.pitch_accent` 仅在当前为 NULL 时回填；
/// - `examples.translation_zh` 按 (note_id, japanese, sort_order) 匹配
///   词库例句，仅在当前为 NULL 时回填——用户改过日文或已写中文的行
///   都不会被触碰；
/// - 不回填释义、词性等任何其它字段，不更新 `updated_at_ms`。
public struct GRDBJLPTEnrichmentRepository: JLPTEnrichmentStore, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func enrichmentCandidates() async throws -> [JLPTEnrichmentCandidate] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_ref, reading,
                           (pitch_accent IS NULL) AS needs_pitch
                    FROM notes
                    WHERE origin = 'builtin_jlpt' AND source_ref IS NOT NULL
                      AND (pitch_accent IS NULL
                           OR EXISTS (SELECT 1 FROM examples e
                                      WHERE e.note_id = notes.id
                                        AND e.translation_zh IS NULL))
                    ORDER BY created_at_ms, id
                    """
            ).map { row in
                JLPTEnrichmentCandidate(
                    noteID: try DatabaseValueCodec.decodeUUID(row["id"]),
                    sourceRef: row["source_ref"],
                    reading: row["reading"],
                    needsPitchAccent: row["needs_pitch"]
                )
            }
        }
    }

    public func applyEnrichment(
        _ writes: [JLPTEnrichmentWrite]
    ) async throws -> JLPTEnrichmentBatchResult {
        try await pool.write { db in
            var result = JLPTEnrichmentBatchResult()
            for write in writes {
                guard let pitch = write.pitchAccent else { continue }
                try db.execute(
                    sql: """
                        UPDATE notes SET pitch_accent = ?
                        WHERE id = ? AND pitch_accent IS NULL
                        """,
                    arguments: [
                        pitch.rawValue,
                        DatabaseValueCodec.encode(write.noteID),
                    ]
                )
                if db.changesCount > 0 {
                    result.pitchFilled += 1
                }
            }

            let noteIDs = writes.filter { !$0.examples.isEmpty }.map(\.noteID)
            guard !noteIDs.isEmpty else { return result }

            var lookup: [ExampleKey: String] = [:]
            for write in writes {
                for example in write.examples {
                    guard let translation = example.translationZH else { continue }
                    lookup[ExampleKey(
                        noteID: write.noteID,
                        japanese: example.japanese,
                        sortOrder: example.sortOrder
                    )] = translation
                }
            }
            guard !lookup.isEmpty else { return result }

            let placeholders = noteIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, note_id, japanese, sort_order FROM examples
                    WHERE translation_zh IS NULL
                      AND note_id IN (\(placeholders))
                    ORDER BY note_id, sort_order, id
                    """,
                arguments: StatementArguments(noteIDs.map(DatabaseValueCodec.encode))
            )
            for row in rows {
                let noteID = try DatabaseValueCodec.decodeUUID(row["note_id"])
                let key = ExampleKey(
                    noteID: noteID,
                    japanese: row["japanese"],
                    sortOrder: row["sort_order"]
                )
                guard let translation = lookup[key] else { continue }
                let id: String = row["id"]
                try db.execute(
                    sql: """
                        UPDATE examples SET translation_zh = ?
                        WHERE id = ? AND translation_zh IS NULL
                        """,
                    arguments: [translation, id]
                )
                if db.changesCount > 0 {
                    result.examplesFilled += 1
                }
            }
            return result
        }
    }

    private struct ExampleKey: Hashable {
        let noteID: UUID
        let japanese: String
        let sortOrder: Int
    }
}
