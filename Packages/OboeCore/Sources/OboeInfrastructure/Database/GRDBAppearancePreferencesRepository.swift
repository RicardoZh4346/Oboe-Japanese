import Foundation
import GRDB
import OboeDomain

public struct GRDBAppearancePreferencesRepository: AppearancePreferencesRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func loadOrCreateAppearance(
        defaultTimeZoneID: String
    ) async throws -> AppAppearance {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await pool.write { db in
            try AppSettingsRowDefaults.insertIfMissing(
                in: db, learningTimeZoneID: defaultTimeZoneID
            )
            return try Self.fetch(in: db)
        }
    }

    public func updateAppearance(_ appearance: AppAppearance) async throws -> AppAppearance {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE app_settings SET appearance = ? WHERE id = 1",
                arguments: [appearance.rawValue]
            )
            return try Self.fetch(in: db)
        }
    }

    private static func fetch(in db: Database) throws -> AppAppearance {
        guard let rawValue = try String.fetchOne(
            db,
            sql: "SELECT appearance FROM app_settings WHERE id = 1"
        ), let appearance = AppAppearance(rawValue: rawValue) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        return appearance
    }
}
