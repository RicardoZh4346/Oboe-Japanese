import Foundation

/// API Key 在模型目录/执行请求中的携带方式。
public enum AIAPIKeyHeaderStyle: String, CaseIterable, Codable, Sendable {
    /// `Authorization: Bearer <key>`（OpenAI 兼容、DashScope、xAI）。
    case bearer = "bearer"
    /// `x-api-key: <key>`（Anthropic；另需 `anthropic-version`，由 protocolKind 决定）。
    case xAPIKey = "x_api_key"
    /// `x-goog-api-key: <key>`（Gemini）。
    case xGoogAPIKey = "x_goog_api_key"
}

/// 单个供应商预设：地址、线协议、模型列表路径与鉴权方式。
/// 预设不提供默认模型名——模型必须由用户从目录中选择（或自定义服务手动填写）。
public struct AIProviderPreset: Equatable, Sendable {
    public let serviceKind: AIServiceKind
    /// 界面显示名。
    public let displayName: String
    /// 规范化 HTTPS baseURL（无尾斜杠、无查询参数）。
    public let baseURL: String
    public let protocolKind: AIProtocolKind
    /// 模型列表路径，拼接到 `baseURL` 之后（如 `v1/models`）。
    public let modelListPath: String
    public let apiKeyHeaderStyle: AIAPIKeyHeaderStyle
    /// 预设供应商强制使用的响应格式模式（草稿中的值被忽略）。
    public let responseFormatMode: AIResponseFormatMode
    /// 面向用户的补充说明（如 Qwen 的地域绑定提示），可为空。
    public let note: String?
    /// 供应商能力声明；缺省按 `protocolKind` 推导，需偏离时显式传入。
    public let capabilities: AIProviderCapabilities

    public init(
        serviceKind: AIServiceKind,
        displayName: String,
        baseURL: String,
        protocolKind: AIProtocolKind,
        modelListPath: String,
        apiKeyHeaderStyle: AIAPIKeyHeaderStyle,
        responseFormatMode: AIResponseFormatMode,
        note: String? = nil,
        capabilities: AIProviderCapabilities? = nil
    ) {
        self.serviceKind = serviceKind
        self.displayName = displayName
        self.baseURL = baseURL
        self.protocolKind = protocolKind
        self.modelListPath = modelListPath
        self.apiKeyHeaderStyle = apiKeyHeaderStyle
        self.responseFormatMode = responseFormatMode
        self.note = note
        self.capabilities = capabilities ?? .defaults(for: protocolKind)
    }
}

/// 集中式供应商注册表：所有预设的地址、协议与显示名的唯一来源。
/// `custom` 没有预设，返回 nil——其地址与名称来自用户输入。
public enum AIProviderPresetRegistry {
    /// 与 `AIServiceKind` 声明顺序一致的预设列表（不含 custom）。
    public static let all: [AIProviderPreset] = [
        AIProviderPreset(
            serviceKind: .deepSeek,
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            protocolKind: .openAICompatible,
            modelListPath: "models",
            apiKeyHeaderStyle: .bearer,
            responseFormatMode: .jsonObject
        ),
        AIProviderPreset(
            serviceKind: .kimi,
            displayName: "Kimi（Moonshot AI）",
            baseURL: "https://api.moonshot.cn/v1",
            protocolKind: .openAICompatible,
            modelListPath: "models",
            apiKeyHeaderStyle: .bearer,
            responseFormatMode: .jsonObject
        ),
        AIProviderPreset(
            serviceKind: .glm,
            displayName: "GLM（智谱）",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            protocolKind: .openAICompatible,
            modelListPath: "models",
            apiKeyHeaderStyle: .bearer,
            responseFormatMode: .jsonObject
        ),
        AIProviderPreset(
            serviceKind: .openAI,
            displayName: "ChatGPT / OpenAI API",
            baseURL: "https://api.openai.com/v1",
            protocolKind: .openAICompatible,
            modelListPath: "models",
            apiKeyHeaderStyle: .bearer,
            responseFormatMode: .jsonObject
        ),
        AIProviderPreset(
            serviceKind: .claude,
            displayName: "Claude（Anthropic）",
            baseURL: "https://api.anthropic.com",
            protocolKind: .anthropic,
            modelListPath: "v1/models",
            apiKeyHeaderStyle: .xAPIKey,
            responseFormatMode: .promptedJSON
        ),
        AIProviderPreset(
            serviceKind: .gemini,
            displayName: "Gemini（Google）",
            baseURL: "https://generativelanguage.googleapis.com",
            protocolKind: .gemini,
            modelListPath: "v1beta/models",
            apiKeyHeaderStyle: .xGoogAPIKey,
            responseFormatMode: .promptedJSON
        ),
        AIProviderPreset(
            serviceKind: .qwen,
            displayName: "Qwen（通义千问）",
            baseURL: "https://dashscope.aliyuncs.com",
            protocolKind: .dashScope,
            modelListPath: "api/v1/models",
            apiKeyHeaderStyle: .bearer,
            responseFormatMode: .promptedJSON,
            note: "API Key 与地域绑定，默认北京域名，可切换新加坡/美国或专属域名（使用自定义兼容服务）。"
        ),
        AIProviderPreset(
            serviceKind: .grok,
            displayName: "Grok（xAI）",
            baseURL: "https://api.x.ai/v1",
            protocolKind: .xAI,
            modelListPath: "language-models",
            apiKeyHeaderStyle: .bearer,
            responseFormatMode: .jsonObject
        )
    ]

    public static func preset(for kind: AIServiceKind) -> AIProviderPreset? {
        all.first { $0.serviceKind == kind }
    }

    /// 供应商能力查询：预设取注册表声明；custom 无预设，按 OpenAI 兼容
    /// 默认能力处理（目录/生成/三种输出模式）——与 adapter 分发语义一致。
    public static func capabilities(for kind: AIServiceKind) -> AIProviderCapabilities {
        preset(for: kind)?.capabilities ?? .openAICompatible
    }
}
