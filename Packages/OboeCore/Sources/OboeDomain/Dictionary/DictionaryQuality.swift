import Foundation

/// S19 Dictionary 2.0 基础增强：质量/元数据值对象层（不改 S06 冻结的
/// `DictionaryRepository`/`DictionaryModels`——本文件全部是增量类型）。
///
/// 覆盖四件事：
/// 1. **释义 fallback 链**：zh → en → 显式 `.unavailable` 标记（D08：
///    如实报告实际语言与机翻标记，UI 加语言标签）；
/// 2. **中文覆盖率统计**：entry 级 / sense 级 zh gloss 有无 +
///    `dictionary_metadata` 构建端对齐统计的透出比对；
/// 3. **rejected 报告**：消费侧审计——词典产物中无法被检索/释义链路
///    消费的条目按原因分类（样本有界）；构建期被拒条目在
///    `qa-report.json`（构建端产物，不进包），本报告覆盖的是
///    「产物内但不可用」一侧；
/// 4. **版本/checksum 描述**：`DictionaryArtifactDescriptor` 把
///    metadata 与文件级 SHA-256 钉在一起——词典换库检测与
///    `lexeme_dictionary_bindings` 重绑定的判定输入。

// MARK: - 释义 fallback（zh → en → 无释义）

/// 单条词条的释义呈现决议。`preferredGlosses` 只回答「有没有」，
/// 本类型把 fallback 层级与「无释义」显式化（S19：fallback 链必须
/// 以无释义标记收尾而不是 nil 静默）。
public enum GlossResolution: Equatable, Sendable {
    /// 优先语言（默认 zho）直接命中。
    case preferred(language: String, glosses: [DictionaryGloss])
    /// 优先语言缺失，回落语言（默认 eng）命中。
    case fallback(language: String, glosses: [DictionaryGloss])
    /// 两种语言都无任何释义——UI 显示「无释义」占位而非空白。
    case unavailable

    /// 实际展示语言；`.unavailable` 为 nil。
    public var language: String? {
        switch self {
        case let .preferred(language, _), let .fallback(language, _):
            return language
        case .unavailable:
            return nil
        }
    }

    /// 是否为回退结果（UI 加「EN」标签）。
    public var isFallback: Bool {
        if case .fallback = self { return true }
        return false
    }

    /// gloss 数组（`.unavailable` 为空）。
    public var glosses: [DictionaryGloss] {
        switch self {
        case let .preferred(_, glosses), let .fallback(_, glosses):
            return glosses
        case .unavailable:
            return []
        }
    }
}

public enum GlossFallbackResolver {
    /// sense 级决议：本 sense 的 zh → en → unavailable。
    public static func resolve(
        _ sense: DictionarySense,
        preferred: String = DictionaryGlossLanguage.chinese,
        fallback: String = DictionaryGlossLanguage.english
    ) -> GlossResolution {
        let preferredGlosses = sense.glosses(language: preferred)
        if !preferredGlosses.isEmpty {
            return .preferred(language: preferred, glosses: preferredGlosses)
        }
        let fallbackGlosses = sense.glosses(language: fallback)
        if !fallbackGlosses.isEmpty {
            return .fallback(language: fallback, glosses: fallbackGlosses)
        }
        return .unavailable
    }

    /// entry 级决议：第一个可用 sense 的结果；overlay 释义只作
    /// 「有 zh/en 覆盖」的旁证（overlay 无 sense 序，不进 glosses 明细）。
    public static func resolve(
        _ entry: DictionaryEntry,
        preferred: String = DictionaryGlossLanguage.chinese,
        fallback: String = DictionaryGlossLanguage.english
    ) -> GlossResolution {
        for sense in entry.senses {
            let resolved = resolve(
                sense, preferred: preferred, fallback: fallback)
            if resolved != .unavailable { return resolved }
        }
        // sense 全无 gloss 时看 overlay（entry 级对齐层）。
        let preferredOverlay = entry.overlayGlosses.filter {
            $0.language == preferred
        }
        if !preferredOverlay.isEmpty {
            return .preferred(
                language: preferred,
                glosses: preferredOverlay.enumerated().map { index, overlay in
                    DictionaryGloss(
                        language: overlay.language,
                        text: overlay.text,
                        order: index,
                        sourceID: overlay.sourceID,
                        isMachineGenerated: true
                    )
                })
        }
        let fallbackOverlay = entry.overlayGlosses.filter {
            $0.language == fallback
        }
        if !fallbackOverlay.isEmpty {
            return .fallback(
                language: fallback,
                glosses: fallbackOverlay.enumerated().map { index, overlay in
                    DictionaryGloss(
                        language: overlay.language,
                        text: overlay.text,
                        order: index,
                        sourceID: overlay.sourceID,
                        isMachineGenerated: true
                    )
                })
        }
        return .unavailable
    }
}

// MARK: - 中文覆盖率

/// 中文释义覆盖率（entry 级 + sense 级 + gloss 计数）。
/// `declaredAlignmentRate` 来自 `dictionary_metadata.zh_alignment_rate`
/// （构建端口径），`entryAlignmentRate` 是消费侧实测——两者并列透出，
/// 显著背离即数据质量问题（报告层如实给出，不裁决）。
public struct ChineseCoverageStats: Equatable, Sendable, Codable {
    public let entryCount: Int
    /// 至少一个 zho gloss 的 entry 数。
    public let entriesWithChinese: Int
    public let senseCount: Int
    /// 至少一个 zho gloss 的 sense 数。
    public let sensesWithChinese: Int
    public let zhGlossCount: Int
    public let engGlossCount: Int
    /// `entriesWithChinese / entryCount`（entryCount=0 时为 nil）。
    public var entryAlignmentRate: Double? {
        entryCount > 0
            ? Double(entriesWithChinese) / Double(entryCount)
            : nil
    }
    /// `sensesWithChinese / senseCount`（senseCount=0 时为 nil）。
    public var senseAlignmentRate: Double? {
        senseCount > 0
            ? Double(sensesWithChinese) / Double(senseCount)
            : nil
    }

    public init(
        entryCount: Int,
        entriesWithChinese: Int,
        senseCount: Int,
        sensesWithChinese: Int,
        zhGlossCount: Int,
        engGlossCount: Int
    ) {
        self.entryCount = entryCount
        self.entriesWithChinese = entriesWithChinese
        self.senseCount = senseCount
        self.sensesWithChinese = sensesWithChinese
        self.zhGlossCount = zhGlossCount
        self.engGlossCount = engGlossCount
    }
}

// MARK: - rejected 报告（消费侧审计）

/// 条目被拒进检索/释义链路的原因分类（按可归因性排列）。
/// 「被拒」= 产物中存在记录但该原因使条目无法被正常消费。
public enum DictionaryRejectionReason: String, Codable, Sendable, CaseIterable {
    /// 无任何 forms 行——written 通道永远命不中。
    case entryWithoutForms
    /// 无任何 readings 行——读音通道/消歧不可用。
    case entryWithoutReadings
    /// 无任何 senses 行——无释义无 POS。
    case entryWithoutSenses
    /// 有 sense 但全部 gloss 行数为 0——显示即「无释义」。
    case entryWithoutGlosses
    /// 全部 forms 的 normalized_text 为空——规范化通道不可检索。
    case unsearchableForms
    /// forms/readings/senses 引用了不存在的 entry_id（孤儿行）。
    case orphanedRows
}

/// 单类拒绝的计数 + 有界样本（报告样本上限见
/// `DictionaryQualityReport.sampleLimit`）。
public struct RejectedEntryClass: Equatable, Sendable, Codable {
    public let reason: DictionaryRejectionReason
    public let count: Int
    /// 样本 entry_id（孤儿行类为涉及的 entry_id），按 id 升序截断。
    public let sampleEntryIDs: [Int64]

    public init(
        reason: DictionaryRejectionReason,
        count: Int,
        sampleEntryIDs: [Int64]
    ) {
        self.reason = reason
        self.count = count
        self.sampleEntryIDs = sampleEntryIDs
    }
}

/// 词典产物审计报告：`metadata` 版本 + 中文覆盖 + rejected 分类。
/// Codable 以便导出与 QA 对比。
public struct DictionaryQualityReport: Equatable, Sendable, Codable {
    /// 每类拒绝原因的样本上限。
    public static let sampleLimit = 20

    public let datasetVersion: String
    public let dictionaryVersion: String
    public let chineseCoverage: ChineseCoverageStats
    /// 构建端声明口径（`dictionary_metadata` 原始值）。
    public let declaredZhEntriesAligned: Int?
    public let declaredZhAlignmentRate: Double?
    public let rejections: [RejectedEntryClass]
    /// 报告生成时的审计器版本（规则变更 bump）。
    public let auditVersion: String

    public init(
        datasetVersion: String,
        dictionaryVersion: String,
        chineseCoverage: ChineseCoverageStats,
        declaredZhEntriesAligned: Int?,
        declaredZhAlignmentRate: Double?,
        rejections: [RejectedEntryClass],
        auditVersion: String
    ) {
        self.datasetVersion = datasetVersion
        self.dictionaryVersion = dictionaryVersion
        self.chineseCoverage = chineseCoverage
        self.declaredZhEntriesAligned = declaredZhEntriesAligned
        self.declaredZhAlignmentRate = declaredZhAlignmentRate
        self.rejections = rejections
        self.auditVersion = auditVersion
    }

    /// 被拒 entry 总数（孤儿行类计行数）。
    public var totalRejected: Int {
        rejections.reduce(0) { $0 + $1.count }
    }
}

// MARK: - 版本/checksum 描述

/// 词典产物版本+文件校验的描述快照——`dictionary_artifact_records`
/// 表（v22）与运行时换库检测共用的事实模型。
public struct DictionaryArtifactDescriptor: Equatable, Sendable {
    /// 文件级 SHA-256（小写 hex，流式计算——与 `ReaderHashing` 同口径）。
    public let fileSHA256: String
    public let byteCount: Int64
    public let schemaVersion: String
    public let datasetVersion: String
    public let dictionaryVersion: String
    public let chineseLayerVersion: String?
    /// 构建端声明的 zh 对齐率。
    public let zhAlignmentRate: Double?

    public init(
        fileSHA256: String,
        byteCount: Int64,
        schemaVersion: String,
        datasetVersion: String,
        dictionaryVersion: String,
        chineseLayerVersion: String? = nil,
        zhAlignmentRate: Double? = nil
    ) {
        self.fileSHA256 = fileSHA256
        self.byteCount = byteCount
        self.schemaVersion = schemaVersion
        self.datasetVersion = datasetVersion
        self.dictionaryVersion = dictionaryVersion
        self.chineseLayerVersion = chineseLayerVersion
        self.zhAlignmentRate = zhAlignmentRate
    }

    /// 与另一描述是否同一数据版本（文件字节可因重打包变化，
    /// dataset_version 才是语义版本）。
    public func sameDataset(as other: DictionaryArtifactDescriptor) -> Bool {
        datasetVersion == other.datasetVersion
    }
}
