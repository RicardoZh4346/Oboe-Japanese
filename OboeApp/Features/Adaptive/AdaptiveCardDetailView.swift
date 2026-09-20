import OboeDomain
import SwiftUI

/// 易错详情页 (T03): card identity, status badge, metrics, trigger reasons,
/// and the recent-ten history with version badges only when versions differ.
/// T04 adds the single-card actions: suspend/resume and the edit entry into
/// the existing note editor.
struct AdaptiveCardDetailView: View {
    let service: AdaptiveCardService
    let cardID: UUID
    /// Builds the existing note detail/editor for this card's note. The
    /// callback argument is invoked after the editor persisted a change.
    let noteEditor: (AdaptiveCardItem, @escaping () async -> Void) -> AnyView
    /// T07 AI repair session entry — nil hides it (e.g. service missing).
    let aiRepairService: AIRepairService?
    /// T09: the split preview's deck picker source.
    let deckService: DeckManagementService?
    /// T07: the repair sheet's manual-edit fallback, keyed by note id + kind.
    let repairNoteEditor: ((UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView)?
    /// Fired after this page changed the card (suspend/resume/edit) so the
    /// list behind us can refresh its snapshot.
    let onChanged: () async -> Void

    @State private var model: AdaptiveCardDetailViewModel

    init(
        service: AdaptiveCardService,
        cardID: UUID,
        contentCardService: ContentCardService?,
        aiRepairService: AIRepairService? = nil,
        deckService: DeckManagementService? = nil,
        noteEditor: @escaping (AdaptiveCardItem, @escaping () async -> Void) -> AnyView,
        repairNoteEditor: ((UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView)? = nil,
        onChanged: @escaping () async -> Void = {}
    ) {
        self.service = service
        self.cardID = cardID
        self.aiRepairService = aiRepairService
        self.deckService = deckService
        self.noteEditor = noteEditor
        self.repairNoteEditor = repairNoteEditor
        self.onChanged = onChanged
        _model = State(
            initialValue: AdaptiveCardDetailViewModel(
                service: service,
                cardID: cardID,
                contentCardService: contentCardService
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading, model.detail == nil {
                ProgressView("正在载入卡片记录…")
                    .accessibilityIdentifier("adaptive-detail-loading")
            } else if let error = model.loadErrorMessage, model.detail == nil {
                ContentUnavailableView(
                    "无法载入详情",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text(error)
                )
                .accessibilityIdentifier("adaptive-detail-error")
            } else if model.isCardGone {
                ContentUnavailableView(
                    "这张卡已被删除",
                    systemImage: "trash",
                    description: Text("删除的卡不再出现在易错列表中，其历史记录也不会计入其他卡片。")
                )
                .accessibilityIdentifier("adaptive-detail-gone")
            } else if let detail = model.detail {
                content(detail)
            }
        }
        .navigationTitle("卡片详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func content(_ detail: AdaptiveCardDetail) -> some View {
        let item = detail.item
        let metrics = item.assessment.metrics
        let showsVersionBadge = Set(detail.recentSamples.map(\.contentVersion)).count > 1
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.headword)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        statusBadge(item.assessment.status)
                    }
                    Text(item.templateKind.adaptiveDirectionLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !item.isEnabled {
                        Text("已暂停")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("遗忘数据") {
                LabeledContent("累计遗忘", value: "\(metrics.lifetimeLapses) 次")
                LabeledContent("近 \(metrics.recentCount) 次分布", value: recentDistribution(detail))
                LabeledContent("当前难度", value: String(format: "%.2f / 10", metrics.difficulty))
                LabeledContent("当前稳定度", value: String(format: "%.1f 天", metrics.stability))
            }
            .accessibilityIdentifier("adaptive-detail-metrics")

            Section("触发原因") {
                if item.assessment.triggers.isEmpty {
                    Text("这张卡表现正常，没有触发任何易错规则。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(item.assessment.triggers, id: \.self) { trigger in
                        Label(trigger.explanation, systemImage: "exclamationmark.circle")
                    }
                }
                if item.assessment.isRecovered {
                    Label("近期表现改善", systemImage: "arrow.up.circle")
                        .foregroundStyle(OboeTheme.Colors.accent)
                }
            }
            .accessibilityIdentifier("adaptive-detail-triggers")

            Section("近期复习记录") {
                if detail.recentSamples.isEmpty {
                    Text("还没有复习记录。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detail.recentSamples, id: \.logID) { sample in
                        HistoryRow(sample: sample, showsVersionBadge: showsVersionBadge)
                    }
                }
            }
            .accessibilityIdentifier("adaptive-detail-history")

            Section("操作") {
                if model.canToggleEnabled {
                    Button {
                        Task { await toggleEnabled(item) }
                    } label: {
                        HStack {
                            Label(
                                item.isEnabled ? "暂停这张卡" : "重新启用这张卡",
                                systemImage: item.isEnabled ? "pause.circle" : "play.circle"
                            )
                            Spacer()
                            if model.isActionInFlight {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isActionInFlight)
                    .accessibilityIdentifier("adaptive-detail-toggle-enabled")
                }

                NavigationLink {
                    noteEditor(item) {
                        await model.load()
                        await onChanged()
                    }
                } label: {
                    Label("编辑卡片", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("adaptive-detail-edit")

                if let aiRepairService {
                    NavigationLink {
                        AIRepairView(
                            service: aiRepairService,
                            cardID: item.cardID,
                            deckService: deckService,
                            noteEditor: repairNoteEditor,
                            onChanged: {
                                await model.load()
                                await onChanged()
                            },
                            onCommitted: {
                                await model.load()
                                await onChanged()
                            }
                        )
                    } label: {
                        Label("AI 修卡", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("adaptive-detail-ai-repair")
                }

                Text("编辑会更新同一知识点的其他学习方向。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("adaptive-detail-actions")
        }
        .scrollContentBackground(.hidden)
        .background(OboeTheme.Colors.pageBackground)
        .accessibilityIdentifier("adaptive-detail-content")
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.actionErrorMessage != nil },
                set: { shown in if !shown { model.actionErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.actionErrorMessage ?? "未知错误")
        }
    }

    private func toggleEnabled(_ item: AdaptiveCardItem) async {
        if await model.setCardEnabled(!item.isEnabled) {
            await onChanged()
        }
    }

    private func recentDistribution(_ detail: AdaptiveCardDetail) -> String {
        var counts: [ReviewRating: Int] = [:]
        for sample in detail.recentSamples {
            counts[sample.rating, default: 0] += 1
        }
        return [ReviewRating.again, .hard, .good, .easy]
            .filter { counts[$0, default: 0] > 0 }
            .map { "\($0.title) \(counts[$0, default: 0])" }
            .joined(separator: " · ")
    }

    private func statusBadge(_ status: AdaptiveCardStatus) -> some View {
        Text(status.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.12), in: Capsule())
            .foregroundStyle(status.tint)
    }
}

/// One history line: rating dot + label, content-version badge when visible,
/// due-review flag, timestamp.
private struct HistoryRow: View {
    let sample: AdaptiveReviewSample
    let showsVersionBadge: Bool

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sample.rating.foregroundTint)
                .frame(width: 8, height: 8)
            Text(sample.rating.title)
                .font(.subheadline.weight(.medium))
            if showsVersionBadge {
                Text(sample.contentVersionBadge)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Text(sample.isDueReview ? "到期复习" : "学习中")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.formatter.string(from: sample.reviewedAt))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
