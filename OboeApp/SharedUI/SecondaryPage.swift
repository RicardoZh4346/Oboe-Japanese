import SwiftUI
import UIKit

/// 二级页面统一修饰符（v0.5.5）：从「今日」「牌组」「设置」三个一级
/// Tab 页 push 出去的页面一律隐藏底部 Tab Bar。
///
/// iOS 上隐藏状态沿导航栈继承——二级页继续 push 的三级页（知识点
/// 详情、词条详情、AI 修卡建议预览等）同样不显示 Tab Bar，无需在
/// 每个深链页重复标注；返回一级页时系统自动恢复。
///
/// 隐藏只走 UIKit `hidesBottomBarWhenPushed`（由 `SecondaryPageTabBarHook`
/// 在 push 当下落位，Anchor 兜底），Tab Bar 的隐藏/恢复都随导航转场
/// 同步执行。**不要再叠加** `.toolbar(.hidden, for: .tabBar)`——SwiftUI
/// 的 tabBar 偏好在 pop 转场结束后才结算恢复，双轨并用时它会盖过
/// UIKit 路径，表现为 bar 晚到 + 整页内容上移（iOS 26/27 实测）。
///
/// sheet / fullScreenCover 会覆盖整个窗口（含 Tab Bar），不需要
/// 使用本修饰符。
private struct SecondaryPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TabBarHidesOnPush())
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

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UINavigationController.self
        guard let original = class_getInstanceMethod(
            cls,
            #selector(UINavigationController.pushViewController(
                _:animated:))),
            let hooked = class_getInstanceMethod(
                cls,
                #selector(UINavigationController
                    .oboe_pushViewController(_:animated:))),
            let originalSet = class_getInstanceMethod(
                cls,
                #selector(UINavigationController.setViewControllers(
                    _:animated:))),
            let hookedSet = class_getInstanceMethod(
                cls,
                #selector(UINavigationController
                    .oboe_setViewControllers(_:animated:)))
        else { return }
        method_exchangeImplementations(original, hooked)
        // `pushViewController` 不是唯一入栈口：NavigationStack 的快照
        // 恢复/批量替换会走 `setViewControllers`——只钩 push 时该路径
        // 仍丢标志，pop 返回后 Tab Bar 出现延迟复发（真机复现）。
        method_exchangeImplementations(originalSet, hookedSet)
    }
}

private extension UINavigationController {
    @objc func oboe_pushViewController(
        _ viewController: UIViewController, animated: Bool
    ) {
        viewController.hidesBottomBarWhenPushed = true
        // 实现已与系统方法交换——这是原 pushViewController。
        oboe_pushViewController(viewController, animated: animated)
    }

    @objc func oboe_setViewControllers(
        _ viewControllers: [UIViewController], animated: Bool
    ) {
        // 标全部非根控制器——根（各 Tab 的一级页）必须保持 false，
        // 否则 Tab 首页会跟着藏 bar。本 App 一切非根页都是二级页。
        for controller in viewControllers.dropFirst() {
            controller.hidesBottomBarWhenPushed = true
        }
        oboe_setViewControllers(viewControllers, animated: animated)
    }
}

/// 把 `hidesBottomBarWhenPushed` 标到承载本页的被 push VC 上。
/// 沿 parent 链向上找到 UINavigationController 的直接子 VC——即
/// 导航栈里真正被 push 的那个控制器。
private struct TabBarHidesOnPush: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Anchor { Anchor() }
    func updateUIViewController(
        _ uiViewController: Anchor, context: Context
    ) {
        uiViewController.applyIfNeeded()
    }

    final class Anchor: UIViewController {
        private var applied = false

        func applyIfNeeded() {
            var pushed = parent
            while let next = pushed?.parent,
                  !(next is UINavigationController) {
                pushed = next
            }
            pushed?.hidesBottomBarWhenPushed = true
            applied = pushed != nil
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyIfNeeded()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if !applied { applyIfNeeded() }
        }
    }
}

extension View {
    /// 标记本页为二级页面：隐藏底部 Tab Bar，返回一级页时自动恢复。
    func secondaryPage() -> some View {
        modifier(SecondaryPageModifier())
    }
}
