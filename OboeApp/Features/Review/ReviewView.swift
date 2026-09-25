import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit

struct ReviewView: View {
    let service: StudySessionService
    let historyService: StudyHistoryService
    let speechPreferencesService: SpeechPreferencesService
    let adaptiveCardService: AdaptiveCardService
    let adaptivePreferencesService: AdaptivePreferencesService
    /// T07 answer-face AI repair entry — nil hides it entirely.
    let aiRepairService: AIRepairService?
    /// T09: the split preview's deck picker source.
    let deckService: DeckManagementService?
    /// T07: the repair sheet's manual-edit fallback, keyed by note id + kind.
    let repairNoteEditor: ((UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView)?
    let speechService: any SpeechService
    /// S07：背面来源区依赖——nil 时 StudyCardView 不渲染来源块。
    let sourceContextRepository: (any SourceContextRepository)?
    let inboxImageStore: InboxImageStore?
    /// S09：专项学习驱动——normal scope 可为 nil。
    let customStudyRepository: (any CustomStudyRepository)?
    let customStudyService: CustomStudyService?
    let scope: StudyScope

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    /// 会话容器在 scene 导航状态上——compact/regular 壳层切换或窗口
    /// resize 重建视图树时，@State model 会随树销毁；scene 级缓存让
    /// 进行中的学习会话跨壳层续存（resize 不重置）。
    @Environment(SceneNavigationState.self) private var navigation
    /// The card whose repair sheet is open — item-based so the sheet always
    /// belongs to the card that spawned it.
    @State private var aiRepairCardID: UUID?
    @State private var recallInputController = RecallInputController()
    /// 「收起键盘」只在键盘可见时显示——跟随 willShow/willHide。
    @State private var isKeyboardVisible = false

    init(
        service: StudySessionService,
        historyService: StudyHistoryService,
        speechPreferencesService: SpeechPreferencesService,
        adaptiveCardService: AdaptiveCardService,
        adaptivePreferencesService: AdaptivePreferencesService,
        aiRepairService: AIRepairService? = nil,
        deckService: DeckManagementService? = nil,
        repairNoteEditor: ((UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView)? = nil,
        speechService: any SpeechService,
        sourceContextRepository: (any SourceContextRepository)? = nil,
        inboxImageStore: InboxImageStore? = nil,
        customStudyRepository: (any CustomStudyRepository)? = nil,
        customStudyService: CustomStudyService? = nil,
        scope: StudyScope
    ) {
        self.service = service
        self.historyService = historyService
        self.speechPreferencesService = speechPreferencesService
        self.adaptiveCardService = adaptiveCardService
        self.adaptivePreferencesService = adaptivePreferencesService
        self.aiRepairService = aiRepairService
        self.deckService = deckService
        self.repairNoteEditor = repairNoteEditor
        self.speechService = speechService
        self.sourceContextRepository = sourceContextRepository
        self.inboxImageStore = inboxImageStore
        self.customStudyRepository = customStudyRepository
        self.customStudyService = customStudyService
        self.scope = scope
    }

    private var model: ReviewViewModel {
        navigation.reviewSession(for: scope) {
            ReviewViewModel(
                service: service,
                historyService: historyService,
                speechPreferencesService: speechPreferencesService,
                adaptiveCardService: adaptiveCardService,
                adaptivePreferencesService: adaptivePreferencesService,
                speechService: speechService,
                customStudyRepository: customStudyRepository,
                customStudyService: customStudyService,
                scope: scope
            )
        }
    }

    var body: some View {
        Group {
            if model.isLoading, model.plan == nil, !model.isCustomSession {
                ProgressView("正在载入下一张…")
            } else if let card = model.card {
                // 聚焦工作流限宽居中——iPad 大屏不出现全宽卡片。
                ReadableContentContainer(role: .review) {
                    reviewContent(card)
                }
            } else if model.isCustomSession {
                ReadableContentContainer(role: .review) {
                    customStudyState
                }
            } else if let plan = model.plan {
                ReadableContentContainer(role: .review) {
                    completionState(plan)
                }
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
        .secondaryPage()
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
                recallInputController.closeKeyboard()
            }
        }
        .onDisappear {
            recallInputController.closeKeyboard()
            model.stopSpeech()
            model.stopWaitingRefresh()
            // 离开即结束本次会话呈现：否则 scene 缓存的 model 下次进入
            // 会先闪出上一会话的旧卡。
            model.resetPresentedSession()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )
        ) { _ in isKeyboardVisible = true }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )
        ) { _ in isKeyboardVisible = false }
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
            } else if model.isCustomSession {
                customProgressHeader
            }

            VStack(spacing: 0) {
                ScrollView {
                    StudyCardView(
                        content: card.content,
                        isAnswerVisible: model.isAnswerVisible,
                        isSpeechAvailable: model.isSpeechAvailable,
                        leechReminderStatus: model.leechReminderStatus,
                        onPrimarySpeech: model.playPrimarySpeech,
                        onExampleSpeech: model.playExampleSpeech,
                        onListeningPrompt: model.playListeningPrompt,
                        listeningPromptStatus: model.listeningPromptStatus,
                        typedAnswer: model.isTypedRecall ? model.recallAttempt?.rawInput : nil,
                        typedAnswerComparison: model.recallAttempt?.comparison,
                        onAIRepair: aiRepairService == nil ? nil : {
                            aiRepairCardID = card.content.cardID
                        },
                        sourceContextRepository: sourceContextRepository,
                        inboxImageStore: inboxImageStore
                    )
                    .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                    .padding(.vertical, OboeTheme.Spacing.md)
                    if model.isTypedRecall, !model.isAnswerVisible {
                        let isListening = card.content.templateKind == .vocabularyListening
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isListening ? "请用日语复述听到的内容" : "请用日语回答").font(.headline)
                            RecallTextInput(
                                text: model.recallAttempt?.rawInput ?? "",
                                isEnabled: !model.isLoading && !model.isMutating,
                                prompt: isListening ? "请用日语复述听到的内容" : "请用日语回答",
                                controller: recallInputController,
                                onInput: model.updateRecallInput,
                                onConfirm: model.revealAnswer
                            )
                            if let error = model.recallInputError {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                        .padding(.bottom)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("review-content-scroll")

                bottomBar(card)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: model.isAnswerVisible
            )
            .id(model.presentationID)
            .transition(.opacity)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: card.content.cardID
        )
        .background(OboeTheme.Colors.pageBackground)
        .adaptivePresentation(
            role: .focusedWorkflow,
            isPresented: Binding(
                get: { aiRepairCardID != nil },
                set: { shown in if !shown { aiRepairCardID = nil } }
            ),
            onDismiss: {
                // Returning from repair keeps studying — refresh the same card
                // so an in-sheet manual edit is reflected without advancing.
                Task { await model.refresh(preservingCurrentCard: true) }
            },
            content: {
            if let aiRepairService, let aiRepairCardID {
                NavigationStack {
                    AIRepairView(
                        service: aiRepairService,
                        cardID: aiRepairCardID,
                        deckService: deckService,
                        noteEditor: repairNoteEditor,
                        onChanged: {
                            await model.refresh(preservingCurrentCard: true)
                        },
                        onCommitted: {
                            // The card's content changed under the user's
                            // eyes — reload it and re-present the question
                            // face so no stale input or revealed answer
                            // survives the edit.
                            await model.refresh()
                        }
                    )
                }
                .presentationDetents([.large])
            }
            }
        )
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
            if let notice = model.listeningSkipNotice {
                Label(notice, systemImage: "headphones")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-listening-skip-notice")
            }
            if model.mustPlayListeningPromptFirst {
                Text("请先播放音频，再查看答案")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("review-listening-play-first-hint")
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
                        showsIntervals: model.showsIntervals,
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
            } else if model.isTypedRecall {
                Button("确认回答") { recallInputController.confirm() }
                    .buttonStyle(.oboePrimary)
                    .disabled(!model.canConfirmRecall || model.mustPlayListeningPromptFirst)
                    .accessibilityIdentifier("review-confirm-input-button")
                if isKeyboardVisible {
                    Button("收起键盘") { recallInputController.closeKeyboard() }
                        .font(.footnote)
                        .accessibilityIdentifier("review-dismiss-keyboard-button")
                }
            } else {
                Button("显示答案") {
                    model.revealAnswer()
                }
                .buttonStyle(.oboePrimary)
                .disabled(model.mustPlayListeningPromptFirst)
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
                        "剩余 \(summary.remainingCount) · 新词 \(summary.newCount) · 已完成 \(summary.completedCount)"
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
        if !model.skippedListeningIDs.isEmpty {
            listeningSkippedState(plan: plan, nextDue: later.first?.dueAt)
        } else if let next = later.first?.dueAt {
            waitingState(plan: plan, nextDue: next, laterCount: later.count)
        } else {
            finishedState(plan: plan)
        }
    }

    /// T18 (设计 §8.3): every now-candidate listening card failed to play —
    /// show the real remaining count and an explicit re-check, never the
    /// "all done" state. Skipped cards stay due; nothing was rated.
    private func listeningSkippedState(plan: TodayPlan, nextDue: Date?) -> some View {
        VStack(spacing: 0) {
            progressHeader(plan: plan)
            Spacer()
            VStack(spacing: OboeTheme.Spacing.md) {
                Image(systemName: "headphones")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("剩余 \(model.scopedSkippedListeningCount) 张听力卡暂无法播放")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let nextDue {
                    Text("\(StudyTimeText.until(nextDue))后还有更多卡片到期。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("重试音频卡") {
                    model.retrySkippedListeningCards()
                }
                .buttonStyle(.oboePrimary)
                .accessibilityIdentifier("review-listening-retry-button")
            }
            .padding(.horizontal, OboeTheme.pageHorizontalPadding)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review-listening-skipped-state")
            Spacer()
        }
        .background(OboeTheme.Colors.pageBackground)
    }

    private func waitingState(plan: TodayPlan, nextDue: Date, laterCount: Int) -> some View {
        VStack(spacing: 0) {
            progressHeader(plan: plan)
            Spacer()
            OboeEmptyState(
                systemImage: "clock",
                title: "当前已完成",
                message: "\(StudyTimeText.until(nextDue))后还有 \(laterCount) 张，到期会自动开始；也可先退出。",
                stateIdentifier: "review-waiting-state"
            )
            Button("完成") { dismiss() }
                .buttonStyle(.oboePrimary)
                .accessibilityIdentifier("review-waiting-dismiss-button")
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

    /// S09 专项进度头：冻结队列上的位置 + 模式标签（practice 不暗示
    /// FSRS 影响；scheduled 明示计入正式调度）。
    private var customProgressHeader: some View {
        VStack(spacing: OboeTheme.Spacing.xs) {
            HStack {
                Text(
                    "已呈现 \(model.customPresentedCount) · 剩余 \(model.customRemainingCount)"
                )
                .accessibilityIdentifier("review-custom-progress")
                Spacer()
                Text(
                    scope.customMode == .practiceOnly
                        ? "练习·不影响排期" : "专项·计入调度"
                )
                .accessibilityIdentifier("review-custom-mode")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let session = model.customSession,
               !session.queue.cardIDs.isEmpty {
                let total = Double(session.queue.cardIDs.count)
                ProgressView(
                    value: Double(model.customPresentedCount) / total
                )
                .tint(OboeTheme.Colors.accent)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// S09 专项完成/空态：空队列、删除卡耗尽、会话结束统一落这里；
    /// 「再来一轮」按同 filter 新开会话（队列重新冻结）。
    @ViewBuilder
    private var customStudyState: some View {
        if model.isLoading {
            ProgressView("正在载入下一张…")
        } else {
            VStack(spacing: 0) {
                if model.customSession != nil {
                    customProgressHeader
                }
                Spacer()
                VStack(spacing: OboeTheme.Spacing.lg) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(OboeTheme.Colors.accent)
                        .accessibilityHidden(true)
                    Text(
                        model.customSession == nil
                            ? "专项学习已结束" : "本次专项学习完成"
                    )
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("review-custom-complete-state")
                    if scope.customMode == .practiceOnly {
                        Text(
                            "练习 \(model.customPresentedCount) 张 · 重来 \(model.customAgainCount) 次 · 不影响排期"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("review-custom-summary")
                    } else {
                        Text("正式提交 \(model.customPresentedCount) 次评分")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("review-custom-summary")
                    }
                    if model.customSession != nil {
                        Button("再来一轮") {
                            Task { await model.restartCustomSession() }
                        }
                        .buttonStyle(.oboePrimary)
                        .accessibilityIdentifier("review-custom-restart-button")
                    }
                    Button("完成") { dismiss() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("review-finish-button")
                }
                .padding(.horizontal, OboeTheme.pageHorizontalPadding)
                Spacer()
            }
            .background(OboeTheme.Colors.pageBackground)
        }
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
