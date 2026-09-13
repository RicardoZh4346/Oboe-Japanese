import Foundation

public struct BuiltinJLPTExample: Equatable, Identifiable, Sendable {
    public let id: String
    public let japanese: String
    public let english: String?
    public let sortOrder: Int

    public init(id: String, japanese: String, english: String?, sortOrder: Int) {
        self.id = id
        self.japanese = japanese
        self.english = english
        self.sortOrder = sortOrder
    }
}

public struct BuiltinJLPTVocabulary: Equatable, Identifiable, Sendable {
    public let id: String
    public let level: JLPTLevel
    public let headword: String
    public let reading: String
    public let meaningZH: String?
    public let meaningsEN: [String]
    public let partOfSpeech: String?
    public let frequencyRank: Int?
    public let dataFlags: Int
    public let examples: [BuiltinJLPTExample]

    public init(
        id: String,
        level: JLPTLevel,
        headword: String,
        reading: String,
        meaningZH: String?,
        meaningsEN: [String],
        partOfSpeech: String?,
        frequencyRank: Int?,
        dataFlags: Int,
        examples: [BuiltinJLPTExample] = []
    ) {
        self.id = id
        self.level = level
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.meaningsEN = meaningsEN
        self.partOfSpeech = partOfSpeech
        self.frequencyRank = frequencyRank
        self.dataFlags = dataFlags
        self.examples = examples
    }
}

public struct JLPTLevelSummary: Equatable, Identifiable, Sendable {
    public let level: JLPTLevel
    public let vocabularyCount: Int
    public let importedCount: Int

    public init(level: JLPTLevel, vocabularyCount: Int, importedCount: Int = 0) {
        self.level = level
        self.vocabularyCount = vocabularyCount
        self.importedCount = importedCount
    }

    public var id: JLPTLevel { level }
}

public enum JLPTLibrarySort: String, CaseIterable, Sendable {
    case source
    case frequency
    case kana
}

public struct JLPTLibraryPage: Equatable, Sendable {
    public let items: [BuiltinJLPTVocabulary]
    public let nextOffset: Int?

    public init(items: [BuiltinJLPTVocabulary], nextOffset: Int?) {
        self.items = items
        self.nextOffset = nextOffset
    }
}

public protocol JLPTLibraryRepository: Sendable {
    func levelCounts() async throws -> [JLPTLevel: Int]
    func vocabulary(
        level: JLPTLevel,
        query: String,
        sort: JLPTLibrarySort,
        limit: Int,
        offset: Int
    ) async throws -> JLPTLibraryPage
    func vocabulary(id: String) async throws -> BuiltinJLPTVocabulary?
}

public struct JLPTLibraryService: Sendable {
    public static let pageSize = 60
    private let repository: any JLPTLibraryRepository

    public init(repository: any JLPTLibraryRepository) {
        self.repository = repository
    }

    public func levelCounts() async throws -> [JLPTLevel: Int] {
        try await repository.levelCounts()
    }

    public func vocabulary(
        level: JLPTLevel,
        query: String = "",
        sort: JLPTLibrarySort = .source,
        offset: Int = 0,
        limit: Int = pageSize
    ) async throws -> JLPTLibraryPage {
        guard offset >= 0, limit > 0 else {
            return JLPTLibraryPage(items: [], nextOffset: nil)
        }
        return try await repository.vocabulary(
            level: level,
            query: SearchTextNormalizer.normalize(query),
            sort: sort,
            limit: limit,
            offset: offset
        )
    }

    public func vocabulary(id: String) async throws -> BuiltinJLPTVocabulary? {
        try await repository.vocabulary(id: id)
    }
}

public struct JLPTImportProgress: Equatable, Sendable {
    public let processed: Int
    public let total: Int
    public let imported: Int
    public let skipped: Int
    public let failed: Int

    public init(processed: Int, total: Int, imported: Int, skipped: Int, failed: Int) {
        self.processed = processed
        self.total = total
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
    }
}

public struct JLPTImportResult: Equatable, Sendable {
    public let deckID: UUID
    public let imported: Int
    public let skipped: Int
    public let failed: Int

    public init(deckID: UUID, imported: Int, skipped: Int, failed: Int) {
        self.deckID = deckID
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
    }
}

public enum JLPTImportError: Error, Equatable, Sendable {
    case chineseMeaningRequired
    case directionRequired
    case deckNotFound
}

extension JLPTImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .chineseMeaningRequired:
            "请先填写中文释义。"
        case .directionRequired:
            "请至少选择一个卡片方向。"
        case .deckNotFound:
            "目标牌组已不存在，请重新选择。"
        }
    }
}

public protocol JLPTImporting: Sendable {
    func importedCounts() async throws -> [JLPTLevel: Int]
    func importedSourceRefs(_ sourceRefs: [String]) async throws -> Set<String>
    func importVocabulary(
        _ vocabulary: BuiltinJLPTVocabulary,
        deckID: UUID,
        meaningZH: String,
        directions: Set<VocabularyCardDirection>
    ) async throws -> JLPTImportResult
    func importLevel(
        _ level: JLPTLevel,
        vocabulary: [BuiltinJLPTVocabulary],
        directions: Set<VocabularyCardDirection>,
        progress: @escaping @Sendable (JLPTImportProgress) async -> Void
    ) async throws -> JLPTImportResult
}
