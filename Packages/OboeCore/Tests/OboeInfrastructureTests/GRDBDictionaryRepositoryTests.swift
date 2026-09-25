import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// S06 词典仓储测试：真实构建产物（`.codex_tmp/dictionary-artifacts/
/// japanese-dictionary.sqlite`，sha256 8f0758d4…，schema v1，218,807 条）
/// 复制到临时目录后使用。
///
/// Fixture 解析顺序：
/// 1. 环境变量 `OBOE_DICTIONARY_FIXTURE`（CI/特殊环境覆盖）；
/// 2. 仓库内 `.codex_tmp/dictionary-artifacts/japanese-dictionary.sqlite`
///    ——若 iCloud dataless（未物化）则跳过，避免阻塞；
/// 3. `/tmp/oboe-dict/japanese-dictionary.sqlite`（本地预物化副本）。
final class GRDBDictionaryRepositoryTests: XCTestCase {

    // MARK: - fixture

    private struct TestLocation {
        let rootURL: URL
        let databaseURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "GRDBDictionaryRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
            databaseURL = rootURL.appendingPathComponent("japanese-dictionary.sqlite")
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private static func artifactURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["OBOE_DICTIONARY_FIXTURE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        // #filePath → …/Packages/OboeCore/Tests/OboeInfrastructureTests/<file>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OboeInfrastructureTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OboeCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
        let artifact = repoRoot.appendingPathComponent(
            ".codex_tmp/dictionary-artifacts/japanese-dictionary.sqlite"
        )
        // iCloud file provider 下的 dataless 文件读取会阻塞；有物化状态才用仓库副本
        if let status = try? artifact.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]
        ).ubiquitousItemDownloadingStatus {
            if status == .current, FileManager.default.fileExists(atPath: artifact.path) {
                return artifact
            }
        } else if FileManager.default.fileExists(atPath: artifact.path) {
            return artifact
        }
        let fallback = URL(fileURLWithPath: "/tmp/oboe-dict/japanese-dictionary.sqlite")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return artifact // 让后续拷贝报错并给出清晰信息
    }

    private func makeRepository() throws -> (GRDBDictionaryRepository, TestLocation) {
        let location = try TestLocation()
        try FileManager.default.copyItem(
            at: Self.artifactURL(),
            to: location.databaseURL
        )
        return (GRDBDictionaryRepository(databaseURL: location.databaseURL), location)
    }

    /// UTF-8 逐字节序（与 SQLite BINARY collation 一致）
    private func binaryLE(_ lhs: String, _ rhs: String) -> Bool {
        !rhs.utf8.lexicographicallyPrecedes(lhs.utf8)
    }

    private func request(
        _ query: String,
        candidates: [DeinflectionCandidate] = [],
        limit: Int = 30,
        cursor: DictionarySearchCursor? = nil
    ) -> DictionarySearchRequest {
        DictionarySearchRequest(query: query, candidates: candidates, limit: limit, cursor: cursor)
    }

    // MARK: - metadata / 校验

    func testMetadataReportsFrozenSchemaV1AndDatasetVersion() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let metadata = try await repository.metadata()
        XCTAssertEqual(metadata.schemaVersion, "1")
        XCTAssertEqual(metadata.datasetVersion, "2026.09.24-1")
        XCTAssertEqual(metadata.dictionaryVersion, "2026.09.24-1")
        XCTAssertEqual(metadata.entryCount, 218_807)
        XCTAssertEqual(metadata.formCount, 233_511)
        XCTAssertEqual(metadata.senseCount, 253_651)
        XCTAssertEqual(metadata.normalizer, "oboe-search-normalizer/1")
        XCTAssertEqual(metadata.jmdictSourceVersion, "2026-09-24-daily")
        XCTAssertEqual(metadata.chineseLayerVersion, "v2026-09-02")
        XCTAssertNotNil(metadata.licenseRevision)
    }

    func testIncompatibleSchemaVersionIsRejectedNotCrash() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }
        // 在副本上把 schema_version 改成 2（测试侧可写，仓储仍只读打开）
        let writer = try DatabaseQueue(path: location.databaseURL.path)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE dictionary_metadata SET value = '2' WHERE key = 'schema_version'"
            )
        }
        try writer.close()

        await XCTAssertThrowsErrorAsync(try await repository.metadata()) { error in
            guard case DictionaryError.incompatibleSchema(let found) = error else {
                return XCTFail("期望 incompatibleSchema，实际 \(error)")
            }
            XCTAssertEqual(found, "2")
        }
        // 其余入口同样拒绝而不是崩溃
        await XCTAssertThrowsErrorAsync(try await repository.search(request("食べる")))
        await XCTAssertThrowsErrorAsync(try await repository.entry(id: 1))
    }

    func testMissingDatasetVersionIsRejected() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }
        let writer = try DatabaseQueue(path: location.databaseURL.path)
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM dictionary_metadata WHERE key IN ('dataset_version','dictionary_version')"
            )
        }
        try writer.close()

        await XCTAssertThrowsErrorAsync(try await repository.metadata()) { error in
            guard case DictionaryError.incompatibleSchema = error else {
                return XCTFail("期望 incompatibleSchema，实际 \(error)")
            }
        }
    }

    func testMissingFileYieldsUnavailable() async throws {
        let location = try TestLocation()
        defer { location.remove() }
        let repository = GRDBDictionaryRepository(
            databaseURL: location.rootURL.appendingPathComponent("nonexistent.sqlite")
        )
        await XCTAssertThrowsErrorAsync(try await repository.metadata()) { error in
            guard case DictionaryError.unavailable = error else {
                return XCTFail("期望 unavailable，实际 \(error)")
            }
        }
    }

    // MARK: - sources（Sources/Licenses 事实源）

    func testSourcesReturnJMdictAndTomoshiWithLicenseFacts() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let sources = try await repository.sources()
        XCTAssertEqual(sources.map(\.id), ["jmdict_e", "tomoshi"])

        let jmdict = try XCTUnwrap(sources.first { $0.id == "jmdict_e" })
        XCTAssertEqual(jmdict.name, "JMdict (EDRDG)")
        XCTAssertEqual(jmdict.version, "2026-09-24-daily")
        XCTAssertEqual(jmdict.license, "CC-BY-SA-4.0")
        XCTAssertTrue(jmdict.licenseURL.contains("creativecommons.org"))
        XCTAssertFalse(jmdict.attribution.isEmpty)
        XCTAssertFalse(jmdict.sha256.isEmpty)
        XCTAssertGreaterThan(jmdict.inputBytes, 0)
        XCTAssertFalse(jmdict.retrievedAt.isEmpty)

        let tomoshi = try XCTUnwrap(sources.first { $0.id == "tomoshi" })
        XCTAssertEqual(tomoshi.version, "v2026-09-02")
        XCTAssertEqual(tomoshi.consumedTables, ["meta", "table_licenses", "zh_defs"])
        XCTAssertTrue(tomoshi.modifications.contains("machine-assisted")
            || tomoshi.modifications.contains("zh"))
    }

    // MARK: - 精确 / 规范化搜索

    func testExactSearchKanjiAndKana() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // Kanji 精确：食べる = entry 1358280
        let kanji = try await repository.search(request("食べる"))
        let kanjiHit = try XCTUnwrap(kanji.items.first { $0.entryID == 1_358_280 })
        XCTAssertEqual(kanjiHit.reason, .exact)
        XCTAssertEqual(kanjiHit.channel, .form)
        XCTAssertEqual(kanjiHit.matchedForm, "食べる")
        XCTAssertEqual(kanjiHit.rank, 1)
        XCTAssertEqual(kanji.normalizedQuery, "食べる")

        // Kana 精确：たべる 命中同一词条（走 readings 通道）
        let kana = try await repository.search(request("たべる"))
        let kanaHit = try XCTUnwrap(kana.items.first { $0.entryID == 1_358_280 })
        XCTAssertEqual(kanaHit.reason, .exact)
        XCTAssertEqual(kanaHit.channel, .reading)
        XCTAssertTrue(kanaHit.matchedSurfaces.contains("たべる"))

        // 规范化命中：カタカナ输入 → 片→平，reason = normalized
        let katakana = try await repository.search(request("タベル"))
        let kataHit = try XCTUnwrap(katakana.items.first { $0.entryID == 1_358_280 })
        XCTAssertEqual(katakana.normalizedQuery, "たべる")
        XCTAssertEqual(kataHit.reason, .normalized)

        // に：大量词条通过读音精确命中（页内 exact/normalized 段在前，
        // 其后才是 prefix 段——两段交错出现属正常分页）
        let ni = try await repository.search(request("に"))
        let niExact = ni.items.filter {
            $0.reason == .exact || $0.reason == .normalized
        }
        let niIDs = Set(niExact.map(\.entryID))
        XCTAssertTrue(niIDs.isSuperset(of: [1_195_250, 1_314_550, 1_416_890]))
        if let firstPrefix = ni.items.firstIndex(where: { $0.reason == .prefix }) {
            XCTAssertTrue(
                ni.items[..<firstPrefix].allSatisfy {
                    $0.reason == .exact || $0.reason == .normalized
                },
                "前缀段之前只允许 exact/normalized"
            )
        }

        // 鰐：单汉字精确命中（id 1562640）
        let wani = try await repository.search(request("鰐"))
        XCTAssertTrue(wani.items.contains { $0.entryID == 1_562_640 })
        // わに（读音）：鰐 + 和邇
        let waniKana = try await repository.search(request("わに"))
        let waniIDs = Set(waniKana.items.map(\.entryID))
        XCTAssertTrue(waniIDs.isSuperset(of: [1_562_640, 5_718_277]))

        // 不存在词：空页
        let none = try await repository.search(request("そんざいしないことば"))
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertFalse(none.hasMore)
        XCTAssertNil(none.nextCursor)
    }

    func testExactHitsOrderedByCommonRankThenID() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // 「と」：大量同形/同音词条；校验 exact 段按 (rank, id) 非递减
        let page = try await repository.search(request("と", limit: 100))
        let exactItems = page.items.filter {
            $0.reason == .exact || $0.reason == .normalized
        }
        XCTAssertGreaterThan(exactItems.count, 1)
        var previous: (Int, Int64)?
        for hit in exactItems {
            let rank = hit.rank ?? Int(Int32.max)
            if let prev = previous {
                XCTAssertTrue(
                    rank > prev.0 || (rank == prev.0 && hit.entryID > prev.1),
                    "exact 段须按 (rank, entryID) 升序"
                )
            }
            previous = (rank, hit.entryID)
        }
    }

    // MARK: - 前缀 + keyset 分页

    func testPrefixSearchOrderedAndDeduplicated() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // 「食べ」前缀应命中 食べる 等
        let page = try await repository.search(request("食べ", limit: 30))
        let prefixItems = page.items.filter { $0.reason == .prefix }
        XCTAssertFalse(prefixItems.isEmpty)
        XCTAssertTrue(prefixItems.contains { $0.entryID == 1_358_280 })
        // 前缀段按 (matchedNormalized, entryID) BINARY 非递减
        var previous: (String, Int64)?
        for hit in prefixItems {
            if let prev = previous {
                XCTAssertTrue(
                    binaryLE(prev.0, hit.matchedNormalized)
                        || (prev.0 == hit.matchedNormalized && hit.entryID > prev.1),
                    "前缀段须按 (normalized, entryID) 升序：\(prev) vs \(hit.matchedNormalized),\(hit.entryID)"
                )
            }
            previous = (hit.matchedNormalized, hit.entryID)
        }
    }

    func testKeysetPaginationStableAcrossPagesNoDuplicates() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // 「あぶら」前缀窗口约 88 条 + 精确若干：30/页 → 多页
        var allItems: [DictionaryHit] = []
        var cursor: DictionarySearchCursor?
        var hasMore = true
        var pageCount = 0
        while hasMore {
            let page = try await repository.search(request("あぶら", limit: 30, cursor: cursor))
            allItems += page.items
            cursor = page.nextCursor
            hasMore = page.hasMore
            pageCount += 1
            XCTAssertLessThanOrEqual(pageCount, 30, "翻页不收敛")
            XCTAssertEqual(hasMore, cursor != nil, "hasMore 与 nextCursor 必须一致")
        }

        XCTAssertGreaterThanOrEqual(pageCount, 2, "应产生多页")
        let ids = allItems.map(\.entryID)
        XCTAssertEqual(Set(ids).count, ids.count, "跨页不得重复")
        XCTAssertFalse(ids.isEmpty)
        // 前缀段全局有序
        let prefixItems = allItems.filter { $0.reason == .prefix }
        var previous: (String, Int64)?
        for hit in prefixItems {
            if let prev = previous {
                XCTAssertTrue(
                    binaryLE(prev.0, hit.matchedNormalized)
                        || (prev.0 == hit.matchedNormalized && hit.entryID > prev.1)
                )
            }
            previous = (hit.matchedNormalized, hit.entryID)
        }
        // 精确段在前、前缀段在后
        let firstPrefixIndex = allItems.firstIndex { $0.reason == .prefix }
        let lastExactIndex = allItems.lastIndex {
            $0.reason == .exact || $0.reason == .normalized || $0.reason == .deinflected
        }
        if let firstPrefixIndex, let lastExactIndex {
            XCTAssertLessThan(lastExactIndex, firstPrefixIndex,
                              "exact/deinflected 段必须整体排在前缀段之前")
        }
    }

    func testExactPhasePaginatesAcrossPages() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // 「こう」精确命中 51 条（> limit 30）：page1 全 exact，
        // page2 继续 exact 后才进入 prefix——跨页不重不漏。
        let page1 = try await repository.search(request("こう", limit: 30))
        XCTAssertEqual(page1.items.count, 30)
        XCTAssertTrue(page1.items.allSatisfy {
            $0.reason == .exact || $0.reason == .normalized
        })
        XCTAssertTrue(page1.hasMore)
        XCTAssertEqual(page1.nextCursor?.phase, 0)

        let page2 = try await repository.search(
            request("こう", limit: 30, cursor: page1.nextCursor)
        )
        let ids1 = page1.items.map(\.entryID)
        let ids2 = page2.items.map(\.entryID)
        XCTAssertTrue(Set(ids1).isDisjoint(with: Set(ids2)), "跨页不得重复")
        XCTAssertEqual(Set(ids1 + ids2).count, ids1.count + ids2.count)
        // page2 头部应仍是 exact 段（51 精确命中共需两页）
        let exactInPage2 = page2.items.filter {
            $0.reason == .exact || $0.reason == .normalized
        }
        XCTAssertEqual(exactInPage2.count, 21, "剩余 21 条精确命中应在 page2 头部")
    }

    func testCursorSurvivesJSONRoundTrip() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let page1 = try await repository.search(request("あぶら", limit: 30))
        XCTAssertTrue(page1.hasMore)
        let cursor = try XCTUnwrap(page1.nextCursor)
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(DictionarySearchCursor.self, from: data)
        let directPage2 = try await repository.search(
            request("あぶら", limit: 30, cursor: cursor)
        )
        let decodedPage2 = try await repository.search(
            request("あぶら", limit: 30, cursor: decoded)
        )
        XCTAssertEqual(directPage2.items, decodedPage2.items)
        XCTAssertEqual(directPage2.hasMore, decodedPage2.hasMore)
    }

    func testCursorDatasetMismatchRestartsFromFirstPage() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let fresh = try await repository.search(request("あぶら", limit: 30))
        var badCursor = try XCTUnwrap(fresh.nextCursor)
        badCursor.datasetVersion = "1999.01.01-0"
        let restarted = try await repository.search(
            request("あぶら", limit: 30, cursor: badCursor)
        )
        XCTAssertEqual(restarted.items, fresh.items, "版本失配游标应回退第一页")
    }

    func testLimitClampedAndEmptyQuerySafe() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let one = try await repository.search(request("食", limit: 1))
        XCTAssertEqual(one.items.count, 1)
        XCTAssertTrue(one.hasMore)

        // limit 0 → clamp 1；limit 999 → clamp 100
        XCTAssertEqual(request("食", limit: 0).limit, 1)
        XCTAssertEqual(request("食", limit: 999).limit, 100)

        // 空查询不扫库
        let empty = try await repository.search(request(""))
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.hasMore)
        let spaces = try await repository.search(request("  　  "))
        XCTAssertTrue(spaces.items.isEmpty)
    }

    // MARK: - 变形还原路径

    func testDeinflectedHitsRespectPOSIntersection() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }
        let deinflector = JapaneseDeinflector()

        // 食べなかった → 食べる（v1）
        let candidates = deinflector.candidates(for: "食べなかった")
        XCTAssertFalse(candidates.contains { $0.isTruncationMarker })
        XCTAssertTrue(candidates.contains { $0.lemma == "食べる" })
        let page = try await repository.search(request("食べなかった", candidates: candidates))
        let hit = try XCTUnwrap(page.items.first { $0.entryID == 1_358_280 })
        XCTAssertEqual(hit.reason, .deinflected)
        XCTAssertEqual(hit.matchedLemma, "食べる")
        XCTAssertFalse(hit.reasonChain.isEmpty)

        // 行った → 行く（明示例外，v5kS）
        let ikuCandidates = deinflector.candidates(for: "行った")
        let ikuPage = try await repository.search(
            request("行った", candidates: ikuCandidates)
        )
        let ikuHit = try XCTUnwrap(ikuPage.items.first { $0.entryID == 1_578_850 })
        XCTAssertEqual(ikuHit.reason, .deinflected)

        // 見せた → 見せる{v1…}：名词词条 ミセル(2203680, pos={n}) 必须被
        // sense_pos ∩ admissiblePOS 过滤裁掉；見せる(1259210, v1) 保留。
        let misetaCandidates = deinflector.candidates(for: "見せた")
        XCTAssertTrue(misetaCandidates.contains { $0.lemma == "見せる" })
        let misetaPage = try await repository.search(
            request("見せた", candidates: misetaCandidates)
        )
        let misetaIDs = Set(misetaPage.items.map(\.entryID))
        XCTAssertTrue(misetaIDs.contains(1_259_210), "見せる 应命中")
        XCTAssertFalse(misetaIDs.contains(2_203_680), "ミセル(n) 应被 POS 过滤裁掉")
    }

    func testDeinflectedSectionBetweenExactAndPrefix() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }
        let deinflector = JapaneseDeinflector()

        // 「食べた」：自身无精确词条，候选 食べる 在精确段之后、前缀段之前
        let candidates = deinflector.candidates(for: "食べた")
        let page = try await repository.search(
            request("食べた", candidates: candidates, limit: 100)
        )
        let deinIndex = page.items.firstIndex { $0.reason == .deinflected }
        let prefixIndex = page.items.firstIndex { $0.reason == .prefix }
        if let deinIndex, let prefixIndex {
            XCTAssertLessThan(deinIndex, prefixIndex,
                              "变形候选段须排在前缀段之前")
        }
        XCTAssertTrue(page.items.contains { $0.entryID == 1_358_280 && $0.reason == .deinflected })
    }

    // MARK: - 详情聚合

    func testEntryDetailAggregation() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let entry = try await repository.entry(id: 1_358_280)
        let detail = try XCTUnwrap(entry)
        XCTAssertEqual(detail.primaryForm, "食べる")
        XCTAssertEqual(detail.commonRank, 1)

        // forms：食べる(standard, priority 1) + 喰べる(sK)
        XCTAssertEqual(detail.forms.count, 2)
        let standard = try XCTUnwrap(detail.forms.first { $0.text == "食べる" })
        XCTAssertEqual(standard.formType, "standard")
        XCTAssertEqual(standard.priority, 1)
        let sk = try XCTUnwrap(detail.forms.first { $0.text == "喰べる" })
        XCTAssertEqual(sk.formType, "sK")

        // readings：たべる
        XCTAssertEqual(detail.readings.map(\.reading), ["たべる"])
        XCTAssertFalse(detail.readings[0].noKanji)

        // senses：2 个，按 sense_order
        XCTAssertEqual(detail.senses.count, 2)
        XCTAssertEqual(detail.senses.map(\.order), [0, 1])
        XCTAssertTrue(detail.senses[0].posCodes.contains("v1"))
        XCTAssertTrue(detail.senses[0].posCodes.contains("vt"))

        // glosses：sense0 eng「to eat」+ zho（机翻标记）
        let sense0 = detail.senses[0]
        let eng = sense0.glosses(language: "eng")
        XCTAssertEqual(eng.first?.text, "to eat")
        let zho = sense0.glosses(language: "zho")
        XCTAssertEqual(zho.first?.text, "吃;食用")
        XCTAssertTrue(zho.first?.isMachineGenerated ?? false)
        XCTAssertEqual(zho.first?.sourceID, "tomoshi")
        // sense1 多 eng gloss 按 gloss_order
        let eng1 = detail.senses[1].glosses(language: "eng")
        XCTAssertEqual(eng1.map(\.order), [0, 1, 2])

        // 词条 POS 并集
        XCTAssertTrue(detail.partOfSpeechCodes.contains("v1"))

        // 缺 id → nil
        let missing = try await repository.entry(id: 999_999_999_999)
        XCTAssertNil(missing)
    }

    func testEntryDetailTagsAndRestrictions() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // xref：entry 1000090 的 sense_tags 含 category=xref
        let xref = try await unwrapped(repository, id: 1_000_090)
        let xrefTags = xref.senses.flatMap(\.tags).filter { $0.category == "xref" }
        XCTAssertFalse(xrefTags.isEmpty)
        XCTAssertTrue(xrefTags.contains { $0.code.contains("二重丸") })

        // ant：entry 1014680
        let ant = try await unwrapped(repository, id: 1_014_680)
        XCTAssertTrue(ant.senses.flatMap(\.tags).contains { $0.category == "ant" })

        // reading→form 限定：entry 1000110（ＣＤプレーヤー）
        let cd = try await unwrapped(repository, id: 1_000_110)
        let r1 = try XCTUnwrap(cd.readings.first { $0.reading == "シーディープレーヤー" })
        XCTAssertEqual(r1.restrictedForms, ["ＣＤプレーヤー"])
        let r2 = try XCTUnwrap(cd.readings.first { $0.reading == "シーディープレイヤー" })
        XCTAssertEqual(r2.restrictedForms, ["ＣＤプレイヤー"])

        // sense→form 限定：entry 1010230（半片）sense_order=1 限定表记「半片」
        let hanpen = try await unwrapped(repository, id: 1_010_230)
        let restricted = try XCTUnwrap(hanpen.senses.first { $0.order == 1 })
        XCTAssertEqual(restricted.restrictedForms, ["半片"])

        // sense→reading 限定：entry 1000320（彼処）sense_order=1 限定三个读音
        let asoko = try await unwrapped(repository, id: 1_000_320)
        let asokoSense = try XCTUnwrap(asoko.senses.first { $0.order == 1 })
        XCTAssertEqual(Set(asokoSense.restrictedReadings), ["あそこ", "あすこ", "アソコ"])
    }

    func testEntriesPreservesInputOrderAndSkipsMissing() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        let entries = try await repository.entries(
            ids: [1_578_850, 1_358_280, 999_999_999_999, 1_358_280]
        )
        XCTAssertEqual(entries.map(\.id), [1_578_850, 1_358_280])
        XCTAssertEqual(entries[0].primaryForm, "行く")
        XCTAssertEqual(entries[1].primaryForm, "食べる")

        let empty = try await repository.entries(ids: [])
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - 中文缺失回退（D08）

    func testChineseFallbackToEnglish() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // entry 2870833（身拭い）：全部 sense 无 zho 覆盖 → 回退 eng
        let entry = try await unwrapped(repository, id: 2_870_833)
        XCTAssertTrue(entry.glosses(language: "zho").isEmpty)
        let preferred = try XCTUnwrap(entry.preferredGlosses())
        XCTAssertEqual(preferred.language, "eng")
        XCTAssertFalse(preferred.glosses.isEmpty)
        // sense 级同样
        let sensePreferred = try XCTUnwrap(entry.senses.first?.preferredGlosses())
        XCTAssertEqual(sensePreferred.language, "eng")

        // 正常词条 zh 优先
        let taberu = try await unwrapped(repository, id: 1_358_280)
        let zh = try XCTUnwrap(taberu.preferredGlosses())
        XCTAssertEqual(zh.language, "zho")
    }

    // MARK: - QueryService 端到端（含详情组装）

    func testQueryServiceAssemblesDetailsAndDeinflection() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }
        let service = DictionaryQueryService(
            repository: repository,
            deinflector: JapaneseDeinflector()
        )

        let outcome = try await service.search(query: "食べなかった")
        let item = try XCTUnwrap(outcome.items.first { $0.hit.entryID == 1_358_280 })
        XCTAssertEqual(item.hit.reason, .deinflected)
        XCTAssertEqual(item.entry?.primaryForm, "食べる")
        XCTAssertFalse(item.hit.reasonChain.isEmpty)
        // reason 链可展示给 UI
        XCTAssertTrue(item.hit.reasonChain.joined().contains("なかった")
            || !item.hit.reasonChain.isEmpty)

        // 详情随命中带出：释义可用
        let gloss = try XCTUnwrap(item.entry?.preferredGlosses())
        XCTAssertFalse(gloss.glosses.isEmpty)
    }

    // MARK: - 并发 / lazy

    func testLazyOpenIsThreadSafeUnderConcurrentFirstUse() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try await repository.metadata()
                    _ = try await repository.search(
                        DictionarySearchRequest(query: "食べる", limit: 10)
                    )
                    _ = try await repository.sources()
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: - 性能粗测（输出实测值）

    func testWarmPrefixQueryPerformance() async throws {
        let (repository, location) = try makeRepository()
        defer { location.remove() }

        // 冷开（open+validate+首查）计时
        let coldStart = ContinuousClock.now
        _ = try await repository.search(request("食", limit: 30))
        let coldMs = coldStart.duration(to: .now).milliseconds
        print("[perf] dictionary cold open+first query: \(coldMs) ms")

        // warm prefix：20 次「食」前缀查询
        var samples: [Int64] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            _ = try await repository.search(request("食", limit: 30))
            samples.append(start.duration(to: .now).milliseconds)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95) - 1]
        print("[perf] warm prefix query p50=\(p50) ms p95=\(p95) ms max=\(samples.last!) ms")
        // D04 预算：prefix p95 ≤100ms；任务目标 <50ms（宽松断言 + 实测输出）
        XCTAssertLessThan(p95, 100, "warm prefix p95 超出 100ms 预算")
    }

    // MARK: - helpers

    /// `XCTAssertThrowsError` 的 async 变体
    private func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("期望抛错但未抛：\(message)", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }

    /// `entry(id:)` + XCTUnwrap 二合一（async 版）
    private func unwrapped(
        _ repository: GRDBDictionaryRepository,
        id: Int64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> DictionaryEntry {
        let entry = try await repository.entry(id: id)
        return try XCTUnwrap(entry, "entry \(id) 不存在", file: file, line: line)
    }

}

private extension Duration {
    var milliseconds: Int64 {
        (components.seconds * 1000) + (components.attoseconds / 1_000_000_000_000_000)
    }
}
