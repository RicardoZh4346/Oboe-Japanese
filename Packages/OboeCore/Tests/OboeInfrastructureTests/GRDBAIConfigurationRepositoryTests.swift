import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class GRDBAIConfigurationRepositoryTests: XCTestCase {
    func testDefaultsAndCustomConfigurationPersistWithoutCredentialMaterial() async throws {
        let location = AIConfigurationTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBAIConfigurationRepository(database: database)

        let defaults = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertFalse(defaults.isEnabled)
        XCTAssertEqual(defaults.serviceKind, .deepSeek)
        XCTAssertEqual(defaults.baseURL.absoluteString, "https://api.deepseek.com")
        XCTAssertEqual(defaults.responseFormatMode, .jsonObject)

        let custom = try AIConfigurationValidator.validate(
            AIConfigurationDraft(
                isEnabled: true,
                serviceKind: .custom,
                serviceName: "私有兼容服务",
                baseURL: "https://ai.example/v1",
                modelID: "jp-model",
                responseFormatMode: .jsonSchema
            ),
            credentialID: UUID()
        )
        try await repository.saveAIConfiguration(custom)
        try database.close()

        let reopened = try OboeDatabase(path: location.databaseURL.path)
        let loaded = try await GRDBAIConfigurationRepository(database: reopened)
            .loadOrCreateAIConfiguration(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(loaded, custom)
        let columns = try await reopened.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('app_settings')")
        }
        XCTAssertFalse(columns.contains("api_key"))
        XCTAssertFalse(columns.contains("authorization"))
    }

    func testPersistedConfigurationWithoutModelIDLoadsAsUnselectedNotCorrupt() async throws {
        let location = AIConfigurationTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBAIConfigurationRepository(database: database)
        _ = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: "Asia/Shanghai"
        )

        // 模拟「已选供应商、未选模型」的持久化行。
        let credentialID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE app_settings
                    SET ai_enabled = 0, ai_provider_id = 'kimi',
                        ai_service_name = 'Kimi', ai_base_url = 'https://api.moonshot.cn/v1',
                        ai_model_id = NULL, ai_credential_id = ?,
                        ai_response_format_mode = 'json_object'
                    WHERE id = 1
                    """,
                arguments: [credentialID.uuidString.lowercased()]
            )
        }

        let loaded = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(loaded.serviceKind, .kimi)
        XCTAssertEqual(loaded.serviceName, "Kimi（Moonshot AI）")
        XCTAssertEqual(loaded.baseURL.absoluteString, "https://api.moonshot.cn/v1")
        XCTAssertNil(loaded.modelID)
        XCTAssertNil(loaded.resolved)
        XCTAssertEqual(loaded.credentialReference.id, credentialID)
    }

    func testLegacyV05DeepSeekRowLoadsWithoutLoss() async throws {
        let location = AIConfigurationTestLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.databaseURL.path)
        let repository = GRDBAIConfigurationRepository(database: database)
        _ = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: "Asia/Shanghai"
        )

        // v0.5 写入的行：provider=deepseek、显式模型名、json_object。
        let credentialID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE app_settings
                    SET ai_enabled = 1, ai_provider_id = 'deepseek',
                        ai_service_name = 'DeepSeek', ai_base_url = 'https://api.deepseek.com',
                        ai_model_id = 'deepseek-v4-pro', ai_credential_id = ?,
                        ai_response_format_mode = 'json_object'
                    WHERE id = 1
                    """,
                arguments: [credentialID.uuidString.lowercased()]
            )
        }

        let loaded = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertEqual(loaded.serviceKind, .deepSeek)
        XCTAssertEqual(loaded.modelID, "deepseek-v4-pro")
        XCTAssertEqual(loaded.resolved?.modelID, "deepseek-v4-pro")
        XCTAssertEqual(loaded.credentialReference.id, credentialID)
        XCTAssertEqual(loaded.credentialReference.host, "api.deepseek.com")

        // 无 modelID 的配置可往返保存。
        var draft = AIConfigurationDraft(configuration: loaded)
        draft.isEnabled = false
        draft.modelID = nil
        let unselected = try AIConfigurationValidator.validate(
            draft,
            credentialID: loaded.credentialReference.id
        )
        try await repository.saveAIConfiguration(unselected)
        let reloaded = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(reloaded, unselected)
        XCTAssertNil(reloaded.modelID)
    }

    func testKeychainAccountIsBoundToReferenceProviderAndHost() {
        let id = UUID()
        let deepSeek = AICredentialReference(
            id: id,
            serviceKind: .deepSeek,
            host: "api.deepseek.com"
        )
        let customSameHost = AICredentialReference(
            id: id,
            serviceKind: .custom,
            host: "api.deepseek.com"
        )
        let customOtherHost = AICredentialReference(
            id: id,
            serviceKind: .custom,
            host: "other.example"
        )

        XCTAssertNotEqual(
            KeychainAICredentialStore.account(for: deepSeek),
            KeychainAICredentialStore.account(for: customSameHost)
        )
        XCTAssertNotEqual(
            KeychainAICredentialStore.account(for: customSameHost),
            KeychainAICredentialStore.account(for: customOtherHost)
        )
    }
}

private struct AIConfigurationTestLocation {
    let directoryURL: URL
    let databaseURL: URL

    init() {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AIConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try! FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
