import Foundation

public enum AIServiceKind: String, CaseIterable, Codable, Sendable {
    case deepSeek = "deepseek"
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .custom: "自定义兼容服务"
        }
    }
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

public struct AIConfigurationDraft: Equatable, Sendable {
    public var isEnabled: Bool
    public var serviceKind: AIServiceKind
    public var serviceName: String
    public var baseURL: String
    public var modelID: String
    public var responseFormatMode: AIResponseFormatMode

    public init(
        isEnabled: Bool,
        serviceKind: AIServiceKind,
        serviceName: String,
        baseURL: String,
        modelID: String,
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

    public static let deepSeekDefault = AIConfigurationDraft(
        isEnabled: false,
        serviceKind: .deepSeek,
        serviceName: "DeepSeek",
        baseURL: "https://api.deepseek.com",
        modelID: "deepseek-v4-pro",
        responseFormatMode: .jsonObject
    )
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

public struct AIConfiguration: Equatable, Sendable {
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
        case .modelIDRequired: "请输入模型 ID。"
        case .modelIDTooLong: "模型 ID 不能超过 200 个字符。"
        case .apiKeyRequired: "启用 AI 前需要为当前服务地址保存 API Key。"
        case .invalidPersistedConfiguration: "本机保存的 AI 配置无效，请重新配置。"
        }
    }
}

public enum AIConfigurationValidator {
    public static func validate(
        _ draft: AIConfigurationDraft,
        credentialID: UUID
    ) throws -> AIConfiguration {
        let serviceName: String
        let baseURLText: String
        switch draft.serviceKind {
        case .deepSeek:
            serviceName = AIConfigurationDraft.deepSeekDefault.serviceName
            baseURLText = AIConfigurationDraft.deepSeekDefault.baseURL
        case .custom:
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

        let modelID = draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw AIConfigurationError.modelIDRequired }
        guard modelID.count <= 200 else { throw AIConfigurationError.modelIDTooLong }

        let authority = components.port.map { "\(host):\($0)" } ?? host
        return AIConfiguration(
            isEnabled: draft.isEnabled,
            serviceKind: draft.serviceKind,
            serviceName: serviceName,
            baseURL: normalizedURL,
            modelID: modelID,
            responseFormatMode: draft.serviceKind == .deepSeek
                ? .jsonObject
                : draft.responseFormatMode,
            credentialReference: AICredentialReference(
                id: credentialID,
                serviceKind: draft.serviceKind,
                host: authority
            )
        )
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
        let configuration = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: defaultTimeZoneID
        )
        let credential = try await credentialStore.readCredential(
            for: configuration.credentialReference
        )
        return AIConfigurationStatus(
            configuration: configuration,
            hasAPIKey: credential?.isEmpty == false
        )
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
        let bindingChanged = provisional.serviceKind != current.configuration.serviceKind
            || provisional.credentialAuthority != current.configuration.credentialAuthority
        let credentialID = bindingChanged
            ? UUID()
            : current.configuration.credentialReference.id
        let configuration = try AIConfigurationValidator.validate(
            draft,
            credentialID: credentialID
        )
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
