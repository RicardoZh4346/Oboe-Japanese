import Foundation
import OboeDomain

/// 句子分析入口。共享管线（adapter 分发、发送、状态码、响应上限、取消）
/// 在 `AIRequestExecutor`；本类型只负责把输入翻译成 `AIMessageExchange`，
/// 原始模型文本交给 `SentenceAnalysisDecoder`。
public struct ChatCompletionsSentenceAnalysisClient: SentenceAnalysisClient, Sendable {
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
        input: SentenceAnalysisInput,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        try await executor.run(
            Self.exchange(for: input, configuration: configuration),
            configuration: configuration,
            credential: credential
        )
    }

    /// 协议无关的句子分析请求描述。
    static func exchange(
        for input: SentenceAnalysisInput,
        configuration: ResolvedAIConfiguration
    ) throws -> AIMessageExchange {
        let userPayload = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": SentenceAnalysisPromptV2.schemaVersion,
                "sentence": input.sentence
            ],
            options: [.sortedKeys]
        )
        guard let userContent = String(data: userPayload, encoding: .utf8) else {
            throw SentenceAnalysisError.invalidJSON
        }
        return AIMessageExchange(
            systemPrompt: SentenceAnalysisPromptV2.systemInstruction,
            userPrompt: userContent,
            maximumOutputTokens: maximumOutputTokens,
            outputContract: AIOutputContract(
                mode: configuration.responseFormatMode,
                schemaName: "oboe_sentence_analysis_v2",
                schema: outputSchema()
            )
        )
    }

    /// OpenAI Chat Completions 线格式的请求体（既有测试/调试入口）。
    static func requestBody(
        input: SentenceAnalysisInput,
        configuration: ResolvedAIConfiguration
    ) throws -> Data {
        try OpenAIChatCompletionsAdapter().requestBody(
            for: exchange(for: input, configuration: configuration),
            configuration: configuration
        )
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
                "partsOfSpeech": [
                    "type": "array",
                    "uniqueItems": true,
                    "items": [
                        "type": "string",
                        "enum": VocabularyPartOfSpeech.allCases.map(\.rawValue)
                    ]
                ],
                "pitchAccent": [
                    "anyOf": [
                        ["type": "integer", "minimum": 0],
                        ["type": "null"]
                    ]
                ],
                "usage": ["type": "string"],
                "connection": ["type": "string"],
                "notes": ["type": "string"]
            ],
            "required": [
                "kind", "headword", "reading", "meaningZH", "partsOfSpeech", "pitchAccent",
                "usage", "connection", "notes"
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
                "schemaVersion": ["type": "integer", "const": SentenceAnalysisPromptV2.schemaVersion],
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
