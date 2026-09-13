import XCTest
@testable import OboeDomain

final class JapaneseSpeechTests: XCTestCase {
    func testVocabularySpeechPrefersReadingAndQueuesExampleAfterReveal() {
        let policy = ReviewSpeechPolicy(
            content: content(
                template: .vocabularyJapaneseToChinese,
                headword: "食べる",
                reading: "たべる",
                example: "毎朝パンを食べます。"
            )
        )
        let preferences = SpeechPreferences(
            autoPlayWordAudio: true,
            autoPlayExampleAudio: true
        )

        XCTAssertEqual(policy.primaryText, "たべる")
        XCTAssertEqual(policy.automaticQuestionTexts(preferences: preferences), ["たべる"])
        XCTAssertEqual(
            policy.automaticAnswerTexts(preferences: preferences),
            ["毎朝パンを食べます。"]
        )
    }

    func testChineseToJapaneseNeverLeaksJapaneseBeforeReveal() {
        let policy = ReviewSpeechPolicy(
            content: content(
                template: .vocabularyChineseToJapanese,
                headword: "見る",
                reading: "みる",
                example: "映画を見ます。"
            )
        )
        let preferences = SpeechPreferences(
            autoPlayWordAudio: true,
            autoPlayExampleAudio: true
        )

        XCTAssertFalse(policy.exposesJapaneseOnQuestion)
        XCTAssertTrue(policy.exposesPrimaryOnAnswer)
        XCTAssertTrue(policy.automaticQuestionTexts(preferences: preferences).isEmpty)
        XCTAssertEqual(
            policy.automaticAnswerTexts(preferences: preferences),
            ["みる", "映画を見ます。"]
        )
    }

    func testDefaultsDisableAutomaticSpeechAndMissingReadingFallsBackToForm() {
        let policy = ReviewSpeechPolicy(
            content: content(
                template: .grammarFormToExplanation,
                headword: "～たことがある",
                reading: nil,
                example: nil
            )
        )

        XCTAssertEqual(policy.primaryText, "～たことがある")
        XCTAssertTrue(policy.automaticQuestionTexts(preferences: .defaults).isEmpty)
        XCTAssertTrue(policy.automaticAnswerTexts(preferences: .defaults).isEmpty)
    }

    private func content(
        template: CardTemplateKind,
        headword: String,
        reading: String?,
        example: String?
    ) -> ReviewCardContent {
        ReviewCardContent(
            cardID: UUID(),
            noteID: UUID(),
            deckID: UUID(),
            templateKind: template,
            headword: headword,
            reading: reading,
            meaningZH: "含义",
            partOfSpeech: nil,
            usage: nil,
            connection: nil,
            exampleJapanese: example,
            exampleTranslationZH: nil,
            notes: nil
        )
    }
}
