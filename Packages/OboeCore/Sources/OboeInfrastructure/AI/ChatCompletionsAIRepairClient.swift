import Foundation
import OboeDomain

/// Chat Completions transport for the repair analysis (设计 §6.1). Sends only
/// the whitelisted request context produced by `AIRepairRequestEncoder` —
/// credentials live in the Authorization header, never in the payload. The
/// raw model output is returned untouched; `AIRepairOutputDecoder` is the
/// only consumer allowed to type it.
///
/// 线协议差异由 adapter 收敛（Anthropic Messages / OpenAI Chat Completions）；
/// 共享的发送、状态码、取消与响应上限语义在 `AIRequestExecutor`。
public struct ChatCompletionsAIRepairClient: AIRepairClient, Sendable {
    static let maximumResponseBytes = AIHTTPSupport.defaultMaximumResponseBytes
    static let maximumOutputTokens = 4_000

    private let executor: AIRequestExecutor

    public init() {
        self.init(transport: URLSessionAIHTTPTransport(timeout: AIHTTPSupport.executionTimeout))
    }

    init(transport: any AIHTTPTransport) {
        executor = AIRequestExecutor(
            transport: transport,
            maximumResponseBytes: Self.maximumResponseBytes
        )
    }

    public func analyze(
        context: AIRepairRequestContext,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        try await executor.run(
            Self.exchange(for: context, configuration: configuration),
            configuration: configuration,
            credential: credential
        )
    }

    /// 协议无关的修卡请求描述：白名单上下文 JSON + v2 提示词契约。
    static func exchange(
        for context: AIRepairRequestContext,
        configuration: ResolvedAIConfiguration
    ) throws -> AIMessageExchange {
        AIMessageExchange(
            systemPrompt: AIRepairPromptV2.systemInstruction(),
            userPrompt: try AIRepairRequestEncoder.encode(context),
            maximumOutputTokens: maximumOutputTokens,
            outputContract: AIOutputContract(
                mode: configuration.responseFormatMode,
                schemaName: "oboe_ai_repair_v2",
                schema: outputSchema()
            )
        )
    }

    /// OpenAI Chat Completions 线格式的请求体（既有测试/调试入口）。
    static func requestBody(
        context: AIRepairRequestContext,
        configuration: ResolvedAIConfiguration
    ) throws -> Data {
        try OpenAIChatCompletionsAdapter().requestBody(
            for: exchange(for: context, configuration: configuration),
            configuration: configuration
        )
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
