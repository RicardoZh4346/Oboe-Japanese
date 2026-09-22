import Foundation
import OboeDomain

/// AI 制卡入口。共享管线（adapter 分发、发送、状态码、响应上限、取消）
/// 在 `AIRequestExecutor`；本类型只负责把制卡输入翻译成
/// `AIMessageExchange`，原始模型文本原样返回给 `AICardOutputDecoder`。
public struct ChatCompletionsAICardGenerationClient: AICardGenerationClient, Sendable {
    static let maximumResponseBytes = AIHTTPSupport.defaultMaximumResponseBytes
    static let maximumOutputTokens = 1_200

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

    public func generate(
        input: AICardGenerationInput,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        try await executor.run(
            Self.exchange(for: input, configuration: configuration),
            configuration: configuration,
            credential: credential
        )
    }

    /// 协议无关的制卡请求描述：schemaVersioned 用户负载 + v2 提示词契约。
    static func exchange(
        for input: AICardGenerationInput,
        configuration: ResolvedAIConfiguration
    ) throws -> AIMessageExchange {
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
        return AIMessageExchange(
            systemPrompt: AICardPromptV2.systemInstruction(for: input.kind),
            userPrompt: userContent,
            maximumOutputTokens: maximumOutputTokens,
            outputContract: AIOutputContract(
                mode: configuration.responseFormatMode,
                schemaName: "oboe_\(input.kind.rawValue)_card_v2",
                schema: outputSchema(for: input.kind)
            )
        )
    }

    /// OpenAI Chat Completions 线格式的请求体（既有测试/调试入口）。
    static func requestBody(
        input: AICardGenerationInput,
        configuration: ResolvedAIConfiguration
    ) throws -> Data {
        try OpenAIChatCompletionsAdapter().requestBody(
            for: exchange(for: input, configuration: configuration),
            configuration: configuration
        )
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
