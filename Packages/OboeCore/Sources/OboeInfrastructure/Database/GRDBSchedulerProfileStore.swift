import Foundation
import GRDB
import OboeDomain

enum GRDBSchedulerProfileStore {
    static func configuredPreset(in db: Database) throws -> RetentionPreset {
        let rawValue = try Int.fetchOne(
            db,
            sql: "SELECT retention_preset FROM app_settings WHERE id = 1"
        ) ?? RetentionPreset.standard.rawValue
        guard let preset = RetentionPreset(rawValue: rawValue) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return preset
    }

    static func ensureConfiguredProfile(
        candidateID: UUID,
        createdAtMilliseconds: Int64,
        in db: Database
    ) throws -> UUID {
        try ensureProfile(
            preset: configuredPreset(in: db),
            candidateID: candidateID,
            createdAtMilliseconds: createdAtMilliseconds,
            in: db
        )
    }

    static func ensureProfile(
        preset: RetentionPreset,
        candidateID: UUID = UUID(),
        createdAtMilliseconds: Int64,
        in db: Database
    ) throws -> UUID {
        let profile = SchedulerProfile(preset: preset)
        let parameterData = try JSONEncoder().encode(profile.parameters)
        let parametersJSON = String(decoding: parameterData, as: UTF8.self)
        try db.execute(
            sql: """
                INSERT INTO scheduler_profiles(
                    id, configuration_version, algorithm_version, library_revision,
                    parameters_json, desired_retention, max_interval_days, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(configuration_version) DO NOTHING
                """,
            arguments: [
                DatabaseValueCodec.encode(candidateID),
                profile.configurationVersion,
                SwiftFSRSReviewScheduler.algorithmVersion,
                SwiftFSRSReviewScheduler.dependencyRevision,
                parametersJSON,
                profile.targetRetention,
                profile.maximumIntervalDays,
                createdAtMilliseconds
            ]
        )
        guard let persistedID: String = try String.fetchOne(
            db,
            sql: "SELECT id FROM scheduler_profiles WHERE configuration_version = ?",
            arguments: [profile.configurationVersion]
        ) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return try DatabaseValueCodec.decodeUUID(persistedID)
    }
}
