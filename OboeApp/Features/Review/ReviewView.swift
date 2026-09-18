import OboeDomain
import SwiftUI

struct ReviewView: View {
    let service: StudySessionService
    let historyService: StudyHistoryService
    let speechPreferencesService: SpeechPreferencesService
    let speechService: any SpeechService
    let scope: StudyScope

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReviewViewModel

    init(
        service: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        speechService: any SpeechService,
        scope: StudyScope
    ) {
        self.service = service
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.speechService = speechService
        self.scope = scope
        _model = State(
            initialValue: ReviewViewModel(
                service: service,
                historyService: historyService,
                speechPreferencesService: speechPreferencesService,
                speechService: speechService,
                scope: scope
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading, model.plan == nil {
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
        .navigationBarBackButtonHidden(model.isMutating)
        .toolbar(.hidden, for: .tabBar)
        .interactiveDismissDisabled(model.isMutating)
        .sensoryFeedback(.success, trigger: model.completedSubmissionCount)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.canUndo {
                    Button("撤销", systemImage: "arrow.uturn.backward") {
                        Task { await model.undoLastSubmission() }
                    }
                    .disabled(model.isMutating || model.isLoading)
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
        .onDisappear {
            model.stopSpeech()
            model.stopWaitingRefresh()
        }
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
                progressHeader(plan: plan)
            }

            VStack(spacing: 0) {
                ScrollView {
                    StudyCardView(
                        content: card.content,
                        isAnswerVisible: model.isAnswerVisible,
                        isSpeechAvailable: model.isSpeechAvailable,
                        onPrimarySpeech: model.playPrimarySpeech,
                        onExampleSpeech: model.playExampleSpeech
                    )
                    .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                    .padding(.vertical, OboeTheme.Spacing.md)
                }
                .accessibilityIdentifier("review-content-scroll")

                bottomBar(card)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: model.isAnswerVisible
            )
            .id(card.content.cardID)
            .transition(.opacity)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: card.content.cardID
        )
        .background(OboeTheme.Colors.pageBackground)
    }

    private func bottomBar(_ card: LoadedReviewCard) -> some View {
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
                    ReviewRatingBar(
                        choices: card.choices,
                        isSubmitting: model.isSubmitting,
                        submittingRating: model.submittingRating,
                        onRate: { rating in
                            Task { await model.submit(rating) }
                        }
                    )
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
                .buttonStyle(.oboePrimary)
                .accessibilityIdentifier("review-show-answer-button")
            }
        }
        .padding()
        .background(.bar)
        .disabled(model.isLoading || model.isMutating || model.hasCommittedCurrentCard)
    }

    private func progressHeader(plan: TodayPlan) -> some View {
        VStack(spacing: OboeTheme.Spacing.xs) {
            HStack {
                if let summary = model.scopeSummary {
                    Text(
                        "剩余 \(summary.remainingCount) · 新卡 \(summary.newCount) · 已完成 \(summary.completedCount)"
                    )
                    .accessibilityIdentifier("review-progress-summary")
                } else {
                    Text("剩余 \(model.scopedRemainingCount(in: plan))")
                        .accessibilityIdentifier("review-progress-summary")
                }
                Spacer()
                Text(model.categoryLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let fraction = model.scopeSummary?.completionFraction {
                ProgressView(value: fraction)
                    .tint(OboeTheme.Colors.accent)
                    .accessibilityLabel("当前范围完成比例")
                    .accessibilityIdentifier("review-progress-bar")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func completionState(_ plan: TodayPlan) -> some View {
        let later = model.scopedLaterItems(in: plan)
        if let next = later.first?.dueAt {
            waitingState(plan: plan, nextDue: next, laterCount: later.count)
        } else {
            finishedState(plan: plan)
        }
    }

    private func waitingState(plan: TodayPlan, nextDue: Date, laterCount: Int) -> some View {
        VStack(spacing: 0) {
            progressHeader(plan: plan)
            Spacer()
            OboeEmptyState(
                systemImage: "clock",
                title: "当前已完成",
                message: "\(StudyTimeText.until(nextDue))后还有 \(laterCount) 张，可先退出或等待自动刷新。",
                actionTitle: "刷新",
                action: { Task { await model.refresh() } },
                actionIdentifier: "review-wait-refresh-button",
                stateIdentifier: "review-waiting-state"
            )
            Spacer()
        }
        .background(OboeTheme.Colors.pageBackground)
    }

    private func finishedState(plan: TodayPlan) -> some View {
        VStack(spacing: 0) {
            progressHeader(plan: plan)
            ScrollView {
                VStack(spacing: OboeTheme.Spacing.xl) {
                    Spacer(minLength: OboeTheme.Spacing.xl)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(OboeTheme.Colors.accent)
                        .accessibilityHidden(true)
                    Text(plan.isDayComplete ? "今日任务全部完成" : "本卡组今日任务已完成")
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("review-complete-state")
                    if !plan.isDayComplete {
                        Text("其他卡组今天还有任务。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    statisticsSection
                    Button("完成") { dismiss() }
                        .buttonStyle(.oboePrimary)
                        .accessibilityIdentifier("review-finish-button")
                    Spacer(minLength: OboeTheme.Spacing.xl)
                }
                .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                .padding(.vertical, OboeTheme.Spacing.xl)
            }
        }
        .background(OboeTheme.Colors.pageBackground)
    }

    @ViewBuilder
    private var statisticsSection: some View {
        if let statistics = model.completionStatistics {
            if statistics.answerCount > 0 {
                OboeCardSurface(padding: OboeTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: OboeTheme.Spacing.md) {
                        Text("今日学习")
                            .font(.headline)
                            .accessibilityIdentifier("review-statistics-card")
                        HStack(spacing: OboeTheme.Spacing.lg) {
                            statisticsMetric(
                                "新学", value: statistics.newLearnedCardCount,
                                identifier: "review-statistics-new"
                            )
                            statisticsMetric(
                                "复习", value: statistics.reviewedCardCount,
                                identifier: "review-statistics-review"
                            )
                            statisticsMetric(
                                "合计", value: statistics.studiedCardCount,
                                identifier: "review-statistics-total"
                            )
                        }
                        .accessibilityElement(children: .contain)
                        if statistics.ratings.total > 0 {
                            Divider()
                            Text("评分分布（按评分次数）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: OboeTheme.Spacing.md) {
                                ForEach(ReviewRating.allCases, id: \.self) { rating in
                                    Text("\(rating.title) \(statistics.ratings[rating])")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(rating.foregroundTint)
                                        .accessibilityIdentifier(
                                            "review-statistics-rating-\(rating.identifier)"
                                        )
                                }
                            }
                        }
                    }
                }
            } else {
                Text("今日还没有评分记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-statistics-empty")
            }
        } else if model.statisticsErrorMessage != nil {
            VStack(spacing: OboeTheme.Spacing.sm) {
                Text("统计暂时无法载入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重新载入") {
                    Task { await model.reloadStatistics() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("review-statistics-retry-button")
            }
            .accessibilityIdentifier("review-statistics-error")
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityIdentifier("review-statistics-loading")
        }
    }

    private func statisticsMetric(_ title: String, value: Int, identifier: String) -> some View {
        VStack(spacing: OboeTheme.Spacing.xxs) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
            Text("\(title)（张）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value) 张")
        .accessibilityIdentifier(identifier)
    }
}
