import Foundation

/// 顶层 Feature 分区。compact 壳层映射为三 Tab（Inbox 仍挂 Today
/// 之下）；regular 壳层映射为 NavigationSplitView sidebar 项——
/// Inbox 在 regular 提升为一级 section（列表详情两列）。
enum AppSection: Hashable {
    case today
    case decks
    case inbox
    case settings
}
