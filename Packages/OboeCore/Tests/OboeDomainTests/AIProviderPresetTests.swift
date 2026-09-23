import Foundation
import XCTest
@testable import OboeDomain

final class AIProviderPresetTests: XCTestCase {
    func testEveryNonCustomKindHasPresetAndCustomHasNone() {
        for kind in AIServiceKind.allCases {
            if kind == .custom {
                XCTAssertNil(AIProviderPresetRegistry.preset(for: kind))
            } else {
                XCTAssertNotNil(
                    AIProviderPresetRegistry.preset(for: kind),
                    "\(kind) 缺少预设"
                )
            }
        }
        XCTAssertEqual(AIProviderPresetRegistry.all.count, AIServiceKind.allCases.count - 1)
    }

    func testPresetEndpointsProtocolsAndDisplayNames() {
        func preset(_ kind: AIServiceKind) -> AIProviderPreset {
            guard let preset = AIProviderPresetRegistry.preset(for: kind) else {
                XCTFail("missing preset for \(kind)")
                fatalError()
            }
            return preset
        }

        let deepSeek = preset(.deepSeek)
        XCTAssertEqual(deepSeek.displayName, "DeepSeek")
        XCTAssertEqual(deepSeek.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(deepSeek.protocolKind, .openAICompatible)
        XCTAssertEqual(deepSeek.modelListPath, "models")
        XCTAssertEqual(deepSeek.apiKeyHeaderStyle, .bearer)

        let kimi = preset(.kimi)
        XCTAssertEqual(kimi.displayName, "Kimi（Moonshot AI）")
        XCTAssertEqual(kimi.baseURL, "https://api.moonshot.cn/v1")
        XCTAssertEqual(kimi.protocolKind, .openAICompatible)
        XCTAssertEqual(kimi.modelListPath, "models")

        let glm = preset(.glm)
        XCTAssertEqual(glm.displayName, "GLM（智谱）")
        XCTAssertEqual(glm.baseURL, "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(glm.protocolKind, .openAICompatible)
        XCTAssertEqual(glm.modelListPath, "models")

        let openAI = preset(.openAI)
        XCTAssertEqual(openAI.displayName, "ChatGPT / OpenAI API")
        XCTAssertEqual(openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(openAI.protocolKind, .openAICompatible)
        XCTAssertEqual(openAI.modelListPath, "models")

        let claude = preset(.claude)
        XCTAssertEqual(claude.displayName, "Claude（Anthropic）")
        XCTAssertEqual(claude.baseURL, "https://api.anthropic.com")
        XCTAssertEqual(claude.protocolKind, .anthropic)
        XCTAssertEqual(claude.modelListPath, "v1/models")
        XCTAssertEqual(claude.apiKeyHeaderStyle, .xAPIKey)

        let gemini = preset(.gemini)
        XCTAssertEqual(gemini.displayName, "Gemini（Google）")
        XCTAssertEqual(gemini.baseURL, "https://generativelanguage.googleapis.com")
        XCTAssertEqual(gemini.protocolKind, .gemini)
        XCTAssertEqual(gemini.modelListPath, "v1beta/models")
        XCTAssertEqual(gemini.apiKeyHeaderStyle, .xGoogAPIKey)

        let qwen = preset(.qwen)
        XCTAssertEqual(qwen.displayName, "Qwen（通义千问）")
        XCTAssertEqual(qwen.baseURL, "https://dashscope.aliyuncs.com")
        XCTAssertEqual(qwen.protocolKind, .dashScope)
        XCTAssertEqual(qwen.modelListPath, "api/v1/models")
        XCTAssertEqual(qwen.apiKeyHeaderStyle, .bearer)
        XCTAssertTrue(qwen.note?.contains("地域") == true)

        let grok = preset(.grok)
        XCTAssertEqual(grok.displayName, "Grok（xAI）")
        XCTAssertEqual(grok.baseURL, "https://api.x.ai/v1")
        XCTAssertEqual(grok.protocolKind, .xAI)
        XCTAssertEqual(grok.modelListPath, "language-models")
        XCTAssertEqual(grok.apiKeyHeaderStyle, .bearer)
    }

    func testPresetBaseURLsAreNormalizedHTTPSWithoutQueryOrCredentials() {
        for preset in AIProviderPresetRegistry.all {
            let components = URLComponents(string: preset.baseURL)
            XCTAssertEqual(components?.scheme, "https", preset.serviceKind.rawValue)
            XCTAssertNil(components?.user)
            XCTAssertNil(components?.password)
            XCTAssertNil(components?.query)
            XCTAssertNil(components?.fragment)
            XCTAssertFalse(components?.host?.isEmpty != false, preset.serviceKind.rawValue)
            XCTAssertFalse(preset.baseURL.hasSuffix("/"), preset.serviceKind.rawValue)
        }
    }

    func testNoPresetCarriesADefaultModelID() {
        for kind in AIServiceKind.allCases {
            let draft = AIConfigurationDraft.preset(kind)
            XCTAssertNil(draft.modelID, "\(kind) 预设不得带默认模型名")
            XCTAssertFalse(draft.isEnabled)
            XCTAssertEqual(draft.serviceKind, kind)
        }
        XCTAssertNil(AIConfigurationDraft.deepSeekDefault.modelID)
    }

    func testValidatorForcesPresetNameAndFormatButKeepsEditedHTTPSURL() throws {
        var draft = AIConfigurationDraft.preset(.claude)
        draft.serviceName = "随便写"
        draft.baseURL = "https://proxy.example.com/anthropic/"
        draft.responseFormatMode = .jsonSchema
        draft.modelID = "claude-sonnet-test"

        let configuration = try AIConfigurationValidator.validate(draft, credentialID: UUID())
        XCTAssertEqual(configuration.serviceName, "Claude（Anthropic）")
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://proxy.example.com/anthropic")
        XCTAssertEqual(configuration.responseFormatMode, .promptedJSON)
        XCTAssertEqual(configuration.modelID, "claude-sonnet-test")
    }

    /// 能力声明契约：所有预设都支持模型目录与生成（协议族↔能力的一致性
    /// 由该断言把守）；预设的强制 responseFormatMode 必须落在其能力集内；
    /// Anthropic/Gemini 协议没有 response_format，不得声明 jsonSchema/jsonObject；
    /// 本项目不支持流式。
    func testPresetCapabilitiesAreConsistentWithProtocolKind() {
        for preset in AIProviderPresetRegistry.all {
            let capabilities = preset.capabilities
            XCTAssertTrue(
                capabilities.supportsModelCatalog,
                "\(preset.serviceKind) 应支持模型目录"
            )
            XCTAssertTrue(
                capabilities.supportsGeneration,
                "\(preset.serviceKind) 应支持文本生成"
            )
            XCTAssertFalse(
                capabilities.supportsStreaming,
                "\(preset.serviceKind) 不支持流式"
            )
            XCTAssertTrue(
                capabilities.supportedOutputModes.contains(preset.responseFormatMode),
                "\(preset.serviceKind) 的强制模式必须在能力集内"
            )
            switch preset.protocolKind {
            case .anthropic, .gemini:
                XCTAssertEqual(
                    capabilities.supportedOutputModes,
                    [.promptedJSON],
                    "\(preset.serviceKind) 协议无 response_format，只支持提示词 JSON"
                )
            case .openAICompatible, .xAI, .dashScope:
                XCTAssertEqual(
                    capabilities.supportedOutputModes,
                    Set(AIResponseFormatMode.allCases),
                    "\(preset.serviceKind) 兼容 response_format，支持全部模式"
                )
            }
        }
    }

    /// custom 无预设：能力按 OpenAI 兼容默认处理（目录/生成/三种模式），
    /// 与 adapter 分发的 fallback 语义一致。
    func testCustomCapabilitiesFallBackToOpenAICompatibleDefaults() {
        let capabilities = AIProviderPresetRegistry.capabilities(for: .custom)
        XCTAssertTrue(capabilities.supportsModelCatalog)
        XCTAssertTrue(capabilities.supportsGeneration)
        XCTAssertFalse(capabilities.supportsStreaming)
        XCTAssertEqual(
            capabilities.supportedOutputModes,
            Set(AIResponseFormatMode.allCases)
        )
        for kind in AIServiceKind.allCases where kind != .custom {
            XCTAssertEqual(
                AIProviderPresetRegistry.capabilities(for: kind),
                AIProviderPresetRegistry.preset(for: kind)?.capabilities
            )
        }
    }

    func testServiceKindDisplayNamesComeFromRegistry() {
        XCTAssertEqual(AIServiceKind.openAI.displayName, "ChatGPT / OpenAI API")
        XCTAssertEqual(AIServiceKind.qwen.displayName, "Qwen（通义千问）")
        XCTAssertEqual(AIServiceKind.custom.displayName, "自定义兼容服务")
        XCTAssertEqual(AIServiceKind.allCases.count, 9)
    }
}
