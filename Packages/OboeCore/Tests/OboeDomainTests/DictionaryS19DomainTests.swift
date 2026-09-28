import Foundation
import OboeDomain
import XCTest

/// S19 域层测试：释义 fallback 链、层级匹配解析（exact written >
/// exact reading > deinflected）、同层重绑决策——全 fake lookup，
/// 不碰 GRDB。
final class DictionaryS19DomainTests: XCTestCase {

    // MARK: - fake lookup

    /// 可控 `DictionaryTieredLookup`：键 → 命中列表直给。
    private final class FakeLookup: DictionaryTieredLookup,
        @unchecked Sendable {
        var formHits: [String: [TieredEntryMatch]] = [:]
        var readingHits: [String: [TieredEntryMatch]] = [:]
        var surfaces: [Int64: DictionaryEntrySurface] = [:]
        var version: String? = "test-v2"
        /// 调用记录——断言「高层命中后低层未被查询」。
        private(set) var queriedKeys: [String] = []

        func formMatches(normalizedKey: String) async throws
            -> [TieredEntryMatch] {
            queriedKeys.append("form:\(normalizedKey)")
            return formHits[normalizedKey] ?? []
        }
        func readingMatches(normalizedKey: String) async throws
            -> [TieredEntryMatch] {
            queriedKeys.append("reading:\(normalizedKey)")
            return readingHits[normalizedKey] ?? []
        }
        func lemmaMatches(normalizedKeys: [String]) async throws
            -> [String: [TieredEntryMatch]] {
            for key in normalizedKeys { queriedKeys.append("lemma:\(key)") }
            var result: [String: [TieredEntryMatch]] = [:]
            for key in normalizedKeys {
                let combined = (formHits[key] ?? []) + (readingHits[key] ?? [])
                if !combined.isEmpty { result[key] = combined }
            }
            return result
        }
        func entrySurfaces(entryIDs: [Int64]) async throws
            -> [Int64: DictionaryEntrySurface] {
            Dictionary(uniqueKeysWithValues: surfaces.filter {
                entryIDs.contains($0.key)
            })
        }
        func datasetVersion() async throws -> String? { version }
    }

    private func match(
        _ id: Int64, surface: String, rank: Int? = nil
    ) -> TieredEntryMatch {
        TieredEntryMatch(
            entryID: id, matchedSurface: surface, commonRank: rank)
    }

    // MARK: - 三层排序样例（验收核心）

    /// 同一 surface 同时是 A 的表记与 B 的读音——exactWritten 层锁定，
    /// reading 层不再被查询。
    func testExactWrittenBeatsExactReading() async throws {
        let lookup = FakeLookup()
        lookup.formHits["事"] = [match(100, surface: "事")]
        lookup.readingHits["事"] = [match(200, surface: "こと")]
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(writtenForm: "事"), lookup: lookup)
        guard case let .resolved(m, tier) = outcome else {
            return XCTFail("期望 resolved，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .exactWritten)
        XCTAssertEqual(m.entryID, 100)
        XCTAssertFalse(
            lookup.queriedKeys.contains { $0.hasPrefix("reading:") },
            "exactWritten 命中后不得再查 reading 层")
    }

    /// 表记无命中 → 读音层胜出 → deinflected 不再查。
    func testExactReadingBeatsDeinflected() async throws {
        let lookup = FakeLookup()
        lookup.readingHits["たべる"] = [match(1358280, surface: "たべる")]
        lookup.formHits["たべる(deinflected)"] = [match(999, surface: "x")]
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(
                writtenForm: "たべる",
                deinflectionLemmas: ["たべる(deinflected)"]),
            lookup: lookup)
        guard case let .resolved(m, tier) = outcome else {
            return XCTFail("期望 resolved，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .exactReading)
        XCTAssertEqual(m.entryID, 1_358_280)
        XCTAssertFalse(
            lookup.queriedKeys.contains { $0.hasPrefix("lemma:") },
            "exactReading 命中后不得再查 deinflected 层")
    }

    /// 活用形只在 deinflected 层命中。
    func testDeinflectedWhenExactMisses() async throws {
        let lookup = FakeLookup()
        lookup.formHits["食べる"] = [match(1358280, surface: "食べる", rank: 1)]
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(
                writtenForm: "食べなかった",
                deinflectionLemmas: ["食べなかった", "食べる"]),
            lookup: lookup)
        guard case let .resolved(m, tier) = outcome else {
            return XCTFail("期望 resolved，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .deinflected)
        XCTAssertEqual(m.entryID, 1_358_280)
    }

    /// SourceContext 最强：验证通过直接 resolved（零常规查询）。
    func testSourceContextVerified() async throws {
        let lookup = FakeLookup()
        lookup.formHits["事"] = [match(100, surface: "事")]
        lookup.surfaces[42] = DictionaryEntrySurface(
            entryID: 42, primaryForm: "事",
            normalizedForms: ["事"], normalizedReadings: ["こと"])
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(
                writtenForm: "事", reading: "こと", contextEntryID: 42),
            lookup: lookup)
        guard case let .resolved(m, tier) = outcome else {
            return XCTFail("期望 resolved，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .sourceContext)
        XCTAssertEqual(m.entryID, 42)
        XCTAssertTrue(
            lookup.queriedKeys.isEmpty,
            "sourceContext 验证通过后不得再查常规层")
    }

    /// SourceContext 验证失败（entry 表面不含该表记）→ 下探常规层。
    func testSourceContextMismatchFallsThrough() async throws {
        let lookup = FakeLookup()
        lookup.formHits["事"] = [match(100, surface: "事")]
        lookup.surfaces[42] = DictionaryEntrySurface(
            entryID: 42, primaryForm: "言",
            normalizedForms: ["言"], normalizedReadings: [])
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(
                writtenForm: "事", contextEntryID: 42), lookup: lookup)
        guard case let .resolved(m, tier) = outcome else {
            return XCTFail("期望 resolved，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .exactWritten)
        XCTAssertEqual(m.entryID, 100)
    }

    /// 高层歧义锁定：exactWritten 多候选 → ambiguous，
    /// 更低层绝不再查（低层命中不可能更可靠）。
    func testAmbiguousAtHighTierBlocksLower() async throws {
        let lookup = FakeLookup()
        lookup.formHits["甲"] = [
            match(1, surface: "甲"), match(2, surface: "甲"),
        ]
        lookup.readingHits["甲"] = [match(3, surface: "甲")]
        lookup.surfaces[1] = DictionaryEntrySurface(
            entryID: 1, primaryForm: "甲",
            normalizedForms: ["甲"], normalizedReadings: ["こう"])
        lookup.surfaces[2] = DictionaryEntrySurface(
            entryID: 2, primaryForm: "甲",
            normalizedForms: ["甲"], normalizedReadings: ["かん"])
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(writtenForm: "甲"), lookup: lookup)
        guard case let .ambiguous(tier, candidates) = outcome else {
            return XCTFail("期望 ambiguous，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .exactWritten)
        XCTAssertEqual(candidates.map(\.entryID), [1, 2])
        XCTAssertFalse(
            lookup.queriedKeys.contains { $0.hasPrefix("reading:") })
    }

    /// 层内读音消歧：同形异音 Note 读音恰选一。
    func testReadingDisambiguatesWithinTier() async throws {
        let lookup = FakeLookup()
        lookup.formHits["頭"] = [
            match(1, surface: "頭"), match(2, surface: "頭"),
        ]
        lookup.surfaces[1] = DictionaryEntrySurface(
            entryID: 1, primaryForm: "頭",
            normalizedForms: ["頭"], normalizedReadings: ["あたま"])
        lookup.surfaces[2] = DictionaryEntrySurface(
            entryID: 2, primaryForm: "頭",
            normalizedForms: ["頭"], normalizedReadings: ["かしら"])
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(writtenForm: "頭", reading: "あたま"),
            lookup: lookup)
        guard case let .resolved(m, tier) = outcome else {
            return XCTFail("期望 resolved，实际 \(outcome)")
        }
        XCTAssertEqual(tier, .exactWritten)
        XCTAssertEqual(m.entryID, 1)
    }

    func testUnresolvedWhenNothingHits() async throws {
        let lookup = FakeLookup()
        let outcome = try await DictionaryLexemeResolver.resolve(
            LexemeResolutionInput(
                writtenForm: "そんざいしない",
                deinflectionLemmas: ["そんざいする"]),
            lookup: lookup)
        XCTAssertEqual(outcome, .unresolved)
    }

    // MARK: - 同层重绑决策

    /// 同层唯一命中==旧值 → current。
    func testRebindCurrentWhenSameEntryHits() async throws {
        let lookup = FakeLookup()
        lookup.formHits["事"] = [match(100, surface: "事")]
        let decision = try await DictionaryLexemeResolver.reresolve(
            tier: .exactWritten, currentEntryID: 100,
            input: LexemeResolutionInput(writtenForm: "事"),
            lookup: lookup)
        XCTAssertEqual(decision, .current)
        // 只查了 forms——不降级。
        XCTAssertTrue(lookup.queriedKeys.allSatisfy {
            $0.hasPrefix("form:")
        })
    }

    /// 同层唯一命中是不同 ent_seq → rebound（更新绑定）。
    func testRebindWithinTierToNewEntry() async throws {
        let lookup = FakeLookup()
        lookup.formHits["事"] = [match(200, surface: "事")]
        let decision = try await DictionaryLexemeResolver.reresolve(
            tier: .exactWritten, currentEntryID: 100,
            input: LexemeResolutionInput(writtenForm: "事"),
            lookup: lookup)
        XCTAssertEqual(decision, .rebound(entryID: 200))
    }

    /// 同层零命中 → stale，保留旧值。
    func testRebindStaleWhenTierMisses() async throws {
        let lookup = FakeLookup()
        // written 层在新库已无该表记，但 reading 层有——
        // 同层规则下不得换绑到 reading 层命中。
        lookup.readingHits["事"] = [match(300, surface: "こと")]
        let decision = try await DictionaryLexemeResolver.reresolve(
            tier: .exactWritten, currentEntryID: 100,
            input: LexemeResolutionInput(writtenForm: "事"),
            lookup: lookup)
        guard case .stale = decision else {
            return XCTFail("期望 stale，实际 \(decision)")
        }
        XCTAssertTrue(lookup.queriedKeys.allSatisfy {
            $0.hasPrefix("form:")
        }, "stale 判定不得探查更低层")
    }

    /// 同层多候选且读音消歧无果 → ambiguous。
    func testRebindAmbiguousKeepsOld() async throws {
        let lookup = FakeLookup()
        lookup.formHits["事"] = [
            match(100, surface: "事"), match(101, surface: "事"),
        ]
        lookup.surfaces[100] = DictionaryEntrySurface(
            entryID: 100, primaryForm: "事",
            normalizedForms: ["事"], normalizedReadings: ["こと"])
        lookup.surfaces[101] = DictionaryEntrySurface(
            entryID: 101, primaryForm: "事",
            normalizedForms: ["事"], normalizedReadings: ["ことべ"])
        let decision = try await DictionaryLexemeResolver.reresolve(
            tier: .exactWritten, currentEntryID: 100,
            input: LexemeResolutionInput(writtenForm: "事"),
            lookup: lookup)
        guard case let .ambiguous(ids) = decision else {
            return XCTFail("期望 ambiguous，实际 \(decision)")
        }
        XCTAssertEqual(Set(ids), [100, 101])
    }

    /// deinflected 层重绑：用 lexeme.normalizedLemma 重放 lemma 命中。
    func testRebindDeinflectedTier() async throws {
        let lookup = FakeLookup()
        lookup.formHits["食べる"] = [match(555, surface: "食べる")]
        let decision = try await DictionaryLexemeResolver.reresolve(
            tier: .deinflected, currentEntryID: 1_358_280,
            input: LexemeResolutionInput(
                writtenForm: "食べなかった",
                deinflectionLemmas: ["食べる"]),
            lookup: lookup)
        XCTAssertEqual(decision, .rebound(entryID: 555))
    }

    /// verifiedExisting 存量绑定：只核验旧 entry 表面。
    func testRebindVerifiedExisting() async throws {
        let lookup = FakeLookup()
        lookup.surfaces[100] = DictionaryEntrySurface(
            entryID: 100, primaryForm: "事",
            normalizedForms: ["事"], normalizedReadings: ["こと"])
        let ok = try await DictionaryLexemeResolver.reresolve(
            tier: .verifiedExisting, currentEntryID: 100,
            input: LexemeResolutionInput(writtenForm: "事", reading: "こと"),
            lookup: lookup)
        XCTAssertEqual(ok, .current)

        let missing = try await DictionaryLexemeResolver.reresolve(
            tier: .verifiedExisting, currentEntryID: 999,
            input: LexemeResolutionInput(writtenForm: "事"),
            lookup: lookup)
        XCTAssertEqual(missing, .stale(detail: "entry_missing"))
        // 核验路径不查任何匹配通道。
        XCTAssertTrue(lookup.queriedKeys.isEmpty)
    }

    // MARK: - 释义 fallback（zh → en → 无释义）

    private func sense(
        _ glosses: [(String, String)]  // (language, text)
    ) -> DictionarySense {
        DictionarySense(
            id: 1, order: 0, posCodes: [], tags: [],
            glosses: glosses.enumerated().map { idx, pair in
                DictionaryGloss(
                    language: pair.0, text: pair.1, order: idx,
                    sourceID: "test", isMachineGenerated: true)
            })
    }

    func testGlossPreferredChinese() {
        let entry = DictionaryEntry(
            id: 1, primaryForm: "事", commonRank: nil, forms: [],
            readings: [],
            senses: [sense([("zho", "事情"), ("eng", "thing")])])
        let resolved = GlossFallbackResolver.resolve(entry)
        guard case let .preferred(language, glosses) = resolved else {
            return XCTFail("期望 preferred，实际 \(resolved)")
        }
        XCTAssertEqual(language, "zho")
        XCTAssertEqual(glosses.map(\.text), ["事情"])
        XCTAssertFalse(resolved.isFallback)
    }

    func testGlossFallbackToEnglish() {
        let entry = DictionaryEntry(
            id: 1, primaryForm: "事", commonRank: nil, forms: [],
            readings: [],
            senses: [sense([("eng", "thing")])])
        let resolved = GlossFallbackResolver.resolve(entry)
        guard case let .fallback(language, glosses) = resolved else {
            return XCTFail("期望 fallback，实际 \(resolved)")
        }
        XCTAssertEqual(language, "eng")
        XCTAssertEqual(glosses.map(\.text), ["thing"])
        XCTAssertTrue(resolved.isFallback)
    }

    func testGlossUnavailableMarker() {
        let entry = DictionaryEntry(
            id: 1, primaryForm: "事", commonRank: nil, forms: [],
            readings: [], senses: [sense([])])
        XCTAssertEqual(GlossFallbackResolver.resolve(entry), .unavailable)
        XCTAssertNil(GlossResolution.unavailable.language)
        XCTAssertTrue(GlossResolution.unavailable.glosses.isEmpty)
    }

    /// entry 级决议跳过低个无释义 sense；overlay 作为 zh 覆盖旁证。
    func testEntryLevelFallsAcrossSensesAndOverlay() {
        let overlayOnly = DictionaryEntry(
            id: 2, primaryForm: "x", commonRank: nil, forms: [],
            readings: [], senses: [sense([])],
            overlayGlosses: [DictionaryEntryOverlay(
                language: "zho", text: "仅条目级中文", sourceID: "t")])
        let resolved = GlossFallbackResolver.resolve(overlayOnly)
        guard case let .preferred(language, glosses) = resolved else {
            return XCTFail("期望 overlay preferred，实际 \(resolved)")
        }
        XCTAssertEqual(language, "zho")
        XCTAssertEqual(glosses.map(\.text), ["仅条目级中文"])
    }

    // MARK: - 报告值类型

    func testCoverageRatesAndRejectionTotals() {
        let coverage = ChineseCoverageStats(
            entryCount: 4, entriesWithChinese: 3,
            senseCount: 8, sensesWithChinese: 5,
            zhGlossCount: 6, engGlossCount: 9)
        XCTAssertEqual(coverage.entryAlignmentRate, 0.75)
        XCTAssertEqual(coverage.senseAlignmentRate, 0.625)

        let report = DictionaryQualityReport(
            datasetVersion: "v", dictionaryVersion: "v",
            chineseCoverage: coverage,
            declaredZhEntriesAligned: 3, declaredZhAlignmentRate: 0.75,
            rejections: [
                RejectedEntryClass(
                    reason: .entryWithoutForms, count: 2,
                    sampleEntryIDs: [7, 9]),
                RejectedEntryClass(
                    reason: .orphanedRows, count: 5,
                    sampleEntryIDs: [42]),
            ],
            auditVersion: "s19-audit-1")
        XCTAssertEqual(report.totalRejected, 7)
    }
}
