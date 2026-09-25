import XCTest
@testable import OboeDomain

/// S03 变形还原器测试契约（技术文档 §5.2 / 需求 §8、§16.2）：
/// golden 命中、每规则组正反例、词性冲突、同形多义、原形无损、
/// 预算/深度上界、固定排序、重复调用一致、规范化一致。
final class JapaneseDeinflectorTests: XCTestCase {
    private let deinflector = JapaneseDeinflector()

    // MARK: - helpers

    private func realCandidates(_ surface: String) -> [DeinflectionCandidate] {
        deinflector.candidates(for: surface).filter { !$0.isTruncationMarker }
    }

    private func lemmas(_ surface: String) -> Set<String> {
        Set(realCandidates(surface).map(\.lemma))
    }

    private func candidates(_ surface: String, lemma: String) -> [DeinflectionCandidate] {
        realCandidates(surface).filter { $0.lemma == lemma }
    }

    /// 断言 surface 推出 lemma，且至少一条候选的原因链/词性满足要求。
    private func assertHit(
        _ surface: String,
        _ lemma: String,
        reasonSubstrings: [String] = [],
        pos: Set<JapanesePartOfSpeech>? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hits = candidates(surface, lemma: lemma)
        XCTAssertFalse(
            hits.isEmpty,
            "「\(surface)」未推出「\(lemma)」。实际候选：\(lemmas(surface).sorted())",
            file: file, line: line
        )
        if !reasonSubstrings.isEmpty {
            let ok = hits.contains { candidate in
                let chain = candidate.reasons.joined(separator: "→")
                return reasonSubstrings.allSatisfy { chain.contains($0) }
            }
            XCTAssertTrue(
                ok,
                "「\(surface)→\(lemma)」缺少原因链 \(reasonSubstrings)，实际：\(hits.map { $0.reasons })",
                file: file, line: line
            )
        }
        if let pos {
            let ok = hits.contains { $0.admissiblePOS == pos }
            XCTAssertTrue(
                ok,
                "「\(surface)→\(lemma)」词性集合不含 \(pos)，实际：\(hits.map { $0.admissiblePOS })",
                file: file, line: line
            )
        }
    }

    // MARK: - §16.2 Golden

    func testGoldenQueries() {
        // 原形：lemma 即自身，零成本、无原因链
        for surface in ["食べる", "行く", "する", "来る", "分かる", "困る", "見る", "見える", "見せる"] {
            assertHit(surface, surface)
            let identity = candidates(surface, lemma: surface).first { $0.reasons.isEmpty }
            XCTAssertNotNil(identity, "「\(surface)」缺原形候选")
            XCTAssertEqual(identity?.cost, 0)
        }
        // いい：原形 + 例外 よい
        assertHit("いい", "いい")
        assertHit("いい", "よい", reasonSubstrings: ["例外"], pos: [.adjI])
        // 变形 golden
        assertHit("食べなかった", "食べる", reasonSubstrings: ["否定", "过去"])
        assertHit("行っている", "行く", reasonSubstrings: ["例外"])
        assertHit("食べさせられなかった", "食べる", reasonSubstrings: ["否定", "使役被动"])
    }

    // MARK: - 五段动词

    func testGodanUTsuRuSharesEuphonic() {
        // う・つ・る 三行共用 った/って 促音便
        assertHit("買った", "買う", reasonSubstrings: ["过去"])
        assertHit("待った", "待つ", reasonSubstrings: ["过去"])
        assertHit("分かった", "分かる", reasonSubstrings: ["过去"])
        assertHit("買って", "買う", reasonSubstrings: ["て形"])
        assertHit("待って", "待つ", reasonSubstrings: ["て形"])
        assertHit("分かって", "分かる", reasonSubstrings: ["て形"])
        // 同形多义：買った → 買う/買つ/買る 均成候选（词典侧按存在性裁）
        let found = lemmas("買った")
        XCTAssertTrue(found.contains("買う"))
        XCTAssertTrue(found.contains("買つ"))
        XCTAssertTrue(found.contains("買る"))
    }

    func testGodanNuBuMuVoicedEuphonic() {
        assertHit("死んだ", "死ぬ", reasonSubstrings: ["过去"])
        assertHit("遊んだ", "遊ぶ", reasonSubstrings: ["过去"])
        assertHit("読んだ", "読む", reasonSubstrings: ["过去"])
        assertHit("死んで", "死ぬ", reasonSubstrings: ["て形"])
        assertHit("遊んで", "遊ぶ", reasonSubstrings: ["て形"])
        assertHit("読んで", "読む", reasonSubstrings: ["て形"])
        // 同形不同义：んだ 同时是 ぬ/ぶ/む 行的音便
        let found = lemmas("読んだ")
        XCTAssertTrue(found.isSuperset(of: ["読ぬ", "読ぶ", "読む"]))
    }

    func testGodanKuGu() {
        assertHit("書いた", "書く", reasonSubstrings: ["过去"])
        assertHit("書いて", "書く", reasonSubstrings: ["て形"])
        assertHit("泳いだ", "泳ぐ", reasonSubstrings: ["过去"])
        assertHit("泳いで", "泳ぐ", reasonSubstrings: ["て形"])
        // 反例：促音便 って/错误未然形 あない 不适用于く行，不应推出 書く
        XCTAssertFalse(lemmas("書って").contains("書く"))
        XCTAssertFalse(lemmas("書あない").contains("書く"))
        XCTAssertFalse(lemmas("泳いだ").contains("泳く"))
    }

    func testGodanSu() {
        assertHit("話した", "話す", reasonSubstrings: ["过去"])
        assertHit("話して", "話す", reasonSubstrings: ["て形"])
        assertHit("話さない", "話す", reasonSubstrings: ["否定"])
        // 同形多义：した → する（vs 过去）与 v5s/v1 其他解释并存
        let found = lemmas("した")
        XCTAssertTrue(found.contains("する"))
        XCTAssertGreaterThan(found.count, 1)
    }

    func testGodanConditionalVolitionalImperativePotential() {
        assertHit("行けば", "行く", reasonSubstrings: ["条件"])
        assertHit("行こう", "行く", reasonSubstrings: ["意志"])
        assertHit("行け", "行く", reasonSubstrings: ["命令"])
        assertHit("行ける", "行く", reasonSubstrings: ["可能"])
        assertHit("買えば", "買う", reasonSubstrings: ["条件"])
        assertHit("買おう", "買う", reasonSubstrings: ["意志"])
        assertHit("買え", "買う", reasonSubstrings: ["命令"])
        assertHit("話せ", "話す", reasonSubstrings: ["命令"])
    }

    func testGodanNegative() {
        assertHit("行かない", "行く", reasonSubstrings: ["否定"], pos: [.v5k, .v5kS])
        assertHit("行かなかった", "行く", reasonSubstrings: ["否定", "过去"])
        assertHit("行かぬ", "行く", reasonSubstrings: ["ぬ"])
        assertHit("行かず", "行く", reasonSubstrings: ["ず"])
        assertHit("行かずに", "行く", reasonSubstrings: ["ずに"])
        assertHit("読まない", "読む", reasonSubstrings: ["否定"])
        // 反例：错误的未然形（あ段）不应推出原形
        XCTAssertFalse(lemmas("買あない").contains("買う"))
    }

    func testGodanPassiveCausativeCausativePassive() {
        assertHit("行かれる", "行く", reasonSubstrings: ["被动"])
        assertHit("行かせる", "行く", reasonSubstrings: ["使役"])
        assertHit("行かせられる", "行く", reasonSubstrings: ["使役被动"])
        assertHit("読まれる", "読む", reasonSubstrings: ["被动"])
        assertHit("読ませる", "読む", reasonSubstrings: ["使役"])
        // 五段使役被动短形（される）
        assertHit("読まされる", "読む", reasonSubstrings: ["使役被动"])
        assertHit("行かされる", "行く", reasonSubstrings: ["使役被动"])
        // 使役被动 + 过去：经 た→る 链式还原
        assertHit("行かされた", "行く", reasonSubstrings: ["过去", "使役被动"])
        assertHit("読ませられた", "読む", reasonSubstrings: ["过去", "使役被动"])
        // 五段使役短形（す）
        assertHit("行かす", "行く", reasonSubstrings: ["使役"])
    }

    func testGodanPolite() {
        assertHit("行きます", "行く", reasonSubstrings: ["礼貌"], pos: [.v5k, .v5kS])
        assertHit("行きました", "行く", reasonSubstrings: ["礼貌", "过去"])
        assertHit("行きません", "行く", reasonSubstrings: ["礼貌", "否定"])
        assertHit("行きませんでした", "行く", reasonSubstrings: ["礼貌", "否定", "过去"])
        assertHit("行きましょう", "行く", reasonSubstrings: ["礼貌", "意志"])
        assertHit("読みます", "読む", reasonSubstrings: ["礼貌"])
        assertHit("話します", "話す", reasonSubstrings: ["礼貌"])
        // 反例：い形容词+ます不是动词
        XCTAssertFalse(lemmas("高いました").contains("高い"))
    }

    func testGodanTeiruChains() {
        assertHit("泳いでいる", "泳ぐ", reasonSubstrings: ["进行"])
        assertHit("読んでいる", "読む", reasonSubstrings: ["进行"])
        assertHit("買っている", "買う", reasonSubstrings: ["进行"])
        assertHit("話している", "話す", reasonSubstrings: ["进行"])
        assertHit("読んでいた", "読む", reasonSubstrings: ["进行", "过去"])
        assertHit("読んでいない", "読む", reasonSubstrings: ["进行", "否定"])
        assertHit("読んでいなかった", "読む", reasonSubstrings: ["进行", "否定", "过去"])
        // 缩约 てる
        assertHit("読んでる", "読む", reasonSubstrings: ["进行"])
        // てしまう缩约（っちゃ／んじゃ）
        assertHit("買っちゃった", "買う", reasonSubstrings: ["てしまう"])
        assertHit("死んじゃった", "死ぬ", reasonSubstrings: ["てしまう"])
    }

    func testGodanUSpecialRow() {
        // 問う（v5u-s）：て・た不音便
        assertHit("問うて", "問う", reasonSubstrings: ["て形"])
        assertHit("問うた", "問う", reasonSubstrings: ["过去"])
        let pos = candidates("問うて", lemma: "問う").first?.admissiblePOS
        XCTAssertTrue(pos?.contains(.v5uS) == true, "問うて→問う 应保留 v5u-s")
    }

    // MARK: - 一段动词

    func testIchidan() {
        assertHit("食べます", "食べる", reasonSubstrings: ["礼貌"])
        assertHit("食べました", "食べる", reasonSubstrings: ["礼貌", "过去"])
        assertHit("食べません", "食べる", reasonSubstrings: ["礼貌", "否定"])
        assertHit("食べませんでした", "食べる", reasonSubstrings: ["礼貌", "否定", "过去"])
        assertHit("食べて", "食べる", reasonSubstrings: ["て形"])
        assertHit("食べた", "食べる", reasonSubstrings: ["过去"])
        assertHit("食べたら", "食べる", reasonSubstrings: ["条件"])
        assertHit("食べても", "食べる", reasonSubstrings: ["让步"])
        assertHit("食べない", "食べる", reasonSubstrings: ["否定"])
        assertHit("食べなかった", "食べる", reasonSubstrings: ["否定", "过去"])
        assertHit("食べぬ", "食べる", reasonSubstrings: ["ぬ"])
        assertHit("食べず", "食べる", reasonSubstrings: ["ず"])
        assertHit("食べずに", "食べる", reasonSubstrings: ["ずに"])
        assertHit("食べれば", "食べる", reasonSubstrings: ["条件"])
        assertHit("食べよう", "食べる", reasonSubstrings: ["意志"])
        assertHit("食べろ", "食べる", reasonSubstrings: ["命令"])
        assertHit("食べよ", "食べる", reasonSubstrings: ["命令"])
        assertHit("食べさせる", "食べる", reasonSubstrings: ["使役"])
        assertHit("食べさせられた", "食べる", reasonSubstrings: ["使役被动"])
        assertHit("食べている", "食べる", reasonSubstrings: ["进行"])
        assertHit("食べていた", "食べる", reasonSubstrings: ["进行", "过去"])
        assertHit("食べていない", "食べる", reasonSubstrings: ["进行", "否定"])
        assertHit("食べてる", "食べる", reasonSubstrings: ["进行"])
        assertHit("食べちゃった", "食べる", reasonSubstrings: ["てしまう"])
        assertHit("食べたい", "食べる", reasonSubstrings: ["愿望"])
        assertHit("食べながら", "食べる", reasonSubstrings: ["并行"])
        // ら抜き可能（缩约、更高成本仍保留）
        assertHit("食べれる", "食べる", reasonSubstrings: ["ら抜き"])
        // 反例：食べます 不应推出 食べない
        XCTAssertFalse(lemmas("食べます").contains("食べない"))
    }

    func testIchidanRareruAmbiguity() {
        // 食べられる → 食べる：可能/被动/尊敬三条解释各自成候选（§8.3）
        let hits = candidates("食べられる", lemma: "食べる")
        let reasonChains = hits.map { $0.reasons.joined(separator: "→") }
        XCTAssertTrue(reasonChains.contains { $0.contains("可能") })
        XCTAssertTrue(reasonChains.contains { $0.contains("被动") })
        XCTAssertTrue(reasonChains.contains { $0.contains("尊敬") })
        XCTAssertGreaterThanOrEqual(hits.count, 3)
    }

    // MARK: - する / くる（假名与汉字变体）

    func testSuru() {
        assertHit("した", "する", reasonSubstrings: ["过去"], pos: [.vs, .vsI, .vsS])
        assertHit("して", "する", reasonSubstrings: ["て形"])
        assertHit("しない", "する", reasonSubstrings: ["否定"])
        assertHit("しなかった", "する", reasonSubstrings: ["否定", "过去"])
        assertHit("します", "する", reasonSubstrings: ["礼貌"])
        assertHit("しました", "する", reasonSubstrings: ["礼貌", "过去"])
        assertHit("しません", "する", reasonSubstrings: ["礼貌", "否定"])
        assertHit("しませんでした", "する", reasonSubstrings: ["礼貌", "否定", "过去"])
        assertHit("しよう", "する", reasonSubstrings: ["意志"])
        assertHit("しろ", "する", reasonSubstrings: ["命令"])
        assertHit("せよ", "する", reasonSubstrings: ["命令"])
        assertHit("すれば", "する", reasonSubstrings: ["条件"])
        assertHit("せず", "する", reasonSubstrings: ["ず"])
        assertHit("せずに", "する", reasonSubstrings: ["ずに"])
        assertHit("される", "する", reasonSubstrings: ["被动"])
        assertHit("させる", "する", reasonSubstrings: ["使役"])
        assertHit("できる", "する", reasonSubstrings: ["可能"])
        assertHit("している", "する", reasonSubstrings: ["进行"])
        assertHit("していた", "する", reasonSubstrings: ["进行", "过去"])
        assertHit("したい", "する", reasonSubstrings: ["愿望"])
        // 名词+する（汉字词干）
        assertHit("勉強した", "勉強する", reasonSubstrings: ["过去"])
        assertHit("勉強します", "勉強する", reasonSubstrings: ["礼貌"])
        assertHit("勉強している", "勉強する", reasonSubstrings: ["进行"])
        // する系派生链：されなかった → される → する
        assertHit("されなかった", "する", reasonSubstrings: ["否定", "被动"])
    }

    func testKuruKanaAndKanji() {
        // 假名 くる 系
        assertHit("きた", "くる", reasonSubstrings: ["过去"], pos: [.vk])
        assertHit("きて", "くる", reasonSubstrings: ["て形"])
        assertHit("こない", "くる", reasonSubstrings: ["否定"])
        assertHit("こなかった", "くる", reasonSubstrings: ["否定", "过去"])
        assertHit("きます", "くる", reasonSubstrings: ["礼貌"])
        assertHit("きました", "くる", reasonSubstrings: ["礼貌", "过去"])
        assertHit("きません", "くる", reasonSubstrings: ["礼貌", "否定"])
        assertHit("こよう", "くる", reasonSubstrings: ["意志"])
        assertHit("こい", "くる", reasonSubstrings: ["命令"])
        assertHit("くれば", "くる", reasonSubstrings: ["条件"])
        assertHit("こられる", "くる", reasonSubstrings: ["可能"])
        assertHit("きている", "くる", reasonSubstrings: ["进行"])
        // 汉字 来る 系
        assertHit("来た", "来る", reasonSubstrings: ["过去"], pos: [.vk])
        assertHit("来て", "来る", reasonSubstrings: ["て形"])
        assertHit("来ない", "来る", reasonSubstrings: ["否定"])
        assertHit("来なかった", "来る", reasonSubstrings: ["否定", "过去"])
        assertHit("来ました", "来る", reasonSubstrings: ["礼貌", "过去"])
        assertHit("来ません", "来る", reasonSubstrings: ["礼貌", "否定"])
        assertHit("来よう", "来る", reasonSubstrings: ["意志"])
        assertHit("来い", "来る", reasonSubstrings: ["命令"])
        assertHit("来れば", "来る", reasonSubstrings: ["条件"])
        assertHit("来られる", "来る", reasonSubstrings: ["可能"])
        assertHit("来ている", "来る", reasonSubstrings: ["进行"])
        // 表记隔离：假名形不推汉字 lemma，反之亦然
        XCTAssertFalse(lemmas("きた").contains("来る"))
        XCTAssertFalse(lemmas("来た").contains("くる"))
    }

    // MARK: - い形容词

    func testIAdjective() {
        assertHit("高かった", "高い", reasonSubstrings: ["过去"], pos: [.adjI])
        assertHit("高くない", "高い", reasonSubstrings: ["否定"], pos: [.adjI])
        assertHit("高くなかった", "高い", reasonSubstrings: ["否定", "过去"], pos: [.adjI])
        assertHit("高くて", "高い", reasonSubstrings: ["て形"])
        assertHit("高くなくて", "高い", reasonSubstrings: ["否定", "て形"])
        assertHit("高くありません", "高い", reasonSubstrings: ["礼貌", "否定"])
        assertHit("高くありませんでした", "高い", reasonSubstrings: ["礼貌", "否定", "过去"])
        assertHit("高いです", "高い", reasonSubstrings: ["礼貌"])
        assertHit("高かったです", "高い", reasonSubstrings: ["礼貌", "过去"])
        assertHit("高ければ", "高い", reasonSubstrings: ["条件"])
        assertHit("高かったら", "高い", reasonSubstrings: ["条件"])
        assertHit("高かろう", "高い", reasonSubstrings: ["意志"])
        // 原形不受损：高い 不产生任何动词候选
        for candidate in realCandidates("高い") {
            XCTAssertTrue(
                candidate.admissiblePOS.isDisjoint(with: JapanesePartOfSpeech.verbClasses)
                    || candidate.lemma == "高い",
                "「高い」推出动词候选 \(candidate.lemma)"
            )
        }
    }

    // MARK: - 词性冲突与过滤标签

    func testPOSConflict() {
        // 形容词形推出的 高い 只能标 adj-i，词典侧可拒绝动词词条
        for candidate in candidates("高かった", lemma: "高い") {
            XCTAssertEqual(candidate.admissiblePOS, [.adjI])
        }
        // 动词形推出的 食べる 不得标 adj-i
        for candidate in candidates("食べない", lemma: "食べる") {
            XCTAssertFalse(candidate.admissiblePOS.contains(.adjI))
        }
        // 五段行还原保持行级精度：行かない→行く 只允许 く行系
        for candidate in candidates("行かない", lemma: "行く") {
            XCTAssertTrue(candidate.admissiblePOS.isSubset(of: [.v5k, .v5kS]))
        }
        // 误候选（食べった→食べる 按五段る行解释）带 v5r 标签，
        // 词典侧用真实 JMdict POS（食べる=v1）可裁掉
        let fake = candidates("食べった", lemma: "食べる")
        XCTAssertFalse(fake.isEmpty)
        XCTAssertTrue(fake.allSatisfy { $0.admissiblePOS.isSubset(of: [.v5r, .v5rI]) })
    }

    // MARK: - 例外

    func testIkuException() {
        // 行った→行く 是明示例外，而非「行う/行きます规则误推」
        assertHit("行った", "行く", reasonSubstrings: ["例外"], pos: [.v5k, .v5kS])
        assertHit("行って", "行く", reasonSubstrings: ["例外"])
        assertHit("行っている", "行く", reasonSubstrings: ["例外"])
        assertHit("行っていた", "行く", reasonSubstrings: ["例外"])
        assertHit("行ったら", "行く", reasonSubstrings: ["例外"])
        assertHit("行っちゃった", "行く", reasonSubstrings: ["例外"])
        // 复合同样命中（持って行った→持って行く）
        assertHit("持って行った", "持って行く", reasonSubstrings: ["例外"])
        // 同形多义保留：行った 也合法地是 行う（おこなう）的过去
        assertHit("行った", "行う", reasonSubstrings: ["过去"], pos: [.v5u, .v5uS])
        assertHit("行っている", "行う", pos: [.v5u, .v5uS])
    }

    func testIiException() {
        assertHit("いい", "よい", reasonSubstrings: ["例外"], pos: [.adjI])
        // wholeForm 防误伤：かわいい 不推出 かわよい
        XCTAssertFalse(lemmas("かわいい").contains("かわよい"))
        // 链式：いいです → いい → よい
        assertHit("いいです", "よい", pos: [.adjI])
        // よい 自身活用按通用 adj-i 规则
        assertHit("よかった", "よい", reasonSubstrings: ["过去"])
        assertHit("よくない", "よい", reasonSubstrings: ["否定"])
    }

    // MARK: - 深层链式还原

    func testDeepChains() {
        // 使役被动 + 进行 + 过去否定：三层链
        assertHit(
            "食べさせられていなかった",
            "食べる",
            reasonSubstrings: ["进行", "使役被动"]
        )
        // 使役 + 礼貌过去否定
        assertHit(
            "食べさせませんでした",
            "食べる",
            reasonSubstrings: ["礼貌", "使役"]
        )
        // 愿望 + 过去（经 adj-i 中间形）
        assertHit("行きたかった", "行く", reasonSubstrings: ["愿望"])
        assertHit("食べたかった", "食べる", reasonSubstrings: ["愿望"])
        // 所有原因链长度都不超过 maxDepth
        for surface in ["食べさせられていなかった", "食べさせられなかった", "行っている"] {
            for candidate in realCandidates(surface) {
                XCTAssertLessThanOrEqual(
                    candidate.reasons.count,
                    JapaneseDeinflector.defaultMaxDepth,
                    "「\(surface)」候选 \(candidate.lemma) 原因链超深"
                )
            }
        }
    }

    // MARK: - 预算与上界

    func testBudgetBounds() {
        let nasty = "食べさせられなかった"
        let result = deinflector.analyze(nasty)
        XCTAssertLessThanOrEqual(result.expandedStates, JapaneseDeinflector.defaultMaxStates)
        XCTAssertLessThanOrEqual(
            realCandidates(nasty).count,
            JapaneseDeinflector.defaultMaxStates + 1
        )
        XCTAssertFalse(result.isTruncated, "常规输入不应触达预算上限")
    }

    func testTruncationMarker() {
        // 小预算实例确定性触发截断标记，而不是崩溃/死循环
        let tiny = JapaneseDeinflector(maxDepth: 8, maxStates: 3)
        let result = tiny.analyze("食べなかった")
        XCTAssertTrue(result.isTruncated)
        let candidates = tiny.candidates(for: "食べなかった")
        XCTAssertTrue(candidates.last?.isTruncationMarker == true)
        XCTAssertEqual(candidates.last?.reasons, ["search.truncated"])
        // 即使截断，已有候选仍可用（原形无损）
        XCTAssertTrue(candidates.contains { $0.lemma == "食べなかった" && $0.cost == 0 })
    }

    func testDepthBudgetRespected() {
        let shallow = JapaneseDeinflector(maxDepth: 1, maxStates: 128)
        for candidate in shallow.candidates(for: "食べさせられなかった") {
            if !candidate.isTruncationMarker {
                XCTAssertLessThanOrEqual(candidate.reasons.count, 1)
            }
        }
    }

    func testRuntimeBound() {
        // 状态/深度有界 ⇒ 单次调用时间上界。200 次调用应远小于阈值。
        let inputs = ["食べさせられなかった", "行っている", "食べなかった", "高かった", "来ませんでした"]
        let start = Date()
        for _ in 0..<200 {
            for input in inputs {
                _ = deinflector.candidates(for: input)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10.0)
    }

    // MARK: - 原形无损与未知输入

    func testIdentityAlwaysPresent() {
        for surface in ["食べる", "行く", "高い", "する", "xyz", "ああああ"] {
            let hits = candidates(surface, lemma: surface)
            XCTAssertTrue(hits.contains { $0.reasons.isEmpty && $0.cost == 0 })
        }
        // 非日语输入：只有原形候选，不编造 lemma
        XCTAssertEqual(lemmas("xyz"), ["xyz"])
    }

    // MARK: - 固定排序与确定性

    func testDeterministicOrderingAndRepeatability() {
        let inputs = ["食べさせられなかった", "行った", "食べられる", "高かった"]
        for input in inputs {
            let first = deinflector.candidates(for: input)
            let second = deinflector.candidates(for: input)
            XCTAssertEqual(first, second, "「\(input)」重复调用结果不一致")
            // 排序固定：成本非递减
            let costs = first.filter { !$0.isTruncationMarker }.map(\.cost)
            XCTAssertEqual(costs, costs.sorted(), "「\(input)」候选未按成本排序")
            // 原形候选在首位（成本 0）
            XCTAssertEqual(first.first?.cost, 0)
        }
    }

    // MARK: - 规范化一致性

    func testNormalizationEquivalence() {
        // 半角片假名 / 全角片假名 / 平假名 经同一规范化后行为一致
        // （片假名输入归一为平假名，与汉字表记的 lemma 差异由词典
        //   reading 索引弥合，不在本层）
        let kanaBase = lemmas("たべなかった")
        XCTAssertEqual(lemmas("タベナカッタ"), kanaBase)
        XCTAssertEqual(lemmas("ﾀﾍﾞﾅｶｯﾀ"), kanaBase)
        // 首尾空白、汉字表记不变
        XCTAssertEqual(lemmas(" 食べなかった "), lemmas("食べなかった"))
        let suruBase = lemmas("した")
        XCTAssertEqual(lemmas("シタ"), suruBase)
        XCTAssertEqual(lemmas("ｼﾀ"), suruBase)
        // Unicode 全角 ASCII / NFC 差异
        XCTAssertEqual(lemmas("ｶﾀｶﾅ"), lemmas("かたかな"))
    }

    // MARK: - 协议一致性

    func testProtocolConformance() {
        let contract: any Deinflecting = JapaneseDeinflector()
        let candidates = contract.candidates(for: "食べなかった")
        XCTAssertTrue(candidates.contains { $0.lemma == "食べる" })
    }
}
