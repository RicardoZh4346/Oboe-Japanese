import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// Gemini 原生 generateContent adapter：端点路径编码、`x-goog-api-key`
/// 鉴权头、systemInstruction/contents 请求体结构、finishReason 语义
/// 与 candidates/parts 解码的完整覆盖，外加四个业务流的路由断言与
/// 能力 fail-fast（capabilityMismatch）回归。
final class GeminiGenerateContentAdapterTests: XCTestCase {

    // MARK: - 端点与鉴权头

    func testEndpointAndHeadersSnapshot() async throws {
        let configuration = try Self.geminiConfiguration()
        let transport = GeminiCapturingTransport(
            response: Self.geminiResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: transport
        ).testConnection(configuration: configuration, credential: "gemini-key")

        let captured = await transport.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-key"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
    }

    /// 模型 ID 出现在 URL 路径中，必须编码为单个路径段。
    /// `-`/`.`/`_` 等合法字符原样保留；`/` 与空 ID 直接拒绝——
    /// `models/x` 残留绝不能被当成路径分隔符注入。
    func testModelIDPathSegmentEncoding() throws {
        XCTAssertEqual(
            try GeminiGenerateContentAdapter.pathSegment(
                forModelID: "gemini-2.5_flash.latest"
            ),
            "gemini-2.5_flash.latest"
        )
        XCTAssertEqual(
            try GeminiGenerateContentAdapter.pathSegment(forModelID: "a b"),
            "a%20b"
        )
        for bad in ["", "models/gemini-2.5-flash", "a/b"] {
            XCTAssertThrowsError(
                try GeminiGenerateContentAdapter.pathSegment(forModelID: bad)
            ) { error in
                XCTAssertEqual(
                    error as? AIConnectionError,
                    .unsupportedConfiguration(statusCode: 0)
                )
            }
        }
        // 编码结果进入完整端点后仍然是单一 `:generateContent` 段。
        var draft = AIConfigurationDraft.preset(.gemini)
        draft.isEnabled = true
        draft.modelID = "models/gemini-2.5-flash"
        let badConfiguration = try AIConfigurationValidator.resolve(
            draft,
            credentialID: UUID()
        )
        XCTAssertThrowsError(
            try GeminiGenerateContentAdapter().endpointURL(for: badConfiguration)
        )
    }

    // MARK: - 请求体结构

    /// systemInstruction/contents/generationConfig 三段的完整快照；
    /// 不虚构 responseSchema/responseMimeType/stream 等字段；
    /// 凭据只在协议头，绝不进 body。
    func testRequestBodyShape() async throws {
        let configuration = try Self.geminiConfiguration()
        let transport = GeminiCapturingTransport(
            response: Self.geminiResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: transport
        ).testConnection(configuration: configuration, credential: "gemini-key")

        let captured = await transport.lastRequest()
        let request = try XCTUnwrap(captured)
        let body = try Self.requestJSONObject(request)

        let systemInstruction = try XCTUnwrap(
            body["systemInstruction"] as? [String: Any]
        )
        let systemParts = try XCTUnwrap(
            systemInstruction["parts"] as? [[String: Any]]
        )
        XCTAssertEqual(systemParts.count, 1)
        XCTAssertEqual(
            systemParts[0]["text"] as? String,
            "Return only one JSON object with exactly one boolean field named ok."
        )

        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        let userParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(userParts.count, 1)
        XCTAssertEqual(userParts[0]["text"] as? String, #"Return {"ok":true}."#)

        let generationConfig = try XCTUnwrap(
            body["generationConfig"] as? [String: Any]
        )
        XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 128)

        // 协议层不发结构化输出/流式字段；模型 ID 只在 URL 路径中。
        XCTAssertNil(body["response_format"])
        XCTAssertNil(body["responseSchema"])
        XCTAssertNil(body["responseMimeType"])
        XCTAssertNil(body["stream"])
        XCTAssertNil(body["model"])
        let rawBody = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(rawBody.contains("gemini-key"))
    }

    /// 与 Anthropic adapter 同策略：即使 exchange 携带 jsonSchema
    /// 契约（预设强制 promptedJSON，这里做防御性断言），body 也不带
    /// 任何结构化输出字段。
    func testGeminiBodyNeverCarriesResponseSchema() throws {
        let adapter = GeminiGenerateContentAdapter()
        for mode in AIResponseFormatMode.allCases {
            let exchange = AIMessageExchange(
                systemPrompt: "sys",
                userPrompt: "usr",
                maximumOutputTokens: 64,
                outputContract: AIOutputContract(
                    mode: mode,
                    schemaName: "test_schema",
                    schema: ["type": "object"]
                )
            )
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: adapter.requestBody(
                        for: exchange,
                        configuration: try Self.geminiConfiguration()
                    )
                ) as? [String: Any]
            )
            XCTAssertNil(body["response_format"])
            XCTAssertNil(body["responseSchema"])
            XCTAssertNil(body["responseMimeType"])
            XCTAssertNil(body["stream"])
            let systemInstruction = try XCTUnwrap(
                body["systemInstruction"] as? [String: Any]
            )
            XCTAssertEqual(
                (systemInstruction["parts"] as? [[String: Any]])?.first?["text"]
                    as? String,
                "sys"
            )
        }
    }

    // MARK: - 响应解码：finishReason / parts 全分支

    func testResponseDecodingCoversAllFinishReasons() async throws {
        let configuration = try Self.geminiConfiguration()
        let okJSON = #"{"ok":true}"#

        let cases: [(AIHTTPResponse, AIConnectionError?)] = [
            // 正常：STOP + 单文本 part。
            (Self.geminiResponse(okJSON), nil),
            // candidates 空数组与缺失 candidates 键 → 空响应。
            (Self.geminiCandidates([]), .emptyResponse),
            (
                AIHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)
                ),
                .emptyResponse
            ),
            // parts 空数组 / 文本为空白 → 空响应。
            (Self.geminiResponse(parts: []), .emptyResponse),
            (Self.geminiResponse("   "), .emptyResponse),
            // MAX_TOKENS → 截断（即使带部分文本）。
            (
                Self.geminiResponse(okJSON, finishReason: "MAX_TOKENS"),
                .truncatedResponse
            ),
            // 其他 finishReason → malformed。
            (
                Self.geminiResponse(okJSON, finishReason: "SAFETY"),
                .malformedResponse
            ),
            (
                Self.geminiResponse(okJSON, finishReason: "RECITATION"),
                .malformedResponse
            ),
            (
                Self.geminiResponse(okJSON, finishReason: "OTHER"),
                .malformedResponse
            ),
            // finishReason 为 null（缺失同样视为非法收尾）。
            (Self.geminiResponse(okJSON, finishReason: nil), .malformedResponse),
            // 非文本 part（functionCall/inlineData 等）→ malformed。
            (
                Self.geminiResponse(
                    parts: [["functionCall": ["name": "f", "args": [:]]]]
                ),
                .malformedResponse
            ),
            // 非法 JSON / 非 generateContent 信封 → malformed。
            (
                AIHTTPResponse(statusCode: 200, headers: [:], body: Data("bad".utf8)),
                .malformedResponse
            ),
            (
                AIHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"[{"text":"x"}]"#.utf8)
                ),
                .malformedResponse
            )
        ]

        for (response, expected) in cases {
            let client = ChatCompletionsAIConnectionClient(
                transport: GeminiCapturingTransport(response: response)
            )
            do {
                _ = try await client.testConnection(
                    configuration: configuration,
                    credential: "gemini-key"
                )
                XCTAssertNil(expected, "Expected \(String(describing: expected))")
            } catch let error as AIConnectionError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    /// candidates[0].content.parts 中全部文本 part 拼接为模型输出。
    func testMultipleTextPartsConcatenate() async throws {
        let configuration = try Self.geminiConfiguration()
        let client = ChatCompletionsAIConnectionClient(
            transport: GeminiCapturingTransport(
                response: Self.geminiResponse(
                    parts: [
                        ["text": #"{"ok":"#],
                        ["text": #"true"}"#]
                    ]
                )
            )
        )
        // 拼出 {"ok":"true"}：ok 不是 Bool → capabilityMismatch，
        // 证明拼接确实发生了。
        do {
            _ = try await client.testConnection(
                configuration: configuration,
                credential: "gemini-key"
            )
            XCTFail("Expected capabilityMismatch")
        } catch let error as AIConnectionError {
            XCTAssertEqual(error, .capabilityMismatch)
        }
    }

    // MARK: - 四种业务流路由

    func testAllFourFlowsRouteThroughGeminiAdapter() async throws {
        let configuration = try Self.geminiConfiguration()
        let endpoint =
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

        // 1. 连接测试
        let connectionTransport = GeminiCapturingTransport(
            response: Self.geminiResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: connectionTransport
        ).testConnection(configuration: configuration, credential: "gemini-key")
        let connectionRequest = await connectionTransport.lastRequest()
        let connectionBody = try Self.requestJSONObject(
            try XCTUnwrap(connectionRequest)
        )
        XCTAssertEqual(connectionRequest?.url?.absoluteString, endpoint)
        XCTAssertEqual(
            (connectionBody["generationConfig"] as? [String: Any])?["maxOutputTokens"]
                as? Int,
            128
        )

        // 2. AI 制卡
        let cardTransport = GeminiCapturingTransport(
            response: Self.geminiResponse(Self.vocabularyJSON)
        )
        let cardContent = try await ChatCompletionsAICardGenerationClient(
            transport: cardTransport
        ).generate(
            input: AICardGenerationInput(kind: .vocabulary, text: "食べる"),
            configuration: configuration,
            credential: "gemini-key"
        )
        XCTAssertEqual(cardContent, Self.vocabularyJSON)
        let cardRequest = await cardTransport.lastRequest()
        let cardBody = try Self.requestJSONObject(try XCTUnwrap(cardRequest))
        XCTAssertEqual(cardRequest?.url?.absoluteString, endpoint)
        XCTAssertEqual(
            (cardBody["generationConfig"] as? [String: Any])?["maxOutputTokens"]
                as? Int,
            1_200
        )
        XCTAssertTrue(
            Self.systemText(in: cardBody)?.contains("oboe-card-generation-v2") == true
        )

        // 3. 句子分析
        let sentenceTransport = GeminiCapturingTransport(
            response: Self.geminiResponse(Self.sentenceJSON)
        )
        let sentenceContent = try await ChatCompletionsSentenceAnalysisClient(
            transport: sentenceTransport
        ).analyze(
            input: SentenceAnalysisInput(sentence: "日本に行ったことがありますか。"),
            configuration: configuration,
            credential: "gemini-key"
        )
        XCTAssertEqual(sentenceContent, Self.sentenceJSON)
        let sentenceRequest = await sentenceTransport.lastRequest()
        let sentenceBody = try Self.requestJSONObject(
            try XCTUnwrap(sentenceRequest)
        )
        XCTAssertEqual(sentenceRequest?.url?.absoluteString, endpoint)
        XCTAssertEqual(
            (sentenceBody["generationConfig"] as? [String: Any])?["maxOutputTokens"]
                as? Int,
            4_000
        )
        XCTAssertTrue(
            Self.systemText(in: sentenceBody)?.contains("oboe-sentence-analysis-v2")
                == true
        )

        // 4. AI 修复
        let repairTransport = GeminiCapturingTransport(
            response: Self.geminiResponse(Self.repairJSON)
        )
        let repairContent = try await ChatCompletionsAIRepairClient(
            transport: repairTransport
        ).analyze(
            context: Self.repairContext,
            configuration: configuration,
            credential: "gemini-key"
        )
        XCTAssertEqual(repairContent, Self.repairJSON)
        let repairRequest = await repairTransport.lastRequest()
        let repairBody = try Self.requestJSONObject(try XCTUnwrap(repairRequest))
        XCTAssertEqual(repairRequest?.url?.absoluteString, endpoint)
        XCTAssertEqual(
            (repairBody["generationConfig"] as? [String: Any])?["maxOutputTokens"]
                as? Int,
            4_000
        )
        XCTAssertTrue(
            Self.systemText(in: repairBody)?.contains("oboe-ai-repair-v2") == true
        )
        // 凭据只在协议头中，绝不进 body。
        let rawBody = String(data: try XCTUnwrap(repairRequest?.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(rawBody.contains("gemini-key"))
        XCTAssertEqual(
            repairRequest?.value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-key"
        )
    }

    // MARK: - 能力 fail-fast

    /// 输出模式超出供应商能力集时在发请求前拒绝（capabilityMismatch）。
    /// 预设的 responseFormatMode 由 validator 强制——这里手工构造一个
    /// 绕过校验的 resolved 配置做防御性回归。
    func testUnsupportedOutputModeFailsFastWithoutSending() async throws {
        let configuration = ResolvedAIConfiguration(
            isEnabled: true,
            serviceKind: .claude,
            serviceName: "Claude（Anthropic）",
            baseURL: URL(string: "https://api.anthropic.com")!,
            modelID: "claude-test-model",
            responseFormatMode: .jsonSchema,  // Claude 能力集只含 promptedJSON
            credentialReference: AICredentialReference(
                id: UUID(),
                serviceKind: .claude,
                host: "api.anthropic.com"
            )
        )
        let transport = GeminiCapturingTransport(
            response: Self.geminiResponse(#"{"ok":true}"#)
        )
        do {
            _ = try await ChatCompletionsAIConnectionClient(
                transport: transport
            ).testConnection(configuration: configuration, credential: "key")
            XCTFail("Expected capabilityMismatch")
        } catch let error as AIConnectionError {
            XCTAssertEqual(error, .capabilityMismatch)
        }
        let sent = await transport.lastRequest()
        XCTAssertNil(sent, "能力不匹配必须在发请求前 fail-fast")
    }

    /// custom 按 OpenAI 兼容默认能力放行全部三种输出模式——能力 gate
    /// 不得误拦自定义服务。
    func testCustomServicePassesCapabilityGateForAllModes() async throws {
        for mode in AIResponseFormatMode.allCases {
            let configuration = Self.customConfiguration(mode: mode)
            let transport = GeminiCapturingTransport(
                response: Self.openAIStyleResponse(#"{"ok":true}"#)
            )
            _ = try await ChatCompletionsAIConnectionClient(
                transport: transport
            ).testConnection(configuration: configuration, credential: "key")
            let sent = await transport.lastRequest()
            XCTAssertNotNil(sent, "custom 的 \(mode) 应正常发请求")
        }
    }

    /// 能力声明与 adapter 分发的一致性契约：注册表中每个预设
    /// （以及 custom）都能解析出执行 adapter。
    func testEveryServiceKindResolvesAnAdapter() throws {
        for kind in AIServiceKind.allCases {
            var draft = AIConfigurationDraft.preset(kind)
            draft.isEnabled = true
            draft.modelID = "contract-model"
            if kind == .custom {
                draft.serviceName = "Fixture"
                draft.baseURL = "https://fixture.example/v1"
            }
            let configuration = try AIConfigurationValidator.resolve(
                draft,
                credentialID: UUID()
            )
            XCTAssertNotNil(
                try AIMessageAdapterRegistry.adapter(for: configuration),
                "\(kind) 声明 supportsGeneration，必须能解析出 adapter"
            )
        }
    }

    // MARK: - Fixtures

    private static let vocabularyJSON = #"{"schemaVersion":2,"kind":"vocabulary","headword":"食べる","reading":"たべる","meaningZH":"吃","partsOfSpeech":["一段动词","他动词"],"pitchAccent":2,"jlpt":"N5","examples":[{"japanese":"毎朝パンを食べます。","translationZH":"我每天早上吃面包。"}],"notes":"","warnings":[]}"#

    private static let sentenceJSON = #"{"schemaVersion":2,"sentence":"日本に行ったことがありますか。","translationZH":"你去过日本吗？","explanationZH":"询问过去经历。","items":[],"warnings":[]}"#

    private static let repairJSON = #"{"schemaVersion":2,"problemTypes":[],"summary":"ok","suggestions":[]}"#

    private static var repairContext: AIRepairRequestContext {
        AIRepairRequestContext(
            note: AIRepairNoteSnapshot(
                kind: .vocabulary,
                headword: "受ける",
                reading: "うける",
                meaningZH: "接受；遭受",
                partOfSpeech: "一段动词 / 他动词",
                pitchAccent: PitchAccent(rawValue: 2),
                jlpt: .n3
            ),
            direction: .vocabularyJapaneseToChinese,
            reviewSummary: AIRepairReviewSummary(
                recentCount: 6,
                recentAgainCount: 3,
                dueAgainStreak: 2,
                lifetimeLapses: 6
            ),
            userComment: "总是记混"
        )
    }

    static func geminiConfiguration() throws -> ResolvedAIConfiguration {
        var draft = AIConfigurationDraft.preset(.gemini)
        draft.isEnabled = true
        draft.modelID = "gemini-2.5-flash"
        return try AIConfigurationValidator.resolve(draft, credentialID: UUID())
    }

    static func customConfiguration(mode: AIResponseFormatMode) -> ResolvedAIConfiguration {
        ResolvedAIConfiguration(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "Fixture",
            baseURL: URL(string: "https://fixture.example/v1")!,
            modelID: "fixture-model",
            responseFormatMode: mode,
            credentialReference: AICredentialReference(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                serviceKind: .custom,
                host: "fixture.example"
            )
        )
    }

    /// Gemini generateContent 响应信封：默认单候选 STOP + 单文本 part。
    static func geminiResponse(
        _ text: String,
        finishReason: String? = "STOP"
    ) -> AIHTTPResponse {
        geminiResponse(parts: [["text": text]], finishReason: finishReason)
    }

    static func geminiResponse(
        parts: [[String: Any]],
        finishReason: String? = "STOP"
    ) -> AIHTTPResponse {
        geminiCandidates([[
            "content": ["role": "model", "parts": parts],
            "finishReason": finishReason ?? NSNull()
        ]])
    }

    static func geminiCandidates(_ candidates: [[String: Any]]) -> AIHTTPResponse {
        let data = try! JSONSerialization.data(
            withJSONObject: ["candidates": candidates]
        )
        return AIHTTPResponse(statusCode: 200, headers: [:], body: data)
    }

    static func openAIStyleResponse(_ content: String) -> AIHTTPResponse {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["content": content],
                "finish_reason": "stop"
            ]]
        ])
        return AIHTTPResponse(statusCode: 200, headers: [:], body: data)
    }

    /// 请求体 JSON → systemInstruction 首段文本。
    private static func systemText(in body: [String: Any]) -> String? {
        ((body["systemInstruction"] as? [String: Any])?["parts"]
            as? [[String: Any]])?.first?["text"] as? String
    }

    private static func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
    }
}

private actor GeminiCapturingTransport: AIHTTPTransport {
    let response: AIHTTPResponse
    private var request: URLRequest?

    init(response: AIHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) -> AIHTTPResponse {
        self.request = request
        return response
    }

    func lastRequest() -> URLRequest? { request }
}
