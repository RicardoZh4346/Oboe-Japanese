import XCTest
@testable import OboeDomain

/// T01 frozen mora contract (设计 §6.1)：音调核位置按真实 mora 计数，
/// 小假名并入前一 mora，促音/拨音/长音各自独立成 mora。
final class JapaneseMoraCounterTests: XCTestCase {
    func testPlainReadings() {
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "たべる"), 3)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ねこ"), 2)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "あ"), 1)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "がくせい"), 4)
    }

    func testPalatalizedCombinations() {
        // きょう = きょ + う → 2 mora; きょうゆう = 4 mora。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "きょう"), 2)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "きょうゆう"), 4)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "りゅう"), 2)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "じゅぎょう"), 3)
    }

    func testSokuonHatsuonAndChoonpuEachCount() {
        // きって = き・っ・て → 3; えんぴつ = え・ん・ぴ・つ → 4。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "きって"), 3)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "えんぴつ"), 4)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "あんない"), 4)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "こうこう"), 4)
        // セーター = セ・ー・タ・ー → 4 mora（长音符各计一个）。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "セーター"), 4)
    }

    func testLoanwordCombinations() {
        // ティッシュ = ティ・ッ・シュ → 3；ファミリー = ファ・ミ・リー → 4。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ティッシュ"), 3)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ファミリー"), 4)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ヴァイオリン"), 5)
        // フィードバック = フィ・ー・ド・バ・ッ・ク → 6 mora。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "フィードバック"), 6)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "チェック"), 3)
    }

    func testKatakanaAndHalfWidthNormalizeToSameCount() {
        XCTAssertEqual(
            JapaneseMoraCounter.moraCount(of: "タベル"),
            JapaneseMoraCounter.moraCount(of: "たべる")
        )
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ﾃｨｯｼｭ"), 3)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "キャンプ"), 3)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ｷｬﾝﾌﾟ"), 3)
    }

    func testLongWordsReachPitchSixAndBeyond() {
        // 7/6 mora 的长词允许音调 5、6 等合法大值存在空间。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "コミュニケーション"), 7)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "こうこうせい"), 6)
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: ""), 0)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "   "), 0)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: " たべる "), 3)
    }

    func testLeadingSmallKanaCountsAsItsOwnMora() {
        // 防御：开头的细小假名没有可并入的前一 mora，按一个 mora 计。
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ゃ"), 1)
        XCTAssertEqual(JapaneseMoraCounter.moraCount(of: "ゃく"), 2)
    }
}
