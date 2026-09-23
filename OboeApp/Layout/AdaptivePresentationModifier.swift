import SwiftUI

/// modal 语义角色：描述"这是什么性质的呈现"，具体形态交给
/// `LayoutPolicy.presentation(for:)` 按当前壳层决定。
enum PresentationRole: Hashable, Sendable {
    /// 牌组选择、短选项。
    case quickPicker
    /// 新建、编辑表单。
    case editor
    /// AI Provider、只读/轻编辑属性面板。
    case inspector
    /// 恢复确认、不可中断操作。
    case blockingFlow
    /// Review、AI 修卡等需要聚焦的完整流程。
    case focusedWorkflow
}

private struct AdaptivePresentationModifier<SheetContent: View>: ViewModifier {
    let role: PresentationRole
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheetContent: () -> SheetContent

    @Environment(\.layoutPolicy) private var layoutPolicy

    func body(content: Content) -> some View {
        switch layoutPolicy.presentation(for: role) {
        case .popover:
            content.popover(
                isPresented: $isPresented,
                content: sheetContent
            )
        case .inspector:
            content.inspector(
                isPresented: $isPresented,
                content: sheetContent
            )
        case .sheet, .detail:
            // detail 呈现策略在 PR 6+ 接入 SplitView detail 列；
            // 首轮仍落到 sheet 保持语义可用。
            content.sheet(
                isPresented: $isPresented,
                onDismiss: onDismiss,
                content: sheetContent
            )
        }
    }
}

extension View {
    /// 按 PresentationRole 自适应呈现：compact 一律 sheet（iPhone 行为
    /// 不变）；regular 下 quickPicker→popover、inspector→inspector。
    func adaptivePresentation<Content: View>(
        role: PresentationRole,
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(
            AdaptivePresentationModifier(
                role: role,
                isPresented: isPresented,
                onDismiss: onDismiss,
                sheetContent: content
            )
        )
    }
}
