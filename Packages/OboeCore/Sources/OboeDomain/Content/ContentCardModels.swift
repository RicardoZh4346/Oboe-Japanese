import Foundation

public struct CardDirectionState: Equatable, Identifiable, Sendable {
    public let cardID: UUID
    public let templateKind: CardTemplateKind
    public let isEnabled: Bool

    public init(cardID: UUID, templateKind: CardTemplateKind, isEnabled: Bool) {
        self.cardID = cardID
        self.templateKind = templateKind
        self.isEnabled = isEnabled
    }

    public var id: UUID { cardID }
}

public struct NewCardSeed: Equatable, Sendable {
    public let id: UUID
    public let templateKind: CardTemplateKind

    public init(id: UUID, templateKind: CardTemplateKind) {
        self.id = id
        self.templateKind = templateKind
    }
}

public struct ContentCommitResult: Equatable, Sendable {
    public let noteID: UUID
    public let cardCount: Int
    public let wasCreated: Bool

    public init(noteID: UUID, cardCount: Int, wasCreated: Bool = true) {
        self.noteID = noteID
        self.cardCount = cardCount
        self.wasCreated = wasCreated
    }
}

public enum ContentOrigin: String, Equatable, Sendable {
    case manual
    case ai
    case builtinJLPT = "builtin_jlpt"
}

public enum ContentCardError: Error, Equatable, Sendable {
    case deckRequired
    case cardDirectionRequired
    case deckNotFound
    case knowledgePointNotFound
    case cardNotFound
    case invalidTemplateForKnowledgePoint
    /// 提交的来源记录 noteID 与本次 commit 的 noteID 不一致——
    /// 静默错挂到其它 Note 比失败更糟，事务层直接拒绝（设计 §6.2）。
    case sourceContextNoteMismatch
}

public struct VocabularyContentCommit: Equatable, Sendable {
    public let noteID: UUID
    public let exampleID: UUID
    public let draftID: UUID?
    /// 归属（home）牌组。
    public let deckID: UUID
    /// Note 的全部成员牌组；始终包含 `deckID`。
    public let deckIDs: Set<UUID>
    public let content: ValidatedVocabularyContent
    public let tags: [KnowledgeTag]
    public let cards: [NewCardSeed]
    public let schedulerProfileID: UUID
    public let createdAt: Date
    public let origin: ContentOrigin
    public let sourceRef: String?
    /// The exact text the user processed (capture commits only). Persisted to
    /// notes.source_text; never occupies source_ref.
    public let sourceText: String?
    /// 装配好的来源记录（v15）：由 service 以 noteID/createdAt 装配，
    /// repository 在 Note/Card 同事务内插入——重试不生成第二来源，
    /// 内容变动后的重试经 digest 判冲突（设计 §6.2）。
    public let sourceContext: SourceContext?

    public init(
        noteID: UUID,
        exampleID: UUID,
        draftID: UUID?,
        deckID: UUID,
        content: ValidatedVocabularyContent,
        tags: [KnowledgeTag],
        cards: [NewCardSeed],
        schedulerProfileID: UUID,
        createdAt: Date,
        origin: ContentOrigin = .manual,
        sourceRef: String? = nil,
        sourceText: String? = nil,
        deckIDs: Set<UUID>? = nil,
        sourceContext: SourceContext? = nil
    ) {
        self.noteID = noteID
        self.exampleID = exampleID
        self.draftID = draftID
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? [deckID]).union([deckID])
        self.content = content
        self.tags = tags
        self.cards = cards
        self.schedulerProfileID = schedulerProfileID
        self.createdAt = createdAt
        self.origin = origin
        self.sourceRef = sourceRef
        self.sourceText = sourceText
        self.sourceContext = sourceContext
    }
}

public struct GrammarContentCommit: Equatable, Sendable {
    public let noteID: UUID
    public let exampleID: UUID
    public let draftID: UUID?
    /// 归属（home）牌组。
    public let deckID: UUID
    /// Note 的全部成员牌组；始终包含 `deckID`。
    public let deckIDs: Set<UUID>
    public let content: ValidatedGrammarContent
    public let tags: [KnowledgeTag]
    public let card: NewCardSeed
    public let schedulerProfileID: UUID
    public let createdAt: Date
    public let origin: ContentOrigin
    public let sourceText: String?
    /// 同 `VocabularyContentCommit.sourceContext`。
    public let sourceContext: SourceContext?

    public init(
        noteID: UUID,
        exampleID: UUID,
        draftID: UUID?,
        deckID: UUID,
        content: ValidatedGrammarContent,
        tags: [KnowledgeTag],
        card: NewCardSeed,
        schedulerProfileID: UUID,
        createdAt: Date,
        origin: ContentOrigin = .manual,
        sourceText: String? = nil,
        deckIDs: Set<UUID>? = nil,
        sourceContext: SourceContext? = nil
    ) {
        self.noteID = noteID
        self.exampleID = exampleID
        self.draftID = draftID
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? [deckID]).union([deckID])
        self.content = content
        self.tags = tags
        self.card = card
        self.schedulerProfileID = schedulerProfileID
        self.createdAt = createdAt
        self.origin = origin
        self.sourceText = sourceText
        self.sourceContext = sourceContext
    }
}

public struct CardDirectionReplacement: Equatable, Sendable {
    public let noteID: UUID
    public let kind: KnowledgePointKind
    public let enabledCards: [NewCardSeed]
    public let schedulerProfileID: UUID
    public let updatedAt: Date

    public init(
        noteID: UUID,
        kind: KnowledgePointKind,
        enabledCards: [NewCardSeed],
        schedulerProfileID: UUID,
        updatedAt: Date
    ) {
        self.noteID = noteID
        self.kind = kind
        self.enabledCards = enabledCards
        self.schedulerProfileID = schedulerProfileID
        self.updatedAt = updatedAt
    }
}

public protocol ContentCardRepository: Sendable {
    func commitVocabulary(
        _ commit: VocabularyContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult
    func commitGrammar(
        _ commit: GrammarContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult
    func fetchCardDirections(noteID: UUID) async throws -> [CardDirectionState]
    func replaceEnabledCardDirections(
        _ replacement: CardDirectionReplacement
    ) async throws -> [CardDirectionState]
    /// Single-card suspend/resume (design §5.2). Writes only `is_enabled`;
    /// suspending applies the existing daily_tasks cancellation rule for that
    /// card alone. Scheduling fields, logs and the note are untouched.
    func setCardEnabled(
        cardID: UUID,
        isEnabled: Bool,
        at updatedAt: Date
    ) async throws -> CardDirectionState
    /// Single-card delete for the repair split flow (design §5.3): removes
    /// only the target Card row — siblings and the Note survive even when this
    /// was the last card. `review_logs.card_id` SET NULLs while `card_key`
    /// history stays orphaned; `daily_tasks` rows cascade away.
    func deleteCard(cardID: UUID) async throws
}

public struct ContentCardService: Sendable {
    private let repository: any ContentCardRepository
    private let sourceContextService = SourceContextService()
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        repository: any ContentCardRepository,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.now = now
        self.makeID = makeID
    }

    /// `deckIDs` 为 Note 的全部成员牌组；缺省时仅以 `deckID`（home）为成员。
    public func commitVocabulary(
        draftID: UUID?,
        deckID: UUID?,
        formData: VocabularyFormData,
        directions: Set<VocabularyCardDirection>,
        rawTagNames: [String] = [],
        origin: ContentOrigin = .manual,
        sourceRef: String? = nil,
        capture: CaptureCommitContext? = nil,
        deckIDs: Set<UUID>? = nil,
        sourceContext: SourceContextDraft? = nil
    ) async throws -> ContentCommitResult {
        guard let deckID else {
            throw ContentCardError.deckRequired
        }
        let request = try NewVocabularyCommitRequest(
            noteID: makeID(),
            deckID: deckID,
            formData: formData,
            directions: directions
        )
        let cards = directions
            .map(\.templateKind)
            .sorted { $0.rawValue < $1.rawValue }
            .map { NewCardSeed(id: makeID(), templateKind: $0) }
        let createdAt = now()
        let commit = VocabularyContentCommit(
            noteID: request.noteID,
            exampleID: makeID(),
            draftID: draftID,
            deckID: request.deckID,
            content: request.content,
            tags: try makeTags(rawTagNames),
            cards: cards,
            schedulerProfileID: makeID(),
            createdAt: createdAt,
            origin: origin,
            sourceRef: sourceRef,
            sourceText: capture?.sourceText,
            deckIDs: deckIDs,
            sourceContext: sourceContext.map {
                // 新 Note 尚无既有来源——resolvePrimary 恒为原样；
                // 追加来源的路径走 SourceContextRepository，不经这里。
                sourceContextService.makeContext(
                    from: $0,
                    noteID: request.noteID,
                    now: createdAt,
                    makeID: makeID
                )
            }
        )
        return try await repository.commitVocabulary(commit, capture: capture)
    }

    /// `deckIDs` 为 Note 的全部成员牌组；缺省时仅以 `deckID`（home）为成员。
    public func commitGrammar(
        draftID: UUID?,
        deckID: UUID?,
        formData: GrammarFormData,
        includesDirection: Bool,
        rawTagNames: [String] = [],
        origin: ContentOrigin = .manual,
        capture: CaptureCommitContext? = nil,
        deckIDs: Set<UUID>? = nil,
        sourceContext: SourceContextDraft? = nil
    ) async throws -> ContentCommitResult {
        guard let deckID else {
            throw ContentCardError.deckRequired
        }
        guard includesDirection else {
            throw ContentCardError.cardDirectionRequired
        }
        let noteID = makeID()
        let createdAt = now()
        let commit = GrammarContentCommit(
            noteID: noteID,
            exampleID: makeID(),
            draftID: draftID,
            deckID: deckID,
            content: try formData.validatedContent(),
            tags: try makeTags(rawTagNames),
            card: NewCardSeed(id: makeID(), templateKind: .grammarFormToExplanation),
            schedulerProfileID: makeID(),
            createdAt: createdAt,
            origin: origin,
            sourceText: capture?.sourceText,
            deckIDs: deckIDs,
            sourceContext: sourceContext.map {
                sourceContextService.makeContext(
                    from: $0,
                    noteID: noteID,
                    now: createdAt,
                    makeID: makeID
                )
            }
        )
        return try await repository.commitGrammar(commit, capture: capture)
    }

    public func fetchCardDirections(noteID: UUID) async throws -> [CardDirectionState] {
        try await repository.fetchCardDirections(noteID: noteID)
    }

    public func replaceEnabledCardDirections(
        noteID: UUID,
        kind: KnowledgePointKind,
        enabledTemplates: Set<CardTemplateKind>
    ) async throws -> [CardDirectionState] {
        guard enabledTemplates.allSatisfy({ $0.knowledgePointKind == kind }) else {
            throw ContentCardError.invalidTemplateForKnowledgePoint
        }
        let cards = enabledTemplates
            .sorted { $0.rawValue < $1.rawValue }
            .map { NewCardSeed(id: makeID(), templateKind: $0) }
        return try await repository.replaceEnabledCardDirections(
            CardDirectionReplacement(
                noteID: noteID,
                kind: kind,
                enabledCards: cards,
                schedulerProfileID: makeID(),
                updatedAt: now()
            )
        )
    }

    /// Adaptive-detail suspend/resume entry point (T04): a single-card
    /// command, deliberately NOT routed through `replaceEnabledCardDirections`
    /// which would rewrite the note's whole direction set (design §5.2).
    public func setCardEnabled(
        cardID: UUID,
        isEnabled: Bool
    ) async throws -> CardDirectionState {
        try await repository.setCardEnabled(
            cardID: cardID,
            isEnabled: isEnabled,
            at: now()
        )
    }

    /// Repair-split helper (T08 consumes it inside its own transaction via the
    /// repository's `in db` overload); exposed for direct single-card deletes.
    public func deleteCard(cardID: UUID) async throws {
        try await repository.deleteCard(cardID: cardID)
    }

    private func makeTags(_ rawNames: [String]) throws -> [KnowledgeTag] {
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
        return tags
    }
}

public extension CardTemplateKind {
    var knowledgePointKind: KnowledgePointKind {
        switch self {
        case .vocabularyJapaneseToChinese, .vocabularyChineseToJapanese, .vocabularyListening:
            .vocabulary
        case .grammarFormToExplanation:
            .grammar
        }
    }

    /// Directions offered wherever card directions are picked — the note
    /// editor's direction management, the repair split toggles and the
    /// repository's replace-set validation all share this whitelist.
    static func applicable(to kind: KnowledgePointKind) -> [CardTemplateKind] {
        switch kind {
        case .vocabulary:
            [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese, .vocabularyListening]
        case .grammar:
            [.grammarFormToExplanation]
        }
    }
}

public extension VocabularyCardDirection {
    var templateKind: CardTemplateKind {
        switch self {
        case .japaneseToChinese:
            .vocabularyJapaneseToChinese
        case .chineseToJapanese:
            .vocabularyChineseToJapanese
        case .listening:
            .vocabularyListening
        }
    }
}
