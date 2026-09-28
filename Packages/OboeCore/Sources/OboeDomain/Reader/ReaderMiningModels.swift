import Foundation

/// v0.7.0 S11：Reader 挖词（Mining）领域模型与事务边界。
/// 依据：详细技术实现文档 §6.2/§11.2 + S03/S08/S12 已落地基建。
///
/// 边界划分：
/// - `ReaderMiningService`（OboeDomain）：lookup 编排（词典 → 候选 →
///   知识状态 → 已关联 Note）、请求装配、generation 乱序保护、批量调度。
/// - `ReaderMiningStore`（OboeInfrastructure/GRDB）：一次 `pool.write`
///   内完成 receipt 回放检查 → Note/来源/membership → lexeme 关联 →
///   活动事件 → receipt 记录，全部同事务。
///
/// 幂等：`operationID` 由调用方生成并对同一次用户操作保持稳定
/// （Inspector 打开时生成一次，重试复用）。`reader_mining_receipts`
/// 行按 operation_id 回放；同 ID 不同负载 → `operationPayloadConflict`。
///
/// 乱序保护：请求携带 `expectedGeneration`（发起时的数据库世代），
/// 服务在写事务内复核 `isCurrentGeneration`——恢复/迁移后旧世代的
/// 请求一律 `staleGeneration` 拒绝，不写回。

// MARK: - 点词定位与快照

/// 挖词的原文定位 + 快照字段。持久化进 `source_contexts` 的
/// `reader_*`/`selected_surface`/`original_sentence`/`surrounding_text`。
/// Reader 定位是弱引用（§4.3-5）：文档删除后来源行原样保留。
public struct ReaderMiningContext: Equatable, Sendable {
    public let documentID: UUID
    public let chapterID: UUID
    /// 块级定位（章序+块序+块内 UTF-16 偏移+块 hash+前后文）。
    public let location: ReaderLocation
    /// 挖词所在句（UI 从块文本截取）。
    public let sentence: String
    /// 句前后文，有界（`SourceContextDraft.maximumSurroundingCharacters`）。
    public let surroundingText: String?
    /// 点词表面原文（选中的 token surface）。
    public let selectedSurface: String
    /// 文档标题快照。
    public let sourceTitle: String?

    public init(
        documentID: UUID,
        chapterID: UUID,
        location: ReaderLocation,
        sentence: String,
        surroundingText: String?,
        selectedSurface: String,
        sourceTitle: String?
    ) {
        self.documentID = documentID
        self.chapterID = chapterID
        self.location = location
        self.sentence = sentence
        self.surroundingText = surroundingText
        self.selectedSurface = selectedSurface
        self.sourceTitle = sourceTitle
    }
}

// MARK: - 查询侧（Inspector 数据）

/// 单个义项的展示/选择投影。
public struct ReaderMiningSense: Equatable, Identifiable, Sendable {
    /// 词条 `senses.id`（词条内唯一）。
    public let id: Int64
    public let posCodes: [String]
    /// zh→en 优先链拼出的释义摘要；空 = 本义项无可用 gloss。
    public let glossText: String
    /// 实际释义语言（"zho"/"eng"）——英语兜底如实标记（D08）。
    public let glossLanguage: String?
    /// `source_contexts.dictionary_sense_key` 的稳定值：
    /// "<entryID>:<senseID>"——跨快照可比对的义项指纹。
    public let senseKey: String

    public init(
        id: Int64,
        posCodes: [String],
        glossText: String,
        glossLanguage: String?,
        senseKey: String
    ) {
        self.id = id
        self.posCodes = posCodes
        self.glossText = glossText
        self.glossLanguage = glossLanguage
        self.senseKey = senseKey
    }
}

/// 已存在的词汇 Note 摘要（重复 Note 选择 / 已关联展示用）。
public struct ReaderLinkedNote: Equatable, Identifiable, Sendable {
    public var id: UUID { noteID }
    public let noteID: UUID
    public let headword: String
    public let reading: String?
    public let meaningZH: String
    /// 归属（home）牌组。
    public let deckID: UUID

    public init(
        noteID: UUID,
        headword: String,
        reading: String?,
        meaningZH: String,
        deckID: UUID
    ) {
        self.noteID = noteID
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.deckID = deckID
    }
}

/// 挖词候选（Inspector 候选列表行）：词典条目或 OOV 本地身份。
/// `lexicalKey` 已按 `LexicalIdentityKey` 编码——挖词时直接作
/// lexeme 身份，不产生第二处 key 构造点。
public struct ReaderMiningCandidate: Equatable, Identifiable, Sendable {
    public var id: String { lexicalKey.identityKey }
    public let lexicalKey: LexicalKey
    /// 已落库 lexeme 的 id（未落库 = nil）。
    public let lexemeID: UUID?
    public let knowledgeState: VocabularyKnowledgeState
    /// 词典原形/首选表记。
    public let writtenForm: String
    public let reading: String?
    /// 词条级 POS code 交集。
    public let posCodes: [String]
    /// JMdict entryID；OOV/local 候选为 nil。
    public let entryID: Int64?
    /// 义项列表（义项选择 UI 数据）。
    public let senses: [ReaderMiningSense]
    /// 已关联到该 lexeme 的既有词汇 Note（「只加来源」候选）。
    public let linkedNotes: [ReaderLinkedNote]
    /// 候选来源说明（deinflect 链等，UI 诊断展示）。
    public let reasons: [String]
    /// 词典 dataset version（provenance——lexeme 行与来源快照用）。
    public let dictionaryVersion: String?

    public init(
        lexicalKey: LexicalKey,
        lexemeID: UUID?,
        knowledgeState: VocabularyKnowledgeState,
        writtenForm: String,
        reading: String?,
        posCodes: [String],
        entryID: Int64?,
        senses: [ReaderMiningSense],
        linkedNotes: [ReaderLinkedNote],
        reasons: [String] = [],
        dictionaryVersion: String? = nil
    ) {
        self.lexicalKey = lexicalKey
        self.lexemeID = lexemeID
        self.knowledgeState = knowledgeState
        self.writtenForm = writtenForm
        self.reading = reading
        self.posCodes = posCodes
        self.entryID = entryID
        self.senses = senses
        self.linkedNotes = linkedNotes
        self.reasons = reasons
        self.dictionaryVersion = dictionaryVersion
    }
}

/// `lookup` 结果：候选 + 重名 Note + 是否必须显式选择。
public struct ReaderMiningLookup: Equatable, Sendable {
    public let surface: String
    public let reading: String?
    public let candidates: [ReaderMiningCandidate]
    /// 与挖词目标（候选 lemma 或表面）内容重名的既有词汇 Note——
    /// 「已有 Note」入口，不随候选走。
    public let duplicateNotes: [ReaderLinkedNote]
    /// token 处于 ambiguous / 多候选 → UI 必须让用户显式选一个候选，
    /// 不得默认取第一个（§6.2：不按概率最高自动挖词）。
    public let requiresSelection: Bool

    public init(
        surface: String,
        reading: String?,
        candidates: [ReaderMiningCandidate],
        duplicateNotes: [ReaderLinkedNote],
        requiresSelection: Bool
    ) {
        self.surface = surface
        self.reading = reading
        self.candidates = candidates
        self.duplicateNotes = duplicateNotes
        self.requiresSelection = requiresSelection
    }
}

// MARK: - 写侧（挖词请求）

/// 用户在 Inspector 中确认的候选 + 义项选择。
/// 必须由用户显式选择产生——服务层不提供默认选择。
public struct ReaderMiningSelection: Equatable, Sendable {
    public let lexicalKey: LexicalKey
    /// 词条 lemma/表记（Note headword 的默认预填值）。
    public let writtenForm: String
    /// `lexemes.normalized_lemma` 用的规范化 lemma。
    public let normalizedLemma: String
    public let reading: String?
    /// 词族粗标签（`lexemes.pos_family`）。
    public let posFamily: String?
    public let posCodes: [String]
    /// JMdict entryID；OOV 自建候选为 nil。
    public let entryID: Int64?
    /// 选定义项（senses.id）；nil = 未细分义项。
    public let senseID: Int64?
    /// `source_contexts.dictionary_sense_key` 值。
    public let senseKey: String?
    /// 所选释义语言（D08）。
    public let selectedGlossLanguage: String?
    /// 预填释义（义项 gloss 拼接或用户编辑结果）。可为空——
    /// `VocabularyFormData` 校验会拒绝空 meaning，UI 必须给出值。
    public let meaningZH: String
    /// 词典 dataset version（lexeme provenance + 来源快照）。
    public let dictionaryVersion: String?

    public init(
        lexicalKey: LexicalKey,
        writtenForm: String,
        normalizedLemma: String,
        reading: String?,
        posFamily: String?,
        posCodes: [String],
        entryID: Int64?,
        senseID: Int64?,
        senseKey: String?,
        selectedGlossLanguage: String?,
        meaningZH: String,
        dictionaryVersion: String?
    ) {
        self.lexicalKey = lexicalKey
        self.writtenForm = writtenForm
        self.normalizedLemma = normalizedLemma
        self.reading = reading
        self.posFamily = posFamily
        self.posCodes = posCodes
        self.entryID = entryID
        self.senseID = senseID
        self.senseKey = senseKey
        self.selectedGlossLanguage = selectedGlossLanguage
        self.meaningZH = meaningZH
        self.dictionaryVersion = dictionaryVersion
    }
}

/// 预填编辑器对默认字段的用户修订；nil 字段表示沿用候选默认值。
public struct ReaderMiningFieldOverrides: Equatable, Sendable {
    public var headword: String?
    public var reading: String?
    public var meaningZH: String?
    public var partOfSpeech: String?
    public var exampleJapanese: String?
    public var exampleTranslationZH: String?
    public var notes: String?

    public init(
        headword: String? = nil,
        reading: String? = nil,
        meaningZH: String? = nil,
        partOfSpeech: String? = nil,
        exampleJapanese: String? = nil,
        exampleTranslationZH: String? = nil,
        notes: String? = nil
    ) {
        self.headword = headword
        self.reading = reading
        self.meaningZH = meaningZH
        self.partOfSpeech = partOfSpeech
        self.exampleJapanese = exampleJapanese
        self.exampleTranslationZH = exampleTranslationZH
        self.notes = notes
    }
}

/// 单次挖词请求。`operationID` 对同一逻辑操作保持稳定（重试复用）；
/// `expectedGeneration` 捕获发起时的数据库世代（容器 generation），
/// 恢复后旧请求在写事务内被拒。
public struct ReaderMiningRequest: Sendable {
    public let operationID: UUID
    public let expectedGeneration: Int
    /// 目标（home）牌组。
    public let deckID: UUID
    /// 额外成员牌组（新建时并入 `note_decks`；link 既有 Note 时只做追加）。
    public let additionalDeckIDs: Set<UUID>
    /// 用户显式选择的候选；nil = 未选择——`mine` 抛 `selectionRequired`，
    /// 批量路径计 `requiresSelection`，绝不自动取首候选。
    public let selection: ReaderMiningSelection?
    /// 非 nil → 命中既有 Note：不加新卡，只追加 membership + 来源 +
    /// lexeme 关联（kind=`link_existing_note`）。
    public let existingNoteID: UUID?
    public let context: ReaderMiningContext
    /// 制卡方向（仅新建路径生效）。默认三方向全开——与词汇编辑器
    /// （`AddContentCommitCoordinator.vocabularyDirections` 回退）及
    /// JLPT 导入的默认一致。
    public let cardDirections: Set<VocabularyCardDirection>
    /// 预填编辑器字段修订（仅新建路径生效）。
    public let fieldOverrides: ReaderMiningFieldOverrides?

    public init(
        operationID: UUID,
        expectedGeneration: Int,
        deckID: UUID,
        additionalDeckIDs: Set<UUID> = [],
        selection: ReaderMiningSelection?,
        existingNoteID: UUID? = nil,
        context: ReaderMiningContext,
        cardDirections: Set<VocabularyCardDirection> = Set(VocabularyCardDirection.allCases),
        fieldOverrides: ReaderMiningFieldOverrides? = nil
    ) {
        self.operationID = operationID
        self.expectedGeneration = expectedGeneration
        self.deckID = deckID
        self.additionalDeckIDs = additionalDeckIDs
        self.selection = selection
        self.existingNoteID = existingNoteID
        self.context = context
        self.cardDirections = cardDirections
        self.fieldOverrides = fieldOverrides
    }
}

/// 挖词事务结果（receipt result_json 的可解码投影）。
public struct ReaderMiningOutcome: Equatable, Sendable {
    public let noteID: UUID
    public let lexemeID: UUID
    /// 本次产生的卡数；link 既有 Note 恒为 0。
    public let cardCount: Int
    /// true = 命中既有 Note（只加了来源/membership）。
    public let wasExistingNote: Bool
    /// true = receipt 回放（重试命中既有 receipt，未产生新写入）。
    public let wasReplayed: Bool

    public init(
        noteID: UUID,
        lexemeID: UUID,
        cardCount: Int,
        wasExistingNote: Bool,
        wasReplayed: Bool
    ) {
        self.noteID = noteID
        self.lexemeID = lexemeID
        self.cardCount = cardCount
        self.wasExistingNote = wasExistingNote
        self.wasReplayed = wasReplayed
    }
}

// MARK: - 批量挖词

/// 批量队列项：`isSelected = false` 的项不产生任何写入（用户未勾选）。
public struct ReaderMiningBatchItem: Sendable {
    public let request: ReaderMiningRequest
    public var isSelected: Bool
    /// UI 行标识。
    public let label: String

    public init(
        request: ReaderMiningRequest,
        isSelected: Bool,
        label: String
    ) {
        self.request = request
        self.isSelected = isSelected
        self.label = label
    }
}

public struct ReaderMiningBatchFailure: Equatable, Sendable {
    public let operationID: UUID
    public let label: String
    public let errorDescription: String

    public init(operationID: UUID, label: String, errorDescription: String) {
        self.operationID = operationID
        self.label = label
        self.errorDescription = errorDescription
    }
}

/// 批量结束摘要：已提交项保留、取消项丢弃，互不补偿（§11.2）。
public struct ReaderMiningBatchSummary: Equatable, Sendable {
    public var totalCount: Int = 0
    /// 实际新写入的项数。
    public var committedCount: Int = 0
    /// receipt 回放命中的项数（重试不产生新卡）。
    public var replayedCount: Int = 0
    /// 未勾选跳过的项数。
    public var skippedCount: Int = 0
    /// 候选未显式选择（ambiguous 保护）跳过的项数。
    public var requiresSelectionCount: Int = 0
    /// 剩余未处理（取消）的项数。
    public var cancelledCount: Int = 0
    public var failures: [ReaderMiningBatchFailure] = []
    public var wasCancelled: Bool { cancelledCount > 0 }

    public init() {}
}

// MARK: - Cloze 创建（S13 Reader→Cloze）

/// Reader → Cloze 创建草稿：「点词」或「正文选段」装配出的
/// 未持久化输入。`blankUTF16Range` 是**句内** UTF-16 坐标
/// （`context.sentence` 的坐标系，不是块内坐标）——创建表单把
/// 它预填进 `SentenceFormData.utf16Start/Length`；用户改句后坐标
/// 失效，必须经「第 N 处」重选（与编辑路径同一判据）。
public struct ReaderClozeDraft: Equatable, Identifiable, Sendable {
    /// sheet(item:) 用——每次新建的草稿一个 id。
    public let id: UUID
    /// 与挖词同源的定位/快照上下文（reader_* 定位 + 截取的句 +
    /// 有界前后文）——原样进 `source_contexts`。
    public let context: ReaderMiningContext
    /// blank 在 `context.sentence` 内的 UTF-16 范围。
    public let blankUTF16Range: Range<Int>
    /// 挖空表记（token surface 或用户选中的原文段）。
    public let surface: String
    /// 原形——仅用户显式选定候选后由调用方填入；歧义 token 不
    /// 自动取首候选（§6.2 同一防线）。
    public let lemma: String?
    /// 挖空处活用读音（token 解析值；纯选段路径为 nil）。
    public let reading: String?

    public init(
        id: UUID = UUID(),
        context: ReaderMiningContext,
        blankUTF16Range: Range<Int>,
        surface: String,
        lemma: String? = nil,
        reading: String? = nil
    ) {
        self.id = id
        self.context = context
        self.blankUTF16Range = blankUTF16Range
        self.surface = surface
        self.lemma = lemma
        self.reading = reading
    }
}

/// Reader→Cloze 创建请求。`cloze` 是已验证内容（表单在调用前过
/// `ValidatedClozeContent`——range/快照/答案集构造期冻结）；
/// `operationID` 语义与挖词一致：同一次用户操作保持稳定，重试
/// 复用 receipt 回放，不复制 Note。
public struct ReaderClozeMiningRequest: Sendable {
    public let operationID: UUID
    /// 发起时的数据库世代（容器 generation 快照）——写事务内复核。
    public let expectedGeneration: Int
    /// 目标（home）牌组。
    public let deckID: UUID
    /// 额外成员牌组（并入 `note_decks`）。
    public let additionalDeckIDs: Set<UUID>
    /// 已验证 cloze 内容（快照 + UTF-16 blank + surface + 答案集）。
    public let cloze: ValidatedClozeContent
    /// 整句中文释义——sentence 允许空（v19 条件 CHECK）。
    public let meaningZH: String?
    /// `notes.notes` 自由备注。
    public let notes: String?
    public let tags: [KnowledgeTag]
    /// Reader 定位上下文（来源记录装配输入）。
    public let context: ReaderMiningContext

    public init(
        operationID: UUID,
        expectedGeneration: Int,
        deckID: UUID,
        additionalDeckIDs: Set<UUID> = [],
        cloze: ValidatedClozeContent,
        meaningZH: String? = nil,
        notes: String? = nil,
        tags: [KnowledgeTag] = [],
        context: ReaderMiningContext
    ) {
        self.operationID = operationID
        self.expectedGeneration = expectedGeneration
        self.deckID = deckID
        self.additionalDeckIDs = additionalDeckIDs
        self.cloze = cloze
        self.meaningZH = meaningZH
        self.notes = notes
        self.tags = tags
        self.context = context
    }
}

/// Cloze 创建事务结果（receipt result_json 的可解码投影）。
/// 无 lexemeID——句卡不进词汇知识网络（§9.1/§11.2）。
public struct ReaderClozeMiningOutcome: Equatable, Sendable {
    public let noteID: UUID
    /// 恒为 1（sentence Note 恰一张 sentence_cloze 卡）。
    public let cardCount: Int
    /// true = receipt 回放（重试命中既有 receipt，未产生新写入）。
    public let wasReplayed: Bool

    public init(noteID: UUID, cardCount: Int, wasReplayed: Bool) {
        self.noteID = noteID
        self.cardCount = cardCount
        self.wasReplayed = wasReplayed
    }
}

// MARK: - 错误

public enum ReaderMiningError: Error, Equatable, Sendable {
    /// 请求发起世代已不是当前世代——恢复/迁移后旧请求不写回。
    case staleGeneration(expected: Int, current: Int)
    /// 未显式选择候选（ambiguous token / OOV 都必须由用户点选）。
    case selectionRequired
    /// `existingNoteID` 目标 Note 不存在或不是词汇 Note。
    case noteNotFound(UUID)
    /// 同 operationID 不同负载回放——不得复用 receipt。
    case operationPayloadConflict(UUID)
    /// receipt 行存在但 result_json 无法解码——数据损坏信号。
    case receiptCorrupt(UUID)
}

extension ReaderMiningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staleGeneration:
            "阅读器数据库已更新，本次挖词请求已过期，请重试。"
        case .selectionRequired:
            "该词存在多个候选释义，请先选择一个候选再挖词。"
        case .noteNotFound:
            "目标笔记不存在或已删除。"
        case .operationPayloadConflict:
            "同一挖词操作的重复提交内容不一致，已拒绝。"
        case .receiptCorrupt:
            "挖词回执数据损坏，无法回放。"
        }
    }
}
