import SwiftUI

struct OboeCardSurface<Content: View>: View {
    var padding: CGFloat = OboeTheme.Spacing.cardPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(
                OboeTheme.Colors.cardBackground,
                in: RoundedRectangle(
                    cornerRadius: OboeTheme.Radius.card,
                    style: .continuous
                )
            )
    }
}

#Preview("Light") {
    OboeCardSurface {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
            Text("食べる").oboeFont(.questionHeadword)
            Text("たべる").oboeFont(.kana).foregroundStyle(.secondary)
        }
    }
    .padding(OboeTheme.pageHorizontalPadding)
    .background(OboeTheme.Colors.pageBackground)
}

#Preview("Dark + Accessibility XL") {
    OboeCardSurface {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
            Text("食べる").oboeFont(.questionHeadword)
            Text("たべる").oboeFont(.kana).foregroundStyle(.secondary)
        }
    }
    .padding(OboeTheme.pageHorizontalPadding)
    .background(OboeTheme.Colors.pageBackground)
    .environment(\.colorScheme, .dark)
    .dynamicTypeSize(.accessibility2)
}
