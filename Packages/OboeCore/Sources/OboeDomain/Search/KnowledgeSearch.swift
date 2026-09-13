import Foundation

public enum SearchTextNormalizer {
    public static func normalize(_ value: String) -> String {
        let compatibilityNormalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let scalars = compatibilityNormalized.unicodeScalars.map { scalar -> UnicodeScalar in
            switch scalar.value {
            case 0x30A1...0x30F6, 0x30FD...0x30FE:
                UnicodeScalar(scalar.value - 0x60) ?? scalar
            default:
                scalar
            }
        }
        return String(String.UnicodeScalarView(scalars))
            .precomposedStringWithCanonicalMapping
    }
}

public struct KnowledgeSearchPage: Equatable, Sendable {
    public let items: [KnowledgePointSummary]
    public let nextOffset: Int?

    public init(items: [KnowledgePointSummary], nextOffset: Int?) {
        self.items = items
        self.nextOffset = nextOffset
    }
}

public protocol KnowledgeSearchRepository: Sendable {
    func search(
        normalizedQuery: String,
        deckID: UUID?,
        limit: Int,
        offset: Int
    ) async throws -> KnowledgeSearchPage
}

public struct KnowledgeSearchService: Sendable {
    public static let pageSize = 50

    private let repository: any KnowledgeSearchRepository

    public init(repository: any KnowledgeSearchRepository) {
        self.repository = repository
    }

    public func search(
        _ query: String,
        deckID: UUID? = nil,
        offset: Int = 0
    ) async throws -> KnowledgeSearchPage {
        let normalizedQuery = SearchTextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty, offset >= 0 else {
            return KnowledgeSearchPage(items: [], nextOffset: nil)
        }
        return try await repository.search(
            normalizedQuery: normalizedQuery,
            deckID: deckID,
            limit: Self.pageSize,
            offset: offset
        )
    }
}
