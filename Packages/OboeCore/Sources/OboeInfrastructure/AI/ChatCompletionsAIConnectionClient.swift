import Foundation
import OboeDomain

/// 连接测试入口。transport/状态码/取消/重定向等共享语义在
/// `AIHTTPTransport.swift` 与 `AIRequestExecutor`；本类型只描述
/// 「让模型返回 {"ok":true}」这一次交换并校验内容。
/// 按 `ResolvedAIConfiguration.serviceKind` 的协议族分发 adapter——
/// 名字里的 ChatCompletions 只是历史命名，Claude 走 Anthropic Messages。
public struct ChatCompletionsAIConnectionClient: AIConnectionClient, Sendable {
    static let timeout: TimeInterval = AIHTTPSupport.executionTimeout
    static let maximumResponseBytes = AIHTTPSupport.defaultMaximumResponseBytes
    static let connectionTestMaximumOutputTokens = 128

    private let executor: AIRequestExecutor

    public init() {
        self.init(transport: URLSessionAIHTTPTransport(timeout: Self.timeout))
    }

    init(transport: any AIHTTPTransport) {
        executor = AIRequestExecutor(
            transport: transport,
            maximumResponseBytes: Self.maximumResponseBytes
        )
    }

    public func testConnection(
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> AIConnectionTestResult {
        let content = try await executor.run(
            Self.exchange(for: configuration),
            configuration: configuration,
            credential: credential
        )
        guard let contentData = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: contentData),
              let dictionary = object as? [String: Any],
              dictionary.count == 1,
              dictionary["ok"] as? Bool == true else {
            throw AIConnectionError.capabilityMismatch
        }

        return AIConnectionTestResult(
            serviceName: configuration.serviceName,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode
        )
    }

    /// 协议无关的连接测试请求描述。
    static func exchange(for configuration: ResolvedAIConfiguration) -> AIMessageExchange {
        AIMessageExchange(
            systemPrompt: "Return only one JSON object with exactly one boolean field named ok.",
            userPrompt: "Return {\"ok\":true}.",
            maximumOutputTokens: connectionTestMaximumOutputTokens,
            outputContract: AIOutputContract(
                mode: configuration.responseFormatMode,
                schemaName: "oboe_connection_test",
                schema: [
                    "type": "object",
                    "properties": ["ok": ["type": "boolean"]],
                    "required": ["ok"],
                    "additionalProperties": false
                ]
            )
        )
    }

    /// OpenAI Chat Completions 线格式的请求体（既有测试/调试入口）。
    static func connectionTestBody(for configuration: ResolvedAIConfiguration) throws -> Data {
        try OpenAIChatCompletionsAdapter().requestBody(
            for: exchange(for: configuration),
            configuration: configuration
        )
    }
}
