import XCTest
import UIKit

/// iPad regular（三栏 NavigationSplitView）壳层的 UI 测试导航适配层。
///
/// 探测结果（iPad Pro 13-inch，iOS 26.5，竖/横屏一致）：
/// - sidebar 以 overlay 列常驻且可命中，无需旋转或开关；
///   行内 Image 与 StaticText 共享 identifier，Image 不可点击——
///   一律锁定 StaticText 分支。
/// - 返回按钮 identifier 恒为 `BackButton`（label = 上一页标题）；
///   `navigationBars.buttons.element(boundBy: 0)` 在分栏下会命中
///   最左列工具栏按钮，禁止用于返回。
/// - `collectionViews` 文档序 ≈ content 列 → detail 列 → sidebar
///   （label「边栏」）；`firstMatch` 不是「正在看的列」，滚动显露
///   必须按列挑选容器。
/// - Settings 是三栏：content=分类列表（settings-category-list），
///   detail 在选中 `settings-category-*` 行后才挂载目标表单。
extension XCUIApplication {

    // MARK: - 壳层判定

    /// 当前是否处于 regular 分栏壳层。判据：sidebar 行在无障碍树
    /// → regular；否则 Tab Bar 存在 → compact；二级页隐藏 Tab Bar
    /// 时退回设备族判定。
    var isRegularShell: Bool {
        if staticTexts["sidebar-today"].exists { return true }
        if tabBars.firstMatch.exists { return false }
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    /// 启动/重启后等待任一壳层锚点出现（sidebar 行或 Tab Bar）。
    /// 双侧轮询，避免单 waitForExistence 在错误壳层上空等满超时。
    @MainActor
    @discardableResult
    func waitForShellReady(timeout: TimeInterval = 8) -> Bool {
        let sidebar = staticTexts["sidebar-today"]
        let todayTab = tabBars.buttons["今日"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sidebar.exists || todayTab.exists { return true }
            usleep(100_000)
        }
        return sidebar.exists || todayTab.exists
    }

    // MARK: - sidebar / 一级入口

    /// 点选 sidebar 一级入口行（sidebar-today / sidebar-inbox /
    /// sidebar-reader / sidebar-settings / sidebar-jlpt-library /
    /// sidebar-favorites / sidebar-search）。
    @MainActor
    func tapSidebarRow(
        _ identifier: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 重选当前 sidebar 项是 no-op，列内 push 栈（编辑器、分析
        // 结果、条目详情等）会残留——先弹回列根再点行，与 compact
        // 「先 pop 到一级页再点 tab」的语义对齐。
        popAllColumnStacks()
        let row = staticTexts[identifier]
        // 行可能「已挂载但不可命中」（overlay 收起中、sheet 刚关、
        // 竖屏 sidebar 被系统折叠）或根本未挂载（在 sidebar 折叠线
        // 以下，如 jlpt-library/favorites 等靠后行）——轮询可命中
        // 性，必要时唤出 sidebar 并在其列表内滚动显露。
        let deadline = Date().addingTimeInterval(timeout)
        var scrolledDown = false
        while Date() < deadline {
            if row.exists, row.isHittable { break }
            if !row.exists {
                let sidebar = collectionViews["边栏"]
                if sidebar.exists {
                    if scrolledDown {
                        swipeContainerDown(sidebar)
                    } else {
                        swipeContainerUp(sidebar)
                    }
                }
            }
            revealSidebarIfNeeded()
            usleep(150_000)
        }
        if !row.exists, !scrolledDown {
            scrolledDown = true
            let sidebar = collectionViews["边栏"]
            let rescan = Date().addingTimeInterval(2)
            while !row.exists, Date() < rescan {
                if sidebar.exists { swipeContainerUp(sidebar) }
                usleep(150_000)
            }
        }
        XCTAssertTrue(
            row.waitForExistence(timeout: 2),
            "缺少 sidebar 入口 \(identifier)",
            file: file,
            line: line
        )
        if row.isHittable {
            row.tap()
            return
        }
        // sheet 刚关闭/overlay 收起后命中测试可能持续失效：
        // 再从屏幕左缘右扫唤出 sidebar，仍不可命中则对行中心做
        // 坐标点击（比直接 XCTFail 更接近可恢复路径）。
        swipeSidebarOpenFromEdge()
        _ = row.waitForExistence(timeout: 1)
        if row.isHittable {
            row.tap()
            return
        }
        // 行本身不存在时无需坐标兜底（上面的断言已记录失败）。
        guard row.exists else { return }
        let point = row.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        // 坐标点击不校验可命中性——后续等待目标页锚点的断言
        // 会给出更有语义的失败信息。
        point.tap()
        usleep(300_000)
    }

    /// 竖屏 sidebar 折叠时，系统支持从屏幕左缘右扫唤出 overlay。
    @MainActor
    private func swipeSidebarOpenFromEdge() {
        let window = windows.firstMatch
        guard window.exists else { return }
        let start = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)
        )
        let end = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
        usleep(300_000)
    }

    /// 确保 sidebar overlay 展开且行已挂载（返回/前台切换后系统
    /// 可能自动收起 overlay——行元素此时整体缺席而非仅不可命中）。
    /// compact 下是 no-op。
    @MainActor
    @discardableResult
    func ensureSidebarMounted(timeout: TimeInterval = 4) -> Bool {
        guard isRegularShell else { return true }
        let probe = staticTexts["sidebar-today"]
        if probe.exists { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            revealSidebarIfNeeded()
            if probe.waitForExistence(timeout: 0.5) { return true }
            swipeSidebarOpenFromEdge()
            if probe.waitForExistence(timeout: 0.5) { return true }
        }
        return probe.exists
    }

    /// sidebar overlay 被收起时，系统会给出「显示边栏」开关。
    /// 注意：行可能在树里「存在但不可命中」（竖屏折叠/sheet 刚关
    /// 闭的过渡态）——守卫必须看 isHittable 而非 exists。
    @MainActor
    private func revealSidebarIfNeeded() {
        let probe = staticTexts["sidebar-today"]
        if probe.exists, probe.isHittable { return }
        let toggle = buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "边栏", "Sidebar"
            )
        ).firstMatch
        if toggle.exists, toggle.isHittable {
            toggle.tap()
            return
        }
        // 兜底：分栏导航栏首位的列展开按钮（如「Oboe」返回样式）。
        // 只在行完全缺席时才用它，避免误点返回。
        if !probe.exists {
            for index in 0..<min(navigationBars.count, 4) {
                let first = navigationBars.element(boundBy: index)
                    .buttons.element(boundBy: 0)
                if first.exists, first.isHittable,
                   first.identifier != "BackButton" {
                    first.tap()
                    if probe.waitForExistence(timeout: 1.5) { return }
                }
            }
        }
    }

    /// 双壳层统一的一级区切换：compact 点 Tab Bar，regular 点
    /// sidebar 行。「牌组」在 regular 没有对应 section——牌组行
    /// 常驻 sidebar，无需切换，调用方后续直接点名称行即可。
    @MainActor
    func selectPrimarySection(_ name: String) {
        if isRegularShell {
            // 重选当前 section 是 no-op，列内 push 栈会残留——先清栈。
            popAllColumnStacks()
            switch name {
            case "今日": tapSidebarRow("sidebar-today")
            case "收集箱": tapSidebarRow("sidebar-inbox")
            case "阅读": tapSidebarRow("sidebar-reader")
            case "设置": tapSidebarRow("sidebar-settings")
            case "牌组": break // deck/library/favorites/search 都在 sidebar
            default: break
            }
            return
        }
        let tab = tabBars.buttons[name]
        _ = tab.waitForExistence(timeout: 5)
        tab.tap()
    }

    /// 牌组区二级入口：compact=牌组列表根页按钮，regular=sidebar 行。
    /// key ∈ library / favorites / search。
    @MainActor
    func openDecksEntry(
        _ key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let compactID: String
        let regularID: String
        switch key {
        case "library":
            compactID = "jlpt-library-entry"
            regularID = "sidebar-jlpt-library"
        case "favorites":
            compactID = "favorites-button"
            regularID = "sidebar-favorites"
        case "search":
            compactID = "global-search-button"
            regularID = "sidebar-search"
        default:
            XCTFail("未知牌组入口 \(key)", file: file, line: line)
            return
        }
        if isRegularShell {
            tapSidebarRow(regularID)
            return
        }
        let entry = buttons[compactID]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), file: file, line: line)
        entry.tap()
    }

    /// regular：按名称点选 sidebar 里的牌组行。优先按
    /// `sidebar-deck-*` identifier + 名称 label 匹配行容器，
    /// 退化时取 sidebar 区域（x<360）内的同名文本。
    @MainActor
    func selectSidebarDeck(
        named name: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 重选同一牌组是 no-op，内容列可能仍停在编辑器/分析页——
        // 先清栈再选行（与 compact popToPrimaryPageIfNeeded 对齐）。
        popAllColumnStacks()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rowByID = descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                    "sidebar-deck-", name
                )
            ).firstMatch
            if rowByID.exists, rowByID.isHittable {
                rowByID.tap()
                return
            }
            let byLabel = staticTexts.matching(
                NSPredicate(format: "label == %@", name)
            )
            // sidebar overlay 列宽随窗口缩放变化——取实际边栏宽度。
            let sidebarRight = collectionViews["边栏"].firstMatch.exists
                ? collectionViews["边栏"].firstMatch.frame.maxX + 8
                : 360
            for index in 0..<byLabel.count {
                let candidate = byLabel.element(boundBy: index)
                // sidebar 行文本落在 overlay 宽度内。
                if candidate.exists, candidate.isHittable,
                   candidate.frame.minX < sidebarRight {
                    candidate.tap()
                    return
                }
            }
            usleep(100_000)
        }
        XCTFail("sidebar 中找不到牌组行「\(name)」", file: file, line: line)
    }

    /// 双壳层「打开牌组详情」：compact=列表里点名称行；
    /// regular=点 sidebar 牌组行（行选中即 content 列详情）。
    @MainActor
    func openDeck(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isRegularShell {
            selectSidebarDeck(named: name, file: file, line: line)
            return
        }
        // S18：compact TabView 懒挂载——牌组列表只在选中该 Tab 后
        // 进入无障碍树。openDeck 语义是「从任意位置打开牌组」，
        // 故先切 Tab（已选中时等价于 pop 回列表根，再点名行）。
        let decksTab = tabBars.buttons["牌组"]
        if decksTab.waitForExistence(timeout: 3) {
            decksTab.tap()
        }
        let row = staticTexts[name]
        revealElement(row)
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "牌组「\(name)」行不存在",
            file: file,
            line: line
        )
        row.tap()
    }

    /// 双壳层牌组行元素（断言存在性/徽标用）：compact=列表行
    /// （按钮或文本），regular=sidebar 里 `sidebar-deck-*` 且
    /// label 含名称的行容器。
    func deckRow(named name: String) -> XCUIElement {
        if isRegularShell {
            return descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                    "sidebar-deck-", name
                )
            ).firstMatch
        }
        return staticTexts[name]
    }

    /// 双壳层建牌组入口：compact=空态按钮/列表工具栏，
    /// regular=sidebar 工具栏「新建牌组」。
    @MainActor
    func openDeckCreateEditor(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isRegularShell {
            let create = buttons["sidebar-deck-create-button"]
            XCTAssertTrue(
                create.waitForExistence(timeout: 5),
                "缺少 sidebar 新建牌组按钮",
                file: file,
                line: line
            )
            create.tap()
            return
        }
        let emptyCreate = buttons["deck-create-empty-button"]
        if emptyCreate.waitForExistence(timeout: 3) {
            emptyCreate.tap()
            return
        }
        let toolbarCreate = buttons["deck-create-toolbar-button"]
        XCTAssertTrue(
            toolbarCreate.waitForExistence(timeout: 3),
            "缺少新建牌组按钮",
            file: file,
            line: line
        )
        toolbarCreate.tap()
    }

    /// 双壳层：从牌组入口打开「添加」流程，停在「添加」页。
    /// compact=牌组 tab → 牌组行 → 详情工具栏「添加」；
    /// regular=sidebar 牌组行 → content 列详情 → 「添加」。
    @MainActor
    func openDeckAddFlow(
        deckName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if isRegularShell {
            selectSidebarDeck(named: deckName, file: file, line: line)
        } else {
            let decksTab = tabBars.buttons["牌组"]
            _ = decksTab.waitForExistence(timeout: 5)
            decksTab.tap()
            let row = staticTexts[deckName]
            revealElement(row, requireHittable: true)
            XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
            row.tap()
        }
        let addButton = buttons["deck-add-button"]
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 5),
            "牌组「\(deckName)」详情缺少添加入口",
            file: file,
            line: line
        )
        addButton.tap()
        XCTAssertTrue(
            navigationBars["添加"].waitForExistence(timeout: 5),
            "添加页未打开",
            file: file,
            line: line
        )
    }

    /// Form/List 行内控件：iOS 26 分组样式下 identifier 可能挂到
    /// 行容器（cell/other）而非 Button 本体——`app.buttons[id]`
    /// 会永远查不到。优先按按钮解析，缺席时退回任意类型。
    func formControl(_ identifier: String) -> XCUIElement {
        let button = buttons[identifier]
        if button.exists { return button }
        return descendants(matching: .any)[identifier].firstMatch
    }

    // MARK: - 返回 / 栈管理

    /// 弹回当前栈一层。regular 用系统 BackButton（列根页面没有
    /// BackButton——此时是 no-op，因为列表列始终可见）；
    /// compact 保持「导航栏首个按钮」既有语义。
    @MainActor
    @discardableResult
    func popBackIfNeeded() -> Bool {
        if isRegularShell {
            // 多列并存多个 BackButton——取最右侧可命中者（最深列的
            // push 栈），firstMatch 可能命中浅列导致弹错栈。
            let back = buttons.matching(identifier: "BackButton")
                .allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
                .max { $0.frame.minX < $1.frame.minX }
            guard let back else { return false }
            back.tap()
            return true
        }
        let back = navigationBars.buttons.element(boundBy: 0)
        guard back.exists, back.isHittable else { return false }
        back.tap()
        return true
    }

    /// compact：二级页隐藏 Tab Bar，逐层返回到一级页。
    /// regular：sidebar 常驻，无需返回——纯 no-op。
    @MainActor
    func popToPrimaryIfNeeded() {
        guard !isRegularShell else { return }
        for _ in 0..<5 {
            if tabBars.buttons["牌组"].exists { return }
            let back = navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { return }
            back.tap()
        }
    }

    /// regular：把 content/detail 列里所有 push 栈逐层弹回列根。
    /// 重复点选已选中的 sidebar 行是 no-op（栈保留），所以凡是要
    /// 「重新导航到某区/某牌组」的路径都必须先清栈——这对应
    /// compact 里 popToPrimaryPageIfNeeded 的语义。
    /// 弹法：优先最左列的 BackButton（content 列比 detail 列浅），
    /// 直到没有可命中返回键。
    @MainActor
    func popAllColumnStacks(maxPops: Int = 8) {
        guard isRegularShell else { return }
        for _ in 0..<maxPops {
            let backs = buttons.matching(identifier: "BackButton")
                .allElementsBoundByIndex
                .filter { $0.exists && $0.isHittable }
                .sorted { $0.frame.minX < $1.frame.minX }
            guard let back = backs.first else { return }
            back.tap()
            usleep(200_000)
        }
    }

    // MARK: - 设置（三栏）

    /// SettingsRoute.identifier 全量（与 SettingsCategoryListView 同步）。
    private var settingsCategoryIdentifiers: [String] {
        ["appearance", "learning", "speech", "adaptive", "ai", "backup", "about"]
    }

    /// detail 列是否停在「分类根页/空占位」——只有此时换分类才安全；
    /// 二级页（选择模型、关于 Oboe 等）换分类会 pop 掉 push 栈。
    private var isAtSettingsCategoryRoot: Bool {
        if descendants(matching: .any)["settings-detail-empty"].exists {
            return true
        }
        let categoryTitles = [
            "外观", "学习计划", "发音与回忆", "主动回忆与易错卡",
            "AI 服务", "数据与快照", "关于"
        ]
        return categoryTitles.contains { navigationBars[$0].exists }
    }

    /// regular 设置三栏：目标控件只在所属分类的 detail 列挂载。
    /// 元素未挂载且 detail 停在分类根页/空占位时逐行试选分类；
    /// compact（无分类列）与已挂载时直接返回。
    @MainActor
    func selectSettingsCategoryIfNeeded(for element: XCUIElement) {
        guard !element.exists else { return }
        guard collectionViews["settings-category-list"].exists else { return }
        guard isAtSettingsCategoryRoot else { return }
        for identifier in settingsCategoryIdentifiers {
            let row = staticTexts["settings-category-\(identifier)"]
            if row.exists, row.isHittable {
                row.tap()
            }
            if element.waitForExistence(timeout: 1) { return }
        }
    }

    // MARK: - 多列感知显露

    /// 当前页所有可滚动容器，按「最可能承载目标」排序：
    /// 目标已挂载→包含其中心的容器优先；未挂载→按列右到左
    /// （detail → content → sidebar）排列，因为新内容总落在更深列。
    private func revealContainers(
        preferring element: XCUIElement
    ) -> [XCUIElement] {
        // iOS 26 下 regular 宽度的 Form/分组列表可能以 Table 挂载
        // （content 列编辑器即是），不属于 collectionViews/scrollViews，
        // 必须一并枚举否则深层行永远扫不到。
        var containers = collectionViews.allElementsBoundByIndex
        containers += tables.allElementsBoundByIndex
        containers += scrollViews.allElementsBoundByIndex
        // S18：观察流驱动的列表重载会在「枚举→读 frame」的间隙
        // 卸载容器（lazy query 元素读到已消失的快照即断言失败）——
        // 先滤掉不可解析者，把竞态窗口收窄到可忽略范围。
        containers = containers.filter { $0.exists }
        // 目标可能多匹配（同名文本同时挂在 content/detail 列）——
        // 取 firstMatch 再读 frame，否则 snapshot 取单元素直接失败。
        let single = element.firstMatch
        let mid: CGPoint? = single.exists
            ? CGPoint(x: single.frame.midX, y: single.frame.midY)
            : nil
        return containers.sorted { lhs, rhs in
            if let mid {
                let lHit = lhs.frame.contains(mid)
                let rHit = rhs.frame.contains(mid)
                if lHit != rHit { return lHit }
            }
            return lhs.frame.maxX > rhs.frame.maxX
        }
    }

    /// 元素已挂载但卡在视口边缘（不可命中）时，把承载它的容器
    /// 往上推一小段使其完全露出。
    @MainActor
    private func nudgeIntoView(_ element: XCUIElement) {
        let single = element.firstMatch
        guard single.exists, !single.isHittable else { return }
        let mid = CGPoint(x: single.frame.midX, y: single.frame.midY)
        guard let container = revealContainers(preferring: element)
            .first(where: { $0.frame.contains(mid) }) else { return }
        let dx = swipeAnchorX(for: container)
        container.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.7))
            .press(
                forDuration: 0.05,
                thenDragTo: container.coordinate(
                    withNormalizedOffset: CGVector(dx: dx, dy: 0.4)
                )
            )
    }

    /// regular 下 sidebar 以 overlay 盖在列容器左侧（content 列容器
    /// frame 从 x=0 起算，前 ~290pt 实际被 sidebar 命中）。对容器做
    /// `swipeUp()`/`swipeDown()` 会以元素中心为手势起点——若中心落在
    /// 覆盖区里，手势滚的是 sidebar 而非目标列（编辑器列 cv 中心
    /// x≈284 恰在覆盖区内，是 iPad 失败批的根因之一）。
    /// 此处按容器 frame 计算一个避开 sidebar 覆盖区的归一化 x。
    /// 注意 iPadOS 窗口可缩放/偏移（frame 非整屏坐标），覆盖区宽度
    /// 不能写死 300——实测缩放态下 sidebar 实际命中到 x≈352。
    private func swipeAnchorX(for container: XCUIElement) -> CGFloat {
        let frame = container.frame
        let sidebar = collectionViews["边栏"].firstMatch
        let sidebarMaxX = sidebar.exists ? sidebar.frame.maxX : 300
        guard frame.minX < sidebarMaxX, frame.maxX > sidebarMaxX + 40 else {
            return 0.5
        }
        return min(0.9, (sidebarMaxX + 40 - frame.minX) / frame.width)
    }

    /// 对容器做「上扫」（手指上移 = 露出下方内容）。
    @MainActor
    func swipeContainerUp(_ container: XCUIElement) {
        let dx = swipeAnchorX(for: container)
        container.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.65))
            .press(
                forDuration: 0.05,
                thenDragTo: container.coordinate(
                    withNormalizedOffset: CGVector(dx: dx, dy: 0.3)
                )
            )
    }

    /// 点击元素直到 `condition` 满足（最多 retries 次）。
    /// regular 下 Form 行按钮的 tap 可能撞上滚动减速/布局漂移
    /// 被静默吞掉（元素 still hittable、动作不触发）——实测
    /// iPad 编辑器列保存按钮即属此类。每次重试前先等 frame
    /// 稳定再点。
    @MainActor
    @discardableResult
    func tapUntil(
        _ trigger: XCUIElement,
        retries: Int = 3,
        condition: () -> Bool
    ) -> Bool {
        for _ in 0..<retries {
            if condition() { return true }
            if trigger.exists {
                waitForStableFrame(trigger)
                trigger.firstMatch.tap()
            }
            usleep(400_000)
            if condition() { return true }
        }
        return condition()
    }

    /// 正式保存按钮 + 「已正式保存」状态的有界重试封装。
    /// 词汇/语法添加表单共用该模式；重复确认弹窗路径不走这里。
    @MainActor
    func commitFormAndWaitSaved(
        kind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let save = formControl("\(kind)-formal-save-button")
        let saved = staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "已正式保存")
        ).firstMatch
        let ok = tapUntil(save) { saved.exists }
        if !ok {
            // S18：状态行挂在表单顶部 Section——滚到底部「正式保存」
            // 按钮后已被 List 卸载（提交本身已落库，只是断言看不到）。
            // 向下扫回顶部让状态行重新挂载，再判定一次。
            revealElementBySwipingDown(saved, requireHittable: false, passes: 6)
        }
        XCTAssertTrue(
            ok || saved.exists,
            "正式保存未生效（\(kind)）",
            file: file,
            line: line
        )
    }

    /// 对容器做「下扫」（露出上方内容）。
    @MainActor
    func swipeContainerDown(_ container: XCUIElement) {
        let dx = swipeAnchorX(for: container)
        container.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.3))
            .press(
                forDuration: 0.05,
                thenDragTo: container.coordinate(
                    withNormalizedOffset: CGVector(dx: dx, dy: 0.65)
                )
            )
    }

    /// 收起屏幕键盘。iPad 上 Done/完成 键不收键盘，键盘专属
    /// 「隐藏键盘」键可能处于屏外悬浮态不可点；内容列普遍有
    /// `scrollDismissesKeyboard(.immediately)`——对容器做真实
    /// 滚动即可收键盘（同时推进内容，正是显露路径所需）。
    @MainActor
    func dismissOnscreenKeyboard() {
        let keyboard = keyboards.firstMatch
        guard keyboard.exists else { return }
        // 「隐藏键盘」点完后 iPad 键盘退成 ~68pt 的底部残条（悬浮
        // 键盘折叠把手），exists 仍为 true——判定须按高度坍缩而非
        // waitForNonExistence，否则残条会让循环扫遍所有容器。
        func keyboardGone() -> Bool {
            !keyboard.exists || keyboard.frame.height < 120
        }
        func waitGone(_ timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if keyboardGone() { return true }
                usleep(100_000)
            }
            return keyboardGone()
        }
        if keyboardGone() { return }
        let hideKey = keyboard.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "隐藏键盘", "Hide keyboard"
            )
        ).firstMatch
        if hideKey.exists, hideKey.isHittable {
            hideKey.tap()
            if waitGone(1.5) { return }
        }
        for name in ["done", "Done", "完成", "return", "换行"] {
            let key = keyboard.buttons[name]
            if key.exists, key.isHittable {
                key.tap()
                if waitGone(1.5) { return }
            }
        }
        // 滚动收键盘兜底：逐个容器尝试（与 reveal 相同的列序）。
        for container in revealContainers(preferring: keyboard) {
            swipeContainerUp(container)
            if waitGone(1.5) { return }
        }
        // 最后兜底：对键盘本体下扫（iPhone 浮层收键盘路径）。
        // 悬浮/半离屏键盘 visibleFrame 为空，swipeDown 会直接抛错——
        // 只对可命中的键盘尝试。
        if keyboard.exists, keyboard.isHittable { keyboard.swipeDown() }
    }

    /// 键盘是否已收起。iPad 上「隐藏键盘」会把键盘坍缩成 ~68pt
    /// 的底部残条（悬浮键盘把手），`exists` 仍为 true——断言须按
    /// 高度坍缩判定而非 waitForNonExistence。
    func waitForKeyboardDismissed(timeout: TimeInterval = 3) -> Bool {
        let keyboard = keyboards.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !keyboard.exists || keyboard.frame.height < 120 {
                return true
            }
            usleep(100_000)
        }
        return !keyboard.exists || keyboard.frame.height < 120
    }

    /// 等目标 frame 稳定（连续两帧相同，最长 ~1.4s）。
    /// regular 下列内容异步铺开（预览段物化、草稿恢复、键盘收起
    /// 改变 content inset）——元素已挂载但位置仍在漂移，此时 tap
    /// 会按过期坐标合成、落在错误行上，表现为静默无效。
    @MainActor
    func waitForStableFrame(_ element: XCUIElement, polls: Int = 7) {
        let single = element.firstMatch
        guard single.exists else { return }
        var last = single.frame
        for _ in 0..<polls {
            usleep(200_000)
            guard single.exists else { return }
            let now = single.frame
            if now == last { return }
            last = now
        }
    }

    /// 多列感知双向显露：先向上扫、再向下扫，每轮逐容器尝试。
    /// regular 下同时负责「先选中目标所在设置分类」。
    /// requireHittable=false 用于只验证挂载不点击的断言前置。
    @MainActor
    func revealElement(
        _ element: XCUIElement,
        requireHittable: Bool = true,
        passes: Int = 12
    ) {
        revealElementScrolling(element, requireHittable: requireHittable, passes: passes)
        // 到达后等布局沉降——列内异步内容会使目标 frame 继续漂移。
        waitForStableFrame(element)
    }

    @MainActor
    private func revealElementScrolling(
        _ element: XCUIElement,
        requireHittable: Bool = true,
        passes: Int = 12
    ) {
        // 多匹配时 isHittable 会抛「Multiple matching elements」——
        // 一律用 firstMatch 做命中判断，点击侧由调用方自行解析。
        let single = element.firstMatch
        var attempted = 0
        func reached() -> Bool {
            guard element.exists else { return false }
            if !requireHittable || single.isHittable { return true }
            // 已挂载且完整落在窗口内（Image/标签类元素不参与
            // hit-test，或被 overlay 语义标记不可命中）——继续扫
            // 只会把它推出视口卸载。可点性交由调用方 tap 判定。
            if attempted > 0 {
                let frame = single.frame
                let window = windows.firstMatch.frame
                if !frame.isEmpty,
                   window.insetBy(dx: 1, dy: 1).contains(frame) {
                    return true
                }
            }
            return false
        }
        for _ in 0..<passes {
            if reached() { return }
            attempted += 1
            selectSettingsCategoryIfNeeded(for: element)
            if element.exists, !single.isHittable { nudgeIntoView(element) }
            var swiped = false
            for container in revealContainers(preferring: element) {
                if reached() { return }
                swipeContainerUp(container)
                swiped = true
            }
            if !swiped {
                // 无滚动容器（如 regular 今日固定布局）——再等一次挂载。
                _ = element.waitForExistence(timeout: 1.5)
                if reached() { return }
            }
        }
        for _ in 0..<passes {
            if reached() { return }
            attempted += 1
            selectSettingsCategoryIfNeeded(for: element)
            var swiped = false
            for container in revealContainers(preferring: element) {
                if reached() { return }
                swipeContainerDown(container)
                swiped = true
            }
            if !swiped { return }
        }
    }

    /// 返回最可能承载该元素的滚动容器——元素已挂载时取「框内
    /// 包含其中心」的容器，否则按列右到左取首个。供需要直接对
    /// 容器做 swipe 的用例（如把行抬离 Tab Bar 遮挡区）使用。
    func scrollContainerHosting(_ element: XCUIElement) -> XCUIElement {
        let containers = revealContainers(preferring: element)
        let single = element.firstMatch
        if single.exists {
            let mid = CGPoint(x: single.frame.midX, y: single.frame.midY)
            if let hosting = containers.first(where: { $0.frame.contains(mid) }) {
                return hosting
            }
        }
        return containers.first ?? collectionViews.firstMatch
    }

    /// 只向下扫的显露（目标在当前视口上方时使用）。
    @MainActor
    func revealElementBySwipingDown(
        _ element: XCUIElement,
        requireHittable: Bool = true,
        passes: Int = 12
    ) {
        let single = element.firstMatch
        func reached() -> Bool {
            element.exists && (!requireHittable || single.isHittable)
        }
        for _ in 0..<passes {
            if reached() { return }
            for container in revealContainers(preferring: element) {
                if reached() { return }
                swipeContainerDown(container)
            }
        }
        waitForStableFrame(element)
    }

    // MARK: - 今日页

    /// Today 页强制重载。v0.5.8 起两侧壳层都传了 openSettings，
    /// `today-refresh-button` 实际不再渲染——按钮缺席时退回
    /// 后台→前台 scenePhase 路径触发 model.load()。
    @MainActor
    func refreshToday() {
        let refresh = buttons["today-refresh-button"]
        if refresh.exists {
            refresh.tap()
            return
        }
        XCUIDevice.shared.press(.home)
        activate()
    }
}
