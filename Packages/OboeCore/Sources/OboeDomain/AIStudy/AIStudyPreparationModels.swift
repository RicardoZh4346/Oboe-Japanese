import Foundation

/// v0.7.5 S15——Reader「AI 准备学习内容」编排层的领域值类型。
///
/// 本文件只放**纯值类型与纯函数**：范围选择/预检报告/planner 冻结
/// 清单（manifest）/预览投影/选择策略/终态摘要。持久化与装配在
/// OboeInfrastructure（`AIStudyPreparationService`），SwiftUI 在
/// OboeApp（`ReaderAIStudySheet`）。
///
/// 关键不变量（对齐 contracts-frozen §4/§6/§9 与 decisions D10–D17）：
/// - `AIStudyJobManifest` 是 Job 的**唯一重建依据**：token 快照 +
///   词典候选快照 + 请求元数据全量冻结——重启/恢复时 replan 必须
///   产出逐字节相同的 requestHash，不依赖届时词典/系统状态。
/// - 确认前**不写任何业务数据**（Note/Card/membership 一律不动）；
///   允许的写只有证据链：token 缓存、occurrence 锚点、Job/manifest。
/// - 预览按 **unit 唯一身份** 聚合（`jmdict:sense-v1:` 键），物理
///   occurrence 只作计数/证据；计数分层互不重叠。
/// - JLPT 是**参考标签**：只经唯一 headword+reading 命中附级，
///   绝不用于构造词典身份（JMdict 非官方 JLPT 表）。

// MARK: - 版本常量（S15 编排层）

public enum AIStudyPreparation {
    /// `ai_study_jobs.pipeline_version`——S15 管线实现版本。
    public static let pipelineVersion = "ai-study-pipeline-v1"
    /// `ai_study_jobs.policy_version`——路由/确认策略族
    /// （阈值/上限/默认方向）。
    public static let policyVersion = "ai-study-policy-v1"
    /// manifest 载荷格式版本（解码端未知版本一律拒绝）。
    public static let manifestFormatVersion = 1
    /// 产品译出语（`AIStudyRequestMetadata.language`）。
    public static let targetLanguage = "zho"
}

// MARK: - 范围选择（预检 UI 层）

/// 用户可选的分析范围（预检页展示用；`AIStudyScope` 是冻结序列化形）。
public enum AIStudyScopeChoice: String, CaseIterable, Codable, Sendable {
    /// 当前段/短文本（当前可见块）。
    case currentText
    /// 当前章。
    case currentChapter
    /// 尚未产出 occurrence 证据的章节（当前 contentRevision 口径）。
    case unprocessedChapters
    /// 全书。
    case wholeBook

    public var displayName: String {
        switch self {
        case .currentText: "当前段"
        case .currentChapter: "当前章节"
        case .unprocessedChapters: "未处理章节"
        case .wholeBook: "全书"
        }
    }
}

/// 范围请求：choice + 定位参数（currentText 需 blockID，
/// currentChapter 需 chapterID）。
public struct AIStudyScopeRequest: Equatable, Sendable {
    public let choice: AIStudyScopeChoice
    /// `.currentChapter` 必填；其余忽略。
    public let chapterID: UUID?
    /// `.currentText` 必填；其余忽略。
    public let blockID: UUID?

    public init(
        choice: AIStudyScopeChoice,
        chapterID: UUID? = nil,
        blockID: UUID? = nil
    ) {
        self.choice = choice
        self.chapterID = chapterID
        self.blockID = blockID
    }
}

// MARK: - Provider 就绪态（预检报告组分）

/// AI 配置/凭据的就绪判定——预检只读配置，不触网络。
public struct AIStudyProviderReadiness: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        /// 配置完整（enabled + model + key 存在）→ 可派发。
        case ready
        /// 用户未启用 AI——可准备但不可派发（开始按钮禁用）。
        case disabled
        /// 未选择模型。
        case missingModel
        /// 缺 API Key。
        case missingKey
    }

    public let state: State
    /// 供报告回显的非敏感快照（enabled/model/serviceName）。
    public let isEnabled: Bool
    public let serviceName: String
    public let serviceKind: AIServiceKind
    public let modelID: String?
    /// `ResolvedAIConfiguration`——派发期使用；非就绪态为 nil。
    public let resolved: ResolvedAIConfiguration?

    public init(
        state: State,
        isEnabled: Bool,
        serviceName: String,
        serviceKind: AIServiceKind,
        modelID: String?,
        resolved: ResolvedAIConfiguration?
    ) {
        self.state = state
        self.isEnabled = isEnabled
        self.serviceName = serviceName
        self.serviceKind = serviceKind
        self.modelID = modelID
        self.resolved = resolved
    }

    public var isReady: Bool { state == .ready }
}

// MARK: - 预检报告

/// 预检问题集：`fatal` 成员出现时 `canStart == false`。
public enum AIStudyPrecheckIssue: Equatable, Hashable, Sendable {
    /// 文档不存在/不可用（missing/failed/processing）。
    case documentUnavailable
    /// 范围内没有任何正文块。
    case emptyScope
    /// 有块但目标 token 数为 0（全非词 token）。
    case noTargetTokens
    /// 形态分析服务装配缺席。
    case morphologyMissing
    /// 词典不可用/未安装。
    case dictionaryUnavailable
    /// 同 (document,contentRevision) 已有活跃 Job（部分唯一索引域）。
    case activeJobConflict(jobID: UUID, status: AIStudyJobStatus)
    /// AI 未启用。
    case providerDisabled
    /// 未选择模型。
    case providerMissingModel
    /// 缺 API Key。
    case providerMissingKey

    /// 是否阻断「开始准备」。
    public var isFatal: Bool {
        switch self {
        case .documentUnavailable, .emptyScope, .noTargetTokens,
             .morphologyMissing, .activeJobConflict:
            true
        case .dictionaryUnavailable, .providerDisabled,
             .providerMissingModel, .providerMissingKey:
            // 词典缺席仍可准备（OOV 照常）→ 降为提示；provider 问题
            // 在派发期会立刻暴露，但允许先创建 Job（离线排队语义——
            // 修好配置后 resume 续跑）。只有「准备」本身需要词典吗？
            // 不——candidates 为空不阻塞 manifest。故全部非 fatal。
            false
        }
    }
}

/// 一次预检的完整快照——UI 直渲染。
public struct AIStudyPrecheckReport: Equatable, Sendable {
    public let documentID: UUID
    public let documentTitle: String
    public let contentRevision: Int64
    public let request: AIStudyScopeRequest
    /// 估算（见 `AIStudyEstimate`——分「已缓存精确值」与「启发式上界」）。
    public let estimate: AIStudyEstimate
    public let provider: AIStudyProviderReadiness
    /// 同 revision 的既有 Job（非活跃终态也带回——UI 展示
    /// 「上次分析于…」入口可复用）。
    public let existingJob: AIStudyJob?
    /// 活跃 Job（isFatal 冲突成员）。
    public let activeJob: AIStudyJob?
    /// 其他 revision 的遗留活跃 Job（内容已漂移 → stale 提示）。
    public let staleJob: AIStudyJob?
    public let issues: [AIStudyPrecheckIssue]
    /// 非阻断提示（如「本章已全部处理过」「词典不可用将全 OOV」）。
    public let warnings: [String]

    public init(
        documentID: UUID,
        documentTitle: String,
        contentRevision: Int64,
        request: AIStudyScopeRequest,
        estimate: AIStudyEstimate,
        provider: AIStudyProviderReadiness,
        existingJob: AIStudyJob?,
        activeJob: AIStudyJob?,
        staleJob: AIStudyJob?,
        issues: [AIStudyPrecheckIssue],
        warnings: [String]
    ) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.contentRevision = contentRevision
        self.request = request
        self.estimate = estimate
        self.provider = provider
        self.existingJob = existingJob
        self.activeJob = activeJob
        self.staleJob = staleJob
        self.issues = issues
        self.warnings = warnings
    }

    /// 无 fatal 问题即可开始准备。
    public var canStart: Bool {
        !issues.contains(where: \.isFatal) && estimate.blockCount > 0
    }
}

/// 预检估算——token 级数字按 token-cache 命中率分精度：
/// `tokenEstimateIsExact == true` 时全部块命中缓存，
/// requestCount/uniqueUnits 是精确值；否则为启发式上界并如实标注。
public struct AIStudyEstimate: Equatable, Sendable {
    public let chapterCount: Int
    public let blockCount: Int
    /// 范围内 UTF-16 总长度。
    public let totalUTF16Length: Int
    /// 目标 token 数（coverage 口径：lexical+auxiliary+OOV）。
    public let targetTokenCount: Int
    /// 唯一学习单元数估算（按 lemma/读音/首候选 entry 去重）。
    public let uniqueUnitEstimate: Int
    /// 预计请求数（按 ≤40 occ/请求 与 48KiB 预算的粗略打包上界）。
    public let requestEstimate: Int
    /// token 计数来源：缓存命中块数 / 总块数。
    public let cachedTokenBlockCount: Int
    /// 全部块命中 token 缓存 → token 级数字精确。
    public var tokenEstimateIsExact: Bool {
        cachedTokenBlockCount == blockCount
    }
    /// 命中 `ai_study_cache` 的请求数上界（**同 requestHash** 才命中
    /// ——预检不运行 planner，只能给 0；真实命中数在分析期结算）。
    public let cachedRequestCount: Int

    public init(
        chapterCount: Int,
        blockCount: Int,
        totalUTF16Length: Int,
        targetTokenCount: Int,
        uniqueUnitEstimate: Int,
        requestEstimate: Int,
        cachedTokenBlockCount: Int,
        cachedRequestCount: Int = 0
    ) {
        self.chapterCount = chapterCount
        self.blockCount = blockCount
        self.totalUTF16Length = totalUTF16Length
        self.targetTokenCount = targetTokenCount
        self.uniqueUnitEstimate = uniqueUnitEstimate
        self.requestEstimate = requestEstimate
        self.cachedTokenBlockCount = cachedTokenBlockCount
        self.cachedRequestCount = cachedRequestCount
    }
}

// MARK: - 冻结清单（manifest，§9.1 确定性 replan 的唯一依据）

/// Job 冻结清单：planner 重建 `AIStudyPlannerInput` 所需的全部输入
/// 快照——token/候选 entry/原文/元数据，全部随 Job 持久化。
///
/// 恢复语义：Runner 每次 drive 都 `planner(job)` replan；清单在场
/// 即逐字节重建（新进程/词典更新/OS 升级都不影响已冻结请求）。
/// 清单缺席（备份恢复/异常）→ 该 Job 无法 replan——调用方按
/// `.missingSource` 语义拒绝续跑，不静默重算。
public struct AIStudyJobManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var jobID: UUID
    public var documentID: UUID
    public var contentRevision: Int64
    /// `ai_study_jobs.scope_json` 同值（冗余自持——清单独立可读）。
    public var scope: AIStudyScope
    /// 版本快照（= requestHash 环境组分）。
    public var parserVersion: String
    public var morphologyVersion: String
    public var osBuild: String
    public var dictionaryDatasetVersion: String
    /// token 缓存键折叠形态（`<parser>|<morph>|<osBuild>`）。
    public var tokenizerVersion: String
    /// 请求元数据（§4.4 全组分；planner 用它定稿 requestHash）。
    public var providerKind: String
    public var endpointFingerprint: String
    public var model: String
    public var responseMode: String
    public var promptVersion: String
    public var language: String
    public var generationParameters: [String: String]
    /// planner 构造参数（每 sense 英文 gloss 上限）。
    public var maxGlossesPerSense: Int
    /// 范围内的 Reader 块快照（planner 输入块序）。
    public var blocks: [Block]
    /// 本 Job 引用到的全部词典 entry 快照（id 排序；planner 的
    /// senseSource 从此取——候选内容冻结，不受词典后续更新影响）。
    public var dictionaryEntries: [Entry]

    public init(
        formatVersion: Int = AIStudyPreparation.manifestFormatVersion,
        jobID: UUID,
        documentID: UUID,
        contentRevision: Int64,
        scope: AIStudyScope,
        parserVersion: String,
        morphologyVersion: String,
        osBuild: String,
        dictionaryDatasetVersion: String,
        tokenizerVersion: String,
        providerKind: String,
        endpointFingerprint: String,
        model: String,
        responseMode: String,
        promptVersion: String,
        language: String,
        generationParameters: [String: String] = [:],
        maxGlossesPerSense: Int,
        blocks: [Block],
        dictionaryEntries: [Entry]
    ) {
        self.formatVersion = formatVersion
        self.jobID = jobID
        self.documentID = documentID
        self.contentRevision = contentRevision
        self.scope = scope
        self.parserVersion = parserVersion
        self.morphologyVersion = morphologyVersion
        self.osBuild = osBuild
        self.dictionaryDatasetVersion = dictionaryDatasetVersion
        self.tokenizerVersion = tokenizerVersion
        self.providerKind = providerKind
        self.endpointFingerprint = endpointFingerprint
        self.model = model
        self.responseMode = responseMode
        self.promptVersion = promptVersion
        self.language = language
        self.generationParameters = generationParameters
        self.maxGlossesPerSense = maxGlossesPerSense
        self.blocks = blocks
        self.dictionaryEntries = dictionaryEntries
    }

    /// 由清单重建 planner 元数据（requestHash 组分逐项还原）。
    public var requestMetadata: AIStudyRequestMetadata {
        AIStudyRequestMetadata(
            dictionaryDatasetVersion: dictionaryDatasetVersion,
            morphologyVersion: morphologyVersion,
            parserVersion: parserVersion,
            osBuild: osBuild,
            providerKind: providerKind,
            endpointFingerprint: endpointFingerprint,
            model: model,
            responseMode: responseMode,
            promptVersion: promptVersion,
            language: language,
            generationParameters: generationParameters
        )
    }

    // MARK: 块快照

    /// 一个 Reader 块的冻结输入：`scopeKey` + 原文 + token 快照 +
    /// 句界 + 上下文/定位锚。
    public struct Block: Codable, Equatable, Sendable {
        /// planner `scopeKey`——`doc:<id>:rev:<r>:ch:<co>:b:<bo>`。
        public var scopeKey: String
        /// `reader_blocks.id`（本机重链用；备份恢复后可能失配）。
        public var readerBlockID: UUID
        public var chapterID: UUID
        public var chapterOrdinal: Int
        public var blockOrdinal: Int
        /// `reader_blocks.text_hash`。
        public var sourceHash: String
        /// 原文全文（planner `sourceText`；token UTF-16 坐标系）。
        public var sourceText: String
        /// 相邻块上下文（planner `context`——可为空串）。
        public var context: String
        /// 句界 UTF-16 区间 `[start,end)` 扁平编码（成对）。
        public var sentenceRanges: [Int]
        /// 是否请求译文。
        public var wantsTranslation: Bool
        /// token 快照（`CachedReaderToken` 1:1 编码——与 token
        /// 缓存同一 Codable 形态，恢复不依赖缓存行存活）。
        public var tokens: [CachedReaderToken]

        public init(
            scopeKey: String,
            readerBlockID: UUID,
            chapterID: UUID,
            chapterOrdinal: Int,
            blockOrdinal: Int,
            sourceHash: String,
            sourceText: String,
            context: String,
            sentenceRanges: [Int],
            wantsTranslation: Bool,
            tokens: [CachedReaderToken]
        ) {
            self.scopeKey = scopeKey
            self.readerBlockID = readerBlockID
            self.chapterID = chapterID
            self.chapterOrdinal = chapterOrdinal
            self.blockOrdinal = blockOrdinal
            self.sourceHash = sourceHash
            self.sourceText = sourceText
            self.context = context
            self.sentenceRanges = sentenceRanges
            self.wantsTranslation = wantsTranslation
            self.tokens = tokens
        }

        /// 解码 token 快照（materialize 回 `ReaderToken`）。
        public var materializedTokens: [ReaderToken] {
            tokens.map { $0.materialize() }
        }

        /// 句界区间还原。
        public var materializedSentenceRanges: [Range<Int>] {
            var ranges: [Range<Int>] = []
            ranges.reserveCapacity(sentenceRanges.count / 2)
            var index = 0
            while index + 1 < sentenceRanges.count {
                let start = sentenceRanges[index]
                let end = sentenceRanges[index + 1]
                if start >= 0, end > start {
                    ranges.append(start..<end)
                }
                index += 2
            }
            return ranges
        }
    }

    // MARK: 词典 entry 快照（planner 候选详情的冻结副本）

    /// `DictionaryEntry` 的 Codable 投影——planner 只消费
    /// `primaryForm/readings/senses`（候选过滤 + matched 证据），
    /// 但全字段照录保持快照真实（预览/应用比对同源）。
    public struct Entry: Codable, Equatable, Sendable {
        public struct Form: Codable, Equatable, Sendable {
            public var id: Int64
            public var text: String
            public var formType: String
            public var priority: Int?
        }
        public struct Reading: Codable, Equatable, Sendable {
            public var id: Int64
            public var reading: String
            public var noKanji: Bool
            public var restrictedFormIDs: [Int64]
            public var restrictedForms: [String]
        }
        public struct Gloss: Codable, Equatable, Sendable {
            public var language: String
            public var text: String
            public var order: Int
            public var sourceID: String
            public var isMachineGenerated: Bool
            public var sourceFingerprint: String?
        }
        public struct SenseTag: Codable, Equatable, Sendable {
            public var category: String
            public var code: String
        }
        public struct Sense: Codable, Equatable, Sendable {
            public var id: Int64
            public var order: Int
            public var posCodes: [String]
            public var tags: [SenseTag]
            public var glosses: [Gloss]
            public var restrictedFormIDs: [Int64]
            public var restrictedForms: [String]
            public var restrictedReadingIDs: [Int64]
            public var restrictedReadings: [String]

            /// 还原 `DictionarySense`（unitKey 指纹/预览释义共用）。
            public func materialize() -> DictionarySense {
                DictionarySense(
                    id: id, order: order,
                    posCodes: posCodes,
                    tags: tags.map {
                        DictionarySenseTag(
                            category: $0.category, code: $0.code)
                    },
                    glosses: glosses.map {
                        DictionaryGloss(
                            language: $0.language, text: $0.text,
                            order: $0.order, sourceID: $0.sourceID,
                            isMachineGenerated: $0.isMachineGenerated,
                            sourceFingerprint: $0.sourceFingerprint)
                    },
                    restrictedFormIDs: restrictedFormIDs,
                    restrictedForms: restrictedForms,
                    restrictedReadingIDs: restrictedReadingIDs,
                    restrictedReadings: restrictedReadings
                )
            }
        }
        public struct OverlayGloss: Codable, Equatable, Sendable {
            public var language: String
            public var text: String
            public var sourceID: String
        }

        public var id: Int64
        public var primaryForm: String
        public var commonRank: Int?
        public var forms: [Form]
        public var readings: [Reading]
        public var senses: [Sense]
        public var overlayGlosses: [OverlayGloss]

        public init(entry: DictionaryEntry) {
            id = entry.id
            primaryForm = entry.primaryForm
            commonRank = entry.commonRank
            forms = entry.forms.map {
                Form(id: $0.id, text: $0.text,
                     formType: $0.formType, priority: $0.priority)
            }
            readings = entry.readings.map {
                Reading(id: $0.id, reading: $0.reading,
                        noKanji: $0.noKanji,
                        restrictedFormIDs: $0.restrictedFormIDs,
                        restrictedForms: $0.restrictedForms)
            }
            senses = entry.senses.map { sense in
                Sense(
                    id: sense.id, order: sense.order,
                    posCodes: sense.posCodes,
                    tags: sense.tags.map {
                        SenseTag(category: $0.category, code: $0.code)
                    },
                    glosses: sense.glosses.map {
                        Gloss(language: $0.language, text: $0.text,
                              order: $0.order, sourceID: $0.sourceID,
                              isMachineGenerated: $0.isMachineGenerated,
                              sourceFingerprint: $0.sourceFingerprint)
                    },
                    restrictedFormIDs: sense.restrictedFormIDs,
                    restrictedForms: sense.restrictedForms,
                    restrictedReadingIDs: sense.restrictedReadingIDs,
                    restrictedReadings: sense.restrictedReadings
                )
            }
            overlayGlosses = entry.overlayGlosses.map {
                OverlayGloss(language: $0.language, text: $0.text,
                             sourceID: $0.sourceID)
            }
        }

        /// 还原 `DictionaryEntry`（planner/预览共用）。
        public func materialize() -> DictionaryEntry {
            DictionaryEntry(
                id: id,
                primaryForm: primaryForm,
                commonRank: commonRank,
                forms: forms.map {
                    DictionaryForm(id: $0.id, text: $0.text,
                                   formType: $0.formType,
                                   priority: $0.priority)
                },
                readings: readings.map {
                    DictionaryReading(
                        id: $0.id, reading: $0.reading,
                        noKanji: $0.noKanji,
                        restrictedFormIDs: $0.restrictedFormIDs,
                        restrictedForms: $0.restrictedForms)
                },
                senses: senses.map { sense in
                    DictionarySense(
                        id: sense.id, order: sense.order,
                        posCodes: sense.posCodes,
                        tags: sense.tags.map {
                            DictionarySenseTag(
                                category: $0.category, code: $0.code)
                        },
                        glosses: sense.glosses.map {
                            DictionaryGloss(
                                language: $0.language, text: $0.text,
                                order: $0.order, sourceID: $0.sourceID,
                                isMachineGenerated: $0.isMachineGenerated,
                                sourceFingerprint: $0.sourceFingerprint)
                        },
                        restrictedFormIDs: sense.restrictedFormIDs,
                        restrictedForms: sense.restrictedForms,
                        restrictedReadingIDs: sense.restrictedReadingIDs,
                        restrictedReadings: sense.restrictedReadings
                    )
                },
                overlayGlosses: overlayGlosses.map {
                    DictionaryEntryOverlay(
                        language: $0.language, text: $0.text,
                        sourceID: $0.sourceID)
                }
            )
        }
    }

    // MARK: 编解码（BLOB 载荷——sortedKeys 稳定编码）

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> AIStudyJobManifest {
        let manifest = try JSONDecoder().decode(
            AIStudyJobManifest.self, from: data)
        guard manifest.formatVersion
                == AIStudyPreparation.manifestFormatVersion else {
            throw ManifestError.unsupportedFormat(
                manifest.formatVersion)
        }
        return manifest
    }

    public enum ManifestError: Error, Equatable, Sendable {
        case unsupportedFormat(Int)
    }
}

// MARK: - 句界估计（planner `sentenceRanges` 输入）

/// 确定性句界探测——`AIStudyPlannerInput.sentenceRanges` 的供给。
/// 规则：UTF-16 扫描，`。！？!?` 与换行后切分；覆盖全文不留缺口
/// （末段无终止符也成句）。不引入启发式 NLP——同输入恒同输出。
public enum AIStudySentenceSegments {
    /// 句终字符集（UTF-16 code unit 判定，含全角/半角与换行）。
    private static func isTerminator(_ unit: UTF16.CodeUnit) -> Bool {
        switch unit {
        case 0x3002, 0xFF01, 0xFF1F,  // 。！？
             0x0021, 0x003F,          // ! ?
             0x000A, 0x000D,          // \n \r
             0x2026:                 // …（省略显式成句，避免整段粘连）
            return true
        default:
            return false
        }
    }

    /// 返回覆盖 `text` 全文的不重叠句界区间（UTF-16 坐标）。
    /// 空文本返回空数组；终止符后跟同类字符归入同一句。
    public static func ranges(of text: String) -> [Range<Int>] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < units.count {
            if isTerminator(units[index]) {
                // 连续终止符合并（如「？！」「……」\r\n）。
                var end = index + 1
                while end < units.count, isTerminator(units[end]) {
                    end += 1
                }
                ranges.append(start..<end)
                start = end
                index = end
            } else {
                index += 1
            }
        }
        if start < units.count {
            ranges.append(start..<units.count)
        }
        return ranges
    }
}

// MARK: - 输入指纹（§9.1 重建判定键）

/// `ai_study_jobs.input_fingerprint`：scope + 内容 + 版本 + provider
/// 的 canonical SHA-256——同输入同指纹（重建判定），任一漂移即换
/// 指纹（不串 Job）。计算走 `AIStudyCanonicalJSON`（模块内共享）。
public enum AIStudyInputFingerprint {
    public static func compute(
        documentID: UUID,
        contentRevision: Int64,
        scopeHash: String,
        blockHashes: [String],
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
        policyVersion: String
    ) -> String {
        AIStudyCanonicalJSON.sha256Hex(of: .object([
            ("blockHashes", .array(
                blockHashes.map { .string($0) })),
            ("contentRevision", .integer(contentRevision)),
            ("dictionaryDatasetVersion",
             .string(dictionaryDatasetVersion)),
            ("documentID",
             .string(documentID.uuidString.lowercased())),
            ("endpointFingerprint", .string(endpointFingerprint)),
            ("language", .string(language)),
            ("model", .string(model)),
            ("morphologyVersion", .string(morphologyVersion)),
            ("osBuild", .string(osBuild)),
            ("parserVersion", .string(parserVersion)),
            ("policyVersion", .string(policyVersion)),
            ("promptVersion", .string(promptVersion)),
            ("providerKind", .string(providerKind)),
            ("responseMode", .string(responseMode)),
            ("scopeHash", .string(scopeHash)),
        ]))
    }
}

// MARK: - 预览投影（S15 §5.2：unit 唯一身份聚合）

/// 预览行——一个**唯一学习单元**（`jmdict:sense-v1:` 键），聚合
/// 其全部 occurrence；决策字段可变（UI 内编辑），确认时冻结为
/// immutable selection 行。
public struct AIStudyPreviewItem: Equatable, Identifiable, Sendable {
    /// unit 身份键（= selection.unitKey）。
    public let unitKey: String
    public let entryID: Int64
    public let senseID: Int64
    /// 词条级合并义项集：同 entry 的全部合法义项并入一张卡的
    /// `senseIDs` 载荷（真机反馈裁决：一词条一卡）。空集 = 仅
    /// `senseID` 代表义项（旧路径兼容）。`unitKey` 恒锚合并集中
    /// 词典序最小的义项。
    public var mergedSenseIDs: [Int64]
    /// 词典快照的词目（`entry.primaryForm`）。
    public let headword: String
    public let reading: String?
    /// 首选语言释义摘要（zh→en 回退）。
    public let glossSummary: String?
    /// JLPT 参考级（唯一 headword+reading 命中才赋值；参考标签）。
    public var jlptLevel: JLPTLevel?
    /// 本 unit 在范围内的 occurrence 数（解析行计数）。
    public var occurrenceCount: Int
    /// 首次出现的原句（块内句界切片）。
    public var firstSentence: String?
    /// 首次出现的块定位（章节/块序）。
    public var firstLocator: String?
    /// 锚定证据 revision（同 unit 的 resolution revision 最大值）。
    public var evidenceRevision: Int64
    /// 置信度区间（同 unit 解析行 min/max）。
    public var confidenceRange: ClosedRange<Double>?
    /// 含低置信 occurrence。
    public var containsLowConfidence: Bool
    /// 既有 unit（identity_key 命中 `lexical_learning_units`）。
    public var existingUnitID: UUID?
    /// 既有 unit 的 tooEasy flag。
    public var unitIsTooEasy: Bool
    /// 既有 unit 已关联的 vocabulary Note（复用候选，可能多个）。
    public var linkedNotes: [LinkedNote]
    /// 同 headword 的未关联 vocabulary Note（复用候选）。
    public var duplicateNotes: [LinkedNote]
    /// 当前决策（nil = 未决定——确认时不会产生 selection 行）。
    public var decision: AISelectionDecision?
    /// 决策的参数化动作载荷（reuse/create 必填；确认时冻结）。
    public var proposedAction: AIStudyProposedAction?

    public var id: String { unitKey }

    /// 复用 Note 摘要。
    public struct LinkedNote: Equatable, Identifiable, Sendable {
        public let noteID: UUID
        public let headword: String
        public let reading: String?
        public let deckID: UUID
        public var id: UUID { noteID }

        public init(
            noteID: UUID,
            headword: String,
            reading: String?,
            deckID: UUID
        ) {
            self.noteID = noteID
            self.headword = headword
            self.reading = reading
            self.deckID = deckID
        }
    }

    public init(
        unitKey: String,
        entryID: Int64,
        senseID: Int64,
        mergedSenseIDs: [Int64] = [],
        headword: String,
        reading: String?,
        glossSummary: String?,
        jlptLevel: JLPTLevel?,
        occurrenceCount: Int,
        firstSentence: String?,
        firstLocator: String?,
        evidenceRevision: Int64,
        confidenceRange: ClosedRange<Double>?,
        containsLowConfidence: Bool,
        existingUnitID: UUID?,
        unitIsTooEasy: Bool,
        linkedNotes: [LinkedNote],
        duplicateNotes: [LinkedNote],
        decision: AISelectionDecision?,
        proposedAction: AIStudyProposedAction?
    ) {
        self.unitKey = unitKey
        self.entryID = entryID
        self.senseID = senseID
        self.mergedSenseIDs = mergedSenseIDs
        self.headword = headword
        self.reading = reading
        self.glossSummary = glossSummary
        self.jlptLevel = jlptLevel
        self.occurrenceCount = occurrenceCount
        self.firstSentence = firstSentence
        self.firstLocator = firstLocator
        self.evidenceRevision = evidenceRevision
        self.confidenceRange = confidenceRange
        self.containsLowConfidence = containsLowConfidence
        self.existingUnitID = existingUnitID
        self.unitIsTooEasy = unitIsTooEasy
        self.linkedNotes = linkedNotes
        self.duplicateNotes = duplicateNotes
        self.decision = decision
        self.proposedAction = proposedAction
    }

    /// VoiceOver 标签：身份 + 状态全量（无障碍标签必须可区分 unit）。
    public var accessibilityLabelText: String {
        var parts = [headword]
        if let reading { parts.append(reading) }
        if let jlptLevel { parts.append(jlptLevel.rawValue) }
        parts.append("出现 \(occurrenceCount) 次")
        if let unitID = existingUnitID {
            parts.append(
                "已有学习单元 \(String(unitID.uuidString.prefix(8)))")
        }
        if unitIsTooEasy { parts.append("已标记太简单") }
        return parts.joined(separator: "，")
    }
}

/// 待确认 occurrence——低置信/未解析/被拒的 token 级行（不进
/// unit 聚合：无可靠身份可聚合）。
public struct AIStudyPreviewPendingItem: Equatable, Identifiable, Sendable {
    /// 稳定 id：`requestHash|tokenKey`。
    public var id: String { "\(requestHash)|\(tokenKey)" }
    /// 最新 resolution 行 id——改判落库时 occurrence
    /// `resolution_id` 链接的换指依据。
    public let resolutionID: UUID?
    public let requestHash: String
    public let tokenKey: String
    public let surface: String
    public let reading: String?
    /// 原文句（所在块句界切片）。
    public let sentence: String?
    public let status: AIStudyResolutionStatus
    public let reasonCode: AIStudyReasonCode?
    public let confidence: Double?
    /// 可供改判的候选（低置信修正入口的选项集）。
    public let alternatives: [Alternative]
    /// AI 的首选（低置信行 = validator 合法但被阈值路由的选择）——
    /// 行内显示「AI 建议：xxx」+ 一键采纳入口；unresolved/缺选定
    /// 行为 nil。采纳写 `correctedSelection`，走同一改判落库路径。
    public let aiSuggested: Alternative?
    /// 用户改判结果（nil = 未处理，应用期保持未解析）。
    public var correctedSelection: AIStudySelection?

    public struct Alternative: Equatable, Sendable {
        public let entryID: Int64
        public let senseID: Int64
        public let lemma: String
        public let glossSummary: String?

        public init(
            entryID: Int64,
            senseID: Int64,
            lemma: String,
            glossSummary: String?
        ) {
            self.entryID = entryID
            self.senseID = senseID
            self.lemma = lemma
            self.glossSummary = glossSummary
        }
    }

    public init(
        resolutionID: UUID? = nil,
        requestHash: String,
        tokenKey: String,
        surface: String,
        reading: String?,
        sentence: String?,
        status: AIStudyResolutionStatus,
        reasonCode: AIStudyReasonCode?,
        confidence: Double?,
        alternatives: [Alternative],
        aiSuggested: Alternative? = nil,
        correctedSelection: AIStudySelection? = nil
    ) {
        self.resolutionID = resolutionID
        self.requestHash = requestHash
        self.tokenKey = tokenKey
        self.surface = surface
        self.reading = reading
        self.sentence = sentence
        self.status = status
        self.reasonCode = reasonCode
        self.confidence = confidence
        self.alternatives = alternatives
        self.aiSuggested = aiSuggested
        self.correctedSelection = correctedSelection
    }
}

/// 预览快照——互不重叠计数：resolved 唯一单元数 / 待确认
/// occurrence 数 / 失败块数 分列，绝不混算。
public struct AIStudyPreview: Sendable {
    public let jobID: UUID
    public let documentID: UUID
    public let contentRevision: Int64
    /// 快照锚：生成时刻的 Job epoch（确认时复核——变了即 stale）。
    public let jobEpoch: Int64
    public let jobStatus: AIStudyJobStatus
    /// 范围/证据锚（确认前 refresh 比对用）。
    public let scopeHash: String
    public var items: [AIStudyPreviewItem]
    public var pending: [AIStudyPreviewPendingItem]
    public let totalBlockCount: Int
    public let resolvedBlockCount: Int
    public let failedBlockCount: Int
    public let cancelledBlockCount: Int
    /// 翻译成功块数（translation_status == done）。
    public let translatedBlockCount: Int
    public let generatedAtMs: Int64

    public init(
        jobID: UUID,
        documentID: UUID,
        contentRevision: Int64,
        jobEpoch: Int64,
        jobStatus: AIStudyJobStatus,
        scopeHash: String,
        items: [AIStudyPreviewItem],
        pending: [AIStudyPreviewPendingItem],
        totalBlockCount: Int,
        resolvedBlockCount: Int,
        failedBlockCount: Int,
        cancelledBlockCount: Int,
        translatedBlockCount: Int,
        generatedAtMs: Int64
    ) {
        self.jobID = jobID
        self.documentID = documentID
        self.contentRevision = contentRevision
        self.jobEpoch = jobEpoch
        self.jobStatus = jobStatus
        self.scopeHash = scopeHash
        self.items = items
        self.pending = pending
        self.totalBlockCount = totalBlockCount
        self.resolvedBlockCount = resolvedBlockCount
        self.failedBlockCount = failedBlockCount
        self.cancelledBlockCount = cancelledBlockCount
        self.translatedBlockCount = translatedBlockCount
        self.generatedAtMs = generatedAtMs
    }
}

// MARK: - 选择策略（§5.3 冻结集）

/// 批量选择策略：只改 `decision`/`proposedAction`，不动证据字段。
/// 全部纯函数——同预览同策略同结果。
public enum AIStudySelectionStrategy: Equatable, Sendable {
    /// 推荐：高置信（无低置信混入）且未标 tooEasy 的 unit → 学习。
    /// 含低置信行/已有 tooEasy flag/已有 Note 关联的项不进推荐——
    /// 分别留待人工或默认复用。
    case recommended
    /// 全部：所有可学 unit（含混低置信的——用户显式全选才带它们）。
    case all
    /// JLPT 参考级集合：按 jlptLevel ∈ levels 过滤后同 recommended。
    case jlpt(Set<JLPTLevel>)
    /// 新内容上限：只让前 `limit` 个「将新建」的 unit 进 create，
    /// 其余落 skip（既有 unit 的 reuse 不占新名额——D17 语义：
    /// 限制的是新增学习负担，不是关联已有材料）。
    case newItemsLimit(Int)

    /// 应用策略：改 `items` 的就地决策。`studyDeckID` 是 reuse 的
    /// membership 目标（文章绑定牌组）；`directions` 为 create 快照。
    public func apply(
        to items: inout [AIStudyPreviewItem],
        studyDeckID: UUID?,
        directions: Set<VocabularyCardDirection>
    ) {
        // 先归位：非跳过类决策清空重算（策略重复应用幂等）。
        var createBudget: Int?
        if case .newItemsLimit(let limit) = self {
            createBudget = max(0, limit)
        }
        for index in items.indices {
            var item = items[index]
            guard isEligible(item, for: self) else {
                // 不在策略覆盖集 → 不改动既有决策（不静默跳过）。
                items[index] = item
                continue
            }
            // 默认动作：有 linked Note 建议复用首张，否则 create；
            // tooEasy 项永不自动 create。
            if item.unitIsTooEasy {
                item.decision = .tooEasy
                item.proposedAction = .setTooEasy
            } else if let reusable = item.linkedNotes.first {
                item.decision = .reuse
                item.proposedAction = .reuseNote(
                    noteID: reusable.noteID,
                    addMembershipTo: studyDeckID)
            } else {
                if var budget = createBudget {
                    guard budget > 0 else {
                        item.decision = .skip
                        item.proposedAction = .recordSkip
                        items[index] = item
                        continue
                    }
                    budget -= 1
                    createBudget = budget
                }
                item.decision = .create
                item.proposedAction = .createNote(
                    directions: directions,
                    senseIDs: item.mergedSenseIDs)
            }
            items[index] = item
        }
    }

    /// 策略覆盖判定。
    private func isEligible(
        _ item: AIStudyPreviewItem,
        for strategy: AIStudySelectionStrategy
    ) -> Bool {
        switch strategy {
        case .recommended:
            // 含低置信 occurrence 的 unit 不进自动推荐（§5.3）。
            return !item.containsLowConfidence
        case .all:
            return true
        case .jlpt(let levels):
            return item.jlptLevel.map { levels.contains($0) } ?? false
        case .newItemsLimit:
            return !item.containsLowConfidence
        }
    }
}

// MARK: - JLPT 参考索引（唯一命中才附级，D07）

/// JLPT 参考级查找表：`(normalize(headword), normalize(reading))`
/// → level；同键多个不同 level 视为歧义——**不附级**（宁缺勿滥）。
///
/// 这是**参考标签**用途：preview 行展示与 `jlpt` 策略过滤；
/// 绝不进 unitKey/语义指纹——词典身份以 JMdict 快照为唯一事实源。
public struct AIStudyJLPTReferenceIndex: Sendable {
    public struct Row: Sendable {
        public let headword: String
        public let reading: String
        public let level: JLPTLevel

        public init(headword: String, reading: String, level: JLPTLevel) {
            self.headword = headword
            self.reading = reading
            self.level = level
        }
    }

    private let levels: [String: JLPTLevel]

    public init(rows: [Row]) {
        var seen: [String: JLPTLevel] = [:]
        var ambiguous = Set<String>()
        for row in rows {
            let key = Self.key(headword: row.headword, reading: row.reading)
            if let existing = seen[key], existing != row.level {
                ambiguous.insert(key)
            } else {
                seen[key] = row.level
            }
        }
        for key in ambiguous { seen.removeValue(forKey: key) }
        levels = seen
    }

    /// 归一化规则与 `SearchTextNormalizer` 同族（trim+小写+NFKC）；
    /// reading 额外折半角→全角前统一片假名（JMdict/词库两侧
    /// 表记系不同源，matching 必须同口径）。
    public static func normalized(_ text: String) -> String {
        SearchTextNormalizer.normalize(text)
    }

    private static func key(headword: String, reading: String) -> String {
        normalized(headword) + "\u{1F}" + normalized(reading)
    }

    /// 唯一命中才返回 level；歧义键 init 时已剔除。
    public func level(headword: String, reading: String?) -> JLPTLevel? {
        levels[Self.key(
            headword: headword, reading: reading ?? headword)]
    }

    public var isEmpty: Bool { levels.isEmpty }
}

// MARK: - occurrence 位置键（S22 着色直查）

/// `reader_study_occurrences` 行的定位键——Reader 着色把 token
/// 位置直接映到已绑 unit 的 occurrence（绕开 lexeme 解析链：
/// 多候选 token 没有 lexicalKey、lexeme 缺行时词卡建成仍不
/// 变色——真机反馈「制卡完成词仍橙色」的直查通道）。
///
/// 四元组全等才命中：章序 + 块序 + 块内 UTF-16 起点 + 长度。
/// blockOrdinal 是**章内**序数——跨章同序块靠 chapterOrdinal
/// 区分，缺它会错贴状态。
public struct ReaderOccurrencePosition: Hashable, Sendable {
    public let chapterOrdinal: Int
    public let blockOrdinal: Int
    public let startUTF16: Int
    public let lengthUTF16: Int

    public init(
        chapterOrdinal: Int,
        blockOrdinal: Int,
        startUTF16: Int,
        lengthUTF16: Int
    ) {
        self.chapterOrdinal = chapterOrdinal
        self.blockOrdinal = blockOrdinal
        self.startUTF16 = startUTF16
        self.lengthUTF16 = lengthUTF16
    }
}

// MARK: - 终态摘要（S15 §9：互不重叠计数 + 入口载荷）

/// 应用完成后的摘要——计数**互斥分桶**（每 unit 恰落一桶），
/// 卡片数单列（created 才会 >0）。
public struct AIStudyJobSummary: Equatable, Sendable {
    public let jobID: UUID
    public let status: AIStudyJobStatus
    /// 文章绑定牌组（summary「开始学习/查看牌组」目标）。
    public let studyDeckID: UUID?
    public let deckName: String?

    /// 新建 Note 数（含降级复用计数单列——见 `degradedToReuse`）。
    public let createdNoteCount: Int
    /// 复用既有 Note 数。
    public let reusedNoteCount: Int
    /// create 降级为复用（unit 已有 primary Note）——单列不混算。
    public let degradedToReuseCount: Int
    /// 置 tooEasy 数。
    public let tooEasyCount: Int
    /// 显式跳过数（recordSkip 结算）。
    public let skippedCount: Int
    /// 预览存在但未产生本批 selection 的 unit 数。
    public let unselectedCount: Int
    /// 应用失败的 unit 数（receipt 带 errorCode）。
    public let failedUnitCount: Int
    /// 待确认 occurrence 数（低置信+未解析未改判）。
    public let unresolvedCount: Int
    /// 实际新建卡片总数（directions 展开后的真实行数）。
    public let createdCardCount: Int
    /// 译文成功块数。
    public let translatedBlockCount: Int
    /// 总块数 / 已解析块数 / 失败块数。
    public let totalBlockCount: Int
    public let resolvedBlockCount: Int
    public let failedBlockCount: Int

    public init(
        jobID: UUID,
        status: AIStudyJobStatus,
        studyDeckID: UUID?,
        deckName: String?,
        createdNoteCount: Int,
        reusedNoteCount: Int,
        degradedToReuseCount: Int,
        tooEasyCount: Int,
        skippedCount: Int,
        unselectedCount: Int,
        failedUnitCount: Int,
        unresolvedCount: Int,
        createdCardCount: Int,
        translatedBlockCount: Int,
        totalBlockCount: Int,
        resolvedBlockCount: Int,
        failedBlockCount: Int
    ) {
        self.jobID = jobID
        self.status = status
        self.studyDeckID = studyDeckID
        self.deckName = deckName
        self.createdNoteCount = createdNoteCount
        self.reusedNoteCount = reusedNoteCount
        self.degradedToReuseCount = degradedToReuseCount
        self.tooEasyCount = tooEasyCount
        self.skippedCount = skippedCount
        self.unselectedCount = unselectedCount
        self.failedUnitCount = failedUnitCount
        self.unresolvedCount = unresolvedCount
        self.createdCardCount = createdCardCount
        self.translatedBlockCount = translatedBlockCount
        self.totalBlockCount = totalBlockCount
        self.resolvedBlockCount = resolvedBlockCount
        self.failedBlockCount = failedBlockCount
    }
}
