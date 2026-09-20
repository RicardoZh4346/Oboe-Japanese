import Foundation
import GRDB
import OboeDomain

public enum GRDBAIRepairDraftRepositoryError: Error, Equatable, Sendable {
    case unsupportedDraftPayloadVersion(Int)
}

/// `draft_kind = 'ai_repair'` persistence (设计 §6.3): envelopes travel inside
/// `payload_json` via `AIRepairDraftCodec`; provider/model/prompt columns hold
/// non-secret provenance only — credentials are never persisted.
public struct GRDBAIRepairDraftRepository: AIRepairDraftStore, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func saveDraft(
        id: UUID,
        envelope: AIRepairDraftEnvelope,
        provenance: AIRepairDraftProvenance,
        updatedAt: Date
    ) async throws {
        let payloadJSON = try AIRepairDraftCodec.encode(envelope)
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(updatedAt)
        try await pool.write { db in
            try Self.saveDraft(
                id: id,
                payloadJSON: payloadJSON,
                provenance: provenance,
                updatedAtMilliseconds: updatedAtMilliseconds,
                in: db
            )
        }
    }

    /// In-transaction variant for the T08 commit path — the note update and
    /// the draft's committed receipt must land in the same transaction.
    static func saveDraft(
        id: UUID,
        payloadJSON: String,
        provenance: AIRepairDraftProvenance,
        updatedAtMilliseconds: Int64,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO drafts(
                    id, draft_kind, payload_version, payload_json,
                    provider_id, model_id, prompt_version, updated_at_ms
                ) VALUES (?, 'ai_repair', ?, ?, ?, ?, ?, ?)
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
                DatabaseValueCodec.encode(id),
                AIRepairDraftFormat.currentPayloadVersion,
                payloadJSON,
                provenance.providerID,
                provenance.modelID,
                provenance.promptVersion,
                updatedAtMilliseconds
            ]
        )
    }

    public func fetchDraft(id: UUID) async throws -> AIRepairDraftEnvelope? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT payload_version, payload_json
                    FROM drafts
                    WHERE id = ? AND draft_kind = 'ai_repair'
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            ) else {
                return nil
            }
            return try Self.decodeEnvelope(row)
        }
    }

    public func fetchAllDrafts() async throws -> [(id: UUID, envelope: AIRepairDraftEnvelope)] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, payload_version, payload_json
                    FROM drafts
                    WHERE draft_kind = 'ai_repair'
                    ORDER BY updated_at_ms DESC, id DESC
                    """
            ).map { row in
                let idValue: String = row["id"]
                return (
                    id: try DatabaseValueCodec.decodeUUID(idValue),
                    envelope: try Self.decodeEnvelope(row)
                )
            }
        }
    }

    public func deleteDraft(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM drafts WHERE id = ? AND draft_kind = 'ai_repair'",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
    }

    private static func decodeEnvelope(_ row: Row) throws -> AIRepairDraftEnvelope {
        let payloadVersion: Int = row["payload_version"]
        guard payloadVersion == AIRepairDraftFormat.currentPayloadVersion else {
            throw GRDBAIRepairDraftRepositoryError.unsupportedDraftPayloadVersion(
                payloadVersion
            )
        }
        let payloadJSON: String = row["payload_json"]
        return try AIRepairDraftCodec.decode(payloadJSON)
    }
}
