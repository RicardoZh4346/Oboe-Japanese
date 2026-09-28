import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S10：AI Resolver client 全矩阵测试。
/// 依据：工作包要求——三 Provider fake 全通、能力 fail-fast 不发请求、
/// 429 两形 Retry-After、401 停派、timeout/5xx retryable、取消传播、
/// 跨源重定向分类、validator 全链降级、无 Key 泄漏。
/// 一切流量走 `AIStudyFakeTransport`——无真实网络、无 Keychain。
final class AIStudyResolverClientTests: XCTestCase {

    // MARK: - 三 Provider fake 全通

    /// OpenAI 兼容（custom + jsonObject）：合法响应 →
    /// ValidatedBlockOutcome；断言线格式（Bearer 头、messages 结构、
    /// system 内含 promptVersion、user 内含围栏与 requestID）。
    func testOpenAICompatibleSuccessPath() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001, 1002])]),
        ])
        let content = Self.studyResponseJSON(request: request, words: [
            Self.word("t01", status: "resolved", entryID: 100, senseID: 1001,
                      confidence: 0.97),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "sk-test-openai")

        XCTAssertEqual(result.outcome.lexicalStatus, .resolved)
        XCTAssertEqual(result.outcome.translationStatus, .done)
        XCTAssertEqual(result.outcome.translation, "译文")
        XCTAssertEqual(result.outcome.aiResolvedCount, 1)
        XCTAssertEqual(result.requestHash, request.requestHash)
        XCTAssertEqual(result.requestID, request.requestID)
        XCTAssertEqual(result.providerKind, "custom")
        XCTAssertEqual(result.model, "fixture-model")
        XCTAssertEqual(result.promptVersion, AIStudyPrompt.promptVersion)
        XCTAssertEqual(result.responseMode, .jsonObject)
        XCTAssertGreaterThan(result.responseBytes, 0)

        let sent = await transport.lastRequest()
        let httpRequest = try XCTUnwrap(sent)
        XCTAssertEqual(
            httpRequest.url?.absoluteString,
            "https://fixture.example/v1/chat/completions")
        XCTAssertEqual(
            httpRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-test-openai")
        let body = try Self.requestJSONObject(httpRequest)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        let system = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(system.contains(AIStudyPrompt.promptVersion))
        let user = try XCTUnwrap(messages[1]["content"] as? String)
        XCTAssertTrue(user.contains("<ai-study-request>"))
        XCTAssertTrue(user.contains(request.requestID))
        XCTAssertTrue(user.contains("</ai-study-request>"))
        // 凭据只在协议头，绝不进 body。
        let rawBody = String(
            data: try XCTUnwrap(httpRequest.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(rawBody.contains("sk-test-openai"))
        XCTAssertEqual(
            (body["response_format"] as? [String: Any])?["type"] as? String,
            "json_object")
    }

    /// Anthropic Messages（claude preset + promptedJSON）：
    /// 同一请求同样过 validator 得合法 outcome；x-api-key 头鉴权。
    func testAnthropicSuccessPath() async throws {
        let config = try Self.claudeConfig()
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
            Self.token("t02", candidates: [Self.candidate(200, senses: [2001])]),
        ])
        let content = Self.studyResponseJSON(request: request, words: [
            Self.word("t01", status: "resolved", entryID: 100, senseID: 1001,
                      confidence: 0.95),
            Self.word("t02", status: "resolved", entryID: 200, senseID: 2001,
                      confidence: 0.9),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.anthropic(text: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "claude-key")

        XCTAssertEqual(result.outcome.lexicalStatus, .resolved)
        XCTAssertEqual(result.outcome.aiResolvedCount, 2)
        XCTAssertEqual(result.responseMode, .promptedJSON)

        let sent = await transport.lastRequest()
        let httpRequest = try XCTUnwrap(sent)
        XCTAssertEqual(
            httpRequest.url?.absoluteString,
            "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(
            httpRequest.value(forHTTPHeaderField: "x-api-key"), "claude-key")
        XCTAssertEqual(
            httpRequest.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01")
        let body = try Self.requestJSONObject(httpRequest)
        // Anthropic：system 是顶层字段，与 OpenAI 渲染同源同文本。
        XCTAssertEqual(
            body["system"] as? String,
            AIStudyPrompt.render(for: request).systemPrompt)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(
            messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(
            blocks[0]["text"] as? String,
            AIStudyPrompt.render(for: request).userPrompt)
        XCTAssertNil(body["response_format"], "promptedJSON 不发 response_format")
    }

    /// Gemini generateContent（gemini preset + promptedJSON）：
    /// x-goog-api-key 头 + 模型在 URL 路径中。
    func testGeminiSuccessPath() async throws {
        let config = try Self.geminiConfig()
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
        ])
        let content = Self.studyResponseJSON(request: request, words: [
            Self.word("t01", status: "resolved", entryID: 100, senseID: 1001,
                      confidence: 0.9),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.gemini(text: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "gemini-key")

        XCTAssertEqual(result.outcome.lexicalStatus, .resolved)

        let sent = await transport.lastRequest()
        let httpRequest = try XCTUnwrap(sent)
        XCTAssertEqual(
            httpRequest.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertEqual(
            httpRequest.value(forHTTPHeaderField: "x-goog-api-key"),
            "gemini-key")
        XCTAssertNil(httpRequest.value(forHTTPHeaderField: "Authorization"))
        let body = try Self.requestJSONObject(httpRequest)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertTrue(
            (parts[0]["text"] as? String)?.contains("<ai-study-request>")
                == true)
    }

    /// jsonSchema 模式：`response_format.json_schema` 携带契约名与
    /// §3.2 schema——strict 路径同样过本地 validator。
    func testJSONSchemaModeSendsNamedContract() async throws {
        let config = Self.customConfig(mode: .jsonSchema)
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
        ])
        let content = Self.studyResponseJSON(request: request, words: [
            Self.word("t01", status: "resolved", entryID: 100, senseID: 1001,
                      confidence: 0.9),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "key")
        XCTAssertEqual(result.outcome.lexicalStatus, .resolved)

        let sent = await transport.lastRequest()
        let body = try Self.requestJSONObject(try XCTUnwrap(sent))
        let responseFormat = try XCTUnwrap(
            body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(
            responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["name"] as? String, "oboe_ai_study_v1")
    }

    // MARK: - 能力 / 元数据 fail-fast（不发请求）

    /// 供应商能力不符（claude 协议能力只有 promptedJSON，强行
    /// jsonObject）→ `unsupportedConfiguration`，transport 零请求。
    func testCapabilityMismatchFailsBeforeSending() async throws {
        let config = try Self.claudeConfig(modeOverride: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: "{}"))
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected unsupportedConfiguration")
        } catch let error as AIStudyResolverError {
            guard case .unsupportedConfiguration(let reason) = error else {
                return XCTFail("Expected unsupportedConfiguration, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty, "应带可操作提示")
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0, "fail-fast 不得发出任何请求")
    }

    /// 请求元数据 ↔ 当前配置不一致 → fail-fast（requestHash 必须如实
    /// 描述发送方；model/responseMode/endpoint/providerKind 四种漂移）。
    func testMetadataMismatchFailsBeforeSending() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: "{}"))
        let client = AIStudyResolverClient(transport: transport)

        var mismatches: [(String, (inout AIStudyRequestMetadata) -> Void)] = []
        mismatches.append(("model", { $0 = .init(
            dictionaryDatasetVersion: $0.dictionaryDatasetVersion,
            morphologyVersion: $0.morphologyVersion,
            parserVersion: $0.parserVersion, osBuild: $0.osBuild,
            providerKind: $0.providerKind,
            endpointFingerprint: $0.endpointFingerprint,
            model: "other-model", responseMode: $0.responseMode,
            promptVersion: $0.promptVersion, language: $0.language,
            generationParameters: $0.generationParameters) }))
        mismatches.append(("responseMode", { $0 = .init(
            dictionaryDatasetVersion: $0.dictionaryDatasetVersion,
            morphologyVersion: $0.morphologyVersion,
            parserVersion: $0.parserVersion, osBuild: $0.osBuild,
            providerKind: $0.providerKind,
            endpointFingerprint: $0.endpointFingerprint,
            model: $0.model, responseMode: "prompted_json",
            promptVersion: $0.promptVersion, language: $0.language,
            generationParameters: $0.generationParameters) }))
        mismatches.append(("endpoint", { $0 = .init(
            dictionaryDatasetVersion: $0.dictionaryDatasetVersion,
            morphologyVersion: $0.morphologyVersion,
            parserVersion: $0.parserVersion, osBuild: $0.osBuild,
            providerKind: $0.providerKind,
            endpointFingerprint: "https://other.example/v1",
            model: $0.model, responseMode: $0.responseMode,
            promptVersion: $0.promptVersion, language: $0.language,
            generationParameters: $0.generationParameters) }))
        mismatches.append(("providerKind", { $0 = .init(
            dictionaryDatasetVersion: $0.dictionaryDatasetVersion,
            morphologyVersion: $0.morphologyVersion,
            parserVersion: $0.parserVersion, osBuild: $0.osBuild,
            providerKind: "other-provider",
            endpointFingerprint: $0.endpointFingerprint,
            model: $0.model, responseMode: $0.responseMode,
            promptVersion: $0.promptVersion, language: $0.language,
            generationParameters: $0.generationParameters) }))

        for (name, mutate) in mismatches {
            var metadata = Self.metadata(for: config)
            mutate(&metadata)
            let request = Self.makeRequest(metadata: metadata, tokens: [])
            do {
                _ = try await client.resolve(
                    request, configuration: config, credential: "key")
                XCTFail("\(name): expected unsupportedConfiguration")
            } catch let error as AIStudyResolverError {
                guard case .unsupportedConfiguration = error else {
                    return XCTFail("\(name): got \(error)")
                }
            }
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0, "所有元数据漂移都应 fail-fast")
    }

    /// 注入的 prompt 版本与请求元数据不符 → fail-fast。
    func testPromptVersionMismatchFailsBeforeSending() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: "{}"))
        let client = AIStudyResolverClient(transport: transport)
        let rendered = AIStudyPrompt.render(for: request)
        let tampered = AIStudyPrompt.Messages(
            promptVersion: "ai-study-prompt-v0",
            systemPrompt: rendered.systemPrompt,
            userPrompt: rendered.userPrompt)

        do {
            _ = try await client.resolve(
                request, prompt: tampered,
                configuration: config, credential: "key")
            XCTFail("Expected unsupportedConfiguration")
        } catch let error as AIStudyResolverError {
            guard case .unsupportedConfiguration = error else {
                return XCTFail("got \(error)")
            }
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - 429：Retry-After 秒数 / HTTP-date / 缺失

    func testRateLimitedWithSecondsHeader() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.http(
                statusCode: 429, headers: ["Retry-After": "7"]))
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected rateLimited")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 7))
        }
    }

    /// HTTP-date 形态：`Retry-After: <now+45s 的 IMF-fixdate>` →
    /// 解析为 45 秒（注入固定时钟保证确定性）。
    func testRateLimitedWithHTTPDateHeader() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let fixedNow = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.http(
                statusCode: 429,
                headers: [
                    "Retry-After": AIStudyFakeResponses.httpDate(
                        fixedNow.addingTimeInterval(45))
                ]))
        let client = AIStudyResolverClient(
            transport: transport, now: { fixedNow })

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected rateLimited")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 45))
        }
    }

    func testRateLimitedWithoutHeader() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.http(statusCode: 429))
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected rateLimited")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .rateLimited(retryAfter: nil))
        }
    }

    // MARK: - 401/403/402 → authFailed（停派信号）

    func testAuthFailuresMapToAuthFailed() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        for statusCode in [401, 403, 402] {
            let transport = AIStudyFakeTransport(
                response: AIStudyFakeResponses.http(statusCode: statusCode))
            let client = AIStudyResolverClient(transport: transport)
            do {
                _ = try await client.resolve(
                    request, configuration: config, credential: "key")
                XCTFail("HTTP \(statusCode): expected authFailed")
            } catch let error as AIStudyResolverError {
                XCTAssertEqual(error, .authFailed,
                               "HTTP \(statusCode) 应映射 authFailed")
            }
        }
    }

    /// 本地凭据非法（控制字符）→ executor 在发请求前抛
    /// invalidCredential → authFailed；同样零请求。
    func testInvalidCredentialMapsToAuthFailedWithoutSending() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: "{}"))
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "bad\nkey")
            XCTFail("Expected authFailed")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .authFailed)
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }

    // MARK: - retryable：timeout / 5xx / 网络错误 / adapter 层非法响应

    func testRetryableMappings() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])

        // URLError → AIHTTPSupport.map → retryable（携带映射后码位）。
        let urlErrorCases: [(URLError.Code, AIConnectionError)] = [
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .networkUnavailable),
            (.cannotFindHost, .connectionFailed),
        ]
        for (code, expected) in urlErrorCases {
            let transport = AIStudyFakeTransport(error: URLError(code))
            let client = AIStudyResolverClient(transport: transport)
            do {
                _ = try await client.resolve(
                    request, configuration: config, credential: "key")
                XCTFail("\(code): expected retryable")
            } catch let error as AIStudyResolverError {
                XCTAssertEqual(error, .retryable(expected),
                               "URLError \(code) 应映射 retryable(\(expected))")
            }
        }

        // 5xx → retryable(.serviceUnavailable)。
        for statusCode in [500, 503] {
            let transport = AIStudyFakeTransport(
                response: AIStudyFakeResponses.http(statusCode: statusCode))
            let client = AIStudyResolverClient(transport: transport)
            do {
                _ = try await client.resolve(
                    request, configuration: config, credential: "key")
                XCTFail("HTTP \(statusCode): expected retryable")
            } catch let error as AIStudyResolverError {
                XCTAssertEqual(
                    error, .retryable(.serviceUnavailable(statusCode: statusCode)))
            }
        }
    }

    /// 200 但 body 非协议信封 → adapter 解码失败 .malformedResponse →
    /// retryable（传输层正常、内容层坏数据，§7 malformed 不猜半截，
    /// 该档由 §9.2「有限重试」承接）。
    func testAdapterMalformedEnvelopeIsRetryable() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.http(
                statusCode: 200, body: "not a provider envelope"))
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected retryable")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .retryable(.malformedResponse))
        }
    }

    /// OpenAI finish_reason=length → .truncatedResponse → retryable。
    func testTruncatedResponseIsRetryable() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(
                content: "{}", finishReason: "length"))
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected retryable")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .retryable(.truncatedResponse))
        }
    }

    // MARK: - 取消传播

    /// 慢响应 fake + 外部取消 → `.cancelled`（§9.2：cancel 网络 Task）。
    func testCancellationPropagates() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            steps: [.suspendUntilCancelled])
        let client = AIStudyResolverClient(transport: transport)

        let task = Task<AIStudyResolverResult, Error> {
            try await client.resolve(
                request, configuration: config, credential: "key")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancelled")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - 跨源重定向（沿用现有分类）

    /// transport 直接抛 `AIConnectionError.redirectRejected`（与
    /// `URLSessionAIHTTPTransport` 同源拒同形）→ `.redirectRejected`。
    func testCrossOriginRedirectClassification() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])
        let transport = AIStudyFakeTransport(
            error: AIConnectionError.redirectRejected)
        let client = AIStudyResolverClient(transport: transport)

        do {
            _ = try await client.resolve(
                request, configuration: config, credential: "key")
            XCTFail("Expected redirectRejected")
        } catch let error as AIStudyResolverError {
            XCTAssertEqual(error, .redirectRejected)
        }
    }

    // MARK: - validator 全链（fake → adapter → validator → outcome）

    /// 非法候选（entryID ∉ 该 token 候选集）→ rejected，不形成
    /// selected；同块其他合法项保留（§3.3/§7 单项层）。
    func testValidatorChainRejectsIllegalCandidate() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
            Self.token("t02", candidates: [Self.candidate(200, senses: [2001])]),
        ])
        let content = Self.studyResponseJSON(request: request, words: [
            Self.word("t01", status: "resolved", entryID: 999, senseID: 1001,
                      confidence: 0.9),
            Self.word("t02", status: "resolved", entryID: 200, senseID: 2001,
                      confidence: 0.9),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "key")

        let t01 = result.outcome.resolutions.first { $0.tokenKey == "t01" }
        XCTAssertEqual(t01?.status, .rejected)
        XCTAssertEqual(t01?.reasonCode, .candidateNotInSet)
        XCTAssertNil(t01?.selected)
        let t02 = result.outcome.resolutions.first { $0.tokenKey == "t02" }
        XCTAssertEqual(t02?.status, .aiResolved)
        XCTAssertEqual(result.outcome.lexicalStatus, .partial)
        XCTAssertEqual(result.outcome.invalidItemCount, 1)
    }

    /// 重复 tokenID → 该 token 整体降级 unresolved（不
    /// last-write-wins）；其余保留。
    func testValidatorChainDuplicateTokenDowngrades() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
            Self.token("t02", candidates: [Self.candidate(200, senses: [2001])]),
        ])
        let content = Self.studyResponseJSON(request: request, words: [
            Self.word("t01", status: "resolved", entryID: 100, senseID: 1001,
                      confidence: 0.9),
            Self.word("t01", status: "resolved", entryID: 100, senseID: 1001,
                      confidence: 0.8),
            Self.word("t02", status: "resolved", entryID: 200, senseID: 2001,
                      confidence: 0.9),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "key")

        let t01 = result.outcome.resolutions.first { $0.tokenKey == "t01" }
        XCTAssertEqual(t01?.status, .unresolved)
        XCTAssertEqual(t01?.reasonCode, .duplicateTokenID)
        XCTAssertEqual(result.outcome.duplicateTokenCount, 1)
        let t02 = result.outcome.resolutions.first { $0.tokenKey == "t02" }
        XCTAssertEqual(t02?.status, .aiResolved)
    }

    /// 坏译文（trim 后空）→ translationStatus .failed，词义结果保留。
    func testValidatorChainBadTranslationKeepsResolutions() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
        ])
        let content = Self.studyResponseJSON(
            request: request, translation: "   ", words: [
                Self.word("t01", status: "resolved", entryID: 100,
                          senseID: 1001, confidence: 0.9),
            ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(content: content))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "key")

        XCTAssertEqual(result.outcome.translationStatus, .failed)
        XCTAssertNil(result.outcome.translation)
        XCTAssertEqual(result.outcome.lexicalStatus, .resolved)
    }

    /// 模型输出完全非 JSON → 外层拒：lexicalStatus .failed +
    /// envelopeRejection .malformedJSON（返回 outcome 而非 throw——
    /// 传输成功、内容坏数据由 validator 归因）。
    func testMalformedModelOutputFailsBlock() async throws {
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [
            Self.token("t01", candidates: [Self.candidate(100, senses: [1001])]),
        ])
        let transport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(
                content: "this is not json"))
        let client = AIStudyResolverClient(transport: transport)

        let result = try await client.resolve(
            request, configuration: config, credential: "key")

        XCTAssertEqual(result.outcome.lexicalStatus, .failed)
        XCTAssertEqual(result.outcome.envelopeRejection, .malformedJSON)
        XCTAssertTrue(result.outcome.resolutions.isEmpty)
    }

    /// promptedJSON 路径（Anthropic/Gemini）同样过 validator：
    /// OOV token 被造伪候选 → rejected（§7：不因模式省略本地校验）。
    func testPromptedJSONPathsStillValidate() async throws {
        // Anthropic leg
        let claudeConfig = try Self.claudeConfig()
        let claudeRequest = Self.makeRequest(
            configuration: claudeConfig, tokens: [
                Self.token("t01"), // OOV：candidates=[]
                Self.token("t02",
                           candidates: [Self.candidate(200, senses: [2001])]),
            ])
        let claudeContent = Self.studyResponseJSON(
            request: claudeRequest, words: [
                Self.word("t01", status: "resolved", entryID: 200,
                          senseID: 2001, confidence: 0.99), // 伪候选
                Self.word("t02", status: "resolved", entryID: 200,
                          senseID: 2001, confidence: 0.9),
            ])
        let claudeTransport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.anthropic(text: claudeContent))
        let claudeResult = try await AIStudyResolverClient(
            transport: claudeTransport
        ).resolve(
            claudeRequest, configuration: claudeConfig, credential: "key")

        let t01 = claudeResult.outcome.resolutions.first {
            $0.tokenKey == "t01" }
        XCTAssertEqual(t01?.status, .rejected)
        XCTAssertEqual(t01?.reasonCode, .candidateNotInSet)

        // Gemini leg
        let geminiConfig = try Self.geminiConfig()
        let geminiRequest = Self.makeRequest(
            configuration: geminiConfig, tokens: [
                Self.token("t01"),
                Self.token("t02",
                           candidates: [Self.candidate(200, senses: [2001])]),
            ])
        let geminiContent = Self.studyResponseJSON(
            request: geminiRequest, words: [
                Self.word("t01", status: "resolved", entryID: 200,
                          senseID: 2001, confidence: 0.99),
                Self.word("t02", status: "resolved", entryID: 200,
                          senseID: 2001, confidence: 0.9),
            ])
        let geminiTransport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.gemini(text: geminiContent))
        let geminiResult = try await AIStudyResolverClient(
            transport: geminiTransport
        ).resolve(
            geminiRequest, configuration: geminiConfig, credential: "key")

        let g01 = geminiResult.outcome.resolutions.first {
            $0.tokenKey == "t01" }
        XCTAssertEqual(g01?.status, .rejected)
        XCTAssertEqual(g01?.reasonCode, .candidateNotInSet)
    }

    // MARK: - 无 Key 泄漏

    /// 哨兵凭据不出现在：请求 body、请求 URL、错误对象文本、
    /// localizedDescription。成功/失败两路都断言。
    func testNoKeyLeakage() async throws {
        let secret = "sk-SENTINEL-9f8e7d"
        let config = Self.customConfig(mode: .jsonObject)
        let request = Self.makeRequest(configuration: config, tokens: [])

        // 成功路：body/URL 不含（凭据只应出现在协议头）。
        let okTransport = AIStudyFakeTransport(
            response: AIStudyFakeResponses.openAI(
                content: Self.studyResponseJSON(request: request, words: [])))
        let client = AIStudyResolverClient(transport: okTransport)
        _ = try await client.resolve(
            request, configuration: config, credential: secret)
        let sent = await okTransport.lastRequest()
        let httpRequest = try XCTUnwrap(sent)
        let bodyString = String(
            data: try XCTUnwrap(httpRequest.httpBody), encoding: .utf8) ?? ""
        XCTAssertFalse(bodyString.contains(secret))
        XCTAssertFalse(
            httpRequest.url?.absoluteString.contains(secret) ?? false)

        // 失败路：错误对象文本/描述不含哨兵。
        for response in [
            AIStudyFakeResponses.http(statusCode: 401),
            AIStudyFakeResponses.http(
                statusCode: 429, headers: ["Retry-After": "3"]),
            AIStudyFakeResponses.http(statusCode: 500),
        ] {
            let transport = AIStudyFakeTransport(response: response)
            let client = AIStudyResolverClient(transport: transport)
            do {
                _ = try await client.resolve(
                    request, configuration: config, credential: secret)
                XCTFail("expected throw")
            } catch {
                XCTAssertFalse(String(describing: error).contains(secret))
                XCTAssertFalse(
                    error.localizedDescription.contains(secret))
            }
        }
    }

    /// 代码层面断言 client 不持有任何 Keychain/凭据存储——
    /// 凭据仅逐次以参数注入，无第二套存储通道。
    func testClientHoldsNoCredentialStore() {
        let client = AIStudyResolverClient(
            transport: AIStudyFakeTransport(
                response: AIStudyFakeResponses.http(statusCode: 200)))
        for child in Mirror(reflecting: client).children {
            let typeName = String(describing: type(of: child.value))
            XCTAssertFalse(typeName.contains("Keychain"),
                           "client 不得持有 Keychain 存储（\(typeName)）")
            XCTAssertFalse(typeName.contains("CredentialStore"),
                           "client 不得持有凭据存储（\(typeName)）")
        }
        // executor 内部字段同样不得有存储型成员。
        for child in Mirror(reflecting: client).children
            where String(describing: type(of: child.value))
                .contains("Executor") {
            for inner in Mirror(reflecting: child.value).children {
                let typeName = String(describing: type(of: inner.value))
                XCTAssertFalse(typeName.contains("Keychain"))
                XCTAssertFalse(typeName.contains("CredentialStore"))
            }
        }
    }

    // MARK: - Fixtures

    private static func customConfig(
        mode: AIResponseFormatMode
    ) -> ResolvedAIConfiguration {
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

    /// claude preset → resolved（responseFormatMode 被 preset 锁定为
    /// promptedJSON）；`modeOverride` 用成员构造绕过 preset 锁，
    /// 制造能力不符场景。
    private static func claudeConfig(
        modeOverride: AIResponseFormatMode? = nil
    ) throws -> ResolvedAIConfiguration {
        var draft = AIConfigurationDraft.preset(.claude)
        draft.isEnabled = true
        draft.modelID = "claude-test-model"
        let resolved = try AIConfigurationValidator.resolve(
            draft, credentialID: UUID())
        guard let modeOverride else { return resolved }
        return ResolvedAIConfiguration(
            isEnabled: resolved.isEnabled,
            serviceKind: resolved.serviceKind,
            serviceName: resolved.serviceName,
            baseURL: resolved.baseURL,
            modelID: resolved.modelID,
            responseFormatMode: modeOverride,
            credentialReference: resolved.credentialReference
        )
    }

    private static func geminiConfig() throws -> ResolvedAIConfiguration {
        var draft = AIConfigurationDraft.preset(.gemini)
        draft.isEnabled = true
        draft.modelID = "gemini-2.5-flash"
        return try AIConfigurationValidator.resolve(draft, credentialID: UUID())
    }

    /// 与生产接线同口径的元数据构造：providerKind/endpointFingerprint/
    /// model/responseMode 全部从配置派生——requestHash 的真实性
    /// 依赖这一步与发送方一致。
    private static func metadata(
        for configuration: ResolvedAIConfiguration
    ) -> AIStudyRequestMetadata {
        AIStudyRequestMetadata(
            dictionaryDatasetVersion: "2026.09.24-1",
            morphologyVersion: "morph/1",
            parserVersion: "parser/1",
            osBuild: "25A",
            providerKind: configuration.serviceKind.rawValue,
            endpointFingerprint: AIStudyEndpointFingerprint.normalize(
                configuration.baseURL.absoluteString),
            model: configuration.modelID,
            responseMode: configuration.responseFormatMode.rawValue,
            promptVersion: AIStudyPrompt.promptVersion,
            language: "zho",
            generationParameters: [
                "maxOutputTokens": "4000"
            ]
        )
    }

    private static func token(
        _ id: String,
        candidates: [AIStudyCandidate] = []
    ) -> AIStudyToken {
        AIStudyToken(
            tokenID: id, surface: "表", lemma: "表", reading: nil,
            posFamily: "noun", utf16Start: 0, utf16Length: 1,
            candidates: candidates)
    }

    private static func candidate(
        _ entryID: Int64, senses: [Int64]
    ) -> AIStudyCandidate {
        AIStudyCandidate(
            entryID: entryID, lemma: "表", reading: "ひょう",
            matchedForm: "表", matchedReading: "ひょう",
            senses: senses.map {
                AIStudyCandidateSense(
                    senseID: $0, enGlosses: ["g\($0)"],
                    restrictedForms: [], restrictedReadings: [])
            })
    }

    /// 定稿请求：走真实 serializer 生成 requestID/candidateSetHash/
    /// requestHash——与 planner 产物同形，不是手工填充的近似物。
    private static func makeRequest(
        configuration: ResolvedAIConfiguration,
        tokens: [AIStudyToken],
        wantsTranslation: Bool = true
    ) -> AIStudyRequest {
        makeRequest(
            metadata: metadata(for: configuration),
            tokens: tokens, wantsTranslation: wantsTranslation)
    }

    private static func makeRequest(
        metadata: AIStudyRequestMetadata,
        tokens: [AIStudyToken],
        wantsTranslation: Bool = true
    ) -> AIStudyRequest {
        let blockKey = "doc:test:rev:1:p:0#r0-1"
        let block = AIStudyBlock(
            blockKey: blockKey,
            targetText: "表", context: "",
            targetUTF16Start: 0, targetUTF16Length: 1,
            tokens: tokens,
            candidateSetHash: AIStudyRequestSerializer.candidateSetHash(
                tokens: tokens),
            wantsTranslation: wantsTranslation)
        let unsigned = AIStudyRequest(
            requestID: AIStudyRequestSerializer.requestID(
                blockKey: blockKey),
            blocks: [block],
            metadata: metadata,
            requestHash: "")
        return AIStudyRequest(
            requestID: unsigned.requestID,
            blocks: unsigned.blocks,
            metadata: metadata,
            requestHash: AIStudyRequestSerializer.requestHash(unsigned))
    }

    /// §3.2 形态的响应 payload（模型文本——再进协议信封）。
    private static func studyResponseJSON(
        request: AIStudyRequest,
        translation: Any? = "译文",
        words: [[String: Any]]
    ) -> String {
        let object: [String: Any] = [
            "schemaVersion": request.schemaVersion,
            "requestID": request.requestID,
            "translation": translation ?? NSNull(),
            "words": words,
        ]
        return String(
            data: try! JSONSerialization.data(withJSONObject: object),
            encoding: .utf8)!
    }

    private static func word(
        _ tokenID: String, status: String,
        entryID: Int64? = nil, senseID: Int64? = nil,
        confidence: Double? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "tokenID": tokenID, "status": status,
        ]
        dict["entryID"] = entryID.map { NSNumber(value: $0) } ?? NSNull()
        dict["senseID"] = senseID.map { NSNumber(value: $0) } ?? NSNull()
        dict["confidence"] = confidence.map { NSNumber(value: $0) } ?? NSNull()
        return dict
    }

    private static func requestJSONObject(
        _ request: URLRequest
    ) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
    }
}
