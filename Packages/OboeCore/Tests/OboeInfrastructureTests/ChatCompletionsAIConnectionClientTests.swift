import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class ChatCompletionsAIConnectionClientTests: XCTestCase {
    func testBuildsMinimalAuthenticatedDeepSeekRequestAndAcceptsFixedResponse() async throws {
        let recorder = AIRequestRecorder()
        let transport = FixedAIHTTPTransport(
            response: AIHTTPResponse(
                statusCode: 200,
                headers: [:],
                body: completionBody(content: #"{"ok":true}"#)
            ),
            recorder: recorder
        )
        var draft = AIConfigurationDraft.deepSeekDefault
        draft.isEnabled = true
        draft.modelID = "deepseek-v4-pro"
        let configuration = try AIConfigurationValidator.resolve(draft, credentialID: UUID())
        let client = ChatCompletionsAIConnectionClient(transport: transport)

        let result = try await client.testConnection(
            configuration: configuration,
            credential: "test-only-key"
        )

        XCTAssertEqual(result.modelID, "deepseek-v4-pro")
        XCTAssertEqual(result.responseFormatMode, .jsonObject)
        let captured = await recorder.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
        let body = try requestJSONObject(request)
        XCTAssertEqual(body["model"] as? String, "deepseek-v4-pro")
        XCTAssertEqual(body["max_tokens"] as? Int, 128)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(
            (body["response_format"] as? [String: Any])?["type"] as? String,
            "json_object"
        )
    }

    func testCapabilityModesEncodeOnlyTheirDeclaredProtocolFeature() throws {
        let schemaBody = try jsonObject(
            ChatCompletionsAIConnectionClient.connectionTestBody(
                for: try configuration(mode: .jsonSchema)
            )
        )
        let schemaFormat = try XCTUnwrap(schemaBody["response_format"] as? [String: Any])
        XCTAssertEqual(schemaFormat["type"] as? String, "json_schema")
        XCTAssertNotNil(schemaFormat["json_schema"])

        let objectBody = try jsonObject(
            ChatCompletionsAIConnectionClient.connectionTestBody(
                for: try configuration(mode: .jsonObject)
            )
        )
        XCTAssertEqual(
            (objectBody["response_format"] as? [String: Any])?["type"] as? String,
            "json_object"
        )

        let promptedBody = try jsonObject(
            ChatCompletionsAIConnectionClient.connectionTestBody(
                for: try configuration(mode: .promptedJSON)
            )
        )
        XCTAssertNil(promptedBody["response_format"])
    }

    func testHTTPFailuresMapToStableCategoriesWithoutLeakingBody() async throws {
        let cases: [(Int, [String: String], AIConnectionError)] = [
            (400, [:], .unsupportedConfiguration(statusCode: 400)),
            (401, [:], .authenticationFailed),
            (402, [:], .insufficientBalance),
            (404, [:], .unsupportedConfiguration(statusCode: 404)),
            (422, [:], .unsupportedConfiguration(statusCode: 422)),
            (429, ["Retry-After": "17"], .rateLimited(retryAfterSeconds: 17)),
            (500, [:], .serviceUnavailable(statusCode: 500)),
            (503, [:], .serviceUnavailable(statusCode: 503)),
            (418, [:], .unexpectedStatus(statusCode: 418))
        ]
        let config = try configuration(mode: .jsonObject)
        let secretBody = Data(#"{"error":{"message":"test-only-key https://secret.example"}}"#.utf8)

        for (status, headers, expected) in cases {
            let client = ChatCompletionsAIConnectionClient(
                transport: FixedAIHTTPTransport(
                    response: AIHTTPResponse(statusCode: status, headers: headers, body: secretBody)
                )
            )
            let error = await connectionError(from: client, configuration: config)
            XCTAssertEqual(error, expected)
            XCTAssertFalse(error?.localizedDescription.contains("test-only-key") == true)
            XCTAssertFalse(error?.localizedDescription.contains("secret.example") == true)
        }
    }
}

extension ChatCompletionsAIConnectionClientTests {
    func testTransportErrorsMapTimeoutCancellationOfflineAndTLS() async throws {
        let config = try configuration(mode: .jsonObject)
        let cases: [(URLError.Code, AIConnectionError)] = [
            (.cancelled, .cancelled),
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .networkUnavailable),
            (.networkConnectionLost, .networkUnavailable),
            (.serverCertificateUntrusted, .secureConnectionFailed),
            (.cannotConnectToHost, .connectionFailed)
        ]

        for (code, expected) in cases {
            let client = ChatCompletionsAIConnectionClient(
                transport: FailingAIHTTPTransport(error: URLError(code))
            )
            let error = await connectionError(from: client, configuration: config)
            XCTAssertEqual(error, expected)
        }
    }

    func testRejectsOversizeMalformedEmptyTruncatedAndCapabilityMismatchResponses() async throws {
        let config = try configuration(mode: .jsonObject)
        let cases: [(Data, AIConnectionError)] = [
            (
                Data(
                    repeating: 0x20,
                    count: ChatCompletionsAIConnectionClient.maximumResponseBytes + 1
                ),
                .responseTooLarge
            ),
            (Data("not-json".utf8), .malformedResponse),
            (try JSONSerialization.data(withJSONObject: ["choices": []]), .emptyResponse),
            (completionBody(content: ""), .emptyResponse),
            (
                completionBody(content: #"{"ok":true}"#, finishReason: "length"),
                .truncatedResponse
            ),
            (completionBody(content: "plain text"), .capabilityMismatch),
            (completionBody(content: #"{"ok":false}"#), .capabilityMismatch)
        ]

        for (body, expected) in cases {
            let client = ChatCompletionsAIConnectionClient(
                transport: FixedAIHTTPTransport(
                    response: AIHTTPResponse(statusCode: 200, headers: [:], body: body)
                )
            )
            let error = await connectionError(from: client, configuration: config)
            XCTAssertEqual(error, expected)
        }
    }

    func testRedirectPolicyForwardsAuthorizationOnlyWithinSameHTTPSOrigin() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example:443/v1"))
        )
        original.setValue("Bearer test-only-key", forHTTPHeaderField: "Authorization")

        let sameOrigin = URLRequest(
            url: try XCTUnwrap(URL(string: "https://API.example/redirected"))
        )
        let accepted = SameOriginRedirectDelegate.redirectedRequest(
            originalRequest: original,
            proposedRequest: sameOrigin
        )
        XCTAssertEqual(
            accepted?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-only-key"
        )

        let crossOrigin = URLRequest(
            url: try XCTUnwrap(URL(string: "https://other.example/redirected"))
        )
        XCTAssertNil(SameOriginRedirectDelegate.redirectedRequest(
            originalRequest: original,
            proposedRequest: crossOrigin
        ))

        let downgrade = URLRequest(
            url: try XCTUnwrap(URL(string: "http://api.example/redirected"))
        )
        XCTAssertNil(SameOriginRedirectDelegate.redirectedRequest(
            originalRequest: original,
            proposedRequest: downgrade
        ))
    }
}

private extension ChatCompletionsAIConnectionClientTests {
    func configuration(mode: AIResponseFormatMode) throws -> ResolvedAIConfiguration {
        try AIConfigurationValidator.resolve(
            AIConfigurationDraft(
                isEnabled: true,
                serviceKind: .custom,
                serviceName: "测试服务",
                baseURL: "https://api.example/v1",
                modelID: "test-model",
                responseFormatMode: mode
            ),
            credentialID: UUID()
        )
    }

    func connectionError(
        from client: ChatCompletionsAIConnectionClient,
        configuration: ResolvedAIConfiguration
    ) async -> AIConnectionError? {
        do {
            _ = try await client.testConnection(
                configuration: configuration,
                credential: "test-only-key"
            )
            XCTFail("Expected connection test to fail")
            return nil
        } catch let error as AIConnectionError {
            return error
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
            return nil
        }
    }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
        try jsonObject(try XCTUnwrap(request.httpBody))
    }

    func completionBody(content: String, finishReason: String = "stop") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["content": content],
                "finish_reason": finishReason
            ]]
        ])
    }
}

private actor AIRequestRecorder {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }
}

private struct FixedAIHTTPTransport: AIHTTPTransport {
    let response: AIHTTPResponse
    let recorder: AIRequestRecorder?

    init(response: AIHTTPResponse, recorder: AIRequestRecorder? = nil) {
        self.response = response
        self.recorder = recorder
    }

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        await recorder?.record(request)
        return response
    }
}

private struct FailingAIHTTPTransport: AIHTTPTransport {
    let error: URLError

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        throw error
    }
}
