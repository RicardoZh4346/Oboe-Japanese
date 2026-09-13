import Foundation
import OboeDomain

public struct ChatCompletionsSentenceAnalysisClient: SentenceAnalysisClient, Sendable {
    static let maximumResponseBytes = 256 * 1_024
    static let maximumOutputTokens = 4_000

    private let transport: any AIHTTPTransport

    public init() {
        transport = URLSessionAIHTTPTransport(timeout: ChatCompletionsAIConnectionClient.timeout)
    }

    init(transport: any AIHTTPTransport) {
        self.transport = transport
    }

    public func analyze(
        input: SentenceAnalysisInput,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        let request = try makeRequest(
            input: input,
            configuration: configuration,
            credential: credential
        )
        let response: AIHTTPResponse
        do {
            try Task.checkCancellation()
            response = try await transport.send(request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw AIConnectionError.cancelled
        } catch let error as AIConnectionError {
            throw error
        } catch let error as URLError {
            throw ChatCompletionsAIConnectionClient.map(error)
        } catch {
            throw AIConnectionError.connectionFailed
        }

        try ChatCompletionsAIConnectionClient.validateStatus(response)
        guard response.body.count <= Self.maximumResponseBytes else {
            throw AIConnectionError.responseTooLarge
        }
        let envelope: ChatCompletionEnvelope
        do {
            envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: response.body)
        } catch {
            throw AIConnectionError.malformedResponse
        }
        guard let choice = envelope.choices.first else { throw AIConnectionError.emptyResponse }
        if choice.finishReason == "length" { throw AIConnectionError.truncatedResponse }
        guard choice.finishReason == "stop" else { throw AIConnectionError.malformedResponse }
        let content = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIConnectionError.emptyResponse }
        return content
    }

    private func makeRequest(
        input: SentenceAnalysisInput,
        configuration: AIConfiguration,
        credential: String
    ) throws -> URLRequest {
        guard !credential.isEmpty,
              credential.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIConnectionError.invalidCredential
        }
        var request = URLRequest(
            url: ChatCompletionsAIConnectionClient.chatCompletionsEndpoint(
                baseURL: configuration.baseURL
            ),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: ChatCompletionsAIConnectionClient.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.requestBody(input: input, configuration: configuration)
        return request
    }

    static func requestBody(
        input: SentenceAnalysisInput,
        configuration: AIConfiguration
    ) throws -> Data {
        let userPayload = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": SentenceAnalysisPromptV1.schemaVersion,
                "sentence": input.sentence
            ],
            options: [.sortedKeys]
        )
        guard let userContent = String(data: userPayload, encoding: .utf8) else {
            throw SentenceAnalysisError.invalidJSON
        }
        var body: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": SentenceAnalysisPromptV1.systemInstruction],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": maximumOutputTokens,
            "stream": false
        ]
        switch configuration.responseFormatMode {
        case .jsonSchema:
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "oboe_sentence_analysis_v1",
                    "strict": true,
                    "schema": outputSchema()
                ]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptedJSON:
            break
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func outputSchema() -> [String: Any] {
        let span: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "occurrence": ["type": "integer", "minimum": 1, "maximum": 100]
            ],
            "required": ["text", "occurrence"],
            "additionalProperties": false
        ]
        let card: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": [AICardGenerationKind.vocabulary.rawValue, AICardGenerationKind.grammar.rawValue]
                ],
                "headword": ["type": "string"],
                "reading": ["type": "string"],
                "meaningZH": ["type": "string"],
                "partOfSpeech": ["type": "string"],
                "usage": ["type": "string"],
                "connection": ["type": "string"],
                "notes": ["type": "string"]
            ],
            "required": [
                "kind", "headword", "reading", "meaningZH", "partOfSpeech", "usage",
                "connection", "notes"
            ],
            "additionalProperties": false
        ]
        let item: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": SentenceAnalysisItemKind.allCases.map(\.rawValue)],
                "surface": ["type": "string"],
                "canonicalForm": ["type": "string"],
                "reading": ["type": "string"],
                "meaningZH": ["type": "string"],
                "roleZH": ["type": "string"],
                "spans": ["type": "array", "maxItems": 8, "items": span],
                "cardDraft": ["anyOf": [card, ["type": "null"]]]
            ],
            "required": [
                "kind", "surface", "canonicalForm", "reading", "meaningZH", "roleZH",
                "spans", "cardDraft"
            ],
            "additionalProperties": false
        ]
        return [
            "type": "object",
            "properties": [
                "schemaVersion": ["type": "integer", "const": SentenceAnalysisPromptV1.schemaVersion],
                "sentence": ["type": "string"],
                "translationZH": ["type": "string"],
                "explanationZH": ["type": "string"],
                "items": ["type": "array", "maxItems": 30, "items": item],
                "warnings": ["type": "array", "maxItems": 5, "items": ["type": "string"]]
            ],
            "required": [
                "schemaVersion", "sentence", "translationZH", "explanationZH", "items", "warnings"
            ],
            "additionalProperties": false
        ]
    }
}
