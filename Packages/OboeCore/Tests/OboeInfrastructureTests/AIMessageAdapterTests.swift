import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// Step 11: adapter 路由 + 线格式快照。同一领域请求分别在
/// OpenAI Chat Completions 与 Anthropic Messages 两种协议下断言：
/// 端点、鉴权头、body 结构、stop_reason/finish_reason 语义与错误映射一致。
final class AIMessageAdapterTests: XCTestCase {

    // MARK: - 同一领域请求的两种线格式快照

    func testSameExchangeProducesEquivalentWireFormats() async throws {
        let input = AICardGenerationInput(
            kind: .vocabulary,
            text: "食べる",
            context: "早餐语境"
        )
        let claude = try Self.claudeConfiguration()
        let custom = Self.customConfiguration(mode: .jsonObject)

        let claudeTransport = AdapterCapturingTransport(
            response: Self.anthropicResponse(Self.vocabularyJSON)
        )
        let claudeContent = try await ChatCompletionsAICardGenerationClient(
            transport: claudeTransport
        ).generate(input: input, configuration: claude, credential: "claude-key")

        let openAITransport = AdapterCapturingTransport(
            response: Self.openAIResponse(Self.vocabularyJSON)
        )
        let openAIContent = try await ChatCompletionsAICardGenerationClient(
            transport: openAITransport
        ).generate(input: input, configuration: custom, credential: "openai-key")

        // 两边返回同样的模型文本（线格式差异不影响业务结果）。
        XCTAssertEqual(claudeContent, Self.vocabularyJSON)
        XCTAssertEqual(openAIContent, Self.vocabularyJSON)

        let capturedClaude = await claudeTransport.lastRequest()
        let capturedOpenAI = await openAITransport.lastRequest()
        let claudeRequest = try XCTUnwrap(capturedClaude)
        let openAIRequest = try XCTUnwrap(capturedOpenAI)

        // 端点与鉴权头。
        XCTAssertEqual(
            claudeRequest.url?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(claudeRequest.value(forHTTPHeaderField: "x-api-key"), "claude-key")
        XCTAssertEqual(
            claudeRequest.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
        XCTAssertNil(claudeRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            openAIRequest.url?.absoluteString,
            "https://fixture.example/v1/chat/completions"
        )
        XCTAssertEqual(
            openAIRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer openai-key"
        )
        XCTAssertNil(openAIRequest.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(openAIRequest.value(forHTTPHeaderField: "anthropic-version"))

        let claudeBody = try Self.requestJSONObject(claudeRequest)
        let openAIBody = try Self.requestJSONObject(openAIRequest)

        // 两份快照：system 提示词与 user 负载必须逐字相同，模型/输出上限相同。
        let openAIMessages = try XCTUnwrap(openAIBody["messages"] as? [[String: Any]])
        XCTAssertEqual(openAIMessages.count, 2)
        XCTAssertEqual(openAIMessages[0]["role"] as? String, "system")
        XCTAssertEqual(openAIMessages[1]["role"] as? String, "user")
        XCTAssertEqual(
            claudeBody["system"] as? String,
            openAIMessages[0]["content"] as? String
        )
        let claudeMessages = try XCTUnwrap(claudeBody["messages"] as? [[String: Any]])
        XCTAssertEqual(claudeMessages.count, 1)
        XCTAssertEqual(claudeMessages[0]["role"] as? String, "user")
        let claudeContentBlocks = try XCTUnwrap(
            claudeMessages[0]["content"] as? [[String: Any]]
        )
        XCTAssertEqual(claudeContentBlocks.count, 1)
        XCTAssertEqual(claudeContentBlocks[0]["type"] as? String, "text")
        XCTAssertEqual(
            claudeContentBlocks[0]["text"] as? String,
            openAIMessages[1]["content"] as? String
        )
        // model 各自取自己的配置；同一业务流的输出上限必须一致。
        XCTAssertEqual(claudeBody["model"] as? String, "claude-test-model")
        XCTAssertEqual(openAIBody["model"] as? String, "fixture-model")
        XCTAssertEqual(
            claudeBody["max_tokens"] as? Int,
            openAIBody["max_tokens"] as? Int
        )

        // Anthropic 线格式不带 OpenAI 专属字段。
        XCTAssertNil(claudeBody["response_format"])
        XCTAssertNil(claudeBody["stream"])
        XCTAssertEqual(openAIBody["stream"] as? Bool, false)
        XCTAssertEqual(
            (openAIBody["response_format"] as? [String: Any])?["type"] as? String,
            "json_object"
        )
    }

    /// Anthropic adapter 永不发送 `response_format`/`stream`，即使 exchange
    /// 携带 jsonSchema 契约（preset 对 Claude 强制 promptedJSON，这里做防御性断言）。
    func testAnthropicBodyNeverCarriesResponseFormat() throws {
        let adapter = AnthropicMessagesAdapter()
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
                        configuration: Self.customConfiguration(mode: mode)
                    )
                ) as? [String: Any]
            )
            XCTAssertNil(body["response_format"])
            XCTAssertNil(body["stream"])
            XCTAssertEqual(body["system"] as? String, "sys")
        }
    }

    // MARK: - Claude 响应解码：正常/空/截断/非法 stop_reason

    func testAnthropicResponseDecodingCoversAllStopReasons() async throws {
        let configuration = try Self.claudeConfiguration()
        let okJSON = #"{"ok":true}"#

        let cases: [(AIHTTPResponse, AIConnectionError?)] = [
            // 正常：单文本块。
            (Self.anthropicResponse(okJSON), nil),
            // 空 content 数组。
            (Self.anthropicResponse(content: []), .emptyResponse),
            // 文本块内容为空串。
            (Self.anthropicResponse("   "), .emptyResponse),
            // max_tokens → 截断。
            (Self.anthropicResponse(okJSON, stopReason: "max_tokens"), .truncatedResponse),
            // 其他 stop_reason → malformed。
            (
                Self.anthropicResponse(okJSON, stopReason: "stop_sequence"),
                .malformedResponse
            ),
            (Self.anthropicResponse(okJSON, stopReason: "tool_use"), .malformedResponse),
            (Self.anthropicResponse(okJSON, stopReason: "refusal"), .malformedResponse),
            // stop_reason 为 null。
            (Self.anthropicResponse(okJSON, stopReason: nil), .malformedResponse),
            // 非文本 block。
            (
                Self.anthropicResponse(
                    content: [["type": "tool_use", "id": "t1", "name": "x"]]
                ),
                .malformedResponse
            ),
            // 非 JSON / 非 Messages 信封。
            (
                AIHTTPResponse(statusCode: 200, headers: [:], body: Data("bad".utf8)),
                .malformedResponse
            ),
            (
                AIHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Self.openAIResponse(okJSON).body
                ),
                .malformedResponse
            )
        ]

        for (response, expected) in cases {
            let client = ChatCompletionsAIConnectionClient(
                transport: AdapterCapturingTransport(response: response)
            )
            do {
                _ = try await client.testConnection(
                    configuration: configuration,
                    credential: "claude-key"
                )
                XCTAssertNil(expected, "Expected \(String(describing: expected))")
            } catch let error as AIConnectionError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    /// 多个文本块拼接后仍走同一内容校验。
    func testAnthropicMultipleTextBlocksConcatenate() async throws {
        let configuration = try Self.claudeConfiguration()
        let client = ChatCompletionsAIConnectionClient(
            transport: AdapterCapturingTransport(
                response: Self.anthropicResponse(
                    content: [
                        ["type": "text", "text": #"{"ok":"#],
                        ["type": "text", "text": #"true"}"#]
                    ]
                )
            )
        )
        // 拼出 {"ok":"true"}：ok 不是 Bool → capabilityMismatch，
        // 证明拼接确实发生了。
        do {
            _ = try await client.testConnection(
                configuration: configuration,
                credential: "claude-key"
            )
            XCTFail("Expected capabilityMismatch")
        } catch let error as AIConnectionError {
            XCTAssertEqual(error, .capabilityMismatch)
        }
    }

    func testAnthropicCapabilityCheckMatchesOpenAISemantics() async throws {
        let configuration = try Self.claudeConfiguration()
        for content in ["plain text", #"{"ok":false}"#, #"{"ok":true,"x":1}"#] {
            let client = ChatCompletionsAIConnectionClient(
                transport: AdapterCapturingTransport(
                    response: Self.anthropicResponse(content)
                )
            )
            do {
                _ = try await client.testConnection(
                    configuration: configuration,
                    credential: "claude-key"
                )
                XCTFail("Expected capabilityMismatch")
            } catch let error as AIConnectionError {
                XCTAssertEqual(error, .capabilityMismatch)
            }
        }

        let client = ChatCompletionsAIConnectionClient(
            transport: AdapterCapturingTransport(
                response: Self.anthropicResponse(#"{"ok":true}"#)
            )
        )
        let result = try await client.testConnection(
            configuration: configuration,
            credential: "claude-key"
        )
        XCTAssertEqual(result.modelID, "claude-test-model")
        XCTAssertEqual(result.responseFormatMode, .promptedJSON)
        XCTAssertEqual(result.serviceName, "Claude（Anthropic）")
    }

    // MARK: - 四种业务流 × 两种 adapter

    func testAllFourFlowsRouteThroughAnthropicAdapter() async throws {
        let configuration = try Self.claudeConfiguration()

        // 1. 连接测试
        let connectionTransport = AdapterCapturingTransport(
            response: Self.anthropicResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: connectionTransport
        ).testConnection(configuration: configuration, credential: "claude-key")
        let connectionRequest = await connectionTransport.lastRequest()
        let connectionBody = try Self.requestJSONObject(
            try XCTUnwrap(connectionRequest)
        )
        XCTAssertEqual(connectionBody["max_tokens"] as? Int, 128)

        // 2. AI 制卡
        let cardTransport = AdapterCapturingTransport(
            response: Self.anthropicResponse(Self.vocabularyJSON)
        )
        let cardContent = try await ChatCompletionsAICardGenerationClient(
            transport: cardTransport
        ).generate(
            input: AICardGenerationInput(kind: .vocabulary, text: "食べる"),
            configuration: configuration,
            credential: "claude-key"
        )
        XCTAssertEqual(cardContent, Self.vocabularyJSON)
        let capturedCard = await cardTransport.lastRequest()
        let cardRequest = try XCTUnwrap(capturedCard)
        let cardBody = try Self.requestJSONObject(cardRequest)
        XCTAssertEqual(
            cardRequest.url?.absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(cardBody["max_tokens"] as? Int, 1_200)
        XCTAssertTrue(
            (cardBody["system"] as? String)?.contains("oboe-card-generation-v2") == true
        )

        // 3. 句子分析
        let sentenceTransport = AdapterCapturingTransport(
            response: Self.anthropicResponse(Self.sentenceJSON)
        )
        let sentenceContent = try await ChatCompletionsSentenceAnalysisClient(
            transport: sentenceTransport
        ).analyze(
            input: SentenceAnalysisInput(sentence: "日本に行ったことがありますか。"),
            configuration: configuration,
            credential: "claude-key"
        )
        XCTAssertEqual(sentenceContent, Self.sentenceJSON)
        let sentenceRequest = await sentenceTransport.lastRequest()
        let sentenceBody = try Self.requestJSONObject(
            try XCTUnwrap(sentenceRequest)
        )
        XCTAssertEqual(sentenceBody["max_tokens"] as? Int, 4_000)
        XCTAssertTrue(
            (sentenceBody["system"] as? String)?.contains("oboe-sentence-analysis-v2") == true
        )

        // 4. AI 修复
        let repairTransport = AdapterCapturingTransport(
            response: Self.anthropicResponse(Self.repairJSON)
        )
        let repairContent = try await ChatCompletionsAIRepairClient(
            transport: repairTransport
        ).analyze(
            context: Self.repairContext,
            configuration: configuration,
            credential: "claude-key"
        )
        XCTAssertEqual(repairContent, Self.repairJSON)
        let capturedRepair = await repairTransport.lastRequest()
        let repairRequest = try XCTUnwrap(capturedRepair)
        let repairBody = try Self.requestJSONObject(repairRequest)
        XCTAssertEqual(repairBody["max_tokens"] as? Int, 4_000)
        XCTAssertTrue(
            (repairBody["system"] as? String)?.contains("oboe-ai-repair-v2") == true
        )
        // 凭据只在协议头中，绝不进 body。
        let rawBody = String(data: try XCTUnwrap(repairRequest.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(rawBody.contains("claude-key"))
    }

    /// OpenAI adapter 上的四个业务流（回归既有语义，一次跑通）。
    func testAllFourFlowsStillWorkOnOpenAIAdapter() async throws {
        let configuration = Self.customConfiguration(mode: .jsonObject)

        _ = try await ChatCompletionsAIConnectionClient(
            transport: AdapterCapturingTransport(
                response: Self.openAIResponse(#"{"ok":true}"#)
            )
        ).testConnection(configuration: configuration, credential: "key")

        let card = try await ChatCompletionsAICardGenerationClient(
            transport: AdapterCapturingTransport(
                response: Self.openAIResponse(Self.vocabularyJSON)
            )
        ).generate(
            input: AICardGenerationInput(kind: .vocabulary, text: "食べる"),
            configuration: configuration,
            credential: "key"
        )
        XCTAssertEqual(card, Self.vocabularyJSON)

        let sentence = try await ChatCompletionsSentenceAnalysisClient(
            transport: AdapterCapturingTransport(
                response: Self.openAIResponse(Self.sentenceJSON)
            )
        ).analyze(
            input: SentenceAnalysisInput(sentence: "日本に行ったことがありますか。"),
            configuration: configuration,
            credential: "key"
        )
        XCTAssertEqual(sentence, Self.sentenceJSON)

        let repair = try await ChatCompletionsAIRepairClient(
            transport: AdapterCapturingTransport(
                response: Self.openAIResponse(Self.repairJSON)
            )
        ).analyze(
            context: Self.repairContext,
            configuration: configuration,
            credential: "key"
        )
        XCTAssertEqual(repair, Self.repairJSON)
    }

    // MARK: - 结构化输出成功/失败（两种 adapter 上同一个严格 decoder）

    func testStructuredOutputDecodesIdenticallyOnBothAdapters() async throws {
        let claudeConfig = try Self.claudeConfiguration()
        let openAIConfig = Self.customConfiguration(mode: .jsonSchema)
        let input = AICardGenerationInput(kind: .vocabulary, text: "食べる")
        let legs: [(AIHTTPResponse, ResolvedAIConfiguration)] = [
            (Self.anthropicResponse(Self.vocabularyJSON), claudeConfig),
            (Self.openAIResponse(Self.vocabularyJSON), openAIConfig)
        ]

        // 成功：两种线格式返回同样的 JSON → 同一个严格 decoder 接受。
        for (response, config) in legs {
            let content = try await ChatCompletionsAICardGenerationClient(
                transport: AdapterCapturingTransport(response: response)
            ).generate(input: input, configuration: config, credential: "key")
            let candidate = try AICardOutputDecoder.decode(
                content,
                requestID: input.requestID,
                sourceInput: input
            )
            guard case .vocabulary = candidate.payload else {
                return XCTFail("Expected vocabulary payload")
            }
        }

        // 失败：契约版本错误的内容在两种 adapter 上都过不了严格 decoder。
        let badJSON = #"{"schemaVersion":1,"kind":"vocabulary"}"#
        for (response, config) in [
            (Self.anthropicResponse(badJSON), claudeConfig),
            (Self.openAIResponse(badJSON), openAIConfig)
        ] {
            let content = try await ChatCompletionsAICardGenerationClient(
                transport: AdapterCapturingTransport(response: response)
            ).generate(input: input, configuration: config, credential: "key")
            XCTAssertThrowsError(
                try AICardOutputDecoder.decode(
                    content,
                    requestID: input.requestID,
                    sourceInput: input
                )
            ) { error in
                XCTAssertEqual(
                    error as? AICardGenerationError,
                    .unsupportedSchemaVersion
                )
            }
        }
    }

    // MARK: - 协议分发：xAI / DashScope 走 OpenAI 兼容，Gemini 走原生 generateContent

    /// Gemini 配置走原生 generateContent adapter：请求确实发出，
    /// 端点为 `{base}/v1beta/models/{model}:generateContent`，
    /// 凭据在 `x-goog-api-key` 头中。
    func testGeminiConfigurationUsesNativeGenerateContentAdapter() async throws {
        var draft = AIConfigurationDraft.preset(.gemini)
        draft.isEnabled = true
        draft.modelID = "gemini-2.5-flash"
        let configuration = try AIConfigurationValidator.resolve(draft, credentialID: UUID())

        let transport = AdapterCapturingTransport(
            response: Self.geminiResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: transport
        ).testConnection(configuration: configuration, credential: "gemini-key")
        let sent = await transport.lastRequest()
        let request = try XCTUnwrap(sent, "Gemini 已有执行 adapter，应发出请求")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-key"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDashScopeAndXAIRouteThroughOpenAICompatibleEndpoints() async throws {
        // DashScope：官方 OpenAI 兼容模式。
        var qwenDraft = AIConfigurationDraft.preset(.qwen)
        qwenDraft.isEnabled = true
        qwenDraft.modelID = "qwen-max"
        let qwen = try AIConfigurationValidator.resolve(qwenDraft, credentialID: UUID())
        let qwenTransport = AdapterCapturingTransport(
            response: Self.openAIResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: qwenTransport
        ).testConnection(configuration: qwen, credential: "qwen-key")
        let capturedQwen = await qwenTransport.lastRequest()
        let qwenRequest = try XCTUnwrap(capturedQwen)
        XCTAssertEqual(
            qwenRequest.url?.absoluteString,
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        )
        XCTAssertEqual(
            qwenRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer qwen-key"
        )

        // xAI：/v1/chat/completions 即 OpenAI 兼容端点。
        var grokDraft = AIConfigurationDraft.preset(.grok)
        grokDraft.isEnabled = true
        grokDraft.modelID = "grok-4"
        let grok = try AIConfigurationValidator.resolve(grokDraft, credentialID: UUID())
        let grokTransport = AdapterCapturingTransport(
            response: Self.openAIResponse(#"{"ok":true}"#)
        )
        _ = try await ChatCompletionsAIConnectionClient(
            transport: grokTransport
        ).testConnection(configuration: grok, credential: "grok-key")
        let capturedGrok = await grokTransport.lastRequest()
        let grokRequest = try XCTUnwrap(capturedGrok)
        XCTAssertEqual(
            grokRequest.url?.absoluteString,
            "https://api.x.ai/v1/chat/completions"
        )
        XCTAssertEqual(
            grokRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer grok-key"
        )
    }

    /// 共享管线语义在 Anthropic 路径上保持一致：状态码、URLError、响应上限。
    func testSharedPipelineSemanticsApplyToAnthropic() async throws {
        let configuration = try Self.claudeConfiguration()
        let failures: [(AIHTTPResponse, AIConnectionError)] = [
            (AIHTTPResponse(statusCode: 401, headers: [:], body: Data()), .authenticationFailed),
            (
                AIHTTPResponse(
                    statusCode: 429,
                    headers: ["Retry-After": "7"],
                    body: Data()
                ),
                .rateLimited(retryAfterSeconds: 7)
            ),
            (
                AIHTTPResponse(statusCode: 529, headers: [:], body: Data()),
                .serviceUnavailable(statusCode: 529)
            ),
            (
                AIHTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(repeating: 0x41, count: 256 * 1_024 + 1)
                ),
                .responseTooLarge
            )
        ]
        for (response, expected) in failures {
            let client = ChatCompletionsAIConnectionClient(
                transport: AdapterCapturingTransport(response: response)
            )
            do {
                _ = try await client.testConnection(
                    configuration: configuration,
                    credential: "claude-key"
                )
                XCTFail("Expected \(expected)")
            } catch let error as AIConnectionError {
                XCTAssertEqual(error, expected)
            }
        }

        let failing = ChatCompletionsAIConnectionClient(
            transport: AdapterFailingTransport(error: URLError(.timedOut))
        )
        do {
            _ = try await failing.testConnection(
                configuration: configuration,
                credential: "claude-key"
            )
            XCTFail("Expected timedOut")
        } catch let error as AIConnectionError {
            XCTAssertEqual(error, .timedOut)
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

    static func claudeConfiguration() throws -> ResolvedAIConfiguration {
        var draft = AIConfigurationDraft.preset(.claude)
        draft.isEnabled = true
        draft.modelID = "claude-test-model"
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

    static func openAIResponse(
        _ content: String,
        finishReason: String = "stop"
    ) -> AIHTTPResponse {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": ["content": content],
                "finish_reason": finishReason
            ]]
        ])
        return AIHTTPResponse(statusCode: 200, headers: [:], body: data)
    }

    static func anthropicResponse(
        _ text: String,
        stopReason: String? = "end_turn"
    ) -> AIHTTPResponse {
        anthropicResponse(
            content: [["type": "text", "text": text]],
            stopReason: stopReason
        )
    }

    static func anthropicResponse(
        content: [[String: Any]],
        stopReason: String? = "end_turn"
    ) -> AIHTTPResponse {
        var object: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "claude-test-model",
            "content": content,
            "usage": ["input_tokens": 1, "output_tokens": 1]
        ]
        object["stop_reason"] = stopReason ?? NSNull()
        return AIHTTPResponse(
            statusCode: 200,
            headers: [:],
            body: try! JSONSerialization.data(withJSONObject: object)
        )
    }

    /// Gemini generateContent 响应信封：单个候选、单文本 part。
    static func geminiResponse(
        _ text: String,
        finishReason: String? = "STOP"
    ) -> AIHTTPResponse {
        geminiResponse(
            parts: [["text": text]],
            finishReason: finishReason
        )
    }

    static func geminiResponse(
        parts: [[String: Any]],
        finishReason: String? = "STOP"
    ) -> AIHTTPResponse {
        var candidate: [String: Any] = [
            "content": ["role": "model", "parts": parts]
        ]
        candidate["finishReason"] = finishReason ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: [
            "candidates": [candidate]
        ])
        return AIHTTPResponse(statusCode: 200, headers: [:], body: data)
    }

    private static func requestJSONObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
    }
}

private actor AdapterCapturingTransport: AIHTTPTransport {
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

private struct AdapterFailingTransport: AIHTTPTransport {
    let error: URLError

    func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        throw error
    }
}
