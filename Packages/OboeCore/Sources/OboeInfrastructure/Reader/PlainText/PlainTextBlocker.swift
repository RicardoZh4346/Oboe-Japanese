import Foundation
import OboeDomain

/// 文本分块器（S05，设计 §5）：输入规范化 grapheme cluster 流，
/// 产出「块文本 + 起点 UTF-16 偏移」。规则：
///
/// - 目标 ~`ReaderBlock.targetUTF16Length`（2000）UTF-16 units；
///   硬上限 `ReaderBlock.maximumUTF16Length`（8192）。
/// - 空行（连续 ≥2 个 "\n"，规范化的段落边界）是**硬边界**：
///   换行序列整体归入前一块，下一块从段首开始；
/// - 单个 "\n" 不强制切——短行（轻小说常见）合并到 ~target；
/// - 超过 target 遇任意换行即切；超过 target + `paragraphGrace`
///   仍未遇换行，退到句末边界（。！？!?… 及吸收尾随引号/括号；
///   ASCII "." 需后跟空白/换行才算句末，避免 "3.14" 误判）；
/// - 到达硬上限时若 append 该簇将越界，先出块（切点恒在 cluster
///   边界——不断开组合字符/emoji 序列）。
///
/// 契约无 sentence 级字段，句边界仅作切分提示，不持久化（§4.x）。
/// 全空白缓冲（如前导空行）不成块直接丢弃——其余情形块拼接
/// == canonical 全文。
struct PlainTextBlocker: Sendable {
    /// 越过 target 后仍给段落边界让路的窗口（UTF-16 units）。
    static let defaultParagraphGrace = 512

    private let targetUTF16: Int
    private let maximumUTF16: Int
    private let paragraphGrace: Int

    /// 当前未成块缓冲（规范化簇的拼接）。
    private var buffer = ""
    private var bufferUTF16 = 0
    /// 全流态：上一簇是句末或句末收尾符（引号/括号等）。
    private var afterSentenceTerminal = false
    /// ASCII "．" 待定：须见空白才算句末。
    private var pendingPeriod = false
    /// 已见段落边界、仍在吞连续换行：换行序列归前块。
    private var paragraphBreakPending = false

    /// 已产出块数 = 下一块 ordinal。
    private(set) var nextOrdinal = 0
    /// 已产出块的 canonical UTF-16 总量（块起点偏移由调用方累计）。
    private(set) var consumedUTF16 = 0

    init(
        targetUTF16: Int = ReaderBlock.targetUTF16Length,
        maximumUTF16: Int = ReaderBlock.maximumUTF16Length,
        paragraphGrace: Int = PlainTextBlocker.defaultParagraphGrace
    ) {
        self.targetUTF16 = targetUTF16
        self.maximumUTF16 = maximumUTF16
        self.paragraphGrace = paragraphGrace
    }

    /// 喂入一个规范化 cluster；若越过切点返回成块文本。
    mutating func feed(_ cluster: String) -> String? {
        let length = cluster.utf16.count
        if paragraphBreakPending {
            if cluster == "\n" {
                // 空行续段：换行并入前一块，不切。
                buffer.append(cluster)
                bufferUTF16 += length
                return nil
            }
            paragraphBreakPending = false
            let emitted = flush()  // 全空白缓冲时 nil（丢前导空行）
            buffer.append(cluster)
            bufferUTF16 = length
            updateSentenceState(cluster)
            return emitted
        }
        // 空行（第二个起的连续 \n）= 段落硬边界：置位等下簇再切，
        // 保证换行序列归入当前块。
        if cluster == "\n", lastClusterIsNewline() {
            paragraphBreakPending = true
            buffer.append(cluster)
            bufferUTF16 += length
            return nil
        }
        // 硬上限：append 会越界 → 当前位置切（cluster 边界）。
        if !buffer.isEmpty && bufferUTF16 + length > maximumUTF16 {
            let emitted = flush()
            buffer.append(cluster)
            bufferUTF16 = length
            updateSentenceState(cluster)
            return emitted
        }
        buffer.append(cluster)
        bufferUTF16 += length
        updateSentenceState(cluster)
        if bufferUTF16 >= targetUTF16 {
            if cluster == "\n" {
                return flush()  // 过 target 后首个换行即切
            }
            if bufferUTF16 >= targetUTF16 + paragraphGrace,
               afterSentenceTerminal {
                return flush()  // 句末兜底
            }
        }
        return nil
    }

    /// EOF：剩余缓冲成最后一块（空/全空白缓冲 → nil）。
    mutating func finish() -> String? {
        paragraphBreakPending = false
        return flush()
    }

    /// 出块；空或全空白缓冲仅清零不产出（前导/孤立空行不成块）。
    /// consumedUTF16 无条件累计——丢弃的空白也计入 canonical 偏移，
    /// 调用方才能用 `consumedUTF16 - 块长` 得到真起点。
    @discardableResult
    private mutating func flush() -> String? {
        let output = buffer
        let length = bufferUTF16
        buffer.removeAll(keepingCapacity: true)
        bufferUTF16 = 0
        afterSentenceTerminal = false
        pendingPeriod = false
        consumedUTF16 += length
        guard !output.isEmpty,
              !output.unicodeScalars.allSatisfy({
                  $0.properties.isWhitespace
              })
        else { return nil }
        nextOrdinal += 1
        return output
    }

    private func lastClusterIsNewline() -> Bool {
        buffer.last == "\n"
    }

    /// 句末状态机：terminal → 收尾符序列 → 普通字符复位。
    /// ASCII "." 只挂 pendingPeriod，见到空白/换行/收尾符才坐实句末。
    private mutating func updateSentenceState(_ cluster: String) {
        if Self.isSentenceTerminal(cluster) {
            afterSentenceTerminal = true
            pendingPeriod = false
            return
        }
        if afterSentenceTerminal {
            if Self.isSentenceCloser(cluster) {
                return  // 仍在收尾符串中，保持句末态
            }
            afterSentenceTerminal = false
        }
        if pendingPeriod {
            if Self.isWhitespace(cluster) || Self.isSentenceCloser(cluster)
                || cluster == "\n" {
                afterSentenceTerminal = true
            }
            pendingPeriod = false
        }
        if Self.isPeriodLike(cluster) {
            pendingPeriod = true
        }
    }

    // MARK: - 边界字符表

    /// 强句末：CJK 句号/感叹/问号、半角感叹/问号、省略号。
    private static func isSentenceTerminal(_ cluster: String) -> Bool {
        guard let scalar = cluster.unicodeScalars.last else { return false }
        switch scalar.value {
        case 0x3002 /* 。 */, 0xFF01 /* ！ */, 0xFF1F /* ？ */,
             0x21 /* ! */, 0x3F /* ? */,
             0x2026 /* … */, 0x2025 /* ‥ */,
             0xFF0E /* ．（全角句点视为强句末） */:
            return true
        default:
            return false
        }
    }

    /// ASCII "." / 全角 "．" 之外的「待定句点」——只认 ASCII '.'。
    private static func isPeriodLike(_ cluster: String) -> Bool {
        cluster.unicodeScalars.last?.value == 0x2E
    }

    /// 句末收尾符：引号/括号类簇。多字符簇（如 ”’）看尾 scalar。
    private static func isSentenceCloser(_ cluster: String) -> Bool {
        guard let scalar = cluster.unicodeScalars.last else { return false }
        switch scalar.value {
        case 0x300D /* 」 */, 0x300F /* 』 */, 0xFF09 /* ） */,
             0x29 /* ) */, 0x3009 /* 〉 */, 0x300B /* 》 */,
             0x3011 /* 】 */, 0x3017 /* 〕 */,
             0x2019 /* ’ */, 0x201D /* ” */, 0xBB /* » */,
             0x22 /* " */, 0x27 /* ' */, 0x5D /* ] */, 0x7D /* } */,
             0xFF5D /* ｝ */, 0x301B /* 〛 */, 0x3019 /* 〙 */:
            return true
        default:
            return false
        }
    }

    private static func isWhitespace(_ cluster: String) -> Bool {
        cluster.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace
        }
    }
}
