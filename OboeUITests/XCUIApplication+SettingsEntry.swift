import XCTest

/// v0.5.8：compact 壳层的设置入口从底部 Tab 收进今日页右上角齿轮，
/// 以 sheet 呈现。所有需要进入设置页的用例统一走这里——入口形态
/// 再变时只改这一处。
extension XCUIApplication {

    /// 今日页齿轮 → 设置 sheet。若当前停在其它 Tab 先回今日页。
    @MainActor
    func openSettingsFromTodayGear(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let todayTab = tabBars.buttons["今日"]
        if todayTab.exists {
            todayTab.tap()
        }
        let gear = buttons["today-settings-button"].firstMatch
        XCTAssertTrue(
            gear.waitForExistence(timeout: 5),
            "今日页缺少设置齿轮入口",
            file: file,
            line: line
        )
        gear.tap()
        XCTAssertTrue(
            navigationBars["设置"].waitForExistence(timeout: 5),
            "设置 sheet 未打开",
            file: file,
            line: line
        )
    }

    /// 关闭设置 sheet（右上角「完成」）。
    @MainActor
    func dismissSettingsSheet(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let done = buttons["settings-done-button"].firstMatch
        XCTAssertTrue(
            done.waitForExistence(timeout: 5),
            "设置 sheet 缺少完成按钮",
            file: file,
            line: line
        )
        done.tap()
        _ = navigationBars["设置"].waitForNonExistence(timeout: 3)
    }

    /// 今日页导航栏：标题会并入连续天数（「今日（已连续 N 天）」），
    /// 一律按 identifier 前缀匹配。
    var todayNavigationBar: XCUIElement {
        navigationBars.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "今日")
        ).firstMatch
    }
}
