import Foundation
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// `NLJapaneseMorphologyService` 集成测试（真实 NLTokenizer + 随包词典）。
/// 覆盖：活用形合并解词、lemma/reading 区分、行く促音便、いい不规则、
/// OOV、歧义留疑、能力缺失、取消、token 分类、缓存编解码。
final class MorphologyServiceTests: XCTestCase {

    private func tokenize(_ text: String) async throws -> [ReaderToken] {
        let service = try MorphologyTestSupport.makeService()
        return try await service.tokenize(MorphologyTestSupport.makeBlock(text))
    }

    private func token(
        _ tokens: [ReaderToken], covering surface: String
    ) -> ReaderToken? {
        tokens.first { $0.surface == surface }
    }

    // MARK: - 活用形合并 + lemma 还原

    func testTabeteitaResolvesToTaberu() async throws {
        let tokens = try await tokenize("私は昨日ラーメンを食べていた。")
        let merged = try XCTUnwrap(token(tokens, covering: "食べていた"),
                                   "食べていた 应被合并为单 token")
        XCTAssertTrue(merged.candidates.contains { $0.lemma == "食べる" },
                      "candidates: \(merged.candidates.map(\.lemma))")
        XCTAssertEqual(merged.sourceRangeUTF16, 9..<14)
        XCTAssertEqual(merged.mergedSpanUTF16, merged.sourceRangeUTF16)
        XCTAssertGreaterThan(merged.systemTokenIndexes.count, 1,
                             "多系统 token 合并应保留原始索引集")
        XCTAssertEqual(merged.tokenClass, .lexical)
    }

    func testMitaLemmaIsMiruWithDistinctReading() async throws {
        let tokens = try await tokenize("彼は映画を見た。")
        let token = try XCTUnwrap(token(tokens, covering: "見た"))
        // lemma 候选含 見る；候选读音是 lemma 级（みる），不填 token.reading
        // 的活用形假象（cost>0 → token.reading = nil）。
        XCTAssertTrue(token.candidates.contains { $0.lemma == "見る" },
                      "candidates: \(token.candidates.map(\.lemma))")
        XCTAssertNil(token.reading)
    }

    func testIkanakattaResolvesToIku() async throws {
        let tokens = try await tokenize("学校に行かなかった。")
        let token = try XCTUnwrap(token(tokens, covering: "行かなかった"))
        XCTAssertTrue(token.candidates.contains { $0.lemma == "行く" },
                      "candidates: \(token.candidates.map(\.lemma))")
    }

    func testYokattaResolvesToYoi() async throws {
        let tokens = try await tokenize("昨日の夜はよかった。")
        let token = try XCTUnwrap(token(tokens, covering: "よかった"))
        XCTAssertTrue(token.candidates.contains { ["よい", "良い"].contains($0.lemma) },
                      "candidates: \(token.candidates.map(\.lemma))")
    }

    // MARK: - S07 新增规则端到端

    func testSouYoutaiAndNasaiAndKunattaAndSugite() async throws {
        // そう 様態（v5）：降りそうだ→降る（NL 边界上 だ 并入 span）。
        var tokens = try await tokenize("雨が降りそうだ。")
        XCTAssertTrue(
            token(tokens, covering: "降りそうだ")?.candidates
                .contains { $0.lemma == "降る" } ?? false,
            "tokens: \(tokens.map(\.surface))")

        // なさい（v1）：起きなさい→起きる
        tokens = try await tokenize("早く起きなさい。")
        XCTAssertTrue(
            token(tokens, covering: "起きなさい")?.candidates
                .contains { $0.lemma == "起きる" } ?? false)

        // くなった（adj-i 连用 + なる）：寒くなった→寒い
        tokens = try await tokenize("昨日より少し寒くなった。")
        XCTAssertTrue(
            token(tokens, covering: "寒くなった")?.candidates
                .contains { $0.lemma == "寒い" } ?? false,
            "tokens: \(tokens.map(\.surface))")

        // すぎて：高すぎて→高い
        tokens = try await tokenize("値段が高すぎて買えなかった。")
        XCTAssertTrue(
            token(tokens, covering: "高すぎて")?.candidates
                .contains { $0.lemma == "高い" } ?? false)
    }

    func testVariantKanjiFoldTakaku() async throws {
        // 髙く→髙い→折叠→高い（variant map 髙→高）。
        let tokens = try await tokenize("成績が髙く評価された。")
        let token = try XCTUnwrap(token(tokens, covering: "髙く"))
        XCTAssertTrue(token.candidates.contains { $0.lemma == "高い" },
                      "candidates: \(token.candidates.map(\.lemma))")
    }

    // MARK: - aux 链拆分（S01 决议：动词 target + aux token）

    func testShiteshimattaSplitsAtAuxBoundary() async throws {
        let tokens = try await tokenize("宿題をしてしまった。")
        // して (→する) 与 しまった (→しまう) 分计，不整 span 合成 知る。
        let shite = try XCTUnwrap(token(tokens, covering: "して"))
        XCTAssertTrue(shite.candidates.contains { $0.lemma == "する" },
                      "candidates: \(shite.candidates.map(\.lemma))")
        let shimatta = try XCTUnwrap(token(tokens, covering: "しまった"))
        XCTAssertTrue(shimatta.candidates.contains { $0.lemma == "しまう" },
                      "candidates: \(shimatta.candidates.map(\.lemma))")
        XCTAssertEqual(shimatta.tokenClass, .auxiliary,
                       "て形后的 aux-v 链续段应记 auxiliary")
        XCTAssertNil(token(tokens, covering: "してしまった"),
                     "整 span 不得吞并为 知る")
    }

    // MARK: - OOV / 歧义 / 分类

    func testOOVKatakanaUnresolved() async throws {
        let tokens = try await tokenize("グスコーブドリの伝記を読んだ。")
        let token = try XCTUnwrap(token(tokens, covering: "グスコーブドリ"),
                                  "OOV 也是合法 token")
        XCTAssertEqual(token.resolutionStatus, .unresolved)
        XCTAssertTrue(token.candidates.isEmpty)
        XCTAssertNil(token.lexicalKey)
        XCTAssertTrue(token.tokenClass.countsForCoverage)
    }

    func testLatinWordIsOutOfVocabulary() async throws {
        let tokens = try await tokenize("Wi-Fiに繋がらない。")
        let wifi = try XCTUnwrap(token(tokens, covering: "Wi-Fi"))
        XCTAssertEqual(wifi.tokenClass, .outOfVocabulary)
        XCTAssertEqual(wifi.resolutionStatus, .unresolved)
    }

    func testAmbiguityStaysAmbiguousWithoutLexicalKey() async throws {
        // 私 → 複数条目命中：ambiguous + lexicalKey=nil（不自动挖词）。
        let tokens = try await tokenize("私は学生です。")
        let token = try XCTUnwrap(token(tokens, covering: "私"))
        XCTAssertEqual(token.resolutionStatus, .ambiguous)
        XCTAssertNil(token.lexicalKey)
        XCTAssertLessThanOrEqual(token.candidates.count,
                                 MorphologyCandidate.maximumRetained)
    }

    func testNonLexicalClasses() async throws {
        let tokens = try await tokenize("３０００円で買った😊")
        if let digits = token(tokens, covering: "３０００") {
            XCTAssertEqual(digits.tokenClass, .nonLexical)
            XCTAssertFalse(digits.tokenClass.countsForCoverage)
        }
        // 句号/emoji 为 nonLexical。
        XCTAssertTrue(tokens.allSatisfy { $0.tokenClass != .nonLexical
            || $0.resolutionStatus == .unresolved })
        if let emoji = tokens.first(where: { $0.surface == "😊" }) {
            XCTAssertEqual(emoji.tokenClass, .nonLexical)
        }
    }

    // MARK: - 能力缺失 / 取消

    func testCapabilityMissingThrows() async throws {
        let service = try MorphologyTestSupport.makeService(
            tokenizer: FakeMorphologySystemTokenizer(schemes: []))
        do {
            _ = try await service.tokenize(MorphologyTestSupport.makeBlock("食べていた。"))
            XCTFail("应抛 capabilityMissing")
        } catch let MorphologyError.capabilityMissing(missing) {
            XCTAssertTrue(missing.contains("TokenType"))
        }
    }

    func testCancellationPreCancelledTask() async throws {
        let service = try MorphologyTestSupport.makeService(
            tokenizer: FakeMorphologySystemTokenizer())
        let block = MorphologyTestSupport.makeBlock("私はラーメンを食べていた。")
        let task = Task { () throws -> [ReaderToken] in
            try await service.tokenize(block)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后应抛 cancelled")
        } catch MorphologyError.cancelled {
            // ok
        } catch is CancellationError {
            // ok（包装前抛出的系统取消也接受）
        }
    }

    func testCancellationMidPipeline() async throws {
        // resolver 返回前任务已取消 → 装配前的 checkCancellation 抛 cancelled。
        struct CancelResolver: MorphologyCandidateResolver {
            func resolveCandidates(_ spans: [SpanCandidates]) async throws
                -> [[MorphologyCandidate]] {
                var results: [[MorphologyCandidate]] = []
                for _ in spans {
                    try Task.checkCancellation()
                    results.append([])
                }
                return results
            }
        }
        let tokenizer = FakeMorphologySystemTokenizer(tokens: [
            sysToken("食べ", start: 0), sysToken("て", start: 2),
            sysToken("い", start: 3), sysToken("た", start: 4),
        ])
        let service = NLJapaneseMorphologyService(
            resolver: CancelResolver(), tokenizer: tokenizer)
        let block = MorphologyTestSupport.makeBlock("食べていた。")
        let task = Task { () throws -> [ReaderToken] in
            try await service.tokenize(block)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("取消后应抛 cancelled")
        } catch MorphologyError.cancelled {
            // ok
        } catch is CancellationError {
            // ok
        }
    }

    // MARK: - provenance / cache 键

    func testProvenanceAndCacheKey() async throws {
        let service = try MorphologyTestSupport.makeService()
        let tokens = try await service.tokenize(
            MorphologyTestSupport.makeBlock("食べていた。"))
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.allSatisfy { !$0.provenance.isEmpty })
        XCTAssertTrue(tokens.first?.provenance.contains("nl.word-tokenizer") ?? false)

        let key = await service.tokenCacheKey(blockHash: "h1", parserVersion: "p1")
        XCTAssertEqual(key.blockHash, "h1")
        XCTAssertTrue(key.morphologyVersion.contains(
            JapaneseDeinflector.deinflectorRulesVersion))
        XCTAssertFalse(key.osBuild.isEmpty)
        // dataset 版本在首次 tokenize 后已回填。
        XCTAssertNotEqual(service.dictionaryDatasetVersion, "unopened")
    }

    // MARK: - token 缓存编解码 + 内存仓储

    func testReaderTokenCacheCodecRoundTrip() throws {
        let token = ReaderToken(
            surface: "食べていた",
            sourceRangeUTF16: 9..<14,
            mergedSpanUTF16: 9..<14,
            systemTokenIndexes: 4..<8,
            candidates: [MorphologyCandidate(
                lemma: "食べる", normalizedForm: "食べる", reading: "たべる",
                posCodes: ["v1", "vt"], entryID: 123,
                reasons: ["v1.teita"], cost: 1)],
            tokenClass: .lexical, reading: nil,
            lexicalKey: LexicalKey(
                provider: .jmdict, externalID: "123",
                identityKey: "jmdict|123|食べる|たべる"),
            resolutionStatus: .resolved,
            provenance: ["nl.word-tokenizer", "span.merge.4tok"]
        )
        let data = try ReaderTokenCacheCodec.encode([token])
        let decoded = try XCTUnwrap(ReaderTokenCacheCodec.decode(data))
        XCTAssertEqual(decoded, [token])
    }

    func testInMemoryCacheStoreKeySemantics() async throws {
        let store = InMemoryReaderTokenCacheStore()
        let key = TokenCacheKey(
            blockHash: "b1", parserVersion: "p1", morphologyVersion: "m1",
            dictionaryDatasetVersion: "d1", osBuild: "o1")
        let tokens = [ReaderToken(
            surface: "私", sourceRangeUTF16: 0..<1, systemTokenIndexes: 0..<1,
            candidates: [], tokenClass: .lexical, reading: nil,
            lexicalKey: nil, resolutionStatus: .unresolved, provenance: [])]
        await store.store(tokens, for: key)
        let loaded = await store.load(key: key)
        XCTAssertEqual(loaded, tokens)
        // 任一版本字段变化 → miss。
        let staleKey = TokenCacheKey(
            blockHash: "b1", parserVersion: "p1", morphologyVersion: "m2",
            dictionaryDatasetVersion: "d1", osBuild: "o1")
        let staleHit = await store.load(key: staleKey)
        XCTAssertNil(staleHit)
        // 版本面失效：probe 字段失配行被清。
        await store.evictStaleVersions(probe: TokenCacheKey(
            blockHash: "other", parserVersion: "p1", morphologyVersion: "m2",
            dictionaryDatasetVersion: "d1", osBuild: "o1"))
        let evictedHit = await store.load(key: key)
        XCTAssertNil(evictedHit)
    }
}
