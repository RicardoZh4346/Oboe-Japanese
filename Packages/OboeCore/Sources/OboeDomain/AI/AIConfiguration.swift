import Foundation

/// AI 服务供应商。`rawValue` 持久化在 `app_settings.ai_provider_id`，
/// 只能追加 case，不能改动既有 rawValue（v0.5 已写入 `deepseek` / `custom`）。
public enum AIServiceKind: String, CaseIterable, Codable, Sendable {
    case deepSeek = "deepseek"
    case kimi = "kimi"
    case glm = "glm"
    case openAI = "openai"
    case claude = "claude"
    case gemini = "gemini"
    case qwen = "qwen"
    case grok = "grok"
    case custom = "custom"

    public var displayName: String {
        AIProviderPresetRegistry.preset(for: self)?.displayName ?? "自定义兼容服务"
    }

    /// 预设供应商的地址、协议与响应格式一律以注册表为准；
    /// 只有自定义服务允许用户填写 baseURL / serviceName / responseFormatMode。
    public var isCustomEndpoint: Bool { self == .custom }
}

/// 供应商 API 的线协议族，决定模型列表/执行请求如何编码与解码。
public enum AIProtocolKind: String, CaseIterable, Codable, Sendable {
    /// OpenAI 兼容（`Authorization: Bearer`，`GET …/models` 返回 `data: [{id}]`）。
    case openAICompatible = "openai_compatible"
    /// Anthropic 原生（`x-api-key` + `anthropic-version`，`GET /v1/models`）。
    case anthropic = "anthropic"
    /// Google Gemini 原生（`x-goog-api-key`，`GET /v1beta/models`）。
    case gemini = "gemini"
    /// 阿里 DashScope 原生（`Authorization: Bearer`，`GET /api/v1/models`）。
    case dashScope = "dashscope"
    /// xAI 原生（`Authorization: Bearer`，`GET /v1/language-models`）。
    case xAI = "xai"
}

public enum AIResponseFormatMode: String, CaseIterable, Codable, Sendable {
    case jsonSchema = "json_schema"
    case jsonObject = "json_object"
    case promptedJSON = "prompted_json"

    public var displayName: String {
        switch self {
        case .jsonSchema: "JSON Schema"
        case .jsonObject: "JSON Object"
        case .promptedJSON: "仅提示返回 JSON"
        }
    }
}

/// 编辑中的 AI 配置。`modelID == nil` 是合法状态：表示"尚未选择模型"，
/// 不再用虚假的默认模型名占位。能否执行 AI 由 `ResolvedAIConfiguration` 保证。
public struct AIConfigurationDraft: Equatable, Sendable {
    public var isEnabled: Bool
    public var serviceKind: AIServiceKind
    public var serviceName: String
    public var baseURL: String
    public var modelID: String?
    public var responseFormatMode: AIResponseFormatMode

    public init(
        isEnabled: Bool,
        serviceKind: AIServiceKind,
        serviceName: String,
        baseURL: String,
        modelID: String?,
        responseFormatMode: AIResponseFormatMode = .jsonObject
    ) {
        self.isEnabled = isEnabled
        self.serviceKind = serviceKind
        self.serviceName = serviceName
        self.baseURL = baseURL
        self.modelID = modelID
        self.responseFormatMode = responseFormatMode
    }

    public init(configuration: AIConfiguration) {
        self.init(
            isEnabled: configuration.isEnabled,
            serviceKind: configuration.serviceKind,
            serviceName: configuration.serviceName,
            baseURL: configuration.baseURL.absoluteString,
            modelID: configuration.modelID,
            responseFormatMode: configuration.responseFormatMode
        )
    }

    /// 按供应商生成空白草稿：预设服务使用注册表中的地址与名称，
    /// 不携带任何默认模型名——模型必须由用户从目录中选择或（自定义）填写。
    public static func preset(_ kind: AIServiceKind) -> AIConfigurationDraft {
        let preset = AIProviderPresetRegistry.preset(for: kind)
        return AIConfigurationDraft(
            isEnabled: false,
            serviceKind: kind,
            serviceName: preset?.displayName ?? "",
            baseURL: preset?.baseURL ?? "",
            modelID: nil,
            responseFormatMode: preset?.responseFormatMode ?? .jsonObject
        )
    }

    /// v0.5 兼容入口：默认草稿即 DeepSeek 预设（不含默认模型名）。
    public static let deepSeekDefault = AIConfigurationDraft.preset(.deepSeek)
}

public struct AICredentialReference: Equatable, Hashable, Sendable {
    public let id: UUID
    public let serviceKind: AIServiceKind
    public let host: String

    public init(id: UUID, serviceKind: AIServiceKind, host: String) {
        self.id = id
        self.serviceKind = serviceKind
        self.host = host.lowercased()
    }
}

/// 已持久化的 AI 配置。`modelID` 可为空（"已配置供应商但尚未选模型"）；
/// 需要执行 AI 的调用方必须通过 `resolved` / `requireResolved()` 取得
/// `ResolvedAIConfiguration`，把"模型已选定"变成类型层面的保证。
public struct AIConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let serviceKind: AIServiceKind
    public let serviceName: String
    public let baseURL: URL
    public let modelID: String?
    public let responseFormatMode: AIResponseFormatMode
    public let credentialReference: AICredentialReference

    public init(
        isEnabled: Bool,
        serviceKind: AIServiceKind,
        serviceName: String,
        baseURL: URL,
        modelID: String?,
        responseFormatMode: AIResponseFormatMode,
        credentialReference: AICredentialReference
    ) {
        self.isEnabled = isEnabled
        self.serviceKind = serviceKind
        self.serviceName = serviceName
        self.baseURL = baseURL
        self.modelID = modelID
        self.responseFormatMode = responseFormatMode
        self.credentialReference = credentialReference
    }

    public var credentialAuthority: String {
        credentialReference.host
    }

    /// 非 nil 即表示配置完整、可执行 AI。
    public var resolved: ResolvedAIConfiguration? {
        ResolvedAIConfiguration(configuration: self)
    }

    public func requireResolved() throws -> ResolvedAIConfiguration {
        guard let resolved else { throw AIConfigurationError.modelIDRequired }
        return resolved
    }

    /// 从已解析的运行时配置还原为持久化形态。
    public init(resolved: ResolvedAIConfiguration) {
        self.init(
            isEnabled: resolved.isEnabled,
            serviceKind: resolved.serviceKind,
            serviceName: resolved.serviceName,
            baseURL: resolved.baseURL,
            modelID: resolved.modelID,
            responseFormatMode: resolved.responseFormatMode,
            credentialReference: resolved.credentialReference
        )
    }
}

/// 运行时完整配置：字段与 `AIConfiguration` 一致但 `modelID` 非空。
/// 所有真正发起 AI 请求的 client 只接受这一类型。
public struct ResolvedAIConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let serviceKind: AIServiceKind
    public let serviceName: String
    public let baseURL: URL
    public let modelID: String
    public let responseFormatMode: AIResponseFormatMode
    public let credentialReference: AICredentialReference

    public init(
        isEnabled: Bool,
        serviceKind: AIServiceKind,
        serviceName: String,
        baseURL: URL,
        modelID: String,
        responseFormatMode: AIResponseFormatMode,
        credentialReference: AICredentialReference
    ) {
        self.isEnabled = isEnabled
        self.serviceKind = serviceKind
        self.serviceName = serviceName
        self.baseURL = baseURL
        self.modelID = modelID
        self.responseFormatMode = responseFormatMode
        self.credentialReference = credentialReference
    }

    public init?(configuration: AIConfiguration) {
        guard let modelID = configuration.modelID, !modelID.isEmpty else { return nil }
        self.init(
            isEnabled: configuration.isEnabled,
            serviceKind: configuration.serviceKind,
            serviceName: configuration.serviceName,
            baseURL: configuration.baseURL,
            modelID: modelID,
            responseFormatMode: configuration.responseFormatMode,
            credentialReference: configuration.credentialReference
        )
    }

    public var credentialAuthority: String {
        credentialReference.host
    }
}

public struct AIConfigurationStatus: Equatable, Sendable {
    public let configuration: AIConfiguration
    public let hasAPIKey: Bool

    public init(configuration: AIConfiguration, hasAPIKey: Bool) {
        self.configuration = configuration
        self.hasAPIKey = hasAPIKey
    }
}

public enum AIConfigurationError: Error, Equatable, Sendable {
    case serviceNameRequired
    case serviceNameTooLong
    case baseURLRequired
    case secureHTTPSRequired
    case credentialsInURLNotAllowed
    case queryOrFragmentNotAllowed
    case invalidBaseURL
    case modelIDRequired
    case modelIDTooLong
    case apiKeyRequired
    case invalidPersistedConfiguration
}

extension AIConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .serviceNameRequired: "请输入服务名称。"
        case .serviceNameTooLong: "服务名称不能超过 80 个字符。"
        case .baseURLRequired: "请输入服务地址。"
        case .secureHTTPSRequired: "AI 服务地址必须使用 HTTPS。"
        case .credentialsInURLNotAllowed: "服务地址不能包含用户名或密码。"
        case .queryOrFragmentNotAllowed: "服务地址不能包含查询参数或片段。"
        case .invalidBaseURL: "请输入有效的 AI 服务地址。"
        case .modelIDRequired: "请先选择模型。"
        case .modelIDTooLong: "模型 ID 不能超过 200 个字符。"
        case .apiKeyRequired: "启用 AI 前需要为当前服务地址保存 API Key。"
        case .invalidPersistedConfiguration: "本机保存的 AI 配置无效，请重新配置。"
        }
    }
}

public enum AIConfigurationValidator {
    /// 校验草稿并产出可持久化的 `AIConfiguration`：`modelID` 允许为空。
    /// 预设供应商的名称、地址、响应格式一律以注册表为准，忽略草稿对应字段。
    public static func validate(
        _ draft: AIConfigurationDraft,
        credentialID: UUID
    ) throws -> AIConfiguration {
        let preset = AIProviderPresetRegistry.preset(for: draft.serviceKind)
        let serviceName: String
        let baseURLText: String
        if let preset {
            serviceName = preset.displayName
            baseURLText = preset.baseURL
        } else {
            serviceName = draft.serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            baseURLText = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !serviceName.isEmpty else { throw AIConfigurationError.serviceNameRequired }
        guard serviceName.count <= 80 else { throw AIConfigurationError.serviceNameTooLong }
        guard !baseURLText.isEmpty else { throw AIConfigurationError.baseURLRequired }
        guard baseURLText.count <= 2_048,
              baseURLText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: baseURLText),
              components.scheme?.lowercased() == "https" else {
            throw AIConfigurationError.secureHTTPSRequired
        }
        guard components.user == nil, components.password == nil else {
            throw AIConfigurationError.credentialsInURLNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw AIConfigurationError.queryOrFragmentNotAllowed
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw AIConfigurationError.invalidBaseURL
        }

        components.scheme = "https"
        components.host = host
        if components.port == 443 { components.port = nil }
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" { components.path = "" }
        guard let normalizedURL = components.url else {
            throw AIConfigurationError.invalidBaseURL
        }

        let trimmedModelID = draft.modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = trimmedModelID?.isEmpty == false ? trimmedModelID : nil
        if let modelID, modelID.count > 200 {
            throw AIConfigurationError.modelIDTooLong
        }

        let authority = components.port.map { "\(host):\($0)" } ?? host
        return AIConfiguration(
            isEnabled: draft.isEnabled,
            serviceKind: draft.serviceKind,
            serviceName: serviceName,
            baseURL: normalizedURL,
            modelID: modelID,
            responseFormatMode: preset?.responseFormatMode ?? draft.responseFormatMode,
            credentialReference: AICredentialReference(
                id: credentialID,
                serviceKind: draft.serviceKind,
                host: authority
            )
        )
    }

    /// 校验并要求模型已选定，产出可执行 AI 的 `ResolvedAIConfiguration`。
    public static func resolve(
        _ draft: AIConfigurationDraft,
        credentialID: UUID
    ) throws -> ResolvedAIConfiguration {
        let configuration = try validate(draft, credentialID: credentialID)
        guard let resolved = configuration.resolved else {
            throw AIConfigurationError.modelIDRequired
        }
        return resolved
    }
}

public protocol AIConfigurationRepository: Sendable {
    func loadOrCreateAIConfiguration(defaultTimeZoneID: String) async throws -> AIConfiguration
    func saveAIConfiguration(_ configuration: AIConfiguration) async throws
}

public protocol AICredentialStore: Sendable {
    func readCredential(for reference: AICredentialReference) async throws -> String?
    func saveCredential(_ credential: String, for reference: AICredentialReference) async throws
    func deleteCredential(for reference: AICredentialReference) async throws
}

public actor AIConfigurationService {
    private let repository: any AIConfigurationRepository
    private let credentialStore: any AICredentialStore

    public init(
        repository: any AIConfigurationRepository,
        credentialStore: any AICredentialStore
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
    }

    public func load(defaultTimeZoneID: String) async throws -> AIConfigurationStatus {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        var configuration = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: defaultTimeZoneID
        )
        let credential = try await credentialStore.readCredential(
            for: configuration.credentialReference
        )
        let hasAPIKey = credential?.isEmpty == false
        if Self.isLegacyAutoInsertedConfiguration(
            configuration, hasAPIKey: hasAPIKey
        ) {
            // 落库一次，让残留占位值不再回显。
            configuration = try await clearPersistedModelID(of: configuration)
        }
        return AIConfigurationStatus(
            configuration: configuration,
            hasAPIKey: hasAPIKey
        )
    }

    /// v0.5 及更早版本在 AI 列缺失时会把示例模型名「deepseek-v4-pro」
    /// 作为默认草稿值落库。从未保存过 Key 且未启用，说明该行是自动
    /// 插入的占位而非用户选择——归一化为「未选择」。已存 Key 或已启用
    /// 的配置原样保留，避免误清用户曾确认过的值。
    private static func isLegacyAutoInsertedConfiguration(
        _ configuration: AIConfiguration,
        hasAPIKey: Bool
    ) -> Bool {
        !hasAPIKey
            && !configuration.isEnabled
            && configuration.serviceKind == .deepSeek
            && configuration.modelID == "deepseek-v4-pro"
    }

    private func clearPersistedModelID(
        of configuration: AIConfiguration
    ) async throws -> AIConfiguration {
        let cleared = try AIConfigurationValidator.validate(
            AIConfigurationDraft(
                isEnabled: false,
                serviceKind: configuration.serviceKind,
                serviceName: configuration.serviceName,
                baseURL: configuration.baseURL.absoluteString,
                modelID: nil,
                responseFormatMode: configuration.responseFormatMode
            ),
            credentialID: configuration.credentialReference.id
        )
        try await repository.saveAIConfiguration(cleared)
        return cleared
    }

    public func save(
        _ draft: AIConfigurationDraft,
        apiKey: String?,
        defaultTimeZoneID: String
    ) async throws -> AIConfigurationStatus {
        let current = try await load(defaultTimeZoneID: defaultTimeZoneID)
        let provisional = try AIConfigurationValidator.validate(
            draft,
            credentialID: current.configuration.credentialReference.id
        )
        // Key 绑定的是「供应商 + host:port」：同绑定换模型不动 Key，
        // 换供应商或 host 则生成新的 credential reference 并要求重新输入。
        let bindingChanged = provisional.serviceKind != current.configuration.serviceKind
            || provisional.credentialAuthority != current.configuration.credentialAuthority
        let credentialID = bindingChanged
            ? UUID()
            : current.configuration.credentialReference.id
        let configuration = try AIConfigurationValidator.validate(
            draft,
            credentialID: credentialID
        )
        // 未选模型的草稿可以保存（禁用状态），但启用 AI 必须已选模型。
        if configuration.isEnabled, configuration.modelID == nil {
            throw AIConfigurationError.modelIDRequired
        }
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementKey = trimmedKey?.isEmpty == false ? trimmedKey : nil
        let currentKey = bindingChanged
            ? nil
            : try await credentialStore.readCredential(for: current.configuration.credentialReference)

        if configuration.isEnabled, replacementKey == nil, currentKey?.isEmpty != false {
            throw AIConfigurationError.apiKeyRequired
        }

        if let replacementKey {
            try await credentialStore.saveCredential(
                replacementKey,
                for: configuration.credentialReference
            )
        }

        do {
            try await repository.saveAIConfiguration(configuration)
        } catch {
            if replacementKey != nil {
                if bindingChanged {
                    try? await credentialStore.deleteCredential(for: configuration.credentialReference)
                } else if let currentKey {
                    try? await credentialStore.saveCredential(
                        currentKey,
                        for: current.configuration.credentialReference
                    )
                } else {
                    try? await credentialStore.deleteCredential(for: configuration.credentialReference)
                }
            }
            throw error
        }

        if bindingChanged {
            try? await credentialStore.deleteCredential(for: current.configuration.credentialReference)
        }
        return AIConfigurationStatus(
            configuration: configuration,
            hasAPIKey: replacementKey != nil || currentKey?.isEmpty == false
        )
    }

    public func removeAPIKey(defaultTimeZoneID: String) async throws -> AIConfigurationStatus {
        let current = try await load(defaultTimeZoneID: defaultTimeZoneID)
        let disabledDraft = AIConfigurationDraft(
            isEnabled: false,
            serviceKind: current.configuration.serviceKind,
            serviceName: current.configuration.serviceName,
            baseURL: current.configuration.baseURL.absoluteString,
            modelID: current.configuration.modelID,
            responseFormatMode: current.configuration.responseFormatMode
        )
        let disabled = try AIConfigurationValidator.validate(
            disabledDraft,
            credentialID: current.configuration.credentialReference.id
        )
        try await repository.saveAIConfiguration(disabled)
        try await credentialStore.deleteCredential(for: disabled.credentialReference)
        return AIConfigurationStatus(configuration: disabled, hasAPIKey: false)
    }
}
