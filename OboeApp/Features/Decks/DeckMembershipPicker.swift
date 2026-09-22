import OboeDomain
import SwiftUI

/// 多牌组选择的可编辑内容：勾选成员牌组 + 指定归属（home）牌组。
/// 约束：至少保留一个成员（移除最后一个成员的点击被禁用）；移除 home
/// 牌组时自动回退到列表顺序中的首个剩余成员。
struct DeckMembershipList: View {
    let decks: [DeckSummary]
    @Binding var selection: DeckMembershipSelection

    var body: some View {
        Section {
            ForEach(decks) { deck in
                let isMember = selection.deckIDs.contains(deck.id)
                let isHome = selection.homeDeckID == deck.id
                Button {
                    _ = selection.toggle(deckID: deck.id, decks: decks)
                } label: {
                    HStack {
                        Text(deck.name)
                            .foregroundStyle(.primary)
                        if isHome {
                            Text("归属")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                        }
                        Spacer()
                        Text("\(deck.noteCount) 个知识点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isMember {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .disabled(isMember && selection.deckIDs.count == 1)
                .accessibilityLabel(deck.name)
                .accessibilityValue(membershipValue(isMember: isMember, isHome: isHome))
                .accessibilityHint(
                    isMember && selection.deckIDs.count == 1
                        ? "至少需要保留一个牌组"
                        : "双击切换成员状态"
                )
                .accessibilityIdentifier("deck-membership-row-\(deck.id.uuidString)")
            }
        } header: {
            Text("成员牌组")
        } footer: {
            Text("至少选择一个牌组；卡片与复习进度在所有成员牌组间共享。")
        }

        Section {
            Picker("归属牌组", selection: homeBinding) {
                ForEach(decks.filter { selection.deckIDs.contains($0.id) }) { deck in
                    Text(deck.name).tag(deck.id as UUID?)
                }
            }
            .disabled(selection.deckIDs.isEmpty)
            .accessibilityIdentifier("deck-membership-home-picker")
        } footer: {
            Text("归属牌组决定新卡额度与全部任务复习的历史归因；切换归属不影响卡片与学习进度。")
        }
    }

    private var homeBinding: Binding<UUID?> {
        Binding(
            get: { selection.homeDeckID },
            set: { newValue in
                if let newValue, selection.deckIDs.contains(newValue) {
                    selection.homeDeckID = newValue
                }
            }
        )
    }

    private func membershipValue(isMember: Bool, isHome: Bool) -> String {
        switch (isMember, isHome) {
        case (true, true): "已选中，归属牌组"
        case (true, false): "已选中"
        default: "未选中"
        }
    }
}

/// Form 行：展示当前选择摘要并打开多牌组选择 sheet。取消不写入，
/// 完成才把草稿写回绑定。
struct DeckMembershipField: View {
    let decks: [DeckSummary]
    @Binding var selection: DeckMembershipSelection
    var rowAccessibilityID: String

    @State private var isPresented = false
    @State private var draft = DeckMembershipSelection()

    var body: some View {
        Button {
            draft = selection
            isPresented = true
        } label: {
            HStack {
                Text("牌组")
                    .foregroundStyle(.primary)
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(decks.isEmpty)
        .accessibilityIdentifier(rowAccessibilityID)
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                Form {
                    DeckMembershipList(decks: decks, selection: $draft)
                }
                .navigationTitle("选择牌组")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isPresented = false }
                            .accessibilityIdentifier("deck-membership-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            selection = draft.normalized(decks: decks)
                            isPresented = false
                        }
                        .disabled(draft.deckIDs.isEmpty)
                        .accessibilityIdentifier("deck-membership-done")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var summary: String {
        guard !selection.deckIDs.isEmpty else { return "未选择" }
        let homeName = decks.first(where: { $0.id == selection.homeDeckID })?.name
        if selection.deckIDs.count == 1 {
            return homeName ?? "1 个牌组"
        }
        return "\(selection.deckIDs.count) 个牌组 · 归属 \(homeName ?? "未指定")"
    }
}
