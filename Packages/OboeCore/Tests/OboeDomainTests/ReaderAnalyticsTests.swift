import Foundation
import XCTest
import OboeDomain

/// S22 `ReaderAnalytics` 纯类型测试：版本分段的 run 归并、
/// 派生计数口径、nil 语义。
final class ReaderAnalyticsTests: XCTestCase {

    private func point(
        _ day: String
    ) -> (metricVersion: String, morphologyVersion: String,
          dictionaryVersion: String?, point: ReaderCoverageTrendPoint) {
        (
            metricVersion: "m",
            morphologyVersion: "v",
            dictionaryVersion: "d",
            point: ReaderCoverageTrendPoint(
                id: UUID(), studyDayID: day,
                createdAt: Date(timeIntervalSince1970: 1),
                uniqueKnownOrLearningCoverage: 0.5,
                tokenCoverage: 0.4,
                isPartial: false, analyzedBlocks: 1, totalBlocks: 1
            )
        )
    }

    private func versioned(
        _ day: String, metric: String, morphology: String, dict: String?
    ) -> (metricVersion: String, morphologyVersion: String,
          dictionaryVersion: String?, point: ReaderCoverageTrendPoint) {
        (
            metricVersion: metric,
            morphologyVersion: morphology,
            dictionaryVersion: dict,
            point: ReaderCoverageTrendPoint(
                id: UUID(), studyDayID: day,
                createdAt: Date(timeIntervalSince1970: 1),
                uniqueKnownOrLearningCoverage: nil,
                tokenCoverage: nil,
                isPartial: false, analyzedBlocks: 1, totalBlocks: 1
            )
        )
    }

    /// 空输入 → 空段列表；同版本连续点归并成单段。
    func testSegmentationMergesConsecutiveEqualVersions() {
        XCTAssertTrue(ReaderCoverageSegmentation.segments(of: []).isEmpty)
        let segments = ReaderCoverageSegmentation.segments(
            of: [point("d1"), point("d2"), point("d3")])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].points.count, 3)
        XCTAssertEqual(segments[0].versionKey, "m|v|d")
    }

    /// A→B→A：版本回退开新段而不是回接前段（不跨时段连线）。
    func testSegmentationNeverReconnectsAcrossVersionSwitch() {
        var items = [point("d1"), point("d2")]
        items.append(versioned("d3", metric: "m", morphology: "v2", dict: "d"))
        items.append(point("d4"))
        let segments = ReaderCoverageSegmentation.segments(of: items)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.points.count), [2, 1, 1])
        XCTAssertEqual(segments.map(\.id), [0, 1, 2])
        // 两个 morph-1 段各自独立——id 不同才能被图表当不同序列。
        XCTAssertNotEqual(segments[0].id, segments[2].id)
        XCTAssertEqual(segments[0].versionKey, segments[2].versionKey)
    }

    /// dictionary_version 的 nil↔值 也是版本切换；nil 键渲染为 "—"。
    func testSegmentationTreatsNilDictionaryAsBoundary() {
        let items = [
            versioned("d1", metric: "m", morphology: "v", dict: nil),
            versioned("d2", metric: "m", morphology: "v", dict: "d1"),
        ]
        let segments = ReaderCoverageSegmentation.segments(of: items)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].versionKey, "m|v|—")
    }

    /// 单点也成段——孤立版本行不是「无数据」。
    func testSinglePointFormsSegment() {
        let segments = ReaderCoverageSegmentation.segments(of: [point("d1")])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].points.count, 1)
    }

    /// 派生计数：mining = 新建+关联；cardCreation = 新建+cloze；
    /// total 是全部五态和。
    func testDayPointDerivedCounts() {
        let p = ReaderActivityDayPoint(
            localDate: "2026-09-15",
            minedNewNote: 2, linkedExistingNote: 1, createdCloze: 3,
            markedKnown: 4, resetKnowledge: 1
        )
        XCTAssertEqual(p.total, 11)
        XCTAssertEqual(p.miningCount, 3)
        XCTAssertEqual(p.cardCreationCount, 5)
        XCTAssertFalse(p.isUnfiled)
        XCTAssertEqual(p.id, "2026-09-15")
        let unfiled = ReaderActivityDayPoint(
            localDate: "", minedNewNote: 1, linkedExistingNote: 0,
            createdCloze: 0, markedKnown: 0, resetKnowledge: 0
        )
        XCTAssertTrue(unfiled.isUnfiled)
    }

    /// `unmarkedCount` 钳到非负（并发窗口四支计数非同一快照时
    /// 不向外暴露负值）。
    func testUnmarkedCountNeverNegative() {
        let s = ReaderKnowledgeSummary(
            knownCount: 5, learningCount: 5, ignoredCount: 5,
            trackedLexemeCount: 10
        )
        XCTAssertEqual(s.unmarkedCount, 0)
        let normal = ReaderKnowledgeSummary(
            knownCount: 1, learningCount: 2, ignoredCount: 1,
            trackedLexemeCount: 10
        )
        XCTAssertEqual(normal.unmarkedCount, 6)
    }

    /// `progress` = basisPoints/10000；nil 保持 nil（不伪造 0%）。
    func testDocumentSummaryProgressMapping() {
        let noProgress = ReaderDocumentSummary(
            documentID: UUID(), title: "t", documentExists: true,
            lastOpenedAt: nil, progressBasisPoints: nil,
            eventCount: 0, latestCoverage: nil
        )
        XCTAssertNil(noProgress.progress)
        let half = ReaderDocumentSummary(
            documentID: UUID(), title: "t", documentExists: true,
            lastOpenedAt: nil, progressBasisPoints: 5000,
            eventCount: 0, latestCoverage: nil
        )
        XCTAssertEqual(half.progress, 0.5)
    }

    /// `hasNoBody` = totalBlocks == 0（未分析过的空文档快照）。
    func testLatestCoverageHasNoBody() {
        let empty = ReaderDocumentLatestCoverage(
            studyDayID: "d", metricVersion: "m", morphologyVersion: "v",
            uniqueKnownOrLearningCoverage: nil, tokenCoverage: nil,
            isPartial: false, analyzedBlocks: 0, totalBlocks: 0
        )
        XCTAssertTrue(empty.hasNoBody)
        let body = ReaderDocumentLatestCoverage(
            studyDayID: "d", metricVersion: "m", morphologyVersion: "v",
            uniqueKnownOrLearningCoverage: 0.5, tokenCoverage: 0.4,
            isPartial: true, analyzedBlocks: 1, totalBlocks: 3
        )
        XCTAssertFalse(body.hasNoBody)
        XCTAssertTrue(body.isPartial)
    }
}
