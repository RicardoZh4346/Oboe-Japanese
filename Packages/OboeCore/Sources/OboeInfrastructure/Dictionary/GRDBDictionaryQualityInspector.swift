import Foundation
import GRDB
import OboeDomain

/// S19 词典质量/元数据层（GRDB 只读实现）。
///
/// 与 `GRDBDictionaryRepository` 同纪律：自带只读 `DatabaseQueue`
/// （`Configuration.readonly = true`、lazy open、schema_version == "1"
/// 与 dataset_version 非空校验）。**不向词典库写任何字节**——
/// 覆盖率/拒绝报告与 checksum 都是纯读路径。
///
/// - `audit`：中文覆盖（entry/sense 级 zho gloss 有无，与 metadata
///   构建端口径并列透出）+ rejected 分类（产物中不可被检索/释义
///   链路消费的条目，样本有界）；
/// - `artifactDescriptor`：metadata + `ReaderHashing.digestFile`
///   流式 SHA-256——v22 `dictionary_artifact_records` 的写入输入；
/// - `DictionaryTieredLookup`：层级匹配的查找实现（forms/readings
///   通道分离，deinflected 段批量 IN-chunk，命中按 (rank,id) 排序
///   且 entry 去重）。
public final class GRDBDictionaryQualityInspector: DictionaryTieredLookup,
    @unchecked Sendable {

    /// 审计规则版本——`DictionaryQualityReport.auditVersion`。
    public static let auditVersion = "s19-audit-1"
    private static let inChunkSize = 400
    private static let rankNullSentinel = Int(Int32.max)

    private enum Backend {
        case lazyURL(URL)
        case reader(any DatabaseReader, datasetVersion: String)
    }

    private let backend: Backend
    private let lock = NSLock()
    private var queue: DatabaseQueue?
    private var cachedDatasetVersion: String?

    /// 生产入口：词典文件路径（lazy open——构造不触碰文件）。
    public init(databaseURL: URL) {
        backend = .lazyURL(databaseURL)
    }

    /// 测试入口：注入任意 DatabaseReader（内存库/计数池）。
    /// 该入口下 `artifactDescriptor` 不可用（无文件可摘要）。
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

    // MARK: - 产物描述（版本 + checksum）

    /// 文件级描述：`dictionary_metadata` 全集 + 流式 SHA-256。
    /// 只有 `databaseURL` 构造的实例可用。
    public func artifactDescriptor() async throws -> DictionaryArtifactDescriptor {
        guard case let .lazyURL(url) = backend else {
            throw DictionaryError.unavailable(
                "artifactDescriptor requires a file-backed inspector")
        }
        let digest = try ReaderHashing.digestFile(at: url)
        let metadata = try await self.metadata()
        return DictionaryArtifactDescriptor(
            fileSHA256: digest.sha256,
            byteCount: digest.byteCount,
            schemaVersion: metadata.schemaVersion,
            datasetVersion: metadata.datasetVersion,
            dictionaryVersion: metadata.dictionaryVersion,
            chineseLayerVersion: metadata.chineseLayerVersion,
            zhAlignmentRate: metadata.zhAlignmentRate
        )
    }

    /// 词典 metadata（复用只读连接；与 repository 同校验）。
    public func metadata() async throws -> DictionaryMetadata {
        let reader = try openReader()
        return try await reader.read { db in
            Self.makeMetadata(try Self.readMetadataValues(db: db))
        }
    }

    // MARK: - 质量审计

    /// 全量审计：中文覆盖 + rejected 分类。只读；样本截断至
    /// `DictionaryQualityReport.sampleLimit`。
    public func audit() async throws -> DictionaryQualityReport {
        let reader = try openReader()
        let datasetVersion = try await currentDatasetVersion()
        return try await reader.read { db in
            try Self.checkCancellation()
            let values = try Self.readMetadataValues(db: db)
            let metadata = Self.makeMetadata(values)

            // —— 中文覆盖（entry/sense/gloss 三口径）——
            let coverage = ChineseCoverageStats(
                entryCount: metadata.entryCount,
                entriesWithChinese: try Self.entryCountWithLanguage(
                    db, language: DictionaryGlossLanguage.chinese),
                senseCount: metadata.senseCount,
                sensesWithChinese: try Self.senseCountWithLanguage(
                    db, language: DictionaryGlossLanguage.chinese),
                zhGlossCount: try Self.glossCount(
                    db, language: DictionaryGlossLanguage.chinese),
                engGlossCount: try Self.glossCount(
                    db, language: DictionaryGlossLanguage.english)
            )

            try Self.checkCancellation()

            // —— rejected 分类（样本 = 升序 entry_id 前 N 条）——
            var rejections: [RejectedEntryClass] = []
            let limit = DictionaryQualityReport.sampleLimit
            func classify(
                _ reason: DictionaryRejectionReason,
                sql: String
            ) throws {
                let ids = try Int64.fetchAll(
                    db, sql: sql + " ORDER BY entry_id LIMIT \(limit)")
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM (\(sql))") ?? 0
                rejections.append(RejectedEntryClass(
                    reason: reason, count: count, sampleEntryIDs: ids))
            }

            try classify(.entryWithoutForms, sql: """
                SELECT e.id AS entry_id FROM entries e
                WHERE NOT EXISTS(SELECT 1 FROM forms f
                                 WHERE f.entry_id = e.id)
                """)
            try classify(.entryWithoutReadings, sql: """
                SELECT e.id AS entry_id FROM entries e
                WHERE NOT EXISTS(SELECT 1 FROM readings r
                                 WHERE r.entry_id = e.id)
                """)
            try classify(.entryWithoutSenses, sql: """
                SELECT e.id AS entry_id FROM entries e
                WHERE NOT EXISTS(SELECT 1 FROM senses s
                                 WHERE s.entry_id = e.id)
                """)
            try classify(.entryWithoutGlosses, sql: """
                SELECT e.id AS entry_id FROM entries e
                WHERE EXISTS(SELECT 1 FROM senses s
                             WHERE s.entry_id = e.id)
                  AND NOT EXISTS(
                      SELECT 1 FROM senses s
                      JOIN glosses g ON g.sense_id = s.id
                      WHERE s.entry_id = e.id)
                """)
            try classify(.unsearchableForms, sql: """
                SELECT e.id AS entry_id FROM entries e
                WHERE EXISTS(SELECT 1 FROM forms f
                             WHERE f.entry_id = e.id)
                  AND NOT EXISTS(
                      SELECT 1 FROM forms f
                      WHERE f.entry_id = e.id
                        AND length(f.normalized_text) > 0)
                """)
            // 孤儿行：FK 指向不存在 entry 的 forms/readings/senses。
            // count 按行数（样本列去重后的 entry_id）。
            let orphanRows = try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM forms f
                        WHERE NOT EXISTS(SELECT 1 FROM entries e
                                         WHERE e.id = f.entry_id))
                     + (SELECT COUNT(*) FROM readings r
                        WHERE NOT EXISTS(SELECT 1 FROM entries e
                                         WHERE e.id = r.entry_id))
                     + (SELECT COUNT(*) FROM senses s
                        WHERE NOT EXISTS(SELECT 1 FROM entries e
                                         WHERE e.id = s.entry_id))
                """) ?? 0
            let orphanSamples = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT entry_id FROM (
                    SELECT entry_id FROM forms f
                    WHERE NOT EXISTS(SELECT 1 FROM entries e
                                     WHERE e.id = f.entry_id)
                    UNION ALL
                    SELECT entry_id FROM readings r
                    WHERE NOT EXISTS(SELECT 1 FROM entries e
                                     WHERE e.id = r.entry_id)
                    UNION ALL
                    SELECT entry_id FROM senses s
                    WHERE NOT EXISTS(SELECT 1 FROM entries e
                                     WHERE e.id = s.entry_id)
                ) ORDER BY entry_id LIMIT \(limit)
                """)
            rejections.append(RejectedEntryClass(
                reason: .orphanedRows,
                count: orphanRows,
                sampleEntryIDs: orphanSamples))

            return DictionaryQualityReport(
                datasetVersion: datasetVersion,
                dictionaryVersion: metadata.dictionaryVersion,
                chineseCoverage: coverage,
                declaredZhEntriesAligned: Int(
                    values["zh_entries_aligned"] ?? ""),
                declaredZhAlignmentRate: metadata.zhAlignmentRate,
                rejections: rejections,
                auditVersion: Self.auditVersion
            )
        }
    }

    // MARK: - DictionaryTieredLookup

    /// `forms.normalized_text == key`：命中按 (rank, entryID) 升序，
    /// 同 entry 只保留首个命中表面。
    public func formMatches(normalizedKey: String) async throws
        -> [TieredEntryMatch] {
        guard !normalizedKey.isEmpty else { return [] }
        let reader = try openReader()
        return try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.entry_id, f.text, e.common_rank
                    FROM forms f JOIN entries e ON e.id = f.entry_id
                    WHERE f.normalized_text = ?
                    """,
                arguments: [normalizedKey])
            return Self.sortedDedupedMatches(rows)
        }
    }

    /// `readings.normalized_reading == key`：同 formMatches 排序口径。
    public func readingMatches(normalizedKey: String) async throws
        -> [TieredEntryMatch] {
        guard !normalizedKey.isEmpty else { return [] }
        let reader = try openReader()
        return try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.entry_id, r.reading, e.common_rank
                    FROM readings r JOIN entries e ON e.id = r.entry_id
                    WHERE r.normalized_reading = ?
                    """,
                arguments: [normalizedKey])
            return Self.sortedDedupedMatches(rows)
        }
    }

    /// deinflected 段：一批 lemma key 的双通道命中。一次 read 内
    /// IN-chunk 取完 forms+readings，再按 key 归组（不逐 key SQL）。
    public func lemmaMatches(
        normalizedKeys: [String]
    ) async throws -> [String: [TieredEntryMatch]] {
        let keys = Array(Set(normalizedKeys.filter { !$0.isEmpty })).sorted()
        guard !keys.isEmpty else { return [:] }
        let reader = try openReader()
        return try await reader.read { db in
            var formRows: [Row] = []
            var readingRows: [Row] = []
            for chunk in keys.chunked(Self.inChunkSize) {
                let p = Self.placeholders(chunk.count)
                let args = StatementArguments(Array(chunk))
                formRows += try Row.fetchAll(
                    db,
                    sql: """
                        SELECT f.normalized_text AS key,
                               f.entry_id, f.text, e.common_rank
                        FROM forms f JOIN entries e ON e.id = f.entry_id
                        WHERE f.normalized_text IN (\(p))
                        """,
                    arguments: args)
                readingRows += try Row.fetchAll(
                    db,
                    sql: """
                        SELECT r.normalized_reading AS key,
                               r.entry_id, r.reading, e.common_rank
                        FROM readings r JOIN entries e ON e.id = r.entry_id
                        WHERE r.normalized_reading IN (\(p))
                        """,
                    arguments: args)
            }
            var result: [String: [TieredEntryMatch]] = [:]
            var grouped: [String: [Row]] = [:]
            for row in formRows + readingRows {
                grouped[row["key"], default: []].append(row)
            }
            for (key, rows) in grouped {
                result[key] = Self.sortedDedupedMatches(rows)
            }
            return result
        }
    }

    /// entry 表面集合（sourceContext 验证 + 层内读音消歧）。
    public func entrySurfaces(
        entryIDs: [Int64]
    ) async throws -> [Int64: DictionaryEntrySurface] {
        let unique = Array(Set(entryIDs)).sorted()
        guard !unique.isEmpty else { return [:] }
        let reader = try openReader()
        return try await reader.read { db in
            var result: [Int64: DictionaryEntrySurface] = [:]
            for chunk in unique.chunked(Self.inChunkSize) {
                let p = Self.placeholders(chunk.count)
                let args = StatementArguments(Array(chunk))
                var primary: [Int64: String] = [:]
                var forms: [Int64: Set<String>] = [:]
                var readings: [Int64: Set<String>] = [:]
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, primary_form FROM entries
                        WHERE id IN (\(p))
                        """,
                    arguments: args) {
                    primary[row["id"]] = row["primary_form"]
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, normalized_text FROM forms
                        WHERE entry_id IN (\(p))
                        """,
                    arguments: args) {
                    forms[row["entry_id"], default: []]
                        .insert(row["normalized_text"])
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, normalized_reading FROM readings
                        WHERE entry_id IN (\(p))
                        """,
                    arguments: args) {
                    readings[row["entry_id"], default: []]
                        .insert(row["normalized_reading"])
                }
                for entryID in chunk {
                    guard let primaryForm = primary[entryID] else { continue }
                    result[entryID] = DictionaryEntrySurface(
                        entryID: entryID,
                        primaryForm: primaryForm,
                        normalizedForms: forms[entryID] ?? [],
                        normalizedReadings: readings[entryID] ?? []
                    )
                }
            }
            return result
        }
    }

    public func datasetVersion() async throws -> String? {
        if case let .reader(_, version) = backend { return version }
        return try await currentDatasetVersion()
    }

    // MARK: - 内部

    private static func sortedDedupedMatches(_ rows: [Row])
        -> [TieredEntryMatch] {
        var byEntry: [Int64: TieredEntryMatch] = [:]
        for row in rows {
            let entryID: Int64 = row["entry_id"]
            let surface: String = row["text"] ?? row["reading"] ?? ""
            let rank: Int? = row["common_rank"]
            if let existing = byEntry[entryID] {
                // 同 entry 保留更小 rank/更前表面（确定性）。
                let better = (rank ?? rankNullSentinel, surface)
                    < (existing.commonRank ?? rankNullSentinel,
                       existing.matchedSurface)
                if !better { continue }
            }
            byEntry[entryID] = TieredEntryMatch(
                entryID: entryID, matchedSurface: surface,
                commonRank: rank)
        }
        return byEntry.values.sorted {
            ($0.commonRank ?? rankNullSentinel, $0.entryID)
                < ($1.commonRank ?? rankNullSentinel, $1.entryID)
        }
    }

    private func currentDatasetVersion() async throws -> String {
        if case let .reader(_, version) = backend { return version }
        let reader = try openReader()
        if let cached = lock.withLock({ cachedDatasetVersion }) {
            return cached
        }
        let version = try await reader.read { db in
            let values = try Self.readMetadataValues(db: db)
            return values["dataset_version"]
                ?? values["dictionary_version"] ?? ""
        }
        lock.withLock { cachedDatasetVersion = version }
        return version
    }

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
            configuration.label = "Oboe dictionary quality inspector"
            let queue: DatabaseQueue
            do {
                queue = try DatabaseQueue(
                    path: url.path, configuration: configuration)
            } catch {
                throw DictionaryError.unavailable("\(error)")
            }
            do {
                try queue.read { db in
                    try Self.validateSchema(db: db)
                    let values = try Self.readMetadataValues(db: db)
                    guard values["schema_version"] == "1" else {
                        throw DictionaryError.incompatibleSchema(
                            found: values["schema_version"])
                    }
                    let dataset = values["dataset_version"]
                        ?? values["dictionary_version"]
                    guard let dataset, !dataset.isEmpty else {
                        throw DictionaryError.incompatibleSchema(
                            found: values["schema_version"])
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
            "entries", "forms", "readings", "senses", "glosses",
            "dictionary_metadata",
        ]
        for table in required where try !db.tableExists(table) {
            throw DictionaryError.incompatibleSchema(found: nil)
        }
    }

    private static func readMetadataValues(db: Database) throws
        -> [String: String] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT key, value FROM dictionary_metadata")
        var values: [String: String] = [:]
        for row in rows { values[row["key"]] = row["value"] }
        return values
    }

    private static func makeMetadata(_ values: [String: String])
        -> DictionaryMetadata {
        func int(_ key: String) -> Int { Int(values[key] ?? "") ?? 0 }
        return DictionaryMetadata(
            schemaVersion: values["schema_version"] ?? "",
            datasetVersion: values["dataset_version"]
                ?? values["dictionary_version"] ?? "",
            dictionaryVersion: values["dictionary_version"] ?? "",
            builtAt: values["built_at"],
            entryCount: int("entry_count"),
            formCount: int("form_count"),
            readingCount: int("reading_count"),
            senseCount: int("sense_count"),
            glossCount: int("gloss_count"),
            licenseRevision: values["license_revision"],
            jmdictSourceVersion: values["jmdict_source_version"],
            jmdictSourceSHA256: values["jmdict_source_sha256"],
            chineseLayerVersion: values["chinese_layer_version"],
            normalizer: values["normalizer"],
            zhAlignmentRate: Double(values["zh_alignment_rate"] ?? ""),
            rawValues: values
        )
    }

    private static func entryCountWithLanguage(
        _ db: Database, language: String
    ) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM entries e
            WHERE EXISTS(
                SELECT 1 FROM senses s
                JOIN glosses g ON g.sense_id = s.id
                WHERE s.entry_id = e.id AND g.language = ?)
            """, arguments: [language]) ?? 0
    }

    private static func senseCountWithLanguage(
        _ db: Database, language: String
    ) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM senses s
            WHERE EXISTS(
                SELECT 1 FROM glosses g
                WHERE g.sense_id = s.id AND g.language = ?)
            """, arguments: [language]) ?? 0
    }

    private static func glossCount(
        _ db: Database, language: String
    ) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM glosses WHERE language = ?",
            arguments: [language]) ?? 0
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
