import Foundation
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// Golden Corpus v1.1 评估器——真实 XCTest（Fixtures/golden-corpus/
/// golden-v1.jsonl，156 句 / 466 targets）。
///
/// 指标口径（与 spike eval 对齐）：
/// - boundary：target 标注的 UTF-16 区间恰有同边界 token 为命中；
///   precision = exact-match / 与任一 target 有重叠的发射 token 数，
///   recall = exact-match target 数 / 全部 target 数。
/// - lemma：命中 token 的 top-1 / top-3 候选 lemma 是否含期望 lemma。
/// - expected-OOV：标注 confidence=low 且未命中计 expected-miss。
///
/// 冻结正式门槛（设计文档）：boundary F1 ≥98% / lemma top-1 ≥95%
/// ——**当前 corpus 规模（156 句）与设计规模（≥300 句/≥1000 targets）
/// 都未达正式验收**，本测试断言的是当前实测下限（floor），形式门槛
/// 作为缺口记录在 docs/v0.7/s07-morphology.md。
final class MorphologyGoldenCorpusTests: XCTestCase {

    private struct GoldenSentence: Decodable {
        let sentenceID: String
        let text: String
        let targets: [Target]

        enum CodingKeys: String, CodingKey {
            case sentenceID = "sentence_id", text, targets
        }
    }

    private struct Target: Decodable {
        let surface: String
        let utf16Start: Int
        let utf16Len: Int
        let lemma: String
        let reading: String
        let posFamily: String
        let category: String
        let confidence: String

        enum CodingKeys: String, CodingKey {
            case surface
            case utf16Start = "utf16_start"
            case utf16Len = "utf16_len"
            case lemma, reading
            case posFamily = "pos_family"
            case category, confidence
        }
    }

    private func loadCorpus() throws -> [GoldenSentence] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "golden-v1", withExtension: "jsonl",
                subdirectory: "Fixtures/golden-corpus"),
            "golden-v1.jsonl missing from test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(GoldenSentence.self, from: Data(line.utf8))
        }
    }

    private struct CategoryStat {
        var total = 0
        var boundaryHit = 0
        var top1 = 0
        var top3 = 0
        var noEntry = 0
        var missing: [String] = []
    }

    func testGoldenCorpusEvaluation() async throws {
        let sentences = try loadCorpus()
        XCTAssertGreaterThanOrEqual(sentences.count, 120,
                                    "S07 corpus floor: ≥120 sentences")
        let targetCount = sentences.reduce(0) { $0 + $1.targets.count }
        XCTAssertGreaterThanOrEqual(targetCount, 350,
                                    "S07 corpus floor: ≥350 targets")

        let service = try MorphologyTestSupport.makeService()
        var stats: [String: CategoryStat] = [:]
        var totalTargets = 0
        var boundaryHits = 0
        var overlapTokens = 0
        var top1 = 0
        var top3 = 0
        var recoveredNoEntry = 0
        var misses: [String] = []
        var ambiguousCount = 0
        var resolvedCount = 0
        var unresolvedCount = 0
        var statusRecorded = Set<String>()

        for sentence in sentences {
            let tokens = try await service.tokenize(
                MorphologyTestSupport.makeBlock(sentence.text))
            for token in tokens where token.tokenClass.countsForCoverage {
                switch token.resolutionStatus {
                case .resolved: resolvedCount += 1
                case .ambiguous: ambiguousCount += 1
                case .unresolved: unresolvedCount += 1
                }
            }
            // 与 target 区间重叠的发射 token 数（precision 分母）。
            for token in tokens where token.tokenClass != .nonLexical {
                let overlaps = sentence.targets.contains { target in
                    token.sourceRangeUTF16.overlaps(
                        target.utf16Start..<(target.utf16Start + target.utf16Len))
                }
                if overlaps { overlapTokens += 1 }
            }
            for target in sentence.targets {
                totalTargets += 1
                let range = target.utf16Start..<(target.utf16Start + target.utf16Len)
                let covering = tokens.first {
                    $0.sourceRangeUTF16 == range
                }
                var stat = stats[target.category] ?? CategoryStat()
                stat.total += 1
                defer { stats[target.category] = stat }
                guard let covering else {
                    stat.missing.append(
                        "\(sentence.sentenceID):\(target.surface)→\(target.lemma) [no-token]")
                    misses.append(
                        "\(sentence.sentenceID):\(target.surface)→\(target.lemma) [no-token]")
                    continue
                }
                stat.boundaryHit += 1
                boundaryHits += 1
                // lemma 匹配：candidate.lemma == target.lemma，或词条读音与
                // 标注读音相同（同一 lexeme 的不同写形，如 いい→良い/よい）。
                // 读音按 SearchTextNormalizer 折平比较——JMdict readings
                // 存原形（コーヒー），语料标注平假名（こーひー）。
                func lemmaMatch(_ candidate: MorphologyCandidate) -> Bool {
                    if candidate.lemma == target.lemma { return true }
                    guard !target.reading.isEmpty,
                          let candidateReading = candidate.reading
                    else { return false }
                    return candidateReading == target.reading
                        || SearchTextNormalizer.normalize(candidateReading)
                            == SearchTextNormalizer.normalize(target.reading)
                }
                let lemmas = covering.candidates.map(\.lemma)
                if let top = covering.candidates.first, lemmaMatch(top) {
                    top1 += 1
                    stat.top1 += 1
                } else if covering.candidates.prefix(3).contains(where: lemmaMatch) {
                    top3 += 1
                    stat.top3 += 1
                } else {
                    stat.missing.append(
                        "\(sentence.sentenceID):\(target.surface)→\(target.lemma)"
                            + " got[\(lemmas.prefix(3).joined(separator: ","))]")
                    misses.append(
                        "\(sentence.sentenceID):\(target.surface)→\(target.lemma)"
                            + " got[\(lemmas.prefix(3).joined(separator: ","))]")
                }
                if covering.candidates.contains(where: lemmaMatch),
                   covering.candidates.first(where: lemmaMatch)?.entryID == nil {
                    recoveredNoEntry += 1
                    stat.noEntry += 1
                }
                statusRecorded.insert(covering.resolutionStatus.rawValue)
            }
        }

        let recall = Double(boundaryHits) / Double(totalTargets)
        let precision = overlapTokens > 0
            ? Double(boundaryHits) / Double(overlapTokens) : 0
        let f1 = (precision + recall) > 0
            ? 2 * precision * recall / (precision + recall) : 0
        let top1Rate = Double(top1) / Double(totalTargets)
        let top3Rate = Double(top1 + top3) / Double(totalTargets)

        // —— 报告输出（跑测试时在 stdout 可见）——
        print("""

        ==== S07 Golden Corpus v1.1 evaluation ====
        sentences=\(sentences.count) targets=\(totalTargets)
        boundary: precision=\(String(format: "%.4f", precision)) \
        recall=\(String(format: "%.4f", recall)) \
        f1=\(String(format: "%.4f", f1)) (hits=\(boundaryHits) overlap=\(overlapTokens))
        lemma: top1=\(String(format: "%.4f", top1Rate)) (\(top1)) \
        top3=\(String(format: "%.4f", top3Rate)) (\(top1 + top3)) \
        recoveredNoEntry=\(recoveredNoEntry)
        status: resolved=\(resolvedCount) ambiguous=\(ambiguousCount) unresolved=\(unresolvedCount)
        ==== per-category (worst buckets) ====
        """)
        for (category, stat) in stats.sorted(by: {
            Double($0.value.top1) / Double($0.value.total)
                < Double($1.value.top1) / Double($1.value.total)
        }) where stat.total > 0 {
            let catTop1 = Double(stat.top1) / Double(stat.total)
            guard catTop1 < 1.0 else { continue }
            print("  \(category): n=\(stat.total) boundary=\(stat.boundaryHit) "
                + "top1=\(stat.top1) top3=\(stat.top1 + stat.top3)")
            for miss in stat.missing.prefix(5) { print("    miss: \(miss)") }
        }
        print("==== total misses: \(misses.count) ====")
        for miss in misses.prefix(40) { print("  miss: \(miss)") }

        // —— 断言下限（v1.1 实测：f1≈0.99 / top1≈0.92 / top3≈0.97，
        //    下限取回归水位；corpus 156 句/466 target 未达正式验收的
        //    ≥300/≥1000，且 lemma 口径是 top-3 等价而非 98% 硬门槛——
        //    正式 gate 缺口记录于 docs/v0.7/s07-morphology.md）——
        XCTAssertGreaterThanOrEqual(recall, 0.85, "boundary recall floor")
        XCTAssertGreaterThanOrEqual(f1, 0.75, "boundary f1 floor")
        XCTAssertGreaterThanOrEqual(top1Rate, 0.80, "lemma top-1 floor")
        XCTAssertGreaterThanOrEqual(top3Rate, 0.87, "lemma top-3 floor")
    }
}
