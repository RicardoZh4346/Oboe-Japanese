import Foundation

/// 一个可渲染译文片段（infra 从 `reader_translation_blocks` 行投影
/// ——锚点已解析、source_hash 已与活动原文核对）。
public struct ReaderTranslationPiece: Equatable, Sendable {
    public let locatorKey: String
    /// 块内 UTF-16 目标区间（locator_key `#r` 段）。
    public let range: Range<Int>
    public let text: String
    public let translationRevision: Int
    /// provenance：发表时的请求元数据快照（§7：取请求侧，非模型自报）。
    public let provider: String?
    public let model: String?
    public let promptVersion: String?
    public let createdAt: Date

    public init(
        locatorKey: String,
        range: Range<Int>,
        text: String,
        translationRevision: Int,
        provider: String?,
        model: String?,
        promptVersion: String?,
        createdAt: Date
    ) {
        self.locatorKey = locatorKey
        self.range = range
        self.text = text
        self.translationRevision = translationRevision
        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
        self.createdAt = createdAt
    }
}

/// 译文片段 → 块级展示模型（§6.3/§14.2 的装配规则唯一实现点）。
///
/// 规则：
/// - **整段行优先**：覆盖整块（`0..<len`）的片段至多一个 current
///   （同 key 同语言部分唯一）——存在即完整译文；多个整段行并存时
///   取最新 `createdAt`（跨 key 规范迁移期的防御）。
/// - **片段拼接**：无整段行时按区间起点排序贪心取不重叠片段——
///   同起点取最新片段，重叠片段整体跳过（译文不得错位拼贴）。
/// - **齐全才完整**：片段并集覆盖 `[0, blockUTF16Length)` 才拼成
///   完整段落译文（顺序 = 区间起点——多 subblock 翻译顺序）；
///   否则 `partial`：片段 + 缺失区间占位（§6.3「部分缺失展示
///   明确占位」）。
public enum ReaderTranslationAssembly {
    /// 译文 provenance（展示「由 X 模型生成」+ 版本追踪）。
    public struct Provenance: Equatable, Sendable {
        public let provider: String?
        public let model: String?
        public let promptVersion: String?

        public init(provider: String?, model: String?, promptVersion: String?) {
            self.provider = provider
            self.model = model
            self.promptVersion = promptVersion
        }
    }

    /// 展示态片段（拼贴已就绪）。
    public struct Segment: Equatable, Sendable {
        public let range: Range<Int>
        public let text: String

        public init(range: Range<Int>, text: String) {
            self.range = range
            self.text = text
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// 无可渲染译文（无行 / source_hash 不匹配被过滤后）。
        case none
        /// 完整译文：整段行或片段全覆盖拼接。
        case complete(text: String, provenance: Provenance)
        /// 部分覆盖：已有片段按序展示 + 缺失区间占位。
        case partial(segments: [Segment], missingRanges: [Range<Int>])
    }

    public static func assemble(
        pieces: [ReaderTranslationPiece],
        blockUTF16Length: Int
    ) -> Outcome {
        guard blockUTF16Length > 0 else { return .none }

        // 整段行：起点 0 且终点 ≥ 块长。
        let spans = pieces.filter {
            $0.range.lowerBound <= 0 && $0.range.upperBound >= blockUTF16Length
        }
        if let span = spans.max(by: {
            ($0.createdAt, $0.translationRevision)
                < ($1.createdAt, $1.translationRevision)
        }) {
            return .complete(
                text: span.text,
                provenance: Provenance(
                    provider: span.provider, model: span.model,
                    promptVersion: span.promptVersion))
        }

        // 片段贪心覆盖：起点升序、同起点最新者优先、重叠片段跳过。
        let sorted = pieces.sorted {
            ($0.range.lowerBound, -$0.range.upperBound, $0.createdAt)
                < ($1.range.lowerBound, -$1.range.upperBound, $1.createdAt)
        }
        var segments: [Segment] = []
        var coveredEnd = 0
        var hasGaps = false
        var provenance: Provenance?
        for piece in sorted {
            // 区间必须在块内且不越过已覆盖终点——越界/重叠跳过。
            guard piece.range.lowerBound >= coveredEnd,
                  piece.range.lowerBound >= 0,
                  piece.range.upperBound <= blockUTF16Length,
                  !piece.range.isEmpty, !piece.text.isEmpty
            else { continue }
            if piece.range.lowerBound > coveredEnd {
                hasGaps = true
            }
            segments.append(Segment(range: piece.range, text: piece.text))
            coveredEnd = piece.range.upperBound
            if provenance == nil {
                provenance = Provenance(
                    provider: piece.provider, model: piece.model,
                    promptVersion: piece.promptVersion)
            }
        }
        guard !segments.isEmpty else { return .none }

        if !hasGaps,
           coveredEnd >= blockUTF16Length,
           segments.first?.range.lowerBound == 0 {
            let text = segments.map(\.text).joined()
            return .complete(
                text: text,
                provenance: provenance ?? Provenance(
                    provider: nil, model: nil, promptVersion: nil))
        }

        // 缺失区间 = [0,len) 减片段并集（segments 已按序不重叠）。
        var missing: [Range<Int>] = []
        var cursor = 0
        for segment in segments {
            if segment.range.lowerBound > cursor {
                missing.append(cursor..<segment.range.lowerBound)
            }
            cursor = max(cursor, segment.range.upperBound)
        }
        if cursor < blockUTF16Length {
            missing.append(cursor..<blockUTF16Length)
        }
        return .partial(segments: segments, missingRanges: missing)
    }
}
