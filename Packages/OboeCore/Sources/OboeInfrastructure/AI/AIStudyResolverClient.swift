import Foundation
import OboeDomain

/// v0.7.5 S10：AI Resolver client 错误分类。
/// 依据：技术文档 §9.2（401/403/402 停派、429 Retry-After 优先、
/// timeout/5xx 有限重试、取消传播）与 §7（截断/malformed 不猜半截、
/// 跨源重定向沿用现有分类）。
///
/// 错误对象只携带分类与码位——不含响应正文、不含凭据、不含
/// 可能带秘密的完整 URL（endpoint 指纹已规范化、无凭据无 query）。
public enum AIStudyResolverError: Error, Equatable, Sendable {
    /// 取消（§9.2：停止派发、cancel 网络 Task）。
    case cancelled
    /// 401/403/402 及本地凭据缺失/非法——**停止本 Job 新请求**的信号；
    /// 修复 Key/余额前重试无意义。
    case authFailed
    /// 429。`retryAfter` 为建议等待秒数（支持 Retry-After 秒数与
    /// HTTP-date 两种形态；服务端未给出时为 nil，由调用方做
    /// full-jitter 退避，§9.2 建议 2s 起、上限 60s）。
    case rateLimited(retryAfter: TimeInterval?)
    /// 可重试故障：timeout、5xx、网络不可用、连接/TLS 失败、
    /// 空/截断/非法响应、响应超限、未预期状态码。
    /// 关联值保留底层 `AIConnectionError` 供诊断计数。
    case retryable(AIConnectionError)
    /// 能力/配置不符——发请求前 fail-fast；消息为可操作提示
    /// （换输出模式、换模型、重新分析、检查 Base URL）。
    case unsupportedConfiguration(String)
    /// 跨源/降级重定向被拒——沿用现有 `AIConnectionError
    /// .redirectRejected` 分类语义（保护凭据不外泄）。
    case redirectRejected
}

extension AIStudyResolverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "AI 学习分析请求已取消。"
        case .authFailed:
            "API Key 无效、没有访问权限或余额不足；本批次已停止发送新请求，请检查服务配置。"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "请求过于频繁，请在 \(Int(retryAfter)) 秒后重试。"
            } else {
                "请求过于频繁，请稍后重试。"
            }
        case let .retryable(underlying):
            underlying.errorDescription
                ?? "AI 服务暂时不可用，请稍后重试。"
        case let .unsupportedConfiguration(reason):
            reason
        case .redirectRejected:
            "服务尝试跳转到其他地址，已为保护 API Key 停止请求。"
        }
    }
}

/// 一次成功 resolve 的返回：`ValidatedBlockOutcome` + 快照/诊断。
/// `requestHash` 与 `request.requestHash` 恒等——再导出一次便于
/// 调用方不再回查请求对象。
public struct AIStudyResolverResult: Equatable, Sendable {
    /// validator 输出的块级结果（lexical/translation 双子状态 +
    /// resolutions + 全部诊断计数——§3.3/§7）。
    public let outcome: ValidatedBlockOutcome
    /// §4.4 请求哈希（缓存/幂等键）。
    public let requestHash: String
    /// 本请求 opaque ID（响应按它精确匹配过）。
    public let requestID: String
    /// 发送方快照——全部取自**请求元数据**而非模型自报（§7：
    /// Provider/model/promptVersion 使用请求元数据，不接受自报覆盖）。
    public let providerKind: String
    public let model: String
    public let promptVersion: String
    /// 实际使用的输出模式（配置快照）。
    public let responseMode: AIResponseFormatMode
    /// 服务端随响应给出的重试建议（Retry-After；正常 2xx 一般无）。
    public let suggestedRetryAfter: TimeInterval?
    /// 解码后模型文本字节数（诊断用——不含正文本身）。
    public let responseBytes: Int

    public init(
        outcome: ValidatedBlockOutcome,
        requestHash: String,
        requestID: String,
        providerKind: String,
        model: String,
        promptVersion: String,
        responseMode: AIResponseFormatMode,
        suggestedRetryAfter: TimeInterval?,
        responseBytes: Int
    ) {
        self.outcome = outcome
        self.requestHash = requestHash
        self.requestID = requestID
        self.providerKind = providerKind
        self.model = model
        self.promptVersion = promptVersion
        self.responseMode = responseMode
        self.suggestedRetryAfter = suggestedRetryAfter
        self.responseBytes = responseBytes
    }
}

/// v0.7.5 S10：AI Resolver client。
/// 管线：`AIStudyRequest` → `AIStudyRequestSerializer.serializedRequest`
/// payload → `AIStudyPrompt` 模板 → `AIMessageExchange` → 现有
/// `AIRequestExecutor`/adapter 发请求 → 模型文本 →
/// `AIStudyResponseValidator.validate` → `ValidatedBlockOutcome`。
///
/// # 关键语义
///
/// - **走现有共享管线**：adapter 分发、鉴权头、60s 超时、状态码映射、
///   同源重定向守门、取消映射全部复用 `AIRequestExecutor`/adapter，
///   不复制实现。transport 外叠一层 probe（同 `AIHTTPTransport` 协议）
///   只为读取 Retry-After 等响应头——executor 只回传正文文本，而
///   §9.2 要求 HTTP-date 形态 Retry-After 支持，probe 是零共享层改动
///   的最小取头方式。
/// - **fail-fast**：发请求前先验能力（`AIProviderCapabilities`：
///   supportsGeneration + responseMode ∈ supportedOutputModes——
///   Anthropic/Gemini 的 promptedJSON 路径同样过 validator，本地校验
///   不省略），再验请求元数据 ↔ 当前配置一致性（model/responseMode/
///   providerKind/endpointFingerprint/promptVersion）——任一不符说明
///   requestHash 已不描述真实发送方，直接 `unsupportedConfiguration`
///   拒发，不发「缓存键说谎」的请求。
/// - **零 Key 接触**：不读不写 Keychain、不存凭据；credential 仅作
///   参数透传给现有管线（仅存于 Authorization 等协议头）。本类型
///   不打日志；错误只携带分类码位，不含正文/Key/带秘密 URL。
public struct AIStudyResolverClient: Sendable {
    /// 输出 token 上限：40 occurrence × words 项 + 译文，沿用句析档。
    static let maximumOutputTokens = 4_000
    static let maximumResponseBytes = AIHTTPSupport.defaultMaximumResponseBytes

    private let executor: AIRequestExecutor
    /// executor 内部使用的 transport 外层探针——只为拿响应头。
    private let probe: AIStudyTransportProbe
    /// Retry-After HTTP-date 求差的时钟（测试可注入固定值）。
    private let now: @Sendable () -> Date

    public init() {
        self.init(
            transport: URLSessionAIHTTPTransport(
                timeout: AIHTTPSupport.executionTimeout))
    }

    /// 测试/复用注入点：与既有四个 client 相同的 transport 注入惯例；
    /// `now` 供 Retry-After HTTP-date 解析的确定性测试。
    init(
        transport: any AIHTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let probe = AIStudyTransportProbe(inner: transport)
        self.probe = probe
        self.executor = AIRequestExecutor(
            transport: probe,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        self.now = now
    }

    // MARK: - 公开入口

    /// 默认渲染 `AIStudyPrompt`（版本常量与元数据一致时直通）。
    public func resolve(
        _ request: AIStudyRequest,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> AIStudyResolverResult {
        try await resolve(
            request,
            prompt: AIStudyPrompt.render(for: request),
            configuration: configuration,
            credential: credential
        )
    }

    /// 主入口：请求 + 提示词包 + 连接配置 → 校验后的块级结果。
    /// `prompt` 允许注入自定义渲染（A/B、回归 fixture）；其
    /// `promptVersion` 仍必须与请求元数据一致，否则 requestHash
    /// 不描述真实 prompt——fail-fast 拒发。
    public func resolve(
        _ request: AIStudyRequest,
        prompt: AIStudyPrompt.Messages,
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> AIStudyResolverResult {
        try Self.preflight(
            request: request, prompt: prompt, configuration: configuration)

        let content: String
        do {
            content = try await executor.run(
                Self.exchange(
                    for: request, prompt: prompt,
                    configuration: configuration),
                configuration: configuration,
                credential: credential
            )
        } catch {
            let mapped = await classify(error)
            throw mapped
        }

        // Anthropic/Gemini promptedJSON 与 OpenAI 严格模式同路——
        // 一切 Provider 响应都过同一个本地 validator（§7：不因模式名
        // 含 structured 就省略本地验证）。
        let outcome = AIStudyResponseValidator.validate(
            responseData: Data(content.utf8),
            request: request
        )
        let headers = await probe.lastResponse?.headers ?? [:]
        return AIStudyResolverResult(
            outcome: outcome,
            requestHash: request.requestHash,
            requestID: request.requestID,
            providerKind: request.metadata.providerKind,
            model: request.metadata.model,
            promptVersion: request.metadata.promptVersion,
            responseMode: configuration.responseFormatMode,
            suggestedRetryAfter: Self.retryAfterInterval(
                headers: headers, now: now()),
            responseBytes: content.utf8.count
        )
    }

    // MARK: - preflight（fail-fast：能力 + 元数据一致性）

    /// 发请求前的全部确定性检查；任一失败都是
    /// `unsupportedConfiguration` 且**不会发出任何请求**。
    static func preflight(
        request: AIStudyRequest,
        prompt: AIStudyPrompt.Messages,
        configuration: ResolvedAIConfiguration
    ) throws {
        // 1) 供应商能力：与 executor 内建检查同源、提前到客户端层，
        //    产出 study 语境的可操作提示。
        let capabilities = AIProviderPresetRegistry.capabilities(
            for: configuration.serviceKind)
        guard capabilities.supportsGeneration else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "当前服务（\(configuration.serviceKind.displayName)）不提供文本生成能力，请在设置中更换供应商。")
        }
        guard capabilities.supportedOutputModes.contains(
            configuration.responseFormatMode
        ) else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "当前服务协议不支持 \(configuration.responseFormatMode.displayName) 输出；请在设置中改用受支持的输出格式或更换供应商。")
        }
        // 2) 请求元数据 ↔ 当前配置一致性：requestHash 覆盖的字段必须
        //    如实描述真实发送方，否则结果会落进错误的缓存键。
        guard request.metadata.model == configuration.modelID else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "请求规划时的模型（\(request.metadata.model)）与当前配置（\(configuration.modelID)）不一致；请用当前配置重新分析。")
        }
        guard request.metadata.responseMode
                == configuration.responseFormatMode.rawValue else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "请求规划时的输出格式（\(request.metadata.responseMode)）与当前配置不一致；请重新分析。")
        }
        let protocolKind = AIMessageAdapterRegistry.protocolKind(
            for: configuration)
        guard request.metadata.providerKind == configuration.serviceKind.rawValue
                || request.metadata.providerKind == protocolKind.rawValue else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "请求规划时的供应商（\(request.metadata.providerKind)）与当前配置（\(configuration.serviceKind.rawValue)）不一致；请重新分析。")
        }
        guard AIStudyEndpointFingerprint.normalize(
                configuration.baseURL.absoluteString)
                == request.metadata.endpointFingerprint else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "请求规划时的服务地址与当前配置不一致；请检查 Base URL 或重新分析。")
        }
        guard prompt.promptVersion == request.metadata.promptVersion else {
            throw AIStudyResolverError.unsupportedConfiguration(
                "提示词版本（\(prompt.promptVersion)）与请求元数据（\(request.metadata.promptVersion)）不一致；请重新分析。")
        }
    }

    // MARK: - exchange 构造

    /// 协议无关的 exchange：system 契约 + 围栏化 user payload +
    /// 按配置模式落地的输出契约（jsonSchema/jsonObject 走
    /// `response_format`；promptedJSON 只靠提示词——两路都过本地
    /// validator）。
    static func exchange(
        for request: AIStudyRequest,
        prompt: AIStudyPrompt.Messages,
        configuration: ResolvedAIConfiguration
    ) -> AIMessageExchange {
        AIMessageExchange(
            systemPrompt: prompt.systemPrompt,
            userPrompt: prompt.userPrompt,
            maximumOutputTokens: maximumOutputTokens,
            outputContract: AIOutputContract(
                mode: configuration.responseFormatMode,
                schemaName: "oboe_ai_study_v1",
                schema: outputSchema()
            )
        )
    }

    /// §3.2 响应契约的 strict JSON-schema 投影（OpenAI
    /// `response_format: json_schema` 用；其余模式忽略该字段）。
    /// 每个字段都列 required——strict 模式要求全键必填，可空槽位
    /// 用 `anyOf … null` 表达（与修卡/制卡 schema 同法）。
    private static func outputSchema() -> [String: Any] {
        let integerOrNull: [String: Any] = [
            "anyOf": [["type": "integer"], ["type": "null"]]
        ]
        let stringOrNull: [String: Any] = [
            "anyOf": [["type": "string"], ["type": "null"]]
        ]
        let numberOrNull: [String: Any] = [
            "anyOf": [["type": "number"], ["type": "null"]]
        ]
        let word: [String: Any] = [
            "type": "object",
            "properties": [
                "tokenID": ["type": "string"],
                "status": ["type": "string", "enum": ["resolved", "unresolved"]],
                "entryID": integerOrNull,
                "senseID": integerOrNull,
                "confidence": numberOrNull,
            ],
            "required": ["tokenID", "status", "entryID", "senseID", "confidence"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "schemaVersion": [
                    "type": "integer", "const": AIStudyRequest.schemaVersion],
                "requestID": ["type": "string"],
                "translation": stringOrNull,
                "words": [
                    "type": "array",
                    "maxItems": AIStudyBudget.maxWordItems,
                    "items": word,
                ],
            ],
            "required": ["schemaVersion", "requestID", "translation", "words"],
            "additionalProperties": false,
        ]
    }

    // MARK: - 错误分类（§9.2）

    /// `AIConnectionError` → 本契约错误。429 重新解析响应头以支持
    /// HTTP-date（共享层 `AIHTTPSupport` 目前只认秒数——probe 保留的
    /// 原始头在客户端侧补齐第二形态，不动共享代码）。
    private func classify(_ error: Error) async -> AIStudyResolverError {
        guard let connectionError = error as? AIConnectionError else {
            return .retryable(.connectionFailed)
        }
        switch connectionError {
        case .cancelled:
            return .cancelled
        case .authenticationFailed, .insufficientBalance,
             .invalidCredential, .credentialMissing:
            // 401/403/402 + 凭据本地校验失败 → 停派信号（§9.2：
            // 修正前不再发新请求）。
            return .authFailed
        case let .rateLimited(declaredSeconds):
            let headers = await probe.lastResponse?.headers
            let parsed = headers.flatMap {
                Self.retryAfterInterval(headers: $0, now: now())
            }
            return .rateLimited(
                retryAfter: parsed ?? declaredSeconds.map(TimeInterval.init))
        case .redirectRejected:
            return .redirectRejected
        case .capabilityMismatch:
            return .unsupportedConfiguration(
                "当前服务的输出模式与供应商能力不符；请在设置中调整输出格式或更换供应商。")
        case let .unsupportedConfiguration(statusCode):
            return .unsupportedConfiguration(
                "服务拒绝了当前模型或端点配置（HTTP \(statusCode)）；请检查模型名与服务地址。")
        case .aiDisabled:
            return .unsupportedConfiguration(
                "AI 未启用；请先在设置中启用并保存配置。")
        case .modelNotSelected:
            return .unsupportedConfiguration(
                "尚未选择模型；请在设置中选择模型后重试。")
        default:
            // timedOut / serviceUnavailable / networkUnavailable /
            // connectionFailed / secureConnectionFailed /
            // unexpectedStatus / responseTooLarge / malformedResponse /
            // emptyResponse / truncatedResponse → 有限重试档。
            return .retryable(connectionError)
        }
    }

    // MARK: - Retry-After（秒数 + HTTP-date 两形）

    /// 与 `AIHTTPSupport` 相同的上限（24h），防服务端发离谱值。
    static let maxRetryAfterInterval: TimeInterval = 86_400

    /// 解析 Retry-After：整数秒 → 直接采用；否则按 HTTP-date
    /// （IMF-fixdate，另兼容 RFC850/asctime 遗留形）与 `now` 求差。
    /// 头缺失、空值、无法解析 → nil（由调用方做 full-jitter 退避）。
    static func retryAfterInterval(
        headers: [String: String],
        now: Date
    ) -> TimeInterval? {
        guard let raw = headers.first(where: {
            $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return min(TimeInterval(seconds), maxRetryAfterInterval)
        }
        guard let date = parseHTTPDate(raw) else { return nil }
        return min(
            max(date.timeIntervalSince(now), 0),
            maxRetryAfterInterval
        )
    }

    /// HTTP-date 三形态（RFC 7231 IMF-fixdate + 遗留 RFC850/asctime）。
    static func parseHTTPDate(_ value: String) -> Date? {
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
            "EEE MMM d HH:mm:ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// transport 外层探针：转发 `AIHTTPTransport.send` 并保留最近一次
/// 响应（状态码 + 头 + body 引用），供 Retry-After 等头字段在
/// executor 只回传文本之后仍可读取。actor 隔离保证并发安全。
private actor AIStudyTransportProbe: AIHTTPTransport {
    private let inner: any AIHTTPTransport
    private(set) var lastResponse: AIHTTPResponse?

    init(inner: any AIHTTPTransport) {
        self.inner = inner
    }

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        let response = try await inner.send(request)
        lastResponse = response
        return response
    }
}
