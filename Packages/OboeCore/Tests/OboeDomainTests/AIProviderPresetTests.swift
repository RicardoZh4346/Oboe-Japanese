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

    func testServiceKindDisplayNamesComeFromRegistry() {
        XCTAssertEqual(AIServiceKind.openAI.displayName, "ChatGPT / OpenAI API")
        XCTAssertEqual(AIServiceKind.qwen.displayName, "Qwen（通义千问）")
        XCTAssertEqual(AIServiceKind.custom.displayName, "自定义兼容服务")
        XCTAssertEqual(AIServiceKind.allCases.count, 9)
    }
}
