import Foundation

/// 顶层 Feature 分区。compact 壳层映射为三 Tab；regular 壳层映射为
/// NavigationSplitView sidebar 项。Inbox 首版仍挂在 Today 之下。
enum AppSection: Hashable {
    case today
    case decks
    case settings
}
