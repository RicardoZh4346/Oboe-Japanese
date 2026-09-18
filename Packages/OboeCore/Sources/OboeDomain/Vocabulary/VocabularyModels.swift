import Foundation

public enum JLPTLevel: String, CaseIterable, Codable, Hashable, Sendable {
    case n5 = "N5"
    case n4 = "N4"
    case n3 = "N3"
    case n2 = "N2"
    case n1 = "N1"
}

public struct VocabularyFormData: Codable, Equatable, Sendable {
    public var headword: String
    public var reading: String
    public var meaningZH: String
    public var partOfSpeech: String
    public var jlpt: JLPTLevel?
    public var exampleJapanese: String
    public var exampleTranslationZH: String
    public var notes: String

    public init(
        headword: String = "",
        reading: String = "",
        meaningZH: String = "",
        partOfSpeech: String = "",
        jlpt: JLPTLevel? = nil,
        exampleJapanese: String = "",
        exampleTranslationZH: String = "",
        notes: String = ""
    ) {
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.jlpt = jlpt
        self.exampleJapanese = exampleJapanese
        self.exampleTranslationZH = exampleTranslationZH
        self.notes = notes
    }

    public func validatedContent() throws -> ValidatedVocabularyContent {
        let headword = self.headword.trimmed
        guard !headword.isEmpty else {
            throw VocabularyValidationError.headwordRequired
        }

        let meaningZH = self.meaningZH.trimmed
        guard !meaningZH.isEmpty else {
            throw VocabularyValidationError.meaningRequired
        }

        let exampleJapanese = self.exampleJapanese.trimmed
        let exampleTranslationZH = self.exampleTranslationZH.trimmed
        guard !exampleJapanese.isEmpty || exampleTranslationZH.isEmpty else {
            throw VocabularyValidationError.exampleJapaneseRequired
        }

        let example: VocabularyExampleContent?
        if exampleJapanese.isEmpty {
            example = nil
        } else {
            example = VocabularyExampleContent(
                japanese: exampleJapanese,
                translationZH: exampleTranslationZH.nilIfEmpty
            )
        }

        return ValidatedVocabularyContent(
            headword: headword,
            reading: reading.trimmed.nilIfEmpty,
            meaningZH: meaningZH,
            partOfSpeech: partOfSpeech.trimmed.nilIfEmpty,
            jlpt: jlpt,
            example: example,
            notes: notes.trimmed.nilIfEmpty
        )
    }
}

public enum VocabularyValidationError: Error, Equatable, Sendable {
    case headwordRequired
    case meaningRequired
    case exampleJapaneseRequired
    case cardDirectionRequired
}

public struct VocabularyExampleContent: Codable, Equatable, Sendable {
    public let japanese: String
    public let translationZH: String?

    public init(japanese: String, translationZH: String?) {
        self.japanese = japanese
        self.translationZH = translationZH
    }
}

public struct ValidatedVocabularyContent: Codable, Equatable, Sendable {
    public let headword: String
    public let reading: String?
    public let meaningZH: String
    public let partOfSpeech: String?
    public let jlpt: JLPTLevel?
    public let example: VocabularyExampleContent?
    public let notes: String?

    public init(
        headword: String,
        reading: String?,
        meaningZH: String,
        partOfSpeech: String?,
        jlpt: JLPTLevel?,
        example: VocabularyExampleContent?,
        notes: String?
    ) {
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.jlpt = jlpt
        self.example = example
        self.notes = notes
    }
}

public struct VocabularyExample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let japanese: String
    public let translationZH: String?
    public let sortOrder: Int

    public init(id: UUID, japanese: String, translationZH: String?, sortOrder: Int) {
        self.id = id
        self.japanese = japanese
        self.translationZH = translationZH
        self.sortOrder = sortOrder
    }
}

public struct VocabularyNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID
    public let headword: String
    public let reading: String?
    public let meaningZH: String
    public let partOfSpeech: String?
    public let jlpt: JLPTLevel?
    public let notes: String?
    public let contentVersion: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let examples: [VocabularyExample]

    public init(
        id: UUID,
        deckID: UUID,
        headword: String,
        reading: String?,
        meaningZH: String,
        partOfSpeech: String?,
        jlpt: JLPTLevel?,
        notes: String?,
        contentVersion: Int,
        createdAt: Date,
        updatedAt: Date,
        examples: [VocabularyExample]
    ) {
        self.id = id
        self.deckID = deckID
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.jlpt = jlpt
        self.notes = notes
        self.contentVersion = contentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.examples = examples
    }

    public var formData: VocabularyFormData {
        let firstExample = examples.first
        return VocabularyFormData(
            headword: headword,
            reading: reading ?? "",
            meaningZH: meaningZH,
            partOfSpeech: partOfSpeech ?? "",
            jlpt: jlpt,
            exampleJapanese: firstExample?.japanese ?? "",
            exampleTranslationZH: firstExample?.translationZH ?? "",
            notes: notes ?? ""
        )
    }
}

public struct VocabularyNoteSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID
    public let headword: String
    public let reading: String?
    public let meaningZH: String

    public init(id: UUID, deckID: UUID, headword: String, reading: String?, meaningZH: String) {
        self.id = id
        self.deckID = deckID
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
    }
}

public struct VocabularyDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID?
    public let formData: VocabularyFormData
    public let updatedAt: Date

    public init(id: UUID, deckID: UUID?, formData: VocabularyFormData, updatedAt: Date) {
        self.id = id
        self.deckID = deckID
        self.formData = formData
        self.updatedAt = updatedAt
    }
}

public enum VocabularyCardDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case japaneseToChinese
    case chineseToJapanese
}

public struct NewVocabularyCommitRequest: Equatable, Sendable {
    public let noteID: UUID
    public let deckID: UUID
    public let content: ValidatedVocabularyContent
    public let directions: Set<VocabularyCardDirection>

    public init(
        noteID: UUID,
        deckID: UUID,
        formData: VocabularyFormData,
        directions: Set<VocabularyCardDirection>
    ) throws {
        guard !directions.isEmpty else {
            throw VocabularyValidationError.cardDirectionRequired
        }
        self.noteID = noteID
        self.deckID = deckID
        content = try formData.validatedContent()
        self.directions = directions
    }
}

public protocol VocabularyCommitTransaction: Sendable {
    func commitNewVocabulary(_ request: NewVocabularyCommitRequest) async throws -> VocabularyNote
}

public protocol VocabularyRepository: Sendable {
    func fetchVocabularySummaries(deckID: UUID) async throws -> [VocabularyNoteSummary]
    func fetchVocabulary(id: UUID) async throws -> VocabularyNote?
    func saveVocabularyDraft(_ draft: VocabularyDraft) async throws
    func fetchLatestVocabularyDraft() async throws -> VocabularyDraft?
    func fetchVocabularyDraft(id: UUID) async throws -> VocabularyDraft?
    func deleteVocabularyDraft(id: UUID) async throws
    func updateVocabulary(
        id: UUID,
        content: ValidatedVocabularyContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> VocabularyNote?
}

public struct VocabularyService: Sendable {
    private let repository: any VocabularyRepository
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any VocabularyRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    public func fetchVocabularySummaries(deckID: UUID) async throws -> [VocabularyNoteSummary] {
        try await repository.fetchVocabularySummaries(deckID: deckID)
    }

    public func fetchVocabulary(id: UUID) async throws -> VocabularyNote? {
        try await repository.fetchVocabulary(id: id)
    }

    @discardableResult
    public func saveDraft(
        id: UUID?,
        deckID: UUID?,
        formData: VocabularyFormData
    ) async throws -> VocabularyDraft {
        let draft = VocabularyDraft(
            id: id ?? makeID(),
            deckID: deckID,
            formData: formData,
            updatedAt: now()
        )
        try await repository.saveVocabularyDraft(draft)
        return draft
    }

    public func fetchLatestDraft() async throws -> VocabularyDraft? {
        try await repository.fetchLatestVocabularyDraft()
    }

    public func fetchDraft(id: UUID) async throws -> VocabularyDraft? {
        try await repository.fetchVocabularyDraft(id: id)
    }

    public func deleteDraft(id: UUID) async throws {
        try await repository.deleteVocabularyDraft(id: id)
    }

    public func updateVocabulary(
        id: UUID,
        formData: VocabularyFormData
    ) async throws -> VocabularyNote? {
        let content = try formData.validatedContent()
        return try await repository.updateVocabulary(
            id: id,
            content: content,
            newExampleID: makeID(),
            at: now()
        )
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
