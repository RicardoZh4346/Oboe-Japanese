import Foundation
import OboeDomain

public struct ChatCompletionsAICardGenerationClient: AICardGenerationClient, Sendable {
    static let maximumResponseBytes = 256 * 1_024
    static let maximumOutputTokens = 1_200

    private let transport: any AIHTTPTransport

    public init() {
        transport = URLSessionAIHTTPTransport(timeout: ChatCompletionsAIConnectionClient.timeout)
    }

    init(transport: any AIHTTPTransport) {
        self.transport = transport
    }

    public func generate(
        input: AICardGenerationInput,
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
        guard let choice = envelope.choices.first else {
            throw AIConnectionError.emptyResponse
        }
        if choice.finishReason == "length" {
            throw AIConnectionError.truncatedResponse
        }
        guard choice.finishReason == "stop" else {
            throw AIConnectionError.malformedResponse
        }
        let content = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIConnectionError.emptyResponse }
        return content
    }

    private func makeRequest(
        input: AICardGenerationInput,
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
        input: AICardGenerationInput,
        configuration: AIConfiguration
    ) throws -> Data {
        let userPayload = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": AICardPromptV2.schemaVersion,
                "kind": input.kind.rawValue,
                "input": input.text,
                "context": input.context
            ],
            options: [.sortedKeys]
        )
        guard let userContent = String(data: userPayload, encoding: .utf8) else {
            throw AICardGenerationError.invalidJSON
        }
        var body: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                [
                    "role": "system",
                    "content": AICardPromptV2.systemInstruction(for: input.kind)
                ],
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
                    "name": "oboe_\(input.kind.rawValue)_card_v2",
                    "strict": true,
                    "schema": outputSchema(for: input.kind)
                ]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptedJSON:
            break
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func outputSchema(for kind: AICardGenerationKind) -> [String: Any] {
        let nullableJLPT: [String: Any] = [
            "anyOf": [
                ["type": "string", "enum": JLPTLevel.allCases.map(\.rawValue)],
                ["type": "null"]
            ]
        ]
        let examples: [String: Any] = [
            "type": "array",
            "maxItems": 1,
            "items": [
                "type": "object",
                "properties": [
                    "japanese": ["type": "string"],
                    "translationZH": ["type": "string"]
                ],
                "required": ["japanese", "translationZH"],
                "additionalProperties": false
            ]
        ]
        let warnings: [String: Any] = [
            "type": "array",
            "maxItems": 5,
            "items": ["type": "string"]
        ]
        var properties: [String: Any] = [
            "schemaVersion": ["type": "integer", "const": AICardPromptV2.schemaVersion],
            "kind": ["type": "string", "const": kind.rawValue],
            "meaningZH": ["type": "string"],
            "jlpt": nullableJLPT,
            "examples": examples,
            "notes": ["type": "string"],
            "warnings": warnings
        ]
        let required: [String]
        switch kind {
        case .vocabulary:
            properties["headword"] = ["type": "string"]
            properties["reading"] = ["type": "string"]
            properties["partsOfSpeech"] = [
                "type": "array",
                "uniqueItems": true,
                "items": [
                    "type": "string",
                    "enum": VocabularyPartOfSpeech.allCases.map(\.rawValue)
                ]
            ]
            properties["pitchAccent"] = [
                "anyOf": [
                    ["type": "integer", "minimum": 0],
                    ["type": "null"]
                ]
            ]
            required = [
                "schemaVersion", "kind", "headword", "reading", "meaningZH",
                "partsOfSpeech", "pitchAccent", "jlpt", "examples", "notes", "warnings"
            ]
        case .grammar:
            properties["grammarForm"] = ["type": "string"]
            properties["usage"] = ["type": "string"]
            properties["connection"] = ["type": "string"]
            required = [
                "schemaVersion", "kind", "grammarForm", "meaningZH", "usage",
                "connection", "jlpt", "examples", "notes", "warnings"
            ]
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }
}
