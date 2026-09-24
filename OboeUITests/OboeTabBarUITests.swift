import Foundation
import XCTest

/// v0.5.5 Step 6 + Step 7 验收：
/// - Step 6：三个一级页 push 出的二级页统一隐藏底部 Tab Bar，
///   返回一级页后恢复；更深层页面继承隐藏状态；快速切换 Tab 与
///   sheet 覆盖均不破坏该行为。
/// - Step 7：今日首页常规字号为固定首屏布局（无纵向滚动），
///   圆形 CTA + 紧凑任务文案 + 两枚等宽入口磁贴 + 胶囊提醒，
///   四种种子态与辅助字号备用布局均可渲染、可点击。
final class OboeTabBarUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 工具

    @MainActor
    private func launchApp(
        seed: String? = nil,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        if let seed {
            app.launchEnvironment["OBOE_UI_TEST_TODAY_SEED"] = seed
        }
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    /// `.toolbar(.hidden, for: .tabBar)` 会整体移除 TabBar 视图；
    /// 隐藏随 push 转场异步发生，先等它消失再断言。
    @MainActor
    private func assertTabBarHidden(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bar = app.tabBars.firstMatch
        if bar.exists {
            XCTAssertTrue(
                bar.waitForNonExistence(timeout: 3),
                "二级页不应显示底部 Tab Bar",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(
            app.tabBars.buttons["今日"].exists,
            "二级页不应保留任何 Tab 按钮",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertTabBarVisible(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.tabBars.buttons["今日"].waitForExistence(timeout: 3),
            "返回一级页后 Tab Bar 必须恢复",
            file: file,
            line: line
        )
    }

    /// push 页左上角返回按钮。
    @MainActor
    private func popToPrevious(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
    }

    // MARK: - Step 6：一级页 → 二级页隐藏，返回恢复

    /// 今日 → 复习：push 后隐藏，返回后恢复。
    /// v0.5.8：模拟器上合成的边缘右滑不再可靠触发交互式 pop
    /// （统计页同样不触发——环境限制而非页面问题），改用返回按钮。
    @MainActor
    func testTodayReviewRouteHidesTabBarUntilBack() {
        let app = launchApp(seed: "ready")
        assertTabBarVisible(app)
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["review-question"]
                .waitForExistence(timeout: 5)
        )
        assertTabBarHidden(app)

        popToPrevious(in: app)
        XCTAssertTrue(
            app.todayNavigationBar.waitForExistence(timeout: 5),
            "返回后今日页导航栏未出现"
        )
        assertTabBarVisible(app)
    }

    /// 今日 → 每日统计。
    @MainActor
    func testTodayStatisticsRouteHidesTabBarUntilBack() {
        let app = launchApp(seed: "complete")
        assertTabBarVisible(app)
        let entry = app.descendants(matching: .any)["today-statistics-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(app.navigationBars["每日统计"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        popToPrevious(in: app)
        XCTAssertTrue(app.todayNavigationBar.waitForExistence(timeout: 5))
        assertTabBarVisible(app)
    }

    /// 今日 → 收集箱；中途打开录入 sheet 不影响隐藏状态。
    @MainActor
    func testTodayInboxRouteHidesTabBarAndSheetStillWorks() {
        let app = launchApp(seed: "ready")
        let entry = app.descendants(matching: .any)["today-inbox-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.navigationBars["收集箱"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        // sheet 覆盖整窗（含 Tab Bar），关闭后回到二级页仍保持隐藏。
        let add = app.buttons["inbox-add-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(
            app.textViews["inbox-capture-text-editor"].waitForExistence(timeout: 5)
        )
        app.buttons["inbox-capture-cancel-button"].tap()
        XCTAssertTrue(app.navigationBars["收集箱"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        popToPrevious(in: app)
        XCTAssertTrue(app.todayNavigationBar.waitForExistence(timeout: 5))
        assertTabBarVisible(app)
    }

    /// 今日 → 需要关注 → 卡片详情：三级页继承隐藏状态。
    @MainActor
    func testTodayAdaptiveRouteKeepsTabBarHiddenOnDeepPages() {
        let app = launchApp(
            seed: "ready",
            environment: ["OBOE_UI_TEST_ADAPTIVE_SEED": "1"]
        )
        let entry = app.descendants(matching: .any)["today-adaptive-entry"]
        XCTAssertTrue(
            entry.waitForExistence(timeout: 10),
            "种子含易错卡时首页必须显示胶囊提醒"
        )
        entry.tap()
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        let row = app.cells.containing(.staticText, identifier: "受ける").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["卡片详情"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["易错卡"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)
        popToPrevious(in: app)
        XCTAssertTrue(app.todayNavigationBar.waitForExistence(timeout: 5))
        assertTabBarVisible(app)
    }

    /// 牌组 → 牌组详情 → 添加：详情与更深的添加页都隐藏。
    @MainActor
    func testDecksDetailAndAddRoutesHideTabBar() {
        let app = launchApp()
        app.tabBars.buttons["牌组"].tap()
        let create = app.buttons["deck-create-empty-button"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let nameField = app.textFields["deck-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.tap()
        nameField.typeText("深潜牌组")
        app.buttons["deck-name-save-button"].tap()

        let row = app.staticTexts["深潜牌组"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["深潜牌组"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        let add = app.buttons["deck-add-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["添加"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["深潜牌组"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)
        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["牌组"].waitForExistence(timeout: 5))
        assertTabBarVisible(app)
    }

    /// 牌组 → JLPT 词汇库 → 等级页：深层路由保持隐藏。
    @MainActor
    func testDecksJLPTRouteKeepsTabBarHiddenOnNestedPages() {
        let app = launchApp()
        app.tabBars.buttons["牌组"].tap()
        let library = app.buttons["jlpt-library-entry"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        XCTAssertTrue(app.navigationBars["JLPT 词汇库"].waitForExistence(timeout: 5))
        let acknowledge = app.buttons["我知道了"]
        if acknowledge.waitForExistence(timeout: 2) {
            acknowledge.tap()
        }
        assertTabBarHidden(app)

        let level = app.buttons["jlpt-level-N5"]
        XCTAssertTrue(level.waitForExistence(timeout: 5))
        level.tap()
        XCTAssertTrue(app.navigationBars["N5"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)

        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["JLPT 词汇库"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)
        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["牌组"].waitForExistence(timeout: 5))
        assertTabBarVisible(app)
    }

    /// 牌组 → 全局搜索 / 收藏。
    @MainActor
    func testDecksSearchAndFavoritesRoutesHideTabBar() {
        let app = launchApp()
        app.tabBars.buttons["牌组"].tap()

        let search = app.buttons["global-search-button"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)
        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["牌组"].waitForExistence(timeout: 5))
        assertTabBarVisible(app)

        let favorites = app.buttons["favorites-button"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        XCTAssertTrue(app.navigationBars["收藏"].waitForExistence(timeout: 5))
        assertTabBarHidden(app)
        popToPrevious(in: app)
        assertTabBarVisible(app)
    }

    /// 设置 → 关于（v0.5.8：设置经今日页齿轮以 sheet 打开，sheet 内
    /// 二级页沿用返回语义；关闭 sheet 后 Tab Bar 恢复）。
    @MainActor
    func testSettingsAboutRouteHidesTabBarUntilBack() {
        let app = launchApp()
        app.openSettingsFromTodayGear()

        let about = app.buttons["about-navigation-link"]
        for _ in 0..<12 where !(about.exists && about.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()

        XCTAssertTrue(app.navigationBars["关于 Oboe"].waitForExistence(timeout: 5))
        popToPrevious(in: app)
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.dismissSettingsSheet()
        assertTabBarVisible(app)
    }

    /// 快速连续切换一级 Tab：Tab Bar 始终在位、页面正确。
    /// v0.5.8 起设置不在 Tab Bar（今日页齿轮 sheet），循环只含两 tab。
    @MainActor
    func testRapidTabSwitchingKeepsTabBarOnPrimaryPages() {
        let app = launchApp(seed: "ready")
        for tab in ["牌组", "今日", "牌组", "今日"] {
            app.tabBars.buttons[tab].tap()
            let bar = tab == "今日" ? app.todayNavigationBar : app.navigationBars[tab]
            XCTAssertTrue(
                bar.waitForExistence(timeout: 3),
                "快速切换到 \(tab) 后未显示对应页面"
            )
            XCTAssertTrue(app.tabBars.buttons["今日"].exists, "\(tab) 页 Tab Bar 丢失")
        }
    }

    // MARK: - Step 7：固定首屏布局

    /// SE 首屏不滚动：CTA、任务计数、两枚磁贴、主牌组行全部
    /// 存在且可点击；常规字号下不出现任何滚动容器。
    @MainActor
    func testTodayFixedLayoutPutsAllPrimaryContentOnFirstScreen() {
        let app = launchApp(seed: "ready")

        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        for identifier in [
            "today-summary",
            "today-new-count",
            "today-review-count",
            "today-learning-count",
            "today-remaining-count",
            "today-completed-count",
            "today-statistics-entry",
            "today-inbox-entry",
            "today-primary-deck",
        ] {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.exists, "首屏缺少 \(identifier)")
        }
        XCTAssertTrue(start.isHittable, "圆形 CTA 必须可直接点击")
        XCTAssertTrue(
            app.descendants(matching: .any)["today-statistics-entry"].isHittable,
            "每日统计磁贴必须可直接点击"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["today-inbox-entry"].isHittable,
            "收集箱磁贴必须可直接点击"
        )
        XCTAssertFalse(
            app.scrollViews.firstMatch.exists
                || app.collectionViews.firstMatch.exists,
            "常规字号下首页不应存在滚动容器"
        )
    }

    /// 圆形 CTA 视觉居中：导航标题与 Home Indicator 不应造成偏移。
    @MainActor
    func testTodayCircularCTAStaysHorizontallyCentered() {
        let app = launchApp(seed: "ready")
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(
            start.frame.midX,
            app.frame.midX,
            accuracy: 12,
            "圆形 CTA 必须在屏幕上水平居中"
        )
    }

    /// 两枚入口磁贴等宽并排（同一行、相同宽度）。
    @MainActor
    func testTodayShortcutTilesAreEqualWidthSideBySide() {
        let app = launchApp(seed: "ready")
        let statistics = app.descendants(matching: .any)["today-statistics-entry"]
        let inbox = app.descendants(matching: .any)["today-inbox-entry"]
        XCTAssertTrue(statistics.waitForExistence(timeout: 10))
        XCTAssertTrue(inbox.exists)
        XCTAssertEqual(
            statistics.frame.width,
            inbox.frame.width,
            accuracy: 1,
            "两枚磁贴必须等宽"
        )
        XCTAssertEqual(
            statistics.frame.minY,
            inbox.frame.minY,
            accuracy: 1,
            "两枚磁贴必须并排同行"
        )
    }

    /// 磁贴真实可点击：分别进入每日统计与收集箱。
    @MainActor
    func testTodayShortcutTilesNavigate() {
        let app = launchApp(seed: "ready")

        app.descendants(matching: .any)["today-statistics-entry"].tap()
        XCTAssertTrue(app.navigationBars["每日统计"].waitForExistence(timeout: 5))
        popToPrevious(in: app)

        app.descendants(matching: .any)["today-inbox-entry"].tap()
        XCTAssertTrue(app.navigationBars["收集箱"].waitForExistence(timeout: 5))
        popToPrevious(in: app)
        XCTAssertTrue(app.todayNavigationBar.waitForExistence(timeout: 5))
    }

    /// waiting 种子：非可操作 CTA 渲染等待态，磁贴仍可用。
    @MainActor
    func testTodayWaitingSeedShowsWaitingState() {
        let app = launchApp(seed: "waiting")
        XCTAssertTrue(
            app.descendants(matching: .any)["today-waiting-state"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertFalse(
            app.buttons["today-start-button"].exists,
            "等待态不得出现可点击 CTA"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["today-statistics-entry"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["today-inbox-entry"].exists
        )
    }

    /// complete 种子：完成态圆盘 + 磁贴。
    @MainActor
    func testTodayCompleteSeedShowsCompletionState() {
        let app = launchApp(seed: "complete")
        XCTAssertTrue(
            app.descendants(matching: .any)["today-day-complete"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.buttons["today-start-button"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["today-statistics-entry"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["today-inbox-entry"].exists
        )
    }

    /// empty-deck 种子：空牌组态 + 主牌组名显示。
    @MainActor
    func testTodayEmptyDeckSeedShowsEmptyState() {
        let app = launchApp(seed: "empty-deck")
        XCTAssertTrue(
            app.descendants(matching: .any)["today-empty-deck"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts["today-primary-deck"].label.contains("主牌组"),
            "空牌组态仍应显示主牌组名"
        )
    }

    /// 空库：无牌组态 + 主牌组显示「未设置」。
    @MainActor
    func testTodayNoDecksShowsUnsetPrimaryDeck() {
        let app = launchApp()
        XCTAssertTrue(
            app.descendants(matching: .any)["today-no-decks"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts["today-primary-deck"].label.contains("未设置")
        )
        XCTAssertFalse(app.buttons["today-start-button"].exists)
    }

    /// 辅助字号（ax5）：退化为可读性优先的滚动布局，CTA 变整宽卡片
    /// 且首屏即可点；磁贴滚动后仍可达。
    @MainActor
    func testTodayAccessibilityTypeFallsBackToReadableLayout() {
        let app = launchApp(
            seed: "ready",
            environment: ["OBOE_UI_TEST_DYNAMIC_TYPE": "ax5"]
        )
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "ax5 下 CTA 必须存在")
        XCTAssertTrue(start.isHittable, "ax5 下 CTA 必须可点击")
        XCTAssertTrue(
            app.scrollViews.firstMatch.exists,
            "辅助字号应启用滚动备用布局"
        )

        let inbox = app.descendants(matching: .any)["today-inbox-entry"]
        for _ in 0..<10 where !(inbox.exists && inbox.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(inbox.isHittable, "ax5 下收集箱磁贴必须滚动可达")
    }

    /// 深色模式：CTA 与磁贴保持渲染可点击（边界由描边/底色保证，
    /// 对比度由 T16 审计覆盖）。
    @MainActor
    func testTodayDarkModeKeepsControlsReachable() {
        let app = launchApp(
            seed: "ready",
            environment: ["OBOE_UI_TEST_APPEARANCE_DARK": "1"]
        )
        let start = app.buttons["today-start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(
            app.descendants(matching: .any)["today-statistics-entry"].isHittable
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["today-inbox-entry"].isHittable
        )
    }

}
