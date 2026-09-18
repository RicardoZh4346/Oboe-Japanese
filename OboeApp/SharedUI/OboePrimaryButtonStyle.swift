import SwiftUI

struct OboePrimaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = OboeTheme.Radius.large
    var minHeight: CGFloat = 56
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .background(
                OboeTheme.Colors.accent,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == OboePrimaryButtonStyle {
    static var oboePrimary: OboePrimaryButtonStyle { OboePrimaryButtonStyle() }
}

#Preview("Light") {
    VStack(spacing: OboeTheme.Spacing.md) {
        Button("显示答案") {}
            .buttonStyle(.oboePrimary)
        Button("不可用") {}
            .buttonStyle(.oboePrimary)
            .disabled(true)
    }
    .padding(OboeTheme.pageHorizontalPadding)
    .background(OboeTheme.Colors.pageBackground)
}

#Preview("Dark + Accessibility XL") {
    Button("显示答案") {}
        .buttonStyle(.oboePrimary)
        .padding(OboeTheme.pageHorizontalPadding)
        .background(OboeTheme.Colors.pageBackground)
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.accessibility2)
}
