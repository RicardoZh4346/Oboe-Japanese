import Foundation
import GRDB
import OboeDomain

public enum GRDBSentenceAnalysisDraftRepositoryError: Error, Equatable, Sendable {
    case unsupportedDraftPayloadVersion(Int)
    case invalidDraftPayload
}

public struct GRDBSentenceAnalysisDraftRepository: SentenceAnalysisDraftRepository, Sendable {
    private static let draftPayloadVersion = 1
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func saveSentenceAnalysisDraft(_ draft: SentenceAnalysisDraft) async throws {
        guard draft.result == nil || draft.result?.sentence == draft.sentence else {
            throw GRDBSentenceAnalysisDraftRepositoryError.invalidDraftPayload
        }
        let payload = DraftPayload(sentence: draft.sentence, result: draft.result)
        let data = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw GRDBSentenceAnalysisDraftRepositoryError.invalidDraftPayload
        }
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(draft.updatedAt)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json,
                        provider_id, model_id, prompt_version, updated_at_ms
                    ) VALUES (?, 'sentence_analysis', ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        draft_kind = excluded.draft_kind,
                        payload_version = excluded.payload_version,
                        payload_json = excluded.payload_json,
                        provider_id = excluded.provider_id,
                        model_id = excluded.model_id,
                        prompt_version = excluded.prompt_version,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    DatabaseValueCodec.encode(draft.id),
                    Self.draftPayloadVersion,
                    payloadJSON,
                    draft.providerID,
                    draft.modelID,
                    draft.promptVersion,
                    updatedAtMilliseconds
                ]
            )
        }
    }

    public func fetchLatestSentenceAnalysisDraft() async throws -> SentenceAnalysisDraft? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, payload_version, payload_json, provider_id, model_id,
                           prompt_version, updated_at_ms
                    FROM drafts
                    WHERE draft_kind = 'sentence_analysis'
                      AND NOT EXISTS (
                          SELECT 1 FROM inbox_processing_contexts ipc
                          WHERE ipc.draft_id = drafts.id
                      )
                    ORDER BY updated_at_ms DESC, id DESC
                    LIMIT 1
                    """
            ) else {
                return nil
            }
            return try Self.decodeDraft(row)
        }
    }

    public func fetchSentenceAnalysisDraft(id: UUID) async throws -> SentenceAnalysisDraft? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, payload_version, payload_json, provider_id, model_id,
                           prompt_version, updated_at_ms
                    FROM drafts
                    WHERE id = ? AND draft_kind = 'sentence_analysis'
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            ) else {
                return nil
            }
            return try Self.decodeDraft(row)
        }
    }

    private static func decodeDraft(_ row: Row) throws -> SentenceAnalysisDraft {
        let payloadVersion: Int = row["payload_version"]
        guard payloadVersion == Self.draftPayloadVersion else {
            throw GRDBSentenceAnalysisDraftRepositoryError.unsupportedDraftPayloadVersion(
                payloadVersion
            )
        }
        let payloadJSON: String = row["payload_json"]
        guard let data = payloadJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data),
              payload.result == nil || payload.result?.sentence == payload.sentence else {
            throw GRDBSentenceAnalysisDraftRepositoryError.invalidDraftPayload
        }
        let idValue: String = row["id"]
        let updatedAtMilliseconds: Int64 = row["updated_at_ms"]
        return SentenceAnalysisDraft(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            sentence: payload.sentence,
            result: payload.result,
            providerID: row["provider_id"],
            modelID: row["model_id"],
            promptVersion: row["prompt_version"],
            updatedAt: DatabaseValueCodec.decodeDate(milliseconds: updatedAtMilliseconds)
        )
    }

    public func deleteSentenceAnalysisDraft(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM drafts WHERE id = ? AND draft_kind = 'sentence_analysis'",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
    }
}

private struct DraftPayload: Codable {
    let sentence: String
    let result: SentenceAnalysisResult?
}
