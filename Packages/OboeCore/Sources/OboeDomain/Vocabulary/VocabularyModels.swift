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
    /// 东京式音调核位置；nil 表示未设置。UI 展示为“音调”。
    public var pitchAccent: PitchAccent?

    public init(
        headword: String = "",
        reading: String = "",
        meaningZH: String = "",
        partOfSpeech: String = "",
        jlpt: JLPTLevel? = nil,
        exampleJapanese: String = "",
        exampleTranslationZH: String = "",
        notes: String = "",
        pitchAccent: PitchAccent? = nil
    ) {
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.jlpt = jlpt
        self.exampleJapanese = exampleJapanese
        self.exampleTranslationZH = exampleTranslationZH
        self.notes = notes
        self.pitchAccent = pitchAccent
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

        let readingValue = reading.trimmed.nilIfEmpty
        if let pitchAccent {
            guard readingValue != nil else {
                throw VocabularyValidationError.pitchAccentRequiresReading
            }
            guard pitchAccent.isConsistent(withReading: readingValue) else {
                throw VocabularyValidationError.pitchAccentExceedsMora
            }
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
            reading: readingValue,
            meaningZH: meaningZH,
            partOfSpeech: partOfSpeech.trimmed.nilIfEmpty,
            jlpt: jlpt,
            example: example,
            notes: notes.trimmed.nilIfEmpty,
            pitchAccent: pitchAccent
        )
    }
}

public enum VocabularyValidationError: Error, Equatable, Sendable {
    case headwordRequired
    case meaningRequired
    case exampleJapaneseRequired
    case cardDirectionRequired
    case pitchAccentRequiresReading
    case pitchAccentExceedsMora
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
    public let pitchAccent: PitchAccent?

    public init(
        headword: String,
        reading: String?,
        meaningZH: String,
        partOfSpeech: String?,
        jlpt: JLPTLevel?,
        example: VocabularyExampleContent?,
        notes: String?,
        pitchAccent: PitchAccent? = nil
    ) {
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.jlpt = jlpt
        self.example = example
        self.notes = notes
        self.pitchAccent = pitchAccent
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
    /// 归属（home）牌组；成员全集见 `deckIDs`。
    public let deckID: UUID
    /// 该 Note 的全部成员牌组；始终包含 `deckID`。
    public let deckIDs: Set<UUID>
    public let headword: String
    public let reading: String?
    public let meaningZH: String
    public let partOfSpeech: String?
    public let jlpt: JLPTLevel?
    public let notes: String?
    public let pitchAccent: PitchAccent?
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
        examples: [VocabularyExample],
        pitchAccent: PitchAccent? = nil,
        deckIDs: Set<UUID>? = nil
    ) {
        self.id = id
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? [deckID]).union([deckID])
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.jlpt = jlpt
        self.notes = notes
        self.pitchAccent = pitchAccent
        self.contentVersion = contentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.examples = examples
    }

    /// 兼容旧 JSON：缺失 `deckIDs` 键时以 home deck 为唯一成员。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        deckID = try container.decode(UUID.self, forKey: .deckID)
        deckIDs = (try container.decodeIfPresent(Set<UUID>.self, forKey: .deckIDs) ?? [deckID])
            .union([deckID])
        headword = try container.decode(String.self, forKey: .headword)
        reading = try container.decodeIfPresent(String.self, forKey: .reading)
        meaningZH = try container.decode(String.self, forKey: .meaningZH)
        partOfSpeech = try container.decodeIfPresent(String.self, forKey: .partOfSpeech)
        jlpt = try container.decodeIfPresent(JLPTLevel.self, forKey: .jlpt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        pitchAccent = try container.decodeIfPresent(PitchAccent.self, forKey: .pitchAccent)
        contentVersion = try container.decode(Int.self, forKey: .contentVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        examples = try container.decode([VocabularyExample].self, forKey: .examples)
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
            notes: notes ?? "",
            pitchAccent: pitchAccent
        )
    }
}

public struct VocabularyNoteSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 归属（home）牌组；成员全集见 `deckIDs`。
    public let deckID: UUID
    public let deckIDs: Set<UUID>
    public let headword: String
    public let reading: String?
    public let meaningZH: String

    public init(
        id: UUID,
        deckID: UUID,
        headword: String,
        reading: String?,
        meaningZH: String,
        deckIDs: Set<UUID>? = nil
    ) {
        self.id = id
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? [deckID]).union([deckID])
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
    }
}

public struct VocabularyDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 归属（home）牌组；v0.5 起对应 payload 的 `homeDeckID`，旧 payload 的
    /// `deckID` 解码时自动迁移到这里并同时成为唯一 `deckIDs` 元素。
    public let deckID: UUID?
    /// 草稿提交后 Note 应归属的全部牌组；始终包含 `deckID`（若非空）。
    public let deckIDs: Set<UUID>
    public let formData: VocabularyFormData
    public let updatedAt: Date

    public init(
        id: UUID,
        deckID: UUID?,
        deckIDs: Set<UUID>? = nil,
        formData: VocabularyFormData,
        updatedAt: Date
    ) {
        self.id = id
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? []).union(deckID.map { [$0] } ?? [])
        self.formData = formData
        self.updatedAt = updatedAt
    }
}

public enum VocabularyCardDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case japaneseToChinese
    case chineseToJapanese
    /// Audio-prompt → Chinese meaning. Persisted as `vocabulary_listening`;
    /// the review question face is built by the dedicated listening view.
    case listening
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
        deckIDs: Set<UUID>? = nil,
        formData: VocabularyFormData
    ) async throws -> VocabularyDraft {
        let draft = VocabularyDraft(
            id: id ?? makeID(),
            deckID: deckID,
            deckIDs: deckIDs,
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
