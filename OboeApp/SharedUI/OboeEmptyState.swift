import SwiftUI

struct OboeEmptyState: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var actionIdentifier: String?
    var stateIdentifier: String?

    var body: some View {
        VStack(spacing: OboeTheme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(
                    stateIdentifier ?? "oboe-empty-state-title"
                )
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.oboePrimary)
                    .frame(maxWidth: 240)
                    .padding(.top, OboeTheme.Spacing.xs)
                    .accessibilityIdentifier(
                        actionIdentifier ?? "oboe-empty-state-action-button"
                    )
            }
        }
        .padding(OboeTheme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("Light") {
    OboeEmptyState(
        systemImage: "tray",
        title: "收件箱是空的",
        message: "通过添加、分享或拍照把日语内容放到这里。",
        actionTitle: "立即添加",
        action: {}
    )
    .background(OboeTheme.Colors.pageBackground)
}

#Preview("Dark + Accessibility XL") {
    OboeEmptyState(
        systemImage: "tray",
        title: "收件箱是空的",
        message: "通过添加、分享或拍照把日语内容放到这里。"
    )
    .background(OboeTheme.Colors.pageBackground)
    .environment(\.colorScheme, .dark)
    .dynamicTypeSize(.accessibility2)
}
