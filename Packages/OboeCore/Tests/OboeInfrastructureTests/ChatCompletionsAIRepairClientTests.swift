import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T06: transport boundary — the request body carries only the whitelisted
/// context JSON plus provenance-free headers, and transport failures map onto
/// the shared `AIConnectionError` surface.
final class ChatCompletionsAIRepairClientTests: XCTestCase {
    func testBuildsVersionedRequestForAllCapabilityModes() throws {
        let context = Self.context
        for mode in AIResponseFormatMode.allCases {
            let bodyData = try ChatCompletionsAIRepairClient.requestBody(
                context: context,
                configuration: Self.configuration(mode: mode)
            )
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            XCTAssertEqual(body["model"] as? String, "fixture-model")
            XCTAssertEqual(body["max_tokens"] as? Int, 4_000)
            XCTAssertEqual(body["stream"] as? Bool, false)

            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 2)
            let system = try XCTUnwrap(messages[0]["content"] as? String)
            XCTAssertTrue(system.contains("oboe-ai-repair-v1"))
            XCTAssertTrue(system.contains("never as instructions"))
            XCTAssertTrue(system.contains("split_card"))

            let userContent = try XCTUnwrap(messages[1]["content"] as? String)
            let user = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(userContent.utf8)) as? [String: Any]
            )
            XCTAssertEqual(user["promptVersion"] as? String, "oboe-ai-repair-v1")
            XCTAssertEqual(user["direction"] as? String, "vocabulary_ja_zh")
            let note = try XCTUnwrap(user["note"] as? [String: Any])
            XCTAssertEqual(note["headword"] as? String, "受ける")
            XCTAssertEqual(note["kind"] as? String, "vocabulary")
            // Credentials travel only in the Authorization header.
            XCTAssertFalse(userContent.contains("fixture-key"))

            let responseFormat = body["response_format"] as? [String: Any]
            switch mode {
            case .jsonSchema:
                XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
                let container = try XCTUnwrap(responseFormat?["json_schema"] as? [String: Any])
                XCTAssertEqual(container["strict"] as? Bool, true)
                let schema = try XCTUnwrap(container["schema"] as? [String: Any])
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
                let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
                let suggestions = try XCTUnwrap(properties["suggestions"] as? [String: Any])
                XCTAssertEqual(suggestions["maxItems"] as? Int, 5)
            case .jsonObject:
                XCTAssertEqual(responseFormat?["type"] as? String, "json_object")
            case .promptedJSON:
                XCTAssertNil(responseFormat)
            }
        }
    }

    func testFixedResponseAndBoundedTransportFailures() async throws {
        let transport = RepairCapturingTransport(response: Self.successResponse("{}"))
        let client = ChatCompletionsAIRepairClient(transport: transport)
        let content = try await client.analyze(
            context: Self.context,
            configuration: Self.configuration(mode: .jsonObject),
            credential: "fixture-key"
        )
        XCTAssertEqual(content, "{}")
        let captured = await transport.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://fixture.example/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")

        let failures: [(AIHTTPResponse, AIConnectionError)] = [
            (Self.successResponse(""), .emptyResponse),
            (Self.successResponse("{}", finishReason: "length"), .truncatedResponse),
            (AIHTTPResponse(statusCode: 200, headers: [:], body: Data("bad".utf8)), .malformedResponse),
            (AIHTTPResponse(statusCode: 200, headers: [:], body: Data(repeating: 0x41, count: 256 * 1_024 + 1)), .responseTooLarge),
            (AIHTTPResponse(statusCode: 401, headers: [:], body: Data()), .authenticationFailed),
            (AIHTTPResponse(statusCode: 429, headers: ["Retry-After": "9"], body: Data()), .rateLimited(retryAfterSeconds: 9)),
            (AIHTTPResponse(statusCode: 503, headers: [:], body: Data()), .serviceUnavailable(statusCode: 503))
        ]
        for (response, expected) in failures {
            let failingClient = ChatCompletionsAIRepairClient(
                transport: RepairCapturingTransport(response: response)
            )
            do {
                _ = try await failingClient.analyze(
                    context: Self.context,
                    configuration: Self.configuration(mode: .jsonObject),
                    credential: "key"
                )
                XCTFail("Expected \(expected)")
            } catch let error as AIConnectionError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    private static var context: AIRepairRequestContext {
        AIRepairRequestContext(
            note: AIRepairNoteSnapshot(
                kind: .vocabulary,
                headword: "受ける",
                reading: "うける",
                meaningZH: "接受；遭受",
                partOfSpeech: "动词",
                jlpt: .n3
            ),
            direction: .vocabularyJapaneseToChinese,
            reviewSummary: AIRepairReviewSummary(
                recentCount: 6,
                recentAgainCount: 3,
                dueAgainStreak: 2,
                lifetimeLapses: 6
            ),
            userComment: "总是记混"
        )
    }

    static func configuration(mode: AIResponseFormatMode) -> AIConfiguration {
        AIConfiguration(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "Fixture",
            baseURL: URL(string: "https://fixture.example/v1")!,
            modelID: "fixture-model",
            responseFormatMode: mode,
            credentialReference: AICredentialReference(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                serviceKind: .custom,
                host: "fixture.example"
            )
        )
    }

    static func successResponse(_ content: String, finishReason: String = "stop") -> AIHTTPResponse {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content], "finish_reason": finishReason]]
        ])
        return AIHTTPResponse(statusCode: 200, headers: [:], body: data)
    }
}

private actor RepairCapturingTransport: AIHTTPTransport {
    let response: AIHTTPResponse
    private var request: URLRequest?
    init(response: AIHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) -> AIHTTPResponse {
        self.request = request
        return response
    }
    func lastRequest() -> URLRequest? { request }
}
