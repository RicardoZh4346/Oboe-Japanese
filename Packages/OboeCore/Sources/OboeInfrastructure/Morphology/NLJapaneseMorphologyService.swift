import Foundation
import os
import OboeDomain

/// v0.7.0 S07 正式实现：`JapaneseMorphologyService` 的
/// NL + Deinflector + JMdict 混合管线（spike 路线 B，S02 裁决采纳）。
///
/// 管线：`NLTokenizer(.word)` 边界 → token 分类（tokenType/数字/拉丁）
/// → 每起点有界 span 枚举（≤4 token、≤24 UTF-16、仅连续 word token）
/// → `JapaneseDeinflector` 候选（含 variant 折叠补充键）
/// → `MorphologyCandidateResolver` 一次性批量词典解析（IN-chunk，
///   无逐 token SQL）
/// → span 选择（冻结规则 a–d 的可操作化，见 `selectSpan`）
/// → `ReaderToken`（`systemTokenIndexes`/`mergedSpanUTF16`/
///   `provenance` 全量保留）。
///
/// 并发：`actor`——NaturalLanguage 的 tokenizer/tagger 实例非线程安全，
/// 所有 NL 调用在 actor 隔离内串行执行。
///
/// 能力：`tokenType` scheme 缺失时抛 `MorphologyError.capabilityMissing`
/// （不是空 lemma 的成功结果；§6.1）。script/language scheme 缺失时
/// 用 Unicode 区间启发式降级并在 provenance 记录。
///
/// 冻结 span 选择规则的可操作化（MorphologySpanBudget 文档注释 a–d）：
/// - (a) 起点可解 span 取最长；
/// - (b) 「token 级已可解」解释为**较短前缀 span 已可解**——仅当最长
///   span 的 top-1 是「弱命中」（deinflect 出的假名 lemma 只靠 readings
///   通道拼上汉字词条，如 してしまった→しる→知る）时，**≥2 token 的**
///   可解前缀胜出（して→する 优先于 してしまった→知る）；若最长 span
///   的 top-1 是强命中（exact 命中或 lemma 写形命中 forms），更长 span
///   胜出（アイスクリーム／図書館／見た→見る）；弱命中的最短前缀只
///   信多 token——单かな readings 命中噪声过大（かい→会）；
/// - (b′) 纯かな功能词（は/が/を/に…，len-1 可解）是硬边界：含它的
///   更长 span 一律否决（をして、はいい 吞并修复）；
/// - (c) 弱命中 + 多前缀可解的平局里，边界落在纯かな助动词前缀
///   （て/で/い/ます/しまっ…）的切分优先；
/// - (d) 仍平局 / 候选并列 → `resolutionStatus = .ambiguous`，
///   `lexicalKey` 留空，不自动挖词。
public actor NLJapaneseMorphologyService: JapaneseMorphologyService {

    /// 合并启发式版本（morphologyVersion 组成之二；选择规则变更 bump）。
    public static let mergeHeuristicsVersion = "1.0.0"

    /// token cache 键的 morphologyVersion：规则表版本 × 合并启发式版本。
    public nonisolated var morphologyVersion: String {
        "deinflect-\(JapaneseDeinflector.deinflectorRulesVersion)+merge-\(Self.mergeHeuristicsVersion)"
    }
    /// token cache 键的 osBuild：系统 tokenizer 随 OS 变化。
    public nonisolated var osBuild: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }
    /// 实现版本串（`JapaneseMorphologyService.implementationVersion`）。
    public nonisolated let implementationVersion: String

    /// 词典 dataset 版本（S02 协议要求 nonisolated）——首个 `tokenize`
    /// 调用后从 `MorphologyDatasetVersionProvider` 惰性回填；
    /// 未打开前为 "unopened"。
    public nonisolated var dictionaryDatasetVersion: String {
        datasetVersionLock.withLock { $0 }
    }
    private let datasetVersionLock = OSAllocatedUnfairLock(initialState: "unopened")

    private let deinflector: JapaneseDeinflector
    private let resolver: any MorphologyCandidateResolver
    private let tokenizer: any MorphologySystemTokenizer
    private let datasetVersionProvider: (any MorphologyDatasetVersionProvider)?
    private var didFetchDatasetVersion = false

    /// 生产构造：resolver 若实现 `MorphologyDatasetVersionProvider`
    /// （`GRDBMorphologyCandidateResolver` 是），dataset 版本自动回填。
    public init(
        resolver: any MorphologyCandidateResolver,
        deinflector: JapaneseDeinflector = JapaneseDeinflector(),
        implementationVersion: String = "nl-hybrid-1.0.0"
    ) {
        self.deinflector = deinflector
        self.resolver = resolver
        self.tokenizer = NaturalLanguageMorphologyTokenizer()
        self.datasetVersionProvider = resolver as? MorphologyDatasetVersionProvider
        self.implementationVersion = implementationVersion
    }

    /// 测试构造：注入 tokenizer/tag 能力 seam（fake 能力缺失、确定性边界）。
    init(
        resolver: any MorphologyCandidateResolver,
        deinflector: JapaneseDeinflector = JapaneseDeinflector(),
        tokenizer: any MorphologySystemTokenizer,
        datasetVersionProvider: (any MorphologyDatasetVersionProvider)? = nil,
        implementationVersion: String = "nl-hybrid-test"
    ) {
        self.deinflector = deinflector
        self.resolver = resolver
        self.tokenizer = tokenizer
        self.datasetVersionProvider = datasetVersionProvider
            ?? (resolver as? MorphologyDatasetVersionProvider)
        self.implementationVersion = implementationVersion
    }

    // MARK: - JapaneseMorphologyService

    public func tokenize(_ block: MorphologyBlock) async throws -> [ReaderToken] {
        try Self.checkCancellation()
        let schemes = Set(tokenizer.availableWordTagSchemes())
        let missing = Self.requiredSchemes.filter { !schemes.contains($0) }
        guard missing.isEmpty else {
            throw MorphologyError.capabilityMissing(missing: missing.joined(separator: ","))
        }

        if !didFetchDatasetVersion {
            didFetchDatasetVersion = true
            let version = (try? await datasetVersionProvider?.morphologyDatasetVersion())
                ?? "unresolved"
            datasetVersionLock.withLock { $0 = version }
        }

        let text = block.text
        let systemTokens = tokenizer.wordTokens(in: text)
        guard !systemTokens.isEmpty else { return [] }
        try Self.checkCancellation()

        // 1) 预分类：tokenType / 数字 / 拉丁字词。
        let classified = systemTokens.map { Self.classify($0) }

        // 2) span 枚举：每个 word 起点向右并 ≤4 token、≤24 UTF-16、
        //    仅连续 word token（跨越空白/标点不并入）。
        var spanJobs: [SpanJob] = []
        spanJobs.reserveCapacity(systemTokens.count)
        for start in systemTokens.indices {
            guard classified[start] == .word else { continue }
            var utf16Length = 0
            for length in 1...MorphologySpanBudget.maximumSpanTokens {
                let end = start + length - 1
                guard end < systemTokens.count else { break }
                guard classified[end] == .word else { break }
                // 连续性：上一 token 的 end 必须等于本 token 的 start
                if length > 1,
                   systemTokens[end - 1].rangeUTF16.upperBound
                       != systemTokens[end].rangeUTF16.lowerBound {
                    break
                }
                utf16Length = systemTokens[end].rangeUTF16.upperBound
                    - systemTokens[start].rangeUTF16.lowerBound
                guard utf16Length <= MorphologySpanBudget.maximumSpanUTF16Length else { break }
                let range: Range<Int> = systemTokens[start].rangeUTF16.lowerBound
                    ..< systemTokens[end].rangeUTF16.upperBound
                spanJobs.append(SpanJob(
                    startToken: start, tokenCount: length,
                    rangeUTF16: range, surface: Self.slice(text, range)
                ))
            }
        }
        try Self.checkCancellation()

        // 3) 每 span 生成 SpanCandidates（identity 键 + variant 折叠键 +
        //    deinflect 候选 + 折叠 lemma 复本）。
        let spanInputs = spanJobs.map { makeSpanInput($0) }
        let resolved = try await resolver.resolveCandidates(spanInputs)
        try Self.checkCancellation()

        // 4) 按起点索引化，应用选择规则发 token。
        var spansByStart: [Int: [(job: SpanJob, candidates: [MorphologyCandidate])]] = [:]
        for (job, candidates) in zip(spanJobs, resolved) {
            spansByStart[job.startToken, default: []].append((job, candidates))
        }

        // 功能词边界标记（冻结规则 b/c 的可操作化之一）：纯かな功能词
        // token（は/が/を/に…）且 len-1 span 可解——此类 token 不得被并入
        // 更长 span（をして/はいい/雨が降りそう 类吞并修复）。
        // 注：不能查 posCodes —— 候选在 resolver 截断到 top-5，は 的
        // prt 词条按 (cost,rank,entryID) 排序常落在截断位之后；
        // 「表记 ∈ 功能词集 + len-1 可解」是可操作化的必要条件。
        var particleBoundary = [Bool](repeating: false, count: systemTokens.count)
        for index in systemTokens.indices {
            let surface = systemTokens[index].surface
            guard Self.isPureKana(surface),
                  Self.kanaFunctionWordPieces.contains(surface),
                  let len1 = (spansByStart[index] ?? [])
                        .first(where: { $0.job.tokenCount == 1 }),
                  !len1.candidates.isEmpty
            else { continue }
            particleBoundary[index] = true
        }

        var emitted: [ReaderToken] = []
        emitted.reserveCapacity(systemTokens.count)
        var index = 0
        while index < systemTokens.count {
            try Self.checkCancellation()
            let token = systemTokens[index]
            switch classified[index] {
            case .nonLexical:
                emitted.append(makeToken(
                    surface: token.surface, range: token.rangeUTF16,
                    systemTokens: index..<(index + 1), candidates: [],
                    tokenClass: .nonLexical, status: .unresolved,
                    provenance: ["nl.word-tokenizer", "class.nonLexical"]
                ))
                index += 1
            case .outOfVocabulary:
                emitted.append(makeToken(
                    surface: token.surface, range: token.rangeUTF16,
                    systemTokens: index..<(index + 1), candidates: [],
                    tokenClass: .outOfVocabulary, status: .unresolved,
                    provenance: ["nl.word-tokenizer", "class.outOfVocabulary.nonJapaneseScript"]
                ))
                index += 1
            case .word:
                let spans = spansByStart[index] ?? []
                let selection = selectSpan(
                    spans, at: index,
                    tokens: systemTokens, particleBoundary: particleBoundary)
                switch selection {
                case let .merged(job, candidates, rule):
                    emitted.append(makeToken(
                        surface: job.surface, range: job.rangeUTF16,
                        systemTokens: index..<(index + job.tokenCount),
                        candidates: candidates,
                        tokenClass: tokenClass(
                            surface: job.surface, candidates: candidates,
                            previous: emitted.last
                        ),
                        status: nil,
                        provenance: [
                            "nl.word-tokenizer",
                            "span.merge.\(job.tokenCount)tok",
                            "deinflect.\(JapaneseDeinflector.deinflectorRulesVersion)",
                            "dict.batch",
                            rule,
                        ]
                    ))
                    index += job.tokenCount
                case .unresolvedSingle:
                    let isAux = Self.isAuxiliaryFragment(token.surface)
                    emitted.append(makeToken(
                        surface: token.surface, range: token.rangeUTF16,
                        systemTokens: index..<(index + 1), candidates: [],
                        tokenClass: isAux ? .auxiliary : .lexical,
                        status: .unresolved,
                        provenance: [
                            "nl.word-tokenizer",
                            isAux ? "class.auxiliary.kanaFragment" : "class.lexical.oov",
                        ]
                    ))
                    index += 1
                }
            }
        }
        return emitted
    }

    /// cache 键组装便捷方法（`parserVersion` 由调用方的 ReaderParser 提供）。
    public func tokenCacheKey(blockHash: String, parserVersion: String) -> TokenCacheKey {
        TokenCacheKey(
            blockHash: blockHash,
            parserVersion: parserVersion,
            morphologyVersion: morphologyVersion,
            dictionaryDatasetVersion: dictionaryDatasetVersion,
            osBuild: osBuild
        )
    }

    // MARK: - 能力要求

    /// 必需 scheme：tokenType 参与 token 分类，缺失即显式降级。
    /// （script/language 缺失走 Unicode 区间回退，不抛。）
    static let requiredSchemes: [String] = ["TokenType"]

    private static func checkCancellation() throws {
        if Task.isCancelled { throw MorphologyError.cancelled }
    }

    // MARK: - token 预分类

    private enum PreClass { case word, nonLexical, outOfVocabulary }

    private static func classify(_ token: MorphologySystemToken) -> PreClass {
        if let type = token.tokenType, type != "Word" {
            return .nonLexical   // Punctuation/Whitespace/Other（emoji 等）
        }
        let normalized = SearchTextNormalizer.normalize(token.surface)
        if isPureDigits(normalized) { return .nonLexical }
        if isLatinWord(token.surface) { return .outOfVocabulary }
        return .word
    }

    /// 独立纯数字（§7 不计分母）：规范化后全为 ASCII 数字与千分位/小数点。
    private static func isPureDigits(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        return normalized.allSatisfy {
            $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",")
        }
    }

    /// 独立英文字词（§7 OOV 计 unknown）：全 ASCII 字母（允许内部连字符/
    /// 撇号，如 Wi-Fi / don't）。
    private static func isLatinWord(_ surface: String) -> Bool {
        guard !surface.isEmpty else { return false }
        var hasLetter = false
        for scalar in surface.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                guard scalar.isASCII else { return false }
                hasLetter = true
            } else if scalar.isASCII, "-'".unicodeScalars.contains(scalar) {
                continue
            } else {
                return false
            }
        }
        return hasLetter
    }

    /// 纯かな（平假名/片假名/长音符），用于 aux 判别与折叠判断。
    private static func isPureKana(_ surface: String) -> Bool {
        !surface.isEmpty && surface.unicodeScalars.allSatisfy {
            (0x3040...0x30FF).contains($0.value) || $0 == "・" || $0 == "ー"
        }
    }

    /// 纯かな助动词前缀集（冻结规则 c）：て/で/い/ます/しまっ 类
    /// aux 链起始片段——span 平局时边界落在这些 token 前的切分优先。
    /// 粒子助词（が/も/の）也计入——它们本来就该作新 token 起点。
    static let kanaAuxPrefixPieces: Set<String> = [
        "て", "で", "い", "う", "た", "だ", "ぬ", "ず", "な", "ない",
        "よう", "よ", "ろ", "ば", "れ", "られる", "せ", "させ",
        "ます", "まし", "ませ", "ましょ", "だっ", "です", "でし", "だろ",
        "なかっ", "しまっ", "しまう", "しまい", "ちゃ", "じゃ",
        "とく", "どく", "いる", "いた", "いな", "いまし", "くる", "き",
        "きて", "くれ", "くれる", "もら", "あげ", "み", "お", "そう", "さ",
        "が", "も", "の", "を", "に", "へ", "と", "か", "は", "ながら",
        "つつ", "なさい", "こそ", "すら", "のみ", "でも", "まで", "より",
    ]

    /// 功能词边界集：这些纯かな token 若 len-1 可解即视为语法边界——
    /// span 内含（或以其为起点扩展）一律否决。
    /// て/で 不在此集（て形前缀属 aux 链内部，见 kanaAuxPrefixPieces）；
    /// なら 也不在（ならなかった 等くなら系活用内部碎片）。
    static let kanaFunctionWordPieces: Set<String> = [
        "は", "が", "を", "に", "へ", "も", "の", "と", "か", "ね", "よ",
        "ぞ", "な", "わ", "だけ", "こそ", "すら", "でも", "まで", "より",
        "ほど", "ばかり", "から", "けど", "けれど",
    ]

    /// 未解析纯かな短 token → auxiliary（助动词残段：だっ/なかっ/しまっ…）。
    /// 超过 6 个 UTF-16 单元的未解析かな按 lexical-unresolved 处理
    /// （可能是词典缺条的真词，而非活用残段）。
    private static func isAuxiliaryFragment(_ surface: String) -> Bool {
        isPureKana(surface) && surface.utf16.count <= 6
    }

    // MARK: - span 候选构造

    private struct SpanJob {
        let startToken: Int
        let tokenCount: Int
        let rangeUTF16: Range<Int>
        let surface: String
    }

    private func makeSpanInput(_ job: SpanJob) -> SpanCandidates {
        var normalizedForms = [SearchTextNormalizer.normalize(job.surface)]
        normalizedForms.append(contentsOf:
            JapaneseVariantForms.additionalNormalizedKeys(of: job.surface))
        var seen = Set<String>()
        normalizedForms = normalizedForms.filter { seen.insert($0).inserted }

        var deinflections = deinflector.candidates(for: job.surface)
        // variant 折叠 lemma 复本：髙かった→deinflect→髙い→折叠键 高い
        var folded: [DeinflectionCandidate] = []
        for candidate in deinflections where !candidate.isTruncationMarker {
            let foldedLemma = JapaneseVariantForms.folded(candidate.lemma)
            guard foldedLemma != candidate.lemma else { continue }
            folded.append(DeinflectionCandidate(
                surface: candidate.surface,
                lemma: foldedLemma,
                admissiblePOS: candidate.admissiblePOS,
                reasons: candidate.reasons + ["variant.fold"],
                cost: candidate.cost
            ))
        }
        deinflections.append(contentsOf: folded)
        return SpanCandidates(
            surface: job.surface,
            normalizedForms: normalizedForms,
            deinflections: deinflections
        )
    }

    // MARK: - span 选择（冻结规则 a–d 的可操作化）

    private enum SpanChoice {
        case merged(SpanJob, [MorphologyCandidate], rule: String)
        case unresolvedSingle
    }

    /// 候选「置信档」——用于规则 (b) 的弱命中判定：
    /// 假名 lemma 经 deinflect 推出、只靠 readings 通道拼上汉字词条的
    /// 解释为弱（してしまった→しる→知る）；exact 命中与 lemma 写形命中
    /// forms 为强。
    private static func topTier(_ candidates: [MorphologyCandidate]) -> Tier {
        guard let top = candidates.first else { return .none }
        if top.cost == 0 {
            return top.reasons.contains("exact.identity.form") ? .exactForm : .exactReading
        }
        return top.reasons.contains("deinflected.form") ? .derivedForm : .derivedReading
    }

    private enum Tier: Int, Comparable {
        case exactForm = 0
        case exactReading = 1
        case derivedForm = 2
        case derivedReading = 3
        case none = 4
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private func selectSpan(
        _ spans: [(job: SpanJob, candidates: [MorphologyCandidate])],
        at start: Int,
        tokens: [MorphologySystemToken],
        particleBoundary: [Bool]
    ) -> SpanChoice {
        // 含功能词边界 token 的更长 span 一律否决（规则 b/c 的前置
        // 可操作化：语法边界 token 不可被吞并，也不得以其扩展）。
        func crossesParticleBoundary(_ job: SpanJob) -> Bool {
            job.tokenCount > 1
                && (job.startToken..<(job.startToken + job.tokenCount))
                    .contains { particleBoundary[$0] }
        }
        let resolvable = spans.filter {
            !$0.candidates.isEmpty && !crossesParticleBoundary($0.job)
        }
        guard let longest = resolvable.max(by: { $0.job.tokenCount < $1.job.tokenCount })
        else { return .unresolvedSingle }

        // (a) 最长可解优先——除非 top-1 是弱命中且有较短可解前缀 (b)(c)。
        // 弱命中拆分的可操作化约束：前缀须为 **≥2 个 system token** 的
        // 可解 span——单かな token 的 readings 命中噪声大（かい→会、
        // し→市…），真前缀（して／行って／持って…）在 NL 边界上必然
        // 是多 token 连用/て形。否则 かいた→かく→書く 会被拆成
        // かい|た 垃圾、できない→できる 会丢 できる。
        if Self.topTier(longest.candidates) == .derivedReading {
            let prefixes = resolvable.filter {
                $0.job.tokenCount < longest.job.tokenCount && $0.job.tokenCount >= 2
            }
            if !prefixes.isEmpty {
                // (c) 边界落在纯かな助动词前缀 token 前的切分优先；
                //     再取最长前缀；仍平取 top tier 最优、最短。
                let auxBoundary = prefixes.filter {
                    let boundaryToken = start + $0.job.tokenCount
                    return boundaryToken < tokens.count
                        && Self.kanaAuxPrefixPieces.contains(tokens[boundaryToken].surface)
                        && Self.isPureKana(tokens[boundaryToken].surface)
                }
                let pool = auxBoundary.isEmpty ? prefixes : auxBoundary
                if let choice = pool.max(by: { lhs, rhs in
                    if lhs.job.tokenCount != rhs.job.tokenCount {
                        return lhs.job.tokenCount < rhs.job.tokenCount
                    }
                    return Self.topTier(lhs.candidates) > Self.topTier(rhs.candidates)
                }) {
                    return .merged(choice.job, choice.candidates,
                                   rule: "select.rule-b-c.splitAtAux")
                }
            }
        }
        return .merged(longest.job, longest.candidates,
                       rule: "select.rule-a.longestResolvable")
    }

    // MARK: - ReaderToken 装配

    private func tokenClass(
        surface: String,
        candidates: [MorphologyCandidate],
        previous: ReaderToken?
    ) -> ReaderTokenClass {
        // 已解析かな token：top 候选词性全属 aux 家族，或紧跟て/で形且
        // 候选含 aux-v/aux-adj → auxiliary（动词 target + aux token 分计）。
        guard Self.isPureKana(surface) else { return .lexical }
        let auxPOS: Set<String> = ["aux", "aux-v", "aux-adj", "aux-n", "cop"]
        let posUnion = Set(candidates.flatMap(\.posCodes))
        if !posUnion.isEmpty, posUnion.isSubset(of: auxPOS) { return .auxiliary }
        if let previous,
           previous.tokenClass == .lexical || previous.tokenClass == .auxiliary,
           previous.surface.hasSuffix("て") || previous.surface.hasSuffix("で") {
            // aux-v/aux-adj 词性直接佐证；
            if !posUnion.isDisjoint(with: ["aux-v", "aux-adj"]) {
                return .auxiliary
            }
            // 或 lemma 命中常见补助动词集（JMdict 的 しまう/もらう 只标 v5，
            // 不标 aux-v——て形后续段按补助动词分计）。
            if candidates.contains(where: { Self.auxiliaryLemmas.contains($0.lemma) }) {
                return .auxiliary
            }
        }
        return .lexical
    }

    /// て/で形后的补助动词 lemma 集（词典未标 aux 词性的常规补助动词）。
    static let auxiliaryLemmas: Set<String> = [
        "いる", "いく", "くる", "おく", "しまう", "もらう", "くれる", "あげる",
        "みる", "おる", "ある", "くださる", "やる", "いただく", "いらっしゃる",
        "居る", "行く", "来る", "置く", "仕舞う", "貰う", "呉れる", "挙げる",
        "見る", "為る", "下さる", "遣る", "頂く",
    ]

    private func makeToken(
        surface: String,
        range: Range<Int>,
        systemTokens: Range<Int>,
        candidates: [MorphologyCandidate],
        tokenClass: ReaderTokenClass,
        status: TokenResolutionStatus?,
        provenance: [String]
    ) -> ReaderToken {
        let resolved = status ?? (candidates.count == 1 ? .resolved : .ambiguous)
        let top = candidates.first
        // lexicalKey 只在高置信单候选时回填（§6.2：不按概率自动挖词）。
        let lexicalKey: LexicalKey? = {
            guard resolved == .resolved, let entryID = top?.entryID else { return nil }
            // S08 起统一走 `LexicalIdentityKey`——reader token 与 Note
            // 回填产出同一 identity_key 编码，否则 lexemes 会分裂。
            return LexicalIdentityKey.jmdict(
                entryID: entryID,
                normalizedForm: top?.normalizedForm ?? "",
                reading: top?.reading
            )
        }()
        // 活用形 token 的实际读音无来源——只在 exact 命中时回填候选读音
        // （此时候选读音≈token 实际读音），派生命中的 lemma 读音不回填。
        let reading = (top?.cost == 0) ? top?.reading : nil
        return ReaderToken(
            surface: surface,
            sourceRangeUTF16: range,
            mergedSpanUTF16: range,
            systemTokenIndexes: systemTokens,
            candidates: candidates,
            tokenClass: tokenClass,
            reading: reading,
            lexicalKey: lexicalKey,
            resolutionStatus: resolved,
            provenance: provenance
        )
    }

    // MARK: - 工具

    private static func slice(_ text: String, _ utf16Range: Range<Int>) -> String {
        let start = text.utf16.index(
            text.utf16.startIndex, offsetBy: utf16Range.lowerBound
        )
        let end = text.utf16.index(
            text.utf16.startIndex, offsetBy: utf16Range.upperBound
        )
        return String(text[start..<end])
    }
}
