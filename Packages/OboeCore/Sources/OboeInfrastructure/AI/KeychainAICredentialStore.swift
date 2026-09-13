import Foundation
import OboeDomain
import Security

public enum AICredentialStoreError: Error, Equatable, Sendable {
    case invalidEncoding
    case unexpectedStatus(Int32)
}

extension AICredentialStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: "无法安全读取已保存的 API Key。"
        case let .unexpectedStatus(status): "系统钥匙串操作失败（代码 \(status)）。"
        }
    }
}

public struct KeychainAICredentialStore: AICredentialStore, Sendable {
    static let service = "com.oboe.ai.credentials"

    public init() {}

    public func readCredential(for reference: AICredentialReference) async throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account(for: reference),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw AICredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let credential = String(data: data, encoding: .utf8) else {
            throw AICredentialStoreError.invalidEncoding
        }
        return credential
    }

    public func saveCredential(
        _ credential: String,
        for reference: AICredentialReference
    ) async throws {
        guard let data = credential.data(using: .utf8) else {
            throw AICredentialStoreError.invalidEncoding
        }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account(for: reference)
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AICredentialStoreError.unexpectedStatus(updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AICredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    public func deleteCredential(for reference: AICredentialReference) async throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account(for: reference)
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AICredentialStoreError.unexpectedStatus(status)
        }
    }

    static func account(for reference: AICredentialReference) -> String {
        [
            reference.id.uuidString.lowercased(),
            reference.serviceKind.rawValue,
            reference.host.lowercased()
        ].joined(separator: "|")
    }
}
