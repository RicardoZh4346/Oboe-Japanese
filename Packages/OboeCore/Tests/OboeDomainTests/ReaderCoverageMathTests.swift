import Foundation
import XCTest
@testable import OboeDomain

/// S09 覆盖率口径纯函数测试（§7 / D04）。D04 样例：534 known /
/// 31 learning / 42 unknown / 12 ignored → token 87.97%、
/// 已知+学习中 unique 93.08%（全 distinct key 时 token==unique）。
final class ReaderCoverageMathTests: XCTestCase {

    private func contribution(
        _ dedupKey: String,
        identityKey: String? = nil,
        ambiguous: Bool = false,
        oov: Bool = false
    ) -> ReaderCoverageMath.TokenContribution {
        ReaderCoverageMath.TokenContribution(
            dedupKey: dedupKey, identityKey: identityKey,
            isAmbiguous: ambiguous, isOutOfVocabulary: oov)
    }

    /// D04 验收样例：534/31/42/12 → 87.97%（token 已知口径）与
    /// 93.08%（已知+学习中；distinct key 时 token/unique 一致）。
    func testD04SampleExactPercentages() {
        var acc = ReaderCoverageAccumulator()
        for i in 0..<534 { acc.add(contribution("k\(i)"), state: .known) }
        for i in 0..<31 { acc.add(contribution("l\(i)"), state: .learning) }
        for i in 0..<42 { acc.add(contribution("u\(i)"), state: .unknown) }
        for i in 0..<12 { acc.add(contribution("i\(i)"), state: .ignored) }
        let m = acc.metrics(analyzedBlocks: 3, totalBlocks: 3)

        XCTAssertEqual(m.eligible, 607)  // ignored 不进分母
        XCTAssertEqual(m.tokenCoverage ?? 0, 534.0 / 607.0, accuracy: 1e-12)
        XCTAssertEqual(
            m.knownOrLearningCoverage ?? 0, 565.0 / 607.0, accuracy: 1e-12)
        XCTAssertEqual(
            String(format: "%.2f%%", (m.tokenCoverage ?? 0) * 100), "87.97%")
        XCTAssertEqual(
            String(format: "%.2f%%", (m.knownOrLearningCoverage ?? 0) * 100),
            "93.08%")
        // 全 distinct → unique 与 token 一致（D04 第二口径落点）。
        XCTAssertEqual(m.uniqueEligible, 607)
        XCTAssertEqual(
            m.uniqueKnownOrLearningCoverage ?? 0, 565.0 / 607.0,
            accuracy: 1e-12)
        // 快照持久化投影：unique_numerator = |K∪L| = 565。
        XCTAssertEqual(m.uniqueKnown + m.uniqueLearning, 565)
        XCTAssertFalse(m.isPartial)
    }

    /// 重复 lemma 去重：同 dedupKey 的多次 token 在 unique 口径计 1。
    func testUniqueDedupAcrossBlocks() {
        var a = ReaderCoverageAccumulator()
        var b = ReaderCoverageAccumulator()
        // 同一 lexeme 在两块各出现 3/2 次。
        for _ in 0..<3 { a.add(contribution("k-dup"), state: .known) }
        for _ in 0..<2 { b.add(contribution("k-dup"), state: .known) }
        b.add(contribution("u-1"), state: .unknown)
        a.merge(b)
        let m = a.metrics(analyzedBlocks: 2, totalBlocks: 2)
        XCTAssertEqual(m.known, 5)
        XCTAssertEqual(m.uniqueKnown, 1)
        XCTAssertEqual(m.uniqueEligible, 2)
        XCTAssertEqual(m.tokenCoverage ?? 0, 5.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(m.uniqueCoverage ?? 0, 0.5, accuracy: 1e-12)
    }

    /// eligible==0：全 ignored → 「暂无可统计词汇」（nil），不是 100%。
    func testAllIgnoredDenominatorZero() {
        var acc = ReaderCoverageAccumulator()
        for i in 0..<4 { acc.add(contribution("i\(i)"), state: .ignored) }
        let m = acc.metrics(analyzedBlocks: 1, totalBlocks: 1)
        XCTAssertNil(m.tokenCoverage)
        XCTAssertNil(m.knownOrLearningCoverage)
        XCTAssertNil(m.uniqueKnownOrLearningCoverage)
        XCTAssertTrue(m.hasAnyCountableTokens)  // 有 token 但全被排除
        XCTAssertFalse(m.hasEligibleTokens)
    }

    /// 无词文档：0 可计 token——与全 OOV 文档区分（后者覆盖率为 0）。
    func testEmptyDocumentDistinctFromAllOOV() {
        let empty = ReaderCoverageAccumulator()
            .metrics(analyzedBlocks: 1, totalBlocks: 1)
        XCTAssertFalse(empty.hasAnyCountableTokens)
        XCTAssertNil(empty.tokenCoverage)

        var oov = ReaderCoverageAccumulator()
        oov.add(contribution("oov|x", oov: true), state: .unknown)
        let m = oov.metrics(analyzedBlocks: 1, totalBlocks: 1)
        XCTAssertTrue(m.hasAnyCountableTokens)
        XCTAssertEqual(m.outOfVocabulary, 1)
        XCTAssertEqual(m.tokenCoverage ?? -1, 0.0, accuracy: 1e-12)
    }

    /// 分类器：nonLexical 不计入；无 key → unknown + unresolved 去重键；
    /// 歧义 → unknown + pending；OOV → unknown + OOV 标记。
    func testContributionClassification() {
        func token(
            _ surface: String,
            klass: ReaderTokenClass,
            status: TokenResolutionStatus,
            key: LexicalKey? = nil,
            candidates: [MorphologyCandidate] = []
        ) -> ReaderToken {
            ReaderToken(
                surface: surface, sourceRangeUTF16: 0..<surface.utf16.count,
                systemTokenIndexes: 0..<1, candidates: candidates,
                tokenClass: klass, reading: nil, lexicalKey: key,
                resolutionStatus: status, provenance: [])
        }
        // nonLexical → 无贡献
        XCTAssertNil(ReaderCoverageMath.contribution(
            of: token("、", klass: .nonLexical, status: .unresolved)))
        // resolved + key → identityKey 去重
        let key = LexicalKey(provider: .jmdict, externalID: "1",
                             identityKey: "jmdict|1|見る|みる")
        let keyed = ReaderCoverageMath.contribution(
            of: token("見る", klass: .lexical, status: .resolved, key: key))
        XCTAssertEqual(keyed?.dedupKey, "jmdict|1|見る|みる")
        XCTAssertEqual(keyed?.identityKey, "jmdict|1|見る|みる")
        // unresolved 无候选 → OOV + unresolved|<normalized>
        let oov = ReaderCoverageMath.contribution(
            of: token("hello", klass: .outOfVocabulary, status: .unresolved))
        XCTAssertEqual(oov?.dedupKey, "unresolved|hello")
        XCTAssertNil(oov?.identityKey)
        XCTAssertTrue(oov?.isOutOfVocabulary ?? false)
        // ambiguous 有候选无 key → 待确认（unknown），非 OOV
        let amb = ReaderCoverageMath.contribution(
            of: token("今日", klass: .lexical, status: .ambiguous,
                      candidates: [MorphologyCandidate(
                        lemma: "今日", normalizedForm: "今日",
                        reading: "きょう", posCodes: [], entryID: 1,
                        reasons: [], cost: 0)]))
        XCTAssertTrue(amb?.isAmbiguous ?? false)
        XCTAssertFalse(amb?.isOutOfVocabulary ?? true)
        // 状态解析：无 key → unknown；有 key 未落库 → unknown；
        // 落库 → 查表值。
        XCTAssertEqual(
            ReaderCoverageMath.state(of: oov!, states: [:]), .unknown)
        XCTAssertEqual(
            ReaderCoverageMath.state(of: keyed!, states: [:]), .unknown)
        XCTAssertEqual(
            ReaderCoverageMath.state(
                of: keyed!, states: ["jmdict|1|見る|みる": .known]),
            .known)
    }

    /// partial 语义：analyzed<total → isPartial（取消/中断不得冒充全书）。
    func testPartialFlag() {
        let partial = ReaderCoverageAccumulator()
            .metrics(analyzedBlocks: 2, totalBlocks: 5)
        XCTAssertTrue(partial.isPartial)
        let complete = ReaderCoverageAccumulator()
            .metrics(analyzedBlocks: 5, totalBlocks: 5)
        XCTAssertFalse(complete.isPartial)
    }
}
