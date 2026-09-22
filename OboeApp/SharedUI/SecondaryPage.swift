import SwiftUI

/// 二级页面统一修饰符（v0.5.5）：从「今日」「牌组」「设置」三个一级
/// Tab 页 push 出去的页面一律隐藏底部 Tab Bar。
///
/// iOS 上隐藏状态沿导航栈继承——二级页继续 push 的三级页（知识点
/// 详情、词条详情、AI 修卡建议预览等）同样不显示 Tab Bar，无需在
/// 每个深链页重复标注；返回一级页时系统自动恢复。
///
/// sheet / fullScreenCover 会覆盖整个窗口（含 Tab Bar），不需要
/// 使用本修饰符。
private struct SecondaryPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(.hidden, for: .tabBar)
    }
}

extension View {
    /// 标记本页为二级页面：隐藏底部 Tab Bar，返回一级页时自动恢复。
    func secondaryPage() -> some View {
        modifier(SecondaryPageModifier())
    }
}
