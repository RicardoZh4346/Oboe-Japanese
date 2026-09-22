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
        importAwaitingSharedCaptures: @escaping @Sendable () async -> Void = {}
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
                    ScrollView {
                        VStack(spacing: 18) {
                            heroCard(plan)
                            summary(plan.summary)
                            if let item = pendingContinueItem {
                                continueCaptureEntry(item)
                            }
                            inboxEntry
                            if model.showsAdaptiveEntry {
                                adaptiveEntry
                            }
                            if let statistics = model.statistics {
                                todayStatistics(statistics, studyDay: plan.studyDay)
                            }
                        }
                        .padding()
                    }
                    .refreshable {
                        await model.load()
                    }
                } else {
                    ContentUnavailableView(
                        "无法载入今日计划",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                        description: Text(model.loadErrorMessage ?? "请稍后重试。")
                    )
                }
            }
            .navigationTitle("今日")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task { await model.load() }
                    }
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("today-refresh-button")
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

    private func summary(_ summary: TodayStudySummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("今日任务")
                    .font(.headline)
                Spacer()
                if let fraction = summary.completionFraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.headline)
                        .monospacedDigit()
                        .accessibilityIdentifier("today-completion-percent")
                } else {
                    Text("暂无任务")
                        .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                }
            }
            if let fraction = summary.completionFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("今日完成比例")
                    .accessibilityRespondsToUserInteraction(false)
            }
            LazyVGrid(columns: summaryColumns, spacing: 12) {
                SummaryMetric(title: "新词", value: summary.newCount, tint: .blue, identifier: "today-new-count")
                SummaryMetric(title: "待复习", value: summary.reviewCount, tint: .orange, identifier: "today-review-count")
                SummaryMetric(title: "学习中", value: summary.learningCount, tint: .purple, identifier: "today-learning-count")
                SummaryMetric(title: "剩余", value: summary.remainingCount, tint: .indigo, identifier: "today-remaining-count")
                SummaryMetric(title: "已完成", value: summary.completedCount, tint: .green, identifier: "today-completed-count")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("today-summary")
    }

    private func todayStatistics(
        _ statistics: TodayReviewStatistics,
        studyDay: StudyDay
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("今日统计")
                    .font(.headline)
                Spacer()
                if let streak = model.currentStreak {
                    Text("连续 \(streak) 天")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                        .accessibilityIdentifier("today-streak")
                }
                NavigationLink {
                    DailyStatisticsView(
                        studyDay: studyDay,
                        historyService: historyService
                    )
                } label: {
                    // 44×44 最小可点击区域：trailing 对齐保持视觉原位。
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("查看每日统计")
                .accessibilityIdentifier("today-statistics-entry")
            }
            LazyVGrid(columns: statisticColumns, spacing: 12) {
                StatisticMetric(
                    title: "今日新学",
                    value: statistics.newLearnedCount,
                    identifier: "today-learned-count"
                )
                StatisticMetric(
                    title: "复习次数",
                    value: statistics.reviewAnswerCount,
                    identifier: "today-review-answer-count"
                )
                StatisticMetric(
                    title: "回答总数",
                    value: statistics.answerCount,
                    identifier: "today-answer-count"
                )
            }
            Divider()
            LazyVGrid(columns: ratingStatisticColumns, spacing: 8) {
                ForEach(ReviewRating.allCases, id: \.self) { rating in
                    VStack(spacing: 4) {
                        Text(rating.title)
                            .font(.caption)
                            .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                        Text("\(statistics.ratings[rating])")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("today-rating-\(rating.identifier)-count")
                }
            }
            Text(
                statistics.answerCount == 0
                    ? "今天还没有有效评分；开始学习后会在这里累计。"
                    : "统计按有效评分事件计算，已撤销评分不计入。"
            )
            .font(.caption)
            .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
    }

    /// Continue-processing entry for a capture saved with "在 App 中继续" —
    /// a passive card only: it never navigates by itself, never launches AI,
    /// and doesn't interrupt other unfinished edits.
    private func continueCaptureEntry(_ item: InboxItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
                VStack(alignment: .leading, spacing: 6) {
                    Label("继续处理刚保存的内容", systemImage: "arrow.right.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OboeTheme.Colors.accent)
                    Text(item.text)
                        .font(.caption)
                        .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-continue-capture-link")
            Button {
                pendingContinueItem = nil
                clearPendingContinueItem()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-continue-capture-dismiss")
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
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

    private var inboxEntry: some View {
        NavigationLink {
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
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.headline)
                    .foregroundStyle(OboeTheme.Colors.accent)
                    .accessibilityHidden(true)
                Text("收集箱")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(
                    unprocessedInboxCount > 0
                        ? "\(unprocessedInboxCount) 条待处理"
                        : "暂无待处理"
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
                .accessibilityIdentifier("today-inbox-count")
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            unprocessedInboxCount > 0
                ? "收集箱，\(unprocessedInboxCount) 条待处理"
                : "收集箱，暂无待处理"
        )
        .accessibilityIdentifier("today-inbox-entry")
    }

    /// Home entry for the Adaptive center (T03): visible only while enabled
    /// leech cards exist AND reminders are on; count comes from the same
    /// snapshot the list page filters, so the number can never disagree.
    private var adaptiveEntry: some View {
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
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("需要关注")
                    .font(.subheadline.weight(.medium))
                Spacer()
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
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("需要关注，\(model.adaptiveLeechCount) 张卡最近经常遗忘")
        .accessibilityIdentifier("today-adaptive-entry")
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

    private var summaryColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible()),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    private var statisticColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible()),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 3
        )
    }

    private var ratingStatisticColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible()),
            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4
        )
    }

    // MARK: - 首屏 Hero（T14，设计 §8.1/§8.3）

    /// Hero 卡即主 CTA：可学任务时整卡跳转主牌组 scope（v0.5.5 起不再
    /// 提供「全部牌组」学习入口），卡内整合 now/later/完成/等待状态与
    /// 主牌组一行。无可学任务时退化为纯展示状态卡（不包
    /// NavigationLink），保证内部标识符可被查询、VoiceOver 按
    /// 标题→状态→主牌组 顺序朗读。
    private func heroCard(_ plan: TodayPlan) -> some View {
        let hero = heroPresentation(plan)
        return Group {
            if hero.isActionable, let deckID = model.primaryDeckID {
                NavigationLink(
                    value: StudyScope(
                        deckID: deckID,
                        title: model.primaryDeckName ?? "主牌组"
                    )
                ) {
                    heroContent(hero)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today-start-button")
            } else {
                heroContent(hero)
            }
        }
    }

    private func heroContent(_ hero: HeroPresentation) -> some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.sm) {
            if dynamicTypeSize.isAccessibilitySize {
                heroIcon(hero)
                heroTitle(hero)
                heroStatus(hero)
            } else {
                HStack(spacing: OboeTheme.Spacing.md) {
                    heroIcon(hero)
                    VStack(alignment: .leading, spacing: OboeTheme.Spacing.xxs) {
                        heroTitle(hero)
                        heroStatus(hero)
                    }
                    Spacer(minLength: 0)
                    if hero.isActionable {
                        Image(systemName: "chevron.right")
                            .font(.title3.bold())
                            .foregroundStyle(.white.opacity(0.9))
                            .accessibilityHidden(true)
                    }
                }
            }
            Text("主牌组 · \(model.primaryDeckName ?? "未设置")")
                .font(.footnote.weight(.medium))
                .foregroundStyle(
                    hero.isActionable ? Color.white : OboeTheme.Colors.secondaryOnCard
                )
                .accessibilityIdentifier("today-primary-deck")
        }
        .padding(OboeTheme.Spacing.cardPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: 150,
            alignment: .leading
        )
        .background {
            heroBackground(actionable: hero.isActionable)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: OboeTheme.Radius.card,
                        style: .continuous
                    )
                )
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: OboeTheme.Radius.card,
                style: .continuous
            )
        )
    }

    private func heroTitle(_ hero: HeroPresentation) -> some View {
        Text("开始学习")
            .font(.title.bold())
            .foregroundStyle(hero.isActionable ? Color.white : Color.primary)
    }

    /// 状态行：图标与文案同时区分状态（不依赖颜色），
    /// `statusIdentifier` 保留既有 UI 测试锚点。
    private func heroStatus(_ hero: HeroPresentation) -> some View {
        Text(hero.statusText)
            .font(.subheadline)
            .foregroundStyle(
                hero.isActionable ? Color.white : OboeTheme.Colors.secondaryOnCard
            )
            .accessibilityIdentifier(hero.statusIdentifier)
    }

    private func heroIcon(_ hero: HeroPresentation) -> some View {
        Image(systemName: hero.icon)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(hero.isActionable ? Color.white : hero.iconTint)
            .accessibilityHidden(true)
    }

    /// 状态优先级：无牌组 > 空主牌组 > 全天完成 > 等待下一批 > 可学习。
    /// v0.5.5 起 CTA 只进入主牌组 scope，任务计数按 `deckIDs` 成员关系
    /// 过滤——共享 Note 的卡从任一成员牌组都可见，但不跨牌组重复计。
    /// 无牌组时保留 `today-no-decks` 语义——引导创建而非跳转。
    private func heroPresentation(_ plan: TodayPlan) -> HeroPresentation {
        if model.decks.isEmpty {
            return HeroPresentation(
                icon: "rectangle.stack.badge.plus",
                statusText: "还没有学习内容，先到「牌组」创建牌组",
                isActionable: false,
                statusIdentifier: "today-no-decks",
                iconTint: OboeTheme.Colors.accent
            )
        }
        if let primary = model.primaryDeck, primary.isEmpty {
            return HeroPresentation(
                icon: "rectangle.stack",
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
                    statusText: "今日任务全部完成，明天 04:00 后生成新计划",
                    isActionable: false,
                    statusIdentifier: "today-day-complete",
                    iconTint: .green
                )
            }
            return HeroPresentation(
                icon: "clock",
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
                    statusText: "当前已完成，\(StudyTimeText.until(next))后还有 \(scopedLater.count) 张",
                    isActionable: false,
                    statusIdentifier: "today-waiting-state",
                    iconTint: .orange
                )
            }
            return HeroPresentation(
                icon: "clock",
                statusText: "暂无可学任务",
                isActionable: false,
                statusIdentifier: "today-waiting-state",
                iconTint: .orange
            )
        }
        return HeroPresentation(
            icon: "play.fill",
            statusText: "现在 \(scopedNow.count) 张 · 今日完成 \(plan.summary.completedCount)",
            isActionable: true,
            statusIdentifier: "today-hero-ready",
            iconTint: .white
        )
    }

    /// 压暗端用黑色叠加而非半透明 accent：白字在渐变任何位置都保持
    /// ≥4.5:1 对比度（深色模式的 accent 较亮，黑叠层同样生效）。
    private func heroBackground(actionable: Bool) -> AnyView {
        guard actionable else {
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

    private struct HeroPresentation {
        let icon: String
        let statusText: String
        let isActionable: Bool
        let statusIdentifier: String
        let iconTint: Color
    }
}
private struct SummaryMetric: View {
    let title: String
    let value: Int
    let tint: Color
    let identifier: String

    var body: some View {
        HStack {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
            Spacer()
            Text("\(value)")
                .font(.headline)
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct StatisticMetric: View {
    let title: String
    let value: Int
    let identifier: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(OboeTheme.Colors.secondaryOnCard)
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
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
    var statistics: TodayReviewStatistics?
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

    /// T13（设计 §8.2）：plan/decks/settings 并发发出；statistics 依赖
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
            async let statisticsRequest = historyService.fetchTodayStatistics(
                studyDayID: freshPlan.studyDay.id
            )
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
            statistics = try await statisticsRequest
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
