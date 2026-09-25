import SwiftUI
import UIKit

/// S11 导出分享：系统 Share Sheet（含 AirDrop/存储到文件）——
/// `completionWithItemsHandler` 回调即导出 lease 释放点，文件在
/// sheet 存活期间绝不删除；iPad 由外层 `.sheet` 提供 popover 锚点。
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            context.coordinator.completion(completed)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject {
        let completion: (Bool) -> Void

        init(completion: @escaping (Bool) -> Void) {
            self.completion = completion
        }
    }
}
