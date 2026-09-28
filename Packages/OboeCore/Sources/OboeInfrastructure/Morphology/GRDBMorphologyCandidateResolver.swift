import Foundation
import GRDB
import OboeDomain

/// 词典 dataset 版本提供者（S07）：resolver 顺带向 MorphologyService 报告
/// `dictionaryDatasetVersion`（token cache 键组成之一）。
public protocol MorphologyDatasetVersionProvider: Sendable {
    func morphologyDatasetVersion() async throws -> String
}

/// S07 冻结的 `MorphologyCandidateResolver` 批量实现——对随包词典库做
/// N span × M 候选的批量命中解析，**没有逐 token SQL**（§17 约束）：
///
/// 一次 `resolveCandidates` 调用只发一组 IN-chunk 批量查询：
/// 1. `forms.normalized_text IN (…)` / `readings.normalized_reading IN (…)`
///    ——所有 span 的所有 identity key 与 deinflect lemma key 合一查；
/// 2. `entries WHERE id IN (…)`——命中 entry 的 primary_form/common_rank；
/// 3. `senses JOIN sense_pos … WHERE s.entry_id IN (…)`——POS 门控全集；
/// 4. `readings WHERE entry_id IN (…)`——候选读音回填。
///
/// 通道语义（与 `GRDBDictionaryRepository.SearchEngine` 一致，纯组合复用
/// 同一批 SQL 谓词，不改 SearchEngine 代码路径）：
/// - **exact 通道**：`SpanCandidates.normalizedForms`（含 variant 折叠键）
///   与 identity（reasons 为空）候选——**无 POS 门**（spike §3.3：
///   identity 的 admissiblePOS 是活用类全集，过滤反而误杀）；
/// - **derived 通道**：其余 deinflect 候选 lemma 的双通道精确命中，
///   要求 `entry.sense_pos ∩ admissiblePOS ≠ ∅`；
/// - 候选排序 `(cost, common_rank, entryID)`，每 span 截断至
///   `MorphologyCandidate.maximumRetained`（5），同 entry 取最优候选。
///
/// 连接策略：自带只读 `DatabaseQueue`（lazy open，复刻
/// `GRDBDictionaryRepository` 的 schema_version/dataset_version 校验），
/// 不共享搜索仓储的连接；测试可用 `init(reader:datasetVersion:)` 注入任意
/// `DatabaseReader`（含计数 wrapper / 内存库）。
public final class GRDBMorphologyCandidateResolver: MorphologyCandidateResolver,
    MorphologyDatasetVersionProvider, @unchecked Sendable {

    /// IN 列表分块上限（规避 SQLite 变量上限；与词典仓储一致取 400）。
    static let inChunkSize = 400
    /// common_rank NULL 排序哨兵。
    private static let rankNullSentinel = Int(Int32.max)

    private enum Backend {
        case lazyURL(URL)
        case reader(any DatabaseReader, datasetVersion: String)
    }

    /// 单个 span 的查找计划：identity 键 + (候选, lemma 规范化键) 序列。
    private struct LookupPlan {
        /// 保序的 identity/exact 通道键。
        var normalizedKeys: [String] = []
        /// 派生候选及其 lemma 规范化键（identity 候选不在这里——
        /// 它走 normalizedKeys 的 exact 通道）。
        var derived: [(candidate: DeinflectionCandidate, key: String)] = []
    }

    /// 词典命中行（双通道）。
    private struct Hit {
        enum Channel: String { case form, reading }
        let entryID: Int64
        let surface: String
        let channel: Channel
    }

    private let backend: Backend
    private let lock = NSLock()
    private var queue: DatabaseQueue?
    private var cachedDatasetVersion: String?

    /// 生产入口：对随包词典 sqlite 自建只读连接（lazy open）。
    public init(databaseURL: URL) {
        backend = .lazyURL(databaseURL)
    }

    /// 测试/复用入口：注入任意 `DatabaseReader`（计数池、内存库、
    /// DatabaseQueue/DatabasePool 均可）。`datasetVersion` 直接报告。
    public init(reader: any DatabaseReader, datasetVersion: String) {
        backend = .reader(reader, datasetVersion: datasetVersion)
    }

    deinit {
        lock.lock()
        let queue = self.queue
        self.queue = nil
        lock.unlock()
        try? queue?.close()
    }

    // MARK: - MorphologyDatasetVersionProvider

    public func morphologyDatasetVersion() async throws -> String {
        if case let .reader(_, datasetVersion) = backend { return datasetVersion }
        let reader = try openReader()
        if let cached = lock.withLock({ cachedDatasetVersion }) { return cached }
        let version = try await reader.read { db in
            let values = try Self.readMetadataValues(db: db)
            return values["dataset_version"] ?? values["dictionary_version"] ?? ""
        }
        lock.withLock { cachedDatasetVersion = version }
        return version
    }

    // MARK: - MorphologyCandidateResolver

    /// 批量解析：一次 `db.read` 内发完所有 IN-chunk 查询，再在内存里
    /// 组装每 span 的有序候选。输入顺序与输出数组一一对应。
    public func resolveCandidates(
        _ spans: [SpanCandidates]
    ) async throws -> [[MorphologyCandidate]] {
        guard !spans.isEmpty else { return [] }
        try Self.checkCancellation()
        let reader = try openReader()

        // —— 每 span 的查找计划；键集合全集合一批量查 ——
        var plans: [LookupPlan] = []
        plans.reserveCapacity(spans.count)
        var allKeys = Set<String>()
        for span in spans {
            var plan = LookupPlan()
            var identitySeen = Set<String>()
            for key in span.normalizedForms where !key.isEmpty {
                if identitySeen.insert(key).inserted {
                    plan.normalizedKeys.append(key)
                }
            }
            var derivedSeen = Set<String>()
            for candidate in span.deinflections {
                guard !candidate.isTruncationMarker, !candidate.lemma.isEmpty
                else { continue }
                // identity 候选（无 reasons）：只走 exact 通道，无 POS 门。
                if candidate.reasons.isEmpty {
                    let key = SearchTextNormalizer.normalize(candidate.lemma)
                    if !key.isEmpty, identitySeen.insert(key).inserted {
                        plan.normalizedKeys.append(key)
                    }
                    continue
                }
                let key = SearchTextNormalizer.normalize(candidate.lemma)
                guard !key.isEmpty else { continue }
                if derivedSeen.insert(key + "\u{1F}" + String(candidate.cost)).inserted {
                    plan.derived.append((candidate, key))
                }
                allKeys.insert(key)
            }
            for key in plan.normalizedKeys { allKeys.insert(key) }
            plans.append(plan)
        }

        let orderedKeys = allKeys.sorted()
        let fetched = try await reader.read { db in
            try Self.checkCancellation()
            var formHits: [String: [Hit]] = [:]
            var readingHits: [String: [Hit]] = [:]
            for chunk in orderedKeys.chunked(Self.inChunkSize) {
                let p = Self.placeholders(chunk.count)
                let args = StatementArguments(Array(chunk))
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT normalized_text, entry_id, text FROM forms
                        WHERE normalized_text IN (\(p))
                        """,
                    arguments: args
                ) {
                    formHits[row["normalized_text"], default: []].append(
                        Hit(entryID: row["entry_id"], surface: row["text"], channel: .form)
                    )
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT normalized_reading, entry_id, reading FROM readings
                        WHERE normalized_reading IN (\(p))
                        """,
                    arguments: args
                ) {
                    readingHits[row["normalized_reading"], default: []].append(
                        Hit(entryID: row["entry_id"], surface: row["reading"], channel: .reading)
                    )
                }
            }
            try Self.checkCancellation()

            var hitEntryIDs = Set<Int64>()
            for hits in formHits.values { for h in hits { hitEntryIDs.insert(h.entryID) } }
            for hits in readingHits.values { for h in hits { hitEntryIDs.insert(h.entryID) } }

            var rankByEntry: [Int64: Int?] = [:]
            var primaryFormByEntry: [Int64: String] = [:]
            var posByEntry: [Int64: Set<String>] = [:]
            var readingsByEntry: [Int64: [String]] = [:]
            for chunk in Array(hitEntryIDs).chunked(Self.inChunkSize) {
                let ids = Array(chunk)
                let p = Self.placeholders(ids.count)
                let args = StatementArguments(ids)
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, primary_form, common_rank FROM entries
                        WHERE id IN (\(p))
                        """,
                    arguments: args
                ) {
                    rankByEntry[row["id"]] = row["common_rank"]
                    primaryFormByEntry[row["id"]] = row["primary_form"]
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT s.entry_id, sp.code
                        FROM senses s JOIN sense_pos sp ON sp.sense_id = s.id
                        WHERE s.entry_id IN (\(p))
                        """,
                    arguments: args
                ) {
                    posByEntry[row["entry_id"], default: []].insert(row["code"])
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, reading FROM readings
                        WHERE entry_id IN (\(p)) ORDER BY id
                        """,
                    arguments: args
                ) {
                    readingsByEntry[row["entry_id"], default: []].append(row["reading"])
                }
            }
            return FetchResult(
                formHits: formHits, readingHits: readingHits,
                rankByEntry: rankByEntry, primaryFormByEntry: primaryFormByEntry,
                posByEntry: posByEntry, readingsByEntry: readingsByEntry
            )
        }

        // —— 内存装配每 span 的候选 ——
        var output: [[MorphologyCandidate]] = []
        output.reserveCapacity(spans.count)
        for (index, span) in spans.enumerated() {
            try Self.checkCancellation()
            output.append(assemble(
                span: span, plan: plans[index], fetched: fetched
            ))
        }
        return output
    }

    // MARK: - 候选装配（纯内存，无 SQL）

    private struct FetchResult {
        var formHits: [String: [Hit]]
        var readingHits: [String: [Hit]]
        var rankByEntry: [Int64: Int?]
        var primaryFormByEntry: [Int64: String]
        var posByEntry: [Int64: Set<String>]
        var readingsByEntry: [Int64: [String]]
    }

    private func assemble(
        span: SpanCandidates,
        plan: LookupPlan,
        fetched: FetchResult
    ) -> [MorphologyCandidate] {
        let primaryKey = SearchTextNormalizer.normalize(span.surface)

        func reading(for entryID: Int64, matched: Hit, key: String) -> String? {
            if matched.channel == .reading { return matched.surface }
            guard let readings = fetched.readingsByEntry[entryID] else { return nil }
            return readings.first {
                SearchTextNormalizer.normalize($0) == key
            } ?? readings.first
        }

        var candidates: [MorphologyCandidate] = []

        // exact 通道（identity / variant 折叠键，无 POS 门）。
        // lemma 取词条 canonical 写形（primary_form）——半角かな/异体字/
        // 读音写形的命中应报告词条原形而非 surface（ﾃｷｽﾄ→テキスト）。
        for key in plan.normalizedKeys {
            let isVariant = key != primaryKey
            let hits = (fetched.formHits[key] ?? [])
                + (fetched.readingHits[key] ?? [])
            for hit in hits {
                var reasons = hit.channel == .form
                    ? ["exact.identity.form"] : ["exact.identity.reading"]
                if isVariant { reasons.append("variant.fold") }
                let lemma = fetched.primaryFormByEntry[hit.entryID]
                    ?? (isVariant ? key : span.surface)
                candidates.append(MorphologyCandidate(
                    lemma: lemma,
                    normalizedForm: key,
                    reading: reading(for: hit.entryID, matched: hit, key: key),
                    posCodes: (fetched.posByEntry[hit.entryID] ?? []).sorted(),
                    entryID: hit.entryID,
                    reasons: reasons,
                    cost: 0
                ))
            }
        }

        // derived 通道（POS∩ 门控）
        for (candidate, key) in plan.derived {
            let admissible = Set(candidate.admissiblePOS.map(\.rawValue))
            let hits = (fetched.formHits[key] ?? [])
                + (fetched.readingHits[key] ?? [])
            for hit in hits {
                let entryPOS = fetched.posByEntry[hit.entryID] ?? []
                let overlap = entryPOS.intersection(admissible)
                guard !overlap.isEmpty else { continue }
                let folded = key != SearchTextNormalizer.normalize(candidate.lemma)
                var reasons = candidate.reasons
                    + [hit.channel == .form ? "deinflected.form" : "deinflected.reading"]
                if folded { reasons.append("variant.fold") }
                candidates.append(MorphologyCandidate(
                    lemma: candidate.lemma,
                    normalizedForm: key,
                    reading: reading(for: hit.entryID, matched: hit, key: key),
                    posCodes: overlap.sorted(),
                    entryID: hit.entryID,
                    reasons: reasons,
                    cost: candidate.cost
                ))
            }
        }

        // 排序 (cost, common_rank, entryID)；同 entry 取首个（最优）；
        // 截断至 maximumRetained。
        candidates.sort { lhs, rhs in
            if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
            let lr = fetched.rankByEntry[lhs.entryID ?? -1] ?? nil
            let rr = fetched.rankByEntry[rhs.entryID ?? -1] ?? nil
            let l = lr ?? Self.rankNullSentinel
            let r = rr ?? Self.rankNullSentinel
            if l != r { return l < r }
            return (lhs.entryID ?? .max) < (rhs.entryID ?? .max)
        }
        var seenEntries = Set<Int64>()
        return candidates.filter { candidate in
            guard let entryID = candidate.entryID else { return true }
            return seenEntries.insert(entryID).inserted
        }.prefix(MorphologyCandidate.maximumRetained).map { $0 }
    }

    // MARK: - lazy open

    private func openReader() throws -> any DatabaseReader {
        switch backend {
        case let .reader(reader, _):
            return reader
        case let .lazyURL(url):
            lock.lock()
            defer { lock.unlock() }
            if let queue { return queue }
            var configuration = Configuration()
            configuration.readonly = true
            configuration.label = "Oboe morphology resolver"
            let queue: DatabaseQueue
            do {
                queue = try DatabaseQueue(path: url.path, configuration: configuration)
            } catch {
                throw DictionaryError.unavailable("\(error)")
            }
            do {
                try queue.read { db in
                    try Self.validateSchema(db: db)
                    let values = try Self.readMetadataValues(db: db)
                    guard values["schema_version"] == "1" else {
                        throw DictionaryError.incompatibleSchema(found: values["schema_version"])
                    }
                    let dataset = values["dataset_version"] ?? values["dictionary_version"]
                    guard let dataset, !dataset.isEmpty else {
                        throw DictionaryError.incompatibleSchema(found: values["schema_version"])
                    }
                    cachedDatasetVersion = dataset
                }
            } catch {
                try? queue.close()
                throw error
            }
            self.queue = queue
            return queue
        }
    }

    private static func validateSchema(db: Database) throws {
        let required = [
            "entries", "forms", "readings", "senses", "sense_pos",
            "dictionary_metadata",
        ]
        for table in required where try !db.tableExists(table) {
            throw DictionaryError.incompatibleSchema(found: nil)
        }
    }

    private static func readMetadataValues(db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM dictionary_metadata")
        var values: [String: String] = [:]
        for row in rows { values[row["key"]] = row["value"] }
        return values
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw MorphologyError.cancelled }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
