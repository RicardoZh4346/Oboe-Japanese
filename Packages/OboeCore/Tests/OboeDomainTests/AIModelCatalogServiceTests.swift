import Foundation
import XCTest
@testable import OboeDomain

final class AIModelCatalogServiceTests: XCTestCase {
    func testFetchReturnsModelsAndNeverPersistsAnything() async throws {
        let repository = CatalogTestRepository()
        let client = StubCatalogClient(result: .success([
            AIModelDescriptor(id: "b-model"), AIModelDescriptor(id: "a-model")
        ]))
        let service = AIModelCatalogService(
            repository: repository,
            credentialStore: CatalogCredentialStore(credential: "sk-test"),
            client: client
        )

        let models = try await service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")

        XCTAssertEqual(models.map(\.id), ["b-model", "a-model"])
        let saveCount = await repository.saveCount
        XCTAssertEqual(saveCount, 0, "模型列表不得写入数据库")
    }

    func testFetchRequiresCredentialBeforeHittingClient() async throws {
        let client = StubCatalogClient(result: .success([AIModelDescriptor(id: "m")]))
        let service = AIModelCatalogService(
            repository: CatalogTestRepository(),
            credentialStore: CatalogCredentialStore(credential: nil),
            client: client
        )
        do {
            _ = try await service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")
            XCTFail("缺少 API Key 时不得发起请求")
        } catch let error as AIModelCatalogError {
            XCTAssertEqual(error, .credentialMissing)
        }
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    func testInvalidCredentialFailsLocally() async throws {
        let client = StubCatalogClient(result: .success([AIModelDescriptor(id: "m")]))
        let service = AIModelCatalogService(
            repository: CatalogTestRepository(),
            credentialStore: CatalogCredentialStore(credential: "key\nwith\nnewlines"),
            client: client
        )
        do {
            _ = try await service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")
            XCTFail("非法 Key 不得发起请求")
        } catch let error as AIModelCatalogError {
            XCTAssertEqual(error, .invalidCredential)
        }
        let calls = await client.callCount
        XCTAssertEqual(calls, 0)
    }

    func testNewerFetchSupersedesInFlightResult() async throws {
        let client = BlockingCatalogClient()
        let service = AIModelCatalogService(
            repository: CatalogTestRepository(),
            credentialStore: CatalogCredentialStore(credential: "sk-test"),
            client: client
        )

        async let firstResult = service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")
        await client.waitForCallCount(1)
        async let secondResult = service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")
        await client.waitForCallCount(2)
        await client.releaseAll(models: [AIModelDescriptor(id: "fresh-model")])

        do {
            _ = try await firstResult
            XCTFail("被取代的请求不得交付结果")
        } catch let error as AIModelCatalogError {
            XCTAssertEqual(error, .requestSuperseded)
        }
        let second = try await secondResult
        XCTAssertEqual(second.map(\.id), ["fresh-model"])
    }

    func testInvalidateDiscardsInFlightResultAfterBindingChange() async throws {
        let client = BlockingCatalogClient()
        let repository = CatalogTestRepository()
        let service = AIModelCatalogService(
            repository: repository,
            credentialStore: CatalogCredentialStore(credential: "sk-test"),
            client: client
        )

        async let staleResult = service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")
        await client.waitForCallCount(1)
        // 供应商 / Key / URL 变化：在途结果必须作废。
        await service.invalidatePendingFetches()
        await client.releaseAll(models: [AIModelDescriptor(id: "stale-model")])

        do {
            _ = try await staleResult
            XCTFail("作废旧结果不得交付")
        } catch let error as AIModelCatalogError {
            XCTAssertEqual(error, .requestSuperseded)
        }
    }

    func testCancelledTaskThrowsAndDeliversNothing() async throws {
        let client = BlockingCatalogClient()
        let service = AIModelCatalogService(
            repository: CatalogTestRepository(),
            credentialStore: CatalogCredentialStore(credential: "sk-test"),
            client: client
        )

        let task = Task {
            try await service.fetchModels(defaultTimeZoneID: "Asia/Shanghai")
        }
        await client.waitForCallCount(1)
        task.cancel()
        await client.releaseAll(models: [AIModelDescriptor(id: "late-model")])

        do {
            _ = try await task.value
            XCTFail("取消的任务不得交付结果")
        } catch is CancellationError {
            // 预期：页面状态不更新。
        }
    }
}

private actor CatalogTestRepository: AIConfigurationRepository {
    private(set) var saveCount = 0
    var configuration = AIConfiguration(
        isEnabled: false,
        serviceKind: .deepSeek,
        serviceName: "DeepSeek",
        baseURL: URL(string: "https://api.deepseek.com")!,
        modelID: nil,
        responseFormatMode: .jsonObject,
        credentialReference: AICredentialReference(
            id: UUID(),
            serviceKind: .deepSeek,
            host: "api.deepseek.com"
        )
    )

    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) async throws -> AIConfiguration {
        configuration
    }

    func saveAIConfiguration(_ configuration: AIConfiguration) async throws {
        saveCount += 1
    }
}

private actor CatalogCredentialStore: AICredentialStore {
    let credential: String?

    init(credential: String?) { self.credential = credential }

    func readCredential(for reference: AICredentialReference) async throws -> String? {
        credential
    }

    func saveCredential(_ credential: String, for reference: AICredentialReference) async throws {}
    func deleteCredential(for reference: AICredentialReference) async throws {}
}

private actor StubCatalogClient: AIModelCatalogClient {
    let result: Result<[AIModelDescriptor], Error>
    private(set) var callCount = 0

    init(result: Result<[AIModelDescriptor], Error>) { self.result = result }

    func fetchModels(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> [AIModelDescriptor] {
        callCount += 1
        return try result.get()
    }
}

private actor BlockingCatalogClient: AIModelCatalogClient {
    private(set) var callCount = 0
    private var continuations: [CheckedContinuation<[AIModelDescriptor], Error>] = []

    func fetchModels(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> [AIModelDescriptor] {
        callCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async {
        while callCount < count {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func releaseAll(models: [AIModelDescriptor]) {
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume(returning: models)
        }
    }
}
