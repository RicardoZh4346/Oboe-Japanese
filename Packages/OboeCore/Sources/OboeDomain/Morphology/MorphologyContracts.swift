import Foundation

/// v0.7.0 S02 冻结契约：日语词法分析接口与词汇身份。
/// 依据：详细技术实现文档 §6（§6.1 接口、§6.3 LexicalKey 与学习关联）。
/// 冻结项：token/candidate 结构、lexical key 构成、解析状态机、
/// token 缓存键字段、有界 span 合并预算。

// MARK: - 输入与输出

/// 送交词法分析的正文块。`text` 是渲染原文——不得传入查询规范化副本
/// （§6.1：规范化只生成查询值，`sourceRangeUTF16` 必须指向原文）。
public struct MorphologyBlock: Equatable, Sendable {
    public let blockID: UUID
    public let text: String
    /// canonical text hash——token cache 键的组成之一。
    public let textHash: String

    public init(blockID: UUID, text: String, textHash: String) {
        self.blockID = blockID
        self.text = text
        self.textHash = textHash
    }
}

/// 词典候选（§6.1 Candidate，S01 spike 修订）。
/// `lemma`/`normalizedForm`/`reading` 是三个独立字段，不得互相
/// 当作默认同义值。歧义时保留候选上限 5 个（spike §7.3 决议）。
public struct MorphologyCandidate: Equatable, Hashable, Sendable {
    /// ambiguous 状态下保留的候选上限。
    public static let maximumRetained = 5

    /// 词典原形（如 食べる）。
    public let lemma: String
    /// 规范化表记（SearchTextNormalizer 输出，与 DB normalized_* 列同算法）。
    public let normalizedForm: String
    /// 候选读音（词典 readings 命中回填；可为 nil）。
    public let reading: String?
    /// JMdict 风格 POS 标签集（命中条目的 sense_pos 交集）。
    public let posCodes: [String]
    /// 词典 entryID——命中词库时非空；OOV 候选为 nil。
    public let entryID: Int64?
    /// 候选来源/理由链（deinflect 规则 id、span 合并、exact 命中等），
    /// 用于诊断与 Golden Corpus 归因。
    public let reasons: [String]
    /// 排序成本（deinflect 路径累加；原形 exact = 0）。
    public let cost: Int

    public init(
        lemma: String,
        normalizedForm: String,
        reading: String?,
        posCodes: [String],
        entryID: Int64?,
        reasons: [String],
        cost: Int
    ) {
        self.lemma = lemma
        self.normalizedForm = normalizedForm
        self.reading = reading
        self.posCodes = posCodes
        self.entryID = entryID
        self.reasons = reasons
        self.cost = cost
    }
}

/// token 的词典解析状态（§6.1 resolutionStatus）。
public enum TokenResolutionStatus: String, Codable, Sendable {
    /// 高置信单候选，可自动关联。
    case resolved
    /// 多个候选——等待用户选择，不自动挖词。
    case ambiguous
    /// OOV/能力缺失：无词典候选。仍是合法 token，参与覆盖率 unknown。
    case unresolved
}

/// token 粗分类（覆盖率口径 §7 的分母依据）。
/// 计入覆盖率：lexical + auxiliary + outOfVocabulary；
/// 不计入：nonLexical（§7：空白/标点/纯符号/独立纯数字不计，
/// 助词/助动词计入，独立英文字词作 OOV 计 unknown）。
/// S01 决议：助动词链按「动词 target + aux token」分计——
/// てしまう/ている 不整 span 合成单 token（spike §7.5，已确认）。
public enum ReaderTokenClass: String, Codable, Sendable {
    /// 实词与助词。
    case lexical
    /// 助动词段（て/い/ます/だっ/しまっ 类并入或独立的段）——计覆盖率。
    case auxiliary
    /// 空白、标点、纯符号、独立纯数字——不计入。
    case nonLexical
    /// 独立英文字词等 OOV——计 unknown（§7）。
    case outOfVocabulary

    /// 是否计入覆盖率分母。
    public var countsForCoverage: Bool {
        switch self {
        case .lexical, .auxiliary, .outOfVocabulary: true
        case .nonLexical: false
        }
    }
}

public struct ReaderToken: Equatable, Sendable {
    /// 原文切片（渲染原文）。
    public let surface: String
    /// 在块内的 UTF-16 范围（面向渲染原文，不是规范化串）。
    public let sourceRangeUTF16: Range<Int>
    /// 合并 span 的 UTF-16 范围——词典命中依据；与 sourceRangeUTF16
    /// 在助动词链场景不同（spike §7.2：前者定候选、后者定渲染）。
    /// 未合并时 == sourceRangeUTF16。
    public let mergedSpanUTF16: Range<Int>
    /// 覆盖的底层系统 token 索引范围——保留原始 NL 边界供诊断（§6.1）。
    public let systemTokenIndexes: Range<Int>
    /// 按置信度排序的候选；可为空（OOV）；歧义时至多
    /// `MorphologyCandidate.maximumRetained` 个。
    public let candidates: [MorphologyCandidate]
    public let tokenClass: ReaderTokenClass
    /// token 实际活用读音（非 lemma 读音）。
    public let reading: String?
    /// 已确认的词汇身份——用户在歧义中选择或自动解析后填入。
    public let lexicalKey: LexicalKey?
    public let resolutionStatus: TokenResolutionStatus
    /// 生成路径（tokenizer+spanMerge+deinflect+dictLookup…），诊断用。
    public let provenance: [String]

    public init(
        surface: String,
        sourceRangeUTF16: Range<Int>,
        mergedSpanUTF16: Range<Int>? = nil,
        systemTokenIndexes: Range<Int>,
        candidates: [MorphologyCandidate],
        tokenClass: ReaderTokenClass,
        reading: String?,
        lexicalKey: LexicalKey?,
        resolutionStatus: TokenResolutionStatus,
        provenance: [String]
    ) {
        self.surface = surface
        self.sourceRangeUTF16 = sourceRangeUTF16
        self.mergedSpanUTF16 = mergedSpanUTF16 ?? sourceRangeUTF16
        self.systemTokenIndexes = systemTokenIndexes
        self.candidates = candidates
        self.tokenClass = tokenClass
        self.reading = reading
        self.lexicalKey = lexicalKey
        self.resolutionStatus = resolutionStatus
        self.provenance = provenance
    }
}

// MARK: - 词汇身份（§6.3）

/// 词汇身份的持久化主键是内部 UUID（`lexemes.id`）；
/// `LexicalKey` 是可解析的外部身份，用于跨库关联与回填。
public struct LexicalKey: Equatable, Hashable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case jmdict
        case local
    }

    public let provider: Provider
    /// JMdict：`ent_seq`；local：规范化 (written,reading,pos) 编码。
    public let externalID: String
    /// 规范编码后的 identity_key 全文（provider+id+表记/读音规范化，
    /// §6.3 canonical JSON hash 方向）；唯一。
    public let identityKey: String

    public init(provider: Provider, externalID: String, identityKey: String) {
        self.provider = provider
        self.externalID = externalID
        self.identityKey = identityKey
    }
}

/// 词法分析服务（§6.1）。实现需在 actor 内串行化系统 tokenizer
/// 实例的使用（NLTokenizer/NLTagger 非线程安全）。
public protocol JapaneseMorphologyService: Sendable {
    /// 实现版本串——token cache 键的组成之一。
    var implementationVersion: String { get }
    /// 词典 dataset 版本——token cache 键的组成之一。
    var dictionaryDatasetVersion: String { get }
    /// 对一块原文产出 token 序列；支持 `Task` 取消的批处理调用方。
    func tokenize(_ block: MorphologyBlock) async throws -> [ReaderToken]
}

/// token cache 键（§6.1 + S01 冻结修订）：
/// `blockHash + parserVersion + morphologyVersion +
/// dictionaryDatasetVersion + OSBuild`。任一字段变化 → 该块缓存
/// 失效；缓存按块内 per-token 行存取（spike §7.1d：sentence 级
/// 失效太粗）。
///
/// 冻结细节：
/// - `blockHash` = 原文块的 SHA-256 over UTF-8 bytes——不做任何
///   normalize（§6.1 原文不可被规范化替换）。
/// - `morphologyVersion` 语义化版本串，覆盖 Deinflector 规则表版本 ×
///   合并启发式版本，任一变更 bump。
/// - `osBuild` = 系统 build 号（系统 tokenizer 随 OS 变化）。
public struct TokenCacheKey: Equatable, Hashable, Sendable {
    public let blockHash: String
    public let parserVersion: String
    public let morphologyVersion: String
    public let dictionaryDatasetVersion: String
    /// 系统 tokenizer 随 OS 变化——计入系统 build 号。
    public let osBuild: String

    public init(
        blockHash: String,
        parserVersion: String,
        morphologyVersion: String,
        dictionaryDatasetVersion: String,
        osBuild: String
    ) {
        self.blockHash = blockHash
        self.parserVersion = parserVersion
        self.morphologyVersion = morphologyVersion
        self.dictionaryDatasetVersion = dictionaryDatasetVersion
        self.osBuild = osBuild
    }
}

/// 候选批量解析边界（S01 spike §2.2/§7.4 决议）：
/// tokenize 需要 N tokens × M 候选 → entry 命中集的批量查询，
/// 复用词典库同一 SQL 的 IN-chunk 机制；不允许逐 token 调分页
/// `search()`（§17 无逐 token SQL）。
public protocol MorphologyCandidateResolver: Sendable {
    /// 一组 span 的候选文本批量解析为词典命中。
    /// 输入顺序保留；返回与输入等长的候选数组（可为空数组 = OOV）。
    func resolveCandidates(_ spans: [SpanCandidates]) async throws -> [[MorphologyCandidate]]
}

/// 一个待解析 span 的输入：surface 原文 + Deinflector 候选链。
public struct SpanCandidates: Equatable, Sendable {
    /// 原文（未规范化）。
    public let surface: String
    /// 规范化表记集（exact 通道：cost-0 identity 走此路，无 POS 门——
    /// spike §3.3：identity 候选 admissiblePOS 为活用类集合，
    /// 须经 exact 通道而非 POS 过滤）。
    public let normalizedForms: [String]
    /// Deinflector 候选（lemma + admissiblePOS + reasons + cost）。
    public let deinflections: [DeinflectionCandidate]

    public init(
        surface: String,
        normalizedForms: [String],
        deinflections: [DeinflectionCandidate]
    ) {
        self.surface = surface
        self.normalizedForms = normalizedForms
        self.deinflections = deinflections
    }
}

/// 有界 span 合并预算（§6.1）：最多相邻 4 个系统 token、
/// 合计 24 UTF-16 units。食べていた 类多 token 活用段靠它还原。
///
/// 冻结的 span 选择规则（S01 spike §3.2/§7 决议——最长命中即收
/// 是错的：してしまった 整 span 会解析成 知る；正确解是
/// して→する + しまった→しまう）：
/// (a) 对每个起点枚举 span 集，优先取「首个 lemma 可解的最长 span」；
/// (b) 原 token 级已可解的 token 不可被更长 span 吞并；
/// (c) 纯かな助动词前缀（て/で/い/ます/しまっ…）倾向作新词起点；
/// (d) 仍平局 → resolutionStatus = ambiguous，交用户选择入口，
///     不自动挖词（§6.2：不按概率最高自动挖词）。
public enum MorphologySpanBudget {
    public static let maximumSpanTokens = 4
    public static let maximumSpanUTF16Length = 24
}

/// 词法分析错误。
public enum MorphologyError: Error, Equatable, Sendable {
    case cancelled
    /// 系统能力缺失（availableTagSchemes 不支持所需 scheme）——
    /// 不是空 lemma 的成功结果，调用方须显式降级。
    case capabilityMissing(missing: String)
}
