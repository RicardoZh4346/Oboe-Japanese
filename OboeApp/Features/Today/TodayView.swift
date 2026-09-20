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
                            summary(plan.summary)
                            if let statistics = model.statistics {
                                todayStatistics(statistics)
                            }
                            inboxEntry
                            if model.showsAdaptiveEntry {
                                adaptiveEntry
                            }
                            if let item = pendingContinueItem {
                                continueCaptureEntry(item)
                            }
                            sessionStatus(plan)
                            startButtons(plan)
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
                        .font(.headline.monospacedDigit())
                        .accessibilityIdentifier("today-completion-percent")
                } else {
                    Text("暂无任务")
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction = summary.completionFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("今日完成比例")
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

    private func todayStatistics(_ statistics: TodayReviewStatistics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今日统计")
                .font(.headline)
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
                            .foregroundStyle(.secondary)
                        Text("\(statistics.ratings[rating])")
                            .font(.headline.monospacedDigit())
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
            .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
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
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func sessionStatus(_ plan: TodayPlan) -> some View {
        if plan.isDayComplete {
            ContentUnavailableView(
                "今日任务全部完成",
                systemImage: "checkmark.circle.fill",
                description: Text("明天 04:00 后会生成新的学习日计划。")
            )
            .accessibilityIdentifier("today-day-complete")
        } else if plan.availableNow.isEmpty, let next = plan.nextAvailableAt {
            ContentUnavailableView(
                "当前已完成",
                systemImage: "clock",
                description: Text("\(StudyTimeText.until(next))后还有 \(plan.availableLater.count) 张。")
            )
            .accessibilityIdentifier("today-waiting-state")
        }
    }

    @ViewBuilder
    private func startButtons(_ plan: TodayPlan) -> some View {
        if !model.decks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink(value: StudyScope(deckID: nil, title: "全部牌组")) {
                    Label("开始学习", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(plan.availableNow.isEmpty)
                .accessibilityIdentifier("today-start-all-button")

                Text("按牌组学习")
                    .font(.headline)
                    .padding(.top, 6)
                ForEach(model.decks) { deck in
                    let counts = model.counts(for: deck.id)
                    NavigationLink(value: StudyScope(deckID: deck.id, title: deck.name)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(deck.name)
                                Text("现在 \(counts.now) · 稍后 \(counts.later)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(counts.now == 0)
                    .accessibilityIdentifier("today-start-deck-\(deck.id.uuidString)")
                    Divider()
                }
            }
            .padding()
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        } else {
            ContentUnavailableView(
                "还没有学习内容",
                systemImage: "rectangle.stack.badge.plus",
                description: Text("先到“牌组”创建牌组，再从“添加”保存手动卡片。")
            )
            .accessibilityIdentifier("today-no-decks")
        }
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
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .font(.headline.monospacedDigit())
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
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.bold().monospacedDigit())
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
    var decks: [DeckSummary] = []
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

    func load() async {
        isLoading = true
        do {
            let freshPlan = try await studyService.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            async let decksRequest = deckService.fetchDecks()
            async let statisticsRequest = historyService.fetchTodayStatistics(
                studyDayID: freshPlan.studyDay.id
            )
            plan = freshPlan
            decks = try await decksRequest
            statistics = try await statisticsRequest
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

    func counts(for deckID: UUID) -> (now: Int, later: Int) {
        guard let plan else { return (0, 0) }
        return (
            plan.availableNow.count { $0.deckID == deckID },
            plan.availableLater.count { $0.deckID == deckID }
        )
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
