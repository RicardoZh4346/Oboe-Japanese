import OboeDomain
import OboeInfrastructure
import SwiftUI
import UIKit

/// 阅读正文原生桥（S10）：整章 `ReaderBlock` 渲染进一个 UITextView，
/// token 着色 + 点选 + 长按选择共存 + 辅助功能。
///
/// 渲染模型：块文本以 `\n\n` 拼接为一根 NSAttributedString；每个
/// `TokenHighlight` 映射为 `.foregroundColor`（按知识状态）+
/// `.link`（`oboe-reader-token://` 伪 URL，载荷 = blockID + utf16
/// range）。点词 = `shouldInteractWith URL` 回调（tap 命中 link
/// 属性自动触发——不与自定义手势竞争）；长按选择走系统
/// `isSelectable` 链路，两者天然共存。
///
/// 辅助功能：UITextView 本身是单一 accessibilityElement——整段朗读
/// 不会按单字碎；token link 出现在 VoiceOver 转子「链接」里，flick
/// 导航可在词粒度停靠并激活（走同一 onTokenTap），是词级可达的
/// 正确形态。
///
/// 位置恢复：restoreBlockOrdinal/restoreUTF16Offset → 组合串内
/// 定位字符偏移 → `scrollRangeToVisible`（块粒度，像素无关——
/// 字号/Dynamic Type 变化后依然落在同一块）。
struct ReaderTextView: UIViewRepresentable {

    /// 批量挖词选中 token 的渲染地址（块 + 块内 utf16 range）。
    /// 选中词换专属配色，用户能看见哪些已入队。
    struct TokenRef: Hashable, Sendable {
        let blockID: UUID
        let range: Range<Int>
    }

    /// token 着色 + link 所需的视图输入（VM 的 TokenHighlight 视图态）。
    let blocks: [ReaderBlock]
    let highlights: [UUID: [ReaderDocumentViewModel.TokenHighlight]]
    /// 批量挖词已入队的 token（正文里的选中态着色）。
    var selectedTokens: Set<TokenRef> = []
    /// 位置恢复目标（nil = 不滚动）；消费后 view 应清零回调由
    /// coordinator 内一次性执行。
    let restoreBlockOrdinal: Int?
    let restoreUTF16Offset: Int
    /// 顶部可见块/块内偏移回调（scrollViewDidScroll 驱动）。
    let onVisibleBlockChange: (Int, Int) -> Void
    /// token 命中回调。
    let onTokenTap: (UUID, Range<Int>) -> Void
    /// S13「挖句成卡」入口：系统文本选择菜单中的动作回调——
    /// 参数 = (blockID, 块内 utf16 选区)。nil = 菜单不注入该动作
    /// （挖词装配缺席时选段只是普通系统选择）。
    var onClozeSelection: ((UUID, Range<Int>) -> Void)? = nil
    /// 当前可见块的书签态（未用——书签按钮在 SwiftUI 侧）。
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(
            top: OboeTheme.Spacing.md,
            left: OboeTheme.pageHorizontalPadding,
            bottom: 240,  // 底部留白：末段可读区不被工具栏压住
            right: OboeTheme.pageHorizontalPadding
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = context.coordinator
        textView.accessibilityIdentifier = "reader-text-view"
        // 链接呈色与文字一致——点击目标由着色承担，不下划线不蓝。
        textView.linkTextAttributes = [:]
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.enqueueComposeIfNeeded(
            blocks: blocks,
            highlights: highlights,
            selectedTokens: selectedTokens,
            dynamicTypeSize: dynamicTypeSize,
            restoreBlockOrdinal: restoreBlockOrdinal,
            restoreUTF16Offset: restoreUTF16Offset,
            in: textView
        )
    }

    // MARK: - 组合

    /// 块 + 着色 → NSAttributedString + 每块的 NSRange 索引。
    /// 返回 ranges 按下标对应 blocks。
    /// nonisolated：长文全量组合（含逐 token 伪 URL）在 detached
    /// 任务里跑，不占主线程（S10 长粘贴文本卡死修复）。
    nonisolated static func compose(
        blocks: [ReaderBlock],
        highlights: [UUID: [ReaderDocumentViewModel.TokenHighlight]],
        selectedTokens: Set<TokenRef> = [],
        dynamicTypeSize: DynamicTypeSize
    ) -> (NSAttributedString, [NSRange]) {
        let baseFont = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .preferredFont(forTextStyle: .body)
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.paragraphSpacing = 10
        let composed = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for block in blocks {
            // 新输入已作废本次合成——提前退出，半截结果会被
            // 代次检查丢弃。
            if Task.isCancelled { break }
            if composed.length > 0 {
                composed.append(NSAttributedString(
                    string: "\n\n",
                    attributes: [
                        .font: baseFont, .paragraphStyle: paragraph,
                    ]
                ))
            }
            let start = composed.length
            let string = NSMutableAttributedString(
                string: block.text,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraph,
                ]
            )
            if let tokens = highlights[block.id] {
                for token in tokens {
                    guard token.utf16Range.lowerBound >= 0,
                          token.utf16Range.upperBound
                            <= block.text.utf16.count else {
                        continue
                    }
                    let nsRange = NSRange(
                        location: token.utf16Range.lowerBound,
                        length: token.utf16Range.count
                    )
                    let selected = selectedTokens.contains(TokenRef(
                        blockID: block.id, range: token.utf16Range
                    ))
                    // 批量挖词选中词压过知识状态色：紫前景+浅紫底纹，
                    // 与 known/learning/unknown/ignored 四色不混淆。
                    string.addAttribute(
                        .foregroundColor,
                        value: selected
                            ? Self.selectedColor
                            : Self.color(for: token.state),
                        range: nsRange
                    )
                    if selected {
                        string.addAttribute(
                            .backgroundColor,
                            value: Self.selectedBackground,
                            range: nsRange
                        )
                    }
                    // link 伪 URL 同时承担：点词命中 + VoiceOver 链接转子。
                    string.addAttribute(
                        .link,
                        value: Self.tokenURL(
                            blockID: block.id, range: token.utf16Range
                        ),
                        range: nsRange
                    )
                }
            }
            composed.append(string)
            ranges.append(NSRange(
                location: start, length: string.length
            ))
        }
        return (composed, ranges)
    }

    /// 状态图例颜色（§状态图例：known 默认色/learning 品牌蓝/
    /// unknown 强调橙/ignored 弱灰——色值不依赖暗色硬编码）。
    nonisolated static func color(
        for state: VocabularyKnowledgeState
    ) -> UIColor {
        switch state {
        case .known: UIColor.label
        case .learning: UIColor(OboeTheme.Colors.accent)
        case .unknown: .systemOrange
        case .ignored: .secondaryLabel
        }
    }

    /// 批量挖词选中态配色（区别于四态知识着色）。
    nonisolated static var selectedColor: UIColor { .systemPurple }
    nonisolated static var selectedBackground: UIColor {
        .systemPurple.withAlphaComponent(0.16)
    }

    nonisolated static func tokenURL(
        blockID: UUID, range: Range<Int>
    ) -> URL {
        URL(
            string:
                "oboe-reader-token://\(blockID.uuidString.lowercased())"
                + "/\(range.lowerBound)-\(range.upperBound)"
        )!
    }

    static func parseTokenURL(
        _ url: URL
    ) -> (blockID: UUID, range: Range<Int>)? {
        guard url.scheme == "oboe-reader-token",
              let blockID = UUID(uuidString: url.host ?? ""),
              let rangePart = url.pathComponents.last,
              let dash = rangePart.firstIndex(of: "-"),
              let lower = Int(rangePart[..<dash]),
              let upper = Int(rangePart[rangePart.index(after: dash)...])
        else { return nil }
        return (blockID, lower..<upper)
    }

    // MARK: - Coordinator

    /// compose 产物的跨任务边界搬运盒——串/ranges 构造后不再
    /// 可变，仅在生成线程写、主线程读各一次。
    private struct ComposedText: @unchecked Sendable {
        let string: NSAttributedString
        let ranges: [NSRange]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReaderTextView
        /// 块序 → 组合串 NSRange（compose 结果镜像）。
        var blockRanges: [NSRange] = []
        var pendingRestore: Int?
        var pendingRestoreOffset = 0
        /// 滚动回调节流：最后一次上报的块序 + 块内偏移。块内同块
        /// 小滚动不重报——@Observable 写内存位每帧触发会打满主线程。
        private var lastReportedOrdinal = -1
        private var lastReportedOffset = -1

        /// 已应用/合成中的输入：重复 updateUIView（进度条、
        /// Inspector 等无关属性刷新都会触发）不再全量重组——
        /// 长文 compose 是主线程级成本。
        private var composedBlocks: [ReaderBlock]?
        private var composedHighlights: [UUID: [
            ReaderDocumentViewModel.TokenHighlight
        ]]?
        private var composedSelection: Set<TokenRef>?
        private var composedTypeSize: DynamicTypeSize?
        /// 合成代次：新输入作废旧结果，后到的不许回写。
        private var composeGeneration = 0
        private var composeTask: Task<Void, Never>?

        init(_ parent: ReaderTextView) { self.parent = parent }

        /// 输入变化 → detached 合成 attributed 串（逐 token
        /// `URL(string:)` 在长文上是秒级主线程占用，必须离主）→
        /// 回主线程应用并触发恢复滚动。输入没变 → 完全跳过。
        func enqueueComposeIfNeeded(
            blocks: [ReaderBlock],
            highlights: [UUID: [ReaderDocumentViewModel.TokenHighlight]],
            selectedTokens: Set<TokenRef>,
            dynamicTypeSize: DynamicTypeSize,
            restoreBlockOrdinal: Int?,
            restoreUTF16Offset: Int,
            in textView: UITextView
        ) {
            guard composedBlocks != blocks
                || composedHighlights != highlights
                || composedSelection != selectedTokens
                || composedTypeSize != dynamicTypeSize
            else { return }
            composedBlocks = blocks
            composedHighlights = highlights
            composedSelection = selectedTokens
            composedTypeSize = dynamicTypeSize
            composeGeneration += 1
            let generation = composeGeneration
            composeTask?.cancel()
            let work = Task.detached(priority: .userInitiated) {
                let (string, ranges) = ReaderTextView.compose(
                    blocks: blocks,
                    highlights: highlights,
                    selectedTokens: selectedTokens,
                    dynamicTypeSize: dynamicTypeSize
                )
                return ComposedText(string: string, ranges: ranges)
            }
            composeTask = Task { [weak self, weak textView] in
                let result = await work.value
                guard let self, let textView,
                      generation == self.composeGeneration else { return }
                textView.attributedText = result.string
                self.blockRanges = result.ranges
                self.pendingRestore = restoreBlockOrdinal
                self.pendingRestoreOffset = restoreUTF16Offset
                // 恢复滚动在下一 runloop——attributedText 刚换、
                // layout 未就绪。
                if self.pendingRestore != nil {
                    self.performRestore(in: textView)
                }
            }
        }

        /// link 命中 → onTokenTap。iOS 17 起 text item 主动作取代
        /// `shouldInteractWith`（点按与 VoiceOver 链接激活都走这里）；
        /// 返回自定义 UIAction 即替代默认打开行为。
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case let .link(url) = textItem.content,
                  let hit = ReaderTextView.parseTokenURL(url)
            else { return defaultAction }
            return UIAction { [weak self] _ in
                self?.parent.onTokenTap(hit.blockID, hit.range)
            }
        }

        /// S13：系统编辑菜单注入「挖句成卡」。仅当选区**完整落在
        /// 单一块内**才出现（句截取以块为单位——跨块选段不做
        /// 单 blank cloze）；`onClozeSelection` 缺席 → 返回 nil，
        /// 系统菜单原样展示。
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let onClozeSelection = parent.onClozeSelection,
                  range.length > 0
            else { return nil }
            for (index, blockRange) in blockRanges.enumerated() {
                guard parent.blocks.indices.contains(index),
                      range.location >= blockRange.location,
                      NSMaxRange(range) <= NSMaxRange(blockRange)
                else { continue }
                let block = parent.blocks[index]
                let start = range.location - blockRange.location
                let rangeInBlock = start..<(start + range.length)
                let action = UIAction(title: "挖句成卡") { _ in
                    onClozeSelection(block.id, rangeInBlock)
                }
                return UIMenu(children: suggestedActions + [action])
            }
            return nil
        }

        /// 顶部可见字符 → 所在块序 + 块内 utf16 偏移。
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView,
                  textView.textStorage.length > 0 else { return }
            let topPoint = CGPoint(
                x: textView.textContainerInset.left
                    + textView.textContainer.lineFragmentPadding,
                y: scrollView.contentOffset.y
                    + textView.textContainerInset.top + 1
            )
            var charIndex = textView.layoutManager
                .characterIndex(
                    for: topPoint,
                    in: textView.textContainer,
                    fractionOfDistanceBetweenInsertionPoints: nil
                )
            charIndex = min(charIndex, textView.textStorage.length - 1)
            // 块范围按 location 单调递增——二分定位，长文数百块
            // 时滚动回调不再每次线性扫全表。
            var lo = 0
            var hi = blockRanges.count
            var hitIndex: Int?
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                let range = blockRanges[mid]
                if charIndex < range.location {
                    hi = mid
                } else if charIndex >= NSMaxRange(range) {
                    lo = mid + 1
                } else {
                    hitIndex = mid
                    break
                }
            }
            guard let index = hitIndex,
                  parent.blocks.indices.contains(index) else { return }
            let range = blockRanges[index]
            let offset = charIndex - range.location
            let block = parent.blocks[index]
            if block.ordinal != lastReportedOrdinal
                || abs(offset - lastReportedOffset) >= 64 {
                lastReportedOrdinal = block.ordinal
                lastReportedOffset = offset
                parent.onVisibleBlockChange(block.ordinal, offset)
            }
        }

        /// 恢复滚动：等下一次 layout pass 后跳到目标块的块内偏移。
        /// 只对目标字形范围请求布局——非连续布局模式下
        /// `ensureLayout(for: textContainer)` 会强制排完整章，
        /// 长文首次进入就在这里卡死。
        func performRestore(in textView: UITextView) {
            guard let ordinal = pendingRestore else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingRestore = nil
                guard let index = self.parent.blocks.firstIndex(where: {
                    $0.ordinal == ordinal
                }), self.blockRanges.indices.contains(index) else {
                    return
                }
                let range = self.blockRanges[index]
                let offset = min(
                    self.pendingRestoreOffset, range.length
                )
                let target = NSRange(
                    location: range.location + offset, length: 0
                )
                let layoutManager = textView.layoutManager
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: target, actualCharacterRange: nil
                )
                layoutManager.ensureLayout(forGlyphRange: glyphRange)
                var rect = layoutManager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: textView.textContainer
                )
                // boundingRect 是容器坐标——加上内边距才是滚动坐标；
                // 上方留一段视野让目标行不贴顶。
                rect = rect.offsetBy(
                    dx: textView.textContainerInset.left
                        + textView.textContainer.lineFragmentPadding,
                    dy: textView.textContainerInset.top
                ).insetBy(dx: 0, dy: -80)
                textView.scrollRectToVisible(rect, animated: false)
            }
        }
    }
}
