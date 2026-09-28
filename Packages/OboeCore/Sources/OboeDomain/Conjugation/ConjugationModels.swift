import Foundation

/// S15 活用训练域模型（需求 §13 / 技术文档 §12）。
///
/// 设计红线：
/// - 词性显式传入，`JapaneseConjugator` 不做「る结尾 → 一段」式猜测；
///   JMdict POS 缺失时由上层决定不给该词出题（`init?(jmdictTag:)` 为 nil
///   或调用方根本无 POS）。
/// - 敬体与普通体不混入同一答案集：ます系与普通形是不同 `ConjugationForm`。
/// - 规范形/缩约形/等价变体/表记变体用 `AnswerVariant` 显式标记。
/// - 纯值类型，无 IO。

/// 活用类别（出题输入）。`rawValue` 入库（snake/kebab 小写串，稳定）。
public enum ConjugationClass: String, Codable, CaseIterable, Sendable, Hashable {
    // 五段九行
    case godanU        // う行（買う）
    case godanUTou     // う行特殊 v5u-s（問う/請う系：て・た不音便 問うて）
    case godanTsu      // つ行（待つ）
    case godanRu       // る行（帰る）
    case godanRuAru    // る行特殊 v5r-i（ある系：否定=ない 整体词例外）
    case godanNu       // ぬ行（死ぬ）
    case godanBu       // ぶ行（遊ぶ）
    case godanMu       // む行（読む）
    case godanKu       // く行（書く）
    case godanKuIku    // く行特殊 v5k-s（行く：て・た促音便 行って）
    case godanGu       // ぐ行（泳ぐ）
    case godanSu       // す行（話す）
    case godanAruKeigo // 五段 -aru 系 v5aru（ござる/なさる：连用い+音便っ）
    // 一段・不规则
    case ichidan       // v1（食べる）
    case suru          // する・名詞+する（勉強する）
    case suruS         // vs-s（愛する系：未然さ/连用し）
    case kuru          // くる・来る（含 持ってくる 等复合）
    // 形容词
    case iAdjective    // い形容词（高い；いい/良い/よい 为不规则）
    case naAdjective   // な形容词（静か）

    /// JMdict POS 标签 → 活用类别。`adj-na` 不在形态 POS 枚举内，
    /// 由调用方直接选 `.naAdjective`。
    public init?(jmdictTag: JapanesePartOfSpeech) {
        switch jmdictTag {
        case .v5u: self = .godanU
        case .v5uS: self = .godanUTou
        case .v5k: self = .godanKu
        case .v5kS: self = .godanKuIku
        case .v5g: self = .godanGu
        case .v5s: self = .godanSu
        case .v5t: self = .godanTsu
        case .v5n: self = .godanNu
        case .v5b: self = .godanBu
        case .v5m: self = .godanMu
        case .v5r: self = .godanRu
        case .v5rI: self = .godanRuAru
        case .v5aru: self = .godanAruKeigo
        case .v1: self = .ichidan
        case .vs, .vsI: self = .suru
        case .vsS: self = .suruS
        case .vk: self = .kuru
        case .adjI: self = .iAdjective
        }
    }

    /// 该类别可出题的形式集合（需求 §13：动词 13 形 / 形容词 7 形）。
    public var supportedForms: Set<ConjugationForm> {
        switch self {
        case .iAdjective, .naAdjective:
            return [.past, .negative, .pastNegative, .te,
                    .conditionalBa, .conditionalTara, .volitional]
        case .godanAruKeigo:
            // 敬语 -aru 动词不取可能/被动/使役（语义上不成立）。
            return [.masu, .te, .past, .negative, .pastNegative,
                    .conditionalBa, .conditionalTara, .volitional,
                    .imperative]
        default:
            return Set(ConjugationForm.allCases)
        }
    }

    /// 出题展示名（UI 可直接用）。
    public var displayName: String {
        switch self {
        case .godanU: return "五段・う行"
        case .godanUTou: return "五段・う行特殊（問う系）"
        case .godanTsu: return "五段・つ行"
        case .godanRu: return "五段・る行"
        case .godanRuAru: return "五段・る行特殊（ある系）"
        case .godanNu: return "五段・ぬ行"
        case .godanBu: return "五段・ぶ行"
        case .godanMu: return "五段・む行"
        case .godanKu: return "五段・く行"
        case .godanKuIku: return "五段・く行特殊（行く）"
        case .godanGu: return "五段・ぐ行"
        case .godanSu: return "五段・す行"
        case .godanAruKeigo: return "五段・-aru 敬语系"
        case .ichidan: return "一段动词"
        case .suru: return "する动词"
        case .suruS: return "する动词特殊（愛する系）"
        case .kuru: return "くる动词"
        case .iAdjective: return "い形容词"
        case .naAdjective: return "な形容词"
        }
    }
}

/// 活用目标形（动词 13 + 形容词子集）。
/// `rawValue` 入库为 rule_id 的形部分，稳定不改。
public enum ConjugationForm: String, Codable, CaseIterable, Sendable, Hashable {
    case masu              // 礼貌（ます）
    case te                // て形
    case past              // 过去（た/かった/だった）
    case negative          // 否定（ない系）
    case pastNegative      // 过去否定（なかった系）
    case conditionalBa     // 条件（ば）——与 たら 显式区分
    case conditionalTara   // 条件（たら）
    case volitional        // 意志
    case imperative        // 命令
    case potential         // 可能
    case passive           // 被动
    case causative         // 使役
    case causativePassive  // 使役被动

    /// 出题展示名（如「食べる の て形」）。
    public var displayName: String {
        switch self {
        case .masu: return "ます形"
        case .te: return "て形"
        case .past: return "过去形（た）"
        case .negative: return "否定形（ない）"
        case .pastNegative: return "过去否定形（なかった）"
        case .conditionalBa: return "条件形（ば）"
        case .conditionalTara: return "条件形（たら）"
        case .volitional: return "意志形"
        case .imperative: return "命令形"
        case .potential: return "可能形"
        case .passive: return "被动形"
        case .causative: return "使役形"
        case .causativePassive: return "使役被动形"
        }
    }
}

/// 答案变体标记——「规范和缩约变体需显式标记」（技术文档 §12）。
public enum AnswerVariant: String, Codable, Sendable, Hashable {
    /// 规范形（首选答案）。
    case standard
    /// 等价规范变体（食べよ/せよ/させられる 等同样成立的书面变体）。
    case alternate
    /// 缩约形（される/れる/さす/じゃない 等——口语可接受，明确标记）。
    case contracted
    /// 表记变体（全假名/汉字互写，仅当给出了 reading 才生成）。
    case script
}

/// 单个可接受答案。
public struct AcceptedAnswer: Equatable, Hashable, Sendable {
    public let text: String
    public let variant: AnswerVariant
    /// 生成该答案的规则 id（如 `conj.v5k.potential`），入库溯源。
    public let ruleID: String

    public init(text: String, variant: AnswerVariant, ruleID: String) {
        self.text = text
        self.variant = variant
        self.ruleID = ruleID
    }
}

/// 一次正向生成的完整结果。
public struct ConjugationResult: Equatable, Sendable {
    /// 规范化后的原形表记。
    public let lemma: String
    /// 规范化后的读音（未提供为 nil）。
    public let reading: String?
    public let conjugationClass: ConjugationClass
    public let form: ConjugationForm
    /// 主规则 id（accepted[0].ruleID）。
    public let ruleID: String
    /// 全部可接受答案，primary 为首元素（`.standard` 变体）。
    public let accepted: [AcceptedAnswer]

    public init(
        lemma: String, reading: String?,
        conjugationClass: ConjugationClass, form: ConjugationForm,
        ruleID: String, accepted: [AcceptedAnswer]
    ) {
        self.lemma = lemma
        self.reading = reading
        self.conjugationClass = conjugationClass
        self.form = form
        self.ruleID = ruleID
        self.accepted = accepted
    }

    /// 首选规范答案。
    public var primary: String { accepted[0].text }
    /// 可接受答案文本集（判分用；含全部变体）。
    public var acceptedTexts: Set<String> { Set(accepted.map(\.text)) }
}

/// 活用生成错误。
public enum ConjugationError: Error, Equatable, Sendable {
    /// lemma 规范化后为空。
    case emptyLemma
    /// lemma 与声明的活用类别不匹配（如 godanKu 但词尾非 く）。
    case lemmaClassMismatch(lemma: String, expectedSuffix: String)
    /// 该类别不支持此形式（如形容词的可能形）。
    case unsupportedForm(ConjugationClass, ConjugationForm)
    /// 一段/特殊类的词干为空（如 lemma 恰为活用尾）。
    case emptyStem
}
