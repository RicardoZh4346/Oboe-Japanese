import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    let dependencies: AppDependencies
    let exporter: PortableBackupExporter
    let restorationPreparer: PortableBackupRestorationPreparer
    let studyService: StudySessionService
    let speechPreferencesService: SpeechPreferencesService
    let aiConfigurationService: AIConfigurationService
    let aiConnectionTestService: AIConnectionTestService
    let speechService: any SpeechService

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("portableBackup.lastSuccessfulExportAtMilliseconds")
    private var lastSuccessfulExportAtMilliseconds = 0.0
    @State private var isPreparingExport = false
    @State private var exportPresentation: ExportPresentation?
    @State private var isSelectingBackup = false
    @State private var isPreparingRestoration = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparedRestoration: PreparedRestoration?
    @State private var preparationForCleanup: PreparedRestoration?
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
    @State private var aiDraft = AIConfigurationDraft.deepSeekDefault
    @State private var loadedAIStatus: AIConfigurationStatus?
    @State private var apiKeyInput = ""
    @State private var isLoadingAIConfiguration = true
    @State private var isSavingAIConfiguration = false
    @State private var isTestingAIConnection = false
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var showAIEnablePrivacyConfirmation = false
    @State private var showRemoveAPIKeyConfirmation = false
    @State private var aiStatusMessage: String?
    /// Share files still sitting in the pending queue — they live outside the
    /// database, so the export scope note must say they are not included.
    @State private var pendingSharedCaptureCount: Int?

    var body: some View {
        NavigationStack {
            List {
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

                learningSettingsSection

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

                aiSettingsSection

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

                    Text("AI 服务连接与凭据不会写入备份；图片附件不随备份迁移，跨设备恢复后正文保留。")
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

                    if isPreparingRestoration {
                        HStack {
                            ProgressView()
                            Text("正在校验并导入临时区…")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("取消检查", role: .cancel) {
                                preparationTask?.cancel()
                            }
                            .accessibilityIdentifier("portable-backup-prepare-cancel-button")
                        }
                    }

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

                Section("关于") {
                    NavigationLink {
                        AboutOboeView()
                    } label: {
                        Label("关于 Oboe", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("about-navigation-link")
                }

            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("设置")
            .sheet(item: $exportPresentation) { presentation in
                PortableBackupDocumentPicker(fileURL: presentation.url) { didExport in
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
            .sheet(
                item: $preparedRestoration,
                onDismiss: discardPreparedRestoration
            ) { preparation in
                RestorationImpactPreviewView(preparation: preparation) {
                    try await applyPreparedRestoration(preparation)
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
                        prepareRestoration(from: url)
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
                appearancePreference = dependencies.appearancePreference
                refreshPendingSharedCaptures()
                await loadLearningSettings()
                await loadSpeechPreferences()
                await loadAIConfiguration()
                await loadLocalSnapshots()
            }
            .onDisappear {
                connectionTestTask?.cancel()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else {
                    connectionTestTask?.cancel()
                    return
                }
                refreshPendingSharedCaptures()
            }
            .alert("启用 AI 功能？", isPresented: $showAIEnablePrivacyConfirmation) {
                Button("取消", role: .cancel) {}
                Button("了解并启用") {
                    aiDraft.isEnabled = true
                }
            } message: {
                Text("之后使用 AI 功能时，当前输入和你选择的语境会发送到所配置的服务。Oboe 不会上传整个牌组或学习历史。")
            }
            .confirmationDialog(
                "删除本机保存的 API Key？",
                isPresented: $showRemoveAPIKeyConfirmation,
                titleVisibility: .visible
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
                LabeledContent("每日新卡", value: "\(dailyNewCardLimit) 张")
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
                try await dependencies.setAppearancePreference(appearance)
                appearanceStatus = "显示模式已保存并立即应用。"
            } catch {
                appearancePreference = dependencies.appearancePreference
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
            aiCapabilityFields
            aiCredentialFields
            aiConfigurationActions
            aiPrivacyNotes
        }
    }

    private var aiEnabledToggle: some View {
        Toggle(
            "启用 AI 功能",
            isOn: Binding(
                get: { aiDraft.isEnabled },
                set: { isEnabled in
                    if isEnabled, !aiDraft.isEnabled {
                        showAIEnablePrivacyConfirmation = true
                    } else {
                        aiDraft.isEnabled = false
                    }
                }
            )
        )
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-enabled-toggle")
    }

    private var aiServicePicker: some View {
        Picker("服务", selection: $aiDraft.serviceKind) {
            ForEach(AIServiceKind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-service-picker")
        .onChange(of: aiDraft.serviceKind) { previous, current in
            updateAIPreset(from: previous, to: current)
        }
    }

    @ViewBuilder
    private var aiEndpointFields: some View {
        if aiDraft.serviceKind == .custom {
            TextField("服务名称", text: $aiDraft.serviceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
                .accessibilityIdentifier("ai-service-name-field")
            TextField("https://example.com/v1", text: $aiDraft.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
                .accessibilityIdentifier("ai-base-url-field")
        } else {
            LabeledContent("服务地址", value: AIConfigurationDraft.deepSeekDefault.baseURL)
        }

        TextField("模型 ID", text: $aiDraft.modelID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
            .accessibilityIdentifier("ai-model-id-field")
    }

    @ViewBuilder
    private var aiCapabilityFields: some View {
        if aiDraft.serviceKind == .deepSeek {
            LabeledContent("结构化输出", value: AIResponseFormatMode.jsonObject.displayName)
                .accessibilityIdentifier("ai-response-format-fixed")
        } else {
            Picker("结构化输出", selection: $aiDraft.responseFormatMode) {
                ForEach(AIResponseFormatMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
            .accessibilityIdentifier("ai-response-format-picker")
        }
    }

    @ViewBuilder
    private var aiCredentialFields: some View {
        SecureField(
            hasAPIKeyForDraft ? "留空以保留已保存的 Key" : "API Key",
            text: $apiKeyInput
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
        Button {
            saveAIConfiguration()
        } label: {
            if isSavingAIConfiguration {
                ProgressView()
            } else {
                Label("保存 AI 配置", systemImage: "externaldrive.badge.checkmark")
            }
        }
        .disabled(isLoadingAIConfiguration || isSavingAIConfiguration || isTestingAIConnection)
        .accessibilityIdentifier("ai-save-configuration-button")

        if isTestingAIConnection {
            HStack {
                ProgressView()
                Text("正在测试连接…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) {
                    connectionTestTask?.cancel()
                }
                .accessibilityIdentifier("ai-cancel-connection-test-button")
            }
        } else {
            Button {
                testAIConnection()
            } label: {
                Label("测试连接", systemImage: "network")
            }
            .disabled(!canTestAIConnection)
            .accessibilityIdentifier("ai-test-connection-button")
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
        Text("保存配置不会发起网络请求。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-no-network-note")
        Text("只有点击“测试连接”才会发送最小 JSON 请求，可能产生少量 API 用量；不会自动重试。")
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
            || isPreparingRestoration
            || preparedRestoration != nil
            || dependencies.isDatabaseOperationInProgress
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

    private var canTestAIConnection: Bool {
        guard !isLoadingAIConfiguration, !isSavingAIConfiguration,
              let loadedAIStatus, loadedAIStatus.hasAPIKey,
              loadedAIStatus.configuration.isEnabled,
              apiKeyInput.isEmpty,
              let candidate = try? AIConfigurationValidator.validate(
                  aiDraft,
                  credentialID: loadedAIStatus.configuration.credentialReference.id
              ) else {
            return false
        }
        return candidate == loadedAIStatus.configuration
    }

    private func loadAIConfiguration() async {
        isLoadingAIConfiguration = true
        do {
            let status = try await aiConfigurationService.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            loadedAIStatus = status
            aiDraft = AIConfigurationDraft(configuration: status.configuration)
            apiKeyInput = ""
        } catch {
            errorMessage = "无法读取 AI 配置：\(error.localizedDescription)"
        }
        isLoadingAIConfiguration = false
    }

    private func updateAIPreset(from previous: AIServiceKind, to current: AIServiceKind) {
        guard previous != current else { return }
        switch current {
        case .deepSeek:
            aiDraft.serviceName = AIConfigurationDraft.deepSeekDefault.serviceName
            aiDraft.baseURL = AIConfigurationDraft.deepSeekDefault.baseURL
            aiDraft.modelID = AIConfigurationDraft.deepSeekDefault.modelID
            aiDraft.responseFormatMode = .jsonObject
        case .custom:
            aiDraft.serviceName = ""
            aiDraft.baseURL = "https://"
            aiDraft.modelID = ""
            aiDraft.responseFormatMode = .jsonObject
        }
        apiKeyInput = ""
    }

    private func saveAIConfiguration() {
        guard !isSavingAIConfiguration, !isTestingAIConnection else { return }
        isSavingAIConfiguration = true
        errorMessage = nil
        Task {
            do {
                let status = try await aiConfigurationService.save(
                    aiDraft,
                    apiKey: apiKeyInput,
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                loadedAIStatus = status
                aiDraft = AIConfigurationDraft(configuration: status.configuration)
                apiKeyInput = ""
                aiStatusMessage = "AI 配置已保存在本机；尚未发起网络请求。"
            } catch {
                errorMessage = "无法保存 AI 配置：\(error.localizedDescription)"
            }
            isSavingAIConfiguration = false
        }
    }

    private func testAIConnection() {
        guard canTestAIConnection, !isTestingAIConnection else { return }
        isTestingAIConnection = true
        aiStatusMessage = nil
        errorMessage = nil
        connectionTestTask = Task {
            defer {
                isTestingAIConnection = false
                connectionTestTask = nil
            }
            do {
                let result = try await aiConnectionTestService.testConnection(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )
                aiStatusMessage = "连接成功：\(result.serviceName) / \(result.modelID) / \(result.responseFormatMode.displayName)。"
            } catch let error as AIConnectionError where error == .cancelled {
                aiStatusMessage = error.localizedDescription
            } catch is CancellationError {
                aiStatusMessage = AIConnectionError.cancelled.localizedDescription
            } catch {
                errorMessage = "连接测试失败：\(error.localizedDescription)"
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

    /// The pending queue lives outside the database — the count refreshes on
    /// appear and foreground so the export scope note stays honest.
    private func refreshPendingSharedCaptures() {
        pendingSharedCaptureCount = dependencies.pendingSharedCaptureCount()
    }

    private func prepareExport() {
        isPreparingExport = true
        errorMessage = nil
        Task {
            do {
                let result = try await exporter.export(appVersion: Self.appVersion)
                exportPresentation = ExportPresentation(url: result.url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparingExport = false
        }
    }

    private func prepareRestoration(from url: URL) {
        isPreparingRestoration = true
        errorMessage = nil
        preparationTask = Task {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let preparation = try await restorationPreparer.prepare(fileURL: url)
                if Task.isCancelled {
                    try? await restorationPreparer.discard(preparation)
                    throw CancellationError()
                }
                preparationForCleanup = preparation
                preparedRestoration = preparation
            } catch is CancellationError {
                // User cancellation is an expected, silent outcome.
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparingRestoration = false
            preparationTask = nil
        }
    }

    private func discardPreparedRestoration() {
        guard let preparationForCleanup else {
            return
        }
        self.preparationForCleanup = nil
        Task {
            try? await restorationPreparer.discard(preparationForCleanup)
        }
    }

    private func applyPreparedRestoration(_ preparation: PreparedRestoration) async throws {
        try await dependencies.applyPreparedRestoration(preparation)
        self.preparationForCleanup = nil
        try? await restorationPreparer.discard(preparation)
        await loadLocalSnapshots()
        statusMessage = "完整替换恢复已完成，今日任务已按有效记录重新校正。"
    }

    private func loadLocalSnapshots() async {
        isLoadingSnapshots = true
        do {
            localSnapshots = try await dependencies.localSnapshots()
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
                let snapshot = try await dependencies.createLocalSnapshot()
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
                try await dependencies.restoreLocalSnapshot(snapshot)
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

            Section("隐私") {
                Text("学习数据默认只保存在本机。AI 默认关闭；只有你主动请求时，当前输入才会发送到所配置的服务。可携带备份为未加密文件。")
                    .accessibilityIdentifier("about-privacy-summary")
            }
        }
        .navigationTitle("关于 Oboe")
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

private struct RestorationImpactPreviewView: View {
    let preparation: PreparedRestoration
    let apply: @MainActor @Sendable () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("备份信息") {
                    LabeledContent("文件", value: preparation.sourceFilename)
                    LabeledContent("导出时间") {
                        Text(preparation.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("应用版本", value: preparation.sourceAppVersion)
                    LabeledContent(
                        "格式版本",
                        value: "v\(preparation.sourceFormatVersion) → v\(preparation.preparedFormatVersion)"
                    )
                }

                Section("完整替换影响") {
                    impactRow("牌组", current: preparation.current.deckCount, backup: preparation.backup.deckCount)
                    impactRow("知识点", current: preparation.current.noteCount, backup: preparation.backup.noteCount)
                    impactRow("卡片", current: preparation.current.cardCount, backup: preparation.backup.cardCount)
                    impactRow("评分历史", current: preparation.current.reviewCount, backup: preparation.backup.reviewCount)
                    impactRow("草稿", current: preparation.current.draftCount, backup: preparation.backup.draftCount)
                    impactRow(
                        "收集箱",
                        current: preparation.current.inboxItemCount,
                        backup: preparation.backup.inboxItemCount
                    )
                    impactRow(
                        "处理中",
                        current: preparation.current.processingInboxItemCount,
                        backup: preparation.backup.processingInboxItemCount
                    )
                }

                if !preparation.restoresInboxData {
                    Section {
                        Label(
                            "此备份早于收集箱格式，恢复后收集箱将为空。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("portable-backup-preview-inbox-empty-warning")
                    }
                }

                Section {
                    Text("备份不包含 API 密钥、AI 连接配置、共享中转文件和本地图片附件；条目中的图片引用若无法解析将置空并保留正文。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-preview-excluded-scopes")
                }

                Section {
                    Label("文件已在临时区通过格式、校验值、数量、外键和调度状态检查。", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("portable-backup-preview-valid")
                    Text("当前资料库尚未改变。选择完整替换后仍需再次确认。")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("portable-backup-preview-requires-confirmation")
                }
            }
            .navigationTitle("恢复影响预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完整替换恢复", role: .destructive) { isConfirming = true }
                        .disabled(isApplying)
                        .accessibilityIdentifier("portable-backup-apply-button")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isApplying)
                }
            }
            .interactiveDismissDisabled(isApplying)
            .overlay {
                if isApplying {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                        ProgressView("正在安全替换资料库…")
                    }
                }
            }
            .alert("确认完整替换？", isPresented: $isConfirming) {
                Button("替换当前资料库", role: .destructive) {
                    isApplying = true
                    Task {
                        do {
                            try await apply()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isApplying = false
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前资料库会先创建回滚快照；替换完成后将重建搜索数据并校正今日额度。")
            }
            .alert(
                "恢复失败",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { shown in if !shown { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func impactRow(_ title: String, current: Int, backup: Int) -> some View {
        LabeledContent(title) {
            Text("当前 \(current) → 备份 \(backup)")
                .monospacedDigit()
        }
    }
}

private struct ExportPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PortableBackupDocumentPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(false)
        }
    }
}
