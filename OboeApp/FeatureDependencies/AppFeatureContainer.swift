import Foundation
import OboeDomain
import OboeInfrastructure

/// ready 后一次性发布的 Feature 依赖容器。所有服务先在局部变量构造
/// 完整，再随 `phase = .ready(container)` 原子暴露给 UI；数据库替换后
/// `generation` 递增，驱动旧 View tree 失效重建。
struct AppFeatureContainer {
    let generation: Int
    let today: TodayFeatureDependencies
    let decks: DeckFeatureDependencies
    let settings: SettingsFeatureDependencies
    let shared: SharedFeatureDependencies
}
