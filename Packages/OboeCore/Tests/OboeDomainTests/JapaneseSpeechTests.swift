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

    /// T15/§8: explicit template branches — a listening card's question face
    /// exposes nothing through the word-audio channel (its prompt audio rides
    /// `autoPlayListeningAudio` in T18), while the answer face may still speak
    /// the revealed headword/reading.
    func testListeningCardExposesNoJapaneseOnQuestionAndSpeaksPrimaryAfterReveal() {
        let policy = ReviewSpeechPolicy(
            content: content(
                template: .vocabularyListening,
                headword: "聞く",
                reading: "きく",
                example: "音楽を聞きます。"
            )
        )
        let preferences = SpeechPreferences(
            autoPlayWordAudio: true,
            autoPlayExampleAudio: true
        )

        XCTAssertFalse(policy.exposesJapaneseOnQuestion)
        XCTAssertTrue(policy.automaticQuestionTexts(preferences: preferences).isEmpty)
        XCTAssertTrue(policy.exposesPrimaryOnAnswer)
        XCTAssertEqual(policy.primaryText, "きく")
        XCTAssertEqual(
            policy.automaticAnswerTexts(preferences: preferences),
            ["きく", "音楽を聞きます。"]
        )
    }

    /// T17/§8.2: the listening prompt speaks ONLY the word — non-empty reading
    /// preferred, headword fallback, never the example sentence — and the
    /// channel is closed for every other template.
    func testListeningPromptIsReadingOrHeadwordOnly() {
        let withReading = ReviewSpeechPolicy(
            content: content(
                template: .vocabularyListening,
                headword: "聞く",
                reading: "きく",
                example: "音楽を聞きます。"
            )
        )
        XCTAssertEqual(withReading.listeningPromptText, "きく")

        let withoutReading = ReviewSpeechPolicy(
            content: content(
                template: .vocabularyListening,
                headword: "聞く",
                reading: nil,
                example: "音楽を聞きます。"
            )
        )
        XCTAssertEqual(withoutReading.listeningPromptText, "聞く")

        let blankReading = ReviewSpeechPolicy(
            content: content(
                template: .vocabularyListening,
                headword: "聞く",
                reading: "  ",
                example: nil
            )
        )
        XCTAssertEqual(blankReading.listeningPromptText, "聞く")

        for template in [
            CardTemplateKind.vocabularyJapaneseToChinese,
            .vocabularyChineseToJapanese,
            .grammarFormToExplanation
        ] {
            let policy = ReviewSpeechPolicy(
                content: content(
                    template: template,
                    headword: "聞く",
                    reading: "きく",
                    example: "音楽を聞きます。"
                )
            )
            XCTAssertNil(policy.listeningPromptText, "\(template.rawValue) 不得走听力提示音频通道")
        }
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
