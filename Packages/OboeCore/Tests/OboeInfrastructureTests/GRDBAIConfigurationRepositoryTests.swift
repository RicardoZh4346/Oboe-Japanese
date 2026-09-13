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
