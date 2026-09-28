import Foundation

/// v0.7.0 S02 冻结契约：CSV/TSV 导入导出。
/// 依据：详细技术实现文档 §10（两阶段解析、映射/校验/重复、
/// 事务/并发/恢复、CSV 导出）。
/// 冻结项：10 字段集合、三种重复策略、统一 VocabularyDuplicateKey、
/// job/receipt 持久化语义、批大小与取消/续传规则。

// MARK: - 字段与映射

/// 可导入字段（原需求 §10 的 10 字段，仅 vocabulary Note）。
public enum VocabularyImportField: String, Codable, CaseIterable, Sendable {
    case headword
    case reading
    case meaningZH
    case partOfSpeech
    case pitchAccent
    case jlpt
    case exampleJapanese
    case exampleTranslationZH
    case tags
    case notes
}

/// 列映射：CSV 列号 → 字段。预览阶段的「样本」不承诺总行数（§10.1）。
public struct ImportFieldMapping: Equatable, Sendable {
    /// columnIndex(0 起始) → field。
    public let columnToField: [Int: VocabularyImportField]
    /// tags 字段解析规则：导出模式 = JSON array；用户可选分号列表。
    public enum TagRule: String, Codable, Sendable {
        case jsonArray
        case semicolonList
    }
    public let tagRule: TagRule
    public let duplicatePolicy: DuplicatePolicy
    /// 显式开启后才允许空值清空可选字段（D11）。
    public let allowEmptyOverwrite: Bool
    /// 多例句：默认保留既有并去重追加；「替换主要例句」必须在预览展示。
    public enum ExampleRule: String, Codable, Sendable {
        case appendDeduplicated
        case replacePrimary
    }
    public let exampleRule: ExampleRule
    /// 新 Note 的方向集合由向导统一选择（§10.2）。
    public let newCardTemplates: [CardTemplateKind]
    /// 目标牌组（membership 附加目标）。
    public let targetDeckID: UUID

    public init(
        columnToField: [Int: VocabularyImportField],
        tagRule: TagRule,
        duplicatePolicy: DuplicatePolicy,
        allowEmptyOverwrite: Bool,
        exampleRule: ExampleRule,
        newCardTemplates: [CardTemplateKind],
        targetDeckID: UUID
    ) {
        self.columnToField = columnToField
        self.tagRule = tagRule
        self.duplicatePolicy = duplicatePolicy
        self.allowEmptyOverwrite = allowEmptyOverwrite
        self.exampleRule = exampleRule
        self.newCardTemplates = newCardTemplates
        self.targetDeckID = targetDeckID
    }
}

/// 重复策略（§10.2 表）。
public enum DuplicatePolicy: String, Codable, Sendable {
    /// 不写内容、不加 membership/tags，报告 skipped。
    case skip
    /// 仅映射且非空字段覆盖；保留调度；内容变更递增 contentVersion。
    case update
    /// 内容不变，标签并集 + 附加 membership；保留调度。
    case mergeTags
}

/// 统一重复键（§10.2）：kind + trim(headword) +
/// COALESCE(trim(reading), '')。不做 NFKC/平片假名归一化，
/// 不用 Reader lexical ID。近似匹配只给提示。
public struct VocabularyDuplicateKey: Equatable, Hashable, Sendable {
    public let kind: KnowledgePointKind
    public let headword: String
    public let reading: String

    public init(kind: KnowledgePointKind, headword: String, reading: String?) {
        self.kind = kind
        self.headword = headword.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reading = (reading ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 解析层（§10.1）

/// 逻辑记录：状态机 parser 的可重放输出（fieldStart/unquoted/
/// quoted/afterQuote 四态）。行号用于错误定位与 receipt。
public struct ImportLogicalRow: Equatable, Sendable {
    /// 1 起始的逻辑记录号。
    public let logicalRowNumber: Int
    /// 原始字节中的行范围（错误报告用）。
    public let rawLineRange: Range<Int>
    /// 已解析字段（未做映射）；尾空字段保留。
    public let fields: [String]

    public init(logicalRowNumber: Int, rawLineRange: Range<Int>, fields: [String]) {
        self.logicalRowNumber = logicalRowNumber
        self.rawLineRange = rawLineRange
        self.fields = fields
    }
}

public enum ImportParseError: Error, Equatable, Sendable {
    /// 未闭合引号/非法转义等——带逻辑记录号与原始行范围。
    case malformedRow(logicalRow: Int, rawLines: Range<Int>, reason: String)
    /// 检测期无法判定编码（候选需用户选择）。
    case undeterminedEncoding
    /// 编码已确定/被指定后，流中途出现非法字节序列。
    /// `offset` 为失败处的输入字节偏移。
    case invalidEncoding(offset: Int, reason: String)
    /// 超出预算：50MiB 文件 / 100k 行 / 64KiB 单字段 / 1MiB 单记录。
    case limitExceeded(metric: String, limit: Int)
    case cancelled
}

/// 增量 CSV/TSV parser（§10.1）：分 chunk 输入，状态机处理
/// quoted newline、`""` 转义、跨 chunk 多字节、无结尾换行、BOM。
/// 绝不允许 `split("\n")` 实现。
public protocol DelimitedTextParser: Sendable {
    /// delimiter 检测候选：comma/tab/semicolon；置信不足由用户选择。
    static var candidateDelimiters: [Character] { get }
    /// 推进一个 chunk（UTF-8 已解码文本；编码层在 parser 上游）。
    /// 返回本 chunk 内新产出的完整逻辑记录（可能为空）。
    mutating func feed(_ chunk: String) throws -> [ImportLogicalRow]
    /// EOF 冲刷；产生最后一条记录或末尾错误。
    mutating func finish() throws -> [ImportLogicalRow]
}

// MARK: - 计划与执行（§10.2/§10.3）

/// 单行预检结果。
public enum ImportRowVerdict: Equatable, Sendable {
    case createNew
    /// update/mergeTags 命中既有 Note；冲突（同键多条）单列待选。
    case updateExisting(noteID: UUID)
    case conflict(candidates: [UUID], reason: String)
    case invalid(reason: String)
    /// 文件内部重复：以首个已计划/已提交目标为基准。
    case inFileDuplicate(firstLogicalRow: Int)
}

public enum ImportJobStatus: String, Codable, Sendable {
    case previewed
    case running
    case cancelled
    /// 恢复时对 in-progress job 的落态（§10.3）。
    case interrupted
    case completed
    case failed
}

/// 行级幂等 receipt：`(jobID, logicalRowNumber)` 唯一；
/// 重跑同一 job 用 receipts 跳过已完成行；新建 job 是新的导入。
public struct ImportRowReceipt: Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case created
        case updated
        case mergedTags
        case skipped
        case failed
    }

    public let jobID: UUID
    public let logicalRowNumber: Int
    /// 行 payload digest——同 job 重跑遇不同内容即冲突。
    public let payloadDigest: String
    public let action: Action
    public let targetNoteID: UUID?

    public init(
        jobID: UUID,
        logicalRowNumber: Int,
        payloadDigest: String,
        action: Action,
        targetNoteID: UUID?
    ) {
        self.jobID = jobID
        self.logicalRowNumber = logicalRowNumber
        self.payloadDigest = payloadDigest
        self.action = action
        self.targetNoteID = targetNoteID
    }
}

public struct ImportJob: Equatable, Identifiable, Sendable {
    public let id: UUID
    /// 原文件 hash（续传/重选校验——崩溃后有 staging+hash 才允许续传）。
    public let fileHash: String
    /// 映射+策略的指纹；mapping 变更必须重建 plan。
    public let mappingHash: String
    public let policy: DuplicatePolicy
    public let targetDeckID: UUID
    public var status: ImportJobStatus
    public let createdAt: Date

    public init(
        id: UUID,
        fileHash: String,
        mappingHash: String,
        policy: DuplicatePolicy,
        targetDeckID: UUID,
        status: ImportJobStatus,
        createdAt: Date
    ) {
        self.id = id
        self.fileHash = fileHash
        self.mappingHash = mappingHash
        self.policy = policy
        self.targetDeckID = targetDeckID
        self.status = status
        self.createdAt = createdAt
    }
}

/// 批执行常量（§10.3）。
public enum ImportBatchPolicy {
    /// 每批最多 200 行；批失败回滚整批、报告失败位置，可重试。
    public static let maximumRowsPerBatch = 200
}

/// 导入执行边界。命令必须经由 S03 的事务 writer——
/// 导入器不得绕过 validated command 直接写 notes/cards（§10.3）。
public protocol ImportPlanRepository: Sendable {
    func createJob(_ job: ImportJob) async throws
    func fetchJob(id: UUID) async throws -> ImportJob?
    func updateJobStatus(id: UUID, status: ImportJobStatus) async throws
    func recordReceipts(_ receipts: [ImportRowReceipt]) async throws
    func completedRowNumbers(jobID: UUID) async throws -> Set<Int>
}
