import SwiftUI
import UIKit
import Observation

/// CompactShell 持有可观察显隐状态；导航操作开始时同步更新，避免
/// pop 结束后才移除目的地 toolbar 偏好造成内容再次改变 safe area。
@MainActor
@Observable
final class NavigationTabBarVisibility {
    var isHidden = false
}

private struct SecondaryPageModifier: ViewModifier {
    @Environment(NavigationTabBarVisibility.self) private var visibility: NavigationTabBarVisibility?

    func body(content: Content) -> some View {
        if visibility != nil {
            content.background(TabBarHidesOnPush())
        } else {
            content.toolbar(.hidden, for: .tabBar)
                .background(TabBarHidesOnPush())
        }
    }
}

private struct PrimaryPageModifier: ViewModifier {
    @Environment(NavigationTabBarVisibility.self) private var visibility: NavigationTabBarVisibility?

    func body(content: Content) -> some View {
        if let visibility {
            content
                .toolbar(visibility.isHidden ? .hidden : .visible, for: .tabBar)
                .background(TabBarHidesOnPush(rootVisibility: visibility))
        } else {
            content
        }
    }
}

/// iOS 26/27 实测：`TabBarHidesOnPush` 的标记时机是被 push VC 首次
/// 视图加载——而 UITabBarController 在 `pushViewController` 调用当下
/// 就查询目标 VC 的 `hidesBottomBarWhenPushed`。标记晚于查询时
/// push 进栈不带隐藏标志，pop 返回时 bar 走 SwiftUI 偏好恢复路径
/// （转场结束后才出现，表现为 bar 晚到 + 整页内容上移）。
///
/// 确定性修法：在 `pushViewController` 执行前把标志落位。本 App 所
/// 有 push 目标页都是二级页（`.secondaryPage()`），统一标记没有
/// 误伤面；iPad/侧栏壳层没有 UITabBarController，标志天然无效。
@MainActor
enum SecondaryPageTabBarHook {
    private static var installed = false
    private static var visibilityKey: UInt8 = 0

    static func register(_ visibility: NavigationTabBarVisibility, on navigation: UINavigationController) {
        objc_setAssociatedObject(navigation, &visibilityKey, visibility, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func update(_ navigation: UINavigationController, destination: UIViewController?, root: UIViewController? = nil) {
        guard let visibility = objc_getAssociatedObject(navigation, &visibilityKey) as? NavigationTabBarVisibility,
              let destination else { return }
        visibility.isHidden = destination !== (root ?? navigation.viewControllers.first)
    }

    static func settle(_ navigation: UINavigationController) {
        update(navigation, destination: navigation.topViewController)
        // 包括交互返回取消；最终以真实栈顶校正，防止 bar 留在错误状态。
        navigation.transitionCoordinator?.animate(alongsideTransition: nil) { [weak navigation] _ in
            guard let navigation else { return }
            MainActor.assumeIsolated {
                update(navigation, destination: navigation.topViewController)
            }
        }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UINavigationController.self
        let pairs: [(Selector, Selector)] = [
            (#selector(UINavigationController.pushViewController(_:animated:)),
             #selector(UINavigationController.oboe_pushViewController(_:animated:))),
            (#selector(UINavigationController.setViewControllers(_:animated:)),
             #selector(UINavigationController.oboe_setViewControllers(_:animated:))),
            (#selector(UINavigationController.popViewController(animated:)),
             #selector(UINavigationController.oboe_popViewController(animated:))),
            (#selector(UINavigationController.popToRootViewController(animated:)),
             #selector(UINavigationController.oboe_popToRootViewController(animated:))),
            (#selector(UINavigationController.popToViewController(_:animated:)),
             #selector(UINavigationController.oboe_popToViewController(_:animated:))),
        ]
        let methods = pairs.compactMap { original, hooked -> (Method, Method)? in
            guard let originalMethod = class_getInstanceMethod(cls, original),
                  let hookedMethod = class_getInstanceMethod(cls, hooked) else { return nil }
            return (originalMethod, hookedMethod)
        }
        guard methods.count == pairs.count else { return }
        for (original, hooked) in methods { method_exchangeImplementations(original, hooked) }
    }
}

private extension UINavigationController {
    @objc func oboe_pushViewController(
        _ viewController: UIViewController, animated: Bool
    ) {
        viewController.hidesBottomBarWhenPushed = !viewControllers.isEmpty
        SecondaryPageTabBarHook.update(self, destination: viewController)
        // 实现已与系统方法交换——这是原 pushViewController。
        oboe_pushViewController(viewController, animated: animated)
        SecondaryPageTabBarHook.settle(self)
    }

    @objc func oboe_setViewControllers(
        _ viewControllers: [UIViewController], animated: Bool
    ) {
        // 标全部非根控制器——根（各 Tab 的一级页）必须保持 false，
        // 否则 Tab 首页会跟着藏 bar。本 App 一切非根页都是二级页。
        for controller in viewControllers.dropFirst() {
            controller.hidesBottomBarWhenPushed = true
        }
        if let visibility = viewControllers.last {
            SecondaryPageTabBarHook.update(self, destination: visibility, root: viewControllers.first)
        }
        oboe_setViewControllers(viewControllers, animated: animated)
        SecondaryPageTabBarHook.settle(self)
    }

    @objc func oboe_popViewController(animated: Bool) -> UIViewController? {
        let destination = viewControllers.dropLast().last
        SecondaryPageTabBarHook.update(self, destination: destination)
        let popped = oboe_popViewController(animated: animated)
        SecondaryPageTabBarHook.settle(self)
        return popped
    }

    @objc func oboe_popToRootViewController(animated: Bool) -> [UIViewController]? {
        SecondaryPageTabBarHook.update(self, destination: viewControllers.first)
        let popped = oboe_popToRootViewController(animated: animated)
        SecondaryPageTabBarHook.settle(self)
        return popped
    }

    @objc func oboe_popToViewController(_ controller: UIViewController, animated: Bool) -> [UIViewController]? {
        if viewControllers.contains(controller) {
            SecondaryPageTabBarHook.update(self, destination: controller)
        }
        let popped = oboe_popToViewController(controller, animated: animated)
        SecondaryPageTabBarHook.settle(self)
        return popped
    }
}

/// 把 `hidesBottomBarWhenPushed` 标到承载本页的被 push VC 上。
/// 沿 parent 链向上找到 UINavigationController 的直接子 VC——即
/// 导航栈里真正被 push 的那个控制器。
private struct TabBarHidesOnPush: UIViewControllerRepresentable {
    var rootVisibility: NavigationTabBarVisibility? = nil

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.rootVisibility = rootVisibility
        return anchor
    }
    func updateUIViewController(
        _ uiViewController: Anchor, context: Context
    ) {
        uiViewController.rootVisibility = rootVisibility
        uiViewController.applyIfNeeded()
    }

    final class Anchor: UIViewController {
        var rootVisibility: NavigationTabBarVisibility?
        private var applied = false

        func applyIfNeeded() {
            var pushed = parent
            while let next = pushed?.parent,
                  !(next is UINavigationController) {
                pushed = next
            }
            guard let pushed, let navigation = pushed.parent as? UINavigationController else { return }
            if let rootVisibility {
                SecondaryPageTabBarHook.register(rootVisibility, on: navigation)
            } else {
                pushed.hidesBottomBarWhenPushed = pushed !== navigation.viewControllers.first
            }
            applied = true
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyIfNeeded()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyIfNeeded()
            if let navigation = navigationController {
                // 交互式手势也可能绕开 pop API；用出现目标提前同步。
                var destination: UIViewController = self
                while let parent = destination.parent, !(parent is UINavigationController) {
                    destination = parent
                }
                SecondaryPageTabBarHook.update(navigation, destination: destination)
                navigation.transitionCoordinator?.animate(alongsideTransition: nil) { [weak navigation] _ in
                    guard let navigation else { return }
                    MainActor.assumeIsolated {
                        SecondaryPageTabBarHook.update(navigation, destination: navigation.topViewController)
                    }
                }
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if !applied { applyIfNeeded() }
        }
    }
}

extension View {
    func primaryPage() -> some View {
        modifier(PrimaryPageModifier())
    }

    /// 标记本页为二级页面：隐藏底部 Tab Bar，返回一级页时自动恢复。
    func secondaryPage() -> some View {
        modifier(SecondaryPageModifier())
    }
}
