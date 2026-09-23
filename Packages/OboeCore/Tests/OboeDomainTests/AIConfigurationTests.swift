import Foundation
import XCTest
@testable import OboeDomain

final class AIConfigurationTests: XCTestCase {
    func testDeepSeekPresetPersistsEditedEndpointAndCanonicalName() throws {
        // 预设地址可编辑（代理/网关场景）：持久化用户改过的地址，
        // 服务名仍以注册表规范名为准。
        var draft = AIConfigurationDraft.deepSeekDefault
        draft.serviceName = "被忽略"
        draft.baseURL = "https://proxy.example.com/v1/"
        draft.modelID = "  deepseek-v4-flash  "

        let configuration = try AIConfigurationValidator.validate(
            draft,
            credentialID: UUID()
        )

        XCTAssertEqual(configuration.serviceKind, .deepSeek)
        XCTAssertEqual(configuration.serviceName, "DeepSeek")
        XCTAssertEqual(
            configuration.baseURL.absoluteString, "https://proxy.example.com/v1"
        )
        XCTAssertEqual(configuration.modelID, "deepseek-v4-flash")
        XCTAssertFalse(configuration.isEnabled)

        // 未编辑时沿用官方地址。
        var untouched = AIConfigurationDraft.deepSeekDefault
        untouched.modelID = "deepseek-v4-flash"
        let official = try AIConfigurationValidator.validate(
            untouched,
            credentialID: UUID()
        )
        XCTAssertEqual(official.baseURL.absoluteString, "https://api.deepseek.com")

        // 非法地址照常拒绝（预设同样走 HTTPS/凭据/查询校验）。
        draft.baseURL = "http://unsafe.example"
        XCTAssertThrowsError(
            try AIConfigurationValidator.validate(draft, credentialID: UUID())
        ) {
            XCTAssertEqual($0 as? AIConfigurationError, .secureHTTPSRequired)
        }
    }

    func testCustomEndpointRequiresHTTPSAndRejectsEmbeddedCredentialsOrQuery() throws {
        let credentialID = UUID()
        var draft = AIConfigurationDraft(
            isEnabled: false,
            serviceKind: .custom,
            serviceName: "  本机兼容服务  ",
            baseURL: "https://EXAMPLE.com:443/v1///",
            modelID: " local-model "
        )

        let configuration = try AIConfigurationValidator.validate(
            draft,
            credentialID: credentialID
        )
        XCTAssertEqual(configuration.serviceName, "本机兼容服务")
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://example.com/v1")
        XCTAssertEqual(configuration.credentialAuthority, "example.com")

        draft.baseURL = "http://example.com/v1"
        XCTAssertThrowsError(try AIConfigurationValidator.validate(draft, credentialID: credentialID)) {
            XCTAssertEqual($0 as? AIConfigurationError, .secureHTTPSRequired)
        }
        draft.baseURL = "https://user:secret@example.com/v1"
        XCTAssertThrowsError(try AIConfigurationValidator.validate(draft, credentialID: credentialID)) {
            XCTAssertEqual($0 as? AIConfigurationError, .credentialsInURLNotAllowed)
        }
        draft.baseURL = "https://example.com/v1?token=secret"
        XCTAssertThrowsError(try AIConfigurationValidator.validate(draft, credentialID: credentialID)) {
            XCTAssertEqual($0 as? AIConfigurationError, .queryOrFragmentNotAllowed)
        }
    }

    func testCredentialIsRetainedForSameBindingButNeverReusedAfterServiceOrHostChange() async throws {
        let initial = try AIConfigurationValidator.validate(
            .deepSeekDefault,
            credentialID: UUID()
        )
        let repository = FakeAIConfigurationRepository(configuration: initial)
        let credentials = FakeAICredentialStore()
        let service = AIConfigurationService(
            repository: repository,
            credentialStore: credentials
        )

        var deepSeek = AIConfigurationDraft.deepSeekDefault
        deepSeek.isEnabled = true
        deepSeek.modelID = "deepseek-v4-pro"
        let configured = try await service.save(
            deepSeek,
            apiKey: "  sk-private-value  ",
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(configured.hasAPIKey)
        let configuredKey = await credentials.credential(
            for: configured.configuration.credentialReference
        )
        XCTAssertEqual(configuredKey, "sk-private-value")

        deepSeek.modelID = "deepseek-v4-flash"
        let modelChanged = try await service.save(
            deepSeek,
            apiKey: nil,
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(modelChanged.hasAPIKey)
        XCTAssertEqual(
            modelChanged.configuration.credentialReference.id,
            configured.configuration.credentialReference.id
        )

        let custom = AIConfigurationDraft(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "兼容服务",
            baseURL: "https://other.example/v1",
            modelID: "model-a"
        )
        do {
            _ = try await service.save(
                custom,
                apiKey: nil,
                defaultTimeZoneID: "Asia/Shanghai"
            )
            XCTFail("A changed service/host must require a newly entered key")
        } catch let error as AIConfigurationError {
            XCTAssertEqual(error, .apiKeyRequired)
        }

        let switched = try await service.save(
            custom,
            apiKey: "custom-secret",
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertTrue(switched.hasAPIKey)
        XCTAssertNotEqual(
            switched.configuration.credentialReference.id,
            configured.configuration.credentialReference.id
        )
        let oldKey = await credentials.credential(
            for: configured.configuration.credentialReference
        )
        let switchedKey = await credentials.credential(
            for: switched.configuration.credentialReference
        )
        XCTAssertNil(oldKey)
        XCTAssertEqual(switchedKey, "custom-secret")
    }

    /// v0.5 及更早版本首次载入会把示例模型名「deepseek-v4-pro」落库；
    /// 从未保存 Key 的未启用行应被归一化为「未选择」且持久化清除。
    func testLegacyAutoInsertedModelIsClearedWhenNoKeyWasEverSaved() async throws {
        var legacyDraft = AIConfigurationDraft.deepSeekDefault
        legacyDraft.modelID = "deepseek-v4-pro"
        let initial = try AIConfigurationValidator.validate(
            legacyDraft, credentialID: UUID()
        )
        let repository = FakeAIConfigurationRepository(configuration: initial)
        let credentials = FakeAICredentialStore()
        let service = AIConfigurationService(
            repository: repository,
            credentialStore: credentials
        )

        let loaded = try await service.load(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertNil(loaded.configuration.modelID)
        XCTAssertFalse(loaded.configuration.isEnabled)

        let reloaded = try await service.load(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertNil(reloaded.configuration.modelID)
    }

    /// 存过 Key 的「deepseek-v4-pro」视为用户确认过的选择，原样保留；
    /// 已启用状态同样不动（避免静默关闭曾可用的配置）。
    func testLegacyModelNameIsKeptWhenKeyExistsOrEnabled() async throws {
        var legacyDraft = AIConfigurationDraft.deepSeekDefault
        legacyDraft.modelID = "deepseek-v4-pro"
        let initial = try AIConfigurationValidator.validate(
            legacyDraft, credentialID: UUID()
        )
        let repository = FakeAIConfigurationRepository(configuration: initial)
        let credentials = FakeAICredentialStore()
        let service = AIConfigurationService(
            repository: repository,
            credentialStore: credentials
        )
        try await credentials.saveCredential(
            "sk-x", for: initial.credentialReference
        )

        let loaded = try await service.load(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(loaded.configuration.modelID, "deepseek-v4-pro")
        XCTAssertTrue(loaded.hasAPIKey)
    }

    func testRemovingCredentialDisablesAIWithoutChangingOfflineConfiguration() async throws {
        let initial = try AIConfigurationValidator.validate(
            .deepSeekDefault,
            credentialID: UUID()
        )
        let repository = FakeAIConfigurationRepository(configuration: initial)
        let credentials = FakeAICredentialStore()
        let service = AIConfigurationService(
            repository: repository,
            credentialStore: credentials
        )
        var draft = AIConfigurationDraft.deepSeekDefault
        draft.isEnabled = true
        draft.modelID = "deepseek-v4-pro"
        let configured = try await service.save(
            draft,
            apiKey: "secret",
            defaultTimeZoneID: "Asia/Shanghai"
        )

        let removed = try await service.removeAPIKey(defaultTimeZoneID: "Asia/Shanghai")

        XCTAssertFalse(removed.configuration.isEnabled)
        XCTAssertFalse(removed.hasAPIKey)
        XCTAssertEqual(removed.configuration.modelID, configured.configuration.modelID)
        let deletedKey = await credentials.credential(
            for: configured.configuration.credentialReference
        )
        XCTAssertNil(deletedKey)
    }

    func testDraftWithoutModelIsValidButNotExecutable() throws {
        var draft = AIConfigurationDraft.deepSeekDefault
        draft.isEnabled = false

        let configuration = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        XCTAssertNil(configuration.modelID)
        XCTAssertNil(configuration.resolved)
        XCTAssertThrowsError(try configuration.requireResolved()) {
            XCTAssertEqual($0 as? AIConfigurationError, .modelIDRequired)
        }
        XCTAssertThrowsError(
            try AIConfigurationValidator.resolve(draft, credentialID: UUID())
        ) {
            XCTAssertEqual($0 as? AIConfigurationError, .modelIDRequired)
        }

        draft.modelID = "   "
        let stillEmpty = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        XCTAssertNil(stillEmpty.modelID)

        draft.modelID = "deepseek-v4-pro"
        let resolved = try AIConfigurationValidator.resolve(draft, credentialID: UUID())
        XCTAssertEqual(resolved.modelID, "deepseek-v4-pro")
        XCTAssertEqual(resolved.serviceKind, .deepSeek)
    }

    func testSaveAllowsDisabledDraftWithoutModelButRejectsEnabledOne() async throws {
        let initial = try AIConfigurationValidator.validate(
            .deepSeekDefault,
            credentialID: UUID()
        )
        let repository = FakeAIConfigurationRepository(configuration: initial)
        let credentials = FakeAICredentialStore()
        let service = AIConfigurationService(
            repository: repository,
            credentialStore: credentials
        )

        // 禁用状态下保存「供应商已选、模型未选」是合法的。
        let disabled = try await service.save(
            .deepSeekDefault,
            apiKey: "sk-x",
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertNil(disabled.configuration.modelID)
        XCTAssertTrue(disabled.hasAPIKey)

        var enabledNoModel = AIConfigurationDraft.deepSeekDefault
        enabledNoModel.isEnabled = true
        do {
            _ = try await service.save(
                enabledNoModel,
                apiKey: nil,
                defaultTimeZoneID: "Asia/Shanghai"
            )
            XCTFail("启用 AI 必须先选择模型")
        } catch let error as AIConfigurationError {
            XCTAssertEqual(error, .modelIDRequired)
        }
    }

    func testHostChangeRebindsCredentialEvenWithinSameServiceKind() async throws {
        let initial = try AIConfigurationValidator.validate(
            .deepSeekDefault,
            credentialID: UUID()
        )
        let repository = FakeAIConfigurationRepository(configuration: initial)
        let credentials = FakeAICredentialStore()
        let service = AIConfigurationService(
            repository: repository,
            credentialStore: credentials
        )

        let hostA = AIConfigurationDraft(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "服务A",
            baseURL: "https://a.example/v1",
            modelID: "m"
        )
        let configured = try await service.save(
            hostA,
            apiKey: "key-a",
            defaultTimeZoneID: "Asia/Shanghai"
        )

        var hostB = hostA
        hostB.baseURL = "https://b.example/v1"
        do {
            _ = try await service.save(
                hostB,
                apiKey: nil,
                defaultTimeZoneID: "Asia/Shanghai"
            )
            XCTFail("host 变化必须要求重新输入 Key")
        } catch let error as AIConfigurationError {
            XCTAssertEqual(error, .apiKeyRequired)
        }

        let switched = try await service.save(
            hostB,
            apiKey: "key-b",
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertNotEqual(
            switched.configuration.credentialReference.id,
            configured.configuration.credentialReference.id
        )
        let oldKey = await credentials.credential(
            for: configured.configuration.credentialReference
        )
        XCTAssertNil(oldKey)
    }
}

private actor FakeAIConfigurationRepository: AIConfigurationRepository {
    private var configuration: AIConfiguration

    init(configuration: AIConfiguration) {
        self.configuration = configuration
    }

    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) async throws -> AIConfiguration {
        configuration
    }

    func saveAIConfiguration(_ configuration: AIConfiguration) async throws {
        self.configuration = configuration
    }
}

private actor FakeAICredentialStore: AICredentialStore {
    private var credentials: [AICredentialReference: String] = [:]

    func readCredential(for reference: AICredentialReference) async throws -> String? {
        credentials[reference]
    }

    func saveCredential(_ credential: String, for reference: AICredentialReference) async throws {
        credentials[reference] = credential
    }

    func deleteCredential(for reference: AICredentialReference) async throws {
        credentials[reference] = nil
    }

    func credential(for reference: AICredentialReference) -> String? {
        credentials[reference]
    }
}
