import Foundation
import GRDB
import OboeDomain

/// GRDB 实现的只读词典仓储（S06 / 技术文档 §4.3、§4.4、冻结协议 §2.6）。
///
/// - **只读**：`Configuration.readonly = true`，不写、不开 WAL；
/// - **lazy open**：init 只存 URL，首个调用才打开并校验
///   `dictionary_metadata`（`schema_version == "1"` 且
///   `dataset_version`/`dictionary_version` 非空，否则抛
///   `DictionaryError.incompatibleSchema`——可恢复错误，不崩溃）；
///   NSLock 保护，并发首次访问只打开一次；
/// - **搜索页序**（§4.4）：规范化精确（按 common_rank、entryID）→
///   变形候选精确（按 common_rank、候选 cost、entryID）→ 规范化前缀
///   （`(normalized, entryID)` BINARY keyset，`> q AND < 上界` 走
///   `idx_forms_normalized`/`idx_readings_normalized`）；
/// - **去重**：同一 entry 跨通道/跨表面/跨候选只在首个命中位置出现一次，
///   跨页不重不漏——前缀阶段以"该 entry 最小匹配 normalized = 首个命中
///   位置"判定，叠加确定性的 exact/deinflected 命中集合跳过；
/// - **游标失配**：`datasetVersion` 或格式版本不符时按 nil 处理，
///   重新从第一页查（冻结协议："版本变化后重新从第一页查询"）。
public final class GRDBDictionaryRepository: DictionaryRepository, @unchecked Sendable {
    /// IN 列表分块（规避 SQLite 变量上限）
    private static let inChunkSize = 400
    /// 每通道每次 keyset 取数窗口
    private static let channelFetchSize = 128
    /// common_rank NULL 参与排序时的哨兵（排最后）
    private static let rankNullSentinel = Int(Int32.max)

    private let databaseURL: URL
    private let lock = NSLock()
    private var queue: DatabaseQueue?
    private var cachedDatasetVersion: String?

    /// lazy open：构造不读写文件、不校验；兼容性以首次调用结果为准。
    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    deinit {
        lock.lock()
        let queue = self.queue
        self.queue = nil
        lock.unlock()
        try? queue?.close()
    }

    // MARK: - DictionaryRepository

    public func metadata() async throws -> DictionaryMetadata {
        let queue = try openQueue()
        return try await queue.read { db in
            Self.makeMetadata(try Self.readMetadataValues(db: db))
        }
    }

    public func search(_ request: DictionarySearchRequest) async throws -> DictionarySearchPage {
        let queue = try openQueue()
        let datasetVersion = currentDatasetVersion()
        let normalized = request.normalizedQuery
        guard !normalized.isEmpty else {
            // 防空查询全库扫描（§4.4）
            return DictionarySearchPage(
                items: [],
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: normalized
            )
        }
        // 游标校验：格式/词典版本失配一律回第一页（不崩溃、不报错）。
        let cursor: DictionarySearchCursor?
        if let c = request.cursor,
           c.formatVersion == 1, c.datasetVersion == datasetVersion {
            cursor = c
        } else {
            cursor = nil
        }
        return try await queue.read { db in
            var engine = SearchEngine(
                db: db,
                query: normalized,
                rawQuery: request.query,
                candidates: request.candidates,
                datasetVersion: datasetVersion
            )
            return try engine.page(limit: request.limit, cursor: cursor)
        }
    }

    public func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
        let queue = try openQueue()
        // 保序去重：按输入顺序返回存在的词条，重复 id 只返回一次。
        var seen = Set<Int64>()
        let orderedIDs = ids.filter { seen.insert($0).inserted }
        guard !orderedIDs.isEmpty else { return [] }
        return try await queue.read { db in
            try Self.fetchEntries(db: db, ids: orderedIDs)
        }
    }

    public func entry(id: Int64) async throws -> DictionaryEntry? {
        try await entries(ids: [id]).first
    }

    public func sources() async throws -> [DictionarySourceInfo] {
        let queue = try openQueue()
        return try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source_id, source_name, source_version, source_url,
                           license, license_url, retrieved_at, sha256, input_bytes,
                           attribution, consumed_tables_json, modifications
                    FROM dictionary_sources
                    ORDER BY source_id
                    """
            )
            return rows.map { row in
                let tablesJSON: String = row["consumed_tables_json"]
                let tables = (try? JSONDecoder().decode(
                    [String].self,
                    from: Data(tablesJSON.utf8)
                )) ?? []
                return DictionarySourceInfo(
                    id: row["source_id"],
                    name: row["source_name"],
                    version: row["source_version"],
                    url: row["source_url"],
                    license: row["license"],
                    licenseURL: row["license_url"],
                    retrievedAt: row["retrieved_at"],
                    sha256: row["sha256"],
                    inputBytes: row["input_bytes"],
                    attribution: row["attribution"],
                    consumedTables: tables,
                    modifications: row["modifications"]
                )
            }
        }
    }

    // MARK: - lazy open + 版本校验

    /// 线程安全惰性打开：首个调用建只读连接并做 schema 校验。
    /// 校验失败即关闭连接抛错，不缓存坏库（下次调用重试同样的错误）。
    private func openQueue() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue { return queue }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "Oboe built-in dictionary"
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
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

    /// 打开后的当前 dataset_version（openQueue 成功后必有值）。
    private func currentDatasetVersion() -> String {
        lock.lock()
        defer { lock.unlock() }
        return cachedDatasetVersion ?? ""
    }

    /// 必需表探测（缺一即视为不兼容 schema）。
    private static func validateSchema(db: Database) throws {
        let required = [
            "entries", "forms", "readings", "senses", "glosses",
            "sense_pos", "sense_tags", "dictionary_metadata",
            "dictionary_sources",
        ]
        for table in required where try !db.tableExists(table) {
            throw DictionaryError.incompatibleSchema(found: nil)
        }
    }

    private static func readMetadataValues(db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT key, value FROM dictionary_metadata"
        )
        var values: [String: String] = [:]
        for row in rows {
            values[row["key"]] = row["value"]
        }
        return values
    }

    private static func makeMetadata(_ values: [String: String]) -> DictionaryMetadata {
        func int(_ key: String) -> Int { Int(values[key] ?? "") ?? 0 }
        return DictionaryMetadata(
            schemaVersion: values["schema_version"] ?? "",
            datasetVersion: values["dataset_version"] ?? values["dictionary_version"] ?? "",
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

    // MARK: - 详情聚合

    /// 批量聚合 entry 详情。按 `ids` 输入顺序返回，缺失 id 跳过。
    private static func fetchEntries(db: Database, ids: [Int64]) throws -> [DictionaryEntry] {
        var base: [Int64: (primaryForm: String, commonRank: Int?)] = [:]
        var formsByEntry: [Int64: [DictionaryForm]] = [:]
        var formTextByID: [Int64: String] = [:]
        var readingIDsByEntry: [Int64: [Int64]] = [:]
        var readingTextByID: [Int64: String] = [:]
        var readingNoKanji: [Int64: Bool] = [:]
        var readingRestrictedFormIDs: [Int64: [Int64]] = [:]
        var senseIDsByEntry: [Int64: [(id: Int64, order: Int)]] = [:]
        var posBySense: [Int64: [String]] = [:]
        var tagsBySense: [Int64: [DictionarySenseTag]] = [:]
        var glossesBySense: [Int64: [DictionaryGloss]] = [:]
        var senseRestrictedFormIDs: [Int64: [Int64]] = [:]
        var senseRestrictedReadingIDs: [Int64: [Int64]] = [:]
        var overlaysByEntry: [Int64: [DictionaryEntryOverlay]] = [:]

        for chunk in ids.chunked(inChunkSize) {
            let p = placeholders(chunk.count)
            let args = StatementArguments(chunk)

            for row in try Row.fetchAll(
                db,
                sql: "SELECT id, primary_form, common_rank FROM entries WHERE id IN (\(p))",
                arguments: args
            ) {
                base[row["id"]] = (row["primary_form"], row["common_rank"])
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT id, entry_id, text, form_type, priority
                    FROM forms WHERE entry_id IN (\(p)) ORDER BY id
                    """,
                arguments: args
            ) {
                let formID: Int64 = row["id"]
                let text: String = row["text"]
                formTextByID[formID] = text
                formsByEntry[row["entry_id"], default: []].append(
                    DictionaryForm(
                        id: formID,
                        text: text,
                        formType: row["form_type"],
                        priority: row["priority"]
                    )
                )
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT id, entry_id, reading, no_kanji
                    FROM readings WHERE entry_id IN (\(p)) ORDER BY id
                    """,
                arguments: args
            ) {
                let readingID: Int64 = row["id"]
                let entryID: Int64 = row["entry_id"]
                let noKanji: Int = row["no_kanji"]
                readingTextByID[readingID] = row["reading"]
                readingNoKanji[readingID] = noKanji != 0
                readingIDsByEntry[entryID, default: []].append(readingID)
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT rfr.reading_id, rfr.form_id
                    FROM reading_form_restrictions rfr
                    JOIN readings r ON r.id = rfr.reading_id
                    WHERE r.entry_id IN (\(p)) ORDER BY rfr.reading_id, rfr.form_id
                    """,
                arguments: args
            ) {
                readingRestrictedFormIDs[row["reading_id"], default: []].append(row["form_id"])
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT id, entry_id, sense_order
                    FROM senses WHERE entry_id IN (\(p))
                    ORDER BY entry_id, sense_order
                    """,
                arguments: args
            ) {
                senseIDsByEntry[row["entry_id"], default: []].append(
                    (id: row["id"], order: row["sense_order"])
                )
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT sp.sense_id, sp.code
                    FROM sense_pos sp JOIN senses s ON s.id = sp.sense_id
                    WHERE s.entry_id IN (\(p)) ORDER BY sp.sense_id, sp.code
                    """,
                arguments: args
            ) {
                posBySense[row["sense_id"], default: []].append(row["code"])
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT st.sense_id, st.category, st.code
                    FROM sense_tags st JOIN senses s ON s.id = st.sense_id
                    WHERE s.entry_id IN (\(p))
                    ORDER BY st.sense_id, st.category, st.code
                    """,
                arguments: args
            ) {
                tagsBySense[row["sense_id"], default: []].append(
                    DictionarySenseTag(category: row["category"], code: row["code"])
                )
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT g.sense_id, g.language, g.text, g.gloss_order,
                           g.source_id, g.is_machine_generated, g.source_fingerprint
                    FROM glosses g JOIN senses s ON s.id = g.sense_id
                    WHERE s.entry_id IN (\(p))
                    ORDER BY g.sense_id, g.gloss_order
                    """,
                arguments: args
            ) {
                let generated: Int = row["is_machine_generated"]
                glossesBySense[row["sense_id"], default: []].append(
                    DictionaryGloss(
                        language: row["language"],
                        text: row["text"],
                        order: row["gloss_order"],
                        sourceID: row["source_id"],
                        isMachineGenerated: generated != 0,
                        sourceFingerprint: row["source_fingerprint"]
                    )
                )
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT sfr.sense_id, sfr.form_id
                    FROM sense_form_restrictions sfr
                    JOIN senses s ON s.id = sfr.sense_id
                    WHERE s.entry_id IN (\(p)) ORDER BY sfr.sense_id, sfr.form_id
                    """,
                arguments: args
            ) {
                senseRestrictedFormIDs[row["sense_id"], default: []].append(row["form_id"])
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT srr.sense_id, srr.reading_id
                    FROM sense_reading_restrictions srr
                    JOIN senses s ON s.id = srr.sense_id
                    WHERE s.entry_id IN (\(p)) ORDER BY srr.sense_id, srr.reading_id
                    """,
                arguments: args
            ) {
                senseRestrictedReadingIDs[row["sense_id"], default: []].append(row["reading_id"])
            }
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT entry_id, language, text, source_id
                    FROM entry_gloss_overlays WHERE entry_id IN (\(p))
                    ORDER BY entry_id, language
                    """,
                arguments: args
            ) {
                overlaysByEntry[row["entry_id"], default: []].append(
                    DictionaryEntryOverlay(
                        language: row["language"],
                        text: row["text"],
                        sourceID: row["source_id"]
                    )
                )
            }
        }

        var readingsByEntry: [Int64: [DictionaryReading]] = [:]
        for (entryID, readingIDs) in readingIDsByEntry {
            readingsByEntry[entryID] = readingIDs.map { readingID in
                let formIDs = readingRestrictedFormIDs[readingID] ?? []
                return DictionaryReading(
                    id: readingID,
                    reading: readingTextByID[readingID] ?? "",
                    noKanji: readingNoKanji[readingID] ?? false,
                    restrictedFormIDs: formIDs,
                    restrictedForms: formIDs.compactMap { formTextByID[$0] }
                )
            }
        }

        return ids.compactMap { entryID in
            guard let info = base[entryID] else { return nil }
            let senses = (senseIDsByEntry[entryID] ?? []).map { sense in
                let formIDs = senseRestrictedFormIDs[sense.id] ?? []
                let restrictedReadingIDs = senseRestrictedReadingIDs[sense.id] ?? []
                return DictionarySense(
                    id: sense.id,
                    order: sense.order,
                    posCodes: posBySense[sense.id] ?? [],
                    tags: tagsBySense[sense.id] ?? [],
                    glosses: glossesBySense[sense.id] ?? [],
                    restrictedFormIDs: formIDs,
                    restrictedForms: formIDs.compactMap { formTextByID[$0] },
                    restrictedReadingIDs: restrictedReadingIDs,
                    restrictedReadings: restrictedReadingIDs.compactMap { readingTextByID[$0] }
                )
            }
            return DictionaryEntry(
                id: entryID,
                primaryForm: info.primaryForm,
                commonRank: info.commonRank,
                forms: formsByEntry[entryID] ?? [],
                readings: readingsByEntry[entryID] ?? [],
                senses: senses,
                overlayGlosses: overlaysByEntry[entryID] ?? []
            )
        }
    }

    // MARK: - 静态工具

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    // MARK: - 搜索引擎（单次 search 调用的私有状态机）

    /// 一次 `search` 的全部状态：双通道拉取游标、entry 信息缓存、
    /// 确定性的 exact/deinflected 命中集合。只在单个 `db.read` 内活动。
    private struct SearchEngine {
        let db: Database
        /// normalizedQuery
        let query: String
        /// 原始输入（判定 .exact vs .normalized）
        let rawQuery: String
        let candidates: [DeinflectionCandidate]
        let datasetVersion: String
        /// normalized > query 且 < prefixUpper（nil = 无上界）
        let prefixUpper: String?

        /// 逐 entry 信息缓存（normalized 表面、rank）
        var infoCache: [Int64: EntryInfo] = [:]
        var cachedExactIDs: Set<Int64>?
        var cachedDeinflected: (list: [DictionaryHit], ids: Set<Int64>)?

        init(
            db: Database,
            query: String,
            rawQuery: String,
            candidates: [DeinflectionCandidate],
            datasetVersion: String
        ) {
            self.db = db
            self.query = query
            self.rawQuery = rawQuery
            self.candidates = candidates
            self.datasetVersion = datasetVersion
            self.prefixUpper = Self.prefixUpperBound(of: query)
        }

        /// 通道行：统一携带两种排序键字段（phase 0 用 rank，phase 2 用 normalized）。
        struct ChannelRow {
            var normalized: String
            var rank: Int
            var entryID: Int64
            var surface: String
            var channel: DictionaryMatchChannel
        }

        /// 双通道各自独立 keyset 拉取状态（`bound` = 最后消费行）。
        struct ChannelState {
            var rows: [ChannelRow] = []
            var index = 0
            var bound: DictionarySearchCursor.KeysetBound?
            /// 「最近一次取数不满窗口」——缓冲区清空后不必再查 DB
            var exhausted = false

            /// 写进游标的耗尽语义：缓冲已消费完 **且** DB 侧无更多行。
            /// 注意必须要求 index 越过缓冲末尾——页末丢弃未消费的缓冲行
            /// 是安全的（它们都在 bound 之后，下一页会按 keyset 重新取回），
            /// 但若此时 exhausted=true 会让续页完全跳过该通道丢数据。
            var isDrained: Bool {
                exhausted && index >= rows.count
            }

            mutating func peek(
                engine: inout SearchEngine,
                phase: Int,
                channel: DictionaryMatchChannel
            ) throws -> ChannelRow? {
                if index >= rows.count {
                    guard !exhausted else { return nil }
                    rows = try engine.fetchChannel(channel: channel, phase: phase, bound: bound)
                    index = 0
                    if rows.count < GRDBDictionaryRepository.channelFetchSize {
                        exhausted = true
                    }
                    if rows.isEmpty { return nil }
                    // 预取本批 entry 的 normalized 表面信息（首个命中位置判定用）
                    try engine.prefetchEntryInfos(rows.map(\.entryID))
                }
                return rows[index]
            }

            /// 消费当前 peek 行：推进 keyset 位置与缓冲下标。
            mutating func advance() {
                guard index < rows.count else { return }
                let row = rows[index]
                bound = DictionarySearchCursor.KeysetBound(
                    normalized: row.normalized,
                    rank: row.rank,
                    entryID: row.entryID
                )
                index += 1
            }
        }

        /// entry 最小信息：首个命中位置判定 + 匹配表面收集 + rank。
        struct EntryInfo {
            var rank: Int?
            var forms: [(normalized: String, surface: String)] = []
            var readings: [(normalized: String, surface: String)] = []

            /// 前缀区间内最小的匹配 normalized（BINARY 序）；无匹配为 nil。
            func minPrefixNormalized(query: String, upper: String?) -> String? {
                var best: String?
                for pair in forms + readings
                where SearchEngine.isInPrefixRange(pair.normalized, query: query, upper: upper) {
                    if let current = best {
                        if SearchEngine.binaryLessThan(pair.normalized, current) {
                            best = pair.normalized
                        }
                    } else {
                        best = pair.normalized
                    }
                }
                return best
            }

            /// 全部前缀匹配表面，按 (normalized, channel[form先], surface) 排序。
            func prefixMatchingSurfaces(
                query: String,
                upper: String?
            ) -> [(normalized: String, surface: String, channel: DictionaryMatchChannel)] {
                var result: [(String, String, DictionaryMatchChannel)] = []
                for pair in forms
                where SearchEngine.isInPrefixRange(pair.normalized, query: query, upper: upper) {
                    result.append((pair.normalized, pair.surface, .form))
                }
                for pair in readings
                where SearchEngine.isInPrefixRange(pair.normalized, query: query, upper: upper) {
                    result.append((pair.normalized, pair.surface, .reading))
                }
                result.sort { lhs, rhs in
                    if lhs.0 != rhs.0 {
                        return SearchEngine.binaryLessThan(lhs.0, rhs.0)
                    }
                    if lhs.2 != rhs.2 { return lhs.2 == .form }
                    return SearchEngine.binaryLessThan(lhs.1, rhs.1)
                }
                return result
            }
        }

        // MARK: 页装配

        /// 装配一页；`cursor` 已在上层完成版本校验。
        mutating func page(
            limit: Int,
            cursor: DictionarySearchCursor?
        ) throws -> DictionarySearchPage {
            var items: [DictionaryHit] = []
            var phase = max(0, min(cursor?.phase ?? 0, 2))
            var form = ChannelState()
            var reading = ChannelState()
            var deinflectedOffset = 0
            switch phase {
            case 0, 2:
                form.bound = cursor?.formBound
                reading.bound = cursor?.readingBound
                form.exhausted = cursor?.formExhausted ?? false
                reading.exhausted = cursor?.readingExhausted ?? false
            case 1:
                deinflectedOffset = cursor?.deinflectedOffset ?? 0
            default:
                break
            }

            // Phase 0：规范化精确（合并键 (rank, entryID)，entry 在该键下唯一）
            if phase == 0 {
                while items.count < limit {
                    guard let key = try nextExactKey(form: &form, reading: &reading) else {
                        break
                    }
                    let surfaces = try consumeEqualExactKey(
                        key, form: &form, reading: &reading
                    )
                    items.append(Self.makeExactHit(
                        key: key, surfaces: surfaces,
                        rawQuery: rawQuery, normalizedQuery: query
                    ))
                }
                let exactDone = try form.peek(engine: &self, phase: 0, channel: .form) == nil
                    && reading.peek(engine: &self, phase: 0, channel: .reading) == nil
                if !exactDone {
                    // 精确段未消费完：下一页继续 phase 0
                    return DictionarySearchPage(
                        items: items,
                        nextCursor: DictionarySearchCursor(
                            datasetVersion: datasetVersion,
                            phase: 0,
                            formBound: form.bound,
                            readingBound: reading.bound,
                            formExhausted: form.isDrained,
                            readingExhausted: reading.isDrained
                        ),
                        hasMore: true,
                        normalizedQuery: query
                    )
                }
                phase = 1
            }

            // Phase 1：变形候选精确（确定性排序列表 + offset 分页）
            if phase == 1 {
                let resolved = try deinflectedHits()
                while items.count < limit, deinflectedOffset < resolved.count {
                    items.append(resolved[deinflectedOffset])
                    deinflectedOffset += 1
                }
                if deinflectedOffset < resolved.count {
                    return DictionarySearchPage(
                        items: items,
                        nextCursor: DictionarySearchCursor(
                            datasetVersion: datasetVersion,
                            phase: 1,
                            deinflectedOffset: deinflectedOffset
                        ),
                        hasMore: true,
                        normalizedQuery: query
                    )
                }
                phase = 2
                form = ChannelState()
                reading = ChannelState()
            }

            // Phase 2：规范化前缀（合并键 (normalized, entryID)；
            // entry 只在"最小匹配 normalized"处发射一次）
            if phase == 2 {
                while items.count < limit {
                    guard let key = try nextPrefixKey(form: &form, reading: &reading) else {
                        break
                    }
                    _ = try consumeEqualPrefixKey(key, form: &form, reading: &reading)
                    let entryID = key.entryID
                    if try shouldSkipPrefixHit(entryID: entryID) { continue }
                    let info = entryInfo(entryID)
                    guard info.minPrefixNormalized(query: query, upper: prefixUpper) == key.normalized
                    else {
                        continue // 非首个命中位置：此前已发射过该 entry
                    }
                    items.append(makePrefixHit(entryID: entryID, info: info))
                }
                let more = try form.peek(engine: &self, phase: 2, channel: .form) != nil
                    || reading.peek(engine: &self, phase: 2, channel: .reading) != nil
                return DictionarySearchPage(
                    items: items,
                    nextCursor: more
                        ? DictionarySearchCursor(
                            datasetVersion: datasetVersion,
                            phase: 2,
                            formBound: form.bound,
                            readingBound: reading.bound,
                            formExhausted: form.isDrained,
                            readingExhausted: reading.isDrained
                        )
                        : nil,
                    hasMore: more,
                    normalizedQuery: query
                )
            }

            return DictionarySearchPage(
                items: items,
                nextCursor: nil,
                hasMore: false,
                normalizedQuery: query
            )
        }

        // MARK: phase 0（精确，(rank, entryID) 序）

        private mutating func nextExactKey(
            form: inout ChannelState,
            reading: inout ChannelState
        ) throws -> (rank: Int, entryID: Int64)? {
            let f = try form.peek(engine: &self, phase: 0, channel: .form)
            let r = try reading.peek(engine: &self, phase: 0, channel: .reading)
            switch (f, r) {
            case (nil, nil): return nil
            case let (f?, nil): return (f.rank, f.entryID)
            case let (nil, r?): return (r.rank, r.entryID)
            case let (f?, r?):
                if f.rank != r.rank { return f.rank < r.rank ? (f.rank, f.entryID) : (r.rank, r.entryID) }
                return f.entryID <= r.entryID ? (f.rank, f.entryID) : (r.rank, r.entryID)
            }
        }

        /// 消费两通道中所有排序键等于 key 的行（同 entry 的全部命中表面）。
        private mutating func consumeEqualExactKey(
            _ key: (rank: Int, entryID: Int64),
            form: inout ChannelState,
            reading: inout ChannelState
        ) throws -> [(surface: String, channel: DictionaryMatchChannel)] {
            var surfaces: [(String, DictionaryMatchChannel)] = []
            while let row = try form.peek(engine: &self, phase: 0, channel: .form),
                  row.rank == key.rank, row.entryID == key.entryID {
                surfaces.append((row.surface, .form))
                form.advance()
            }
            while let row = try reading.peek(engine: &self, phase: 0, channel: .reading),
                  row.rank == key.rank, row.entryID == key.entryID {
                surfaces.append((row.surface, .reading))
                reading.advance()
            }
            return surfaces
        }

        private static func makeExactHit(
            key: (rank: Int, entryID: Int64),
            surfaces: [(surface: String, channel: DictionaryMatchChannel)],
            rawQuery: String,
            normalizedQuery: String
        ) -> DictionaryHit {
            // form 通道优先展示，其次按表面文字稳定排序；表面去重。
            let ordered = surfaces.sorted { lhs, rhs in
                if lhs.channel != rhs.channel { return lhs.channel == .form }
                return SearchEngine.binaryLessThan(lhs.surface, rhs.surface)
            }
            var seen = Set<String>()
            let texts = ordered.map(\.surface).filter { seen.insert($0).inserted }
            return DictionaryHit(
                entryID: key.entryID,
                matchedForm: texts.first ?? "",
                matchedNormalized: normalizedQuery,
                matchedSurfaces: texts,
                channel: ordered.first?.channel ?? .form,
                reason: texts.contains(rawQuery) ? .exact : .normalized,
                rank: key.rank == GRDBDictionaryRepository.rankNullSentinel ? nil : key.rank
            )
        }

        // MARK: phase 1（变形候选）

        /// 确定性命中集（已 POS 过滤、去精确段、排序）。同一搜索内缓存。
        private mutating func deinflectedHits() throws -> [DictionaryHit] {
            if let cachedDeinflected { return cachedDeinflected.list }
            let resolved = try resolveDeinflected()
            cachedDeinflected = resolved
            return resolved.list
        }

        private mutating func deinflectedIDSet() throws -> Set<Int64> {
            if let cachedDeinflected { return cachedDeinflected.ids }
            let resolved = try resolveDeinflected()
            cachedDeinflected = resolved
            return resolved.ids
        }

        /// 候选 lemma → 双通道规范化精确命中 → JMdict sense_pos ∩
        /// admissiblePOS 过滤 → 去精确段 → (rank, cost, entryID) 排序。
        /// 同一 entry 取 `candidates` 序列中最靠前的候选（reasonChain/
        /// matchedLemma 透传给 UI 展示变形路径）。
        private mutating func resolveDeinflected() throws -> (list: [DictionaryHit], ids: Set<Int64>) {
            // 规范化 lemma → 保持 Deinflector 输出序（优先级序）的候选分组。
            var lemmaOrder: [String] = []
            var orderedCandidates: [(lemma: String, candidate: DeinflectionCandidate)] = []
            var seenLemmas = Set<String>()
            for candidate in candidates {
                guard !candidate.isTruncationMarker, !candidate.lemma.isEmpty else { continue }
                let lemma = SearchTextNormalizer.normalize(candidate.lemma)
                guard !lemma.isEmpty else { continue }
                if lemma == query, candidate.cost == 0 { continue } // 原形自身归精确段
                orderedCandidates.append((lemma, candidate))
                if seenLemmas.insert(lemma).inserted { lemmaOrder.append(lemma) }
            }
            guard !orderedCandidates.isEmpty else { return ([], []) }

            // 逐 lemma 双通道精确查找（索引 seek；lemma 数 ≤ 候选预算 128）。
            var rowsByLemma: [String: [(entryID: Int64, surface: String, channel: DictionaryMatchChannel)]] = [:]
            for lemma in lemmaOrder {
                var rows: [(Int64, String, DictionaryMatchChannel)] = []
                for row in try Row.fetchAll(
                    db,
                    sql: "SELECT entry_id, text FROM forms WHERE normalized_text = ?",
                    arguments: [lemma]
                ) {
                    rows.append((row["entry_id"], row["text"], .form))
                }
                for row in try Row.fetchAll(
                    db,
                    sql: "SELECT entry_id, reading FROM readings WHERE normalized_reading = ?",
                    arguments: [lemma]
                ) {
                    rows.append((row["entry_id"], row["reading"], .reading))
                }
                rowsByLemma[lemma] = rows
            }

            // entry → 最优候选 + 全部命中表面
            var bestCandidate: [Int64: DeinflectionCandidate] = [:]
            var surfacesByEntry: [Int64: [(String, DictionaryMatchChannel)]] = [:]
            for (lemma, candidate) in orderedCandidates {
                for row in rowsByLemma[lemma] ?? [] {
                    surfacesByEntry[row.entryID, default: []].append((row.surface, row.channel))
                    if bestCandidate[row.entryID] == nil {
                        bestCandidate[row.entryID] = candidate
                    }
                }
            }
            let candidateEntryIDs = Array(bestCandidate.keys)
            guard !candidateEntryIDs.isEmpty else { return ([], []) }

            // POS 交集过滤：entry 全部 sense_pos code 集合 ∩ admissiblePOS ≠ ∅。
            // 无 sense_pos 的 entry 一律被裁掉（粗粒度"动词"标签不足为凭，§5.1）。
            var posByEntry: [Int64: Set<String>] = [:]
            for chunk in candidateEntryIDs.chunked(GRDBDictionaryRepository.inChunkSize) {
                let p = GRDBDictionaryRepository.placeholders(chunk.count)
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT s.entry_id, sp.code
                        FROM senses s JOIN sense_pos sp ON sp.sense_id = s.id
                        WHERE s.entry_id IN (\(p))
                        """,
                    arguments: StatementArguments(chunk)
                ) {
                    posByEntry[row["entry_id"], default: []].insert(row["code"])
                }
            }
            try prefetchEntryInfos(candidateEntryIDs)
            let exact = try exactIDSet()

            var decorated: [(rank: Int, cost: Int, entryID: Int64, candidate: DeinflectionCandidate)] = []
            for entryID in candidateEntryIDs {
                guard let candidate = bestCandidate[entryID] else { continue }
                let entryPOS = posByEntry[entryID] ?? []
                let admissible = Set(candidate.admissiblePOS.map(\.rawValue))
                guard !entryPOS.isDisjoint(with: admissible) else { continue }
                guard !exact.contains(entryID) else { continue }
                let rank = infoCache[entryID]?.rank ?? GRDBDictionaryRepository.rankNullSentinel
                decorated.append((rank, candidate.cost, entryID, candidate))
            }
            decorated.sort { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.cost != rhs.cost { return lhs.cost < rhs.cost }
                return lhs.entryID < rhs.entryID
            }

            var hits: [DictionaryHit] = []
            var ids = Set<Int64>()
            for item in decorated {
                var seen = Set<String>()
                let surfaces = (surfacesByEntry[item.entryID] ?? [])
                    .sorted { lhs, rhs in
                        if lhs.1 != rhs.1 { return lhs.1 == .form }
                        return SearchEngine.binaryLessThan(lhs.0, rhs.0)
                    }
                let texts = surfaces.map(\.0).filter { seen.insert($0).inserted }
                let info = infoCache[item.entryID]
                hits.append(DictionaryHit(
                    entryID: item.entryID,
                    matchedForm: texts.first
                        ?? info?.forms.first?.surface
                        ?? info?.readings.first?.surface
                        ?? "",
                    matchedNormalized: SearchTextNormalizer.normalize(item.candidate.lemma),
                    matchedSurfaces: texts,
                    channel: surfaces.first?.1 ?? .form,
                    reason: .deinflected,
                    reasonChain: item.candidate.reasons,
                    matchedLemma: item.candidate.lemma,
                    rank: item.rank == GRDBDictionaryRepository.rankNullSentinel ? nil : item.rank
                ))
                ids.insert(item.entryID)
            }
            return (hits, ids)
        }

        // MARK: phase 2（前缀，(normalized, entryID) BINARY 序）

        private mutating func nextPrefixKey(
            form: inout ChannelState,
            reading: inout ChannelState
        ) throws -> (normalized: String, entryID: Int64)? {
            let f = try form.peek(engine: &self, phase: 2, channel: .form)
            let r = try reading.peek(engine: &self, phase: 2, channel: .reading)
            switch (f, r) {
            case (nil, nil): return nil
            case let (f?, nil): return (f.normalized, f.entryID)
            case let (nil, r?): return (r.normalized, r.entryID)
            case let (f?, r?):
                if Self.binaryLessThan(f.normalized, r.normalized) { return (f.normalized, f.entryID) }
                if Self.binaryLessThan(r.normalized, f.normalized) { return (r.normalized, r.entryID) }
                return f.entryID <= r.entryID ? (f.normalized, f.entryID) : (r.normalized, r.entryID)
            }
        }

        /// 消费两通道中 (normalized, entryID) 与 key 相同的全部行。
        private mutating func consumeEqualPrefixKey(
            _ key: (normalized: String, entryID: Int64),
            form: inout ChannelState,
            reading: inout ChannelState
        ) throws -> [ChannelRow] {
            var rows: [ChannelRow] = []
            while let row = try form.peek(engine: &self, phase: 2, channel: .form),
                  row.normalized == key.normalized, row.entryID == key.entryID {
                rows.append(row)
                form.advance()
            }
            while let row = try reading.peek(engine: &self, phase: 2, channel: .reading),
                  row.normalized == key.normalized, row.entryID == key.entryID {
                rows.append(row)
                reading.advance()
            }
            return rows
        }

        /// 前缀阶段全局去重：entry 已在精确段或变形候选段命中则跳过。
        /// 两个集合都是本查询的确定性结果，跨页一致。
        private mutating func shouldSkipPrefixHit(entryID: Int64) throws -> Bool {
            if try exactIDSet().contains(entryID) { return true }
            if try deinflectedIDSet().contains(entryID) { return true }
            return false
        }

        private func makePrefixHit(entryID: Int64, info: EntryInfo) -> DictionaryHit {
            let matching = info.prefixMatchingSurfaces(query: query, upper: prefixUpper)
            let minNorm = matching.first?.normalized
            let atMin = matching.filter { $0.normalized == minNorm }
            var seen = Set<String>()
            let texts = matching.map(\.surface).filter { seen.insert($0).inserted }
            return DictionaryHit(
                entryID: entryID,
                matchedForm: atMin.first?.surface ?? texts.first ?? "",
                matchedNormalized: minNorm ?? "",
                matchedSurfaces: texts,
                channel: atMin.first?.channel ?? .form,
                reason: .prefix,
                rank: info.rank
            )
        }

        // MARK: 确定性集合 / entry 信息

        /// 精确命中 entry 全集（两通道 normalized == query）。
        private mutating func exactIDSet() throws -> Set<Int64> {
            if let cachedExactIDs { return cachedExactIDs }
            var ids = Set<Int64>()
            for row in try Row.fetchAll(
                db,
                sql: "SELECT entry_id FROM forms WHERE normalized_text = ?",
                arguments: [query]
            ) { ids.insert(row["entry_id"]) }
            for row in try Row.fetchAll(
                db,
                sql: "SELECT entry_id FROM readings WHERE normalized_reading = ?",
                arguments: [query]
            ) { ids.insert(row["entry_id"]) }
            cachedExactIDs = ids
            return ids
        }

        private mutating func entryInfo(_ entryID: Int64) -> EntryInfo {
            infoCache[entryID] ?? EntryInfo(rank: nil)
        }

        /// 批量补全 infoCache（通道 peek 时按批预取）。
        private mutating func prefetchEntryInfos(_ entryIDs: [Int64]) throws {
            let missing = Array(Set(entryIDs).filter { infoCache[$0] == nil })
            guard !missing.isEmpty else { return }
            for chunk in missing.chunked(GRDBDictionaryRepository.inChunkSize) {
                let p = GRDBDictionaryRepository.placeholders(chunk.count)
                let args = StatementArguments(chunk)
                for row in try Row.fetchAll(
                    db,
                    sql: "SELECT id, common_rank FROM entries WHERE id IN (\(p))",
                    arguments: args
                ) {
                    let id: Int64 = row["id"]
                    var info = infoCache[id] ?? EntryInfo(rank: nil)
                    info.rank = row["common_rank"]
                    infoCache[id] = info
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, normalized_text, text
                        FROM forms WHERE entry_id IN (\(p))
                        """,
                    arguments: args
                ) {
                    let id: Int64 = row["entry_id"]
                    var info = infoCache[id] ?? EntryInfo(rank: nil)
                    info.forms.append((normalized: row["normalized_text"], surface: row["text"]))
                    infoCache[id] = info
                }
                for row in try Row.fetchAll(
                    db,
                    sql: """
                        SELECT entry_id, normalized_reading, reading
                        FROM readings WHERE entry_id IN (\(p))
                        """,
                    arguments: args
                ) {
                    let id: Int64 = row["entry_id"]
                    var info = infoCache[id] ?? EntryInfo(rank: nil)
                    info.readings.append((normalized: row["normalized_reading"], surface: row["reading"]))
                    infoCache[id] = info
                }
            }
            // 标记未命中 entry（避免重复查询不存在的 id）
            for id in missing where infoCache[id] == nil {
                infoCache[id] = EntryInfo(rank: nil)
            }
        }

        // MARK: 通道取数

        /// 单通道 keyset 拉取。
        /// - phase 0：`(rank, entryID)` 序（rank = COALESCE(common_rank, 哨兵)）；
        /// - phase 2：`(normalized, entryID)` BINARY 序，范围 `> query AND < 上界`。
        private func fetchChannel(
            channel: DictionaryMatchChannel,
            phase: Int,
            bound: DictionarySearchCursor.KeysetBound?
        ) throws -> [ChannelRow] {
            let table = channel == .form ? "forms" : "readings"
            let normColumn = channel == .form ? "normalized_text" : "normalized_reading"
            let surfaceColumn = channel == .form ? "text" : "reading"
            let limit = GRDBDictionaryRepository.channelFetchSize

            if phase == 0 {
                var sql = """
                    SELECT t.entry_id AS eid, t.\(surfaceColumn) AS surf,
                           COALESCE(e.common_rank, \(GRDBDictionaryRepository.rankNullSentinel)) AS rnk
                    FROM \(table) t JOIN entries e ON e.id = t.entry_id
                    WHERE t.\(normColumn) = ?
                    """
                var arguments: StatementArguments = [query]
                if let bound {
                    sql += """
                         AND (COALESCE(e.common_rank, \(GRDBDictionaryRepository.rankNullSentinel)) > ?
                              OR (COALESCE(e.common_rank, \(GRDBDictionaryRepository.rankNullSentinel)) = ?
                                  AND t.entry_id > ?))
                        """
                    arguments += [bound.rank, bound.rank, bound.entryID]
                }
                sql += " ORDER BY rnk, t.entry_id LIMIT \(limit)"
                return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
                    ChannelRow(
                        normalized: "",
                        rank: $0["rnk"],
                        entryID: $0["eid"],
                        surface: $0["surf"],
                        channel: channel
                    )
                }
            }

            var sql = """
                SELECT t.\(normColumn) AS nrm, t.entry_id AS eid, t.\(surfaceColumn) AS surf
                FROM \(table) t
                WHERE t.\(normColumn) > ?
                """
            var arguments: StatementArguments = [query]
            if let prefixUpper {
                sql += " AND t.\(normColumn) < ?"
                arguments += [prefixUpper]
            }
            if let bound {
                sql += """
                     AND (t.\(normColumn) > ? OR (t.\(normColumn) = ? AND t.entry_id > ?))
                    """
                arguments += [bound.normalized, bound.normalized, bound.entryID]
            }
            sql += " ORDER BY t.\(normColumn), t.entry_id LIMIT \(limit)"
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map {
                ChannelRow(
                    normalized: $0["nrm"],
                    rank: 0,
                    entryID: $0["eid"],
                    surface: $0["surf"],
                    channel: channel
                )
            }
        }

        // MARK: BINARY 字符串工具（与 SQLite BINARY collation 一致）

        /// UTF-8 逐字节比较 = SQLite BINARY collation。
        static func binaryLessThan(_ lhs: String, _ rhs: String) -> Bool {
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }

        /// normalized ∈ (query, upper)：前缀区间（不含精确命中）。
        static func isInPrefixRange(_ normalized: String, query: String, upper: String?) -> Bool {
            guard binaryLessThan(query, normalized) else { return false }
            if let upper { return binaryLessThan(normalized, upper) }
            return true
        }

        /// 前缀上界：末位 scalar +1；末位 U+10FFFF 向前进位；全满无上界。
        /// 注意跳过 UTF-16 代理区（0xD800–0xDFFF，非合法 scalar）。
        static func prefixUpperBound(of query: String) -> String? {
            var scalars = Array(query.unicodeScalars)
            while let last = scalars.last {
                var next = last.value + 1
                if (0xD800...0xDFFF).contains(next) { next = 0xE000 }
                if next <= 0x10FFFF, let scalar = Unicode.Scalar(next) {
                    scalars[scalars.count - 1] = scalar
                    return String(String.UnicodeScalarView(scalars))
                }
                scalars.removeLast()
            }
            return nil
        }
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
