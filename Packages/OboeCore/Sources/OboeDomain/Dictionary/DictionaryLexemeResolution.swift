import Foundation

/// S19：lexeme → dictionary entry 的**层级匹配**解析（exact written >
/// exact reading > deinflected）与词典换库后的「同层重绑定」决策。
///
/// 与 `GRDBDictionaryRepository` 搜索排序的区别：搜索是 UI 浏览序
/// （exact → deinflected → prefix 分页）；这里是**身份绑定序**——
/// 为一个 lemma/Note 选定唯一词典 entry。规则（设计 §6.3 + S19 验收）：
///
/// 1. `sourceContext`：Note/Reader 事件自带的 `dictionary_entry_id`
///    经表记+读音验证（最强——人工/挖掘时已定位到具体 ent_seq）；
/// 2. `exactWritten`：规范化表记 ∈ `forms.normalized_text`；
/// 3. `exactReading`：规范化表记 ∈ `readings.normalized_reading`
///    （输入本身是读音形——假名查词）；
/// 4. `deinflected`：活用还原 lemma（按 cost 升序）首个非空命中集。
///
/// **高层命中即锁定**：某层产生候选（哪怕多候选 ambiguous）就不再
/// 下探更低层——低层命中不可能比「表记精确命中」更可靠。歧义时返回
/// 该层候选集（有界 `maximumAmbiguousCandidates`），交用户选择。
///
/// 层内多候选消歧：Note 读音规范化后恰能选中一个候选 entry（其
/// normalizedReadings 含该读音）→ resolved；否则 ambiguous。
///
/// 换库重绑（`reresolve`）：**只跑原层级**。同层唯一命中 → 更新绑定；
/// 同层零命中 → `stale`（保留旧 entry_id 并标记）；同层多命中 →
/// `ambiguous`（同样保留旧值）。绝不静默降级到更低层换绑。

// MARK: - 匹配层级

/// lexeme 绑定的词典匹配层级（`lexeme_dictionary_bindings.match_tier`
/// 列值——v22 schema）。`Comparable` 数字越小层级越强。
public enum DictionaryMatchTier: String, Codable, Sendable, CaseIterable, Comparable {
    /// SourceContext 携带的 ent_seq 经表记+读音验证通过。
    case sourceContext
    /// 规范化表记命中 forms 通道。
    case exactWritten
    /// 规范化表记命中 readings 通道。
    case exactReading
    /// 活用还原 lemma 命中（forms/readings 双通道）。
    case deinflected
    /// 仅用于绑定记录：v22 之前建立的既有绑定无层级信息，换库时
    /// 只能「原 entry 仍在且表记/读音相容」的核验语义——永不
    /// 出现在新解析结果中。
    case verifiedExisting

    /// 层级强度（小=强）。`verifiedExisting` 不参与比较语义——
    /// 只作记录值；Comparable 里置于最弱。
    private var rank: Int {
        switch self {
        case .sourceContext: return 0
        case .exactWritten: return 1
        case .exactReading: return 2
        case .deinflected: return 3
        case .verifiedExisting: return 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }

    /// 是否为真实解析层级（`verifiedExisting` 只作绑定记录值）。
    public var isResolutionTier: Bool { self != .verifiedExisting }
}

// MARK: - 查找 seam 与命中行

/// 层级命中行：entry + 命中表面 + common_rank（排序/展示用）。
public struct TieredEntryMatch: Equatable, Sendable {
    public let entryID: Int64
    public let matchedSurface: String
    public let commonRank: Int?

    public init(entryID: Int64, matchedSurface: String, commonRank: Int?) {
        self.entryID = entryID
        self.matchedSurface = matchedSurface
        self.commonRank = commonRank
    }
}

/// entry 的规范化表面集合（`sourceContext`/`verifiedExisting` 层验证与
/// 层内读音消歧共用）。
public struct DictionaryEntrySurface: Equatable, Sendable {
    public let entryID: Int64
    public let primaryForm: String
    public let normalizedForms: Set<String>
    public let normalizedReadings: Set<String>

    public init(
        entryID: Int64,
        primaryForm: String,
        normalizedForms: Set<String>,
        normalizedReadings: Set<String>
    ) {
        self.entryID = entryID
        self.primaryForm = primaryForm
        self.normalizedForms = normalizedForms
        self.normalizedReadings = normalizedReadings
    }
}

/// 词典侧分层查找边界。实现要求（§17 同口径）：
/// - 每个 `*Matches` 返回按 (common_rank, entryID) 升序、**entry 去重**
///   后的序列——同 entry 多表面命中只保留首个；
/// - `lemmaMatches` 必须批量 IN-chunk（deinflected 候选一组一查），
///   不得逐 key SQL；
/// - 只读——实现方不得向词典库写入任何状态。
public protocol DictionaryTieredLookup: Sendable {
    /// `forms.normalized_text == normalizedKey` 的命中。
    func formMatches(normalizedKey: String) async throws -> [TieredEntryMatch]
    /// `readings.normalized_reading == normalizedKey` 的命中。
    func readingMatches(normalizedKey: String) async throws -> [TieredEntryMatch]
    /// deinflected 段：一组 lemma 的规范化 key → 双通道合并命中。
    /// 返回只含有命中 key 的条目；同一 entry 跨 key 命中按首 key 归组。
    func lemmaMatches(
        normalizedKeys: [String]
    ) async throws -> [String: [TieredEntryMatch]]
    /// entry 表面集合（验证/消歧）；不存在的 id 静默缺席。
    func entrySurfaces(
        entryIDs: [Int64]
    ) async throws -> [Int64: DictionaryEntrySurface]
    /// 当前 dataset_version（绑定记录写入列）。
    func datasetVersion() async throws -> String?
}

// MARK: - 解析输入/输出

/// 层级解析输入。`deinflectionLemmas` 由调用方按 deinflector
/// cost 升序传入（第一个非空命中集即锁定该层——继续取更低 cost
/// 之后的 lemma 没有意义）。
public struct LexemeResolutionInput: Equatable, Sendable {
    /// 显示表记（Note headword / token surface 原文）。
    public let writtenForm: String
    /// 已知读音（Note reading；层内消歧 + sourceContext 验证用）。
    public let reading: String?
    /// 变形还原 lemma 序列（cost 升序）。
    public let deinflectionLemmas: [String]
    /// SourceContext 里的既有 entry 绑定候选（最强层）。
    public let contextEntryID: Int64?

    public init(
        writtenForm: String,
        reading: String? = nil,
        deinflectionLemmas: [String] = [],
        contextEntryID: Int64? = nil
    ) {
        self.writtenForm = writtenForm
        self.reading = reading
        self.deinflectionLemmas = deinflectionLemmas
        self.contextEntryID = contextEntryID
    }
}

/// 层级解析结果。
public enum LexemeResolutionOutcome: Equatable, Sendable {
    /// 唯一命中：`tier` 记录命中层级，`match` 是胜出候选。
    case resolved(match: TieredEntryMatch, tier: DictionaryMatchTier)
    /// 高层有多候选：不再下探，交用户选择（候选有界截断）。
    case ambiguous(tier: DictionaryMatchTier, candidates: [TieredEntryMatch])
    /// 各层均无候选。
    case unresolved
}

/// 换库重绑决策（同层语义）。
public enum LexemeRebindDecision: Equatable, Sendable {
    /// 旧 entry_id 在新库仍有效（同层核验通过或唯一命中恰是旧值）。
    case current
    /// 同层唯一命中是新 entry——允许更新绑定（记录了层级语义未变）。
    case rebound(entryID: Int64)
    /// 同层零命中 / sourceContext 验证失败：保留旧值并标记。
    case stale(detail: String)
    /// 同层多命中无法定夺：保留旧值并标记（候选 id 列表入 detail）。
    case ambiguous(candidateEntryIDs: [Int64])
}

// MARK: - 绑定记录（v22 `lexeme_dictionary_bindings`）

/// 绑定状态：current=当前有效；stale=换库后同层失配，保留旧值待查；
/// ambiguousAwaiting=同层多候选，保留旧值待用户确认。
public enum LexemeBindingStatus: String, Codable, Sendable {
    case current
    case stale
    case ambiguousAwaiting
}

/// `lexeme_dictionary_bindings` 行的领域投影：绑定事实 =
/// (entry, 命中层级, 绑定时的 dataset 版本, 状态)。
public struct LexemeBindingRecord: Equatable, Sendable {
    public let lexemeID: UUID
    public let entryID: Int64
    public let tier: DictionaryMatchTier
    /// 绑定最后一次被确认时的词典 dataset_version。
    public let datasetVersion: String
    public let status: LexemeBindingStatus
    /// 机器可读细节（`entry_missing`/`ambiguous:<n>` 等）。
    public let detail: String?
    /// 首次解析时间；换库重绑不改它（provenance）。
    public let resolvedAt: Date
    public let updatedAt: Date

    public init(
        lexemeID: UUID,
        entryID: Int64,
        tier: DictionaryMatchTier,
        datasetVersion: String,
        status: LexemeBindingStatus,
        detail: String? = nil,
        resolvedAt: Date,
        updatedAt: Date
    ) {
        self.lexemeID = lexemeID
        self.entryID = entryID
        self.tier = tier
        self.datasetVersion = datasetVersion
        self.status = status
        self.detail = detail
        self.resolvedAt = resolvedAt
        self.updatedAt = updatedAt
    }
}

/// 换库重绑一轮的统计（服务返回值与报告口径同源）。
public struct LexemeRebindSummary: Equatable, Sendable {
    /// 参与核验的绑定/存量 jmdict lexeme 总数。
    public var scanned = 0
    /// 旧绑定仍有效（含同层唯一命中恰是旧值）。
    public var confirmedCurrent = 0
    /// 同层唯一命中新 entry——已换绑。
    public var rebound = 0
    /// 同层零命中/验证失败——保留旧值标 stale。
    public var markedStale = 0
    /// 同层多候选——保留旧值标 ambiguousAwaiting。
    public var markedAmbiguous = 0
    /// 本轮使用的 dataset_version。
    public let datasetVersion: String

    public init(datasetVersion: String) {
        self.datasetVersion = datasetVersion
    }
}

// MARK: - 解析器

/// 层级解析与重绑决策的唯一实现点（纯逻辑 + seam，无 SQL）。
public enum DictionaryLexemeResolver {
    /// 规则版本——绑定记录与报告引用；规则变更 bump。
    public static let resolutionRulesVersion = "s19-tiered-resolution-1"
    /// ambiguous 结果保留的候选上限。
    public static let maximumAmbiguousCandidates = 8

    /// 正向层级解析：sourceContext → exactWritten → exactReading →
    /// deinflected；高层产生候选即锁定（零命中才下探）。
    public static func resolve(
        _ input: LexemeResolutionInput,
        lookup: any DictionaryTieredLookup
    ) async throws -> LexemeResolutionOutcome {
        // 层 0：SourceContext 验证（最强，不参与「候选排序」——
        // 验证失败不算歧义，直接下探常规层）。
        if let contextID = input.contextEntryID,
           let surface = try await lookup.entrySurfaces(entryIDs: [contextID])[contextID],
           verify(surface: surface, input: input) {
            return .resolved(
                match: TieredEntryMatch(
                    entryID: contextID,
                    matchedSurface: surface.primaryForm,
                    commonRank: nil),
                tier: .sourceContext
            )
        }

        let normalizedWritten = SearchTextNormalizer.normalize(input.writtenForm)

        // 层 1：exactWritten
        if !normalizedWritten.isEmpty {
            let writtenHits = try await lookup.formMatches(
                normalizedKey: normalizedWritten)
            if let outcome = try await decide(
                tier: .exactWritten, matches: writtenHits,
                input: input, lookup: lookup) {
                return outcome
            }
            // 层 2：exactReading（written 本身是读音形）
            let readingHits = try await lookup.readingMatches(
                normalizedKey: normalizedWritten)
            if let outcome = try await decide(
                tier: .exactReading, matches: readingHits,
                input: input, lookup: lookup) {
                return outcome
            }
        }

        // 层 3：deinflected——按 cost 序取首个非空命中集。
        let lemmaKeys = input.deinflectionLemmas
            .map { SearchTextNormalizer.normalize($0) }
            .filter { !$0.isEmpty }
        if !lemmaKeys.isEmpty {
            let byKey = try await lookup.lemmaMatches(normalizedKeys: lemmaKeys)
            for key in lemmaKeys {
                guard let matches = byKey[key], !matches.isEmpty else { continue }
                if let outcome = try await decide(
                    tier: .deinflected, matches: matches,
                    input: input, lookup: lookup) {
                    return outcome
                }
                // 该层有候选但 decide 返回 nil 的情况不存在——
                // decide 对非空输入恒有结论（resolved/ambiguous）。
            }
        }
        return .unresolved
    }

    /// 同层重绑：词典换库后只在原匹配层级内重解析。
    /// `verifiedExisting`/`sourceContext` 走原 entry 核验路径。
    public static func reresolve(
        tier: DictionaryMatchTier,
        currentEntryID: Int64,
        input: LexemeResolutionInput,
        lookup: any DictionaryTieredLookup
    ) async throws -> LexemeRebindDecision {
        switch tier {
        case .sourceContext, .verifiedExisting:
            // 原绑定核验：entry 仍存在且表记（与读音）相容 → current。
            guard let surface = try await lookup.entrySurfaces(
                entryIDs: [currentEntryID])[currentEntryID]
            else {
                return .stale(detail: "entry_missing")
            }
            return verify(surface: surface, input: input)
                ? .current
                : .stale(detail: "surface_mismatch")

        case .exactWritten, .exactReading, .deinflected:
            let matches = try await sameTierMatches(
                tier: tier, input: input, lookup: lookup)
            return try await decideRebind(
                matches: matches, currentEntryID: currentEntryID,
                input: input, lookup: lookup)
        }
    }

    // MARK: - 层内逻辑

    /// 只取指定层的命中集（重绑用——绝不跨层）。
    private static func sameTierMatches(
        tier: DictionaryMatchTier,
        input: LexemeResolutionInput,
        lookup: any DictionaryTieredLookup
    ) async throws -> [TieredEntryMatch] {
        let normalizedWritten = SearchTextNormalizer.normalize(input.writtenForm)
        switch tier {
        case .exactWritten:
            guard !normalizedWritten.isEmpty else { return [] }
            return try await lookup.formMatches(normalizedKey: normalizedWritten)
        case .exactReading:
            guard !normalizedWritten.isEmpty else { return [] }
            return try await lookup.readingMatches(normalizedKey: normalizedWritten)
        case .deinflected:
            let lemmaKeys = input.deinflectionLemmas
                .map { SearchTextNormalizer.normalize($0) }
                .filter { !$0.isEmpty }
            guard !lemmaKeys.isEmpty else { return [] }
            let byKey = try await lookup.lemmaMatches(normalizedKeys: lemmaKeys)
            for key in lemmaKeys {
                if let matches = byKey[key], !matches.isEmpty { return matches }
            }
            return []
        case .sourceContext, .verifiedExisting:
            return []  // 不走命中集路径
        }
    }

    /// 非空候选集 → resolved/ambiguous；空集返回 nil（调用方继续下探）。
    private static func decide(
        tier: DictionaryMatchTier,
        matches: [TieredEntryMatch],
        input: LexemeResolutionInput,
        lookup: any DictionaryTieredLookup
    ) async throws -> LexemeResolutionOutcome? {
        let deduped = dedupeByEntry(matches)
        guard !deduped.isEmpty else { return nil }
        if deduped.count == 1 {
            return .resolved(match: deduped[0], tier: tier)
        }
        // 层内消歧：Note 读音规范化后恰好选中一个 entry。
        if let narrowed = try await disambiguateByReading(
            deduped, input: input, lookup: lookup) {
            return .resolved(match: narrowed, tier: tier)
        }
        return .ambiguous(
            tier: tier,
            candidates: Array(deduped.prefix(maximumAmbiguousCandidates))
        )
    }

    /// 重绑决策：同层候选集 + 旧绑定值。
    /// - 零命中 → `stale`（保留旧值）；
    /// - 唯一命中==旧值 → `current`；唯一命中是新 id → `rebound`；
    /// - 多候选先按读音消歧（消出唯一即按上两条裁决），
    ///   仍多 → `ambiguous`（保留旧值并标记——不静默换绑）。
    private static func decideRebind(
        matches: [TieredEntryMatch],
        currentEntryID: Int64,
        input: LexemeResolutionInput,
        lookup: any DictionaryTieredLookup
    ) async throws -> LexemeRebindDecision {
        let deduped = dedupeByEntry(matches)
        if deduped.isEmpty { return .stale(detail: "no_same_tier_match") }
        if deduped.count == 1 {
            return deduped[0].entryID == currentEntryID
                ? .current
                : .rebound(entryID: deduped[0].entryID)
        }
        if let narrowed = try await disambiguateByReading(
            deduped, input: input, lookup: lookup) {
            return narrowed.entryID == currentEntryID
                ? .current
                : .rebound(entryID: narrowed.entryID)
        }
        return .ambiguous(candidateEntryIDs: deduped.map(\.entryID))
    }

    /// 读音消歧：候选 entry 的 normalizedReadings 恰有一个包含
    /// 输入读音时返回该候选；读音缺省或与表记同 key（无增量信息）
    /// 时不做消歧返回 nil。
    private static func disambiguateByReading(
        _ matches: [TieredEntryMatch],
        input: LexemeResolutionInput,
        lookup: any DictionaryTieredLookup
    ) async throws -> TieredEntryMatch? {
        let normalizedReading = SearchTextNormalizer.normalize(input.reading ?? "")
        guard !normalizedReading.isEmpty,
              normalizedReading != SearchTextNormalizer.normalize(input.writtenForm)
        else { return nil }
        let surfaces = try await lookup.entrySurfaces(
            entryIDs: matches.map(\.entryID))
        let narrowed = matches.filter {
            surfaces[$0.entryID]?.normalizedReadings.contains(normalizedReading)
                ?? false
        }
        return narrowed.count == 1 ? narrowed[0] : nil
    }

    /// SourceContext/verifiedExisting 层验证：表记命中 +（有读音时）
    /// 读音也命中——与 `LexemeBackfillService.verify` 同口径。
    private static func verify(
        surface: DictionaryEntrySurface,
        input: LexemeResolutionInput
    ) -> Bool {
        guard surface.normalizedForms.contains(
            SearchTextNormalizer.normalize(input.writtenForm)) else { return false }
        if let reading = input.reading {
            let normalized = SearchTextNormalizer.normalize(reading)
            if !normalized.isEmpty {
                return surface.normalizedReadings.contains(normalized)
            }
        }
        return true
    }

    /// entry 去重（保留首个命中位置=最优排序位）。
    private static func dedupeByEntry(_ matches: [TieredEntryMatch])
        -> [TieredEntryMatch] {
        var seen = Set<Int64>()
        return matches.filter { seen.insert($0.entryID).inserted }
    }
}
