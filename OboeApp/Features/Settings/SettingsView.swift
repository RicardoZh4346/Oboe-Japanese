import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    /// 窄依赖包 + 运行期操作闭包：设置页不再持有全局 runtime 对象。
    let dependencies: SettingsFeatureDependencies
    let operations: AppRuntimeOperations
    let isDatabaseOperationInProgress: Bool
    let exporter: PortableBackupPackageExporter
    /// S11：preparer 仍由容器注入（统一协调器经工厂配置使用同一实例）。
    let studyService: StudySessionService
    let speechPreferencesService: SpeechPreferencesService
    let adaptivePreferencesService: AdaptivePreferencesService
    let aiConfigurationService: AIConfigurationService
    let aiConnectionTestService: AIConnectionTestService
    let aiModelCatalogService: AIModelCatalogService
    let speechService: any SpeechService
    let dictionaryQueryService: DictionaryQueryService
    /// regular detail 列的分类过滤：nil 渲染全部 section（compact 单
    /// List 行为不变）；非 nil 只渲染该分类。
    let categoryFilter: SettingsRoute?
    /// modal 呈现（compact sheet）时的关闭回调；nil 表示常驻页面，
    /// 不显示「完成」按钮。
    let dismissAction: (() -> Void)?

    init(
        dependencies: SettingsFeatureDependencies,
        operations: AppRuntimeOperations,
        isDatabaseOperationInProgress: Bool,
        categoryFilter: SettingsRoute? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.dependencies = dependencies
        self.operations = operations
        self.isDatabaseOperationInProgress = isDatabaseOperationInProgress
        self.categoryFilter = categoryFilter
        self.dismissAction = dismissAction
        exporter = dependencies.exporter
        studyService = dependencies.studyService
        speechPreferencesService = dependencies.speechPreferencesService
        adaptivePreferencesService = dependencies.adaptivePreferencesService
        aiConfigurationService = dependencies.aiConfigurationService
        aiConnectionTestService = dependencies.aiConnectionTestService
        aiModelCatalogService = dependencies.aiModelCatalogService
        speechService = dependencies.speechService
        dictionaryQueryService = dependencies.dictionaryQueryService
    }

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("portableBackup.lastSuccessfulExportAtMilliseconds")
    private var lastSuccessfulExportAtMilliseconds = 0.0
    @State private var isPreparingExport = false
    @State private var exportPresentation: ExportPresentation?
    /// S11：校验/预览/恢复改由 BackupImportCoordinator 统一驱动——
    /// 本页只投递文件；进行中状态读 operations 传入的 coordinator。
    @State private var isSelectingBackup = false
    @State private var localSnapshots: [DatabaseSnapshot] = []
    @State private var snapshotToRestore: DatabaseSnapshot?
    @State private var isLoadingSnapshots = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var appearancePreference = AppAppearance.system
    @State private var isSavingAppearance = false
    @State private var appearanceStatus: String?
    @State private var learningTimeZoneID = TimeZone.autoupdatingCurrent.identifier
    @State private var dailyNewCardLimit = 10
    @State private var retentionPreset = RetentionPreset.standard
    @State private var isLoadingLearningSettings = true
    @State private var isSavingLearningSettings = false
    @State private var learningSettingsStatus: String?
    @State private var speechPreferences = SpeechPreferences.defaults
    @State private var isLoadingSpeechPreferences = true
    @State private var isUpdatingSpeechPreferences = false
    @State private var adaptivePreferences = AdaptivePreferences.defaults
    @State private var isLoadingAdaptivePreferences = true
    @State private var isUpdatingAdaptivePreferences = false
    @State private var aiDraft = AIConfigurationDraft.deepSeekDefault
    @State private var loadedAIStatus: AIConfigurationStatus?
    @State private var apiKeyInput = ""
    @State private var isLoadingAIConfiguration = true
    @State private var isSavingAIConfiguration = false
    @State private var isTestingAIConnection = false
    @State private var connectionTestTask: Task<Void, Never>?
    /// 已拉取的模型列表（只存在于内存）；供应商/Key/地址变化即失效清空。
    @State private var fetchedModels: [AIModelDescriptor] = []
    @State private var isFetchingModels = false
    @State private var modelFetchError: String?
    @State private var modelFetchTask: Task<Void, Never>?
    /// 最近一次「保存并测试」通过时的草稿（isEnabled 归一化为 false）。
    /// 总开关只能在草稿与该状态一致时打开——测试成功是开启 AI 的前置条件。
    @State private var testedDraft: AIConfigurationDraft?
    @State private var showAIEnablePrivacyConfirmation = false
    @State private var showRemoveAPIKeyConfirmation = false
    @State private var aiStatusMessage: String?
    /// Share files still sitting in the pending queue — they live outside the
    /// database, so the export scope note must say they are not included.
    @State private var pendingSharedCaptureCount: Int?

    /// regular detail 列的 section 门控：filter 为 nil（compact）时
    /// 全部渲染，否则只渲染目标分类。
    private func shows(_ category: SettingsRoute) -> Bool {
        categoryFilter == nil || categoryFilter == category
    }

    var body: some View {
        NavigationStack {
            List {
                if shows(.appearance) {
                Section("外观") {
                    Picker("显示模式", selection: $appearancePreference) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.settingsDisplayName).tag(appearance)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isSavingAppearance)
                    .accessibilityIdentifier("appearance-picker")
                    .onChange(of: appearancePreference) { previous, current in
                        guard previous != current else { return }
                        saveAppearance(current)
                    }
                    if let appearanceStatus {
                        Text(appearanceStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("appearance-status")
                    }
                }
                }

                if shows(.learning) {
                learningSettingsSection
                }

                if shows(.speech) {
                Section("发音") {
                    Toggle(
                        "自动播放单词",
                        isOn: Binding(
                            get: { speechPreferences.autoPlayWordAudio },
                            set: { isEnabled in updateAutoPlayWordAudio(isEnabled) }
                        )
                    )
                    .disabled(isLoadingSpeechPreferences || isUpdatingSpeechPreferences)
                    .accessibilityIdentifier("speech-auto-play-word-toggle")

                    Toggle(
                        "自动播放例句",
                        isOn: Binding(
                            get: { speechPreferences.autoPlayExampleAudio },
                            set: { isEnabled in updateAutoPlayExampleAudio(isEnabled) }
                        )
                    )
                    .disabled(isLoadingSpeechPreferences || isUpdatingSpeechPreferences)
                    .accessibilityIdentifier("speech-auto-play-example-toggle")

                    Toggle(
                        "听力卡自动播放",
                        isOn: Binding(
                            get: { adaptivePreferences.autoPlayListeningAudio },
                            set: { updateAutoPlayListeningAudio($0) }
                        )
                    )
                    .disabled(isLoadingAdaptivePreferences || isUpdatingAdaptivePreferences)
                    .accessibilityIdentifier("adaptive-autoplay-listening-toggle")

                    Text("默认开启。听力卡出题时自动播放一次音频；关闭后仍可手动播放。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("adaptive-autoplay-listening-note")

                    switch speechService.availability {
                    case let .available(voiceName):
                        Label("日语语音可用：\(voiceName)", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("speech-voice-available")
                    case .unavailable:
                        Label("未发现可用的日语语音", systemImage: "speaker.slash")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("speech-voice-unavailable")
                        Text("可前往系统设置 → 辅助功能 → 朗读内容 → 声音，下载日语声音。没有语音时仍可继续学习。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text("使用设备上的系统日语语音；它不是标准重音词典或真人录音。默认不自动播放。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("speech-offline-note")
                }
                }

                if shows(.adaptive) {
                Section("主动回忆") {
                    Toggle(
                        "中文→日文输入",
                        isOn: Binding(
                            get: { adaptivePreferences.typedAnswerChineseToJapanese },
                            set: { updateTypedAnswerChineseToJapanese($0) }
                        )
                    )
                    .disabled(isLoadingAdaptivePreferences || isUpdatingAdaptivePreferences)
                    .accessibilityIdentifier("adaptive-typed-answer-zh-ja-toggle")

                    Text("默认开启。中文→日文卡需先输入回答再查看答案；从下一张卡开始生效，评分仍由你选择。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("adaptive-typed-answer-zh-ja-note")

                    Toggle(
                        "听力卡输入",
                        isOn: Binding(
                            get: { adaptivePreferences.typedAnswerListening },
                            set: { updateTypedAnswerListening($0) }
                        )
                    )
                    .disabled(isLoadingAdaptivePreferences || isUpdatingAdaptivePreferences)
                    .accessibilityIdentifier("adaptive-typed-answer-listening-toggle")

                    Text("默认开启。听力卡需先用日语复述听到的内容再查看答案；从下一张卡开始生效，评分仍由你选择。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("adaptive-typed-answer-listening-note")
                }

                Section("易错卡") {
                    Toggle(
                        "复习提醒",
                        isOn: Binding(
                            get: { adaptivePreferences.leechRemindersEnabled },
                            set: { isEnabled in updateLeechReminders(isEnabled) }
                        )
                    )
                    .disabled(isLoadingAdaptivePreferences || isUpdatingAdaptivePreferences)
                    .accessibilityIdentifier("adaptive-leech-reminders-toggle")

                    Text("开启后：首页显示“需要关注”入口，答案页对近期经常遗忘的卡片显示轻提示；问题页不做任何提示。关闭不影响易错判定与列表。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("adaptive-leech-reminders-note")
                }
                }

                if shows(.ai) {
                aiSettingsSection
                }

                if shows(.backup) {
                Section("数据管理") {
                    Button {
                        prepareExport()
                    } label: {
                        Label(
                            isPreparingExport ? "正在准备备份…" : "导出全部学习数据",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("portable-backup-export-button")

                    if isPreparingExport {
                        ProgressView()
                            .accessibilityLabel("正在创建一致性备份")
                    }

                    LabeledContent("最近导出") {
                        Text(lastExportDescription)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("portable-backup-last-export")
                    }

                    Text("备份包含学习内容、草稿、卡片进度和历史记录，文件未加密。请保存到可信位置。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-privacy-note")

                    Text("AI 服务连接与凭据不会写入备份；收集箱图片附件随备份一并打包迁移。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-scope-note")

                    if let pendingSharedCaptureCount, pendingSharedCaptureCount > 0 {
                        Text("还有 \(pendingSharedCaptureCount) 个尚未导入的共享内容，不会包含在本次备份中。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("portable-backup-pending-share-note")
                    }

                    Button {
                        isSelectingBackup = true
                    } label: {
                        Label("检查备份并预览", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("portable-backup-prepare-button")



                    Text("选择文件会先在临时区校验并预览；只有再次明确确认后才会完整替换当前资料库。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-preview-scope-note")
                }

                Section("本机快照") {
                    Button {
                        createLocalSnapshot()
                    } label: {
                        Label("立即创建本机快照", systemImage: "externaldrive.badge.plus")
                    }
                    .disabled(isBusy || isLoadingSnapshots)
                    .accessibilityIdentifier("local-snapshot-create-button")

                    if isLoadingSnapshots {
                        ProgressView("正在读取快照…")
                    } else if localSnapshots.isEmpty {
                        Text("还没有可恢复的本机快照。")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("local-snapshot-empty")
                    } else {
                        ForEach(localSnapshots, id: \.url) { snapshot in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshotReason(snapshot.reason))
                                    Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("恢复") {
                                    snapshotToRestore = snapshot
                                }
                                .buttonStyle(.bordered)
                                .disabled(isBusy)
                                .accessibilityIdentifier("local-snapshot-restore-button")
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("本机快照每日最多创建一份并保留最近 3 份；它们与 App 位于同一设备，不能防止卸载或设备丢失。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("local-snapshot-scope-note")
                }
                }

                if shows(.about) {
                Section("关于") {
                    NavigationLink {
                        AboutOboeView(dictionaryQueryService: dictionaryQueryService)
                    } label: {
                        Label("关于 Oboe", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("about-navigation-link")
                }
                }

            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(categoryFilter?.title ?? "设置")
            .toolbar {
                if let dismissAction {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismissAction() }
                            .accessibilityIdentifier("settings-done-button")
                    }
                }
            }
            .sheet(item: $exportPresentation) { presentation in
                // S11：导出交系统 Share Sheet（含 AirDrop）；sheet
                // 关闭回调即导出 lease 释放点，存活期间不删文件。
                ShareSheet(activityItems: [presentation.url]) { didExport in
                    exportPresentation = nil
                    if didExport {
                        lastSuccessfulExportAtMilliseconds = Date().timeIntervalSince1970 * 1_000
                    }
                    refreshPendingSharedCaptures()
                    Task {
                        try? await exporter.removeExport(at: presentation.url)
                    }
                }
            }
            .fileImporter(
                isPresented: $isSelectingBackup,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    if let url = urls.first {
                        // S11：与 AirDrop/外部 URL 同一安全链路。
                        operations.submitBackupFile(url)
                    }
                case let .failure(error):
                    if !(error is CancellationError) {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .alert(
                "操作失败",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .alert(
                "恢复本机快照？",
                isPresented: Binding(
                    get: { snapshotToRestore != nil },
                    set: { shown in if !shown { snapshotToRestore = nil } }
                ),
                presenting: snapshotToRestore
            ) { snapshot in
                Button("完整替换并恢复", role: .destructive) {
                    restoreLocalSnapshot(snapshot)
                }
                Button("取消", role: .cancel) {}
            } message: { snapshot in
                Text("当前资料库会先生成回滚快照，再替换为 \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)) 的内容。")
            }
            .task {
                appearancePreference = operations.currentAppearancePreference()
                refreshPendingSharedCaptures()
                await loadLearningSettings()
                await loadSpeechPreferences()
                await loadAdaptivePreferences()
                await loadAIConfiguration()
                await loadLocalSnapshots()
            }
            .onDisappear {
                connectionTestTask?.cancel()
                modelFetchTask?.cancel()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else {
                    connectionTestTask?.cancel()
                    modelFetchTask?.cancel()
                    return
                }
                refreshPendingSharedCaptures()
            }
            .onChange(of: isDatabaseOperationInProgress) { _, busy in
                // S11：统一导入协调器完成安全替换（或本页快照恢复）后
                // 刷新本页收尾状态。
                if !busy {
                    Task { await finishRestorationCleanup() }
                }
            }
            .alert("启用 AI 功能？", isPresented: $showAIEnablePrivacyConfirmation) {
                Button("取消", role: .cancel) {}
                Button("了解并启用") {
                    aiDraft.isEnabled = true
                }
            } message: {
                Text("之后使用 AI 功能时，当前输入和你选择的语境会发送到所配置的服务。Oboe 不会上传整个牌组或学习历史。")
            }
            .alert(
                "删除本机保存的 API Key？",
                isPresented: $showRemoveAPIKeyConfirmation
            ) {
                Button("删除 API Key", role: .destructive) {
                    removeAPIKey()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除后 AI 会同时关闭；离线学习不受影响。")
            }
        }
    }

    private var learningSettingsSection: some View {
        Section("学习计划") {
            Stepper(value: $dailyNewCardLimit, in: 0...999) {
                LabeledContent("每日新词", value: "\(dailyNewCardLimit) 个")
            }
            .disabled(isLoadingLearningSettings || isSavingLearningSettings)
            .accessibilityIdentifier("learning-daily-new-limit-stepper")

            Picker("复习目标强度", selection: $retentionPreset) {
                ForEach(RetentionPreset.allCases, id: \.self) { preset in
                    Text(preset.settingsDisplayName).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .disabled(isLoadingLearningSettings || isSavingLearningSettings)
            .accessibilityIdentifier("learning-retention-picker")

            Picker("学习时区", selection: $learningTimeZoneID) {
                ForEach(learningTimeZoneOptions, id: \.self) { identifier in
                    Text(identifier).tag(identifier)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(isLoadingLearningSettings || isSavingLearningSettings)
            .accessibilityIdentifier("learning-time-zone-picker")

            LabeledContent(
                "调度配置版本",
                value: SchedulerProfile(preset: retentionPreset).configurationVersion
            )
            .accessibilityIdentifier("learning-configuration-version")

            Button {
                saveLearningSettings()
            } label: {
                if isSavingLearningSettings {
                    ProgressView()
                } else {
                    Label("保存学习设置", systemImage: "calendar.badge.checkmark")
                }
            }
            .disabled(isLoadingLearningSettings || isSavingLearningSettings)
            .accessibilityIdentifier("learning-settings-save-button")

            Text("每日额度会立即刷新当前学习日；调整目标强度只影响之后的评分，不改写现有到期时间；学习时区从下一个学习日生效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("learning-settings-effect-note")
            Text("学习计划与发音偏好会随学习数据备份；AI 连接和 API Key 不进入备份。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("learning-settings-backup-note")
            if let learningSettingsStatus {
                Text(learningSettingsStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("learning-settings-status")
            }
        }
    }

    private var learningTimeZoneOptions: [String] {
        var options = TimeZone.knownTimeZoneIdentifiers
        if !options.contains(learningTimeZoneID) {
            options.append(learningTimeZoneID)
        }
        return options.sorted()
    }

    private var lastExportDescription: String {
        guard lastSuccessfulExportAtMilliseconds > 0 else {
            return "尚未导出"
        }
        return Date(timeIntervalSince1970: lastSuccessfulExportAtMilliseconds / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func saveAppearance(_ appearance: AppAppearance) {
        guard !isSavingAppearance else { return }
        isSavingAppearance = true
        appearanceStatus = nil
        Task {
            do {
                try await operations.setAppearancePreference(appearance)
                appearanceStatus = "显示模式已保存并立即应用。"
            } catch {
                appearancePreference = operations.currentAppearancePreference()
                errorMessage = "无法保存显示模式：\(error.localizedDescription)"
            }
            isSavingAppearance = false
        }
    }

    @ViewBuilder
    private var aiSettingsSection: some View {
        Section("AI 服务") {
            aiEnabledToggle
            aiServicePicker
            aiEndpointFields
            aiModelSelectionRow
            aiCapabilityFields
            aiCredentialFields
            aiConfigurationActions
            aiPrivacyNotes
        }
    }

    @ViewBuilder
    private var aiEnabledToggle: some View {
        Toggle(
            "启用 AI 功能",
            isOn: Binding(
                get: { aiDraft.isEnabled },
                set: { isEnabled in
                    if isEnabled, !aiDraft.isEnabled {
                        showAIEnablePrivacyConfirmation = true
                    } else if !isEnabled {
                        aiDraft.isEnabled = false
                    }
                }
            )
        )
        .disabled(aiEnableToggleDisabled)
        .accessibilityIdentifier("ai-enabled-toggle")

        if aiEnableGateHintVisible {
            Text("开启前需要选择模型并通过「保存并测试」验证连接。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai-enable-gated-note")
        }
    }

    private var aiServicePicker: some View {
        Picker(
            "服务",
            selection: Binding(
                get: { aiDraft.serviceKind },
                set: { kind in updateAIPreset(to: kind) }
            )
        ) {
            ForEach(AIServiceKind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-service-picker")
    }

    @ViewBuilder
    private var aiEndpointFields: some View {
        if aiDraft.serviceKind == .custom {
            TextField("服务名称", text: $aiDraft.serviceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
                .accessibilityIdentifier("ai-service-name-field")
            aiBaseURLField(title: "https://example.com/v1")
        } else {
            // 预设服务预填官方地址但可改（代理/网关场景）；
            // 改动地址会失效已选模型与已测状态，域名变化需重填 Key。
            aiBaseURLField(title: "服务地址")
        }

        if let providerNote = AIProviderPresetRegistry.preset(for: aiDraft.serviceKind)?.note {
            Text(providerNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai-provider-note")
        }
        if aiDraft.serviceKind == .openAI {
            Text("ChatGPT 订阅不包含 OpenAI API 额度；使用 API 需要在 OpenAI 开发者平台单独充值。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai-openai-billing-note")
        }
    }

    /// 服务地址输入框（所有服务可编辑）。仅在文本真正变化时才失效
    /// 已选模型——SwiftUI 的输入框在二次挂载时可能重放 `set("")`，
    /// 无守卫会把刚从模型页带回的选择清空。
    private func aiBaseURLField(title: String) -> some View {
        TextField(
            title,
            text: Binding(
                get: { aiDraft.baseURL },
                set: { newValue in
                    guard newValue != aiDraft.baseURL else { return }
                    aiDraft.baseURL = newValue
                    invalidateAIModelSelection()
                }
            )
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-base-url-field")
    }

    /// 模型选择入口：已选显示 modelID，未选显示「未选择」；
    /// 列表与搜索在二级页完成（长 ID 与最大字号更容易排版）。
    private var aiModelSelectionRow: some View {
        NavigationLink {
            AIModelPickerView(
                serviceName: aiDraft.serviceName.isEmpty
                    ? aiDraft.serviceKind.displayName
                    : aiDraft.serviceName,
                models: fetchedModels,
                isFetching: isFetchingModels,
                errorMessage: modelFetchError,
                prerequisiteMessage: modelFetchPrerequisiteMessage,
                selectedModelID: aiDraft.modelID,
                onFetch: fetchAIModels,
                onCancel: { modelFetchTask?.cancel() },
                onSelect: { model in aiDraft.modelID = model.id }
            )
        } label: {
            LabeledContent("模型") {
                Text(aiDraft.modelID ?? "未选择")
                    .foregroundStyle(
                        aiDraft.modelID == nil ? Color.secondary : Color.primary
                    )
            }
        }
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-model-selection-link")
    }

    @ViewBuilder
    private var aiCapabilityFields: some View {
        // 候选按供应商能力集过滤；DeepSeek 固定 JSON Object（产品决策），
        // 能力集只有单一模式的供应商（Claude/Gemini 仅提示词 JSON）也
        // 直接显示固定值——预设供应商的模式本就被 validator 强制。
        let modes = aiSelectableResponseFormatModes
        if aiDraft.serviceKind == .deepSeek || modes.count == 1 {
            LabeledContent(
                "结构化输出",
                value: aiFixedResponseFormatMode(modes).displayName
            )
            .accessibilityIdentifier("ai-response-format-fixed")
        } else {
            Picker("结构化输出", selection: $aiDraft.responseFormatMode) {
                ForEach(modes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
            .accessibilityIdentifier("ai-response-format-picker")
        }
    }

    /// 当前供应商可选的结构化输出模式：能力集按 allCases 声明顺序过滤。
    private var aiSelectableResponseFormatModes: [AIResponseFormatMode] {
        let supported = AIProviderPresetRegistry
            .capabilities(for: aiDraft.serviceKind)
            .supportedOutputModes
        return AIResponseFormatMode.allCases.filter { supported.contains($0) }
    }

    /// 固定展示时的模式：预设取注册表强制值，否则取唯一可选项/草稿值。
    private func aiFixedResponseFormatMode(
        _ modes: [AIResponseFormatMode]
    ) -> AIResponseFormatMode {
        AIProviderPresetRegistry.preset(for: aiDraft.serviceKind)?.responseFormatMode
            ?? modes.first
            ?? aiDraft.responseFormatMode
    }

    @ViewBuilder
    private var aiCredentialFields: some View {
        SecureField(
            hasAPIKeyForDraft ? "留空以保留已保存的 Key" : "API Key",
            text: Binding(
                get: { apiKeyInput },
                set: { newValue in
                    // 仅真实编辑才失效已选模型——字段在二级页返回重新挂载时
                    // 可能重放一次 `set`（值为当前文本），不能据此清空选择。
                    guard newValue != apiKeyInput else { return }
                    apiKeyInput = newValue
                    invalidateAIModelSelection()
                }
            )
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .privacySensitive()
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-api-key-field")

        Label(
            apiKeyStatusText,
            systemImage: hasAPIKeyForDraft ? "checkmark.shield" : "key.slash"
        )
        .foregroundStyle(hasAPIKeyForDraft ? Color.secondary : Color.orange)
        .accessibilityIdentifier(
            hasAPIKeyForDraft ? "ai-key-configured" : "ai-key-not-configured"
        )
    }

    @ViewBuilder
    private var aiConfigurationActions: some View {
        if isSavingAIConfiguration || isTestingAIConnection {
            HStack {
                ProgressView()
                Text(isTestingAIConnection ? "正在测试连接…" : "正在保存配置…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) {
                    connectionTestTask?.cancel()
                }
                .accessibilityIdentifier("ai-cancel-connection-test-button")
            }
            .accessibilityIdentifier("ai-save-test-in-progress")
        } else {
            Button {
                saveAIConfigurationAndTest()
            } label: {
                Label("保存并测试", systemImage: "checkmark.circle")
            }
            .disabled(!canSaveAndTestAIConfiguration)
            .accessibilityIdentifier("ai-save-configuration-button")
        }

        if hasUnsavedAIChanges {
            Text("有未保存的更改——点「保存并测试」保存并验证连接。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai-unsaved-changes-note")
        }

        if loadedAIStatus?.hasAPIKey == true {
            Button("删除已保存的 API Key", role: .destructive) {
                showRemoveAPIKeyConfirmation = true
            }
            .disabled(isSavingAIConfiguration || isTestingAIConnection)
            .accessibilityIdentifier("ai-remove-key-button")
        }
    }

    @ViewBuilder
    private var aiPrivacyNotes: some View {
        Text("API Key 仅保存在本机钥匙串，解锁后可用且不迁移到其他设备；应用不会回显完整 Key，也不会将它写入资料库、备份或日志。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-key-privacy-note")
        Text("使用 AI 时，只会把当前输入和你选择的语境发送到上方服务，不会上传整个牌组或学习历史。自定义服务仅接受 HTTPS；更换服务或域名后必须重新填写 Key。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-request-privacy-note")
        Text("「获取模型」会把 API Key 发送给所选服务做鉴权，仅用于列出可选模型；不会发送学习内容。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-model-fetch-note")
        Text("「保存并测试」保存配置后立即发送最小 JSON 请求验证连接，可能产生少量 API 用量；不会自动重试。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-connection-cost-note")
        if let aiStatusMessage {
            Text(aiStatusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai-configuration-status")
        }
    }

    private var isBusy: Bool {
        isPreparingExport
            || exportPresentation != nil
            || isSelectingBackup
            || isDatabaseOperationInProgress
    }

    private func loadLearningSettings() async {
        isLoadingLearningSettings = true
        do {
            let settings = try await studyService.loadLearningSettings(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            learningTimeZoneID = settings.learningTimeZoneID
            dailyNewCardLimit = settings.dailyNewCardLimit
            retentionPreset = settings.retentionPreset
        } catch {
            errorMessage = "无法读取学习设置：\(error.localizedDescription)"
        }
        isLoadingLearningSettings = false
    }

    private func saveLearningSettings() {
        guard !isLoadingLearningSettings, !isSavingLearningSettings else { return }
        isSavingLearningSettings = true
        learningSettingsStatus = nil
        errorMessage = nil
        Task {
            do {
                let defaultTimeZoneID = TimeZone.autoupdatingCurrent.identifier
                _ = try await studyService.setLearningTimeZone(
                    learningTimeZoneID,
                    defaultTimeZoneID: defaultTimeZoneID
                )
                _ = try await studyService.setRetentionPreset(
                    retentionPreset,
                    defaultTimeZoneID: defaultTimeZoneID
                )
                _ = try await studyService.setDailyNewCardLimit(
                    dailyNewCardLimit,
                    defaultTimeZoneID: defaultTimeZoneID
                )
                let settings = try await studyService.loadLearningSettings(
                    defaultTimeZoneID: defaultTimeZoneID
                )
                learningTimeZoneID = settings.learningTimeZoneID
                dailyNewCardLimit = settings.dailyNewCardLimit
                retentionPreset = settings.retentionPreset
                learningSettingsStatus = "学习设置已保存。"
            } catch {
                errorMessage = "无法保存学习设置：\(error.localizedDescription)"
                await loadLearningSettings()
            }
            isSavingLearningSettings = false
        }
    }

    private var hasAPIKeyForDraft: Bool {
        guard let loadedAIStatus, loadedAIStatus.hasAPIKey,
              let candidate = try? AIConfigurationValidator.validate(
                aiDraft,
                credentialID: loadedAIStatus.configuration.credentialReference.id
              ) else {
            return false
        }
        return candidate.serviceKind == loadedAIStatus.configuration.serviceKind
            && candidate.credentialAuthority == loadedAIStatus.configuration.credentialAuthority
    }

    private var apiKeyStatusText: String {
        if hasAPIKeyForDraft { return "当前服务已配置 API Key" }
        if loadedAIStatus?.hasAPIKey == true { return "服务或域名已更改，需要重新填写 API Key" }
        return "当前服务尚未配置 API Key"
    }

    /// 已持久化配置对应的草稿（isEnabled 归一化为 false）——
    /// 「已启用且未改动」判定的比较基准。
    private var persistedDraftNormalized: AIConfigurationDraft? {
        guard let loadedAIStatus else { return nil }
        var draft = AIConfigurationDraft(configuration: loadedAIStatus.configuration)
        draft.isEnabled = false
        return draft
    }

    /// 当前草稿是否允许开启 AI：本会话内已通过连接测试的同一草稿，
    /// 或本来就处于启用状态且未被改动的持久化配置。Key 输入框有
    /// 未保存的新 Key 时一律要求重新「保存并测试」。
    private var canEnableAIDraft: Bool {
        guard apiKeyInput.isEmpty else { return false }
        var normalized = aiDraft
        normalized.isEnabled = false
        if normalized == testedDraft {
            return true
        }
        if loadedAIStatus?.configuration.isEnabled == true,
           normalized == persistedDraftNormalized {
            return true
        }
        return false
    }

    private var aiEnableToggleDisabled: Bool {
        isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection
            || (!aiDraft.isEnabled && !canEnableAIDraft)
    }

    private var aiEnableGateHintVisible: Bool {
        !isLoadingAIConfiguration && !aiDraft.isEnabled && !canEnableAIDraft
    }

    /// 「保存并测试」前置条件：已选模型、有可用 Key（已保存或已填写）、
    /// 草稿能通过校验（自定义服务地址等），且没有进行中的 AI 任务。
    private var canSaveAndTestAIConfiguration: Bool {
        guard !isLoadingAIConfiguration, !isSavingAIConfiguration,
              !isTestingAIConnection, !isFetchingModels,
              aiDraft.modelID?.isEmpty == false,
              hasAPIKeyForDraft
                  || !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let credentialID = loadedAIStatus?.configuration.credentialReference.id,
              (try? AIConfigurationValidator.validate(
                  aiDraft,
                  credentialID: credentialID
              )) != nil else {
            return false
        }
        return true
    }

    /// 草稿（含 Key 输入）与持久化配置是否有差异——用于提示
    /// 「保存并测试」才会生效。
    private var hasUnsavedAIChanges: Bool {
        guard !isLoadingAIConfiguration,
              let loadedAIStatus,
              let candidate = try? AIConfigurationValidator.validate(
                  aiDraft,
                  credentialID: loadedAIStatus.configuration.credentialReference.id
              ) else {
            return false
        }
        return candidate != loadedAIStatus.configuration || !apiKeyInput.isEmpty
    }

    /// 「获取模型」前置条件的可解释文案；nil 表示可以获取。
    private var modelFetchPrerequisiteMessage: String? {
        if isLoadingAIConfiguration {
            return "正在读取 AI 配置…"
        }
        if isSavingAIConfiguration || isTestingAIConnection {
            return "正在保存并测试配置…"
        }
        guard hasAPIKeyForDraft
                || !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "请先填写 API Key——获取模型需要用它做鉴权。"
        }
        guard let credentialID = loadedAIStatus?.configuration.credentialReference.id,
              (try? AIConfigurationValidator.validate(
                  aiDraft,
                  credentialID: credentialID
              )) != nil else {
            return "请先完善服务配置（自定义服务需要有效的 HTTPS 地址与名称）。"
        }
        return nil
    }

    private var canFetchAIModels: Bool {
        modelFetchPrerequisiteMessage == nil && !isFetchingModels
    }

    /// 供应商/Key/地址变化：在途请求作废、清空已拉取列表与已选模型，
    /// 并取消测试通过状态——之后必须重新获取模型并「保存并测试」。
    private func invalidateAIModelSelection() {
        modelFetchTask?.cancel()
        modelFetchTask = nil
        isFetchingModels = false
        fetchedModels = []
        modelFetchError = nil
        aiDraft.modelID = nil
        testedDraft = nil
        if aiDraft.isEnabled {
            aiDraft.isEnabled = false
        }
        Task {
            await aiModelCatalogService.invalidatePendingFetches()
        }
    }

    private func loadAIConfiguration() async {
        // `.task` 在二级页（模型选择等）pop 返回时会重跑——已加载过就跳过，
        // 否则重建草稿会把刚选的模型/拉取的列表/测试通过状态全部抹掉。
        guard loadedAIStatus == nil else { return }
        isLoadingAIConfiguration = true
        do {
            let status = try await aiConfigurationService.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            loadedAIStatus = status
            aiDraft = AIConfigurationDraft(configuration: status.configuration)
            apiKeyInput = ""
            fetchedModels = []
            modelFetchError = nil
            testedDraft = nil
        } catch {
            errorMessage = "无法读取 AI 配置：\(error.localizedDescription)"
        }
        isLoadingAIConfiguration = false
    }

    private func updateAIPreset(to kind: AIServiceKind) {
        guard kind != aiDraft.serviceKind else { return }
        aiDraft.serviceKind = kind
        if let preset = AIProviderPresetRegistry.preset(for: kind) {
            aiDraft.serviceName = preset.displayName
            aiDraft.baseURL = preset.baseURL
            aiDraft.responseFormatMode = preset.responseFormatMode
        } else {
            aiDraft.serviceName = ""
            aiDraft.baseURL = "https://"
            aiDraft.responseFormatMode = .jsonObject
        }
        apiKeyInput = ""
        invalidateAIModelSelection()
    }

    /// 「获取模型」：先把当前草稿与 Key 落库（模型目录服务只读取
    /// 已持久化配置与凭据），再拉取可选模型列表。
    private func fetchAIModels() {
        guard canFetchAIModels else { return }
        isFetchingModels = true
        modelFetchError = nil
        modelFetchTask = Task {
            defer {
                isFetchingModels = false
                modelFetchTask = nil
            }
            do {
                // 未选模型时不能持久化 enabled——按关闭态保存。
                var draftToSave = aiDraft
                if draftToSave.modelID == nil {
                    draftToSave.isEnabled = false
                }
                let status = try await aiConfigurationService.save(
                    draftToSave,
                    apiKey: apiKeyInput,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                loadedAIStatus = status
                apiKeyInput = ""
                aiDraft = AIConfigurationDraft(configuration: status.configuration)
                let models = try await aiModelCatalogService.fetchModels(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                fetchedModels = models
            } catch let error as AIModelCatalogError
            where error == .cancelled || error == .requestSuperseded {
                // 用户取消或配置在请求途中又变化——静默回到可重试状态。
            } catch is CancellationError {
            } catch {
                modelFetchError = error.localizedDescription
            }
        }
    }

    /// 「保存并测试」：先按关闭态保存（测试通过前持久化配置绝不保留
    /// enabled），随后立即发起连接测试；草稿要求开启且测试通过时
    /// 再补存 enabled——持久化的 enabled 配置必然对应一次通过的测试。
    private func saveAIConfigurationAndTest() {
        guard canSaveAndTestAIConfiguration else { return }
        isSavingAIConfiguration = true
        isTestingAIConnection = false
        errorMessage = nil
        aiStatusMessage = nil
        connectionTestTask = Task {
            defer {
                isSavingAIConfiguration = false
                isTestingAIConnection = false
                connectionTestTask = nil
            }
            let timeZoneID = TimeZone.autoupdatingCurrent.identifier
            do {
                var disabledDraft = aiDraft
                disabledDraft.isEnabled = false
                let status = try await aiConfigurationService.save(
                    disabledDraft,
                    apiKey: apiKeyInput,
                    defaultTimeZoneID: timeZoneID
                )
                loadedAIStatus = status
                apiKeyInput = ""
            } catch is CancellationError {
                aiStatusMessage = "已取消保存。"
                return
            } catch {
                errorMessage = "无法保存 AI 配置：\(error.localizedDescription)"
                return
            }

            isTestingAIConnection = true
            do {
                let result = try await aiConnectionTestService
                    .testConnectionAllowingDisabled(defaultTimeZoneID: timeZoneID)
                var normalized = aiDraft
                normalized.isEnabled = false
                testedDraft = normalized
                if aiDraft.isEnabled {
                    do {
                        let enabledStatus = try await aiConfigurationService.save(
                            aiDraft,
                            apiKey: nil,
                            defaultTimeZoneID: timeZoneID
                        )
                        loadedAIStatus = enabledStatus
                        aiStatusMessage = "已保存并通过连接测试，AI 已启用：\(result.serviceName) / \(result.modelID)。"
                    } catch {
                        errorMessage = "连接测试已通过，但保存启用状态失败：\(error.localizedDescription)"
                    }
                } else {
                    aiStatusMessage = "已保存并通过连接测试：\(result.serviceName) / \(result.modelID)。现在可以开启 AI。"
                }
            } catch let error as AIConnectionError where error == .cancelled {
                aiStatusMessage = error.localizedDescription
            } catch is CancellationError {
                aiStatusMessage = AIConnectionError.cancelled.localizedDescription
            } catch {
                errorMessage = "连接测试失败：\(error.localizedDescription)"
                testedDraft = nil
            }
            // 以持久化结果重建草稿：测试失败时持久化停留在关闭态，
            // 草稿同步回落到未启用，避免显示一个无效的"已开启"。
            if let loadedAIStatus {
                aiDraft = AIConfigurationDraft(configuration: loadedAIStatus.configuration)
            }
        }
    }

    private func removeAPIKey() {
        guard !isSavingAIConfiguration, !isTestingAIConnection else { return }
        isSavingAIConfiguration = true
        errorMessage = nil
        Task {
            do {
                let status = try await aiConfigurationService.removeAPIKey(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                loadedAIStatus = status
                aiDraft = AIConfigurationDraft(configuration: status.configuration)
                apiKeyInput = ""
                aiStatusMessage = "API Key 已从本机钥匙串删除，AI 已关闭。"
            } catch {
                errorMessage = "无法删除 API Key：\(error.localizedDescription)"
            }
            isSavingAIConfiguration = false
        }
    }

    private func loadSpeechPreferences() async {
        isLoadingSpeechPreferences = true
        do {
            speechPreferences = try await speechPreferencesService.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
        } catch {
            errorMessage = "无法读取发音设置：\(error.localizedDescription)"
        }
        isLoadingSpeechPreferences = false
    }

    private func updateAutoPlayWordAudio(_ isEnabled: Bool) {
        guard !isUpdatingSpeechPreferences else { return }
        speechPreferences = SpeechPreferences(
            autoPlayWordAudio: isEnabled,
            autoPlayExampleAudio: speechPreferences.autoPlayExampleAudio
        )
        isUpdatingSpeechPreferences = true
        Task {
            do {
                speechPreferences = try await speechPreferencesService
                    .setAutoPlayWordAudio(isEnabled)
            } catch {
                errorMessage = "无法保存发音设置：\(error.localizedDescription)"
                await loadSpeechPreferences()
            }
            isUpdatingSpeechPreferences = false
        }
    }

    private func updateAutoPlayExampleAudio(_ isEnabled: Bool) {
        guard !isUpdatingSpeechPreferences else { return }
        speechPreferences = SpeechPreferences(
            autoPlayWordAudio: speechPreferences.autoPlayWordAudio,
            autoPlayExampleAudio: isEnabled
        )
        isUpdatingSpeechPreferences = true
        Task {
            do {
                speechPreferences = try await speechPreferencesService
                    .setAutoPlayExampleAudio(isEnabled)
            } catch {
                errorMessage = "无法保存发音设置：\(error.localizedDescription)"
                await loadSpeechPreferences()
            }
            isUpdatingSpeechPreferences = false
        }
    }

    private func loadAdaptivePreferences() async {
        isLoadingAdaptivePreferences = true
        do {
            adaptivePreferences = try await adaptivePreferencesService.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
        } catch {
            errorMessage = "无法读取学习偏好：\(error.localizedDescription)"
        }
        isLoadingAdaptivePreferences = false
    }

    private func updateTypedAnswerChineseToJapanese(_ isEnabled: Bool) {
        guard !isLoadingAdaptivePreferences, !isUpdatingAdaptivePreferences else { return }
        let previous = adaptivePreferences
        isUpdatingAdaptivePreferences = true
        Task {
            defer { isUpdatingAdaptivePreferences = false }
            do {
                adaptivePreferences = try await adaptivePreferencesService
                    .setTypedAnswerChineseToJapanese(isEnabled)
            } catch {
                adaptivePreferences = previous
                errorMessage = "无法保存输入设置：\(error.localizedDescription)"
            }
        }
    }

    private func updateAutoPlayListeningAudio(_ isEnabled: Bool) {
        guard !isLoadingAdaptivePreferences, !isUpdatingAdaptivePreferences else { return }
        let previous = adaptivePreferences
        isUpdatingAdaptivePreferences = true
        Task {
            defer { isUpdatingAdaptivePreferences = false }
            do {
                adaptivePreferences = try await adaptivePreferencesService
                    .setAutoPlayListeningAudio(isEnabled)
            } catch {
                adaptivePreferences = previous
                errorMessage = "无法保存自动播放设置：\(error.localizedDescription)"
            }
        }
    }

    private func updateTypedAnswerListening(_ isEnabled: Bool) {
        guard !isLoadingAdaptivePreferences, !isUpdatingAdaptivePreferences else { return }
        let previous = adaptivePreferences
        isUpdatingAdaptivePreferences = true
        Task {
            defer { isUpdatingAdaptivePreferences = false }
            do {
                adaptivePreferences = try await adaptivePreferencesService
                    .setTypedAnswerListening(isEnabled)
            } catch {
                adaptivePreferences = previous
                errorMessage = "无法保存输入设置：\(error.localizedDescription)"
            }
        }
    }

    private func updateLeechReminders(_ isEnabled: Bool) {
        guard !isUpdatingAdaptivePreferences else { return }
        adaptivePreferences = AdaptivePreferences(
            typedAnswerChineseToJapanese: adaptivePreferences.typedAnswerChineseToJapanese,
            autoPlayListeningAudio: adaptivePreferences.autoPlayListeningAudio,
            typedAnswerListening: adaptivePreferences.typedAnswerListening,
            leechRemindersEnabled: isEnabled
        )
        isUpdatingAdaptivePreferences = true
        Task {
            do {
                adaptivePreferences = try await adaptivePreferencesService
                    .setLeechRemindersEnabled(isEnabled)
            } catch {
                errorMessage = "无法保存易错卡设置：\(error.localizedDescription)"
                await loadAdaptivePreferences()
            }
            isUpdatingAdaptivePreferences = false
        }
    }

    /// The pending queue lives outside the database — the count refreshes on
    /// appear and foreground so the export scope note stays honest.
    private func refreshPendingSharedCaptures() {
        pendingSharedCaptureCount = operations.pendingSharedCaptureCount()
    }

    private func prepareExport() {
        isPreparingExport = true
        errorMessage = nil
        Task {
            do {
                let result = try await exporter.export(appVersion: Self.appVersion)
                exportPresentation = ExportPresentation(url: result.url)
                if !result.unresolvedAttachmentIDs.isEmpty {
                    statusMessage = "备份已生成，但有 \(result.unresolvedAttachmentIDs.count) 个图片附件未能解析，未随备份打包。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparingExport = false
        }
    }

    /// S11：恢复成功后的本页收尾（快照列表刷新 + 状态文案）——
    /// apply 已由 BackupImportCoordinator 完成。
    private func finishRestorationCleanup() async {
        await loadLocalSnapshots()
        statusMessage = "完整替换恢复已完成，今日任务已按有效记录重新校正。"
    }

    private func loadLocalSnapshots() async {
        isLoadingSnapshots = true
        do {
            localSnapshots = try await operations.localSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingSnapshots = false
    }

    private func createLocalSnapshot() {
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                let snapshot = try await operations.createLocalSnapshot()
                statusMessage = snapshot == nil ? "今天已经有一份本机快照。" : "本机快照已创建。"
                await loadLocalSnapshots()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restoreLocalSnapshot(_ snapshot: DatabaseSnapshot) {
        snapshotToRestore = nil
        errorMessage = nil
        statusMessage = nil
        Task {
            do {
                try await operations.restoreLocalSnapshot(snapshot)
                statusMessage = "本机快照恢复成功，今日任务已重新校正。"
                await loadLocalSnapshots()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func snapshotReason(_ reason: DatabaseSnapshotReason) -> String {
        switch reason {
        case .daily: "每日快照"
        case .restoration: "恢复前回滚快照"
        case .export: "导出快照"
        case .migration: "迁移前快照"
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }
}

private struct AboutOboeView: View {
    /// S06：词典来源与许可入口（事实由 DictionaryQueryService.sources()
    /// 从打包产物读出，不再硬编码第二份 license 文本）。
    let dictionaryQueryService: DictionaryQueryService

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }

    private var thirdPartyNotices: String {
        guard let url = Bundle.main.url(
            forResource: "THIRD_PARTY_NOTICES",
            withExtension: "txt"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "第三方许可文本未能载入。"
        }
        return text
    }

    private var jlptDataNotice: String {
        let url = Bundle.main.url(
            forResource: "NOTICE",
            withExtension: "txt",
            subdirectory: "JLPT"
        ) ?? Bundle.main.url(forResource: "NOTICE", withExtension: "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "内置 JLPT 词库许可文本未能载入。"
        }
        return text
    }

    var body: some View {
        List {
            Section("版本") {
                LabeledContent("Oboe", value: "\(version) (\(build))")
            }

            Section("开源许可") {
                Text("Oboe 源代码采用 MIT 许可证；学习内容与代码许可相互独立。")
                    .accessibilityIdentifier("about-license-summary")
            }

            Section("第三方组件") {
                Text(thirdPartyNotices)
                    .font(.caption)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("about-third-party-notices")
            }

            Section("内置 JLPT 词库来源") {
                Text("社区整理的学习参考数据，并非官方 JLPT 词表。")
                DisclosureGroup("数据来源与许可") {
                    Text(jlptDataNotice)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("about-jlpt-data-notice")
            }

            Section("内置词典来源") {
                Text("离线日语词典，支持活用形还原；不联网、不进入可携带备份。")
                NavigationLink {
                    DictionarySourcesView(queryService: dictionaryQueryService)
                } label: {
                    Label("数据来源与许可", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("about-dictionary-sources-link")
            }

            Section("隐私") {
                Text("学习数据默认只保存在本机。AI 默认关闭；只有你主动请求时，当前输入才会发送到所配置的服务。可携带备份为未加密文件。")
                    .accessibilityIdentifier("about-privacy-summary")
            }
        }
        .navigationTitle("关于 Oboe")
        .secondaryPage()
    }
}

private extension RetentionPreset {
    var settingsDisplayName: String {
        switch self {
        case .light: "轻量（85%）"
        case .standard: "标准（90%）"
        case .intensive: "强化（95%）"
        }
    }
}

private extension AppAppearance {
    var settingsDisplayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}


private struct ExportPresentation: Identifiable {
    let id = UUID()
    let url: URL
}
