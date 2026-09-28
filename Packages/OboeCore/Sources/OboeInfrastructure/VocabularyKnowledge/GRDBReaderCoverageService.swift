import Foundation
import GRDB
import OboeDomain

/// S09 文档覆盖率服务（§7 / D04）：token/unique 双口径、局部进度、
/// 快照持久化、增量失效与未知词列表。
///
/// 数据流：
/// - token 来源 = `reader_token_cache`（v17，按块 BLOB）→ 未命中才
///   调 `JapaneseMorphologyService.tokenize` 并回写缓存。覆盖率
///   重算永不绕过缓存逐块重分词；缓存键折叠为
///   `tokenizer_version = "<parserVersion>|<morphologyVersion>|<osBuild>"`
///   + `dictionary_version = dictionaryDatasetVersion`——版本切换
///   自然 miss，旧版本行不混用（§6.1 五元组折叠进两列）。
/// - 状态来源 = `lexemes` / `vocabulary_knowledge_overrides` /
///   `lexeme_note_links`，全部走 `resolveLexemes` + `states` 的
///   chunked-IN 批量通道，无逐 token/逐 lexeme SQL。
/// - `reader_coverage_snapshots` 两种 scope：
///   `block:<uuid>` = 块级工作行（当前 metric/morphology/学习日的
///   K/L/U/I + 块内 unique 计数；knowledge 变化时只重写受影响块）；
///   `document` = 文档聚合行（token 计数 = 块行聚合校验、unique
///   分子分母 = 全文档去重集；`analyzed_blocks < total_blocks` 即
///   partial——任何读取侧不得把 partial 当全书覆盖率）。
/// - 块→key 索引不建冗余表：由 `reader_token_cache.payload` 解码
///   派生（payload 本身版本化）。knowledge 增量更新 = 解码 payload
///   定位含变更 key 的块，只重写这些块行；文档 unique 去重是全局
///   性质，文档行重算需扫全部 payload（纯 JSON 解码 + 批量状态，
///   不重分词、无逐行 SQL）。
public actor GRDBReaderCoverageService {

    /// 文档级 scope_key。
    public static let documentScope = "document"
    /// 块级 scope_key 前缀。
    public static func blockScope(_ blockID: UUID) -> String {
        "block:\(blockID.uuidString.lowercased())"
    }

    /// 每批提交的块数（进度持久化粒度；取消后已提交批次保留）。
    public static let defaultBatchSize = 16

    public enum CoverageError: Error, Equatable, Sendable {
        case documentNotFound(UUID)
        case invalidTimeZone(String)
    }

    /// `reader_coverage_snapshots` 行的领域投影。
    public struct CoverageSnapshot: Equatable, Sendable {
        public let id: UUID
        public let documentID: UUID
        public let scopeKey: String
        public let chapterID: UUID?
        public let documentTitle: String
        public let contentHash: String
        public let metricVersion: String
        public let morphologyVersion: String
        public let dictionaryVersion: String?
        public let known: Int
        public let learning: Int
        public let unknown: Int
        public let ignored: Int
        /// 持久化的 unique 分子 = |K∪L| distinct key（D04 口径）。
        public let uniqueNumerator: Int
        /// 持久化的 unique 分母 = |K∪L∪U| distinct key。
        public let uniqueDenominator: Int
        public let analyzedBlocks: Int
        public let totalBlocks: Int
        public let studyDayID: String
        public let createdAt: Date

        public var eligible: Int { known + learning + unknown }
        public var isPartial: Bool { analyzedBlocks < totalBlocks }
        public var tokenCoverage: Double? {
            eligible > 0 ? Double(known) / Double(eligible) : nil
        }
        public var knownOrLearningCoverage: Double? {
            eligible > 0 ? Double(known + learning) / Double(eligible) : nil
        }
        /// unique 口径的「已知或学习中」——持久化分子分母直出。
        public var uniqueKnownOrLearningCoverage: Double? {
            uniqueDenominator > 0
                ? Double(uniqueNumerator) / Double(uniqueDenominator) : nil
        }
    }

    private let pool: DatabasePool
    private let morphology: any JapaneseMorphologyService
    /// 形态管线版本（deinflect 规则 × 合并启发式）——快照与缓存键
    /// 组成之一；由装配方从 `NLJapaneseMorphologyService.morphologyVersion`
    /// 取值传入（协议未暴露该字段）。
    private let morphologyVersion: String
    private let osBuild: String
    private let knowledge: GRDBVocabularyKnowledgeRepository
    private let timeZoneID: String
    private let metricVersion: String
    private let batchSize: Int
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID

    public init(
        pool: DatabasePool,
        morphology: any JapaneseMorphologyService,
        morphologyVersion: String,
        osBuild: String,
        knowledge: GRDBVocabularyKnowledgeRepository,
        timeZoneID: String = TimeZone.current.identifier,
        metricVersion: String = ReaderCoverageMetrics.metricVersion,
        batchSize: Int = defaultBatchSize,
        now: @escaping @Sendable () -> Date = { Date() },
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.pool = pool
        self.morphology = morphology
        self.morphologyVersion = morphologyVersion
        self.osBuild = osBuild
        self.knowledge = knowledge
        self.timeZoneID = timeZoneID
        self.metricVersion = metricVersion
        self.batchSize = max(1, batchSize)
        self.now = now
        self.makeID = makeID
    }

    /// 生产便捷构造：直接吃 NL 服务，版本字段自动接线。
    public init(
        pool: DatabasePool,
        morphology: NLJapaneseMorphologyService,
        knowledge: GRDBVocabularyKnowledgeRepository,
        timeZoneID: String = TimeZone.current.identifier,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            pool: pool,
            morphology: morphology,
            morphologyVersion: morphology.morphologyVersion,
            osBuild: morphology.osBuild,
            knowledge: knowledge,
            timeZoneID: timeZoneID,
            now: now
        )
    }

    // MARK: - 全量分析

    /// 文档级覆盖率分析：按块推进、按批提交。已分析块的 token
    /// 由 `reader_token_cache` 直接供给（版本/文本 hash 全键命中），
    /// 取消后重跑天然续接——不重复 tokenize。
    /// - Returns: 最终 metrics（完成时 analyzed == total）。
    @discardableResult
    public func analyze(documentID: UUID) async throws -> ReaderCoverageMetrics {
        let meta = try await documentMeta(documentID)
        let blocks = try await fetchBlocks(documentID: documentID)
        let tokenizerVersion = tokenizerVersion(parserVersion: meta.parserVersion)
        let dictionaryVersion = await ensureDictionaryVersion()
        let studyDay = try currentStudyDayID()
        var document = ReaderCoverageAccumulator()
        var analyzed = 0
        var didPrune = false

        for batch in blocks.chunked(batchSize) {
            try Task.checkCancellation()
            // 1) tokens（缓存优先；miss 才 tokenize——txn 外）
            var stagedPayloads: [(UUID, String, Data)] = []
            var batchTokens: [(BlockRecord, [ReaderToken])] = []
            var batchKeys = Set<LexicalKey>()
            for block in batch {
                try Task.checkCancellation()
                let tokens = try await tokens(
                    for: block,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion,
                    stagedPayloads: &stagedPayloads
                )
                batchTokens.append((block, tokens))
                for token in tokens {
                    if let key = token.lexicalKey { batchKeys.insert(key) }
                }
            }
            // 2) 批量状态解析（resolveLexemes + states 两次 chunked IN）
            let states = try await resolveStates(keys: batchKeys)
            // 3) 分类聚合
            var accumulators: [(BlockRecord, ReaderCoverageAccumulator)] = []
            for (block, tokens) in batchTokens {
                var acc = ReaderCoverageAccumulator()
                for token in tokens { acc.add(token: token, states: states) }
                accumulators.append((block, acc))
                document.merge(acc)
            }
            analyzed += batch.count
            let metrics = document.metrics(
                analyzedBlocks: analyzed, totalBlocks: blocks.count)
            // 4) 单事务提交：payload upsert + 块行 + 文档行
            let prune = !didPrune
            let at = now()
            let staged = stagedPayloads
            let blockRows = accumulators
            let liveIDs = Set(blocks.map(\.id))
            try await pool.write { db in
                if prune {
                    try pruneStaleBlockRows(
                        documentID: documentID,
                        liveBlockIDs: liveIDs,
                        studyDayID: studyDay, in: db)
                }
                for (blockID, textHash, payload) in staged {
                    try upsertTokenPayload(
                        blockID: blockID, textHash: textHash,
                        tokenizerVersion: tokenizerVersion,
                        dictionaryVersion: dictionaryVersion,
                        payload: payload, in: db)
                }
                for (block, acc) in blockRows {
                    try upsertBlockRow(
                        block: block, accumulator: acc,
                        meta: meta, dictionaryVersion: dictionaryVersion,
                        studyDayID: studyDay, at: at, in: db)
                }
                try upsertDocumentRow(
                    meta: meta, metrics: metrics,
                    dictionaryVersion: dictionaryVersion,
                    studyDayID: studyDay, at: at, in: db)
            }
            didPrune = true
        }

        if blocks.isEmpty {
            // 无词文档仍落文档行（0/0、eligible=0 → 覆盖率 nil）。
            try await pool.write { db in
                try pruneStaleBlockRows(
                    documentID: documentID, liveBlockIDs: [],
                    studyDayID: studyDay, in: db)
                try upsertDocumentRow(
                    meta: meta,
                    metrics: ReaderCoverageAccumulator().metrics(
                        analyzedBlocks: 0, totalBlocks: 0),
                    dictionaryVersion: dictionaryVersion,
                    studyDayID: studyDay, at: now(), in: db)
            }
        }
        return document.metrics(
            analyzedBlocks: analyzed, totalBlocks: blocks.count)
    }

    // MARK: - 增量更新

    /// 知识状态变化后的增量刷新：只重写「token 命中变更 lexeme」的
    /// 块行；文档行基于全量 payload 重算（unique 去重是文档级性质）。
    /// `changedLexemeIDs` 为 nil 时全块刷新（字典更新后调用）。
    /// - Returns: 新文档 metrics；从未分析过且无缓存 → nil。
    @discardableResult
    public func refreshKnowledge(
        documentID: UUID,
        changedLexemeIDs: Set<UUID>? = nil
    ) async throws -> ReaderCoverageMetrics? {
        var affectedKeys: Set<String>? = nil
        if let changedLexemeIDs {
            affectedKeys = Set(try await identityKeys(lexemeIDs: changedLexemeIDs))
            if affectedKeys?.isEmpty == true { affectedKeys = [] }
        }
        return try await refreshAggregate(
            documentID: documentID,
            affectedKeys: affectedKeys,
            ensureBlockIDs: []
        )
    }

    /// 指定块重分析（内容变更/定点重算）：只对给定块取新 token
    /// （text_hash 命中仍走缓存），重写其块行并重算文档行。
    @discardableResult
    public func refreshBlocks(
        documentID: UUID,
        blockIDs: Set<UUID>
    ) async throws -> ReaderCoverageMetrics? {
        return try await refreshAggregate(
            documentID: documentID,
            affectedKeys: nil,
            ensureBlockIDs: blockIDs
        )
    }

    /// 增量公共路径：ensureBlockIDs 内的块保证重取 token；其余块用
    /// 既有 payload。affectedKeys 非 nil 时只重写含变更 key 的块行。
    private func refreshAggregate(
        documentID: UUID,
        affectedKeys: Set<String>?,
        ensureBlockIDs: Set<UUID>
    ) async throws -> ReaderCoverageMetrics? {
        let meta = try await documentMeta(documentID)
        let blocks = try await fetchBlocks(documentID: documentID)
        let tokenizerVersion = tokenizerVersion(parserVersion: meta.parserVersion)
        let dictionaryVersion = await ensureDictionaryVersion()
        let studyDay = try currentStudyDayID()

        // 1) 全块 payload 读取（当前版本 + text_hash 匹配才算已分析），
        //    ensureBlockIDs 内的块 miss 时重 tokenize。
        var stagedPayloads: [(UUID, String, Data)] = []
        var tokensByBlock: [UUID: [ReaderToken]] = [:]
        tokensByBlock.reserveCapacity(blocks.count)
        for block in blocks {
            try Task.checkCancellation()
            let ensure = ensureBlockIDs.contains(block.id)
            let tokens = try await ensure
                ? forceTokens(
                    for: block,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion,
                    stagedPayloads: &stagedPayloads)
                : try await cachedTokens(
                    block: block,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion)
            if let tokens { tokensByBlock[block.id] = tokens }
        }
        let analyzedBlocks = blocks.filter { tokensByBlock[$0.id] != nil }
        let hasSnapshot = try await documentRowExists(
            documentID: documentID, studyDayID: studyDay)
        guard !analyzedBlocks.isEmpty || hasSnapshot else { return nil }

        // 2) 受影响块 = token 含变更 key 的已分析块（nil → 全已分析块）。
        let affectedBlockIDs: Set<UUID> = {
            guard let affectedKeys else {
                return Set(analyzedBlocks.map(\.id))
            }
            return Set(analyzedBlocks.filter { block in
                (tokensByBlock[block.id] ?? []).contains {
                    guard let key = $0.lexicalKey else { return false }
                    return affectedKeys.contains(key.identityKey)
                }
            }.map(\.id))
        }()

        // 3) 一次批量状态解析覆盖全部已分析块。
        var allKeys = Set<LexicalKey>()
        for block in analyzedBlocks {
            for token in tokensByBlock[block.id] ?? [] {
                if let key = token.lexicalKey { allKeys.insert(key) }
            }
        }
        let states = try await resolveStates(keys: allKeys)

        // 4) 聚合：块累加器（受影响才写）+ 文档累加器。
        var document = ReaderCoverageAccumulator()
        var perBlock: [UUID: ReaderCoverageAccumulator] = [:]
        for block in analyzedBlocks {
            var acc = ReaderCoverageAccumulator()
            for token in tokensByBlock[block.id] ?? [] {
                acc.add(token: token, states: states)
            }
            perBlock[block.id] = acc
            document.merge(acc)
        }
        let metrics = document.metrics(
            analyzedBlocks: analyzedBlocks.count, totalBlocks: blocks.count)

        // 5) 单事务：payload upsert + 受影响块行 + 文档行 + 清理失联块行。
        let at = now()
        let staged = stagedPayloads
        let liveIDs = Set(analyzedBlocks.map(\.id))
        let affectedRows: [(BlockRecord, ReaderCoverageAccumulator)] =
            analyzedBlocks
                .filter { affectedBlockIDs.contains($0.id) }
                .map { ($0, perBlock[$0.id] ?? ReaderCoverageAccumulator()) }
        try await pool.write { db in
            for (blockID, textHash, payload) in staged {
                try upsertTokenPayload(
                    blockID: blockID, textHash: textHash,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion,
                    payload: payload, in: db)
            }
            try pruneStaleBlockRows(
                documentID: documentID,
                liveBlockIDs: liveIDs,
                studyDayID: studyDay, in: db)
            for (block, acc) in affectedRows {
                try upsertBlockRow(
                    block: block, accumulator: acc,
                    meta: meta, dictionaryVersion: dictionaryVersion,
                    studyDayID: studyDay, at: at, in: db)
            }
            try upsertDocumentRow(
                meta: meta, metrics: metrics,
                dictionaryVersion: dictionaryVersion,
                studyDayID: studyDay, at: at, in: db)
        }
        return metrics
    }

    // MARK: - 读取

    /// 最新文档级快照（当前 metric/morphology 版本内取最近学习日）。
    /// partial 行照常返回——调用方凭 `isPartial` 决定展示口径。
    public func documentSnapshot(
        documentID: UUID
    ) async throws -> CoverageSnapshot? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM reader_coverage_snapshots
                    WHERE document_id = ? AND scope_key = ?
                      AND metric_version = ? AND morphology_version = ?
                    ORDER BY study_day_id DESC, created_at_ms DESC
                    LIMIT 1
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    Self.documentScope, metricVersion, morphologyVersion
                ]
            ) else { return nil }
            return try Self.decodeSnapshot(row)
        }
    }

    /// 本章覆盖率：按章内块级 payload 重聚合（块行 unique 不能相加，
    /// 去重须回到 token 层——读侧小范围聚合，不写快照）。
    public func chapterMetrics(
        documentID: UUID,
        chapterID: UUID
    ) async throws -> ReaderCoverageMetrics? {
        let meta = try await documentMeta(documentID)
        let blocks = try await fetchBlocks(documentID: documentID)
            .filter { $0.chapterID == chapterID }
        guard !blocks.isEmpty else { return nil }
        let tokenizerVersion = tokenizerVersion(parserVersion: meta.parserVersion)
        let dictionaryVersion = await ensureDictionaryVersion()
        var tokensByBlock: [UUID: [ReaderToken]] = [:]
        var analyzed = 0
        for block in blocks {
            if let tokens = try await cachedTokens(
                block: block,
                tokenizerVersion: tokenizerVersion,
                dictionaryVersion: dictionaryVersion
            ) {
                tokensByBlock[block.id] = tokens
                analyzed += 1
            }
        }
        guard analyzed > 0 else { return nil }
        var keys = Set<LexicalKey>()
        for tokens in tokensByBlock.values {
            for token in tokens {
                if let key = token.lexicalKey { keys.insert(key) }
            }
        }
        let states = try await resolveStates(keys: keys)
        var acc = ReaderCoverageAccumulator()
        for tokens in tokensByBlock.values {
            for token in tokens { acc.add(token: token, states: states) }
        }
        return acc.metrics(analyzedBlocks: analyzed, totalBlocks: blocks.count)
    }

    /// 未知词列表（§7：unknown 分桶 + OOV/待确认标记）。
    /// 按出现次数降序、表记升序；offset/limit 分页。
    /// - Returns: (页条目, 全部条目数)。
    public func unknownWords(
        documentID: UUID,
        offset: Int = 0,
        limit: Int = 200
    ) async throws -> (items: [UnknownWordItem], total: Int) {
        let meta = try await documentMeta(documentID)
        let blocks = try await fetchBlocks(documentID: documentID)
        let tokenizerVersion = tokenizerVersion(parserVersion: meta.parserVersion)
        let dictionaryVersion = await ensureDictionaryVersion()

        var keys = Set<LexicalKey>()
        var tokensByBlock: [UUID: [ReaderToken]] = [:]
        for block in blocks {
            guard let tokens = try await cachedTokens(
                block: block,
                tokenizerVersion: tokenizerVersion,
                dictionaryVersion: dictionaryVersion
            ) else { continue }
            tokensByBlock[block.id] = tokens
            for token in tokens {
                if let key = token.lexicalKey { keys.insert(key) }
            }
        }
        let lexemes = try await knowledge.resolveLexemes(keys: Array(keys))
        let states = try await knowledge.states(
            lexemeIDs: lexemes.values.map(\.id))
        var stateByKey: [String: VocabularyKnowledgeState] = [:]
        for (key, lexeme) in lexemes {
            stateByKey[key.identityKey] = states[lexeme.id] ?? .unknown
        }

        struct Group {
            var count = 0
            var displayForm = ""
            var reading: String? = nil
            var lexemeID: UUID? = nil
            var isOOV = false
            var isAmbiguous = false
        }
        var groups: [String: Group] = [:]
        for tokens in tokensByBlock.values {
            for token in tokens {
                guard let c = ReaderCoverageMath.contribution(of: token),
                      ReaderCoverageMath.state(of: c, states: stateByKey) == .unknown
                else { continue }
                var group = groups[c.dedupKey] ?? Group()
                group.count += 1
                group.isOOV = group.isOOV || c.isOutOfVocabulary
                group.isAmbiguous = group.isAmbiguous || c.isAmbiguous
                if let key = token.lexicalKey,
                   let lexeme = lexemes[key] {
                    group.displayForm = lexeme.writtenForm
                    group.reading = group.reading ?? lexeme.reading
                    group.lexemeID = lexeme.id
                } else if group.displayForm.isEmpty {
                    group.displayForm = token.surface
                    group.reading = group.reading ?? token.reading
                }
                groups[c.dedupKey] = group
            }
        }
        let sorted = groups
            .map { dedupKey, group in
                UnknownWordItem(
                    dedupKey: dedupKey,
                    displayForm: group.displayForm,
                    reading: group.reading,
                    lexemeID: group.lexemeID,
                    occurrenceCount: group.count,
                    isOutOfVocabulary: group.isOOV,
                    isAmbiguous: group.isAmbiguous
                )
            }
            .sorted {
                $0.occurrenceCount != $1.occurrenceCount
                    ? $0.occurrenceCount > $1.occurrenceCount
                    : $0.displayForm < $1.displayForm
            }
        let lower = min(max(0, offset), sorted.count)
        let upper = min(lower + max(0, limit), sorted.count)
        return (Array(sorted[lower..<upper]), sorted.count)
    }

    // MARK: - 内部：取数

    private struct DocumentMeta: Sendable {
        let id: UUID
        let title: String
        let canonicalTextHash: String
        let parserVersion: String
    }

    private struct BlockRecord: Sendable {
        let id: UUID
        let chapterID: UUID
        let ordinal: Int
        let text: String
        let textHash: String
    }

    private func documentMeta(_ documentID: UUID) async throws -> DocumentMeta {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT title, canonical_text_hash, parser_version
                    FROM reader_documents WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ) else { throw CoverageError.documentNotFound(documentID) }
            return DocumentMeta(
                id: documentID,
                title: row["title"],
                canonicalTextHash: row["canonical_text_hash"],
                parserVersion: row["parser_version"]
            )
        }
    }

    /// 块按章节序 + 块序排列（分析顺序 = 阅读顺序）。
    private func fetchBlocks(documentID: UUID) async throws -> [BlockRecord] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT b.id, b.chapter_id, b.ordinal, b.text, b.text_hash
                    FROM reader_blocks b
                    JOIN reader_chapters c ON c.id = b.chapter_id
                    WHERE b.document_id = ?
                    ORDER BY c.ordinal, b.ordinal
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            ).map { row in
                BlockRecord(
                    id: try DatabaseValueCodec.decodeUUID(row["id"]),
                    chapterID: try DatabaseValueCodec.decodeUUID(row["chapter_id"]),
                    ordinal: row["ordinal"],
                    text: row["text"],
                    textHash: row["text_hash"]
                )
            }
        }
    }

    private func tokenizerVersion(parserVersion: String) -> String {
        "\(parserVersion)|\(morphologyVersion)|\(osBuild)"
    }

    /// NL 服务的 dataset 版本在首次 tokenize 后才回填；
    /// 未取到先用空块热身一次（不产生写）。
    private func ensureDictionaryVersion() async -> String {
        var version = morphology.dictionaryDatasetVersion
        if version == "unopened" {
            _ = try? await morphology.tokenize(
                MorphologyBlock(blockID: makeID(), text: "", textHash: "warmup"))
            version = morphology.dictionaryDatasetVersion
        }
        return version
    }

    private func currentStudyDayID() throws -> String {
        do {
            return try StudyDayBoundaryCalculator().studyDay(
                containing: now(), timeZoneID: timeZoneID,
                newCardLimit: 0, id: makeID()
            ).localDate
        } catch {
            throw CoverageError.invalidTimeZone(timeZoneID)
        }
    }

    /// 缓存命中（当前版本 + text_hash 全键）→ tokens；否则 nil。
    private func cachedTokens(
        block: BlockRecord,
        tokenizerVersion: String,
        dictionaryVersion: String
    ) async throws -> [ReaderToken]? {
        try await pool.read { db in
            guard let payload = try Data.fetchOne(
                db,
                sql: """
                    SELECT payload FROM reader_token_cache
                    WHERE block_id = ? AND tokenizer_version = ?
                      AND dictionary_version = ? AND text_hash = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(block.id),
                    tokenizerVersion, dictionaryVersion, block.textHash
                ]
            ) else { return nil }
            return ReaderTokenCacheCodec.decode(payload)
        }
    }

    /// 缓存优先；miss 才 tokenize 并把 payload 暂存待提交。
    private func tokens(
        for block: BlockRecord,
        tokenizerVersion: String,
        dictionaryVersion: String,
        stagedPayloads: inout [(UUID, String, Data)]
    ) async throws -> [ReaderToken] {
        if let cached = try await cachedTokens(
            block: block,
            tokenizerVersion: tokenizerVersion,
            dictionaryVersion: dictionaryVersion
        ) { return cached }
        return try await forceTokens(
            for: block,
            tokenizerVersion: tokenizerVersion,
            dictionaryVersion: dictionaryVersion,
            stagedPayloads: &stagedPayloads)
    }

    /// 无条件 tokenize（refreshBlocks 的定点重分析路径——payload
    /// 仍存在时先按 hash 校验，命中即复用避免无效重算）。
    private func forceTokens(
        for block: BlockRecord,
        tokenizerVersion: String,
        dictionaryVersion: String,
        stagedPayloads: inout [(UUID, String, Data)]
    ) async throws -> [ReaderToken] {
        let tokens = try await morphology.tokenize(
            MorphologyBlock(
                blockID: block.id, text: block.text, textHash: block.textHash))
        stagedPayloads.append((
            block.id, block.textHash,
            try ReaderTokenCacheCodec.encode(tokens)
        ))
        return tokens
    }

    /// key → 状态：两次 chunked IN（resolveLexemes + states），
    /// 未落库 key 不出现于结果（调用方按 unknown 计）。
    private func resolveStates(
        keys: Set<LexicalKey>
    ) async throws -> [String: VocabularyKnowledgeState] {
        guard !keys.isEmpty else { return [:] }
        let lexemes = try await knowledge.resolveLexemes(keys: Array(keys))
        let states = try await knowledge.states(
            lexemeIDs: lexemes.values.map(\.id))
        var result: [String: VocabularyKnowledgeState] = [:]
        result.reserveCapacity(lexemes.count)
        for (key, lexeme) in lexemes {
            result[key.identityKey] = states[lexeme.id] ?? .unknown
        }
        return result
    }

    private func identityKeys(lexemeIDs: Set<UUID>) async throws -> [String] {
        let encoded = lexemeIDs.map(DatabaseValueCodec.encode)
        guard !encoded.isEmpty else { return [] }
        return try await pool.read { db in
            var keys: [String] = []
            for chunk in encoded.chunked(400) {
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                keys += try String.fetchAll(
                    db,
                    sql: """
                        SELECT identity_key FROM lexemes
                        WHERE id IN (\(placeholders))
                        """,
                    arguments: StatementArguments(Array(chunk))
                )
            }
            return keys
        }
    }

    private func documentRowExists(
        documentID: UUID,
        studyDayID: String
    ) async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM reader_coverage_snapshots
                        WHERE document_id = ? AND scope_key = ?
                          AND metric_version = ? AND morphology_version = ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    Self.documentScope, metricVersion, morphologyVersion
                ]
            ) ?? false
        }
    }

    // MARK: - 内部：写

    nonisolated private func upsertTokenPayload(
        blockID: UUID,
        textHash: String,
        tokenizerVersion: String,
        dictionaryVersion: String,
        payload: Data,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_token_cache(
                    block_id, text_hash, tokenizer_version,
                    dictionary_version, payload
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(block_id, tokenizer_version, dictionary_version)
                DO UPDATE SET
                    text_hash = excluded.text_hash,
                    payload = excluded.payload
                """,
            arguments: [
                DatabaseValueCodec.encode(blockID), textHash,
                tokenizerVersion, dictionaryVersion, payload
            ]
        )
    }

    nonisolated private func upsertBlockRow(
        block: BlockRecord,
        accumulator: ReaderCoverageAccumulator,
        meta: DocumentMeta,
        dictionaryVersion: String,
        studyDayID: String,
        at: Date,
        in db: Database
    ) throws {
        let m = accumulator.metrics(analyzedBlocks: 1, totalBlocks: 1)
        try upsertRow(
            id: makeID(), documentID: meta.id,
            documentTitle: meta.title, scopeKey: Self.blockScope(block.id),
            chapterID: block.chapterID, contentHash: block.textHash,
            dictionaryVersion: dictionaryVersion, metrics: m,
            studyDayID: studyDayID, at: at, in: db
        )
    }

    nonisolated private func upsertDocumentRow(
        meta: DocumentMeta,
        metrics: ReaderCoverageMetrics,
        dictionaryVersion: String,
        studyDayID: String,
        at: Date,
        in db: Database
    ) throws {
        try upsertRow(
            id: makeID(), documentID: meta.id,
            documentTitle: meta.title, scopeKey: Self.documentScope,
            chapterID: nil, contentHash: meta.canonicalTextHash,
            dictionaryVersion: dictionaryVersion, metrics: metrics,
            studyDayID: studyDayID, at: at, in: db
        )
    }

    nonisolated private func upsertRow(
        id: UUID,
        documentID: UUID,
        documentTitle: String,
        scopeKey: String,
        chapterID: UUID?,
        contentHash: String,
        dictionaryVersion: String,
        metrics: ReaderCoverageMetrics,
        studyDayID: String,
        at: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_coverage_snapshots(
                    id, document_id, document_title, scope_key, chapter_id,
                    content_hash, metric_version, morphology_version,
                    dictionary_version, known_count, learning_count,
                    unknown_count, ignored_count, unique_numerator,
                    unique_denominator, analyzed_blocks, total_blocks,
                    study_day_id, created_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(document_id, scope_key, study_day_id,
                            metric_version, morphology_version)
                DO UPDATE SET
                    document_title = excluded.document_title,
                    chapter_id = excluded.chapter_id,
                    content_hash = excluded.content_hash,
                    dictionary_version = excluded.dictionary_version,
                    known_count = excluded.known_count,
                    learning_count = excluded.learning_count,
                    unknown_count = excluded.unknown_count,
                    ignored_count = excluded.ignored_count,
                    unique_numerator = excluded.unique_numerator,
                    unique_denominator = excluded.unique_denominator,
                    analyzed_blocks = excluded.analyzed_blocks,
                    total_blocks = excluded.total_blocks,
                    created_at_ms = excluded.created_at_ms
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(documentID),
                documentTitle, scopeKey,
                chapterID.map(DatabaseValueCodec.encode),
                contentHash, metricVersion, morphologyVersion,
                dictionaryVersion,
                metrics.known, metrics.learning, metrics.unknown,
                metrics.ignored,
                metrics.uniqueKnown + metrics.uniqueLearning,
                metrics.uniqueEligible,
                metrics.analyzedBlocks, metrics.totalBlocks,
                studyDayID,
                try DatabaseValueCodec.encode(at)
            ]
        )
    }

    /// 清理块级工作行：版本/口径/学习日失配或块已脱离已分析集
    /// （块删除/缓存失效）。文档级行保留作历史趋势（同日同版本
    /// upsert；版本切换由 UNIQUE 键天然分线）。
    nonisolated private func pruneStaleBlockRows(
        documentID: UUID,
        liveBlockIDs: Set<UUID>,
        studyDayID: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM reader_coverage_snapshots
                WHERE document_id = ? AND scope_key LIKE 'block:%'
                  AND (metric_version != ? OR morphology_version != ?
                       OR study_day_id != ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(documentID),
                metricVersion, morphologyVersion, studyDayID
            ]
        )
        if liveBlockIDs.isEmpty {
            try db.execute(
                sql: """
                    DELETE FROM reader_coverage_snapshots
                    WHERE document_id = ? AND scope_key LIKE 'block:%'
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
            return
        }
        for chunk in Array(liveBlockIDs).chunked(300) {
            let scopes = chunk.map { Self.blockScope($0) }
            let placeholders = Array(repeating: "?", count: scopes.count)
                .joined(separator: ",")
            try db.execute(
                sql: """
                    DELETE FROM reader_coverage_snapshots
                    WHERE document_id = ? AND scope_key LIKE 'block:%'
                      AND scope_key NOT IN (\(placeholders))
                    """,
                arguments: StatementArguments(
                    [DatabaseValueCodec.encode(documentID)] + scopes)
            )
        }
    }

    private static func decodeSnapshot(_ row: Row) throws -> CoverageSnapshot {
        CoverageSnapshot(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            scopeKey: row["scope_key"],
            chapterID: (row["chapter_id"] as String?).flatMap {
                try? DatabaseValueCodec.decodeUUID($0)
            },
            documentTitle: row["document_title"],
            contentHash: row["content_hash"],
            metricVersion: row["metric_version"],
            morphologyVersion: row["morphology_version"],
            dictionaryVersion: row["dictionary_version"],
            known: row["known_count"],
            learning: row["learning_count"],
            unknown: row["unknown_count"],
            ignored: row["ignored_count"],
            uniqueNumerator: row["unique_numerator"],
            uniqueDenominator: row["unique_denominator"],
            analyzedBlocks: row["analyzed_blocks"],
            totalBlocks: row["total_blocks"],
            studyDayID: row["study_day_id"],
            createdAt: DatabaseValueCodec.decodeDate(milliseconds: row["created_at_ms"])
        )
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(
                index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[index..<next])
            index = next
        }
        return result
    }
}
