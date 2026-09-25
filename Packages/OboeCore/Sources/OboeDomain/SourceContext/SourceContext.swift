import Foundation

/// 来源类型（设计 §6.1）：`paste` 入口映射为 `manual` 并保留 title
/// 描述，不强迫改变 SharedCapture 协议；`reader`/`import` 为后续
/// 入口预留，本版 UI 不产出。
public enum SourceContextType: String, Codable, CaseIterable, Sendable {
    case manual
    case share
    case ocr
    case dictionary
    case reader
    case `import`
}

/// Note 的一条来源上下文（用户库 v15）。快照语义：字典上游移除条目后
/// 仍保留已存的用户内容与来源文本，链接显示不可用——`dictionary_*`
/// 只记录保存时的快照值，不对字典库建跨库引用。
///
/// `imageReference` 延续 v14 的受控资源 ID 弱引用模型：不写外部绝对
/// 路径，孤儿清理由统一附件引用查询负责。
public struct SourceContext: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let noteID: UUID
    public let sourceType: SourceContextType
    /// 用户确认的来源句子（不是自动分词结果）。
    public let originalSentence: String?
    /// 句子前后文，有界——避免整个大文档不受控入库。
    public let surroundingText: String?
    public let sourceTitle: String?
    /// 仅本地展示；不自动抓取网页。
    public let sourceURL: String?
    public let sourceApp: String?
    public let imageReference: String?
    public let dictionaryEntryID: Int64?
    /// 保存时的字典 dataset_version——上游升级后可判链接新旧。
    public let dictionaryVersion: String?
    public let dictionarySenseKey: String?
    /// D08：所选释义语言（如 "zho"/"eng"）。英语兜底时保留该标记，
    /// UI 显示语言标签而不是假装是中文。
    public let selectedGlossLanguage: String?
    /// 「有来源时最多一个 primary」由部分唯一索引保证；旧 Note
    /// 零来源合法。
    public let isPrimary: Bool
    public let createdAt: Date

    public init(
        id: UUID,
        noteID: UUID,
        sourceType: SourceContextType,
        originalSentence: String?,
        surroundingText: String?,
        sourceTitle: String?,
        sourceURL: String?,
        sourceApp: String?,
        imageReference: String?,
        dictionaryEntryID: Int64?,
        dictionaryVersion: String?,
        dictionarySenseKey: String?,
        selectedGlossLanguage: String?,
        isPrimary: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.noteID = noteID
        self.sourceType = sourceType
        self.originalSentence = originalSentence
        self.surroundingText = surroundingText
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.sourceApp = sourceApp
        self.imageReference = imageReference
        self.dictionaryEntryID = dictionaryEntryID
        self.dictionaryVersion = dictionaryVersion
        self.dictionarySenseKey = dictionarySenseKey
        self.selectedGlossLanguage = selectedGlossLanguage
        self.isPrimary = isPrimary
        self.createdAt = createdAt
    }
}

/// 制卡前由各入口（OCR/Share/Dictionary/manual）构造、随编辑器草稿
/// 与续编 payload 流转的未持久化来源。`noteID`/`createdAt`/`id` 在
/// commit 事务内由提交方赋予。Codable：续编 payload 内嵌序列化。
public struct SourceContextDraft: Equatable, Codable, Sendable {
    public var sourceType: SourceContextType
    public var originalSentence: String?
    public var surroundingText: String?
    public var sourceTitle: String?
    public var sourceURL: String?
    public var sourceApp: String?
    public var imageReference: String?
    public var dictionaryEntryID: Int64?
    public var dictionaryVersion: String?
    public var dictionarySenseKey: String?
    public var selectedGlossLanguage: String?
    /// 默认 true：第一版写一条主来源；向已有 Note 加来源时由提交方
    /// 显式决定（默认不替换现有主来源）。
    public var isPrimary: Bool

    public init(
        sourceType: SourceContextType,
        originalSentence: String? = nil,
        surroundingText: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        sourceApp: String? = nil,
        imageReference: String? = nil,
        dictionaryEntryID: Int64? = nil,
        dictionaryVersion: String? = nil,
        dictionarySenseKey: String? = nil,
        selectedGlossLanguage: String? = nil,
        isPrimary: Bool = true
    ) {
        self.sourceType = sourceType
        self.originalSentence = originalSentence
        self.surroundingText = surroundingText
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.sourceApp = sourceApp
        self.imageReference = imageReference
        self.dictionaryEntryID = dictionaryEntryID
        self.dictionaryVersion = dictionaryVersion
        self.dictionarySenseKey = dictionarySenseKey
        self.selectedGlossLanguage = selectedGlossLanguage
        self.isPrimary = isPrimary
    }

    /// 持久化前调用：修剪空白并把超长 surrounding 截断到有界上限，
    /// 空串字段归一为 nil。
    public func normalized() -> SourceContextDraft {
        var draft = self
        draft.originalSentence = Self.trimmed(originalSentence)
        draft.surroundingText = Self.trimmed(surroundingText)
            .map { String($0.prefix(Self.maximumSurroundingCharacters)) }
        draft.sourceTitle = Self.trimmed(sourceTitle)
        draft.sourceURL = Self.trimmed(sourceURL)
        draft.sourceApp = Self.trimmed(sourceApp)
        draft.dictionaryVersion = Self.trimmed(dictionaryVersion)
        draft.dictionarySenseKey = Self.trimmed(dictionarySenseKey)
        draft.selectedGlossLanguage = Self.trimmed(selectedGlossLanguage)
        return draft
    }

    /// surrounding_text 的长度上限（设计 §6.2「有长度限制」）。
    /// 取远大于自然句段的值，阻止整篇文档入库。
    public static let maximumSurroundingCharacters = 2_000

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum SourceContextError: Error, Equatable, Sendable {
    /// 同 Note 已有 primary 来源时写入第二条 primary（部分唯一索引）。
    case primaryConflict(noteID: UUID)
    case missingNote(noteID: UUID)
}
