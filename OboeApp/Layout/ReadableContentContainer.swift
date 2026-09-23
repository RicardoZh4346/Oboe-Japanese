import SwiftUI

/// 可读内容角色：决定内容宽度上限取自哪个 policy token。
enum ReadableContentRole: Hashable, Sendable {
    /// 正文/列表类可读内容。
    case article
    /// 表单/编辑器。
    case editor
    /// Review 聚焦页。
    case review
}

/// 将内容限制在 `LayoutPolicy` 的角色宽度 token 内并居中——宽屏下
/// 内容不无限拉伸，compact 下 token 大于可用宽度时自然占满。
struct ReadableContentContainer<Content: View>: View {
    let role: ReadableContentRole
    @ViewBuilder let content: Content

    @Environment(\.layoutPolicy) private var layoutPolicy

    var body: some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }

    private var maxWidth: CGFloat {
        switch role {
        case .article: layoutPolicy.readableContentMaxWidth
        case .editor: layoutPolicy.editorMaxWidth
        case .review: layoutPolicy.reviewMaxWidth
        }
    }
}
