import SwiftUI

/// regular 壳层下 Settings 区的 content 列：分类列表，选中项写进
/// `SceneNavigationState.selectedSettingsRoute`，detail 列渲染对应
/// `SettingsView(categoryFilter:)`。compact 壳层不使用本视图——
/// `SettingsView` 仍以单 List 承载全部分类。
struct SettingsCategoryListView: View {
    @Binding var selection: SettingsRoute?

    var body: some View {
        List(SettingsRoute.allCases, id: \.self, selection: $selection) { route in
            Label(route.title, systemImage: route.systemImage)
                .tag(route)
                .accessibilityIdentifier("settings-category-\(route.identifier)")
        }
        .navigationTitle("设置")
        .accessibilityIdentifier("settings-category-list")
    }
}

private extension SettingsRoute {
    /// 可访问性/冒烟测试用的稳定标识。
    var identifier: String {
        switch self {
        case .appearance: "appearance"
        case .learning: "learning"
        case .speech: "speech"
        case .adaptive: "adaptive"
        case .ai: "ai"
        case .backup: "backup"
        case .about: "about"
        }
    }
}
