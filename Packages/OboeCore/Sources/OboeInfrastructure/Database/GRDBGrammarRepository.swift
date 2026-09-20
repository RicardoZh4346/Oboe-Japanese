import Foundation
import GRDB
import OboeDomain

public enum GRDBGrammarRepositoryError: Error, Equatable, Sendable {
    case unsupportedDraftPayloadVersion(Int)
    case invalidDraftPayload
    case invalidJLPTLevel(String)
}

public struct GRDBGrammarRepository: GrammarRepository, Sendable {
    private static let draftPayloadVersion = 1

    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func fetchGrammar(id: UUID) async throws -> GrammarNote? {
        try await pool.read { db in
            try Self.fetchGrammar(id: id, in: db)
        }
    }

    public func saveGrammarDraft(_ draft: GrammarDraft) async throws {
        let payload = DraftPayload(deckID: draft.deckID, formData: draft.formData)
        let data = try JSONEncoder().encode(payload)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw GRDBGrammarRepositoryError.invalidDraftPayload
        }
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(draft.updatedAt)

        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json,
                        provider_id, model_id, prompt_version, updated_at_ms
                    ) VALUES (?, 'grammar', ?, ?, NULL, NULL, NULL, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        draft_kind = excluded.draft_kind,
                        payload_version = excluded.payload_version,
                        payload_json = excluded.payload_json,
                        provider_id = NULL,
                        model_id = NULL,
                        prompt_version = NULL,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                arguments: [
                    DatabaseValueCodec.encode(draft.id),
                    Self.draftPayloadVersion,
                    payloadJSON,
                    updatedAtMilliseconds
                ]
            )
        }
    }

    public func fetchLatestGrammarDraft() async throws -> GrammarDraft? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, payload_version, payload_json, updated_at_ms
                    FROM drafts
                    WHERE draft_kind = 'grammar'
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

    public func fetchGrammarDraft(id: UUID) async throws -> GrammarDraft? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, payload_version, payload_json, updated_at_ms
                    FROM drafts
                    WHERE id = ? AND draft_kind = 'grammar'
                    """,
                arguments: [DatabaseValueCodec.encode(id)]
            ) else {
                return nil
            }
            return try Self.decodeDraft(row)
        }
    }

    public func deleteGrammarDraft(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM drafts WHERE id = ? AND draft_kind = 'grammar'",
                arguments: [DatabaseValueCodec.encode(id)]
            )
        }
    }

    public func updateGrammar(
        id: UUID,
        content: ValidatedGrammarContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> GrammarNote? {
        let updatedAtMilliseconds = try DatabaseValueCodec.encode(date)
        return try await pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ? AND kind = 'grammar')",
                arguments: [DatabaseValueCodec.encode(id)]
            ) == true else {
                return nil
            }

            try db.execute(
                sql: """
                    UPDATE notes SET
                        headword = ?,
                        meaning_zh = ?,
                        usage = ?,
                        connection = ?,
                        jlpt = ?,
                        notes = ?,
                        content_version = content_version + 1,
                        updated_at_ms = ?
                    WHERE id = ? AND kind = 'grammar'
                    """,
                arguments: [
                    content.grammarForm,
                    content.meaningZH,
                    content.usage,
                    content.connection,
                    content.jlpt?.rawValue,
                    content.notes,
                    updatedAtMilliseconds,
                    DatabaseValueCodec.encode(id)
                ]
            )

            let existingExampleIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM examples WHERE note_id = ? ORDER BY sort_order, id",
                arguments: [DatabaseValueCodec.encode(id)]
            )
            try Self.replacePrimaryExample(
                noteID: id,
                content: content.example,
                existingExampleIDs: existingExampleIDs,
                newExampleID: newExampleID,
                in: db
            )

            return try Self.fetchGrammar(id: id, in: db)
        }
    }

    static func replacePrimaryExample(
        noteID: UUID,
        content: GrammarExampleContent?,
        existingExampleIDs: [String],
        newExampleID: UUID,
        in db: Database
    ) throws {
        guard let content else {
            try db.execute(
                sql: "DELETE FROM examples WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            return
        }

        if let primaryID = existingExampleIDs.first {
            try db.execute(
                sql: """
                    UPDATE examples
                    SET japanese = ?, translation_zh = ?, sort_order = 0
                    WHERE id = ? AND note_id = ?
                    """,
                arguments: [
                    content.japanese,
                    content.translationZH,
                    primaryID,
                    DatabaseValueCodec.encode(noteID)
                ]
            )
            if existingExampleIDs.count > 1 {
                try db.execute(
                    sql: "DELETE FROM examples WHERE note_id = ? AND id <> ?",
                    arguments: [DatabaseValueCodec.encode(noteID), primaryID]
                )
            }
        } else {
            try db.execute(
                sql: """
                    INSERT INTO examples(id, note_id, japanese, translation_zh, sort_order)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(newExampleID),
                    DatabaseValueCodec.encode(noteID),
                    content.japanese,
                    content.translationZH
                ]
            )
        }
    }

    private static func fetchGrammar(id: UUID, in db: Database) throws -> GrammarNote? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    id, deck_id, headword, meaning_zh, usage, connection,
                    jlpt, notes, content_version, created_at_ms, updated_at_ms
                FROM notes
                WHERE id = ? AND kind = 'grammar'
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        ) else {
            return nil
        }

        let examples = try Row.fetchAll(
            db,
            sql: """
                SELECT id, japanese, translation_zh, sort_order
                FROM examples
                WHERE note_id = ?
                ORDER BY sort_order, id
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        ).map { exampleRow in
            let idValue: String = exampleRow["id"]
            let japanese: String = exampleRow["japanese"]
            let translationZH: String? = exampleRow["translation_zh"]
            let sortOrder: Int = exampleRow["sort_order"]
            return GrammarExample(
                id: try DatabaseValueCodec.decodeUUID(idValue),
                japanese: japanese,
                translationZH: translationZH,
                sortOrder: sortOrder
            )
        }

        let idValue: String = row["id"]
        let deckIDValue: String = row["deck_id"]
        let grammarForm: String = row["headword"]
        let meaningZH: String = row["meaning_zh"]
        let usage: String? = row["usage"]
        let connection: String? = row["connection"]
        let jlptValue: String? = row["jlpt"]
        let notes: String? = row["notes"]
        let contentVersion: Int = row["content_version"]
        let createdAtMilliseconds: Int64 = row["created_at_ms"]
        let updatedAtMilliseconds: Int64 = row["updated_at_ms"]

        return GrammarNote(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            deckID: try DatabaseValueCodec.decodeUUID(deckIDValue),
            grammarForm: grammarForm,
            meaningZH: meaningZH,
            usage: usage,
            connection: connection,
            jlpt: try decodeJLPT(jlptValue),
            notes: notes,
            contentVersion: contentVersion,
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: createdAtMilliseconds),
            updatedAt: DatabaseValueCodec.decodeDate(milliseconds: updatedAtMilliseconds),
            examples: examples
        )
    }

    private static func decodeDraft(_ row: Row) throws -> GrammarDraft {
        let payloadVersion: Int = row["payload_version"]
        guard payloadVersion == Self.draftPayloadVersion else {
            throw GRDBGrammarRepositoryError.unsupportedDraftPayloadVersion(payloadVersion)
        }
        let payloadJSON: String = row["payload_json"]
        guard let data = payloadJSON.data(using: .utf8) else {
            throw GRDBGrammarRepositoryError.invalidDraftPayload
        }
        let payload: DraftPayload
        do {
            payload = try JSONDecoder().decode(DraftPayload.self, from: data)
        } catch {
            throw GRDBGrammarRepositoryError.invalidDraftPayload
        }

        let idValue: String = row["id"]
        let updatedAtMilliseconds: Int64 = row["updated_at_ms"]
        return GrammarDraft(
            id: try DatabaseValueCodec.decodeUUID(idValue),
            deckID: payload.deckID,
            formData: payload.formData,
            updatedAt: DatabaseValueCodec.decodeDate(milliseconds: updatedAtMilliseconds)
        )
    }

    private static func decodeJLPT(_ value: String?) throws -> JLPTLevel? {
        guard let value else {
            return nil
        }
        guard let level = JLPTLevel(rawValue: value) else {
            throw GRDBGrammarRepositoryError.invalidJLPTLevel(value)
        }
        return level
    }
}

private struct DraftPayload: Codable {
    let deckID: UUID?
    let formData: GrammarFormData
}
