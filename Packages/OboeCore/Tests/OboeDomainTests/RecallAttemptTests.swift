import Foundation
import OboeDomain
import XCTest

final class RecallAttemptTests: XCTestCase {
    private let enabled = AdaptivePreferences(
        typedAnswerChineseToJapanese: true,
        autoPlayListeningAudio: true,
        typedAnswerListening: true,
        leechRemindersEnabled: true
    )

    /// v0.5.5 产品默认：两个主动回忆输入开关均为开启（其余两项保持开启）。
    func testAdaptivePreferencesDefaultsEnableBothTypedRecalls() {
        XCTAssertTrue(AdaptivePreferences.defaults.typedAnswerChineseToJapanese)
        XCTAssertTrue(AdaptivePreferences.defaults.autoPlayListeningAudio)
        XCTAssertTrue(AdaptivePreferences.defaults.typedAnswerListening)
        XCTAssertTrue(AdaptivePreferences.defaults.leechRemindersEnabled)
    }

    private func attempt(
        cardID: UUID = UUID(),
        preferences: AdaptivePreferences? = nil
    ) -> RecallAttempt {
        RecallAttempt(
            cardID: cardID, contentVersion: 1,
            template: .vocabularyChineseToJapanese,
            preferences: preferences ?? enabled
        )
    }

    /// v0.5.5：产品默认改为中文→日文与听力卡先输入回答（typedJapanese），
    /// 其余模板仍 reveal-only；每个开关只作用于自己的模板。
    func testModeUsesOnlyItsOwnTemplatePreferenceAndTypedDefaults() {
        XCTAssertEqual(
            RecallMode.resolve(template: .vocabularyChineseToJapanese, preferences: .defaults),
            .typedJapanese
        )
        XCTAssertEqual(
            RecallMode.resolve(template: .vocabularyListening, preferences: .defaults),
            .typedJapanese
        )
        for template in [CardTemplateKind.vocabularyJapaneseToChinese, .grammarFormToExplanation] {
            XCTAssertEqual(RecallMode.resolve(template: template, preferences: .defaults), .revealOnly)
        }
        for chinese in [false, true] {
            for listening in [false, true] {
                let preferences = AdaptivePreferences(
                    typedAnswerChineseToJapanese: chinese,
                    autoPlayListeningAudio: false,
                    typedAnswerListening: listening,
                    leechRemindersEnabled: false
                )
                XCTAssertEqual(RecallMode.resolve(template: .vocabularyChineseToJapanese, preferences: preferences), chinese ? .typedJapanese : .revealOnly)
                XCTAssertEqual(RecallMode.resolve(template: .vocabularyListening, preferences: preferences), listening ? .typedJapanese : .revealOnly)
                XCTAssertEqual(RecallMode.resolve(template: .vocabularyJapaneseToChinese, preferences: preferences), .revealOnly)
                XCTAssertEqual(RecallMode.resolve(template: .grammarFormToExplanation, preferences: preferences), .revealOnly)
            }
        }
    }

    func testEmptyAndWhitespaceCannotConfirmOrSubmit() {
        var state = attempt()
        for input in ["", " ", "\n\t\r", "　", "\u{00a0}"] {
            XCTAssertTrue(state.updateInput(input))
            XCTAssertFalse(state.canConfirm)
            XCTAssertFalse(state.confirmInput())
            XCTAssertFalse(state.beginSubmission(eventID: UUID()))
            XCTAssertEqual(state.phase, .question)
            XCTAssertNil(state.pendingEventID)
        }
    }

    func testConfirmationFreezesOriginalInputAndDoesNotCreateReviewEvent() {
        var state = attempt()
        XCTAssertTrue(state.updateInput("  おかあさん　"))
        XCTAssertTrue(state.confirmInput(comparison: .matched))
        XCTAssertEqual(state.phase, .answer)
        XCTAssertEqual(state.rawInput, "  おかあさん　")
        XCTAssertEqual(state.comparison, .matched)
        XCTAssertNil(state.pendingEventID)
        let confirmed = state
        XCTAssertFalse(state.confirmInput(comparison: .different))
        XCTAssertFalse(state.updateInput("別の回答"))
        XCTAssertEqual(state, confirmed)
    }

    func testRevealOnlyKeepsOriginalRevealFlow() {
        // v0.5.5 起 .defaults 已开启 typed 输入；reveal 路径须显式关闭。
        var state = attempt(preferences: AdaptivePreferences(
            typedAnswerChineseToJapanese: false,
            autoPlayListeningAudio: true,
            typedAnswerListening: false,
            leechRemindersEnabled: true
        ))
        XCTAssertFalse(state.updateInput("入力"))
        XCTAssertTrue(state.canConfirm)
        XCTAssertTrue(state.confirmInput(comparison: .matched))
        XCTAssertEqual(state.phase, .answer)
        XCTAssertEqual(state.rawInput, "")
        XCTAssertNil(state.comparison)
        XCTAssertNil(state.pendingEventID)
    }

    func testSubmissionFailureRetainsInputComparisonAndSameEventForRetry() {
        var state = attempt()
        state.updateInput("おかあさん")
        state.confirmInput(comparison: .close)
        let eventID = UUID()
        XCTAssertTrue(state.beginSubmission(eventID: eventID))
        XCTAssertEqual(state.phase, .submitting)
        XCTAssertFalse(state.updateInput("変更"))
        XCTAssertFalse(state.confirmInput())
        XCTAssertFalse(state.beginSubmission(eventID: eventID))
        XCTAssertFalse(state.submissionFailed(eventID: UUID()))
        XCTAssertEqual(state.phase, .submitting)
        XCTAssertTrue(state.submissionFailed(eventID: eventID))
        XCTAssertEqual(state.phase, .answer)
        XCTAssertEqual(state.rawInput, "おかあさん")
        XCTAssertEqual(state.comparison, .close)
        XCTAssertEqual(state.pendingEventID, eventID)
        XCTAssertFalse(state.beginSubmission(eventID: UUID()))
        XCTAssertTrue(state.beginSubmission(eventID: eventID))
    }

    func testOrdinaryRefreshPreservesQuestionAnswerAndFailedSubmission() {
        var state = attempt()
        state.updateInput("おか")
        let question = state
        state.reloadContent(version: 1)
        XCTAssertEqual(state, question)
        state.confirmInput()
        let eventID = UUID()
        state.beginSubmission(eventID: eventID)
        state.submissionFailed(eventID: eventID)
        let failed = state
        state.reloadContent(version: 1)
        XCTAssertEqual(state, failed)
    }

    func testContentChangeResetsAllTransientStateAndIgnoresOldFailure() {
        var state = attempt()
        state.updateInput("回答")
        state.confirmInput(comparison: .different)
        let eventID = UUID()
        state.beginSubmission(eventID: eventID)
        state.reloadContent(version: 2)
        XCTAssertEqual(state.contentVersion, 2)
        assertClean(state)
        XCTAssertFalse(state.submissionFailed(eventID: eventID))
        XCTAssertEqual(state.mode, .typedJapanese)
    }

    func testUndoRestartClearsEvenWhenContentVersionIsUnchanged() {
        var state = attempt()
        state.updateInput("回答")
        state.confirmInput(comparison: .matched)
        state.beginSubmission(eventID: UUID())
        state.restart()
        assertClean(state)
        XCTAssertEqual(state.contentVersion, 1)
    }

    func testNextPresentationClearsInputEvenForSameCardAndSamplesNewSettings() {
        let id = UUID()
        var current = attempt(cardID: id)
        current.updateInput("回答")
        current.confirmInput(comparison: .matched)
        // v0.5.5 起 .defaults 为 typed；用显式关闭的偏好验证 reveal 采样。
        let nextPreferences = AdaptivePreferences(
            typedAnswerChineseToJapanese: false,
            autoPlayListeningAudio: true,
            typedAnswerListening: false,
            leechRemindersEnabled: true
        )
        current.reloadContent(version: 2)
        XCTAssertEqual(current.mode, .typedJapanese)
        let repeatedCard = attempt(cardID: id, preferences: nextPreferences)
        XCTAssertEqual(repeatedCard.mode, .revealOnly)
        assertClean(repeatedCard)
        let nextCard = attempt(preferences: nextPreferences)
        XCTAssertNotEqual(nextCard.cardID, current.cardID)
        assertClean(nextCard)
    }

    private func assertClean(_ state: RecallAttempt, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.phase, .question, file: file, line: line)
        XCTAssertEqual(state.rawInput, "", file: file, line: line)
        XCTAssertNil(state.comparison, file: file, line: line)
        XCTAssertNil(state.pendingEventID, file: file, line: line)
    }
}
