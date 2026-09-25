import Foundation
import XCTest

/// v0.6.0 S13 UI matrix 补测：专项学习入口/预览/会话启动、
/// 词典查词→制卡预填的端到端（真词典产物随 bundle）。
final class OboeV060UITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        // 种子：一个主牌组 + 两张可学卡（专项 preview 计数=2）。
        app.launchEnvironment["OBOE_UI_TEST_TODAY_SEED"] = "ready"
        app.launch()
        return app
    }

    /// compact：底部 tab → 牌组列表首行；regular：sidebar deck 行。
    private func openFirstDeckDetail(in app: XCUIApplication) -> Bool {
        if app.tabBars.firstMatch.waitForExistence(timeout: 5) {
            app.tabBars.buttons["牌组"].tap()
            let row = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "deck-row-")
            ).firstMatch
            guard row.waitForExistence(timeout: 5) else { return false }
            row.tap()
            return true
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        let row = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "sidebar-deck-")
        ).firstMatch
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap()
        return true
    }

    // MARK: - S09 专项学习

    @MainActor
    func testCustomStudySetupAndStartFlow() {
        let app = launchSeededApp()
        guard openFirstDeckDetail(in: app) else {
            XCTFail("未能打开牌组详情")
            return
        }

        let entry = app.buttons["deck-custom-study-button"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "详情页缺少专项学习入口")
        entry.tap()

        // setup sheet：preset/deck/预览/开始按钮齐备——start 在表单
        // 末段，需要先向上滚动让它进入可达性树。
        let preview = app.staticTexts["custom-study-preview-count"]
        XCTAssertTrue(
            preview.waitForExistence(timeout: 8),
            "专项 setup 未出现预览计数"
        )
        app.swipeUp()
        let start = app.buttons["custom-study-start-button"]
        XCTAssertTrue(
            start.waitForExistence(timeout: 3),
            "专项 setup 缺少开始按钮"
        )
        XCTAssertTrue(start.isEnabled, "候选>0 时开始按钮应可用")
        // 默认不调度（practiceOnly）：额度警示不显示。
        XCTAssertFalse(
            app.switches["custom-study-schedule-toggle"].value as? String == "1"
        )
        start.tap()

        // Review 同一 UI：专项进度头 + 问题面按钮。
        XCTAssertTrue(
            app.staticTexts["review-custom-progress"].waitForExistence(timeout: 8)
                || app.buttons["review-show-answer-button"].waitForExistence(timeout: 8),
            "专项会话未进入复习界面"
        )
    }

    // MARK: - S07 词典查词 → 制卡预填

    @MainActor
    func testDictionaryLookupOpensPrefilledEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launch()

        // 全局搜索入口（Decks 工具栏「搜索」）。
        if app.tabBars.firstMatch.waitForExistence(timeout: 5) {
            app.tabBars.buttons["牌组"].tap()
        } else {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.staticTexts["sidebar-search"].tap()
        }
        let searchEntry = app.buttons["global-search-button"]
        if searchEntry.waitForExistence(timeout: 5) {
            searchEntry.tap()
        }

        // 切到词典 scope 并检索——Picker 渲染为 popup button/segmented
        // 之一，按可达性类型并集查询。
        let scopePicker = app.popUpButtons["global-search-scope-picker"]
            .exists ? app.popUpButtons["global-search-scope-picker"]
            : app.segmentedControls["global-search-scope-picker"]
        if scopePicker.waitForExistence(timeout: 5) {
            scopePicker.tap()
            let dictOption = app.buttons["词典"]
            if dictOption.waitForExistence(timeout: 3) { dictOption.tap() }
        }
        // .searchable 的 SearchField 位于导航栏、不带 identifier
        // （identifier 落在了内容空态上）——按类型取首个搜索框。
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 6) else {
            XCTFail("词典搜索框未出现")
            return
        }
        field.tap()
        field.typeText("食べる")

        let row = app.buttons["dictionary-result-row"].firstMatch
        guard row.waitForExistence(timeout: 8) else {
            XCTFail("词典未返回 食べる 结果")
            return
        }
        row.tap()

        let create = app.buttons["dictionary-create-card"]
        XCTAssertTrue(
            create.waitForExistence(timeout: 5),
            "词典详情缺少「制作卡片」入口"
        )
        create.tap()

        // 预填编辑器出现（kind picker 或正式保存按钮任一就绪即视为
        // 编辑器装载完成；headword 预填由单测覆盖）。
        XCTAssertTrue(
            app.buttons["vocabulary-dictionary-lookup-button"].waitForExistence(timeout: 8)
                || app.otherElements["add-content-kind-picker"].waitForExistence(timeout: 8)
                || app.buttons.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "add-content-")
                ).firstMatch.waitForExistence(timeout: 8),
            "词典制卡未打开内容编辑器"
        )
    }
}
