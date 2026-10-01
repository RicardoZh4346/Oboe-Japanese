import OboeDomain
import SwiftUI

/// Reader 特性自适应壳层（S10）：
/// - compact 宽度：`NavigationStack` + 行 push 阅读页；
/// - regular 宽度：`NavigationSplitView`（sidebar 文档列表 → detail 阅读页）。
/// 由 TabRootView 等宿主以依赖注入创建。
///
/// v0.7.5 S18：可选注入 scene `SceneNavigationState`——compact 栈
/// 路径绑定 `readerPath`（Deck→Reader 的 `openReaderDocument` 压栈
/// 即push）、regular 列选择读写 `selectedReaderDocumentID`，「打开
/// 牌组」入口经 `openDeck` 跨区路由。nil（测试/预览）→ 全部退回
/// 本地态，行为与旧版一致。
struct ReaderRootView: View {
    private let dependencies: ReaderFeatureDependencies
    private let navigation: SceneNavigationState?
    @State private var libraryModel: ReaderLibraryViewModel
    @State private var selection: UUID?
    /// navigation 缺席时的本地栈路径。
    @State private var localPath = NavigationPath()
    @Environment(\.layoutPolicy) private var layoutPolicy

    init(
        dependencies: ReaderFeatureDependencies,
        navigation: SceneNavigationState? = nil
    ) {
        self.dependencies = dependencies
        self.navigation = navigation
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

    /// compact 栈路径：有 scene 导航时绑到 `readerPath`——
    /// `openReaderDocument` 压栈即 push；无导航则本地栈。
    private var pathBinding: Binding<NavigationPath> {
        if let navigation {
            return Binding(
                get: { navigation.readerPath },
                set: { navigation.readerPath = $0 }
            )
        }
        return $localPath
    }

    /// regular 列选择：有 scene 导航时读写
    /// `selectedReaderDocumentID`（Deck→Reader 路由直接写它）。
    private var selectionBinding: Binding<UUID?> {
        if let navigation {
            return Binding(
                get: { navigation.selectedReaderDocumentID },
                set: { navigation.selectReaderDocument(id: $0) }
            )
        }
        return $selection
    }

    /// 「打开学习牌组」回调：有 scene 导航走 `openDeck` 跨区路由。
    private var openDeck: ((UUID) -> Void)? {
        navigation.map { nav in { nav.openDeck($0) } }
    }

    private func documentWasDeleted(_ documentID: UUID) {
        navigation?.readerDocumentWasDeleted(documentID)
    }

    /// compact：栈 push；文档行自带 NavigationLink(value: UUID)。
    private var compactShell: some View {
        NavigationStack(path: pathBinding) {
            ReaderLibraryView(
                model: libraryModel,
                onOpenDeck: openDeck,
                onDocumentDeleted: documentWasDeleted
            )
                .primaryPage()
                .navigationDestination(for: UUID.self) { id in
                    ReaderView(
                        model: ReaderDocumentViewModel(
                            documentID: id, dependencies: dependencies
                        ),
                        mining: dependencies.mining,
                        aiStudy: dependencies.aiStudy,
                        translation: dependencies.translation,
                        onOpenDeck: openDeck
                    )
                }
        }
    }

    /// regular：列选择模式——行回调写入 selection，detail 跟随。
    private var regularShell: some View {
        NavigationSplitView {
            ReaderLibraryView(
                model: libraryModel,
                selectInSplit: { id in selectionBinding.wrappedValue = id },
                onOpenDeck: openDeck,
                onDocumentDeleted: documentWasDeleted
            )
        } detail: {
            if let documentID = selectionBinding.wrappedValue {
                ReaderView(
                    model: ReaderDocumentViewModel(
                        documentID: documentID, dependencies: dependencies
                    ),
                    mining: dependencies.mining,
                    aiStudy: dependencies.aiStudy,
                    translation: dependencies.translation,
                    onOpenDeck: openDeck
                )
                .id(documentID)
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
