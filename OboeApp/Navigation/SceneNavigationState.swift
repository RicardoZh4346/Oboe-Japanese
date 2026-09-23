import Observation
import SwiftUI

/// 每个 WindowGroup 实例的导航状态：section、列选择、各 Tab 独立
/// NavigationPath。由 AppSceneRoot 创建持有——selection 是 scene 语义，
/// 不能放回 application 级 runtime。
///
/// 数据库替换后 `databaseGenerationDidChange` 清空一切引用旧实体的
/// route/selection，避免新容器渲染陈旧实体。
@MainActor
@Observable
final class SceneNavigationState {
    var section: AppSection = .today
    var selectedDeck: DeckSidebarSelection?
    var selectedNoteID: UUID?
    var selectedInboxItemID: UUID?
    var selectedSettingsRoute: SettingsRoute?
    var splitVisibility: NavigationSplitViewVisibility = .all
    var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    /// compact 壳层三 Tab 各自的栈路径；切 Tab 不丢深度。
    var todayPath = NavigationPath()
    var decksPath = NavigationPath()
    var settingsPath = NavigationPath()

    /// 当前导航状态对应的数据库世代。
    private(set) var generation = 0

    /// 数据库世代更新：清空绑定旧实体的 selection 与全部栈路径。
    /// 同一世代重复调用是 no-op。
    func databaseGenerationDidChange(to newGeneration: Int) {
        guard newGeneration != generation else { return }
        generation = newGeneration
        selectedDeck = nil
        selectedNoteID = nil
        selectedInboxItemID = nil
        todayPath = NavigationPath()
        decksPath = NavigationPath()
        settingsPath = NavigationPath()
    }

    /// 删除当前选中牌组后的 reducer：清空指向该牌组的 sidebar 选择，
    /// 同时清空 detail 选择——不能默认展示已删除实体。
    /// 删除的是别的牌组时，现有选择保持不变。
    func deckWasDeleted(_ deckID: UUID) {
        guard selectedDeck == .deck(deckID) else { return }
        selectedDeck = nil
        selectedNoteID = nil
    }

    /// compact 壳层的 Tab 选择与 section 的映射。
    func selectTab(_ section: AppSection) {
        self.section = section
    }
}
