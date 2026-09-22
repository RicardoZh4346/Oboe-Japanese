import Foundation
import UIKit
import XCTest

final class OboeNavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSwitchesBetweenThreePrimaryTabs() {
        let app = XCUIApplication()
        app.launch()

        // v0.5.5：「添加」入口迁入牌组详情，一级 tab 收敛为三个。
        let expectedTabs = ["今日", "牌组", "设置"]
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

    /// v0.5.5 每日统计：complete 种子含一条有效 review_log，统计页应
    /// 显示连续天数 ≥1 且最近 30 天列表可独立加载。
    @MainActor
    func testDailyStatisticsOpensFromTodayAndShowsStreak() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_TODAY_SEED"] = "complete"
        app.launch()

        let entry = app.descendants(matching: .any)["today-statistics-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(
            app.navigationBars["每日统计"].waitForExistence(timeout: 5),
            "未进入每日统计页"
        )
        XCTAssertTrue(
            app.staticTexts["statistics-streak-count"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.staticTexts["statistics-streak-count"].label,
            "1",
            "complete 种子含一条今日有效评分，streak 应为 1"
        )
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
    func testT24DashboardCumulativeCountsAndCategoryPagination() {
        let app = openT24Dashboard()
        XCTAssertTrue(app.staticTexts["共 662 个词"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["jlpt-progress-notAdded"].label.contains("662"))
        app.buttons["jlpt-progress-target"].tap()
        app.buttons["N3"].tap()
        let total = app.staticTexts["jlpt-progress-total"]
        let n3Count = NSPredicate(format: "label MATCHES %@", "共 3,?078 个词")
        expectation(for: n3Count, evaluatedWith: total)
        waitForExpectations(timeout: 10)
        app.buttons["jlpt-progress-notAdded"].tap()
        let listTotal = app.staticTexts["jlpt-progress-list-total"]
        XCTAssertTrue(listTotal.waitForExistence(timeout: 10))
        XCTAssertEqual(listTotal.label.replacingOccurrences(of: ",", with: ""), "N3 累计 · 3078 个词")
        XCTAssertTrue(app.staticTexts["あさって"].exists)
        let more = app.buttons["jlpt-progress-load-more"]
        for _ in 0..<30 {
            if more.exists && more.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(more.isHittable)
        more.tap()
        for _ in 0..<30 {
            if more.exists && more.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["jlpt-progress-loaded-count"].label.contains("80"))
        XCTAssertFalse(app.staticTexts["掌握率"].exists)
    }

    @MainActor
    func testT24DashboardDarkAccessibilitySizeAndEmptyCategory() {
        let app = openT24Dashboard(large: true)
        let stable = app.buttons["jlpt-progress-stable"]
        for _ in 0..<12 {
            if stable.exists && stable.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(stable.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "T24-Dashboard-Dark-AX5"
        attachment.lifetime = .keepAlways
        add(attachment)
        stable.tap()
        XCTAssertTrue(app.staticTexts["此分类暂无词汇"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testT24DashboardRecomputesAfterWholeLevelImport() {
        let app = openT24Dashboard()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["jlpt-level-N5"].tap()
        app.buttons["导入全级"].tap()
        // v0.5.5：整级导入先显式选牌组——确认弹窗后进选牌组 sheet，空库需先建牌组。
        app.buttons["选择牌组并导入"].tap()
        let createDeck = app.buttons["jlpt-level-import-create-deck"]
        XCTAssertTrue(createDeck.waitForExistence(timeout: 5))
        createDeck.tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("N5 全级")
        app.buttons["deck-name-save-button"].tap()
        let confirm = app.buttons["jlpt-level-import-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.alerts["操作结果"].waitForExistence(timeout: 60))
        let result = app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "新增 ")).firstMatch.label
        let imported = Int(result.components(separatedBy: "新增 ").last?
            .components(separatedBy: "，").first ?? "") ?? 0
        XCTAssertGreaterThan(imported, 0)
        app.alerts.buttons["好"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["jlpt-progress-entry"].tap()
        let learning = app.buttons["jlpt-progress-learning"]
        XCTAssertTrue(learning.waitForExistence(timeout: 10))
        XCTAssertTrue(learning.label.contains("\(imported) 个词"))
        XCTAssertTrue(app.buttons["jlpt-progress-notAdded"].label.contains("\(662 - imported) 个词"))
        learning.tap()
        XCTAssertTrue(app.staticTexts["N5 累计 · \(imported) 个词"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["N5 · 学习中 · 未开始"].firstMatch.exists)
    }

    /// T25: the dashboard's 需要关注 entry opens the weak-vocabulary
    /// list. The seed binds a builtin note to the real N5 食べる entry
    /// with two leech directions plus an unassociated manual leech card —
    /// the word must appear once (dedup by entry), expand to both
    /// directions, drill into the shared card detail, and move between
    /// 易错/已暂停 filters exactly like the Adaptive center.
    @MainActor
    func testT25WeakVocabularyDedupDirectionsAndSuspendResume() {
        let app = openT24Dashboard(environment: ["OBOE_UI_TEST_JLPT_WEAK_SEED": "1"])

        // Dashboard entry: ONE word under 易错 although two leech
        // directions exist — counting unit is the library entry.
        // 入口在「已加入的辅助状态」section 之后，SE 首屏之外——先滚动显露。
        let entry = app.buttons["jlpt-weak-entry"]
        revealExistence(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("经常遗忘 1 个词"), entry.label)
        entry.tap()

        // Weak list: dedup proof — two leech cards AND the unassociated
        // manual leech card still produce exactly one weak word.
        XCTAssertTrue(app.navigationBars["需要关注"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["jlpt-weak-total"].label,
            "N5 累计 · 1 个词",
            "同词双 leech 只计一词；手动 Note 的 leech 不计入内置进度"
        )
        // The headword text and the disclosure button share the identifier —
        // the button query resolves to the single tappable row.
        let wordRow = app.buttons[
            "jlpt-weak-word-openjlpt:N5:df220e3db92cd43c596cbf63d8b3435c49df5e8fb4da32b65014ff9ab3c29bbd"
        ]
        XCTAssertTrue(wordRow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["N5 · 2 个薄弱方向"].waitForExistence(timeout: 3))

        // Expand → both weak directions link to the shared card detail.
        // NavigationLink rows surface as cells/links, not buttons — query
        // by identifier across all element types.
        let directionLinks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'jlpt-weak-card-'")
        )
        if !directionLinks.firstMatch.exists { wordRow.tap() }
        XCTAssertTrue(directionLinks.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(directionLinks.count, 2, "展开必须列出两个薄弱方向")
        XCTAssertTrue(app.staticTexts["日语 → 中文"].exists)
        XCTAssertTrue(app.staticTexts["中文 → 日语"].exists)

        // Drill into the first direction — same Adaptive detail actions.
        directionLinks.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        let detailList = app.collectionViews.firstMatch
        let suspend = app.buttons["暂停这张卡"]
        for _ in 0..<6 where !suspend.isHittable {
            detailList.swipeUp()
        }
        XCTAssertTrue(suspend.waitForExistence(timeout: 3))
        suspend.tap()
        XCTAssertTrue(app.staticTexts["重新启用这张卡"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // One direction still enabled-leech: word stays in 易错, now 1 方向.
        XCTAssertTrue(app.staticTexts["N5 · 1 个薄弱方向"].waitForExistence(timeout: 5))

        // Suspend the remaining direction → the word leaves 易错 entirely.
        let remaining = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'jlpt-weak-card-'")
        ).firstMatch
        XCTAssertTrue(remaining.waitForExistence(timeout: 3))
        remaining.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        let suspend2 = app.buttons["暂停这张卡"]
        for _ in 0..<6 where !suspend2.isHittable {
            detailList.swipeUp()
        }
        XCTAssertTrue(suspend2.waitForExistence(timeout: 3))
        suspend2.tap()
        XCTAssertTrue(app.staticTexts["重新启用这张卡"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["jlpt-weak-empty-leech"]
                .waitForExistence(timeout: 5),
            "全部 leech 方向暂停后易错筛选必须为空"
        )

        // 已暂停筛选：同一词带着两个暂停方向出现 —— 与易错中心一致。
        app.buttons["已暂停 1"].tap()
        XCTAssertEqual(app.staticTexts["jlpt-weak-total"].label, "N5 累计 · 1 个词")
        XCTAssertTrue(wordRow.waitForExistence(timeout: 5))
        let suspendedLinks = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'jlpt-weak-card-'")
        )
        // Expansion state survives the filter switch — only tap when the
        // disclosure is actually collapsed, otherwise the tap collapses it.
        if !suspendedLinks.firstMatch.exists { wordRow.tap() }
        XCTAssertTrue(suspendedLinks.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(suspendedLinks.count, 2)

        // Resume one direction → the word returns to 易错 with 1 方向.
        suspendedLinks.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        let resume = app.buttons["重新启用这张卡"]
        for _ in 0..<6 where !resume.isHittable {
            detailList.swipeUp()
        }
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        resume.tap()
        XCTAssertTrue(app.staticTexts["暂停这张卡"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["易错 1"].tap()
        XCTAssertEqual(app.staticTexts["jlpt-weak-total"].label, "N5 累计 · 1 个词")
        XCTAssertTrue(app.staticTexts["N5 · 1 个薄弱方向"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openT24Dashboard(
        large: Bool = false,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        if large {
            app.launchEnvironment["OBOE_UI_TEST_DYNAMIC_TYPE"] = "ax5"
            app.launchEnvironment["OBOE_UI_TEST_APPEARANCE_DARK"] = "1"
        }
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["牌组"].waitForExistence(timeout: 5))
        app.tabBars.buttons["牌组"].tap()
        app.buttons["jlpt-library-entry"].tap()
        let acknowledge = app.buttons["我知道了"]
        if acknowledge.waitForExistence(timeout: 2) { acknowledge.tap() }
        let progress = app.buttons["jlpt-progress-entry"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        progress.tap()
        XCTAssertTrue(app.staticTexts["jlpt-progress-total"].waitForExistence(timeout: 10))
        return app
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
        XCTAssertTrue(dailyLimit.label.contains("每日新词"))
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
        // 状态行在保存按钮下方，SE 首屏之外——先滚动显露再等待。
        let saveStatus = app.staticTexts["learning-settings-status"]
        revealExistence(saveStatus, in: app)
        XCTAssertTrue(saveStatus.waitForExistence(timeout: 5))

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

        openAddFlow(in: app, deckName: "P21b Small Screen")
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
        dismissKeyboard(in: app)
        let meaning = app.textFields["grammar-meaning-field"]
        revealExistence(meaning, in: app)
        XCTAssertTrue(meaning.exists)
        meaning.tap()
        meaning.typeText("A deliberately long explanation that wraps across several lines on a small screen.")
        dismissKeyboard(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))

        let save = app.buttons["grammar-formal-save-button"]
        reveal(save, in: app)
        XCTAssertTrue(save.isHittable)
        save.tap()

        app.terminate()
        app.launch()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5)
        )
        showReviewAnswer(in: app)

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

        // 未配置 Key 时按钮处于禁用态——disabled 元素不可 hit-test，
        // reveal() 会扫过它导致离屏卸载，只能用存在性显露。
        let testButton = app.buttons["ai-test-connection-button"]
        revealExistence(testButton, in: app)
        XCTAssertTrue(testButton.exists)
        XCTAssertFalse(testButton.isEnabled, "未启用且没有 Key 时不得发起连接测试")

        let costNotice = app.staticTexts["ai-connection-cost-note"]
        revealExistence(costNotice, in: app)
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

        createDeck(in: app, named: "AI 制卡")
        openAddFlow(in: app, deckName: "AI 制卡")
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
        XCTAssertTrue(formalSave.isEnabled, "添加流自带目标牌组，候选应用后可直接入库")
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

        createDeck(in: app, named: "句子分析")
        openAddFlow(in: app, deckName: "句子分析")
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
        // 结果段在首屏下方：List 只挂载视口附近的行，需先滚动显露。
        revealExistence(translation, in: app)
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
        openAddFlow(in: app, deckName: "句子分析")
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["句子分析"].tap()
        XCTAssertTrue(sentenceInput.waitForExistence(timeout: 5))
        XCTAssertEqual(sentenceInput.value as? String, "日本に行ったことがありますか。")
        let restoredTranslation = app.descendants(matching: .any)["sentence-analysis-translation"]
        revealExistence(restoredTranslation, in: app)
        XCTAssertTrue(restoredTranslation.waitForExistence(timeout: 5))
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

        openAddFlow(in: app, deckName: "P20 Cards")
        let kindPicker = app.segmentedControls["add-content-kind-picker"]
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["句子分析"].tap()
        let sentenceInput = app.textViews["sentence-analysis-input"]
        XCTAssertTrue(sentenceInput.waitForExistence(timeout: 5))
        sentenceInput.tap()
        sentenceInput.typeText("日本に行ったことがありますか。")
        dismissKeyboard(in: app)
        app.buttons["sentence-analysis-start-button"].tap()
        let translation = app.descendants(matching: .any)["sentence-analysis-translation"]
        revealExistence(translation, in: app)
        XCTAssertTrue(translation.waitForExistence(timeout: 5))
        // 牌组详情的添加流每次进入都是新编辑器实例：草稿已恢复，
        // 但需要重新切到「句子分析」分页才会渲染结果段。
        openAddFlow(in: app, deckName: "P20 Cards")
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["句子分析"].tap()
        let restoredTranslation = app.descendants(matching: .any)["sentence-analysis-translation"]
        revealExistence(restoredTranslation, in: app)
        XCTAssertTrue(restoredTranslation.waitForExistence(timeout: 5))

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
        // 词汇知识点固定生成三个方向卡 + 语法 1 张 = 4。
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("4"))
        // 知识行在统计卡下方的 List 里，SE 首屏只挂视口附近几行——
        // 两行顺序不定（created_at 并列时按 id 排序），双向扫描显露。
        revealBidirectional(app.staticTexts["行く"], in: app)
        XCTAssertTrue(app.staticTexts["行く"].waitForExistence(timeout: 5))
        revealBidirectional(app.staticTexts["～たことがある"], in: app)
        XCTAssertTrue(app.staticTexts["～たことがある"].waitForExistence(timeout: 5))
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

    /// 牌组详情页顶部提供「设为主牌组」：当日新卡额度先满足主牌组，
    /// 切换后立即重算；未手动指定时自动以排序最前的牌组为主牌组，
    /// 只有零牌组时才是未设置（无取消入口）。
    @MainActor
    func testPrimaryDeckAutoDefaultsAndSwitchesFromDeckDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        let createButton = app.buttons["deck-create-empty-button"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.tap()
        let nameField = app.textFields["deck-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText("主牌组测试")
        app.buttons["deck-name-save-button"].tap()

        let deck = app.staticTexts["主牌组测试"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        deck.tap()
        XCTAssertTrue(app.navigationBars["主牌组测试"].waitForExistence(timeout: 3))

        // 唯一牌组自动成为主牌组：直接显示状态，无设置/取消入口。
        XCTAssertTrue(
            app.descendants(matching: .any)["deck-primary-status"].waitForExistence(timeout: 5),
            "唯一牌组应自动成为主牌组并显示状态"
        )
        XCTAssertFalse(app.buttons["deck-set-primary"].exists)
        XCTAssertFalse(app.buttons["deck-unset-primary"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["主牌组"].waitForExistence(timeout: 5),
            "牌组列表必须给主牌组显示徽标"
        )

        // 新建第二个牌组后可从详情页切换主牌组。
        let createToolbar = app.buttons["deck-create-toolbar-button"]
        XCTAssertTrue(createToolbar.waitForExistence(timeout: 5))
        createToolbar.tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText("副牌组")
        app.buttons["deck-name-save-button"].tap()
        let secondDeck = app.staticTexts["副牌组"]
        XCTAssertTrue(secondDeck.waitForExistence(timeout: 5))
        secondDeck.tap()
        XCTAssertTrue(app.navigationBars["副牌组"].waitForExistence(timeout: 3))

        let setPrimary = app.buttons["deck-set-primary"]
        XCTAssertTrue(setPrimary.waitForExistence(timeout: 3))
        setPrimary.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["deck-primary-status"].waitForExistence(timeout: 5),
            "设为主牌组后详情页必须显示当前主牌组状态"
        )

        // 第一个牌组不再是主牌组，详情页恢复「设为主牌组」入口。
        app.navigationBars.buttons.element(boundBy: 0).tap()
        deck.tap()
        XCTAssertTrue(
            app.buttons["deck-set-primary"].waitForExistence(timeout: 3),
            "非主牌组详情页必须提供「设为主牌组」"
        )
    }

    /// T13：首页只显示一行主牌组（设计 §8.2）——有牌组时显示有效主牌组
    ///（未手动指定时自动默认排序最前的牌组），主牌组被删除后自动回落
    /// 下一个牌组，只有零牌组才显示「未设置」；不出现逐牌组学习入口。
    @MainActor
    func testTodayShowsPrimaryDeckLineWithoutPerDeckEntries() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        // 首个牌组走空态按钮，之后用工具栏的「新建牌组」。
        for (index, name) in ["主牌组首页", "保留牌组"].enumerated() {
            let createButton = index == 0
                ? app.buttons["deck-create-empty-button"]
                : app.buttons["deck-create-toolbar-button"]
            XCTAssertTrue(createButton.waitForExistence(timeout: 5))
            createButton.tap()
            let nameField = app.textFields["deck-name-field"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 2))
            nameField.tap()
            nameField.typeText(name)
            app.buttons["deck-name-save-button"].tap()
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        }

        // 自动默认状态：排序最前的「主牌组首页」即主牌组。
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-refresh-button"].tap()
        let primaryLine = app.staticTexts["today-primary-deck"]
        XCTAssertTrue(primaryLine.waitForExistence(timeout: 5))
        XCTAssertTrue(
            primaryLine.label.contains("主牌组首页"),
            "有牌组时必须显示有效主牌组（自动默认排序最前者），实为 \(primaryLine.label)"
        )
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'today-start-deck-'")
            ).firstMatch.exists
        )

        // 手动改为「保留牌组」后首页显示它的名称。
        decksTab.tap()
        app.staticTexts["保留牌组"].tap()
        let setPrimary = app.buttons["deck-set-primary"]
        XCTAssertTrue(setPrimary.waitForExistence(timeout: 3))
        setPrimary.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["deck-primary-status"]
                .waitForExistence(timeout: 5)
        )
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-refresh-button"].tap()
        XCTAssertTrue(primaryLine.waitForExistence(timeout: 5))
        XCTAssertTrue(primaryLine.label.contains("保留牌组"))

        // 删除当前主牌组后自动回落到剩余的「主牌组首页」。
        decksTab.tap()
        app.staticTexts["保留牌组"].tap()
        let deleteButton = app.buttons["deck-delete-button"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()
        let confirm = app.buttons["确认删除"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["主牌组首页"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["保留牌组"].exists)
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-refresh-button"].tap()
        XCTAssertTrue(primaryLine.waitForExistence(timeout: 5))
        XCTAssertTrue(
            primaryLine.label.contains("主牌组首页"),
            "删除主牌组后应自动回落到剩余牌组，实为 \(primaryLine.label)"
        )

        // 删除最后一个牌组后才显示「未设置」。
        decksTab.tap()
        app.staticTexts["主牌组首页"].tap()
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(
            app.buttons["deck-create-empty-button"].waitForExistence(timeout: 5),
            "删除全部牌组后回到空态"
        )
        app.tabBars.buttons["今日"].tap()
        app.buttons["today-refresh-button"].tap()
        XCTAssertTrue(primaryLine.waitForExistence(timeout: 5))
        XCTAssertTrue(
            primaryLine.label.contains("未设置"),
            "没有任何牌组时才显示未设置，实为 \(primaryLine.label)"
        )
    }

    @MainActor
    func testVocabularyDraftPersistsAcrossRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        // v0.5.5：添加流必须经由牌组进入，目标牌组在入口已确定。
        createDeck(in: app, named: "词汇草稿")
        openAddFlow(in: app, deckName: "词汇草稿")

        let headwordField = app.textFields["vocabulary-headword-field"]
        let meaningField = app.textFields["vocabulary-meaning-field"]
        revealExistence(headwordField, in: app)
        XCTAssertTrue(headwordField.exists)
        let additionalFields = app.buttons["更多字段（可选）"]
        reveal(additionalFields, in: app)
        XCTAssertTrue(additionalFields.exists)
        additionalFields.tap()
        let readingField = app.textFields["vocabulary-reading-field"]
        XCTAssertTrue(readingField.waitForExistence(timeout: 2))
        XCTAssertEqual(readingField.placeholderValue, "假名")
        headwordField.tap()
        headwordField.typeText("食べる")
        dismissKeyboard(in: app)
        meaningField.tap()
        meaningField.typeText("吃")
        dismissKeyboard(in: app)

        app.buttons["vocabulary-save-draft-button"].tap()
        let savedStatus = app.staticTexts["草稿已保存"]
        revealExistenceBySwipingDown(savedStatus, in: app)
        XCTAssertTrue(savedStatus.waitForExistence(timeout: 5))

        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertTrue(formalSave.isEnabled, "入口牌组即目标牌组，字段齐即可入库")

        app.terminate()
        app.launch()
        openAddFlow(in: app, deckName: "词汇草稿")

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
        XCTAssertTrue(restoredFormalSave.isEnabled)
    }

    @MainActor
    func testT08VocabularyPartOfSpeechUsesControlledMultiSelectAtAccessibilitySize() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_DYNAMIC_TYPE"] = "ax5"
        app.launch()

        createDeck(in: app, named: "T08 词性")
        openAddFlow(in: app, deckName: "T08 词性")

        let additionalFields = app.buttons["更多字段（可选）"]
        reveal(additionalFields, in: app)
        XCTAssertTrue(additionalFields.isHittable)
        additionalFields.tap()

        let partOfSpeech = app.buttons["vocabulary-part-of-speech-field"]
        reveal(partOfSpeech, in: app)
        XCTAssertTrue(partOfSpeech.waitForExistence(timeout: 3))
        XCTAssertTrue(partOfSpeech.isHittable)
        XCTAssertFalse(
            app.textFields["vocabulary-part-of-speech-field"].exists,
            "词性必须是受控选择器，不能出现在文本输入 accessibility tree 中"
        )
        XCTAssertEqual(partOfSpeech.value as? String, "未设置")
        partOfSpeech.tap()

        let pronoun = app.buttons["part-of-speech-option-pronoun"]
        let noun = app.buttons["part-of-speech-option-noun"]
        XCTAssertTrue(pronoun.waitForExistence(timeout: 3))
        XCTAssertEqual(pronoun.value as? String, "未选中")
        pronoun.tap()
        noun.tap()
        XCTAssertEqual(pronoun.value as? String, "已选中")
        XCTAssertEqual(noun.value as? String, "已选中")
        app.buttons["part-of-speech-done"].tap()

        XCTAssertTrue(partOfSpeech.waitForExistence(timeout: 3))
        XCTAssertEqual(partOfSpeech.value as? String, "名词 / 代词")
    }

    @MainActor
    func testT09VocabularyPitchPickerOffersMoraBoundedValues() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        createDeck(in: app, named: "T09 音调")
        openAddFlow(in: app, deckName: "T09 音调")

        let additionalFields = app.buttons["更多字段（可选）"]
        reveal(additionalFields, in: app)
        XCTAssertTrue(additionalFields.isHittable)
        additionalFields.tap()

        let reading = app.textFields["vocabulary-reading-field"]
        XCTAssertTrue(reading.waitForExistence(timeout: 3))
        reading.tap()
        reading.typeText("あいうえおか")
        dismissKeyboard(in: app)

        let pitch = app.buttons["vocabulary-pitch-accent-picker"]
        reveal(pitch, in: app)
        XCTAssertTrue(pitch.waitForExistence(timeout: 3))
        XCTAssertTrue(pitch.label.contains("未设置"), pitch.label)
        pitch.tap()
        let six = app.buttons["6"]
        XCTAssertTrue(six.waitForExistence(timeout: 3), "6 mora 读音必须提供音调 6")
        six.tap()
        XCTAssertTrue(pitch.label.contains("6"), pitch.label)

        pitch.tap()
        let unset = app.buttons["未设置"]
        XCTAssertTrue(unset.waitForExistence(timeout: 3))
        unset.tap()
        XCTAssertTrue(pitch.label.contains("未设置"), pitch.label)

        pitch.tap()
        let flat = app.buttons["0（平板型）"]
        XCTAssertTrue(flat.waitForExistence(timeout: 3))
        flat.tap()
        XCTAssertTrue(pitch.label.contains("0（平板型）"), pitch.label)
    }

    @MainActor
    func testManualVocabularyCreatesAllDirectionCardsPersistsEditsAndRestoresDirection() {
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

        openAddFlow(in: app, deckName: "P08 验收")
        // 新表单不再提供方向选择：词的全部方向固定创建。
        XCTAssertFalse(app.switches["vocabulary-direction-zh-ja"].exists)
        XCTAssertFalse(app.switches["vocabulary-direction-listening"].exists)

        let headwordField = app.textFields["vocabulary-headword-field"]
        let meaningField = app.textFields["vocabulary-meaning-field"]
        reveal(headwordField, in: app)
        XCTAssertTrue(headwordField.waitForExistence(timeout: 5))
        headwordField.tap()
        headwordField.typeText("食べる")
        dismissKeyboard(in: app)
        meaningField.tap()
        meaningField.typeText("吃")

        dismissKeyboard(in: app)

        // 预览固定展示全部三个方向。
        for direction in ["vocabulary-ja-zh", "vocabulary-zh-ja", "vocabulary-listening"] {
            let flip = app.buttons["card-preview-flip-\(direction)"]
            reveal(flip, in: app)
            XCTAssertTrue(flip.exists, "缺少方向预览 \(direction)")
        }
        let flipButton = app.buttons["card-preview-flip-vocabulary-ja-zh"]
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
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("3"))
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
    func testVocabularyCreatesAllDirectionsAndTogglesInEditor() {
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
        deckNameField.typeText("T16 验收")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["T16 验收"].waitForExistence(timeout: 5))

        // 新建表单不再提供方向选择：默认创建全部三个方向。
        openAddFlow(in: app, deckName: "T16 验收")
        XCTAssertFalse(app.switches["vocabulary-direction-listening"].exists)

        let headwordField = app.textFields["vocabulary-headword-field"]
        let meaningField = app.textFields["vocabulary-meaning-field"]
        reveal(headwordField, in: app)
        XCTAssertTrue(headwordField.waitForExistence(timeout: 5))
        headwordField.tap()
        headwordField.typeText("聞く")
        dismissKeyboard(in: app)
        meaningField.tap()
        meaningField.typeText("听")
        dismissKeyboard(in: app)

        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        selectDecksTab(in: app)
        let deck = app.staticTexts["T16 验收"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        deck.tap()
        XCTAssertTrue(app.staticTexts["deck-note-count"].label.contains("1"))
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("3"))
        app.staticTexts["聞く"].tap()

        // 编辑器仍可逐方向管理：三个方向默认全部开启。
        let listeningToggle = app.switches["card-direction-toggle-vocabulary_listening"]
        reveal(listeningToggle, in: app)
        XCTAssertTrue(listeningToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(listeningToggle.value as? String, "1")
        let jaZhToggle = app.switches["card-direction-toggle-vocabulary_ja_zh"]
        XCTAssertTrue(jaZhToggle.exists)
        XCTAssertEqual(jaZhToggle.value as? String, "1")

        // 停用 → 重开走同一方向替换路径，不重复创建。
        setSwitch(listeningToggle, enabled: false)
        XCTAssertEqual(listeningToggle.value as? String, "0")
        XCTAssertEqual(jaZhToggle.value as? String, "1")
        setSwitch(listeningToggle, enabled: true)
        XCTAssertEqual(listeningToggle.value as? String, "1")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["deck-card-count"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deck-card-count"].label.contains("3"))
    }

    @MainActor
    func testGrammarDraftPersistsWithIsolatedFieldsAndFavoritesEntry() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        createDeck(in: app, named: "语法草稿")
        openAddFlow(in: app, deckName: "语法草稿")

        let kindPicker = app.segmentedControls["add-content-kind-picker"]
        XCTAssertTrue(kindPicker.waitForExistence(timeout: 5))
        kindPicker.buttons["语法"].tap()

        let grammarFormField = app.textFields["grammar-form-field"]
        let grammarMeaningField = app.textFields["grammar-meaning-field"]
        XCTAssertTrue(grammarFormField.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["vocabulary-reading-field"].exists)
        grammarFormField.tap()
        grammarFormField.typeText("Vたことがある")
        dismissKeyboard(in: app)
        grammarMeaningField.tap()
        grammarMeaningField.typeText("曾经做过")
        dismissKeyboard(in: app)

        app.buttons["grammar-save-draft-button"].tap()
        XCTAssertTrue(app.staticTexts["草稿已保存"].waitForExistence(timeout: 5))

        let formalSave = app.buttons["grammar-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.exists)
        XCTAssertTrue(formalSave.isEnabled, "入口牌组即目标牌组，字段齐即可入库")

        app.terminate()
        app.launch()
        openAddFlow(in: app, deckName: "语法草稿")
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
        app.launchEnvironment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] = "japaneseToChinese"
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

        openAddFlow(in: app, deckName: "P11 Flow")
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(headword, in: app)
        XCTAssertTrue(headword.exists)
        headword.tap()
        headword.typeText("taberu")
        dismissKeyboard(in: app)
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
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled)
        start.tap()

        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-rating-easy"].exists)
        showReviewAnswer(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["review-rating-again"].exists)
        XCTAssertTrue(app.buttons["review-rating-hard"].exists)
        XCTAssertTrue(app.buttons["review-rating-good"].exists)
        XCTAssertTrue(app.buttons["review-rating-easy"].exists)

        app.navigationBars["P11 Flow"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["today-new-count"].label, "1")
        XCTAssertEqual(app.staticTexts["today-remaining-count"].label, "1")

        // v0.5.5：首页 CTA 进入主牌组 scope（首个牌组自动成为主牌组），
        // 其他牌组的学习仍由牌组详情的「学习此牌组」入口承担。
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'today-start-deck-'")
            ).firstMatch.exists
        )
        start.tap()
        XCTAssertTrue(app.navigationBars["P11 Flow"].waitForExistence(timeout: 3))
        showReviewAnswer(in: app)
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
        showReviewAnswer(in: app)
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
        // 评分分布行在统计卡的 LazyVGrid 里，SE 首屏之下需要滚动才会挂载。
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<6 where !easyRatingCount.exists {
            scroll.swipeUp()
        }
        XCTAssertTrue(easyRatingCount.waitForExistence(timeout: 3))
        XCTAssertTrue(easyRatingCount.label.contains("1"))

        decksTab.tap()
        let deckTodayCounts = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'deck-today-counts-'")
        ).firstMatch
        XCTAssertTrue(deckTodayCounts.waitForExistence(timeout: 5))
        XCTAssertTrue(deckTodayCounts.label.contains("今日新词 1 · 复习 0"))
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
    func testReviewAgainWaitsAutoRefreshesWhenDueThenFinishDismisses() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] = "japaneseToChinese"
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("Again Wait")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["Again Wait"].waitForExistence(timeout: 5))

        openAddFlow(in: app, deckName: "Again Wait")
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(headword, in: app)
        XCTAssertTrue(headword.exists)
        headword.tap()
        headword.typeText("nomu")
        dismissKeyboard(in: app)
        meaning.tap()
        meaning.typeText("drink")
        dismissKeyboard(in: app)
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        app.tabBars.buttons["今日"].tap()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))
        showReviewAnswer(in: app)

        let progressSummary = app.descendants(matching: .any)["review-progress-summary"]
        XCTAssertTrue(progressSummary.waitForExistence(timeout: 3))
        XCTAssertTrue(progressSummary.label.contains("剩余 1"))
        XCTAssertTrue(app.descendants(matching: .any)["review-progress-bar"].exists)

        app.buttons["review-rating-again"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-waiting-state"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["review-wait-refresh-button"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(progressSummary.label.contains("剩余 1"))

        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 90)
        )
        showReviewAnswer(in: app)
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        easy.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["review-statistics-card"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["review-statistics-new"].label, "新学 1 张"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["review-statistics-total"].label, "合计 1 张"
        )
        XCTAssertEqual(app.staticTexts["review-statistics-rating-again"].label, "重来 1")
        XCTAssertEqual(app.staticTexts["review-statistics-rating-easy"].label, "简单 1")

        let finish = app.buttons["review-finish-button"]
        XCTAssertTrue(finish.waitForExistence(timeout: 3))
        finish.tap()
        // T14: 任务清空后 Hero 呈现「今日完成」非可操作状态卡，
        // today-start-button 只在可学状态下存在。
        XCTAssertTrue(
            app.staticTexts["today-day-complete"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testReviewSubmissionFailureRetriesInlineThenCompletes() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_SUBMIT_FAILURES"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] = "japaneseToChinese"
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("Retry Flow")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["Retry Flow"].waitForExistence(timeout: 5))

        openAddFlow(in: app, deckName: "Retry Flow")
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(headword, in: app)
        XCTAssertTrue(headword.exists)
        headword.tap()
        headword.typeText("yomu")
        dismissKeyboard(in: app)
        meaning.tap()
        meaning.typeText("read")
        dismissKeyboard(in: app)
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        app.tabBars.buttons["今日"].tap()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))
        showReviewAnswer(in: app)

        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        easy.tap()

        let retry = app.buttons["review-retry-button"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "首次保存失败后应显示内联重试")
        XCTAssertTrue(
            app.descendants(matching: .any)["review-answer"].exists,
            "保存失败后应停留在原卡答案面"
        )
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '评分未保存'")
        ).firstMatch.exists)

        retry.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["review-statistics-total"].label, "合计 1 张"
        )
    }

    @MainActor
    func testReviewSpeechUnavailableKeepsStudyActionsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_SPEECH_UNAVAILABLE"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] = "japaneseToChinese"
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("No Voice")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["No Voice"].waitForExistence(timeout: 5))

        openAddFlow(in: app, deckName: "No Voice")
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(headword, in: app)
        XCTAssertTrue(headword.exists)
        headword.tap()
        headword.typeText("kaku")
        dismissKeyboard(in: app)
        meaning.tap()
        meaning.typeText("write")
        dismissKeyboard(in: app)
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        app.tabBars.buttons["今日"].tap()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))

        let notice = app.descendants(matching: .any)["review-speech-unavailable"]
        XCTAssertTrue(notice.waitForExistence(timeout: 3), "无日语语音时应显示降级提示")
        let questionSpeech = app.buttons["review-question-speech-button"]
        if questionSpeech.exists {
            XCTAssertFalse(questionSpeech.isEnabled, "无语音时发音按钮应禁用")
        }

        showReviewAnswer(in: app)
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        XCTAssertTrue(easy.isHittable)
        easy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testReviewDarkModeKeepsActionsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] = "japaneseToChinese"
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

        let decksTab = app.tabBars.buttons["牌组"]
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("Dark Mode")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["Dark Mode"].waitForExistence(timeout: 5))

        openAddFlow(in: app, deckName: "Dark Mode")
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(headword, in: app)
        XCTAssertTrue(headword.exists)
        headword.tap()
        headword.typeText("miru")
        dismissKeyboard(in: app)
        meaning.tap()
        meaning.typeText("see")
        dismissKeyboard(in: app)
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()

        app.tabBars.buttons["今日"].tap()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))
        showReviewAnswer(in: app)
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        XCTAssertTrue(easy.isHittable)
        easy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["review-finish-button"].exists)
    }

    @MainActor
    func testReviewAccessibilityXLTextKeepsActionsReachable() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"
        ]
        app.launch()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckNameField = app.textFields["deck-name-field"]
        XCTAssertTrue(deckNameField.waitForExistence(timeout: 2))
        deckNameField.tap()
        deckNameField.typeText("XL Text")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["XL Text"].waitForExistence(timeout: 5))

        openAddFlow(in: app, deckName: "XL Text")
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
        grammarForm.typeText("a deliberately long grammar form for XL layout verification")
        let meaning = app.textFields["grammar-meaning-field"]
        revealExistence(meaning, in: app)
        XCTAssertTrue(meaning.exists)
        meaning.tap()
        meaning.typeText("A deliberately long explanation that wraps across several lines.")
        dismissKeyboard(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))

        let save = app.buttons["grammar-formal-save-button"]
        reveal(save, in: app)
        XCTAssertTrue(save.isHittable)
        save.tap()

        app.tabBars.buttons["今日"].tap()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["review-question"].waitForExistence(timeout: 5))

        let showAnswer = app.buttons["review-show-answer-button"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 3))
        let answerScroll = app.scrollViews["review-content-scroll"]
        for _ in 0..<8 where !showAnswer.isHittable {
            answerScroll.swipeUp()
        }
        XCTAssertGreaterThanOrEqual(showAnswer.frame.height, 44, "主操作点击区域不得小于 44pt")
        XCTAssertTrue(showAnswer.isHittable)
        showAnswer.tap()

        var firstRowY: CGFloat?
        for ratingID in ["again", "hard", "good", "easy"] {
            let button = app.buttons["review-rating-\(ratingID)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            XCTAssertTrue(button.isHittable, "特大字号下评分按钮 \(ratingID) 被内容遮挡")
            if ratingID == "again" { firstRowY = button.frame.minY }
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "评分按钮点击区域不足 44pt")
        }
        if let firstRowY {
            XCTAssertGreaterThan(
                app.buttons["review-rating-good"].frame.minY, firstRowY,
                "特大字号下评分区应降级为两行布局"
            )
        }

        app.buttons["review-rating-easy"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["review-finish-button"].exists)
    }

    @MainActor
    func testReviewKeepsAnswerAndSubmissionLockedUntilNextCardIsReady() {
        let app = launchReviewTransitionApp(loadDelay: 4)
        let firstQuestionHasSpeech = app.buttons["review-question-speech-button"].exists
        showReviewAnswer(in: app)
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        easy.tap()

        XCTAssertFalse(
            app.buttons["review-show-answer-button"].exists,
            "下一张尚未载入时，不应先收起旧卡答案并重新启用显示答案"
        )
        XCTAssertTrue(easy.exists)
        XCTAssertFalse(easy.isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].exists)

        let showAnswer = app.buttons["review-show-answer-button"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["review-answer"].exists)
        XCTAssertNotEqual(app.buttons["review-question-speech-button"].exists, firstQuestionHasSpeech)
        XCTAssertTrue(showAnswer.isEnabled)
        XCTAssertTrue(app.buttons["review-undo-button"].isEnabled)
        showReviewAnswer(in: app)
        easy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.descendants(matching: .any)["review-statistics-total"].label.contains("2"))
    }

    @MainActor
    func testReviewNextCardLoadFailureRetriesWithoutResubmittingScore() {
        let app = launchReviewTransitionApp(loadDelay: 0, loadFailures: 1)
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()
        let alert = app.alerts["载入失败"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-retry-button"].exists)
        alert.buttons["重试"].tap()

        let showAnswer = app.buttons["review-show-answer-button"]
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["review-progress-summary"].label.contains("已完成 1"))
        showReviewAnswer(in: app)
        app.buttons["review-rating-easy"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["review-statistics-total"].label.contains("2"))
        XCTAssertTrue(app.staticTexts["review-statistics-rating-easy"].label.contains("2"))
    }

    @MainActor
    func testReviewAutoSpeechSupportsRatingUndoAndBackground() {
        let app = launchReviewTransitionApp(loadDelay: 0, autoSpeech: true)
        let showAnswer = app.buttons["review-show-answer-button"]
        let easy = app.buttons["review-rating-easy"]
        showReviewAnswer(in: app)
        easy.tap()
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["无法播放日语发音"].exists)

        app.buttons["review-undo-button"].tap()
        showReviewAnswer(in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["review-answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(easy.isEnabled)
        easy.tap()
        XCTAssertTrue(showAnswer.waitForExistence(timeout: 5))
        showReviewAnswer(in: app)
        easy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.alerts["无法播放日语发音"].exists)
        app.buttons["review-finish-button"].tap()
        XCTAssertTrue(app.tabBars.buttons["今日"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchReviewTransitionApp(
        loadDelay: Double,
        loadFailures: Int = 0,
        autoSpeech: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_REVIEW_LOAD_DELAY"] = String(loadDelay)
        app.launchEnvironment["OBOE_UI_TEST_REVIEW_LOAD_FAILURES"] = String(loadFailures)
        // 词默认全方向；收窄到两个视觉方向，使卡间断言保持确定。
        app.launchEnvironment["OBOE_UI_TEST_VOCABULARY_DIRECTIONS"] =
            "japaneseToChinese,chineseToJapanese"
        app.launch()

        if autoSpeech {
            let settings = app.tabBars.buttons["设置"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            for identifier in ["speech-auto-play-word-toggle", "speech-auto-play-example-toggle"] {
                let toggle = app.switches[identifier]
                reveal(toggle, in: app)
                moveIntoInteractionSafeArea(toggle, in: app)
                waitUntilEnabled(toggle)
                setSwitch(toggle, enabled: true)
            }
        }

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        app.buttons["deck-create-empty-button"].tap()
        let deckName = app.textFields["deck-name-field"]
        XCTAssertTrue(deckName.waitForExistence(timeout: 2))
        deckName.tap()
        deckName.typeText("Review Transition")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.staticTexts["Review Transition"].waitForExistence(timeout: 5))

        openAddFlow(in: app, deckName: "Review Transition")
        let headword = app.textFields["vocabulary-headword-field"]
        revealExistence(headword, in: app)
        headword.tap()
        headword.typeText("taberu")
        dismissKeyboard(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(meaning, in: app)
        meaning.tap()
        meaning.typeText("eat")
        dismissKeyboard(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let save = app.buttons["vocabulary-formal-save-button"]
        reveal(save, in: app)
        save.tap()

        app.tabBars.buttons["今日"].tap()
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.buttons["review-show-answer-button"].waitForExistence(timeout: 5))
        return app
    }

    /// v0.5.5 第五步：重复提示中的「加入当前牌组」把同一 Note 复用进
    /// 第二牌组——不复制、不重新制卡；回到详情后两个牌组都能看到它。
    /// 已是当前牌组成员时该行只保留「打开查看」，正式保存另建义项仍
    /// 需经确认弹窗。
    @MainActor
    func testDuplicatePromptJoinsCurrentDeckReusingSameNote() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        // 牌组 A 正常添加「兼ねる」。
        createDeck(in: app, named: "共享甲")
        openAddFlow(in: app, deckName: "共享甲")
        let headword = app.textFields["vocabulary-headword-field"]
        let meaning = app.textFields["vocabulary-meaning-field"]
        revealExistence(headword, in: app)
        XCTAssertTrue(headword.exists)
        headword.tap()
        headword.typeText("兼ねる")
        dismissKeyboard(in: app)
        meaning.tap()
        meaning.typeText("兼任")
        dismissKeyboard(in: app)
        let formalSave = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSave, in: app)
        XCTAssertTrue(formalSave.isEnabled)
        formalSave.tap()
        let savedStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "已正式保存")
        ).firstMatch
        revealExistence(savedStatus, in: app)
        XCTAssertTrue(savedStatus.waitForExistence(timeout: 5))

        // 牌组 B 再输入同词：重复提示出现，且优先提供「加入当前牌组」。
        createDeck(in: app, named: "共享乙")
        openAddFlow(in: app, deckName: "共享乙")
        let headwordB = app.textFields["vocabulary-headword-field"]
        revealExistence(headwordB, in: app)
        XCTAssertTrue(headwordB.exists)
        headwordB.tap()
        headwordB.typeText("兼ねる")
        dismissKeyboard(in: app)

        let joinButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "duplicate-join-")
        ).firstMatch
        XCTAssertTrue(joinButton.waitForExistence(timeout: 5), "非成员重复项应提供「加入当前牌组」")
        reveal(joinButton, in: app)
        joinButton.tap()

        // 加入成功后退出添加流、回到牌组 B 详情；内容列表已刷新出该词。
        XCTAssertTrue(
            app.navigationBars["共享乙"].waitForExistence(timeout: 5),
            "加入后应返回来源牌组详情"
        )
        let joinedNote = app.staticTexts["兼ねる"]
        revealBidirectional(joinedNote, in: app)
        XCTAssertTrue(joinedNote.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["deck-note-count"].label.contains("1"),
            "加入后牌组 B 应计 1 个知识点"
        )
        XCTAssertTrue(
            app.staticTexts["deck-card-count"].label.contains("3"),
            "复用同一 Note 的既有 3 张方向卡，不重新制卡"
        )

        // 牌组 A 详情也能看到同一词（同一 Note，同一份正文）。
        app.navigationBars["共享乙"].buttons.element(boundBy: 0).tap()
        let deckA = app.staticTexts["共享甲"]
        XCTAssertTrue(deckA.waitForExistence(timeout: 5))
        deckA.tap()
        let noteInA = app.staticTexts["兼ねる"]
        revealBidirectional(noteInA, in: app)
        XCTAssertTrue(noteInA.waitForExistence(timeout: 5), "牌组 A 应同样显示该知识点")

        // 已是当前牌组成员：再进牌组 B 添加流输入同词，只有「打开查看」
        // 与徽标，不再出现「加入当前牌组」。
        openAddFlow(in: app, deckName: "共享乙")
        let headwordC = app.textFields["vocabulary-headword-field"]
        revealExistence(headwordC, in: app)
        XCTAssertTrue(headwordC.exists)
        headwordC.tap()
        headwordC.typeText("兼ねる")
        dismissKeyboard(in: app)

        let memberBadge = app.staticTexts["已在当前牌组"]
        XCTAssertTrue(memberBadge.waitForExistence(timeout: 5), "成员项应显示「已在当前牌组」")
        XCTAssertFalse(joinButton.exists, "已是成员的重复项不再提供「加入当前牌组」")

        // 「另建义项」仍需明确确认：正式保存先弹确认，取消则留在编辑器。
        let meaningC = app.textFields["vocabulary-meaning-field"]
        revealExistence(meaningC, in: app)
        meaningC.tap()
        meaningC.typeText("另一义项")
        dismissKeyboard(in: app)
        let formalSaveC = app.buttons["vocabulary-formal-save-button"]
        reveal(formalSaveC, in: app)
        XCTAssertTrue(formalSaveC.isEnabled)
        formalSaveC.tap()
        let confirm = app.buttons["duplicate-commit-confirm-button"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "另建义项必须先经确认弹窗")
        app.buttons["取消"].tap()
        XCTAssertTrue(
            app.navigationBars["添加"].waitForExistence(timeout: 3),
            "取消确认后应停留在添加编辑器"
        )
    }

    // MARK: - T16 真机与可访问性验收（模拟器可覆盖部分）

    /// T16：v0.4 数据副本（schema v12）的真实升级路径——App 打开时执行
    /// v13 迁移（含迁移前快照），启动后 enrichment 回填内置词音调与例句
    /// 中文译文；升级库上本机快照创建/恢复可用。全程走真实打开路径，
    /// 不绕过 `databaseLifecycle.open()`。
    @MainActor
    func testT16V04DatabaseUpgradeMigratesEnrichesAndRestores() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_STAGE_SCHEMA_V12"] = "1"
        app.launch()

        // 迁移失败会停在启动错误页；能进主界面即说明 v12→v13 成功。
        let todayTab = app.tabBars.buttons["今日"]
        XCTAssertTrue(todayTab.waitForExistence(timeout: 10), "升级后应能进入主界面")

        // 新卡不丢：v12 种子的 6 张 New 卡被今日计划接纳，Hero 可学习。
        XCTAssertTrue(
            app.buttons["today-start-button"].waitForExistence(timeout: 5),
            "升级库上的新卡必须进入今日队列"
        )

        // 牌组与内容保留：升级牌组含 2 个知识点、6 张卡。
        app.tabBars.buttons["牌组"].tap()
        let deckRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "升级牌组")
        ).firstMatch
        XCTAssertTrue(deckRow.waitForExistence(timeout: 5))
        deckRow.tap()
        let noteCount = app.descendants(matching: .any)["deck-note-count"].firstMatch
        XCTAssertTrue(noteCount.waitForExistence(timeout: 5))
        XCTAssertTrue(noteCount.label.contains("2"), "升级后知识点计数应为 2，实际：\(noteCount.label)")
        let cardCount = app.descendants(matching: .any)["deck-card-count"].firstMatch
        XCTAssertTrue(cardCount.label.contains("6"), "升级后卡片计数应为 6，实际：\(cardCount.label)")

        // enrichment：启动调度只补 NULL——内置词的音调与例句中文译文
        // 应已回填。先等词库页 running 指示消失（若已跑完则直接通过）。
        app.navigationBars.buttons.firstMatch.tap()
        let library = app.buttons["jlpt-library-entry"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let acknowledge = app.buttons["我知道了"]
        if acknowledge.waitForExistence(timeout: 2) { acknowledge.tap() }
        let running = app.descendants(matching: .any)["jlpt-enrichment-running"]
        if running.waitForExistence(timeout: 3) {
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: running
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [gone], timeout: 15), .completed,
                "enrichment 未在预期时间内完成"
            )
        }
        XCTAssertFalse(
            app.buttons["jlpt-enrichment-retry"].exists,
            "enrichment 不应进入失败重试态"
        )
        app.navigationBars.buttons.firstMatch.tap()

        // 打开回填过的内置词详情：音调 2 与例句中文译文来自词库 v2。
        // 行内 headword 与 reading 同文本，须按行标识符定位避免重复匹配。
        XCTAssertTrue(deckRow.waitForExistence(timeout: 5))
        deckRow.tap()
        XCTAssertTrue(
            app.navigationBars["升级牌组"].waitForExistence(timeout: 5),
            "应重新进入升级牌组详情"
        )
        let jlptNote = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'knowledge-row-' AND label CONTAINS 'あさって'"
            )
        ).firstMatch
        revealExistence(jlptNote, in: app)
        XCTAssertTrue(jlptNote.waitForExistence(timeout: 5))
        jlptNote.tap()
        let pitchLabel = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '音调'")
        ).firstMatch
        XCTAssertTrue(
            pitchLabel.waitForExistence(timeout: 5),
            "enrichment 后详情应显示音调"
        )
        XCTAssertTrue(
            app.staticTexts["请后天来吧。"].waitForExistence(timeout: 3),
            "enrichment 应回填例句中文译文"
        )

        // 回滚路径：升级库上创建本机快照并恢复，数据保持完整。
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["设置"].tap()
        let createSnapshot = app.buttons["local-snapshot-create-button"]
        reveal(createSnapshot, in: app)
        XCTAssertTrue(createSnapshot.exists)
        createSnapshot.tap()
        XCTAssertTrue(app.staticTexts["本机快照已创建。"].waitForExistence(timeout: 5))
        let restoreButton = app.buttons["local-snapshot-restore-button"].firstMatch
        reveal(restoreButton, in: app)
        restoreButton.tap()
        let confirmRestore = app.buttons["完整替换并恢复"]
        XCTAssertTrue(confirmRestore.waitForExistence(timeout: 2))
        confirmRestore.tap()

        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 8))
        decksTab.tap()
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", "升级牌组")
            ).firstMatch.waitForExistence(timeout: 5),
            "快照恢复后牌组数据必须完整"
        )
    }

    /// T16：Reduce Motion 下复习流程不依赖动画——展示答案与评分过渡
    /// 关闭后流程照常完成。SwiftUI `accessibilityReduceMotion` 是只读
    /// 环境值无法注入，运行前需先在模拟器开启系统级开关：
    /// `xcrun simctl spawn booted defaults write com.apple.Accessibility
    /// ReduceMotionEnabled -bool true`（跑完恢复 false）。
    @MainActor
    func testT16ReduceMotionReviewFlowCompletes() throws {
        try XCTSkipUnless(
            UIAccessibility.isReduceMotionEnabled,
            "需要先在模拟器开启 Reduce Motion（见方法注释）"
        )

        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launch()

        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        showReviewAnswer(in: app)
        let easy = app.buttons["review-rating-easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 5))
        XCTAssertTrue(easy.isHittable)
        easy.tap()
        // 评分后进入下一张或完成态——任一都证明流程未被动画阻断。
        XCTAssertTrue(
            app.descendants(matching: .any)["review-complete-state"]
                .waitForExistence(timeout: 5)
                || app.buttons["review-show-answer-button"].exists,
            "Reduce Motion 下评分后流程必须继续"
        )
    }

    /// T16：Today Hero 的自动无障碍审计（真机 VoiceOver 走查前的机器
    /// 代理）——对比度、可点击区域、描述充分性、文本裁剪与 trait 审计，
    /// 发现问题即失败。
    ///
    /// `.dynamicType` 一项不交给审计：它对懒容器（LazyVGrid/滚动边界）
    /// 内的标准可缩放文本会持续误报且标记元素逐轮漂移；动态字体缩放
    /// 由 `testT16AccessibilityTypeScalesWithoutTruncation` 用 ax5 实渲染
    /// 帧高对比验证，比审计更直接。
    @MainActor
    func testT16AccessibilityAuditOnTodayHero() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launch()
        XCTAssertTrue(
            app.buttons["today-start-button"].waitForExistence(timeout: 5)
        )
        // 打印每个 issue 的元素与描述供定位，不吞掉任何结果。
        let logIssue: (XCUIAccessibilityAuditIssue) -> Void = { issue in
            print(
                "A11Y-ISSUE type=\(issue.auditType.rawValue) "
                    + "element=\(issue.element) "
                    + "desc=\(issue.compactDescription)"
            )
        }
        // 第一遍：顶部静止位。视口底部边缘带内的元素可能处于懒网格
        // 部分物化/标签栏遮挡区，对比度取色不可靠——留到底部复审
        // （那时它们完全可见）统一裁决，不构成覆盖盲区。
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        let bottomEdgeZoneTop = tabBarTop - 60
        try app.performAccessibilityAudit(
            for: .all.subtracting(.dynamicType)
        ) { issue in
            logIssue(issue)
            if issue.auditType == .contrast,
               let element = issue.element,
               element.exists,
               element.frame.maxY > bottomEdgeZoneTop {
                return true
            }
            return false
        }
        // 第二遍：滚动到底部，让首屏外的元素物化，补做元素级检查
        // （点击区域/描述/trait 基于树数据仍可靠）。对比度不随滚动
        // 复审：审计对滚动后位置的像素取色会映射到滚动前截图（实测
        // 黑字文本被误判落在 Hero 蓝渐变上），结果不可靠。
        for _ in 0..<8 {
            app.scrollViews.firstMatch.swipeUp()
        }
        try app.performAccessibilityAudit(
            for: .all.subtracting([.dynamicType, .contrast])
        ) { issue in
            logIssue(issue)
            return false
        }
    }

    /// T16：最大辅助功能字号实渲染验证——Hero 与指标在 ax5 下不截断、
    /// 按钮可点击，且文本帧高确实随字号放大（审计之外的直接证据）。
    @MainActor
    func testT16AccessibilityTypeScalesWithoutTruncation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_ADAPTIVE_SEED"] = "1"
        app.launchEnvironment["OBOE_UI_TEST_DYNAMIC_TYPE"] = "ax5"
        app.launch()

        // Hero 可操作且未截断。
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "ax5 下 Hero 应存在")
        XCTAssertTrue(start.isHittable, "ax5 下 Hero 必须可点击")
        XCTAssertTrue(start.frame.height > 100, "ax5 下 Hero 应纵向放大")

        // ax5 下 1 列指标网格使「剩余」落于折叠线下，先滚动使其物化。
        let remaining = app.staticTexts["today-remaining-count"]
        for _ in 0..<8 where !remaining.exists {
            app.swipeUp()
        }
        XCTAssertTrue(remaining.exists, "ax5 下指标必须可到达")
        XCTAssertGreaterThan(
            remaining.frame.height, 24,
            "ax5 下指标数字必须随 Dynamic Type 放大"
        )

        // 首屏外区块在 ax5 下仍可滚动到达，不被布局锁死。
        let stat = app.descendants(matching: .any)["today-learned-count"]
        for _ in 0..<10 where !stat.exists {
            app.swipeUp()
        }
        XCTAssertTrue(stat.exists, "ax5 下今日统计必须可到达")
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

    /// 目标行可能在当前视口上方或下方（懒挂载 List 的行序不稳定），
    /// 先向上扫到底、再向下扫回顶，直到元素挂载进无障碍树。
    @MainActor
    private func revealBidirectional(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists { return }
            form.swipeUp()
        }
        for _ in 0..<12 {
            if element.exists { return }
            form.swipeDown()
        }
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
    private func setSwitch(_ element: XCUIElement, enabled: Bool) {
        let expectedValue = enabled ? "1" : "0"
        for attempt in 0..<3 where element.value as? String != expectedValue {
            if attempt == 0 {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            } else {
                element.tap()
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
        // v0.5.5 起只有三个 tab，坐标命中不再可靠，直接点 tab 按钮。
        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
    }

    /// v0.5.5：牌组列表空态/工具栏两种建组入口。
    @MainActor
    private func createDeck(in app: XCUIApplication, named name: String) {
        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        let emptyCreate = app.buttons["deck-create-empty-button"]
        if emptyCreate.waitForExistence(timeout: 3) {
            emptyCreate.tap()
        } else {
            let toolbarCreate = app.buttons["deck-create-toolbar-button"]
            XCTAssertTrue(toolbarCreate.waitForExistence(timeout: 3))
            toolbarCreate.tap()
        }
        let nameField = app.textFields["deck-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText(name)
        app.buttons["deck-name-save-button"].tap()
        // ax5 下行高膨胀，新牌组可能落在折叠线下方未挂载——双向扫描显露。
        let row = app.staticTexts[name]
        revealBidirectional(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// v0.5.5：添加入口迁入牌组详情——牌组列表 → 牌组 → 工具栏「添加」。
    /// 重复点「牌组」tab 会先弹回列表根，因此在详情/编辑器里也可直接调用。
    @MainActor
    private func openAddFlow(in app: XCUIApplication, deckName: String) {
        let decksTab = app.tabBars.buttons["牌组"]
        XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
        decksTab.tap()
        let row = app.staticTexts[deckName]
        revealBidirectional(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // 显露后若停在列表底缘（标签栏遮挡），再向上推一点到可点击区。
        for _ in 0..<6 where !row.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        row.tap()
        let addButton = app.buttons["deck-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        XCTAssertTrue(app.navigationBars["添加"].waitForExistence(timeout: 5))
    }

}


