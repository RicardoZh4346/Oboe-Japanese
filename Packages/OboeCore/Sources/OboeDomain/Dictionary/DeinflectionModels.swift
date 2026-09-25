import Foundation

/// JMdict 风格的粗粒度词性标签（冻结协议 §2.4）。
///
/// `rawValue` 直接采用 JMdict POS tag，词典侧可用 `sense_pos` 里的真实
/// 标签做交集过滤：例如「高かった」会同时推出 高い{adj-i} 与 かう{v5u}
/// 两个候选，前者不会命中动词词条，后者由词典按词条存在性裁掉。
public enum JapanesePartOfSpeech: String, Codable, CaseIterable, Hashable, Sendable, Comparable {
    // 五段动词各行（う・つ・る / ぬ・ぶ・む / く・ぐ / す）
    case v5u = "v5u"      // う行（買う）
    case v5k = "v5k"      // く行（書く）
    case v5g = "v5g"      // ぐ行（泳ぐ）
    case v5s = "v5s"      // す行（話す）
    case v5t = "v5t"      // つ行（待つ）
    case v5n = "v5n"      // ぬ行（死ぬ）
    case v5b = "v5b"      // ぶ行（遊ぶ）
    case v5m = "v5m"      // む行（読む）
    case v5r = "v5r"      // る行（分かる）
    case v5rI = "v5r-i"   // る行特殊（ある／なさる／いらっしゃる系）
    case v5kS = "v5k-s"   // く行特殊（行く：て・た为促音便「行って／行った」）
    case v5uS = "v5u-s"   // う行特殊（問う／訪う：て・た不音便「問うて」）
    case v5aru = "v5aru"  // 五段 -aru 系
    // 一段・不规则
    case v1 = "v1"        // 一段（食べる）
    case vk = "vk"        // くる（来る）
    case vs = "vs"        // 名词+する（勉強する）
    case vsI = "vs-i"     // する本体
    case vsS = "vs-s"     // する特殊（愛する系）
    // い形容词
    case adjI = "adj-i"   // い形容词（高い）

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 全部动词类标签。凡产生「X+る」形态的规则一律输出该集合：
    /// 产生式既可能是一段原形（食べる），也可能是五段／する／くる
    /// 经未然形+助动词派生的中间形（行かされる←行く），须留给后续
    /// 规则继续还原，词性收窄交给终端规则与词典侧过滤完成。
    public static let verbClasses: Set<JapanesePartOfSpeech> = [
        .v5u, .v5k, .v5g, .v5s, .v5t, .v5n, .v5b, .v5m, .v5r,
        .v5rI, .v5kS, .v5uS, .v5aru, .v1, .vk, .vs, .vsI, .vsS
    ]
}

/// 变形还原候选（冻结协议 §2.4 wire spec）。
/// Deinflector 只负责 surface → candidate lemma；是否存在、如何排序
/// 由词典侧结合 admissiblePOS 与词条数据裁决。
public struct DeinflectionCandidate: Equatable, Hashable, Sendable {
    /// 规范化后的查询表记（与 DictionarySearchRequest.normalizedQuery 一致）
    public let surface: String
    /// 候选原形
    public let lemma: String
    /// 该还原路径下原形允许的词性集合（JMdict 风格标签）
    public let admissiblePOS: Set<JapanesePartOfSpeech>
    /// 变形原因链，按规则套用顺序排列（原形候选为空数组）
    public let reasons: [String]
    /// 排序成本：规则成本沿还原路径累加，原形为 0，越小越靠前
    public let cost: Int
    /// 预算截断标记：true 时本条不是真实候选，仅表示搜索在预算内
    /// 未穷尽可能性（达到 maxDepth/maxStates 上限时追加在数组末尾）。
    public let isTruncationMarker: Bool

    public init(
        surface: String,
        lemma: String,
        admissiblePOS: Set<JapanesePartOfSpeech>,
        reasons: [String],
        cost: Int,
        isTruncationMarker: Bool = false
    ) {
        self.surface = surface
        self.lemma = lemma
        self.admissiblePOS = admissiblePOS
        self.reasons = reasons
        self.cost = cost
        self.isTruncationMarker = isTruncationMarker
    }
}

/// 单条还原规则（自写规则表，语法依据见 JapaneseDeinflector 文件头注释）。
/// 套用方向：surface 词尾 suffix → 剥去后补上 replacement，得到更靠
/// 近原形的中间形或原形。例如 食べなかった --[なかった→る]--> 食べる。
public struct DeinflectionRule: Equatable, Hashable, Sendable {
    /// 稳定标识，如 "v5u.te" / "v1.causativePassive"
    public let id: String
    /// 当前词形必须以此结尾才考虑套用
    public let suffix: String
    /// 剥去 suffix 后补上的串（可为空串）
    public let replacement: String
    /// 输入词性集合：当前状态的 admissiblePOS 须与其相交才可套用
    public let fromPOS: Set<JapanesePartOfSpeech>
    /// 输出词性集合：产生的下一状态的 admissiblePOS
    public let toPOS: Set<JapanesePartOfSpeech>
    /// 变形原因（进入候选的 reasons 链）
    public let reason: String
    /// 规则成本，沿路径累加进候选 cost
    public let cost: Int
    /// true 时仅当整个词形恰好等于 suffix 才套用（明示例外用，
    /// 防止「いい→よい」误伤「かわいい」等合法词）
    public let wholeForm: Bool

    public init(
        id: String,
        suffix: String,
        replacement: String,
        fromPOS: Set<JapanesePartOfSpeech>,
        toPOS: Set<JapanesePartOfSpeech>,
        reason: String,
        cost: Int = 1,
        wholeForm: Bool = false
    ) {
        self.id = id
        self.suffix = suffix
        self.replacement = replacement
        self.fromPOS = fromPOS
        self.toPOS = toPOS
        self.reason = reason
        self.cost = cost
        self.wholeForm = wholeForm
    }
}

/// `JapaneseDeinflector.analyze` 的完整结果（比冻结协议接口多暴露
/// 调试/测试所需的元信息）。
public struct DeinflectionResult: Equatable, Sendable {
    /// 原始输入
    public let surface: String
    /// 规范化后的查询串（复用 SearchTextNormalizer）
    public let normalizedQuery: String
    /// 候选列表（固定排序，不含截断标记）
    public let candidates: [DeinflectionCandidate]
    /// 是否因预算（maxStates）耗尽而提前截断
    public let isTruncated: Bool
    /// 实际展开的状态数（≤ maxStates）
    public let expandedStates: Int

    public init(
        surface: String,
        normalizedQuery: String,
        candidates: [DeinflectionCandidate],
        isTruncated: Bool,
        expandedStates: Int
    ) {
        self.surface = surface
        self.normalizedQuery = normalizedQuery
        self.candidates = candidates
        self.isTruncated = isTruncated
        self.expandedStates = expandedStates
    }
}

/// 冻结契约（§2.4，不可改）：
/// `candidates(for:) -> [DeinflectionCandidate]`（深度≤8，状态≤128，含截断标记）
public protocol Deinflecting: Sendable {
    func candidates(for surface: String) -> [DeinflectionCandidate]
}
