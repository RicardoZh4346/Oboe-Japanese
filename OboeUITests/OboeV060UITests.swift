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

    /// compact：底部 tab → 牌组列表首行；regular：sidebar deck 行
    /// （identifier 前缀匹配任意已挂载行，点击可命中分支）。
    @MainActor
    private func openFirstDeckDetail(in app: XCUIApplication) -> Bool {
        guard app.waitForShellReady() else { return false }
        if app.isRegularShell {
            // 注意排除 sidebar-deck-create-button（同前缀的工具栏按钮）。
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier != %@",
                    "sidebar-deck-", "sidebar-deck-create-button"
                )
            )
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                for index in 0..<rows.count {
                    let row = rows.element(boundBy: index)
                    if row.exists, row.isHittable {
                        row.tap()
                        return true
                    }
                }
                usleep(100_000)
            }
            return false
        }
        app.tabBars.buttons["牌组"].tap()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "deck-row-")
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

        // setup sheet：preset/deck/预览/开始按钮齐备——预览/开始在表单
        // 末段，iPad sheet 折线以下懒挂载，先确认 sheet 再滚动显露。
        XCTAssertTrue(
            app.navigationBars["专项学习"].waitForExistence(timeout: 5),
            "专项 setup sheet 未打开"
        )
        // LabeledContent 承载该 identifier——不同壳层下暴露的元素
        // 类型不同（compact=StaticText，regular sheet=Cell），按 any 查。
        let preview = app.descendants(matching: .any)["custom-study-preview-count"]
        app.revealElement(preview, requireHittable: false, passes: 8)
        XCTAssertTrue(
            preview.waitForExistence(timeout: 3),
            "专项 setup 未出现预览计数"
        )
        let start = app.buttons["custom-study-start-button"]
        app.revealElement(start, passes: 6)
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

        // 全局搜索入口：compact=牌组 tab 工具栏「搜索」按钮；
        // regular=sidebar-search 行直达搜索 section（无工具栏按钮）。
        if app.isRegularShell {
            app.tapSidebarRow("sidebar-search")
        } else {
            app.tabBars.buttons["牌组"].tap()
            let searchEntry = app.buttons["global-search-button"]
            if searchEntry.waitForExistence(timeout: 5) {
                searchEntry.tap()
            }
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
