import Foundation
import GRDB
import OboeDomain

/// `origin = builtin_jlpt` Note ↔ 内置词库条目的关联查询
/// （设计 §11.1）。sourceRef 精确匹配，不按 headword 猜测；
/// `origin = ai` 等其它来源一律不参与。
public struct GRDBJLPTNoteAssociationRepository: JLPTNoteAssociationRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func builtinNoteAssociations() async throws -> [String: [UUID]] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_ref FROM notes
                    WHERE origin = 'builtin_jlpt' AND source_ref IS NOT NULL
                    """
            )
            var associations: [String: [UUID]] = [:]
            for row in rows {
                let sourceRef: String = row["source_ref"]
                let noteID = try DatabaseValueCodec.decodeUUID(row["id"])
                associations[sourceRef, default: []].append(noteID)
            }
            return associations
        }
    }
}
