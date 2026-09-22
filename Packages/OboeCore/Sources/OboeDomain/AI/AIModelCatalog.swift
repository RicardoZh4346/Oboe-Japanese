import Foundation

/// 供应商返回的一个可选模型。`id` 是请求时使用的模型 ID；
/// `displayName` 是面向用户的名称（无显示名时与 `id` 相同）。
public struct AIModelDescriptor: Equatable, Hashable, Sendable, Comparable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }

    public static func < (lhs: AIModelDescriptor, rhs: AIModelDescriptor) -> Bool {
        lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            || (lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedSame && lhs.id < rhs.id)
    }
}

/// 模型列表获取错误。所有文案都不包含 API Key 或服务地址。
public enum AIModelCatalogError: Error, Equatable, Sendable {
    case credentialMissing
    case invalidCredential
    case cancelled
    /// 已有更新的请求（或供应商/Key/地址变化）使本次结果作废。
    case requestSuperseded
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
    /// 服务返回了空列表或全部模型被能力过滤排除——不允许自由输入旁路。
    case emptyModelList
}

extension AIModelCatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .credentialMissing:
            "当前服务没有可用的 API Key，请先保存 API Key。"
        case .invalidCredential:
            "API Key 格式无效，请重新填写。"
        case .cancelled:
            "模型列表请求已取消。"
        case .requestSuperseded:
            "模型列表结果已过期，请重新获取。"
        case .timedOut:
            "获取模型列表超时，请检查网络后重试。"
        case .networkUnavailable:
            "当前网络不可用，无法获取模型列表。"
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
            "服务不接受当前模型列表请求（HTTP \(statusCode)）。"
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
            "模型列表响应超过允许的大小。"
        case .malformedResponse:
            "AI 服务返回了无法识别的模型列表。"
        case .emptyModelList:
            "服务没有返回可用于文本生成的模型。"
        }
    }
}

/// 传输边界：按配置的供应商协议获取可选模型列表。
/// 实现方负责 endpoint/header、分页、去重排序与能力过滤；
/// 结果只存在于内存，绝不写入数据库或备份。
public protocol AIModelCatalogClient: Sendable {
    func fetchModels(
        configuration: AIConfiguration,
        credential: String
    ) async throws -> [AIModelDescriptor]
}

/// 领域服务：加载配置与 Key 后委托 client 获取模型列表。
/// 通过单调递增的代次保证「旧结果作废」：新的 fetch 或
/// `invalidatePendingFetches()` 会让尚未返回的旧请求抛出
/// `requestSuperseded`/`cancelled`，UI 不会拿到过期页面状态。
public actor AIModelCatalogService {
    private let repository: any AIConfigurationRepository
    private let credentialStore: any AICredentialStore
    private let client: any AIModelCatalogClient
    private var fetchGeneration = 0

    public init(
        repository: any AIConfigurationRepository,
        credentialStore: any AICredentialStore,
        client: any AIModelCatalogClient
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.client = client
    }

    public func fetchModels(defaultTimeZoneID: String) async throws -> [AIModelDescriptor] {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        fetchGeneration += 1
        let generation = fetchGeneration

        let configuration = try await repository.loadOrCreateAIConfiguration(
            defaultTimeZoneID: defaultTimeZoneID
        )
        guard let credential = try await credentialStore.readCredential(
            for: configuration.credentialReference
        ), !credential.isEmpty else {
            throw AIModelCatalogError.credentialMissing
        }
        guard credential.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw AIModelCatalogError.invalidCredential
        }
        try Task.checkCancellation()
        let models = try await client.fetchModels(
            configuration: configuration,
            credential: credential
        )
        try Task.checkCancellation()
        guard generation == fetchGeneration else {
            throw AIModelCatalogError.requestSuperseded
        }
        return models
    }

    /// 供应商/Key/地址变化后调用：使所有在途请求的结果作废。
    public func invalidatePendingFetches() {
        fetchGeneration += 1
    }
}
