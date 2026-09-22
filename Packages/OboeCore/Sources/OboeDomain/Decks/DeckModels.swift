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
    /// 成员 Note 总数（含共享）。
    public let noteCount: Int
    /// 成员 Note 的 Card 总数（含共享 Note 的卡）。
    public let cardCount: Int
    /// 成员 Note 的复习日志总数（含共享 Note 的日志）。
    public let reviewLogCount: Int
    /// 仅属于该牌组的 Note 数：deleteContents 时会被真正删除。
    public let exclusiveNoteCount: Int
    /// 独占 Note 的 Card 数：deleteContents 时随独占 Note 一并删除。
    public let exclusiveCardCount: Int
    /// 同时属于其他牌组的 Note 数：deleteContents 时仅移除本牌组成员关系。
    public let sharedNoteCount: Int

    public init(
        noteCount: Int,
        cardCount: Int,
        reviewLogCount: Int,
        exclusiveNoteCount: Int? = nil,
        exclusiveCardCount: Int? = nil,
        sharedNoteCount: Int? = nil
    ) {
        self.noteCount = noteCount
        self.cardCount = cardCount
        self.reviewLogCount = reviewLogCount
        self.exclusiveNoteCount = exclusiveNoteCount ?? noteCount
        self.exclusiveCardCount = exclusiveCardCount ?? cardCount
        self.sharedNoteCount = sharedNoteCount ?? 0
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
    /// 删除前预览影响（独占/共享计数）；牌组不存在返回 nil。
    func previewDeletionImpact(id: UUID) async throws -> DeckDeletionImpact?
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

    /// 删除确认页用：分别展示独占（将真正删除）与共享（仅解除关系）
    /// 知识点数（设计 §4.8）。
    public func previewDeletionImpact(id: UUID) async throws -> DeckDeletionImpact? {
        try await repository.previewDeletionImpact(id: id)
    }

    public func deleteDeck(
        id: UUID,
        strategy: DeckDeletionStrategy
    ) async throws -> ManagedDeckDeletionResult {
        try await repository.deleteDeck(id: id, strategy: strategy, at: now())
    }
}
