import UIKit
import XCTest

final class OboeInboxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInboxManualCapturePersistsAcrossRelaunch() {
        let databaseID = UUID().uuidString
        let app = launchApp(databaseID: databaseID)
        openInbox(in: app)

        XCTAssertTrue(app.staticTexts["inbox-empty-state"].waitForExistence(timeout: 5))
        captureText("そんなわけないでしょう。", in: app)
        XCTAssertTrue(
            app.staticTexts["そんなわけないでしょう。"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["手动添加"].exists)

        app.terminate()

        let relaunched = launchApp(databaseID: databaseID)
        openInbox(in: relaunched)
        XCTAssertTrue(
            relaunched.staticTexts["そんなわけないでしょう。"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testInboxDetailEditArchiveAndDelete() {
        let app = launchApp()
        openInbox(in: app)
        captureText("毎朝パンを食べます。", in: app)
        let captured = app.staticTexts["毎朝パンを食べます。"]
        XCTAssertTrue(captured.waitForExistence(timeout: 5))
        captured.tap()

        XCTAssertTrue(app.navigationBars["收集条目"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["inbox-detail-status"].exists)
        let analyzeButton = app.buttons["AI 分析并制卡"]
        XCTAssertTrue(analyzeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(analyzeButton.isEnabled)
        XCTAssertTrue(app.buttons["直接加入学习"].isEnabled)

        app.buttons["inbox-detail-edit-button"].tap()
        let editor = app.textViews["inbox-edit-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("（追记）")
        app.buttons["inbox-edit-save-button"].tap()
        let detailText = app.staticTexts["inbox-detail-text"]
        XCTAssertTrue(
            waitForLabel(detailText, containing: "追记")
        )
        XCTAssertTrue(detailText.label.contains("パン"))

        let archiveButton = app.buttons["inbox-detail-archive-button"]
        let statusText = app.staticTexts["inbox-detail-status"]
        if app.isRegularShell {
            // regular：归档把条目移出「未处理」列表并清空 detail 选择——
            // 状态断言改经筛选器切到「已归档」分段重选行验证。
            app.tapUntil(archiveButton) {
                app.staticTexts["inbox-detail-empty"].exists
            }
            XCTAssertTrue(
                app.staticTexts["inbox-detail-empty"].waitForExistence(timeout: 5)
            )
            let archivedSegment = app.segmentedControls.buttons["已归档"]
            XCTAssertTrue(archivedSegment.waitForExistence(timeout: 5))
            archivedSegment.tap()
            // 行文本已含编辑追加的「（追记）」——用 CONTAINS 匹配。
            let archivedRow = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "毎朝パンを食べます")
            ).firstMatch
            XCTAssertTrue(archivedRow.waitForExistence(timeout: 5))
            archivedRow.tap()
            XCTAssertTrue(
                waitForLabel(
                    app.staticTexts["inbox-detail-status"],
                    containing: "已归档"
                )
            )
            // 取消归档后行离开「已归档」筛选、detail 再次清空。
            app.tapUntil(archiveButton) {
                app.staticTexts["inbox-detail-empty"].exists
            }
            XCTAssertTrue(
                app.staticTexts["inbox-detail-empty"].waitForExistence(timeout: 5)
            )
            let unprocessedSegment = app.segmentedControls.buttons["未处理"]
            unprocessedSegment.tap()
            let restoredRow = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "毎朝パンを食べます")
            ).firstMatch
            XCTAssertTrue(restoredRow.waitForExistence(timeout: 5))
            restoredRow.tap()
            XCTAssertTrue(
                waitForLabel(
                    app.staticTexts["inbox-detail-status"],
                    containing: "未处理"
                )
            )
        } else {
            // compact：保存触发的 onChanged 会驱动页面重载——
            // 若点击落在重建间隙会丢事件；以状态翻转为后置条件重试。
            app.tapUntil(archiveButton) {
                statusText.exists && statusText.label.contains("已归档")
            }
            XCTAssertTrue(
                waitForLabel(statusText, containing: "已归档")
            )
            app.tapUntil(archiveButton) {
                let s = app.staticTexts["inbox-detail-status"]
                return s.exists && s.label.contains("未处理")
            }
            XCTAssertTrue(
                waitForLabel(app.staticTexts["inbox-detail-status"], containing: "未处理")
            )
        }

        app.buttons["inbox-detail-delete-button"].tap()
        let confirmDelete = app.buttons["inbox-detail-delete-confirm-button"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["inbox-empty-state"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testInboxSearchAndSwipeArchive() {
        let app = launchApp()
        openInbox(in: app)
        captureText("パンを食べる", in: app)
        captureText("学校に行く", in: app)

        let searchField = app.searchFields["搜索收集内容"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("ぱん")
        XCTAssertTrue(app.staticTexts["パンを食べる"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["学校に行く"].exists)
        searchField.typeText(String(repeating: "\u{8}", count: 2))

        XCTAssertTrue(app.staticTexts["学校に行く"].waitForExistence(timeout: 5))
        let row = app.staticTexts["学校に行く"]
        row.swipeLeft()
        let archiveButton = app.buttons["归档"]
        XCTAssertTrue(archiveButton.waitForExistence(timeout: 5))
        archiveButton.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["学校に行く"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)

        app.buttons["已归档"].tap()
        XCTAssertTrue(app.staticTexts["学校に行く"].waitForExistence(timeout: 5))
        app.buttons["未处理"].tap()
    }

    @MainActor
    func testInboxBatchArchiveAndTodayEntryCount() {
        let app = launchApp()
        openInbox(in: app)
        captureText("一つ目", in: app)
        captureText("二つ目", in: app)

        app.buttons["inbox-edit-button"].tap()
        app.staticTexts["一つ目"].tap()
        app.staticTexts["二つ目"].tap()
        let batchButton = app.buttons["inbox-batch-archive-button"]
        XCTAssertTrue(batchButton.waitForExistence(timeout: 5))
        batchButton.tap()
        XCTAssertTrue(
            app.staticTexts["inbox-empty-state"].waitForExistence(timeout: 5)
        )

        app.buttons["已归档"].tap()
        XCTAssertTrue(app.staticTexts["一つ目"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["二つ目"].exists)

        popToPrimaryPageIfNeeded(in: app)
        app.selectPrimarySection("今日")
        let entry = app.buttons["today-inbox-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("收集箱"))
        entry.tap()
        XCTAssertTrue(app.navigationBars["收集箱"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testInboxPasteCapture() {
        UIPasteboard.general.string = "パンケーキを焼いた"
        let app = launchApp()
        openInbox(in: app)

        app.buttons["inbox-add-button"].tap()
        let pasteButton = app.buttons["inbox-capture-paste-button"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5))
        XCTAssertTrue(pasteButton.isEnabled, "剪贴板有内容时粘贴按钮应可用")
        pasteButton.tap()
        let editor = app.textViews["inbox-capture-text-editor"]
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "パンケーキ"),
            object: editor
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [pasted], timeout: 5),
            .completed,
            "粘贴内容未写入编辑器"
        )
        app.buttons["inbox-capture-save-button"].tap()

        XCTAssertTrue(app.staticTexts["パンケーキを焼いた"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["粘贴"].exists)
    }

    @MainActor
    func testInboxManualProcessingResumesAcrossRelaunch() {
        let databaseID = UUID().uuidString
        let app = launchApp(databaseID: databaseID)

        // A deck is required for the formal save at the end of this test.
        if !app.isRegularShell {
            let decksTab = app.tabBars.buttons["牌组"]
            XCTAssertTrue(decksTab.waitForExistence(timeout: 5))
            decksTab.tap()
        }
        app.openDeckCreateEditor()
        let deckName = app.textFields["deck-name-field"]
        XCTAssertTrue(deckName.waitForExistence(timeout: 5))
        deckName.tap()
        deckName.typeText("收集入库")
        app.buttons["deck-name-save-button"].tap()
        XCTAssertTrue(app.deckRow(named: "收集入库").waitForExistence(timeout: 5))

        openInbox(in: app)
        captureText("食べる", in: app)

        app.staticTexts["食べる"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收集条目"].waitForExistence(timeout: 5))
        app.buttons["直接加入学习"].tap()

        // Manual entry hides the AI generation section and prefills the form.
        XCTAssertTrue(app.navigationBars["处理收集"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["capture-source-text"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["ai-card-generate-button"].exists)
        let headword = app.textFields["vocabulary-headword-field"]
        reveal(headword, in: app)
        XCTAssertTrue(headword.waitForExistence(timeout: 5))
        XCTAssertEqual(headword.value as? String, "食べる")

        let meaning = app.textFields["vocabulary-meaning-field"]
        reveal(meaning, in: app)
        meaning.tap()
        meaning.typeText("吃")
        XCTAssertEqual(meaning.value as? String, "吃")
        dismissKeyboard(in: app)
        app.buttons["vocabulary-save-draft-button"].tap()
        let draftStatus = app.staticTexts["vocabulary-draft-status"]
        app.revealElementBySwipingDown(draftStatus, requireHittable: false)
        XCTAssertTrue(draftStatus.waitForExistence(timeout: 5))

        // Back to the list: the item moved to 处理中. regular 下第二
        // 次返回是 no-op——列表列始终可见。
        app.popBackIfNeeded()
        app.popBackIfNeeded()
        app.buttons["处理中"].tap()
        XCTAssertTrue(app.staticTexts["食べる"].waitForExistence(timeout: 5))

        app.terminate()

        let relaunched = launchApp(databaseID: databaseID)
        openInbox(in: relaunched)
        relaunched.buttons["处理中"].tap()
        relaunched.staticTexts["食べる"].firstMatch.tap()
        XCTAssertTrue(
            relaunched.buttons["继续处理"]
                .waitForExistence(timeout: 5)
        )
        relaunched.buttons["继续处理"].tap()

        let restoredHeadword = relaunched.textFields["vocabulary-headword-field"]
        revealInEitherDirection(restoredHeadword, in: relaunched)
        XCTAssertTrue(restoredHeadword.waitForExistence(timeout: 5))
        XCTAssertEqual(restoredHeadword.value as? String, "食べる")
        let restoredMeaning = relaunched.textFields["vocabulary-meaning-field"]
        revealInEitherDirection(restoredMeaning, in: relaunched)
        XCTAssertEqual(restoredMeaning.value as? String, "吃")
        let resumeStatus = relaunched.staticTexts["vocabulary-draft-status"]
        relaunched.revealElementBySwipingDown(resumeStatus, requireHittable: false)
        XCTAssertTrue(resumeStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(resumeStatus.label.contains("已恢复"))
        // T15: the capture commit is live — same persisted operationID makes a
        // retry idempotent even after relaunch.
        let formalSave = relaunched.formControl("vocabulary-formal-save-button")
        relaunched.revealElement(formalSave, requireHittable: false)
        XCTAssertTrue(formalSave.exists)
        XCTAssertTrue(formalSave.isEnabled)
        relaunched.tapUntil(formalSave) {
            relaunched.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "已正式保存")
            ).firstMatch.exists
        }

        // The status strip renders near the top of the form — scroll up first.
        let savedStatus = relaunched.staticTexts["vocabulary-draft-status"]
        relaunched.revealElementBySwipingDown(savedStatus, requireHittable: false)
        XCTAssertTrue(savedStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForLabel(savedStatus, containing: "已正式保存")
        )

        // Back to the list: the item moved to 已处理 atomically with the commit.
        relaunched.popBackIfNeeded()
        relaunched.popBackIfNeeded()
        relaunched.buttons["已处理"].tap()
        XCTAssertTrue(relaunched.staticTexts["食べる"].waitForExistence(timeout: 5))

        // The capture draft must not leak into the normal Add page.
        openDeckAddFlow(in: relaunched, deckName: "收集入库")
        let normalHeadword = relaunched.textFields["vocabulary-headword-field"]
        XCTAssertTrue(normalHeadword.waitForExistence(timeout: 5))
        XCTAssertNotEqual(normalHeadword.value as? String, "食べる")
        XCTAssertFalse(
            relaunched.staticTexts["vocabulary-draft-status"].exists
        )
    }

    @MainActor
    func testInboxAnalysisResumeAndStaleAfterTextEdit() {
        let databaseID = UUID().uuidString
        // Step 12 起 AI 启用需「获取模型→选择→保存并测试」——本用例只
        // 验证分析草稿恢复，直接经 seam 预置已启用配置与凭据。
        let app = launchApp(
            databaseID: databaseID,
            environment: ["OBOE_UI_TEST_AI_ENABLED": "1"]
        )
        openInbox(in: app)
        captureText("日本に行ったことがありますか。", in: app)

        app.staticTexts["日本に行ったことがありますか。"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["收集条目"].waitForExistence(timeout: 5))
        app.buttons["AI 分析并制卡"].tap()

        // Heuristic: sentence-ending punctuation suggests 句子分析.
        XCTAssertTrue(app.navigationBars["处理收集"].waitForExistence(timeout: 5))
        let input = app.textViews["sentence-analysis-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "日本に行ったことがありますか。")

        let analyzeButton = app.buttons["sentence-analysis-start-button"]
        reveal(analyzeButton, in: app)
        analyzeButton.tap()
        let selectVocabulary = app.switches["sentence-card-select-vocabulary-1"]
        app.revealElement(selectVocabulary, requireHittable: false, passes: 15)
        XCTAssertTrue(selectVocabulary.waitForExistence(timeout: 10))
        selectVocabulary.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(selectVocabulary.value as? String, "1")
        let selectionStatus = app.staticTexts["sentence-card-status"]
        app.revealElement(selectionStatus, requireHittable: false)
        XCTAssertTrue(selectionStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(selectionStatus.label.contains("已选择 1 项"))

        app.terminate()

        let relaunched = launchApp(
            databaseID: databaseID,
            environment: ["OBOE_UI_TEST_AI_ENABLED": "1"]
        )
        openInbox(in: relaunched)
        relaunched.buttons["处理中"].tap()
        relaunched.staticTexts["日本に行ったことがありますか。"].firstMatch.tap()
        relaunched.buttons["继续处理"].tap()
        let restoredStatus = relaunched.staticTexts["sentence-card-status"]
        relaunched.revealElement(restoredStatus, requireHittable: false)
        XCTAssertTrue(restoredStatus.waitForExistence(timeout: 10))
        XCTAssertTrue(restoredStatus.label.contains("已恢复 1 项选择"))

        // Editing the source invalidates the old analysis on next entry.
        relaunched.popBackIfNeeded()
        relaunched.buttons["inbox-detail-edit-button"].tap()
        let editor = relaunched.textViews["inbox-edit-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("！")
        relaunched.buttons["inbox-edit-save-button"].tap()
        relaunched.buttons["继续处理"].tap()
        let staleNotice = relaunched.staticTexts["capture-stale-notice"]
        relaunched.revealElementBySwipingDown(staleNotice, requireHittable: false)
        XCTAssertTrue(staleNotice.waitForExistence(timeout: 10))
        XCTAssertFalse(relaunched.switches["sentence-card-select-vocabulary-1"].exists)
    }

    @MainActor
    func testInboxProcessingIsolatesItemsAcrossSwitching() {
        let app = launchApp()
        openInbox(in: app)
        captureText("林檎", in: app)
        captureText("蜜柑", in: app)

        // Process A manually.
        app.staticTexts["林檎"].firstMatch.tap()
        app.buttons["直接加入学习"].tap()
        XCTAssertTrue(app.navigationBars["处理收集"].waitForExistence(timeout: 5))
        let headwordA = app.textFields["vocabulary-headword-field"]
        revealInEitherDirection(headwordA, in: app)
        XCTAssertTrue(headwordA.waitForExistence(timeout: 5))
        XCTAssertEqual(headwordA.value as? String, "林檎")
        app.popBackIfNeeded()
        app.popBackIfNeeded()

        // Switch to B: must not inherit A's form.
        app.staticTexts["蜜柑"].firstMatch.tap()
        app.buttons["直接加入学习"].tap()
        XCTAssertTrue(app.navigationBars["处理收集"].waitForExistence(timeout: 5))
        let headwordB = app.textFields["vocabulary-headword-field"]
        revealInEitherDirection(headwordB, in: app)
        XCTAssertTrue(headwordB.waitForExistence(timeout: 5))
        XCTAssertEqual(headwordB.value as? String, "蜜柑")

        // Back to A via the 处理中 filter — still shows A's content.
        app.popBackIfNeeded()
        app.popBackIfNeeded()
        app.buttons["处理中"].tap()
        app.staticTexts["林檎"].firstMatch.tap()
        app.buttons["继续处理"].tap()
        XCTAssertTrue(app.navigationBars["处理收集"].waitForExistence(timeout: 5))
        let headwordARestored = app.textFields["vocabulary-headword-field"]
        revealInEitherDirection(headwordARestored, in: app)
        XCTAssertTrue(headwordARestored.waitForExistence(timeout: 5))
        XCTAssertEqual(headwordARestored.value as? String, "林檎")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        app.revealElement(element)
    }

    /// 续编恢复的表单可能已略微滚动（目标恰在视口上沿之外），
    /// 单方向滑动会越推越远——先扫回顶部，再向下扫。
    /// regular 下自动挑选承载目标的列容器。
    @MainActor
    private func revealInEitherDirection(_ element: XCUIElement, in app: XCUIApplication) {
        app.revealElementBySwipingDown(element, requireHittable: false, passes: 8)
        app.revealElement(element, requireHittable: false)
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        app.dismissOnscreenKeyboard()
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        containing fragment: String
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", fragment),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    /// v0.5.5 起二级页隐藏 Tab Bar：若当前在收集箱/详情/编辑器等
    /// 深层页，先逐层返回直到 Tab Bar 重新出现，再允许点 tab。
    /// regular 下 sidebar 常驻，无需返回。
    @MainActor
    private func popToPrimaryPageIfNeeded(in app: XCUIApplication) {
        app.popToPrimaryIfNeeded()
    }

    /// 收集箱入口：compact 走「今日」页磁贴；regular 走 sidebar
    /// 一级入口（行选中即把收集箱列表装进 content 列）。
    @MainActor
    private func openInbox(in app: XCUIApplication) {
        popToPrimaryPageIfNeeded(in: app)
        if app.isRegularShell {
            app.tapSidebarRow("sidebar-inbox")
            // sheet 关闭过渡中首次 sidebar 点击可能被吞——
            // content 列未落「收集箱」时补点一次。
            if !app.navigationBars["收集箱"].waitForExistence(timeout: 3) {
                app.tapSidebarRow("sidebar-inbox")
            }
            XCTAssertTrue(
                app.navigationBars["收集箱"].waitForExistence(timeout: 5),
                "sidebar 收集箱选中后 content 列未显示收集箱"
            )
            return
        }
        let todayTab = app.tabBars.buttons["今日"]
        XCTAssertTrue(todayTab.waitForExistence(timeout: 5))
        todayTab.tap()
        let entry = app.descendants(matching: .any)["today-inbox-entry"]
        // v0.5.5 Step 7：今日首页常规字号为固定布局、无滚动容器，
        // 入口磁贴就在首屏；保留守卫兼容辅助字号备用布局。
        var attempts = 0
        while !entry.exists, attempts < 8 {
            let scroll = app.scrollContainerHosting(entry)
            if scroll.exists { app.swipeContainerUp(scroll) }
            attempts += 1
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["收集箱"].waitForExistence(timeout: 5))
    }

    /// v0.5.5：普通添加入口在牌组详情工具栏。
    /// regular：sidebar 牌组行 → content 列详情 → 「添加」。
    @MainActor
    private func openDeckAddFlow(in app: XCUIApplication, deckName: String) {
        popToPrimaryPageIfNeeded(in: app)
        app.openDeckAddFlow(deckName: deckName)
    }

    @MainActor
    private func captureText(_ text: String, in app: XCUIApplication) {
        let addButton = app.buttons["inbox-add-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        let editor = app.textViews["inbox-capture-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(text)
        let saveButton = app.buttons["inbox-capture-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()
        XCTAssertTrue(
            app.navigationBars["收集箱"].waitForExistence(timeout: 5)
        )
    }

    // MARK: - Shared-capture import (T20)

    @MainActor
    func testContinueInAppCaptureShowsTodayContinueEntry() throws {
        let queue = try makeQueueDirectory()
        try seedEnvelope(
            queue: queue,
            text: "共有されたメモです。",
            action: "continueInApp"
        )
        let app = launchApp(captureQueue: queue)

        // The cold-start drain imported the capture; the landing tab now
        // offers a passive continue entry (no auto-navigation, no AI).
        let entry = app.buttons["today-continue-capture-link"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let detailText = app.staticTexts["inbox-detail-text"]
        // regular：横幅入场动画期间首次点击可能被吞——detail 未
        // push 出来时重试一次（入口仍在原处）。
        if app.isRegularShell, !detailText.waitForExistence(timeout: 3),
           entry.exists, entry.isHittable {
            entry.tap()
        }
        XCTAssertTrue(detailText.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["共有されたメモです。"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["系统分享"].exists)
    }

    @MainActor
    func testAwaitingSharedCapturesRequireExplicitImport() throws {
        let queue = try makeQueueDirectory()
        try seedEnvelope(
            queue: queue,
            text: "復元前に共有されたテキスト。",
            action: "save"
        )
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_CAPTURE_QUEUE"] = queue.path
        // Fabricates the post-restore boundary: pending files are recorded
        // but not replayed until the user chooses.
        app.launchEnvironment["OBOE_UI_TEST_AWAITING_IMPORT"] = "1"
        app.launch()

        // The file must NOT have been auto-imported — entering the Inbox
        // shows the notice instead.
        openInbox(in: app)
        XCTAssertTrue(
            app.staticTexts["检测到 1 个尚未导入的分享内容"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.staticTexts["復元前に共有されたテキスト。"].exists)

        let importButton = app.buttons["inbox-import-pending-button"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        importButton.tap()
        XCTAssertTrue(
            app.staticTexts["復元前に共有されたテキスト。"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            app.staticTexts["检测到 1 个尚未导入的分享内容"].exists
        )
    }

    @MainActor
    func testExportScopeNoteListsPendingSharedCaptures() throws {
        let queue = try makeQueueDirectory()
        try seedEnvelope(
            queue: queue,
            text: "復元前に共有されたテキスト。",
            action: "save"
        )
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_CAPTURE_QUEUE"] = queue.path
        // Keeps the file pending — the export section must disclose that
        // queued shared captures live outside the backup.
        app.launchEnvironment["OBOE_UI_TEST_AWAITING_IMPORT"] = "1"
        app.launch()

        app.openSettingsFromTodayGear()

        let note = app.staticTexts["portable-backup-pending-share-note"]
        reveal(note, in: app)
        XCTAssertTrue(note.exists)
        XCTAssertTrue(note.label.contains("1 个尚未导入的共享内容"))
    }

    @MainActor
    private func launchApp(
        databaseID: String = UUID().uuidString,
        captureQueue: URL? = nil,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = databaseID
        if let captureQueue {
            app.launchEnvironment["OBOE_UI_TEST_CAPTURE_QUEUE"] = captureQueue.path
        }
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    private func makeQueueDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "UITestCaptureQueue-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("pending", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    /// Writes a CaptureEnvelope wire file (schemaVersion 1) — the same JSON
    /// contract the share extension publishes.
    private func seedEnvelope(
        queue: URL,
        text: String,
        action: String
    ) throws {
        let captureID = UUID().uuidString.lowercased()
        let object: [String: Any] = [
            "schemaVersion": 1,
            "captureID": captureID,
            "text": text,
            "createdAtMs": 1_789_000_000_000,
            "sourceType": "share",
            "requestedAction": action
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try data.write(
            to: queue
                .appendingPathComponent("pending", isDirectory: true)
                .appendingPathComponent("\(captureID).json")
        )
    }

    // MARK: - Image capture & OCR (T21/T23)

    @MainActor
    private func launchImageCaptureApp(
        imageFile: URL,
        ocrFails: Bool = false,
        ocrLong: Bool = false
    ) -> (XCUIApplication, URL) {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "UITestImageStore-\(UUID().uuidString)",
                isDirectory: true
            )
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = UUID().uuidString
        app.launchEnvironment["OBOE_UI_TEST_IMAGE_STORE"] = storeDir.path
        // Picks up this file directly — system pickers can't be driven.
        app.launchEnvironment["OBOE_UI_TEST_IMAGE_FILE"] = imageFile.path
        app.launchEnvironment["OBOE_UI_TEST_OCR_STUB"] = "1"
        if ocrFails {
            app.launchEnvironment["OBOE_UI_TEST_OCR_FAIL"] = "1"
        }
        if ocrLong {
            app.launchEnvironment["OBOE_UI_TEST_OCR_LONG"] = "1"
        }
        app.launch()
        return (app, storeDir)
    }

    /// Waits until a TextEditor's value reaches the expected text — merges
    /// and re-merges apply asynchronously after the toggle tap.
    private func waitForEditorValue(
        _ editor: XCUIElement,
        equals expected: String
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: editor
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    /// v0.5.5：图片收集入口迁入收集箱工具栏。
    @MainActor
    private func openImageCaptureSheet(in app: XCUIApplication) {
        openInbox(in: app)
        let entry = app.buttons["inbox-image-capture-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
    }

    @MainActor
    func testImageCaptureRunsOCRAndCancelCleansUnlinkedResource() throws {
        let (app, storeDir) = launchImageCaptureApp(imageFile: try makeTestPNG())
        openImageCaptureSheet(in: app)

        XCTAssertTrue(
            app.images["image-capture-preview"].waitForExistence(timeout: 5)
        )
        // OCR runs automatically on the stored preview (stubbed blocks).
        XCTAssertTrue(
            app.buttons["ocr-block-0"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["ocr-block-1"].exists)
        // The stored preview exists while the sheet is open.
        var stored = try FileManager.default.contentsOfDirectory(
            atPath: storeDir.path
        )
        XCTAssertEqual(stored.count, 1)

        app.buttons["image-capture-cancel-button"].tap()
        XCTAssertTrue(
            app.buttons["inbox-image-capture-entry"].waitForExistence(timeout: 5)
        )
        // Cancelling discards the unlinked resource — nothing is left behind.
        stored = try FileManager.default.contentsOfDirectory(
            atPath: storeDir.path
        )
        XCTAssertEqual(stored.count, 0)
    }

    @MainActor
    func testImageCaptureShowsHonestErrorForCorruptFile() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestCorrupt-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]).write(to: corrupt)
        let (app, _) = launchImageCaptureApp(imageFile: corrupt)
        openImageCaptureSheet(in: app)

        XCTAssertTrue(
            app.staticTexts["image-capture-error"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.images["image-capture-preview"].exists)
    }

    @MainActor
    func testOCRBlockSelectionEditAndSaveToInbox() throws {
        let (app, storeDir) = launchImageCaptureApp(imageFile: try makeTestPNG())
        openImageCaptureSheet(in: app)

        XCTAssertTrue(app.buttons["ocr-block-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ocr-block-1"].exists)
        // Low-confidence blocks are flagged with a visible footnote.
        XCTAssertTrue(
            app.staticTexts["带警示标记的块置信度较低，请核对后再保存。"]
                .exists
        )

        let editor = app.textViews["ocr-edited-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(
            editor.value as? String,
            "今日はいい天気です\n駅まで歩きます"
        )

        // Deselecting a block re-merges the text while it is still untouched.
        app.buttons["ocr-block-1"].tap()
        XCTAssertTrue(
            waitForEditorValue(editor, equals: "今日はいい天気です")
        )

        // Once the user types, the text is theirs — block toggles stop
        // rewriting it and only mark the selection dirty.
        editor.tap()
        editor.typeText("!")
        XCTAssertTrue(
            app.staticTexts["ocr-edited-badge"].waitForExistence(timeout: 5)
        )
        app.buttons["ocr-block-1"].tap()
        XCTAssertTrue(
            app.buttons["ocr-remerge-button"].waitForExistence(timeout: 5)
        )
        // Explicit re-merge applies the selection and discards the edit.
        app.buttons["ocr-remerge-button"].tap()
        XCTAssertTrue(
            waitForEditorValue(
                editor,
                equals: "今日はいい天気です\n駅まで歩きます"
            )
        )

        // regular：编辑器持有键盘焦点时首次 save tap 会被键盘/滚动
        // 事件吞掉——以 sheet 真正关闭（背景入口恢复可命中）为后置
        // 条件重试。
        let ocrSave = app.buttons["ocr-save-button"]
        XCTAssertTrue(ocrSave.waitForExistence(timeout: 5))
        let closed = app.tapUntil(ocrSave, retries: 5) {
            !ocrSave.exists
                && app.buttons["inbox-image-capture-entry"].isHittable
        }
        XCTAssertTrue(closed, "OCR 保存 sheet 未关闭")
        XCTAssertTrue(
            app.buttons["inbox-image-capture-entry"].waitForExistence(timeout: 5)
        )
        // The linked attachment survives — only unlinked resources are cleaned.
        let stored = try FileManager.default.contentsOfDirectory(
            atPath: storeDir.path
        )
        XCTAssertEqual(stored.count, 1)

        openInbox(in: app)
        let row = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "今日はいい天気です")
        ).firstMatch
        app.revealElement(row, requireHittable: true, passes: 8)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        // regular：详情在 detail 列，图片可能在折叠线下未挂载——
        // 按列显露后再断。
        let detailImage = app.images["inbox-detail-image"]
        app.revealElement(detailImage, requireHittable: false, passes: 6)
        XCTAssertTrue(
            detailImage.waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            waitForLabel(
                app.staticTexts["inbox-detail-source"],
                containing: "来自图片"
            )
        )
    }

    @MainActor
    func testOCROverLimitDisablesSaveWithoutTruncation() throws {
        let (app, _) = launchImageCaptureApp(
            imageFile: try makeTestPNG(),
            ocrLong: true
        )
        openImageCaptureSheet(in: app)

        XCTAssertTrue(app.buttons["ocr-block-0"].waitForExistence(timeout: 5))
        // The counter shows the full block length — proof the text was NOT
        // silently truncated to fit the limit.
        XCTAssertTrue(
            waitForLabel(
                app.staticTexts["ocr-char-count"],
                containing: "20,001/"
            )
        )
        // Over-limit text can never be saved — both paths stay disabled
        // until the user trims the text.
        XCTAssertTrue(
            app.staticTexts["ocr-over-limit"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.buttons["ocr-save-button"].isEnabled)
        XCTAssertFalse(app.buttons["ocr-save-process-button"].isEnabled)

        // Deselecting the block clears the merged text — the warning lifts
        // without the text having been cut down behind the user's back.
        app.buttons["ocr-block-0"].tap()
        XCTAssertTrue(
            waitForLabel(
                app.staticTexts["ocr-char-count"],
                containing: "0/"
            )
        )
        XCTAssertFalse(app.staticTexts["ocr-over-limit"].exists)
    }

    @MainActor
    func testOCRSaveAndProcessEntersUnifiedProcessing() throws {
        let (app, _) = launchImageCaptureApp(imageFile: try makeTestPNG())
        openImageCaptureSheet(in: app)

        XCTAssertTrue(app.buttons["ocr-block-0"].waitForExistence(timeout: 5))
        app.buttons["ocr-save-process-button"].tap()

        // The Inbox item is saved first, then the shared processing context
        // opens on it — the confirmed text is the captured source.
        let sourceText = app.staticTexts["capture-source-text"]
        XCTAssertTrue(sourceText.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(sourceText, containing: "今日はいい天気です"))
    }

    @MainActor
    func testOCRFailureAllowsManualInput() throws {
        let (app, _) = launchImageCaptureApp(
            imageFile: try makeTestPNG(),
            ocrFails: true
        )
        openImageCaptureSheet(in: app)

        XCTAssertTrue(app.staticTexts["ocr-issue"].waitForExistence(timeout: 5))
        let saveButton = app.buttons["ocr-save-button"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled)

        let editor = app.textViews["ocr-edited-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("手動入力テキスト")
        XCTAssertTrue(saveButton.isEnabled)
        // regular：sheet 内 tap 可能被滚动减速吞掉——以 sheet 关闭
        // （saveButton 消失）为后置条件重试。
        app.tapUntil(saveButton) { !saveButton.exists }

        openInbox(in: app)
        // 收集箱列表行可能未挂载（折叠线下）——按列显露后再断。
        let savedRow = app.staticTexts["手動入力テキスト"]
        app.revealElement(savedRow, requireHittable: false, passes: 8)
        XCTAssertTrue(savedRow.waitForExistence(timeout: 5))
    }

    /// A tiny valid PNG produced at runtime — no bundled fixture needed.
    private func makeTestPNG() throws -> URL {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let data = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestImage-\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }
}
