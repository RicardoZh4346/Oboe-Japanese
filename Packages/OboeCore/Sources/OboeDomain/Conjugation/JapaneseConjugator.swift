import Foundation

/// S15 正向活用生成器（需求 §13 / 技术文档 §12）：确认的 lemma + 读音 +
/// 显式活用类别 → 带规则 ID 与多个 accepted forms 的结果。
///
/// 与 `JapaneseDeinflector` 的关系：双向共享 `GodanConjugationTable`
/// 审查行表（五段 a/i/e/o/音便干），但正向生成**不是**把还原规则的
/// suffix↔replacement 简单倒过来——正向按「词干 + 形后缀」组装，并显式
/// 携带规范/缩约/表记变体标记。
///
/// 规则 ID 形如 `conj.v5k.potential` / `conj.v1.causativePassive`；
/// 变体规则在主 id 后追加段（`.short` `.yo` `.contract` `.script`）。
public struct JapaneseConjugator: Sendable {

    /// 正向活用规则语义版本（练习快照 rule_id 的口径部分；任何生成
    /// 规则增删改必须 bump）。
    public static let conjugatorRulesVersion = "1.0.0"

    public init() {}

    // MARK: - 公开 API

    /// 单形生成。lemma/reading 先经 `SearchTextNormalizer` 规范化；
    /// 词尾与声明类别不符抛 `lemmaClassMismatch`（不猜测词性）。
    public func conjugate(
        lemma: String,
        reading: String? = nil,
        conjugationClass: ConjugationClass,
        form: ConjugationForm
    ) throws -> ConjugationResult {
        let normalizedLemma = SearchTextNormalizer.normalize(lemma)
        let normalizedReading = reading.map(SearchTextNormalizer.normalize)
        guard !normalizedLemma.isEmpty else {
            throw ConjugationError.emptyLemma
        }
        guard conjugationClass.supportedForms.contains(form) else {
            throw ConjugationError.unsupportedForm(conjugationClass, form)
        }
        let base = "conj.\(conjugationClass.rawValue).\(form.rawValue)"
        var accepted = try generate(
            lemma: normalizedLemma, reading: normalizedReading,
            conjugationClass: conjugationClass, form: form, ruleID: base)
        // 去重保序（变体可能与规范形字面相同，如全假名 lemma）。
        var seen = Set<String>()
        accepted = accepted.filter { seen.insert($0.text).inserted }
        guard let first = accepted.first else {
            throw ConjugationError.unsupportedForm(conjugationClass, form)
        }
        return ConjugationResult(
            lemma: normalizedLemma, reading: normalizedReading,
            conjugationClass: conjugationClass, form: form,
            ruleID: first.ruleID, accepted: accepted)
    }

    /// 该类别全部支持形的一次生成（出题/测试用）。
    public func conjugateAll(
        lemma: String,
        reading: String? = nil,
        conjugationClass: ConjugationClass
    ) throws -> [ConjugationResult] {
        try conjugationClass.supportedForms
            .sorted { $0.rawValue < $1.rawValue }
            .map { form in
                try conjugate(
                    lemma: lemma, reading: reading,
                    conjugationClass: conjugationClass, form: form)
            }
    }

    /// 判分：输入规范化后命中任一 accepted 即 correct（返回命中项）。
    public func grade(
        _ result: ConjugationResult,
        input: String
    ) -> (isCorrect: Bool, matched: AcceptedAnswer?) {
        let normalized = SearchTextNormalizer.normalize(input)
        let hit = result.accepted.first { $0.text == normalized }
        return (hit != nil, hit)
    }

    // MARK: - 生成入口

    private func generate(
        lemma: String,
        reading: String?,
        conjugationClass: ConjugationClass,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        switch conjugationClass {
        case .godanU, .godanTsu, .godanRu, .godanRuAru, .godanNu,
             .godanBu, .godanMu, .godanKu, .godanGu, .godanSu:
            return try godanForms(
                lemma: lemma, reading: reading,
                row: Self.godanRow(for: conjugationClass),
                teMode: .euphonic,
                form: form, ruleID: ruleID)
        case .godanUTou:
            return try godanForms(
                lemma: lemma, reading: reading,
                row: Self.godanRow(for: conjugationClass),
                teMode: .nonEuphonic,
                form: form, ruleID: ruleID)
        case .godanKuIku:
            return try godanForms(
                lemma: lemma, reading: reading,
                row: Self.godanRow(for: conjugationClass),
                teMode: .sokuon,
                form: form, ruleID: ruleID)
        case .godanAruKeigo:
            return try godanForms(
                lemma: lemma, reading: reading,
                row: GodanConjugationTable.keigoAruRow,
                teMode: .euphonic,
                form: form, ruleID: ruleID)
        case .ichidan:
            return try ichidanForms(
                lemma: lemma, reading: reading,
                form: form, ruleID: ruleID)
        case .suru:
            return try suruForms(
                lemma: lemma, reading: reading, specialS: false,
                form: form, ruleID: ruleID)
        case .suruS:
            return try suruForms(
                lemma: lemma, reading: reading, specialS: true,
                form: form, ruleID: ruleID)
        case .kuru:
            return try kuruForms(
                lemma: lemma, form: form, ruleID: ruleID)
        case .iAdjective:
            return try iAdjectiveForms(
                lemma: lemma, reading: reading,
                form: form, ruleID: ruleID)
        case .naAdjective:
            return try naAdjectiveForms(
                lemma: lemma, reading: reading,
                form: form, ruleID: ruleID)
        }
    }

    private static func godanRow(for cls: ConjugationClass) -> GodanConjugationRow {
        let id: String
        switch cls {
        case .godanU, .godanUTou: id = "u"
        case .godanTsu: id = "t"
        case .godanRu, .godanRuAru: id = "r"
        case .godanNu: id = "n"
        case .godanBu: id = "b"
        case .godanMu: id = "m"
        case .godanKu, .godanKuIku: id = "k"
        case .godanGu: id = "g"
        case .godanSu: id = "s"
        default: preconditionFailure("not a godan class: \(cls)")
        }
        return GodanConjugationTable.rows.first { $0.id == id }!
    }

    // MARK: - 五段

    private enum TeMode {
        case euphonic    // 常规音便（って/んで/いて/いで/して）
        case sokuon      // 行く：促音便（行って/行った）
        case nonEuphonic // 問う系：不音便（問うて/問うた）
    }

    private func godanForms(
        lemma: String,
        reading: String?,
        row: GodanConjugationRow,
        teMode: TeMode,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        guard lemma.hasSuffix(row.lemma) else {
            throw ConjugationError.lemmaClassMismatch(
                lemma: lemma, expectedSuffix: row.lemma)
        }
        let stem = String(lemma.dropLast(row.lemma.count))
        // 読む→よ: reading 末位与 lemma 尾假名一致时取读音干做表记变体。
        let readStem = reading.flatMap { r -> String? in
            guard r.hasSuffix(row.lemma), r != lemma else { return nil }
            return String(r.dropLast(row.lemma.count))
        }
        // ある系整体词例外：ある/有る/在る 的否定是 ない（非 あらない）。
        // 按 lemma 判定而非类别——调用方即便给了泛化 godanRu 也产正确答案。
        let isAruLemma = row.id == "r" && Self.aruWholeLemmas.contains(lemma)
        func emit(_ suffix: String, _ variant: AnswerVariant = .standard,
                  _ suffixID: String = "") -> AcceptedAnswer {
            AcceptedAnswer(
                text: stem + suffix, variant: variant,
                ruleID: ruleID + suffixID)
        }
        func script(_ suffix: String) -> AcceptedAnswer? {
            readStem.map {
                AcceptedAnswer(
                    text: $0 + suffix, variant: .script,
                    ruleID: ruleID + ".script")
            }
        }
        var out: [AcceptedAnswer] = []
        switch form {
        case .masu:
            out += [emit(row.i + "ます")]
        case .te, .past, .conditionalTara:
            let (eStem, end): (String, String) = {
                switch teMode {
                case .euphonic: return (row.stem, form == .te ? row.teEnd : row.taEnd)
                case .sokuon: return ("っ", form == .te ? "て" : "た")
                case .nonEuphonic: return (row.lemma, form == .te ? "て" : "た")
                }
            }()
            let suffix = form == .conditionalTara
                ? eStem + row.taEnd + "ら"
                : eStem + end
            out += [emit(suffix)]
            if let s = script(suffix) { out += [s] }
        case .negative:
            if isAruLemma {
                out += [AcceptedAnswer(
                    text: "ない", variant: .standard,
                    ruleID: ruleID + ".whole")]
            } else {
                out += [emit(row.a + "ない")]
                if let s = script(row.a + "ない") { out += [s] }
            }
        case .pastNegative:
            if isAruLemma {
                out += [AcceptedAnswer(
                    text: "なかった", variant: .standard,
                    ruleID: ruleID + ".whole")]
            } else {
                out += [emit(row.a + "なかった")]
                if let s = script(row.a + "なかった") { out += [s] }
            }
        case .conditionalBa:
            out += [emit(row.e + "ば")]
            if let s = script(row.e + "ば") { out += [s] }
        case .volitional:
            out += [emit(row.o + "う")]
            if let s = script(row.o + "う") { out += [s] }
        case .imperative:
            // -aru 敬语系命令形为连用形（ござい/なさい），其余为仮定干。
            let imp = row.id == "aru" ? row.i : row.e
            out += [emit(imp)]
            if let s = script(imp) { out += [s] }
        case .potential:
            out += [emit(row.e + "る")]
            if let s = script(row.e + "る") { out += [s] }
        case .passive:
            out += [emit(row.a + "れる")]
            if let s = script(row.a + "れる") { out += [s] }
        case .causative:
            out += [emit(row.a + "せる")]
            out += [emit(row.a + "す", .contracted, ".short")]
            if let s = script(row.a + "せる") { out += [s] }
        case .causativePassive:
            out += [emit(row.a + "せられる")]
            out += [emit(row.a + "される", .contracted, ".short")]
            if let s = script(row.a + "せられる") { out += [s] }
        }
        return out
    }

    private static let aruWholeLemmas: Set<String> = ["ある", "有る", "在る"]

    // MARK: - 一段

    private func ichidanForms(
        lemma: String,
        reading: String?,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        guard lemma.hasSuffix("る") else {
            throw ConjugationError.lemmaClassMismatch(
                lemma: lemma, expectedSuffix: "る")
        }
        let stem = String(lemma.dropLast())
        guard !stem.isEmpty else { throw ConjugationError.emptyStem }
        let readStem = reading.flatMap { r -> String? in
            guard r.hasSuffix("る"), r != lemma else { return nil }
            return String(r.dropLast())
        }
        func emit(_ suffix: String, _ variant: AnswerVariant = .standard,
                  _ suffixID: String = "") -> AcceptedAnswer {
            AcceptedAnswer(
                text: stem + suffix, variant: variant,
                ruleID: ruleID + suffixID)
        }
        func script(_ suffix: String) -> AcceptedAnswer? {
            readStem.map {
                AcceptedAnswer(
                    text: $0 + suffix, variant: .script,
                    ruleID: ruleID + ".script")
            }
        }
        var out: [AcceptedAnswer] = []
        func append(_ suffix: String, _ variant: AnswerVariant = .standard,
                    _ suffixID: String = "") {
            out.append(emit(suffix, variant, suffixID))
            if variant == .standard, let s = script(suffix) { out.append(s) }
        }
        switch form {
        case .masu: append("ます")
        case .te: append("て")
        case .past: append("た")
        case .negative: append("ない")
        case .pastNegative: append("なかった")
        case .conditionalBa: append("れば")
        case .conditionalTara: append("たら")
        case .volitional: append("よう")
        case .imperative:
            append("ろ")
            out.append(emit("よ", .alternate, ".yo"))
            if let s = script("よ") { out.append(s) }
        case .potential:
            append("られる")
            out.append(emit("れる", .contracted, ".ranuki"))
        case .passive:
            append("られる")
        case .causative:
            append("させる")
            out.append(emit("さす", .contracted, ".short"))
        case .causativePassive:
            // 一段使役被动缩约「食べされる」属非规范口语形，不收录。
            append("させられる")
        }
        return out
    }

    // MARK: - する系（する / 名詞+する / vs-s 愛する系）

    private func suruForms(
        lemma: String,
        reading: String?,
        specialS: Bool,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        guard lemma.hasSuffix("する") else {
            throw ConjugationError.lemmaClassMismatch(
                lemma: lemma, expectedSuffix: "する")
        }
        let prefix = String(lemma.dropLast(2))
        let readPrefix = reading.flatMap { r -> String? in
            guard r.hasSuffix("する"), r != lemma else { return nil }
            return String(r.dropLast(2))
        }
        func emit(_ suffix: String, _ variant: AnswerVariant = .standard,
                  _ suffixID: String = "") -> AcceptedAnswer {
            AcceptedAnswer(
                text: prefix + suffix, variant: variant,
                ruleID: ruleID + suffixID)
        }
        func script(_ suffix: String) -> AcceptedAnswer? {
            readPrefix.map {
                AcceptedAnswer(
                    text: $0 + suffix, variant: .script,
                    ruleID: ruleID + ".script")
            }
        }
        var out: [AcceptedAnswer] = []
        func append(_ suffix: String, _ variant: AnswerVariant = .standard,
                    _ suffixID: String = "") {
            out.append(emit(suffix, variant, suffixID))
            if variant == .standard, let s = script(suffix) { out.append(s) }
        }
        switch form {
        case .masu: append("します")
        case .te: append("して")
        case .past: append("した")
        case .negative:
            if specialS {
                append("さない")
                out.append(emit("しない", .alternate, ".vs"))
            } else {
                append("しない")
            }
        case .pastNegative:
            if specialS {
                append("さなかった")
                out.append(emit("しなかった", .alternate, ".vs"))
            } else {
                append("しなかった")
            }
        case .conditionalBa: append("すれば")
        case .conditionalTara: append("したら")
        case .volitional: append("しよう")
        case .imperative:
            append("しろ")
            out.append(emit("せよ", .alternate, ".seyo"))
        case .potential:
            if specialS {
                append("し得る")
                out.append(emit("できる", .alternate, ".dekiru"))
            } else {
                append("できる")
            }
        case .passive: append("される")
        case .causative: append("させる")
        case .causativePassive:
            if specialS {
                append("させられる")
            } else {
                append("せられる")
                out.append(emit("させられる", .alternate, ".long"))
            }
        }
        return out
    }

    // MARK: - くる/来る

    /// くる系活用段（连浊复合同样成立：持ってくる→持ってきます）。
    /// kanji 系列按「来＋后缀」整段给出（来本身吸收 き/こ/く 读音，
    /// 与 deinflector 的 vk.kanji.* 规则对齐）。
    private static let kuruKana: [ConjugationForm: [String]] = [
        .masu: ["きます"], .te: ["きて"], .past: ["きた"],
        .negative: ["こない"], .pastNegative: ["こなかった"],
        .conditionalBa: ["くれば"], .conditionalTara: ["きたら"],
        .volitional: ["こよう"], .imperative: ["こい"],
        .potential: ["こられる"], .passive: ["こられる"],
        .causative: ["こさせる"], .causativePassive: ["こさせられる"],
    ]
    private static let kuruKanji: [ConjugationForm: [String]] = [
        .masu: ["来ます"], .te: ["来て"], .past: ["来た"],
        .negative: ["来ない"], .pastNegative: ["来なかった"],
        .conditionalBa: ["来れば"], .conditionalTara: ["来たら"],
        .volitional: ["来よう"], .imperative: ["来い"],
        .potential: ["来られる"], .passive: ["来られる"],
        .causative: ["来させる"], .causativePassive: ["来させられる"],
    ]

    private func kuruForms(
        lemma: String,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        let kanaTail = "くる"
        let kanjiTail = "来る"
        let prefix: String
        let primary: [String]
        let alternateScript: [String]
        if lemma.hasSuffix(kanjiTail) {
            prefix = String(lemma.dropLast(kanjiTail.count))
            primary = Self.kuruKanji[form] ?? []
            alternateScript = Self.kuruKana[form] ?? []
        } else if lemma.hasSuffix(kanaTail) {
            prefix = String(lemma.dropLast(kanaTail.count))
            primary = Self.kuruKana[form] ?? []
            alternateScript = Self.kuruKanji[form] ?? []
        } else {
            throw ConjugationError.lemmaClassMismatch(
                lemma: lemma, expectedSuffix: "くる/来る")
        }
        var out = primary.map {
            AcceptedAnswer(text: prefix + $0, variant: .standard, ruleID: ruleID)
        }
        out += alternateScript.map {
            AcceptedAnswer(
                text: prefix + $0, variant: .script,
                ruleID: ruleID + ".script")
        }
        return out
    }

    // MARK: - い形容词（含 いい 特例）

    /// いい/良い/よい 的词干为不规则 よ/良（いい→よかった）。
    private func iAdjectiveForms(
        lemma: String,
        reading: String?,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        guard lemma.hasSuffix("い") else {
            throw ConjugationError.lemmaClassMismatch(
                lemma: lemma, expectedSuffix: "い")
        }
        // (stem, scriptStem)：良い→(良, よ)、いい/よい→(よ, 良)。
        let iiLemmas: Set<String> = ["いい", "よい"]
        let stem: String
        var scriptStem: String?
        if lemma == "良い" {
            stem = "良"; scriptStem = "よ"
        } else if iiLemmas.contains(lemma) {
            stem = "よ"; scriptStem = "良"
        } else {
            stem = String(lemma.dropLast())
            if let r = reading, r.hasSuffix("い"), r != lemma {
                scriptStem = String(r.dropLast())
            }
        }
        guard !stem.isEmpty else { throw ConjugationError.emptyStem }
        let suffix: [ConjugationForm: String] = [
            .past: "かった", .negative: "くない",
            .pastNegative: "くなかった", .te: "くて",
            .conditionalBa: "ければ", .conditionalTara: "かったら",
            .volitional: "かろう",
        ]
        guard let s = suffix[form] else {
            throw ConjugationError.unsupportedForm(.iAdjective, form)
        }
        var out = [AcceptedAnswer(
            text: stem + s, variant: .standard, ruleID: ruleID)]
        if let ss = scriptStem, ss != stem {
            out.append(AcceptedAnswer(
                text: ss + s, variant: .script, ruleID: ruleID + ".script"))
        }
        return out
    }

    // MARK: - な形容词

    /// な形容词 lemma 若带结尾 な（変な/確かな 系 JMdict 表记），
    /// 活用先剥 な——な本身是断定助动词的连体形，不属于词干。
    private func naAdjectiveForms(
        lemma: String,
        reading: String?,
        form: ConjugationForm,
        ruleID: String
    ) throws -> [AcceptedAnswer] {
        var stem = lemma
        if stem.count > 1, stem.hasSuffix("な") {
            stem = String(stem.dropLast())
        }
        guard !stem.isEmpty else { throw ConjugationError.emptyStem }
        var scriptStem: String? = nil
        if let r = reading {
            var rStem = r
            if rStem.count > 1, rStem.hasSuffix("な") {
                rStem = String(rStem.dropLast())
            }
            if rStem != stem { scriptStem = rStem }
        }
        var out: [AcceptedAnswer] = []
        func append(_ suffix: String, _ variant: AnswerVariant = .standard,
                    _ suffixID: String = "") {
            out.append(AcceptedAnswer(
                text: stem + suffix, variant: variant,
                ruleID: ruleID + suffixID))
            if variant == .standard, let ss = scriptStem {
                out.append(AcceptedAnswer(
                    text: ss + suffix, variant: .script,
                    ruleID: ruleID + ".script"))
            }
        }
        switch form {
        case .past: append("だった")
        case .negative:
            append("ではない")
            out.append(AcceptedAnswer(
                text: stem + "じゃない", variant: .contracted,
                ruleID: ruleID + ".jya"))
            if let ss = scriptStem {
                out.append(AcceptedAnswer(
                    text: ss + "じゃない", variant: .contracted,
                    ruleID: ruleID + ".jya.script"))
            }
        case .pastNegative:
            append("ではなかった")
            out.append(AcceptedAnswer(
                text: stem + "じゃなかった", variant: .contracted,
                ruleID: ruleID + ".jya"))
        case .te: append("で")
        case .conditionalBa: append("なら")
        case .conditionalTara: append("だったら")
        case .volitional: append("だろう")
        default:
            throw ConjugationError.unsupportedForm(.naAdjective, form)
        }
        return out
    }
}
