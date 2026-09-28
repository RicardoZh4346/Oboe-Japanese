import Foundation

/// v0.7.5 S09：候选 planner + 请求序列化器。
/// 依据：contracts-frozen rev2 §3.1（请求形状）、§4.4（requestHash）、
/// 技术文档 §6.2（候选生成/token 身份）、§6.3（请求块拆分）、
/// S02-B §8（sense 级 payload、OOV 显式 unresolved）。
///
/// 纯领域实现：输入是 morphology 输出 + 词典 sense 明细（窄口
/// `AIStudySenseSource`，由 `DictionaryRepository` 适配），输出是定稿的
/// `AIStudyRequest` 序列——不接 Provider、不触网络、不写库。
///
/// # 固定序与确定性
///
/// - 目标 token 按 `sourceRangeUTF16.lowerBound` 排序；候选保留
///   resolver 命中序（词典序）并以 entryID 去重——序列化/hashing
///   完全确定，同输入两进程同值。
/// - `tokenID`/`blockKey`/`requestID` 全部 range 派生，无随机分量。
/// - `candidateSetHash`/`requestHash` 走 canonical JSON（键排序、
///   无空白、最小转义）→ SHA-256，与 sense-fp-1 同一编码约定。

// MARK: - sense 明细来源（窄口，词典适配点）

/// planner 需要的唯一外部数据：候选 entry 的详情（sense/gloss/限制）。
/// `DictionaryRepository.entries(ids:)` 经 `DictionaryRepositorySenseSource`
/// 直接适配；测试以内存 stub 实现。
public protocol AIStudySenseSource: Sendable {
    /// 按输入序返回存在的 entry（缺失静默跳过——planner 视其为
    /// 不可用候选，不产生伪候选）。
    func entries(ids: [Int64]) async throws -> [DictionaryEntry]
}

/// `DictionaryRepository` → `AIStudySenseSource` 适配器（S10/容器接线用）。
public struct DictionaryRepositorySenseSource: AIStudySenseSource {
    public let repository: any DictionaryRepository
    public init(repository: any DictionaryRepository) { self.repository = repository }
    public func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
        try await repository.entries(ids: ids)
    }
}

// MARK: - planner 输入

/// 一个待分析段落（Reader block）的规划输入。
///
/// `tokens` 的 `sourceRangeUTF16` 必须指向 `sourceText` 的 UTF-16
/// 坐标系且目标 token 区间互不重叠（§6.3：请求目标区间不得重叠）。
public struct AIStudyPlannerInput: Sendable {
    /// 块域稳定键——内容无关的定位（如
    /// `"doc:<documentID>:rev:<contentRevision>:p:<blockIndex>"`）。
    /// 同一段重算必须给同一 scopeKey，blockKey/tokenID/requestID 才稳定。
    public let scopeKey: String
    /// 整段原文（token range 坐标系；subblock 的 targetText 是它的切片）。
    public let sourceText: String
    /// 有限相邻上下文（可为空）。同一物理段拆出的所有 subblock 共享
    /// 同一 context——上下文允许重叠但不重复翻译/建 occurrence（§6.3）。
    public let context: String
    /// morphology 输出（planner 内部按 `tokenClass.countsForCoverage`
    /// 过滤目标 occurrence；nonLexical 不进请求）。
    public let tokens: [ReaderToken]
    /// 句界 UTF-16 区间（可选）——超预算时优先沿句界切 subblock；
    /// 缺省/句界仍超限时按 token range 二分。
    public let sentenceRanges: [Range<Int>]
    /// 是否请求译文（§6.3 词义修复路径可只补词义不翻）。
    public let wantsTranslation: Bool

    public init(
        scopeKey: String,
        sourceText: String,
        context: String = "",
        tokens: [ReaderToken],
        sentenceRanges: [Range<Int>] = [],
        wantsTranslation: Bool = true
    ) {
        self.scopeKey = scopeKey
        self.sourceText = sourceText
        self.context = context
        self.tokens = tokens
        self.sentenceRanges = sentenceRanges
        self.wantsTranslation = wantsTranslation
    }
}

// MARK: - 序列化器（canonical JSON + §4.4 hash）

/// 请求/候选的 canonical 序列化与 hash 的唯一实现点。
/// wire JSON 与 hash 编码共用同一 canonical 输出——发送字节
/// 即被 hash 覆盖的字节（候选改动必换 candidateSetHash/requestHash）。
public enum AIStudyRequestSerializer {
    typealias JSON = AIStudyCanonicalJSON.Value

    // MARK: 稳定 ID 派生（§3.1/§6.2：range 派生、非随机）

    /// `t` + SHA256("blockKey|utf16Start|utf16Length") 前 12 hex。
    /// 定长 13 字符；同输入任意进程重建同值。
    public static func tokenID(
        blockKey: String, utf16Start: Int, utf16Length: Int
    ) -> String {
        "t" + String(
            AIStudyCanonicalJSON.sha256Hex(
                "\(blockKey)|\(utf16Start)|\(utf16Length)"
            ).prefix(12)
        )
    }

    /// `"<scopeKey>#r<start>-<end>"`——同 sourceHash 内 subblock
    /// 以目标区间区分（§6.3：目标区间互不重叠）。
    public static func blockKey(scopeKey: String, targetRange: Range<Int>) -> String {
        "\(scopeKey)#r\(targetRange.lowerBound)-\(targetRange.upperBound)"
    }

    /// `rq-` + SHA256("blockKey|schemaVersion") 前 16 hex——
    /// 稳定可重建（重算同块请求得同 ID，响应按它精确匹配）。
    public static func requestID(blockKey: String) -> String {
        "rq-" + String(
            AIStudyCanonicalJSON.sha256Hex(
                "\(blockKey)|\(AIStudyRequest.schemaVersion)"
            ).prefix(16)
        )
    }

    // MARK: wire JSON（发送形态）

    static func senseJSON(_ sense: AIStudyCandidateSense) -> JSON {
        .object([
            ("enGlosses", .array(sense.enGlosses.map { .string($0) })),
            ("restrictedForms", .array(sense.restrictedForms.map { .string($0) })),
            ("restrictedReadings", .array(sense.restrictedReadings.map { .string($0) })),
            ("senseID", .integer(sense.senseID)),
        ])
    }

    static func candidateJSON(_ candidate: AIStudyCandidate) -> JSON {
        .object([
            ("entryID", .integer(candidate.entryID)),
            ("lemma", candidate.lemma.map { JSON.string($0) } ?? .null),
            ("matchedForm", candidate.matchedForm.map { JSON.string($0) } ?? .null),
            ("matchedReading", candidate.matchedReading.map { JSON.string($0) } ?? .null),
            ("posCodes", .array(candidate.posCodes.map { .string($0) })),
            ("reading", candidate.reading.map { JSON.string($0) } ?? .null),
            ("senses", .array(candidate.senses.map(senseJSON))),
        ])
    }

    static func tokenJSON(_ token: AIStudyToken) -> JSON {
        .object([
            ("candidates", .array(token.candidates.map(candidateJSON))),
            ("lemma", token.lemma.map { JSON.string($0) } ?? .null),
            ("needsCandidateConfirmation", .bool(token.needsCandidateConfirmation)),
            ("posFamily", token.posFamily.map { JSON.string($0) } ?? .null),
            ("range", .object([
                ("length", .integer(Int64(token.utf16Length))),
                ("start", .integer(Int64(token.utf16Start))),
            ])),
            ("reading", token.reading.map { JSON.string($0) } ?? .null),
            ("surface", .string(token.surface)),
            ("tokenID", .string(token.tokenID)),
        ])
    }

    static func blockJSON(_ block: AIStudyBlock) -> JSON {
        .object([
            ("blockKey", .string(block.blockKey)),
            ("candidateSetHash", .string(block.candidateSetHash)),
            ("context", .string(block.context)),
            ("targetRange", .object([
                ("length", .integer(Int64(block.targetUTF16Length))),
                ("start", .integer(Int64(block.targetUTF16Start))),
            ])),
            ("targetText", .string(block.targetText)),
            ("tokens", .array(block.tokens.map(tokenJSON))),
            ("wantsTranslation", .bool(block.wantsTranslation)),
        ])
    }

    static func metadataJSON(_ metadata: AIStudyRequestMetadata) -> JSON {
        .object([
            ("providerKind", .string(metadata.providerKind)),
            ("model", .string(metadata.model)),
            ("responseMode", .string(metadata.responseMode)),
            ("promptVersion", .string(metadata.promptVersion)),
            ("language", .string(metadata.language)),
            ("generationParameters", .object(
                metadata.generationParameters.map { ($0.key, JSON.string($0.value)) }
            )),
        ])
    }

    /// 完整请求体（发送给 Provider payload 的 canonical JSON）。
    /// endpoint fingerprint / dataset 版本等环境字段**不进 wire**——
    /// 它们是 requestHash 组分，不是 prompt 内容。
    public static func serializedRequest(_ request: AIStudyRequest) -> String {
        JSON.object([
            ("blocks", .array(request.blocks.map(blockJSON))),
            ("generationParameters", .object(
                request.metadata.generationParameters.map {
                    ($0.key, JSON.string($0.value))
                }
            )),
            ("language", .string(request.metadata.language)),
            ("model", .string(request.metadata.model)),
            ("promptVersion", .string(request.metadata.promptVersion)),
            ("provider", .string(request.metadata.providerKind)),
            ("requestID", .string(request.requestID)),
            ("responseMode", .string(request.metadata.responseMode)),
            ("schemaVersion", .integer(Int64(request.schemaVersion))),
        ]).serialized
    }

    /// 序列化字节数（预算计量口径 = 实际发送的 UTF-8 字节）。
    public static func serializedRequestBytes(_ request: AIStudyRequest) -> Int {
        serializedRequest(request).utf8.count
    }

    // MARK: 候选集 hash（§4.4 candidateSetHash）

    /// 对**实际发送**的 entry/sense/gloss/restriction canonical JSON 取
    /// SHA-256（§4.4：候选排序固定，覆盖 gloss 与限制——任一字节变化
    /// 即换 hash）。不含 tokenID 以外 token 字段：surface/lemma 归
    /// tokenLayoutHash 管。
    public static func candidateSetHash(tokens: [AIStudyToken]) -> String {
        let value = JSON.array(tokens.map { token in
            JSON.object([
                ("candidates", .array(token.candidates.map { candidate in
                    JSON.object([
                        ("entryID", .integer(candidate.entryID)),
                        ("senses", .array(candidate.senses.map { sense in
                            JSON.object([
                                ("enGlosses", .array(
                                    sense.enGlosses.map { .string($0) })),
                                ("restrictedForms", .array(
                                    sense.restrictedForms.map { .string($0) })),
                                ("restrictedReadings", .array(
                                    sense.restrictedReadings.map { .string($0) })),
                                ("senseID", .integer(sense.senseID)),
                            ])
                        })),
                    ])
                })),
                ("tokenID", .string(token.tokenID)),
            ])
        })
        return AIStudyCanonicalJSON.sha256Hex(of: value)
    }

    // MARK: requestHash（§4.4 冻结字段集）

    /// §4.4 的 16 字段 canonical JSON → SHA-256：
    /// `targetTextHash / contextHash / tokenLayoutHash / candidateSetHash /
    ///  dictionaryDatasetVersion / morphologyVersion / parserVersion /
    ///  osBuild / providerKind / normalizedEndpointFingerprint / model /
    ///  responseMode / promptVersion / schemaVersion / language /
    ///  generationParameters`。
    ///
    /// 字段顺序无关（canonical 键排序）；endpoint 指纹**不含 Key**——
    /// 类型上 `AIStudyRequestMetadata.endpointFingerprint` 就不收凭据。
    /// 多块请求时前三项 hash 覆盖按块序排列的数组，保持确定。
    public static func requestHash(_ request: AIStudyRequest) -> String {
        let m = request.metadata
        let targetTextHash = AIStudyCanonicalJSON.sha256Hex(of: .array(
            request.blocks.map { .string($0.targetText) }))
        let contextHash = AIStudyCanonicalJSON.sha256Hex(of: .array(
            request.blocks.map { .string($0.context) }))
        let tokenLayoutHash = AIStudyCanonicalJSON.sha256Hex(of: .array(
            request.blocks.flatMap { block in
                block.tokens.map { token in
                    JSON.object([
                        ("blockKey", .string(block.blockKey)),
                        ("length", .integer(Int64(token.utf16Length))),
                        ("start", .integer(Int64(token.utf16Start))),
                        ("surface", .string(token.surface)),
                        ("tokenID", .string(token.tokenID)),
                    ])
                }
            }))
        let candidateSetHash = AIStudyCanonicalJSON.sha256Hex(of: .array(
            request.blocks.map { .string($0.candidateSetHash) }))
        let root = JSON.object([
            ("candidateSetHash", .string(candidateSetHash)),
            ("contextHash", .string(contextHash)),
            ("dictionaryDatasetVersion", .string(m.dictionaryDatasetVersion)),
            ("generationParameters", .object(
                m.generationParameters.map { ($0.key, JSON.string($0.value)) })),
            ("language", .string(m.language)),
            ("model", .string(m.model)),
            ("morphologyVersion", .string(m.morphologyVersion)),
            ("normalizedEndpointFingerprint", .string(m.endpointFingerprint)),
            ("osBuild", .string(m.osBuild)),
            ("parserVersion", .string(m.parserVersion)),
            ("promptVersion", .string(m.promptVersion)),
            ("providerKind", .string(m.providerKind)),
            ("responseMode", .string(m.responseMode)),
            ("schemaVersion", .integer(Int64(request.schemaVersion))),
            ("targetTextHash", .string(targetTextHash)),
            ("tokenLayoutHash", .string(tokenLayoutHash)),
        ])
        return AIStudyCanonicalJSON.sha256Hex(of: root)
    }
}

// MARK: - planner

/// 从 morphology token 序列构造 `AIStudyRequest` 序列的纯函数式 planner。
///
/// 流程（对应 §6.2/§6.3）：
/// 1. 过滤目标 occurrence（`countsForCoverage`），按 range 排序；
/// 2. 批量取候选 entry 详情 → sense 级过滤（admissible POS ∩ +
///    stagk/stagr 对 matched 证据）→ ≤5 entry 截取；
/// 3. 估算每 token 序列化字节 → 句界分组 → 按 ≤40 occ/块 与
///    48KiB−envelope 预算贪心打包；超限段按 range 二分；
///    单 token 候选组超预算 → `needsCandidateConfirmation` 整块单列；
/// 4. 定稿 blockKey/tokenID/candidateSetHash/requestHash。
///
/// OOV/无候选 token 照常进块（`candidates == []` 显式占位，
/// 绝不造伪候选——S02-B 6/9 伪候选是 validator 动机）。
public struct AIStudyCandidatePlanner: Sendable {
    public let senseSource: any AIStudySenseSource
    /// 每 sense 英文 gloss 上限（S02-B §6：≤3 条最相关 gloss）。
    public let maxGlossesPerSense: Int

    public init(
        senseSource: any AIStudySenseSource,
        maxGlossesPerSense: Int = AIStudyBudget.maxGlossesPerSense
    ) {
        self.senseSource = senseSource
        self.maxGlossesPerSense = maxGlossesPerSense
    }

    /// 打包中间产物：reader token + sense 级候选 + 体积与超预算标记。
    private struct PendingToken {
        let token: ReaderToken
        var candidates: [AIStudyCandidate]
        /// 上游候选数超 `maxCandidatesPerEntry` 被截取。
        var entryOverflow: Bool
        /// 候选组序列化字节 > 块容量（预算超限）。
        var byteOverflow: Bool
        /// 序列化 token payload 字节（tokenID 定长 → 定稿前后同值）。
        var payloadBytes: Int
        /// 该 token 的目标文本份额 = utf8(自身区间) + utf8(到下一
        /// 目标 token 起点的间隙；末 token 延伸到原文尾)——与定稿
        /// 分区约定一致，使打包估算是最终 targetText 的精确上界。
        var textShareBytes: Int
    }

    /// 主入口：产出定稿请求序列（当前每请求一块）。
    public func plan(
        _ input: AIStudyPlannerInput,
        metadata: AIStudyRequestMetadata
    ) async throws -> [AIStudyRequest] {
        let utf16 = Array(input.sourceText.utf16)

        // 1. 目标 occurrence：覆盖率口径（lexical+auxiliary+OOV），
        //    非重叠目标按 range 升序——固定序第一环。
        let targets = input.tokens
            .filter { $0.tokenClass.countsForCoverage }
            .sorted { $0.sourceRangeUTF16.lowerBound < $1.sourceRangeUTF16.lowerBound }

        // 2. 批量取候选详情（一次 IN-chunk，不逐 token 查询）。
        let wantedIDs = targets.flatMap(\.candidates).compactMap(\.entryID)
        var seenIDs = Set<Int64>()
        let orderedIDs = wantedIDs.filter { seenIDs.insert($0).inserted }
        let entries = try await senseSource.entries(ids: orderedIDs)
        let entryMap = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        // 3. 块容量 = 总预算 − 元数据序列化 − 固定骨架余量。
        let metadataBytes = AIStudyRequestSerializer
            .metadataJSON(metadata).serialized.utf8.count
        let capacity = max(
            1024,
            AIStudyBudget.serializedInputBudgetBytes
                - metadataBytes - AIStudyBudget.requestEnvelopeReserveBytes
        )

        // 4. 建候选（POS/限制过滤 → ≤5 截取 → 体积标记）+
        //    每 token 文本份额（含后随间隙）与首 token 前缀。
        var pending = targets.map { token in
            buildPending(token: token, entryMap: entryMap, capacity: capacity)
        }
        let leadingPrefixBytes = targets.first.map {
            String(decoding: utf16[0..<$0.sourceRangeUTF16.lowerBound],
                   as: UTF16.self).utf8.count
        } ?? 0
        for index in pending.indices {
            let range = pending[index].token.sourceRangeUTF16
            let nextStart = index + 1 < pending.count
                ? pending[index + 1].token.sourceRangeUTF16.lowerBound
                : utf16.count
            pending[index].textShareBytes = String(
                decoding: utf16[range.lowerBound..<min(nextStart, utf16.count)],
                as: UTF16.self).utf8.count
        }

        // 5. 打包切块；无目标 token → 单块纯翻译请求（§6.3 words=[]）。
        let groups: [[PendingToken]] = pending.isEmpty
            ? [[]]
            : pack(pending, input: input, utf16: utf16,
                   capacity: capacity, leadingPrefixBytes: leadingPrefixBytes)

        // 6. 定稿：块间按下一组首 token 起点划分目标区间——
        //    全体 subblock 无重叠完整覆盖原文（token 间隔标点与
        //        收尾标点都进某一块的 targetText，不丢译文片段）。
        var requests: [AIStudyRequest] = []
        requests.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let nextStart = groups.indices.contains(index + 1)
                ? groups[index + 1].first?.token.sourceRangeUTF16.lowerBound
                : nil
            requests.append(finalize(
                group: group, input: input, utf16: utf16,
                metadata: metadata,
                isFirstBlock: index == 0,
                nextBlockStart: nextStart))
        }
        return requests
    }

    // MARK: 候选构建（§6.2：admissible POS + sense 级限制过滤）

    private func buildPending(
        token: ReaderToken,
        entryMap: [Int64: DictionaryEntry],
        capacity: Int
    ) -> PendingToken {
        var candidates: [AIStudyCandidate] = []
        var seen = Set<Int64>()
        var entryOverflow = false
        for mc in token.candidates {
            guard let entryID = mc.entryID, seen.insert(entryID).inserted,
                  let entry = entryMap[entryID] else { continue }
            let senses = admissibleSenses(of: entry, for: mc, token: token)
            // 该 occurrence 下无合法 sense 的候选不发送（S02-B：
            // sense 级可见性必须真实，不允许空壳 entry 占位）。
            guard !senses.isEmpty else { continue }
            candidates.append(makeCandidate(
                entry: entry, morphologyCandidate: mc,
                token: token, senses: senses))
            if candidates.count > AIStudyBudget.maxCandidatesPerEntry {
                entryOverflow = true
                candidates.removeLast()
                break
            }
        }
        // 仍有未检视候选 → 也算截断来源（>5 的 entry 被 cap 掉）。
        let payloadBytes = Self.serializedTokenPayloadBytes(
            lemma: token.lemmaOrCandidateLemma,
            reading: token.reading,
            posFamily: posFamily(for: token, candidates: candidates),
            surface: token.surface,
            utf16Start: token.sourceRangeUTF16.lowerBound,
            utf16Length: token.sourceRangeUTF16.count,
            candidates: candidates
        )
        let candidateBytes = AIStudyCanonicalJSON.Value.array(
            candidates.map(AIStudyRequestSerializer.candidateJSON)
        ).serialized.utf8.count
        return PendingToken(
            token: token,
            candidates: candidates,
            entryOverflow: entryOverflow,
            byteOverflow: candidateBytes > capacity,
            payloadBytes: payloadBytes,
            textShareBytes: 0   // 由 plan() 在排序后回填
        )
    }

    /// sense 级合法性门（候选对每个 occurrence 独立成立）：
    /// - admissible POS：候选携带 posCodes（resolver 已按命中路径
    ///   收窄）时，sense.posCodes 必须与之相交；候选无 POS 信息
    ///   （exact 通道）时不加门；
    /// - stagk：restrictedForms 非空 → 必须命中 {lemma,
    ///   normalizedForm, entry.primaryForm}；
    /// - stagr：restrictedReadings 非空 → 必须命中 {候选命中读音,
    ///   token 活用读音}；两侧皆无读音证据 → 该 sense 对本
    ///   occurrence 不可验证，保守剔除。
    private func admissibleSenses(
        of entry: DictionaryEntry,
        for candidate: MorphologyCandidate,
        token: ReaderToken
    ) -> [AIStudyCandidateSense] {
        let formEvidence: Set<String> = [
            candidate.lemma, candidate.normalizedForm, entry.primaryForm
        ]
        let readingEvidence = Set(
            [candidate.reading, token.reading].compactMap { $0 })
        return entry.senses.compactMap { sense in
            if !candidate.posCodes.isEmpty,
               Set(sense.posCodes).isDisjoint(with: candidate.posCodes) {
                return nil
            }
            if !sense.restrictedForms.isEmpty,
               Set(sense.restrictedForms).isDisjoint(with: formEvidence) {
                return nil
            }
            if !sense.restrictedReadings.isEmpty,
               Set(sense.restrictedReadings).isDisjoint(with: readingEvidence) {
                return nil
            }
            let glosses = sense.glosses(language: DictionaryGlossLanguage.english)
                .prefix(maxGlossesPerSense).map(\.text)
            return AIStudyCandidateSense(
                senseID: sense.id,
                enGlosses: Array(glosses),
                restrictedForms: sense.restrictedForms,
                restrictedReadings: sense.restrictedReadings
            )
        }
    }

    /// 组装候选并记录 validator 复核用的 matched 证据：
    /// 受限 sense 满足限制所凭的表记/读音原样写入，保证 validator
    /// 用同一证据复核不会误杀 planner 已放行的 sense。
    private func makeCandidate(
        entry: DictionaryEntry,
        morphologyCandidate mc: MorphologyCandidate,
        token: ReaderToken,
        senses: [AIStudyCandidateSense]
    ) -> AIStudyCandidate {
        let formEvidence = [mc.lemma, mc.normalizedForm, entry.primaryForm]
        let restrictedForms = Set(senses.flatMap(\.restrictedForms))
        let matchedForm = restrictedForms.isEmpty
            ? mc.lemma
            : formEvidence.first(where: { restrictedForms.contains($0) })
        let readingEvidence = [mc.reading, token.reading].compactMap { $0 }
        let restrictedReadings = Set(senses.flatMap(\.restrictedReadings))
        let matchedReading = restrictedReadings.isEmpty
            ? (mc.reading ?? token.reading)
            : readingEvidence.first(where: { restrictedReadings.contains($0) })
        // admissible POS = 保留 sense posCodes ∩ 候选门（无门取 sense 并集）。
        let retained = Set(sensesPosCodes(senses: senses, entry: entry))
        let admissible = mc.posCodes.isEmpty
            ? retained
            : retained.intersection(mc.posCodes)
        return AIStudyCandidate(
            entryID: entry.id,
            lemma: mc.lemma,
            reading: mc.reading ?? token.reading,
            matchedForm: matchedForm,
            matchedReading: matchedReading,
            posCodes: admissible.sorted(),
            senses: senses
        )
    }

    /// 保留 sense 的原始 posCodes（按 senseID 回到 entry 取）。
    private func sensesPosCodes(
        senses: [AIStudyCandidateSense], entry: DictionaryEntry
    ) -> [String] {
        let ids = Set(senses.map(\.senseID))
        return entry.senses.filter { ids.contains($0.id) }.flatMap(\.posCodes)
    }

    /// token 粗粒度词性族（prompt hint）：取候选 admissible 并集首个
    /// 映射族；无候选 → tokenClass 粗映射。
    private func posFamily(
        for token: ReaderToken, candidates: [AIStudyCandidate]
    ) -> String? {
        let codes = Set(candidates.flatMap(\.posCodes))
        if let code = codes.sorted().first {
            if code.hasPrefix("v") { return "verb" }
            if code.hasPrefix("adj") { return "adjective" }
            if code.hasPrefix("adv") { return "adverb" }
            if code.hasPrefix("n") { return "noun" }
            if code.hasPrefix("prt") { return "particle" }
            if code.hasPrefix("aux") || code == "cop" { return "auxiliary" }
            return code
        }
        switch token.tokenClass {
        case .auxiliary: return "auxiliary"
        case .outOfVocabulary: return "oov"
        case .lexical: return nil
        case .nonLexical: return nil
        }
    }

    // MARK: 打包（§6.3：≤40 occ/块 + 48KiB，句界优先切）

    /// 打包上下文里的每 token 占位 tokenID（定长 13 → 体积精确）。
    private static let placeholderTokenID = "t000000000000"

    private static func serializedTokenPayloadBytes(
        lemma: String?, reading: String?, posFamily: String?,
        surface: String, utf16Start: Int, utf16Length: Int,
        candidates: [AIStudyCandidate]
    ) -> Int {
        let token = AIStudyToken(
            tokenID: placeholderTokenID,
            surface: surface, lemma: lemma, reading: reading,
            posFamily: posFamily,
            utf16Start: utf16Start, utf16Length: utf16Length,
            candidates: candidates, needsCandidateConfirmation: false
        )
        return AIStudyRequestSerializer.tokenJSON(token).serialized.utf8.count
    }

    /// 块内容字节 = targetText + context + Σ token payload + 块骨架。
    /// targetText 按定稿分区估算：Σ(textShare) + 首块前缀（对每个块
    /// 都计——对中间块是微幅高估，保证估算是真实上界而非乐观值）。
    private static func blockBytes(
        tokens: [PendingToken], input: AIStudyPlannerInput,
        utf16: [UTF16.CodeUnit], leadingPrefixBytes: Int
    ) -> Int {
        guard !tokens.isEmpty else {
            return input.sourceText.utf8.count + input.context.utf8.count + 160
        }
        return input.context.utf8.count + leadingPrefixBytes
            + tokens.reduce(0) { $0 + $1.payloadBytes + $1.textShareBytes }
            + 160
    }

    /// 句界分组：token 完整落入句界则归该句，跨句/句外 token 自成一组。
    /// 句界缺失 → 全部 token 一组（纯 range 打包）。
    private func segmentize(
        _ tokens: [PendingToken], sentenceRanges: [Range<Int>]
    ) -> [[PendingToken]] {
        guard !sentenceRanges.isEmpty else { return tokens.isEmpty ? [] : [tokens] }
        let sortedRanges = sentenceRanges.sorted { $0.lowerBound < $1.lowerBound }
        var segments: [[PendingToken]] = []
        var current: [PendingToken] = []
        var currentRange: Range<Int>?
        for pending in tokens {
            let r = pending.token.sourceRangeUTF16
            let container = sortedRanges.first {
                $0.contains(r.lowerBound) && r.upperBound <= $0.upperBound
            }
            if let container, container == currentRange {
                current.append(pending)
            } else {
                if !current.isEmpty { segments.append(current) }
                current = [pending]
                currentRange = container
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// 贪心打包：整段（句）作原子单元累加；单段超限 → 先按 40 occ
    /// 分 chunk，再按字节二分。返回的每个元素是一个 block 的 token 组。
    private func pack(
        _ tokens: [PendingToken], input: AIStudyPlannerInput,
        utf16: [UTF16.CodeUnit], capacity: Int, leadingPrefixBytes: Int
    ) -> [[PendingToken]] {
        guard !tokens.isEmpty else { return [] }
        var blocks: [[PendingToken]] = []
        var pending: [PendingToken] = []
        func fits(_ extra: [PendingToken]) -> Bool {
            let merged = pending + extra
            return merged.count <= AIStudyBudget.maxTargetOccurrencesPerRequest
                && Self.blockBytes(
                    tokens: merged, input: input, utf16: utf16,
                    leadingPrefixBytes: leadingPrefixBytes) <= capacity
        }
        for segment in segmentize(tokens, sentenceRanges: input.sentenceRanges) {
            let segmentOverCount =
                segment.count > AIStudyBudget.maxTargetOccurrencesPerRequest
            let segmentOverBytes = Self.blockBytes(
                tokens: segment, input: input, utf16: utf16,
                leadingPrefixBytes: leadingPrefixBytes) > capacity
            if segmentOverCount || segmentOverBytes {
                if !pending.isEmpty { blocks.append(pending); pending = [] }
                blocks.append(contentsOf: splitOversize(
                    segment, input: input, utf16: utf16, capacity: capacity,
                    leadingPrefixBytes: leadingPrefixBytes))
            } else if !fits(segment) {
                blocks.append(pending); pending = segment
            } else {
                pending.append(contentsOf: segment)
            }
        }
        if !pending.isEmpty { blocks.append(pending) }
        return blocks
    }

    /// 超限段拆分：先按 ≤40 token 切 chunk，chunk 仍超字节则按
    /// token 数二分递归；单 token 超预算 → `byteOverflow` 标记单列
    /// （不砍候选字段——§6.3「候选过多需确认，翻译可继续」）。
    private func splitOversize(
        _ tokens: [PendingToken], input: AIStudyPlannerInput,
        utf16: [UTF16.CodeUnit], capacity: Int, leadingPrefixBytes: Int
    ) -> [[PendingToken]] {
        var result: [[PendingToken]] = []
        var index = 0
        while index < tokens.count {
            let chunk = Array(tokens[index..<min(
                index + AIStudyBudget.maxTargetOccurrencesPerRequest,
                tokens.count)])
            index += chunk.count
            if Self.blockBytes(
                tokens: chunk, input: input, utf16: utf16,
                leadingPrefixBytes: leadingPrefixBytes) <= capacity {
                result.append(chunk)
            } else {
                result.append(contentsOf: bisectByBytes(
                    chunk, input: input, utf16: utf16, capacity: capacity,
                    leadingPrefixBytes: leadingPrefixBytes))
            }
        }
        return result
    }

    private func bisectByBytes(
        _ tokens: [PendingToken], input: AIStudyPlannerInput,
        utf16: [UTF16.CodeUnit], capacity: Int, leadingPrefixBytes: Int
    ) -> [[PendingToken]] {
        if tokens.count <= 1 {
            return [tokens] // 单 token 超预算：标记位已在 build 阶段计算
        }
        if Self.blockBytes(
            tokens: tokens, input: input, utf16: utf16,
            leadingPrefixBytes: leadingPrefixBytes) <= capacity {
            return [tokens]
        }
        let mid = tokens.count / 2
        return bisectByBytes(
            Array(tokens[..<mid]), input: input, utf16: utf16,
            capacity: capacity, leadingPrefixBytes: leadingPrefixBytes)
            + bisectByBytes(
                Array(tokens[mid...]), input: input, utf16: utf16,
                capacity: capacity, leadingPrefixBytes: leadingPrefixBytes)
    }

    // MARK: 定稿

    /// 组装最终请求：blockKey → tokenID（块内 range 派生）→
    /// candidateSetHash → requestID → §4.4 requestHash。
    ///
    /// 目标区间划分：首块从 0 起、末块到原文末尾，中间块以
    /// 「本组首 token 起点 → 下组首 token 起点」为界——token 间
    /// 空白/标点归入左侧块，全部块拼出完整原文且不重叠（§6.3：
    /// 仅同一 sourceHash 全片段齐全才拼成完整段落译文）。
    private func finalize(
        group: [PendingToken], input: AIStudyPlannerInput,
        utf16: [UTF16.CodeUnit], metadata: AIStudyRequestMetadata,
        isFirstBlock: Bool, nextBlockStart: Int?
    ) -> AIStudyRequest {
        let targetRange: Range<Int>
        if group.isEmpty {
            // 纯翻译块：无目标 token，覆盖整段（§6.3 words=[] 合法）。
            targetRange = 0..<utf16.count
        } else {
            let start = isFirstBlock
                ? 0
                : group.map { $0.token.sourceRangeUTF16.lowerBound }.min()!
            let end = nextBlockStart ?? utf16.count
            targetRange = start..<min(end, utf16.count)
        }
        let blockKey = AIStudyRequestSerializer.blockKey(
            scopeKey: input.scopeKey, targetRange: targetRange)
        let targetText = String(decoding: utf16[targetRange], as: UTF16.self)

        let tokens: [AIStudyToken] = group.map { pending in
            let t = pending.token
            let range = t.sourceRangeUTF16
            return AIStudyToken(
                tokenID: AIStudyRequestSerializer.tokenID(
                    blockKey: blockKey,
                    utf16Start: range.lowerBound,
                    utf16Length: range.count),
                surface: t.surface,
                lemma: t.lemmaOrCandidateLemma,
                reading: t.reading,
                posFamily: posFamily(for: t, candidates: pending.candidates),
                utf16Start: range.lowerBound,
                utf16Length: range.count,
                candidates: pending.candidates,
                needsCandidateConfirmation:
                    pending.entryOverflow || pending.byteOverflow
            )
        }
        let block = AIStudyBlock(
            blockKey: blockKey,
            targetText: targetText,
            context: input.context,
            targetUTF16Start: targetRange.lowerBound,
            targetUTF16Length: targetRange.count,
            tokens: tokens,
            candidateSetHash: AIStudyRequestSerializer
                .candidateSetHash(tokens: tokens),
            wantsTranslation: input.wantsTranslation
        )
        let request = AIStudyRequest(
            requestID: AIStudyRequestSerializer.requestID(blockKey: blockKey),
            blocks: [block],
            metadata: metadata,
            requestHash: ""
        )
        return AIStudyRequest(
            requestID: request.requestID,
            blocks: request.blocks,
            metadata: metadata,
            requestHash: AIStudyRequestSerializer.requestHash(request)
        )
    }
}

// MARK: - ReaderToken 便捷

private extension ReaderToken {
    /// token 原形：优先候选链首候选 lemma；OOV/无候选为 nil
    /// （不拿 surface 冒充 lemma——OOV 就是 OOV）。
    var lemmaOrCandidateLemma: String? {
        candidates.first?.lemma
    }
}
