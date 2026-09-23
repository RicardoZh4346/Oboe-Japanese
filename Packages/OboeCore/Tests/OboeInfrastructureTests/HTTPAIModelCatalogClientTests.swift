import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class HTTPAIModelCatalogClientTests: XCTestCase {
    // MARK: - Endpoint & headers

    func testPresetEndpointsAndBearerHeaders() async throws {
        let cases: [(AIServiceKind, String)] = [
            (.deepSeek, "https://api.deepseek.com/models"),
            (.kimi, "https://api.moonshot.cn/v1/models"),
            (.glm, "https://open.bigmodel.cn/api/paas/v4/models"),
            (.openAI, "https://api.openai.com/v1/models"),
            (.qwen, "https://dashscope.aliyuncs.com/api/v1/models"),
            (.grok, "https://api.x.ai/v1/language-models")
        ]
        for (kind, expectedURL) in cases {
            let recorder = CatalogRequestRecorder()
            let configuration = try makeConfiguration(kind: kind)
            let client = HTTPAIModelCatalogClient(
                transport: StubCatalogTransport(
                    handler: { _ in
                        AIHTTPResponse(
                            statusCode: 200,
                            headers: [:],
                            body: Self.openAIListBody(ids: ["m-1"])
                        )
                    },
                    recorder: recorder
                )
            )
            _ = try await client.fetchModels(
                configuration: configuration,
                credential: "catalog-test-key"
            )
            let requests = await recorder.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, expectedURL, kind.rawValue)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer catalog-test-key",
                kind.rawValue
            )
            XCTAssertEqual(request.timeoutInterval, 20)
        }
    }

    func testPresetWithUserEditedBaseURLFetchesFromEditedURL() async throws {
        // 预设地址只是初始值：用户把 Kimi 改为网关地址后，
        // 模型列表必须请求编辑后的 baseURL，协议族/路径/鉴权头仍按注册表。
        var draft = AIConfigurationDraft.preset(.kimi)
        draft.baseURL = "https://gateway.example.com/moonshot"
        let configuration = try AIConfigurationValidator.validate(
            draft, credentialID: UUID()
        )
        let recorder = CatalogRequestRecorder()
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in
                    AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Self.openAIListBody(ids: ["m-1"])
                    )
                },
                recorder: recorder
            )
        )
        _ = try await client.fetchModels(
            configuration: configuration,
            credential: "catalog-test-key"
        )
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://gateway.example.com/moonshot/models"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer catalog-test-key"
        )
    }

    func testAnthropicUsesAPIKeyHeaderAndVersion() async throws {
        let recorder = CatalogRequestRecorder()
        let configuration = try makeConfiguration(kind: .claude)
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in
                    AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"data":[{"id":"claude-x","display_name":"Claude X"}],"has_more":false}"#.utf8)
                    )
                },
                recorder: recorder
            )
        )
        let models = try await client.fetchModels(
            configuration: configuration,
            credential: "claude-key"
        )
        XCTAssertEqual(models.map(\.id), ["claude-x"])
        XCTAssertEqual(models.first?.displayName, "Claude X")
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.anthropic.com/v1/models?limit=100"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "claude-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGeminiUsesGoogAPIKeyHeaderAndPageSize() async throws {
        let recorder = CatalogRequestRecorder()
        let configuration = try makeConfiguration(kind: .gemini)
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in
                    AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}]}"#.utf8)
                    )
                },
                recorder: recorder
            )
        )
        let models = try await client.fetchModels(
            configuration: configuration,
            credential: "gemini-key"
        )
        XCTAssertEqual(models.map(\.id), ["gemini-2.5-flash"])
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCustomServiceAppendsModelsOnce() async throws {
        let recorder = CatalogRequestRecorder()
        var draft = AIConfigurationDraft(
            isEnabled: false,
            serviceKind: .custom,
            serviceName: "私有服务",
            baseURL: "https://internal.example/v1/models",
            modelID: nil
        )
        var configuration = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in
                    AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Self.openAIListBody(ids: ["local-model"])
                    )
                },
                recorder: recorder
            )
        )
        _ = try await client.fetchModels(configuration: configuration, credential: "k")
        var requests = await recorder.requests
        var request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://internal.example/v1/models")

        // baseURL 不带 /models 时拼接一次
        draft.baseURL = "https://internal.example/v1/"
        configuration = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        _ = try await client.fetchModels(configuration: configuration, credential: "k")
        requests = await recorder.requests
        request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.url?.absoluteString, "https://internal.example/v1/models")
    }

    // MARK: - Decoders, pagination, dedupe, filtering

    func testOpenAIFormatDeduplicatesAndSorts() async throws {
        let body = Data(#"{"object":"list","data":[{"id":"z-model"},{"id":"a-model"},{"id":"z-model"}]}"#.utf8)
        let models = try await fetchAll(body: body, kind: .deepSeek)
        XCTAssertEqual(models.map(\.id), ["a-model", "z-model"])
    }

    func testAnthropicPaginatesViaAfterID() async throws {
        let recorder = CatalogRequestRecorder()
        let configuration = try makeConfiguration(kind: .claude)
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { request in
                    let query = request.url?.query ?? ""
                    if query.contains("after_id=claude-last") {
                        return AIHTTPResponse(
                            statusCode: 200,
                            headers: [:],
                            body: Data(#"{"data":[{"id":"claude-2"}],"has_more":false}"#.utf8)
                        )
                    }
                    return AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"data":[{"id":"claude-1"},{"id":"claude-1"}],"has_more":true,"last_id":"claude-last"}"#.utf8)
                    )
                },
                recorder: recorder
            )
        )
        let models = try await client.fetchModels(configuration: configuration, credential: "k")
        XCTAssertEqual(models.map(\.id), ["claude-1", "claude-2"])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].url?.query?.contains("after_id=claude-last") == true)
        XCTAssertTrue(requests[1].url?.query?.contains("limit=100") == true)
    }

    func testGeminiPaginatesViaPageTokenAndFiltersCapabilities() async throws {
        let recorder = CatalogRequestRecorder()
        let configuration = try makeConfiguration(kind: .gemini)
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { request in
                    let query = request.url?.query ?? ""
                    if query.contains("pageToken=tok2") {
                        return AIHTTPResponse(
                            statusCode: 200,
                            headers: [:],
                            body: Data(#"{"models":[{"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent"]}]}"#.utf8)
                        )
                    }
                    return AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data("""
                        {"models":[
                            {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]},
                            {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},
                            {"name":"models/imagen-3","supportedGenerationMethods":["generateContent"]},
                            {"name":"models/gemini-flash-tts","supportedGenerationMethods":["generateContent"]}
                        ],"nextPageToken":"tok2"}
                        """.utf8)
                    )
                },
                recorder: recorder
            )
        )
        let models = try await client.fetchModels(configuration: configuration, credential: "k")
        XCTAssertEqual(models.map(\.id), ["gemini-2.5-flash", "gemini-2.5-pro"])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].url?.query?.contains("pageToken=tok2") == true)
    }

    func testDashScopeFormatReadsNestedModels() async throws {
        let body = Data(#"{"request_id":"r1","data":{"models":[{"model":"qwen-max"},{"model":"text-embedding-v3"},{"model_id":"qwen-plus"}]}}"#.utf8)
        let models = try await fetchAll(body: body, kind: .qwen)
        XCTAssertEqual(models.map(\.id), ["qwen-max", "qwen-plus"])
    }

    func testXAIFiltersNonTextModels() async throws {
        let body = Data("""
        {"models":[
            {"id":"grok-4","output_modalities":["text"]},
            {"id":"grok-2-image","output_modalities":["image"]},
            {"id":"grok-embedding","output_modalities":["text"]},
            {"id":"grok-3-mini","output_modalities":["text"]}
        ]}
        """.utf8)
        let models = try await fetchAll(body: body, kind: .grok)
        XCTAssertEqual(models.map(\.id), ["grok-3-mini", "grok-4"])
    }

    func testMalformedAndEmptyResponsesThrow() async throws {
        let configuration = try makeConfiguration(kind: .deepSeek)
        let cases: [(Data, AIModelCatalogError)] = [
            (Data("not-json".utf8), .malformedResponse),
            (Data(#"{"unexpected":[]}"#.utf8), .malformedResponse),
            (Data(#"{"data":[]}"#.utf8), .emptyModelList),
            // 全部被能力过滤排除也视同空列表——不提供自由输入旁路。
            (Data(#"{"data":[{"id":"text-embedding-3-large"},{"id":"tts-1"}]}"#.utf8), .emptyModelList)
        ]
        for (body, expected) in cases {
            let client = HTTPAIModelCatalogClient(
                transport: StubCatalogTransport(
                    handler: { _ in AIHTTPResponse(statusCode: 200, headers: [:], body: body) }
                )
            )
            let error = await catalogError(from: client, configuration: configuration)
            XCTAssertEqual(error, expected)
        }
    }

    // MARK: - Error mapping & transport failures

    func testHTTPFailuresMapWithoutLeakingSecrets() async throws {
        let configuration = try makeConfiguration(kind: .openAI)
        let cases: [(Int, [String: String], AIModelCatalogError)] = [
            (400, [:], .unsupportedConfiguration(statusCode: 400)),
            (401, [:], .authenticationFailed),
            (403, [:], .authenticationFailed),
            (404, [:], .unsupportedConfiguration(statusCode: 404)),
            (429, ["Retry-After": "9"], .rateLimited(retryAfterSeconds: 9)),
            (500, [:], .serviceUnavailable(statusCode: 500)),
            (502, [:], .serviceUnavailable(statusCode: 502)),
            (418, [:], .unexpectedStatus(statusCode: 418))
        ]
        let secretBody = Data(#"{"error":"catalog-test-key api.openai.com"}"#.utf8)
        for (status, headers, expected) in cases {
            let client = HTTPAIModelCatalogClient(
                transport: StubCatalogTransport(
                    handler: { _ in
                        AIHTTPResponse(statusCode: status, headers: headers, body: secretBody)
                    }
                )
            )
            let error = await catalogError(from: client, configuration: configuration)
            XCTAssertEqual(error, expected, "status \(status)")
            XCTAssertFalse(error?.localizedDescription.contains("catalog-test-key") == true)
            XCTAssertFalse(error?.localizedDescription.contains("api.openai.com") == true)
        }
    }

    func testTransportErrorsMapAndOversizeRejected() async throws {
        let configuration = try makeConfiguration(kind: .openAI)
        let urlCases: [(URLError.Code, AIModelCatalogError)] = [
            (.cancelled, .cancelled),
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .networkUnavailable),
            (.serverCertificateUntrusted, .secureConnectionFailed),
            (.cannotConnectToHost, .connectionFailed)
        ]
        for (code, expected) in urlCases {
            let client = HTTPAIModelCatalogClient(
                transport: StubCatalogTransport(handler: { _ in throw URLError(code) })
            )
            let error = await catalogError(from: client, configuration: configuration)
            XCTAssertEqual(error, expected, "\(code)")
        }

        // transport 层拒绝跨域重定向 → redirectRejected
        let redirected = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in throw AIConnectionError.redirectRejected }
            )
        )
        let error = await catalogError(from: redirected, configuration: configuration)
        XCTAssertEqual(error, .redirectRejected)

        // 超大响应
        let oversized = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in
                    AIHTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(
                            repeating: 0x20,
                            count: HTTPAIModelCatalogClient.maximumResponseBytes + 1
                        )
                    )
                }
            )
        )
        let oversizeError = await catalogError(from: oversized, configuration: configuration)
        XCTAssertEqual(oversizeError, .responseTooLarge)
    }

    func testCancellationMapsToCancelledError() async throws {
        let configuration = try makeConfiguration(kind: .openAI)
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(handler: { _ in throw CancellationError() })
        )
        let error = await catalogError(from: client, configuration: configuration)
        XCTAssertEqual(error, .cancelled)
    }

    // MARK: - UI test client

    func testUITestClientReturnsStableDeterministicList() async throws {
        let configuration = try makeConfiguration(kind: .deepSeek)
        let client = UITestAIModelCatalogClient()
        let first = try await client.fetchModels(configuration: configuration, credential: "k")
        let second = try await client.fetchModels(configuration: configuration, credential: "k")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { $0.id.hasPrefix("uitest-deepseek-") })
    }

    // MARK: - Helpers

    private func makeConfiguration(kind: AIServiceKind) throws -> AIConfiguration {
        try AIConfigurationValidator.validate(
            AIConfigurationDraft.preset(kind),
            credentialID: UUID()
        )
    }

    private func fetchAll(
        body: Data,
        kind: AIServiceKind
    ) async throws -> [AIModelDescriptor] {
        let client = HTTPAIModelCatalogClient(
            transport: StubCatalogTransport(
                handler: { _ in AIHTTPResponse(statusCode: 200, headers: [:], body: body) }
            )
        )
        return try await client.fetchModels(
            configuration: makeConfiguration(kind: kind),
            credential: "k"
        )
    }

    private func catalogError(
        from client: HTTPAIModelCatalogClient,
        configuration: AIConfiguration
    ) async -> AIModelCatalogError? {
        do {
            _ = try await client.fetchModels(configuration: configuration, credential: "k")
            XCTFail("Expected catalog fetch to fail")
            return nil
        } catch let error as AIModelCatalogError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
            return nil
        }
    }

    private static func openAIListBody(ids: [String]) -> Data {
        let data = ids.map { ["id": $0] }
        return try! JSONSerialization.data(withJSONObject: ["object": "list", "data": data])
    }
}

private actor CatalogRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

private struct StubCatalogTransport: AIHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> AIHTTPResponse
    var recorder: CatalogRequestRecorder? = nil

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        await recorder?.record(request)
        return try handler(request)
    }
}
