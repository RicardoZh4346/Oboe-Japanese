import Foundation
import GRDB
import OboeDomain

public struct GRDBSchedulingCardRepository: SchedulingCardRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        self.pool = database.pool
    }

    public func fetchCard(id: UUID) async throws -> PersistedSchedulingCard? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM cards WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(id)]
            ) else {
                return nil
            }
            return try Self.decode(row)
        }
    }

    public func saveCard(_ card: PersistedSchedulingCard) async throws {
        let values = try EncodedCard(card)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards (
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, last_review_at_ms, stability, difficulty,
                        reps, lapses, scheduled_days, elapsed_days, learning_step,
                        first_studied_at_ms, state_version, algorithm_version, profile_id
                    ) VALUES (
                        :id, :noteID, :templateKind, :isEnabled, :state,
                        :dueAt, :lastReviewAt, :stability, :difficulty,
                        :repetitions, :lapses, :scheduledDays, :elapsedDays, :learningStep,
                        :firstStudiedAt, :stateVersion, :algorithmVersion, :profileID
                    )
                    ON CONFLICT(id) DO UPDATE SET
                        note_id = excluded.note_id,
                        template_kind = excluded.template_kind,
                        is_enabled = excluded.is_enabled,
                        state = excluded.state,
                        due_at_ms = excluded.due_at_ms,
                        last_review_at_ms = excluded.last_review_at_ms,
                        stability = excluded.stability,
                        difficulty = excluded.difficulty,
                        reps = excluded.reps,
                        lapses = excluded.lapses,
                        scheduled_days = excluded.scheduled_days,
                        elapsed_days = excluded.elapsed_days,
                        learning_step = excluded.learning_step,
                        first_studied_at_ms = excluded.first_studied_at_ms,
                        state_version = excluded.state_version,
                        algorithm_version = excluded.algorithm_version,
                        profile_id = excluded.profile_id
                    """,
                arguments: values.arguments
            )
        }
    }

    static func decode(_ row: Row) throws -> PersistedSchedulingCard {
        let stateValue: Int = row["state"]
        guard let state = SchedulingState(rawValue: stateValue) else {
            throw DatabaseValueCodecError.invalidSchedulingState(stateValue)
        }
        let templateValue: String = row["template_kind"]
        guard let template = CardTemplateKind(rawValue: templateValue) else {
            throw DatabaseValueCodecError.invalidCardTemplate(templateValue)
        }
        let lastReviewMilliseconds: Int64? = row["last_review_at_ms"]
        let firstStudiedMilliseconds: Int64? = row["first_studied_at_ms"]

        return try PersistedSchedulingCard(
            id: DatabaseValueCodec.decodeUUID(row["id"]),
            noteID: DatabaseValueCodec.decodeUUID(row["note_id"]),
            templateKind: template,
            isEnabled: row["is_enabled"],
            scheduling: SchedulingCard(
                dueAt: DatabaseValueCodec.decodeDate(milliseconds: row["due_at_ms"]),
                stability: row["stability"],
                difficulty: row["difficulty"],
                elapsedDays: row["elapsed_days"],
                scheduledDays: row["scheduled_days"],
                learningStep: row["learning_step"],
                repetitions: row["reps"],
                lapses: row["lapses"],
                state: state,
                lastReviewAt: lastReviewMilliseconds.map(DatabaseValueCodec.decodeDate)
            ),
            firstStudiedAt: firstStudiedMilliseconds.map(DatabaseValueCodec.decodeDate),
            stateVersion: row["state_version"],
            algorithmVersion: row["algorithm_version"],
            profileID: DatabaseValueCodec.decodeUUID(row["profile_id"])
        )
    }
}

private struct EncodedCard: Sendable {
    let arguments: StatementArguments

    init(_ card: PersistedSchedulingCard) throws {
        let lastReviewAt = try card.scheduling.lastReviewAt.map(DatabaseValueCodec.encode)
        let firstStudiedAt = try card.firstStudiedAt.map(DatabaseValueCodec.encode)
        arguments = [
            "id": DatabaseValueCodec.encode(card.id),
            "noteID": DatabaseValueCodec.encode(card.noteID),
            "templateKind": card.templateKind.rawValue,
            "isEnabled": card.isEnabled,
            "state": card.scheduling.state.rawValue,
            "dueAt": try DatabaseValueCodec.encode(card.scheduling.dueAt),
            "lastReviewAt": lastReviewAt,
            "stability": card.scheduling.stability,
            "difficulty": card.scheduling.difficulty,
            "repetitions": card.scheduling.repetitions,
            "lapses": card.scheduling.lapses,
            "scheduledDays": card.scheduling.scheduledDays,
            "elapsedDays": card.scheduling.elapsedDays,
            "learningStep": card.scheduling.learningStep,
            "firstStudiedAt": firstStudiedAt,
            "stateVersion": card.stateVersion,
            "algorithmVersion": card.algorithmVersion,
            "profileID": DatabaseValueCodec.encode(card.profileID)
        ]
    }
}
