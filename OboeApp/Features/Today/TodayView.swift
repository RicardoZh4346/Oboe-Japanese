import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI

struct TodayView: View {
    let studyService: StudySessionService
    let historyService: StudyHistoryService
    let deckService: DeckManagementService
    let speechPreferencesService: SpeechPreferencesService
    let adaptiveCardService: AdaptiveCardService
    let adaptivePreferencesService: AdaptivePreferencesService
    let aiRepairService: AIRepairService
    let speechService: any SpeechService
    let inboxService: InboxService
    let processingServices: InboxProcessingServices
    let inboxImageStore: InboxImageStore?
    let ocrService: (any OCRRecognizing)?
    let drainSharedCaptures: @Sendable () async -> Void
    let pendingContinueItemID: UUID?
    let clearPendingContinueItem: @Sendable () -> Void
    let sharedCapturesAwaitingImport: Int?
    let importAwaitingSharedCaptures: @Sendable () async -> Void
    /// 设置入口（v0.5.8）：非 nil 时右上角显示齿轮。compact 壳层给
    /// sheet 呈现闭包，regular 壳层给 sidebar section 切换闭包——
    /// 呈现策略仍归壳层，页面不感知壳层形态。
    let openSettings: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: TodayViewModel
    @State private var path: [StudyScope] = []
    @State private var unprocessedInboxCount = 0
    @State private var pendingContinueItem: InboxItem?

    init(
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        deckService: DeckManagementService,
        speechPreferencesService: SpeechPreferencesService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService,
        aiRepairService: AIRepairService,
        speechService: any SpeechService,
        inboxService: InboxService,
        processingServices: InboxProcessingServices,
        inboxImageStore: InboxImageStore? = nil,
        ocrService: (any OCRRecognizing)? = nil,
        drainSharedCaptures: @escaping @Sendable () async -> Void = {},
        pendingContinueItemID: UUID? = nil,
        clearPendingContinueItem: @escaping @Sendable () -> Void = {},
        sharedCapturesAwaitingImport: Int? = nil,
        importAwaitingSharedCaptures: @escaping @Sendable () async -> Void = {},
        openSettings: (() -> Void)? = nil
    ) {
        self.studyService = studyService
        self.historyService = historyService
        self.deckService = deckService
        self.speechPreferencesService = speechPreferencesService
        self.adaptiveCardService = adaptiveCardService
        self.adaptivePreferencesService = adaptivePreferencesService
        self.aiRepairService = aiRepairService
        self.speechService = speechService
        self.inboxService = inboxService
        self.processingServices = processingServices
        self.inboxImageStore = inboxImageStore
        self.ocrService = ocrService
        self.drainSharedCaptures = drainSharedCaptures
        self.pendingContinueItemID = pendingContinueItemID
        self.clearPendingContinueItem = clearPendingContinueItem
        self.sharedCapturesAwaitingImport = sharedCapturesAwaitingImport
        self.importAwaitingSharedCaptures = importAwaitingSharedCaptures
        self.openSettings = openSettings
        _model = State(
            initialValue: TodayViewModel(
                studyService: studyService,
                historyService: historyService,
                deckService: deckService,
                adaptiveCardService: adaptiveCardService,
                adaptivePreferencesService: adaptivePreferencesService
            )
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.isLoading, model.plan == nil {
                    ProgressView("正在生成今日计划…")
                } else if let plan = model.plan {
                    // regular 下首页内容限宽居中——磁贴与统计摘要不随
                    // detail 列全宽拉伸。
                    ReadableContentContainer(role: .article) {
                        home(plan)
                    }
                } else {
                    ContentUnavailableView(
                        "无法载入今日计划",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        description: Text(model.loadErrorMessage ?? "请稍后重试。")
                    )
                }
            }
            .navigationTitle(streakTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let openSettings {
                        // v0.5.8：设置入口从底部 Tab 收进今日页齿轮；
                        // 手动刷新已由前台/路径回退自动触发覆盖。
                        Button("设置", systemImage: "gearshape") {
                            openSettings()
                        }
                        .accessibilityIdentifier("today-settings-button")
                    } else {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await model.load() }
                        }
                        .disabled(model.isLoading)
                        .accessibilityIdentifier("today-refresh-button")
                    }
                }
            }
            .navigationDestination(for: StudyScope.self) { scope in
                ReviewView(
                    service: studyService,
                    historyService: historyService,
                    speechPreferencesService: speechPreferencesService,
                    adaptiveCardService: adaptiveCardService,
                    adaptivePreferencesService: adaptivePreferencesService,
                    aiRepairService: aiRepairService,
                    deckService: deckService,
                    repairNoteEditor: { noteID, kind, onUpdated in
                        AnyView(
                            noteEditorDestination(
                                noteID: noteID,
                                kind: kind,
                                onUpdated: onUpdated
                            )
                        )
                    },
                    speechService: speechService,
                    scope: scope
                )
            }
            .task {
                await model.load()
                await model.refreshPeriodically()
            }
            .task {
                await observeInboxCount()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.load() }
            }
            .onChange(of: path) { _, newPath in
                guard newPath.isEmpty else { return }
                Task { await model.load() }
            }
            .task(id: pendingContinueItemID) {
                await loadPendingContinueItem()
            }
            .alert(
                "刷新失败",
                isPresented: Binding(
                    get: { model.plan != nil && model.loadErrorMessage != nil },
                    set: { shown in if !shown { model.loadErrorMessage = nil } }
                )
            ) {
                Button("重试") { Task { await model.load() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text(model.loadErrorMessage ?? "未知错误")
            }
        }
    }

    // MARK: - 首页固定布局（v0.5.5 Step 7）

    /// 常规字号下首页无纵向滚动：圆形主 CTA + 紧凑任务文案 + 两枚等宽
    /// 入口磁贴 + 可选提醒，全部落在首屏内。`ViewThatFits` 按可用高度
    /// 在 常规/紧凑/迷你 三档间选择（Spacer 只放在外层，不参与测量，
    /// 保证量到的是真实内容高度）；辅助字号（ax 档）改用可读性优先的
    /// 纵向滚动备用布局。
    @ViewBuilder
    private func home(_ plan: TodayPlan) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                homeColumn(plan, density: .accessibility)
                    .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                    .padding(.vertical, OboeTheme.Spacing.lg)
                    .frame(maxWidth: .infinity)
            }
            .refreshable {
                await model.load()
            }
        } else {
            GeometryReader { _ in
                ViewThatFits(in: .vertical) {
                    homeColumn(plan, density: .regular)
                    homeColumn(plan, density: .compact)
                    homeColumn(plan, density: .mini)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                .padding(.vertical, OboeTheme.Spacing.sm)
            }
        }
    }

    /// 连续天数并入导航大标题（「今日（已连续 N 天）」）；统计尚未
    /// 载入时保持「今日」。
    private var streakTitle: String {
        guard let streak = model.currentStreak else { return "今日" }
        return "今日（已连续 \(streak) 天）"
    }

    /// VoiceOver 顺序即此列顺序：主牌组→开始学习状态（圆形按钮内部）
    /// → 今日任务 → 每日统计 → 收集箱 → 可选提醒。
    private func homeColumn(_ plan: TodayPlan, density: HomeDensity) -> some View {
        VStack(spacing: density.sectionSpacing) {
            studyEntry(plan, density: density)
            compactTaskSummary(plan.summary, density: density)
            shortcutTiles(plan: plan, density: density)
            if let item = pendingContinueItem {
                continueCaptureBanner(item)
            }
            if model.showsAdaptiveEntry {
                adaptiveCapsule
            }
        }
    }

    /// 圆形主 CTA：有可学任务时整圆跳转主牌组 scope（v0.5.5 起不再
    /// 提供「全部牌组」学习入口）；其余状态为纯展示圆盘，保证内部
    /// 标识符可被查询。
    @ViewBuilder
    private func studyEntry(_ plan: TodayPlan, density: HomeDensity) -> some View {
        let hero = heroPresentation(plan)
        if hero.isActionable, let deckID = model.primaryDeckID {
            NavigationLink(
                value: StudyScope(
                    deckID: deckID,
                    title: model.primaryDeckName ?? "主牌组"
                )
            ) {
                TodayStudyButton(
                    hero: hero,
                    primaryDeckName: model.primaryDeckName,
                    density: density
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-start-button")
        } else {
            TodayStudyButton(
                hero: hero,
                primaryDeckName: model.primaryDeckName,
                density: density
            )
        }
    }

    /// 圆形按钮下的紧凑今日任务文案：标题行 + 五个计数，普通字号
    /// 一行排开，辅助字号每项独占一行优先可读性。
    private func compactTaskSummary(
        _ summary: TodayStudySummary,
        density: HomeDensity
    ) -> some View {
        VStack(spacing: density.isAccessibility ? OboeTheme.Spacing.sm : OboeTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日任务")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("today-summary")
                Spacer()
                if let fraction = summary.completionFraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                        .accessibilityIdentifier("today-completion-percent")
                } else {
                    Text("暂无任务")
                        .font(.caption)
                        .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                }
            }
            if density.isAccessibility {
                VStack(spacing: OboeTheme.Spacing.xs) {
                    taskMetricRow("新词", value: summary.newCount, identifier: "today-new-count")
                    taskMetricRow("待复习", value: summary.reviewCount, identifier: "today-review-count")
                    taskMetricRow("学习中", value: summary.learningCount, identifier: "today-learning-count")
                    taskMetricRow("剩余", value: summary.remainingCount, identifier: "today-remaining-count")
                    taskMetricRow("已完成", value: summary.completedCount, identifier: "today-completed-count")
                }
            } else {
                HStack(spacing: 0) {
                    taskMetric("新词", value: summary.newCount, identifier: "today-new-count")
                    taskMetric("待复习", value: summary.reviewCount, identifier: "today-review-count")
                    taskMetric("学习中", value: summary.learningCount, identifier: "today-learning-count")
                    taskMetric("剩余", value: summary.remainingCount, identifier: "today-remaining-count")
                    taskMetric("已完成", value: summary.completedCount, identifier: "today-completed-count")
                }
            }
        }
    }

    private func taskMetric(
        _ title: String,
        value: Int,
        identifier: String
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
            Text("\(value)")
                .font(.headline)
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
    }

    private func taskMetricRow(
        _ title: String,
        value: Int,
        identifier: String
    ) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
            Spacer()
            Text("\(value)")
                .font(.headline)
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
        }
    }

    /// 两枚等宽入口磁贴：每日统计 + 收集箱。辅助字号下纵向堆叠。
    private func shortcutTiles(plan: TodayPlan, density: HomeDensity) -> some View {
        let statisticsTile = NavigationLink {
            DailyStatisticsView(
                studyDay: plan.studyDay,
                historyService: historyService
            )
        } label: {
            HomeShortcutTile(
                title: "每日统计",
                systemImage: "chart.bar.xaxis",
                detail: "逐日记录与连续天数"
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-statistics-entry")

        let inboxTile = NavigationLink {
            InboxView(
                service: inboxService,
                processingServices: processingServices,
                inboxImageStore: inboxImageStore,
                ocrService: ocrService,
                drainSharedCaptures: drainSharedCaptures,
                sharedCapturesAwaitingImport: sharedCapturesAwaitingImport,
                importAwaitingSharedCaptures: importAwaitingSharedCaptures
            )
        } label: {
            HomeShortcutTile(
                title: "收集箱",
                systemImage: "tray.and.arrow.down",
                detail: unprocessedInboxCount > 0
                    ? "\(unprocessedInboxCount) 条待处理"
                    : "暂无待处理",
                detailIdentifier: "today-inbox-count"
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            unprocessedInboxCount > 0
                ? "收集箱，\(unprocessedInboxCount) 条待处理"
                : "收集箱，暂无待处理"
        )
        .accessibilityIdentifier("today-inbox-entry")

        return Group {
            if density.isAccessibility {
                VStack(spacing: OboeTheme.Spacing.sm) {
                    statisticsTile
                    inboxTile
                }
            } else {
                HStack(alignment: .top, spacing: OboeTheme.Spacing.sm) {
                    statisticsTile
                    inboxTile
                }
            }
        }
    }

    /// 继续处理入口并入收集箱区域（Step 7）：仅当有「在 App 中继续」
    /// 的分享保存时出现的窄横幅——仍是纯被动入口，点击直达条目详情，
    /// 不自动导航、不触发 AI，也不打断未完成的编辑。
    private func continueCaptureBanner(_ item: InboxItem) -> some View {
        HStack(spacing: OboeTheme.Spacing.xs) {
            NavigationLink {
                InboxItemDetailView(
                    item: item,
                    service: inboxService,
                    processingServices: processingServices,
                    inboxImageStore: inboxImageStore,
                    onChanged: {
                        pendingContinueItem = nil
                        clearPendingContinueItem()
                    }
                )
            } label: {
                HStack(spacing: OboeTheme.Spacing.xs) {
                    Image(systemName: "arrow.right.circle")
                        .font(.subheadline)
                        .foregroundStyle(OboeTheme.Colors.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("继续处理刚保存的内容")
                            .font(.caption.weight(.medium))
                        Text(item.text)
                            .font(.caption2)
                            .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-continue-capture-link")
            Button {
                pendingContinueItem = nil
                clearPendingContinueItem()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-continue-capture-dismiss")
        }
        .padding(.leading, OboeTheme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            OboeTheme.Colors.cardBackground,
            in: RoundedRectangle(
                cornerRadius: OboeTheme.Radius.medium,
                style: .continuous
            )
        )
    }

    /// 易错提醒改为小胶囊（Step 7）：仍是进入易错中心（T03）的唯一
    /// 首页入口——只在提醒开启且有易错卡时出现；计数与列表页同源，
    /// 数字不会打架。
    private var adaptiveCapsule: some View {
        NavigationLink {
            AdaptiveCenterView(
                service: adaptiveCardService,
                contentCardService: processingServices.contentCardService,
                aiRepairService: aiRepairService,
                deckService: deckService,
                noteEditor: { item, onUpdated in
                    AnyView(noteEditorDestination(for: item, onUpdated: onUpdated))
                },
                repairNoteEditor: { noteID, kind, onUpdated in
                    AnyView(noteEditorDestination(noteID: noteID, kind: kind, onUpdated: onUpdated))
                },
                learningTimeZoneID: { [studyService] in
                    try await studyService.loadLearningSettings(
                        defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                    ).learningTimeZoneID
                }
            )
        } label: {
            HStack(spacing: OboeTheme.Spacing.xs) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("需要关注")
                    .font(.subheadline.weight(.medium))
                Text("\(model.adaptiveLeechCount) 张卡最近经常遗忘")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                    .accessibilityIdentifier("today-adaptive-count")
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, OboeTheme.Spacing.md)
            .frame(minHeight: 44)
            .background(OboeTheme.Colors.cardBackground, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("需要关注，\(model.adaptiveLeechCount) 张卡最近经常遗忘")
        .accessibilityIdentifier("today-adaptive-entry")
    }

    private func loadPendingContinueItem() async {
        guard let id = pendingContinueItemID else {
            pendingContinueItem = nil
            return
        }
        do {
            pendingContinueItem = try await inboxService.fetchItem(id: id)
            if pendingContinueItem == nil {
                clearPendingContinueItem()
            }
        } catch {
            // Fetch failure hides the entry rather than blocking the page.
            pendingContinueItem = nil
        }
    }

    /// T04 edit reflow: the Adaptive detail's edit entry reuses the existing
    /// note detail/editor screens — same services, same validation, same
    /// content-version bump. `onUpdated` lets the detail reload fresh
    /// evidence after the editor persisted a change.
    @ViewBuilder
    private func noteEditorDestination(
        for item: AdaptiveCardItem,
        onUpdated: @escaping () async -> Void
    ) -> some View {
        noteEditorDestination(
            noteID: item.noteID,
            kind: item.templateKind.knowledgePointKind,
            onUpdated: onUpdated
        )
    }

    /// T07: the AI repair sheet's manual-edit fallback needs the same
    /// editors keyed by note id + kind instead of an `AdaptiveCardItem`.
    @ViewBuilder
    private func noteEditorDestination(
        noteID: UUID,
        kind: KnowledgePointKind,
        onUpdated: @escaping () async -> Void
    ) -> some View {
        switch kind {
        case .vocabulary:
            VocabularyDetailView(
                noteID: noteID,
                service: processingServices.vocabularyService,
                knowledgeService: processingServices.knowledgePointService,
                deckService: deckService,
                contentCardService: processingServices.contentCardService,
                historyService: historyService,
                speechService: speechService,
                onUpdated: onUpdated
            )
        case .grammar:
            GrammarDetailView(
                noteID: noteID,
                service: processingServices.grammarService,
                knowledgeService: processingServices.knowledgePointService,
                deckService: deckService,
                contentCardService: processingServices.contentCardService,
                historyService: historyService,
                speechService: speechService,
                onUpdated: onUpdated
            )
        }
    }

    @MainActor
    private func observeInboxCount() async {
        do {
            for try await count in inboxService.observeUnprocessedCount() {
                unprocessedInboxCount = count
            }
        } catch {
            return
        }
    }

    // MARK: - 圆形主 CTA 状态（T14 设计 §8.1/§8.3 → Step 7 圆形按钮）

    /// 状态优先级：无牌组 > 空主牌组 > 全天完成 > 等待下一批 > 可学习。
    /// v0.5.5 起 CTA 只进入主牌组 scope，任务计数按 `deckIDs` 成员关系
    /// 过滤——共享 Note 的卡从任一成员牌组都可见，但不跨牌组重复计。
    /// 无牌组时保留 `today-no-decks` 语义——引导创建而非跳转。
    private func heroPresentation(_ plan: TodayPlan) -> HeroPresentation {
        if model.decks.isEmpty {
            return HeroPresentation(
                icon: "rectangle.stack.badge.plus",
                title: "还没有学习内容",
                statusText: "先到「牌组」创建牌组",
                isActionable: false,
                statusIdentifier: "today-no-decks",
                iconTint: OboeTheme.Colors.accent
            )
        }
        if let primary = model.primaryDeck, primary.isEmpty {
            return HeroPresentation(
                icon: "rectangle.stack",
                title: "还没有卡片",
                statusText: "这个牌组还没有卡片",
                isActionable: false,
                statusIdentifier: "today-empty-deck",
                iconTint: OboeTheme.Colors.accent
            )
        }
        let scopedNow = model.scopedItems(plan.availableNow)
        let scopedLater = model.scopedItems(plan.availableLater)
        if scopedNow.isEmpty, scopedLater.isEmpty {
            if plan.isDayComplete {
                return HeroPresentation(
                    icon: "checkmark.circle.fill",
                    title: "今日完成",
                    statusText: "今日任务全部完成，明天 04:00 后生成新计划",
                    isActionable: false,
                    statusIdentifier: "today-day-complete",
                    iconTint: .green
                )
            }
            return HeroPresentation(
                icon: "clock",
                title: "暂无任务",
                statusText: "主牌组今日没有待学任务",
                isActionable: false,
                statusIdentifier: "today-waiting-state",
                iconTint: .orange
            )
        }
        if scopedNow.isEmpty {
            if let next = scopedLater.first?.dueAt {
                return HeroPresentation(
                    icon: "clock",
                    title: "稍后再来",
                    statusText: "当前已完成，\(StudyTimeText.until(next))后还有 \(scopedLater.count) 张",
                    isActionable: false,
                    statusIdentifier: "today-waiting-state",
                    iconTint: .orange
                )
            }
            return HeroPresentation(
                icon: "clock",
                title: "暂无任务",
                statusText: "暂无可学任务",
                isActionable: false,
                statusIdentifier: "today-waiting-state",
                iconTint: .orange
            )
        }
        return HeroPresentation(
            icon: "play.fill",
            title: "开始学习",
            statusText: "现在 \(scopedNow.count) 张 · 今日完成 \(plan.summary.completedCount)",
            isActionable: true,
            statusIdentifier: "today-hero-ready",
            iconTint: .white
        )
    }

}

/// 圆形主 CTA 的展示态（文件级 private，供 TodayView 与
/// TodayStudyButton 共用）。
private struct HeroPresentation {
    let icon: String
    let title: String
    let statusText: String
    let isActionable: Bool
    let statusIdentifier: String
    let iconTint: Color
}

/// 首页布局密度档：`regular` 常规、`compact` 窄屏/较大字号、`mini`
/// 兜底（保证不裁切）、`accessibility` 辅助字号（ScrollView 备用
/// 布局，卡片式 CTA 代替圆形）。
private enum HomeDensity {
    case regular
    case compact
    case mini
    case accessibility

    var isAccessibility: Bool { self == .accessibility }

    var circleDiameter: CGFloat {
        switch self {
        case .regular: 216
        case .compact: 176
        case .mini: 148
        case .accessibility: 0 // 辅助字号不用圆形
        }
    }

    var sectionSpacing: CGFloat {
        switch self {
        case .regular: OboeTheme.Spacing.xl
        case .compact: OboeTheme.Spacing.md
        case .mini: OboeTheme.Spacing.sm
        case .accessibility: OboeTheme.Spacing.lg
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .regular: 30
        case .compact: 26
        case .mini: 22
        case .accessibility: 44
        }
    }
}

/// 圆形主 CTA（v0.5.5 Step 7）：整合开始/等待/完成状态与主牌组名；
/// 连续天数并入导航大标题，不在圆盘内展示。可学习时作为
/// NavigationLink 的 label 进入主牌组 scope；其余状态为纯展示圆盘。
/// 辅助字号下退化为整宽卡片保证可读性。圆盘在深浅色下都有明确边界：
/// 可操作态为 accent 渐变，其余为卡片底色 + 描边。
private struct TodayStudyButton: View {
    let hero: HeroPresentation
    let primaryDeckName: String?
    let density: HomeDensity

    private var foreground: Color {
        hero.isActionable ? .white : .primary
    }

    private var secondaryForeground: Color {
        // 可操作态用不透明白：带 alpha 的前景色会让无障碍对比度
        // 审计在渐变背景上误判（实测渲染对比度 ~8:1 仍被标记）。
        hero.isActionable ? .white : OboeTheme.Colors.secondaryOnCard
    }

    var body: some View {
        if density.isAccessibility {
            cardBody
        } else {
            circleBody
        }
    }

    /// 圆盘版：自上而下 主牌组 → 标题 → 状态，即 VoiceOver 朗读顺序。
    /// 可操作态无图标、标题加大；等待/完成等非可操作态保留状态图标。
    private var circleBody: some View {
        VStack(
            spacing: density == .mini
                ? OboeTheme.Spacing.xs
                : OboeTheme.Spacing.sm
        ) {
            if !hero.isActionable {
                Image(systemName: hero.icon)
                    .font(.system(size: density.iconSize, weight: .semibold))
                    .foregroundStyle(hero.iconTint)
                    .accessibilityHidden(true)
            }
            Text("主牌组 · \(primaryDeckName ?? "未设置")")
                .font(.caption2)
                .foregroundStyle(secondaryForeground)
                .lineLimit(1)
                .accessibilityIdentifier("today-primary-deck")
            Text(hero.title)
                .font(circleTitleFont)
                .fontWeight(.bold)
                .foregroundStyle(foreground)
            Text(hero.statusText)
                .font(density == .regular ? .caption : .caption2)
                .foregroundStyle(secondaryForeground)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityIdentifier(hero.statusIdentifier)
        }
        .padding(OboeTheme.Spacing.md)
        .frame(width: density.circleDiameter, height: density.circleDiameter)
        .background(circleBackground)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(
                    hero.isActionable
                        ? Color.black.opacity(0.12)
                        : Color.primary.opacity(0.15),
                    lineWidth: 1
                )
        }
        .contentShape(Circle())
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
    }

    private var circleTitleFont: Font {
        switch density {
        case .regular: .title
        case .compact: .title2
        case .mini: .title3
        case .accessibility: .title3
        }
    }

    /// 卡片版（辅助字号）：横向排布，文字随字号放大不裁切。
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
            HStack(spacing: OboeTheme.Spacing.md) {
                Image(systemName: hero.icon)
                    .font(.system(size: density.iconSize, weight: .semibold))
                    .foregroundStyle(hero.isActionable ? .white : hero.iconTint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OboeTheme.Spacing.xxs) {
                    Text(hero.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(foreground)
                    Text(hero.statusText)
                        .font(.subheadline)
                        .foregroundStyle(secondaryForeground)
                        .accessibilityIdentifier(hero.statusIdentifier)
                }
                Spacer(minLength: 0)
                if hero.isActionable {
                    Image(systemName: "chevron.right")
                        .font(.title3.bold())
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityHidden(true)
                }
            }
            Text("主牌组 · \(primaryDeckName ?? "未设置")")
                .font(.footnote.weight(.medium))
                .foregroundStyle(secondaryForeground)
                .accessibilityIdentifier("today-primary-deck")
        }
        .padding(OboeTheme.Spacing.cardPaddingCompact)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background {
            cardBackground
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: OboeTheme.Radius.card,
                        style: .continuous
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: OboeTheme.Radius.card, style: .continuous)
                .strokeBorder(
                    hero.isActionable
                        ? Color.black.opacity(0.12)
                        : Color.primary.opacity(0.15),
                    lineWidth: 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: OboeTheme.Radius.card, style: .continuous))
    }

    private var circleBackground: AnyView {
        backgroundContent
    }

    private var cardBackground: AnyView {
        backgroundContent
    }

    /// 与旧 hero 同一套背景：可操作态为 accent + 黑色压暗渐变，
    /// 其余态为卡片底色。
    private var backgroundContent: AnyView {
        guard hero.isActionable else {
            return AnyView(OboeTheme.Colors.cardBackground)
        }
        return AnyView(
            ZStack {
                OboeTheme.Colors.accent
                LinearGradient(
                    colors: [.black.opacity(0.22), .black.opacity(0.42)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
    }
}

/// 等宽首页入口磁贴（v0.5.5 Step 7）：图标 + 标题 + 一行说明；
/// 由外层 HStack（辅助字号下为 VStack）保证两枚磁贴等宽排列。
private struct HomeShortcutTile: View {
    let title: String
    let systemImage: String
    let detail: String
    var detailIdentifier: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xxs) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(OboeTheme.Colors.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            detailText
        }
        .padding(.horizontal, OboeTheme.Spacing.sm)
        .padding(.vertical, OboeTheme.Spacing.sm)
        // 高度随内容——maxHeight:.infinity 会让磁贴吃掉 ViewThatFits
        // 列的全部余量，触发区域远超可见卡片（v0.5.8 收敛为卡片自身）。
        .frame(
            maxWidth: .infinity,
            minHeight: 72,
            alignment: .topLeading
        )
        .background(
            OboeTheme.Colors.cardBackground,
            in: RoundedRectangle(
                cornerRadius: OboeTheme.Radius.medium,
                style: .continuous
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: OboeTheme.Radius.medium,
                style: .continuous
            )
        )
    }

    @ViewBuilder
    private var detailText: some View {
        if let detailIdentifier {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                .accessibilityIdentifier(detailIdentifier)
        } else {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
        }
    }
}

@MainActor
@Observable
private final class TodayViewModel {
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService
    private let deckService: DeckManagementService
    private let adaptiveCardService: AdaptiveCardService
    private let adaptivePreferencesService: AdaptivePreferencesService

    var plan: TodayPlan?
    /// 当前连续学习天数（只读派生值，不持久化）；载入失败时保持 nil，
    /// 不影响今日计划主流程。
    var currentStreak: Int?
    var decks: [DeckSummary] = []
    /// 主牌组显示名：settings.primaryDeckID 已是有效值（未设置/失效时自动
    /// 取排序最前的牌组）；nil 只在没有任何牌组时出现，View 显示「未设置」。
    var primaryDeckID: UUID?
    var primaryDeckName: String?

    /// 主牌组摘要（含卡片数）；无牌组时为 nil。
    var primaryDeck: DeckSummary? {
        decks.first { $0.id == primaryDeckID }
    }

    /// 按主牌组成员关系过滤队列项（`deckIDs.contains`）。
    func scopedItems(_ items: [TodayQueueItem]) -> [TodayQueueItem] {
        guard let primaryDeckID else { return [] }
        return items.filter { $0.deckIDs.contains(primaryDeckID) }
    }
    var adaptiveLeechCount = 0
    var leechRemindersEnabled = true
    var isLoading = true
    var loadErrorMessage: String?

    var showsAdaptiveEntry: Bool {
        adaptiveLeechCount > 0 && leechRemindersEnabled
    }

    init(
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        deckService: DeckManagementService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService
    ) {
        self.studyService = studyService
        self.historyService = historyService
        self.deckService = deckService
        self.adaptiveCardService = adaptiveCardService
        self.adaptivePreferencesService = adaptivePreferencesService
    }

    /// T13（设计 §8.2）：plan/decks/settings 并发发出；连续天数快照依赖
    /// plan 的 studyDay.id，拿到 plan 后再并行展开。`primaryDeckName`
    /// 由 settings.primaryDeckID 在 decks 中解析——并发读取之间牌组被
    /// 删除时安全回落为 nil，由 View 统一显示「未设置」。
    func load() async {
        isLoading = true
        let timeZoneID = TimeZone.autoupdatingCurrent.identifier
        do {
            async let planRequest = studyService.buildTodayPlan(
                defaultTimeZoneID: timeZoneID
            )
            async let decksRequest = deckService.fetchDecks()
            async let settingsRequest = studyService.loadLearningSettings(
                defaultTimeZoneID: timeZoneID
            )
            let freshPlan = try await planRequest
            async let snapshotRequest = historyService.fetchDailyStatistics(
                endingAt: freshPlan.studyDay,
                dayCount: 30
            )
            let fetchedDecks = try await decksRequest
            let settings = try await settingsRequest
            plan = freshPlan
            decks = fetchedDecks
            primaryDeckID = settings.primaryDeckID
            primaryDeckName = settings.primaryDeckID.flatMap { id in
                fetchedDecks.first { $0.id == id }?.name
            }
            currentStreak = try await snapshotRequest.currentStreak
            await loadAdaptiveState()
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Adaptive entry data is deliberately non-fatal: a classification failure
    /// hides the entry for this refresh rather than breaking the Today page.
    private func loadAdaptiveState() async {
        do {
            async let snapshotRequest = adaptiveCardService.snapshot(at: Date())
            async let preferencesRequest = adaptivePreferencesService.load(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            let snapshot = try await snapshotRequest
            let epoch = await adaptiveCardService.currentEpoch()
            guard snapshot.generation.epoch == epoch else {
                return
            }
            adaptiveLeechCount = snapshot.leechCount
            leechRemindersEnabled = (try await preferencesRequest).leechRemindersEnabled
        } catch is CancellationError {
            return
        } catch {
            adaptiveLeechCount = 0
        }
    }

    func refreshPeriodically() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await load()
        }
    }
}
