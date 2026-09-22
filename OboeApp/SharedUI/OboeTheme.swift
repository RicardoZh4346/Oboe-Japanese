import SwiftUI

enum OboeTheme {
    enum Colors {
        static let accent = Color("OboeBlue")
        static let cardBackground = Color("OboeCardBackground")
        static let pageBackground = Color(.systemGroupedBackground)
        /// 卡片上的次级说明文本：比 `.secondary` 略深，白卡上稳定
        /// 满足对比度审计（系统 secondary 在小字号抗锯齿下处于临界值）。
        static let secondaryOnCard = Color(.label).opacity(0.68)
    }

    enum Radius {
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 20
        static let card: CGFloat = 24
    }

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let cardPadding: CGFloat = 28
        static let cardPaddingCompact: CGFloat = 20
    }

    static let pageHorizontalPadding: CGFloat = 20
}

enum OboeFontStyle {
    case questionHeadword
    case answerHeadword
    case meaningZH
    case kana
    case exampleJapanese
    case hint
    case translation

    fileprivate var size: CGFloat {
        switch self {
        case .questionHeadword: 46
        case .answerHeadword: 42
        case .meaningZH: 21
        case .kana: 18
        case .exampleJapanese: 17
        case .hint: 16
        case .translation: 15
        }
    }

    fileprivate var weight: Font.Weight {
        switch self {
        case .questionHeadword, .answerHeadword, .meaningZH: .semibold
        case .hint: .medium
        case .kana, .exampleJapanese, .translation: .regular
        }
    }

    fileprivate var textStyle: Font.TextStyle {
        switch self {
        case .questionHeadword, .answerHeadword: .largeTitle
        case .meaningZH: .title3
        case .kana, .exampleJapanese: .body
        case .hint, .translation: .subheadline
        }
    }
}

private struct OboeFontModifier: ViewModifier {
    let style: OboeFontStyle
    @ScaledMetric private var size: CGFloat

    init(_ style: OboeFontStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.textStyle)
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: style.weight, design: .default))
    }
}

extension View {
    func oboeFont(_ style: OboeFontStyle) -> some View {
        modifier(OboeFontModifier(style))
    }
}
