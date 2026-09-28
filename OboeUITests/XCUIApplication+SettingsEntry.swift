import XCTest

/// 设置入口统一封装——入口形态随壳层不同：
/// - compact：今日页齿轮 → 设置 sheet（v0.5.8）；
/// - regular：sidebar「设置」行 → 三栏（分类列 + detail 列）。
/// 所有需要进入设置页的用例统一走这里。
extension XCUIApplication {

    /// 进入设置区。compact=今日页齿轮开 sheet；regular=点
    /// sidebar-settings（若正停在今日页也可走齿轮——两条路径
    /// 都落到同一个设置 section，这里统一走 sidebar，与当前
    /// section 无关）。
    @MainActor
    func openSettingsFromTodayGear(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isRegularShell {
            tapSidebarRow("sidebar-settings", file: file, line: line)
            XCTAssertTrue(
                collectionViews["settings-category-list"]
                    .waitForExistence(timeout: 5),
                "设置分类列未出现",
                file: file,
                line: line
            )
            return
        }
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

    /// 离开设置区。compact=点「完成」关 sheet；regular 无
    /// sheet——设置是三栏 section，直接返回，由调用方经
    /// `selectPrimarySection` 切走。
    @MainActor
    func dismissSettingsSheet(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isRegularShell {
            return
        }
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
