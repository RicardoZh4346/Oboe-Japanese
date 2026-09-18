import Foundation

public struct GrammarFormData: Codable, Equatable, Sendable {
    public var grammarForm: String
    public var meaningZH: String
    public var usage: String
    public var connection: String
    public var exampleJapanese: String
    public var exampleTranslationZH: String
    public var jlpt: JLPTLevel?
    public var notes: String

    public init(
        grammarForm: String = "",
        meaningZH: String = "",
        usage: String = "",
        connection: String = "",
        exampleJapanese: String = "",
        exampleTranslationZH: String = "",
        jlpt: JLPTLevel? = nil,
        notes: String = ""
    ) {
        self.grammarForm = grammarForm
        self.meaningZH = meaningZH
        self.usage = usage
        self.connection = connection
        self.exampleJapanese = exampleJapanese
        self.exampleTranslationZH = exampleTranslationZH
        self.jlpt = jlpt
        self.notes = notes
    }

    public func validatedContent() throws -> ValidatedGrammarContent {
        let grammarForm = self.grammarForm.grammarTrimmed
        guard !grammarForm.isEmpty else {
            throw GrammarValidationError.grammarFormRequired
        }

        let meaningZH = self.meaningZH.grammarTrimmed
        guard !meaningZH.isEmpty else {
            throw GrammarValidationError.meaningRequired
        }

        let exampleJapanese = self.exampleJapanese.grammarTrimmed
        let exampleTranslationZH = self.exampleTranslationZH.grammarTrimmed
        guard !exampleJapanese.isEmpty || exampleTranslationZH.isEmpty else {
            throw GrammarValidationError.exampleJapaneseRequired
        }

        let example: GrammarExampleContent?
        if exampleJapanese.isEmpty {
            example = nil
        } else {
            example = GrammarExampleContent(
                japanese: exampleJapanese,
                translationZH: exampleTranslationZH.grammarNilIfEmpty
            )
        }

        return ValidatedGrammarContent(
            grammarForm: grammarForm,
            meaningZH: meaningZH,
            usage: usage.grammarTrimmed.grammarNilIfEmpty,
            connection: connection.grammarTrimmed.grammarNilIfEmpty,
            example: example,
            jlpt: jlpt,
            notes: notes.grammarTrimmed.grammarNilIfEmpty
        )
    }
}

public enum GrammarValidationError: Error, Equatable, Sendable {
    case grammarFormRequired
    case meaningRequired
    case exampleJapaneseRequired
}

public struct GrammarExampleContent: Codable, Equatable, Sendable {
    public let japanese: String
    public let translationZH: String?

    public init(japanese: String, translationZH: String?) {
        self.japanese = japanese
        self.translationZH = translationZH
    }
}

public struct ValidatedGrammarContent: Codable, Equatable, Sendable {
    public let grammarForm: String
    public let meaningZH: String
    public let usage: String?
    public let connection: String?
    public let example: GrammarExampleContent?
    public let jlpt: JLPTLevel?
    public let notes: String?

    public init(
        grammarForm: String,
        meaningZH: String,
        usage: String?,
        connection: String?,
        example: GrammarExampleContent?,
        jlpt: JLPTLevel?,
        notes: String?
    ) {
        self.grammarForm = grammarForm
        self.meaningZH = meaningZH
        self.usage = usage
        self.connection = connection
        self.example = example
        self.jlpt = jlpt
        self.notes = notes
    }
}

public struct GrammarExample: Codable, Equatable, Identifiable, Sendable {
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

public struct GrammarNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID
    public let grammarForm: String
    public let meaningZH: String
    public let usage: String?
    public let connection: String?
    public let jlpt: JLPTLevel?
    public let notes: String?
    public let contentVersion: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let examples: [GrammarExample]

    public init(
        id: UUID,
        deckID: UUID,
        grammarForm: String,
        meaningZH: String,
        usage: String?,
        connection: String?,
        jlpt: JLPTLevel?,
        notes: String?,
        contentVersion: Int,
        createdAt: Date,
        updatedAt: Date,
        examples: [GrammarExample]
    ) {
        self.id = id
        self.deckID = deckID
        self.grammarForm = grammarForm
        self.meaningZH = meaningZH
        self.usage = usage
        self.connection = connection
        self.jlpt = jlpt
        self.notes = notes
        self.contentVersion = contentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.examples = examples
    }

    public var formData: GrammarFormData {
        let firstExample = examples.first
        return GrammarFormData(
            grammarForm: grammarForm,
            meaningZH: meaningZH,
            usage: usage ?? "",
            connection: connection ?? "",
            exampleJapanese: firstExample?.japanese ?? "",
            exampleTranslationZH: firstExample?.translationZH ?? "",
            jlpt: jlpt,
            notes: notes ?? ""
        )
    }
}

public struct GrammarDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID?
    public let formData: GrammarFormData
    public let updatedAt: Date

    public init(id: UUID, deckID: UUID?, formData: GrammarFormData, updatedAt: Date) {
        self.id = id
        self.deckID = deckID
        self.formData = formData
        self.updatedAt = updatedAt
    }
}

public protocol GrammarRepository: Sendable {
    func fetchGrammar(id: UUID) async throws -> GrammarNote?
    func saveGrammarDraft(_ draft: GrammarDraft) async throws
    func fetchLatestGrammarDraft() async throws -> GrammarDraft?
    func fetchGrammarDraft(id: UUID) async throws -> GrammarDraft?
    func deleteGrammarDraft(id: UUID) async throws
    func updateGrammar(
        id: UUID,
        content: ValidatedGrammarContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> GrammarNote?
}

public struct GrammarService: Sendable {
    private let repository: any GrammarRepository
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any GrammarRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    public func fetchGrammar(id: UUID) async throws -> GrammarNote? {
        try await repository.fetchGrammar(id: id)
    }

    @discardableResult
    public func saveDraft(id: UUID?, deckID: UUID?, formData: GrammarFormData) async throws -> GrammarDraft {
        let draft = GrammarDraft(
            id: id ?? makeID(),
            deckID: deckID,
            formData: formData,
            updatedAt: now()
        )
        try await repository.saveGrammarDraft(draft)
        return draft
    }

    public func fetchLatestDraft() async throws -> GrammarDraft? {
        try await repository.fetchLatestGrammarDraft()
    }

    public func fetchDraft(id: UUID) async throws -> GrammarDraft? {
        try await repository.fetchGrammarDraft(id: id)
    }

    public func deleteDraft(id: UUID) async throws {
        try await repository.deleteGrammarDraft(id: id)
    }

    public func updateGrammar(id: UUID, formData: GrammarFormData) async throws -> GrammarNote? {
        let content = try formData.validatedContent()
        return try await repository.updateGrammar(
            id: id,
            content: content,
            newExampleID: makeID(),
            at: now()
        )
    }
}

private extension String {
    var grammarTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var grammarNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
