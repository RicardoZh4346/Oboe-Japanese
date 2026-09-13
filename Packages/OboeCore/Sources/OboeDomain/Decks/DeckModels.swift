import Foundation

public struct DeckName: Equatable, Hashable, Codable, Sendable {
    public static let maximumLength = 80

    public let value: String

    public init(validating rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DeckNameValidationError.empty
        }
        guard trimmed.count <= Self.maximumLength else {
            throw DeckNameValidationError.tooLong(maximum: Self.maximumLength)
        }
        guard trimmed.rangeOfCharacter(from: .newlines.union(.controlCharacters)) == nil else {
            throw DeckNameValidationError.containsLineBreakOrControlCharacter
        }
        value = trimmed
    }
}

public enum DeckNameValidationError: Error, Equatable, Sendable {
    case empty
    case tooLong(maximum: Int)
    case containsLineBreakOrControlCharacter
}

public struct Deck: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let sortOrder: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        name: String,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DeckSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let noteCount: Int
    public let cardCount: Int

    public init(id: UUID, name: String, noteCount: Int, cardCount: Int) {
        self.id = id
        self.name = name
        self.noteCount = noteCount
        self.cardCount = cardCount
    }

    public var isEmpty: Bool {
        noteCount == 0 && cardCount == 0
    }
}

public enum DeckDeletionResult: Equatable, Sendable {
    case deleted
    case notFound
    case notEmpty(noteCount: Int, cardCount: Int)
}

public struct DeckDeletionImpact: Equatable, Sendable {
    public let noteCount: Int
    public let cardCount: Int
    public let reviewLogCount: Int

    public init(noteCount: Int, cardCount: Int, reviewLogCount: Int) {
        self.noteCount = noteCount
        self.cardCount = cardCount
        self.reviewLogCount = reviewLogCount
    }
}

public enum DeckDeletionStrategy: Equatable, Sendable {
    case moveContents(to: UUID)
    case deleteContents
}

public enum ManagedDeckDeletionResult: Equatable, Sendable {
    case deleted(DeckDeletionImpact)
    case sourceNotFound
    case destinationNotFound
    case destinationMatchesSource
}

public protocol DeckRepository: Sendable {
    func deckExists(id: UUID) async throws -> Bool
    func fetchDeckSummaries() async throws -> [DeckSummary]
    func observeDeckSummaries() -> AsyncThrowingStream<[DeckSummary], Error>
    func createDeck(id: UUID, name: String, at date: Date) async throws -> Deck
    func renameDeck(id: UUID, name: String, at date: Date) async throws -> Bool
    func deleteDeckIfEmpty(id: UUID) async throws -> DeckDeletionResult
    func deleteDeck(
        id: UUID,
        strategy: DeckDeletionStrategy,
        at date: Date
    ) async throws -> ManagedDeckDeletionResult
}

public struct DeckManagementService: Sendable {
    private let repository: any DeckRepository
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any DeckRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    public func fetchDecks() async throws -> [DeckSummary] {
        try await repository.fetchDeckSummaries()
    }

    public func observeDecks() -> AsyncThrowingStream<[DeckSummary], Error> {
        repository.observeDeckSummaries()
    }

    @discardableResult
    public func createDeck(named rawName: String) async throws -> Deck {
        let name = try DeckName(validating: rawName)
        return try await repository.createDeck(
            id: makeID(),
            name: name.value,
            at: now()
        )
    }

    @discardableResult
    public func renameDeck(id: UUID, to rawName: String) async throws -> Bool {
        let name = try DeckName(validating: rawName)
        return try await repository.renameDeck(
            id: id,
            name: name.value,
            at: now()
        )
    }

    public func deleteEmptyDeck(id: UUID) async throws -> DeckDeletionResult {
        try await repository.deleteDeckIfEmpty(id: id)
    }

    public func deleteDeck(
        id: UUID,
        strategy: DeckDeletionStrategy
    ) async throws -> ManagedDeckDeletionResult {
        try await repository.deleteDeck(id: id, strategy: strategy, at: now())
    }
}
