import Foundation
import OboeDomain

/// Chat Completions transport for the repair analysis (设计 §6.1). Sends only
/// the whitelisted request context produced by `AIRepairRequestEncoder` —
/// credentials live in the Authorization header, never in the payload. The
/// raw model output is returned untouched; `AIRepairOutputDecoder` is the
/// only consumer allowed to type it.
public struct ChatCompletionsAIRepairClient: AIRepairClient, Sendable {
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
        context: AIRepairRequestContext,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        let request = try makeRequest(
            context: context,
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
        context: AIRepairRequestContext,
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
        request.httpBody = try Self.requestBody(context: context, configuration: configuration)
        return request
    }

    static func requestBody(
        context: AIRepairRequestContext,
        configuration: AIConfiguration
    ) throws -> Data {
        let userContent = try AIRepairRequestEncoder.encode(context)
        var body: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                [
                    "role": "system",
                    "content": AIRepairPromptV2.systemInstruction()
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
                    "name": "oboe_ai_repair_v2",
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

    /// Strict JSON-schema mirror of the v2 response contract — every property
    /// listed is required (optional slots use `anyOf` with null), matching
    /// what `AIRepairOutputDecoder` accepts.
    private static func outputSchema() -> [String: Any] {
        let stringOrNull: [String: Any] = ["anyOf": [["type": "string"], ["type": "null"]]]
        let partsOfSpeech: [String: Any] = [
            "type": "array",
            "uniqueItems": true,
            "items": [
                "type": "string",
                "enum": VocabularyPartOfSpeech.allCases.map(\.rawValue)
            ]
        ]
        let partsOfSpeechOrNull: [String: Any] = [
            "anyOf": [
                [
                    "type": "array",
                    "minItems": 1,
                    "uniqueItems": true,
                    "items": [
                        "type": "string",
                        "enum": VocabularyPartOfSpeech.allCases.map(\.rawValue)
                    ]
                ],
                ["type": "null"]
            ]
        ]
        let pitchAccentOrNull: [String: Any] = [
            "anyOf": [
                ["type": "integer", "minimum": 0],
                ["type": "null"]
            ]
        ]
        let example: [String: Any] = [
            "type": "object",
            "properties": [
                "japanese": ["type": "string"],
                "translationZH": stringOrNull
            ],
            "required": ["japanese", "translationZH"],
            "additionalProperties": false
        ]
        let examples: [String: Any] = [
            "anyOf": [
                ["type": "array", "maxItems": AIRepairOutputDecoder.maximumExamples, "items": example],
                ["type": "null"]
            ]
        ]
        let patchProperties: [String: Any] = [
            "headword": stringOrNull,
            "reading": stringOrNull,
            "meaningZH": stringOrNull,
            "partsOfSpeech": partsOfSpeechOrNull,
            "pitchAccent": pitchAccentOrNull,
            "usage": stringOrNull,
            "connection": stringOrNull,
            "notes": stringOrNull,
            "examples": examples
        ]
        let replacement: [String: Any] = [
            "anyOf": [
                [
                    "type": "object",
                    "properties": patchProperties,
                    "required": Array(patchProperties.keys),
                    "additionalProperties": false
                ],
                ["type": "null"]
            ]
        ]
        let clearFields: [String: Any] = [
            "anyOf": [
                [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "enum": AIRepairClearableField.allCases.map(\.rawValue)
                    ]
                ],
                ["type": "null"]
            ]
        ]
        let candidateProperties: [String: Any] = [
            "kind": [
                "type": "string",
                "enum": [KnowledgePointKind.vocabulary.rawValue, KnowledgePointKind.grammar.rawValue]
            ],
            "headword": ["type": "string"],
            "reading": stringOrNull,
            "meaningZH": ["type": "string"],
            "partsOfSpeech": partsOfSpeech,
            "pitchAccent": pitchAccentOrNull,
            "jlpt": [
                "anyOf": [
                    ["type": "string", "enum": JLPTLevel.allCases.map(\.rawValue)],
                    ["type": "null"]
                ]
            ],
            "usage": stringOrNull,
            "connection": stringOrNull,
            "notes": stringOrNull,
            "examples": examples
        ]
        let splitNotes: [String: Any] = [
            "anyOf": [
                [
                    "type": "array",
                    "maxItems": AIRepairOutputDecoder.maximumSplitNotes,
                    "items": [
                        "type": "object",
                        "properties": candidateProperties,
                        "required": Array(candidateProperties.keys),
                        "additionalProperties": false
                    ]
                ],
                ["type": "null"]
            ]
        ]
        let suggestion: [String: Any] = [
            "type": "object",
            "properties": [
                "type": [
                    "type": "string",
                    "enum": AIRepairSuggestionType.allCases.map(\.rawValue)
                ],
                "title": ["type": "string"],
                "reason": ["type": "string"],
                "replacement": replacement,
                "clearFields": clearFields,
                "splitNotes": splitNotes
            ],
            "required": ["type", "title", "reason", "replacement", "clearFields", "splitNotes"],
            "additionalProperties": false
        ]
        return [
            "type": "object",
            "properties": [
                "schemaVersion": ["type": "integer", "const": AIRepairPromptV2.schemaVersion],
                "problemTypes": [
                    "type": "array",
                    "items": [
                        "type": "string",
                        "enum": AIRepairProblemType.allCases.map(\.rawValue)
                    ]
                ],
                "summary": ["type": "string"],
                "suggestions": [
                    "type": "array",
                    "maxItems": AIRepairOutputDecoder.maximumSuggestions,
                    "items": suggestion
                ]
            ],
            "required": ["schemaVersion", "problemTypes", "summary", "suggestions"],
            "additionalProperties": false
        ]
    }
}
