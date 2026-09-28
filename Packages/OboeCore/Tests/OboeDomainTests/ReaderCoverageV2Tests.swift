import Foundation
import XCTest
@testable import OboeDomain

/// S14 Coverage v2 纯函数测试：`coverage-resolved-sense-2.0.0`
/// 口径（contracts §5.2、技术文档 §13.3、D09）——已解析 unit
/// 去重分母；OOV/待确认只进展示字段；空分母 nil；partial 范围。
final class ReaderCoverageV2Tests: XCTestCase {

    private func stats(
        pending: Int = 0,
        oov: Int = 0,
        analyzed: Int = 1,
        total: Int = 1
    ) -> ReaderCoverageV2.OccurrenceStats {
        ReaderCoverageV2.OccurrenceStats(
            pendingOccurrences: pending,
            oovOccurrences: oov,
            analyzedBlocks: analyzed,
            totalBlocks: total)
    }

    private func unit(
        _ id: UUID,
        _ state: LearningKnowledgeState
    ) -> ReaderCoverageV2.ResolvedUnit {
        ReaderCoverageV2.ResolvedUnit(unitID: id, state: state)
    }

    /// metricVersion 常量冻结（快照 metric_version 列值）。
    func testMetricVersionConstant() {
        XCTAssertEqual(
            ReaderCoverageV2.metricVersion,
            "coverage-resolved-sense-2.0.0")
        XCTAssertEqual(
            ReaderCoverageV2.Result.metricVersion,
            ReaderCoverageV2.metricVersion)
    }

    /// resolved 去重：同 unitID 的多处 occurrence 只计一次；
    /// learning+mastered 作分子，unknown resolved unit 在分母
    /// 不在分子（§13.3）。
    func testResolvedUnitsDeduplicated() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let r = ReaderCoverageV2.compute(
            units: [
                unit(a, .learning), unit(a, .learning), unit(a, .learning),
                unit(b, .mastered), unit(b, .mastered),
                unit(c, .unknown),
            ],
            occurrenceStats: stats(analyzed: 4, total: 4))

        XCTAssertEqual(r.resolvedUnique, 3)
        XCTAssertEqual(r.learningUnique, 1)
        XCTAssertEqual(r.masteredUnique, 1)
        XCTAssertEqual(r.unlearnedUnique, 1)   // unknown：分母不计分子
        XCTAssertEqual(r.resolvedCoverage ?? -1, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(r.masteredCoverage ?? -1, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertFalse(r.isPartial)
    }

    /// OOV/pending 不进分母但计数可见（D09：防 1 个已解析词
    /// 冒充全书高覆盖率）。
    func testOovAndPendingVisibleButNotInDenominator() {
        let a = UUID()
        let r = ReaderCoverageV2.compute(
            units: [unit(a, .learning)],
            occurrenceStats: stats(
                pending: 7, oov: 13, analyzed: 2, total: 10))

        XCTAssertEqual(r.resolvedUnique, 1)
        XCTAssertEqual(r.resolvedCoverage ?? -1, 1.0, accuracy: 1e-12)
        // 相邻展示字段：OOV/待确认 occurrence 与 partial 范围。
        XCTAssertEqual(r.pendingOccurrences, 7)
        XCTAssertEqual(r.oovOccurrences, 13)
        XCTAssertTrue(r.isPartial)  // 2/10 块已分析——不可展示全书
    }

    /// 空分母 → nil（无已解析 unit：全 OOV/未确认范围）。
    func testEmptyDenominatorYieldsNil() {
        let r = ReaderCoverageV2.compute(
            units: [],
            occurrenceStats: stats(pending: 3, oov: 9))
        XCTAssertEqual(r.resolvedUnique, 0)
        XCTAssertNil(r.resolvedCoverage)
        XCTAssertNil(r.masteredCoverage)
        XCTAssertEqual(r.pendingOccurrences, 3)
        XCTAssertEqual(r.oovOccurrences, 9)
    }

    /// 全 mastered：resolvedCoverage 与 masteredCoverage 同到 1。
    func testAllMastered() {
        let r = ReaderCoverageV2.compute(
            units: [unit(UUID(), .mastered), unit(UUID(), .mastered)],
            occurrenceStats: stats())
        XCTAssertEqual(r.resolvedCoverage ?? -1, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.masteredCoverage ?? -1, 1.0, accuracy: 1e-12)
        XCTAssertEqual(r.unlearnedUnique, 0)
    }

    /// partial 范围：analyzedBlocks < totalBlocks → isPartial；
    /// analyzed == total → 非 partial。
    func testPartialRangeFlag() {
        let a = UUID()
        let partial = ReaderCoverageV2.compute(
            units: [unit(a, .learning)],
            occurrenceStats: stats(analyzed: 3, total: 12))
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.analyzedBlocks, 3)
        XCTAssertEqual(partial.totalBlocks, 12)

        let complete = ReaderCoverageV2.compute(
            units: [unit(a, .learning)],
            occurrenceStats: stats(analyzed: 12, total: 12))
        XCTAssertFalse(complete.isPartial)
    }

    /// 同 unitID 重复行状态不一致（投影异常）→ 取最强者保证
    /// 确定性：mastered > learning > unknown。
    func testConflictingDuplicateStatesResolveToStrongest() {
        let a = UUID()
        let mastered = ReaderCoverageV2.compute(
            units: [unit(a, .unknown), unit(a, .mastered)],
            occurrenceStats: stats())
        XCTAssertEqual(mastered.resolvedUnique, 1)
        XCTAssertEqual(mastered.masteredUnique, 1)

        let learning = ReaderCoverageV2.compute(
            units: [unit(a, .learning), unit(a, .unknown)],
            occurrenceStats: stats())
        XCTAssertEqual(learning.learningUnique, 1)
        XCTAssertEqual(learning.unlearnedUnique, 0)
    }

    /// 输入顺序不影响结果（去重 + 最强者规则确定）。
    func testOrderIndependent() {
        let a = UUID()
        let b = UUID()
        let forward = ReaderCoverageV2.compute(
            units: [unit(a, .learning), unit(b, .mastered), unit(a, .mastered)],
            occurrenceStats: stats())
        let reversed = ReaderCoverageV2.compute(
            units: [unit(b, .mastered), unit(a, .mastered), unit(a, .learning)],
            occurrenceStats: stats())
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.masteredUnique, 2)
    }
}
