import Foundation
import XCTest
@testable import OboeDomain

/// S15 正向活用器测试：全形式×全词性矩阵、いい/行く/する/来る/問う等
/// 特例、多 accepted 变体标记、正向→反向（deinflector）一致性性质。
final class JapaneseConjugatorTests: XCTestCase {

    private let conjugator = JapaneseConjugator()

    // MARK: - helpers

    private func primary(
        _ lemma: String, _ cls: ConjugationClass, _ form: ConjugationForm,
        reading: String? = nil
    ) throws -> String {
        try conjugator.conjugate(
            lemma: lemma, reading: reading,
            conjugationClass: cls, form: form).primary
    }

    private func acceptedTexts(
        _ lemma: String, _ cls: ConjugationClass, _ form: ConjugationForm,
        reading: String? = nil
    ) throws -> [String] {
        try conjugator.conjugate(
            lemma: lemma, reading: reading,
            conjugationClass: cls, form: form).accepted.map(\.text)
    }

    private func assertForms(
        _ lemma: String, _ cls: ConjugationClass,
        _ expected: [(ConjugationForm, String)],
        reading: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for (form, want) in expected {
            let got = try primary(lemma, cls, form, reading: reading)
            XCTAssertEqual(
                got, want, "\(lemma) \(form.rawValue)",
                file: file, line: line)
        }
    }

    // MARK: - 五段九行全形式矩阵（每行一个代表词全 13 形）

    func testGodanUAllForms() throws {
        // 買う：わ/い/え/お/っ系
        try assertForms("買う", .godanU, [
            (.masu, "買います"), (.te, "買って"), (.past, "買った"),
            (.negative, "買わない"), (.pastNegative, "買わなかった"),
            (.conditionalBa, "買えば"), (.conditionalTara, "買ったら"),
            (.volitional, "買おう"), (.imperative, "買え"),
            (.potential, "買える"), (.passive, "買われる"),
            (.causative, "買わせる"), (.causativePassive, "買わせられる"),
        ])
        // 缩约变体：使役短形 買わす、使役被动短形 買わされる
        let causative = try acceptedTexts("買う", .godanU, .causative)
        XCTAssertTrue(causative.contains("買わす"))
        let causativePassive = try acceptedTexts(
            "買う", .godanU, .causativePassive)
        XCTAssertTrue(causativePassive.contains("買わされる"))
    }

    func testGodanTsuAllForms() throws {
        try assertForms("待つ", .godanTsu, [
            (.masu, "待ちます"), (.te, "待って"), (.past, "待った"),
            (.negative, "待たない"), (.pastNegative, "待たなかった"),
            (.conditionalBa, "待てば"), (.conditionalTara, "待ったら"),
            (.volitional, "待とう"), (.imperative, "待て"),
            (.potential, "待てる"), (.passive, "待たれる"),
            (.causative, "待たせる"), (.causativePassive, "待たせられる"),
        ])
    }

    func testGodanRuAllForms() throws {
        try assertForms("帰る", .godanRu, [
            (.masu, "帰ります"), (.te, "帰って"), (.past, "帰った"),
            (.negative, "帰らない"), (.pastNegative, "帰らなかった"),
            (.conditionalBa, "帰れば"), (.conditionalTara, "帰ったら"),
            (.volitional, "帰ろう"), (.imperative, "帰れ"),
            (.potential, "帰れる"), (.passive, "帰られる"),
            (.causative, "帰らせる"), (.causativePassive, "帰らせられる"),
        ])
    }

    func testGodanNuAllForms() throws {
        try assertForms("死ぬ", .godanNu, [
            (.masu, "死にます"), (.te, "死んで"), (.past, "死んだ"),
            (.negative, "死なない"), (.pastNegative, "死ななかった"),
            (.conditionalBa, "死ねば"), (.conditionalTara, "死んだら"),
            (.volitional, "死のう"), (.imperative, "死ね"),
            (.potential, "死ねる"), (.passive, "死なれる"),
            (.causative, "死なせる"), (.causativePassive, "死なせられる"),
        ])
    }

    func testGodanBuAllForms() throws {
        try assertForms("遊ぶ", .godanBu, [
            (.masu, "遊びます"), (.te, "遊んで"), (.past, "遊んだ"),
            (.negative, "遊ばない"), (.pastNegative, "遊ばなかった"),
            (.conditionalBa, "遊べば"), (.conditionalTara, "遊んだら"),
            (.volitional, "遊ぼう"), (.imperative, "遊べ"),
            (.potential, "遊べる"), (.passive, "遊ばれる"),
            (.causative, "遊ばせる"), (.causativePassive, "遊ばせられる"),
        ])
    }

    func testGodanMuAllForms() throws {
        try assertForms("読む", .godanMu, [
            (.masu, "読みます"), (.te, "読んで"), (.past, "読んだ"),
            (.negative, "読まない"), (.pastNegative, "読まなかった"),
            (.conditionalBa, "読めば"), (.conditionalTara, "読んだら"),
            (.volitional, "読もう"), (.imperative, "読め"),
            (.potential, "読める"), (.passive, "読まれる"),
            (.causative, "読ませる"), (.causativePassive, "読ませられる"),
        ])
    }

    func testGodanKuAllForms() throws {
        try assertForms("書く", .godanKu, [
            (.masu, "書きます"), (.te, "書いて"), (.past, "書いた"),
            (.negative, "書かない"), (.pastNegative, "書かなかった"),
            (.conditionalBa, "書けば"), (.conditionalTara, "書いたら"),
            (.volitional, "書こう"), (.imperative, "書け"),
            (.potential, "書ける"), (.passive, "書かれる"),
            (.causative, "書かせる"), (.causativePassive, "書かせられる"),
        ])
    }

    func testGodanGuAllForms() throws {
        try assertForms("泳ぐ", .godanGu, [
            (.masu, "泳ぎます"), (.te, "泳いで"), (.past, "泳いだ"),
            (.negative, "泳がない"), (.pastNegative, "泳がなかった"),
            (.conditionalBa, "泳げば"), (.conditionalTara, "泳いだら"),
            (.volitional, "泳ごう"), (.imperative, "泳げ"),
            (.potential, "泳げる"), (.passive, "泳がれる"),
            (.causative, "泳がせる"), (.causativePassive, "泳がせられる"),
        ])
    }

    func testGodanSuAllForms() throws {
        try assertForms("話す", .godanSu, [
            (.masu, "話します"), (.te, "話して"), (.past, "話した"),
            (.negative, "話さない"), (.pastNegative, "話さなかった"),
            (.conditionalBa, "話せば"), (.conditionalTara, "話したら"),
            (.volitional, "話そう"), (.imperative, "話せ"),
            (.potential, "話せる"), (.passive, "話される"),
            (.causative, "話させる"), (.causativePassive, "話させられる"),
        ])
    }

    // MARK: - 五段特殊行

    func testGodanUTouNonEuphonic() throws {
        // 問う/請う（v5u-s）：て・た不音便 問うて/問うた，其余走う行。
        try assertForms("問う", .godanUTou, [
            (.masu, "問います"), (.te, "問うて"), (.past, "問うた"),
            (.negative, "問わない"), (.pastNegative, "問わなかった"),
            (.conditionalBa, "問えば"), (.conditionalTara, "問うたら"),
            (.volitional, "問おう"), (.imperative, "問え"),
            (.potential, "問える"), (.passive, "問われる"),
            (.causative, "問わせる"), (.causativePassive, "問わせられる"),
        ])
        try assertForms("請う", .godanUTou, [
            (.te, "請うて"), (.past, "請うた"), (.conditionalTara, "請うたら"),
        ])
    }

    func testIkuSokuonbin() throws {
        // 行く：て・た・たら 为促音便（行って/行った），其余常规く行。
        try assertForms("行く", .godanKuIku, [
            (.masu, "行きます"), (.te, "行って"), (.past, "行った"),
            (.negative, "行かない"), (.pastNegative, "行かなかった"),
            (.conditionalBa, "行けば"), (.conditionalTara, "行ったら"),
            (.volitional, "行こう"), (.imperative, "行け"),
            (.potential, "行ける"), (.passive, "行かれる"),
            (.causative, "行かせる"), (.causativePassive, "行かせられる"),
        ])
    }

    func testAruNegativeWholeWordException() throws {
        // ある系（v5r-i）：否定是整体词 ない / なかった（非 あらない）。
        try assertForms("ある", .godanRuAru, [
            (.masu, "あります"), (.te, "あって"), (.past, "あった"),
            (.negative, "ない"), (.pastNegative, "なかった"),
            (.conditionalBa, "あれば"), (.conditionalTara, "あったら"),
            (.volitional, "あろう"), (.imperative, "あれ"),
            (.potential, "あれる"),
        ])
        // 非ある词尾走常规：なさる（v5r-i）否定仍是 なさらない
        XCTAssertEqual(
            try primary("なさる", .godanRuAru, .negative), "なさらない")
    }

    func testKeigoAruRow() throws {
        // v5aru（ござる/なさる系）：连用形い+音便っ；命令形=连用形。
        try assertForms("ござる", .godanAruKeigo, [
            (.masu, "ございます"), (.te, "ござって"), (.past, "ござった"),
            (.negative, "ござらない"), (.pastNegative, "ござらなかった"),
            (.conditionalBa, "ござれば"), (.conditionalTara, "ござったら"),
            (.volitional, "ござろう"), (.imperative, "ござい"),
        ])
        try assertForms("なさる", .godanAruKeigo, [
            (.masu, "なさいます"), (.te, "なさって"), (.imperative, "なさい"),
        ])
        // 敬语 -aru 不取可能/被动/使役。
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "ござる", conjugationClass: .godanAruKeigo,
            form: .potential)) { error in
            XCTAssertEqual(
                error as? ConjugationError,
                .unsupportedForm(.godanAruKeigo, .potential))
        }
    }

    // MARK: - 一段

    func testIchidanAllForms() throws {
        try assertForms("食べる", .ichidan, [
            (.masu, "食べます"), (.te, "食べて"), (.past, "食べた"),
            (.negative, "食べない"), (.pastNegative, "食べなかった"),
            (.conditionalBa, "食べれば"), (.conditionalTara, "食べたら"),
            (.volitional, "食べよう"),
            (.potential, "食べられる"), (.passive, "食べられる"),
            (.causative, "食べさせる"), (.causativePassive, "食べさせられる"),
        ])
        // 命令双规范形：食べろ（口）/食べよ（文）
        let imp = try conjugator.conjugate(
            lemma: "食べる", conjugationClass: .ichidan, form: .imperative)
        XCTAssertEqual(imp.accepted.map(\.text), ["食べろ", "食べよ"])
        XCTAssertEqual(imp.accepted.map(\.variant), [.standard, .alternate])
        // 可能缩约：食べられる（规范）/食べれる（ら抜き，显式 contracted）
        let pot = try conjugator.conjugate(
            lemma: "食べる", conjugationClass: .ichidan, form: .potential)
        XCTAssertEqual(
            pot.accepted.map(\.text), ["食べられる", "食べれる"])
        XCTAssertEqual(
            pot.accepted.map(\.variant), [.standard, .contracted])
        // 使役缩约 食べさす
        let caus = try conjugator.conjugate(
            lemma: "食べる", conjugationClass: .ichidan, form: .causative)
        XCTAssertEqual(
            caus.accepted.map(\.text), ["食べさせる", "食べさす"])
    }

    // MARK: - する・くる

    func testSuruAllForms() throws {
        try assertForms("する", .suru, [
            (.masu, "します"), (.te, "して"), (.past, "した"),
            (.negative, "しない"), (.pastNegative, "しなかった"),
            (.conditionalBa, "すれば"), (.conditionalTara, "したら"),
            (.volitional, "しよう"),
            (.potential, "できる"), (.passive, "される"),
            (.causative, "させる"), (.causativePassive, "せられる"),
        ])
        let imp = try conjugator.conjugate(
            lemma: "する", conjugationClass: .suru, form: .imperative)
        XCTAssertEqual(imp.accepted.map(\.text), ["しろ", "せよ"])
        // 使役被动双规范形
        let cp = try conjugator.conjugate(
            lemma: "する", conjugationClass: .suru,
            form: .causativePassive)
        XCTAssertEqual(
            cp.accepted.map(\.text), ["せられる", "させられる"])
    }

    func testNounSuruCompound() throws {
        try assertForms("勉強する", .suru, [
            (.masu, "勉強します"), (.te, "勉強して"), (.past, "勉強した"),
            (.negative, "勉強しない"), (.pastNegative, "勉強しなかった"),
            (.conditionalBa, "勉強すれば"), (.conditionalTara, "勉強したら"),
            (.volitional, "勉強しよう"), (.potential, "勉強できる"),
            (.passive, "勉強される"), (.causative, "勉強させる"),
            (.causativePassive, "勉強せられる"),
        ])
        // 读音给出时产全假名表记变体
        let masu = try conjugator.conjugate(
            lemma: "勉強する", reading: "べんきょうする",
            conjugationClass: .suru, form: .masu)
        XCTAssertTrue(masu.accepted.contains {
            $0.text == "べんきょうします" && $0.variant == .script
        })
    }

    func testSuruSVariant() throws {
        // vs-s（愛する系）：未然 さ / 连用 し
        try assertForms("愛する", .suruS, [
            (.masu, "愛します"), (.te, "愛して"), (.past, "愛した"),
            (.negative, "愛さない"), (.pastNegative, "愛さなかった"),
            (.conditionalBa, "愛すれば"), (.conditionalTara, "愛したら"),
            (.volitional, "愛しよう"), (.potential, "愛し得る"),
            (.passive, "愛される"), (.causative, "愛させる"),
            (.causativePassive, "愛させられる"),
        ])
        let neg = try conjugator.conjugate(
            lemma: "愛する", conjugationClass: .suruS, form: .negative)
        XCTAssertTrue(neg.accepted.contains {
            $0.text == "愛しない" && $0.variant == .alternate })
        let pot = try conjugator.conjugate(
            lemma: "愛する", conjugationClass: .suruS, form: .potential)
        XCTAssertTrue(pot.accepted.contains {
            $0.text == "愛できる" && $0.variant == .alternate })
    }

    func testKuruBothScripts() throws {
        try assertForms("来る", .kuru, [
            (.masu, "来ます"), (.te, "来て"), (.past, "来た"),
            (.negative, "来ない"), (.pastNegative, "来なかった"),
            (.conditionalBa, "来れば"), (.conditionalTara, "来たら"),
            (.volitional, "来よう"), (.imperative, "来い"),
            (.potential, "来られる"), (.passive, "来られる"),
            (.causative, "来させる"), (.causativePassive, "来させられる"),
        ])
        try assertForms("くる", .kuru, [
            (.masu, "きます"), (.te, "きて"), (.past, "きた"),
            (.negative, "こない"), (.pastNegative, "こなかった"),
            (.conditionalBa, "くれば"), (.conditionalTara, "きたら"),
            (.volitional, "こよう"), (.imperative, "こい"),
            (.potential, "こられる"), (.causative, "こさせる"),
            (.causativePassive, "こさせられる"),
        ])
        // 互写变体：来る→き-系列、くる→来-系列
        let ta = try conjugator.conjugate(
            lemma: "来る", conjugationClass: .kuru, form: .past)
        XCTAssertTrue(ta.accepted.contains {
            $0.text == "きた" && $0.variant == .script })
        // 复合动词（持ってくる）
        XCTAssertEqual(
            try primary("持ってくる", .kuru, .te), "持ってきて")
        XCTAssertEqual(
            try primary("持ってくる", .kuru, .negative), "持ってこない")
    }

    // MARK: - 形容词

    func testIAdjectiveForms() throws {
        try assertForms("高い", .iAdjective, [
            (.past, "高かった"), (.negative, "高くない"),
            (.pastNegative, "高くなかった"), (.te, "高くて"),
            (.conditionalBa, "高ければ"), (.conditionalTara, "高かったら"),
            (.volitional, "高かろう"),
        ])
        // 读音表记变体
        let past = try conjugator.conjugate(
            lemma: "高い", reading: "たかい",
            conjugationClass: .iAdjective, form: .past)
        XCTAssertTrue(past.accepted.contains {
            $0.text == "たかかった" && $0.variant == .script })
    }

    func testIiIrregular() throws {
        // いい→よかった（よ/良 两表记；lemma=いい 时よ为规范形）
        try assertForms("いい", .iAdjective, [
            (.past, "よかった"), (.negative, "よくない"),
            (.pastNegative, "よくなかった"), (.te, "よくて"),
            (.conditionalBa, "よければ"), (.conditionalTara, "よかったら"),
        ])
        let past = try conjugator.conjugate(
            lemma: "いい", conjugationClass: .iAdjective, form: .past)
        XCTAssertTrue(past.accepted.contains {
            $0.text == "良かった" && $0.variant == .script })
        // 良い 为 lemma 时反之
        let past2 = try conjugator.conjugate(
            lemma: "良い", conjugationClass: .iAdjective, form: .past)
        XCTAssertEqual(past2.primary, "良かった")
        XCTAssertTrue(past2.accepted.contains {
            $0.text == "よかった" && $0.variant == .script })
    }

    func testNaAdjectiveForms() throws {
        try assertForms("静か", .naAdjective, [
            (.past, "静かだった"), (.negative, "静かではない"),
            (.pastNegative, "静かではなかった"), (.te, "静かで"),
            (.conditionalBa, "静かなら"), (.conditionalTara, "静かだったら"),
            (.volitional, "静かだろう"),
        ])
        // 缩约 じゃない/じゃなかった 显式标记
        let neg = try conjugator.conjugate(
            lemma: "静か", conjugationClass: .naAdjective, form: .negative)
        XCTAssertTrue(neg.accepted.contains {
            $0.text == "静かじゃない" && $0.variant == .contracted })
        // lemma 带结尾な（変な系 JMdict 表记）先剥な
        try assertForms("変な", .naAdjective, [
            (.past, "変だった"), (.negative, "変ではない"), (.te, "変で"),
        ])
    }

    // MARK: - 变体表记（かな/漢字混用）

    func testScriptVariantsFromReading() throws {
        let te = try conjugator.conjugate(
            lemma: "食べる", reading: "たべる",
            conjugationClass: .ichidan, form: .te)
        XCTAssertEqual(te.accepted.map(\.text), ["食べて", "たべて"])
        XCTAssertEqual(te.accepted.map(\.variant), [.standard, .script])
        let nai = try conjugator.conjugate(
            lemma: "読む", reading: "よむ",
            conjugationClass: .godanMu, form: .negative)
        XCTAssertTrue(nai.accepted.contains {
            $0.text == "よまない" && $0.variant == .script })
        // 无读音 → 无 script 变体
        let naiNoReading = try conjugator.conjugate(
            lemma: "読む", conjugationClass: .godanMu, form: .negative)
        XCTAssertEqual(naiNoReading.accepted.map(\.variant), [.standard])
    }

    // MARK: - 输入校验（不猜词性）

    func testValidationErrors() throws {
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "  ", conjugationClass: .ichidan, form: .te)) {
            XCTAssertEqual($0 as? ConjugationError, .emptyLemma)
        }
        // 食べる 按五段く行 → 词尾不符
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "食べる", conjugationClass: .godanKu, form: .te)) {
            XCTAssertEqual(
                $0 as? ConjugationError,
                .lemmaClassMismatch(lemma: "食べる", expectedSuffix: "く"))
        }
        // 泳ぐ 按一段 → 词尾不符
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "泳ぐ", conjugationClass: .ichidan, form: .te)) {
            XCTAssertEqual(
                $0 as? ConjugationError,
                .lemmaClassMismatch(lemma: "泳ぐ", expectedSuffix: "る"))
        }
        // 形容词的可能形 → 不支持（显式错误而非空数组）
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "高い", conjugationClass: .iAdjective, form: .potential)) {
            XCTAssertEqual(
                $0 as? ConjugationError,
                .unsupportedForm(.iAdjective, .potential))
        }
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "静か", conjugationClass: .naAdjective,
            form: .imperative)) {
            XCTAssertEqual(
                $0 as? ConjugationError,
                .unsupportedForm(.naAdjective, .imperative))
        }
        // kuru 类但词尾非 くる/来る
        XCTAssertThrowsError(try conjugator.conjugate(
            lemma: "寝る", conjugationClass: .kuru, form: .te)) {
            XCTAssertEqual(
                $0 as? ConjugationError,
                .lemmaClassMismatch(lemma: "寝る", expectedSuffix: "くる/来る"))
        }
    }

    func testJMdictTagMapping() {
        XCTAssertEqual(
            ConjugationClass(jmdictTag: .v5k), .godanKu)
        XCTAssertEqual(
            ConjugationClass(jmdictTag: .v5kS), .godanKuIku)
        XCTAssertEqual(
            ConjugationClass(jmdictTag: .v5uS), .godanUTou)
        XCTAssertEqual(
            ConjugationClass(jmdictTag: .v5rI), .godanRuAru)
        XCTAssertEqual(
            ConjugationClass(jmdictTag: .v5aru), .godanAruKeigo)
        XCTAssertEqual(ConjugationClass(jmdictTag: .v1), .ichidan)
        XCTAssertEqual(ConjugationClass(jmdictTag: .vs), .suru)
        XCTAssertEqual(ConjugationClass(jmdictTag: .vsI), .suru)
        XCTAssertEqual(ConjugationClass(jmdictTag: .vsS), .suruS)
        XCTAssertEqual(ConjugationClass(jmdictTag: .vk), .kuru)
        XCTAssertEqual(ConjugationClass(jmdictTag: .adjI), .iAdjective)
        // adj-na 不在形态 POS 枚举内（无映射→上层显式传 .naAdjective）
        XCTAssertFalse(JapanesePartOfSpeech.allCases.contains(
            where: { $0.rawValue == "adj-na" }))
    }

    func testSupportedFormsMatrix() {
        for cls in ConjugationClass.allCases {
            let forms = cls.supportedForms
            switch cls {
            case .iAdjective, .naAdjective:
                XCTAssertEqual(forms.count, 7, cls.rawValue)
            case .godanAruKeigo:
                XCTAssertEqual(forms.count, 9, cls.rawValue)
            default:
                XCTAssertEqual(forms.count, ConjugationForm.allCases.count,
                               cls.rawValue)
            }
        }
    }

    // MARK: - 正向→反向一致性性质

    /// 样例集（lemma, reading, class, 额外合法原形）。
    /// 「额外合法原形」覆盖同一词元的表记/活用变体：
    /// いい系（よい/良い）、愛する系（愛す）、来る系（くる互写）。
    private static let propertySamples:
        [(lemma: String, reading: String?, cls: ConjugationClass,
          extraLemmas: [String])] = [
        ("買う", "かう", .godanU, []),
        ("問う", "とう", .godanUTou, []),
        ("請う", "こう", .godanUTou, []),
        ("待つ", "まつ", .godanTsu, []),
        ("帰る", "かえる", .godanRu, []),
        ("ある", nil, .godanRuAru, []),
        ("死ぬ", "しぬ", .godanNu, []),
        ("遊ぶ", "あそぶ", .godanBu, []),
        ("読む", "よむ", .godanMu, []),
        ("書く", "かく", .godanKu, []),
        ("行く", "いく", .godanKuIku, []),
        ("泳ぐ", "およぐ", .godanGu, []),
        ("話す", "はなす", .godanSu, []),
        ("ござる", nil, .godanAruKeigo, []),
        ("なさる", "なさる", .godanAruKeigo, []),
        ("食べる", "たべる", .ichidan, []),
        ("見る", "みる", .ichidan, []),
        ("する", "する", .suru, []),
        ("勉強する", "べんきょうする", .suru, []),
        ("愛する", "あいする", .suruS, ["愛す", "あいす"]),
        ("くる", "くる", .kuru, ["来る"]),
        ("来る", "くる", .kuru, ["くる"]),
        ("持ってくる", "もってくる", .kuru, ["持って来る"]),
        ("高い", "たかい", .iAdjective, []),
        ("いい", "いい", .iAdjective, ["よい", "良い"]),
        ("良い", "よい", .iAdjective, ["よい", "いい"]),
    ]

    /// 已知反向覆盖洞（deinflector 侧尚无对应还原规则，
    /// 见 docs/v0.7/s15-conjugation.md「已知反向覆盖洞」）：
    /// - ある系整体词否定（ない→ある 规则会给常见「ない」引入歧义，
    ///   有意不加）；
    /// - v5aru 连用形い系（ございます/ござい/なさいます/なさい——
    ///   deinflector 无 -aru 行）；
    /// - vs-s 文语可能 愛し得る（无 し得る→する 规则）；
    /// - 行く促音便的全假名表记（いって/いった/いったら——促音便行く
    ///   例外规则含汉字，纯假名路径不在表内）；
    /// - 問う/請う系的たら形（deinflector 有 うて/うた 不音便规则，
    ///   无 うたら）。
    /// な形容词整类无反向（JapanesePartOfSpeech 无 adj-na，属性测试
    /// 不含该类）。
    private static let knownReverseGaps: Set<String> = [
        "ある|negative|ない",
        "ある|pastNegative|なかった",
        "ござる|masu|ございます",
        "ござる|imperative|ござい",
        "なさる|masu|なさいます",
        "なさる|imperative|なさい",
        "愛する|potential|愛し得る",
        "愛する|potential|あいし得る",
        "行く|te|いって",
        "行く|past|いった",
        "行く|conditionalTara|いったら",
        "問う|conditionalTara|問うたら",
        "問う|conditionalTara|とうたら",
        "請う|conditionalTara|請うたら",
        "請う|conditionalTara|こうたら",
    ]

    /// 性质：样例集内每个生成答案的 deinflection 候选必含原 lemma
    /// （或同一词元的表记变体/活用变体）。失配集合必须精确等于
    /// 已记录的覆盖洞——新增洞或修复既有洞都会使本测试失败，
    /// 强制文档同步。
    func testForwardBackwardRoundTrip() throws {
        let deinflector = JapaneseDeinflector()
        var misses: Set<String> = []
        var checked = 0
        for (lemma, reading, cls, extras) in Self.propertySamples {
            let expectedLemmas = Set(
                [SearchTextNormalizer.normalize(lemma)]
                + extras.map(SearchTextNormalizer.normalize)
                + (reading.map { [SearchTextNormalizer.normalize($0)] }
                    ?? []))
            let results = try conjugator.conjugateAll(
                lemma: lemma, reading: reading, conjugationClass: cls)
            for result in results {
                for answer in result.accepted {
                    checked += 1
                    let lemmas = Set(
                        deinflector.candidates(for: answer.text)
                            .filter { !$0.isTruncationMarker }
                            .map(\.lemma))
                    if lemmas.isDisjoint(with: expectedLemmas) {
                        misses.insert(
                            "\(lemma)|\(result.form.rawValue)|\(answer.text)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 200)
        XCTAssertEqual(misses, Self.knownReverseGaps)
    }

    /// 全假名/汉字混写变体也被接受（判分演示：カタカナ输入经
    /// 规范化命中平假名答案）。
    func testGradeNormalizesInput() throws {
        let result = try conjugator.conjugate(
            lemma: "食べる", reading: "たべる",
            conjugationClass: .ichidan, form: .te)
        XCTAssertTrue(conjugator.grade(result, input: "食べて").isCorrect)
        XCTAssertTrue(conjugator.grade(result, input: " 食べて ").isCorrect)
        // カタカナ输入经 SearchTextNormalizer 转平假名命中 script 变体
        XCTAssertTrue(conjugator.grade(result, input: "タベテ").isCorrect)
        XCTAssertFalse(conjugator.grade(result, input: "食べる").isCorrect)
        XCTAssertFalse(conjugator.grade(result, input: "食べた").isCorrect)
    }
}
