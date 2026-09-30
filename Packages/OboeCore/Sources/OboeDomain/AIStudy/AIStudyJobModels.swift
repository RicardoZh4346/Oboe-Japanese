import Foundation

/// v0.7.5 S11（前置·角色 E）：AI Study Job / block / selection /
/// resolution / receipt 的领域模型与状态机。
///
/// 依据：contracts-frozen rev2 §4.1（Job/Block 状态机）、§4.2（Selection）、
/// §4.3（Receipt/actionKey/幂等三层）、§6 v25 表冻结清单；
/// 技术文档 §4（schema 草案）、§9（状态机/恢复协议/取消语义）、
/// §11（ApplyStudySelectionCommand 字段全集）；decisions D10（幂等边界）、
/// D11（awaitingConfirmation/paused）。
///
/// 复用（不重定义，`AIStudyContracts.swift`）：
/// `AIStudyLexicalStatus` / `AIStudyTranslationStatus`（双层子状态枚举）、
/// `AIStudyResolutionStatus` / `AIStudyResolutionOrigin` / `AIStudyReasonCode` /
/// `AIStudyResolution` / `AIStudySelection`（词典义项选定值类型）。
///
/// 纯领域层：不写表（v25 schema 由 M 统一注册）、不接 Runner/网络/仓储、
/// 不 import GRDB。模型字段与 §6 v25 冻结列 1:1 对应（见各类型注释），
/// 供后续 schema / Runner / 应用事务定型。
///
/// # 状态机唯一实现点
///
/// `AIStudyJobStateMachine` 是 §4.1 转移表的**唯一**编码处：
/// Runner/仓储/测试一律经 `canTransition`/`transition` 判定，不得另写
/// 私有转移表。取消语义（§9.2）：任意非终态 → cancelled，转移时
/// `epoch + 1` 使在途结果持久化/应用前的事务内核对失效；
/// 已提交内容保留（cancelled ≠ 全局 rollback），`canResume` 恒 false。

// MARK: - Job 状态 / 恢复原因（§4.1、D11）

/// `ai_study_jobs.status` 十态（§4.1 冻结集、D11）。
public enum AIStudyJobStatus: String, Codable, CaseIterable, Sendable {
    /// 已创建未开工（预检 manifest 完成）。
    case pending
    /// 本地分析/候选生成/请求拆分阶段。
    case analyzing
    /// 有块已派发或待派发，等待 AI 结果/重试。
    case waitingForAI
    /// 预览/确认阶段——用户决策中，非等待网络（D11）。
    case awaitingConfirmation
    /// 已确认选择的应用事务进行中。
    case applying
    /// 暂停（后台/手动/缺 Key/缺原文/内容过期），按持久化阶段续跑。
    case paused
    /// 终态：范围内全部块处理完、全部选定项应用成功、无待确认/待重试。
    case completed
    /// 非终态：部分结果可用但仍有失败或未完成应用（可续跑三去向）。
    case partiallyCompleted
    /// 终态：取消——已提交保留、未提交回滚、epoch+1。
    case cancelled
    /// 终态：不可恢复系统错误。
    case failed
}

/// `ai_study_jobs.resume_reason`（§4.1 冻结集）。
/// 列可空：NULL ≡ `.none`（持久层映射时两者等价）。
public enum AIStudyResumeReason: String, Codable, CaseIterable, Sendable {
    /// 无恢复原因（非 paused，或从未暂停）。
    case none
    /// 缺 API Key/凭据——修好可续。
    case missingKey
    /// 缺原文（文档被删/不可用）。
    case missingSource
    /// 内容 revision 过期——旧 Job stale，不自动继续旧选择（§5）。
    case contentStale
    /// 进后台尽力保存 checkpoint 后暂停（§9.2）。
    case backgroundPause
    /// 用户手动暂停。
    case manualPause
}

// MARK: - 范围（§6.1：全文/章节集/当前段）

/// `ai_study_jobs.scope_json` 内单个原文区间（当前段/自定义范围）。
/// UTF-16 坐标与 `AIStudyBlock.targetUTF16*`、`ReaderToken` 同一约定。
public struct AIStudyScopeRange: Codable, Equatable, Sendable {
    /// 可选定位键（章节/块 locator 规范 key）；纯坐标范围可为 nil。
    public let locatorKey: String?
    public let startUTF16: Int
    public let lengthUTF16: Int

    public init(locatorKey: String? = nil, startUTF16: Int, lengthUTF16: Int) {
        self.locatorKey = locatorKey
        self.startUTF16 = startUTF16
        self.lengthUTF16 = lengthUTF16
    }
}

/// Job 冻结范围（§6.1 范围预检）。`scope_json` 持久化为 JSON；
/// `scopeHash` 是稳定指纹（coverage/重建判定用）。
///
/// 编码稳定性：`chapters`/`blockRanges` 视为**集合**——
/// 序列化与 scopeHash 统一排序去重，同集合不同输入序编码等价。
public enum AIStudyScope: Equatable, Sendable {
    /// 全文（短文章默认，§6.1）。
    case fullDocument
    /// 章节集（EPUB 默认当前章节；元素为章节 locator 规范 key）。
    case chapters([String])
    /// 显式 UTF-16 区间集（长 TXT/字幕当前段，或预览缩圈后的范围）。
    case blockRanges([AIStudyScopeRange])
}

extension AIStudyScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, chapterKeys, ranges
    }
    private enum Kind: String, Codable {
        case fullDocument, chapters, blockRanges
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .fullDocument:
            self = .fullDocument
        case .chapters:
            // 集合语义：解码同样规范化（排序去重），读回值恒为规范形。
            let keys = try container.decode([String].self, forKey: .chapterKeys)
            self = .chapters(Array(Set(keys)).sorted())
        case .blockRanges:
            let ranges = try container.decode([AIStudyScopeRange].self, forKey: .ranges)
            self = .blockRanges(AIStudyScope.sortedRanges(ranges))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullDocument:
            try container.encode(Kind.fullDocument, forKey: .kind)
        case .chapters(let keys):
            try container.encode(Kind.chapters, forKey: .kind)
            // 集合语义：排序去重保证 scope_json 编码稳定。
            try container.encode(Array(Set(keys)).sorted(), forKey: .chapterKeys)
        case .blockRanges(let ranges):
            try container.encode(Kind.blockRanges, forKey: .kind)
            try container.encode(AIStudyScope.sortedRanges(ranges), forKey: .ranges)
        }
    }
}

extension AIStudyScope {
    /// 规范化排序（start, length, locatorKey）——集合语义编码锚点。
    static func sortedRanges(_ ranges: [AIStudyScopeRange]) -> [AIStudyScopeRange] {
        ranges.sorted { lhs, rhs in
            if lhs.startUTF16 != rhs.startUTF16 { return lhs.startUTF16 < rhs.startUTF16 }
            if lhs.lengthUTF16 != rhs.lengthUTF16 { return lhs.lengthUTF16 < rhs.lengthUTF16 }
            return (lhs.locatorKey ?? "") < (rhs.locatorKey ?? "")
        }
    }

    /// 规范 key 集：fullDocument → 空集；chapters → 排序去重 key 集；
    /// blockRanges → 规范化区间列表（locatorKey|start|length 文本化）。
    /// 供 `scopeHash` 与 coverage scope 比对共用。
    public var canonicalElements: [String] {
        switch self {
        case .fullDocument:
            return []
        case .chapters(let keys):
            return Array(Set(keys)).sorted().map { "c:\($0)" }
        case .blockRanges(let ranges):
            return AIStudyScope.sortedRanges(ranges).map {
                "r:\($0.startUTF16)-\($0.lengthUTF16):\($0.locatorKey ?? "")"
            }
        }
    }

    /// `SHA-256(canonical JSON)`——范围敏感：章节集/区间任一分量不同
    /// 即换 hash；同范围任意输入序同 hash。`"fullDocument"` 仍产生
    /// 非空稳定 hash（不作特例空串，避免与空集章节歧义）。
    public var scopeHash: String {
        let kindString: String
        switch self {
        case .fullDocument: kindString = "fullDocument"
        case .chapters: kindString = "chapters"
        case .blockRanges: kindString = "blockRanges"
        }
        return AIStudyCanonicalJSON.sha256Hex(of: .object([
            ("elements", .array(canonicalElements.map { .string($0) })),
            ("kind", .string(kindString)),
        ]))
    }
}

// MARK: - Provider 快照（§6 v25 provider_snapshot_json；wire §2.1）

/// `provider_snapshot_json`——非敏感执行配置快照。
///
/// **类型层面不含任何秘密**：不声明 Key/token/凭据字段，也不声明
/// endpoint（endpoint 指纹属于 requestHash 环境组分
/// `AIStudyRequestMetadata.endpointFingerprint`，经
/// `AIStudyEndpointFingerprint.normalize` 规范化后由请求侧携带；
/// Job 快照不重复持有——同 model 不同服务端不得串缓存靠请求键，
/// 不靠 Job 快照）。备份 v9 导出本 JSON 时因此天然安全。
public struct AIStudyProviderSnapshot: Codable, Equatable, Sendable {
    /// 供应商族（`AIServiceKind.rawValue` 或协议标识，如 "anthropic"）。
    public let providerKind: String
    /// 模型串（与 `ai_study_jobs.model` 列同步冗余——列供查询，快照供审计）。
    public let model: String
    /// `AIResponseFormatMode.rawValue`（promptedJSON/structured 等）。
    public let responseMode: String
    public let promptVersion: String
    /// 路由/确认策略版本（阈值/数量上限等本地策略族）。
    public let policyVersion: String

    public init(
        providerKind: String,
        model: String,
        responseMode: String,
        promptVersion: String,
        policyVersion: String
    ) {
        self.providerKind = providerKind
        self.model = model
        self.responseMode = responseMode
        self.promptVersion = promptVersion
        self.policyVersion = policyVersion
    }
}

// MARK: - ai_study_jobs（§6 v25 行投影）

/// `ai_study_jobs` 行投影。同一 `document_id + content_revision` 至多
/// 一个**活跃** Job（非终态；部分唯一索引由 M 的 v25 schema 落地，
/// 领域侧语义见 `AIStudyJobStateMachine.isActive`）。
///
/// 计数字段为**可重算摘要非真相**（§9「分开计数」+ §4「count 为可重算
/// 摘要」）：Runner 增量维护供进度展示，对账/恢复以 block 行为准
/// 重算；v9 备份白名单不含计数列，恢复后按块重算。
public struct AIStudyJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: UUID
    /// 文章绑定牌组（deck SET NULL；首次「准备」即创建，取消保留空牌组 D14）。
    public var studyDeckID: UUID?
    /// `scope_json` 冻结范围。
    public var scope: AIStudyScope
    /// 输入指纹（scope+内容+版本组合的重建判定键）。
    public var inputFingerprint: String
    public var contentRevision: Int64
    /// `provider_snapshot_json`——见 `AIStudyProviderSnapshot` 秘密约束。
    public var providerSnapshot: AIStudyProviderSnapshot
    public var model: String
    public var pipelineVersion: String
    public var promptVersion: String
    public var policyVersion: String
    public var status: AIStudyJobStatus
    /// 取消/重装配世代：每次取消 +1；结果持久化与应用事务内核对（§9.2）。
    public var epoch: Int64
    /// 最新已确认 `ai_study_selections` revision（单调递增，§4.2）。
    public var selectionRevision: Int64
    /// NULL ≡ `.none`。
    public var resumeReason: AIStudyResumeReason?
    public var createdAtMs: Int64
    public var updatedAtMs: Int64

    // MARK: 计数投影（可重算摘要，非真相）

    /// 已结束本轮请求处理的块数（§9：处理完本轮，不等于成功）。
    public var processedBlocks: Int
    /// 已应用 unit 数。
    public var appliedUnits: Int
    /// 已确认 unit 数。
    public var confirmedUnits: Int
    /// 失败块数（UI 与 partiallyCompleted 判定展示用）。
    public var failedBlocks: Int

    public init(
        id: UUID,
        documentID: UUID,
        studyDeckID: UUID? = nil,
        scope: AIStudyScope,
        inputFingerprint: String,
        contentRevision: Int64,
        providerSnapshot: AIStudyProviderSnapshot,
        model: String,
        pipelineVersion: String,
        promptVersion: String,
        policyVersion: String,
        status: AIStudyJobStatus = .pending,
        epoch: Int64 = 0,
        selectionRevision: Int64 = 0,
        resumeReason: AIStudyResumeReason? = nil,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        processedBlocks: Int = 0,
        appliedUnits: Int = 0,
        confirmedUnits: Int = 0,
        failedBlocks: Int = 0
    ) {
        self.id = id
        self.documentID = documentID
        self.studyDeckID = studyDeckID
        self.scope = scope
        self.inputFingerprint = inputFingerprint
        self.contentRevision = contentRevision
        self.providerSnapshot = providerSnapshot
        self.model = model
        self.pipelineVersion = pipelineVersion
        self.promptVersion = promptVersion
        self.policyVersion = policyVersion
        self.status = status
        self.epoch = epoch
        self.selectionRevision = selectionRevision
        self.resumeReason = resumeReason
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.processedBlocks = processedBlocks
        self.appliedUnits = appliedUnits
        self.confirmedUnits = confirmedUnits
        self.failedBlocks = failedBlocks
    }

    /// 非终态 = 活跃（部分唯一索引「同 document/revision 至多一活跃」
    /// 的领域判据）。
    public var isActive: Bool { AIStudyJobStateMachine.isActive(self) }
}

// MARK: - 文档级进度投影（S22 库行展示）

/// 文档级活跃 Job 进度——Reader 库行/文档入口的「分析进行中」
/// 展示投影（S22 真机反馈：退出分析页后要能在文章行直接看到
/// 进度）。全部字段来自持久化计数（`refreshJobCounters` 同事务
/// 维护），不依赖 Runner 在内存态——后台续跑/重进接管进度一致。
public struct AIStudyJobProgress: Equatable, Sendable {
    public let jobID: UUID
    public let documentID: UUID
    public let status: AIStudyJobStatus
    /// 已结束本轮请求处理的块数（含 resolved/applied/failed）。
    public let processedBlocks: Int
    public let failedBlocks: Int
    /// Job 已落库的块行总数（分母）。
    public let totalBlocks: Int
    /// 已确认 unit 数（待应用/已应用的确认进度）。
    public let confirmedUnits: Int
    public let appliedUnits: Int

    public init(
        jobID: UUID,
        documentID: UUID,
        status: AIStudyJobStatus,
        processedBlocks: Int,
        failedBlocks: Int,
        totalBlocks: Int,
        confirmedUnits: Int,
        appliedUnits: Int
    ) {
        self.jobID = jobID
        self.documentID = documentID
        self.status = status
        self.processedBlocks = processedBlocks
        self.failedBlocks = failedBlocks
        self.totalBlocks = totalBlocks
        self.confirmedUnits = confirmedUnits
        self.appliedUnits = appliedUnits
    }

    /// 0…1 派发进度（totalBlocks=0 时为 0——块行未落库前不
    /// 显示满格）。
    public var fraction: Double {
        guard totalBlocks > 0 else { return 0 }
        return Double(processedBlocks) / Double(totalBlocks)
    }
}

// MARK: - Block 状态（§4.1 十一态）

/// `ai_study_job_blocks.status`（§4.1 冻结集）。
/// 词义/翻译的**结果**子状态独立存 `lexicalStatus`/`translationStatus`
/// （复用 §3.3 枚举）——不用单一 completed 布尔掩盖半成功。
public enum AIStudyBlockStatus: String, Codable, CaseIterable, Sendable {
    /// 待本地分析。
    case pending
    /// 本地分析/候选生成中。
    case analyzing
    /// 请求定稿（requestHash/候选快照已提交），待派发。
    case readyForAI
    /// 网络在途（lease 持有中；resultID 可能在崩溃前已落库）。
    case requesting
    /// 校验通过、结果已持久化（resultID 非空），待路由确认/应用。
    case resolved
    /// 待用户确认（低置信/歧义）。
    case awaitingConfirmation
    /// 应用事务进行中（receipt replay 保护）。
    case applying
    /// 终态：应用完成。
    case applied
    /// 可重试失败，等 `nextRetryAtMs` 到期重排队（§9.2 退避）。
    case retryScheduled
    /// 失败（非终态——显式「重试失败块」可转 analyzing/readyForAI；
    /// 不自动重试，见 `AIStudyJobStateMachine`）。
    case failed
    /// 终态：随 Job 取消/范围缩圈丢弃。已提交结果行不陪葬。
    case cancelled
}

/// `ai_study_job_blocks` 行投影 + 持久化 outcome 的双层子状态投影。
///
/// `locator_json`/`source_hash` 是重链锚（block_id 弱引用语义 D12：
/// 不强引 reader_blocks）；`subblock_key` = planner 的
/// `AIStudyBlock.blockKey`（`<scopeKey>#r<start>-<end>`），
/// UNIQUE(job_id, subblock_key)。
///
/// `leaseEpoch` 为本机运行态租借世代——**不入备份**（wire §2.1）；
/// `resultID` 弱引用已校验结果（本机 staging/cache）。
/// `lexicalStatus`/`translationStatus` 非独立列语义：是 resultID 所指
/// 持久化 outcome 的字段投影（领域聚合视图携带，M 建表时可落冗余列
/// 或从 result 读取，二者编码一致）。
public struct AIStudyJobBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobID: UUID
    /// 规范 locator JSON（重链/排序锚）。
    public var locatorJSON: String
    /// 目标文本 hash（只覆盖目标文本；上下文/候选归 requestHash）。
    public var sourceHash: String
    /// = `AIStudyBlock.blockKey`；UNIQUE(job_id, subblock_key)。
    public var subblockKey: String
    /// 实际发送候选集 hash（§4.4 组分）。
    public var candidateSetHash: String
    /// §4.4 requestHash——请求复用/缓存键；派发前必须落库（§9.1.1）。
    public var requestHash: String
    public var status: AIStudyBlockStatus
    /// 已派发尝试次数（每次 →requesting +1；退避上限判定用，§9.2）。
    public var attemptCount: Int
    /// retryScheduled 的重试到期时刻（更长 Retry-After 持久化，不 busy loop）。
    public var nextRetryAtMs: Int64?
    /// 运行态租借世代——本机列，不导出。
    public var leaseEpoch: Int64?
    /// 已持久化校验结果弱引用（requesting 崩溃恢复：非空 → 不重发）。
    public var resultID: UUID?
    /// 失败归因码（provider/validator/系统错误归类，供 UI/审计）。
    public var lastErrorCode: String?

    // MARK: 双层结果子状态（§3.3/§4.1：词义与翻译独立）

    /// 词义子状态（`AIStudyLexicalStatus`，源自持久化 outcome）。
    public var lexicalStatus: AIStudyLexicalStatus?
    /// 翻译子状态（`AIStudyTranslationStatus`，源自持久化 outcome）。
    public var translationStatus: AIStudyTranslationStatus?

    public init(
        id: UUID,
        jobID: UUID,
        locatorJSON: String,
        sourceHash: String,
        subblockKey: String,
        candidateSetHash: String,
        requestHash: String,
        status: AIStudyBlockStatus = .pending,
        attemptCount: Int = 0,
        nextRetryAtMs: Int64? = nil,
        leaseEpoch: Int64? = nil,
        resultID: UUID? = nil,
        lastErrorCode: String? = nil,
        lexicalStatus: AIStudyLexicalStatus? = nil,
        translationStatus: AIStudyTranslationStatus? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.locatorJSON = locatorJSON
        self.sourceHash = sourceHash
        self.subblockKey = subblockKey
        self.candidateSetHash = candidateSetHash
        self.requestHash = requestHash
        self.status = status
        self.attemptCount = attemptCount
        self.nextRetryAtMs = nextRetryAtMs
        self.leaseEpoch = leaseEpoch
        self.resultID = resultID
        self.lastErrorCode = lastErrorCode
        self.lexicalStatus = lexicalStatus
        self.translationStatus = translationStatus
    }
}

// MARK: - ai_study_selections（§4.2）

/// `ai_study_selections.decision`（§4.2 冻结集）。
public enum AISelectionDecision: String, Codable, CaseIterable, Sendable {
    /// 复用既有 unit/Note（确认时重读当前数据重算，防撞竞态盲写）。
    case reuse
    /// 新建 unit/Note/Card。
    case create
    /// 用户明确跳过——不算失败（§9 completed 语义）。
    case skip
    /// 标 tooEasy。
    case tooEasy
    /// 待决定（预览期占位）。
    case pending
}

/// `ai_study_selections.proposed_action`——确认时预览给出的动作载荷
/// （持久化 JSON）。与 `decision` 分列：decision 是用户可见结论，
/// proposedAction 是应用事务要执行的参数化动作。
///
/// 编码为 `kind` 判别对象，`createNote.directions` 按 rawValue 排序——
/// Set 迭代序不稳定，排序后 `proposed_action` 列 JSON 编码稳定
/// （payload 比对/备份 round-trip 不吃随机序）。
public enum AIStudyProposedAction: Equatable, Sendable {
    /// 复用 primary Note；可选向文章绑定牌组追加 membership
    /// （复用不改原 home/FSRS，§11.4）。
    case reuseNote(noteID: UUID, addMembershipTo: UUID?)
    /// 新建 vocabulary Note + 卡：方向快照（§11.5：沿用实际用户
    /// 设置——仓库无全局方向偏好时复用三方向默认，D17）。
    /// `senseIDs`：词条级合并义项集——文中读音确定后该 entry 的
    /// 全部合法义项并入同一张卡的释义（真机反馈裁决：不再一义项
    /// 一卡）。空集 = 仅 unitKey 锚定的代表义项（旧数据/旧流程）。
    case createNote(
        directions: Set<VocabularyCardDirection>,
        senseIDs: [Int64] = [])
    /// 置 tooEasy（有无 Note 均允许，§2.2）。
    case setTooEasy
    /// 显式跳过——仅落 receipt 锚，不写学习数据。
    case recordSkip
    /// 待决定占位。
    case pending
}

extension AIStudyProposedAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, noteID, addMembershipTo, directions, senseIDs
    }
    private enum Kind: String, Codable {
        case reuseNote, createNote, setTooEasy, recordSkip, pending
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .reuseNote:
            self = .reuseNote(
                noteID: try container.decode(UUID.self, forKey: .noteID),
                addMembershipTo: try container.decodeIfPresent(
                    UUID.self, forKey: .addMembershipTo))
        case .createNote:
            let raw = try container.decode([String].self, forKey: .directions)
            var directions = Set<VocabularyCardDirection>()
            for value in raw {
                guard let direction = VocabularyCardDirection(rawValue: value) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .directions, in: container,
                        debugDescription: "未知方向 \(value)")
                }
                directions.insert(direction)
            }
            // senseIDs 缺省 = 空集（旧 revision 行/旧版本写入的载荷
            // 语义不变——仅 unitKey 锚定的代表义项）。
            self = .createNote(
                directions: directions,
                senseIDs: try container.decodeIfPresent(
                    [Int64].self, forKey: .senseIDs) ?? [])
        case .setTooEasy:
            self = .setTooEasy
        case .recordSkip:
            self = .recordSkip
        case .pending:
            self = .pending
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reuseNote(let noteID, let addMembershipTo):
            try container.encode(Kind.reuseNote, forKey: .kind)
            try container.encode(noteID, forKey: .noteID)
            try container.encodeIfPresent(addMembershipTo, forKey: .addMembershipTo)
        case .createNote(let directions, let senseIDs):
            try container.encode(Kind.createNote, forKey: .kind)
            try container.encode(
                directions.map(\.rawValue).sorted(), forKey: .directions)
            // 空集不写键——编码形态与旧版本逐字节一致（receipt/
            // 备份的 payload 比对不吃字段新增）。
            if !senseIDs.isEmpty {
                try container.encode(
                    senseIDs.sorted(), forKey: .senseIDs)
            }
        case .setTooEasy:
            try container.encode(Kind.setTooEasy, forKey: .kind)
        case .recordSkip:
            try container.encode(Kind.recordSkip, forKey: .kind)
        case .pending:
            try container.encode(Kind.pending, forKey: .kind)
        }
    }
}

/// `ai_study_selections` 行投影：PK(job_id, selection_revision, unit_key)。
///
/// 确认即持久化 **immutable revision**——分批应用/崩溃恢复不丢选择
/// （§4.2）；`evidenceRevision` 记录选择所锚定的解析证据版本，
/// `appliedReceiptID` 回填应用事务的 receipt（弱引用）。
///
/// 命名说明：契约 `AIStudySelection`（§3.3 词典义项选定）已存在，
/// 本行投影故名 `AIStudyJobSelection` 避免重定义。
public struct AIStudyJobSelection: Codable, Equatable, Sendable {
    public var jobID: UUID
    /// 选择锚定的 unit 键（identity key 或预览期稳定占位键）。
    public var unitKey: String
    /// 单调递增的不可变 revision（同 job 内确认批次序号）。
    public var selectionRevision: Int64
    public var decision: AISelectionDecision
    public var proposedAction: AIStudyProposedAction?
    /// 选择锚定的解析证据版本（resolution/分析 revision）。
    public var evidenceRevision: Int64
    /// 应用完成后回填的 receipt（弱引用——receipt 独立 Job 留史）。
    public var appliedReceiptID: UUID?

    public init(
        jobID: UUID,
        unitKey: String,
        selectionRevision: Int64,
        decision: AISelectionDecision,
        proposedAction: AIStudyProposedAction? = nil,
        evidenceRevision: Int64,
        appliedReceiptID: UUID? = nil
    ) {
        self.jobID = jobID
        self.unitKey = unitKey
        self.selectionRevision = selectionRevision
        self.decision = decision
        self.proposedAction = proposedAction
        self.evidenceRevision = evidenceRevision
        self.appliedReceiptID = appliedReceiptID
    }
}

// MARK: - 应用命令（§11 ApplyStudySelectionCommand 字段全集）

/// `ApplyStudySelectionCommand`——§11 字段全集的不可变命令值类型。
///
/// 事务语义（仓储层执行，§11 一次 unit 应用事务）：
/// 复核 generation / Job status+epoch / 文档 revision / 选择 revision；
/// 命中同 payload receipt → 返回历史结果；同 operationID 异 payload →
/// 拒绝（§4.3 幂等第三层）。
public struct AIStudyApplyCommand: Equatable, Sendable {
    public let jobID: UUID
    /// 应用所锚定的 immutable selection revision。
    public let selectionRevision: Int64
    /// 幂等键：应用计划落库时生成并持久化，不每次启动重随机（§8.2）。
    public let operationID: UUID
    /// 负载 hash——receipt replay 比对（同 ID 异 payload 拒绝）。
    public let payloadHash: String
    /// 容器世代 CAS（RestorationWorkGate 世代；restore 后在途命令失效）。
    public let expectedGeneration: Int64
    /// 复核 `ai_study_jobs.epoch`——取消后旧命令不得落库。
    public let jobEpoch: Int64
    /// 复核 `ai_study_jobs.content_revision`（内容过期拒绝盲写）。
    public let documentRevision: Int64
    /// 应用的 unit 锚（= selection.unit_key）。
    public let unitKey: String
    /// 复核 resolution 当前 revision；无 AI resolution 锚（如纯 local
    /// reuse）可为 nil。
    public let resolutionRevision: Int64?
    /// 目标牌组（文章绑定 deck）。
    public let targetDeckID: UUID
    /// 方向快照——预览期用户选择的实际方向集（D17）。
    public let directions: Set<VocabularyCardDirection>

    public init(
        jobID: UUID,
        selectionRevision: Int64,
        operationID: UUID,
        payloadHash: String,
        expectedGeneration: Int64,
        jobEpoch: Int64,
        documentRevision: Int64,
        unitKey: String,
        resolutionRevision: Int64? = nil,
        targetDeckID: UUID,
        directions: Set<VocabularyCardDirection>
    ) {
        self.jobID = jobID
        self.selectionRevision = selectionRevision
        self.operationID = operationID
        self.payloadHash = payloadHash
        self.expectedGeneration = expectedGeneration
        self.jobEpoch = jobEpoch
        self.documentRevision = documentRevision
        self.unitKey = unitKey
        self.resolutionRevision = resolutionRevision
        self.targetDeckID = targetDeckID
        self.directions = directions
    }

    /// 命令锚点与 Job 当前值一致性（§11.1 复核的纯函数部分：
    /// jobID/selectionRevision/epoch/documentRevision）。
    /// `expectedGeneration` 属容器层，不在本函数职责。
    public func anchorsMatch(_ job: AIStudyJob) -> Bool {
        jobID == job.id
            && selectionRevision == job.selectionRevision
            && jobEpoch == job.epoch
            && documentRevision == job.contentRevision
    }
}

// MARK: - actionKey / Receipt（§4.3 幂等第三层）

/// `action_key` 的动作类型分量（§4.3 actionType）。
/// 与 `AISelectionDecision` 分列：decision 是用户选择语义，
/// actionType 是 receipt 锚定的**写动作**类别。
public enum AIStudyActionType: String, Codable, CaseIterable, Sendable {
    /// 新建 vocabulary Note + 卡 + membership + 来源。
    case createNote
    /// 复用 primary Note + membership/来源 dedup。
    case reuseNote
    /// 置 tooEasy（经共享 tooEasy 写路径）。
    case setTooEasy
    /// 显式跳过的幂等锚（不写学习数据，replay 返回历史结果）。
    case recordSkip
}

/// `action_key` 的重建意图分量（§4.3 rebuildIntent）。
public enum AIStudyRebuildIntent: String, Codable, CaseIterable, Sendable {
    /// 常规应用/重放。
    case none
    /// 用户删除新建 Note/移出牌组后的**显式**重建/重新加入——
    /// 与常规 actionKey 分键，使旧 receipt replay 只返回历史结果、
    /// 不顶替「当前仍存在」的证据（§5 生命周期、§8.2）。
    case explicitRebuild
}

/// `ai_study_receipts.action_key` 的稳定编码（§4.3：
/// `f(documentID, contentRevision, unitKey, selectionRevision,
///   actionType, rebuildIntent)`）。
///
/// `canonicalKey` = `"aisk1:" + SHA-256(canonical JSON)`——
/// 前缀版本化；同输入任意进程同 key，异输入不同 key
/// （unitKey 任意字符不构成注入：整组分量进 hash）。
public struct AIStudyActionKey: Equatable, Sendable {
    /// 编码格式版本（算法变更须 bump 并迁移认知）。
    public static let formatVersion = "aisk1"

    public let documentID: UUID
    public let contentRevision: Int64
    public let unitKey: String
    public let selectionRevision: Int64
    public let actionType: AIStudyActionType
    public let rebuildIntent: AIStudyRebuildIntent

    public init(
        documentID: UUID,
        contentRevision: Int64,
        unitKey: String,
        selectionRevision: Int64,
        actionType: AIStudyActionType,
        rebuildIntent: AIStudyRebuildIntent = .none
    ) {
        self.documentID = documentID
        self.contentRevision = contentRevision
        self.unitKey = unitKey
        self.selectionRevision = selectionRevision
        self.actionType = actionType
        self.rebuildIntent = rebuildIntent
    }

    /// 稳定 canonical key 字符串（`action_key` 列值）。
    public var canonicalKey: String {
        let json = AIStudyCanonicalJSON.Value.object([
            ("actionType", .string(actionType.rawValue)),
            ("contentRevision", .integer(contentRevision)),
            ("documentID", .string(documentID.uuidString.lowercased())),
            ("rebuildIntent", .string(rebuildIntent.rawValue)),
            ("selectionRevision", .integer(selectionRevision)),
            ("unitKey", .string(unitKey)),
        ])
        return "\(AIStudyActionKey.formatVersion):"
            + AIStudyCanonicalJSON.sha256Hex(of: json)
    }
}

/// `ai_study_receipts` 行投影（§4.3）：独立于 Job 保留的效果凭据。
/// `outcomeJSON` 内的结果 ID 是弱引用——允许用户事后删除数据，
/// receipt 只证明「当时提交过」，不证明「当前仍存在」（§5）。
public struct AIStudyReceipt: Codable, Equatable, Sendable {
    /// PK——应用计划落库时生成并持久化（§8.2：不重随机）。
    public let operationID: UUID
    /// UNIQUE——`AIStudyActionKey.canonicalKey`。
    public let actionKey: String
    /// 同 ID 比对：同 payload → replay 历史结果；异 payload → 拒绝。
    public let payloadHash: String
    /// 有界结果快照（含弱引用结果 ID）。
    public let outcomeJSON: String
    public let committedAtMs: Int64

    public init(
        operationID: UUID,
        actionKey: String,
        payloadHash: String,
        outcomeJSON: String,
        committedAtMs: Int64
    ) {
        self.operationID = operationID
        self.actionKey = actionKey
        self.payloadHash = payloadHash
        self.outcomeJSON = outcomeJSON
        self.committedAtMs = committedAtMs
    }
}

// MARK: - ai_study_resolutions（§6 v25 行投影）

/// `ai_study_resolutions` 行投影——`(request_hash, token_key, revision)`
/// 唯一的词义处置记录（§6 v25 + §3.3 resolutions[] 落库形态）。
///
/// `jobID`/`jobBlockID`/`documentID`/`unitID` 全部弱引用可 SET NULL
/// （留史审计，不随业务对象删除陪葬）；`selected*` 三分量
/// （entry/sense/datasetVersion）对应 §3.3 `selected{...}`。
///
/// 命名说明：契约 `AIStudyResolution`（§3.3 单 token 处置值类型）
/// 已存在；本类型是**行**投影，名 `AIStudyResolutionRecord`
/// （对齐 `LearningUnitEventRecord` 命名法）。
public struct AIStudyResolutionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let jobID: UUID?
    public let jobBlockID: UUID?
    public let documentID: UUID?
    /// 规范 locator JSON（无原文重链/审计锚）。
    public let locatorJSON: String
    /// 持久化 token 键（= 请求内 tokenID 的稳定映射）。
    public let tokenKey: String
    /// 产生本结果的请求 hash（弱引用缓存/staging）。
    public let requestHash: String
    public let selectedEntryID: Int64?
    public let selectedSenseID: Int64?
    /// 选择所针对的词典快照版本——跨快照不可直接比对（§1.2）。
    public let selectedDatasetVersion: String?
    /// 应用后回填的 unit（弱引用 SET NULL）。
    public let unitID: UUID?
    /// 应答 confidence（低置信行保留原值供展示）。
    public let confidence: Double?
    public let status: AIStudyResolutionStatus
    public let reasonCode: AIStudyReasonCode?
    public let origin: AIStudyResolutionOrigin
    /// 结果 revision——同 (requestHash,tokenKey) 内单调递增，
    /// 重新分析/修正产生新 revision 不覆盖历史。
    public let revision: Int64
    public let createdAtMs: Int64
    /// v28：token 所在句的 AI 译文（schema v2 `sentenceTranslation`）。
    /// 与选义子状态独立——unresolved/低置信行同样可携带；制卡时
    /// 写入词汇卡 `exampleTranslationZH`。
    public let sentenceTranslation: String?

    public init(
        id: UUID,
        jobID: UUID? = nil,
        jobBlockID: UUID? = nil,
        documentID: UUID? = nil,
        locatorJSON: String,
        tokenKey: String,
        requestHash: String,
        selectedEntryID: Int64? = nil,
        selectedSenseID: Int64? = nil,
        selectedDatasetVersion: String? = nil,
        unitID: UUID? = nil,
        confidence: Double? = nil,
        status: AIStudyResolutionStatus,
        reasonCode: AIStudyReasonCode? = nil,
        origin: AIStudyResolutionOrigin,
        revision: Int64,
        createdAtMs: Int64,
        sentenceTranslation: String? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.jobBlockID = jobBlockID
        self.documentID = documentID
        self.locatorJSON = locatorJSON
        self.tokenKey = tokenKey
        self.requestHash = requestHash
        self.selectedEntryID = selectedEntryID
        self.selectedSenseID = selectedSenseID
        self.selectedDatasetVersion = selectedDatasetVersion
        self.unitID = unitID
        self.confidence = confidence
        self.status = status
        self.reasonCode = reasonCode
        self.origin = origin
        self.revision = revision
        self.createdAtMs = createdAtMs
        self.sentenceTranslation = sentenceTranslation
    }

    /// 领域投影：行 → §3.3 `AIStudyResolution` 值类型。
    /// `selected` 仅当 entry/sense/datasetVersion 三分量齐全才重建。
    public var resolution: AIStudyResolution {
        let selection: AIStudySelection?
        if let entryID = selectedEntryID,
           let senseID = selectedSenseID,
           let datasetVersion = selectedDatasetVersion {
            selection = AIStudySelection(
                entryID: entryID,
                senseID: senseID,
                datasetVersion: datasetVersion
            )
        } else {
            selection = nil
        }
        return AIStudyResolution(
            tokenKey: tokenKey,
            selected: selection,
            confidence: confidence,
            status: status,
            reasonCode: reasonCode,
            origin: origin,
            sentenceTranslation: sentenceTranslation
        )
    }
}

// MARK: - 状态机（§4.1 转移表唯一实现点、§9 恢复/取消语义）

/// Job/Block 非法转移错误。
public enum AIStudyJobTransitionError: Error, Equatable, Sendable {
    case illegalJobTransition(from: AIStudyJobStatus, to: AIStudyJobStatus)
    case illegalBlockTransition(from: AIStudyBlockStatus, to: AIStudyBlockStatus)
}

/// `AIStudyJobStateMachine.transition(block:)` 的转移上下文——
/// 转移伴随的持久化字段写入（§9.1 checkpoint 语义）。
/// 全部可选：只携带本次转移需要落值的字段。
public struct AIStudyBlockTransitionContext: Equatable, Sendable {
    /// →requesting：本次派发的运行 lease（崩溃回收到期依据）。
    public var leaseEpoch: Int64?
    /// →retryScheduled：退避到期时刻（含较长 Retry-After 持久化）。
    public var nextRetryAtMs: Int64?
    /// 结果持久化后回填（→resolved 或 requesting 崩溃前已存结果的回补）。
    public var resultID: UUID?
    /// →retryScheduled/failed 的归因码。
    public var lastErrorCode: String?
    /// →resolved：词义子状态落值。
    public var lexicalStatus: AIStudyLexicalStatus?
    /// →resolved：翻译子状态落值。
    public var translationStatus: AIStudyTranslationStatus?
    /// →requesting：置 true 则 attemptCount+1（§9.1.1 派发前提交 attempt）。
    public var incrementAttemptCount: Bool

    public init(
        leaseEpoch: Int64? = nil,
        nextRetryAtMs: Int64? = nil,
        resultID: UUID? = nil,
        lastErrorCode: String? = nil,
        lexicalStatus: AIStudyLexicalStatus? = nil,
        translationStatus: AIStudyTranslationStatus? = nil,
        incrementAttemptCount: Bool = false
    ) {
        self.leaseEpoch = leaseEpoch
        self.nextRetryAtMs = nextRetryAtMs
        self.resultID = resultID
        self.lastErrorCode = lastErrorCode
        self.lexicalStatus = lexicalStatus
        self.translationStatus = translationStatus
        self.incrementAttemptCount = incrementAttemptCount
    }
}

/// 恢复协议（§9.1）输出的**块级**处置——纯函数唯一实现点。
/// Runner 崩溃重启/暂停续跑时按块 checkpoint 分类，不按整篇游标猜
/// （§9.1.6）。
public enum AIStudyBlockResumeAction: Equatable, Sendable {
    /// 已提交完成（applied）→ 幂等跳过：不重发、不重应用（D10 已保存
    /// 结果绝不重发）。
    case skip
    /// 进行中但 resultID 已持久化（requesting/readyForAI 崩溃窗口）→
    /// 用已存结果推进，**绝不重回网络**（D10）。
    case usePersistedResult
    /// 请求定稿可发送，或 requesting 无持久化结果的未知窗口 →
    /// 允许（重）发送（D10：服务端成功未落库的窗口可能再计费，
    /// 本地不承诺远端 exactly-once）。
    case dispatchRequest
    /// retryScheduled 未到期 → 等待至指定时刻，不 busy loop（§9.2）。
    case waitForRetry(untilMs: Int64)
    /// pending/analyzing → 重做本地分析（无网络历史，安全重算）。
    case analyze
    /// awaitingConfirmation → 结果已持久化，回确认阶段。
    case presentForConfirmation
    /// applying → 继续应用事务（receipt replay 防重复写，§9.1.5）。
    case resumeApply
    /// failed → 不自动重试，等显式「重试失败块」动作
    /// （failed→analyzing/readyForAI 转移）。
    case needsExplicitRetry
    /// cancelled → 不恢复。
    case dropped
}

/// `resumeTarget` 的输出——paused/crash-recycle 后 Job 级续跑入口
/// （§4.1「paused→analyzing 按持久化阶段续跑」+ §9.1 恢复协议）。
/// Job 状态机只允许 paused→analyzing；本枚举告诉 Runner 续跑后
/// 哪类工作在前，块级细节由 `AIStudyBlockResumeAction` 驱动。
public enum AIStudyResumeTarget: Equatable, Sendable {
    /// 有块需本地分析/派发/等重试/消费已存结果 → 回 analyzing 续跑。
    case analyze
    /// 无网络/分析遗留，但有待确认结果 → 直奔确认阶段。
    case awaitConfirmation
    /// 仅余已确认选择的应用 → 回应用阶段。
    case apply
    /// 全部块终态/无可恢复工作。
    case finished
}

/// §4.1 状态机唯一实现点（纯函数、无 IO、无时间源——时间以参数传入）。
public enum AIStudyJobStateMachine {

    // MARK: 终态集

    /// Job 终态：completed / cancelled / failed。
    /// `partiallyCompleted` **非**终态——§4.1 有三条出边（续跑语义）。
    public static let terminalJobStates: Set<AIStudyJobStatus> = [
        .completed, .cancelled, .failed,
    ]

    /// Block 终态：applied / cancelled。
    /// `failed` 非终态——显式重试可走 failed→analyzing/readyForAI。
    public static let terminalBlockStates: Set<AIStudyBlockStatus> = [
        .applied, .cancelled,
    ]

    // MARK: §4.1 Job 转移表（唯一编码处）

    /// 逐行编码 §4.1 Job 转移表 + 「任意非终态→cancelled/failed」：
    /// ```text
    /// pending→analyzing；analyzing→waitingForAI；
    /// waitingForAI→awaitingConfirmation；awaitingConfirmation→applying；
    /// applying→completed|partiallyCompleted；
    /// waitingForAI→partiallyCompleted；
    /// partiallyCompleted→waitingForAI|awaitingConfirmation|applying；
    /// analyzing|waitingForAI|applying→paused；paused→analyzing；
    /// 任意非终态→cancelled；不可恢复系统错误→failed。
    /// ```
    private static let jobEdges: [AIStudyJobStatus: Set<AIStudyJobStatus>] = [
        .pending: [.analyzing, .cancelled, .failed],
        .analyzing: [.waitingForAI, .paused, .cancelled, .failed],
        .waitingForAI: [
            .awaitingConfirmation, .partiallyCompleted, .paused,
            .cancelled, .failed,
        ],
        .awaitingConfirmation: [.applying, .cancelled, .failed],
        .applying: [.completed, .partiallyCompleted, .paused, .cancelled, .failed],
        .paused: [.analyzing, .cancelled, .failed],
        .partiallyCompleted: [
            .waitingForAI, .awaitingConfirmation, .applying,
            .cancelled, .failed,
        ],
        .completed: [],
        .cancelled: [],
        .failed: [],
    ]

    // MARK: Block 转移表（§4.1 状态集 + §9 流程推导的唯一编码处）

    /// ```text
    /// pending→analyzing→readyForAI→requesting→resolved
    /// requesting→retryScheduled(可重试失败) | failed(不可重试)
    /// retryScheduled→readyForAI(到期重排队)
    /// resolved→awaitingConfirmation | applying(自动应用)
    /// awaitingConfirmation→applying；applying→applied | failed
    /// failed→analyzing|readyForAI(显式「重试失败块」，§9 partiallyCompleted)
    /// 任意非终态→cancelled
    /// ```
    private static let blockEdges: [AIStudyBlockStatus: Set<AIStudyBlockStatus>] = [
        .pending: [.analyzing, .cancelled],
        .analyzing: [.readyForAI, .failed, .cancelled],
        .readyForAI: [.requesting, .failed, .cancelled],
        .requesting: [.resolved, .retryScheduled, .failed, .cancelled],
        .retryScheduled: [.readyForAI, .failed, .cancelled],
        .resolved: [.awaitingConfirmation, .applying, .cancelled],
        .awaitingConfirmation: [.applying, .cancelled],
        .applying: [.applied, .failed, .cancelled],
        .applied: [],
        .failed: [.analyzing, .readyForAI, .cancelled],
        .cancelled: [],
    ]

    // MARK: 活跃/可恢复判定

    /// 「同一 document/revision 至多一个活跃 Job」的领域判据：
    /// 活跃 = 非终态（§4.1 + §6 部分唯一索引语义）。
    public static func isActive(_ job: AIStudyJob) -> Bool {
        !terminalJobStates.contains(job.status)
    }

    /// 是否可续跑：仅 paused Job 可 resume（paused→analyzing）。
    /// cancelled **不可恢复**——已提交内容保留但不是回滚对象，
    /// 继续取消的 Job 需显式动作并增 epoch（§9：不自动恢复）。
    /// completed/failed 同为终态不可 resume。
    public static func canResume(_ job: AIStudyJob) -> Bool {
        job.status == .paused
    }

    // MARK: Job 转移判定/执行

    public static func canTransition(
        from status: AIStudyJobStatus, to newStatus: AIStudyJobStatus
    ) -> Bool {
        jobEdges[status]?.contains(newStatus) ?? false
    }

    public static func canTransition(
        _ job: AIStudyJob, to newStatus: AIStudyJobStatus
    ) -> Bool {
        canTransition(from: job.status, to: newStatus)
    }

    /// 执行 Job 转移（非法 → throw）。
    ///
    /// 附带语义（§9.2 取消 + D11 暂停原因）：
    /// - →cancelled：`epoch += 1`——使在途的结果持久化/应用事务内
    ///   epoch 核对失效（迟到响应拒写）。已提交内容保留不回滚。
    /// - →paused：`resumeReason` 参数落值（缺省保留原值）。
    /// - 离开 paused：清除 `resumeReason`（原因已消费）。
    /// - `updatedAtMs` 更新为 `atMs`。
    @discardableResult
    public static func transition(
        _ job: inout AIStudyJob,
        to newStatus: AIStudyJobStatus,
        atMs: Int64,
        resumeReason: AIStudyResumeReason? = nil
    ) throws -> AIStudyJob {
        let old = job.status
        guard canTransition(from: old, to: newStatus) else {
            throw AIStudyJobTransitionError.illegalJobTransition(
                from: old, to: newStatus)
        }
        job.status = newStatus
        if newStatus == .cancelled {
            // 取消递增 epoch：停止派发后已起在途写一律被事务内核对拒绝。
            job.epoch += 1
        }
        if newStatus == .paused, let reason = resumeReason {
            job.resumeReason = reason
        }
        if old == .paused, newStatus != .paused {
            job.resumeReason = nil
        }
        job.updatedAtMs = atMs
        return job
    }

    // MARK: Block 转移判定/执行

    /// 注：与 Job 级 `canTransition(from:to:)` 不同名——
    /// 两枚举共享 `pending/cancelled/failed` 等 case 名，
    /// `blockFrom:` 标签让隐式成员调用点无歧义。
    public static func canTransition(
        blockFrom status: AIStudyBlockStatus, to newStatus: AIStudyBlockStatus
    ) -> Bool {
        blockEdges[status]?.contains(newStatus) ?? false
    }

    public static func canTransition(
        _ block: AIStudyJobBlock, to newStatus: AIStudyBlockStatus
    ) -> Bool {
        canTransition(blockFrom: block.status, to: newStatus)
    }

    /// 执行 Block 转移（非法 → throw）。`context` 携带转移伴随落库字段。
    ///
    /// 不变量：
    /// - 离开 requesting（任何去向）→ `leaseEpoch` 清空（运行 lease 作废，
    ///   §9.1 崩溃回收前提）。
    /// - →requesting → `nextRetryAtMs`/`lastErrorCode` 清空（新尝试不背旧债）；
    ///   `context.incrementAttemptCount` 控制 attempt+1。
    /// - →resolved → 清 `lastErrorCode`（成功不挂错误码）。
    @discardableResult
    public static func transition(
        _ block: inout AIStudyJobBlock,
        to newStatus: AIStudyBlockStatus,
        context: AIStudyBlockTransitionContext = .init()
    ) throws -> AIStudyJobBlock {
        let old = block.status
        guard canTransition(blockFrom: old, to: newStatus) else {
            throw AIStudyJobTransitionError.illegalBlockTransition(
                from: old, to: newStatus)
        }
        if old == .requesting, newStatus != .requesting {
            block.leaseEpoch = nil
        }
        if context.incrementAttemptCount {
            block.attemptCount += 1
        }
        if let leaseEpoch = context.leaseEpoch {
            block.leaseEpoch = leaseEpoch
        }
        if let nextRetryAtMs = context.nextRetryAtMs {
            block.nextRetryAtMs = nextRetryAtMs
        }
        if let resultID = context.resultID {
            block.resultID = resultID
        }
        if let lastErrorCode = context.lastErrorCode {
            block.lastErrorCode = lastErrorCode
        }
        if let lexicalStatus = context.lexicalStatus {
            block.lexicalStatus = lexicalStatus
        }
        if let translationStatus = context.translationStatus {
            block.translationStatus = translationStatus
        }
        if newStatus == .requesting {
            block.nextRetryAtMs = nil
            block.lastErrorCode = nil
        }
        if newStatus == .resolved {
            block.lastErrorCode = nil
        }
        block.status = newStatus
        return block
    }

    // MARK: 恢复协议（§9.1）纯函数投影

    /// 单个块的恢复处置分类——§9.1.5 的唯一编码处：
    /// 「有结果则不请求；有 receipt 则 replay；requesting 但无结果
    /// 才重试未知请求」。`nowMs` 由调用方注入（无隐藏时间源）。
    public static func resumeAction(
        for block: AIStudyJobBlock, nowMs: Int64
    ) -> AIStudyBlockResumeAction {
        switch block.status {
        case .applied:
            return .skip
        case .cancelled:
            return .dropped
        case .failed:
            return .needsExplicitRetry
        case .pending, .analyzing:
            return .analyze
        case .readyForAI:
            // 定稿未派发；resultID 已存属崩溃回补的边角，同样不重发。
            return block.resultID != nil ? .usePersistedResult : .dispatchRequest
        case .requesting:
            // 恢复协议核心判据：有持久化结果绝不重发（D10）；
            // 无结果才允许重试未知窗口（可能再计费，不承诺远端幂等）。
            return block.resultID != nil ? .usePersistedResult : .dispatchRequest
        case .retryScheduled:
            if let due = block.nextRetryAtMs, nowMs < due {
                return .waitForRetry(untilMs: due)
            }
            return .dispatchRequest
        case .resolved:
            // 结果已持久化，按结果推进（路由确认/应用），不重发。
            return .usePersistedResult
        case .awaitingConfirmation:
            return .presentForConfirmation
        case .applying:
            return .resumeApply
        }
    }

    /// paused/crash-recycle 的 Job 级续跑入口（§4.1 paused→analyzing
    /// 「按持久化阶段续跑」语义 + §9.1.6 按块 checkpoint 恢复）。
    ///
    /// 聚合规则（取最早未完成阶段）：
    /// 任一块需 analyze/dispatchRequest/waitForRetry/usePersistedResult
    /// → `.analyze`；否则有待确认 → `.awaitConfirmation`；
    /// 否则有应用中 → `.apply`；否则 `.finished`。
    /// cancelled/终态 Job 调用方应先查 `canResume`——本函数对任意
    /// 状态可计算（crash-recycle 的活跃 Job 同样适用）。
    public static func resumeTarget(
        for job: AIStudyJob, blocks: [AIStudyJobBlock]
    ) -> AIStudyResumeTarget {
        if job.status == .cancelled || job.status == .completed
            || job.status == .failed {
            return .finished
        }
        var needsConfirmation = false
        var needsApply = false
        for block in blocks where block.jobID == job.id {
            switch resumeAction(for: block, nowMs: .max) {
            case .analyze, .dispatchRequest, .waitForRetry,
                 .usePersistedResult:
                return .analyze
            case .presentForConfirmation:
                needsConfirmation = true
            case .resumeApply:
                needsApply = true
            case .skip, .needsExplicitRetry, .dropped:
                continue
            }
        }
        if needsConfirmation { return .awaitConfirmation }
        if needsApply { return .apply }
        return .finished
    }

    /// 下一 selection revision（§4.2：确认即持久化 immutable
    /// revision，单调递增不回退）。纯投影——写库由事务层完成。
    public static func nextSelectionRevision(for job: AIStudyJob) -> Int64 {
        job.selectionRevision + 1
    }
}
