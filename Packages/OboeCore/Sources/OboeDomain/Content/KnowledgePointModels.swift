import Foundation

public enum KnowledgePointKind: String, Codable, Hashable, Sendable {
    case vocabulary
    case grammar
}

public struct KnowledgePointSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 归属（home）牌组；成员全集见 `deckIDs`。
    public let deckID: UUID
    /// 该 Note 的全部成员牌组；始终包含 `deckID`。
    public let deckIDs: Set<UUID>
    public let kind: KnowledgePointKind
    public let headword: String
    public let reading: String?
    public let meaningZH: String
    public let usage: String?
    public let isFavorite: Bool

    public init(
        id: UUID,
        deckID: UUID,
        kind: KnowledgePointKind,
        headword: String,
        reading: String?,
        meaningZH: String,
        usage: String?,
        isFavorite: Bool,
        deckIDs: Set<UUID>? = nil
    ) {
        self.id = id
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? [deckID]).union([deckID])
        self.kind = kind
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.usage = usage
        self.isFavorite = isFavorite
    }
}

public struct KnowledgeTag: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let normalizedName: String

    public init(id: UUID, name: String, normalizedName: String) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName
    }
}

public struct KnowledgePointMetadata: Equatable, Sendable {
    public let isFavorite: Bool
    public let tags: [KnowledgeTag]

    public init(isFavorite: Bool, tags: [KnowledgeTag]) {
        self.isFavorite = isFavorite
        self.tags = tags
    }
}

public struct KnowledgePointDeletionImpact: Equatable, Sendable {
    public let cardCount: Int
    public let reviewLogCount: Int

    public init(cardCount: Int, reviewLogCount: Int) {
        self.cardCount = cardCount
        self.reviewLogCount = reviewLogCount
    }
}

public enum KnowledgePointMoveResult: Equatable, Sendable {
    case moved(cardCount: Int)
    case noteNotFound
    case destinationNotFound
    case alreadyInDestination
}

public enum KnowledgePointDeletionResult: Equatable, Sendable {
    case deleted(KnowledgePointDeletionImpact)
    case notFound
}

public struct KnowledgeTagName: Equatable, Sendable {
    public static let maximumLength = 40

    public let displayName: String
    public let normalizedName: String

    public init(validating rawValue: String) throws {
        let displayName = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !displayName.isEmpty else {
            throw KnowledgeTagValidationError.empty
        }
        guard displayName.count <= Self.maximumLength else {
            throw KnowledgeTagValidationError.tooLong(maximum: Self.maximumLength)
        }

        self.displayName = displayName
        normalizedName = displayName
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

public enum KnowledgeTagValidationError: Error, Equatable, Sendable {
    case empty
    case tooLong(maximum: Int)
}

public protocol KnowledgePointRepository: Sendable {
    func fetchKnowledgePointSummaries(deckID: UUID) async throws -> [KnowledgePointSummary]
    /// 读取 Note 的成员关系（home + 全部成员牌组）；Note 不存在时返回 nil。
    func fetchDeckMembership(noteID: UUID) async throws -> NoteDeckMembership?
    /// 原子替换成员关系：校验 Note/牌组存在性与 home∈members，同事务内
    /// 插入缺失成员、删除移除成员、更新 `notes.deck_id` 与 `updated_at_ms`。
    /// 任一步失败时整体回滚。
    func replaceDeckMembership(
        noteID: UUID,
        deckIDs: Set<UUID>,
        homeDeckID: UUID,
        at date: Date
    ) async throws -> NoteDeckMembership
    func fetchFavoriteSummaries() async throws -> [KnowledgePointSummary]
    func fetchDuplicateSummaries(
        kind: KnowledgePointKind,
        headword: String,
        reading: String?,
        excluding noteID: UUID?
    ) async throws -> [KnowledgePointSummary]
    func fetchMetadata(noteID: UUID) async throws -> KnowledgePointMetadata?
    func setFavorite(noteID: UUID, isFavorite: Bool, at date: Date) async throws -> Bool
    func replaceTags(noteID: UUID, tags: [KnowledgeTag], at date: Date) async throws -> Bool
    func moveKnowledgePoint(
        noteID: UUID,
        to destinationDeckID: UUID,
        at date: Date
    ) async throws -> KnowledgePointMoveResult
    func fetchDeletionImpact(noteID: UUID) async throws -> KnowledgePointDeletionImpact?
    func deleteKnowledgePoint(noteID: UUID) async throws -> KnowledgePointDeletionResult
}

public struct KnowledgePointService: Sendable {
    private let repository: any KnowledgePointRepository
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any KnowledgePointRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    public func fetchSummaries(deckID: UUID) async throws -> [KnowledgePointSummary] {
        try await repository.fetchKnowledgePointSummaries(deckID: deckID)
    }

    public func fetchMembership(noteID: UUID) async throws -> NoteDeckMembership? {
        try await repository.fetchDeckMembership(noteID: noteID)
    }

    /// 以给定成员集合与 home 牌组原子替换 Note 的成员关系。
    @discardableResult
    public func replaceMembership(
        noteID: UUID,
        deckIDs: Set<UUID>,
        homeDeckID: UUID
    ) async throws -> NoteDeckMembership {
        try await repository.replaceDeckMembership(
            noteID: noteID,
            deckIDs: deckIDs,
            homeDeckID: homeDeckID,
            at: now()
        )
    }

    public func fetchFavorites() async throws -> [KnowledgePointSummary] {
        try await repository.fetchFavoriteSummaries()
    }

    public func fetchDuplicates(
        kind: KnowledgePointKind,
        headword: String,
        reading: String? = nil,
        excluding noteID: UUID? = nil
    ) async throws -> [KnowledgePointSummary] {
        let headword = headword
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !headword.isEmpty else {
            return []
        }
        let normalizedReading: String?
        switch kind {
        case .vocabulary:
            normalizedReading = (reading ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
        case .grammar:
            normalizedReading = nil
        }
        return try await repository.fetchDuplicateSummaries(
            kind: kind,
            headword: headword,
            reading: normalizedReading,
            excluding: noteID
        )
    }

    public func fetchMetadata(noteID: UUID) async throws -> KnowledgePointMetadata? {
        try await repository.fetchMetadata(noteID: noteID)
    }

    @discardableResult
    public func setFavorite(noteID: UUID, isFavorite: Bool) async throws -> Bool {
        try await repository.setFavorite(noteID: noteID, isFavorite: isFavorite, at: now())
    }

    @discardableResult
    public func replaceTags(noteID: UUID, rawNames: [String]) async throws -> Bool {
        var normalizedNames = Set<String>()
        var tags: [KnowledgeTag] = []
        for rawName in rawNames {
            let name = try KnowledgeTagName(validating: rawName)
            guard normalizedNames.insert(name.normalizedName).inserted else {
                continue
            }
            tags.append(
                KnowledgeTag(
                    id: makeID(),
                    name: name.displayName,
                    normalizedName: name.normalizedName
                )
            )
        }
        return try await repository.replaceTags(noteID: noteID, tags: tags, at: now())
    }

    public func move(
        noteID: UUID,
        to destinationDeckID: UUID
    ) async throws -> KnowledgePointMoveResult {
        try await repository.moveKnowledgePoint(
            noteID: noteID,
            to: destinationDeckID,
            at: now()
        )
    }

    public func fetchDeletionImpact(noteID: UUID) async throws -> KnowledgePointDeletionImpact? {
        try await repository.fetchDeletionImpact(noteID: noteID)
    }

    public func delete(noteID: UUID) async throws -> KnowledgePointDeletionResult {
        try await repository.deleteKnowledgePoint(noteID: noteID)
    }
}
