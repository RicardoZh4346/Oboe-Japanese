import OboeDomain
import OboeInfrastructure
import SwiftUI

/// 场景根：按运行期阶段分发到 compact 壳层（RootTabView）、错误页或
/// 加载页。数据库操作遮罩与外观偏好挂在这里——无论壳层形态如何都生效。
struct AppSceneRoot: View {
    let runtime: AppRuntimeController

    var body: some View {
        Group {
            switch runtime.phase {
            case .ready(let container):
                RootTabView(
                    container: container,
                    operations: runtime.operations,
                    jlptEnrichmentStatus: runtime.jlptEnrichmentStatus,
                    pendingContinueItemID: runtime.pendingContinueItemID,
                    sharedCapturesAwaitingImport: runtime.sharedCapturesAwaitingImport,
                    isDatabaseOperationInProgress: runtime.isDatabaseOperationInProgress
                )
            case .failed(let message):
                ContentUnavailableView(
                    "无法启动 Oboe",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(message)
                )
                .accessibilityIdentifier("app-launch-error")
            case .launching:
                ProgressView("正在打开本地资料库…")
                    .accessibilityIdentifier("app-loading")
            }
        }
        .disabled(runtime.isDatabaseOperationInProgress)
        .overlay {
            if runtime.isDatabaseOperationInProgress {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    ProgressView("正在安全替换资料库…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("database-restoration-progress")
                }
            }
        }
        .preferredColorScheme(runtime.appearancePreference.colorScheme)
    }
}

private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
