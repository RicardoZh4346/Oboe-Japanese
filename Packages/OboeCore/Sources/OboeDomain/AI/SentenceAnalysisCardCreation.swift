import Foundation

public struct SentenceAnalysisCardDraft: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: KnowledgePointKind
    public var headword: String
    public var reading: String
    public var meaningZH: String
    public var partOfSpeech: String
    public var usage: String
    public var connection: String
    public var exampleJapanese: String
    public var exampleTranslationZH: String
    public var notes: String
    public var vocabularyDirections: Set<VocabularyCardDirection>
    public var createDespiteDuplicate: Bool

    public init(
        id: UUID,
        kind: KnowledgePointKind,
        headword: String,
        reading: String = "",
        meaningZH: String,
        partOfSpeech: String = "",
        usage: String = "",
        connection: String = "",
        exampleJapanese: String = "",
        exampleTranslationZH: String = "",
        notes: String = "",
        vocabularyDirections: Set<VocabularyCardDirection> = [.japaneseToChinese],
        createDespiteDuplicate: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.usage = usage
        self.connection = connection
        self.exampleJapanese = exampleJapanese
        self.exampleTranslationZH = exampleTranslationZH
        self.notes = notes
        self.vocabularyDirections = vocabularyDirections
        self.createDespiteDuplicate = createDespiteDuplicate
    }

    public var vocabularyForm: VocabularyFormData {
        VocabularyFormData(
            headword: headword,
            reading: reading,
            meaningZH: meaningZH,
            partOfSpeech: partOfSpeech,
            exampleJapanese: exampleJapanese,
            exampleTranslationZH: exampleTranslationZH,
            notes: notes
        )
    }

    public var grammarForm: GrammarFormData {
        GrammarFormData(
            grammarForm: headword,
            meaningZH: meaningZH,
            usage: usage,
            connection: connection,
            exampleJapanese: exampleJapanese,
            exampleTranslationZH: exampleTranslationZH,
            notes: notes
        )
    }
}

public enum SentenceAnalysisCardCreationError: Error, Equatable, Sendable {
    case selectionRequired
    case selectedItemNotFound
    case tooManyItems(maximum: Int)
    case deckRequired
    case duplicateSourceItem
    case cardDirectionRequired
}

extension SentenceAnalysisCardCreationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .selectionRequired:
            "请至少选择一个分析项目。"
        case .selectedItemNotFound:
            "所选项目已不在当前分析结果中。"
        case let .tooManyItems(maximum):
            "单次最多保存 \(maximum) 个分析项目。"
        case .deckRequired:
            "请选择目标牌组。"
        case .duplicateSourceItem:
            "同一分析项目不能在一个批次中重复保存。"
        case .cardDirectionRequired:
            "每个单词至少需要一个卡片方向。"
        }
    }
}

public enum SentenceAnalysisCardCommitItem: Equatable, Sendable {
    case vocabulary(VocabularyContentCommit)
    case grammar(GrammarContentCommit)

    public var noteID: UUID {
        switch self {
        case let .vocabulary(commit): commit.noteID
        case let .grammar(commit): commit.noteID
        }
    }

    public var cardCount: Int {
        switch self {
        case let .vocabulary(commit): commit.cards.count
        case .grammar: 1
        }
    }
}

public struct SentenceAnalysisCardBatchCommit: Equatable, Sendable {
    public let deckID: UUID
    public let items: [SentenceAnalysisCardCommitItem]

    public init(deckID: UUID, items: [SentenceAnalysisCardCommitItem]) {
        self.deckID = deckID
        self.items = items
    }
}

public struct SentenceAnalysisCardBatchResult: Equatable, Sendable {
    public let noteIDs: [UUID]
    public let cardCount: Int

    public init(noteIDs: [UUID], cardCount: Int) {
        self.noteIDs = noteIDs
        self.cardCount = cardCount
    }
}

public protocol SentenceAnalysisCardRepository: Sendable {
    func commitSentenceAnalysisCards(
        _ batch: SentenceAnalysisCardBatchCommit
    ) async throws -> SentenceAnalysisCardBatchResult
}

public struct SentenceAnalysisCardCreationService: Sendable {
    public static let maximumBatchItems = 30

    private let repository: any SentenceAnalysisCardRepository
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any SentenceAnalysisCardRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    public func makeDrafts(
        from result: SentenceAnalysisResult,
        selectedItemIDs: Set<UUID>
    ) throws -> [SentenceAnalysisCardDraft] {
        guard !selectedItemIDs.isEmpty else {
            throw SentenceAnalysisCardCreationError.selectionRequired
        }
        guard selectedItemIDs.count <= Self.maximumBatchItems else {
            throw SentenceAnalysisCardCreationError.tooManyItems(
                maximum: Self.maximumBatchItems
            )
        }
        let selectedItems = result.items.filter { selectedItemIDs.contains($0.id) }
        guard selectedItems.count == selectedItemIDs.count else {
            throw SentenceAnalysisCardCreationError.selectedItemNotFound
        }
        return selectedItems.map { item in
            Self.makeDraft(from: item, sentence: result.sentence, translationZH: result.translationZH)
        }
    }

    public func validate(_ drafts: [SentenceAnalysisCardDraft]) throws {
        guard !drafts.isEmpty else {
            throw SentenceAnalysisCardCreationError.selectionRequired
        }
        guard drafts.count <= Self.maximumBatchItems else {
            throw SentenceAnalysisCardCreationError.tooManyItems(
                maximum: Self.maximumBatchItems
            )
        }
        guard Set(drafts.map(\.id)).count == drafts.count else {
            throw SentenceAnalysisCardCreationError.duplicateSourceItem
        }
        for draft in drafts {
            switch draft.kind {
            case .vocabulary:
                guard !draft.vocabularyDirections.isEmpty else {
                    throw SentenceAnalysisCardCreationError.cardDirectionRequired
                }
                _ = try draft.vocabularyForm.validatedContent()
            case .grammar:
                _ = try draft.grammarForm.validatedContent()
            }
        }
    }

    public func commit(
        deckID: UUID?,
        drafts: [SentenceAnalysisCardDraft]
    ) async throws -> SentenceAnalysisCardBatchResult {
        guard let deckID else {
            throw SentenceAnalysisCardCreationError.deckRequired
        }
        try validate(drafts)
        let createdAt = now()
        let items = try drafts.map { draft -> SentenceAnalysisCardCommitItem in
            switch draft.kind {
            case .vocabulary:
                let cards = draft.vocabularyDirections
                    .map(\.templateKind)
                    .sorted { $0.rawValue < $1.rawValue }
                    .map { NewCardSeed(id: makeID(), templateKind: $0) }
                return .vocabulary(
                    VocabularyContentCommit(
                        noteID: makeID(),
                        exampleID: makeID(),
                        draftID: nil,
                        deckID: deckID,
                        content: try draft.vocabularyForm.validatedContent(),
                        tags: [],
                        cards: cards,
                        schedulerProfileID: makeID(),
                        createdAt: createdAt
                    )
                )
            case .grammar:
                return .grammar(
                    GrammarContentCommit(
                        noteID: makeID(),
                        exampleID: makeID(),
                        draftID: nil,
                        deckID: deckID,
                        content: try draft.grammarForm.validatedContent(),
                        tags: [],
                        card: NewCardSeed(
                            id: makeID(),
                            templateKind: .grammarFormToExplanation
                        ),
                        schedulerProfileID: makeID(),
                        createdAt: createdAt
                    )
                )
            }
        }
        return try await repository.commitSentenceAnalysisCards(
            SentenceAnalysisCardBatchCommit(deckID: deckID, items: items)
        )
    }

    private static func makeDraft(
        from item: SentenceAnalysisItem,
        sentence: String,
        translationZH: String
    ) -> SentenceAnalysisCardDraft {
        let suggestion = item.suggestedCard
        let kind: KnowledgePointKind
        if let suggestion {
            kind = suggestion.kind == .vocabulary ? .vocabulary : .grammar
        } else {
            switch item.kind {
            case .grammar, .particle:
                kind = .grammar
            case .vocabulary, .expression:
                kind = .vocabulary
            }
        }
        let fallbackHeadword = item.canonicalForm.isEmpty ? item.surface : item.canonicalForm
        let headword = suggestion?.headword.nonEmpty ?? fallbackHeadword
        let meaning = suggestion?.meaningZH.nonEmpty ?? item.meaningZH
        let reading = suggestion?.reading.nonEmpty ?? item.reading
        let notes = suggestion?.notes.nonEmpty ?? item.roleZH
        return SentenceAnalysisCardDraft(
            id: item.id,
            kind: kind,
            headword: headword,
            reading: reading,
            meaningZH: meaning,
            partOfSpeech: suggestion?.partOfSpeech ?? "",
            usage: suggestion?.usage.nonEmpty ?? (kind == .grammar ? item.roleZH : ""),
            connection: suggestion?.connection ?? "",
            exampleJapanese: sentence,
            exampleTranslationZH: translationZH,
            notes: notes
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
