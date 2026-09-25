import Foundation

/// 本地日语词典值对象（S06 / 技术文档 §4.3、§4.4、冻结协议 §2.4/§2.6）。
///
/// 全部类型只读、纯值语义；OboeDomain 不 import GRDB。
/// 语言码沿用产物数据（ISO 639-2/3：`eng`、`zho`），释义用语决策见 D08：
/// 模型如实暴露语言与 `isMachineGenerated`，不假装存在人工中文释义。

// MARK: - 元数据与来源

/// `dictionary_metadata` 表解析结果。打开校验只要求 `schemaVersion == "1"`
/// 且 `datasetVersion` 非空，其余字段如实透出（缺省为 nil/0）。
public struct DictionaryMetadata: Equatable, Sendable {
    /// `dictionary_metadata.schema_version`（冻结契约要求 "1"）
    public let schemaVersion: String
    /// `dataset_version`（缺省时回退 `dictionary_version`，两者皆空判不兼容）
    public let datasetVersion: String
    /// `dictionary_version`
    public let dictionaryVersion: String
    public let builtAt: String?
    public let entryCount: Int
    public let formCount: Int
    public let readingCount: Int
    public let senseCount: Int
    public let glossCount: Int
    public let licenseRevision: String?
    public let jmdictSourceVersion: String?
    public let jmdictSourceSHA256: String?
    public let chineseLayerVersion: String?
    /// 规范化器标识，如 `oboe-search-normalizer/1`
    public let normalizer: String?
    /// `zh_alignment_rate`（无该键或解析失败为 nil）
    public let zhAlignmentRate: Double?
    /// 全部原始 key/value，便于 UI/诊断展示未建模字段
    public let rawValues: [String: String]

    public init(
        schemaVersion: String,
        datasetVersion: String,
        dictionaryVersion: String,
        builtAt: String? = nil,
        entryCount: Int = 0,
        formCount: Int = 0,
        readingCount: Int = 0,
        senseCount: Int = 0,
        glossCount: Int = 0,
        licenseRevision: String? = nil,
        jmdictSourceVersion: String? = nil,
        jmdictSourceSHA256: String? = nil,
        chineseLayerVersion: String? = nil,
        normalizer: String? = nil,
        zhAlignmentRate: Double? = nil,
        rawValues: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.datasetVersion = datasetVersion
        self.dictionaryVersion = dictionaryVersion
        self.builtAt = builtAt
        self.entryCount = entryCount
        self.formCount = formCount
        self.readingCount = readingCount
        self.senseCount = senseCount
        self.glossCount = glossCount
        self.licenseRevision = licenseRevision
        self.jmdictSourceVersion = jmdictSourceVersion
        self.jmdictSourceSHA256 = jmdictSourceSHA256
        self.chineseLayerVersion = chineseLayerVersion
        self.normalizer = normalizer
        self.zhAlignmentRate = zhAlignmentRate
        self.rawValues = rawValues
    }
}

/// `dictionary_sources` 行 —— Sources/Licenses 页唯一事实源（D03）。
public struct DictionarySourceInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let url: String
    public let license: String
    public let licenseURL: String
    /// ISO 时间串，来自锁定 manifest
    public let retrievedAt: String
    /// 输入文件摘要（构建端校验用）
    public let sha256: String
    public let inputBytes: Int64
    /// 许可要求的归属说明原文
    public let attribution: String
    /// `consumed_tables_json` 解码后的表清单（解析失败为空数组）
    public let consumedTables: [String]
    /// 上游数据被构建管线做过的修改说明
    public let modifications: String

    public init(
        id: String,
        name: String,
        version: String,
        url: String,
        license: String,
        licenseURL: String,
        retrievedAt: String,
        sha256: String,
        inputBytes: Int64,
        attribution: String,
        consumedTables: [String],
        modifications: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.url = url
        self.license = license
        self.licenseURL = licenseURL
        self.retrievedAt = retrievedAt
        self.sha256 = sha256
        self.inputBytes = inputBytes
        self.attribution = attribution
        self.consumedTables = consumedTables
        self.modifications = modifications
    }
}

// MARK: - 词条详情

/// `forms` 行：原显示表记 + 表记类型（standard / sK 等 JMdict ke_inf）。
public struct DictionaryForm: Equatable, Sendable {
    public let id: Int64
    public let text: String
    /// `standard` / `sK`(search-only) 等；UI 可据此隐藏罕用表记
    public let formType: String
    /// JMdict priority 派生值，越小越常见；非语料词频
    public let priority: Int?

    public init(id: Int64, text: String, formType: String, priority: Int?) {
        self.id = id
        self.text = text
        self.formType = formType
        self.priority = priority
    }
}

/// `readings` 行。`restrictedFormIDs/Forms` 来自 reading_form_restrictions：
/// 非空时该读音仅适用于列出的表记；空集表示未限制（schema 契约）。
public struct DictionaryReading: Equatable, Sendable {
    public let id: Int64
    public let reading: String
    /// JMdict `re_nokanji`：该读音非真实表记（仅说明读音）
    public let noKanji: Bool
    public let restrictedFormIDs: [Int64]
    /// 冗余的表记文本，免回查
    public let restrictedForms: [String]

    public init(
        id: Int64,
        reading: String,
        noKanji: Bool,
        restrictedFormIDs: [Int64],
        restrictedForms: [String]
    ) {
        self.id = id
        self.reading = reading
        self.noKanji = noKanji
        self.restrictedFormIDs = restrictedFormIDs
        self.restrictedForms = restrictedForms
    }
}

/// `glosses` 行。`isMachineGenerated` 如实暴露（Tomoshi 中文层为
/// LLM 辅助生成，D08/§4.1 不得标为人工词典）。
public struct DictionaryGloss: Equatable, Sendable {
    public let language: String
    public let text: String
    public let order: Int
    public let sourceID: String
    public let isMachineGenerated: Bool
    /// 中文对齐指纹（entryID+gloss/POS 指纹，§4.1.4）；eng gloss 为 nil
    public let sourceFingerprint: String?

    public init(
        language: String,
        text: String,
        order: Int,
        sourceID: String,
        isMachineGenerated: Bool,
        sourceFingerprint: String? = nil
    ) {
        self.language = language
        self.text = text
        self.order = order
        self.sourceID = sourceID
        self.isMachineGenerated = isMachineGenerated
        self.sourceFingerprint = sourceFingerprint
    }
}

/// `sense_tags` 行：category ∈ field/misc/dialect/xref/ant/s_inf/lsource/gloss_attr。
public struct DictionarySenseTag: Equatable, Sendable {
    public let category: String
    public let code: String

    public init(category: String, code: String) {
        self.category = category
        self.code = code
    }
}

/// `senses` 聚合：POS codes、分类 tags、分语言 glosses、表记/读音限定。
public struct DictionarySense: Equatable, Sendable {
    public let id: Int64
    /// `sense_order`（当前快照内稳定，跨快照不承诺）
    public let order: Int
    /// 原始 JMdict POS code（v1/v5u/n/…），供 DeinflectionCandidate.admissiblePOS 交集过滤
    public let posCodes: [String]
    public let tags: [DictionarySenseTag]
    /// 按 `gloss_order` 排序的多语言释义
    public let glosses: [DictionaryGloss]
    /// 空集 = 未限定
    public let restrictedFormIDs: [Int64]
    public let restrictedForms: [String]
    public let restrictedReadingIDs: [Int64]
    public let restrictedReadings: [String]

    public init(
        id: Int64,
        order: Int,
        posCodes: [String],
        tags: [DictionarySenseTag],
        glosses: [DictionaryGloss],
        restrictedFormIDs: [Int64] = [],
        restrictedForms: [String] = [],
        restrictedReadingIDs: [Int64] = [],
        restrictedReadings: [String] = []
    ) {
        self.id = id
        self.order = order
        self.posCodes = posCodes
        self.tags = tags
        self.glosses = glosses
        self.restrictedFormIDs = restrictedFormIDs
        self.restrictedForms = restrictedForms
        self.restrictedReadingIDs = restrictedReadingIDs
        self.restrictedReadings = restrictedReadings
    }

    /// 本 sense 指定语言的释义（按 gloss_order）。
    public func glosses(language: String) -> [DictionaryGloss] {
        glosses.filter { $0.language == language }
    }

    /// zh→en 便捷回退（D08）：优先语言无覆盖时返回回退语言，
    /// 并在返回值中如实报告实际语言，UI 负责加语言标签。
    /// 返回 nil 表示两种语言都没有释义。
    public func preferredGlosses(
        preferred: String = DictionaryGlossLanguage.chinese,
        fallback: String = DictionaryGlossLanguage.english
    ) -> (language: String, glosses: [DictionaryGloss])? {
        let preferredGlosses = glosses(language: preferred)
        if !preferredGlosses.isEmpty { return (preferred, preferredGlosses) }
        let fallbackGlosses = glosses(language: fallback)
        if !fallbackGlosses.isEmpty { return (fallback, fallbackGlosses) }
        return nil
    }
}

/// `entry_gloss_overlays` 行：只能 entry 级对齐、无法 sense 对齐的补充释义。
public struct DictionaryEntryOverlay: Equatable, Sendable {
    public let language: String
    public let text: String
    public let sourceID: String

    public init(language: String, text: String, sourceID: String) {
        self.language = language
        self.text = text
        self.sourceID = sourceID
    }
}

/// 词条完整详情（`entry(id:)`/`entries(ids:)` 的聚合结果）。
public struct DictionaryEntry: Equatable, Sendable {
    /// JMdict `ent_seq`
    public let id: Int64
    public let primaryForm: String
    /// 常见度派生 rank，越小越常见；nil = 非常见词
    public let commonRank: Int?
    public let forms: [DictionaryForm]
    public let readings: [DictionaryReading]
    /// 按 `sense_order` 排序
    public let senses: [DictionarySense]
    /// entry 级补充释义（当前产物为空表，模型仍支持）
    public let overlayGlosses: [DictionaryEntryOverlay]

    public init(
        id: Int64,
        primaryForm: String,
        commonRank: Int?,
        forms: [DictionaryForm],
        readings: [DictionaryReading],
        senses: [DictionarySense],
        overlayGlosses: [DictionaryEntryOverlay] = []
    ) {
        self.id = id
        self.primaryForm = primaryForm
        self.commonRank = commonRank
        self.forms = forms
        self.readings = readings
        self.senses = senses
        self.overlayGlosses = overlayGlosses
    }

    /// 全词条 POS code 并集（sense_pos ∩ admissiblePOS 过滤用）
    public var partOfSpeechCodes: Set<String> {
        Set(senses.flatMap(\.posCodes))
    }

    /// 全部 sense 中某语言的释义。
    public func glosses(language: String) -> [DictionaryGloss] {
        senses.flatMap { $0.glosses(language: language) }
    }

    /// zh→en 回退：返回第一个有可用释义的 sense 语言结果。
    /// 没有任何语言覆盖时返回 nil。
    public func preferredGlosses(
        preferred: String = DictionaryGlossLanguage.chinese,
        fallback: String = DictionaryGlossLanguage.english
    ) -> (language: String, glosses: [DictionaryGloss])? {
        for sense in senses {
            if let result = sense.preferredGlosses(preferred: preferred, fallback: fallback) {
                return result
            }
        }
        return nil
    }
}

/// 产物中实际使用的语言码。
public enum DictionaryGlossLanguage {
    public static let english = "eng"
    public static let chinese = "zho"
}

// MARK: - 搜索

/// 命中原因（冻结协议 §2.4 `matchReason`）。
public enum DictionaryMatchReason: String, Codable, Equatable, Sendable {
    /// 命中表记/读音与用户原始输入逐字符相同（规范化前）
    case exact
    /// 命中经 `SearchTextNormalizer` 规范化（如「タベル」→「たべる」）
    case normalized
    /// 变形还原候选命中（`reasonChain`/`matchedLemma` 透传变形链）
    case deinflected
    /// 规范化前缀命中
    case prefix
}

/// 命中通道：forms 表记或 readings 读音。
public enum DictionaryMatchChannel: String, Codable, Equatable, Sendable {
    case form
    case reading
}

/// 单条搜索命中（§2.4 wire spec：entryID、匹配形式、匹配原因、变形链、rank）。
/// 同一 entry 在页内去重后，命中表面为首个命中位置的表记/读音集合。
public struct DictionaryHit: Equatable, Sendable {
    public let entryID: Int64
    /// 首个命中位置匹配到的显示表面（form text 或 reading）
    public let matchedForm: String
    /// 首个命中位置的 normalized 值（精确段 = normalizedQuery；
    /// 前缀段 = 该 entry 最小匹配 normalized；变形段 = 命中 lemma 的规范化形）
    public let matchedNormalized: String
    /// 同一位置的全部匹配表面（form/reading 双通道去重后可能多于一个）
    public let matchedSurfaces: [String]
    public let channel: DictionaryMatchChannel
    public let reason: DictionaryMatchReason
    /// 变形原因链（deinflected 命中透传 DeinflectionCandidate.reasons；其余为空）
    public let reasonChain: [String]
    /// 变形还原出的原形（deinflected 命中）
    public let matchedLemma: String?
    /// entries.common_rank
    public let rank: Int?

    public init(
        entryID: Int64,
        matchedForm: String,
        matchedNormalized: String = "",
        matchedSurfaces: [String],
        channel: DictionaryMatchChannel,
        reason: DictionaryMatchReason,
        reasonChain: [String] = [],
        matchedLemma: String? = nil,
        rank: Int? = nil
    ) {
        self.entryID = entryID
        self.matchedForm = matchedForm
        self.matchedNormalized = matchedNormalized
        self.matchedSurfaces = matchedSurfaces
        self.channel = channel
        self.reason = reason
        self.reasonChain = reasonChain
        self.matchedLemma = matchedLemma
        self.rank = rank
    }
}

/// keyset 游标（Codable、不透明、可序列化）。
///
/// form/reading 双通道各自记录最后消费位置 `KeysetBound`；
/// `phase` 表示页序阶段（exact → deinflected → prefix）；
/// `deinflectedOffset` 是变形候选区段内的确定性偏移。
/// `datasetVersion` 绑定词典版本：版本变化后调用方必须丢弃游标
/// 重新从第一页查询（仓储对失配游标按 nil 处理并重新从头开始）。
public struct DictionarySearchCursor: Codable, Equatable, Sendable {
    /// 游标格式版本，当前为 1
    public var formatVersion: Int
    /// 生成游标时的 `dictionary_metadata.dataset_version`
    public var datasetVersion: String
    /// 0 = 规范化精确、1 = 变形候选精确、2 = 规范化前缀
    public var phase: Int
    /// forms 通道已消费到的位置（含本位置）
    public var formBound: KeysetBound?
    /// readings 通道已消费到的位置（含本位置）
    public var readingBound: KeysetBound?
    /// forms 通道已耗尽
    public var formExhausted: Bool
    /// readings 通道已耗尽
    public var readingExhausted: Bool
    /// deinflected 区段已发射的条目数
    public var deinflectedOffset: Int

    public init(
        formatVersion: Int = 1,
        datasetVersion: String,
        phase: Int,
        formBound: KeysetBound? = nil,
        readingBound: KeysetBound? = nil,
        formExhausted: Bool = false,
        readingExhausted: Bool = false,
        deinflectedOffset: Int = 0
    ) {
        self.formatVersion = formatVersion
        self.datasetVersion = datasetVersion
        self.phase = phase
        self.formBound = formBound
        self.readingBound = readingBound
        self.formExhausted = formExhausted
        self.readingExhausted = readingExhausted
        self.deinflectedOffset = deinflectedOffset
    }

    /// 通道位置：精确阶段按 (rank, entryID)，前缀阶段按 (normalized, entryID)。
    public struct KeysetBound: Codable, Equatable, Sendable {
        /// 前缀阶段：最后消费的 normalized 值；精确阶段未用（空串）
        public var normalized: String
        /// 精确阶段：最后消费的 common_rank（NULL 记为 `Int.max`）；前缀阶段未用
        public var rank: Int
        public var entryID: Int64

        public init(normalized: String = "", rank: Int = 0, entryID: Int64) {
            self.normalized = normalized
            self.rank = rank
            self.entryID = entryID
        }
    }
}

/// 搜索请求（冻结协议 §2.4）：原词、规范化词、变形候选、limit、cursor。
/// `normalizedQuery` 由 init 用 `SearchTextNormalizer` 计算，保证与
/// 产物 normalized_* 列同一算法（`oboe-search-normalizer/1`）。
public struct DictionarySearchRequest: Equatable, Sendable {
    /// 单查询长度上限（§4.4）
    public static let maxQueryLength = 128
    /// 变形候选预算（§4.4）
    public static let maxCandidates = 128
    /// 默认页大小
    public static let defaultLimit = 30
    /// 最大页大小
    public static let maxLimit = 100

    public let query: String
    public let normalizedQuery: String
    /// Deinflector 输出（可含截断标记；仓储负责跳过）
    public let candidates: [DeinflectionCandidate]
    public let limit: Int
    /// 翻页游标：**必须与第一页相同的 query/candidates 一起重放**，
    /// 否则页序不可保证（变形候选段是按请求重建的确定性列表）。
    public let cursor: DictionarySearchCursor?

    public init(
        query: String,
        candidates: [DeinflectionCandidate] = [],
        limit: Int = DictionarySearchRequest.defaultLimit,
        cursor: DictionarySearchCursor? = nil
    ) {
        let truncatedQuery = String(query.prefix(Self.maxQueryLength))
        self.query = truncatedQuery
        self.normalizedQuery = SearchTextNormalizer.normalize(truncatedQuery)
        self.candidates = Array(candidates.prefix(Self.maxCandidates))
        self.limit = min(max(limit, 1), Self.maxLimit)
        self.cursor = cursor
    }
}

/// 搜索分页结果：`items + nextCursor + hasMore`（任务冻结）。
public struct DictionarySearchPage: Equatable, Sendable {
    /// 页序：规范化精确命中在前（按 common_rank、entryID），
    /// 其后变形候选命中（按 common_rank、候选 cost、entryID），
    /// 最后规范化前缀命中（按 (normalized, entryID)）。
    public let items: [DictionaryHit]
    /// 继续翻页所需游标；`hasMore == false` 时为 nil
    public let nextCursor: DictionarySearchCursor?
    public let hasMore: Bool
    /// 本页实际生效的规范化查询串
    public let normalizedQuery: String

    public init(
        items: [DictionaryHit],
        nextCursor: DictionarySearchCursor?,
        hasMore: Bool,
        normalizedQuery: String
    ) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.normalizedQuery = normalizedQuery
    }
}

/// 词典错误：版本不符是**可恢复错误**（禁用查词功能），不是崩溃。
public enum DictionaryError: Error, Equatable, Sendable {
    /// `schema_version` 缺失或 != "1"，或 `dataset_version`/`dictionary_version` 皆空
    case incompatibleSchema(found: String?)
    /// 词典文件不存在或不可读（包装底层错误描述）
    case unavailable(String)
    /// 游标无法解码/格式版本未知
    case invalidCursor
}
