import Foundation

/// Decks 区 sidebar 选择：内置词库、收藏、搜索或某个牌组。
enum DeckSidebarSelection: Hashable {
    case library
    case favorites
    case search
    case deck(UUID)
}

/// Settings 区二级路由：regular 壳层下作为 detail 列选择，
/// compact 壳层下继续由现有 NavigationLink push 承载。
enum SettingsRoute: Hashable {
    case appearance
    case speech
    case adaptive
    case ai
    case backup
    case about
}

/// typed route 词汇表：逐步替换闭包型 NavigationLink，使 push 状态可恢复。
/// 首轮只声明与现有 `navigationDestination` 对应的载荷，不改调用点语义。
enum AppRoute: Hashable {
    /// Today 页 push 到复习页（现有 `navigationDestination(for: StudyScope.self)`）。
    case review(StudyScope)
    /// Decks 页 push 到牌组详情（现有 `navigationDestination(for: UUID.self)`）。
    case deck(UUID)
}
