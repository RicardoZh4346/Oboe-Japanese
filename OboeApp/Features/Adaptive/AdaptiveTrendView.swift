import OboeDomain
import SwiftUI

/// 本周趋势 (T26): the two-endpoint comparison — card leech status
/// reconstructed at this week's Monday-04:00 boundary (learning time
/// zone) versus right now. The page states plainly that it compares two
/// reconstructed endpoints over the cards that still exist, not a
/// complete history of the week.
struct AdaptiveTrendView: View {
    @State private var model: AdaptiveTrendViewModel

    init(
        trendService: AdaptiveTrendService,
        learningTimeZoneID: @escaping @Sendable () async throws -> String
    ) {
        _model = State(initialValue: AdaptiveTrendViewModel(
            trendService: trendService,
            learningTimeZoneID: learningTimeZoneID
        ))
    }

    var body: some View {
        Group {
            if model.isLoading, model.report == nil {
                ProgressView("正在重建两端对比…")
                    .accessibilityIdentifier("adaptive-trend-loading")
            } else if let error = model.loadErrorMessage, model.report == nil {
                ContentUnavailableView(
                    "无法生成趋势报告",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                    description: Text(error)
                )
                .accessibilityIdentifier("adaptive-trend-error")
            } else if let report = model.report {
                reportList(report)
            }
        }
        .navigationTitle("本周趋势")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func reportList(_ report: AdaptiveTrendReport) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("两端对比说明", systemImage: "info.circle")
                        .font(.subheadline.weight(.medium))
                    Text(
                        "对比本周一 04:00（学习时区）与当前两个时点重建出的易错状态。"
                            + "统计基于当前仍存在的卡片与有效复习记录；已删除的卡片不再计入，"
                            + "不代表整周完整历史。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("adaptive-trend-explanation")
            }

            if report.analyzedCardCount == 0 {
                Section {
                    ContentUnavailableView(
                        "暂无可分析的卡片",
                        systemImage: "tray",
                        description: Text("添加卡片并完成复习后，这里会展示两端对比。")
                    )
                    .accessibilityIdentifier("adaptive-trend-empty")
                }
                .listRowBackground(Color.clear)
            } else {
                Section("本周易错概览") {
                    metricRow(
                        "本周易错卡（任一时点）",
                        value: report.weekLeechCount,
                        identifier: "adaptive-trend-week-leech"
                    )
                    metricRow(
                        "周初易错",
                        value: report.weekStartLeechCount,
                        identifier: "adaptive-trend-start-leech"
                    )
                    metricRow(
                        "当前易错",
                        value: report.currentLeechCount,
                        identifier: "adaptive-trend-current-leech"
                    )
                }
                Section("变化") {
                    metricRow(
                        "新出现",
                        value: report.newlyAppearedCount,
                        identifier: "adaptive-trend-newly-appeared"
                    )
                    metricRow(
                        "仍经常遗忘",
                        value: report.stillLeechCount,
                        identifier: "adaptive-trend-still-leech"
                    )
                    metricRow(
                        "已恢复稳定",
                        value: report.recoveredStableCount,
                        identifier: "adaptive-trend-recovered"
                    )
                    metricRow(
                        "状态改善",
                        value: report.improvedCount,
                        identifier: "adaptive-trend-improved"
                    )
                }
                Section("范围") {
                    metricRow(
                        "参与分析的卡片",
                        value: report.analyzedCardCount,
                        identifier: "adaptive-trend-analyzed"
                    )
                    metricRow(
                        "其中已暂停",
                        value: report.suspendedCount,
                        identifier: "adaptive-trend-suspended"
                    )
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("周界：\(Self.boundaryFormatter.string(from: report.weekStart))（\(report.timeZoneID)）")
                        Text("生成：\(Self.boundaryFormatter.string(from: report.generatedAt))")
                        Text("口径：\(report.policyVersion)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("adaptive-trend-footer")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OboeTheme.Colors.pageBackground)
        .accessibilityIdentifier("adaptive-trend-report")
    }

    private func metricRow(
        _ title: String,
        value: Int,
        identifier: String
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.body.monospacedDigit().weight(.medium))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private static let boundaryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
}
