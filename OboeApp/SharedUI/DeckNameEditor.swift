import OboeDomain
import SwiftUI

/// 新建/重命名牌组的通用 sheet：名称校验在 `DeckName` 内完成，
/// `onSave` 返回 true 才关闭。
struct DeckNameEditor: View {
    let title: String
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(
        title: String,
        initialName: String,
        onSave: @escaping (String) async -> Bool
    ) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var isNameValid: Bool {
        (try? DeckName(validating: name)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("牌组名称", text: $name)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .accessibilityIdentifier("deck-name-field")
                            .onSubmit(save)
                        if !name.isEmpty {
                            Button {
                                name = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清空牌组名称")
                            .accessibilityIdentifier("deck-name-clear-button")
                        }
                    }
                } footer: {
                    Text("名称不能为空，最多 \(DeckName.maximumLength) 个字符。")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!isNameValid || isSaving)
                        .accessibilityIdentifier("deck-name-save-button")
                }
            }
        }
    }

    private func save() {
        guard isNameValid, !isSaving else {
            return
        }
        isSaving = true
        Task {
            if await onSave(name) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}
