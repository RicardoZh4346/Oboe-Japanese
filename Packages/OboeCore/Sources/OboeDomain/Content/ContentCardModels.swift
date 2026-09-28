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
    /// v0.7.0 S12（设计 §9.1）：Reader 挖词/挖句与 CSV/TSV 导入来源。
    /// 只加合法值，不改旧值语义。
    case reader
    case `import`
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
    /// v0.7.0 S12（设计 §9.1）：`sentence_cloze` 卡不是可单独删除的方向卡
    /// ——裸删会让 sentence Note 失去唯一卡片与 definition。删除 Cloze
    /// 必须走整条 Note 删除（`deleteKnowledgePoint`）。
    case clozeDeletionRequiresNoteDelete
    /// v0.7.0 S12：sentence Note 的卡片集合不可经方向替换改写——
    /// 它恒为恰好一张 `sentence_cloze` 卡，方向管理只覆盖词汇/语法。
    case sentenceCardsNotDirectionManaged
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
    /// v0.7.0 S12：sentence Note + `sentence_cloze` Card +
    /// `cloze_definitions` 的原子提交（设计 §9.1–9.3）。
    func commitSentence(
        _ commit: SentenceContentCommit,
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

    /// v0.7.0 S12：装配并提交一条 sentence/Cloze 创建命令。blank 校验
    /// 在 `ValidatedClozeContent` 构造内完成——非法 range/表面不符/空
    /// 答案集/surface 缺失在持久化前抛 `ClozeError`，不产生任何写入。
    /// `deckIDs` 语义与 `commitVocabulary` 相同。
    public func commitSentence(
        deckID: UUID?,
        sentenceSnapshot: String,
        utf16Start: Int,
        utf16Length: Int,
        targetSurface: String,
        targetLemma: String? = nil,
        targetReading: String? = nil,
        acceptedAnswers: [String],
        hint: String? = nil,
        meaningZH: String? = nil,
        notes: String? = nil,
        rawTagNames: [String] = [],
        origin: ContentOrigin = .manual,
        capture: CaptureCommitContext? = nil,
        deckIDs: Set<UUID>? = nil,
        sourceContext: SourceContextDraft? = nil
    ) async throws -> ContentCommitResult {
        guard let deckID else {
            throw ContentCardError.deckRequired
        }
        let cloze = try ValidatedClozeContent(
            sentenceSnapshot: sentenceSnapshot,
            utf16Start: utf16Start,
            utf16Length: utf16Length,
            targetSurface: targetSurface,
            targetLemma: targetLemma,
            targetReading: targetReading,
            acceptedAnswers: acceptedAnswers,
            hint: hint
        )
        let noteID = makeID()
        let createdAt = now()
        let commit = SentenceContentCommit(
            noteID: noteID,
            clozeID: makeID(),
            deckID: deckID,
            cloze: cloze,
            card: NewCardSeed(id: makeID(), templateKind: .sentenceCloze),
            schedulerProfileID: makeID(),
            createdAt: createdAt,
            meaningZH: meaningZH,
            notes: notes,
            tags: try makeTags(rawTagNames),
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
        return try await repository.commitSentence(commit, capture: capture)
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
        case .sentenceCloze:
            .sentence
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
        case .sentence:
            // 句子 Note 恒为恰好一张 sentence_cloze——该集合只用于
            // kind↔template 映射校验；方向替换对 sentence 一律拒绝
            // （仓储层 `sentenceCardsNotDirectionManaged`）。
            [.sentenceCloze]
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
