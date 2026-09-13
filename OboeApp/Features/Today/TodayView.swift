import Observation
import OboeDomain
import SwiftUI

struct TodayView: View {
    let studyService: StudySessionService
    let historyService: StudyHistoryService
    let deckService: DeckManagementService
    let speechPreferencesService: SpeechPreferencesService
    let speechService: any SpeechService

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: TodayViewModel
    @State private var path: [StudyScope] = []

    init(
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        deckService: DeckManagementService,
        speechPreferencesService: SpeechPreferencesService,
        speechService: any SpeechService
    ) {
        self.studyService = studyService
        self.historyService = historyService
        self.deckService = deckService
        self.speechPreferencesService = speechPreferencesService
        self.speechService = speechService
        _model = State(
            initialValue: TodayViewModel(
                studyService: studyService,
                historyService: historyService,
                deckService: deckService
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
                    speechPreferencesService: speechPreferencesService,
                    speechService: speechService,
                    scope: scope
                )
            }
            .task {
                await model.load()
                await model.refreshPeriodically()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.load() }
            }
            .onChange(of: path) { _, newPath in
                guard newPath.isEmpty else { return }
                Task { await model.load() }
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
                SummaryMetric(title: "新卡", value: summary.newCount, tint: .blue, identifier: "today-new-count")
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

private struct StudyScope: Hashable {
    let deckID: UUID?
    let title: String
}

@MainActor
@Observable
private final class TodayViewModel {
    private let studyService: StudySessionService
    private let historyService: StudyHistoryService
    private let deckService: DeckManagementService

    var plan: TodayPlan?
    var statistics: TodayReviewStatistics?
    var decks: [DeckSummary] = []
    var isLoading = true
    var loadErrorMessage: String?

    init(
        studyService: StudySessionService,
        historyService: StudyHistoryService,
        deckService: DeckManagementService
    ) {
        self.studyService = studyService
        self.historyService = historyService
        self.deckService = deckService
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
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
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

private struct ReviewView: View {
    let service: StudySessionService
    let speechPreferencesService: SpeechPreferencesService
    let speechService: any SpeechService
    let scope: StudyScope

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: ReviewViewModel

    init(
        service: StudySessionService,
        speechPreferencesService: SpeechPreferencesService,
        speechService: any SpeechService,
        scope: StudyScope
    ) {
        self.service = service
        self.speechPreferencesService = speechPreferencesService
        self.speechService = speechService
        self.scope = scope
        _model = State(
            initialValue: ReviewViewModel(
                service: service,
                speechPreferencesService: speechPreferencesService,
                speechService: speechService,
                scope: scope
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading, model.card == nil {
                ProgressView("正在载入下一张…")
            } else if let card = model.card {
                reviewContent(card)
            } else if let plan = model.plan {
                completionState(plan)
            } else {
                ContentUnavailableView(
                    "无法开始学习",
                    systemImage: "exclamationmark.triangle",
                    description: Text(model.loadErrorMessage ?? "请返回后重试。")
                )
            }
        }
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(model.isMutating)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.canUndo {
                    Button("撤销", systemImage: "arrow.uturn.backward") {
                        Task { await model.undoLastSubmission() }
                    }
                    .disabled(model.isMutating)
                    .accessibilityLabel("撤销上次评分")
                    .accessibilityIdentifier("review-undo-button")
                }
            }
        }
        .task {
            await model.refresh()
            await model.refreshPreviewPeriodically()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.refresh(preservingCurrentCard: true) }
            } else {
                model.stopSpeech()
            }
        }
        .onDisappear { model.stopSpeech() }
        .alert(
            "载入失败",
            isPresented: Binding(
                get: { model.card != nil && model.loadErrorMessage != nil },
                set: { shown in if !shown { model.loadErrorMessage = nil } }
            )
        ) {
            Button("重试") { Task { await model.refresh(preservingCurrentCard: true) } }
            Button("退出", role: .cancel) {}
        } message: {
            Text(model.loadErrorMessage ?? "未知错误")
        }
        .alert(
            "无法撤销",
            isPresented: Binding(
                get: { model.undoErrorMessage != nil },
                set: { shown in if !shown { model.undoErrorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.undoErrorMessage ?? "未知错误")
        }
        .alert(
            "无法播放日语发音",
            isPresented: Binding(
                get: { model.speechErrorMessage != nil },
                set: { shown in if !shown { model.speechErrorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.speechErrorMessage ?? "未知错误")
        }
    }

    private func reviewContent(_ card: LoadedReviewCard) -> some View {
        VStack(spacing: 0) {
            if let plan = model.plan {
                HStack {
                    Text("剩余 \(model.scopedRemainingCount(in: plan))")
                    Spacer()
                    Text(model.categoryLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    question(card.content)
                    if model.isAnswerVisible {
                        Divider()
                        answer(card.content)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .accessibilityIdentifier("review-content-scroll")

            VStack(spacing: 10) {
                if !model.isSpeechAvailable {
                    Label(
                        "未发现日语语音；仍可继续学习。",
                        systemImage: "speaker.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-speech-unavailable")
                }
                if model.isAnswerVisible {
                    if let message = model.submissionErrorMessage {
                        VStack(spacing: 8) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                            Button("重试保存") {
                                Task { await model.retrySubmission() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isSubmitting)
                            .accessibilityIdentifier("review-retry-button")
                        }
                    } else {
                        ratingButtons(card)
                        DisclosureGroup("如何选择评分") {
                            Text("重来：完全没想起来；困难：努力后答对；良好：正常答对；简单：毫不费力。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                } else {
                    Button("显示答案") {
                        model.revealAnswer()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("review-show-answer-button")
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private func question(_ content: ReviewCardContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(questionHint(for: content.templateKind))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(questionText(for: content))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if ReviewSpeechPolicy(content: content).exposesJapaneseOnQuestion {
                speechButton(label: "播放日语发音", identifier: "review-question-speech-button") {
                    model.playPrimarySpeech()
                }
            }
            if content.templateKind == .vocabularyChineseToJapanese,
               let partOfSpeech = content.partOfSpeech {
                Text(partOfSpeech)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-question")
    }

    private func answer(_ content: ReviewCardContent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("答案")
                .font(.headline)
            switch content.templateKind {
            case .vocabularyJapaneseToChinese:
                optionalFact("假名", content.reading)
                fact("中文", content.meaningZH)
                optionalFact("词性", content.partOfSpeech)
                exampleFacts(content)
                optionalFact("说明", content.notes)
            case .vocabularyChineseToJapanese:
                speechFact("日语", content.headword, identifier: "review-answer-speech-button") {
                    model.playPrimarySpeech()
                }
                optionalFact("假名", content.reading)
                exampleFacts(content)
                optionalFact("说明", content.notes)
            case .grammarFormToExplanation:
                fact("含义", content.meaningZH)
                optionalFact("接续", content.connection)
                optionalFact("用法", content.usage)
                exampleFacts(content)
                optionalFact("注意", content.notes)
            }
        }
        .accessibilityIdentifier("review-answer")
    }

    private func ratingButtons(_ card: LoadedReviewCard) -> some View {
        LazyVGrid(columns: ratingColumns, spacing: 7) {
            ForEach(ReviewRating.allCases, id: \.self) { rating in
                Button {
                    Task { await model.submit(rating) }
                } label: {
                    VStack(spacing: 4) {
                        Text(rating.title)
                            .font(.subheadline.bold())
                        Text(StudyTimeText.interval(until: card.choices[rating].dueAt))
                            .font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(rating.tint)
                .disabled(model.isSubmitting)
                .accessibilityLabel("\(rating.title)，预计\(StudyTimeText.interval(until: card.choices[rating].dueAt))")
                .accessibilityIdentifier("review-rating-\(rating.identifier)")
            }
        }
        .accessibilityIdentifier("review-rating-controls")
    }

    private var ratingColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible()),
            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4
        )
    }

    @ViewBuilder
    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func optionalFact(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            fact(label, value)
        }
    }

    @ViewBuilder
    private func exampleFacts(_ content: ReviewCardContent) -> some View {
        if let example = content.exampleJapanese, !example.isEmpty {
            speechFact("例句", example, identifier: "review-example-speech-button") {
                model.playExampleSpeech()
            }
        }
        optionalFact("例句翻译", content.exampleTranslationZH)
    }

    private func speechFact(
        _ label: String,
        _ value: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .textSelection(.enabled)
            speechButton(label: "播放\(label)发音", identifier: identifier, action: action)
        }
    }

    private func speechButton(
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "speaker.wave.2.fill")
        }
        .buttonStyle(.bordered)
        .disabled(!model.isSpeechAvailable)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func questionText(for content: ReviewCardContent) -> String {
        content.templateKind == .vocabularyChineseToJapanese
            ? content.meaningZH
            : content.headword
    }

    private func questionHint(for template: CardTemplateKind) -> String {
        switch template {
        case .vocabularyJapaneseToChinese: "请回忆中文含义"
        case .vocabularyChineseToJapanese: "请回忆日语表达"
        case .grammarFormToExplanation: "请回忆语法含义和用法"
        }
    }

    @ViewBuilder
    private func completionState(_ plan: TodayPlan) -> some View {
        let later = model.scopedLaterItems(in: plan)
        if let next = later.first?.dueAt {
            ContentUnavailableView {
                Label("当前已完成", systemImage: "clock")
            } description: {
                Text("\(StudyTimeText.until(next))后还有 \(later.count) 张，可先退出。")
            } actions: {
                Button("刷新") { Task { await model.refresh() } }
                    .accessibilityIdentifier("review-wait-refresh-button")
            }
            .accessibilityIdentifier("review-waiting-state")
        } else {
            ContentUnavailableView(
                "本组今日任务已完成",
                systemImage: "checkmark.circle.fill",
                description: Text(scope.deckID == nil ? "今天没有剩余任务。" : "这个牌组今天没有剩余任务。")
            )
            .accessibilityIdentifier("review-complete-state")
        }
    }
}

@MainActor
@Observable
private final class ReviewViewModel {
    private struct PendingSubmission {
        let eventID: UUID
        let rating: ReviewRating
        let durationMilliseconds: Int
        let card: LoadedReviewCard
        let studyDay: StudyDay
    }

    private struct LastSubmission {
        let eventID: UUID
        let studyDay: StudyDay
    }

    private let service: StudySessionService
    private let speechPreferencesService: SpeechPreferencesService
    private let speechService: any SpeechService
    private let scope: StudyScope
    private var answerRevealedAt: Date?
    private var pendingSubmission: PendingSubmission?
    private var lastSubmission: LastSubmission?

    var plan: TodayPlan?
    var card: LoadedReviewCard?
    var currentItem: TodayQueueItem?
    var isAnswerVisible = false
    var isLoading = true
    var isSubmitting = false
    var isUndoing = false
    var loadErrorMessage: String?
    var submissionErrorMessage: String?
    var undoErrorMessage: String?
    var speechErrorMessage: String?
    var speechPreferences = SpeechPreferences.defaults

    init(
        service: StudySessionService,
        speechPreferencesService: SpeechPreferencesService,
        speechService: any SpeechService,
        scope: StudyScope
    ) {
        self.service = service
        self.speechPreferencesService = speechPreferencesService
        self.speechService = speechService
        self.scope = scope
    }

    var categoryLabel: String {
        switch currentItem?.category {
        case .new: "新卡"
        case .learning: "学习中"
        case .review: "复习"
        case .relearning: "重学"
        case nil: ""
        }
    }

    var canUndo: Bool { lastSubmission != nil }
    var isMutating: Bool { isSubmitting || isUndoing }
    var isSpeechAvailable: Bool { speechService.availability.isAvailable }

    func refresh(preservingCurrentCard: Bool = false) async {
        isLoading = true
        if !preservingCurrentCard {
            speechService.stop()
        }
        do {
            let freshPlan = try await service.buildTodayPlan(
                defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
            )
            plan = freshPlan
            if lastSubmission?.studyDay.id != freshPlan.studyDay.id {
                lastSubmission = nil
            }
            let candidates = scopedNowItems(in: freshPlan)
            let selected: TodayQueueItem?
            if preservingCurrentCard,
               let currentItem,
               candidates.contains(where: { $0.cardID == currentItem.cardID }) {
                selected = currentItem
            } else {
                selected = candidates.first
                isAnswerVisible = false
                answerRevealedAt = nil
                pendingSubmission = nil
                submissionErrorMessage = nil
            }
            currentItem = selected
            if let selected {
                card = try await service.loadReviewCard(cardID: selected.cardID)
                speechPreferences = (try? await speechPreferencesService.load(
                    defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
                )) ?? .defaults
                if !preservingCurrentCard {
                    playAutomatically(onAnswer: false)
                }
            } else {
                card = nil
            }
            loadErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            loadErrorMessage = Self.message(for: error)
        }
        isLoading = false
    }

    func revealAnswer() {
        guard card != nil, !isAnswerVisible else { return }
        isAnswerVisible = true
        answerRevealedAt = Date()
        playAutomatically(onAnswer: true)
    }

    func submit(_ rating: ReviewRating) async {
        guard pendingSubmission == nil,
              let card,
              let studyDay = plan?.studyDay,
              isAnswerVisible else {
            return
        }
        speechService.stop()
        let duration = max(0, Int(Date().timeIntervalSince(answerRevealedAt ?? Date()) * 1_000))
        pendingSubmission = PendingSubmission(
            eventID: UUID(),
            rating: rating,
            durationMilliseconds: duration,
            card: card,
            studyDay: studyDay
        )
        await retrySubmission()
    }

    func retrySubmission() async {
        guard let pendingSubmission, !isSubmitting else { return }
        isSubmitting = true
        submissionErrorMessage = nil
        do {
            let submitted = try await service.submit(
                card: pendingSubmission.card,
                rating: pendingSubmission.rating,
                studyDay: pendingSubmission.studyDay,
                eventID: pendingSubmission.eventID,
                durationMilliseconds: pendingSubmission.durationMilliseconds
            )
            lastSubmission = LastSubmission(
                eventID: submitted.eventID,
                studyDay: pendingSubmission.studyDay
            )
            self.pendingSubmission = nil
            isAnswerVisible = false
            answerRevealedAt = nil
            isSubmitting = false
            await refresh()
        } catch {
            isSubmitting = false
            let message = Self.submissionMessage(for: error)
            submissionErrorMessage = message
            if Self.requiresFreshCard(error) {
                self.pendingSubmission = nil
                await refresh(preservingCurrentCard: true)
                submissionErrorMessage = nil
                loadErrorMessage = message
            }
        }
    }

    func undoLastSubmission() async {
        guard let lastSubmission, !isMutating else { return }
        speechService.stop()
        isUndoing = true
        undoErrorMessage = nil
        do {
            _ = try await service.undoLastReview(
                eventID: lastSubmission.eventID,
                studyDay: lastSubmission.studyDay
            )
            self.lastSubmission = nil
            isUndoing = false
            await refresh()
        } catch {
            isUndoing = false
            undoErrorMessage = Self.undoMessage(for: error)
            if error is UndoReviewError {
                self.lastSubmission = nil
            }
        }
    }

    func refreshPreviewPeriodically() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard isAnswerVisible, !isSubmitting, let currentItem else { continue }
            do {
                card = try await service.loadReviewCard(cardID: currentItem.cardID)
            } catch {
                loadErrorMessage = Self.message(for: error)
            }
        }
    }

    func scopedNowItems(in plan: TodayPlan) -> [TodayQueueItem] {
        plan.availableNow.filter { scope.deckID == nil || $0.deckID == scope.deckID }
    }

    func scopedLaterItems(in plan: TodayPlan) -> [TodayQueueItem] {
        plan.availableLater.filter { scope.deckID == nil || $0.deckID == scope.deckID }
    }

    func scopedRemainingCount(in plan: TodayPlan) -> Int {
        scopedNowItems(in: plan).count + scopedLaterItems(in: plan).count
    }

    func playPrimarySpeech() {
        guard let card else { return }
        play([ReviewSpeechPolicy(content: card.content).primaryText])
    }

    func playExampleSpeech() {
        guard let example = card.flatMap({ ReviewSpeechPolicy(content: $0.content).exampleText })
        else { return }
        play([example])
    }

    func stopSpeech() {
        speechService.stop()
    }

    private func playAutomatically(onAnswer: Bool) {
        guard let card else { return }
        let policy = ReviewSpeechPolicy(content: card.content)
        let texts = onAnswer
            ? policy.automaticAnswerTexts(preferences: speechPreferences)
            : policy.automaticQuestionTexts(preferences: speechPreferences)
        guard !texts.isEmpty else { return }
        play(texts)
    }

    private func play(_ texts: [String]) {
        do {
            try speechService.speak(texts)
            speechErrorMessage = nil
        } catch {
            speechErrorMessage = Self.speechMessage(for: error)
        }
    }

    private static func requiresFreshCard(_ error: Error) -> Bool {
        guard let error = error as? SubmitReviewError else { return false }
        return switch error {
        case .stateVersionConflict, .studyDayNotActive, .cardNotInStudyPlan,
             .cardNotDue, .clockMovedBackward, .cardDisabled, .cardNotFound:
            true
        default:
            false
        }
    }

    private static func submissionMessage(for error: Error) -> String {
        guard let error = error as? SubmitReviewError else {
            return "评分未保存：\(error.localizedDescription)。请重试。"
        }
        return switch error {
        case .stateVersionConflict: "卡片已在其他位置更新，已重新载入。"
        case .studyDayNotActive: "学习日已经变化，已刷新今日计划。"
        case .cardNotInStudyPlan: "卡片已不在当前计划中，已刷新。"
        case let .cardNotDue(until): "这张卡尚未到期（\(StudyTimeText.until(until))后）。"
        case .clockMovedBackward: "系统时间早于上次评分，请校正时间后再试。"
        case .cardDisabled, .cardNotFound: "卡片已停用或删除，已刷新。"
        default: "评分未保存，请重试。"
        }
    }

    private static func undoMessage(for error: Error) -> String {
        guard let error = error as? UndoReviewError else {
            return "撤销失败：\(error.localizedDescription)。请重试。"
        }
        return switch error {
        case .reviewNotFound, .alreadyUndone: "这次评分已不存在或已被撤销。"
        case .studyDayMismatch, .studyDayNotActive: "学习日已经变化，不能撤销昨天的评分。"
        case .cardNotFound: "卡片已经删除，无法恢复评分前状态。"
        case .cardDisabled: "卡片已经停用，无法撤销这次评分。"
        case .cardNotInStudyPlan: "卡片已不在当前学习计划中，无法撤销。"
        case .subsequentReviewExists: "这张卡已有后续评分，不能撤销较早记录。"
        case .stateConflict: "卡片状态已发生变化，未执行撤销。"
        }
    }

    private static func message(for error: Error) -> String {
        if error is StudySessionError {
            return "卡片内容已变化，请刷新今日计划。"
        }
        return error.localizedDescription
    }

    private static func speechMessage(for error: Error) -> String {
        guard let error = error as? JapaneseSpeechError else {
            return "系统语音暂时无法播放，请稍后重试。"
        }
        return switch error {
        case .voiceUnavailable:
            "设备未安装可用的日语语音。请在系统设置的辅助功能“朗读内容”中下载日语声音；学习可继续进行。"
        case .noSpeakableText:
            "当前内容没有可朗读的日语文本。"
        case .audioSessionUnavailable:
            "音频正被其他应用或通话占用，请稍后重试。"
        }
    }
}

private enum StudyTimeText {
    static func until(_ date: Date) -> String {
        interval(seconds: max(0, date.timeIntervalSinceNow))
    }

    static func interval(until date: Date) -> String {
        interval(seconds: max(0, date.timeIntervalSinceNow))
    }

    private static func interval(seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60))) 分钟" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600))) 小时" }
        return "\(max(1, Int(seconds / 86_400))) 天"
    }
}

private extension ReviewRating {
    var title: String {
        switch self {
        case .again: "重来"
        case .hard: "困难"
        case .good: "良好"
        case .easy: "简单"
        }
    }

    var identifier: String {
        switch self {
        case .again: "again"
        case .hard: "hard"
        case .good: "good"
        case .easy: "easy"
        }
    }

    var tint: Color {
        switch self {
        case .again: .red
        case .hard: .orange
        case .good: .blue
        case .easy: .green
        }
    }
}
