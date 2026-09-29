import Foundation

/// v0.7.5 S17：译文锚点约定（`reader_translation_blocks.locator_key` /
/// `locator_json` 的唯一构造/解析点——存储层对它们不透明，约定收在
/// 本类型）。
///
/// # locator_key 规范形态
///
/// ```text
/// tr:ch:<chapterOrdinal>:b:<blockOrdinal>#r<utf16Start>-<utf16End>
/// ```
///
/// 设计要点（对应 contracts-frozen §6 v25 + 技术文档 §14.2）：
/// - **不含 documentID / contentRevision**：文档列已隔离文档；
///   contentRevision 变化（relink 重建/v8 恢复补块）不换 key——
///   同一锚点的修订链跨 revision 延续，「一块一译文当前值」语义由
///   `(document_id, locator_key, language) is_current` 部分唯一
///   自然保证（旧译文直到新结果成功落库才翻转）。
/// - **序数定位而非块行 ID**：`reader_blocks.id` 在重链/恢复时可能
///   换发（稳定 ID 复用仅覆盖 ordinal+hash 全等的块）；序数 +
///   目标区间是 re-parse 确定性锚，hash 失配由渲染侧 source_hash
///   比对挡住（译文不出现在不匹配原文下）。
/// - **`#r<s>-<e>` 目标区间**：同一原文块的多个 subblock 译文以
///   UTF-16 区间区分（§6.3：目标区间互不重叠），区间覆盖整块的
///   行（`#r0-<len>`）视作整段译文。
/// - **兼容旧形态**：`doc:<id>:rev:<r>:ch:<co>:b:<bo>#r<s>-<e>`
///   （study Job subblockKey 早期写法）仍可解析 `:ch:/:b:` 序数与
///   `#r` 区间——重链时经 `updateLocators` 迁移到规范 key。
///
/// # locator_json 规范形态
///
/// `ReaderLocation` JSON（sortedKeys）：chapterOrdinal /
/// blockOrdinal / utf16Offset = 目标区间起点 / blockTextHash =
/// 锚定块 `reader_blocks.text_hash` / prefix / suffix（各 ≤32
/// Character）。渲染侧按 (chapterOrdinal, blockOrdinal) 找活动块，
/// 再比对 `source_hash`——锚点判定不依赖 locator_key 字符串本身。
public enum ReaderTranslationLocator {

    /// 解析出的锚点（渲染/重挂共用）。
    public struct Anchor: Equatable, Sendable {
        public let chapterOrdinal: Int
        public let blockOrdinal: Int
        /// 块内 UTF-16 目标区间。
        public let range: Range<Int>

        public init(
            chapterOrdinal: Int,
            blockOrdinal: Int,
            range: Range<Int>
        ) {
            self.chapterOrdinal = chapterOrdinal
            self.blockOrdinal = blockOrdinal
            self.range = range
        }
    }

    // MARK: - key 构造与解析

    /// 规范 locator_key。
    public static func key(
        chapterOrdinal: Int,
        blockOrdinal: Int,
        utf16Range: Range<Int>
    ) -> String {
        "tr:ch:\(chapterOrdinal):b:\(blockOrdinal)"
            + "#r\(utf16Range.lowerBound)-\(utf16Range.upperBound)"
    }

    /// 整块译文的 locator_key（`#r0-<utf16Length>`）。
    public static func wholeBlockKey(
        chapterOrdinal: Int,
        blockOrdinal: Int,
        blockUTF16Length: Int
    ) -> String {
        key(
            chapterOrdinal: chapterOrdinal,
            blockOrdinal: blockOrdinal,
            utf16Range: 0..<blockUTF16Length)
    }

    /// 规范 key 解析（只认 `tr:` 形态）。
    public static func parseKey(_ key: String) -> Anchor? {
        guard key.hasPrefix("tr:ch:") else { return nil }
        guard let ordinals = parseChapterBlockOrdinals(key),
              let range = parseRangeSuffix(key)
        else { return nil }
        return Anchor(
            chapterOrdinal: ordinals.chapterOrdinal,
            blockOrdinal: ordinals.blockOrdinal,
            range: range)
    }

    /// 章/块序数解析——`tr:` 与旧 `doc:` 形态共用 `:ch:<n>:b:<n>`
    /// 子串约定。
    public static func parseChapterBlockOrdinals(
        _ key: String
    ) -> (chapterOrdinal: Int, blockOrdinal: Int)? {
        guard let chRange = key.range(of: ":ch:") else { return nil }
        let tail = key[chRange.upperBound...]
        guard let bRange = tail.range(of: ":b:") else { return nil }
        guard let chapterOrdinal = Int(tail[..<bRange.lowerBound])
        else { return nil }
        let afterB = tail[bRange.upperBound...]
        let blockDigits = afterB.prefix { $0.isNumber }
        guard let blockOrdinal = Int(blockDigits) else { return nil }
        return (chapterOrdinal, blockOrdinal)
    }

    /// `#r<s>-<e>` 区间解析（任意 key 形态——旧 doc: 键同后缀）。
    public static func parseRangeSuffix(_ key: String) -> Range<Int>? {
        guard let marker = key.range(of: "#r", options: .backwards)
        else { return nil }
        let tail = key[marker.upperBound...]
        guard let dash = tail.firstIndex(of: "-") else { return nil }
        guard let start = Int(tail[..<dash]),
              let end = Int(tail[tail.index(after: dash)...]),
              start >= 0, end > start
        else { return nil }
        return start..<end
    }

    /// 行 → 锚点：序数以 `locator_json`（ReaderLocation）为准，
    /// 区间取 key 的 `#r` 后缀；JSON 缺失/损坏时回落 key 解析
    /// （覆盖 tr:/doc: 两形）。两端都缺 → nil（不可锚定）。
    public static func anchor(
        locatorKey: String,
        locatorJSON: String
    ) -> Anchor? {
        let range = parseRangeSuffix(locatorKey)
        if let location = decodeLocation(locatorJSON) {
            guard let range else { return nil }
            return Anchor(
                chapterOrdinal: location.chapterOrdinal,
                blockOrdinal: location.blockOrdinal,
                range: range)
        }
        if let parsed = parseKey(locatorKey) {
            return parsed
        }
        guard let ordinals = parseChapterBlockOrdinals(locatorKey),
              let range else { return nil }
        return Anchor(
            chapterOrdinal: ordinals.chapterOrdinal,
            blockOrdinal: ordinals.blockOrdinal,
            range: range)
    }

    // MARK: - locator_json 构造与解析

    /// ReaderLocation → sortedKeys JSON（存储层 8KiB/json_valid
    /// 约束内——前后文各 ≤32 Character，天然短小）。
    public static func locatorJSON(
        chapterOrdinal: Int,
        blockOrdinal: Int,
        utf16Offset: Int,
        blockTextHash: String,
        prefix: String,
        suffix: String
    ) throws -> String {
        let location = ReaderLocation(
            chapterOrdinal: chapterOrdinal,
            blockOrdinal: blockOrdinal,
            utf16Offset: utf16Offset,
            blockTextHash: blockTextHash,
            prefix: prefix,
            suffix: suffix)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(location), as: UTF8.self)
    }

    /// 从源文本派生前/后缀的便捷版（与 `AIStudyPreparationService
    /// .subblockLocator` 同一窗口：目标区间前/后各 32 UTF-16 单位，
    /// ReaderLocation 自身再按 32 Character 截断）。
    public static func locatorJSON(
        sourceText: String,
        blockTextHash: String,
        chapterOrdinal: Int,
        blockOrdinal: Int,
        targetRange: Range<Int>
    ) throws -> String {
        let units = Array(sourceText.utf16)
        let start = max(0, min(targetRange.lowerBound, units.count))
        let end = max(start, min(targetRange.upperBound, units.count))
        let prefixRange = max(0, start - 32)..<start
        let suffixRange = end..<min(units.count, end + 32)
        return try locatorJSON(
            chapterOrdinal: chapterOrdinal,
            blockOrdinal: blockOrdinal,
            utf16Offset: start,
            blockTextHash: blockTextHash,
            prefix: String(decoding: units[prefixRange], as: UTF16.self),
            suffix: String(decoding: units[suffixRange], as: UTF16.self))
    }

    /// 宽容解码（损坏 JSON → nil——锚点判定交由 key 回落路径）。
    public static func decodeLocation(_ json: String) -> ReaderLocation? {
        try? JSONDecoder().decode(
            ReaderLocation.self, from: Data(json.utf8))
    }
}
