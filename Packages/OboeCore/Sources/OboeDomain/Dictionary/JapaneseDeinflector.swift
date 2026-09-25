import Foundation

/// 有界日语变形还原器（S03 / 技术文档 §5、需求 §8）。
///
/// 纯 Swift、确定性、有界候选搜索：
/// - 状态为 `(form, admissiblePOS, depth, reasons)`，广度优先展开；
/// - visited 键 = `form + 词性集合`，即同一字符串带不同词性状态会分别
///   探索（例如 食べたい{adj-i} 可继续推 食べる，而动词中间形不行）；
/// - 预算：maxDepth = 8、maxStates = 128，耗尽即置截断标记返回，
///   不崩溃、不无限递归；
/// - 原形本身作为零成本候选始终保留；所有派生形也作为候选输出，
///   是否真实存在、选用哪条解释由词典侧用 JMdict POS 交集过滤裁决
///   （「食べられる」的可能／被动／尊敬各自成候选，不做语义消歧）。
///
/// 规则为自写规则表（`defaultRules`），按活用类型分组，语法依据：
/// 五段九行各自的未然形(a)/連用形(i)/仮定・命令形(e)/推量形(o)/音便形，
/// 一段・する・くる・い形容词各活用，以及明示例外（行っ系、いい→よい）。
/// 半角片假名・全角输入经 `SearchTextNormalizer` 与全 App 同一规范化。
public struct JapaneseDeinflector: Deinflecting {
    /// 冻结预算（技术文档 §5.1）
    public static let defaultMaxDepth = 8
    public static let defaultMaxStates = 128

    private let maxDepth: Int
    private let maxStates: Int
    private let rules: [DeinflectionRule]

    /// 搜索状态：(form, admissiblePOS, depth, reasons) + 累计成本
    private struct SearchState {
        var form: String
        var pos: Set<JapanesePartOfSpeech>
        var depth: Int
        var reasons: [String]
        var cost: Int
    }

    public init(
        maxDepth: Int = JapaneseDeinflector.defaultMaxDepth,
        maxStates: Int = JapaneseDeinflector.defaultMaxStates,
        rules: [DeinflectionRule] = JapaneseDeinflector.defaultRules
    ) {
        self.maxDepth = max(0, maxDepth)
        self.maxStates = max(1, maxStates)
        self.rules = rules
    }

    // MARK: - 冻结契约

    /// surface → 候选列表（固定排序）。搜索被预算截断时在末尾追加
    /// `isTruncationMarker == true` 的标记候选，词典侧应跳过该条。
    public func candidates(for surface: String) -> [DeinflectionCandidate] {
        let result = analyze(surface)
        guard result.isTruncated else { return result.candidates }
        return result.candidates + [
            DeinflectionCandidate(
                surface: result.normalizedQuery,
                lemma: "",
                admissiblePOS: [],
                reasons: ["search.truncated"],
                cost: Int.max,
                isTruncationMarker: true
            )
        ]
    }

    // MARK: - 有界搜索

    /// 完整分析入口：返回候选 + 截断/预算元信息，供调试与测试。
    public func analyze(_ surface: String) -> DeinflectionResult {
        // 与 KnowledgeSearch 同一规范化：trim、兼容映射（半角→全角片假名）、
        // 小写、片假名→平假名、canonical precompose。
        let normalized = SearchTextNormalizer.normalize(surface)
        guard !normalized.isEmpty else {
            return DeinflectionResult(
                surface: surface,
                normalizedQuery: "",
                candidates: [],
                isTruncated: false,
                expandedStates: 0
            )
        }

        let allPOS = Set(JapanesePartOfSpeech.allCases)
        var visited: Set<String> = [visitKey(normalized, allPOS)]
        var queue: [SearchState] = [
            SearchState(form: normalized, pos: allPOS, depth: 0, reasons: [], cost: 0)
        ]
        // 原形本身：零成本、无原因链、全词性（交词典判定真实词性）
        var candidates: [DeinflectionCandidate] = [
            DeinflectionCandidate(
                surface: normalized,
                lemma: normalized,
                admissiblePOS: allPOS,
                reasons: [],
                cost: 0
            )
        ]
        var cheapestByKey: [String: Int] = [:]   // 去重键 → candidates 下标
        var expandedStates = 0
        var isTruncated = false
        var head = 0

        while head < queue.count {
            if expandedStates >= maxStates {
                isTruncated = true
                break
            }
            let state = queue[head]
            head += 1
            expandedStates += 1

            for rule in rules {
                // 词性门控 + 词尾匹配；wholeForm 例外要求整词相等
                guard !state.pos.isDisjoint(with: rule.fromPOS),
                      state.form.hasSuffix(rule.suffix) else { continue }
                if rule.wholeForm, state.form != rule.suffix { continue }

                let stem = String(state.form.dropLast(rule.suffix.count))
                let nextForm = stem + rule.replacement
                // 防空形、防自循环
                guard !nextForm.isEmpty, nextForm != state.form else { continue }

                let next = SearchState(
                    form: nextForm,
                    pos: rule.toPOS,
                    depth: state.depth + 1,
                    reasons: state.reasons + [rule.reason],
                    cost: state.cost + rule.cost
                )
                // 候选先于 visited 发射：不同规则可产出同 (form,pos) 但
                // reasons 不同的多条解释（食べられる→食べる 的可能/被动/尊敬），
                // visited 只负责剪枝重复展开，不负责合并候选。
                let candidate = DeinflectionCandidate(
                    surface: normalized,
                    lemma: nextForm,
                    admissiblePOS: next.pos,
                    reasons: next.reasons,
                    cost: next.cost
                )
                let dedupKey = dedupKey(of: candidate)
                if let idx = cheapestByKey[dedupKey] {
                    if candidate.cost < candidates[idx].cost {
                        candidates[idx] = candidate
                    }
                } else {
                    cheapestByKey[dedupKey] = candidates.count
                    candidates.append(candidate)
                }
                // visited 键含词性状态；已见状态不再入队。
                // 深度预算：达到 maxDepth 的形仍可作候选，但不再展开。
                let key = visitKey(nextForm, rule.toPOS)
                if next.depth < maxDepth, visited.insert(key).inserted {
                    queue.append(next)
                }
            }
        }
        if head < queue.count {
            isTruncated = true
        }

        // 固定排序：成本 → lemma → 词性键 → 原因链，保证重复调用一致
        candidates.sort { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            if lhs.lemma != rhs.lemma { return lhs.lemma < rhs.lemma }
            let lp = posKey(lhs.admissiblePOS), rp = posKey(rhs.admissiblePOS)
            if lp != rp { return lp < rp }
            return lhs.reasons.joined(separator: "→") < rhs.reasons.joined(separator: "→")
        }
        return DeinflectionResult(
            surface: surface,
            normalizedQuery: normalized,
            candidates: candidates,
            isTruncated: isTruncated,
            expandedStates: expandedStates
        )
    }

    private func visitKey(_ form: String, _ pos: Set<JapanesePartOfSpeech>) -> String {
        // visited 键必须含词性状态：同形不同词性走不同分支
        form + "\u{1F}" + posKey(pos)
    }

    private func posKey(_ pos: Set<JapanesePartOfSpeech>) -> String {
        pos.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func dedupKey(of candidate: DeinflectionCandidate) -> String {
        candidate.lemma
            + "\u{1F}" + posKey(candidate.admissiblePOS)
            + "\u{1F}" + candidate.reasons.joined(separator: "\u{1E}")
    }

    // MARK: - 自写规则表

    /// 规则组总览（id 前缀）：v5[行].活用 / v1 / vs / vk / adj / exc。
    /// 同一后缀可对应多条规则（如 られる→る 的可能／被动／尊敬），
    /// 产出 lemma 相同但 reasons 不同的多个候选。
    public static let defaultRules: [DeinflectionRule] = buildDefaultRules()

    private static func buildDefaultRules() -> [DeinflectionRule] {
        var rules: [DeinflectionRule] = []
        func add(
            _ id: String,
            _ suffix: String,
            _ replacement: String,
            _ from: Set<JapanesePartOfSpeech>,
            _ to: Set<JapanesePartOfSpeech>,
            _ reason: String,
            cost: Int = 1,
            wholeForm: Bool = false
        ) {
            rules.append(DeinflectionRule(
                id: id, suffix: suffix, replacement: replacement,
                fromPOS: from, toPOS: to, reason: reason,
                cost: cost, wholeForm: wholeForm
            ))
        }

        let all = Set(JapanesePartOfSpeech.allCases)
        let verbs = JapanesePartOfSpeech.verbClasses
        let adjOnly: Set<JapanesePartOfSpeech> = [.adjI]
        let vsPOS: Set<JapanesePartOfSpeech> = [.vs, .vsI, .vsS]

        // MARK: 五段九行
        // 活用形表：a=未然 i=連用 e=仮定/命令 o=推量 stem=音便干(て・た前)
        struct Row {
            let id: String      // "u" "k" ...
            let lemma: String   // う く ...
            let pos: Set<JapanesePartOfSpeech>
            let a, i, e, o, stem, teEnd, taEnd, contract: String
        }
        let rows: [Row] = [
            Row(id: "u", lemma: "う", pos: [.v5u, .v5uS],
                a: "わ", i: "い", e: "え", o: "お",
                stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ"),
            Row(id: "t", lemma: "つ", pos: [.v5t],
                a: "た", i: "ち", e: "て", o: "と",
                stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ"),
            Row(id: "r", lemma: "る", pos: [.v5r, .v5rI],
                a: "ら", i: "り", e: "れ", o: "ろ",
                stem: "っ", teEnd: "て", taEnd: "た", contract: "ちゃ"),
            Row(id: "n", lemma: "ぬ", pos: [.v5n],
                a: "な", i: "に", e: "ね", o: "の",
                stem: "ん", teEnd: "で", taEnd: "だ", contract: "じゃ"),
            Row(id: "b", lemma: "ぶ", pos: [.v5b],
                a: "ば", i: "び", e: "べ", o: "ぼ",
                stem: "ん", teEnd: "で", taEnd: "だ", contract: "じゃ"),
            Row(id: "m", lemma: "む", pos: [.v5m],
                a: "ま", i: "み", e: "め", o: "も",
                stem: "ん", teEnd: "で", taEnd: "だ", contract: "じゃ"),
            Row(id: "k", lemma: "く", pos: [.v5k, .v5kS],
                a: "か", i: "き", e: "け", o: "こ",
                stem: "い", teEnd: "て", taEnd: "た", contract: "ちゃ"),
            Row(id: "g", lemma: "ぐ", pos: [.v5g],
                a: "が", i: "ぎ", e: "げ", o: "ご",
                stem: "い", teEnd: "で", taEnd: "だ", contract: "じゃ"),
            Row(id: "s", lemma: "す", pos: [.v5s],
                a: "さ", i: "し", e: "せ", o: "そ",
                stem: "し", teEnd: "て", taEnd: "た", contract: "ちゃ"),
        ]
        for row in rows {
            let pos = row.pos
            let char = row.lemma
            // 連用形 + ます系 / 愿望 / 副助詞
            add("v5\(row.id).masu", row.i + "ます", char, pos, pos, "礼貌（ます）")
            add("v5\(row.id).mashita", row.i + "ました", char, pos, pos, "礼貌·过去（ました）")
            add("v5\(row.id).masen", row.i + "ません", char, pos, pos, "礼貌·否定（ません）")
            add("v5\(row.id).masendeshita", row.i + "ませんでした", char, pos, pos, "礼貌·过去否定（ませんでした）")
            add("v5\(row.id).mashou", row.i + "ましょう", char, pos, pos, "礼貌·意志（ましょう）")
            add("v5\(row.id).tai", row.i + "たい", char, pos, pos, "愿望（たい）")
            add("v5\(row.id).takatta", row.i + "たかった", char, pos, pos, "愿望·过去（たかった）")
            add("v5\(row.id).takunai", row.i + "たくない", char, pos, pos, "愿望·否定（たくない）")
            add("v5\(row.id).takunakatta", row.i + "たくなかった", char, pos, pos, "愿望·过去否定（たくなかった）")
            add("v5\(row.id).nagara", row.i + "ながら", char, pos, pos, "并行（ながら）")
            add("v5\(row.id).tsutsu", row.i + "つつ", char, pos, pos, "并行（つつ）")
            add("v5\(row.id).sugiru", row.i + "すぎる", char, pos, pos, "过量（すぎる）")
            // 音便て・た・たら・ても
            add("v5\(row.id).te", row.stem + row.teEnd, char, pos, pos, "て形（\(row.stem)\(row.teEnd)）")
            add("v5\(row.id).ta", row.stem + row.taEnd, char, pos, pos, "过去（\(row.stem)\(row.taEnd)）")
            add("v5\(row.id).tara", row.stem + row.taEnd + "ら", char, pos, pos, "条件（たら）")
            add("v5\(row.id).temo", row.stem + row.teEnd + "も", char, pos, pos, "让步（ても）")
            // てしまう缩约（っちゃ／んじゃ／いちゃ／しちゃ）
            add("v5\(row.id).chau", row.stem + row.contract + "う", char, pos, pos, "てしまう缩约", cost: 2)
            add("v5\(row.id).chatta", row.stem + row.contract + "った", char, pos, pos, "てしまう缩约·过去", cost: 2)
            add("v5\(row.id).chatte", row.stem + row.contract + "って", char, pos, pos, "てしまう缩约·て形", cost: 2)
            // ておく缩约（っとく 等）
            add("v5\(row.id).toku", row.stem + "とく", char, pos, pos, "ておく缩约", cost: 2)
            // ている 链：て形本体（って/んで/いて/いで/して）+ いる系
            let te = row.stem + row.teEnd
            add("v5\(row.id).teiru", te + "いる", char, pos, pos, "进行（ている）")
            add("v5\(row.id).teru", te + "る", char, pos, pos, "进行·缩约（てる）", cost: 2)
            add("v5\(row.id).teita", te + "いた", char, pos, pos, "进行·过去（ていた）")
            add("v5\(row.id).teinai", te + "いない", char, pos, pos, "进行·否定（ていない）")
            add("v5\(row.id).teinakatta", te + "いなかった", char, pos, pos, "进行·过去否定（ていなかった）")
            add("v5\(row.id).teimasu", te + "います", char, pos, pos, "进行·礼貌（ています）")
            add("v5\(row.id).teimasen", te + "いません", char, pos, pos, "进行·礼貌否定（ていません）")
            add("v5\(row.id).teimasendeshita", te + "いませんでした", char, pos, pos, "进行·礼貌过去否定（ていませんでした）")
            add("v5\(row.id).tekuru", te + "くる", char, pos, pos, "趋向（てくる）")
            add("v5\(row.id).tekita", te + "きた", char, pos, pos, "趋向·过去（てきた）")
            add("v5\(row.id).tehoshii", te + "ほしい", char, pos, pos, "希望（てほしい）")
            // 未然形 + 助动词
            add("v5\(row.id).nai", row.a + "ない", char, pos, pos, "否定（ない）")
            add("v5\(row.id).nakatta", row.a + "なかった", char, pos, pos, "否定·过去（なかった）")
            add("v5\(row.id).nu", row.a + "ぬ", char, pos, pos, "否定（ぬ）")
            add("v5\(row.id).zu", row.a + "ず", char, pos, pos, "否定（ず）")
            add("v5\(row.id).zuni", row.a + "ずに", char, pos, pos, "否定（ずに）")
            add("v5\(row.id).reru", row.a + "れる", char, pos, pos, "被动（れる）")
            add("v5\(row.id).seru", row.a + "せる", char, pos, pos, "使役（せる）")
            add("v5\(row.id).su", row.a + "す", char, pos, pos, "使役·短形（す）")
            add("v5\(row.id).serareru", row.a + "せられる", char, pos, pos, "使役被动（せられる）")
            add("v5\(row.id).sareru", row.a + "される", char, pos, pos, "使役被动·短形（される）")
            // 仮定・命令・可能（e 干）、意志（o 干）
            add("v5\(row.id).ba", row.e + "ば", char, pos, pos, "条件（ば）")
            add("v5\(row.id).imperative", row.e, char, pos, pos, "命令")
            add("v5\(row.id).potential", row.e + "る", char, pos, pos, "可能")
            add("v5\(row.id).volitional", row.o + "う", char, pos, pos, "意志")
        }
        // う行非音便て・た（問う→問うて/問うた，v5u-s 亦走此路）
        add("v5u.te.nonEuphonic", "うて", "う", [.v5u, .v5uS], [.v5u, .v5uS], "て形（うて）")
        add("v5u.ta.nonEuphonic", "うた", "う", [.v5u, .v5uS], [.v5u, .v5uS], "过去（うた）")

        // MARK: 一段（v1）——派生中间形也按一段活用，from 取全部动词
        add("v1.masu", "ます", "る", verbs, verbs, "礼貌（ます）")
        add("v1.mashita", "ました", "る", verbs, verbs, "礼貌·过去（ました）")
        add("v1.masen", "ません", "る", verbs, verbs, "礼貌·否定（ません）")
        add("v1.masendeshita", "ませんでした", "る", verbs, verbs, "礼貌·过去否定（ませんでした）")
        add("v1.mashou", "ましょう", "る", verbs, verbs, "礼貌·意志（ましょう）")
        add("v1.te", "て", "る", verbs, verbs, "て形（て）")
        add("v1.ta", "た", "る", verbs, verbs, "过去（た）")
        add("v1.tara", "たら", "る", verbs, verbs, "条件（たら）")
        add("v1.temo", "ても", "る", verbs, verbs, "让步（ても）")
        add("v1.nagara", "ながら", "る", verbs, verbs, "并行（ながら）")
        add("v1.tsutsu", "つつ", "る", verbs, verbs, "并行（つつ）")
        add("v1.sugiru", "すぎる", "る", verbs, verbs, "过量（すぎる）")
        add("v1.teshimau", "てしまう", "る", verbs, verbs, "てしまう")
        add("v1.teshimatta", "てしまった", "る", verbs, verbs, "てしまう·过去")
        add("v1.chau", "ちゃう", "る", verbs, verbs, "てしまう缩约", cost: 2)
        add("v1.chatta", "ちゃった", "る", verbs, verbs, "てしまう缩约·过去", cost: 2)
        add("v1.chatte", "ちゃって", "る", verbs, verbs, "てしまう缩约·て形", cost: 2)
        add("v1.toku", "とく", "る", verbs, verbs, "ておく缩约", cost: 2)
        add("v1.nai", "ない", "る", verbs, verbs, "否定（ない）")
        add("v1.nakatta", "なかった", "る", verbs, verbs, "否定·过去（なかった）")
        add("v1.nu", "ぬ", "る", verbs, verbs, "否定（ぬ）")
        add("v1.zu", "ず", "る", verbs, verbs, "否定（ず）")
        add("v1.zuni", "ずに", "る", verbs, verbs, "否定（ずに）")
        add("v1.ba", "れば", "る", verbs, verbs, "条件（ば）")
        add("v1.volitional", "よう", "る", verbs, verbs, "意志")
        add("v1.imperativeRo", "ろ", "る", verbs, verbs, "命令（ろ）")
        add("v1.imperativeYo", "よ", "る", verbs, verbs, "命令（よ）")
        // られる：可能／被动／尊敬三解，各自成候选（需求 §8.3，不做语义消歧）
        add("v1.potential", "られる", "る", verbs, verbs, "可能（られる）")
        add("v1.passive", "られる", "る", verbs, verbs, "被动（られる）")
        add("v1.honorific", "られる", "る", verbs, verbs, "尊敬（られる）")
        add("v1.potentialRanuki", "れる", "る", verbs, verbs, "可能·ら抜き（れる）", cost: 2)
        add("v1.causative", "させる", "る", verbs, verbs, "使役（させる）")
        add("v1.causativeShort", "さす", "る", verbs, verbs, "使役·短形（さす）")
        add("v1.causativePassive", "させられる", "る", verbs, verbs, "使役被动（させられる）")
        // 愿望（たい系本身按い形容词活用；from 含 adj-i 以便链式还原
        // 食べたかった→食べたい{adj-i}→食べる）
        add("v1.tai", "たい", "る", all, verbs, "愿望（たい）")
        add("v1.takatta", "たかった", "る", all, verbs, "愿望·过去（たかった）")
        add("v1.takunai", "たくない", "る", all, verbs, "愿望·否定（たくない）")
        add("v1.takunakatta", "たくなかった", "る", all, verbs, "愿望·过去否定（たくなかった）")
        // ている 链
        add("v1.teiru", "ている", "る", verbs, verbs, "进行（ている）")
        add("v1.teru", "てる", "る", verbs, verbs, "进行·缩约（てる）", cost: 2)
        add("v1.teita", "ていた", "る", verbs, verbs, "进行·过去（ていた）")
        add("v1.teinai", "ていない", "る", verbs, verbs, "进行·否定（ていない）")
        add("v1.teinakatta", "ていなかった", "る", verbs, verbs, "进行·过去否定（ていなかった）")
        add("v1.teimasu", "ています", "る", verbs, verbs, "进行·礼貌（ています）")
        add("v1.teimasen", "ていません", "る", verbs, verbs, "进行·礼貌否定（ていません）")
        add("v1.teimasendeshita", "ていませんでした", "る", verbs, verbs, "进行·礼貌过去否定（ていませんでした）")
        add("v1.tekuru", "てくる", "る", verbs, verbs, "趋向（てくる）")
        add("v1.tekita", "てきた", "る", verbs, verbs, "趋向·过去（てきた）")
        add("v1.tehoshii", "てほしい", "る", verbs, verbs, "希望（てほしい）")

        // MARK: する（vs：本体 vs-i／名词+する vs／愛する系 vs-s 一并接受）
        add("vs.masu", "します", "する", vsPOS, vsPOS, "礼貌（ます）")
        add("vs.mashita", "しました", "する", vsPOS, vsPOS, "礼貌·过去（ました）")
        add("vs.masen", "しません", "する", vsPOS, vsPOS, "礼貌·否定（ません）")
        add("vs.masendeshita", "しませんでした", "する", vsPOS, vsPOS, "礼貌·过去否定（ませんでした）")
        add("vs.mashou", "しましょう", "する", vsPOS, vsPOS, "礼貌·意志（ましょう）")
        add("vs.te", "して", "する", vsPOS, vsPOS, "て形（して）")
        add("vs.ta", "した", "する", vsPOS, vsPOS, "过去（した）")
        add("vs.tara", "したら", "する", vsPOS, vsPOS, "条件（したら）")
        add("vs.temo", "しても", "する", vsPOS, vsPOS, "让步（しても）")
        add("vs.nagara", "しながら", "する", vsPOS, vsPOS, "并行（ながら）")
        add("vs.nai", "しない", "する", vsPOS, vsPOS, "否定（しない）")
        add("vs.nakatta", "しなかった", "する", vsPOS, vsPOS, "否定·过去（しなかった）")
        add("vs.nu", "せぬ", "する", vsPOS, vsPOS, "否定（せぬ）")
        add("vs.zu", "せず", "する", vsPOS, vsPOS, "否定（せず）")
        add("vs.zuni", "せずに", "する", vsPOS, vsPOS, "否定（せずに）")
        add("vs.volitional", "しよう", "する", vsPOS, vsPOS, "意志（しよう）")
        add("vs.imperativeShiro", "しろ", "する", vsPOS, vsPOS, "命令（しろ）")
        add("vs.imperativeSeyo", "せよ", "する", vsPOS, vsPOS, "命令（せよ）")
        add("vs.ba", "すれば", "する", vsPOS, vsPOS, "条件（すれば）")
        add("vs.potential", "できる", "する", vsPOS, vsPOS, "可能（できる）")
        add("vs.passive", "される", "する", vsPOS, vsPOS, "被动（される）")
        add("vs.causative", "させる", "する", vsPOS, vsPOS, "使役（させる）")
        add("vs.causativePassive", "せられる", "する", vsPOS, vsPOS, "使役被动（せられる）")
        add("vs.causativePassive2", "させられる", "する", vsPOS, vsPOS, "使役被动（させられる）")
        add("vs.tai", "したい", "する", vsPOS, vsPOS, "愿望（したい）")
        add("vs.takatta", "したかった", "する", vsPOS, vsPOS, "愿望·过去（したかった）")
        add("vs.takunai", "したくない", "する", vsPOS, vsPOS, "愿望·否定（したくない）")
        add("vs.takunakatta", "したくなかった", "する", vsPOS, vsPOS, "愿望·过去否定（したくなかった）")
        add("vs.teiru", "している", "する", vsPOS, vsPOS, "进行（している）")
        add("vs.teru", "してる", "する", vsPOS, vsPOS, "进行·缩约（してる）", cost: 2)
        add("vs.teita", "していた", "する", vsPOS, vsPOS, "进行·过去（していた）")
        add("vs.teinai", "していない", "する", vsPOS, vsPOS, "进行·否定（していない）")
        add("vs.teinakatta", "していなかった", "する", vsPOS, vsPOS, "进行·过去否定（していなかった）")
        add("vs.teimasu", "しています", "する", vsPOS, vsPOS, "进行·礼貌（しています）")
        add("vs.teimasen", "していません", "する", vsPOS, vsPOS, "进行·礼貌否定（していません）")
        add("vs.teimasendeshita", "していませんでした", "する", vsPOS, vsPOS, "进行·礼貌过去否定（していませんでした）")
        add("vs.tekuru", "してくる", "する", vsPOS, vsPOS, "趋向（してくる）")
        add("vs.tekita", "してきた", "する", vsPOS, vsPOS, "趋向·过去（してきた）")
        add("vs.chau", "しちゃう", "する", vsPOS, vsPOS, "てしまう缩约", cost: 2)
        add("vs.chatta", "しちゃった", "する", vsPOS, vsPOS, "てしまう缩约·过去", cost: 2)

        // MARK: くる（vk）——假名与汉字两套表记变体
        let vkPOS: Set<JapanesePartOfSpeech> = [.vk]
        // 假名 くる 系
        add("vk.masu", "きます", "くる", vkPOS, vkPOS, "礼貌（きます）")
        add("vk.mashita", "きました", "くる", vkPOS, vkPOS, "礼貌·过去（きました）")
        add("vk.masen", "きません", "くる", vkPOS, vkPOS, "礼貌·否定（きません）")
        add("vk.masendeshita", "きませんでした", "くる", vkPOS, vkPOS, "礼貌·过去否定（きませんでした）")
        add("vk.mashou", "きましょう", "くる", vkPOS, vkPOS, "礼貌·意志（きましょう）")
        add("vk.te", "きて", "くる", vkPOS, vkPOS, "て形（きて）")
        add("vk.ta", "きた", "くる", vkPOS, vkPOS, "过去（きた）")
        add("vk.tara", "きたら", "くる", vkPOS, vkPOS, "条件（きたら）")
        add("vk.temo", "きても", "くる", vkPOS, vkPOS, "让步（きても）")
        add("vk.nagara", "きながら", "くる", vkPOS, vkPOS, "并行（きながら）")
        add("vk.nai", "こない", "くる", vkPOS, vkPOS, "否定（こない）")
        add("vk.nakatta", "こなかった", "くる", vkPOS, vkPOS, "否定·过去（こなかった）")
        add("vk.nu", "こぬ", "くる", vkPOS, vkPOS, "否定（こぬ）")
        add("vk.zu", "こず", "くる", vkPOS, vkPOS, "否定（こず）")
        add("vk.zuni", "こずに", "くる", vkPOS, vkPOS, "否定（こずに）")
        add("vk.volitional", "こよう", "くる", vkPOS, vkPOS, "意志（こよう）")
        add("vk.imperative", "こい", "くる", vkPOS, vkPOS, "命令（こい）")
        add("vk.ba", "くれば", "くる", vkPOS, vkPOS, "条件（くれば）")
        add("vk.potential", "こられる", "くる", vkPOS, vkPOS, "可能（こられる）")
        add("vk.causative", "こさせる", "くる", vkPOS, vkPOS, "使役（こさせる）")
        add("vk.causativePassive", "こさせられる", "くる", vkPOS, vkPOS, "使役被动（こさせられる）")
        add("vk.tai", "きたい", "くる", vkPOS, vkPOS, "愿望（きたい）")
        add("vk.takatta", "きたかった", "くる", vkPOS, vkPOS, "愿望·过去（きたかった）")
        add("vk.takunai", "きたくない", "くる", vkPOS, vkPOS, "愿望·否定（きたくない）")
        add("vk.takunakatta", "きたくなかった", "くる", vkPOS, vkPOS, "愿望·过去否定（きたくなかった）")
        add("vk.teiru", "きている", "くる", vkPOS, vkPOS, "进行（きている）")
        add("vk.teru", "きてる", "くる", vkPOS, vkPOS, "进行·缩约（きてる）", cost: 2)
        add("vk.teita", "きていた", "くる", vkPOS, vkPOS, "进行·过去（きていた）")
        add("vk.teinai", "きていない", "くる", vkPOS, vkPOS, "进行·否定（きていない）")
        add("vk.teinakatta", "きていなかった", "くる", vkPOS, vkPOS, "进行·过去否定（きていなかった）")
        add("vk.teimasu", "きています", "くる", vkPOS, vkPOS, "进行·礼貌（きています）")
        add("vk.teimasen", "きていません", "くる", vkPOS, vkPOS, "进行·礼貌否定（きていません）")
        add("vk.teimasendeshita", "きていませんでした", "くる", vkPOS, vkPOS, "进行·礼貌过去否定（きていませんでした）")
        add("vk.tekuru", "きてくる", "くる", vkPOS, vkPOS, "趋向（きてくる）")
        add("vk.tekita", "きてきた", "くる", vkPOS, vkPOS, "趋向·过去（きてきた）")
        // 汉字 来る 系（suffix 含汉字，只作用于 来… 表记）
        add("vk.kanji.masu", "来ます", "来る", vkPOS, vkPOS, "礼貌（来ます）")
        add("vk.kanji.mashita", "来ました", "来る", vkPOS, vkPOS, "礼貌·过去（来ました）")
        add("vk.kanji.masen", "来ません", "来る", vkPOS, vkPOS, "礼貌·否定（来ません）")
        add("vk.kanji.masendeshita", "来ませんでした", "来る", vkPOS, vkPOS, "礼貌·过去否定（来ませんでした）")
        add("vk.kanji.mashou", "来ましょう", "来る", vkPOS, vkPOS, "礼貌·意志（来ましょう）")
        add("vk.kanji.te", "来て", "来る", vkPOS, vkPOS, "て形（来て）")
        add("vk.kanji.ta", "来た", "来る", vkPOS, vkPOS, "过去（来た）")
        add("vk.kanji.tara", "来たら", "来る", vkPOS, vkPOS, "条件（来たら）")
        add("vk.kanji.temo", "来ても", "来る", vkPOS, vkPOS, "让步（来ても）")
        add("vk.kanji.nagara", "来ながら", "来る", vkPOS, vkPOS, "并行（来ながら）")
        add("vk.kanji.nai", "来ない", "来る", vkPOS, vkPOS, "否定（来ない）")
        add("vk.kanji.nakatta", "来なかった", "来る", vkPOS, vkPOS, "否定·过去（来なかった）")
        add("vk.kanji.nu", "来ぬ", "来る", vkPOS, vkPOS, "否定（来ぬ）")
        add("vk.kanji.zu", "来ず", "来る", vkPOS, vkPOS, "否定（来ず）")
        add("vk.kanji.zuni", "来ずに", "来る", vkPOS, vkPOS, "否定（来ずに）")
        add("vk.kanji.volitional", "来よう", "来る", vkPOS, vkPOS, "意志（来よう）")
        add("vk.kanji.imperative", "来い", "来る", vkPOS, vkPOS, "命令（来い）")
        add("vk.kanji.ba", "来れば", "来る", vkPOS, vkPOS, "条件（来れば）")
        add("vk.kanji.potential", "来られる", "来る", vkPOS, vkPOS, "可能（来られる）")
        add("vk.kanji.causative", "来させる", "来る", vkPOS, vkPOS, "使役（来させる）")
        add("vk.kanji.causativePassive", "来させられる", "来る", vkPOS, vkPOS, "使役被动（来させられる）")
        add("vk.kanji.tai", "来たい", "来る", vkPOS, vkPOS, "愿望（来たい）")
        add("vk.kanji.takatta", "来たかった", "来る", vkPOS, vkPOS, "愿望·过去（来たかった）")
        add("vk.kanji.takunai", "来たくない", "来る", vkPOS, vkPOS, "愿望·否定（来たくない）")
        add("vk.kanji.takunakatta", "来たくなかった", "来る", vkPOS, vkPOS, "愿望·过去否定（来たくなかった）")
        add("vk.kanji.teiru", "来ている", "来る", vkPOS, vkPOS, "进行（来ている）")
        add("vk.kanji.teru", "来てる", "来る", vkPOS, vkPOS, "进行·缩约（来てる）", cost: 2)
        add("vk.kanji.teita", "来ていた", "来る", vkPOS, vkPOS, "进行·过去（来ていた）")
        add("vk.kanji.teinai", "来ていない", "来る", vkPOS, vkPOS, "进行·否定（来ていない）")
        add("vk.kanji.teinakatta", "来ていなかった", "来る", vkPOS, vkPOS, "进行·过去否定（来ていなかった）")
        add("vk.kanji.teimasu", "来ています", "来る", vkPOS, vkPOS, "进行·礼貌（来ています）")
        add("vk.kanji.teimasen", "来ていません", "来る", vkPOS, vkPOS, "进行·礼貌否定（来ていません）")
        add("vk.kanji.teimasendeshita", "来ていませんでした", "来る", vkPOS, vkPOS, "进行·礼貌过去否定（来ていませんでした）")
        add("vk.kanji.tekuru", "来てくる", "来る", vkPOS, vkPOS, "趋向（来てくる）")
        add("vk.kanji.tekita", "来てきた", "来る", vkPOS, vkPOS, "趋向·过去（来てきた）")

        // MARK: い形容词（adj-i）
        add("adj.ta", "かった", "い", adjOnly, adjOnly, "过去（かった）")
        add("adj.nai", "くない", "い", adjOnly, adjOnly, "否定（くない）")
        add("adj.nakatta", "くなかった", "い", adjOnly, adjOnly, "否定·过去（くなかった）")
        add("adj.te", "くて", "い", adjOnly, adjOnly, "て形（くて）")
        add("adj.nakute", "くなくて", "い", adjOnly, adjOnly, "否定·て形（くなくて）")
        add("adj.kuarimasen", "くありません", "い", adjOnly, adjOnly, "礼貌·否定（くありません）")
        add("adj.kuarimasendeshita", "くありませんでした", "い", adjOnly, adjOnly, "礼貌·过去否定（くありませんでした）")
        add("adj.desu", "いです", "い", adjOnly, adjOnly, "礼貌（いです）")
        add("adj.kattadesu", "かったです", "い", adjOnly, adjOnly, "礼貌·过去（かったです）")
        add("adj.kunaidesu", "くないです", "い", adjOnly, adjOnly, "礼貌·否定（くないです）")
        add("adj.ba", "ければ", "い", adjOnly, adjOnly, "条件（ければ）")
        add("adj.tara", "かったら", "い", adjOnly, adjOnly, "条件（かったら）")
        add("adj.volitional", "かろう", "い", adjOnly, adjOnly, "意志（かろう）")
        add("adj.sugiru", "すぎる", "い", adjOnly, adjOnly, "过量（すぎる）")

        // MARK: 明示例外
        // 行く：て・た系为促音便「行っ」而非「行い」；suffix 含汉字，
        // 复合（持って行った→持って行く）同样成立。v5k-s 为主、v5k 兼容。
        let ikuPOS: Set<JapanesePartOfSpeech> = [.v5k, .v5kS]
        add("exc.iku.ta", "行った", "行く", all, ikuPOS, "例外·行く促音便（行った）", cost: 0)
        add("exc.iku.te", "行って", "行く", all, ikuPOS, "例外·行く促音便（行って）", cost: 0)
        add("exc.iku.tara", "行ったら", "行く", all, ikuPOS, "例外·行く促音便（行ったら）", cost: 0)
        add("exc.iku.temo", "行っても", "行く", all, ikuPOS, "例外·行く促音便（行っても）", cost: 0)
        add("exc.iku.teiru", "行っている", "行く", all, ikuPOS, "例外·行っている", cost: 0)
        add("exc.iku.teru", "行ってる", "行く", all, ikuPOS, "例外·行ってる", cost: 0)
        add("exc.iku.teita", "行っていた", "行く", all, ikuPOS, "例外·行っていた", cost: 0)
        add("exc.iku.teinai", "行っていない", "行く", all, ikuPOS, "例外·行っていない", cost: 0)
        add("exc.iku.teinakatta", "行っていなかった", "行く", all, ikuPOS, "例外·行っていなかった", cost: 0)
        add("exc.iku.teimasu", "行っています", "行く", all, ikuPOS, "例外·行っています", cost: 0)
        add("exc.iku.teimasen", "行っていません", "行く", all, ikuPOS, "例外·行っていません", cost: 0)
        add("exc.iku.teimasendeshita", "行っていませんでした", "行く", all, ikuPOS, "例外·行っていませんでした", cost: 0)
        add("exc.iku.tekuru", "行ってくる", "行く", all, ikuPOS, "例外·行ってくる", cost: 0)
        add("exc.iku.tekita", "行ってきた", "行く", all, ikuPOS, "例外·行ってきた", cost: 0)
        add("exc.iku.chau", "行っちゃう", "行く", all, ikuPOS, "例外·行っちゃう", cost: 0)
        add("exc.iku.chatta", "行っちゃった", "行く", all, ikuPOS, "例外·行っちゃった", cost: 0)
        // いい→よい：wholeForm 防止误伤 かわいい 等以「いい」结尾的合法词
        add("exc.ii", "いい", "よい", adjOnly, adjOnly, "例外·いい→よい", cost: 0, wholeForm: true)

        return rules
    }
}
