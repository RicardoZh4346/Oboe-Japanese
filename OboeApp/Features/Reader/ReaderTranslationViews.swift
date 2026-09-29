import OboeDomain
import OboeInfrastructure
import SwiftUI

/// 双语模式注入 `ReaderTextView` 的译文段（VM/UIView 共享——
/// 不嵌套在任一类型下，避免视图层反向依赖 VM）。
enum ReaderTranslationSegment: Equatable, Sendable {
    /// 译文正文。
    case text(String)
    /// 部分覆盖：已译片段正文 + 缺段占位（点按补译本段）。
    case partial(text: String)
    /// 折叠态占位（点按展开）。
    case collapsed
    /// 无译文占位（点按翻译本段）。
    case missing
    /// 失败占位（点按重试）。
    case failed
    /// 在途占位（不可点）。
    case requesting
}

/// S17 纯译文模式（§14.2 译文档）：按原文块序逐段译文。
///
/// - 行锚 = 原文块序（与 `ReaderTextView` 的源块坐标系同源）——
///   译文行复用 `ReaderTranslationLocator` 序数语义，滚动/模式切换
///   都按 blockOrdinal 定位，译文不引入第二套坐标。
/// - 缺译/过期/失败 → 行内占位：明确原因 + 「查看原文」内联展开 +
///   「翻译本段/重试」——缺失不静默、失败不丢旧译文（重试只显式
///   触发）。
/// - `scrollPosition(id:)` 与 `scrollTargetLayout`：LazyVStack 天然
///   懒装载（分块/懒加载要求），顶层锚随滚动上报、模式切换下发。
struct ReaderTranslatedOnlyList: View {
    let blocks: [ReaderBlock]
    let model: ReaderTranslationViewModel
    /// 顶层可见块序上报（位置保存 + 模式切换锚共用）。
    let onTopBlockChange: (Int) -> Void
    /// 外部下发的滚动锚（模式切换/恢复目标——nil = 无）。
    let scrollAnchor: Int?
    let onTranslate: (UUID) -> Void
    let onRetry: (UUID) -> Void
    let onRetranslate: (UUID) -> Void

    /// 「查看原文」内联展开的块。
    @State private var expandedOriginal: Set<UUID> = []
    /// 顶层锚（scrollPosition 绑定——值 = 块序）。
    @State private var topOrdinal: Int?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    row(for: block)
                        .padding(
                            .horizontal, OboeTheme.pageHorizontalPadding)
                        .padding(.vertical, OboeTheme.Spacing.sm)
                        .id(block.ordinal)
                }
                Spacer(minLength: 240)  // 末段可读区不被工具栏压住
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $topOrdinal)
        .onAppear {
            topOrdinal = scrollAnchor ?? blocks.first?.ordinal
        }
        .onChange(of: scrollAnchor) { _, anchor in
            if let anchor, topOrdinal != anchor { topOrdinal = anchor }
        }
        .onChange(of: topOrdinal) { _, ordinal in
            if let ordinal { onTopBlockChange(ordinal) }
        }
        // 章切换（blocks 换）→ 回到章首或恢复锚。
        .onChange(of: blocks) { _, _ in
            topOrdinal = scrollAnchor ?? blocks.first?.ordinal
        }
        .background(OboeTheme.Colors.pageBackground)
        .accessibilityIdentifier("reader-translated-list")
    }

    @ViewBuilder
    private func row(for block: ReaderBlock) -> some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
            switch model.renderState(for: block.id) {
            case .requesting:
                HStack(spacing: OboeTheme.Spacing.xs) {
                    ProgressView()
                    Text("翻译中…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                switch model.outcomes[block.id] {
                case let .complete(text, provenance):
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                    provenanceLabel(provenance)
                case let .partial(segments, _):
                    ForEach(
                        Array(segments.enumerated()), id: \.offset
                    ) { _, segment in
                        Text(segment.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    Button {
                        onTranslate(block.id)
                    } label: {
                        Label("补译缺失段", systemImage: "arrow.triangle.2.circlepath")
                            .font(.footnote)
                    }
                    .accessibilityIdentifier(
                        "reader-tr-complete-\(block.ordinal)")
                default:
                    placeholder("该段暂无译文", block: block, retry: false)
                }
            case .missing:
                placeholder("该段暂无译文", block: block, retry: false)
            case .failed:
                placeholder("翻译未完成", block: block, retry: true)
            }
            // 「查看原文」内联展开（占位行外的上下文菜单也到此）。
            if expandedOriginal.contains(block.id) {
                Text(block.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, OboeTheme.Spacing.xxs)
                    .accessibilityIdentifier(
                        "reader-tr-original-\(block.ordinal)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                withAnimation { toggleOriginal(block.id) }
            } label: {
                Label(
                    expandedOriginal.contains(block.id)
                        ? "收起原文" : "查看原文",
                    systemImage: "text.quote")
            }
            Button {
                onRetranslate(block.id)
            } label: {
                Label("重新翻译", systemImage: "arrow.clockwise")
            }
        }
        .accessibilityIdentifier("reader-tr-row-\(block.ordinal)")
    }

    /// 缺译/失败占位：原因 + 内联动作 + 查看原文入口。
    private func placeholder(
        _ title: String, block: ReaderBlock, retry: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xs) {
            HStack(spacing: OboeTheme.Spacing.xs) {
                Image(systemName: "character.bubble")
                Text(title)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack(spacing: OboeTheme.Spacing.md) {
                Button {
                    retry ? onRetry(block.id) : onTranslate(block.id)
                } label: {
                    Label(
                        retry ? "重试" : "翻译本段",
                        systemImage: retry
                            ? "arrow.clockwise"
                            : "character.bubble")
                }
                .accessibilityIdentifier(
                    "reader-tr-\(retry ? "retry" : "translate")-\(block.ordinal)")
                Button {
                    withAnimation { toggleOriginal(block.id) }
                } label: {
                    Label(
                        expandedOriginal.contains(block.id)
                            ? "收起原文" : "查看原文",
                        systemImage: "text.quote")
                }
                .accessibilityIdentifier(
                    "reader-tr-show-original-\(block.ordinal)")
            }
            .font(.footnote)
        }
    }

    private func provenanceLabel(
        _ provenance: ReaderTranslationAssembly.Provenance
    ) -> some View {
        let parts = [provenance.model, provenance.provider]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return Group {
            if !parts.isEmpty {
                Text("译文：\(parts.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleOriginal(_ blockID: UUID) {
        if expandedOriginal.contains(blockID) {
            expandedOriginal.remove(blockID)
        } else {
            expandedOriginal.insert(blockID)
        }
    }
}
