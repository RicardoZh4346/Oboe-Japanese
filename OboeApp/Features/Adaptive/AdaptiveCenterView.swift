import OboeDomain
import SwiftUI

/// 易错卡中心 (T03): filter chips over the shared snapshot, paged rows,
/// empty/loading/error states. Rows navigate to the per-card detail.
/// T04: the detail's suspend/resume/edit actions come back through
/// `model.load()` so the list always re-reads the same snapshot.
struct AdaptiveCenterView: View {
    let service: AdaptiveCardService
    let contentCardService: ContentCardService
    /// T07 AI repair session service for the detail's repair entry.
    let aiRepairService: AIRepairService
    /// T09: the split preview's deck picker source.
    let deckService: DeckManagementService
    /// Builds the existing note detail/editor for a card's note — keeps the
    /// Adaptive feature free of the editor's service surface (T04).
    let noteEditor: (AdaptiveCardItem, @escaping () async -> Void) -> AnyView
    /// T07: the repair sheet's manual-edit fallback, keyed by note id + kind.
    let repairNoteEditor: (UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView
    /// T26: resolves the stored learning time zone for the weekly
    /// two-endpoint trend report — the boundary must never be computed in
    /// the device zone.
    let learningTimeZoneID: @Sendable () async throws -> String

    @State private var model: AdaptiveCenterViewModel

    init(
        service: AdaptiveCardService,
        contentCardService: ContentCardService,
        aiRepairService: AIRepairService,
        deckService: DeckManagementService,
        noteEditor: @escaping (AdaptiveCardItem, @escaping () async -> Void) -> AnyView,
        repairNoteEditor: @escaping (UUID, KnowledgePointKind, @escaping () async -> Void) -> AnyView,
        learningTimeZoneID: @escaping @Sendable () async throws -> String
    ) {
        self.service = service
        self.contentCardService = contentCardService
        self.aiRepairService = aiRepairService
        self.deckService = deckService
        self.noteEditor = noteEditor
        self.repairNoteEditor = repairNoteEditor
        self.learningTimeZoneID = learningTimeZoneID
        _model = State(initialValue: AdaptiveCenterViewModel(service: service))
    }

    var body: some View {
        Group {
            if model.isLoading, model.snapshot == nil {
                ProgressView("正在分析复习记录…")
                    .accessibilityIdentifier("adaptive-loading")
            } else if let error = model.loadErrorMessage, model.snapshot == nil {
                ContentUnavailableView(
                    "无法载入易错分析",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text(error)
                )
                .accessibilityIdentifier("adaptive-load-error")
            } else {
                list
            }
        }
        .navigationTitle("易错卡")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert(
            "刷新失败",
            isPresented: Binding(
                get: { model.snapshot != nil && model.loadErrorMessage != nil },
                set: { shown in if !shown { model.loadErrorMessage = nil } }
            )
        ) {
            Button("重试") { Task { await model.load() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.loadErrorMessage ?? "未知错误")
        }
    }

    private var list: some View {
        List {
            Section {
                NavigationLink {
                    AdaptiveTrendView(
                        trendService: service.trendService,
                        learningTimeZoneID: learningTimeZoneID
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本周趋势")
                                .font(.subheadline.weight(.medium))
                            Text("周初与当前两端易错状态对比")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(OboeTheme.Colors.accent)
                    }
                }
                .accessibilityIdentifier("adaptive-trend-entry")
            }

            Section {
                Picker("筛选", selection: Binding(
                    get: { model.filter },
                    set: { model.selectFilter($0) }
                )) {
                    ForEach(AdaptiveListFilter.allCases, id: \.self) { filter in
                        Text("\(filter.title) \(model.count(for: filter))")
                            .tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("adaptive-filter-picker")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            if model.visibleItems.isEmpty {
                Section {
                    ContentUnavailableView(
                        model.filter.emptyTitle,
                        systemImage: "checkmark.circle",
                        description: Text(model.filter.emptyDescription)
                    )
                    .accessibilityIdentifier("adaptive-empty-\(model.filter.rawValue)")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(model.visibleItems, id: \.cardID) { item in
                        NavigationLink {
                            AdaptiveCardDetailView(
                                service: service,
                                cardID: item.cardID,
                                contentCardService: contentCardService,
                                aiRepairService: aiRepairService,
                                deckService: deckService,
                                noteEditor: noteEditor,
                                repairNoteEditor: repairNoteEditor,
                                onChanged: { await model.load() }
                            )
                        } label: {
                            AdaptiveCardRow(item: item)
                        }
                        .accessibilityIdentifier("adaptive-row-\(item.cardID.uuidString)")
                    }
                    if model.hasMore {
                        Button {
                            model.loadMore()
                        } label: {
                            HStack {
                                Spacer()
                                Text("加载更多（还剩 \(model.filteredTotal - model.visibleItems.count) 条）")
                                    .font(.subheadline)
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("adaptive-load-more")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OboeTheme.Colors.pageBackground)
    }
}

/// One list row: headword + direction + the two numbers the product surface
/// promises (recent-10 Again count, lifetime lapses).
private struct AdaptiveCardRow: View {
    let item: AdaptiveCardItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.headword)
                        .font(.headline)
                        .lineLimit(1)
                    if !item.isEnabled {
                        Text("已暂停")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.templateKind.adaptiveDirectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let metrics = item.assessment.metrics
                Text("最近 \(metrics.recentCount) 次：重来 \(metrics.recentAgainCount) 次")
                    .font(.subheadline.monospacedDigit())
                Text("累计遗忘 \(metrics.lifetimeLapses) 次")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.assessment.status.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(item.assessment.status.tint.opacity(0.12), in: Capsule())
                .foregroundStyle(item.assessment.status.tint)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
