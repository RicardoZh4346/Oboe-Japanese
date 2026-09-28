import Foundation
import OboeDomain

/// v0.7.0 S16：分隔符检测（§10.1）。
///
/// 候选固定为契约的 comma / tab / semicolon。对每个候选用
/// `DelimitedTextParserImpl` 解析整段采样文本，统计各记录的字段数分布：
/// - 众数字段数 < 2 → 该候选没有分隔效果，置信度 0；
/// - 否则置信度 = 字段数等于众数的记录占比（结构一致性）。
/// 采样解析抛出 `malformedRow` 的候选置信度为 0（如 TSV 中的引号协议
/// 在错误分隔符下产生未闭合引号）。
///
/// 裁决：最高置信度 ≥ 0.9 且领先第二名 ≥ 0.2 → `confident`；
/// 否则 `needsUserChoice`，由向导让用户选择（§10.1「置信不足需用户选择」）。
public struct DelimiterCandidate: Equatable, Sendable {
    public let delimiter: Character
    /// 0...1；众数字段数 ≥2 的记录占比。
    public let confidence: Double
    /// 众数字段数（该分隔符下最一致的列数）；无有效结构时为 nil。
    public let modalFieldCount: Int?

    public init(delimiter: Character, confidence: Double, modalFieldCount: Int?) {
        self.delimiter = delimiter
        self.confidence = confidence
        self.modalFieldCount = modalFieldCount
    }
}

public enum DelimiterDetection: Equatable, Sendable {
    /// 单一候选足够置信；`alternatives` 为全部候选（含胜者，按置信度降序）。
    case confident(Character, alternatives: [DelimiterCandidate])
    /// 置信不足：用户必须从候选中选择。
    case needsUserChoice([DelimiterCandidate])
}

public enum DelimiterDetector {

    /// 置信裁决阈值。
    public static let confidenceThreshold = 0.9
    public static let confidenceMargin = 0.2

    /// - Parameters:
    ///   - sample: 已解码的文本采样（编码检测之后的产物；建议前几 KiB）。
    ///   - candidates: 候选分隔符，默认契约集合。
    ///   - maximumSampleRows: 采样解析的行数上限，避免大采样拖慢预览。
    public static func detect(
        in sample: String,
        candidates: [Character] = DelimitedTextParserImpl.candidateDelimiters,
        maximumSampleRows: Int = 200
    ) -> DelimiterDetection {
        let scored = candidates.map { candidate in
            score(delimiter: candidate, in: sample, maximumSampleRows: maximumSampleRows)
        }.sorted { $0.confidence > $1.confidence }

        guard let best = scored.first,
              best.confidence >= confidenceThreshold,
              scored.count < 2 || best.confidence - scored[1].confidence >= confidenceMargin
        else {
            return .needsUserChoice(scored)
        }
        return .confident(best.delimiter, alternatives: scored)
    }

    private static func score(
        delimiter: Character,
        in sample: String,
        maximumSampleRows: Int
    ) -> DelimiterCandidate {
        var parser = DelimitedTextParserImpl(delimiter: delimiter)
        let rows: [ImportLogicalRow]
        do {
            var collected = try parser.feed(sample)
            collected += try parser.finish()
            rows = collected
        } catch {
            return DelimiterCandidate(delimiter: delimiter, confidence: 0, modalFieldCount: nil)
        }

        let sampled = rows.prefix(maximumSampleRows)
        guard !sampled.isEmpty else {
            return DelimiterCandidate(delimiter: delimiter, confidence: 0, modalFieldCount: nil)
        }

        var histogram: [Int: Int] = [:]
        for row in sampled {
            histogram[row.fields.count, default: 0] += 1
        }
        guard let (modalCount, modalRows) = histogram.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }), modalCount >= 2 else {
            return DelimiterCandidate(delimiter: delimiter, confidence: 0, modalFieldCount: modalCountSafe(histogram))
        }
        return DelimiterCandidate(
            delimiter: delimiter,
            confidence: Double(modalRows) / Double(sampled.count),
            modalFieldCount: modalCount
        )
    }

    private static func modalCountSafe(_ histogram: [Int: Int]) -> Int? {
        histogram.max { $0.value < $1.value }?.key
    }
}
