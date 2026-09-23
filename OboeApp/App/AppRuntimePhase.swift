import Foundation

/// 运行期阶段。服务创建成功后一次性发布非可选的 `AppFeatureContainer`——
/// UI 只会看到 launching / ready / failed，永远观察不到半初始化状态。
enum AppRuntimePhase {
    case launching
    case ready(AppFeatureContainer)
    case failed(message: String)
}
