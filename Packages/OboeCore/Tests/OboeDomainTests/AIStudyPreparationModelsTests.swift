import XCTest
@testable import OboeDomain

/// v0.7.5 S15 编排层领域值类型验收：句界确定性、manifest 编码
/// 稳定/拒未知版本、JLPT 参考索引歧义剔除、选择策略冻结语义、
/// 输入指纹同输入同值。
final class AIStudyPreparationModelsTests: XCTestCase {

    // MARK: - 句界（AIStudySentenceSegments）

    func testSentenceRangesCoverFullText() {
        let text = "彼は学校に行った。今日は雨だ！明日は晴れる？"
        let ranges = AIStudySentenceSegments.ranges(of: text)
        XCTAssertEqual(ranges.count, 3)
        // 覆盖全文不留缺口。
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, text.utf16.count)
        for pair in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
        }
    }

    func testSentenceRangesGroupContiguousTerminators() {
        // 连续终止符并入同一句（「？！」「……」「\r\n」）。
        let text = "本当に？！そうか。\r\n次"
        let ranges = AIStudySentenceSegments.ranges(of: text)
        XCTAssertEqual(ranges.count, 3)
        let units = Array(text.utf16)
        XCTAssertEqual(
            String(decoding: units[ranges[0]], as: UTF16.self),
            "本当に？！")
        XCTAssertEqual(
            String(decoding: units[ranges[1]], as: UTF16.self),
            "そうか。\r\n")
    }

    func testSentenceRangesTrailingFragmentAndEmpty() {
        XCTAssertTrue(AIStudySentenceSegments.ranges(of: "").isEmpty)
        // 末段无终止符也成句。
        let text = "今日は晴れ。明日"
        let ranges = AIStudySentenceSegments.ranges(of: text)
        XCTAssertEqual(ranges.count, 2)
        // 「…」单独成句界。
        XCTAssertEqual(
            AIStudySentenceSegments.ranges(of: "ええと…そうか").count, 2)
    }

    // MARK: - Manifest 编码

    private func makeManifest() -> AIStudyJobManifest {
        AIStudyJobManifest(
            jobID: UUID(uuidString:
                "00000000-0000-0000-0000-000000000001")!,
            documentID: UUID(uuidString:
                "00000000-0000-0000-0000-000000000002")!,
            contentRevision: 3,
            scope: .chapters(["ch-1"]),
            parserVersion: "parser-1",
            morphologyVersion: "morph-1",
            osBuild: "os-1",
            dictionaryDatasetVersion: "ds-1",
            tokenizerVersion: "parser-1|morph-1|os-1",
            providerKind: "deepseek",
            endpointFingerprint: "fp",
            model: "model-1",
            responseMode: "promptedJSON",
            promptVersion: "v1",
            language: "zho",
            maxGlossesPerSense: 3,
            blocks: [
                AIStudyJobManifest.Block(
                    scopeKey: "k", readerBlockID: UUID(),
                    chapterID: UUID(), chapterOrdinal: 0,
                    blockOrdinal: 0, sourceHash: "h",
                    sourceText: "テスト。次", context: "",
                    sentenceRanges: [0, 5, 5, 7],
                    wantsTranslation: true, tokens: []),
            ],
            dictionaryEntries: [])
    }

    func testManifestEncodeDecodeRoundTrip() throws {
        let manifest = makeManifest()
        let data = try manifest.encoded()
        let decoded = try AIStudyJobManifest.decode(data)
        XCTAssertEqual(manifest, decoded)
    }

    func testManifestEncodingIsDeterministic() throws {
        let manifest = makeManifest()
        let first = try manifest.encoded()
        let second = try manifest.encoded()
        XCTAssertEqual(first, second, "sortedKeys 编码必须逐字节稳定")
    }

    func testManifestRejectsUnsupportedFormatVersion() throws {
        var manifest = makeManifest()
        manifest.formatVersion = 99
        let data = try manifest.encoded()
        XCTAssertThrowsError(try AIStudyJobManifest.decode(data)) {
            error in
            guard case AIStudyJobManifest.ManifestError
                .unsupportedFormat(99) = error else {
                return XCTFail("期望 unsupportedFormat，得 \(error)")
            }
        }
    }

    // MARK: - JLPT 参考索引

    func testJLPTIndexUniqueHitAndAmbiguity() {
        let index = AIStudyJLPTReferenceIndex(rows: [
            .init(headword: "食べる", reading: "たべる", level: .n5),
            .init(headword: "曖昧", reading: "あいまい", level: .n3),
            // 同键不同级 → 歧义剔除。
            .init(headword: "重複", reading: "ちょうふく", level: .n2),
            .init(headword: "重複", reading: "ちょうふく", level: .n1),
        ])
        XCTAssertEqual(
            index.level(headword: "食べる", reading: "たべる"), .n5)
        // 歧义键不附级（宁缺勿滥）。
        XCTAssertNil(index.level(headword: "重複", reading: "ちょうふく"))
        // 未命中。
        XCTAssertNil(index.level(headword: "存在しない", reading: nil))
    }

    func testJLPTIndexNormalization() {
        let index = AIStudyJLPTReferenceIndex(rows: [
            .init(headword: "学校", reading: "がっこう", level: .n5),
        ])
        // 大小写/空白归一化后仍命中（SearchTextNormalizer 同族）。
        XCTAssertEqual(
            index.level(headword: " 学校 ", reading: "がっこう"), .n5)
    }

    // MARK: - 选择策略

    private func makeItem(
        _ unitKey: String,
        lowConfidence: Bool = false,
        tooEasy: Bool = false,
        jlpt: JLPTLevel? = nil,
        linkedNotes: [AIStudyPreviewItem.LinkedNote] = []
    ) -> AIStudyPreviewItem {
        AIStudyPreviewItem(
            unitKey: unitKey, entryID: 1, senseID: 1,
            headword: unitKey, reading: nil, glossSummary: nil,
            jlptLevel: jlpt, occurrenceCount: 1,
            firstSentence: nil, firstLocator: nil,
            evidenceRevision: 1,
            confidenceRange: lowConfidence ? 0.2...0.4 : 0.8...0.95,
            containsLowConfidence: lowConfidence,
            existingUnitID: nil, unitIsTooEasy: tooEasy,
            linkedNotes: linkedNotes, duplicateNotes: [],
            decision: nil, proposedAction: nil)
    }

    func testRecommendedStrategySkipsLowConfidenceAndTooEasy() {
        var items = [
            makeItem("plain"),
            makeItem("low", lowConfidence: true),
            makeItem("easy", tooEasy: true),
        ]
        let deckID = UUID()
        AIStudySelectionStrategy.recommended.apply(
            to: &items, studyDeckID: deckID,
            directions: [.japaneseToChinese])
        XCTAssertEqual(items[0].decision, .create)
        XCTAssertEqual(
            items[0].proposedAction,
            .createNote(directions: [.japaneseToChinese]))
        // 含低置信行不进策略覆盖集——决策保持未动。
        XCTAssertNil(items[1].decision)
        // tooEasy 在覆盖集内 → 强制 .tooEasy。
        XCTAssertEqual(items[2].decision, .tooEasy)
        XCTAssertEqual(items[2].proposedAction, .setTooEasy)
    }

    func testAllStrategyIncludesLowConfidence() {
        var items = [makeItem("low", lowConfidence: true)]
        AIStudySelectionStrategy.all.apply(
            to: &items, studyDeckID: nil,
            directions: [.japaneseToChinese])
        XCTAssertEqual(items[0].decision, .create)
    }

    func testJLPTStrategyFiltersLevels() {
        var items = [
            makeItem("n5item", jlpt: .n5),
            makeItem("n1item", jlpt: .n1),
            makeItem("noLevel"),
        ]
        AIStudySelectionStrategy.jlpt([.n5, .n4]).apply(
            to: &items, studyDeckID: nil,
            directions: [.japaneseToChinese])
        XCTAssertEqual(items[0].decision, .create)
        XCTAssertNil(items[1].decision)
        XCTAssertNil(items[2].decision)
    }

    func testNewItemsLimitBudgetOnlyCountsCreates() {
        let note = AIStudyPreviewItem.LinkedNote(
            noteID: UUID(), headword: "既存", reading: nil,
            deckID: UUID())
        var items = [
            makeItem("hasNote", linkedNotes: [note]),
            makeItem("new1"),
            makeItem("new2"),
        ]
        AIStudySelectionStrategy.newItemsLimit(1).apply(
            to: &items, studyDeckID: UUID(),
            directions: [.japaneseToChinese])
        // linked Note → reuse，不占新建名额。
        XCTAssertEqual(items[0].decision, .reuse)
        XCTAssertEqual(items[1].decision, .create)
        // 名额耗尽 → skip。
        XCTAssertEqual(items[2].decision, .skip)
        XCTAssertEqual(items[2].proposedAction, .recordSkip)
    }

    // MARK: - 输入指纹 / 范围请求

    func testInputFingerprintDeterministic() {
        let base: (
            UUID, Int64, String, [String], String, String, String,
            String, String, String, String, String, String, String
        ) = (
            UUID(), 1, "scope-hash", ["h1", "h2"], "ds", "m", "p",
            "os", "provider", "endpoint", "model", "mode", "prompt",
            "policy"
        )
        let a = AIStudyInputFingerprint.compute(
            documentID: base.0, contentRevision: base.1,
            scopeHash: base.2, blockHashes: base.3,
            dictionaryDatasetVersion: base.4,
            morphologyVersion: base.5, parserVersion: base.6,
            osBuild: base.7, providerKind: base.8,
            endpointFingerprint: base.9, model: base.10,
            responseMode: base.11, promptVersion: base.12,
            language: "zho", policyVersion: base.13)
        let b = AIStudyInputFingerprint.compute(
            documentID: base.0, contentRevision: base.1,
            scopeHash: base.2, blockHashes: base.3,
            dictionaryDatasetVersion: base.4,
            morphologyVersion: base.5, parserVersion: base.6,
            osBuild: base.7, providerKind: base.8,
            endpointFingerprint: base.9, model: base.10,
            responseMode: base.11, promptVersion: base.12,
            language: "zho", policyVersion: base.13)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64, "SHA-256 hex")
        // 块 hash 改变 → 指纹漂移。
        let c = AIStudyInputFingerprint.compute(
            documentID: base.0, contentRevision: base.1,
            scopeHash: base.2, blockHashes: ["h3"],
            dictionaryDatasetVersion: base.4,
            morphologyVersion: base.5, parserVersion: base.6,
            osBuild: base.7, providerKind: base.8,
            endpointFingerprint: base.9, model: base.10,
            responseMode: base.11, promptVersion: base.12,
            language: "zho", policyVersion: base.13)
        XCTAssertNotEqual(a, c)
    }

    func testScopeChoiceDisplayNames() {
        XCTAssertEqual(AIStudyScopeChoice.currentText.displayName, "当前段")
        XCTAssertEqual(
            AIStudyScopeChoice.unprocessedChapters.displayName,
            "未处理章节")
        XCTAssertEqual(AIStudyScopeChoice.allCases.count, 4)
    }

    func testPreviewItemAccessibilityLabelIncludesIdentity() {
        let item = makeItem(
            "jmdict:sense-v1:100:abc",
            jlpt: .n5,
            linkedNotes: [])
        let label = item.accessibilityLabelText
        XCTAssertTrue(label.contains("jmdict:sense-v1:100:abc"))
        XCTAssertTrue(label.contains("N5"))
        XCTAssertTrue(label.contains("出现 1 次"))
    }
}
