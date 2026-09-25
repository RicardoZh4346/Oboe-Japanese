import OboeDomain
import SwiftUI

/// S09 专项学习设置页（v0.6.0，设计 §7.1/§7.3）。
///
/// 装配约定：本页不自带 NavigationStack/navigationTitle——调用方以
/// `NavigationStack { CustomStudySetupView(...) .navigationTitle("专项学习") }`
/// 包入 sheet（见 `DeckDetailView`）；会话启动后经 `onStart` 回调交给
/// 调用方推进 `ReviewView`。
///
/// 交互约定：
/// - 牌组/JLPT/收藏/preset/顺序/上限任一变更都体现在 `model.filter`
///   （Hashable），`.task(id:)` 自动取消旧任务并重放预览计数；
/// - 「计入调度」说明文案随开关切换（§7.3 超额首学的额度警示）；
/// - 预览候选为 0 或启动进行中时，开始按钮禁用。
struct CustomStudySetupView: View {
    private let onStart: (CustomStudySession) -> Void

    @State private var model: CustomStudySetupModel

    init(
        customStudyService: CustomStudyService,
        customStudyRepository: any CustomStudyRepository,
        deckService: DeckManagementService,
        initialDeckID: UUID? = nil,
        onStart: @escaping (CustomStudySession) -> Void
    ) {
        self.onStart = onStart
        _model = State(
            initialValue: CustomStudySetupModel(
                customStudyService: customStudyService,
                customStudyRepository: customStudyRepository,
                deckService: deckService,
                initialDeckID: initialDeckID
            )
        )
    }

    var body: some View {
        Form {
            scopeSection
            if model.preset == .earlyReview {
                earlyReviewSection
            }
            queueSection
            scheduleSection
            previewSection
            startSection
        }
        .task {
            await model.load()
        }
        .task(id: model.filter) {
            await model.refreshPreview()
        }
        .alert(
            "专项学习",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { model.clearError() }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    // MARK: - 范围

    private var scopeSection: some View {
        Section {
            Picker("范围", selection: $model.preset) {
                Text("自定义").tag(CustomStudyPreset?.none)
                ForEach(CustomStudyPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(CustomStudyPreset?.some(preset))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("custom-study-preset")

            deckRows

            Toggle("仅收藏", isOn: $model.favoriteOnly)

            jlptRow
        } header: {
            Text("范围")
        } footer: {
            Text("不选牌组或 JLPT 等级时，该维度不做限制；preset 与属性条件取交集。")
        }
    }

    /// 牌组多选：行内 checkmark（空集 = 全部牌组）。
    @ViewBuilder
    private var deckRows: some View {
        if model.decks.isEmpty {
            Text("没有可选牌组")
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.decks) { deck in
                Button {
                    model.toggleDeckSelection(deck.id)
                } label: {
                    HStack {
                        Text(deck.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(deck.cardCount) 张卡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.deckIDs.contains(deck.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityIdentifier("custom-study-deck-row")
            }
        }
    }

    /// JLPT 多选 chip（N5–N1，空选 = 不限）。
    private var jlptRow: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
            HStack {
                Text("JLPT 等级")
                Spacer()
                Text(model.jlptLevels.isEmpty ? "不限" : "已选 \(model.jlptLevels.count) 级")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: OboeTheme.Spacing.xs) {
                ForEach(JLPTLevel.allCases, id: \.self) { level in
                    let isSelected = model.jlptLevels.contains(level)
                    Button {
                        model.toggleJLPTLevel(level)
                    } label: {
                        Text(level.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? Color.accentColor : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("custom-study-jlpt-\(level.rawValue)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 提前复习窗口

    private var earlyReviewSection: some View {
        Section {
            Stepper(
                value: $model.earlyReviewWindowDays,
                in: CustomStudyService.earlyReviewWindowDaysRange
            ) {
                LabeledContent("提前复习窗口", value: "\(model.earlyReviewWindowDays) 天")
            }
            .accessibilityIdentifier("custom-study-early-window-stepper")
        } header: {
            Text("提前复习窗口")
        } footer: {
            Text("将未来 \(model.earlyReviewWindowDays) 天内到期的复习卡提前到现在练习。")
        }
    }

    // MARK: - 队列

    private var queueSection: some View {
        Section("队列") {
            Picker("顺序", selection: $model.order) {
                Text("到期顺序").tag(CustomStudyOrder.due)
                Text("随机").tag(CustomStudyOrder.random)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("custom-study-order-picker")

            Stepper(
                value: $model.limit,
                in: 1 ... CustomStudyService.maximumQueueLimit,
                step: 10
            ) {
                LabeledContent("队列上限", value: "\(model.limit) 张")
            }
            .accessibilityIdentifier("custom-study-limit-stepper")
        }
    }

    // MARK: - 调度

    private var scheduleSection: some View {
        Section {
            Toggle("计入调度（影响 FSRS 排期）", isOn: $model.includeInSchedule)
                .accessibilityIdentifier("custom-study-schedule-toggle")
        } header: {
            Text("调度")
        } footer: {
            Text(
                model.includeInSchedule
                    ? "开启后评分会真实更新 FSRS 排期与复习历史；超出今日预约的新词会占用新词额度，可能超过当前上限。"
                    : "练习不影响排期、新词额度与复习统计。"
            )
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            LabeledContent("预览") {
                if model.isLoadingPreview {
                    ProgressView()
                } else if let count = model.candidateCount {
                    Text("预计 \(count) 张卡")
                } else {
                    Text("—")
                }
            }
            .accessibilityIdentifier("custom-study-preview-count")
        } header: {
            Text("预览")
        } footer: {
            if let count = model.candidateCount, count > model.limit {
                Text("候选超过上限，将截取前 \(model.limit) 张。")
            }
        }
    }

    // MARK: - 开始

    private var startSection: some View {
        Section {
            Button {
                Task {
                    if let session = await model.start() {
                        onStart(session)
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    if model.isStarting {
                        ProgressView()
                    } else {
                        Text("开始专项学习")
                            .font(.headline)
                    }
                    Spacer()
                }
            }
            .disabled(!model.canStart)
            .accessibilityIdentifier("custom-study-start-button")
        }
    }
}

private extension CustomStudyPreset {
    /// 设置页选项中文名（需求 §10.2 六个内置 preset + nil=自定义）。
    var displayName: String {
        switch self {
        case .answeredWrongToday: "今日错题"
        case .frequentAgainLast7Days: "近 7 天易错"
        case .leech: "顽固卡"
        case .dueSoon: "即将到期"
        case .earlyReview: "提前复习"
        case .unstudiedNew: "未学新词"
        }
    }
}
