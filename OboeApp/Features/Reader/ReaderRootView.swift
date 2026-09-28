import OboeDomain
import SwiftUI

/// Reader 特性自适应壳层（S10）：
/// - compact 宽度：`NavigationStack` + 行 push 阅读页；
/// - regular 宽度：`NavigationSplitView`（sidebar 文档列表 → detail 阅读页）。
/// 由 TabRootView 等宿主以依赖注入创建。
struct ReaderRootView: View {
    private let dependencies: ReaderFeatureDependencies
    @State private var libraryModel: ReaderLibraryViewModel
    @State private var selection: UUID?
    @Environment(\.layoutPolicy) private var layoutPolicy

    init(dependencies: ReaderFeatureDependencies) {
        self.dependencies = dependencies
        _libraryModel = State(
            initialValue: ReaderLibraryViewModel(dependencies: dependencies)
        )
    }

    var body: some View {
        Group {
            if layoutPolicy.usesSplitNavigation {
                regularShell
            } else {
                compactShell
            }
        }
    }

    /// compact：栈 push；文档行自带 NavigationLink(value: UUID)。
    private var compactShell: some View {
        NavigationStack {
            ReaderLibraryView(model: libraryModel)
                .navigationDestination(for: UUID.self) { id in
                    ReaderView(
                        model: ReaderDocumentViewModel(
                            documentID: id, dependencies: dependencies
                        ),
                        mining: dependencies.mining
                    )
                }
        }
    }

    /// regular：列选择模式——行回调写入 selection，detail 跟随。
    private var regularShell: some View {
        NavigationSplitView {
            ReaderLibraryView(model: libraryModel) { id in
                selection = id
            }
        } detail: {
            if let selection {
                ReaderView(
                    model: ReaderDocumentViewModel(
                        documentID: selection, dependencies: dependencies
                    ),
                    mining: dependencies.mining
                )
                .id(selection)
            } else {
                OboeEmptyState(
                    systemImage: "book",
                    title: "选择一篇读物",
                    message: nil
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
