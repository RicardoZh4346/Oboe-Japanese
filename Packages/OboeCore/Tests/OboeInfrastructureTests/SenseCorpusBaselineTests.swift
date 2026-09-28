import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S02 工作包 B：义项标注语料（Fixtures/sense-corpus/sense-v1.jsonl，
/// 161 句 / 342 targets）的本地质量基线评估器。
///
/// 与 golden 评估器的口径差异：golden 测 boundary+lemma top-k；本文件测
/// 「候选 → 义项」链路的 entry 级召回、resolutionStatus 分布、sense 级可见性
/// 与 §6.3 prompt 体积预算。
///
/// 指标口径：
/// - boundary：target utf16 区间恰有同边界 token 为命中（同 golden）。
/// - entry recall：期望 entryID 出现在该 token ≤5 候选中的比例
///   （boundary miss 计为 recall miss——无 token 即无候选），分
///   ambiguity 层与 dev/validation 子集报告。
/// - entry top-1：期望 entry 恰为候选首位——本地自动接受的可行上界参考。
/// - OOV：expected_entry_id = null 的 target——记录 resolver 是否仍给出
///   候选（spurious candidates），用于评估「非法候选」风险面。
/// - sense 级可见率：MorphologyCandidate 只携带 entryID，无 senseID/
///   gloss/restriction 字段——sense 详情在 resolver 输出对象上**不可见**，
///   如实记录为 0；「若序列化 entry 全部义项则可被 prompt 覆盖」的上限
///   即 entry recall（写进报告，不当作 sense 级能力）。
/// - prompt 预算（§6.3）：每 occurrence 序列化 lemma/reading/POS +
///   每候选 entry 的全部英文 gloss，估算平均/最大字节与 48KiB/40-occurrence
///   预算下的请求块数。
///
/// 断言当前实测下限（floor），不抬门槛；与发布目标（候选召回 ≥95%）
/// 的差距只写进报告输出。
final class SenseCorpusBaselineTests: XCTestCase {

    private struct SenseSentence: Decodable {
        let sentenceID: String
        let subset: String
        let text: String
        let targets: [Target]

        enum CodingKeys: String, CodingKey {
            case sentenceID = "sentence_id", subset, text, targets
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
        let expectedEntryID: Int64?
        let expectedSenseID: Int64?
        let expectedSenseFingerprint: String?
        let ambiguity: String
        let autoAcceptExpectation: String

        enum CodingKeys: String, CodingKey {
            case surface
            case utf16Start = "utf16_start"
            case utf16Len = "utf16_len"
            case lemma, reading
            case posFamily = "pos_family"
            case category, confidence
            case expectedEntryID = "expected_entry_id"
            case expectedSenseID = "expected_sense_id"
            case expectedSenseFingerprint = "expected_sense_fingerprint"
            case ambiguity
            case autoAcceptExpectation = "auto_accept_expectation"
        }
    }

    private func loadCorpus() throws -> [SenseSentence] {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "sense-v1", withExtension: "jsonl",
                subdirectory: "Fixtures/sense-corpus"),
            "sense-v1.jsonl missing from test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try JSONDecoder().decode(SenseSentence.self, from: Data(line.utf8))
        }
    }

    private struct AmbStat {
        var total = 0
        var boundaryHit = 0
        var expectedEntry = 0      // expected_entry_id 非空的 target 数
        var entryInTop5 = 0
        var entryIsTop1 = 0
        var oovSpurious = 0        // 期望 OOV 却拿到 entry 候选的 target 数
        var missing: [String] = []
    }

    /// 词典 gloss 查询（§6.2 prompt 序列化的体积基线）。
    /// 与 resolver 一样直连随包 sqlite 只读打开；不复用 resolver 的
    /// IN-chunk 逻辑（这里是离线评估，不是生产路径）。
    private final class DictionaryGlossSource {
        let queue: DatabaseQueue
        init(url: URL) throws {
            var configuration = Configuration()
            configuration.readonly = true
            queue = try DatabaseQueue(path: url.path, configuration: configuration)
        }

        /// entry 的全部 sense 的英文 gloss（sense_order, gloss_order 有序）。
        func glosses(entryID: Int64) throws -> [(senseID: Int64, glosses: [String])] {
            try queue.read { db in
                var result: [(Int64, [String])] = []
                var bySense: [Int64: [String]] = [:]
                var order: [Int64] = []
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT s.id AS sense_id, g.text
                        FROM senses s JOIN glosses g ON g.sense_id = s.id
                        WHERE s.entry_id = ? AND g.language = 'eng'
                        ORDER BY s.sense_order, g.gloss_order
                        """,
                    arguments: [entryID]
                ) {
                    let senseID: Int64 = row["sense_id"]
                    if bySense[senseID] == nil {
                        bySense[senseID] = []
                        order.append(senseID)
                    }
                    bySense[senseID]?.append(row["text"])
                }
                for senseID in order {
                    result.append((senseID, bySense[senseID] ?? []))
                }
                return result
            }
        }
    }

    func testSenseCorpusBaseline() async throws {
        let sentences = try loadCorpus()
        XCTAssertGreaterThanOrEqual(sentences.count, 120,
                                    "S02 sense corpus floor: ≥120 sentences")
        let targetCount = sentences.reduce(0) { $0 + $1.targets.count }
        XCTAssertGreaterThanOrEqual(targetCount, 200,
                                    "S02 sense corpus floor: ≥200 targets")

        let service = try MorphologyTestSupport.makeService()
        let glossURL = try XCTUnwrap(MorphologyTestSupport.bundledDictionaryURL)
        let glossSource = try DictionaryGlossSource(url: glossURL)

        var stats: [String: AmbStat] = [:]
        var subsetStats: [String: AmbStat] = [:]
        var totalTargets = 0
        var boundaryHits = 0
        var entryHits = 0
        var top1Hits = 0

        var oovSpurious = 0
        var oovTotal = 0
        var resolvedCount = 0
        var ambiguousCount = 0
        var unresolvedCount = 0
        var candidateCountSum = 0
        var candidateCountMax = 0
        var truncatedCount = 0
        var misses: [String] = []
        var restrictedReport: [String] = []
        let senseVisible = 0   // 候选对象不携带 sense 字段——恒为 0
        var expectedEntryTargets = 0
        var boundaryHitEntries = 0

        // prompt 预算累积
        var occurrenceBytes: [Int] = []

        for sentence in sentences {
            let tokens = try await service.tokenize(
                MorphologyTestSupport.makeBlock(sentence.text))
            for token in tokens where token.tokenClass.countsForCoverage {
                switch token.resolutionStatus {
                case .resolved: resolvedCount += 1
                case .ambiguous: ambiguousCount += 1
                case .unresolved: unresolvedCount += 1
                }
                candidateCountSum += token.candidates.count
                candidateCountMax = max(candidateCountMax, token.candidates.count)
            }
            for token in tokens where token.tokenClass != .nonLexical {
                let overlaps = sentence.targets.contains { target in
                    token.sourceRangeUTF16.overlaps(
                        target.utf16Start..<(target.utf16Start + target.utf16Len))
                }
                if overlaps {
                    // §6.3 prompt 预算：只序列化与标注 target 相关的
                    // occurrence（语料全量的近似）。
                    if token.candidates.isEmpty { continue }
                    var serialized: [[String: Any]] = []
                    for candidate in token.candidates {
                        var senses: [[String: Any]] = []
                        if let entryID = candidate.entryID {
                            for sense in try glossSource.glosses(entryID: entryID) {
                                senses.append([
                                    "senseID": sense.senseID,
                                    "gloss": sense.glosses,
                                ])
                            }
                        }
                        serialized.append([
                            "entryID": candidate.entryID ?? -1,
                            "lemma": candidate.lemma,
                            "reading": candidate.reading ?? "",
                            "pos": candidate.posCodes,
                            "senses": senses,
                        ])
                    }
                    let payload: [String: Any] = [
                        "surface": token.surface,
                        "lemma": token.candidates.first?.lemma ?? "",
                        "reading": token.reading ?? "",
                        "pos": token.candidates.first?.posCodes ?? [],
                        "candidates": serialized,
                    ]
                    let bytes = (try? JSONSerialization.data(
                        withJSONObject: payload).count) ?? 0
                    occurrenceBytes.append(bytes)
                }
            }
            for target in sentence.targets {
                totalTargets += 1
                if target.expectedEntryID != nil { expectedEntryTargets += 1 }
                let range = target.utf16Start..<(target.utf16Start + target.utf16Len)
                let covering = tokens.first { $0.sourceRangeUTF16 == range }

                func accumulate(_ key: String, into table: inout [String: AmbStat]) {
                    var stat = table[key] ?? AmbStat()
                    stat.total += 1
                    if target.expectedEntryID != nil { stat.expectedEntry += 1 }
                    defer { table[key] = stat }
                    guard let covering else {
                        stat.missing.append(
                            "\(sentence.sentenceID):\(target.surface)→\(target.lemma) [no-token]")
                        return
                    }
                    stat.boundaryHit += 1
                    guard let expectedEntry = target.expectedEntryID else {
                        // 期望 OOV/无词典词：记录 resolver 是否仍给出
                        // entry 候选（spurious——「非法候选」风险面）。
                        if covering.candidates.contains(where: { $0.entryID != nil }) {
                            stat.oovSpurious += 1
                        }
                        return
                    }
                    if covering.candidates.contains(where: { $0.entryID == expectedEntry }) {
                        stat.entryInTop5 += 1
                        if covering.candidates.first?.entryID == expectedEntry {
                            stat.entryIsTop1 += 1
                        }
                    } else {
                        stat.missing.append(
                            "\(sentence.sentenceID):\(target.surface)→e\(expectedEntry)"
                                + " got[\(covering.candidates.prefix(5).map { String($0.entryID ?? -1) }.joined(separator: ","))]")
                    }
                }
                accumulate(target.ambiguity, into: &stats)
                accumulate(sentence.subset, into: &subsetStats)

                guard let covering else {
                    if target.expectedEntryID != nil {
                        misses.append(
                            "\(sentence.sentenceID):\(target.surface)→e\(target.expectedEntryID!) [no-token]")
                    }
                    continue
                }
                boundaryHits += 1
                if covering.candidates.count >= MorphologyCandidate.maximumRetained {
                    truncatedCount += 1
                }
                if let expectedEntry = target.expectedEntryID {
                    boundaryHitEntries += 1
                    if covering.candidates.contains(where: { $0.entryID == expectedEntry }) {
                        entryHits += 1
                        if covering.candidates.first?.entryID == expectedEntry {
                            top1Hits += 1
                        }
                    } else {
                        misses.append(
                            "\(sentence.sentenceID):\(target.surface)→e\(expectedEntry)"
                                + " got[\(covering.candidates.prefix(5).map { String($0.entryID ?? -1) }.joined(separator: ","))]")
                    }
                } else {
                    oovTotal += 1
                    if covering.candidates.contains(where: { $0.entryID != nil }) {
                        oovSpurious += 1
                    }
                }
                // sense 级可见性：MorphologyCandidate 无 senseID/gloss/
                // restriction 字段——可见率按定义恒为 0，如实记录。
                if target.expectedSenseID != nil {
                    // 仍可证伪：候选对象上没有任何字段可承载 sense 详情。
                }
                if target.ambiguity == "restricted" {
                    restrictedReport.append(
                        "\(sentence.sentenceID):\(target.surface)→e\(target.expectedEntryID ?? -1)"
                            + "/s\(target.expectedSenseID ?? -1)"
                            + " got[\(covering.candidates.map { String($0.entryID ?? -1) }.joined(separator: ","))]")
                }
            }
        }
        // senseVisible 恒 0：候选对象不携带 sense 字段（见上注释）。
        let senseTargets = sentences.reduce(0) {
            $0 + $1.targets.filter { $0.expectedSenseID != nil }.count
        }

        // entry recall 双口径：
        // - all：boundary miss 计为 recall miss（无 token 即无候选，
        //   这是「候选召回」对 AI 消歧的真实上限）；
        // - given-boundary：仅诊断候选排序质量。
        let recallAll = Double(entryHits) / Double(max(expectedEntryTargets, 1))
        let recallHit = Double(entryHits) / Double(max(boundaryHitEntries, 1))
        let boundaryRate = Double(boundaryHits) / Double(totalTargets)
        let top1All = Double(top1Hits) / Double(max(expectedEntryTargets, 1))
        let top1Hit = Double(top1Hits) / Double(max(boundaryHitEntries, 1))
        let coverageTokens = resolvedCount + ambiguousCount + unresolvedCount

        // prompt 预算汇总：48 KiB / 40 occurrence（§6.3 起始工程预算）。
        let budgetBytes = 48 * 1024
        let budgetOccurrences = 40
        var requestBlocks = 0
        var blockBytes = 0
        var blockOccurrences = 0
        for bytes in occurrenceBytes {
            if blockOccurrences >= budgetOccurrences
                || blockBytes + bytes > budgetBytes {
                requestBlocks += 1
                blockBytes = 0
                blockOccurrences = 0
            }
            blockBytes += bytes
            blockOccurrences += 1
        }
        if blockOccurrences > 0 { requestBlocks += 1 }
        let avgBytes = occurrenceBytes.isEmpty ? 0
            : occurrenceBytes.reduce(0, +) / occurrenceBytes.count
        let maxBytes = occurrenceBytes.max() ?? 0

        print("""

        ==== S02 Sense Corpus v1 baseline ====
        sentences=\(sentences.count) targets=\(totalTargets) \
        expected-entry targets=\(expectedEntryTargets) \
        (dev+validation split inside JSONL)
        boundary: hit=\(boundaryHits)/\(totalTargets) rate=\(String(format: "%.4f", boundaryRate))
        entry recall (all expected-entry targets, boundary miss counts): \
        \(entryHits)/\(expectedEntryTargets) = \(String(format: "%.4f", recallAll))
        entry recall | boundary hit (diagnostic): \
        \(entryHits)/\(boundaryHitEntries) = \(String(format: "%.4f", recallHit))
        entry top-1 (all / given-boundary): \
        \(top1Hits)/\(expectedEntryTargets) = \(String(format: "%.4f", top1All)) / \
        \(top1Hits)/\(boundaryHitEntries) = \(String(format: "%.4f", top1Hit))
        tokens at ≤5-candidate truncation: \(truncatedCount)
        status: resolved=\(resolvedCount) ambiguous=\(ambiguousCount) \
        unresolved=\(unresolvedCount) (coverage tokens=\(coverageTokens))
        candidates/token: mean=\(String(format: "%.2f", coverageTokens > 0 ? Double(candidateCountSum) / Double(coverageTokens) : 0)) max=\(candidateCountMax)
        OOV targets=\(oovTotal), spurious entry candidates offered=\(oovSpurious)
        sense-level visibility: \(senseVisible)/\(senseTargets) — \
        MorphologyCandidate carries entryID only (no senseID/gloss/
        restriction); sense detail NOT visible on resolver output objects
        prompt budget (§6.3, full sense gloss per candidate entry):
          occurrences serialized=\(occurrenceBytes.count)
          bytes/occurrence: avg=\(avgBytes) max=\(maxBytes)
          request blocks @ ≤40 occ & ≤48KiB: \(requestBlocks)
        ==== per-ambiguity ====
        """)
        for key in ["monosemous", "polysemous", "restricted", "proper", "oov"] {
            guard let stat = stats[key] else { continue }
            let r = stat.expectedEntry > 0
                ? Double(stat.entryInTop5) / Double(stat.expectedEntry) : 0
            let t1 = stat.expectedEntry > 0
                ? Double(stat.entryIsTop1) / Double(stat.expectedEntry) : 0
            print("  \(key): n=\(stat.total) expectedEntry=\(stat.expectedEntry) "
                + "boundary=\(stat.boundaryHit) "
                + "entryInTop5=\(stat.entryInTop5) (\(String(format: "%.4f", r))) "
                + "top1=\(stat.entryIsTop1) (\(String(format: "%.4f", t1)))"
                + (stat.oovSpurious > 0 ? " spurious=\(stat.oovSpurious)" : ""))
            for miss in stat.missing.prefix(6) { print("    miss: \(miss)") }
        }
        print("==== per-subset ====")
        for key in ["dev", "validation"] {
            guard let stat = subsetStats[key] else { continue }
            let r = stat.expectedEntry > 0
                ? Double(stat.entryInTop5) / Double(stat.expectedEntry) : 0
            print("  \(key): n=\(stat.total) expectedEntry=\(stat.expectedEntry) "
                + "boundary=\(stat.boundaryHit) "
                + "entryInTop5=\(stat.entryInTop5) (\(String(format: "%.4f", r)))")
        }
        print("==== restricted targets (entry-level view) ====")
        for line in restrictedReport { print("  \(line)") }
        print("==== total entry misses: \(misses.count) ====")
        for miss in misses.prefix(50) { print("  miss: \(miss)") }

        // —— 断言下限（floor）：取首轮实测水位留余量（boundary≈0.92 /
        //    recallAll≈0.91 / top1All≈0.83，见 stdout）；发布目标
        //    候选召回 ≥95% 的差距写进报告，不在此抬门槛——
        XCTAssertGreaterThanOrEqual(boundaryRate, 0.88, "boundary floor")
        XCTAssertGreaterThanOrEqual(recallAll, 0.86, "entry recall floor (≥95% is release target, not asserted here)")
        XCTAssertGreaterThanOrEqual(top1All, 0.75, "entry top-1 floor")
        XCTAssertEqual(senseVisible, 0,
                       "candidates are entry-level: sense visibility is 0 by construction")
        // oovSpurious 只记录不断言——「非法候选落库 0」是发布目标，
        // 当前测的是 resolver 对 OOV 仍给候选的事实面（写入报告）。
    }
}
