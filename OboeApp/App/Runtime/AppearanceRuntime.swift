import Foundation
import OboeDomain

/// 外观偏好运行期（技术文档 §10）：加载/持久化 appearance 的唯一
/// 入口。可观察值仍由 `AppRuntimeController.appearancePreference`
/// 发布——这里只做服务调用，不持有状态。
struct AppearanceRuntime {

    func load(
        using service: AppearancePreferencesService
    ) async throws -> AppAppearance {
        try await service.load(
            defaultTimeZoneID: TimeZone.autoupdatingCurrent.identifier
        )
    }

    func set(
        _ appearance: AppAppearance,
        using service: AppearancePreferencesService
    ) async throws -> AppAppearance {
        try await service.set(appearance)
    }
}
