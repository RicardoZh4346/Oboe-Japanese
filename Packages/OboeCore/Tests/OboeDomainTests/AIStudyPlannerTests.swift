import Foundation
import XCTest
@testable import OboeDomain

/// S09 planner 测试：候选构建（sense 级过滤/排序/上限）、块拆分
/// （40 occ/48KiB 双预算、句界/range）、tokenID/blockKey/requestHash
/// 确定性、UTF-16 边界、OOV 占位与「候选过多」标记。
///
/// 依据：contracts §3.1/§4.4、技术文档 §6.2–§6.3、S02-B §8。
final class AIStudyPlannerTests: XCTestCase {

    // MARK: - 基础构建

    /// 单 token 单候选：请求块完整携带 sense 级 payload
    /// （senseID + gloss + 限制），弥补 S02-B 发现的 entry-only 缺口。
    func testBlockCarriesSenseLevelCandidates() async throws {
        let entry = makeAIStudyEntry(
            id: 100, primaryForm: "降る",
            senses: [
                (id: 1001, pos: ["v5r"], glosses: ["to fall (rain)"],
                 rForms: [], rReadings: ["ふる"]),
                (id: 1002, pos: ["v5r"], glosses: ["to descend"],
                 rForms: [], rReadings: ["おりる"]),
            ])
        let token = makeAIStudyToken(
            surface: "降った", start: 0, length: 3, reading: "ふる",
            candidates: [makeAIStudyMorphCandidate(
                lemma: "降る", entryID: 100, pos: ["v5r"], reading: "ふる")])
        let requests = try await plan(
            sourceText: "降った。", tokens: [token], entries: [entry])
        let block = try XCTUnwrap(requests.first?.blocks.first)
        let studyToken = try XCTUnwrap(block.tokens.first)
        XCTAssertEqual(studyToken.surface, "降った")
        let candidate = try XCTUnwrap(studyToken.candidates.first)
        XCTAssertEqual(candidate.entryID, 100)
        let sense = try XCTUnwrap(candidate.senses.first)
        XCTAssertEqual(sense.senseID, 1001)
        XCTAssertEqual(sense.enGlosses, ["to fall (rain)"])
        XCTAssertEqual(sense.restrictedReadings, ["ふる"])
    }

    /// stagr 限制（S02-B 实测案例）：降った 読み「ふる」只应看到
    /// ふる 系义项，おりる 义项在候选层就被剪掉——不靠 AI 猜。
    func testSenseReadingRestrictionFiltersInadmissibleSenses() async throws {
        let entry = makeAIStudyEntry(
            id: 100, primaryForm: "降る",
            senses: [
                (id: 1001, pos: ["v5r"], glosses: ["to fall (rain)"],
                 rForms: [], rReadings: ["ふる"]),
                (id: 1002, pos: ["v5r"], glosses: ["to get off"],
                 rForms: [], rReadings: ["おりる"]),
                (id: 1003, pos: ["v5r"], glosses: ["generic sense"],
                 rForms: [], rReadings: []),
            ])
        let token = makeAIStudyToken(
            surface: "降った", start: 0, length: 3, reading: "ふる",
            candidates: [makeAIStudyMorphCandidate(
                lemma: "降る", entryID: 100, pos: ["v5r"], reading: "ふる")])
        let requests = try await plan(
            sourceText: "降った。", tokens: [token], entries: [entry])
        let senses = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first?.candidates.first?.senses)
        XCTAssertEqual(senses.map(\.senseID), [1001, 1003])
    }

    /// stagk 限制：sense 限定表记不在 {lemma, normalizedForm,
    /// primaryForm} 证据内 → 剔除。
    func testSenseFormRestrictionFiltersInadmissibleSenses() async throws {
        let entry = makeAIStudyEntry(
            id: 200, primaryForm: "上る",
            senses: [
                (id: 2001, pos: ["v5r"], glosses: ["to go up"],
                 rForms: ["上る"], rReadings: []),
                (id: 2002, pos: ["v5r"], glosses: ["to rise (nobori)"],
                 rForms: ["昇る"], rReadings: []),
            ])
        let token = makeAIStudyToken(
            surface: "上った", start: 0, length: 3, reading: "のぼっ",
            candidates: [makeAIStudyMorphCandidate(
                lemma: "上る", entryID: 200, pos: ["v5r"], reading: "のぼる")])
        let requests = try await plan(
            sourceText: "上った。", tokens: [token], entries: [entry])
        let senses = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first?.candidates.first?.senses)
        XCTAssertEqual(senses.map(\.senseID), [2001])
    }

    /// admissible POS 门：候选带 posCodes 时，sense.posCodes
    /// 不相交的义项不进候选集。
    func testPOSGateFiltersSenses() async throws {
        let entry = makeAIStudyEntry(
            id: 300, primaryForm: "走る",
            senses: [
                (id: 3001, pos: ["v5r"], glosses: ["to run"],
                 rForms: [], rReadings: []),
                (id: 3002, pos: ["n"], glosses: ["a run (noun)"],
                 rForms: [], rReadings: []),
            ])
        let token = makeAIStudyToken(
            surface: "走った", start: 0, length: 3,
            candidates: [makeAIStudyMorphCandidate(
                lemma: "走る", entryID: 300, pos: ["v5r"])])
        let requests = try await plan(
            sourceText: "走った。", tokens: [token], entries: [entry])
        let senses = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first?.candidates.first?.senses)
        XCTAssertEqual(senses.map(\.senseID), [3001])
    }

    /// 全部 sense 被限制/门过滤 → 整个候选不发送；
    /// 词典缺 entry → 同样不产生伪候选（S02-B §8）。
    func testFullyFilteredOrMissingEntryYieldsNoCandidate() async throws {
        let filteredEntry = makeAIStudyEntry(
            id: 400, primaryForm: "X",
            senses: [(id: 4001, pos: ["n"], glosses: ["noun only"],
                      rForms: [], rReadings: [])])
        let token = makeAIStudyToken(
            surface: "走った", start: 0, length: 3,
            candidates: [
                // entry 400 存在但全部 sense 被 POS 门过滤
                makeAIStudyMorphCandidate(
                    lemma: "X", entryID: 400, pos: ["v5r"]),
                // entry 999 在词典源中缺失
                makeAIStudyMorphCandidate(
                    lemma: "Y", entryID: 999, pos: ["v5r"]),
            ])
        let requests = try await plan(
            sourceText: "走った。", tokens: [token],
            entries: [filteredEntry])
        let studyToken = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first)
        XCTAssertTrue(studyToken.candidates.isEmpty,
                      "全过滤/词典缺失的候选不得作为空壳发送")
    }

    /// OOV token：candidates=[] 显式占位照常进请求（绝不造伪候选）。
    func testOOVTokenEmittedWithEmptyCandidates() async throws {
        let token = makeAIStudyToken(
            surface: "ケシカラン", start: 0, length: 5,
            tokenClass: .outOfVocabulary, candidates: [])
        let requests = try await plan(
            sourceText: "ケシカラン。", tokens: [token], entries: [])
        let studyToken = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first)
        XCTAssertEqual(studyToken.surface, "ケシカラン")
        XCTAssertTrue(studyToken.candidates.isEmpty)
        XCTAssertFalse(studyToken.tokenID.isEmpty)
    }

    // MARK: - 块拆分预算

    /// 40 occ 边界：41 个目标 → 40 + 1 两块；目标区间互不重叠。
    func testSplitsAtFortyOccurrenceBoundary() async throws {
        let (text, tokens) = makeAIStudyTokenSequence(count: 41)
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].blocks[0].tokens.count, 40)
        XCTAssertEqual(requests[1].blocks[0].tokens.count, 1)
        let range0 = requests[0].blocks[0].targetUTF16Range
        let range1 = requests[1].blocks[0].targetUTF16Range
        XCTAssertFalse(range0.overlaps(range1),
                       "§6.3：请求目标区间不得重叠")
    }

    /// 恰好 40 → 单块。
    func testExactlyFortyOccurrencesStaysSingleBlock() async throws {
        let (text, tokens) = makeAIStudyTokenSequence(count: 40)
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].blocks[0].tokens.count, 40)
    }

    /// 字节预算：大体积候选触发 subblock 拆分；拆分后每块
    /// 序列化 ≤ 预算，且候选字段完整保留（不丢 sense/gloss）。
    func testByteBudgetSplitsWithoutLosingCandidateData() async throws {
        // 每 token 候选带长 gloss（~2.5KB/个），40 个必然超 48KiB。
        let bigGloss = String(repeating: "gloss-padding-", count: 150)
        let entry = makeAIStudyEntry(
            id: 500, primaryForm: "詞",
            senses: [(id: 5001, pos: ["n"], glosses: [bigGloss],
                      rForms: [], rReadings: [])])
        let (text, tokens) = makeAIStudyTokenSequence(
            count: 30,
            candidates: [makeAIStudyMorphCandidate(
                lemma: "詞", entryID: 500, pos: ["n"])])
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [entry])
        XCTAssertGreaterThan(requests.count, 1,
                             "候选体积超预算必须切 subblock")
        var seenTokenIDs = Set<String>()
        for request in requests {
            let block = request.blocks[0]
            for token in block.tokens {
                XCTAssertTrue(seenTokenIDs.insert(token.tokenID).inserted,
                              "token 不丢不重")
                // 候选完整性：sense/gloss 原样保留
                let candidate = try XCTUnwrap(token.candidates.first)
                XCTAssertEqual(candidate.senses.first?.enGlosses, [bigGloss])
            }
        }
        XCTAssertEqual(seenTokenIDs.count, 30)
    }

    /// 单 token 候选组自身超预算 → 「候选过多需确认」标记，
    /// 整块单列；senses 不截断。
    func testOversizeCandidateGroupFlaggedNotTruncated() async throws {
        let hugeGloss = String(repeating: "x", count: 60 * 1024)
        let entry = makeAIStudyEntry(
            id: 600, primaryForm: "巨",
            senses: [(id: 6001, pos: ["n"], glosses: [hugeGloss],
                      rForms: [], rReadings: [])])
        let token = makeAIStudyToken(
            surface: "巨", start: 0, length: 1,
            candidates: [makeAIStudyMorphCandidate(
                lemma: "巨", entryID: 600, pos: ["n"])])
        let requests = try await plan(
            sourceText: "巨。", tokens: [token], entries: [entry])
        let studyToken = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first)
        XCTAssertTrue(studyToken.needsCandidateConfirmation,
                      "候选组超预算 → 标记位（§6.3 候选过多需确认）")
        XCTAssertEqual(studyToken.candidates.first?.senses.first?.enGlosses,
                       [hugeGloss], "不静默砍义项：gloss 完整保留")
    }

    /// 候选 entry 数超上限（>5）→ 契约截取至 5 并置标记位，
    /// 保留候选的 sense 完整。
    func testExcessiveEntryCandidatesCappedAndFlagged() async throws {
        let entries = (0..<7).map { i in
            makeAIStudyEntry(
                id: Int64(700 + i), primaryForm: "多\(i)",
                senses: [(id: Int64(7000 + i), pos: ["n"],
                          glosses: ["g\(i)"], rForms: [], rReadings: [])])
        }
        let token = makeAIStudyToken(
            surface: "多", start: 0, length: 1,
            candidates: entries.enumerated().map { i, entry in
                makeAIStudyMorphCandidate(
                    lemma: "多\(i)", entryID: entry.id,
                    pos: ["n"], cost: i)
            })
        let requests = try await plan(
            sourceText: "多。", tokens: [token], entries: entries)
        let studyToken = try XCTUnwrap(
            requests.first?.blocks.first?.tokens.first)
        XCTAssertEqual(studyToken.candidates.count,
                       AIStudyBudget.maxCandidatesPerEntry)
        XCTAssertTrue(studyToken.needsCandidateConfirmation,
                      ">5 候选被契约截取 → 标记进确认队列")
        for candidate in studyToken.candidates {
            XCTAssertEqual(candidate.senses.count, 1,
                           "保留候选的 sense 不得因 entry 截断而丢失")
        }
    }

    /// 超长句（一句超预算）→ 句界不可用时按 range 二分拆分。
    func testLongSentenceBisectedByRange() async throws {
        let bigGloss = String(repeating: "g", count: 1200)
        let entry = makeAIStudyEntry(
            id: 800, primaryForm: "長",
            senses: [(id: 8001, pos: ["n"], glosses: [bigGloss],
                      rForms: [], rReadings: [])])
        let (text, tokens) = makeAIStudyTokenSequence(
            count: 30,
            candidates: [makeAIStudyMorphCandidate(
                lemma: "長", entryID: 800, pos: ["n"])])
        // 整段一个句界——句界拆分不可行，必须退化为 range 二分。
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [entry],
            sentenceRanges: [0..<Array(text.utf16).count])
        XCTAssertGreaterThan(requests.count, 1)
        let total = requests.reduce(0) { $0 + $1.blocks[0].tokens.count }
        XCTAssertEqual(total, 30, "拆分不丢 token")
    }

    /// 句界优先：两块大小都能容纳时按句界切分而非乱序打包。
    func testSentenceBoundaryPreferredForPacking() async throws {
        let (text, tokens) = makeAIStudyTokenSequence(
            count: 4, surfaceLen: 3, separator: "。")
        let utf16 = Array(text.utf16)
        // 两句：token0-1 一句，token2-3 一句。
        let midpoint = tokens[1].sourceRangeUTF16.upperBound + 1
        let ranges = [0..<midpoint, midpoint..<utf16.count]
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [],
            sentenceRanges: ranges)
        // 全部能装下 → 单块；句界只影响超限时的切点。
        XCTAssertEqual(requests.count, 1)
    }

    // MARK: - 确定性 / hash

    /// tokenID/requestHash 稳定：同输入两次规划完全一致
    /// （两进程同值的等价命题——派生不含随机量与时间量）。
    func testTokenIDsAndHashesStableAcrossRuns() async throws {
        let entry = makeAIStudyEntry(
            id: 900, primaryForm: "定",
            senses: [(id: 9001, pos: ["n"], glosses: ["fixed"],
                      rForms: [], rReadings: [])])
        let (text, tokens) = makeAIStudyTokenSequence(
            count: 3,
            candidates: [makeAIStudyMorphCandidate(
                lemma: "定", entryID: 900, pos: ["n"])])
        let requests1 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry])
        let requests2 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry])
        XCTAssertEqual(requests1, requests2)
        XCTAssertEqual(
            requests1[0].blocks[0].tokens.map(\.tokenID),
            requests2[0].blocks[0].tokens.map(\.tokenID))
        XCTAssertEqual(requests1[0].requestHash, requests2[0].requestHash)
        XCTAssertEqual(requests1[0].requestID, requests2[0].requestID)
    }

    /// candidateSetHash 敏感：gloss 或限制任一变化 → hash 变化；
    /// 候选顺序固定 → 同集合同 hash。
    func testCandidateSetHashSensitiveToGlossAndRestriction() async throws {
        func hashFor(gloss: String, rReadings: [String]) async throws -> String {
            let entry = makeAIStudyEntry(
                id: 950, primaryForm: "降る",
                senses: [(id: 9501, pos: ["v5r"], glosses: [gloss],
                          rForms: [], rReadings: rReadings)])
            let token = makeAIStudyToken(
                surface: "降った", start: 0, length: 3, reading: "ふる",
                candidates: [makeAIStudyMorphCandidate(
                    lemma: "降る", entryID: 950, pos: ["v5r"],
                    reading: "ふる")])
            let requests = try await plan(
                sourceText: "降った。", tokens: [token], entries: [entry])
            return try XCTUnwrap(
                requests.first?.blocks.first?.candidateSetHash)
        }
        let base = try await hashFor(gloss: "to fall", rReadings: ["ふる"])
        let glossChanged = try await hashFor(
            gloss: "to fall down", rReadings: ["ふる"])
        let restrictionChanged = try await hashFor(
            gloss: "to fall", rReadings: ["ふる", "おりる"])
        XCTAssertNotEqual(base, glossChanged, "gloss 变化必须换 hash")
        XCTAssertNotEqual(base, restrictionChanged, "限制变化必须换 hash")
    }

    /// requestHash：endpoint 指纹规范化（不含 Key/userinfo/query），
    /// 同指纹同 hash；换 model / provider / promptVersion 换 hash。
    func testRequestHashCoversEndpointNotKeyAndProviderFields() async throws {
        let entry = makeAIStudyEntry(
            id: 960, primaryForm: "鍵",
            senses: [(id: 9601, pos: ["n"], glosses: ["key"],
                      rForms: [], rReadings: [])])
        let (text, tokens) = makeAIStudyTokenSequence(
            count: 1,
            candidates: [makeAIStudyMorphCandidate(
                lemma: "鍵", entryID: 960, pos: ["n"])])

        // endpoint 指纹规范化：Key 出现在 userinfo/query 都必须被剥掉。
        let fingerprint = AIStudyEndpointFingerprint.normalize(
            "https://user:sk-secret@api.example.com:443/v1?key=sk-secret#frag")
        XCTAssertEqual(fingerprint, "https://api.example.com/v1")
        XCTAssertFalse(fingerprint.contains("sk-secret"))

        let meta1 = makeAIStudyMetadata(endpointFingerprint: fingerprint)
        let r1 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry],
            metadata: meta1)
        // 同一指纹（即便原始 URL 带不同 Key，规范化后一致）→ 同 hash。
        let fingerprint2 = AIStudyEndpointFingerprint.normalize(
            "https://other:sk-different@api.example.com/v1/")
        XCTAssertEqual(fingerprint, fingerprint2)
        let r2 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry],
            metadata: makeAIStudyMetadata(endpointFingerprint: fingerprint2))
        XCTAssertEqual(r1[0].requestHash, r2[0].requestHash,
                       "凭据差异不得进入 requestHash")

        // model/provider/endpoint host 变化 → 换 hash。
        let r3 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry],
            metadata: makeAIStudyMetadata(
                endpointFingerprint: fingerprint, model: "other-model"))
        XCTAssertNotEqual(r1[0].requestHash, r3[0].requestHash)
        let r4 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry],
            metadata: makeAIStudyMetadata(
                endpointFingerprint: fingerprint,
                providerKind: "otherProvider"))
        XCTAssertNotEqual(r1[0].requestHash, r4[0].requestHash)
        let r5 = try await plan(
            sourceText: text, tokens: tokens, entries: [entry],
            metadata: makeAIStudyMetadata(
                endpointFingerprint: AIStudyEndpointFingerprint.normalize(
                    "https://api.different.com/v1")))
        XCTAssertNotEqual(r1[0].requestHash, r5[0].requestHash,
                          "同 model 不同服务端不得串缓存")
    }

    /// 序列化请求体不泄露 endpoint/数据集等环境字段（进 hash 即可）。
    func testSerializedRequestOmitsEnvironmentFields() async throws {
        let (text, tokens) = makeAIStudyTokenSequence(count: 1)
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [])
        let wire = AIStudyRequestSerializer.serializedRequest(requests[0])
        for forbidden in [
            "endpointFingerprint", "dictionaryDatasetVersion",
            "morphologyVersion", "osBuild", "apiKey", "credential",
        ] {
            XCTAssertFalse(wire.contains(forbidden), "leaked \(forbidden)")
        }
        XCTAssertTrue(wire.contains("\"schemaVersion\":1"))
    }

    // MARK: - UTF-16 边界

    /// emoji（代理对）与组合字符：token range 切片 == surface 原文，
    /// 后续 token 不错位。
    func testUTF16EmojiAndCombiningRangesStayAligned() async throws {
        // 「あ😀́食べる」：😀 = 2 UTF-16 units，◌́ 组合符 1 unit。
        let text = "あ😀\u{0301}食べる。"
        let tokens = [
            makeAIStudyToken(surface: "あ", start: 0, length: 1),
            makeAIStudyToken(surface: "😀\u{0301}", start: 1, length: 3),
            makeAIStudyToken(surface: "食べる", start: 4, length: 3),
        ]
        let requests = try await plan(
            sourceText: text, tokens: tokens, entries: [])
        let block = try XCTUnwrap(requests.first?.blocks.first)
        let utf16 = Array(text.utf16)
        for token in block.tokens {
            let slice = String(
                decoding: utf16[token.utf16Range], as: UTF16.self)
            XCTAssertEqual(slice, token.surface,
                           "UTF-16 emoji/组合字符 range 不错位")
        }
        // targetText = 最小外接 → 全句
        XCTAssertEqual(block.targetText, text)
    }

    /// 非目标 token（nonLexical）不进请求。
    func testNonLexicalTokensExcluded() async throws {
        let tokens = [
            makeAIStudyToken(surface: "、", start: 0, length: 1,
                             tokenClass: .nonLexical),
            makeAIStudyToken(surface: "語", start: 1, length: 1),
        ]
        let requests = try await plan(
            sourceText: "、語", tokens: tokens, entries: [])
        XCTAssertEqual(requests.first?.blocks.first?.tokens.count, 1)
    }

    /// 无非词汇目标 → 单块纯翻译请求（§6.3 words=[]）。
    func testNoTargetsProducesTranslationOnlyBlock() async throws {
        let tokens = [
            makeAIStudyToken(surface: "。", start: 0, length: 1,
                             tokenClass: .nonLexical),
        ]
        let requests = try await plan(
            sourceText: "。", tokens: tokens, entries: [])
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].blocks[0].tokens.isEmpty)
        XCTAssertTrue(requests[0].blocks[0].wantsTranslation)
    }

    // MARK: - helpers（同 target 内 validator 测试复用）

    private func plan(
        sourceText: String,
        tokens: [ReaderToken],
        entries: [DictionaryEntry],
        sentenceRanges: [Range<Int>] = [],
        metadata: AIStudyRequestMetadata? = nil
    ) async throws -> [AIStudyRequest] {
        let source = StubAIStudySenseSource(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }))
        let planner = AIStudyCandidatePlanner(senseSource: source)
        return try await planner.plan(
            AIStudyPlannerInput(
                scopeKey: "test-scope",
                sourceText: sourceText,
                context: "",
                tokens: tokens,
                sentenceRanges: sentenceRanges),
            metadata: metadata ?? makeAIStudyMetadata())
    }
}

// MARK: - 共享测试构件（同 target 复用）

struct StubAIStudySenseSource: AIStudySenseSource {
    let entries: [Int64: DictionaryEntry]
    func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
        ids.compactMap { entries[$0] }
    }
}

func makeAIStudyMetadata(
    endpointFingerprint: String = "https://api.example.com",
    providerKind: String = "deepseek",
    model: String = "m"
) -> AIStudyRequestMetadata {
    AIStudyRequestMetadata(
        dictionaryDatasetVersion: "2026.09.24-1",
        morphologyVersion: "morph/1",
        parserVersion: "parser/1",
        osBuild: "25A",
        providerKind: providerKind,
        endpointFingerprint: endpointFingerprint,
        model: model,
        responseMode: "json_object",
        promptVersion: "study-prompt/1",
        language: "zho",
        generationParameters: ["temperature": "0.2"])
}

func makeAIStudyEntry(
    id: Int64,
    primaryForm: String,
    senses: [(id: Int64, pos: [String], glosses: [String],
              rForms: [String], rReadings: [String])]
) -> DictionaryEntry {
    DictionaryEntry(
        id: id,
        primaryForm: primaryForm,
        commonRank: nil,
        forms: [DictionaryForm(
            id: id * 100 + 1, text: primaryForm,
            formType: "standard", priority: nil)],
        readings: [],
        senses: senses.enumerated().map { index, s in
            DictionarySense(
                id: s.id, order: index, posCodes: s.pos, tags: [],
                glosses: s.glosses.enumerated().map { gi, g in
                    DictionaryGloss(
                        language: "eng", text: g, order: gi,
                        sourceID: "test", isMachineGenerated: false)
                },
                restrictedForms: s.rForms,
                restrictedReadings: s.rReadings)
        })
}

func makeAIStudyMorphCandidate(
    lemma: String,
    entryID: Int64?,
    pos: [String] = [],
    reading: String? = nil,
    cost: Int = 0
) -> MorphologyCandidate {
    MorphologyCandidate(
        lemma: lemma, normalizedForm: lemma, reading: reading,
        posCodes: pos, entryID: entryID, reasons: [], cost: cost)
}

func makeAIStudyToken(
    surface: String,
    start: Int,
    length: Int,
    tokenClass: ReaderTokenClass = .lexical,
    reading: String? = nil,
    candidates: [MorphologyCandidate] = []
) -> ReaderToken {
    ReaderToken(
        surface: surface,
        sourceRangeUTF16: start..<(start + length),
        mergedSpanUTF16: start..<(start + length),
        systemTokenIndexes: 0..<1,
        candidates: candidates,
        tokenClass: tokenClass,
        reading: reading,
        lexicalKey: nil,
        resolutionStatus: candidates.isEmpty ? .unresolved : .ambiguous,
        provenance: [])
}

/// 构造 count 个连续目标 token 的文本序列：
/// surface 长 surfaceLen + 分隔符（默认 "、" 不进 token）。
func makeAIStudyTokenSequence(
    count: Int,
    surfaceLen: Int = 2,
    separator: String = "、",
    candidates: [MorphologyCandidate] = []
) -> (text: String, tokens: [ReaderToken]) {
    var text = ""
    var tokens: [ReaderToken] = []
    var offset = 0
    for i in 0..<count {
        let surface = String(repeating: "語", count: surfaceLen)
        if i > 0 {
            text += separator
            offset += Array(separator.utf16).count
        }
        text += surface
        tokens.append(makeAIStudyToken(
            surface: surface, start: offset, length: surfaceLen,
            candidates: candidates))
        offset += surfaceLen
    }
    text += "。"
    return (text, tokens)
}
