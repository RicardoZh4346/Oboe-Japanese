import Foundation

/// 五段九行活用元数据——`JapaneseDeinflector`（反向还原）与
/// `JapaneseConjugator`（正向生成，S15）共享的同一张审查表。
///
/// 列含义：a=未然形 i=連用形 e=仮定・命令形 o=推量形，
/// stem=音便干（て・た前：っ/ん/い/し），teEnd/taEnd=て・た系后缀
/// （清浊），contract=てしまう缩约段（ちゃ/じゃ）。
/// 任一字段变更同时影响双向规则，须同步评估 deinflector 的
/// `deinflectorRulesVersion` 与 conjugator 的 `conjugatorRulesVersion`。
public struct GodanConjugationRow: Equatable, Hashable, Sendable {
    /// 行标识（"u" "t" "r" "n" "b" "m" "k" "g" "s"），规则 id 组成。
    public let id: String
    /// 词尾假名（う・つ・る / ぬ・ぶ・む / く・ぐ / す）。
    public let lemma: String
    /// 该行对应的 JMdict 词性集合（含特殊行 -s/-i）。
    public let pos: Set<JapanesePartOfSpeech>
    public let a: String
    public let i: String
    public let e: String
    public let o: String
    public let stem: String
    public let teEnd: String
    public let taEnd: String
    public let contract: String

    public init(
        id: String, lemma: String, pos: Set<JapanesePartOfSpeech>,
        a: String, i: String, e: String, o: String,
        stem: String, teEnd: String, taEnd: String, contract: String
    ) {
        self.id = id
        self.lemma = lemma
        self.pos = pos
        self.a = a
        self.i = i
        self.e = e
        self.o = o
        self.stem = stem
        self.teEnd = teEnd
        self.taEnd = taEnd
        self.contract = contract
    }
}

public enum GodanConjugationTable {
    /// 审查过的五段九行数据（与 `JapaneseDeinflector.defaultRules`
    /// 的词干/音便定义同源）。
    public static let rows: [GodanConjugationRow] = [
        GodanConjugationRow(
            id: "u", lemma: "う", pos: [.v5u, .v5uS],
            a: "わ", i: "い", e: "え", o: "お",
            stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ"),
        GodanConjugationRow(
            id: "t", lemma: "つ", pos: [.v5t],
            a: "た", i: "ち", e: "て", o: "と",
            stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ"),
        GodanConjugationRow(
            id: "r", lemma: "る", pos: [.v5r, .v5rI],
            a: "ら", i: "り", e: "れ", o: "ろ",
            stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ"),
        GodanConjugationRow(
            id: "n", lemma: "ぬ", pos: [.v5n],
            a: "な", i: "に", e: "ね", o: "の",
            stem: "ん", teEnd: "で", taEnd: "だ", contract: "じゃ"),
        GodanConjugationRow(
            id: "b", lemma: "ぶ", pos: [.v5b],
            a: "ば", i: "び", e: "べ", o: "ぼ",
            stem: "ん", teEnd: "で", taEnd: "だ", contract: "じゃ"),
        GodanConjugationRow(
            id: "m", lemma: "む", pos: [.v5m],
            a: "ま", i: "み", e: "め", o: "も",
            stem: "ん", teEnd: "で", taEnd: "だ", contract: "じゃ"),
        GodanConjugationRow(
            id: "k", lemma: "く", pos: [.v5k, .v5kS],
            a: "か", i: "き", e: "け", o: "こ",
            stem: "い", teEnd: "て", taEnd: "た", contract: "ちゃ"),
        GodanConjugationRow(
            id: "g", lemma: "ぐ", pos: [.v5g],
            a: "が", i: "ぎ", e: "げ", o: "ご",
            stem: "い", teEnd: "で", taEnd: "だ", contract: "じゃ"),
        GodanConjugationRow(
            id: "s", lemma: "す", pos: [.v5s],
            a: "さ", i: "し", e: "せ", o: "そ",
            stem: "し", teEnd: "て", taEnd: "た", contract: "ちゃ"),
    ]

    /// v5aru（ござる・なさる・いらっしゃる系）：连用形为 い、音便为 っ，
    /// 未然/仮定/推量与る行相同（ら/れ/ろ）。不进 `rows`——deinflector
    /// 侧尚无 v5aru 行级还原规则（见 s15 文档「已知反向覆盖洞」）。
    public static let keigoAruRow = GodanConjugationRow(
        id: "aru", lemma: "る", pos: [.v5aru],
        a: "ら", i: "い", e: "れ", o: "ろ",
        stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ")
}
