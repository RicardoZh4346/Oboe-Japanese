import OboeDomain
import OboeInfrastructure
import SwiftUI

/// v0.7.5 S15「AI 准备学习内容」主弹层。
///
/// 单 NavigationStack 内按 `ReaderAIStudyFlowModel.phase` 分屏：
/// 预检 →（准备中）→ 分析进度 → 预览/选择 →（应用中）→ 摘要。
/// 确认前一切操作只动证据链与内存决策——不触碰业务对象。
struct ReaderAIStudySheet: View {
    /// @Bindable：预览编辑（toggles/pickers）需要 $model 双向绑定。
    @Bindable var model: ReaderAIStudyFlowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .preflight: preflightContent
                case .preparing: preparingContent
                case .analyzing: analyzingContent
                case .preview: previewContent
                case .applying: applyingContent
                case .summary: summaryContent
                case .cancelled: cancelledContent
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("ai-study-close")
                }
            }
            // 本地编排/派发/应用期间禁下滑关闭——退出走显式
            // 「取消」按钮（取消语义由 Runner 保证 checkpoint 保留）。
            .interactiveDismissDisabled(
                model.phase == .preparing
                    || model.phase == .analyzing
                    || model.phase == .applying)
        }
        .task {
            if model.report == nil { await model.loadPreflight() }
        }
        .alert("提示", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var navigationTitle: String {
        switch model.phase {
        case .preflight: "AI 准备学习内容"
        case .preparing: "正在准备"
        case .analyzing: "AI 分析中"
        case .preview: "分析预览"
        case .applying: "正在应用"
        case .summary: "完成"
        case .cancelled: "已取消"
        }
    }

    // MARK: - 预检（范围/就绪/估算）

    private var preflightContent: some View {
        Form {
            Section("分析范围") {
                Picker("范围", selection: .init(
                    get: { model.scopeChoice },
                    set: { choice in
                        model.scopeChoice = choice
                        Task { await model.loadPreflight() }
                    }
                )) {
                    if model.context.currentBlockID != nil {
                        Text(AIStudyScopeChoice.currentText.displayName)
                            .tag(AIStudyScopeChoice.currentText)
                    }
                    if model.context.currentChapterID != nil {
                        Text(AIStudyScopeChoice.currentChapter.displayName)
                            .tag(AIStudyScopeChoice.currentChapter)
                    }
                    if model.context.chapterCount > 1 {
                        Text(AIStudyScopeChoice.unprocessedChapters
                            .displayName)
                            .tag(AIStudyScopeChoice.unprocessedChapters)
                        Text(AIStudyScopeChoice.wholeBook.displayName)
                            .tag(AIStudyScopeChoice.wholeBook)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ai-study-scope-picker")
            }

            if let report = model.report {
                providerSection(report.provider)
                estimateSection(report.estimate)

                if !report.warnings.isEmpty {
                    Section("提示") {
                        ForEach(report.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                                .font(.footnote)
                        }
                    }
                }
                if !report.issues.isEmpty {
                    Section("问题") {
                        ForEach(report.issues, id: \.self) { issue in
                            Label(
                                issueDescription(issue),
                                systemImage: issue.isFatal
                                    ? "exclamationmark.triangle.fill"
                                    : "info.circle"
                            )
                            .foregroundStyle(
                                issue.isFatal ? .red : .secondary)
                            .font(.footnote)
                        }
                    }
                }
                if let active = report.activeJob {
                    activeJobSection(active)
                } else {
                    Section {
                        Toggle(
                            "自动生成段落译文",
                            isOn: $model.wantsTranslation)
                        Toggle(
                            "自动建立学习牌组",
                            isOn: $model.automaticApply)
                        Text(
                            "开启后高置信度结果将自动应用；低置信度结果仍需确认。"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    Section {
                        Button {
                            Task { await model.startAnalysis() }
                        } label: {
                            // 纯文本真居中——Label 的图标+文字作为整体
                            // 居中会让文字偏右（真机实测偏位）。
                            Text("开始分析")
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                        .accessibilityIdentifier("ai-study-start")
                    }
                }
            } else if model.isLoadingPreflight {
                Section {
                    ProgressView("正在检查…")
                }
            } else {
                Section {
                    Button("重新检查") {
                        Task { await model.loadPreflight() }
                    }
                    .accessibilityIdentifier("ai-study-preflight-retry")
                }
            }
        }
    }

    @ViewBuilder
    private func providerSection(
        _ provider: AIStudyProviderReadiness
    ) -> some View {
        Section("Provider") {
            LabeledContent("服务", value: provider.serviceName)
            LabeledContent(
                "模型", value: provider.modelID ?? "未选择")
            LabeledContent(
                "状态",
                value: providerStateText(provider.state))
                .accessibilityIdentifier("ai-study-provider-state")
            if provider.state == .missingKey {
                Text("缺少 API Key——可在设置中补齐后仍可继续（任务会暂停等待）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerStateText(
        _ state: AIStudyProviderReadiness.State
    ) -> String {
        switch state {
        case .ready: "就绪"
        case .disabled: "AI 未启用"
        case .missingModel: "未选择模型"
        case .missingKey: "缺少 API Key"
        }
    }

    @ViewBuilder
    private func estimateSection(_ estimate: AIStudyEstimate) -> some View {
        Section("估算") {
            LabeledContent("章节数", value: "\(estimate.chapterCount)")
            LabeledContent(
                "待处理段落", value: "\(estimate.blockCount)")
                .accessibilityIdentifier("ai-study-estimate-blocks")
            LabeledContent(
                "待消歧词汇", value: "\(estimate.targetTokenCount)")
                .accessibilityIdentifier("ai-study-estimate-tokens")
            LabeledContent(
                "预计 AI 请求数",
                value: "\(estimate.requestEstimate)")
                .accessibilityIdentifier("ai-study-estimate-requests")
            LabeledContent(
                "预计学习项",
                value: "\(estimate.uniqueUnitEstimate)")
                .accessibilityIdentifier("ai-study-estimate-units")
            if !estimate.tokenEstimateIsExact {
                Text(
                    "部分段落尚未做本地分析——词汇数为上限估算，"
                    + "开始后会产生精确值。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 同 (document,revision) 已有活跃 Job——续跑入口（唯一索引
    /// 语义下不能并发第二条）。
    @ViewBuilder
    private func activeJobSection(_ active: AIStudyJob) -> some View {
        Section("进行中的分析") {
            Text("该文档已存在一次未完成的分析。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            switch active.status {
            case .paused:
                Button("继续分析") {
                    Task {
                        await adoptActiveJob(active)
                        await model.resume()
                    }
                }
                .accessibilityIdentifier("ai-study-resume-active")
            case .awaitingConfirmation, .partiallyCompleted:
                Button("查看预览") {
                    Task { await adoptActiveJob(active) }
                }
                .accessibilityIdentifier("ai-study-open-preview")
            default:
                ProgressView("分析进行中——可在阅读页稍后查看")
                // 重进接管：共享 Runner 驱动仍在 → 仅挂观察；驱动
                // 已消亡 → adopt 内 `start` 幂等重驱动。
                Button("查看进度") {
                    Task { await adoptActiveJob(active) }
                }
                .accessibilityIdentifier("ai-study-watch-active")
            }
            Button("放弃并取消该分析", role: .destructive) {
                Task {
                    await adoptActiveJob(active)
                    await model.cancel()
                }
            }
            .accessibilityIdentifier("ai-study-cancel-active")
        }
    }

    /// 让流程模型接管既有 Job（续跑/预览入口共用）。
    private func adoptActiveJob(_ active: AIStudyJob) async {
        await model.adopt(job: active)
    }

    // MARK: - 本地编排 / 分析进度

    private var preparingContent: some View {
        VStack(spacing: OboeTheme.Spacing.lg) {
            Spacer()
            if let progress = model.prepareProgress,
               progress.total > 0 {
                ProgressView(
                    value: Double(progress.done),
                    total: Double(progress.total)) {
                        Text("正在分析本地文本…")
                }
                Text("\(progress.done) / \(progress.total) 段")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("正在分析本地文本…")
            }
            Text("形态分析与候选装配在本地进行，不消耗 AI 请求。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: OboeTheme.Spacing.lg) {
                // 后台续跑：本地编排 Task 与 Runner 驱动都不挂在
                // 本模型生命周期上——关闭弹层不取消分析。
                Button("后台继续") { dismiss() }
                    .accessibilityIdentifier("ai-study-background")
                Button("取消", role: .cancel) {
                    Task { await model.cancel() }
                }
                .accessibilityIdentifier("ai-study-cancel-prepare")
            }
        }
        .padding(OboeTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var analyzingContent: some View {
        VStack(spacing: OboeTheme.Spacing.lg) {
            Spacer()
            if let fraction = model.progressFraction {
                ProgressView(value: fraction) {
                    Text("AI 分析中…")
                }
            } else {
                ProgressView("AI 分析中…")
            }
            Text(
                "已解析 \(model.blockCounts.resolved)"
                    + " / \(model.blockCounts.total) 块"
                    + (model.blockCounts.failed > 0
                        ? "，失败 \(model.blockCounts.failed) 块" : ""))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ai-study-progress-text")
            if let code = model.lastFailureCode {
                Text(failureReasonText(code))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai-study-failure-reason")
            }
            if model.isPaused {
                Label(
                    pausedReasonText,
                    systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Text("可离开本页——分析在后台继续，随时回来查看进度。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: OboeTheme.Spacing.lg) {
                Button("后台继续") { dismiss() }
                    .accessibilityIdentifier("ai-study-background")
                if model.isPaused {
                    Button("恢复") {
                        Task { await model.resume() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai-study-resume")
                } else {
                    Button("暂停") {
                        Task { await model.pause() }
                    }
                    .accessibilityIdentifier("ai-study-pause")
                }
                Button("取消", role: .destructive) {
                    Task { await model.cancel() }
                }
                .accessibilityIdentifier("ai-study-cancel")
            }
        }
        .padding(OboeTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 块失败归因码 → 用户可读文案（`last_error_code` 持久化值）。
    private func failureReasonText(_ code: String) -> String {
        switch code {
        case AIStudyRunner.FailureCode.rateLimited:
            "失败原因：Provider 限流——已自动重试，仍失败的可稍后重试。"
        case AIStudyRunner.FailureCode.retryExhausted:
            "失败原因：多次重试未成功——可在预览页重试失败段落。"
        case AIStudyRunner.FailureCode.authFailed:
            "失败原因：API Key 失效——修复后恢复分析。"
        case AIStudyRunner.FailureCode.payloadMissing:
            "失败原因：文档内容已变更——重新发起分析。"
        default:
            "失败原因：\(code)——可在预览页重试失败段落。"
        }
    }

    private var pausedReasonText: String {
        switch model.job?.resumeReason {
        case .missingKey:
            "已暂停：缺少 API Key——请在设置中补齐后恢复。"
        case .missingSource:
            "已暂停：原文不可用。"
        case .contentStale:
            "已暂停：文档内容已变更。"
        case .backgroundPause:
            "已暂停：App 进入后台。"
        default:
            "已暂停。"
        }
    }

    // MARK: - 预览 / 选择

    private var previewContent: some View {
        Form {
            if let preview = model.preview {
                let counts = model.previewCounts
                Section("Analysis Preview") {
                    LabeledContent("复用已有", value: "\(counts.reused)")
                    LabeledContent("新增", value: "\(counts.created)")
                    LabeledContent("太简单", value: "\(counts.tooEasy)")
                    LabeledContent("跳过", value: "\(counts.skipped)")
                    LabeledContent("未决定", value: "\(counts.undecided)")
                    LabeledContent(
                        "需要确认", value: "\(counts.pending)")
                    if preview.failedBlockCount > 0 {
                        LabeledContent(
                            "失败段落",
                            value: "\(preview.failedBlockCount)")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent(
                        "已翻译段落",
                        value:
                            "\(preview.translatedBlockCount)"
                            + "/\(preview.totalBlockCount)")
                }

                Section("制卡策略") {
                    Picker("策略", selection: .init(
                        get: { model.strategyKind },
                        set: { kind in
                            model.strategyKind = kind
                            model.applyStrategy(model.strategy)
                        }
                    )) {
                        ForEach(
                            ReaderAIStudyFlowModel.StrategyKind.allCases,
                            id: \.self
                        ) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("ai-study-strategy")

                    if model.strategyKind == .jlpt {
                        jlptLevelPicker
                    }
                    if model.strategyKind == .newItemsLimit {
                        Stepper(
                            "最多新增 \(model.newItemLimit) 项",
                            value: $model.newItemLimit,
                            in: 1...500)
                        .onChange(of: model.newItemLimit) { _, _ in
                            model.applyStrategy(model.strategy)
                        }
                        .accessibilityIdentifier(
                            "ai-study-new-limit")
                    }
                    Picker("建卡方向", selection: $model.directionPreset) {
                        ForEach(
                            ReaderAIStudyFlowModel.DirectionPreset
                                .allCases,
                            id: \.self
                        ) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.directionPreset) { _, _ in
                        model.applyStrategy(model.strategy)
                    }
                    .accessibilityIdentifier("ai-study-directions")
                }

                if preview.failedBlockCount > 0 {
                    Section {
                        Button(
                            "重试 \(preview.failedBlockCount) 个失败段落"
                        ) {
                            Task { await model.retryFailedBlocks() }
                        }
                        .accessibilityIdentifier("ai-study-retry-failed")
                    }
                }

                Section("学习单元（\(preview.items.count)）") {
                    ForEach(preview.items) { item in
                        unitRow(item)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(item
                                .accessibilityLabelText)
                            .accessibilityIdentifier(
                                "ai-study-unit-\(item.unitKey)")
                    }
                }

                if !preview.pending.isEmpty {
                    Section("待确认（\(preview.pending.count)）") {
                        ForEach(preview.pending) { pending in
                            pendingRow(pending)
                                .accessibilityIdentifier(
                                    "ai-study-pending-\(pending.id)")
                        }
                    }
                }

                Section {
                    Button {
                        Task { await model.confirm() }
                    } label: {
                        Label(
                            "生成学习牌组",
                            systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("ai-study-confirm")
                    Button("取消整个分析", role: .destructive) {
                        Task { await model.cancel() }
                    }
                    .accessibilityIdentifier("ai-study-cancel-preview")
                }
            } else {
                ProgressView("正在生成预览…")
            }
        }
    }

    @ViewBuilder
    private var jlptLevelPicker: some View {
        ForEach(JLPTLevel.allCases, id: \.self) { level in
            Toggle(level.rawValue, isOn: .init(
                get: { model.jlptLevels.contains(level) },
                set: { on in
                    if on {
                        model.jlptLevels.insert(level)
                    } else {
                        model.jlptLevels.remove(level)
                    }
                    model.applyStrategy(model.strategy)
                }
            ))
            .accessibilityIdentifier("ai-study-jlpt-\(level.rawValue)")
        }
    }

    @ViewBuilder
    private func unitRow(_ item: AIStudyPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.headword).font(.headline)
                if let reading = item.reading, reading != item.headword {
                    Text(reading)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let level = item.jlptLevel {
                    Text(level.rawValue)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            .quaternary, in: Capsule())
                }
                if item.containsLowConfidence {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            if let gloss = item.glossSummary {
                Text(gloss)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("出现 \(item.occurrenceCount) 次")
                if item.unitIsTooEasy {
                    Text("已标记太简单")
                        .foregroundStyle(.orange)
                }
                if !item.linkedNotes.isEmpty {
                    Text("已有关联 Note ×\(item.linkedNotes.count)")
                        .foregroundStyle(.secondary)
                }
                if !item.duplicateNotes.isEmpty {
                    Text("疑似重复 Note ×\(item.duplicateNotes.count)")
                        .foregroundStyle(.secondary)
                }
                if let confidence = item.confidenceRange {
                    Text(
                        "置信度 "
                        + String(
                            format: "%.0f–%.0f%%",
                            confidence.lowerBound * 100,
                            confidence.upperBound * 100))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let sentence = item.firstSentence {
                Text(sentence)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Menu {
                Button("新建 Note") {
                    model.setDecision(
                        for: item.unitKey, decision: .create)
                }
                .accessibilityIdentifier(
                    "ai-study-decision-create-\(item.unitKey)")
                ForEach(item.linkedNotes) { note in
                    Button("复用「\(note.headword)」") {
                        model.setDecision(
                            for: item.unitKey, decision: .reuse,
                            reuseNoteID: note.noteID)
                    }
                }
                ForEach(item.duplicateNotes) { note in
                    Button("复用同词 Note「\(note.headword)」") {
                        model.setDecision(
                            for: item.unitKey, decision: .reuse,
                            reuseNoteID: note.noteID)
                    }
                }
                Button("跳过") {
                    model.setDecision(
                        for: item.unitKey, decision: .skip)
                }
                Button("太简单", role: .destructive) {
                    model.setDecision(
                        for: item.unitKey, decision: .tooEasy)
                }
                Button("暂不决定") {
                    model.setDecision(
                        for: item.unitKey, decision: .pending)
                }
            } label: {
                Label(
                    decisionText(item),
                    systemImage: "chevron.up.chevron.down")
                    .font(.footnote.weight(.medium))
            }
            .accessibilityIdentifier(
                "ai-study-decision-menu-\(item.unitKey)")
            .accessibilityLabel("决策：\(item.headword)")
        }
        .padding(.vertical, 2)
    }

    private func decisionText(_ item: AIStudyPreviewItem) -> String {
        switch item.decision {
        case .create: "将新建 Note"
        case .reuse: "将复用 Note"
        case .skip: "跳过"
        case .tooEasy: "标记太简单"
        case .pending, nil: "未决定"
        }
    }

    @ViewBuilder
    private func pendingRow(
        _ pending: AIStudyPreviewPendingItem
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pending.surface).font(.subheadline.weight(.medium))
                if let reading = pending.reading {
                    Text(reading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let confidence = pending.confidence {
                    Text(String(format: "%.0f%%", confidence * 100))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let sentence = pending.sentence {
                Text(sentence)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            if let correction = pending.correctedSelection {
                Label(
                    "已改判 → entry \(correction.entryID)",
                    systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if !pending.alternatives.isEmpty {
                Menu {
                    ForEach(
                        Array(pending.alternatives.enumerated()),
                        id: \.offset
                    ) { _, alternative in
                        Button(
                            alternative.lemma
                                + (alternative.glossSummary.map {
                                    " — \($0)" } ?? "")
                        ) {
                            model.correctPending(
                                pending.id, to: alternative)
                        }
                    }
                    if pending.correctedSelection != nil {
                        Button("撤销改判", role: .destructive) {
                            model.correctPending(pending.id, to: nil)
                        }
                    }
                } label: {
                    Label(
                        pending.correctedSelection == nil
                            ? "选择候选词义" : "已选择候选",
                        systemImage: "list.bullet")
                        .font(.footnote)
                }
                .accessibilityIdentifier(
                    "ai-study-correct-\(pending.id)")
                .accessibilityLabel(
                    "低置信修正：\(pending.surface)")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 应用 / 摘要 / 取消

    private var applyingContent: some View {
        VStack(spacing: OboeTheme.Spacing.lg) {
            Spacer()
            ProgressView("正在写入学习牌组…")
            Text("每个学习单元独立事务——部分失败不会回滚成功项。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(OboeTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryContent: some View {
        Form {
            if let summary = model.summary {
                Section(summary.deckName ?? "学习牌组") {
                    LabeledContent(
                        "新建 Note", value: "\(summary.createdNoteCount)")
                    if summary.degradedToReuseCount > 0 {
                        LabeledContent(
                            "已有 Note 降级复用",
                            value: "\(summary.degradedToReuseCount)")
                    }
                    LabeledContent(
                        "复用 Note", value: "\(summary.reusedNoteCount)")
                    LabeledContent(
                        "太简单", value: "\(summary.tooEasyCount)")
                    LabeledContent(
                        "跳过", value: "\(summary.skippedCount)")
                    if summary.unselectedCount > 0 {
                        LabeledContent(
                            "未选择", value: "\(summary.unselectedCount)")
                    }
                    if summary.failedUnitCount > 0 {
                        LabeledContent(
                            "应用失败",
                            value: "\(summary.failedUnitCount)")
                            .foregroundStyle(.orange)
                    }
                    LabeledContent(
                        "无法确定", value: "\(summary.unresolvedCount)")
                    LabeledContent(
                        "新建卡片", value: "\(summary.createdCardCount)")
                    LabeledContent(
                        "段落翻译",
                        value:
                            "\(summary.translatedBlockCount)"
                            + "/\(summary.totalBlockCount)")
                    if summary.failedBlockCount > 0 {
                        LabeledContent(
                            "失败段落",
                            value: "\(summary.failedBlockCount)")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if let deckID = summary.studyDeckID,
                       let studyDestination =
                            model.dependencies.studyDestination {
                        NavigationLink {
                            studyDestination(
                                deckID, summary.deckName ?? "学习")
                        } label: {
                            Label("开始学习", systemImage: "play.fill")
                        }
                        .accessibilityIdentifier("ai-study-start-study")
                        NavigationLink {
                            model.dependencies.deckDestination?(deckID)
                        } label: {
                            Label("查看牌组", systemImage: "rectangle.stack")
                        }
                        .accessibilityIdentifier("ai-study-open-deck")
                    }
                    Button("返回阅读") {
                        dismiss()
                    }
                    .accessibilityIdentifier("ai-study-return-reader")
                }
            } else {
                ProgressView()
            }
        }
    }

    private var cancelledContent: some View {
        VStack(spacing: OboeTheme.Spacing.lg) {
            Spacer()
            Image(systemName: "xmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("分析已取消")
                .font(.headline)
            Text("已完成的结果已保留；重新开始会跳过已缓存的部分。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("关闭") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ai-study-cancelled-close")
        }
        .padding(OboeTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 描述

    private func issueDescription(
        _ issue: AIStudyPrecheckIssue
    ) -> String {
        switch issue {
        case .documentUnavailable: "文档不可用（缺失或导入失败）"
        case .emptyScope: "所选范围内没有可分析的段落"
        case .noTargetTokens: "范围内没有可学习的词汇"
        case .morphologyMissing: "形态分析服务不可用"
        case .dictionaryUnavailable: "词典不可用——分析将不含词典候选"
        case .activeJobConflict(_, let status):
            "已存在状态为 \(status.rawValue) 的分析任务"
        case .providerDisabled: "AI 未启用——请在设置中启用"
        case .providerMissingModel: "未选择模型——请在设置中选择"
        case .providerMissingKey: "缺少 API Key——请在设置中补齐"
        }
    }
}
