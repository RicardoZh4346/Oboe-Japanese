import Foundation
@testable import OboeInfrastructure

/// S10：AI Resolver client 测试用 fake transport 与三协议响应信封。
/// 惯例沿用 `AIMessageAdapterTests` 的 `AdapterCapturingTransport`——
/// `AIHTTPTransport` 是模块内部协议，fake 只能放测试目标（@testable）。
///
/// 覆盖需求矩阵：固定响应 / malformed / 429+Retry-After（秒数与
/// HTTP-date）/ 401·403·402 / 5xx / timeout / 慢响应（供取消）/
/// 跨源重定向拒绝（直接抛 `AIConnectionError.redirectRejected`，
/// 与 `URLSessionAIHTTPTransport` 的行为一致）。
actor AIStudyFakeTransport: AIHTTPTransport {

    /// 一次 `send` 的行为脚本。
    enum Step: Sendable {
        /// 返回固定响应（含任意 status/headers/body）。
        case respond(AIHTTPResponse)
        /// 抛错（URLError 或 AIConnectionError——executor 各自映射）。
        case fail(any Error & Sendable)
        /// 挂起直到任务被取消（供取消传播测试）；若未被取消，
        /// 超时后抛 `URLError(.timedOut)`——测试中不应到达。
        case suspendUntilCancelled
    }

    private var steps: [Step]
    private let fallback: Step
    /// 已收到的全部请求（供「fail-fast 不发请求」断言）。
    private(set) var requests: [URLRequest] = []

    /// `steps` 依序消费；耗尽后用 `fallback`（默认 200 空体）。
    init(steps: [Step] = [], fallback: Step? = nil) {
        self.steps = steps
        self.fallback = fallback ?? .respond(
            AIHTTPResponse(statusCode: 200, headers: [:], body: Data()))
    }

    /// 单响应便捷构造（覆盖矩阵主力形态）。
    init(response: AIHTTPResponse) {
        self.init(steps: [.respond(response)])
    }

    /// 单错误便捷构造。
    init(error: any Error & Sendable) {
        self.init(steps: [.fail(error)])
    }

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        let step = steps.isEmpty ? fallback : steps.removeFirst()
        switch step {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        case .suspendUntilCancelled:
            // 长时间挂起：Task.sleep 在取消时立即抛 CancellationError。
            try await Task.sleep(nanoseconds: 600_000_000_000)
            throw URLError(.timedOut)
        }
    }

    var requestCount: Int { requests.count }
    func lastRequest() -> URLRequest? { requests.last }
}

/// 三协议线格式响应信封构造器。`content`/`text` 是模型输出的
/// **原始字符串**（ study 契约 JSON），由各信封 JSON 序列化转义。
enum AIStudyFakeResponses {

    // MARK: - OpenAI Chat Completions 形态

    /// `{"choices":[{"message":{"content":…},"finish_reason":…}]}`。
    static func openAI(
        content: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        finishReason: String = "stop"
    ) -> AIHTTPResponse {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["content": content],
                "finish_reason": finishReason,
            ]]
        ])
        return AIHTTPResponse(
            statusCode: statusCode, headers: headers, body: data)
    }

    // MARK: - Anthropic Messages 形态

    /// `{"id","type":"message","role":"assistant","model","content":
    /// [{"type":"text","text":…}],"stop_reason":…,"usage":{…}}`。
    static func anthropic(
        text: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        stopReason: String? = "end_turn"
    ) -> AIHTTPResponse {
        var object: [String: Any] = [
            "id": "msg_fake",
            "type": "message",
            "role": "assistant",
            "model": "claude-fake-model",
            "content": [["type": "text", "text": text]],
            "usage": ["input_tokens": 1, "output_tokens": 1],
        ]
        object["stop_reason"] = stopReason ?? NSNull()
        return AIHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: object)
        )
    }

    // MARK: - Gemini generateContent 形态

    /// `{"candidates":[{"content":{"role":"model","parts":[{"text":…}]},
    /// "finishReason":…}]}`。
    static func gemini(
        text: String,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        finishReason: String? = "STOP"
    ) -> AIHTTPResponse {
        var candidate: [String: Any] = [
            "content": ["role": "model", "parts": [["text": text]]]
        ]
        candidate["finishReason"] = finishReason ?? NSNull()
        return AIHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: [
                "candidates": [candidate]
            ])
        )
    }

    // MARK: - 裸 HTTP 形态（状态码/头驱动——4xx/5xx/malformed）

    /// 不带任何协议信封的裸响应（默认空体）。用于 401/402/403/429/
    /// 5xx 与「200 但体非协议信封 → adapter malformed」两类场景。
    static func http(
        statusCode: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) -> AIHTTPResponse {
        AIHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: Data(body.utf8)
        )
    }

    /// IMF-fixdate 格式化（`EEE, dd MMM yyyy HH:mm:ss 'GMT'`）——
    /// 生成测试用 Retry-After HTTP-date 值。
    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
