import Observation
import OboeDomain
import SwiftUI

/// v0.5.5「每日统计」二级页：展示含今天在内最近 30 个学习日的逐日
/// 记录与当前连续学习天数。零记录日保留为 0 行；支持下拉刷新与
/// 失败重试，不影响首页主学习入口。
struct DailyStatisticsView: View {
    let studyDay: StudyDay
    @State private var model: DailyStatisticsViewModel

    init(studyDay: StudyDay, historyService: StudyHistoryService) {
        self.studyDay = studyDay
        _model = State(
            initialValue: DailyStatisticsViewModel(
                studyDay: studyDay,
                historyService: historyService
            )
        )
    }

    var body: some View {
        Group {
            if model.isLoading, model.snapshot == nil {
                ProgressView("正在载入统计…")
            } else if let snapshot = model.snapshot {
                List {
                    Section {
                        HStack(spacing: 16) {
                            VStack(spacing: 4) {
                                Text("\(snapshot.currentStreak)")
                                    .font(.title.bold())
                                    .monospacedDigit()
                                    .accessibilityIdentifier("statistics-streak-count")
                                Text("连续学习天数")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            Divider()
                            VStack(spacing: 4) {
                                Text("\(snapshot.activeDayCount)")
                                    .font(.title.bold())
                                    .monospacedDigit()
                                    .accessibilityIdentifier("statistics-active-days")
                                Text("近 30 天学习天数")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("最近 30 天") {
                        ForEach(snapshot.days) { day in
                            DailyStatisticsRow(day: day)
                        }
                    }
                }
                .refreshable {
                    await model.load()
                }
            } else {
                ContentUnavailableView(
                    "无法载入统计",
                    systemImage: "chart.bar.xaxis",
                    description: Text(model.errorMessage ?? "请稍后重试。")
                )
            }
        }
        .navigationTitle("每日统计")
        .navigationBarTitleDisplayMode(.inline)
        .secondaryPage()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .disabled(model.isLoading)
                .accessibilityIdentifier("statistics-refresh-button")
            }
        }
        .task {
            await model.load()
        }
        .alert(
            "刷新失败",
            isPresented: Binding(
                get: { model.snapshot != nil && model.errorMessage != nil },
                set: { shown in if !shown { model.errorMessage = nil } }
            )
        ) {
            Button("重试") { Task { await model.load() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }
}

private struct DailyStatisticsRow: View {
    let day: DailyStudyStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(day.localDate)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                Spacer()
                if !day.hasActivity {
                    Text("未学习")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if day.hasActivity {
                HStack(spacing: 12) {
                    Label("新学 \(day.newLearnedCount)", systemImage: "sparkle")
                    Label("复习 \(day.reviewedCardCount)", systemImage: "arrow.counterclockwise")
                    Label("回答 \(day.answerCount)", systemImage: "checkmark.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(
                        StudyTimeText.duration(milliseconds: day.durationMilliseconds),
                        systemImage: "clock"
                    )
                    HStack(spacing: 8) {
                        ForEach(ReviewRating.allCases, id: \.self) { rating in
                            Text("\(rating.title) \(day.ratings[rating])")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statistics-day-\(day.localDate)")
    }
}

@MainActor
@Observable
private final class DailyStatisticsViewModel {
    private let studyDay: StudyDay
    private let historyService: StudyHistoryService

    var snapshot: StudyStatisticsSnapshot?
    var isLoading = true
    var errorMessage: String?

    init(studyDay: StudyDay, historyService: StudyHistoryService) {
        self.studyDay = studyDay
        self.historyService = historyService
    }

    func load() async {
        isLoading = true
        do {
            snapshot = try await historyService.fetchDailyStatistics(
                endingAt: studyDay,
                dayCount: 30
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
