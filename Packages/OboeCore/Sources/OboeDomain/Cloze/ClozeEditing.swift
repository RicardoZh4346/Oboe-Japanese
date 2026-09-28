import Foundation

/// v0.7.0 S13：sentence/Cloze 的手动编辑契约（设计 §9.2：「编辑句子后
/// 必须重新选择并验证范围；只改翻译/hint 不变 range。contentVersion
/// 递增」；cloze-impact-review §4：编辑 cloze 内容必须同时抬
/// `cloze_definitions.content_version` 与 `notes.content_version`——
/// 后者是复习提交守卫的读取点）。
///
/// 语义要点：
/// - 快照可变但 range 必须针对**新**句重新验证——编辑面只携带可选的
///   UTF-16 坐标（nil = 未选），构造 `ValidatedClozeContent` 时整体重验。
/// - Card 与 FSRS 不动：更新只改 `cloze_definitions` 与 `notes` 两行的
///   内容列——若语义变成另一道题，走新 Note 创建而非暗中重置。
/// - 原文删除后仍可编辑：`source_context_id` 与本路径无关。

// MARK: - 表单数据

/// sentence Note 的编辑表单（与 `VocabularyFormData`/`GrammarFormData`
/// 同层）：可变字符串字段 + 可选 blank 坐标。`validatedContent()` 把
/// 表单收敛成构造即冻结的 `ValidatedClozeContent`。
public struct SentenceFormData: Codable, Equatable, Sendable {
    /// 原句（将成为新快照）。编辑后旧坐标即失效——UI 侧调
    /// `invalidateRangeSelection()` 强制重选，这里的坐标也是可选的。
    public var sentence: String
    /// blank 的持久化坐标；nil = 未选择。
    public var utf16Start: Int?
    public var utf16Length: Int?
    /// 挖空处实际表记（如「見た」）。
    public var targetSurface: String
    public var targetLemma: String
    /// 填空处实际活用读音（如「みた」）。
    public var targetReading: String
    /// 完整接受答案列表（必须含 `targetSurface`，§9.3）。
    public var acceptedAnswers: [String]
    public var hint: String
    /// 整句中文释义——sentence 允许留空（v19 条件 CHECK）。
    public var meaningZH: String
    public var notes: String

    public init(
        sentence: String = "",
        utf16Start: Int? = nil,
        utf16Length: Int? = nil,
        targetSurface: String = "",
        targetLemma: String = "",
        targetReading: String = "",
        acceptedAnswers: [String] = [],
        hint: String = "",
        meaningZH: String = "",
        notes: String = ""
    ) {
        self.sentence = sentence
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.targetSurface = targetSurface
        self.targetLemma = targetLemma
        self.targetReading = targetReading
        self.acceptedAnswers = acceptedAnswers
        self.hint = hint
        self.meaningZH = meaningZH
        self.notes = notes
    }

    /// 从既有定义预填（编辑页打开时的表单初值）。当前 range 在
    /// `targetSurface` 候选中能定位时回填坐标；定位不到（损坏行）保持
    /// 未选中，强制用户在保存前重选。
    public init(
        definition: ClozeDefinition,
        meaningZH: String?,
        notes: String?
    ) {
        self.init(
            sentence: definition.sentenceSnapshot,
            targetSurface: definition.targetSurface,
            targetLemma: definition.targetLemma ?? "",
            targetReading: definition.targetReading ?? "",
            acceptedAnswers: definition.acceptedAnswers,
            hint: definition.hint ?? "",
            meaningZH: meaningZH ?? "",
            notes: notes ?? ""
        )
        if candidateRanges.contains(definition.range) {
            utf16Start = definition.range.utf16Start
            utf16Length = definition.range.utf16Length
        }
    }

    /// `targetSurface` 在当前句中的全部可选出现点（升序）。
    public var candidateRanges: [ClozeRange] {
        ClozeValidator.surfaceRanges(of: targetSurface, in: sentence)
    }

    /// 当前选中坐标在候选里的序号（UI 的「第 N 处」展示）；未选中或
    /// 坐标已失效时为 nil。
    public var selectedOccurrenceOrdinal: Int? {
        guard let utf16Start, let utf16Length,
              let range = try? ClozeRange(
                  utf16Start: utf16Start,
                  utf16Length: utf16Length
              )
        else { return nil }
        return candidateRanges.firstIndex(of: range)
    }

    /// 按出现序号选择（0-based）。越界返回 false 且不动现有选择。
    @discardableResult
    public mutating func selectOccurrence(_ ordinal: Int) -> Bool {
        let candidates = candidateRanges
        guard candidates.indices.contains(ordinal) else { return false }
        utf16Start = candidates[ordinal].utf16Start
        utf16Length = candidates[ordinal].utf16Length
        return true
    }

    /// sentence 编辑后调用：清空旧坐标，强制重选范围（§9.2）。
    public mutating func invalidateRangeSelection() {
        utf16Start = nil
        utf16Length = nil
    }

    /// 表单 → 已验证内容；range 未选/非法/与 surface 不符、句空、
    /// answers 空或缺 surface 均抛 `ClozeError`。
    public func validatedContent() throws -> ValidatedClozeContent {
        guard let utf16Start, let utf16Length else {
            throw ClozeError.invalidRange
        }
        return try ValidatedClozeContent(
            sentenceSnapshot: sentence,
            utf16Start: utf16Start,
            utf16Length: utf16Length,
            targetSurface: targetSurface,
            targetLemma: targetLemma,
            targetReading: targetReading,
            acceptedAnswers: acceptedAnswers,
            hint: hint
        )
    }

    /// 收敛成可提交的更新载荷；`expectedContentVersion` 取编辑会话
    /// 打开时读到的 `cloze_definitions.content_version`。
    public func makeUpdate(
        expectedContentVersion: Int
    ) throws -> SentenceContentUpdate {
        SentenceContentUpdate(
            cloze: try validatedContent(),
            meaningZH: meaningZH
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            notes: notes
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            expectedContentVersion: expectedContentVersion
        )
    }
}

// MARK: - 更新载荷与聚合

/// `updateSentence` 的单事务载荷：cloze 全字段 + note 级
/// meaning/notes + 乐观版本。语义为**整体替换**——与
/// `ValidatedVocabularyContent` 更新相同，不提供字段级 patch。
public struct SentenceContentUpdate: Equatable, Sendable {
    public let cloze: ValidatedClozeContent
    /// `nil` = 清空（sentence 允许）；vocabulary/grammar 的
    /// 非空语义不适用于本路径。
    public let meaningZH: String?
    public let notes: String?
    /// 写入前 `cloze_definitions.content_version` 必须等于该值，
    /// 否则抛 `ClozeError.staleContentVersion`。
    public let expectedContentVersion: Int

    public init(
        cloze: ValidatedClozeContent,
        meaningZH: String?,
        notes: String?,
        expectedContentVersion: Int
    ) {
        self.cloze = cloze
        self.meaningZH = meaningZH
        self.notes = notes
        self.expectedContentVersion = expectedContentVersion
    }
}

/// sentence Note 的详情聚合：`cloze_definitions` 行 + notes 的
/// 编辑/展示字段（聚合根的读取面，列表用 `KnowledgePointSummary`）。
public struct SentenceNote: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 归属（home）牌组；成员全集见 `deckIDs`。
    public let deckID: UUID
    public let deckIDs: Set<UUID>
    public let definition: ClozeDefinition
    public let meaningZH: String?
    public let notes: String?
    /// `notes.content_version`——复习提交守卫的读取点，与
    /// `definition.contentVersion` 在编辑路径上同步抬升。
    public let noteContentVersion: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        deckID: UUID,
        deckIDs: Set<UUID>,
        definition: ClozeDefinition,
        meaningZH: String?,
        notes: String?,
        noteContentVersion: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.deckID = deckID
        self.deckIDs = deckIDs
        self.definition = definition
        self.meaningZH = meaningZH
        self.notes = notes
        self.noteContentVersion = noteContentVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - 仓储契约扩展

/// S13 在只读 `ClozeRepository`（S12，复习链路共用）之上追加编辑面。
/// 更新语义（`GRDBClozeRepository` 实现）：
/// 单事务内复核 `note.kind='sentence'`、definition 存在、
/// `content_version == expectedContentVersion`、卡链仍是
/// `sentence_cloze` 且挂在同一 note；然后更新 `cloze_definitions`
/// 全字段（`content_version+1`）并同步 `notes.headword`（=新快照）、
/// `meaning_zh`/`notes`（`content_version+1`）。Card 行与 FSRS
/// 不动；`source_context_id` 不动（删源后的 NULL 状态保持）。
/// 任一前置失败整体回滚——不留半更新行。
public protocol ClozeEditingRepository: ClozeRepository {
    func fetchSentence(noteID: UUID) async throws -> SentenceNote?
    func updateSentence(
        noteID: UUID,
        update: SentenceContentUpdate,
        at date: Date
    ) async throws -> SentenceNote?
}

// MARK: - 服务

/// sentence/Cloze 的手动编辑服务（§9.1：cloze 只手动编辑，不进 AI
/// 修卡）。创建走 `ContentCardService.commitSentence`（S12）；本服务
/// 承载读-改-写与乐观并发。
public struct SentenceService: Sendable {
    private let repository: any ClozeEditingRepository
    private let now: @Sendable () -> Date

    public init(
        repository: any ClozeEditingRepository,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.now = now
    }

    public func fetchDefinition(noteID: UUID) async throws -> ClozeDefinition? {
        try await repository.fetchDefinition(noteID: noteID)
    }

    public func fetchDefinition(cardID: UUID) async throws -> ClozeDefinition? {
        try await repository.fetchDefinition(cardID: cardID)
    }

    /// 详情/编辑初值：definition + note 字段一次取回。
    public func fetchSentence(noteID: UUID) async throws -> SentenceNote? {
        try await repository.fetchSentence(noteID: noteID)
    }

    /// 应用表单编辑：版本取当前持久化行（两次读之间被并发修改会
    /// 被仓储的乐观检查拒绝）。成功返回聚合后的新状态。
    @discardableResult
    public func updateSentence(
        noteID: UUID,
        formData: SentenceFormData
    ) async throws -> SentenceNote? {
        guard let existing = try await repository.fetchSentence(
            noteID: noteID
        ) else {
            return nil
        }
        let update = try formData.makeUpdate(
            expectedContentVersion: existing.definition.contentVersion
        )
        return try await repository.updateSentence(
            noteID: noteID,
            update: update,
            at: now()
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
