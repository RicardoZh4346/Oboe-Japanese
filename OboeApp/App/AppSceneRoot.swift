import OboeDomain
import OboeInfrastructure
import SwiftUI

/// 场景根：按运行期阶段分发到 compact 壳层（RootTabView）、错误页或
/// 加载页。数据库操作遮罩与外观偏好挂在这里——无论壳层形态如何都生效。
struct AppSceneRoot: View {
    let runtime: AppRuntimeController

    /// scene 级导航状态：selection/path 归本 WindowGroup 实例所有，
    /// 不放回 application 级 runtime。
    @State private var navigationState = SceneNavigationState()

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // 壳层边界采集容器尺寸，向全树注入 LayoutPolicy——业务页面
        // 只读 policy token，不自行测屏。
        GeometryReader { proxy in
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
                    .onAppear {
                        // 世代替换时清空绑定旧实体的 route/selection。
                        navigationState.databaseGenerationDidChange(
                            to: container.generation
                        )
                    }
                    .onChange(of: container.generation) { _, generation in
                        navigationState.databaseGenerationDidChange(to: generation)
                    }
                    .environment(navigationState)
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
            .environment(
                \.layoutPolicy,
                LayoutPolicy.resolve(
                    containerWidth: proxy.size.width,
                    horizontalSizeClass: horizontalSizeClass,
                    dynamicTypeSize: dynamicTypeSize
                )
            )
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
