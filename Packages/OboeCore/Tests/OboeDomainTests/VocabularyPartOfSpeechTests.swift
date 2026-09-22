import XCTest
@testable import OboeDomain

/// T01 frozen POS contract (设计 §5.1)：原子白名单固定排序，读写按 " / "
/// 规范化连接；旧库未知值保留展示，不静默丢弃。
final class VocabularyPartOfSpeechTests: XCTestCase {
    func testWhitelistOrderIsFixed() {
        XCTAssertEqual(
            VocabularyPartOfSpeech.allCases.map(\.rawValue),
            [
                "名词", "代词",
                "五段动词", "一段动词", "する动词", "くる动词",
                "他动词", "自动词",
                "い形容词", "な形容词",
                "副词", "助词", "助动词", "接续词", "感叹词",
                "量词", "接头词", "接尾词", "表达"
            ]
        )
    }

    func testParseKnownAtomsComeBackInCanonicalOrder() {
        let (known, unknown) = VocabularyPartOfSpeech.parse("他动词 / 名词")
        XCTAssertEqual(known, [.noun, .transitive])
        XCTAssertTrue(unknown.isEmpty)
    }

    func testParseTrimsAndDeduplicates() {
        let (known, unknown) = VocabularyPartOfSpeech.parse(" 名词 /名词/  名词 ")
        XCTAssertEqual(known, [.noun])
        XCTAssertTrue(unknown.isEmpty)
    }

    func testParsePreservesUnknownLegacyValues() {
        let (known, unknown) = VocabularyPartOfSpeech.parse("名词 / 旧词性 / もう一つ")
        XCTAssertEqual(known, [.noun])
        XCTAssertEqual(unknown, ["旧词性", "もう一つ"])
    }

    func testParseEmptyProducesNothing() {
        for raw in ["", "   ", "/"] {
            let (known, unknown) = VocabularyPartOfSpeech.parse(raw)
            XCTAssertTrue(known.isEmpty, "raw: \(raw)")
            XCTAssertTrue(unknown.isEmpty, "raw: \(raw)")
        }
    }

    func testFormatJoinsInWhitelistOrder() {
        XCTAssertEqual(
            VocabularyPartOfSpeech.format([.transitive, .ichidanVerb]),
            "一段动词 / 他动词"
        )
        XCTAssertEqual(VocabularyPartOfSpeech.format([.noun]), "名词")
        XCTAssertNil(VocabularyPartOfSpeech.format([]))
    }

    func testRoundTripIsStable() {
        for stored in ["名词 / 他动词", "一段动词 / 他动词 / 助动词", "表达"] {
            let (known, unknown) = VocabularyPartOfSpeech.parse(stored)
            XCTAssertTrue(unknown.isEmpty)
            XCTAssertEqual(VocabularyPartOfSpeech.format(known), stored)
        }
    }

    /// 冻结验收：当前内置库出现过的全部原子值都在白名单内。
    /// （数据来自 T00 对 jlpt-library.sqlite 的 part_of_speech 审计。）
    func testBuiltInLibraryAtomsAreWhitelisted() {
        let builtInAtoms = [
            "名词", "他动词", "五段动词", "一段动词", "する动词",
            "副词", "い形容词", "表达", "接续词", "感叹词",
            "量词", "接头词", "接尾词", "助动词", "助词"
        ]
        for atom in builtInAtoms {
            XCTAssertNotNil(
                VocabularyPartOfSpeech(rawValue: atom),
                "built-in atom missing from whitelist: \(atom)"
            )
        }
    }
}
