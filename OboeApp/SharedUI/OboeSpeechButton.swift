import SwiftUI

struct OboeSpeechButton: View {
    let title: String?
    var systemImage: String = "speaker.wave.2.fill"
    var accessibilityLabel: String?
    let action: () -> Void

    init(
        _ title: String? = nil,
        systemImage: String = "speaker.wave.2.fill",
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Label(title, systemImage: systemImage)
                } else {
                    Image(systemName: systemImage)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(OboeTheme.Colors.accent)
            .padding(.horizontal, OboeTheme.Spacing.md)
            .frame(minHeight: 44)
            .background(
                OboeTheme.Colors.accent.opacity(0.12),
                in: RoundedRectangle(
                    cornerRadius: OboeTheme.Radius.medium,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: OboeTheme.Radius.medium,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title ?? "播放发音")
    }
}

#Preview("Light") {
    HStack(spacing: OboeTheme.Spacing.sm) {
        OboeSpeechButton(action: {})
        OboeSpeechButton("朗读例句", action: {})
    }
    .padding(OboeTheme.pageHorizontalPadding)
    .background(OboeTheme.Colors.pageBackground)
}

#Preview("Dark") {
    OboeSpeechButton("朗读例句", action: {})
        .padding(OboeTheme.pageHorizontalPadding)
        .background(OboeTheme.Colors.pageBackground)
        .environment(\.colorScheme, .dark)
}
