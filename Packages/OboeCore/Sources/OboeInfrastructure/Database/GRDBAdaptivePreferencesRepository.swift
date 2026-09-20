import Foundation
import GRDB
import OboeDomain

public struct GRDBAdaptivePreferencesRepository: AdaptivePreferencesRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func loadOrCreateAdaptivePreferences(
        defaultTimeZoneID: String
    ) async throws -> AdaptivePreferences {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, daily_new_card_limit
                    ) VALUES (1, 1, ?, 10)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [defaultTimeZoneID]
            )
            return try Self.fetch(in: db)
        }
    }

    public func updateTypedAnswerChineseToJapanese(
        _ isEnabled: Bool
    ) async throws -> AdaptivePreferences {
        try await update(column: "typed_answer_zh_ja", isEnabled: isEnabled)
    }

    public func updateAutoPlayListeningAudio(
        _ isEnabled: Bool
    ) async throws -> AdaptivePreferences {
        try await update(column: "auto_play_listening_audio", isEnabled: isEnabled)
    }

    public func updateTypedAnswerListening(
        _ isEnabled: Bool
    ) async throws -> AdaptivePreferences {
        try await update(column: "typed_answer_listening", isEnabled: isEnabled)
    }

    public func updateLeechRemindersEnabled(
        _ isEnabled: Bool
    ) async throws -> AdaptivePreferences {
        try await update(column: "leech_reminders_enabled", isEnabled: isEnabled)
    }

    private func update(column: String, isEnabled: Bool) async throws -> AdaptivePreferences {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET \(column) = ? WHERE id = 1",
                arguments: [isEnabled]
            )
            return try Self.fetch(in: db)
        }
    }

    private static func fetch(in db: Database) throws -> AdaptivePreferences {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT typed_answer_zh_ja, auto_play_listening_audio,
                       typed_answer_listening, leech_reminders_enabled
                FROM app_settings WHERE id = 1
                """
        ) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return AdaptivePreferences(
            typedAnswerChineseToJapanese: row["typed_answer_zh_ja"],
            autoPlayListeningAudio: row["auto_play_listening_audio"],
            typedAnswerListening: row["typed_answer_listening"],
            leechRemindersEnabled: row["leech_reminders_enabled"]
        )
    }
}
