import Foundation
import GRDB
import OboeDomain

public struct GRDBReviewSubmissionRepository: ReviewSubmissionRepository, ReviewUndoRepository, Sendable {
    private let pool: DatabasePool
    private let beforeLogInsert: (@Sendable () throws -> Void)?

    public init(database: OboeDatabase) {
        pool = database.pool
        beforeLogInsert = nil
    }

    init(
        database: OboeDatabase,
        beforeLogInsert: @escaping @Sendable () throws -> Void
    ) {
        pool = database.pool
        self.beforeLogInsert = beforeLogInsert
    }

    public func fetchSubmittedReview(eventID: UUID) async throws -> ReviewLogRecord? {
        try await pool.read { db in
            try Self.fetchSubmittedReview(eventID: eventID, in: db)
        }
    }

    public func fetchReviewContext(cardID: UUID) async throws -> ReviewSubmissionContext? {
        try await pool.read { db in
            try Self.fetchReviewContext(cardID: cardID, in: db)
        }
    }

    public func commitReview(_ mutation: ReviewSubmissionMutation) async throws -> ReviewLogRecord {
        try await pool.write { db in
            if let existing = try Self.fetchSubmittedReview(
                eventID: mutation.request.eventID,
                in: db
            ) {
                return existing
            }
            guard let context = try Self.fetchReviewContext(
                cardID: mutation.request.cardID,
                in: db
            ) else {
                throw SubmitReviewError.cardNotFound
            }
            guard context.card.isEnabled else {
                throw SubmitReviewError.cardDisabled
            }
            guard context.card.stateVersion == mutation.request.expectedStateVersion else {
                throw SubmitReviewError.stateVersionConflict(
                    expected: mutation.request.expectedStateVersion,
                    actual: context.card.stateVersion
                )
            }
            let reviewedAtMilliseconds = try DatabaseValueCodec.encode(mutation.reviewedAt)
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM study_days
                        WHERE id = ? AND starts_at_ms <= ? AND ? < ends_at_ms
                    )
                    """,
                arguments: [
                    DatabaseValueCodec.encode(mutation.request.studyDay.id),
                    reviewedAtMilliseconds,
                    reviewedAtMilliseconds
                ]
            ) == true else {
                throw SubmitReviewError.studyDayNotActive
            }
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM daily_tasks
                        WHERE study_day_id = ? AND card_id = ?
                          AND cancelled_at_ms IS NULL
                    )
                    """,
                arguments: [
                    DatabaseValueCodec.encode(mutation.request.studyDay.id),
                    DatabaseValueCodec.encode(mutation.request.cardID)
                ]
            ) == true else {
                throw SubmitReviewError.cardNotInStudyPlan
            }

            let persistedPreviousState = ReviewSchedulingSnapshot(
                scheduling: context.card.scheduling,
                firstStudiedAt: context.card.firstStudiedAt,
                stateVersion: context.card.stateVersion,
                algorithmVersion: context.card.algorithmVersion,
                profileID: context.card.profileID
            )
            guard mutation.noteID == context.card.noteID,
                  mutation.deckIDAtReview == context.deckID,
                  mutation.contentVersion == context.contentVersion,
                  mutation.previousState == persistedPreviousState,
                  mutation.nextState.stateVersion == context.card.stateVersion + 1,
                  mutation.nextState.profileID == context.card.profileID,
                  mutation.nextState.algorithmVersion == context.algorithmVersion,
                  mutation.wasFirstStudy == (context.card.firstStudiedAt == nil),
                  mutation.nextState.firstStudiedAt == (context.card.firstStudiedAt ?? mutation.reviewedAt) else {
                throw SubmitReviewError.staleReviewContext
            }

            try Self.updateCard(mutation, in: db)
            guard db.changesCount == 1 else {
                throw SubmitReviewError.stateVersionConflict(
                    expected: mutation.request.expectedStateVersion,
                    actual: context.card.stateVersion
                )
            }
            try beforeLogInsert?()

            let log = ReviewLogRecord(
                id: UUID(),
                eventID: mutation.request.eventID,
                cardID: mutation.request.cardID,
                cardKey: mutation.request.cardID,
                noteID: mutation.noteID,
                deckIDAtReview: mutation.deckIDAtReview,
                reviewedAt: mutation.reviewedAt,
                studyDayID: mutation.request.studyDay.id,
                wasFirstStudy: mutation.wasFirstStudy,
                rating: mutation.request.rating,
                previousState: mutation.previousState,
                nextState: mutation.nextState,
                durationMilliseconds: mutation.request.durationMilliseconds,
                contentVersion: mutation.contentVersion,
                profileID: mutation.nextState.profileID,
                algorithmVersion: mutation.nextState.algorithmVersion
            )
            try Self.insert(log, in: db)
            return log
        }
    }

    public func commitUndo(
        _ request: UndoReviewRequest,
        undoneAt: Date
    ) async throws -> ReviewLogRecord {
        try await pool.write { db in
            guard let log = try Self.fetchSubmittedReview(eventID: request.eventID, in: db) else {
                throw UndoReviewError.reviewNotFound
            }
            guard log.undoneAt == nil else {
                throw UndoReviewError.alreadyUndone
            }
            guard log.studyDayID == request.studyDay.id else {
                throw UndoReviewError.studyDayMismatch
            }

            let undoneAtMilliseconds = try DatabaseValueCodec.encode(undoneAt)
            let studyDayID = DatabaseValueCodec.encode(request.studyDay.id)
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM study_days
                        WHERE id = ? AND starts_at_ms <= ? AND ? < ends_at_ms
                    )
                    """,
                arguments: [studyDayID, undoneAtMilliseconds, undoneAtMilliseconds]
            ) == true else {
                throw UndoReviewError.studyDayNotActive
            }
            guard let cardID = log.cardID else {
                throw UndoReviewError.cardNotFound
            }
            guard let context = try Self.fetchReviewContext(cardID: cardID, in: db) else {
                throw UndoReviewError.cardNotFound
            }
            guard context.card.isEnabled else {
                throw UndoReviewError.cardDisabled
            }
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM daily_tasks
                        WHERE study_day_id = ? AND card_id = ?
                          AND cancelled_at_ms IS NULL
                    )
                    """,
                arguments: [studyDayID, DatabaseValueCodec.encode(cardID)]
            ) == true else {
                throw UndoReviewError.cardNotInStudyPlan
            }
            guard try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM review_logs
                        WHERE card_key = ? AND id != ? AND undone_at_ms IS NULL
                          AND CAST(json_extract(previous_state_json, '$.stateVersion') AS INTEGER) >= ?
                    )
                    """,
                arguments: [
                    DatabaseValueCodec.encode(log.cardKey),
                    DatabaseValueCodec.encode(log.id),
                    log.nextState.stateVersion
                ]
            ) == false else {
                throw UndoReviewError.subsequentReviewExists
            }

            let persistedState = ReviewSchedulingSnapshot(
                scheduling: context.card.scheduling,
                firstStudiedAt: context.card.firstStudiedAt,
                stateVersion: context.card.stateVersion,
                algorithmVersion: context.card.algorithmVersion,
                profileID: context.card.profileID
            )
            guard try Self.matchesPersistedState(persistedState, log.nextState) else {
                throw UndoReviewError.stateConflict
            }

            try Self.restoreCard(
                cardID: cardID,
                expectedStateVersion: log.nextState.stateVersion,
                state: log.previousState,
                in: db
            )
            guard db.changesCount == 1 else {
                throw UndoReviewError.stateConflict
            }
            try db.execute(
                sql: """
                    UPDATE review_logs SET undone_at_ms = ?
                    WHERE id = ? AND undone_at_ms IS NULL
                    """,
                arguments: [undoneAtMilliseconds, DatabaseValueCodec.encode(log.id)]
            )
            guard db.changesCount == 1,
                  let updated = try Self.fetchSubmittedReview(eventID: request.eventID, in: db) else {
                throw UndoReviewError.alreadyUndone
            }
            return updated
        }
    }

    private static func fetchReviewContext(
        cardID: UUID,
        in db: Database
    ) throws -> ReviewSubmissionContext? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT cards.*,
                       notes.deck_id AS review_deck_id,
                       notes.content_version AS review_content_version,
                       scheduler_profiles.configuration_version AS review_configuration_version,
                       scheduler_profiles.algorithm_version AS review_algorithm_version,
                       scheduler_profiles.parameters_json AS review_parameters_json,
                       scheduler_profiles.desired_retention AS review_desired_retention,
                       scheduler_profiles.max_interval_days AS review_max_interval_days
                FROM cards
                JOIN notes ON notes.id = cards.note_id
                JOIN scheduler_profiles ON scheduler_profiles.id = cards.profile_id
                WHERE cards.id = ?
                """,
            arguments: [DatabaseValueCodec.encode(cardID)]
        ) else {
            return nil
        }
        let parameterJSON: String = row["review_parameters_json"]
        let parameters = try JSONDecoder().decode(
            [Double].self,
            from: Data(parameterJSON.utf8)
        )
        return try ReviewSubmissionContext(
            card: GRDBSchedulingCardRepository.decode(row),
            profile: SchedulerProfile(
                configurationVersion: row["review_configuration_version"],
                targetRetention: row["review_desired_retention"],
                maximumIntervalDays: row["review_max_interval_days"],
                parameters: parameters
            ),
            deckID: DatabaseValueCodec.decodeUUID(row["review_deck_id"]),
            contentVersion: row["review_content_version"],
            algorithmVersion: row["review_algorithm_version"]
        )
    }

    private static func updateCard(
        _ mutation: ReviewSubmissionMutation,
        in db: Database
    ) throws {
        let state = mutation.nextState
        try db.execute(
            sql: """
                UPDATE cards SET
                    state = :state,
                    due_at_ms = :dueAt,
                    last_review_at_ms = :lastReviewAt,
                    stability = :stability,
                    difficulty = :difficulty,
                    reps = :repetitions,
                    lapses = :lapses,
                    scheduled_days = :scheduledDays,
                    elapsed_days = :elapsedDays,
                    learning_step = :learningStep,
                    first_studied_at_ms = :firstStudiedAt,
                    state_version = :nextStateVersion,
                    algorithm_version = :algorithmVersion,
                    profile_id = :profileID
                WHERE id = :cardID
                  AND is_enabled = 1
                  AND state_version = :expectedStateVersion
                """,
            arguments: [
                "state": state.scheduling.state.rawValue,
                "dueAt": try DatabaseValueCodec.encode(state.scheduling.dueAt),
                "lastReviewAt": try state.scheduling.lastReviewAt.map(DatabaseValueCodec.encode),
                "stability": state.scheduling.stability,
                "difficulty": state.scheduling.difficulty,
                "repetitions": state.scheduling.repetitions,
                "lapses": state.scheduling.lapses,
                "scheduledDays": state.scheduling.scheduledDays,
                "elapsedDays": state.scheduling.elapsedDays,
                "learningStep": state.scheduling.learningStep,
                "firstStudiedAt": try state.firstStudiedAt.map(DatabaseValueCodec.encode),
                "nextStateVersion": state.stateVersion,
                "algorithmVersion": state.algorithmVersion,
                "profileID": DatabaseValueCodec.encode(state.profileID),
                "cardID": DatabaseValueCodec.encode(mutation.request.cardID),
                "expectedStateVersion": mutation.request.expectedStateVersion
            ]
        )
    }

    private static func restoreCard(
        cardID: UUID,
        expectedStateVersion: Int,
        state: ReviewSchedulingSnapshot,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE cards SET
                    state = :state,
                    due_at_ms = :dueAt,
                    last_review_at_ms = :lastReviewAt,
                    stability = :stability,
                    difficulty = :difficulty,
                    reps = :repetitions,
                    lapses = :lapses,
                    scheduled_days = :scheduledDays,
                    elapsed_days = :elapsedDays,
                    learning_step = :learningStep,
                    first_studied_at_ms = :firstStudiedAt,
                    state_version = :previousStateVersion,
                    algorithm_version = :algorithmVersion,
                    profile_id = :profileID
                WHERE id = :cardID
                  AND is_enabled = 1
                  AND state_version = :expectedStateVersion
                """,
            arguments: [
                "state": state.scheduling.state.rawValue,
                "dueAt": try DatabaseValueCodec.encode(state.scheduling.dueAt),
                "lastReviewAt": try state.scheduling.lastReviewAt.map(DatabaseValueCodec.encode),
                "stability": state.scheduling.stability,
                "difficulty": state.scheduling.difficulty,
                "repetitions": state.scheduling.repetitions,
                "lapses": state.scheduling.lapses,
                "scheduledDays": state.scheduling.scheduledDays,
                "elapsedDays": state.scheduling.elapsedDays,
                "learningStep": state.scheduling.learningStep,
                "firstStudiedAt": try state.firstStudiedAt.map(DatabaseValueCodec.encode),
                "previousStateVersion": state.stateVersion,
                "algorithmVersion": state.algorithmVersion,
                "profileID": DatabaseValueCodec.encode(state.profileID),
                "cardID": DatabaseValueCodec.encode(cardID),
                "expectedStateVersion": expectedStateVersion
            ]
        )
    }

    private static func matchesPersistedState(
        _ lhs: ReviewSchedulingSnapshot,
        _ rhs: ReviewSchedulingSnapshot
    ) throws -> Bool {
        let left = lhs.scheduling
        let right = rhs.scheduling
        let leftFirstStudiedAt = try lhs.firstStudiedAt.map(DatabaseValueCodec.encode)
        let rightFirstStudiedAt = try rhs.firstStudiedAt.map(DatabaseValueCodec.encode)
        let leftDueAt = try DatabaseValueCodec.encode(left.dueAt)
        let rightDueAt = try DatabaseValueCodec.encode(right.dueAt)
        let leftLastReviewAt = try left.lastReviewAt.map(DatabaseValueCodec.encode)
        let rightLastReviewAt = try right.lastReviewAt.map(DatabaseValueCodec.encode)
        return lhs.schemaVersion == rhs.schemaVersion
            && lhs.stateVersion == rhs.stateVersion
            && lhs.algorithmVersion == rhs.algorithmVersion
            && lhs.profileID == rhs.profileID
            && leftFirstStudiedAt == rightFirstStudiedAt
            && left.state == right.state
            && leftDueAt == rightDueAt
            && leftLastReviewAt == rightLastReviewAt
            && left.stability == right.stability
            && left.difficulty == right.difficulty
            && left.elapsedDays == right.elapsedDays
            && left.scheduledDays == right.scheduledDays
            && left.learningStep == right.learningStep
            && left.repetitions == right.repetitions
            && left.lapses == right.lapses
    }

    private static func insert(_ log: ReviewLogRecord, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO review_logs(
                    id, event_id, card_id, card_key, note_id, deck_id_at_review,
                    reviewed_at_ms, study_day_id, was_first_study, rating,
                    previous_state_json, next_state_json, duration_ms, content_version,
                    profile_id, algorithm_version, undone_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """,
            arguments: [
                DatabaseValueCodec.encode(log.id),
                DatabaseValueCodec.encode(log.eventID),
                log.cardID.map(DatabaseValueCodec.encode),
                DatabaseValueCodec.encode(log.cardKey),
                DatabaseValueCodec.encode(log.noteID),
                DatabaseValueCodec.encode(log.deckIDAtReview),
                try DatabaseValueCodec.encode(log.reviewedAt),
                DatabaseValueCodec.encode(log.studyDayID),
                log.wasFirstStudy,
                log.rating.rawValue,
                try encode(log.previousState),
                try encode(log.nextState),
                log.durationMilliseconds,
                log.contentVersion,
                DatabaseValueCodec.encode(log.profileID),
                log.algorithmVersion
            ]
        )
    }

    private static func fetchSubmittedReview(
        eventID: UUID,
        in db: Database
    ) throws -> ReviewLogRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM review_logs WHERE event_id = ?",
            arguments: [DatabaseValueCodec.encode(eventID)]
        ) else {
            return nil
        }
        let ratingValue: Int = row["rating"]
        guard let rating = ReviewRating(rawValue: ratingValue) else {
            throw SubmitReviewError.invalidPersistedRating(ratingValue)
        }
        let cardIDValue: String? = row["card_id"]
        let undoneAtMilliseconds: Int64? = row["undone_at_ms"]
        return try ReviewLogRecord(
            id: DatabaseValueCodec.decodeUUID(row["id"]),
            eventID: DatabaseValueCodec.decodeUUID(row["event_id"]),
            cardID: try cardIDValue.map(DatabaseValueCodec.decodeUUID),
            cardKey: DatabaseValueCodec.decodeUUID(row["card_key"]),
            noteID: DatabaseValueCodec.decodeUUID(row["note_id"]),
            deckIDAtReview: DatabaseValueCodec.decodeUUID(row["deck_id_at_review"]),
            reviewedAt: DatabaseValueCodec.decodeDate(milliseconds: row["reviewed_at_ms"]),
            studyDayID: DatabaseValueCodec.decodeUUID(row["study_day_id"]),
            wasFirstStudy: row["was_first_study"],
            rating: rating,
            previousState: decode(ReviewSchedulingSnapshot.self, from: row["previous_state_json"]),
            nextState: decode(ReviewSchedulingSnapshot.self, from: row["next_state_json"]),
            durationMilliseconds: row["duration_ms"],
            contentVersion: row["content_version"],
            profileID: DatabaseValueCodec.decodeUUID(row["profile_id"]),
            algorithmVersion: row["algorithm_version"],
            undoneAt: undoneAtMilliseconds.map(DatabaseValueCodec.decodeDate)
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: Data(value.utf8))
    }
}
