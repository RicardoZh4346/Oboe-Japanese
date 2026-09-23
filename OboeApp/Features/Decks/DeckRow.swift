import OboeDomain
import SwiftUI

struct DeckRow: View {
    let deck: DeckSummary
    let today: DeckTodayTaskCount
    let isPrimary: Bool

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
        }
        .padding(.vertical, 4)
    }
}
