import SwiftUI

/// 由容器宽度和环境计算的布局策略。阈值是集中定义的可测试 token——
/// 任何业务页面不得自行复制这些数值，也不得回退到 UIScreen.main。
struct LayoutPolicy: Equatable, Sendable {
    /// 壳层模式：compact 走三 Tab push；regular/wide 走 NavigationSplitView。
    enum Mode: Equatable, Sendable {
        case compact
        case regular
        case wide
    }

    /// modal 呈现策略：由 `PresentationRole` 经 `presentation(for:)` 映射得到。
    enum Presentation: Equatable, Sendable {
        case sheet
        case popover
        case inspector
        case detail
    }

    let mode: Mode
    /// 可读正文的最大宽度（设置、词库详情等单列内容居中用）。
    let readableContentMaxWidth: CGFloat
    /// 编辑器/表单最大宽度——避免宽屏表单无限拉伸。
    let editorMaxWidth: CGFloat
    /// Review 聚焦页内容宽度（650～760pt 区间内的 policy token）。
    let reviewMaxWidth: CGFloat
    let columnSpacing: CGFloat

    var usesSplitNavigation: Bool { mode != .compact }

    func presentation(for role: PresentationRole) -> Presentation {
        switch (role, mode) {
        case (.quickPicker, .compact):
            return .sheet
        case (.quickPicker, .regular), (.quickPicker, .wide):
            return .popover
        case (.editor, .compact):
            return .sheet
        case (.editor, .regular), (.editor, .wide):
            // 首轮 editor 仍用居中大 sheet，不占 detail 列。
            return .sheet
        case (.inspector, .compact):
            return .sheet
        case (.inspector, .regular), (.inspector, .wide):
            return .inspector
        case (.blockingFlow, _):
            return .sheet
        case (.focusedWorkflow, _):
            return .sheet
        }
    }

    /// 宽度阈值 token：compact < 700，regular 700…1099，wide ≥ 1100。
    /// 环境明确 compact（Split View 1/3、iPhone）时直接取 compact。
    static let compactWidthLimit: CGFloat = 700
    static let wideWidthLimit: CGFloat = 1100

    static func resolve(
        containerWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize
    ) -> LayoutPolicy {
        let mode: Mode
        if horizontalSizeClass == .compact || containerWidth < compactWidthLimit {
            mode = .compact
        } else if containerWidth >= wideWidthLimit {
            mode = .wide
        } else {
            mode = .regular
        }
        // 特大字号下收窄内容上限，保证行长可读。
        let accessibilityScale = dynamicTypeSize.isAccessibilitySize ? 0.9 : 1.0
        return LayoutPolicy(
            mode: mode,
            readableContentMaxWidth: 760 * accessibilityScale,
            editorMaxWidth: 680 * accessibilityScale,
            reviewMaxWidth: 720,
            columnSpacing: 24
        )
    }
}
