import Foundation
import GRDB
import OboeDomain

public struct GRDBAIConfigurationRepository: AIConfigurationRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func loadOrCreateAIConfiguration(
        defaultTimeZoneID: String
    ) async throws -> AIConfiguration {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await pool.write { db in
            try AppSettingsRowDefaults.insertIfMissing(
                in: db, learningTimeZoneID: defaultTimeZoneID
            )
            return try Self.fetchAndInitializeIfNeeded(in: db)
        }
    }

    public func saveAIConfiguration(_ configuration: AIConfiguration) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    UPDATE app_settings
                    SET ai_enabled = ?, ai_provider_id = ?, ai_service_name = ?,
                        ai_base_url = ?, ai_model_id = ?, ai_credential_id = ?,
                        ai_response_format_mode = ?
                    WHERE id = 1
                    """,
                arguments: [
                    configuration.isEnabled,
                    configuration.serviceKind.rawValue,
                    configuration.serviceName,
                    configuration.baseURL.absoluteString,
                    configuration.modelID,
                    configuration.credentialReference.id.uuidString.lowercased(),
                    configuration.responseFormatMode.rawValue
                ]
            )
            guard db.changesCount == 1 else {
                throw AIConfigurationError.invalidPersistedConfiguration
            }
        }
    }

    private static func fetchAndInitializeIfNeeded(in db: Database) throws -> AIConfiguration {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM app_settings WHERE id = 1") else {
            throw AIConfigurationError.invalidPersistedConfiguration
        }

        let providerID: String? = row["ai_provider_id"]
        let baseURL: String? = row["ai_base_url"]
        let modelID: String? = row["ai_model_id"]
        let serviceName: String? = row["ai_service_name"]
        let credentialIDText: String? = row["ai_credential_id"]
        let responseFormatModeText: String = row["ai_response_format_mode"]
        if providerID == nil || baseURL == nil || modelID == nil
            || serviceName == nil || credentialIDText == nil {
            let defaults = AIConfigurationDraft.deepSeekDefault
            let credentialID = UUID()
            try db.execute(
                sql: """
                    UPDATE app_settings
                    SET ai_enabled = 0, ai_provider_id = ?, ai_service_name = ?,
                        ai_base_url = ?, ai_model_id = ?, ai_credential_id = ?,
                        ai_response_format_mode = ?
                    WHERE id = 1
                    """,
                arguments: [
                    defaults.serviceKind.rawValue,
                    defaults.serviceName,
                    defaults.baseURL,
                    defaults.modelID,
                    credentialID.uuidString.lowercased(),
                    defaults.responseFormatMode.rawValue
                ]
            )
            return try AIConfigurationValidator.validate(defaults, credentialID: credentialID)
        }

        guard let credentialIDText,
              let credentialID = UUID(uuidString: credentialIDText),
              let providerID,
              let baseURL,
              let modelID,
              let serviceName,
              let responseFormatMode = AIResponseFormatMode(rawValue: responseFormatModeText) else {
            throw AIConfigurationError.invalidPersistedConfiguration
        }
        let serviceKind = AIServiceKind(rawValue: providerID) ?? .custom
        let draft = AIConfigurationDraft(
            isEnabled: row["ai_enabled"],
            serviceKind: serviceKind,
            serviceName: serviceKind == .custom ? serviceName : "DeepSeek",
            baseURL: baseURL,
            modelID: modelID,
            responseFormatMode: responseFormatMode
        )
        do {
            return try AIConfigurationValidator.validate(draft, credentialID: credentialID)
        } catch {
            throw AIConfigurationError.invalidPersistedConfiguration
        }
    }
}
