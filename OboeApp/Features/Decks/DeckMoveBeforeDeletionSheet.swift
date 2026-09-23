import OboeDomain
import SwiftUI

struct DeckMoveBeforeDeletionSheet: View {
    let sourceDeck: DeckSummary
    let destinations: [DeckSummary]
    let onDelete: (UUID) async -> Bool
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List(destinations) { deck in
                Button {
                    moveAndDelete(to: deck.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(deck.name)
                        Text("目标现有 \(deck.noteCount) 个知识点、\(deck.cardCount) 张卡片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("deck-delete-move-destination-\(deck.id.uuidString)")
            }
            .navigationTitle("移动内容后删除")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("将移动“\(sourceDeck.name)”中的 \(sourceDeck.noteCount) 个知识点和 \(sourceDeck.cardCount) 张卡片；已是目标牌组成员的知识点不重复移动，卡片进度保留，评分历史仍记录原牌组。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
    }

    private func moveAndDelete(to destinationID: UUID) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            if await onDelete(destinationID) {
                onDeleted()
                dismiss()
            } else {
                isWorking = false
            }
        }
    }
}
