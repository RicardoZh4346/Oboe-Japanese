import XCTest

/// Step 12 设置页 AI 交互重做：模型目录获取/搜索/选择、
/// 「保存并测试」、测试通过前总开关禁用、供应商切换失效、
/// Key 保留与预设说明文案。
///
/// 模型目录走 `UITestStubbedModelCatalogClient`（`OBOE_UI_TEST_DATABASE_ID`
/// 已隐含该 stub），环境变量可模拟慢请求/失败/空态。
final class OboeSettingsAIUITests: XCTestCase {

    // MARK: - 模型获取 → 搜索 → 选择 → 保存并测试 → 启用

    @MainActor
    func testModelFetchSearchSelectSaveTestAndEnablePersists() {
        let databaseID = UUID().uuidString
        let app = launchApp(
            databaseID: databaseID,
            environment: ["OBOE_UI_TEST_AI_KEY": "1"]
        )
        openSettings(in: app)

        // req 9：未通过连接测试前总开关禁用，且有前置条件提示。
        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        XCTAssertEqual(aiToggle.value as? String, "0")
        XCTAssertFalse(aiToggle.isEnabled)
        XCTAssertTrue(
            app.staticTexts["ai-enable-gated-note"].exists
        )

        // 凭据已由 OBOE_UI_TEST_AI_KEY seam 预置（SecureField 存在性由
        // OboeNavigationUITests.testP17a 覆盖）。

        // req 8：未选模型时「保存并测试」禁用。
        let saveTest = app.buttons["ai-save-configuration-button"]
        revealExistence(saveTest, in: app)
        XCTAssertTrue(saveTest.exists)
        XCTAssertFalse(saveTest.isEnabled)

        // 打开模型二级页 → 获取模型。
        let modelRow = app.descendants(matching: .any)["ai-model-selection-link"]
        reveal(modelRow, in: app)
        modelRow.tap()
        XCTAssertTrue(
            app.navigationBars["选择模型"].waitForExistence(timeout: 5)
        )

        // 鉴权边界说明（req 11）。
        let privacyNote = app.staticTexts["ai-model-fetch-privacy-note"]
        revealExistence(privacyNote, in: app)
        XCTAssertTrue(privacyNote.exists)

        let fetch = app.buttons["ai-model-fetch-button"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        // 三个 stub 模型出现，含超长 ID（req 14：长 ID 不截断布局）。
        let optionA = app.buttons["ai-model-option-uitest-deepseek-model-a"]
        revealExistence(optionA, in: app)
        XCTAssertTrue(optionA.exists)
        XCTAssertTrue(
            app.buttons["ai-model-option-uitest-deepseek-model-b"].exists
        )
        let optionCLong = app.descendants(matching: .any)[
            "ai-model-option-uitest-deepseek-model-c-with-a-deliberately-long-identifier-for-layout"
        ]
        revealExistence(optionCLong, in: app)
        XCTAssertTrue(optionCLong.exists)

        // 搜索过滤：输入 model-b 后只剩 B。
        let search = app.searchFields["搜索模型 ID 或名称"]
        if !search.exists {
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("model-b")
        let optionB = app.buttons["ai-model-option-uitest-deepseek-model-b"]
        XCTAssertTrue(optionB.waitForExistence(timeout: 3))
        XCTAssertFalse(optionA.exists)
        optionB.tap()

        // 回到设置页：行内显示已选模型。
        XCTAssertTrue(
            app.navigationBars["设置"].waitForExistence(timeout: 5)
        )
        let selectedRow = app.descendants(matching: .any)["ai-model-selection-link"]
        revealExistence(selectedRow, in: app)
        XCTAssertTrue(selectedRow.label.contains("uitest-deepseek-model-b"))

        // 「保存并测试」→ 通过 → 状态提示可以开启。
        reveal(saveTest, in: app)
        XCTAssertTrue(saveTest.isEnabled)
        saveTest.tap()
        let status = app.staticTexts["ai-configuration-status"]
        revealExistence(status, in: app)
        XCTAssertTrue(
            waitForLabel(status, containing: "现在可以开启 AI", timeout: 10)
        )

        // req 9：测试通过后总开关解锁——点击会先弹隐私确认。
        reveal(aiToggle, in: app)
        XCTAssertTrue(aiToggle.isEnabled)
        aiToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .tap()
        let confirm = app.buttons["了解并启用"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertEqual(aiToggle.value as? String, "1")

        // 开启仍是草稿——再次「保存并测试」把 enabled 落库。
        revealExistence(saveTest, in: app)
        XCTAssertTrue(saveTest.isEnabled)
        saveTest.tap()
        revealExistence(status, in: app)
        XCTAssertTrue(
            waitForLabel(status, containing: "AI 已启用", timeout: 10)
        )

        // 持久化回归：重启后仍然启用、模型仍为 B、Key 仍配置。
        app.terminate()
        // 凭据存内存态 UITestAICredentialStore——重启需 seam 重新预置；
        // 该 seam 重存持久化草稿，不会改动已保存的启用态与模型。
        let relaunched = launchApp(
            databaseID: databaseID,
            environment: ["OBOE_UI_TEST_AI_KEY": "1"]
        )
        openSettings(in: relaunched)
        let aiToggle2 = relaunched.switches["ai-enabled-toggle"]
        reveal(aiToggle2, in: relaunched)
        XCTAssertEqual(aiToggle2.value as? String, "1")
        let modelRow2 = relaunched
            .descendants(matching: .any)["ai-model-selection-link"]
        revealExistence(modelRow2, in: relaunched)
        XCTAssertTrue(modelRow2.label.contains("uitest-deepseek-model-b"))
        let keyConfigured = relaunched
            .descendants(matching: .any)["ai-key-configured"]
        revealExistence(keyConfigured, in: relaunched)
        XCTAssertTrue(keyConfigured.exists)
    }

    // MARK: - 手动输 Key → 获取 → 选择（回归：SecureField 重挂载重放 set 不得清选择）

    @MainActor
    func testManualKeyEntryThenModelSelectSticks() {
        let app = launchApp() // 不预置 Key——走 SecureField 手动输入路径
        openSettings(in: app)

        let keyField = app.secureTextFields["ai-api-key-field"]
        revealExistence(keyField, in: app)
        keyField.tap()
        // 不收键盘——resign 会触发系统 AutoFill「保存密码？」表盖住二级页。
        keyField.typeText("sk-manual-test")

        openModelPicker(in: app)
        dismissSystemPasswordSavePrompt(in: app)
        let fetch = app.buttons["ai-model-fetch-button"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        let optionA = app.buttons["ai-model-option-uitest-deepseek-model-a"]
        XCTAssertTrue(optionA.waitForExistence(timeout: 10))
        optionA.tap()

        XCTAssertTrue(
            app.navigationBars["设置"].waitForExistence(timeout: 5),
            "点选模型后应回到设置页"
        )
        let selectedRow = app.descendants(matching: .any)["ai-model-selection-link"]
        revealExistence(selectedRow, in: app)
        XCTAssertTrue(
            selectedRow.label.contains("uitest-deepseek-model-a"),
            "点选后模型行仍显示：\(selectedRow.label)"
        )
    }

    // MARK: - 取消在途获取

    @MainActor
    func testModelFetchCancelReturnsToIdle() {
        let app = launchApp(
            environment: [
                "OBOE_UI_TEST_MODEL_CATALOG_DELAY": "30",
                "OBOE_UI_TEST_AI_KEY": "1",
            ]
        )
        openSettings(in: app)
        openModelPicker(in: app)

        let fetch = app.buttons["ai-model-fetch-button"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        let inProgress = app.descendants(matching: .any)["ai-model-fetch-in-progress"]
        XCTAssertTrue(inProgress.waitForExistence(timeout: 5))
        let cancel = app.buttons["ai-model-fetch-cancel-button"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()

        // 静默回落到可重试状态：按钮回来、无错误、无列表。
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["ai-model-fetch-error"].exists
        )
        XCTAssertFalse(
            app.buttons["ai-model-option-uitest-deepseek-model-a"].exists
        )
    }

    // MARK: - 失败 → 重试成功

    @MainActor
    func testModelFetchFailureShowsErrorAndRetrySucceeds() {
        let app = launchApp(
            environment: [
                "OBOE_UI_TEST_MODEL_CATALOG_FAIL_COUNT": "1",
                "OBOE_UI_TEST_AI_KEY": "1",
            ]
        )
        openSettings(in: app)
        openModelPicker(in: app)

        let fetch = app.buttons["ai-model-fetch-button"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        let error = app.descendants(matching: .any)["ai-model-fetch-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let retry = app.buttons["ai-model-fetch-retry-button"]
        XCTAssertTrue(retry.exists)
        retry.tap()

        // 第二次成功：错误消失、模型出现。
        let optionA = app.buttons["ai-model-option-uitest-deepseek-model-a"]
        XCTAssertTrue(optionA.waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
    }

    // MARK: - 空态

    @MainActor
    func testModelFetchEmptyListShowsError() {
        let app = launchApp(
            environment: [
                "OBOE_UI_TEST_MODEL_CATALOG_EMPTY": "1",
                "OBOE_UI_TEST_AI_KEY": "1",
            ]
        )
        openSettings(in: app)
        openModelPicker(in: app)

        let fetch = app.buttons["ai-model-fetch-button"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()

        let error = app.descendants(matching: .any)["ai-model-fetch-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["ai-model-option-uitest-deepseek-model-a"].exists
        )
    }

    // MARK: - 供应商变化清空模型与选择（req 6）

    @MainActor
    func testProviderChangeClearsModelsAndSelection() {
        let app = launchApp(
            environment: ["OBOE_UI_TEST_AI_KEY": "1"]
        )
        openSettings(in: app)
        openModelPicker(in: app)

        let fetch = app.buttons["ai-model-fetch-button"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        fetch.tap()
        let optionB = app.buttons["ai-model-option-uitest-deepseek-model-b"]
        XCTAssertTrue(optionB.waitForExistence(timeout: 5))
        optionB.tap()

        // 已选模型回到设置页，随后切换供应商。
        let selectedRow = app.descendants(matching: .any)["ai-model-selection-link"]
        revealExistence(selectedRow, in: app)
        XCTAssertTrue(selectedRow.label.contains("uitest-deepseek-model-b"))

        let picker = app.descendants(matching: .any)["ai-service-picker"]
        revealExistence(picker, in: app)
        picker.tap()
        let kimi = app.buttons["Kimi（Moonshot AI）"]
        XCTAssertTrue(kimi.waitForExistence(timeout: 3))
        kimi.tap()

        // req 6：模型与已选全部清空；Key 绑定变化，状态提示重新填写。
        revealExistence(selectedRow, in: app)
        XCTAssertTrue(selectedRow.label.contains("未选择"))
        let saveTest = app.buttons["ai-save-configuration-button"]
        revealExistence(saveTest, in: app)
        XCTAssertFalse(saveTest.isEnabled)

        // 重开模型页：无残留列表，且要求先填 Key（绑定已变）。
        openModelPicker(in: app)
        let prerequisite = app
            .descendants(matching: .any)["ai-model-fetch-prerequisite"]
        XCTAssertTrue(prerequisite.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["ai-model-option-uitest-deepseek-model-a"].exists
        )
    }

    // MARK: - 预设地址可编辑 / 自定义可编辑 / preset.note（req 2/3）

    @MainActor
    func testPresetURLEditableNotesAndCustomEditable() {
        let app = launchApp()
        openSettings(in: app)

        // 预设供应商地址可编辑——输入框预填官方地址。
        let urlField = app.textFields["ai-base-url-field"]
        revealExistence(urlField, in: app)
        XCTAssertTrue(urlField.exists)
        XCTAssertEqual(
            urlField.value as? String, "https://api.deepseek.com",
            "预设服务应预填官方地址，实为 \(urlField.value as? String ?? "nil")"
        )

        let picker = app.descendants(matching: .any)["ai-service-picker"]

        // req 3：Qwen 显示地域/专属域名说明，地址预填为官方域名。
        picker.tap()
        let qwen = app.buttons["Qwen（通义千问）"]
        XCTAssertTrue(qwen.waitForExistence(timeout: 3))
        qwen.tap()
        let providerNote = app.staticTexts["ai-provider-note"]
        revealExistence(providerNote, in: app)
        XCTAssertTrue(providerNote.exists)
        revealExistence(urlField, in: app)
        XCTAssertEqual(
            urlField.value as? String, "https://dashscope.aliyuncs.com"
        )

        // req 12：OpenAI 计费边界说明。
        picker.tap()
        let openAI = app.buttons["ChatGPT / OpenAI API"]
        XCTAssertTrue(openAI.waitForExistence(timeout: 3))
        openAI.tap()
        let billingNote = app.staticTexts["ai-openai-billing-note"]
        revealExistence(billingNote, in: app)
        XCTAssertTrue(billingNote.exists)
        XCTAssertFalse(app.staticTexts["ai-provider-note"].exists)

        // 自定义：名称与地址可编辑。
        picker.tap()
        let custom = app.buttons["自定义兼容服务"]
        XCTAssertTrue(custom.waitForExistence(timeout: 3))
        custom.tap()
        revealExistence(urlField, in: app)
        XCTAssertTrue(urlField.exists)
        XCTAssertTrue(
            app.textFields["ai-service-name-field"].exists
        )
    }

    // MARK: - 删除已保存 Key：居中的破坏性确认弹窗

    @MainActor
    func testRemoveAPIKeyShowsAlertAndDeletes() {
        let app = launchApp(
            environment: ["OBOE_UI_TEST_AI_KEY": "1"]
        )
        openSettings(in: app)

        let keyConfigured = app.descendants(matching: .any)["ai-key-configured"]
        revealExistence(keyConfigured, in: app)
        XCTAssertTrue(keyConfigured.exists)

        let remove = app.buttons["ai-remove-key-button"]
        reveal(remove, in: app)
        remove.tap()

        // 居中 alert（不是贴边 action sheet）；取消后 Key 仍在。
        let alert = app.alerts["删除本机保存的 API Key？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["取消"].tap()
        XCTAssertFalse(alert.exists)
        revealExistence(keyConfigured, in: app)
        XCTAssertTrue(keyConfigured.exists)

        // 确认删除：Key 标记消失、出现「尚未配置」状态。
        reveal(remove, in: app)
        remove.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["删除 API Key"].tap()
        let unconfigured = app.descendants(matching: .any)["ai-key-not-configured"]
        XCTAssertTrue(unconfigured.waitForExistence(timeout: 5))
    }

    // MARK: - 关闭 AI 不删除 Key（req 10）

    @MainActor
    func testDisablingAIKeepsKeyAndAllowsReEnable() {
        let app = launchApp(
            environment: ["OBOE_UI_TEST_AI_ENABLED": "1"]
        )
        openSettings(in: app)

        // seam 预置：已启用、模型 ui-test-model、Key 已配置。
        let aiToggle = app.switches["ai-enabled-toggle"]
        reveal(aiToggle, in: app)
        XCTAssertEqual(aiToggle.value as? String, "1")

        // 关闭 AI——不需要测试，且 Key 保留。
        setSwitch(aiToggle, enabled: false)
        let saveTest = app.buttons["ai-save-configuration-button"]
        reveal(saveTest, in: app)
        XCTAssertTrue(saveTest.isEnabled)
        saveTest.tap()

        let status = app.staticTexts["ai-configuration-status"]
        revealExistence(status, in: app)
        XCTAssertTrue(
            waitForLabel(status, containing: "现在可以开启 AI", timeout: 10)
        )
        let keyConfigured = app.descendants(matching: .any)["ai-key-configured"]
        revealExistence(keyConfigured, in: app)
        XCTAssertTrue(
            keyConfigured.exists,
            "关闭 AI 不得删除已保存的 API Key"
        )
    }

    // MARK: - 最大辅助字号下的可达性（req 14）

    @MainActor
    func testModelListAtAccessibilityTextSize() {
        let app = launchApp(
            environment: [
                "OBOE_UI_TEST_DYNAMIC_TYPE": "ax5",
                "OBOE_UI_TEST_AI_KEY": "1",
            ]
        )
        openSettings(in: app)
        openModelPicker(in: app)

        let fetch = app.buttons["ai-model-fetch-button"]
        reveal(fetch, in: app)
        XCTAssertTrue(fetch.exists)
        fetch.tap()

        // ax5 下「可选模型」区可能整体在折叠线以下——先滚动显露再点击。
        let optionA = app.buttons["ai-model-option-uitest-deepseek-model-a"]
        reveal(optionA, in: app)
        XCTAssertTrue(optionA.exists)
        optionA.tap()
        let selectedRow = app.descendants(matching: .any)["ai-model-selection-link"]
        revealExistence(selectedRow, in: app)
        XCTAssertTrue(selectedRow.label.contains("uitest-deepseek-model-a"))
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(
        databaseID: String = UUID().uuidString,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OBOE_UI_TEST_DATABASE_ID"] = databaseID
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()
    }

    @MainActor
    private func openModelPicker(in app: XCUIApplication) {
        let modelRow = app.descendants(matching: .any)["ai-model-selection-link"]
        reveal(modelRow, in: app)
        modelRow.tap()
        XCTAssertTrue(
            app.navigationBars["选择模型"].waitForExistence(timeout: 5)
        )
    }

    /// iOS 在 SecureField 失焦后可能弹系统「保存密码？」表（系统进程托管，
    /// 不出现在 app.sheets，但按钮在 app 层级内可查）。出现则点「以后」。
    @MainActor
    private func dismissSystemPasswordSavePrompt(in app: XCUIApplication) {
        let notNow = app.buttons["以后"]
        if notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            _ = notNow.waitForNonExistence(timeout: 3)
        }
    }

    /// List 懒挂载 + 视口边缘行可能已挂载但不可命中：粗扫定位，
    /// 一旦挂载就改用小幅拖拽把元素带进视口中心——避免全屏 swipe
    /// 把边缘行甩出去并卸载。
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<16 {
            if element.exists {
                if element.isHittable { return }
                nudgeIntoView(element, form: form)
            } else {
                form.swipeUp()
            }
        }
        for _ in 0..<16 {
            if element.exists {
                if element.isHittable { return }
                nudgeIntoView(element, form: form)
            } else {
                form.swipeDown()
            }
        }
    }

    /// 元素已挂载但贴边：向视口中心方向做 1/4 屏拖拽。
    @MainActor
    private func nudgeIntoView(
        _ element: XCUIElement,
        form: XCUIElement
    ) {
        let below = element.frame.midY > form.frame.midY
        let start = form.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: below ? 0.75 : 0.25)
        )
        let end = form.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// 目标可能永远不可命中（disabled 按钮等），只要求挂载进无障碍树。
    @MainActor
    private func revealExistence(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists {
                return
            }
            form.swipeUp()
        }
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
                element.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
                ).tap()
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
    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
