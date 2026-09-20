import Foundation
import OboeDomain
import XCTest

/// T13 answer comparison: normalization, the headword+reading acceptance
/// set and the conservative close rule. Every result is feedback only —
/// `RecallComparison` can never produce or preselect a `ReviewRating`.
final class AnswerComparatorTests: XCTestCase {
    private func compare(
        _ input: String,
        headword: String?,
        reading: String? = nil
    ) -> RecallComparison? {
        AnswerComparator.compare(input: input, headword: headword, reading: reading)
    }

    /// Kanji headword and kana reading are interchangeable: either accepted
    /// answer matches, so script differences are never a dead-wrong verdict.
    func testHeadwordAndReadingBothAccepted() {
        let headword = "お母さん"
        let reading = "おかあさん"
        XCTAssertEqual(compare("お母さん", headword: headword, reading: reading), .matched)
        XCTAssertEqual(compare("おかあさん", headword: headword, reading: reading), .matched)
        XCTAssertEqual(compare("オカアサン", headword: headword, reading: reading), .matched)
    }

    /// NFKC folds half-width katakana into full-width before kana unification.
    func testHalfWidthKatakanaAndFullWidthVariantsMatch() {
        XCTAssertEqual(compare("ｳｹﾙ", headword: "受ける", reading: "うける"), .matched)
        XCTAssertEqual(compare("ウケル", headword: "受ける", reading: "うける"), .matched)
        XCTAssertEqual(compare("ｶﾞｯｺｳ", headword: "がっこう"), .matched)
    }

    func testLeadingAndTrailingWhitespaceIsIgnored() {
        for input in ["  おかあさん", "おかあさん　", "\n\tおかあさん\r\n", "　おかあさん\u{00a0}"] {
            XCTAssertEqual(
                compare(input, headword: "お母さん", reading: "おかあさん"),
                .matched,
                "input \(input.debugDescription)"
            )
        }
    }

    /// Decomposed input composes to the same scalar sequence after NFC.
    func testComposedAndDecomposedCharactersMatch() {
        let decomposed = "か\u{3099}っこう" // がっこう with combining dakuten
        XCTAssertEqual(compare(decomposed, headword: "がっこう"), .matched)
        XCTAssertEqual(compare("か\u{3099}くせい", headword: "学生", reading: "がくせい"), .matched)
    }

    /// Long vowels and geminates are meaningful: normalization must never
    /// collapse them, so these never reach matched. A length≥4 pure-kana
    /// answer one edit away is close; anything else stays different.
    func testLongVowelAndGeminateDistinctions() {
        XCTAssertEqual(compare("おばさん", headword: "おばあさん", reading: "おばあさん"), .close)
        XCTAssertEqual(compare("おばあさん", headword: "おばさん", reading: "おばさん"), .close)
        XCTAssertEqual(compare("きって", headword: "きて", reading: "きて"), .different)
        XCTAssertEqual(compare("おと", headword: "おっと", reading: "おっと"), .different)
        XCTAssertEqual(compare("ここ", headword: "こうこ", reading: "こうこ"), .different)
    }

    /// Without a stored reading, a kana answer can't be verified against the
    /// kanji headword — it lands on different with the self-assessment note,
    /// never an automatic fail.
    func testMissingReadingLeavesKanaAnswerDifferent() {
        XCTAssertEqual(compare("食べる", headword: "食べる", reading: nil), .matched)
        XCTAssertEqual(compare("たべる", headword: "食べる", reading: nil), .different)
        XCTAssertEqual(compare("たべる", headword: "食べる", reading: ""), .different)
        XCTAssertEqual(compare("たべる", headword: "食べる", reading: "たべる"), .matched)
    }

    /// Synonyms and unlisted kanji variants are legitimate answers the set
    /// does not know — different, with the honest "写法不同" copy in UI.
    func testSynonymsAndAlternativeWritingsAreDifferent() {
        XCTAssertEqual(compare("母親", headword: "お母さん", reading: "おかあさん"), .different)
        XCTAssertEqual(compare("鬱", headword: "うつ", reading: "うつ"), .different)
    }

    /// The close rule is deliberately conservative: it needs a pure-kana
    /// input of at least four characters a single edit away from an accepted
    /// answer. Short words and kanji answers never qualify.
    func testCloseRequiresLengthFourPureKanaAndEditDistanceOne() {
        XCTAssertEqual(compare("うけるる", headword: "受ける", reading: "うける"), .close)
        XCTAssertEqual(compare("うけれる", headword: "受ける", reading: "うける"), .close)
        XCTAssertEqual(compare("かたかに", headword: "かたかな", reading: "かたかな"), .close)
        XCTAssertEqual(compare("うけう", headword: "受ける", reading: "うける"), .different)
        XCTAssertEqual(compare("きて", headword: "きって", reading: "きって"), .different)
        XCTAssertEqual(compare("受けう", headword: "受ける", reading: "うける"), .different)
        XCTAssertEqual(compare("うけおお", headword: "受ける", reading: "うける"), .different)
    }

    /// Meaningful punctuation survives normalization — it is part of the
    /// string, so a trailing 。 keeps the answer off matched and off close.
    func testPunctuationIsNotStripped() {
        XCTAssertEqual(compare("こんにちは。", headword: "こんにちは", reading: "こんにちは"), .different)
        XCTAssertEqual(compare("食べる。", headword: "食べる", reading: "たべる"), .different)
    }

    func testBlankInputAndEmptyAcceptedSetReturnNil() {
        for input in ["", "   ", "　", "\n"] {
            XCTAssertNil(compare(input, headword: "食べる", reading: "たべる"))
        }
        XCTAssertNil(compare("たべる", headword: nil, reading: nil))
        XCTAssertNil(compare("たべる", headword: "", reading: "  "))
        XCTAssertNil(compare("たべる", headword: "　", reading: nil))
    }
}
