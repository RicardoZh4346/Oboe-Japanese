import CryptoKit
import Foundation

/// v0.7.0 S12：sentence Note + 单 blank Cloze 的已验证提交载荷与
/// 落库映射。与 `VocabularyContentCommit`/`GrammarContentCommit` 同层：
/// 由调用方（S13 创建流程、S23 恢复管线）装配，`GRDBContentWriteExecutor`
/// 在事务内消费。
///
/// 冻结依据：设计 §9.1–9.3、D07（UTF-16 range + 快照 + hash + range 版本，
/// 绝不持久化 String.Index）、S01 spike G（正面不泄题）。

// MARK: - 快照 hash

public extension ClozeValidator {
    /// 快照完整性 hash 口径：**UTF-8 字节流的 SHA-256，小写 64 位 hex**。
    /// 与 `cloze_definitions.sentence_sha256` 及备份 v8 记录字段一致；
    /// `ReaderHashing.sha256Hex` 采用同一口径。
    static func snapshotSHA256(_ sentence: String) -> String {
        SHA256.hash(data: Data(sentence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 持久化前的完整一致性校验：在 `validate(sentence:range:…)` 之上追加
    /// ——acceptedAnswers 必须包含 targetSurface 本体，且声明的 sha256 必须
    /// 等于快照实算值。创建、恢复预检（§14.2）共用这一个判据；任一不满足
    /// 即抛错，不得落库（错位但仍可评分的卡比失败更糟）。
    static func validatePersisted(
        sentence: String,
        sentenceSHA256: String,
        range: ClozeRange,
        targetSurface: String,
        acceptedAnswers: [String]
    ) throws {
        try validate(
            sentence: sentence,
            range: range,
            targetSurface: targetSurface,
            acceptedAnswers: acceptedAnswers
        )
        guard acceptedAnswers.contains(targetSurface) else {
            throw ClozeError.acceptedAnswersMissingSurface
        }
        guard snapshotSHA256(sentence) == sentenceSHA256 else {
            throw ClozeError.snapshotHashMismatch
        }
    }
}

// MARK: - 已验证内容

/// Cloze 内容的创建期校验结果（等价于 `ValidatedVocabularyContent` 的角色）。
/// 构造即冻结：range/surface/answers 全部过 `ClozeValidator`，sha256 由
/// 构造器对最终快照实算——调用方无法传入与快照不一致的 hash。
public struct ValidatedClozeContent: Equatable, Sendable {
    /// 原句快照（immutable）。落库时同时写入 `notes.headword`。
    public let sentenceSnapshot: String
    public let sentenceSHA256: String
    public let range: ClozeRange
    public let targetSurface: String
    public let targetLemma: String?
    /// 填空处实际活用读音（非 lemma 读音）。
    public let targetReading: String?
    /// 归一化（trim/去空/保序去重）后的接受答案集合，含 targetSurface。
    public let acceptedAnswers: [String]
    public let hint: String?

    /// - throws: `ClozeError` —— 句空 / range 越界或劈字 / 截取≠surface /
    ///   answers 为空或不含 surface。
    public init(
        sentenceSnapshot: String,
        utf16Start: Int,
        utf16Length: Int,
        targetSurface: String,
        targetLemma: String? = nil,
        targetReading: String? = nil,
        acceptedAnswers: [String],
        hint: String? = nil
    ) throws {
        let range = try ClozeRange(utf16Start: utf16Start, utf16Length: utf16Length)
        let normalizedAnswers = Self.normalizedAnswers(acceptedAnswers)
        try ClozeValidator.validate(
            sentence: sentenceSnapshot,
            range: range,
            targetSurface: targetSurface,
            acceptedAnswers: normalizedAnswers
        )
        guard normalizedAnswers.contains(targetSurface) else {
            throw ClozeError.acceptedAnswersMissingSurface
        }
        self.sentenceSnapshot = sentenceSnapshot
        self.sentenceSHA256 = ClozeValidator.snapshotSHA256(sentenceSnapshot)
        self.range = range
        self.targetSurface = targetSurface
        self.targetLemma = Self.nilIfEmpty(targetLemma)
        self.targetReading = Self.nilIfEmpty(targetReading)
        self.acceptedAnswers = normalizedAnswers
        self.hint = Self.nilIfEmpty(hint)
    }

    /// 已有 range/hash 的重建路径（备份恢复）：不重复算 range，但仍完整
    /// 校验 hash/surface/answers——坏记录不得借道进库。
    public init(
        restoringSentenceSnapshot sentenceSnapshot: String,
        sentenceSHA256: String,
        range: ClozeRange,
        targetSurface: String,
        targetLemma: String?,
        targetReading: String?,
        acceptedAnswers: [String],
        hint: String?
    ) throws {
        let normalizedAnswers = Self.normalizedAnswers(acceptedAnswers)
        try ClozeValidator.validatePersisted(
            sentence: sentenceSnapshot,
            sentenceSHA256: sentenceSHA256,
            range: range,
            targetSurface: targetSurface,
            acceptedAnswers: normalizedAnswers
        )
        self.sentenceSnapshot = sentenceSnapshot
        self.sentenceSHA256 = sentenceSHA256
        self.range = range
        self.targetSurface = targetSurface
        self.targetLemma = Self.nilIfEmpty(targetLemma)
        self.targetReading = Self.nilIfEmpty(targetReading)
        self.acceptedAnswers = normalizedAnswers
        self.hint = Self.nilIfEmpty(hint)
    }

    /// 落库 DTO 映射：事务内 note/card/source 的真实 id 由 executor 赋予。
    public func makeDefinition(
        id: UUID,
        noteID: UUID,
        cardID: UUID,
        sourceContextID: UUID?,
        contentVersion: Int = 1
    ) -> ClozeDefinition {
        ClozeDefinition(
            id: id,
            noteID: noteID,
            cardID: cardID,
            sourceContextID: sourceContextID,
            sentenceSnapshot: sentenceSnapshot,
            sentenceSHA256: sentenceSHA256,
            range: range,
            targetSurface: targetSurface,
            targetLemma: targetLemma,
            targetReading: targetReading,
            acceptedAnswers: acceptedAnswers,
            hint: hint,
            contentVersion: contentVersion
        )
    }

    private static func normalizedAnswers(_ answers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for answer in answers {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - 提交命令

/// sentence Note + `sentence_cloze` Card + `cloze_definitions` 行的
/// 原子创建命令（§9.1：一张 sentence Note 恰有一个 definition 与一个
/// Card——本结构由构造即满足）。`noteID`/`clozeID`/`card.id` 由调用方
/// 生成；`definition.card_id` 恒等于 `card.id`，`definition.note_id`
/// 恒等于 `noteID`。
public struct SentenceContentCommit: Equatable, Sendable {
    public let noteID: UUID
    /// `cloze_definitions.id`。
    public let clozeID: UUID
    /// 归属（home）牌组。
    public let deckID: UUID
    /// Note 的全部成员牌组；始终包含 `deckID`。
    public let deckIDs: Set<UUID>
    public let cloze: ValidatedClozeContent
    /// 整句中文释义——可空（v19 条件 CHECK：sentence 允许无翻译）。
    public let meaningZH: String?
    /// `notes.notes` 自由备注。
    public let notes: String?
    public let tags: [KnowledgeTag]
    /// 必须是 `.sentenceCloze` 模板；executor 复核。
    public let card: NewCardSeed
    public let schedulerProfileID: UUID
    public let createdAt: Date
    public let origin: ContentOrigin
    public let sourceText: String?
    /// 装配好的来源记录（v15 语义 + v19 定位列）；同事务写入，
    /// `cloze_definitions.source_context_id` 指向它的 id。
    public let sourceContext: SourceContext?

    public init(
        noteID: UUID,
        clozeID: UUID,
        deckID: UUID,
        cloze: ValidatedClozeContent,
        card: NewCardSeed,
        schedulerProfileID: UUID,
        createdAt: Date,
        meaningZH: String? = nil,
        notes: String? = nil,
        tags: [KnowledgeTag] = [],
        origin: ContentOrigin = .manual,
        sourceText: String? = nil,
        deckIDs: Set<UUID>? = nil,
        sourceContext: SourceContext? = nil
    ) {
        self.noteID = noteID
        self.clozeID = clozeID
        self.deckID = deckID
        self.deckIDs = (deckIDs ?? [deckID]).union([deckID])
        self.cloze = cloze
        self.meaningZH = meaningZH
        self.notes = notes
        self.tags = tags
        self.card = card
        self.schedulerProfileID = schedulerProfileID
        self.createdAt = createdAt
        self.origin = origin
        self.sourceText = sourceText
        self.sourceContext = sourceContext
    }
}

// MARK: - 读取契约

/// `cloze_definitions` 的持久层契约（S12 新增；S13 编辑流程与 S14 复习
/// payload 的消费点）。读取即快照——不解析、不回链 Reader 原文。
public protocol ClozeRepository: Sendable {
    /// 按 Note 取唯一定义；不存在返回 nil（不抛错——非 sentence Note
    /// 无定义是合法状态）。
    func fetchDefinition(noteID: UUID) async throws -> ClozeDefinition?
    /// 按卡取定义（复习链路的自然入口）。
    func fetchDefinition(cardID: UUID) async throws -> ClozeDefinition?
}
