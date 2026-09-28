import Foundation
import OboeDomain
import XCTest
@testable import Oboe

/// S22 `ReaderAnalyticsViewModel` 语义测试：载入聚合、空态、文档选择
/// 与趋势段重载（世代守卫丢弃过期响应）、数值明细/AX 摘要文本。
@MainActor
final class ReaderAnalyticsViewModelTests: XCTestCase {

    private func makeDoc(
        title: String = "doc",
        coverage: ReaderDocumentLatestCoverage? = nil
    ) -> ReaderDocumentSummary {
        ReaderDocumentSummary(
            documentID: UUID(), title: title, documentExists: true,
            lastOpenedAt: nil, progressBasisPoints: nil,
            eventCount: 0, latestCoverage: coverage
        )
    }

    private func makeCoverage(day: String = "2026-09-15") -> ReaderDocumentLatestCoverage {
        ReaderDocumentLatestCoverage(
            studyDayID: day, metricVersion: "coverage-1.0.0",
            morphologyVersion: "morph-1",
            uniqueKnownOrLearningCoverage: 0.9, tokenCoverage: 0.8,
            isPartial: false, analyzedBlocks: 3, totalBlocks: 3
        )
    }

    private func makeTotals() -> ReaderActivityTotals {
        ReaderActivityTotals(
            minedNewNote: 4, linkedExistingNote: 1, createdCloze: 2,
            markedKnown: 7, resetKnowledge: 1, undoneCount: 2
        )
    }

    private func makePoints() -> [ReaderActivityDayPoint] {
        [
            ReaderActivityDayPoint(
                localDate: "2026-09-14", minedNewNote: 0,
                linkedExistingNote: 0, createdCloze: 0,
                markedKnown: 0, resetKnowledge: 0),
            ReaderActivityDayPoint(
                localDate: "2026-09-15", minedNewNote: 2,
                linkedExistingNote: 1, createdCloze: 1,
                markedKnown: 3, resetKnowledge: 0),
        ]
    }

    // MARK: - 载入

    func testLoadPopulatesAllSections() async {
        let source = StubReaderAnalyticsSource()
        await source.setTotals(makeTotals())
        await source.setDaily(makePoints())
        await source.setKnowledge(ReaderKnowledgeSummary(
            knownCount: 12, learningCount: 4, ignoredCount: 2,
            trackedLexemeCount: 30))
        let doc = makeDoc(coverage: makeCoverage())
        await source.setDocuments([doc])
        await source.setTimeline([
            ReaderTimelineEntry(
                id: UUID(), kind: .minedNewNote,
                createdAt: Date(), localDate: "2026-09-15",
                writtenForm: "夢", documentTitle: "doc", isUndone: false)
        ])
        await source.setTrend([ReaderCoverageTrendSegment(
            index: 0, metricVersion: "coverage-1.0.0",
            morphologyVersion: "morph-1", dictionaryVersion: "dict-1",
            points: []
        )])
        let model = ReaderAnalyticsViewModel(source: source)

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.totals?.miningCount, 5)
        XCTAssertEqual(model.knowledge?.knownCount, 12)
        XCTAssertEqual(model.daily.count, 2)
        XCTAssertEqual(model.documents.count, 1)
        XCTAssertEqual(model.timeline.count, 1)
        // 自动选中首个文档 → 触发趋势请求。
        XCTAssertEqual(model.selectedDocumentID, doc.documentID)
        while model.isTrendLoading { await Task.yield() }
        XCTAssertEqual(model.trendSegments.count, 1)
        XCTAssertTrue(model.hasAnyData)
    }

    func testLoadFailureSurfacesErrorAndKeepsEmptyState() async {
        let source = StubReaderAnalyticsSource()
        await source.setFailure(TestError.boom)
        let model = ReaderAnalyticsViewModel(source: source)

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.totals)
        XCTAssertTrue(model.daily.isEmpty)
        XCTAssertFalse(model.hasAnyData)
    }

    // MARK: - 选择与趋势重载

    /// 切换文档只重拉趋势；过期响应被世代号丢弃。
    func testDocumentSwitchReloadsTrendOnly() async {
        let source = StubReaderAnalyticsSource()
        let docA = makeDoc(title: "A", coverage: makeCoverage())
        let docB = makeDoc(title: "B", coverage: makeCoverage())
        await source.setTotals(makeTotals())
        await source.setDaily([])
        await source.setKnowledge(ReaderKnowledgeSummary(
            knownCount: 0, learningCount: 0, ignoredCount: 0,
            trackedLexemeCount: 0))
        await source.setDocuments([docA, docB])
        await source.setTimeline([])
        let model = ReaderAnalyticsViewModel(source: source)
        await model.load()
        while model.isTrendLoading { await Task.yield() }
        let requestsBefore = await source.trendRequests.count
        let totalsCallsBefore = await source.totalsCallCount

        model.selectedDocumentID = docB.documentID
        while await source.trendRequests.count <= requestsBefore {
            await Task.yield()
        }
        while model.isTrendLoading { await Task.yield() }

        XCTAssertEqual(model.selectedDocumentID, docB.documentID)
        let totalsCallsAfter = await source.totalsCallCount
        XCTAssertEqual(totalsCallsAfter, totalsCallsBefore)  // 不重拉总量
        let requests = await source.trendRequests
        XCTAssertEqual(
            requests,
            [docA.documentID, docB.documentID])
    }

    // MARK: - 展示语义

    /// 无数据/无正文态：不伪造 0%、文档状态文案正确。
    func testEmptyAndNoBodyStates() async {
        let source = StubReaderAnalyticsSource()
        await source.setTotals(ReaderActivityTotals(
            minedNewNote: 0, linkedExistingNote: 0, createdCloze: 0,
            markedKnown: 0, resetKnowledge: 0, undoneCount: 0))
        await source.setDaily([])
        await source.setKnowledge(ReaderKnowledgeSummary(
            knownCount: 0, learningCount: 0, ignoredCount: 0,
            trackedLexemeCount: 0))
        let noBody = ReaderDocumentSummary(
            documentID: UUID(), title: "空文档", documentExists: true,
            lastOpenedAt: nil, progressBasisPoints: nil, eventCount: 0,
            latestCoverage: ReaderDocumentLatestCoverage(
                studyDayID: "2026-09-15", metricVersion: "m",
                morphologyVersion: "v",
                uniqueKnownOrLearningCoverage: nil, tokenCoverage: nil,
                isPartial: false, analyzedBlocks: 0, totalBlocks: 0))
        await source.setDocuments([noBody])
        await source.setTimeline([])
        let model = ReaderAnalyticsViewModel(source: source)

        await model.load()

        XCTAssertFalse(model.hasAnyData)
        XCTAssertEqual(model.percentText(nil), "—")
        XCTAssertEqual(
            model.selectedDocumentStatus,
            "最近学习日 2026-09-15：暂无可统计词汇")
        XCTAssertEqual(
            model.dailyChartAccessibilitySummary, "暂无阅读活动")
        XCTAssertEqual(
            model.trendChartAccessibilitySummary, "暂无覆盖率记录")
    }

    /// 已删文档状态文案：coverage 仍可读、带「已删除」标注。
    func testDeletedDocumentStatusLabel() async {
        let source = StubReaderAnalyticsSource()
        await source.setTotals(makeTotals())
        await source.setDaily([])
        await source.setKnowledge(ReaderKnowledgeSummary(
            knownCount: 0, learningCount: 0, ignoredCount: 0,
            trackedLexemeCount: 0))
        let deleted = ReaderDocumentSummary(
            documentID: UUID(), title: "旧文档", documentExists: false,
            lastOpenedAt: nil, progressBasisPoints: nil, eventCount: 0,
            latestCoverage: makeCoverage(day: "2026-09-10"))
        await source.setDocuments([deleted])
        await source.setTimeline([])
        let model = ReaderAnalyticsViewModel(source: source)
        await model.load()

        XCTAssertEqual(
            model.selectedDocumentStatus,
            "最近学习日 2026-09-10：覆盖率 90% · 已删除")
    }

    /// 逐日明细文本与图表 AX 摘要。
    func testDailySummariesAndAccessibility() async {
        let model = ReaderAnalyticsViewModel(source: StubReaderAnalyticsSource())
        model.daily = makePoints()
        model.totals = makeTotals()

        XCTAssertEqual(
            model.dayPointSummary(model.daily[0]), "2026-09-14：无阅读操作")
        XCTAssertEqual(
            model.dayPointSummary(model.daily[1]),
            "2026-09-15：挖词 3，句卡 1，标知 3")
        XCTAssertEqual(
            model.dailyChartAccessibilitySummary,
            "近 2 个学习日内有 1 天产生阅读操作，挖词 5 次，句卡 2 次，标知 7 次；已撤销 2 次不计入")
    }

    /// 时间线与趋势段文案。
    func testTimelineAndSegmentSummaries() {
        let model = ReaderAnalyticsViewModel(source: StubReaderAnalyticsSource())
        let entry = ReaderTimelineEntry(
            id: UUID(), kind: .markedKnown,
            createdAt: Date(), localDate: "2026-09-15",
            writtenForm: "知る", documentTitle: "夏目", isUndone: true)
        XCTAssertEqual(
            model.timelineEntrySummary(entry),
            "标为已掌握「知る」 · 夏目（已撤销）")
        XCTAssertEqual(model.kindTitle(.minedNewNote), "挖词（新建）")
        XCTAssertEqual(model.kindTitle(.createdCloze), "制作句卡")

        let segment = ReaderCoverageTrendSegment(
            index: 1, metricVersion: "coverage-1.0.0",
            morphologyVersion: "morph-2", dictionaryVersion: nil,
            points: [
                ReaderCoverageTrendPoint(
                    id: UUID(), studyDayID: "2026-09-15",
                    createdAt: Date(),
                    uniqueKnownOrLearningCoverage: 0.85,
                    tokenCoverage: 0.7, isPartial: true,
                    analyzedBlocks: 2, totalBlocks: 5)
            ])
        XCTAssertEqual(
            model.segmentLabel(segment),
            "形态 morph-2 · 口径 coverage-1.0.0 · 词典 未记录")
        XCTAssertEqual(
            model.trendPointSummary(segment.points[0]),
            "2026-09-15：覆盖率 85%（已分析 2/5 块）")
        model.trendSegments = [segment]
        XCTAssertEqual(
            model.trendChartAccessibilitySummary,
            "共 1 个版本段：形态 morph-2 · 口径 coverage-1.0.0 · 词典 未记录 共 1 个学习日")
    }
}

// MARK: - 桩件

private enum TestError: Error {
    case boom
}

private actor StubReaderAnalyticsSource: ReaderAnalyticsFetching {
    private var totalsResult: Result<ReaderActivityTotals, Error> =
        .failure(TestError.boom)
    private var dailyResult: Result<[ReaderActivityDayPoint], Error> =
        .success([])
    private var knowledgeResult: Result<ReaderKnowledgeSummary, Error> =
        .failure(TestError.boom)
    private var documentsResult: Result<[ReaderDocumentSummary], Error> =
        .success([])
    private var timelineResult: Result<[ReaderTimelineEntry], Error> =
        .success([])
    private var trendResult: Result<[ReaderCoverageTrendSegment], Error> =
        .success([])

    private(set) var trendRequests: [UUID] = []
    private(set) var totalsCallCount = 0

    func setTotals(_ v: ReaderActivityTotals) { totalsResult = .success(v) }
    func setDaily(_ v: [ReaderActivityDayPoint]) { dailyResult = .success(v) }
    func setKnowledge(_ v: ReaderKnowledgeSummary) {
        knowledgeResult = .success(v)
    }
    func setDocuments(_ v: [ReaderDocumentSummary]) {
        documentsResult = .success(v)
    }
    func setTimeline(_ v: [ReaderTimelineEntry]) { timelineResult = .success(v) }
    func setTrend(_ v: [ReaderCoverageTrendSegment]) {
        trendResult = .success(v)
    }
    func setFailure(_ error: Error) {
        totalsResult = .failure(error)
        dailyResult = .failure(error)
        knowledgeResult = .failure(error)
        documentsResult = .failure(error)
        timelineResult = .failure(error)
        trendResult = .failure(error)
    }

    func activityTotals() async throws -> ReaderActivityTotals {
        totalsCallCount += 1
        return try totalsResult.get()
    }
    func dailyActivity(
        dayCount: Int
    ) async throws -> [ReaderActivityDayPoint] {
        try dailyResult.get()
    }
    func knowledgeSummary() async throws -> ReaderKnowledgeSummary {
        try knowledgeResult.get()
    }
    func documentSummaries(
        limit: Int
    ) async throws -> [ReaderDocumentSummary] {
        try documentsResult.get()
    }
    func coverageTrend(
        documentID: UUID
    ) async throws -> [ReaderCoverageTrendSegment] {
        trendRequests.append(documentID)
        return try trendResult.get()
    }
    func activityTimeline(
        limit: Int
    ) async throws -> [ReaderTimelineEntry] {
        try timelineResult.get()
    }
}
