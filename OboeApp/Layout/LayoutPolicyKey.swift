import SwiftUI

/// 布局策略环境键：由 Shell 边界（AppSceneRoot/Shell 容器）注入当前
/// 容器宽度解析结果；默认 compact——未注入时保持 iPhone 行为。
private struct LayoutPolicyKey: EnvironmentKey {
    static let defaultValue = LayoutPolicy(
        mode: .compact,
        readableContentMaxWidth: 760,
        editorMaxWidth: 680,
        reviewMaxWidth: 720,
        columnSpacing: 24
    )
}

extension EnvironmentValues {
    var layoutPolicy: LayoutPolicy {
        get { self[LayoutPolicyKey.self] }
        set { self[LayoutPolicyKey.self] = newValue }
    }
}
