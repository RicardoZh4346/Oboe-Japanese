import Foundation

public struct AIConnectionTestResult: Equatable, Sendable {
    public let serviceName: String
    public let modelID: String
    public let responseFormatMode: AIResponseFormatMode

    public init(
        serviceName: String,
        modelID: String,
        responseFormatMode: AIResponseFormatMode
    ) {
        self.serviceName = serviceName
        self.modelID = modelID
        self.responseFormatMode = responseFormatMode
    }
}

public enum AIConnectionError: Error, Equatable, Sendable {
    case aiDisabled
    /// 配置已启用/已保存但尚未选择模型——不能执行 AI。
    case modelNotSelected
    case credentialMissing
    case invalidCredential
    case cancelled
    case timedOut
    case networkUnavailable
    case connectionFailed
    case secureConnectionFailed
    case redirectRejected
    case authenticationFailed
    case insufficientBalance
    case unsupportedConfiguration(statusCode: Int)
    case rateLimited(retryAfterSeconds: Int?)
    case serviceUnavailable(statusCode: Int)
    case unexpectedStatus(statusCode: Int)
    case responseTooLarge
    case malformedResponse
    case emptyResponse
    case truncatedResponse
    case capabilityMismatch
}

extension AIConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .aiDisabled:
            "请先保存并启用 AI。"
        case .modelNotSelected:
            "尚未选择模型，请在设置中选择模型后再试。"
        case .credentialMissing:
            "当前服务没有可用的 API Key，请重新保存配置。"
        case .invalidCredential:
            "API Key 格式无效，请重新填写。"
        case .cancelled:
            "AI 请求已取消。"
        case .timedOut:
            "AI 请求超时，请检查网络后重试。"
        case .networkUnavailable:
            "当前网络不可用；本地学习不受影响。"
        case .connectionFailed:
            "无法连接到当前 AI 服务，请检查服务地址和网络。"
        case .secureConnectionFailed:
            "无法建立安全的 HTTPS 连接，请检查服务证书。"
        case .redirectRejected:
            "服务尝试跳转到其他地址，已为保护 API Key 停止请求。"
        case .authenticationFailed:
            "API Key 无效或没有访问权限，请检查当前服务配置。"
        case .insufficientBalance:
            "当前 AI 服务账户余额不足。"
        case let .unsupportedConfiguration(statusCode):
            "服务不接受当前模型、地址或能力配置（HTTP \(statusCode)）。"
        case let .rateLimited(retryAfterSeconds):
            if let retryAfterSeconds {
                "请求过于频繁，请在 \(retryAfterSeconds) 秒后重试。"
            } else {
                "请求过于频繁，请稍后重试。"
            }
        case let .serviceUnavailable(statusCode):
            "AI 服务暂时不可用（HTTP \(statusCode)），请稍后重试。"
        case let .unexpectedStatus(statusCode):
            "AI 服务返回了未预期状态（HTTP \(statusCode)）。"
        case .responseTooLarge:
            "AI 服务响应超过本次请求允许的大小。"
        case .malformedResponse:
            "AI 服务返回了无法识别的响应。"
        case .emptyResponse:
            "AI 服务返回了空内容。"
        case .truncatedResponse:
            "AI 服务响应被截断，请检查模型或输出限制。"
        case .capabilityMismatch:
            "服务响应不符合所选 JSON 能力，请调整能力配置。"
        }
    }
}

public protocol AIConnectionClient: Sendable {
    func testConnection(
        configuration: ResolvedAIConfiguration,
        credential: String
    ) async throws -> AIConnectionTestResult
}

public actor AIConnectionTestService {
    private let repository: any AIConfigurationRepository
    private let credentialStore: any AICredentialStore
    private let client: any AIConnectionClient

    public init(
        repository: any AIConfigurationRepository,
        credentialStore: any AICredentialStore,
        client: any AIConnectionClient
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.client = client
    }

    public func testConnection(defaultTimeZoneID: String) async throws -> AIConnectionTestResult {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        let configuration = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: defaultTimeZoneID
        )
        guard configuration.isEnabled else {
            throw AIConnectionError.aiDisabled
        }
        guard let resolved = configuration.resolved else {
            throw AIConnectionError.modelNotSelected
        }
        guard let credential = try await credentialStore.readCredential(
            for: configuration.credentialReference
        ), !credential.isEmpty else {
            throw AIConnectionError.credentialMissing
        }
        guard credential.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw AIConnectionError.invalidCredential
        }
        try Task.checkCancellation()
        return try await client.testConnection(
            configuration: resolved,
            credential: credential
        )
    }
}
