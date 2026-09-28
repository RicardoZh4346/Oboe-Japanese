import Foundation
import OboeDomain
import UIKit
import XCTest
@testable import Oboe

/// `ReaderTextView.compose` 语义测试：块拼接顺序/分隔符、块范围索引、
/// token 着色与伪 URL 载荷、长文规模下的完整性与性能粗检。
///
/// 回归背景：长粘贴文本（单章数百块、数万 token）曾把全量组合 +
/// 逐 token `URL(string:)` 压在主线程 updateUIView 里，造成阅读页
/// 卡死。compose 现以 nonisolated 在 detached 任务执行——这里锁定
/// 「组合结果与输入严格对应」的契约，规模用例顺带守住量级。
final class ReaderTextViewComposeTests: XCTestCase {

    private func makeBlock(
        ordinal: Int, text: String
    ) -> ReaderBlock {
        ReaderBlock(
            id: UUID(),
            documentID: UUID(),
            chapterID: UUID(),
            ordinal: ordinal,
            text: text,
            textHash: "h\(ordinal)",
            locatorJSON: nil
        )
    }

    private func makeHighlight(
        blockID: UUID, range: Range<Int>,
        surface: String = "語",
        state: VocabularyKnowledgeState = .learning
    ) -> ReaderDocumentViewModel.TokenHighlight {
        .init(
            blockID: blockID, utf16Range: range,
            surface: surface, state: state
        )
    }

    // MARK: - 拼接与索引

    func testComposeJoinsBlocksWithBlankLineAndIndexesRanges() {
        let a = makeBlock(ordinal: 0, text: "今日は")
        let b = makeBlock(ordinal: 1, text: "いい天気")
        let (string, ranges) = ReaderTextView.compose(
            blocks: [a, b], highlights: [:], dynamicTypeSize: .large
        )

        XCTAssertEqual(string.string, "今日は\n\nいい天気")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].location, 0)
        XCTAssertEqual(ranges[0].length, 3)
        XCTAssertEqual(ranges[1].location, 5)  // 3 + "\n\n"
        XCTAssertEqual(ranges[1].length, 4)
        // 每块 range 切片回原块文本。
        XCTAssertEqual(
            (string.string as NSString).substring(with: ranges[1]),
            "いい天気"
        )
    }

    // MARK: - token 着色与链接

    func testComposeAppliesHighlightColorAndTokenURL() throws {
        let block = makeBlock(ordinal: 0, text: "日本語を勉強する")
        let token = makeHighlight(
            blockID: block.id, range: 0..<3,
            surface: "日本語", state: .learning
        )
        let (string, _) = ReaderTextView.compose(
            blocks: [block],
            highlights: [block.id: [token]],
            dynamicTypeSize: .large
        )
        let ns = string.string as NSString
        var effective = NSRange()
        let link = string.attribute(
            .link, at: 0, effectiveRange: &effective
        ) as? URL
        XCTAssertNotNil(link)
        XCTAssertEqual(effective, NSRange(location: 0, length: 3))
        XCTAssertNotNil(
            string.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        )
        // 伪 URL 载荷可回解出 blockID + utf16 range（点词链路）。
        let parsed = ReaderTextView.parseTokenURL(try XCTUnwrap(link))
        XCTAssertEqual(parsed?.blockID, block.id)
        XCTAssertEqual(parsed?.range, 0..<3)
        XCTAssertEqual(ns.substring(with: effective), "日本語")
    }

    /// 批量挖词选中词：前景压过知识状态色 + 带底纹，
    /// 用户能看出哪些词已入队。
    func testComposeSelectedTokenOverridesStateColorAndAddsBackground() {
        let block = makeBlock(ordinal: 0, text: "日本語を勉強する")
        let selected = makeHighlight(
            blockID: block.id, range: 0..<3, state: .unknown
        )
        let normal = makeHighlight(
            blockID: block.id, range: 3..<5, state: .unknown
        )
        let (string, _) = ReaderTextView.compose(
            blocks: [block],
            highlights: [block.id: [selected, normal]],
            selectedTokens: [
                ReaderTextView.TokenRef(
                    blockID: block.id, range: 0..<3
                ),
            ],
            dynamicTypeSize: .large
        )
        var range = NSRange()
        let color = string.attribute(
            .foregroundColor, at: 0, effectiveRange: &range
        ) as? UIColor
        XCTAssertEqual(range, NSRange(location: 0, length: 3))
        XCTAssertEqual(color, ReaderTextView.selectedColor)
        XCTAssertNotNil(
            string.attribute(.backgroundColor, at: 1, effectiveRange: nil)
        )
        // 未选中的相邻 token 保持状态色且无底纹。
        let plain = string.attribute(
            .foregroundColor, at: 3, effectiveRange: nil
        ) as? UIColor
        XCTAssertEqual(
            plain, ReaderTextView.color(for: .unknown)
        )
        XCTAssertNil(
            string.attribute(.backgroundColor, at: 3, effectiveRange: nil)
        )
    }

    func testComposeSkipsOutOfBoundsTokenRanges() {
        let block = makeBlock(ordinal: 0, text: "短")
        let token = makeHighlight(
            blockID: block.id, range: 0..<99
        )
        let (string, _) = ReaderTextView.compose(
            blocks: [block],
            highlights: [block.id: [token]],
            dynamicTypeSize: .large
        )
        var effective = NSRange()
        XCTAssertNil(
            string.attribute(.link, at: 0, effectiveRange: &effective)
        )
    }

    // MARK: - 长文规模

    /// 300 块 × 2000 字 ≈ 60 万 utf16 单元（长粘贴文本量级），
    /// 每块 40 个 token 共 1.2 万条着色/link。守住「全量组合」
    /// 的正确性与粗粒度耗时上界——不替代真机帧率验收。
    func testComposeLargeDocumentIntegrityAndTimeBound() {
        let text = String(
            repeating: "日本語の長い文が続きます。",
            count: 160
        )  // ~2000 utf16 units
        var blocks: [ReaderBlock] = []
        var highlights: [UUID: [ReaderDocumentViewModel.TokenHighlight]] = [:]
        var tokenTotal = 0
        for ordinal in 0..<300 {
            let block = makeBlock(ordinal: ordinal, text: text)
            blocks.append(block)
            var tokens: [ReaderDocumentViewModel.TokenHighlight] = []
            for i in 0..<40 {
                let start = i * 48
                guard start + 12 <= text.utf16.count else { break }
                tokens.append(makeHighlight(
                    blockID: block.id, range: start..<(start + 12)
                ))
                tokenTotal += 1
            }
            highlights[block.id] = tokens
        }

        let start = Date()
        let (string, ranges) = ReaderTextView.compose(
            blocks: blocks,
            highlights: highlights,
            dynamicTypeSize: .large
        )
        let elapsed = Date().timeIntervalSince(start)

        let blockChars = blocks.reduce(0) { $0 + $1.text.utf16.count }
        let separators = 2 * (blocks.count - 1)
        XCTAssertEqual(string.length, blockChars + separators)
        XCTAssertEqual(ranges.count, blocks.count)
        XCTAssertEqual(ranges.last.map(NSMaxRange), string.length)
        // link 属性总数 == token 总数。
        var linkCount = 0
        string.enumerateAttribute(
            .link, in: NSRange(location: 0, length: string.length)
        ) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        XCTAssertEqual(linkCount, tokenTotal)
        // 宽松上界：离线 compose 要求在合理时间内完成（真机/慢 CI
        // 留 10x 余量；旧实现在主线程同量级即表现为卡死）。
        XCTAssertLessThan(elapsed, 15)
    }
}
