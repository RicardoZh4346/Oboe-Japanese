import Foundation

/// 单个 AI 供应商的能力声明：模型目录、文本生成、结构化输出模式与流式。
/// 这是供应商能力的唯一事实源——Settings UI 的可选项、执行层的 fail-fast
/// 与契约测试都从这里取数，避免出现「UI 允许但协议发不出」的不一致。
public struct AIProviderCapabilities: Equatable, Sendable {
    /// 是否提供可拉取的模型目录（列出模型接口）。
    public let supportsModelCatalog: Bool
    /// 是否支持文本生成执行（chat completions / messages / generateContent）。
    public let supportsGeneration: Bool
    /// 协议层可落地的结构化输出模式集合。
    public let supportedOutputModes: Set<AIResponseFormatMode>
    /// 是否支持流式输出。本项目统一走非流式请求，恒为 false。
    public let supportsStreaming: Bool

    public init(
        supportsModelCatalog: Bool,
        supportsGeneration: Bool,
        supportedOutputModes: Set<AIResponseFormatMode>,
        supportsStreaming: Bool
    ) {
        self.supportsModelCatalog = supportsModelCatalog
        self.supportsGeneration = supportsGeneration
        self.supportedOutputModes = supportedOutputModes
        self.supportsStreaming = supportsStreaming
    }
}

extension AIProviderCapabilities {
    /// OpenAI 兼容线协议的默认能力（xAI/DashScope 兼容模式与自定义服务相同）：
    /// 目录 + 生成 + 全部三种输出模式（`response_format` 可落到线上）。
    public static let openAICompatible = AIProviderCapabilities(
        supportsModelCatalog: true,
        supportsGeneration: true,
        supportedOutputModes: Set(AIResponseFormatMode.allCases),
        supportsStreaming: false
    )

    /// 仅提示词 JSON 的能力集：协议层没有 `response_format` 类字段，
    /// 契约靠提示词与严格 decoder 保证（Anthropic Messages、Gemini 首版）。
    public static let promptedJSONOnly = AIProviderCapabilities(
        supportsModelCatalog: true,
        supportsGeneration: true,
        supportedOutputModes: [.promptedJSON],
        supportsStreaming: false
    )

    /// 按线协议族推导的默认能力；预设如需偏离可在注册表中显式覆盖。
    public static func defaults(for protocolKind: AIProtocolKind) -> AIProviderCapabilities {
        switch protocolKind {
        case .openAICompatible, .xAI, .dashScope:
            return .openAICompatible
        case .anthropic, .gemini:
            return .promptedJSONOnly
        }
    }
}
