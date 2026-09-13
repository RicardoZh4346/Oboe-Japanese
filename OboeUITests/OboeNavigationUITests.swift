import XCTest

final class OboeNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSwitchesBetweenFourPrimaryTabs() {
        let app = XCUIApplication()
        app.launch()

        let expectedTabs = ["今日", "牌组", "添加", "设置"]
        for tabName in expectedTabs {
            let tab = app.tabBars.buttons[tabName]
            XCTAssertTrue(tab.waitForExistence(timeout: 2), "缺少 \(tabName) 入口")
            tab.tap()
            XCTAssertTrue(
                app.navigationBars[tabName].waitForExistence(timeout: 2),
                "切换到 \(tabName) 后未显示对应页面"
            )
        }
    }

    @MainActor
    func testP23BuiltinJLPTLibraryOpensOfflineAndShowsExpectedLevels() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        let library = app.buttons["jlpt-library-entry"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()

        XCTAssertTrue(app.navigationBars["JLPT 词汇库"].waitForExistence(timeout: 5))
        let acknowledge = app.buttons["我知道了"]
        if acknowledge.waitForExistence(timeout: 1) {
            acknowledge.tap()
        }
        XCTAssertTrue(app.buttons["jlpt-level-N5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["662 个词"].exists)
        app.buttons["jlpt-level-N5"].tap()
        XCTAssertTrue(app.navigationBars["N5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导入全级"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["あさって"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testP22bColdLaunchPerformance() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testP22cAboutShowsLicensePrivacyAndThirdPartyNotices() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let about = app.buttons["about-navigation-link"]
        reveal(about, in: app)
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()

        XCTAssertTrue(app.navigationBars["关于 Oboe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["about-license-summary"].exists)
        XCTAssertTrue(app.staticTexts["about-third-party-notices"].exists)
        XCTAssertTrue(app.staticTexts["about-third-party-notices"].label.contains("GRDB.swift"))
        XCTAssertTrue(app.staticTexts["about-third-party-notices"].label.contains("swift-fsrs"))
        let privacy = app.staticTexts["about-privacy-summary"]
        reveal(privacy, in: app)
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsShowsPortableBackupExportScope() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let exportButton = app.buttons["portable-backup-export-button"]
        reveal(exportButton, in: app)
        XCTAssertTrue(exportButton.exists)
        let lastExport = app.staticTexts["portable-backup-last-export"]
        reveal(lastExport, in: app)
        XCTAssertTrue(lastExport.label.contains("尚未导出"))
        let privacyNote = app.staticTexts["portable-backup-privacy-note"]
        reveal(privacyNote, in: app)
        XCTAssertTrue(privacyNote.exists)
        let scopeNote = app.staticTexts["portable-backup-scope-note"]
        reveal(scopeNote, in: app)
        XCTAssertTrue(scopeNote.exists)
        XCTAssertFalse(app.buttons["导入数据"].exists)
        XCTAssertFalse(app.buttons["完整替换恢复"].exists)
    }

    @MainActor
    func testSettingsShowsP14bRestoreAndLocalSnapshotEntryPoints() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let prepareButton = app.buttons["portable-backup-prepare-button"]
        reveal(prepareButton, in: app)
        XCTAssertTrue(prepareButton.exists)
        let previewNote = app.staticTexts["portable-backup-preview-scope-note"]
        reveal(previewNote, in: app)
        XCTAssertTrue(previewNote.exists)
        let createSnapshot = app.buttons["local-snapshot-create-button"]
        reveal(createSnapshot, in: app)
        XCTAssertTrue(createSnapshot.exists)
        let snapshotNote = app.staticTexts["local-snapshot-scope-note"]
        reveal(snapshotNote, in: app)
        XCTAssertTrue(snapshotNote.exists)

        createSnapshot.tap()
        XCTAssertTrue(app.staticTexts["本机快照已创建。"].waitForExistence(timeout: 5))
        let restoreButton = app.buttons["local-snapshot-restore-button"].firstMatch
        reveal(restoreButton, in: app)
        XCTAssertTrue(restoreButton.exists)
        restoreButton.tap()
        let confirmRestore = app.buttons["完整替换并恢复"]
        XCTAssertTrue(confirmRestore.waitForExistence(timeout: 2))
        confirmRestore.tap()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        XCTAssertTrue(app.navigationBars["牌组"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法完成操作"].waitForExistence(timeout: 2))

        let addTab = app.tabBars.buttons["添加"]
        addTab.tap()
        XCTAssertTrue(app.navigationBars["添加"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法完成操作"].waitForExistence(timeout: 2))

        let todayTab = app.tabBars.buttons["今日"]
        todayTab.tap()
        XCTAssertTrue(app.navigationBars["今日"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["刷新失败"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testP16SpeechSettingsExposeVoiceStatusAndPersistBothDefaults() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let wordToggle = app.switches["speech-auto-play-word-toggle"]
        let exampleToggle = app.switches["speech-auto-play-example-toggle"]
        reveal(wordToggle, in: app)
        XCTAssertTrue(wordToggle.waitForExistence(timeout: 5))
        moveIntoInteractionSafeArea(wordToggle, in: app)
        XCTAssertEqual(wordToggle.value as? String, "0")
        waitUntilEnabled(wordToggle)
        setSwitch(wordToggle, enabled: true)
        reveal(exampleToggle, in: app)
        XCTAssertTrue(exampleToggle.exists)
        XCTAssertEqual(exampleToggle.value as? String, "0")
        waitUntilEnabled(exampleToggle)
        setSwitch(exampleToggle, enabled: true)
        let offlineNote = app.staticTexts["speech-offline-note"]
        reveal(offlineNote, in: app)
        XCTAssertTrue(offlineNote.exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["speech-voice-available"].exists
                || app.descendants(matching: .any)["speech-voice-unavailable"].exists
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        reveal(wordToggle, in: app)
        XCTAssertTrue(wordToggle.exists)
        waitUntilEnabled(wordToggle)
        XCTAssertEqual(wordToggle.value as? String, "1")
        XCTAssertEqual(exampleToggle.value as? String, "1")
    }

    @MainActor
    func testP21aLearningSettingsExposeRulesAndPersistRetention() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let dailyLimit = app.descendants(matching: .any)["learning-daily-new-limit-stepper"]
        XCTAssertTrue(dailyLimit.waitForExistence(timeout: 5))
        XCTAssertTrue(dailyLimit.label.contains("每日新卡"))
        XCTAssertTrue(dailyLimit.label.contains("10"))

        let retention = app.descendants(matching: .any)["learning-retention-picker"]
        XCTAssertTrue(retention.exists)
        retention.tap()
        let intensive = app.buttons["强化（95%）"]
        XCTAssertTrue(intensive.waitForExistence(timeout: 2))
        intensive.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["learning-time-zone-picker"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["learning-configuration-version"]
                .label.contains("r95")
        )
        XCTAssertTrue(app.staticTexts["learning-settings-effect-note"].exists)
        XCTAssertTrue(app.staticTexts["learning-settings-backup-note"].exists)

        app.buttons["learning-settings-save-button"].tap()
        XCTAssertTrue(
            app.staticTexts["learning-settings-status"].waitForExistence(timeout: 5)
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        let restoredVersion = app.descendants(matching: .any)["learning-configuration-version"]
        XCTAssertTrue(restoredVersion.waitForExistence(timeout: 5))
        XCTAssertTrue(restoredVersion.label.contains("r95"))
    }

    @MainActor
    func testP21bAppearancePersistsAndDefaultAIStaysDisabled() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let appearance = app.descendants(matching: .any)["appearance-picker"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let dark = app.buttons["深色"]
        XCTAssertTrue(dark.waitForExistence(timeout: 2))
        dark.tap()
        XCTAssertTrue(app.staticTexts["appearance-status"].waitForExistence(timeout: 5))

        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        XCTAssertEqual(aiToggle.value as? String, "0")

        app.terminate()
        app.launch()
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertTrue(
            appearance.label.contains("深色") || String(describing: appearance.value).contains("深色")
        )
    }

    @MainActor
    func testP21bAccessibilityTextLongReviewAndForegroundKeepActionsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckName = app.textFields["deck-name-field"]
        XCTAssertTrue(deckName.waitForExistence(timeout: 2))
        deckName.tap()
        deckName.typeText("P21b Small Screen")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["P21b Small Screen"].waitForExistence(timeout: 5))

        app.tabBars.buttons["添加"].tap()
        let kindPicker = app.descendants(matching: .any)["add-content-kind-picker"]
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        let segmentedPicker = app.segmentedControls["add-content-kind-picker"]
        if segmentedPicker.exists {
            segmentedPicker.buttons["语法"].tap()
        } else {
            kindPicker.tap()
            let grammarChoice = app.buttons["语法"]
            XCTAssertTrue(grammarChoice.waitForExistence(timeout: 2))
            grammarChoice.tap()
        }

        let grammarForm = app.textFields["grammar-form-field"]
        revealExistence(grammarForm, in: app)
        XCTAssertTrue(grammarForm.exists)
        grammarForm.tap()
        grammarForm.typeText("V-ta-koto-ga-aru: a deliberately long grammar form for layout verification")
        let meaning = app.textFields["grammar-meaning-field"]
        revealExistence(meaning, in: app)
        XCTAssertTrue(meaning.exists)
        meaning.tap()
        meaning.typeText("A deliberately long explanation that wraps across several lines on a small screen.")
        let keyboardDone = app.buttons["add-keyboard-done-button"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 2))
        keyboardDone.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))

        let save = app.buttons["grammar-formal-save-button"]
        reveal(save, in: app)
        XCTAssertTrue(save.isHittable)
        save.tap()

        app.terminate()
        app.launch()
        let start = app.buttons["today-start-all-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5)
        )
        let showAnswer = app.buttons["review-show-answer-button"]
        XCTAssertTrue(showAnswer.isHittable)
        showAnswer.tap()

        for ratingID in ["again", "hard", "good", "easy"] {
            let button = app.buttons["review-rating-\(ratingID)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            XCTAssertTrue(button.isHittable, "大字号下评分按钮 \(ratingID) 被内容遮挡")
        }
        XCTAssertTrue(app.buttons["review-rating-easy"].label.contains("简单，预计"))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["review-rating-easy"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-rating-easy"].isHittable)
    }

    @MainActor
    func testP17aShowsDisabledDeepSeekPresetAndCredentialPrivacyBoundary() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        XCTAssertTrue(aiToggle.exists)
        XCTAssertEqual(aiToggle.value as? String, "0")
        let servicePicker = app.descendants(matching: .any)["ai-service-picker"]
        revealExistence(servicePicker, in: app)
        XCTAssertTrue(servicePicker.exists)
        let modelField = app.textFields["ai-model-id-field"]
        reveal(modelField, in: app)
        XCTAssertTrue(modelField.exists)
        XCTAssertEqual(modelField.value as? String, "deepseek-v4-pro")
        let keyField = app.secureTextFields["ai-api-key-field"]
        reveal(keyField, in: app)
        XCTAssertTrue(keyField.exists)
        let keyStatus = app.descendants(matching: .any)["ai-key-not-configured"]
        revealExistence(keyStatus, in: app)
        XCTAssertTrue(keyStatus.exists)
        let keyPrivacy = app.staticTexts["ai-key-privacy-note"]
        reveal(keyPrivacy, in: app)
        XCTAssertTrue(keyPrivacy.exists)
        let requestPrivacy = app.staticTexts["ai-request-privacy-note"]
        reveal(requestPrivacy, in: app)
        XCTAssertTrue(requestPrivacy.exists)
        let noNetwork = app.staticTexts["ai-no-network-note"]
        reveal(noNetwork, in: app)
        XCTAssertTrue(noNetwork.exists)
    }

    @MainActor
    func testP17bShowsCapabilityAndExplicitMeteredConnectionTest() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let capability = app.descendants(matching: .any)["ai-response-format-fixed"]
        reveal(capability, in: app)
        XCTAssertTrue(capability.exists)

        let testButton = app.buttons["ai-test-connection-button"]
        reveal(testButton, in: app)
        XCTAssertTrue(testButton.exists)
        XCTAssertFalse(testButton.isEnabled, "未启用且没有 Key 时不得发起连接测试")

        let costNotice = app.staticTexts["ai-connection-cost-note"]
        reveal(costNotice, in: app)
        XCTAssertTrue(costNotice.exists)
    }

    @MainActor
    func testP18GeneratesSeparateCandidateThenRequiresExplicitAdoption() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let keyField = app.secureTextFields["ai-api-key-field"]
        reveal(keyField, in: app)
        XCTAssertTrue(keyField.isHittable)
        keyField.tap()
        keyField.typeText("ui-test-key")
        dismissKeyboard(in: app)

        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        aiToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enableButton = app.buttons["了解并启用"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 2))
        enableButton.tap()
        XCTAssertEqual(aiToggle.value as? String, "1")

        let saveConfiguration = app.buttons["ai-save-configuration-button"]
        reveal(saveConfiguration, in: app)
        XCTAssertTrue(saveConfiguration.isHittable)
        saveConfiguration.tap()
        let keyConfigured = app.descendants(matching: .any)["ai-key-configured"]
        XCTAssertTrue(keyConfigured.waitForExistence(timeout: 5))

        let addTab = app.tabBars.buttons["添加"]
        addTab.tap()
        let aiInput = app.textFields["ai-card-vocabulary-input"]
        XCTAssertTrue(aiInput.waitForExistence(timeout: 5))
        aiInput.tap()
        aiInput.typeText("食べる")
        dismissKeyboard(in: app)

        let manualMeaning = app.textFields["vocabulary-meaning-field"]
        reveal(manualMeaning, in: app)
        manualMeaning.tap()
        manualMeaning.typeText("手工内容")
        dismissKeyboard(in: app)

        let generate = app.buttons["ai-card-generate-button"]
        revealBySwipingDown(generate, in: app)
        generate.tap()
        let cancel = app.buttons["ai-card-cancel-button"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2))
        cancel.tap()
        XCTAssertEqual(aiInput.value as? String, "食べる", "取消必须保留原始输入")

        XCTAssertTrue(generate.waitForExistence(timeout: 2))
        generate.tap()
        let candidate = app.descendants(matching: .any)["ai-card-candidate-section"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        reveal(manualMeaning, in: app)
        XCTAssertEqual(manualMeaning.value as? String, "手工内容", "响应不得自动覆盖用户表单")

        let apply = app.buttons["ai-card-apply-candidate-button"]
        revealBySwipingDown(apply, in: app)
        apply.tap()
        let draftStatus = app.descendants(matching: .any)["vocabulary-draft-status"]
        revealBySwipingDown(draftStatus, in: app)
        XCTAssertTrue(draftStatus.exists)
        reveal(manualMeaning, in: app)
        XCTAssertEqual(manualMeaning.value as? String, "吃")
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertFalse(formalSave.isEnabled, "未选择牌组时不能正式入库")
    }

    @MainActor
    func testP19AnalyzesSentenceAndRestoresDraft() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let keyField = app.secureTextFields["ai-api-key-field"]
        reveal(keyField, in: app)
        XCTAssertTrue(keyField.isHittable)
        keyField.tap()
        keyField.typeText("ui-test-key")
        dismissKeyboard(in: app)

        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        aiToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enableButton = app.buttons["了解并启用"]
        XCTAssertTrue(enableButton.waitForExistence(timeout: 2))
        enableButton.tap()

        let saveConfiguration = app.buttons["ai-save-configuration-button"]
        reveal(saveConfiguration, in: app)
        XCTAssertTrue(saveConfiguration.isHittable)
        saveConfiguration.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ai-key-configured"].waitForExistence(timeout: 5)
        )

        let addTab = app.tabBars.buttons["添加"]
        addTab.tap()
        let kindPicker = app.segmentedControls["add-content-kind-picker"]
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["句子分析"].tap()

        let sentenceInput = app.textViews["sentence-analysis-input"]
        XCTAssertTrue(sentenceInput.waitForExistence(timeout: 5))
        sentenceInput.tap()
        sentenceInput.typeText("日本に行ったことがありますか。")
        dismissKeyboard(in: app)

        let analyze = app.buttons["sentence-analysis-start-button"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 3))
        XCTAssertTrue(analyze.isEnabled)
        analyze.tap()

        let translation = app.descendants(matching: .any)["sentence-analysis-translation"]
        XCTAssertTrue(translation.waitForExistence(timeout: 5))
        XCTAssertTrue(translation.label.contains("你去过日本吗"))
        let initialAlignment = app.staticTexts["sentence-analysis-aligned"]
        revealExistence(initialAlignment, in: app)
        XCTAssertTrue(initialAlignment.exists)

        let vocabulary = app.buttons["sentence-analysis-item-vocabulary-1"]
        revealExistence(vocabulary, in: app)
        XCTAssertTrue(vocabulary.exists)
        XCTAssertTrue(vocabulary.label.contains("行った"))
        XCTAssertTrue(vocabulary.label.contains("行く"))

        let grammar = app.buttons["sentence-analysis-item-grammar-2"]
        revealExistence(grammar, in: app)
        XCTAssertTrue(grammar.exists)
        XCTAssertTrue(grammar.label.contains("曾经"))

        let unalignedItem = app.buttons["sentence-analysis-item-expression-3"]
        revealExistence(unalignedItem, in: app)
        XCTAssertTrue(unalignedItem.exists)
        XCTAssertTrue(unalignedItem.label.contains("解释仍然可读"))

        let boundary = app.staticTexts["sentence-analysis-card-actions"]
        revealExistence(boundary, in: app)
        XCTAssertTrue(boundary.exists)

        let draftStatus = app.staticTexts["sentence_analysis-draft-status"]
        revealExistenceBySwipingDown(draftStatus, in: app)
        XCTAssertTrue(draftStatus.waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(addTab.waitForExistence(timeout: 5))
        addTab.tap()
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["句子分析"].tap()
        XCTAssertTrue(sentenceInput.waitForExistence(timeout: 5))
        XCTAssertEqual(sentenceInput.value as? String, "日本に行ったことがありますか。")
        XCTAssertTrue(
            app.descendants(matching: .any)["sentence-analysis-translation"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["已恢复上次分析草稿"].exists)
    }

    @MainActor
    func testP20SelectsTwoAnalysisItemsAndAtomicallyCreatesTwoCards() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckName = app.textFields["deck-name-field"]
        XCTAssertTrue(deckName.waitForExistence(timeout: 2))
        deckName.tap()
        deckName.typeText("P20 Cards")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["P20 Cards"].waitForExistence(timeout: 5))

        let settingsTab = app.tabBars.buttons["设置"]
        settingsTab.tap()
        let keyField = app.secureTextFields["ai-api-key-field"]
        reveal(keyField, in: app)
        keyField.tap()
        keyField.typeText("ui-test-key")
        dismissKeyboard(in: app)
        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        aiToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["了解并启用"].waitForExistence(timeout: 2))
        app.buttons["了解并启用"].tap()
        let saveConfiguration = app.buttons["ai-save-configuration-button"]
        reveal(saveConfiguration, in: app)
        saveConfiguration.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ai-key-configured"].waitForExistence(timeout: 5)
        )

        app.tabBars.buttons["添加"].tap()
        let kindPicker = app.segmentedControls["add-content-kind-picker"]
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["句子分析"].tap()
        let sentenceInput = app.textViews["sentence-analysis-input"]
        XCTAssertTrue(sentenceInput.waitForExistence(timeout: 5))
        sentenceInput.tap()
        sentenceInput.typeText("日本に行ったことがありますか。")
        dismissKeyboard(in: app)
        app.buttons["sentence-analysis-start-button"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["sentence-analysis-translation"]
                .waitForExistence(timeout: 5)
        )
        decksTab.tap()
        app.tabBars.buttons["添加"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["sentence-analysis-translation"]
                .waitForExistence(timeout: 5)
        )

        let selectVocabulary = app.switches["sentence-card-select-vocabulary-1"]
        reveal(selectVocabulary, in: app)
        setSwitch(selectVocabulary, enabled: true)
        let selectGrammar = app.switches["sentence-card-select-grammar-2"]
        reveal(selectGrammar, in: app)
        setSwitch(selectGrammar, enabled: true)

        let saveBatch = app.buttons["sentence-card-batch-save-button"]
        reveal(saveBatch, in: app)
        XCTAssertTrue(saveBatch.isEnabled)
        XCTAssertTrue(saveBatch.label.contains("2"))
        saveBatch.tap()
        let savedStatus = app.staticTexts["sentence-card-status"]
        let twoSaved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "2 个知识点"),
            object: savedStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [twoSaved], timeout: 5), .completed)

        decksTab.tap()
        let deck = app.staticTexts["P20 Cards"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        deck.tap()
        XCTAssertTrue(app.staticTexts["deck-note-count"].label.contains("2"))
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("2"))
        XCTAssertTrue(app.staticTexts["行く"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["～たことがある"].exists)
    }

    @MainActor
    func testP15ExposesGlobalAndDeckScopedSearch() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()

        let globalSearch = app.buttons["global-search-button"]
        XCTAssertTrue(globalSearch.waitForExistence(timeout: 5))
        globalSearch.tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["日语、假名或中文"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["global-search-empty-state"].exists)

        app.navigationBars["搜索"].buttons.element(boundBy: 0).tap()
        let createButton = app.buttons["deck-create-empty-button"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        let nameField = app.textFields["deck-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText("P15 Search")
        app.buttons["deck-name-save-button"].tap()

        let deck = app.staticTexts["P15 Search"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        deck.tap()
        XCTAssertTrue(app.navigationBars["P15 Search"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.searchFields["搜索本牌组"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testEmptyDeckCreateRenamePersistenceAndDeleteFlow() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()

        let emptyCreateButton = app.buttons["deck-create-empty-button"]
        XCTAssertTrue(emptyCreateButton.waitForExistence(timeout: 5))
        emptyCreateButton.tap()

        let nameField = app.textFields["deck-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        let saveButton = app.buttons["deck-name-save-button"]
        XCTAssertFalse(saveButton.isEnabled)
        nameField.tap()
        nameField.typeText("N5 单词")
        saveButton.tap()

        let createdDeck = app.staticTexts["N5 单词"]
        XCTAssertTrue(createdDeck.waitForExistence(timeout: 5))
        createdDeck.tap()
        XCTAssertTrue(app.navigationBars["N5 单词"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["deck-note-count"].label.contains("0"))
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("0"))

        app.buttons["deck-rename-button"].tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        let clearNameButton = app.buttons["deck-name-clear-button"]
        XCTAssertTrue(clearNameButton.waitForExistence(timeout: 2))
        clearNameButton.tap()
        nameField.tap()
        nameField.typeText("日语基础")
        XCTAssertEqual(nameField.value as? String, "日语基础")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.navigationBars["日语基础"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        let persistedDeck = app.staticTexts["日语基础"]
        XCTAssertTrue(persistedDeck.waitForExistence(timeout: 5))
        persistedDeck.tap()

        app.buttons["deck-delete-button"].tap()
        let confirmDelete = app.buttons["确认删除"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 2))
        confirmDelete.tap()
        XCTAssertTrue(emptyCreateButton.waitForExistence(timeout: 5))
    }

    @MainActor
    func testVocabularyDraftPersistsAndFormalSaveRequiresDeck() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let addTab = app.tabBars.buttons["添加"]
        XCTAssertTrue(addTab.waitForExistence(timeout: 5))
        addTab.tap()

        let headwordField = app.textFields["vocabulary-headword-field"]
        let meaningField = app.textFields["vocabulary-meaning-field"]
        XCTAssertTrue(headwordField.waitForExistence(timeout: 5))
        let additionalFields = app.buttons["更多字段（可选）"]
        reveal(additionalFields, in: app)
        XCTAssertTrue(additionalFields.exists)
        additionalFields.tap()
        let readingField = app.textFields["vocabulary-reading-field"]
        XCTAssertTrue(readingField.waitForExistence(timeout: 2))
        XCTAssertEqual(readingField.placeholderValue, "假名")
        headwordField.tap()
        headwordField.typeText("食べる")
        meaningField.tap()
        meaningField.typeText("吃")
        dismissKeyboard(in: app)

        app.buttons["vocabulary-save-draft-button"].tap()
        XCTAssertTrue(app.staticTexts["草稿已保存"].waitForExistence(timeout: 5))

        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertFalse(formalSave.isEnabled)

        app.terminate()
        app.launch()
        XCTAssertTrue(addTab.waitForExistence(timeout: 5))
        addTab.tap()

        let kindPicker = app.segmentedControls["add-content-kind-picker"]
        revealExistenceBySwipingDown(kindPicker, in: app)
        XCTAssertTrue(kindPicker.exists)
        kindPicker.buttons["单词"].tap()
        reveal(headwordField, in: app)
        XCTAssertTrue(headwordField.exists)
        XCTAssertEqual(headwordField.value as? String, "食べる")
        XCTAssertEqual(meaningField.value as? String, "吃")
        let restoredStatus = app.staticTexts["已恢复上次草稿"]
        revealExistenceBySwipingDown(restoredStatus, in: app)
        XCTAssertTrue(restoredStatus.exists)

        let restoredFormalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(restoredFormalSave, in: app)
        XCTAssertTrue(restoredFormalSave.exists)
        XCTAssertFalse(restoredFormalSave.isEnabled)
    }

    @MainActor
    func testManualVocabularyCreatesTwoCardsPersistsEditsAndRestoresDirection() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("P08 验收")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["P08 验收"].waitForExistence(timeout: 5))

        let addTab = app.tabBars.buttons["添加"]
        addTab.tap()
        let reverseDirection = app.switches["vocabulary-direction-zh-ja"]
        reveal(reverseDirection, in: app)
        XCTAssertTrue(reverseDirection.exists)
        setSwitch(reverseDirection, enabled: true)

        let headwordField = app.textFields["vocabulary-headword-field"]
        let meaningField = app.textFields["vocabulary-meaning-field"]
        reveal(headwordField, in: app)
        XCTAssertTrue(headwordField.waitForExistence(timeout: 5))
        headwordField.tap()
        headwordField.typeText("食べる")
        meaningField.tap()
        meaningField.typeText("吃")

        dismissKeyboard(in: app)

        let flipButton = app.buttons["card-preview-flip-vocabulary-ja-zh"]
        reveal(flipButton, in: app)
        XCTAssertTrue(flipButton.exists)
        flipButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["card-preview-answer-vocabulary-ja-zh"].exists
        )

        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        app.terminate()
        app.launch()
        let relaunchedDecksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(relaunchedDecksTab.waitForExistence(timeout: 5))
        selectDecksTab(in: app)
        let deck = app.staticTexts["P08 验收"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        deck.tap()
        XCTAssertTrue(app.staticTexts["deck-note-count"].label.contains("1"))
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("2"))
        let knowledgePoint = app.staticTexts["食べる"]
        XCTAssertTrue(knowledgePoint.waitForExistence(timeout: 5))
        knowledgePoint.tap()

        let reverseDirectionInDetail = app.switches[
            "card-direction-toggle-vocabulary_zh_ja"
        ]
        reveal(reverseDirectionInDetail, in: app)
        XCTAssertTrue(reverseDirectionInDetail.exists)
        XCTAssertEqual(reverseDirectionInDetail.value as? String, "1")
        setSwitch(reverseDirectionInDetail, enabled: false)
        setSwitch(reverseDirectionInDetail, enabled: true)

        let editButton = app.buttons["vocabulary-edit-button"]
        XCTAssertTrue(editButton.exists)
        editButton.tap()
        let editMeaning = app.textFields["vocabulary-meaning-field"]
        XCTAssertTrue(editMeaning.waitForExistence(timeout: 2))
        editMeaning.tap()
        editMeaning.typeText("2")
        app.buttons["vocabulary-edit-save-button"].tap()
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.tap()
        XCTAssertTrue(editMeaning.waitForExistence(timeout: 2))
        XCTAssertTrue((editMeaning.value as? String)?.hasSuffix("2") == true)
    }

    @MainActor
    func testGrammarDraftPersistsWithIsolatedFieldsAndFavoritesEntry() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let addTab = app.tabBars.buttons["添加"]
        XCTAssertTrue(addTab.waitForExistence(timeout: 5))
        addTab.tap()

        let kindPicker = app.segmentedControls["add-content-kind-picker"]
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["语法"].tap()

        let grammarFormField = app.textFields["grammar-form-field"]
        let grammarMeaningField = app.textFields["grammar-meaning-field"]
        XCTAssertTrue(grammarFormField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["vocabulary-reading-field"].exists)
        grammarFormField.tap()
        grammarFormField.typeText("Vたことがある")
        grammarMeaningField.tap()
        grammarMeaningField.typeText("曾经做过")
        dismissKeyboard(in: app)

        app.buttons["grammar-save-draft-button"].tap()
        XCTAssertTrue(app.staticTexts["草稿已保存"].waitForExistence(timeout: 5))

        let formalSave = app.buttons["grammar-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertFalse(formalSave.isEnabled)

        app.terminate()
        app.launch()
        XCTAssertTrue(addTab.waitForExistence(timeout: 5))
        addTab.tap()
        revealExistenceBySwipingDown(kindPicker, in: app)
        XCTAssertTrue(kindPicker.exists)
        kindPicker.buttons["语法"].tap()

        reveal(grammarFormField, in: app)
        XCTAssertTrue(grammarFormField.exists)
        XCTAssertEqual(grammarFormField.value as? String, "Vたことがある")
        XCTAssertEqual(grammarMeaningField.value as? String, "曾经做过")
        XCTAssertFalse(app.textFields["vocabulary-reading-field"].exists)
        let restoredStatus = app.staticTexts["已恢复上次草稿"]
        revealExistenceBySwipingDown(restoredStatus, in: app)
        XCTAssertTrue(restoredStatus.exists)

        let decksTab = app.tabBars.buttons["牌组"]
        decksTab.tap()
        let favoritesButton = app.buttons["favorites-button"]
        XCTAssertTrue(favoritesButton.waitForExistence(timeout: 5))
        favoritesButton.tap()
        XCTAssertTrue(app.navigationBars["收藏"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["还没有收藏"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testManualCardCompletesRealTodayReviewAndSurvivesRestart() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("P11 Flow")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["P11 Flow"].waitForExistence(timeout: 5))

        app.tabBars.buttons["添加"].tap()
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        XCTAssertTrue(headword.waitForExistence(timeout: 5))
        headword.tap()
        headword.typeText("taberu")
        meaning.tap()
        meaning.typeText("eat")
        dismissKeyboard(in: app)
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["today-summary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today-new-count"].label, "1")
        XCTAssertEqual(app.staticTexts["today-remaining-count"].label, "1")
        XCTAssertEqual(app.staticTexts["today-learned-count"].label, "0")
        XCTAssertEqual(app.staticTexts["today-review-answer-count"].label, "0")
        XCTAssertEqual(app.staticTexts["today-answer-count"].label, "0")
        let start = app.buttons["today-start-all-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()

        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-rating-easy"].exists)
        app.buttons["review-show-answer-button"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["review-rating-again"].exists)
        XCTAssertTrue(app.buttons["review-rating-hard"].exists)
        XCTAssertTrue(app.buttons["review-rating-good"].exists)
        XCTAssertTrue(app.buttons["review-rating-easy"].exists)

        app.navigationBars["全部牌组"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today-new-count"].label, "1")
        XCTAssertEqual(app.staticTexts["today-remaining-count"].label, "1")

        let deckStart = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'today-start-deck-'")
        ).firstMatch
        XCTAssertTrue(deckStart.waitForExistence(timeout: 5))
        deckStart.tap()
        XCTAssertTrue(app.navigationBars["P11 Flow"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["review-show-answer-button"].waitForExistence(timeout: 5))
        app.buttons["review-show-answer-button"].tap()
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        easy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )

        let undo = app.buttons["review-undo-button"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))
        XCTAssertFalse(undo.exists)
        XCTAssertTrue(app.buttons["review-show-answer-button"].waitForExistence(timeout: 3))
        app.buttons["review-show-answer-button"].tap()
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        easy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["today-day-complete"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today-completed-count"].label, "1")
        XCTAssertEqual(app.staticTexts["today-remaining-count"].label, "0")
        XCTAssertEqual(app.staticTexts["today-learned-count"].label, "1")
        XCTAssertEqual(app.staticTexts["today-review-answer-count"].label, "0")
        XCTAssertEqual(app.staticTexts["today-answer-count"].label, "1")
        let easyRatingCount = app.descendants(matching: .any)["today-rating-easy-count"]
        XCTAssertTrue(easyRatingCount.waitForExistence(timeout: 3))
        XCTAssertTrue(easyRatingCount.label.contains("1"))

        decksTab.tap()
        let deckTodayCounts = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'deck-today-counts-'")
        ).firstMatch
        XCTAssertTrue(deckTodayCounts.waitForExistence(timeout: 5))
        XCTAssertTrue(deckTodayCounts.label.contains("今日新卡 1 · 复习 0"))
        app.staticTexts["P11 Flow"].firstMatch.tap()
        let knowledgePoint = app.staticTexts["taberu"]
        XCTAssertTrue(knowledgePoint.waitForExistence(timeout: 5))
        knowledgePoint.tap()

        let cardHistory = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'card-history-card-'")
        ).firstMatch
        reveal(cardHistory, in: app)
        XCTAssertTrue(cardHistory.exists)
        cardHistory.tap()
        let activeHistoryCount = app.descendants(matching: .any)["card-history-active-count"]
        XCTAssertTrue(activeHistoryCount.waitForExistence(timeout: 5))
        XCTAssertTrue(activeHistoryCount.label.contains("1 次"))
        let historyEntries = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'card-history-entry-'")
        )
        XCTAssertEqual(historyEntries.count, 2)
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
    }

    @MainActor
    private func moveIntoInteractionSafeArea(_ element: XCUIElement, in app: XCUIApplication) {
        guard element.exists, element.frame.maxY >= app.frame.maxY - 100 else { return }
        let form = app.collectionViews.firstMatch
        form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(
                forDuration: 0.05,
                thenDragTo: form.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)
                )
            )
    }

    @MainActor
    private func revealBySwipingDown(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists, element.isHittable {
                return
            }
            form.swipeDown()
        }
    }

    @MainActor
    private func revealExistence(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists {
                return
            }
            form.swipeUp()
        }
    }

    @MainActor
    private func revealExistenceBySwipingDown(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists {
                return
            }
            form.swipeDown()
        }
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let returnKey = app.keyboards.buttons["return"]
        if returnKey.exists {
            returnKey.tap()
        } else {
            app.keyboards.firstMatch.swipeDown()
        }
    }

    @MainActor
    private func setSwitch(_ element: XCUIElement, enabled: Bool) {
        let expectedValue = enabled ? "1" : "0"
        guard element.value as? String != expectedValue else { return }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func selectDecksTab(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.375, dy: 0.95)).tap()
    }

}
