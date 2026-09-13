import Foundation
import XCTest
@testable import OboeDomain

final class AIConnectionTests: XCTestCase {
    func testDisabledConfigurationNeverReadsCredentialOrStartsNetwork() async throws {
        let configuration = try AIConfigurationValidator.validate(
            .deepSeekDefault,
            credentialID: UUID()
        )
        let repository = ConnectionTestRepository(configuration: configuration)
        let credentials = ConnectionTestCredentialStore(credential: "test-key")
        let client = RecordingConnectionClient()
        let service = AIConnectionTestService(
            repository: repository,
            credentialStore: credentials,
            client: client
        )

        do {
            _ = try await service.testConnection(defaultTimeZoneID: "Asia/Shanghai")
            XCTFail("Disabled AI must not start a connection test")
        } catch let error as AIConnectionError {
            XCTAssertEqual(error, .aiDisabled)
        }
        let credentialReadCount = await credentials.readCount
        let clientCallCount = await client.callCount
        XCTAssertEqual(credentialReadCount, 0)
        XCTAssertEqual(clientCallCount, 0)
    }

    func testEnabledConfigurationRequiresCredentialBeforeNetwork() async throws {
        var draft = AIConfigurationDraft.deepSeekDefault
        draft.isEnabled = true
        let configuration = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        let client = RecordingConnectionClient()
        let service = AIConnectionTestService(
            repository: ConnectionTestRepository(configuration: configuration),
            credentialStore: ConnectionTestCredentialStore(credential: nil),
            client: client
        )

        do {
            _ = try await service.testConnection(defaultTimeZoneID: "Asia/Shanghai")
            XCTFail("Missing credentials must fail locally")
        } catch let error as AIConnectionError {
            XCTAssertEqual(error, .credentialMissing)
        }
        let clientCallCount = await client.callCount
        XCTAssertEqual(clientCallCount, 0)
    }

    func testEnabledConfigurationPassesOnlyCurrentBindingToClient() async throws {
        var draft = AIConfigurationDraft(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "兼容服务",
            baseURL: "https://model.example/v1",
            modelID: "jp-model",
            responseFormatMode: .jsonSchema
        )
        let configuration = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        let client = RecordingConnectionClient()
        let service = AIConnectionTestService(
            repository: ConnectionTestRepository(configuration: configuration),
            credentialStore: ConnectionTestCredentialStore(credential: "test-only-key"),
            client: client
        )

        let result = try await service.testConnection(defaultTimeZoneID: "Asia/Shanghai")

        XCTAssertEqual(result.serviceName, "兼容服务")
        XCTAssertEqual(result.responseFormatMode, .jsonSchema)
        let received = await client.received
        XCTAssertEqual(received?.configuration, configuration)
        XCTAssertEqual(received?.credential, "test-only-key")

        draft.responseFormatMode = .promptedJSON
        XCTAssertNotEqual(draft.responseFormatMode, result.responseFormatMode)
    }
}

private actor ConnectionTestRepository: AIConfigurationRepository {
    let configuration: AIConfiguration

    init(configuration: AIConfiguration) {
        self.configuration = configuration
    }

    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) -> AIConfiguration {
        configuration
    }

    func saveAIConfiguration(_ configuration: AIConfiguration) {}
}

private actor ConnectionTestCredentialStore: AICredentialStore {
    let credential: String?
    private(set) var readCount = 0

    init(credential: String?) {
        self.credential = credential
    }

    func readCredential(for reference: AICredentialReference) -> String? {
        readCount += 1
        return credential
    }

    func saveCredential(_ credential: String, for reference: AICredentialReference) {}
    func deleteCredential(for reference: AICredentialReference) {}
}

private actor RecordingConnectionClient: AIConnectionClient {
    private(set) var callCount = 0
    private(set) var received: (configuration: AIConfiguration, credential: String)?

    func testConnection(
        configuration: AIConfiguration,
        credential: String
    ) -> AIConnectionTestResult {
        callCount += 1
        received = (configuration, credential)
        return AIConnectionTestResult(
            serviceName: configuration.serviceName,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode
        )
    }
}
