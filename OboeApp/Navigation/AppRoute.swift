import Foundation

/// Decks 区 sidebar 选择：内置词库、收藏、搜索或某个牌组。
enum DeckSidebarSelection: Hashable {
    case library
    case favorites
    case search
    case deck(UUID)
}

/// Settings 区二级路由：regular 壳层下 content 列为分类列表、detail
/// 列渲染对应表单；compact 壳层下 `SettingsView` 仍以单 List 承载全部
/// 分类（filter=nil）。
enum SettingsRoute: Hashable, CaseIterable {
    case appearance
    case learning
    case speech
    case adaptive
    case ai
    case backup
    case about

    var title: String {
        switch self {
        case .appearance: "外观"
        case .learning: "学习计划"
        case .speech: "发音与回忆"
        case .adaptive: "主动回忆与易错卡"
        case .ai: "AI 服务"
        case .backup: "数据与快照"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush"
        case .learning: "calendar.day.timeline.left"
        case .speech: "speaker.wave.2"
        case .adaptive: "brain.head.profile"
        case .ai: "sparkles"
        case .backup: "externaldrive"
        case .about: "info.circle"
        }
    }
}

/// typed route 词汇表：逐步替换闭包型 NavigationLink，使 push 状态可恢复。
/// 首轮只声明与现有 `navigationDestination` 对应的载荷，不改调用点语义。
enum AppRoute: Hashable {
    /// Today 页 push 到复习页（现有 `navigationDestination(for: StudyScope.self)`）。
    case review(StudyScope)
    /// Decks 页 push 到牌组详情（现有 `navigationDestination(for: UUID.self)`）。
    case deck(UUID)
}
