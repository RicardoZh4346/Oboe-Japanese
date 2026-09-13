import Foundation
import GRDB
import OboeDomain

public struct GRDBSpeechPreferencesRepository: SpeechPreferencesRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func loadOrCreateSpeechPreferences(
        defaultTimeZoneID: String
    ) async throws -> SpeechPreferences {
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

    public func updateAutoPlayWordAudio(_ isEnabled: Bool) async throws -> SpeechPreferences {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET auto_play_word_audio = ? WHERE id = 1",
                arguments: [isEnabled]
            )
            return try Self.fetch(in: db)
        }
    }

    public func updateAutoPlayExampleAudio(_ isEnabled: Bool) async throws -> SpeechPreferences {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET auto_play_example_audio = ? WHERE id = 1",
                arguments: [isEnabled]
            )
            return try Self.fetch(in: db)
        }
    }

    private static func fetch(in db: Database) throws -> SpeechPreferences {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT auto_play_word_audio, auto_play_example_audio
                FROM app_settings WHERE id = 1
                """
        ) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return SpeechPreferences(
            autoPlayWordAudio: row["auto_play_word_audio"],
            autoPlayExampleAudio: row["auto_play_example_audio"]
        )
    }
}
