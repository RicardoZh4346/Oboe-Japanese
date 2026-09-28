import Foundation

/// Canonical 规范化器（§4.2 canonical_text）：CRLF/CR → LF + NFC，
/// 增量、切块不敏感。
///
/// 切块不变性的两个关键点：
/// 1. **末尾簇扣押**：每轮扣押最后一个 grapheme cluster，下次 feed 前缀
///    合并后再判界——「e」+「◌́」跨 chunk 仍会规范化为单个「é」。
/// 2. **CR 滞留**：`\r` 在转换为 `\n` **之前**进入 pending（原文簇），
///    跨 chunk 的 CRLF（`...\r` | `\n...`）合并后仍折成单个 `\n`；
///    若先转换再扣押会多出一个 `\n`（曾被当 bug 修过）。
///
/// NFC 不跨 grapheme 边界（组合符永远随基字符同簇），故逐簇
/// `precomposedStringWithCanonicalMapping` ≡ 全文一次性 NFC。
struct CanonicalTextNormalizer: Sendable {
    /// 扣押的原文簇（未转换、未 NFC），下次 feed 前置合并。
    private var pending: String?

    /// 推入一段解码文本，返回可安全输出的 canonical 簇序列。
    mutating func feed(_ piece: String) -> [String] {
        let merged = (pending ?? "") + piece
        guard !merged.isEmpty else { return [] }
        let clusters = merged.clusterSequence()
        guard clusters.count > 1 else {
            pending = clusters.first  // 不足两簇：全部扣押等下文
            return []
        }
        var emitted: [String] = []
        emitted.reserveCapacity(clusters.count)
        // 处理除末簇外的全部簇；末簇留下次判界。
        // 注意 CRLF 本身是单个 grapheme cluster（UAX #29 CR×LF），
        // 所以只可能是 "\r\n" 或孤立 "\r" 两种簇，无需向前窥探。
        for cluster in clusters.dropLast() {
            emitted.append(Self.canonicalize(cluster))
        }
        pending = clusters.last
        return emitted
    }

    /// EOF：冲刷扣押簇。
    mutating func finish() -> [String] {
        guard let tail = pending else { return [] }
        pending = nil
        return [Self.canonicalize(tail)]
    }

    /// 单簇 canonical 化：行尾折叠 + 逐簇 NFC。
    private static func canonicalize(_ cluster: String) -> String {
        if cluster == "\r\n" || cluster == "\r" { return "\n" }
        return precomposed(cluster)
    }

    /// 逐簇 NFC（`precomposedStringWithCanonicalMapping`）。
    private static func precomposed(_ cluster: String) -> String {
        cluster.precomposedStringWithCanonicalMapping
    }
}

private extension String {
    /// 按扩展 grapheme cluster 切分（`...` 区间枚举，对短串高效）。
    func clusterSequence() -> [String] {
        var result: [String] = []
        result.reserveCapacity(count / 4 + 1)
        var index = startIndex
        while index < endIndex {
            let next = self.index(after: index)
            result.append(String(self[index..<next]))
            index = next
        }
        return result
    }
}
