import CryptoKit
import Foundation

/// v0.7.5 S09：AI 学习分析（Reader study）请求/响应契约与值类型。
/// 依据：contracts-frozen rev2 §3（Resolver 契约、分层校验、预算常量）、
/// §3.3（BlockOutcome/Resolution）、§4.4（requestHash 字段集）、
/// 技术文档 §6–§7、S02-B 基线（候选只到 entry 级、OOV 伪候选 6/9）。
///
/// 本文件只有纯值类型与常量——不 import GRDB/网络/SwiftUI。
/// Provider 接线（S10）、Job 持久化（S11）不在本工作包。
///
/// # 核心设计（对应契约条款）
///
/// - **sense 级候选**：`AIStudyCandidate` 携带
///   `senses[{senseID, enGlosses, restrictedForms, restrictedReadings}]`。
///   S02-B 实测 `MorphologyCandidate` 只到 entryID（sense 可见性 0/333），
///   本契约是「AI 只能在候选内选 sense」的判定基础。
/// - **OOV 显式占位**：`candidates == []` 的 token 照常进请求，
///   AI 无候选可选，validator 拒绝任何非集合内 entry——
///   6/9 伪候选是 validator 存在的直接动机。
/// - **tokenID 可重建**：由 (blockKey, utf16Start, utf16Len) 派生短 ID，
///   非随机 UUID（§3.1：range 派生或有序短 ID；§6.2：跨请求不依赖随机）。
/// - **不静默砍义项**：候选 entry 数超上限或序列化超预算时置
///   `needsCandidateConfirmation` 标记位进确认队列，不丢字段换表面置信度。

// MARK: - 预算常量（contracts §3.2 rev2 冻结值 + validator 工程边界）

/// AI 请求/响应的工程预算与路由阈值。
///
/// 前四个常量为 rev2 冻结值（S02-B 实测确认：40×769B≈31KB < 48KiB，
/// occurrence 上限先于字节上限触发）；其余为 validator 防御边界，
/// 取值偏宽松——目的是挡住失控响应，不是收紧正常流量。
public enum AIStudyBudget {
    /// 每请求目标 occurrence 上限（§3.2）。
    public static let maxTargetOccurrencesPerRequest = 40
    /// 单请求序列化输入字节上限（UTF-8，§3.2）。
    public static let serializedInputBudgetBytes = 48 * 1024
    /// 每 token 候选 entry 上限（§3.1 `candidates[]: ≤5 entry`）。
    public static let maxCandidatesPerEntry = 5
    /// 低置信路由阈值：confidence < 此值合法但进确认队列（§3.2）。
    public static let lowConfidenceThreshold = 0.80

    // MARK: validator 防御边界（S09 工程值，非冻结契约）

    /// 响应体原始字节上限——外层校验在解码前先挡掉失控体积。
    public static let maxResponseBytes = 256 * 1024
    /// 外层 JSON 深度上限（递归结构防御）。
    public static let maxJSONDepth = 32
    /// `words[]` 元素上限（≥ 40 目标的正常响应远低于此）。
    public static let maxWordItems = 2048
    /// 译文 trim 后字符数上限——超限仅 translation 子状态失败。
    public static let maxTranslationLength = 4096
    /// 序列化预算中预留给请求元数据/prompt 模板的部分。
    /// block 打包时按 `serializedInputBudgetBytes - 此值` 计容量。
    public static let requestEnvelopeReserveBytes = 2048
    /// 每 sense 发送的英文 gloss 上限（S02-B §6 建议：
    /// 只带 ≤3 个最相关 gloss 而非全部；超限不丢 sense，只截 gloss 列表）。
    public static let maxGlossesPerSense = 3
}

// MARK: - 请求侧：token / candidate / block / request（§3.1）

/// 送交 Provider 的目标 token（一个 occurrence 一个 tokenID，
/// 不按 surface 合并——§6.2）。
public struct AIStudyToken: Equatable, Sendable {
    /// 请求内稳定短 ID：`t` + SHA256(blockKey|start|len) 前 12 hex。
    /// 可重建、非随机（§3.1/§6.2）。
    public let tokenID: String
    /// 原文切片（渲染原文，未规范化）。
    public let surface: String
    /// 词法分析还原原形；OOV token 可为 nil。
    public let lemma: String?
    /// token 实际活用读音（非 lemma 读音）；可为 nil。
    public let reading: String?
    /// 粗粒度词性族提示（prompt hint，如 "verb"/"noun"/"auxiliary"）；
    /// 不作校验依据。
    public let posFamily: String?
    /// token 起点（原文块 UTF-16 坐标）。
    public let utf16Start: Int
    /// token 长度（UTF-16 units）。
    public let utf16Length: Int
    /// sense 级候选集（按固定序，≤ `AIStudyBudget.maxCandidatesPerEntry`）；
    /// 空 = OOV/无候选显式占位——AI 不得为其造词。
    public let candidates: [AIStudyCandidate]
    /// 候选过多需确认标记（§6.3：候选组超上限/超预算时置位，
    /// 不静默砍义项制造高置信答案）。
    public let needsCandidateConfirmation: Bool

    public init(
        tokenID: String,
        surface: String,
        lemma: String?,
        reading: String?,
        posFamily: String?,
        utf16Start: Int,
        utf16Length: Int,
        candidates: [AIStudyCandidate],
        needsCandidateConfirmation: Bool = false
    ) {
        self.tokenID = tokenID
        self.surface = surface
        self.lemma = lemma
        self.reading = reading
        self.posFamily = posFamily
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.candidates = candidates
        self.needsCandidateConfirmation = needsCandidateConfirmation
    }

    /// UTF-16 区间（`utf16Start..<utf16Start+utf16Length`）。
    public var utf16Range: Range<Int> { utf16Start..<(utf16Start + utf16Length) }
}

/// 一个候选词典条目：entryID + sense 级明细。
/// `matchedForm`/`matchedReading` 记录 planner 判定 sense 限制时使用的
/// 表记/读音证据——validator 用同一证据复核「sense 的表记/读音限制有效」
/// （§7 表单项层），两边证据一致才不会误杀合法候选。
public struct AIStudyCandidate: Equatable, Sendable {
    /// JMdict `ent_seq`。
    public let entryID: Int64
    /// 候选还原原形（prompt 展示 + validator 证据）。
    public let lemma: String?
    /// 候选命中读音（词典 readings 回填；无回退到 token 活用读音）。
    public let reading: String?
    /// 满足 `restrictedForms` 的表记证据（无限制时为 lemma）。
    public let matchedForm: String?
    /// 满足 `restrictedReadings` 的读音证据（无限制时为命中读音）。
    public let matchedReading: String?
    /// 该 occurrence 下 admissible POS 交集（`candidate.posCodes ∩
    /// 保留 sense.posCodes` 的并集；候选无 POS 门时为保留 sense 并集）——
    /// 供 prompt 消歧与 `posFamily` 派生，非 validator 校验字段。
    public let posCodes: [String]
    /// 该 occurrence 下合法的 sense 集——已经过 admissible POS 与
    /// 表记/读音限制过滤；空集候选不发送（入口即被 planner 丢弃）。
    public let senses: [AIStudyCandidateSense]

    public init(
        entryID: Int64,
        lemma: String?,
        reading: String?,
        matchedForm: String?,
        matchedReading: String?,
        posCodes: [String] = [],
        senses: [AIStudyCandidateSense]
    ) {
        self.entryID = entryID
        self.lemma = lemma
        self.reading = reading
        self.matchedForm = matchedForm
        self.matchedReading = matchedReading
        self.posCodes = posCodes
        self.senses = senses
    }
}

/// 候选内的一个可选义项。`senseID` 是**本次候选快照行 ID**
/// （`senses.id`），不是 entry 内义项序号——prompt 必须显式说明（§7）。
public struct AIStudyCandidateSense: Equatable, Sendable {
    public let senseID: Int64
    /// 英文 gloss（按 gloss_order，至多 `maxGlossesPerSense` 条）。
    public let enGlosses: [String]
    /// stagk 表记限制文本；空 = 未限定。
    public let restrictedForms: [String]
    /// stagr 读音限制文本；空 = 未限定。
    public let restrictedReadings: [String]

    public init(
        senseID: Int64,
        enGlosses: [String],
        restrictedForms: [String],
        restrictedReadings: [String]
    ) {
        self.senseID = senseID
        self.enGlosses = enGlosses
        self.restrictedForms = restrictedForms
        self.restrictedReadings = restrictedReadings
    }
}

/// 一个请求块：目标文本 + 有限上下文 + token/候选集。
/// 对应 `ai_study_job_blocks` 一行的领域投影（S11 落库）。
public struct AIStudyBlock: Equatable, Sendable {
    /// 块稳定键：`"<scopeKey>#r<utf16Start>-<utf16End>"`——
    /// 同 sourceHash 的各 subblock 以目标区间区分，互不重叠。
    public let blockKey: String
    /// 本块负责翻译/消歧的原文切片（原文 UTF-16 range 对应文本）。
    public let targetText: String
    /// 有限相邻上下文——可重叠，但不重复翻译/创建 occurrence（§6.3）。
    public let context: String
    /// 目标区间起点（原文 UTF-16 坐标）。
    public let targetUTF16Start: Int
    /// 目标区间长度（UTF-16 units）。
    public let targetUTF16Length: Int
    /// 目标 token 序列（`words[]` 应答只允许引用这些 tokenID）。
    public let tokens: [AIStudyToken]
    /// 实际发送候选集的 canonical JSON SHA-256（§4.4 requestHash 组分）。
    /// 由 planner 在定稿时计算，serializer 可重算校验。
    public let candidateSetHash: String
    /// 本块是否请求译文（§6.3 允许纯词义修复请求不翻）。
    public let wantsTranslation: Bool

    public init(
        blockKey: String,
        targetText: String,
        context: String,
        targetUTF16Start: Int,
        targetUTF16Length: Int,
        tokens: [AIStudyToken],
        candidateSetHash: String,
        wantsTranslation: Bool = true
    ) {
        self.blockKey = blockKey
        self.targetText = targetText
        self.context = context
        self.targetUTF16Start = targetUTF16Start
        self.targetUTF16Length = targetUTF16Length
        self.tokens = tokens
        self.candidateSetHash = candidateSetHash
        self.wantsTranslation = wantsTranslation
    }

    /// 目标区间（UTF-16）。
    public var targetUTF16Range: Range<Int> {
        targetUTF16Start..<(targetUTF16Start + targetUTF16Length)
    }
}

/// 请求元数据快照——requestHash 的环境/版本组分（§4.4）。
/// `endpointFingerprint` 必须经 `AIStudyEndpointFingerprint.normalize`
/// 规范化且**不含 API Key**（同 model 不同服务端不得串缓存）。
public struct AIStudyRequestMetadata: Equatable, Sendable {
    public let dictionaryDatasetVersion: String
    public let morphologyVersion: String
    public let parserVersion: String
    /// 系统 tokenizer 随 OS 漂移——记系统 build 号（TokenCacheKey 同口径）。
    public let osBuild: String
    /// 供应商族（`AIServiceKind.rawValue` 或 protocol 标识）。
    public let providerKind: String
    /// 规范化 endpoint 指纹（scheme://host[:port][/path]，无凭据无 query）。
    public let endpointFingerprint: String
    public let model: String
    /// `AIResponseFormatMode.rawValue`——不同输出模式不串缓存。
    public let responseMode: String
    public let promptVersion: String
    /// 目标语言（如 `"zho"`；决定译文与释义语言）。
    public let language: String
    /// 生成参数快照（键值均为字符串的确定性映射；
    /// canonical JSON 按键排序进 hash，参数变动即换键）。
    public let generationParameters: [String: String]

    public init(
        dictionaryDatasetVersion: String,
        morphologyVersion: String,
        parserVersion: String,
        osBuild: String,
        providerKind: String,
        endpointFingerprint: String,
        model: String,
        responseMode: String,
        promptVersion: String,
        language: String,
        generationParameters: [String: String] = [:]
    ) {
        self.dictionaryDatasetVersion = dictionaryDatasetVersion
        self.morphologyVersion = morphologyVersion
        self.parserVersion = parserVersion
        self.osBuild = osBuild
        self.providerKind = providerKind
        self.endpointFingerprint = endpointFingerprint
        self.model = model
        self.responseMode = responseMode
        self.promptVersion = promptVersion
        self.language = language
        self.generationParameters = generationParameters
    }
}

/// 完整请求值对象（§3.1）。planner 当前每请求只发一个 block
/// （与 `ai_study_job_blocks` 1:1，`requestHash` 即块级缓存键）；
/// `blocks` 保持数组形态以兼容契约与未来合批。
public struct AIStudyRequest: Equatable, Sendable {
    /// 冻结 schema 版本（§3.1）。
    public static let schemaVersion = 1

    public let schemaVersion: Int
    /// 本地 opaque ID：`rq-` + SHA256(blockKey|schemaVersion) 前 16 hex——
    /// 稳定可重建编码，响应校验按它精确匹配（§3.2 requestID 校验）。
    public let requestID: String
    public let blocks: [AIStudyBlock]
    public let metadata: AIStudyRequestMetadata
    /// §4.4 requestHash——planner 定稿时计算落值；
    /// `AIStudyRequestSerializer.requestHash` 可对同输入确定性重算。
    public let requestHash: String

    public init(
        requestID: String,
        blocks: [AIStudyBlock],
        metadata: AIStudyRequestMetadata,
        requestHash: String,
        schemaVersion: Int = AIStudyRequest.schemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.blocks = blocks
        self.metadata = metadata
        self.requestHash = requestHash
    }
}

// MARK: - 响应侧：wire 形状（§3.2）

/// Provider 返回的单个词结果（外层 JSON `words[]` 元素）。
/// 注：validator 不用 Codable 严格解码它——逐元素 tolerant decode
/// 在 `AIStudyResponseValidator` 手写实现，本类型只作结构化投影。
public struct AIStudyWordResult: Codable, Equatable, Sendable {
    public let tokenID: String
    /// `"resolved" | "unresolved"`。
    public let status: String
    public let entryID: Int64?
    /// 本次候选快照行 ID，**不是义项序号**。
    public let senseID: Int64?
    public let confidence: Double?

    public init(
        tokenID: String,
        status: String,
        entryID: Int64? = nil,
        senseID: Int64? = nil,
        confidence: Double? = nil
    ) {
        self.tokenID = tokenID
        self.status = status
        self.entryID = entryID
        self.senseID = senseID
        self.confidence = confidence
    }
}

/// Provider 响应外层（§3.2 示例 JSON 的结构化投影）。
/// `translation` 可选：类型错误/缺失只影响 translation 子状态。
public struct AIStudyResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let translation: String?
    public let words: [AIStudyWordResult]

    public init(
        schemaVersion: Int,
        requestID: String,
        translation: String?,
        words: [AIStudyWordResult]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.translation = translation
        self.words = words
    }
}

// MARK: - 校验输出：Resolution / BlockOutcome（§3.3）

/// resolution 状态（§3.3 冻结集）。
public enum AIStudyResolutionStatus: String, Codable, Sendable {
    /// AI 选择合法且 confidence ≥ 阈值（或缺席按低置信路由——
    /// 缺席不进本态）。
    case aiResolved
    /// 用户在确认/预览中选定（S15/S16 写入路径使用；validator 不产生）。
    case userConfirmed
    /// 合法候选但 confidence < 0.80（含 resolved 应答缺 confidence）——
    /// 进确认队列，不可自动采纳。
    case lowConfidence
    /// 未解析：缺项/OOV/重复降级/非法项降级 的归并出口。
    case unresolved
    /// 应答给出非法候选被拒绝（跨 token 偷换/集合外 entry/sense/限制不符）。
    /// 与 unresolved 区分：rejected 表示「AI 给了答案但被我们拒了」。
    case rejected
}

/// resolution 来源（§3.3：ai|user|local）。
public enum AIStudyResolutionOrigin: String, Codable, Sendable {
    case ai
    case user
    case local
}

/// resolution 的 reasonCode——落库 CHECK 域（§3.3 reasonCode?）。
/// 注意部分 code 是**计数/日志归因**：`tokenNotInRequest`、
/// `malformedItem`、`envelopeRejected` 对应的对象不产生 resolution 行
/// （未知 token 不建对象、坏元素不可归因、外层失败整包拒），
/// 它们预留给 S11 错误日志/审计列，不出现在 resolutions[]。
public enum AIStudyReasonCode: String, Codable, Sendable {
    /// OOV/词典无候选——显式占位，不是失败（S02-B：禁止伪候选补词）。
    case noCandidate
    /// 应答缺失该目标 token 的 words 项。
    case missingWord
    /// tokenID 不属于本请求——该元素被丢弃不产生对象（计 dropped）。
    case tokenNotInRequest
    /// entryID/senseID 不在**该 token**候选集（跨 token 偷换/幻觉 entry）。
    case candidateNotInSet
    /// sense 表记/读音限制与该 occurrence 证据不符（§7 单项层）。
    case restrictionNotSatisfied
    /// 相同 tokenID 出现多次——该 token 整体降级（不 last-write-wins）。
    case duplicateTokenID
    /// confidence 非 finite 或越界 [0,1]——该项降级。
    case invalidConfidence
    /// resolved 项缺 entryID 或 senseID——不完整选择降级。
    case incompleteSelection
    /// 单项结构无法 tolerant decode（类型错误/非对象）。
    case malformedItem
    /// status 取值不在契约集。
    case unknownStatus
    /// 单项坏数据之外的外层拒绝（malformed/超界）——块整体 failed。
    case envelopeRejected
    /// 候选组超上限/超预算——planner 侧标记的确认原因。
    case candidateOverflow
    /// 合法但低于 `lowConfidenceThreshold`。
    case belowConfidenceThreshold
}

/// 一次成功选定（§3.3 `selected{provider,entryID,senseID,datasetVersion}`）。
public struct AIStudySelection: Equatable, Sendable {
    /// 词典提供者（当前唯一 `"jmdict"`）。
    public let provider: String
    public let entryID: Int64
    public let senseID: Int64
    /// 选择所针对的快照版本——跨快照不可直接比对（§1.2）。
    public let datasetVersion: String

    public init(
        provider: String = "jmdict",
        entryID: Int64,
        senseID: Int64,
        datasetVersion: String
    ) {
        self.provider = provider
        self.entryID = entryID
        self.senseID = senseID
        self.datasetVersion = datasetVersion
    }
}

/// 单 token 的处置结果（§3.3 resolutions[] 行投影）。
/// 每个**本请求目标 token** 恰有一行；未知 tokenID/坏元素不产生行。
public struct AIStudyResolution: Equatable, Sendable {
    /// 请求内 token 键（= `AIStudyToken.tokenID`；S11 映射持久 tokenKey）。
    public let tokenKey: String
    /// 合法选定；nil = 无有效选择（unresolved/rejected）。
    public let selected: AIStudySelection?
    /// 应答 confidence（经 finite/[0,1] 校验；低置信行保留原值供展示）。
    public let confidence: Double?
    public let status: AIStudyResolutionStatus
    public let reasonCode: AIStudyReasonCode?
    public let origin: AIStudyResolutionOrigin

    public init(
        tokenKey: String,
        selected: AIStudySelection?,
        confidence: Double?,
        status: AIStudyResolutionStatus,
        reasonCode: AIStudyReasonCode?,
        origin: AIStudyResolutionOrigin
    ) {
        self.tokenKey = tokenKey
        self.selected = selected
        self.confidence = confidence
        self.status = status
        self.reasonCode = reasonCode
        self.origin = origin
    }
}

/// 块级词义子状态（§3.3/§4.1：词义与翻译子状态独立）。
public enum AIStudyLexicalStatus: String, Codable, Sendable {
    /// 全部目标 token 取得合法选定（aiResolved/userConfirmed）。
    case resolved
    /// 部分 token 有可用处置（含 lowConfidence 待确认），其余降级。
    case partial
    /// 无任何 token 取得选定（全缺项/OOV/全被拒）。
    case unresolved
    /// 外层校验拒绝（malformed/schema/requestID/超界）——无可信结果。
    case failed
}

/// 块级翻译子状态（§3.3）。
public enum AIStudyTranslationStatus: String, Codable, Sendable {
    case done
    case failed
    case notRequested
}

/// 外层拒绝原因——`lexicalStatus == .failed` 时的归因。
public enum AIStudyEnvelopeRejection: String, Equatable, Sendable {
    /// 原始字节超 `maxResponseBytes`。
    case responseTooLarge
    /// JSON 解析失败/截断——不猜半截 JSON（§7）。
    case malformedJSON
    /// 顶层不是对象。
    case notAnObject
    /// 递归深度超 `maxJSONDepth`。
    case depthExceeded
    /// `schemaVersion != 1`——整包拒。
    case schemaVersionMismatch
    /// `requestID` 与本请求不符——整包拒。
    case requestIDMismatch
    /// `words` 字段存在但非数组。
    case invalidWordsField
    /// `words` 元素数超 `maxWordItems`。
    case tooManyWords
    /// 请求含多个 block——当前契约每请求一块（planner 保证）。
    case unsupportedBlockCount
}

/// 分层校验的输出（§3.3 BlockOutcome + 计数）。
///
/// 消费纪律：
/// - `lexicalStatus == .failed` 时 `resolutions` 恒空、计数只有
///   外层归因——持久层按 failed/retryScheduled 处理，不应用任何词义。
/// - 其他状态下 `resolutions` 覆盖**每个目标 token 恰一行**；
///   未知 tokenID/坏元素只进计数不进数组（§7：未知 token 不创建对象）。
public struct ValidatedBlockOutcome: Equatable, Sendable {
    /// 被应答的块（= `request.blocks[0].blockKey`；外层拒绝时同记）。
    public let blockKey: String
    public let lexicalStatus: AIStudyLexicalStatus
    public let translationStatus: AIStudyTranslationStatus
    /// 合法译文（trim 后）；失败/未请求为 nil。
    public let translation: String?
    /// 外层拒绝归因；非 failed 为 nil。
    public let envelopeRejection: AIStudyEnvelopeRejection?
    public let resolutions: [AIStudyResolution]

    // 计数（§7「记录错误计数」+ S11 统计口径）
    /// 本请求目标 token 总数。
    public let targetTokenCount: Int
    /// status == aiResolved 的 token 数。
    public let aiResolvedCount: Int
    /// status == lowConfidence 的 token 数（进确认队列）。
    public let lowConfidenceCount: Int
    /// status ∈ {unresolved, rejected} 的 token 数。
    public let unresolvedTokenCount: Int
    /// tokenID 不在本请求的丢弃元素数。
    public let droppedUnknownTokenCount: Int
    /// 重复 tokenID 降级的 token 数。
    public let duplicateTokenCount: Int
    /// 无法 tolerant decode 的坏元素数。
    public let malformedItemCount: Int
    /// 结构可解但选择非法/不完整/置信越界的降级元素数。
    public let invalidItemCount: Int

    public init(
        blockKey: String,
        lexicalStatus: AIStudyLexicalStatus,
        translationStatus: AIStudyTranslationStatus,
        translation: String?,
        envelopeRejection: AIStudyEnvelopeRejection?,
        resolutions: [AIStudyResolution],
        targetTokenCount: Int,
        aiResolvedCount: Int,
        lowConfidenceCount: Int,
        unresolvedTokenCount: Int,
        droppedUnknownTokenCount: Int,
        duplicateTokenCount: Int,
        malformedItemCount: Int,
        invalidItemCount: Int
    ) {
        self.blockKey = blockKey
        self.lexicalStatus = lexicalStatus
        self.translationStatus = translationStatus
        self.translation = translation
        self.envelopeRejection = envelopeRejection
        self.resolutions = resolutions
        self.targetTokenCount = targetTokenCount
        self.aiResolvedCount = aiResolvedCount
        self.lowConfidenceCount = lowConfidenceCount
        self.unresolvedTokenCount = unresolvedTokenCount
        self.droppedUnknownTokenCount = droppedUnknownTokenCount
        self.duplicateTokenCount = duplicateTokenCount
        self.malformedItemCount = malformedItemCount
        self.invalidItemCount = invalidItemCount
    }
}

// MARK: - endpoint 指纹规范化（§4.4：不含 Key）

/// `normalizedEndpointFingerprint` 的唯一构造点。
///
/// 规则：`scheme://host[:port][/path]`——
/// - scheme/host 小写；默认端口（https→443、http→80）省略；
/// - 丢弃 userinfo、query、fragment——**凭据永不进指纹**；
/// - path 保留（同一 host 不同网关路径不串缓存），去尾斜杠；
/// - 解析失败的裸串退化为 trim+lowercase（仍不含调用方给的 Key——
///   Key 本来就不属于 URL 字段；本函数不接收 Key 参数，从类型上杜绝）。
public enum AIStudyEndpointFingerprint {
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.host != nil || components.scheme != nil else {
            return trimmed.lowercased()
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if let scheme = components.scheme { components.scheme = scheme.lowercased() }
        if let host = components.host { components.host = host.lowercased() }
        if components.port == 443, components.scheme == "https" { components.port = nil }
        if components.port == 80, components.scheme == "http" { components.port = nil }
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path == "/" { components.path = "" }
        return components.string?.lowercased() ?? trimmed.lowercased()
    }
}

// MARK: - canonical JSON（请求 hash / 序列化共用）

/// 与 `SemanticFingerprint` 同一 canonical 约定：
/// 对象键按 UTF-8 字节序排序、无空白、非 ASCII 原文、最小转义集——
/// 与 Python `json.dumps(ensure_ascii=False, sort_keys=True,
/// separators=(",",":"))` 字节级一致，构建侧可复算。
/// （`CanonicalJSONValue` 在其文件内为 private，此处为模块内共享实现。）
enum AIStudyCanonicalJSON {
    indirect enum Value {
        case string(String)
        case integer(Int64)
        case bool(Bool)
        case null
        case array([Value])
        case object([(String, Value)])

        func serialize(into out: inout String) {
            switch self {
            case .string(let value):
                AIStudyCanonicalJSON.serializeString(value, into: &out)
            case .integer(let value):
                out.append(String(value))
            case .bool(let value):
                out.append(value ? "true" : "false")
            case .null:
                out.append("null")
            case .array(let items):
                out.append("[")
                for (index, item) in items.enumerated() {
                    if index > 0 { out.append(",") }
                    item.serialize(into: &out)
                }
                out.append("]")
            case .object(let pairs):
                let sorted = pairs.sorted {
                    $0.0.utf8.lexicographicallyPrecedes($1.0.utf8)
                }
                out.append("{")
                for (index, pair) in sorted.enumerated() {
                    if index > 0 { out.append(",") }
                    AIStudyCanonicalJSON.serializeString(pair.0, into: &out)
                    out.append(":")
                    pair.1.serialize(into: &out)
                }
                out.append("}")
            }
        }

        var serialized: String {
            var out = ""
            serialize(into: &out)
            return out
        }
    }

    static func serializeString(_ value: String, into out: inout String) {
        out.append("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append("\\\"")
            case 0x5C: out.append("\\\\")
            case 0x08: out.append("\\b")
            case 0x0C: out.append("\\f")
            case 0x0A: out.append("\\n")
            case 0x0D: out.append("\\r")
            case 0x09: out.append("\\t")
            case 0x00...0x1F:
                out.append(String(format: "\\u%04x", scalar.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
    }

    /// SHA-256 lower-hex（64 chars）。
    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// canonical JSON → SHA-256 便捷入口。
    static func sha256Hex(of value: Value) -> String {
        sha256Hex(value.serialized)
    }
}
