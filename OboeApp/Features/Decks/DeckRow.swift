import OboeDomain
import OboeInfrastructure
import SwiftUI

struct DeckRow: View {
    let deck: DeckSummary
    let today: DeckTodayTaskCount
    let isPrimary: Bool
    /// v0.7.5 S18：学习进度聚合（nil = 观察流未发射/依赖缺席 →
    /// 隐藏进度行，不显示「0%」误导）。
    let learningProgress: DeckLearningProgress?

    init(
        deck: DeckSummary,
        today: DeckTodayTaskCount,
        isPrimary: Bool,
        learningProgress: DeckLearningProgress? = nil
    ) {
        self.deck = deck
        self.today = today
        self.isPrimary = isPrimary
        self.learningProgress = learningProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(deck.name)
                    .font(.headline)
                if isPrimary {
                    Text("主牌组")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(OboeTheme.Colors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            OboeTheme.Colors.accent.opacity(0.12),
                            in: Capsule()
                        )
                }
            }
            HStack(spacing: 16) {
                Label("\(deck.noteCount) 个知识点", systemImage: "text.book.closed")
                Label("\(deck.cardCount) 张卡片", systemImage: "rectangle.on.rectangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("今日新词 \(today.newCount) · 复习 \(today.reviewCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("deck-today-counts-\(deck.id.uuidString)")
            if let learningProgress {
                // 词义数 = 去重 unit 覆盖数；progress nil（空 deck/
                // 全非词汇 deck）显示「—」而非 0%（契约 §5.1）。
                Text(
                    learningProgress.progress.map {
                        "词义 \(learningProgress.unitCount) · 学习进度 \(Int(($0 * 100).rounded()))%"
                    } ?? "词义 \(learningProgress.unitCount) · 学习进度 —"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "deck-progress-\(deck.id.uuidString)"
                )
            }
        }
        .padding(.vertical, 4)
    }
}
