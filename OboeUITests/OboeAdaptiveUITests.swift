import XCTest
import UIKit

/// T03 UI coverage: the seeded fixture (OBOE_UI_TEST_ADAPTIVE_SEED) provides
/// one leech ja→zh card (lapses 6, six due-review Agains, due now) and one
/// warning zh→ja card (lapses 3, due later) on the same note — exercising the
/// home entry, filter counts, detail page and the answer-face reminder
/// without reaching into the database.
final class OboeAdaptiveUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecallMarkedTextReturnCommitsCompositionBeforeAnswer() {
        let field = UITextField()
        let controller = RecallInputController()
        controller.field = field
        var confirmations = 0
        var input = ""
        controller.onInput = { input = $0 }
        controller.onConfirm = { confirmations += 1 }
        field.setMarkedText("うける", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        XCTAssertFalse(controller.textFieldShouldReturn(field))
        XCTAssertNil(field.markedTextRange)
        XCTAssertEqual(input, "うける")
        XCTAssertEqual(confirmations, 0)
        XCTAssertFalse(controller.textFieldShouldReturn(field))
        XCTAssertEqual(confirmations, 1)
        field.text = "　 \n"
        controller.confirm()
        XCTAssertEqual(confirmations, 1)
        field.text = String(repeating: "あ", count: 201)
        controller.confirm()
        XCTAssertEqual(confirmations, 1)
    }

    @MainActor
    func testChineseToJapaneseRecallDisabledKeepsRevealFlow() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_SEED"] = "1"
        // v0.5.5 起默认开启——本用例正是验证"关闭后保持 reveal 流程"，
        // 不能再依赖旧默认，显式传 off。
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let reveal = app.buttons["review-show-answer-button"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["review-recall-input"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        reveal.tap()
        XCTAssertTrue(app.buttons["review-rating-easy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["你的答案"].exists)
    }

    @MainActor
    func testTypedRecallConfirmForegroundRetryAndUndo() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SUBMIT_FAILURES"] = "1"
        app.launch()
        app.openSettingsFromTodayGear()
        let toggle = app.switches["adaptive-typed-answer-zh-ja-toggle"]
        reveal(toggle, in: app)
        setSwitch(toggle, enabled: true, in: app)
        app.dismissSettingsSheet()
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-start-button"].tap()
        let input = app.textFields["review-recall-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let confirm = app.buttons["review-confirm-input-button"]
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertFalse(app.buttons["review-show-answer-button"].exists)
        XCTAssertFalse(app.buttons["review-rating-easy"].exists)
        XCTAssertFalse(app.staticTexts["受ける"].exists)
        input.typeText("ukeru")
        app.scrollViews["review-content-scroll"].swipeUp()
        XCTAssertEqual(input.value as? String, "ukeru")
        XCTAssertTrue(confirm.isHittable)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "ukeru")
        input.tap()
        input.typeText("\n")
        let answer = app.staticTexts["review-your-answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertEqual(answer.label, "ukeru")
        XCTAssertTrue(app.staticTexts["标准答案"].exists)
        XCTAssertTrue(app.staticTexts["review-progress-summary"].label.contains("已完成 0"))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.isHittable)
        easy.tap()
        let retry = app.buttons["review-retry-button"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(answer.label, "ukeru")
        retry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5))
        // The adaptive fixture attributes the sibling's six historical Again
        // logs to this study day. Our reverse card adds one card and one Easy.
        XCTAssertEqual(app.descendants(matching: .any)["review-statistics-total"].label, "合计 2 张")
        XCTAssertEqual(app.staticTexts["review-statistics-rating-easy"].label, "简单 1")
        app.buttons["review-undo-button"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue((input.value as? String) == "请用日语回答" || (input.value as? String) == "")
        XCTAssertFalse(confirm.isEnabled)
        input.typeText("answer")
        app.buttons["review-dismiss-keyboard-button"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertEqual(answer.label, "answer")
    }

    /// T13: after confirming a typed answer the comparison result shows as
    /// feedback copy under 你的答案 — matched/close/different — while the four
    /// rating buttons remain the only way to record a review.
    @MainActor
    func testTypedRecallComparisonFeedback() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_SEED"] = "1"
        app.launch()
        app.openSettingsFromTodayGear()
        let toggle = app.switches["adaptive-typed-answer-zh-ja-toggle"]
        reveal(toggle, in: app)
        setSwitch(toggle, enabled: true, in: app)
        app.dismissSettingsSheet()
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-start-button"].tap()
        let input = app.textFields["review-recall-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let confirm = app.buttons["review-confirm-input-button"]
        let feedback = app.staticTexts["review-comparison-feedback"]
        let answer = app.staticTexts["review-your-answer"]
        let complete = app.descendants(matching: .any)["review-complete-state"]
        let undo = app.buttons["review-undo-button"]

        XCTAssertFalse(feedback.exists, "问题面不得出现对比结果")

        // matched：命中 reading，展示原文输入；评分仍需显式选择。
        input.typeText("うける")
        confirm.tap()
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.label, "和标准答案一致。")
        XCTAssertEqual(answer.label, "うける")
        XCTAssertTrue(app.staticTexts["标准答案"].exists)
        XCTAssertTrue(app.buttons["review-rating-easy"].isHittable)
        XCTAssertFalse(complete.exists)
        app.buttons["review-rating-easy"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(feedback.exists)

        // close：长度≥4 纯假名、编辑距离 1。
        input.typeText("うけれる")
        confirm.tap()
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.label, "和标准答案接近，请对照差异自评。")
        app.buttons["review-rating-easy"].tap()
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))

        // different：只说明写法不同，自评仍由用户完成。
        input.typeText("たべもの")
        confirm.tap()
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertEqual(feedback.label, "写法不同，请对照答案自评。")
        XCTAssertTrue(app.buttons["review-rating-easy"].isHittable)
        XCTAssertFalse(complete.exists)
    }

    /// T14: largest accessibility type size + a long standard answer — the
    /// answer scrolls inside the card, the rating grid collapses to two
    /// columns, and a failed submission's error copy plus retry stay
    /// reachable so nothing truncates into an unsubmittable state.
    @MainActor
    func testTypedRecallLongAnswerAccessibilitySizeAndRetry() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_SEED"] = "long"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_DYNAMIC_TYPE"] = "ax5"
        app.launchEnvironment["OBOE_UI_TEST_SUBMIT_FAILURES"] = "1"
        app.launch()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let input = app.textFields["review-recall-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("わかりません")
        app.buttons["review-confirm-input-button"].tap()
        XCTAssertTrue(app.staticTexts["review-your-answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["review-comparison-feedback"].exists)
        // 长答案随卡片滚动容器可达；评分区由底部安全区域承载，始终可点。
        let scroll = app.scrollViews["review-content-scroll"]
        XCTAssertTrue(scroll.exists)
        scroll.swipeUp()
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 5))
        XCTAssertTrue(easy.isHittable, "大字号长答案下评分按钮必须可达")
        easy.tap()
        let retry = app.buttons["review-retry-button"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "提交失败必须显示错误文案与重试")
        retry.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"]
                .waitForExistence(timeout: 5)
        )
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "t14-ax5-long-answer-complete"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// T14: the question face carries no answer content in the accessibility
    /// tree — no 标准答案/你的答案/对比反馈, no Japanese headword/reading text
    /// and no question-side speech button for zh→ja — under dark appearance.
    /// After confirming, the answer group appears. (Reduce Motion remains a
    /// read-only trait — real-device verification is deferred to T28.)
    @MainActor
    func testTypedRecallQuestionFaceHasNoAnswerLeakage() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_APPEARANCE_DARK"] = "1"
        app.launch()
        app.openSettingsFromTodayGear()
        let toggle = app.switches["adaptive-typed-answer-zh-ja-toggle"]
        reveal(toggle, in: app)
        setSwitch(toggle, enabled: true, in: app)
        app.dismissSettingsSheet()
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-start-button"].tap()
        let input = app.textFields["review-recall-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.descendants(matching: .any)["review-answer"].exists)
        XCTAssertFalse(app.staticTexts["review-your-answer"].exists)
        XCTAssertFalse(app.staticTexts["review-comparison-feedback"].exists)
        XCTAssertFalse(app.staticTexts["标准答案"].exists)
        XCTAssertFalse(app.staticTexts["受ける"].exists)
        XCTAssertFalse(app.staticTexts["うける"].exists)
        XCTAssertFalse(
            app.buttons["review-question-speech-button"].exists,
            "中文→日文问题面不得提供朗读答案的按钮"
        )
        input.typeText("うける")
        app.buttons["review-confirm-input-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["review-your-answer"].exists)
        XCTAssertTrue(app.staticTexts["review-comparison-feedback"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "t14-dark-answer-face"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// T17: the listening card's question face carries ONLY the play button
    /// and a generic hint — no headword/reading/meaning/example text and no
    /// word-audio button. Manual replay keeps the answer hidden; after reveal
    /// the full answer (with word/example audio) appears; rating advances to
    /// the sibling direction's normal visual card.
    @MainActor
    func testListeningCardQuestionFaceAndDirectionSwitch() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        // T18: deterministic playback — autoplay fires on load and completes.
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "ok"
        // v0.5.5：听力与 zh→ja 卡均默认 typed——本用例审计 reveal
        // 问题面与方向切换，两个开关都显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_TYPED_PREF"] = "0"
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()

        app.buttons["today-start-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5)
        )

        // 问题面：播放按钮与通用说明存在，四类文字答案均不在无障碍树中。
        let playButton = app.buttons["review-listening-play-button"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 5), "听力卡必须提供播放按钮")
        XCTAssertTrue(app.staticTexts["请听音频，回忆含义"].exists)
        XCTAssertFalse(app.staticTexts["聞く"].exists, "问题面不得出现词形")
        XCTAssertFalse(app.staticTexts["きく"].exists, "问题面不得出现假名")
        XCTAssertFalse(app.staticTexts["听；询问"].exists, "问题面不得出现释义")
        XCTAssertFalse(app.staticTexts["毎朝ラジオを聞く。"].exists, "问题面不得出现例句")
        XCTAssertFalse(
            app.buttons["review-question-speech-button"].exists,
            "听力问题面不得出现 word-audio 朗读按钮"
        )
        XCTAssertFalse(app.descendants(matching: .any)["review-answer"].exists)

        // 自动播放完成（T18）：状态文本出现且未揭示答案。
        XCTAssertTrue(
            app.staticTexts["review-listening-status"].waitForExistence(timeout: 5),
            "自动播放完成后应出现播放状态"
        )
        XCTAssertFalse(app.descendants(matching: .any)["review-answer"].exists)

        // 手动重播：播放不揭示答案。
        playButton.tap()
        XCTAssertFalse(app.descendants(matching: .any)["review-answer"].exists)

        // 揭示答案：完整内容 + 答案面词/例句朗读按钮。
        showReviewAnswer(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["聞く"].exists)
        XCTAssertTrue(app.staticTexts["きく"].exists)
        XCTAssertTrue(app.staticTexts["听；询问"].exists)
        XCTAssertTrue(app.buttons["review-answer-speech-button"].exists)

        // 评分后切到视觉方向卡：中文问题文本 + 无听力播放按钮。
        app.buttons["review-rating-easy"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["吃"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-listening-play-button"].exists)
        XCTAssertTrue(app.buttons["review-show-answer-button"].exists)
    }

    /// T17: 听力卡输入自 v0.5.5 起默认开启——设置页先验证默认值，
    /// 听力卡随后要求先日语复述再揭示；对比仅为反馈。zh→ja 同胞卡经
    /// `OBOE_UI_TEST_TYPED_RECALL_PREF=0` 显式关闭以保持逐模板门控断言。
    @MainActor
    func testListeningTypedRecallUsesInputThenRevealsAnswer() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "ok"
        // v0.5.5：zh→ja 同胞卡也默认 typed——为保留逐模板门控断言，
        // 显式关闭 zh→ja，让后半段仍落在 reveal-only 路径。
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()

        app.openSettingsFromTodayGear()
        let toggle = app.switches["adaptive-typed-answer-listening-toggle"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "听力输入自 v0.5.5 起默认开启")
        setSwitch(toggle, enabled: true, in: app)

        app.tabBars.buttons["今日"].tap()
        app.buttons["today-start-button"].tap()

        let input = app.textFields["review-recall-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "开启后听力卡必须出现输入框")
        XCTAssertTrue(app.buttons["review-listening-play-button"].exists)
        XCTAssertFalse(app.buttons["review-show-answer-button"].exists)
        XCTAssertFalse(app.staticTexts["聞く"].exists)

        // T18: 确认需等播放完成（自动播放默认开启）。
        XCTAssertTrue(app.staticTexts["review-listening-status"].waitForExistence(timeout: 5))
        input.typeText("きく")
        app.buttons["review-confirm-input-button"].tap()
        XCTAssertTrue(
            app.staticTexts["review-your-answer"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.staticTexts["review-your-answer"].label, "きく")
        XCTAssertEqual(
            app.staticTexts["review-comparison-feedback"].label,
            "和标准答案一致。"
        )
        // 对比仅为反馈：评分仍需显式点击。
        XCTAssertTrue(app.buttons["review-rating-easy"].isHittable)
        app.buttons["review-rating-easy"].tap()

        // 下一张 zh→ja 卡未开输入开关 → 回到 reveal-only 流程。
        XCTAssertTrue(
            app.buttons["review-show-answer-button"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.textFields["review-recall-input"].exists)
    }

    /// T18: with 自动播放关闭 the question face must not auto-play — the
    /// reveal button stays disabled behind "请先播放音频" until the user
    /// plays manually and playback completes.
    @MainActor
    func testListeningAutoplayOffManualPlayAndRevealGate() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_AUTOPLAY_OFF"] = "1"
        // v0.5.5：听力卡现为 typed 默认——本用例验证 reveal 门控，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_TYPED_PREF"] = "0"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "ok"
        app.launch()

        app.buttons["today-start-button"].tap()
        let playButton = app.buttons["review-listening-play-button"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 5))

        // 未播放：不自动播放（无状态文本），揭示被门控。
        XCTAssertFalse(app.staticTexts["review-listening-status"].exists)
        let showAnswer = app.buttons["review-show-answer-button"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 5))
        XCTAssertFalse(showAnswer.isEnabled, "未播放音频时不得允许翻答案")
        XCTAssertTrue(
            app.descendants(matching: .any)["review-listening-play-first-hint"].exists
        )

        // 手动播放完成后门控解除。
        playButton.tap()
        XCTAssertTrue(app.staticTexts["review-listening-status"].waitForExistence(timeout: 5))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: showAnswer)
        waitForExpectations(timeout: 5)
        showAnswer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["聞く"].exists)
    }

    /// T18: question-face audioSessionUnavailable marks the card skipped for
    /// the session — no rating, no scheduling write, no re-pick loop. After
    /// the remaining card is rated the "暂无法播放" state keeps the real
    /// remaining count and offers an explicit retry that re-checks.
    @MainActor
    func testListeningAudioFailureSkipsWithoutRatingAndRetries() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "fail"
        // v0.5.5：zh→ja 卡现为 typed 默认——本用例覆盖 reveal 流程，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()

        app.buttons["today-start-button"].tap()

        // 失败 → 跳过听力卡 → 轻提示 + 下一张（zh→ja 视觉卡）。
        XCTAssertTrue(
            app.descendants(matching: .any)["review-listening-skip-notice"]
                .waitForExistence(timeout: 5),
            "音频失败后必须显示跳过轻提示"
        )
        XCTAssertTrue(app.staticTexts["吃"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-listening-play-button"].exists)

        // 评完剩余卡 → 仅剩被跳过的听力卡 → “暂无法播放”态而非完成态。
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()
        let skippedState = app.descendants(matching: .any)["review-listening-skipped-state"]
        XCTAssertTrue(skippedState.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["剩余 1 张听力卡暂无法播放"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["review-complete-state"].exists,
            "音频跳过不得显示为今日完成"
        )

        // 显式重试：清空跳过集并重新检查 → 仍失败 → 回到同一状态。
        app.buttons["review-listening-retry-button"].tap()
        XCTAssertTrue(skippedState.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["剩余 1 张听力卡暂无法播放"].exists)
    }

    /// T18: no Japanese voice at all — the listening card is skipped at load
    /// (装载发现 voiceUnavailable) and the next card is presented instead.
    @MainActor
    func testListeningVoiceUnavailableSkipsAtLoad() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_UNAVAILABLE"] = "1"
        app.launch()

        app.buttons["today-start-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-listening-skip-notice"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["吃"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-listening-play-button"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-speech-unavailable"].exists
        )
    }

    /// T18: a started-but-never-completed playback keeps the reveal gate
    /// closed — "引擎开始" is not proof of audible output (设计 §8.3).
    @MainActor
    func testListeningPendingPlaybackKeepsRevealGated() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "pending"
        // v0.5.5：听力卡现为 typed 默认——本用例验证 reveal 门控，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_TYPED_PREF"] = "0"
        app.launch()

        app.buttons["today-start-button"].tap()
        XCTAssertTrue(
            app.buttons["review-listening-play-button"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["review-listening-status"].waitForExistence(timeout: 5)
        )
        let showAnswer = app.buttons["review-show-answer-button"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 5))
        // 播放未完成的短时间内答案必须仍被门控。
        XCTAssertFalse(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(showAnswer.isEnabled)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-listening-play-first-hint"].exists
        )
    }

    /// T18: answer-face speech failure (例句/词朗读) only alerts — it must
    /// neither skip the card nor discard the completed recall (设计 §8.3).
    @MainActor
    func testAnswerFaceSpeechFailureAlertsWithoutSkipping() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "fail"
        // v0.5.5：zh→ja 卡现为 typed 默认——本用例覆盖 reveal 流程，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()

        app.buttons["today-start-button"].tap()
        // 听力卡失败后跳过 → 视觉卡。
        XCTAssertTrue(app.staticTexts["吃"].waitForExistence(timeout: 5))
        showReviewAnswer(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5))

        // 答案面朗读失败：弹窗提示，卡片留在原处可正常评分。
        app.buttons["review-answer-speech-button"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["知道了"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].exists)
        XCTAssertFalse(app.buttons["review-listening-retry-button"].exists)
        app.buttons["review-rating-easy"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-listening-skipped-state"]
                .waitForExistence(timeout: 5)
        )
    }

    /// T19 (设计 §8.2/§12): full accessibility-tree traversal — the listening
    /// question face must contain no headword/reading/meaning/example text in
    /// ANY element's label/value/identifier, across autoplay completion,
    /// manual replay, and background return. Dark appearance + maximum
    /// assistive text size cover the presentation variants in the same pass.
    /// The reveal is the positive control: the same strings must appear then.
    @MainActor
    func testListeningQuestionFaceAccessibilityTreeExcludesAnswerContent() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "ok"
        // v0.5.5：听力卡现为 typed 默认——本用例审计 reveal 问题面，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_TYPED_PREF"] = "0"
        app.launchEnvironment["OBOE_UI_TEST_APPEARANCE_DARK"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_DYNAMIC_TYPE"] = "ax5"
        app.launch()

        app.buttons["today-start-button"].tap()
        XCTAssertTrue(
            app.buttons["review-listening-play-button"].waitForExistence(timeout: 8)
        )
        // 自动播放完成后的首个问题面。
        XCTAssertTrue(
            app.staticTexts["review-listening-status"].waitForExistence(timeout: 8)
        )
        assertListeningQuestionFaceFreeOfAnswerContent(app)

        // 手动重播后仍然无泄漏。
        app.buttons["review-listening-play-button"].tap()
        assertListeningQuestionFaceFreeOfAnswerContent(app)

        // 后台返回：播放被打断只算取消，问题面不泄题、仍可重播。
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.buttons["review-listening-play-button"].waitForExistence(timeout: 8)
        )
        assertListeningQuestionFaceFreeOfAnswerContent(app)

        // 正控：揭示后同样的检查必须能命中答案文本（证明遍历有效）。
        showReviewAnswer(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 8)
        )
        let revealedTree = app.debugDescription
        for expected in ["聞く", "きく", "听；询问", "ラジオを聞く"] {
            XCTAssertTrue(
                revealedTree.contains(expected), "揭示后无障碍树应包含答案文本「\(expected)」"
            )
        }
    }

    /// T19: with autoplay OFF the question face is still clean — no status
    /// text, no answer content, and the manual play path stays gated until
    /// playback completes.
    @MainActor
    func testListeningAutoplayOffQuestionFaceAccessibilityTree() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_AUTOPLAY_OFF"] = "1"
        // v0.5.5：听力卡现为 typed 默认——本用例审计 reveal 问题面，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_TYPED_PREF"] = "0"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "ok"
        app.launch()

        app.buttons["today-start-button"].tap()
        XCTAssertTrue(
            app.buttons["review-listening-play-button"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.staticTexts["review-listening-status"].exists)
        assertListeningQuestionFaceFreeOfAnswerContent(app)

        app.buttons["review-listening-play-button"].tap()
        XCTAssertTrue(
            app.staticTexts["review-listening-status"].waitForExistence(timeout: 5)
        )
        assertListeningQuestionFaceFreeOfAnswerContent(app)
    }

    /// T19: the optional typed-input question face — the field's placeholder
    /// and label are generic ("请用日语复述听到的内容"), the tree is clean
    /// before and while typing a non-answer string, and the confirm path
    /// reveals the answer as the positive control.
    @MainActor
    func testListeningTypedInputQuestionFaceAccessibilityTree() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "ok"
        app.launchEnvironment["OBOE_UI_TEST_LISTENING_TYPED_PREF"] = "1"
        app.launch()

        app.buttons["today-start-button"].tap()
        let input = app.textFields["review-recall-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["review-listening-status"].waitForExistence(timeout: 5)
        )
        assertListeningQuestionFaceFreeOfAnswerContent(app)
        XCTAssertEqual(
            input.label, "请用日语复述听到的内容", "输入框 label 必须为通用提示"
        )

        // 用户自输非答案文本：树中出现的是输入值，不是卡片答案。
        input.typeText("あいう")
        assertListeningQuestionFaceFreeOfAnswerContent(app)

        app.buttons["review-confirm-input-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["聞く"].exists)
        XCTAssertTrue(app.staticTexts["毎朝ラジオを聞く。"].exists)
    }

    /// T21 (设计 §9): deck-scoped session — the sibling policy separates
    /// note A's two directions across rating refreshes (A-ja2zh → B →
    /// A-zh2ja), and the globally-earliest card in deck「干扰牌组」never
    /// appears. The listening sibling precheck-skips (speech unavailable).
    @MainActor
    func testScopedDeckSiblingSeparationAcrossRefresh() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_SIBLING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_UNAVAILABLE"] = "1"
        // v0.5.5：A-zh2ja 卡现为 typed 默认——本用例覆盖 reveal 流程，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()

        enterScopedReview(deckNamed: "错开牌组", in: app)

        // A-ja2zh first (queue order), then the sibling A-zh2ja yields to B.
        XCTAssertTrue(app.staticTexts["読む"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["習う"].exists, "干扰牌组的卡不得出现在 scoped 会话")
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()

        XCTAssertTrue(app.staticTexts["書く"].waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.staticTexts["读"].exists,
            "同 Note 的 zh→ja 应让位给不同 Note 的间隔卡"
        )
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()

        // 债务清偿：A-zh2ja 回到队列首位并展示。
        XCTAssertTrue(app.staticTexts["读"].waitForExistence(timeout: 8))
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()

        XCTAssertFalse(app.staticTexts["習う"].exists)
    }

    /// T21 (设计 §9.2): undo re-presents the undone card ahead of the
    /// policy pick — after rating A then B, undoing B must bring B back
    /// even though the policy alone would pick A2 (different note wins).
    @MainActor
    func testUndoRePresentsUndoneCardAheadOfSiblingPolicy() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_SIBLING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_UNAVAILABLE"] = "1"
        // v0.5.5：A-zh2ja 卡现为 typed 默认——本用例覆盖 reveal 流程，显式关闭。
        app.launchEnvironment["OBOE_UI_TEST_TYPED_RECALL_PREF"] = "0"
        app.launch()

        enterScopedReview(deckNamed: "错开牌组", in: app)

        XCTAssertTrue(app.staticTexts["読む"].waitForExistence(timeout: 8))
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()

        XCTAssertTrue(app.staticTexts["書く"].waitForExistence(timeout: 8))
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()

        // Now showing A-zh2ja. Undo reverts B's rating — B must re-present
        // (undo preference), not stay on A2 or advance elsewhere.
        XCTAssertTrue(app.staticTexts["读"].waitForExistence(timeout: 8))
        app.buttons["review-undo-button"].tap()
        XCTAssertTrue(app.staticTexts["書く"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["读"].exists, "撤销后应优先重现被撤销的 B 卡")
    }

    /// T21 (设计 §9.2): a listening card whose audio fails never produced a
    /// valid question — its note must not land in `lastPresentedNoteID`.
    /// The failing card shares note A with the next two candidates; if the
    /// skip polluted the memory, A-ja2zh would defer and B would show
    /// first. Expect A-ja2zh (読む) as the next card instead.
    @MainActor
    func testListeningFailureDoesNotPolluteSiblingMemory() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_SIBLING_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_STUB"] = "fail"
        app.launch()

        enterScopedReview(deckNamed: "错开牌组", in: app)
        // The listening face is transient — it presents, the stub fails
        // playback asynchronously, and the card is session-skipped within
        // a beat, faster than XCUI's polling catches the play button.
        // Assert the skip notice fired, then the real check: the next pick
        // must not treat note A as "just presented". Polluted memory would
        // defer A-ja2zh and show 書く; correct rollback shows 読む.
        _ = app.staticTexts["review-listening-skip-notice"].waitForExistence(timeout: 5)
        XCTAssertTrue(app.staticTexts["読む"].waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.staticTexts["書く"].exists,
            "失败的听力卡不应污染 lastPresentedNoteID——同 Note 卡不应被延期"
        )
    }

    /// T19 audit core: dump the WHOLE accessibility tree (every element's
    /// label/value/identifier in one snapshot) and assert none of the seeded
    /// listening card's answer strings appear anywhere — not just missing
    /// StaticTexts, but no parent-combined label or stray value either.
    private func assertListeningQuestionFaceFreeOfAnswerContent(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].exists,
            "审计前提：听力问题面必须存在", file: file, line: line
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["review-answer"].exists,
            "审计前提：答案面不得存在", file: file, line: line
        )
        let tree = app.debugDescription
        for leaked in ["聞く", "きく", "听；询问", "ラジオを聞く", "每天早上听广播"] {
            XCTAssertFalse(
                tree.contains(leaked),
                "听力问题面无障碍树泄漏答案文本「\(leaked)」",
                file: file, line: line
            )
        }
    }

    /// v0.5.5：全新安装上两个主动回忆输入开关默认开启；已关闭的选择
    /// 跨启动保留，且两个开关相互独立（关闭 zh→ja 不影响听力）。
    @MainActor
    func testTypedAnswerPreferencesDefaultOnAndPersistAcrossLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()
        app.openSettingsFromTodayGear()
        let zhToggle = app.switches["adaptive-typed-answer-zh-ja-toggle"]
        reveal(zhToggle, in: app)
        XCTAssertTrue(zhToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(zhToggle.value as? String, "1", "中文→日文输入默认开启")
        let listeningToggle = app.switches["adaptive-typed-answer-listening-toggle"]
        reveal(listeningToggle, in: app)
        XCTAssertTrue(listeningToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(listeningToggle.value as? String, "1", "听力输入默认开启")
        setSwitch(zhToggle, enabled: false, in: app)
        let saved = NSPredicate(format: "value == '0' AND enabled == true")
        expectation(for: saved, evaluatedWith: zhToggle)
        waitForExpectations(timeout: 5)
        app.terminate()
        app.launch()
        app.openSettingsFromTodayGear()
        let restored = app.switches["adaptive-typed-answer-zh-ja-toggle"]
        reveal(restored, in: app)
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.value as? String, "0", "已关闭的选择跨启动保留")
        let restoredListening = app.switches["adaptive-typed-answer-listening-toggle"]
        reveal(restoredListening, in: app)
        XCTAssertEqual(
            restoredListening.value as? String, "1",
            "听力开关独立保持默认开启"
        )
        setSwitch(restored, enabled: true, in: app)
        expectation(
            for: NSPredicate(format: "value == '1' AND enabled == true"),
            evaluatedWith: restored
        )
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testHomeEntryHiddenWhenNoLeechCards() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        XCTAssertTrue(app.todayNavigationBar.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["today-adaptive-entry"].exists,
            "0 张易错卡时首页不得显示“需要关注”入口"
        )
    }

    @MainActor
    func testAdaptiveCenterListDetailAndAnswerReminder() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launch()

        // 首页入口：leech=1 时显示，计数与列表来自同一快照。
        let entry = app.descendants(matching: .any)["today-adaptive-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "存在易错卡时首页必须显示入口")
        let count = app.staticTexts["today-adaptive-count"]
        XCTAssertTrue(count.label.contains("1 张卡最近经常遗忘"))
        entry.tap()

        // 列表：默认易错筛选，同 Note 的预警方向在“预警”筛选下。
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["受ける"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最近 6 次：重来 6 次"].exists)
        XCTAssertTrue(app.staticTexts["累计遗忘 6 次"].exists)
        XCTAssertTrue(app.staticTexts["经常遗忘"].exists)
        XCTAssertTrue(app.staticTexts["日语 → 中文"].exists)

        // 筛选切换与计数一致（同一快照驱动）。
        let warning = app.buttons["预警 1"]
        XCTAssertTrue(warning.waitForExistence(timeout: 3))
        warning.tap()
        XCTAssertTrue(app.staticTexts["中文 → 日语"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["累计遗忘 3 次"].exists)
        XCTAssertTrue(app.staticTexts["近期偏难"].exists)

        let suspended = app.buttons["已暂停 0"]
        XCTAssertTrue(suspended.exists)
        suspended.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["adaptive-empty-suspended"]
                .waitForExistence(timeout: 3)
        )

        // 详情：回到易错行进入，验证触发原因与近期记录。
        app.buttons["易错 1"].tap()
        let row = app.cells.containing(.staticText, identifier: "受ける").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["累计遗忘次数达到阈值"].exists)
        let lapseValue = app.staticTexts.matching(NSPredicate(
            format: "label == '6 次' OR (label CONTAINS '累计遗忘' AND label CONTAINS '6')"
        )).firstMatch
        XCTAssertTrue(lapseValue.exists, "详情页必须显示累计遗忘 6 次")
        // 近期复习记录 section 在 SE 首屏之下——先滚动使其挂载进无障碍树。
        let historySection = app.descendants(matching: .any)["adaptive-detail-history"]
        let detailContent = app.collectionViews.firstMatch
        for _ in 0..<8 where !historySection.exists {
            detailContent.swipeUp()
        }
        XCTAssertTrue(historySection.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 问题面不得出现任何易错暗示；答案面显示轻提示。
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["review-leech-reminder"].exists,
            "问题面不得显示易错提示"
        )
        showReviewAnswer(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5),
            "答案面必须展开"
        )
        let reminder = app.staticTexts["这张卡近期经常遗忘，建议留意。"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 5), "答案面必须显示易错轻提示")
    }

    /// T04: from the detail page the user can suspend the card — it leaves
    /// the leech filter and home count, appears under 已暂停, and resuming
    /// brings the SAME card back without touching its history. The edit
    /// entry opens the existing note editor.
    @MainActor
    func testSuspendResumeAndEditFromDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launch()

        let entry = app.descendants(matching: .any)["today-adaptive-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        // 详情页操作区：暂停按钮 + 编辑入口 + 多方向提示文案。
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))
        let row = app.cells.containing(.staticText, identifier: "受ける").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        // 操作区在历史记录下方，先滚动使其进入无障碍树。
        let detailList = app.collectionViews.firstMatch
        for _ in 0..<6 where !app.staticTexts["编辑会更新同一知识点的其他学习方向。"].exists {
            detailList.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["编辑会更新同一知识点的其他学习方向。"].exists)
        XCTAssertTrue(
            app.staticTexts["编辑卡片"].exists,
            "详情页必须有编辑入口"
        )

        let toggle = app.buttons["暂停这张卡"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
        XCTAssertTrue(
            app.staticTexts["重新启用这张卡"].waitForExistence(timeout: 5),
            "暂停后按钮必须变为重新启用"
        )
        // “已暂停”徽标在页首——先滚回顶部让它进入无障碍树。
        for _ in 0..<6 where !app.staticTexts["已暂停"].exists {
            detailList.swipeDown()
        }
        XCTAssertTrue(app.staticTexts["已暂停"].exists)

        // 返回列表：leech 筛选空态，已暂停=1，预警不受影响。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["adaptive-empty-leech"]
                .waitForExistence(timeout: 5),
            "唯一的 leech 卡暂停后易错筛选必须为空"
        )
        XCTAssertTrue(app.buttons["预警 1"].exists)
        app.buttons["已暂停 1"].tap()
        let suspendedRow = app.cells.containing(.staticText, identifier: "受ける").firstMatch
        XCTAssertTrue(suspendedRow.waitForExistence(timeout: 3), "暂停的卡必须在已暂停筛选下")
        XCTAssertTrue(app.staticTexts["累计遗忘 6 次"].exists, "暂停不得清空历史数据")

        // 重新启用：同一张卡回到易错筛选。
        suspendedRow.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        let resumeToggle = app.buttons["重新启用这张卡"]
        for _ in 0..<6 where !resumeToggle.isHittable {
            detailList.swipeUp()
        }
        XCTAssertTrue(resumeToggle.waitForExistence(timeout: 3))
        resumeToggle.tap()
        XCTAssertTrue(app.staticTexts["暂停这张卡"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 列表仍停留在已暂停筛选：此时应为空态；切回易错筛选找回该卡。
        XCTAssertTrue(
            app.descendants(matching: .any)["adaptive-empty-suspended"]
                .waitForExistence(timeout: 5),
            "重新启用后已暂停筛选必须为空"
        )
        app.buttons["易错 1"].tap()
        let leechRow = app.cells.containing(.staticText, identifier: "受ける").firstMatch
        XCTAssertTrue(leechRow.waitForExistence(timeout: 5), "重新启用后卡必须回到易错筛选")

        // 编辑入口进入现有编辑器（词形字段可见），返回后详情仍在。
        leechRow.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        let editEntry = app.buttons["编辑卡片"]
        for _ in 0..<6 where !editEntry.isHittable {
            detailList.swipeUp()
        }
        XCTAssertTrue(editEntry.waitForExistence(timeout: 3))
        editEntry.tap()
        XCTAssertTrue(app.staticTexts["词形"].waitForExistence(timeout: 5), "编辑必须打开现有笔记编辑器")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDisablingRemindersHidesEntryAndAnswerHint() {
        let databaseID = UUID().uuidString
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = databaseID
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launch()

        app.openSettingsFromTodayGear()
        let toggle = app.switches["adaptive-leech-reminders-toggle"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        setSwitch(toggle, enabled: false, in: app)

        // 重启后偏好已持久化：入口隐藏、答案面不再出现提示。
        app.terminate()
        app.launch()
        XCTAssertTrue(app.todayNavigationBar.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["today-adaptive-entry"].exists,
            "关闭提醒后首页入口必须隐藏"
        )
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        showReviewAnswer(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.staticTexts["这张卡近期经常遗忘，建议留意。"].exists,
            "关闭提醒后答案面不得显示易错提示"
        )
    }

    /// T07: the full repair session from the Adaptive detail — context
    /// explainer, persisted explanation, analyzing state, candidate
    /// suggestions and the read-only preview. Nothing is applied; re-entering
    /// restores the typed comment.
    @MainActor
    func testAIRepairSessionFromAdaptiveDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        openRepairFromAdaptiveDetail(in: app)
        XCTAssertTrue(app.navigationBars["AI 修卡"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["AI 建议仅供参考，确认后才会修改卡片。"].exists,
            "必须如实说明建议只是候选"
        )

        // List 内 TextField 的实际控件类型随实现变化——本页只有一个可编辑
        // 文本控件，逐类型查询。
        var commentField = app.textFields["ai-repair-comment"]
        for candidate in [
            app.textViews["ai-repair-comment"],
            app.textFields.firstMatch,
            app.textViews.firstMatch
        ] where !commentField.exists {
            commentField = candidate
        }
        XCTAssertTrue(commentField.waitForExistence(timeout: 3))
        commentField.tap()
        commentField.typeText("总和其他词混淆")
        dismissKeyboard(in: app)

        // 没有默认触发：必须显式点击分析。
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 3))
        analyze.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ai-repair-analyzing"].exists
                || app.staticTexts["这张卡可能因近形词混淆而难记，例句也偏复杂。"].waitForExistence(timeout: 8),
            "分析中或建议结果必须出现"
        )
        XCTAssertTrue(
            app.staticTexts["这张卡可能因近形词混淆而难记，例句也偏复杂。"]
                .waitForExistence(timeout: 8),
            "AI 摘要必须展示给用户"
        )
        revealRepairSuggestion("拆为两张卡", in: app)
        XCTAssertTrue(app.staticTexts["补充辨析说明"].exists)
        XCTAssertTrue(app.staticTexts["拆为两张卡"].exists)

        // 点击建议进入预览：有差异对照与受影响方向，但无任何采用按钮。
        let splitRow = app.cells.containing(.staticText, identifier: "拆为两张卡").firstMatch
        XCTAssertTrue(splitRow.waitForExistence(timeout: 3))
        splitRow.tap()
        XCTAssertTrue(app.navigationBars["建议预览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["拆分为 2 张新卡"].exists)
        XCTAssertTrue(app.staticTexts["受影响的学习方向"].exists)
        // T09 起拆卡预览有「采用拆分」按钮，但原卡处置未选前必须禁用——
        // 采用始终需要显式确认，预览本身不写任何东西。
        let splitAdopt = app.buttons["ai-repair-split-adopt"]
        for _ in 0..<6 where !splitAdopt.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(splitAdopt.waitForExistence(timeout: 3))
        XCTAssertFalse(splitAdopt.isEnabled, "未选择原卡处置时采用必须禁用")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 返回详情再进入：说明仍在（草稿持久化）。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        openRepairFromDetail(in: app)
        XCTAssertTrue(app.navigationBars["AI 修卡"].waitForExistence(timeout: 5))
        var restored = app.textFields["ai-repair-comment"]
        for candidate in [
            app.textViews["ai-repair-comment"],
            app.textFields.firstMatch,
            app.textViews.firstMatch
        ] where !restored.exists {
            restored = candidate
        }
        XCTAssertTrue(restored.waitForExistence(timeout: 3))
        XCTAssertEqual(
            (restored.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            "总和其他词混淆",
            "返回再进入说明必须仍在"
        )
    }

    /// T07: AI disabled — the request fails honestly, the draft stays
    /// retryable and the manual-edit path remains available.
    @MainActor
    func testAIRepairUnavailableStillAllowsManualEdit() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launch()

        openRepairFromAdaptiveDetail(in: app)
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        XCTAssertTrue(
            app.staticTexts["请先保存并启用 AI。"].waitForExistence(timeout: 5),
            "关闭 AI 时必须显示可理解错误"
        )
        let manualEdit = app.staticTexts["手动编辑卡片"]
        let manualButton = app.buttons["手动编辑卡片"]
        for _ in 0..<6 where !(manualEdit.exists || manualButton.exists) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(manualButton.waitForExistence(timeout: 3), "AI 不可用时手动编辑必须可用")
        manualButton.tap()
        XCTAssertTrue(
            app.staticTexts["词形"].waitForExistence(timeout: 5),
            "手动编辑必须打开现有笔记编辑器"
        )
    }

    /// T07: answer-face entry + cancel — the in-flight request is cancelled,
    /// the card is untouched and the session returns to a retryable state.
    @MainActor
    func testAIRepairAnswerFaceEntryAndCancel() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        showReviewAnswer(in: app)

        let entry = app.buttons["AI 修卡"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "答案面必须有 AI 修卡入口")
        // 修卡入口位于答案事实之后，不得插入「标准答案」标题与内容之间。
        let standardAnswer = app.staticTexts["标准答案"]
        if standardAnswer.exists {
            XCTAssertGreaterThan(
                entry.frame.minY,
                standardAnswer.frame.minY,
                "AI 修卡入口必须位于标准答案标题之下"
            )
            let answerValue = app.staticTexts["食べる"]
            if answerValue.exists {
                XCTAssertGreaterThan(
                    entry.frame.minY,
                    answerValue.frame.minY,
                    "AI 修卡入口必须位于答案内容之下"
                )
            }
        }
        entry.tap()
        XCTAssertTrue(app.navigationBars["AI 修卡"].waitForExistence(timeout: 5))

        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        let cancel = app.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "分析中必须出现取消按钮")
        cancel.tap()
        // 取消后请求作废：回到可重试状态，不出现结果，卡不受影响。
        XCTAssertTrue(
            app.buttons["ai-repair-analyze"].waitForExistence(timeout: 8),
            "取消后必须回到可重试状态"
        )
        XCTAssertFalse(
            app.staticTexts["这张卡可能因近形词混淆而难记，例句也偏复杂。"].exists,
            "取消后不得展示晚到的结果"
        )
        // 关闭回到学习流，卡片仍在。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5),
            "关闭修卡后必须能继续学习"
        )
    }

    /// T08: the adopt path — preview → 采用 → confirmation → guarded commit.
    /// A cancelled confirmation writes nothing; a confirmed one shows the
    /// committed state and persists the suggested content to the note.
    @MainActor
    func testAIRepairAdoptSuggestionCommits() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        openRepairFromAdaptiveDetail(in: app)
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        revealRepairSuggestion("补充辨析说明", in: app)
        XCTAssertTrue(
            app.staticTexts["补充辨析说明"].waitForExistence(timeout: 10),
            "分析完成后必须出现建议列表"
        )

        let row = app.cells.containing(.staticText, identifier: "补充辨析说明").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["建议预览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["受影响的学习方向"].exists)

        // 取消确认：不产生任何写入，仍在预览页。
        let adopt = app.buttons["ai-repair-adopt"]
        for _ in 0..<6 where !adopt.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(adopt.waitForExistence(timeout: 3), "预览页必须有采用按钮")
        adopt.tap()
        let cancelConfirm = app.alerts.firstMatch.buttons["取消"].firstMatch
        XCTAssertTrue(cancelConfirm.waitForExistence(timeout: 3), "必须弹出采用确认")
        cancelConfirm.tap()
        XCTAssertFalse(
            app.staticTexts["已采用建议，卡片内容已更新。"].exists,
            "取消确认不得提交任何写入"
        )

        // 确认采用：提交后展示已采用状态，采用按钮消失。
        adopt.tap()
        let confirm = app.buttons["ai-repair-adopt-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["已采用建议，卡片内容已更新。"].waitForExistence(timeout: 8),
            "采用后必须显示已采用状态"
        )
        XCTAssertFalse(app.buttons["ai-repair-adopt"].exists, "已采用后不得再出现采用按钮")

        // 返回列表：已提交会话终结，prepareDraft 跳过 committed 草稿开启
        // 新会话——分析按钮回到可重试状态，已采用横幅不再显示。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.buttons["ai-repair-analyze"].waitForExistence(timeout: 5),
            "已提交后回到主页必须是可重新开始的新会话"
        )

        // 打开手动编辑：建议的说明字段已写入笔记。
        let manualButton = app.buttons["手动编辑卡片"]
        for _ in 0..<8 where !manualButton.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(manualButton.waitForExistence(timeout: 3))
        manualButton.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '受け取る'"))
                .firstMatch.waitForExistence(timeout: 5),
            "采用后建议的说明必须写入笔记"
        )
    }

    /// T08: 编辑后采用 — the suggestion's merged content opens as a form,
    /// saving persists the edited candidate, and the same confirmation
    /// commits it through the guarded transaction.
    @MainActor
    func testAIRepairEditThenAdopt() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        openRepairFromAdaptiveDetail(in: app)
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        revealRepairSuggestion("补充辨析说明", in: app)
        XCTAssertTrue(app.staticTexts["补充辨析说明"].waitForExistence(timeout: 10))
        let row = app.cells.containing(.staticText, identifier: "补充辨析说明").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["建议预览"].waitForExistence(timeout: 5))

        let editAdopt = app.buttons["ai-repair-edit-adopt"]
        for _ in 0..<6 where !editAdopt.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(editAdopt.waitForExistence(timeout: 3), "预览页必须有编辑后采用入口")
        editAdopt.tap()
        XCTAssertTrue(app.navigationBars["编辑后采用"].waitForExistence(timeout: 5))

        // 说明字段已带入建议内容，追加用户自己的补充。
        var notesField = app.textFields["说明"]
        for candidate in [app.textViews["说明"], app.textFields.firstMatch] where !notesField.exists {
            notesField = candidate
        }
        XCTAssertTrue(notesField.waitForExistence(timeout: 3))
        notesField.tap()
        notesField.typeText("，手动补充")
        app.buttons["ai-repair-edit-save"].tap()

        // Sheet 关闭后同一确认框出现——确认后采用编辑候选。
        let confirm = app.buttons["ai-repair-adopt-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "保存编辑后必须弹出采用确认")
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["已采用建议，卡片内容已更新。"].waitForExistence(timeout: 8),
            "编辑后采用必须成功提交"
        )

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let manualButton = app.buttons["手动编辑卡片"]
        for _ in 0..<8 where !manualButton.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(manualButton.waitForExistence(timeout: 3))
        manualButton.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '手动补充'"))
                .firstMatch.waitForExistence(timeout: 5),
            "编辑后的内容必须写入笔记"
        )
    }

    /// T08: committing on the card currently being studied resets its face —
    /// old input is cleared and the question is presented again.
    @MainActor
    func testAIRepairAdoptFromReviewResetsCardFace() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        showReviewAnswer(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5))

        let entry = app.buttons["AI 修卡"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["AI 修卡"].waitForExistence(timeout: 5))
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        revealRepairSuggestion("补充辨析说明", in: app)
        XCTAssertTrue(app.staticTexts["补充辨析说明"].waitForExistence(timeout: 10))
        let row = app.cells.containing(.staticText, identifier: "补充辨析说明").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()

        let adopt = app.buttons["ai-repair-adopt"]
        for _ in 0..<6 where !adopt.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(adopt.waitForExistence(timeout: 3))
        adopt.tap()
        let confirm = app.buttons["ai-repair-adopt-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["已采用建议，卡片内容已更新。"].waitForExistence(timeout: 8)
        )

        // 关闭修卡页：学习卡回到问题面，旧输入/答案不再保留。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 8),
            "采用后学习卡必须重新呈现问题面"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["review-answer"].exists,
            "采用后不得保留已展开的答案面"
        )
    }

    /// T09: the full split path — per-candidate content/directions, shared
    /// deck, required original-card disposition, confirmation, commit. The
    /// original leech card ends suspended (its sibling untouched) and two
    /// fresh notes with four New cards are created.
    @MainActor
    func testAIRepairSplitAdoptCommits() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        openRepairFromAdaptiveDetail(in: app)
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        // 建议列表在 AI 分析 section 下方，SE 首屏之外——先滚动挂载。
        let splitTitle = app.staticTexts["拆为两张卡"]
        for _ in 0..<10 where !splitTitle.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(splitTitle.waitForExistence(timeout: 10))
        let row = app.cells.containing(.staticText, identifier: "拆为两张卡").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["建议预览"].waitForExistence(timeout: 5))

        // 候选内容与方向预览：两个候选各显示摘要与方向开关。
        XCTAssertTrue(app.staticTexts["拆分为 2 张新卡"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '接受（考试、治疗等）'")
            ).firstMatch.exists,
            "第一个候选的摘要必须展示"
        )
        // List 内 Toggle 的 identifier 落在行容器上——开关本体按标签查询，
        // 两个候选同名开关按无障碍树顺序取。
        let jaZhSwitches = app.switches.matching(
            NSPredicate(format: "label == '日语 → 中文'")
        )
        let firstJaZh = jaZhSwitches.element(boundBy: 0)
        reveal(firstJaZh, in: app)
        XCTAssertTrue(firstJaZh.waitForExistence(timeout: 3))
        // 第二个候选在视口外时开关未挂载——滚动至两个都进入无障碍树。
        for _ in 0..<8 where jaZhSwitches.count < 2 {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertEqual(jaZhSwitches.count, 2, "两个候选各有「日语 → 中文」开关")
        let zhJaSwitches = app.switches.matching(
            NSPredicate(format: "label == '中文 → 日语'")
        )
        for _ in 0..<8 where zhJaSwitches.count < 2 {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertEqual(zhJaSwitches.count, 2, "两个候选各有「中文 → 日语」开关")
        // 方向默认沿用原笔记快照（受影响的两个方向全开）。
        XCTAssertEqual(firstJaZh.value as? String, "1", "方向必须默认沿用原笔记快照")

        // 牌组选择：T09 起为多成员选择行（ai-repair-split-deck），
        // 种子只有一个牌组，摘要直接显示归属牌组名。iOS 26 中 Section 级
        // 标识符会传播覆盖行内元素自身标识符，按 label 查询该按钮。
        let deckRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '牌组、'")
        ).firstMatch
        reveal(deckRow, in: app)
        XCTAssertTrue(deckRow.waitForExistence(timeout: 3))
        XCTAssertTrue(deckRow.label.contains("自适应测试"))

        // 原卡处置必选：三个选项都在、推荐只是标签、未选前采用禁用。
        // 同理 disposition-* 行标识符被所属 Section 覆盖，按 label 查询。
        XCTAssertTrue(app.staticTexts["原卡处置（必选）"].exists)
        let pauseOption = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '暂停原卡'")
        ).firstMatch
        let pauseLabel = app.staticTexts["暂停原卡（推荐）"].firstMatch
        reveal(pauseLabel, in: app)
        XCTAssertTrue(pauseLabel.waitForExistence(timeout: 3))
        let adopt = app.buttons["ai-repair-split-adopt"]
        for _ in 0..<6 where !adopt.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(adopt.waitForExistence(timeout: 3))
        XCTAssertFalse(adopt.isEnabled, "未选择原卡处置时采用必须禁用")
        (pauseOption.exists ? pauseOption : pauseLabel).tap()

        // 确认与预览分离：弹窗复述数量与处置，确认后才提交。
        XCTAssertTrue(adopt.isEnabled, "选择处置后采用必须可用")
        adopt.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '2 个新笔记' AND label CONTAINS '4 张新卡' AND label CONTAINS '自适应测试'")
            ).firstMatch.exists,
            "确认框必须复述新笔记数、新卡数与牌组"
        )
        let confirm = app.buttons["ai-repair-split-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        // 已提交态：预览页与主页都显示拆卡回执。
        XCTAssertTrue(
            app.staticTexts["已拆分为 2 个新笔记。"].waitForExistence(timeout: 8),
            "拆分提交后必须显示已采用状态"
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '共创建 4 张新卡' AND label CONTAINS '原卡已暂停'")
            ).firstMatch.exists,
            "回执必须说明新卡数与原卡处置"
        )
        XCTAssertFalse(
            app.buttons["ai-repair-split-adopt"].exists,
            "已采用后不得再出现采用按钮"
        )

        // 详情页：原卡暂停徽标；列表：已暂停=1、兄弟预警方向不受影响。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.buttons["ai-repair-analyze"].waitForExistence(timeout: 5),
            "已提交后回到主页必须是新会话"
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        for _ in 0..<6 where !app.staticTexts["已暂停"].exists {
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(app.staticTexts["已暂停"].exists, "原卡必须显示已暂停")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["已暂停 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["预警 1"].exists, "兄弟方向不得被处置")
    }

    /// T09: editing the direction selection refreshes the confirmation
    /// preview (2+1=3 张新卡), and cancelling it writes nothing.
    @MainActor
    func testAIRepairSplitDirectionEditRefreshesPreview() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_AI_ENABLED"] = "1"
        app.launch()

        openRepairFromAdaptiveDetail(in: app)
        let analyze = app.buttons["ai-repair-analyze"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        revealRepairSuggestion("拆为两张卡", in: app)
        XCTAssertTrue(app.staticTexts["拆为两张卡"].waitForExistence(timeout: 10))
        let row = app.cells.containing(.staticText, identifier: "拆为两张卡").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["建议预览"].waitForExistence(timeout: 5))

        // 关掉第二个候选的「中文 → 日语」方向（开关按标签+顺序定位）。
        let zhJaSwitches = app.switches.matching(
            NSPredicate(format: "label == '中文 → 日语'")
        )
        let toggle = zhJaSwitches.element(boundBy: 1)
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(zhJaSwitches.count, 2)
        setSwitch(toggle, enabled: false, in: app)

        // 选「保留原卡」后确认框必须反映修改后的方向数（3 张新卡）。
        let keepLabel = app.staticTexts["保留原卡"].firstMatch
        reveal(keepLabel, in: app)
        XCTAssertTrue(keepLabel.waitForExistence(timeout: 3))
        keepLabel.tap()
        let adopt = app.buttons["ai-repair-split-adopt"]
        for _ in 0..<6 where !adopt.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(adopt.waitForExistence(timeout: 3))
        XCTAssertTrue(adopt.isEnabled)
        adopt.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '3 张新卡' AND label CONTAINS '保留'")
            ).firstMatch.exists,
            "方向修改后确认预览必须刷新为 3 张新卡"
        )

        // 取消确认：不写任何东西，仍在预览页可继续选择。
        alert.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["建议预览"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.staticTexts["已拆分为 2 个新笔记。"].exists,
            "取消确认不得提交任何写入"
        )
        XCTAssertTrue(adopt.waitForExistence(timeout: 3))
    }

    /// T26: the Adaptive center's 本周趋势 entry opens the two-endpoint
    /// report. With OBOE_UI_TEST_TREND_SEED the fixture gains a second
    /// note whose leech state forms strictly inside the comparison week,
    /// so the report reads 周初 1 / 当前 2 / 新出现 1 / 仍经常遗忘 1 over
    /// three analysed cards — and the explanation states plainly that it
    /// is a two-endpoint reconstruction, not the week's full history.
    @MainActor
    func testWeeklyTrendTwoEndpointReport() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TREND_SEED"] = "1"
        app.launch()

        let entry = app.descendants(matching: .any)["today-adaptive-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "存在易错卡时首页必须显示入口")
        entry.tap()
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))

        let trendEntry = app.descendants(matching: .any)["adaptive-trend-entry"]
        XCTAssertTrue(trendEntry.waitForExistence(timeout: 5), "易错中心必须有本周趋势入口")
        trendEntry.tap()

        XCTAssertTrue(app.navigationBars["本周趋势"].waitForExistence(timeout: 5))
        let explanation = app.descendants(matching: .any)["adaptive-trend-explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertTrue(
            explanation.label.contains("不代表整周完整历史"),
            "说明必须明确两端对比口径而非完整历史"
        )

        assertTrendMetric("adaptive-trend-week-leech", equals: "2", in: app)
        assertTrendMetric("adaptive-trend-start-leech", equals: "1", in: app)
        assertTrendMetric("adaptive-trend-current-leech", equals: "2", in: app)
        assertTrendMetric("adaptive-trend-newly-appeared", equals: "1", in: app)
        assertTrendMetric("adaptive-trend-still-leech", equals: "1", in: app)
        assertTrendMetric("adaptive-trend-recovered", equals: "0", in: app)
        assertTrendMetric("adaptive-trend-improved", equals: "0", in: app)
        assertTrendMetric("adaptive-trend-analyzed", equals: "3", in: app)
        assertTrendMetric("adaptive-trend-suspended", equals: "0", in: app)
        // 页脚在视口外——滚动到它进入无障碍树。
        let footer = app.descendants(matching: .any)["adaptive-trend-footer"]
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !footer.exists {
            list.swipeUp()
        }
        XCTAssertTrue(footer.waitForExistence(timeout: 3))
    }

    /// T26: the report stays reachable at the largest text size under
    /// dark appearance — the entry, the report surface and the
    /// explanation must all survive the accessibility tree.
    @MainActor
    func testWeeklyTrendReachableUnderDarkAndLargeText() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_TREND_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_DYNAMIC_TYPE"] = "ax5"
        app.launchEnvironment["OBOE_UI_TEST_APPEARANCE_DARK"] = "1"
        app.launch()

        let entry = app.descendants(matching: .any)["today-adaptive-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))

        let trendEntry = app.descendants(matching: .any)["adaptive-trend-entry"]
        XCTAssertTrue(trendEntry.waitForExistence(timeout: 5))
        trendEntry.tap()

        XCTAssertTrue(app.navigationBars["本周趋势"].waitForExistence(timeout: 5))
        let explanation = app.descendants(matching: .any)["adaptive-trend-explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        // 大字号下其余指标行可能被推出视口——滚动后仍须可达。
        let list = app.collectionViews.firstMatch
        let newly = app.descendants(matching: .any)["adaptive-trend-newly-appeared"]
        for _ in 0..<8 where !newly.exists {
            list.swipeUp()
        }
        XCTAssertTrue(newly.waitForExistence(timeout: 3), "大字号下指标行必须可达")
    }

    @MainActor
    private func assertTrendMetric(
        _ identifier: String,
        equals expected: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let metric = app.descendants(matching: .any)[identifier]
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 where !metric.exists {
            list.swipeUp()
        }
        XCTAssertTrue(
            metric.waitForExistence(timeout: 5),
            "缺少指标 \(identifier)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            metric.label.hasSuffix(expected),
            "\(identifier) 应为 \(expected)，实际为 \(metric.label)",
            file: file,
            line: line
        )
    }

    /// 建议行在 AI 分析 section 下方，SE 首屏之外——滚动至标题挂载进
    /// 无障碍树（`exists` 不会主动翻页）。
    @MainActor
    private func revealRepairSuggestion(_ title: String, in app: XCUIApplication) {
        let text = app.staticTexts[title]
        for _ in 0..<10 where !text.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
    }

    @MainActor
    private func openRepairFromAdaptiveDetail(in app: XCUIApplication) {
        let entry = app.descendants(matching: .any)["today-adaptive-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))
        let row = app.cells.containing(.staticText, identifier: "受ける").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        openRepairFromDetail(in: app)
    }

    /// Taps the AI-repair action while the adaptive detail page is already
    /// on screen.
    @MainActor
    private func openRepairFromDetail(in app: XCUIApplication) {
        let repair = app.buttons["AI 修卡"]
        for _ in 0..<8 where !repair.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(repair.waitForExistence(timeout: 3), "详情页必须有 AI 修卡入口")
        repair.tap()
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        for name in ["done", "Done", "完成", "return", "换行"] {
            let key = app.keyboards.buttons[name]
            if key.exists {
                key.tap()
                return
            }
        }
        app.keyboards.firstMatch.swipeDown()
    }

    @MainActor
    private func showReviewAnswer(in app: XCUIApplication) {
        let button = app.buttons["review-show-answer-button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let scroll = app.scrollViews["review-content-scroll"]
        for _ in 0..<8 where !button.isHittable {
            scroll.swipeUp()
        }
        XCTAssertTrue(button.isHittable, "显示答案按钮不可达")
        button.tap()
    }

    /// T15：首页逐牌组入口移除后，scoped 会话经 牌组 tab → 牌组详情 →
    /// 「学习此牌组」进入（设计 §4.7 预留的恢复位置）。
    @MainActor
    private func enterScopedReview(deckNamed name: String, in app: XCUIApplication) {
        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()

        let deckRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
        XCTAssertTrue(deckRow.waitForExistence(timeout: 8))
        deckRow.tap()

        // 「学习此牌组」在牌组详情「今日」分区里——内容列表较长时在视口外。
        let studyButton = app.descendants(matching: .any)["deck-study-button"]
        for _ in 0..<8 where !studyButton.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(studyButton.waitForExistence(timeout: 5))
        studyButton.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists, element.isHittable {
                return
            }
            form.swipeUp()
        }
        // 若向上滚到底仍未命中，元素可能在首屏上方——回滚复查。
        for _ in 0..<12 {
            if element.exists, element.isHittable {
                return
            }
            form.swipeDown()
        }
    }

    @MainActor
    private func setSwitch(_ element: XCUIElement, enabled: Bool, in app: XCUIApplication) {
        let expectedValue = enabled ? "1" : "0"
        let list = app.collectionViews.firstMatch
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<3 {
            // A row recycled off-viewport loses its identifier entirely —
            // scroll it back before tapping.
            reveal(element, in: app)
            guard element.exists else { continue }
            if element.value as? String == expectedValue { break }
            // Then lift the row fully clear of the tab bar: a clipped row's
            // trailing edge forwards taps to the tab bar instead.
            for _ in 0..<4
            where element.isHittable
                    && tabBar.exists && element.frame.maxY > tabBar.frame.minY - 4 {
                list.swipeUp()
            }
            guard element.isHittable else { continue }
            // SwiftUI exposes a Toggle as TWO elements: the row (identifier +
            // label, whole-row frame) and the anonymous inner UISwitch
            // (trailing edge). Tapping the row synthesizes at its center —
            // the label area — which does not toggle. Tap the inner control
            // directly: the switch without an identifier sitting inside the
            // row's trailing half at the same vertical center.
            let row = element.frame
            var hit = false
            for index in 0..<app.switches.count {
                let inner = app.switches.element(boundBy: index)
                guard inner.isHittable, inner.identifier.isEmpty else { continue }
                let innerFrame = inner.frame
                guard innerFrame.minX > row.midX,
                      innerFrame.midY > row.minY, innerFrame.midY < row.maxY
                else { continue }
                inner.tap()
                hit = true
                break
            }
            if !hit {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expectedValue),
                object: element
            )
            if XCTWaiter.wait(for: [expectation], timeout: 2) == .completed {
                return
            }
        }
        XCTAssertEqual(element.value as? String, expectedValue)
    }
}
