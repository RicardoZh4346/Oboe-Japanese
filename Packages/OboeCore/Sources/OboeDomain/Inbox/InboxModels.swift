import Foundation

public enum InboxSourceType: String, Codable, CaseIterable, Sendable {
    case manual
    case paste
    case share
    case ocr
}

public enum InboxStatus: String, Codable, CaseIterable, Sendable {
    case unprocessed
    case processing
    case processed
    case archived
}

public struct InboxText: Equatable, Hashable, Codable, Sendable {
    public static let maximumCharacterCount = 20_000
    public static let maximumUTF8ByteCount = 256 * 1_024

    public let value: String

    public init(validating rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InboxTextValidationError.empty
        }
        guard rawValue.count <= Self.maximumCharacterCount else {
            throw InboxTextValidationError.tooLong(maximumCharacters: Self.maximumCharacterCount)
        }
        guard rawValue.utf8.count <= Self.maximumUTF8ByteCount else {
            throw InboxTextValidationError.tooLarge(maximumBytes: Self.maximumUTF8ByteCount)
        }
        value = rawValue
    }
}

public enum InboxTextValidationError: Error, Equatable, Sendable {
    case empty
    case tooLong(maximumCharacters: Int)
    case tooLarge(maximumBytes: Int)
}

public struct InboxItem: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let sourceType: InboxSourceType
    public let status: InboxStatus
    public let contentRevision: Int
    public let sourceApp: String?
    public let sourceURL: String?
    public let imageReference: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let processedAt: Date?
    public let archivedAt: Date?
    public let statusBeforeArchive: InboxStatus?

    public init(
        id: UUID,
        text: String,
        sourceType: InboxSourceType,
        status: InboxStatus,
        contentRevision: Int,
        sourceApp: String?,
        sourceURL: String?,
        imageReference: String?,
        createdAt: Date,
        updatedAt: Date,
        processedAt: Date?,
        archivedAt: Date?,
        statusBeforeArchive: InboxStatus?
    ) {
        self.id = id
        self.text = text
        self.sourceType = sourceType
        self.status = status
        self.contentRevision = contentRevision
        self.sourceApp = sourceApp
        self.sourceURL = sourceURL
        self.imageReference = imageReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.processedAt = processedAt
        self.archivedAt = archivedAt
        self.statusBeforeArchive = statusBeforeArchive
    }
}
