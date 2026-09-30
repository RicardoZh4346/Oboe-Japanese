import Foundation
import XCTest
@testable import OboeDomain

/// S09 validator 测试：需求 §48 Resolver 全矩阵 + 追加边界。
/// 依据：contracts §3.2/§3.3 分层校验、技术文档 §7 校验表、
/// S02-B §8（OOV no-candidate、候选集成员校验）。
///
/// 矩阵对照（需求 §48「AI Resolver」行）：
/// - 合法候选            → testValidCandidateAccepted
/// - 非法 entryID        → testRejectsEntryIDNotInCandidateSet
/// - 非法 senseID        → testRejectsSenseIDNotInCandidateSet
/// - duplicate tokenID   → testDuplicateTokenIDDifferentAnswersDowngrades
/// - low confidence      → testLowConfidenceRoutedToConfirmation
/// - partial invalid     → testMalformedItemPreservesOthers /
///                         testInvalidItemPreservesValidOnes
/// - malformed JSON      → testMalformedJSONFailsEnvelope
/// - timeout/cancel      → 传输层职责（S10），validator 不覆盖
///
/// 追加（S09 工作包指定）：
/// - token 不存在        → testUnknownTokenIDDropped
/// - 跨 token 偷换       → testRejectsCrossTokenCandidateSwap
/// - 非法 sense（限制不符）→ testRejectsSenseViolatingRestriction
/// - 缺项                → testMissingTokenMarkedUnresolved
/// - NaN/越界 confidence → testOutOfRangeConfidenceDowngradesItem
/// - 译文空/超长          → testEmptyOrOversizedTranslationFailsSubstatusOnly
/// - requestID/schemaVersion 不符 → testRequestIDMismatchRejectsEnvelope /
///                                 testSchemaVersionMismatchRejectsEnvelope
/// - OOV 造伪候选         → testOOVTokenRejectsFabricatedCandidate
final class AIStudyValidatorTests: XCTestCase {

    // MARK: - §48 合法候选

    func testValidCandidateAccepted() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], []), (1002, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.97),
        ])
        XCTAssertEqual(outcome.lexicalStatus, .resolved)
        XCTAssertEqual(outcome.translationStatus, .done)
        XCTAssertEqual(outcome.translation, "译文")
        let resolution = resolutionFor(outcome, "t01")
        XCTAssertEqual(resolution?.status, .aiResolved)
        XCTAssertEqual(resolution?.selected?.entryID, 100)
        XCTAssertEqual(resolution?.selected?.senseID, 1001)
        XCTAssertEqual(resolution?.selected?.datasetVersion,
                       "2026.09.24-1")
        XCTAssertEqual(resolution?.origin, .ai)
        XCTAssertEqual(outcome.aiResolvedCount, 1)
    }

    // MARK: - §48 非法 entryID / senseID

    func testRejectsEntryIDNotInCandidateSet() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 999, senseID: 1001,
                 confidence: 0.9),   // entryID ∉ t01 候选
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.9),
        ])
        let bad = resolutionFor(outcome, "t01")
        XCTAssertEqual(bad?.status, .rejected)
        XCTAssertEqual(bad?.reasonCode, .candidateNotInSet)
        XCTAssertNil(bad?.selected, "非法候选不产生选定行（§3.3）")
        // 单项坏数据不影响同块其他项
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .aiResolved)
        XCTAssertEqual(outcome.lexicalStatus, .partial)
        XCTAssertEqual(outcome.invalidItemCount, 1)
    }

    func testRejectsSenseIDNotInCandidateSet() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], []), (1002, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 7777,
                 confidence: 0.9),   // entry 合法但 senseID ∉ 该候选
        ])
        let bad = resolutionFor(outcome, "t01")
        XCTAssertEqual(bad?.status, .rejected)
        XCTAssertEqual(bad?.reasonCode, .candidateNotInSet)
    }

    /// 跨 token 偷换：(entryID,senseID) 在请求别处合法，
    /// 但不属于**该 token** 候选集 → 非法（§3.2/§7）。
    func testRejectsCrossTokenCandidateSwap() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            // 把 t02 的合法候选贴在 t01 上
            word("t01", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.95),
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.95),
        ])
        let swapped = resolutionFor(outcome, "t01")
        XCTAssertEqual(swapped?.status, .rejected)
        XCTAssertEqual(swapped?.reasonCode, .candidateNotInSet)
        XCTAssertNil(swapped?.selected)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .aiResolved)
    }

    /// sense 限制不符：候选里发出的 sense 带 stagr=[おりる]，
    /// 但该 occurrence 的读音证据（matched/候选/token）皆无 おりる
    /// → validator 独立复核拒绝（即便元素出自候选集合内）。
    func testRejectsSenseViolatingRestriction() {
        let candidate = AIStudyCandidate(
            entryID: 100, lemma: "降る", reading: "ふる",
            matchedForm: "降る", matchedReading: "ふる",
            senses: [
                AIStudyCandidateSense(
                    senseID: 1002, enGlosses: ["to get off"],
                    restrictedForms: [], restrictedReadings: ["おりる"]),
            ])
        let request = makeRequest(tokens: [
            AIStudyToken(
                tokenID: "t01", surface: "降った", lemma: "降る",
                reading: "ふる", posFamily: "verb",
                utf16Start: 0, utf16Length: 3, candidates: [candidate]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1002,
                 confidence: 0.9),
        ])
        let bad = resolutionFor(outcome, "t01")
        XCTAssertEqual(bad?.status, .rejected)
        XCTAssertEqual(bad?.reasonCode, .restrictionNotSatisfied)
    }

    // MARK: - §48 duplicate tokenID

    /// 重复 tokenID（答案不同）→ 该 token 整体降级 unresolved，
    /// 不 last-write-wins；其他 token 保留（§7）。
    func testDuplicateTokenIDDifferentAnswersDowngrades() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], []), (1002, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
            word("t01", status: "resolved", entryID: 100, senseID: 1002,
                 confidence: 0.8),
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.9),
        ])
        let dup = resolutionFor(outcome, "t01")
        XCTAssertEqual(dup?.status, .unresolved)
        XCTAssertEqual(dup?.reasonCode, .duplicateTokenID)
        XCTAssertNil(dup?.selected)
        XCTAssertEqual(outcome.duplicateTokenCount, 1)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .aiResolved)
    }

    // MARK: - §48 low confidence

    /// confidence < lowConfidenceThreshold：合法但进确认队列——
    /// 选定保留、状态 lowConfidence、块为 partial（不可自动采纳）。
    /// v0.7.5-F：阈值 0.80→0.50（provider 保守自报不再当主拦截器）。
    func testLowConfidenceRoutedToConfirmation() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.3),
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.95),
        ])
        let low = resolutionFor(outcome, "t01")
        XCTAssertEqual(low?.status, .lowConfidence)
        XCTAssertEqual(low?.reasonCode, .belowConfidenceThreshold)
        XCTAssertEqual(low?.selected?.senseID, 1001,
                       "低置信保留原候选——用户可确认，不许填伪造 ID")
        XCTAssertEqual(low?.confidence, 0.3)
        XCTAssertEqual(outcome.lowConfidenceCount, 1)
        XCTAssertEqual(outcome.lexicalStatus, .partial)
    }

    /// 0.5–0.79 区间（原阈值会拦下的段）现在直通——C5 的判定面。
    func testModerateConfidenceAccepted() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.65),
        ])
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved)
        XCTAssertEqual(outcome.lexicalStatus, .resolved)
    }

    /// resolved 但缺 confidence → 无法证明 ≥阈值 → lowConfidence。
    func testMissingConfidenceRoutesLowConfidence() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001),
        ])
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .lowConfidence)
    }

    /// 阈值边界：恰好 lowConfidenceThreshold → aiResolved。
    func testConfidenceAtThresholdAccepted() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: AIStudyBudget.lowConfidenceThreshold),
        ])
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved)
    }

    // MARK: - v2 句译字段（C7）

    /// `sentenceTranslation` 随 resolution 透传；unresolved 项也保留
    /// （翻译与选义子状态独立）。
    func testSentenceTranslationCarriedThrough() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02"),   // OOV——句译仍应保留
        ])
        var resolvedWord = word(
            "t01", status: "resolved", entryID: 100, senseID: 1001,
            confidence: 0.9)
        resolvedWord["sentenceTranslation"] = "第一句的译文"
        var unresolvedWord = word("t02", status: "unresolved")
        unresolvedWord["sentenceTranslation"] = "同句译文"
        let outcome = validate(request, words: [resolvedWord, unresolvedWord])
        XCTAssertEqual(
            resolutionFor(outcome, "t01")?.sentenceTranslation,
            "第一句的译文")
        XCTAssertEqual(
            resolutionFor(outcome, "t02")?.sentenceTranslation,
            "同句译文")
    }

    /// 句译坏值剥除：超长/空串/非串 → nil，不降级词义。
    func testSentenceTranslationStrippedOnViolation() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
            studyToken("t03", candidates: [studyCandidate(300, senses: [
                (3001, [], [])])]),
        ])
        var w1 = word("t01", status: "resolved", entryID: 100,
                      senseID: 1001, confidence: 0.9)
        w1["sentenceTranslation"] = String(
            repeating: "译",
            count: AIStudyBudget.maxSentenceTranslationLength + 1)
        var w2 = word("t02", status: "resolved", entryID: 200,
                      senseID: 2001, confidence: 0.9)
        w2["sentenceTranslation"] = "   "
        var w3 = word("t03", status: "resolved", entryID: 300,
                      senseID: 3001, confidence: 0.9)
        w3["sentenceTranslation"] = 42
        let outcome = validate(request, words: [w1, w2, w3])
        XCTAssertEqual(outcome.lexicalStatus, .resolved,
                       "句译字段违规不拖累词义状态")
        for token in ["t01", "t02", "t03"] {
            XCTAssertNil(resolutionFor(outcome, token)?.sentenceTranslation)
            XCTAssertEqual(resolutionFor(outcome, token)?.status, .aiResolved)
        }
    }

    // MARK: - §48 partial invalid / malformed JSON

    /// words[] 混进非对象坏元素 → 计 malformedItem，其余保留。
    func testMalformedItemPreservesOthers() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let wordsJSON = """
            [
              42,
              {"tokenID":"t01","status":"resolved","entryID":100,
               "senseID":1001,"confidence":0.9},
              {"tokenID":"t02","status":"resolved","entryID":200,
               "senseID":2001,"confidence":0.9}
            ]
            """
        let outcome = validate(request, wordsLiteral: wordsJSON)
        XCTAssertEqual(outcome.malformedItemCount, 1)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .aiResolved)
        XCTAssertEqual(outcome.lexicalStatus, .resolved)
    }

    /// 单项选择非法（缺 senseID）→ 该项降级 unresolved，
    /// 其余合法项不受影响（§7「单项坏数据保留其他项」）。
    func testInvalidItemPreservesValidOnes() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: nil,
                 confidence: 0.9),
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.9),
        ])
        let bad = resolutionFor(outcome, "t01")
        XCTAssertEqual(bad?.status, .unresolved)
        XCTAssertEqual(bad?.reasonCode, .incompleteSelection)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .aiResolved)
        XCTAssertEqual(outcome.invalidItemCount, 1)
        XCTAssertEqual(outcome.lexicalStatus, .partial)
    }

    /// malformed JSON：不猜半截、不正则拼接——整包 failed。
    func testMalformedJSONFailsEnvelope() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let truncated = "{\"schemaVersion\":\(AIStudyRequest.schemaVersion),"
            + "\"requestID\":\"x\","
        let outcome = validate(request, rawData: Data(truncated.utf8))
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .malformedJSON)
        XCTAssertTrue(outcome.resolutions.isEmpty,
                      "外层失败不产生任何 resolution")
        XCTAssertEqual(outcome.translationStatus, .failed)
    }

    /// 完全非 JSON 字节 → 同样 failed。
    func testGarbageBytesFailEnvelope() {
        let request = makeRequest(tokens: [])
        let outcome = validate(request, rawData: Data("not json".utf8))
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .malformedJSON)
    }

    // MARK: - 追加：token 不存在 / 缺项

    /// 未知 tokenID：不创建任何对象，只计 droppedUnknownToken。
    func testUnknownTokenIDDropped() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("tGHOST", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(outcome.droppedUnknownTokenCount, 1)
        XCTAssertEqual(outcome.resolutions.count, 1,
                       "未知 token 不产生 resolution 行")
        XCTAssertEqual(resolutionFor(outcome, "tGHOST"), nil)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved)
    }

    /// 缺项：目标 token 无 words 项 → unresolved + missingWord；
    /// OOV 目标缺项 → unresolved + noCandidate。
    func testMissingTokenMarkedUnresolved() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02"),   // OOV 占位
            studyToken("t03", candidates: [studyCandidate(300, senses: [
                (3001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            word("t03", status: "resolved", entryID: 300, senseID: 3001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(resolutionFor(outcome, "t01")?.reasonCode, .missingWord)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .unresolved)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.reasonCode, .noCandidate)
        XCTAssertEqual(resolutionFor(outcome, "t03")?.status, .aiResolved)
        XCTAssertEqual(outcome.lexicalStatus, .partial)
        XCTAssertEqual(outcome.unresolvedTokenCount, 2)
    }

    // MARK: - 追加：NaN/越界 confidence

    /// confidence 越界（>1 或 <0）→ 该项降级 unresolved；
    /// 非数字类型同样降级（不把字符串当置信度猜）。
    func testOutOfRangeConfidenceDowngradesItem() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
            studyToken("t03", candidates: [studyCandidate(300, senses: [
                (3001, [], [])])]),
        ])
        let outcome = validate(request, wordsLiteral: """
            [
              {"tokenID":"t01","status":"resolved","entryID":100,
               "senseID":1001,"confidence":1.5},
              {"tokenID":"t02","status":"resolved","entryID":200,
               "senseID":2001,"confidence":"high"},
              {"tokenID":"t03","status":"resolved","entryID":300,
               "senseID":3001,"confidence":0.9}
            ]
            """)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .unresolved)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.reasonCode,
                       .invalidConfidence)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .unresolved)
        XCTAssertEqual(resolutionFor(outcome, "t02")?.reasonCode,
                       .invalidConfidence)
        XCTAssertEqual(resolutionFor(outcome, "t03")?.status, .aiResolved)
        XCTAssertEqual(outcome.invalidItemCount, 2)
    }

    // MARK: - 追加：译文子状态

    /// 译文 trim 后为空 → translationStatus=.failed，
    /// 词义结果保留（§7：只影响 translation 子状态）。
    func testEmptyTranslationFailsSubstatusOnly() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(
            request, translation: "   \n  ", words: [
                word("t01", status: "resolved", entryID: 100,
                     senseID: 1001, confidence: 0.9),
            ])
        XCTAssertEqual(outcome.translationStatus, .failed)
        XCTAssertNil(outcome.translation)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved,
                       "译文失败不得吞掉合法词义结果")
        XCTAssertEqual(outcome.lexicalStatus, .resolved)
    }

    /// 译文超长 → 同子状态失败。
    func testOversizedTranslationFailsSubstatusOnly() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let huge = String(
            repeating: "译", count: AIStudyBudget.maxTranslationLength + 1)
        let outcome = validate(request, translation: huge, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(outcome.translationStatus, .failed)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved)
    }

    /// 译文缺失（wantsTranslation）→ failed 子状态。
    func testMissingTranslationFailsSubstatus() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, translation: nil, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(outcome.translationStatus, .failed)
        XCTAssertEqual(outcome.lexicalStatus, .resolved)
    }

    /// 非字符串译文（类型错）→ failed 子状态，不是整包拒。
    func testNonStringTranslationFailsSubstatus() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, wordsLiteral: """
            [{"tokenID":"t01","status":"resolved","entryID":100,
              "senseID":1001,"confidence":0.9}]
            """, translationLiteral: "42")
        XCTAssertEqual(outcome.translationStatus, .failed)
        XCTAssertEqual(resolutionFor(outcome, "t01")?.status, .aiResolved)
    }

    /// 不请求译文的块：translation 字段缺失 → notRequested。
    func testTranslationNotRequested() {
        let block = makeBlock(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ], wantsTranslation: false)
        let request = makeRequest(blocks: [block])
        let outcome = validate(request, translation: nil, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(outcome.translationStatus, .notRequested)
    }

    // MARK: - 追加：外层 schema/requestID

    func testRequestIDMismatchRejectsEnvelope() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(
            request, requestIDOverride: "rq-different", words: [
                word("t01", status: "resolved", entryID: 100,
                     senseID: 1001, confidence: 0.9),
            ])
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .requestIDMismatch)
        XCTAssertTrue(outcome.resolutions.isEmpty)
    }

    /// v1 响应在 v2 请求下被拒——schema bump 即整包拒（缓存键
    /// 含 promptVersion+schemaVersion 不同键，此断言锁死「旧
    /// 契约响应不得混进新请求」的边界）。
    func testSchemaVersionMismatchRejectsEnvelope() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(
            request, schemaVersion: AIStudyRequest.schemaVersion - 1,
            words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .schemaVersionMismatch)
    }

    /// words 非数组 → 外层拒（区别于元素级坏数据）。
    func testNonArrayWordsFieldRejected() {
        let request = makeRequest(tokens: [])
        let outcome = validate(request, wordsLiteral: "\"oops\"")
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .invalidWordsField)
    }

    /// 外层大小：响应体超 `maxResponseBytes` → 解码前即拒。
    func testOversizedResponseRejected() {
        let request = makeRequest(tokens: [])
        let big = Data(repeating: 0x20,
                       count: AIStudyBudget.maxResponseBytes + 1)
        let outcome = validate(request, rawData: big)
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .responseTooLarge)
    }

    /// 递归深度超 `maxJSONDepth` → 外层拒（结构防御）。
    func testDeeplyNestedResponseRejected() {
        let request = makeRequest(tokens: [])
        var json = "{\"schemaVersion\":\(AIStudyRequest.schemaVersion),\"requestID\":\"rq-test\",\"x\":"
        json += String(repeating: "[", count: AIStudyBudget.maxJSONDepth + 2)
        json += String(repeating: "]", count: AIStudyBudget.maxJSONDepth + 2)
        json += "}"
        let outcome = validate(request, rawData: Data(json.utf8))
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .depthExceeded)
    }

    /// words 数量超 `maxWordItems` → 外层拒。
    func testTooManyWordsRejected() {
        let request = makeRequest(tokens: [])
        let words = [[String: Any]](
            repeating: ["tokenID": "t?", "status": "unresolved"],
            count: AIStudyBudget.maxWordItems + 1)
        let envelope: [String: Any] = [
            "schemaVersion": AIStudyRequest.schemaVersion,
            "requestID": "rq-test",
            "translation": "译文", "words": words,
        ]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let outcome = AIStudyResponseValidator.validate(
            responseData: data, request: request)
        XCTAssertEqual(outcome.lexicalStatus, .failed)
        XCTAssertEqual(outcome.envelopeRejection, .tooManyWords)
    }

    // MARK: - 追加：OOV 伪候选防线（S02-B 6/9 直接动机）

    /// OOV token（candidates=[]）：AI 报 resolved + 词典真实
    /// entry/sense → 该组合不在候选集（空集）→ 拒绝，不落库。
    func testOOVTokenRejectsFabricatedCandidate() {
        let request = makeRequest(tokens: [
            studyToken("t01"),  // OOV 显式占位
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
        ])
        let outcome = validate(request, words: [
            // AI 给 OOV 造了一个词典里真实存在的 entry/sense
            word("t01", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.99),
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.9),
        ])
        let fabricated = resolutionFor(outcome, "t01")
        XCTAssertEqual(fabricated?.status, .rejected)
        XCTAssertEqual(fabricated?.reasonCode, .candidateNotInSet)
        XCTAssertNil(fabricated?.selected,
                     "伪候选不得形成选定——非法候选落库通道为零")
        XCTAssertEqual(resolutionFor(outcome, "t02")?.status, .aiResolved)
    }

    /// OOV token 的合法路径：AI 报 unresolved → unresolved +
    /// noCandidate（显式占位，不算坏数据）。
    func testOOVTokenUnresolvedIsCleanPath() {
        let request = makeRequest(tokens: [studyToken("t01")])
        let outcome = validate(request, words: [
            word("t01", status: "unresolved"),
        ])
        let resolution = resolutionFor(outcome, "t01")
        XCTAssertEqual(resolution?.status, .unresolved)
        XCTAssertEqual(resolution?.reasonCode, .noCandidate)
        XCTAssertEqual(outcome.invalidItemCount, 0)
        XCTAssertEqual(outcome.lexicalStatus, .unresolved)
    }

    /// 「候选过多需确认」token：即便 AI 高置信应答，也强制进
    /// 确认队列（§6.3 不靠截断候选提升表面置信度）。
    func testCandidateOverflowTokenForcedToConfirmation() {
        let flagged = AIStudyToken(
            tokenID: "t01", surface: "多", lemma: "多", reading: nil,
            posFamily: nil, utf16Start: 0, utf16Length: 1,
            candidates: [studyCandidate(100, senses: [(1001, [], [])])],
            needsCandidateConfirmation: true)
        let request = makeRequest(tokens: [flagged])
        let outcome = validate(request, words: [
            word("t01", status: "resolved", entryID: 100, senseID: 1001,
                 confidence: 0.99),
        ])
        let resolution = resolutionFor(outcome, "t01")
        XCTAssertEqual(resolution?.status, .lowConfidence)
        XCTAssertEqual(resolution?.reasonCode, .candidateOverflow)
        XCTAssertEqual(resolution?.selected?.senseID, 1001)
        XCTAssertEqual(outcome.lexicalStatus, .partial)
    }

    // MARK: - 汇总形态

    /// 全部缺项/被拒 → lexicalStatus=.unresolved（不是 failed——
    /// 外层合法，内容全降级）。
    func testAllUnresolvedYieldsUnresolvedStatus() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
        ])
        let outcome = validate(request, words: [])
        XCTAssertEqual(outcome.lexicalStatus, .unresolved)
        XCTAssertEqual(outcome.envelopeRejection, nil)
    }

    /// 每目标恰一行 resolution，与请求 token 序一致。
    func testResolutionCoversEveryTargetExactlyOnce() {
        let request = makeRequest(tokens: [
            studyToken("t01", candidates: [studyCandidate(100, senses: [
                (1001, [], [])])]),
            studyToken("t02", candidates: [studyCandidate(200, senses: [
                (2001, [], [])])]),
            studyToken("t03"),
        ])
        let outcome = validate(request, words: [
            word("t02", status: "resolved", entryID: 200, senseID: 2001,
                 confidence: 0.9),
        ])
        XCTAssertEqual(outcome.resolutions.map(\.tokenKey),
                       ["t01", "t02", "t03"])
        XCTAssertEqual(outcome.targetTokenCount, 3)
    }

    // MARK: - helpers

    private func studyToken(
        _ id: String,
        candidates: [AIStudyCandidate] = []
    ) -> AIStudyToken {
        AIStudyToken(
            tokenID: id, surface: "表", lemma: "表", reading: nil,
            posFamily: nil, utf16Start: 0, utf16Length: 1,
            candidates: candidates)
    }

    private func studyCandidate(
        _ entryID: Int64,
        senses: [(senseID: Int64, rForms: [String], rReadings: [String])]
    ) -> AIStudyCandidate {
        AIStudyCandidate(
            entryID: entryID, lemma: "表", reading: "ひょう",
            matchedForm: "表", matchedReading: "ひょう",
            senses: senses.map {
                AIStudyCandidateSense(
                    senseID: $0.senseID, enGlosses: ["g\($0.senseID)"],
                    restrictedForms: $0.rForms,
                    restrictedReadings: $0.rReadings)
            })
    }

    private func makeBlock(
        tokens: [AIStudyToken],
        wantsTranslation: Bool = true
    ) -> AIStudyBlock {
        AIStudyBlock(
            blockKey: "test-scope#r0-1",
            targetText: "表", context: "",
            targetUTF16Start: 0, targetUTF16Length: 1,
            tokens: tokens,
            candidateSetHash: "hash",
            wantsTranslation: wantsTranslation)
    }

    private func makeRequest(
        tokens: [AIStudyToken],
        wantsTranslation: Bool = true
    ) -> AIStudyRequest {
        makeRequest(blocks: [makeBlock(
            tokens: tokens, wantsTranslation: wantsTranslation)])
    }

    private func makeRequest(blocks: [AIStudyBlock]) -> AIStudyRequest {
        AIStudyRequest(
            requestID: "rq-test",
            blocks: blocks,
            metadata: makeAIStudyMetadata(),
            requestHash: "h")
    }

    private func word(
        _ tokenID: String, status: String,
        entryID: Int64? = nil, senseID: Int64? = nil,
        confidence: Double? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "tokenID": tokenID, "status": status,
        ]
        dict["entryID"] = entryID.map { NSNumber(value: $0) } ?? NSNull()
        dict["senseID"] = senseID.map { NSNumber(value: $0) } ?? NSNull()
        dict["confidence"] = confidence.map { NSNumber(value: $0) } ?? NSNull()
        return dict
    }

    private func validate(
        _ request: AIStudyRequest,
        translation: String? = "译文",
        schemaVersion: Int = AIStudyRequest.schemaVersion,
        requestIDOverride: String? = nil,
        words: [[String: Any]] = [],
        wordsLiteral: String? = nil,
        translationLiteral: String? = nil,
        rawData: Data? = nil
    ) -> ValidatedBlockOutcome {
        let data: Data
        if let rawData {
            data = rawData
        } else if wordsLiteral == nil && translationLiteral == nil {
            // 正常路径：JSONSerialization 保证合法 JSON（含转义）。
            let envelope: [String: Any] = [
                "schemaVersion": schemaVersion,
                "requestID": requestIDOverride ?? request.requestID,
                "translation": translation ?? NSNull(),
                "words": words,
            ]
            data = try! JSONSerialization.data(withJSONObject: envelope)
        } else {
            // 边界路径：literal 由调用方保证是需要的手工形态。
            let translationJSON = translationLiteral
                ?? (translation.map { "\"\($0)\"" } ?? "null")
            let wordsJSON = wordsLiteral ?? "[]"
            let json = """
                {"schemaVersion":\(schemaVersion),
                 "requestID":"\(requestIDOverride ?? request.requestID)",
                 "translation":\(translationJSON),
                 "words":\(wordsJSON)}
                """
            data = Data(json.utf8)
        }
        return AIStudyResponseValidator.validate(
            responseData: data, request: request)
    }

    private func resolutionFor(
        _ outcome: ValidatedBlockOutcome, _ tokenID: String
    ) -> AIStudyResolution? {
        outcome.resolutions.first { $0.tokenKey == tokenID }
    }
}
