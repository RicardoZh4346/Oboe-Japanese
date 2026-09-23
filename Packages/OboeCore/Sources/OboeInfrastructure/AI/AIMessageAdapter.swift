import Foundation
import OboeDomain

// MARK: - 协议无关的请求描述

/// 期望的结构化输出能力，取自 `ResolvedAIConfiguration.responseFormatMode`。
/// 是否/如何落到线上由 adapter 决定——Anthropic Messages 不支持
/// `response_format`，一律不发送，只靠提示词 + 严格 decoder 保证契约。
enum AIOutputContract {
    /// 仅在提示词中要求返回 JSON。
    case promptedJSON
    /// `response_format: {"type": "json_object"}`。
    case jsonObject
    /// `response_format: {"type": "json_schema", ...}`。
    case jsonSchema(name: String, schema: [String: Any])

    /// 由持久化的响应格式模式生成契约。`.jsonSchema` 模式必须携带契约名与
    /// schema——各业务流的 schema 是内置常量，正常路径不可能缺失。
    init(mode: AIResponseFormatMode, schemaName: String, schema: [String: Any]) {
        switch mode {
        case .jsonSchema:
            self = .jsonSchema(name: schemaName, schema: schema)
        case .jsonObject:
            self = .jsonObject
        case .promptedJSON:
            self = .promptedJSON
        }
    }
}

/// 与线协议无关的一次 AI 请求：系统提示 + 用户文本 → 纯文本（JSON）输出。
/// 业务层只负责把领域输入翻译成这一结构；vendor 差异全部收敛到 adapter。
struct AIMessageExchange {
    var systemPrompt: String
    var userPrompt: String
    var maximumOutputTokens: Int
    var outputContract: AIOutputContract
}

// MARK: - Adapter 协议与共享请求构造

/// 一种 AI 线协议：端点、协议头、请求体编码与响应正文解码。
/// 实现都是无状态值类型；凭据只出现在 HTTP 头中，绝不进入 body。
protocol AIMessageAdapter: Sendable {
    /// 执行端点 URL（在 `configuration.baseURL` 基础上定位）。
    func endpointURL(for configuration: ResolvedAIConfiguration) throws -> URL
    /// 写入协议要求的鉴权/版本头；Content-Type/Accept 由共享层统一处理。
    func applyProtocolHeaders(to request: inout URLRequest, credential: String)
    /// 把交换编码为协议请求体。
    func requestBody(
        for exchange: AIMessageExchange,
        configuration: ResolvedAIConfiguration
    ) throws -> Data
    /// 把响应体解码为模型文本；统一映射到 `AIConnectionError`
    /// （emptyResponse / truncatedResponse / malformedResponse）。
    func content(fromResponseBody body: Data) throws -> String
}

extension AIMessageAdapter {
    /// 共享请求构造：credential 校验 → POST + JSON 头 + 统一超时 →
    /// 协议头 → body。所有 adapter 复用，保证鉴权与缓存策略一致。
    func makeRequest(
        for exchange: AIMessageExchange,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) throws -> URLRequest {
        guard !credential.isEmpty,
              credential.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIConnectionError.invalidCredential
        }
        var request = URLRequest(
            url: try endpointURL(for: configuration),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: AIHTTPSupport.executionTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyProtocolHeaders(to: &request, credential: credential)
        request.httpBody = try requestBody(for: exchange, configuration: configuration)
        return request
    }

    /// 把 `path` 拼到 baseURL 之后；baseURL 已以该路径结尾时原样返回
    /// （自定义服务允许用户直接粘贴完整端点地址）。
    func appendingEndpointPath(_ path: String, to baseURL: URL) throws -> URL {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return baseURL }
        if baseURL.path.lowercased().hasSuffix("/\(normalizedPath.lowercased())") {
            return baseURL
        }
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw AIConnectionError.malformedResponse
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/" + normalizedPath
        guard let url = components.url else {
            throw AIConnectionError.malformedResponse
        }
        return url
    }
}

// MARK: - OpenAI Chat Completions

/// OpenAI 兼容协议：`{base}/chat/completions`，`Authorization: Bearer`，
/// `messages` 数组内嵌 system；`.jsonSchema`/`.jsonObject` 落到
/// `response_format`。DashScope 走官方兼容模式时传入不同的路径。
struct OpenAIChatCompletionsAdapter: AIMessageAdapter {
    /// chat completions 相对 baseURL 的路径。DashScope 兼容模式为
    /// `compatible-mode/v1/chat/completions`。
    let chatCompletionsPath: String

    init(chatCompletionsPath: String = "chat/completions") {
        self.chatCompletionsPath = chatCompletionsPath
    }

    func endpointURL(for configuration: ResolvedAIConfiguration) throws -> URL {
        try appendingEndpointPath(chatCompletionsPath, to: configuration.baseURL)
    }

    func applyProtocolHeaders(to request: inout URLRequest, credential: String) {
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    }

    func requestBody(
        for exchange: AIMessageExchange,
        configuration: ResolvedAIConfiguration
    ) throws -> Data {
        var body: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": exchange.systemPrompt],
                ["role": "user", "content": exchange.userPrompt]
            ],
            "max_tokens": exchange.maximumOutputTokens,
            "stream": false
        ]
        switch exchange.outputContract {
        case .jsonSchema(let name, let schema):
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": name,
                    "strict": true,
                    "schema": schema
                ]
            ]
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptedJSON:
            break
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func content(fromResponseBody body: Data) throws -> String {
        let envelope: ChatCompletionEnvelope
        do {
            envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: body)
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
}

struct ChatCompletionEnvelope: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
        let finishReason: String

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Decodable {
        let content: String
    }
}

// MARK: - Anthropic Messages

/// Anthropic Messages 协议：`{base}/v1/messages`，`x-api-key` +
/// `anthropic-version` 头；system 是顶层字段不进 `messages`，用户文本包装为
/// `content: [{type: "text", ...}]`。协议不支持 `response_format`，
/// `outputContract` 一律忽略——JSON 契约靠提示词与严格 decoder 保证。
struct AnthropicMessagesAdapter: AIMessageAdapter {
    static let anthropicVersion = "2023-06-01"

    func endpointURL(for configuration: ResolvedAIConfiguration) throws -> URL {
        try appendingEndpointPath("v1/messages", to: configuration.baseURL)
    }

    func applyProtocolHeaders(to request: inout URLRequest, credential: String) {
        request.setValue(credential, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
    }

    func requestBody(
        for exchange: AIMessageExchange,
        configuration: ResolvedAIConfiguration
    ) throws -> Data {
        let body: [String: Any] = [
            "model": configuration.modelID,
            "max_tokens": exchange.maximumOutputTokens,
            "system": exchange.systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [["type": "text", "text": exchange.userPrompt]]
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func content(fromResponseBody body: Data) throws -> String {
        let envelope: AnthropicMessagesEnvelope
        do {
            envelope = try JSONDecoder().decode(AnthropicMessagesEnvelope.self, from: body)
        } catch {
            throw AIConnectionError.malformedResponse
        }
        // max_tokens → 截断；其余非 end_turn 的 stop_reason
        // （stop_sequence/tool_use/refusal/缺失）对本契约都是非法收尾。
        if envelope.stopReason == "max_tokens" {
            throw AIConnectionError.truncatedResponse
        }
        guard envelope.stopReason == "end_turn" else {
            throw AIConnectionError.malformedResponse
        }
        guard !envelope.content.isEmpty else {
            throw AIConnectionError.emptyResponse
        }
        let texts = envelope.content.compactMap { block -> String? in
            block.type == "text" ? block.text : nil
        }
        guard texts.count == envelope.content.count else {
            // 出现非文本 block（tool_use/thinking 等）——契约之外。
            throw AIConnectionError.malformedResponse
        }
        let content = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIConnectionError.emptyResponse }
        return content
    }
}

struct AnthropicMessagesEnvelope: Decodable {
    let content: [ContentBlock]
    let stopReason: String?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

// MARK: - Gemini generateContent

/// Google Gemini 原生协议：
/// `POST {base}/v1beta/models/{model}:generateContent`，`x-goog-api-key`
/// 头鉴权；system 提示词走顶层 `systemInstruction`，用户文本为
/// `contents[].parts[]`。首版不发送 `responseSchema`/`responseMimeType`
/// 等结构化输出字段——JSON 契约与 Anthropic 一样靠提示词 + 严格
/// decoder 保证，不虚构供应商能力。
struct GeminiGenerateContentAdapter: AIMessageAdapter {
    func endpointURL(for configuration: ResolvedAIConfiguration) throws -> URL {
        let encodedModel = try Self.pathSegment(forModelID: configuration.modelID)
        // 静态前缀复用共享拼接（处理尾斜杠与 baseURL 已含该路径的情形）；
        // 模型段已 percent-encode，必须经 percentEncodedPath 追加——
        // 走 path setter 会把 % 二次编码。
        let modelsBase = try appendingEndpointPath(
            "v1beta/models",
            to: configuration.baseURL
        )
        guard var components = URLComponents(
            url: modelsBase,
            resolvingAgainstBaseURL: false
        ) else {
            throw AIConnectionError.malformedResponse
        }
        components.percentEncodedPath += "/\(encodedModel):generateContent"
        guard let url = components.url else {
            throw AIConnectionError.malformedResponse
        }
        return url
    }

    /// 模型 ID 编码为单个路径段。`/` 直接拒绝——`models/x` 这类残留
    /// 形式绝不能被当成路径分隔符注入；其余非路径段字符（空格等）
    /// percent-encode。空 ID 或编码失败一律 fail-fast，不发畸形请求。
    static func pathSegment(forModelID modelID: String) throws -> String {
        guard !modelID.isEmpty, !modelID.contains("/") else {
            throw AIConnectionError.unsupportedConfiguration(statusCode: 0)
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = modelID.addingPercentEncoding(
            withAllowedCharacters: allowed
        ), !encoded.isEmpty else {
            throw AIConnectionError.unsupportedConfiguration(statusCode: 0)
        }
        return encoded
    }

    func applyProtocolHeaders(to request: inout URLRequest, credential: String) {
        request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
    }

    func requestBody(
        for exchange: AIMessageExchange,
        configuration: ResolvedAIConfiguration
    ) throws -> Data {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": exchange.systemPrompt]]],
            "contents": [
                ["role": "user", "parts": [["text": exchange.userPrompt]]]
            ],
            "generationConfig": [
                "maxOutputTokens": exchange.maximumOutputTokens
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    func content(fromResponseBody body: Data) throws -> String {
        let envelope: GeminiGenerateContentEnvelope
        do {
            envelope = try JSONDecoder().decode(
                GeminiGenerateContentEnvelope.self,
                from: body
            )
        } catch {
            throw AIConnectionError.malformedResponse
        }
        // candidates 缺失或为空（含 promptFeedback 拦截的情形）→ 空响应。
        guard let candidate = envelope.candidates?.first else {
            throw AIConnectionError.emptyResponse
        }
        // MAX_TOKENS → 截断；其余非 STOP 的 finishReason
        // （SAFETY/RECITATION/OTHER 等）对本契约都是非法收尾。
        // finishReason 缺失同样视为非法：非流式响应中完成态 candidate
        // 必带该字段，与 Anthropic adapter 的严格语义保持一致。
        if candidate.finishReason == "MAX_TOKENS" {
            throw AIConnectionError.truncatedResponse
        }
        guard candidate.finishReason == "STOP" else {
            throw AIConnectionError.malformedResponse
        }
        let parts = candidate.content?.parts ?? []
        guard parts.allSatisfy({ $0.text != nil }) else {
            // 非文本 part（functionCall/inlineData 等）——契约之外。
            throw AIConnectionError.malformedResponse
        }
        let content = parts.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw AIConnectionError.emptyResponse }
        return content
    }
}

struct GeminiGenerateContentEnvelope: Decodable {
    let candidates: [Candidate]?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
    }

    struct Content: Decodable {
        let parts: [Part]?
    }

    struct Part: Decodable {
        let text: String?
    }
}

// MARK: - 分发

/// 按配置的协议族分发执行 adapter。
/// - `.openAICompatible` 与 `.xAI`：OpenAI Chat Completions 线格式
///   （xAI 的 `…/v1/chat/completions` 即 OpenAI 兼容端点）。
/// - `.dashScope`：阿里官方 OpenAI 兼容模式
///   （`{base}/compatible-mode/v1/chat/completions`）。
/// - `.anthropic`：Anthropic Messages。
/// - `.gemini`：Google 原生 `generateContent`
///   （`x-goog-api-key` 鉴权，模型 ID 在 URL 路径中）。
enum AIMessageAdapterRegistry {
    static func adapter(
        for configuration: ResolvedAIConfiguration
    ) throws -> any AIMessageAdapter {
        switch protocolKind(for: configuration) {
        case .openAICompatible, .xAI:
            return OpenAIChatCompletionsAdapter()
        case .dashScope:
            return OpenAIChatCompletionsAdapter(
                chatCompletionsPath: "compatible-mode/v1/chat/completions"
            )
        case .anthropic:
            return AnthropicMessagesAdapter()
        case .gemini:
            return GeminiGenerateContentAdapter()
        }
    }

    /// 执行协议族：预设供应商以注册表为准；自定义服务一律按 OpenAI 兼容处理。
    static func protocolKind(
        for configuration: ResolvedAIConfiguration
    ) -> AIProtocolKind {
        AIProviderPresetRegistry.preset(for: configuration.serviceKind)?.protocolKind
            ?? .openAICompatible
    }
}

// MARK: - 共享请求管线

/// 所有 AI 执行入口共享的请求管线：adapter 分发 → 请求构造 → 发送
/// （取消映射）→ 状态码校验 → 响应大小上限 → adapter 解码正文为文本。
/// 业务层只负责把领域输入翻译成 `AIMessageExchange`。
struct AIRequestExecutor: Sendable {
    let transport: any AIHTTPTransport
    let maximumResponseBytes: Int

    init(
        transport: any AIHTTPTransport,
        maximumResponseBytes: Int = AIHTTPSupport.defaultMaximumResponseBytes
    ) {
        self.transport = transport
        self.maximumResponseBytes = maximumResponseBytes
    }

    func run(
        _ exchange: AIMessageExchange,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> String {
        // 能力 fail-fast：供应商不支持生成、或当前输出模式不在其能力集内时
        // 不发请求直接拒绝。custom 取 OpenAI 兼容默认能力，不会被误拦。
        let capabilities = AIProviderPresetRegistry.capabilities(
            for: configuration.serviceKind
        )
        guard capabilities.supportsGeneration,
              capabilities.supportedOutputModes.contains(
                  configuration.responseFormatMode
              )
        else {
            throw AIConnectionError.capabilityMismatch
        }
        let adapter = try AIMessageAdapterRegistry.adapter(for: configuration)
        let request = try adapter.makeRequest(
            for: exchange,
            configuration: configuration,
            credential: credential
        )
        let response = try await send(request)
        try AIHTTPSupport.validateStatus(response)
        guard response.body.count <= maximumResponseBytes else {
            throw AIConnectionError.responseTooLarge
        }
        return try adapter.content(fromResponseBody: response.body)
    }

    /// 发送请求并把取消/URLError 统一映射到 `AIConnectionError`；
    /// transport 主动抛出的 `AIConnectionError`（如同源重定向拒绝）原样透传。
    private func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw AIConnectionError.cancelled
        } catch let error as AIConnectionError {
            throw error
        } catch let error as URLError {
            throw AIHTTPSupport.map(error)
        } catch {
            throw AIConnectionError.connectionFailed
        }
    }
}
