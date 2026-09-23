import OboeDomain
import OboeInfrastructure
import OboeSharedCapture
import SwiftUI

@main
struct OboeApp: App {
    @State private var runtime = AppRuntimeController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppSceneRoot(runtime: runtime)
                .modifier(UITestTraitOverrideModifier())
                .task {
                    await runtime.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await runtime.drainSharedCaptures() }
                    case .background:
                        Task { await runtime.createDailySnapshotIfNeeded() }
                    default:
                        break
                    }
                }
        }
    }
}

/// DEBUG-only UI-test trait override (T14): `OBOE_UI_TEST_DYNAMIC_TYPE`
/// forces a Dynamic Type size (e.g. `ax5`) so layout/accessibility-size
/// branches can be exercised in simulator UI tests without changing
/// persisted settings. Reduce Motion is a read-only trait and stays on the
/// real-device checklist (T28). The override is a no-op in release builds
/// and when the variable is absent or unrecognized.
private struct UITestTraitOverrideModifier: ViewModifier {
    #if DEBUG
    private static var dynamicTypeSize: DynamicTypeSize? {
        switch ProcessInfo.processInfo.environment["OBOE_UI_TEST_DYNAMIC_TYPE"] {
        case "extraLarge", "xl": return .xLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1", "ax1": return .accessibility1
        case "accessibility3", "ax3": return .accessibility3
        case "accessibility5", "ax5": return .accessibility5
        default: return nil
        }
    }

    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        if let size = Self.dynamicTypeSize {
            content.environment(\.dynamicTypeSize, size)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
