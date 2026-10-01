import Foundation
import GRDB
import OboeDomain
import os

/// v0.7.5 S15：Reader「AI 准备学习内容」编排服务。
///
/// 本服务是 Reader 原文 ↔ AI 管线的**唯一粘合层**。职责链：
///
/// 1. `preflight` —— 文档/范围/活跃 Job/词典/缓存命中估算（只读，
///    零写入）。
/// 2. `prepare` —— token 缓存编排 + `AIStudyJobManifest` 冻结 + Job
///    行创建（证据写入仅限 `reader_token_cache` /
///    `reader_study_occurrences`（pending 锚点）/ `ai_study_jobs` /
///    `ai_study_job_manifests`——**确认前零业务对象**）。
/// 3. `plannedBlocks(for:)` —— Runner 的确定性 planner 闭包：
///    重放**只认 manifest**，不依赖届时词典/系统/token 缓存。
/// 4. `finalizeResults` —— Runner 收束后：occurrence 状态/链接回填
///    + 译文经 `GRDBReaderTranslationStore.publish` 落库。
/// 5. `buildPreview` —— unit 唯一身份聚合预览（仍零业务写）。
/// 6. `recordSelections` —— immutable selection revision + 低置信
///    改判落 `ai_study_resolutions`（origin=user）。
/// 7. `summary` —— `AIStudyApplyReport` → 互斥分桶摘要。
///
/// 关键不变量：
/// - 准备期唯一新增的业务可见对象是**文章绑定牌组**（容器元数据，
///   `ensureStudyDeck`——D14「首次准备即创建绑定」）；Note/Card/
///   membership 一律等 `AIStudyApplyService.applyConfirmedJob`。
/// - occurrence 唯一键 `(document, revision, locator, tokenizer,
///   start, len)` 自然去重——重跑 `INSERT OR IGNORE` 保先行。
/// - manifest 缺席/格式不符 → 拒绝续跑（`.missingSource` 语义），
///   不静默重算。
public struct AIStudyPreparationService: Sendable {
    /// 预检/预览用的窄 morphology 接口（`NLJapaneseMorphologyService`
    /// 直接满足；测试注入内存 stub）。
    public protocol MorphologySource: Sendable {
        var morphologyVersion: String { get }
        var osBuild: String { get }
        var dictionaryDatasetVersion: String { get }
        func tokenize(_ block: MorphologyBlock) async throws -> [ReaderToken]
    }

    /// 本服务对 Reader 持久层的窄读面（App 侧 `ReaderDocumentStore`
    /// 协议只多不少——三方法适配即可，测试用 stub 同形）。
    public protocol ReaderSource: Sendable {
        func fetchDocument(id: UUID) async throws -> ReaderDocumentMetadata?
        func fetchChapters(documentID: UUID) async throws
            -> [ReaderChapterMetadata]
        func fetchBlocks(documentID: UUID, chapterID: UUID) async throws
            -> [ReaderBlock]
    }

    private let pool: DatabasePool
    private let reader: any ReaderSource
    private let morphology: any MorphologySource
    private let dictionary: any DictionaryRepository
    private let jobStore: GRDBAIStudyJobStore
    /// 预览期 JLPT 参考索引供给（宿主装配——内置库在独立连接上，
    /// 由应用层决定装载策略；缺席时预览行 `jlptLevel` 恒 nil）。
    private let jlptIndexProvider:
        (@Sendable () async throws -> AIStudyJLPTReferenceIndex)?
    private let maxGlossesPerSense: Int
    /// `entries(ids:)` IN-批量上限（词典侧 SQL 变量上界留白）。
    private let dictionaryBatchSize: Int
    /// 证据写批次（cache+occurrence 同一事务；块数粒度）。
    private let commitBatchSize: Int
    private let now: @Sendable () -> Date

    public init(
        pool: DatabasePool,
        reader: any ReaderSource,
        morphology: any MorphologySource,
        dictionary: any DictionaryRepository,
        jobStore: GRDBAIStudyJobStore? = nil,
        jlptIndexProvider: (@Sendable () async throws
            -> AIStudyJLPTReferenceIndex)? = nil,
        maxGlossesPerSense: Int = AIStudyBudget.maxGlossesPerSense,
        dictionaryBatchSize: Int = 300,
        commitBatchSize: Int = 16,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pool = pool
        self.reader = reader
        self.morphology = morphology
        self.dictionary = dictionary
        self.jobStore = jobStore ?? GRDBAIStudyJobStore(pool: pool)
        self.jlptIndexProvider = jlptIndexProvider
        self.maxGlossesPerSense = maxGlossesPerSense
        self.dictionaryBatchSize = dictionaryBatchSize
        self.commitBatchSize = commitBatchSize
        self.now = now
    }

    public init(
        database: OboeDatabase,
        reader: any ReaderSource,
        morphology: any MorphologySource,
        dictionary: any DictionaryRepository,
        jlptIndexProvider: (@Sendable () async throws
            -> AIStudyJLPTReferenceIndex)? = nil
    ) {
        self.init(
            pool: database.pool,
            reader: reader,
            morphology: morphology,
            dictionary: dictionary,
            jlptIndexProvider: jlptIndexProvider
        )
    }

    private var nowMs: Int64 {
        Int64(now().timeIntervalSince1970 * 1_000)
    }

    /// planner 上下文：prev 块原文尾 400 Character（确定性边界）。
    private static let contextCharacters = 400
    /// ReaderLocation 前后缀已自带 32 Character 上限。

    // MARK: - 错误

    public enum PreparationError: Error, Equatable, Sendable {
        /// 预检有阻断问题仍被调用方放行。
        case precheckFailed([AIStudyPrecheckIssue])
        case documentMissing(UUID)
        /// 文档非 `.available`（missing/failed/processing）。
        case documentUnavailable(UUID)
        /// 范围内零块。
        case emptyScope
        /// `reader_documents.content_revision` 已漂移。
        case staleContent(expected: Int64, found: Int64)
        /// manifest JSON 超 `GRDBAIStudyManifestSchema.manifestMaxBytes`。
        case manifestTooLarge(bytes: Int)
        /// `ai_study_job_manifests` 无该 Job 行。
        case manifestMissing(jobID: UUID)
        /// manifest 自证不符（jobID/documentID/版本）。
        case manifestInvalid(jobID: UUID)
        /// 预览锚过时（epoch/scopeHash 漂移）——重取预览再确认。
        case stalePreview(jobID: UUID)
        /// Job 不在可确认状态。
        case jobNotConfirmable(jobID: UUID, status: AIStudyJobStatus)
        case jobNotFound(UUID)
        case invalidCorrection(tokenKey: String)
    }

    // MARK: - 内部：范围解析

    /// `AIStudyScopeRequest` → 冻结 `AIStudyScope` + 有序章列
    /// （currentText 场景 `chapters` 含宿主章，`blockIDs` 精确到块）。
    private struct ResolvedScope: Sendable {
        var scope: AIStudyScope
        var chapters: [ReaderChapterMetadata]
        /// 非 nil = currentText 精确块（只含该块）。
        var blockID: UUID?
    }

    /// 已处理章判定：`reader_study_occurrences` 在本文档+本 revision
    /// 存在非 pending 行的 `chapterOrdinal` 集（locator_json 内嵌
    /// `chapterOrdinal`——JSON1 投影）。pending-only 章视为未处理
    /// （上次准备取消/未跑完不应遮蔽本章）。
    private func processedChapterOrdinals(
        documentID: UUID, contentRevision: Int64
    ) async throws -> Set<Int> {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT
                        json_extract(locator_json, '$.chapterOrdinal')
                            AS chapter_ordinal
                    FROM reader_study_occurrences
                    WHERE document_id = ? AND content_revision = ?
                      AND resolution_status != 'pending'
                    """,
                arguments: [
                    DatabaseValueCodec.encode(documentID),
                    contentRevision,
                ])
            return Set(rows.compactMap { $0["chapter_ordinal"] as Int? })
        }
    }

    /// 上一行只判存在性；真正取行用 store（避免重复解码代码）。
    private func latestJob(
        documentID: UUID, contentRevision: Int64?
    ) async throws -> AIStudyJob? {
        try await pool.read { db in
            let sql: String
            var arguments = StatementArguments([
                DatabaseValueCodec.encode(documentID)])
            if let contentRevision {
                sql = """
                    SELECT id FROM ai_study_jobs
                    WHERE document_id = ? AND content_revision = ?
                    ORDER BY created_at_ms DESC LIMIT 1
                    """
                arguments += [contentRevision]
            } else {
                sql = """
                    SELECT id FROM ai_study_jobs
                    WHERE document_id = ?
                      AND status NOT IN ('completed','cancelled','failed')
                    ORDER BY updated_at_ms DESC LIMIT 1
                    """
            }
            guard let row = try Row.fetchOne(db, sql: sql,
                                             arguments: arguments)
            else { return nil }
            let id: UUID = try DatabaseValueCodec.decodeUUID(row["id"])
            return try GRDBAIStudyJobStore.fetchJob(id: id, in: db)
        }
    }

    private func resolveScope(
        documentID: UUID,
        contentRevision: Int64,
        request: AIStudyScopeRequest
    ) async throws -> ResolvedScope {
        let chapters = try await reader.fetchChapters(documentID: documentID)
            .sorted { $0.ordinal < $1.ordinal }
        switch request.choice {
        case .wholeBook:
            return ResolvedScope(scope: .fullDocument, chapters: chapters)
        case .currentChapter:
            guard let chapterID = request.chapterID,
                  let chapter = chapters.first(where: {
                      $0.id == chapterID
                  }) else {
                throw PreparationError.emptyScope
            }
            return ResolvedScope(
                scope: .chapters([chapter.canonicalHash]),
                chapters: [chapter])
        case .unprocessedChapters:
            let processed = try await processedChapterOrdinals(
                documentID: documentID, contentRevision: contentRevision)
            let pending = chapters.filter {
                !processed.contains($0.ordinal)
            }
            return ResolvedScope(
                scope: .chapters(pending.map(\.canonicalHash)),
                chapters: pending)
        case .currentText:
            guard let blockID = request.blockID else {
                throw PreparationError.emptyScope
            }
            // 宿主章一次 SQL 定位（不遍历全书取块）。
            let chapterID: UUID? = try await pool.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT chapter_id FROM reader_blocks WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(blockID)]
                ).flatMap { row in
                    try? DatabaseValueCodec.decodeUUID(row["chapter_id"])
                }
            }
            guard let chapterID,
                  let chapter = chapters.first(where: {
                      $0.id == chapterID
                  }) else {
                throw PreparationError.emptyScope
            }
            return ResolvedScope(
                scope: .chapters([chapter.canonicalHash]),
                chapters: [chapter],
                blockID: blockID)
        }
    }

    // MARK: - 内部：token 供给（缓存 → tokenize → 暂存）

    private struct MaterializedBlock: Sendable {
        var record: ReaderBlock
        var chapter: ReaderChapterMetadata
        var scopeKey: String
        var tokens: [ReaderToken]
        /// 新 tokenize 待提交的缓存 payload（命中缓存为 nil）。
        var stagedCachePayload: Data?
    }

    /// `reader_token_cache` 全键命中（block+tokenizer+dictionary+
    /// text_hash 四分量——v17 表形态）→ 解码 tokens。
    private func cachedTokens(
        blockID: UUID,
        textHash: String,
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
                    DatabaseValueCodec.encode(blockID),
                    tokenizerVersion, dictionaryVersion, textHash,
                ]
            ) else { return nil }
            return ReaderTokenCacheCodec.decode(payload)
        }
    }

    /// 块序列物化：按 (章序, 块序) 逐块供给 tokens；miss 经
    /// `morphology.tokenize`（内部 cancellation-aware）并把 payload
    /// 暂存——**不在此提交**，由调用方批事务落库（取消无半块写）。
    private func materializeBlocks(
        documentID: UUID,
        contentRevision: Int64,
        scope: ResolvedScope,
        tokenizerVersion: String,
        dictionaryVersion: String,
        manifestBytesBudget: Int,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [MaterializedBlock] {
        var materialized: [MaterializedBlock] = []
        // manifest 字节下界累计：每块 sourceText + tokens 按 manifest
        // 同款 .sortedKeys 编码逐块求和——真 manifest 还含 entries/
        // 信封/上下文等额外字节，故此和严格 < 真载荷；超过预算即可
        // 提前判负（不会误杀），避免超大文档全量 tokenize 后才被拒
        // （S21 F1/F2：1MB 文档曾 269s + 1.1GB RSS 后才拒）。
        let payloadEncoder = JSONEncoder()
        payloadEncoder.outputFormatting = [.sortedKeys]
        var payloadFloor = 0
        var processed = 0
        // 先按章枚举块总数（进度分母——每章一次 count 不贵）。
        var chapterBlocks: [UUID: [ReaderBlock]] = [:]
        var total = 0
        for chapter in scope.chapters {
            let blocks = try await reader.fetchBlocks(
                documentID: documentID, chapterID: chapter.id
            ).sorted { $0.ordinal < $1.ordinal }
            let filtered = blocks.filter { block in
                scope.blockID == nil || block.id == scope.blockID
            }
            chapterBlocks[chapter.id] = filtered
            total += filtered.count
        }
        guard total > 0 else { throw PreparationError.emptyScope }

        for chapter in scope.chapters {
            guard let blocks = chapterBlocks[chapter.id] else { continue }
            for block in blocks {
                try Task.checkCancellation()
                let tokens: [ReaderToken]
                var staged: Data?
                if let cached = try await cachedTokens(
                    blockID: block.id,
                    textHash: block.textHash,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion
                ) {
                    tokens = cached
                } else {
                    tokens = try await morphology.tokenize(
                        MorphologyBlock(
                            blockID: block.id,
                            text: block.text,
                            textHash: block.textHash))
                    staged = try ReaderTokenCacheCodec.encode(tokens)
                }
                let scopeKey = Self.scopeKey(
                    documentID: documentID,
                    contentRevision: contentRevision,
                    chapterOrdinal: chapter.ordinal,
                    blockOrdinal: block.ordinal)
                materialized.append(MaterializedBlock(
                    record: block, chapter: chapter,
                    scopeKey: scopeKey, tokens: tokens,
                    stagedCachePayload: staged))
                payloadFloor += block.text.utf8.count
                    + (try payloadEncoder.encode(
                        tokens.map { CachedReaderToken(token: $0) })
                    ).count
                if payloadFloor > manifestBytesBudget {
                    throw PreparationError.manifestTooLarge(
                        bytes: payloadFloor)
                }
                processed += 1
                progress?(processed, total)
            }
        }
        return materialized
    }

    static func scopeKey(
        documentID: UUID,
        contentRevision: Int64,
        chapterOrdinal: Int,
        blockOrdinal: Int
    ) -> String {
        "doc:\(documentID.uuidString.lowercased())"
            + ":rev:\(contentRevision)"
            + ":ch:\(chapterOrdinal):b:\(blockOrdinal)"
    }

    // MARK: - 内部：occurrence 证据行

    /// token 级 locator（occurrence 唯一键的 locator_json 分量）：
    /// `blockOrdinal/chapterOrdinal` 供章归属 SQL 投影，
    /// `utf16Offset` 记 token 起点，`blockTextHash` 重链锚。
    private static func occurrenceLocator(
        block: MaterializedBlock, tokenStartUTF16: Int
    ) throws -> String {
        let units = Array(block.record.text.utf16)
        let prefixRange = max(0, tokenStartUTF16 - 32)..<tokenStartUTF16
        let suffixStart = tokenStartUTF16
        let suffixEnd = min(units.count, tokenStartUTF16 + 32)
        let location = ReaderLocation(
            chapterOrdinal: block.chapter.ordinal,
            blockOrdinal: block.record.ordinal,
            utf16Offset: tokenStartUTF16,
            blockTextHash: block.record.textHash,
            prefix: String(decoding: units[prefixRange], as: UTF16.self),
            suffix: String(decoding: units[suffixStart..<suffixEnd],
                           as: UTF16.self))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(location)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }

    /// 批事务提交：暂存 token payload + pending occurrence 锚点
    /// （INSERT OR IGNORE——已有行保留其 resolution_status/链接）。
    /// 事务入口先 `checkCancellation`：取消不提交本批。
    private func commitBatch(
        documentID: UUID,
        contentRevision: Int64,
        tokenizerVersion: String,
        dictionaryVersion: String,
        blocks: [MaterializedBlock],
        atMs: Int64
    ) async throws {
        guard !blocks.isEmpty else { return }
        try await pool.write { db in
            try Task.checkCancellation()
            for block in blocks {
                if let payload = block.stagedCachePayload {
                    try db.execute(
                        sql: """
                            INSERT INTO reader_token_cache(
                                block_id, text_hash, tokenizer_version,
                                dictionary_version, payload
                            ) VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT(
                                block_id, tokenizer_version,
                                dictionary_version)
                            DO UPDATE SET
                                text_hash = excluded.text_hash,
                                payload = excluded.payload
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(block.record.id),
                            block.record.textHash,
                            tokenizerVersion, dictionaryVersion, payload,
                        ])
                }
                for token in block.tokens
                where token.tokenClass.countsForCoverage {
                    let locator = try Self.occurrenceLocator(
                        block: block,
                        tokenStartUTF16: token.sourceRangeUTF16.lowerBound)
                    try db.execute(
                        sql: """
                            INSERT INTO reader_study_occurrences(
                                id, document_id, content_revision,
                                locator_json, block_source_hash,
                                tokenizer_version, start_utf16,
                                length_utf16, resolution_status
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending')
                            ON CONFLICT(
                                document_id, content_revision,
                                locator_json, tokenizer_version,
                                start_utf16, length_utf16)
                            DO NOTHING
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(UUID()),
                            DatabaseValueCodec.encode(documentID),
                            contentRevision,
                            locator,
                            block.record.textHash,
                            tokenizerVersion,
                            token.sourceRangeUTF16.lowerBound,
                            token.sourceRangeUTF16.count,
                        ])
                }
            }
        }
    }

    // MARK: - 预检

    /// 预检：范围解析 + 估算 + 冲突/提供方就绪汇总（零写入）。
    public func preflight(
        documentID: UUID,
        request: AIStudyScopeRequest,
        provider: AIStudyProviderReadiness
    ) async throws -> AIStudyPrecheckReport {
        guard let document = try await reader.fetchDocument(id: documentID)
        else {
            throw PreparationError.documentMissing(documentID)
        }
        var issues: [AIStudyPrecheckIssue] = []
        var warnings: [String] = []
        if document.availability != .available {
            issues.append(.documentUnavailable)
        }
        let revision = Int64(document.contentRevision)

        // 词典元数据缺席降级为非 fatal（OOV 照常推进）。
        let dictionaryVersion = await ensureDictionaryVersion()
        let metadataAvailable = (try? await dictionary.metadata()) != nil
        if !metadataAvailable {
            issues.append(.dictionaryUnavailable)
            warnings.append("词典不可用——本次分析将不附词典候选。")
        }
        let tokenizerVersion = Self.tokenizerVersion(
            parserVersion: document.parserVersion,
            morphologyVersion: morphology.morphologyVersion,
            osBuild: morphology.osBuild)

        // 范围解析（unprocessedChapters 需要 revision 口径的
        // occurrence 投影）。
        var scope: ResolvedScope?
        var chapterBlocks: [UUID: [ReaderBlock]] = [:]
        do {
            scope = try await resolveScope(
                documentID: documentID,
                contentRevision: revision,
                request: request)
        } catch PreparationError.emptyScope {
            issues.append(.emptyScope)
        }
        if let scope {
            for chapter in scope.chapters {
                let blocks = try await reader.fetchBlocks(
                    documentID: documentID, chapterID: chapter.id
                ).sorted { $0.ordinal < $1.ordinal }
                chapterBlocks[chapter.id] = blocks.filter {
                    scope.blockID == nil || $0.id == scope.blockID
                }
            }
        }

        // 估算：命中缓存的块给精确 token 数；miss 块走启发式上界
        // （≈0.45 token/UTF-16 unit——日语块均值的保守高估）。
        var blockCount = 0
        var totalUTF16 = 0
        var cachedBlockCount = 0
        var exactTargetTokens = 0
        var uncachedUTF16 = 0
        var uniqueKeys = Set<String>()
        for chapter in scope?.chapters ?? [] {
            for block in chapterBlocks[chapter.id] ?? [] {
                blockCount += 1
                let utf16 = block.text.utf16.count
                totalUTF16 += utf16
                if let tokens = try await cachedTokens(
                    blockID: block.id,
                    textHash: block.textHash,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion
                ) {
                    cachedBlockCount += 1
                    for token in tokens
                    where token.tokenClass.countsForCoverage {
                        exactTargetTokens += 1
                        uniqueKeys.insert(
                            (token.lexicalKey?.identityKey ?? "")
                                + "|"
                                + (token.reading ?? token.surface))
                    }
                } else {
                    uncachedUTF16 += utf16
                }
            }
        }
        let uncachedTokenEstimate = Int(
            (Double(uncachedUTF16) * 0.45).rounded(.up))
        let targetTokenCount = exactTargetTokens + uncachedTokenEstimate
        // 唯一单元估算：缓存命中部分取精确去重数；miss 部分按
        // 「每个 token 都可能新单元」上界（加和为上界估值）。
        let uniqueUnitEstimate = uniqueKeys.count + uncachedTokenEstimate
        // 请求数：双约束上界（≤40 occ/请求 且 ≤48KiB 输入预算）——
        // 不跑 planner 的粗略打包下界估算，如实标注非精确。
        let tokenBound = max(1, targetTokenCount / 40)
        let byteBound = max(1, totalUTF16 * 2 / (48 * 1024))
        let requestEstimate = max(
            min(blockCount, max(tokenBound, byteBound)), 1)

        if blockCount == 0, !issues.contains(.emptyScope) {
            issues.append(.emptyScope)
        }
        let tokenEstimateExact = cachedBlockCount == blockCount
        if tokenEstimateExact && targetTokenCount == 0 && blockCount > 0 {
            issues.append(.noTargetTokens)
        }

        // Job 冲突/陈旧提示（同 revision 活跃 Job = fatal）。
        let activeJob = try await jobStore.fetchActiveJob(
            documentID: documentID, contentRevision: revision)
        if let activeJob {
            issues.append(.activeJobConflict(
                jobID: activeJob.id, status: activeJob.status))
        }
        let stale = try await latestJob(
            documentID: documentID, contentRevision: nil)
            .flatMap { job -> AIStudyJob? in
                job.contentRevision == revision ? nil : job
            }
        let existing = try await latestJob(
            documentID: documentID, contentRevision: revision)

        // Provider 就绪（非 fatal——允许离线建队，派发期暴露）。
        switch provider.state {
        case .ready: break
        case .disabled: issues.append(.providerDisabled)
        case .missingModel: issues.append(.providerMissingModel)
        case .missingKey: issues.append(.providerMissingKey)
        }
        if request.choice == .unprocessedChapters,
           scope?.chapters.isEmpty == true {
            warnings.append("当前修订下所有章节均已产生解析证据。")
        }

        return AIStudyPrecheckReport(
            documentID: documentID,
            documentTitle: document.title,
            contentRevision: revision,
            request: request,
            estimate: AIStudyEstimate(
                chapterCount: scope?.chapters.count ?? 0,
                blockCount: blockCount,
                totalUTF16Length: totalUTF16,
                targetTokenCount: targetTokenCount,
                uniqueUnitEstimate: uniqueUnitEstimate,
                requestEstimate: requestEstimate,
                cachedTokenBlockCount: cachedBlockCount),
            provider: provider,
            existingJob: existing,
            activeJob: activeJob,
            staleJob: stale,
            issues: issues,
            warnings: warnings)
    }

    static func tokenizerVersion(
        parserVersion: String,
        morphologyVersion: String,
        osBuild: String
    ) -> String {
        "\(parserVersion)|\(morphologyVersion)|\(osBuild)"
    }

    /// NL 服务 dataset 版本在首次 tokenize 后才回填——未取到先以
    /// 空块热身（coverage 服务同款；不产生写）。
    private func ensureDictionaryVersion() async -> String {
        var version = morphology.dictionaryDatasetVersion
        if version.isEmpty || version == "unopened" {
            _ = try? await morphology.tokenize(
                MorphologyBlock(
                    blockID: UUID(), text: "", textHash: "warmup"))
            version = morphology.dictionaryDatasetVersion
        }
        return version.isEmpty ? "unknown" : version
    }

    // MARK: - 准备（Job + manifest 原子提交）

    /// 创建 Job：token 编排 + manifest 冻结 + `ai_study_jobs` 行 +
    /// 文章绑定牌组（容器元数据）——单写事务提交，取消/失败全回滚。
    /// 预检报告作为陈旧防线：scope/revision 漂移即拒。
    @discardableResult
    public func prepare(
        documentID: UUID,
        report: AIStudyPrecheckReport,
        configuration: ResolvedAIConfiguration,
        wantsTranslation: Bool = true,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> AIStudyJob {
        guard report.documentID == documentID,
              report.estimate.blockCount > 0,
              !report.issues.contains(where: \.isFatal) else {
            throw PreparationError.precheckFailed(report.issues)
        }
        guard let document = try await reader.fetchDocument(id: documentID)
        else { throw PreparationError.documentMissing(documentID) }
        let revision = Int64(document.contentRevision)
        guard document.availability == .available else {
            throw PreparationError.documentUnavailable(documentID)
        }
        guard revision == report.contentRevision else {
            throw PreparationError.staleContent(
                expected: report.contentRevision, found: revision)
        }

        let dictionaryVersion = await ensureDictionaryVersion()
        let tokenizerVersion = Self.tokenizerVersion(
            parserVersion: document.parserVersion,
            morphologyVersion: morphology.morphologyVersion,
            osBuild: morphology.osBuild)

        let scope = try await resolveScope(
            documentID: documentID,
            contentRevision: revision,
            request: report.request)
        let blocks = try await materializeBlocks(
            documentID: documentID,
            contentRevision: revision,
            scope: scope,
            tokenizerVersion: tokenizerVersion,
            dictionaryVersion: dictionaryVersion,
            manifestBytesBudget: GRDBAIStudyManifestSchema
                .manifestMaxBytes,
            progress: progress)

        // manifest 先行构建+尺寸核验——`manifestTooLarge` 必须在
        // 任何证据提交前抛出，否则超大文档会留下数万条孤儿
        // occurrence/token-cache 行（S21 F1：1MB 文档曾 commit
        // 151k occurrence 后才被拒）。
        var seenIDs = Set<Int64>()
        let wantedIDs = blocks.flatMap { block in
            block.tokens
                .filter { $0.tokenClass.countsForCoverage }
                .flatMap(\.candidates).compactMap(\.entryID)
        }.filter { seenIDs.insert($0).inserted }
        var manifestEntries: [AIStudyJobManifest.Entry] = []
        for chunk in wantedIDs.chunkedPreparation(dictionaryBatchSize) {
            try Task.checkCancellation()
            let entries = try await dictionary.entries(ids: Array(chunk))
            manifestEntries.append(
                contentsOf: entries.map { .init(entry: $0) })
        }
        manifestEntries.sort { $0.id < $1.id }

        let jobID = UUID()
        let manifest = try buildManifest(
            jobID: jobID, documentID: documentID,
            contentRevision: revision,
            scope: scope.scope,
            blocks: blocks,
            entries: manifestEntries,
            configuration: configuration,
            parserVersion: document.parserVersion,
            dictionaryDatasetVersion: dictionaryVersion,
            tokenizerVersion: tokenizerVersion,
            wantsTranslation: wantsTranslation)
        let payload = try manifest.encoded()
        guard payload.count
                <= GRDBAIStudyManifestSchema.manifestMaxBytes else {
            throw PreparationError.manifestTooLarge(bytes: payload.count)
        }

        // 分批提交证据（cache payload + occurrence pending 锚点）；
        // 批大小 commitBatchSize，取消点在事务首行。
        var batch: [MaterializedBlock] = []
        for block in blocks {
            try Task.checkCancellation()
            batch.append(block)
            if batch.count >= commitBatchSize {
                try await commitBatch(
                    documentID: documentID,
                    contentRevision: revision,
                    tokenizerVersion: tokenizerVersion,
                    dictionaryVersion: dictionaryVersion,
                    blocks: batch, atMs: nowMs)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try await commitBatch(
            documentID: documentID, contentRevision: revision,
            tokenizerVersion: tokenizerVersion,
            dictionaryVersion: dictionaryVersion,
            blocks: batch, atMs: nowMs)

        let fingerprint = AIStudyInputFingerprint.compute(
            documentID: documentID,
            contentRevision: revision,
            scopeHash: scope.scope.scopeHash,
            blockHashes: blocks.map {
                "\($0.scopeKey)|\($0.record.textHash)"
            },
            dictionaryDatasetVersion: dictionaryVersion,
            morphologyVersion: morphology.morphologyVersion,
            parserVersion: document.parserVersion,
            osBuild: morphology.osBuild,
            providerKind: configuration.serviceKind.rawValue,
            endpointFingerprint: manifest.endpointFingerprint,
            model: configuration.modelID,
            responseMode: configuration.responseFormatMode.rawValue,
            promptVersion: AIStudyPrompt.promptVersion,
            language: manifest.language,
            policyVersion: AIStudyPreparation.policyVersion)

        let job = AIStudyJob(
            id: jobID,
            documentID: documentID,
            studyDeckID: nil,   // 事务内 ensureStudyDeck 回填
            scope: scope.scope,
            inputFingerprint: fingerprint,
            contentRevision: revision,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: configuration.serviceKind.rawValue,
                model: configuration.modelID,
                responseMode: configuration.responseFormatMode.rawValue,
                promptVersion: AIStudyPrompt.promptVersion,
                policyVersion: AIStudyPreparation.policyVersion),
            model: configuration.modelID,
            pipelineVersion: AIStudyPreparation.pipelineVersion,
            promptVersion: AIStudyPrompt.promptVersion,
            policyVersion: AIStudyPreparation.policyVersion,
            status: .pending,
            createdAtMs: nowMs,
            updatedAtMs: nowMs)

        // 单事务：revision 复核 → 牌组绑定（D14）→ Job 行 →
        // manifest 行——任一失败全回滚。
        let atMs = nowMs
        let expectedRevision = Int(revision)
        return try await pool.write { db in
            try Task.checkCancellation()
            let currentRevision = try Int.fetchOne(
                db,
                sql: """
                    SELECT content_revision FROM reader_documents
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)])
            guard currentRevision == expectedRevision,
                  currentRevision != nil else {
                throw PreparationError.staleContent(
                    expected: revision,
                    found: Int64(currentRevision ?? -1))
            }
            let deckID = try GRDBReaderStudyDeckService.ensureStudyDeck(
                documentID: documentID,
                expectedContentRevision: expectedRevision,
                at: now(), in: db)
            var bound = job
            bound.studyDeckID = deckID
            try GRDBAIStudyJobStore.insertJob(bound, in: db)
            try db.execute(
                sql: """
                    INSERT INTO ai_study_job_manifests(
                        job_id, manifest, created_at_ms
                    ) VALUES (?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(jobID),
                    payload, atMs,
                ])
            return bound
        }
    }

    // MARK: - manifest 读写/重建

    /// 清单持久化读（缺席 → nil——调用方按 missingSource 拒绝续跑）。
    public func loadManifest(
        jobID: UUID
    ) async throws -> AIStudyJobManifest? {
        guard let data = try await pool.read({ db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT manifest FROM ai_study_job_manifests
                    WHERE job_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(jobID)])
        }) else { return nil }
        return try AIStudyJobManifest.decode(data)
    }

    /// 冻结清单 → planner 输入快照装配（词典快照为唯一 sense 源）。
    public struct ManifestSenseSource: AIStudySenseSource {
        private let entriesByID: [Int64: DictionaryEntry]

        public init(manifest: AIStudyJobManifest) {
            entriesByID = Dictionary(
                uniqueKeysWithValues: manifest.dictionaryEntries
                    .map { ($0.id, $0.materialize()) })
        }

        public func entries(ids: [Int64]) async throws
            -> [DictionaryEntry] {
            ids.compactMap { entriesByID[$0] }
        }
    }

    /// manifest → `AIStudyPlannerInput`（逐块重建——恢复路径与首跑
    /// 共用同一构造，保证 requestHash 逐字节一致）。
    private func plannerInput(
        for block: AIStudyJobManifest.Block
    ) -> AIStudyPlannerInput {
        AIStudyPlannerInput(
            scopeKey: block.scopeKey,
            sourceText: block.sourceText,
            context: block.context,
            tokens: block.materializedTokens,
            sentenceRanges: block.materializedSentenceRanges,
            wantsTranslation: block.wantsTranslation)
    }

    /// Runner 的 planner 闭包实现：`insertBlocksIfAbsent` 形态
    /// （不覆盖 checkpoint；subblock 行 id 每次随机——唯一键在
    /// `(job_id, subblock_key)`，重放命中即跳）。
    public func plannedBlocks(
        for job: AIStudyJob
    ) async throws -> [AIStudyRunner.PlannedBlock] {
        guard let manifest = try await loadManifest(jobID: job.id) else {
            throw PreparationError.manifestMissing(jobID: job.id)
        }
        guard manifest.jobID == job.id,
              manifest.documentID == job.documentID,
              manifest.formatVersion
                == AIStudyPreparation.manifestFormatVersion else {
            throw PreparationError.manifestInvalid(jobID: job.id)
        }
        let planner = AIStudyCandidatePlanner(
            senseSource: ManifestSenseSource(manifest: manifest),
            maxGlossesPerSense: manifest.maxGlossesPerSense)
        let metadata = manifest.requestMetadata
        var planned: [AIStudyRunner.PlannedBlock] = []
        for block in manifest.blocks {
            try Task.checkCancellation()
            let requests = try await planner.plan(
                plannerInput(for: block), metadata: metadata)
            for request in requests {
                guard let payload = request.blocks.first else {
                    continue
                }
                planned.append(AIStudyRunner.PlannedBlock(
                    block: AIStudyJobBlock(
                        id: UUID(),
                        jobID: job.id,
                        locatorJSON: try Self.subblockLocator(
                            block: block, request: request),
                        sourceHash: block.sourceHash,
                        subblockKey: payload.blockKey,
                        candidateSetHash: payload.candidateSetHash,
                        requestHash: request.requestHash),
                    request: request))
            }
        }
        return planned
    }

    /// subblock 定位 JSON（`ai_study_job_blocks.locator_json` +
    /// resolution 行 locator 的规范形态）。
    static func subblockLocator(
        block: AIStudyJobManifest.Block,
        request: AIStudyRequest
    ) throws -> String {
        guard let target = request.blocks.first else {
            throw CocoaError(.coderInvalidValue)
        }
        let units = Array(block.sourceText.utf16)
        let start = target.targetUTF16Start
        let end = start + target.targetUTF16Length
        let prefixRange = max(0, start - 32)..<start
        let suffixRange = min(end, units.count)..<min(units.count, end + 32)
        let location = ReaderLocation(
            chapterOrdinal: block.chapterOrdinal,
            blockOrdinal: block.blockOrdinal,
            utf16Offset: start,
            blockTextHash: block.sourceHash,
            prefix: String(decoding: units[prefixRange], as: UTF16.self),
            suffix: String(decoding: units[suffixRange], as: UTF16.self))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(location)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }

    private func buildManifest(
        jobID: UUID,
        documentID: UUID,
        contentRevision: Int64,
        scope: AIStudyScope,
        blocks: [MaterializedBlock],
        entries: [AIStudyJobManifest.Entry],
        configuration: ResolvedAIConfiguration,
        parserVersion: String,
        dictionaryDatasetVersion: String,
        tokenizerVersion: String,
        wantsTranslation: Bool
    ) throws -> AIStudyJobManifest {
        // 上下文：前一块尾 400 Character（确定性窗口）。
        var manifestBlocks: [AIStudyJobManifest.Block] = []
        manifestBlocks.reserveCapacity(blocks.count)
        var previousText = ""
        for block in blocks {
            let context = previousText.isEmpty
                ? ""
                : String(previousText.suffix(Self.contextCharacters))
            let ranges = AIStudySentenceSegments.ranges(
                of: block.record.text)
            manifestBlocks.append(AIStudyJobManifest.Block(
                scopeKey: block.scopeKey,
                readerBlockID: block.record.id,
                chapterID: block.chapter.id,
                chapterOrdinal: block.chapter.ordinal,
                blockOrdinal: block.record.ordinal,
                sourceHash: block.record.textHash,
                sourceText: block.record.text,
                context: context,
                sentenceRanges: ranges.flatMap { [$0.lowerBound,
                                                 $0.upperBound] },
                wantsTranslation: wantsTranslation,
                tokens: block.tokens.map { CachedReaderToken(token: $0) }))
            previousText = block.record.text
        }
        return AIStudyJobManifest(
            jobID: jobID,
            documentID: documentID,
            contentRevision: contentRevision,
            scope: scope,
            parserVersion: parserVersion,
            morphologyVersion: morphology.morphologyVersion,
            osBuild: morphology.osBuild,
            dictionaryDatasetVersion: dictionaryDatasetVersion,
            tokenizerVersion: tokenizerVersion,
            providerKind: configuration.serviceKind.rawValue,
            endpointFingerprint: AIStudyEndpointFingerprint.normalize(
                configuration.baseURL.absoluteString),
            model: configuration.modelID,
            responseMode: configuration.responseFormatMode.rawValue,
            promptVersion: AIStudyPrompt.promptVersion,
            language: AIStudyPreparation.targetLanguage,
            maxGlossesPerSense: maxGlossesPerSense,
            blocks: manifestBlocks,
            dictionaryEntries: entries)
    }

    // MARK: - Runner 收束：occurrence 回填 + 译文发布

    /// 分析收束后的证据收尾（幂等——重跑无害）：
    /// 1. occurrence：按 resolution 最新 revision 回填
    ///    `resolution_status`/`resolution_id`（tokenKey → 块内
    ///    UTF-16 range 由 manifest replan 反查）。
    /// 2. 译文：`translationStatus == .done` 的块经
    ///    `GRDBReaderTranslationStore.publish` 落库（校验+历史保留
    ///    由 publish 保证；locatorKey 走 S17 `ReaderTranslationLocator`
    ///    规范 `tr:` 形态——由 subblockKey/锚点 JSON 派生）。
    public func finalizeResults(jobID: UUID) async throws {
        guard let job = try await jobStore.fetchJob(id: jobID) else {
            throw PreparationError.jobNotFound(jobID)
        }
        guard let manifest = try await loadManifest(jobID: jobID) else {
            throw PreparationError.manifestMissing(jobID: jobID)
        }
        let blocks = try await jobStore.fetchBlocks(jobID: jobID)
        guard !blocks.isEmpty else { return }

        // tokenKey → (manifest 块, UTF-16 range)：manifest replan
        // 反查（tokenID 由 blockKey+range 派生——重建同一映射）。
        let index = try await planIndex(manifest: manifest)
        let resolutions = try await pool.read { db in
            try GRDBAIStudyJobStore.fetchResolutions(jobID: jobID, in: db)
        }
        // 每 (requestHash,tokenKey) 取最高 revision（在闭包外物化——
        // @Sendable 闭包不能捕获 var）。
        var latest: [String: AIStudyResolutionRecord] = [:]
        for record in resolutions {
            let key = "\(record.requestHash)\u{1F}\(record.tokenKey)"
            if let existing = latest[key], existing.revision >= record.revision {
                continue
            }
            latest[key] = record
        }
        // 只读缓存读（`cachedResult` 带 LRU touch 写——read 语境
        // 下用直读 SQL，不挪 last_accessed_at_ms）。
        let cached: [String: AIStudyCachedResult] = try await pool.read { db in
            var results: [String: AIStudyCachedResult] = [:]
            for block in blocks {
                if let result = try Self.cachedResultReadOnly(
                    requestHash: block.requestHash, in: db) {
                    results[block.subblockKey] = result
                }
            }
            return results
        }

        let latestRecords = Array(latest.values)
        try await pool.write { db in
            try Task.checkCancellation()
            // occurrence 回填：块行 locator 记章/块序 + token 起讫。
            for record in latestRecords {
                guard let token = index.token(record.tokenKey,
                                            requestHash: record.requestHash)
                else { continue }
                let status: String
                switch record.status {
                case .aiResolved: status = "aiResolved"
                case .userConfirmed: status = "userConfirmed"
                case .lowConfidence: status = "lowConfidence"
                case .unresolved: status = "unresolved"
                case .rejected: status = "rejected"
                }
                try db.execute(
                    sql: """
                        UPDATE reader_study_occurrences
                        SET resolution_status = ?, resolution_id = ?,
                            unit_id = COALESCE(?, unit_id)
                        WHERE document_id = ? AND content_revision = ?
                          AND tokenizer_version = ?
                          AND start_utf16 = ? AND length_utf16 = ?
                          AND json_extract(locator_json,'$.chapterOrdinal')
                              = ?
                          AND json_extract(locator_json,'$.blockOrdinal')
                              = ?
                        """,
                    arguments: [
                        status,
                        DatabaseValueCodec.encode(record.id),
                        // S20：resolution 已绑 unit（重收束/部分应用后
                        // 路径）时一并回填——NULL 则保留既有值，
                        // 绝不把已绑定链接清掉。
                        record.unitID.map(DatabaseValueCodec.encode),
                        DatabaseValueCodec.encode(job.documentID),
                        job.contentRevision,
                        manifest.tokenizerVersion,
                        token.utf16Start, token.utf16Length,
                        token.chapterOrdinal, token.blockOrdinal,
                    ])
            }
            // 译文发布（publish 自带校验/历史/原子切换）。
            for block in blocks
            where block.status == .resolved {
                guard let result = cached[block.subblockKey],
                      result.translationStatus == .done,
                      let translation = result.translation,
                      !translation.isEmpty
                else { continue }
                _ = try GRDBReaderTranslationStore.publish(
                    documentID: job.documentID,
                    locatorKey: Self.translationLocatorKey(for: block),
                    locatorJSON: block.locatorJSON,
                    sourceHash: block.sourceHash,
                    language: manifest.language,
                    translatedText: translation,
                    provider: result.providerKind,
                    model: result.model,
                    promptVersion: result.promptVersion,
                    requestHash: result.requestHash,
                    at: now(), in: db)
            }
        }

        // S20：收束即落整文档 Coverage v2 快照（best-effort——
        // 快照是历史留痕，失败只记日志绝不让 finalize 失败）。
        // 版本分量取 Job 冻结 manifest——快照必须归因到产出它的
        // 分析上下文，不是调用当下的词典/形态状态。
        await recordCoverageSnapshot(
            documentID: job.documentID,
            dictionaryVersion: manifest.dictionaryDatasetVersion,
            morphologyVersion: manifest.morphologyVersion)
    }

    /// v26 快照 best-effort 写入（S20 集成点）：独立短事务，
    /// 失败经 `snapshotLogger` 记录后继续——度量行绝不当业务
    /// 失败的乘数。同度量上下文重放由唯一键去重（幂等）。
    private func recordCoverageSnapshot(
        documentID: UUID,
        dictionaryVersion: String,
        morphologyVersion: String
    ) async {
        do {
            try await pool.write { db in
                _ = try GRDBReaderCoverageSnapshotStore
                    .recordDocumentSnapshot(
                        documentID: documentID,
                        dictionaryVersion: dictionaryVersion,
                        morphologyVersion: morphologyVersion,
                        at: now(), in: db)
            }
        } catch {
            Self.snapshotLogger.error(
                "coverage snapshot skipped for \(documentID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// S20 快照失败的统一日志点（finalize/其他触发点同纪律）。
    private static let snapshotLogger = Logger(
        subsystem: "com.oboe.infra",
        category: "ai-study-coverage")

    /// job block → S17 译文 locator_key：`tr:ch:<co>:b:<bo>#r<s>-<e>`
    /// （序数取块行 locatorJSON，区间取 subblockKey `#r` 后缀）。
    /// 解析失败回落原 subblockKey——渲染侧按 locatorJSON 序数锚定，
    /// key 形态差异不影响落位正确性。
    static func translationLocatorKey(for block: AIStudyJobBlock) -> String {
        guard let anchor = ReaderTranslationLocator.anchor(
            locatorKey: block.subblockKey,
            locatorJSON: block.locatorJSON
        ) else { return block.subblockKey }
        return ReaderTranslationLocator.key(
            chapterOrdinal: anchor.chapterOrdinal,
            blockOrdinal: anchor.blockOrdinal,
            utf16Range: anchor.range)
    }

    // MARK: - 预览装配

    /// manifest replan 的共享索引：tokenKey→(token, 块序) +
    /// requestHash→request。
    private struct PlanIndex: Sendable {
        /// tokenKey → 定位分量（供 occurrence/sentence 反查）。
        struct TokenAnchor: Sendable {
            var token: AIStudyToken
            var manifestBlock: AIStudyJobManifest.Block
            var chapterOrdinal: Int { manifestBlock.chapterOrdinal }
            var blockOrdinal: Int { manifestBlock.blockOrdinal }
            var utf16Start: Int { token.utf16Start }
            var utf16Length: Int { token.utf16Length }
        }
        var tokens: [String: TokenAnchor] = [:]
        var requests: [String: AIStudyRequest] = [:]
        /// manifestBlock.scopeKey → 源块（firstSentence 切片用）。
        var blocks: [String: AIStudyJobManifest.Block] = [:]

        func token(_ tokenKey: String, requestHash: String)
            -> TokenAnchor? {
            // requestHash → request → blockKey 限定 tokenKey 域
            // （tokenID 仅块内唯一，跨块重名理论可能）。
            guard let request = requests[requestHash],
                  let block = request.blocks.first else { return nil }
            return tokens["\(block.blockKey)\u{1F}\(tokenKey)"]
                ?? tokens[tokenKey]
        }

        mutating func absorb(
            request: AIStudyRequest,
            manifestBlock: AIStudyJobManifest.Block
        ) {
            requests[request.requestHash] = request
            for block in request.blocks {
                for token in block.tokens {
                    let anchor = TokenAnchor(
                        token: token, manifestBlock: manifestBlock)
                    tokens[token.tokenID] = anchor
                    tokens["\(block.blockKey)\u{1F}\(token.tokenID)"]
                        = anchor
                }
            }
        }
    }

    /// `ai_study_cache` 只读探测（**不含** `cachedResult` 的 LRU
    /// touch 写）——read 事务/preview 路径专用。
    static func cachedResultReadOnly(
        requestHash: String, in db: Database
    ) throws -> AIStudyCachedResult? {
        guard let json = try String.fetchOne(
            db,
            sql: """
                SELECT validated_result_json FROM ai_study_cache
                WHERE request_hash = ?
                """,
            arguments: [requestHash]),
              let data = json.data(using: .utf8)
        else { return nil }
        return try JSONDecoder().decode(AIStudyCachedResult.self,
                                        from: data)
    }

    private func planIndex(
        manifest: AIStudyJobManifest
    ) async throws -> PlanIndex {
        let planner = AIStudyCandidatePlanner(
            senseSource: ManifestSenseSource(manifest: manifest),
            maxGlossesPerSense: manifest.maxGlossesPerSense)
        let metadata = manifest.requestMetadata
        var index = PlanIndex()
        for block in manifest.blocks {
            try Task.checkCancellation()
            let requests = try await planner.plan(
                plannerInput(for: block), metadata: metadata)
            for request in requests {
                index.absorb(request: request, manifestBlock: block)
            }
            index.blocks[block.scopeKey] = block
        }
        return index
    }

    /// unit 身份键：`jmdict:sense-v1:<entryID>:<fingerprint>`——
    /// 与 `DictionarySenseBinding.identityKey` 同一格式（S05 键空间）。
    private func unitKey(
        entryID: Int64,
        sense: DictionarySense?
    ) -> String? {
        guard let sense else { return nil }
        return "jmdict:sense-v1:\(entryID):"
            + SemanticFingerprint.compute(entryID: entryID, sense: sense)
    }

    /// 预览聚合：`ai_study_resolutions` 最新 revision → unit 分组 +
    /// 待确认队列 + 既有学习态复核（units/flags/links/Notes 批量
    /// IN 读——确认前仍零写）。
    public func buildPreview(
        jobID: UUID
    ) async throws -> AIStudyPreview {
        let nowMs = nowMs
        guard let job = try await jobStore.fetchJob(id: jobID) else {
            throw PreparationError.jobNotFound(jobID)
        }
        guard let manifest = try await loadManifest(jobID: jobID) else {
            throw PreparationError.manifestMissing(jobID: jobID)
        }
        let index = try await planIndex(manifest: manifest)
        let manifestEntries = Dictionary(
            uniqueKeysWithValues: manifest.dictionaryEntries
                .map { ($0.id, $0) })

        let snapshot = try await pool.read { db -> (
            blocks: [AIStudyJobBlock],
            resolutions: [AIStudyResolutionRecord],
            translatedCount: Int
        ) in
            let blocks = try GRDBAIStudyJobStore.fetchBlocks(
                jobID: jobID, in: db)
            let resolutions = try GRDBAIStudyJobStore.fetchResolutions(
                jobID: jobID, in: db)
            var translated = 0
            for block in blocks {
                if let result = try Self.cachedResultReadOnly(
                    requestHash: block.requestHash, in: db),
                   result.translationStatus == .done {
                    translated += 1
                }
            }
            return (blocks, resolutions, translated)
        }

        // 最新 revision/（request,token） 分组。
        var latest: [String: AIStudyResolutionRecord] = [:]
        for record in snapshot.resolutions {
            let key = "\(record.requestHash)\u{1F}\(record.tokenKey)"
            if let existing = latest[key],
               existing.revision >= record.revision { continue }
            latest[key] = record
        }

        // 按句中选定义项聚合：同义项重复出现复用，不同义项分别建卡。
        struct Aggregate {
            var entryID: Int64
            var senseID: Int64
            var occurrenceCount: Int
            var firstSentence: String?
            var firstLocator: String?
            var evidenceRevision: Int64
            var confidenceMin: Double?
            var confidenceMax: Double?
            var containsLowConfidence: Bool
        }
        var aggregates: [String: Aggregate] = [:]
        var pendingItems: [AIStudyPreviewPendingItem] = []

        let orderedRecords = latest.values.sorted { lhs, rhs in
            let l = index.token(lhs.tokenKey, requestHash: lhs.requestHash)
            let r = index.token(rhs.tokenKey, requestHash: rhs.requestHash)
            return (l?.chapterOrdinal ?? Int.max, l?.blockOrdinal ?? Int.max,
                    l?.utf16Start ?? Int.max, lhs.requestHash, lhs.tokenKey)
                < (r?.chapterOrdinal ?? Int.max, r?.blockOrdinal ?? Int.max,
                   r?.utf16Start ?? Int.max, rhs.requestHash, rhs.tokenKey)
        }
        for record in orderedRecords {
            let anchor = index.token(
                record.tokenKey, requestHash: record.requestHash)
            switch record.status {
            case .aiResolved, .userConfirmed:
                guard let entryID = record.selectedEntryID,
                      let senseID = record.selectedSenseID,
                      let entry = manifestEntries[entryID],
                      let sense = entry.senses.first(where: { $0.id == senseID }),
                      let key = unitKey(entryID: entryID, sense: sense.materialize()) else {
                    // 词典快照缺 entry/sense——按待确认占位
                    // （不伪候选、不静默吞证据）。
                    pendingItems.append(
                        pendingItem(for: record, anchor: anchor,
                                    manifest: manifest))
                    continue
                }
                let recordConfidence = record.confidence
                if var aggregate = aggregates[key] {
                    aggregate.occurrenceCount += 1
                    aggregate.evidenceRevision = max(
                        aggregate.evidenceRevision, record.revision)
                    if let confidence = recordConfidence {
                        if confidence
                            < AIStudyBudget.lowConfidenceThreshold {
                            aggregate.containsLowConfidence = true
                        }
                        aggregate.confidenceMin = min(
                            aggregate.confidenceMin ?? confidence,
                            confidence)
                        aggregate.confidenceMax = max(
                            aggregate.confidenceMax ?? confidence,
                            confidence)
                    }
                    aggregates[key] = aggregate
                } else {
                    aggregates[key] = Aggregate(
                        entryID: entryID,
                        senseID: senseID,
                        occurrenceCount: 1,
                        firstSentence: sentence(for: anchor),
                        firstLocator: anchor.map {
                            "第 \($0.chapterOrdinal + 1) 章 · 段 \($0.blockOrdinal + 1)"
                        },
                        evidenceRevision: record.revision,
                        confidenceMin: recordConfidence,
                        confidenceMax: recordConfidence,
                        containsLowConfidence:
                            (recordConfidence ?? 1)
                                < AIStudyBudget.lowConfidenceThreshold)
                }
            case .lowConfidence, .unresolved, .rejected:
                pendingItems.append(
                    pendingItem(for: record, anchor: anchor,
                                manifest: manifest))
            }
        }

        var items: [AIStudyPreviewItem] = []
        items.reserveCapacity(aggregates.count)
        for aggregate in aggregates.values {
            guard let entry = manifestEntries[aggregate.entryID]
            else { continue }
            guard let sense = entry.senses.first(where: { $0.id == aggregate.senseID }),
                  let key = unitKey(entryID: aggregate.entryID, sense: sense.materialize())
            else { continue }
            var item = AIStudyPreviewItem(
                unitKey: key,
                entryID: aggregate.entryID,
                senseID: sense.id,
                mergedSenseIDs: [sense.id],
                headword: entry.primaryForm,
                reading: entry.readings.first?.reading,
                glossSummary: sense.materialize().preferredGlosses()
                    .map { $0.glosses.map(\.text).joined(separator: "; ") },
                jlptLevel: nil,
                occurrenceCount: aggregate.occurrenceCount,
                firstSentence: aggregate.firstSentence,
                firstLocator: aggregate.firstLocator,
                evidenceRevision: aggregate.evidenceRevision,
                confidenceRange: nil,
                containsLowConfidence: aggregate.containsLowConfidence,
                existingUnitID: nil,
                unitIsTooEasy: false,
                linkedNotes: [],
                duplicateNotes: [],
                decision: nil,
                proposedAction: nil)
            if let lo = aggregate.confidenceMin,
               let hi = aggregate.confidenceMax, lo <= hi {
                item.confidenceRange = lo...hi
            }
            items.append(item)
        }
        items.sort { $0.unitKey < $1.unitKey }

        // 既有学习态复核 + JLPT 参考标签（两段都批量 IN）。
        await attachLearningState(to: &items)
        if let jlptIndex = try? await jlptIndexProvider?() {
            for idx in items.indices {
                items[idx].jlptLevel = jlptIndex.level(
                    headword: items[idx].headword,
                    reading: items[idx].reading)
            }
        }

        let blockCounts = snapshot.blocks.reduce(into: (
            resolved: 0, failed: 0, cancelled: 0)) { counts, block in
            switch block.status {
            case .resolved, .applied, .awaitingConfirmation:
                counts.resolved += 1
            case .failed:
                counts.failed += 1
            case .cancelled:
                counts.cancelled += 1
            default:
                break
            }
        }

        return AIStudyPreview(
            jobID: jobID,
            documentID: job.documentID,
            contentRevision: job.contentRevision,
            jobEpoch: job.epoch,
            jobStatus: job.status,
            scopeHash: job.scope.scopeHash,
            items: items,
            pending: pendingItems.sorted { $0.id < $1.id },
            totalBlockCount: snapshot.blocks.count,
            resolvedBlockCount: blockCounts.resolved,
            failedBlockCount: blockCounts.failed,
            cancelledBlockCount: blockCounts.cancelled,
            translatedBlockCount: snapshot.translatedCount,
            generatedAtMs: nowMs)
    }

    private func pendingItem(
        for record: AIStudyResolutionRecord,
        anchor: PlanIndex.TokenAnchor?,
        manifest: AIStudyJobManifest
    ) -> AIStudyPreviewPendingItem {
        // 改判候选 = 请求侧为该 token 准备的合法候选集
        // （与 prompt 同集——用户只能在合法候选内改判）。
        let alternatives: [AIStudyPreviewPendingItem.Alternative]
        if let anchor {
            let entriesByID = Dictionary(
                uniqueKeysWithValues: manifest.dictionaryEntries
                    .map { ($0.id, $0) })
            alternatives = anchor.token.candidates.flatMap { candidate in
                candidate.senses.compactMap { senseRef in
                    guard let entry = entriesByID[candidate.entryID],
                          let sense = entry.senses.first(
                              where: { $0.id == senseRef.senseID })
                    else { return nil }
                    let preferred = sense.materialize().preferredGlosses()
                    return AIStudyPreviewPendingItem.Alternative(
                        entryID: candidate.entryID,
                        senseID: senseRef.senseID,
                        lemma: candidate.lemma ?? entry.primaryForm,
                        glossSummary: preferred?.glosses
                            .map(\.text).joined(separator: "; "))
                }
            }
        } else {
            alternatives = []
        }
        // AI 首选：低置信行保留合法选定（validator 只挡阈值不挡
        // 选择）——在 alternatives 中找到同 entryID+senseID 的项
        // 作一键采纳入口。unresolved/被拒行无选定 → nil。
        let aiSuggested = record.selectedEntryID.flatMap { entryID in
            record.selectedSenseID.flatMap { senseID in
                alternatives.first(where: {
                    $0.entryID == entryID && $0.senseID == senseID
                })
            }
        }
        return AIStudyPreviewPendingItem(
            resolutionID: record.id,
            requestHash: record.requestHash,
            tokenKey: record.tokenKey,
            surface: anchor?.token.surface ?? record.tokenKey,
            reading: anchor?.token.reading,
            sentence: sentence(for: anchor),
            status: record.status,
            reasonCode: record.reasonCode,
            confidence: record.confidence,
            alternatives: alternatives,
            aiSuggested: aiSuggested)
    }

    /// token 所在句（manifest 块句界切片；range 外 → nil）。
    private func sentence(
        for anchor: PlanIndex.TokenAnchor?
    ) -> String? {
        guard let anchor else { return nil }
        let block = anchor.manifestBlock
        let rangeStart = anchor.utf16Start
        for sentenceRange in block.materializedSentenceRanges {
            if sentenceRange.contains(rangeStart) {
                let units = Array(block.sourceText.utf16)
                guard sentenceRange.upperBound <= units.count else {
                    break
                }
                return String(decoding:
                    units[sentenceRange], as: UTF16.self)
            }
        }
        return nil
    }

    /// 批量学习态复核：identity_key 命中 unit + flag + linked Notes
    /// + 同 headword 未关联 Note（候选复用列表）。全部只读。
    private func attachLearningState(
        to items: inout [AIStudyPreviewItem]
    ) async {
        let keys = items.map(\.unitKey)
        guard !keys.isEmpty else { return }
        let headwords = items.map(\.headword)
        // 全部读集在一次 read 事务物化为补丁，事务外再套用
        // （@Sendable 闭包不能捕获 inout）。
        struct Patch: Sendable {
            var unitID: UUID
            var tooEasy: Bool
            var deleted: Bool
            var linked: [AIStudyPreviewItem.LinkedNote]
            var duplicates: [AIStudyPreviewItem.LinkedNote]
        }
        let patches: [String: Patch]?
        // unitKey → headword 映射入事务（duplicates 过滤需要）。
        let headwordByKey = Dictionary(
            uniqueKeysWithValues: zip(keys, headwords))
        do {
            patches = try await pool.read { db in
                var unitsByKey: [String: UUID] = [:]
                for chunk in keys.chunkedPreparation(400) {
                    let placeholders = chunk.map { _ in "?" }
                        .joined(separator: ",")
                    for row in try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, identity_key
                            FROM lexical_learning_units
                            WHERE identity_key IN (\(placeholders))
                            """,
                        arguments: StatementArguments(Array(chunk))) {
                        let identityKey: String = row["identity_key"]
                        unitsByKey[identityKey] =
                            try DatabaseValueCodec.decodeUUID(row["id"])
                    }
                }
                var history = Set<UUID>()
                var flags: [UUID: Bool] = [:]
                var links: [UUID: [UUID]] = [:]
                var primaryLinks: [UUID: [UUID]] = [:]
                let unitIDs = Array(unitsByKey.values)
                for chunk in unitIDs.chunkedPreparation(400) {
                    let placeholders = chunk.map { _ in "?" }
                        .joined(separator: ",")
                    let arguments = StatementArguments(
                        chunk.map(DatabaseValueCodec.encode))
                    for row in try Row.fetchAll(db, sql: """
                        SELECT DISTINCT unit_id_snapshot FROM learning_unit_events
                        WHERE unit_id_snapshot IN (\(placeholders))
                          AND kind IN ('noteLinked', 'noteUnlinked')
                        """, arguments: arguments) {
                        history.insert(try DatabaseValueCodec.decodeUUID(row["unit_id_snapshot"]))
                    }
                    for row in try Row.fetchAll(
                        db,
                        sql: """
                            SELECT unit_id, too_easy
                            FROM learning_unit_flags
                            WHERE unit_id IN (\(placeholders))
                            """,
                        arguments: arguments) {
                        let tooEasy: Int = row["too_easy"]
                        flags[try DatabaseValueCodec.decodeUUID(
                            row["unit_id"])] = tooEasy != 0
                    }
                    for row in try Row.fetchAll(
                        db,
                        sql: """
                            SELECT unit_id, note_id, role
                            FROM learning_unit_note_links
                            WHERE unit_id IN (\(placeholders))
                            """,
                        arguments: arguments) {
                        let unitID = try DatabaseValueCodec.decodeUUID(
                            row["unit_id"])
                        let noteID = try DatabaseValueCodec.decodeUUID(
                            row["note_id"])
                        links[unitID, default: []].append(noteID)
                        // D02：复用面只认 primary；legacy_secondary 仅参与
                        // 同 headword 去重排除，不作为可复用 note 呈现。
                        let role: String = row["role"]
                        if role == "primary" {
                            primaryLinks[unitID, default: []].append(noteID)
                        }
                    }
                }
                // Note 明细（linked + 同 headword 未关联候选）。
                let noteIDs = Array(Set(links.values.flatMap { $0 }))
                var noteRows: [UUID: (headword: String, reading: String?,
                                      deckID: UUID)] = [:]
                for chunk in noteIDs.chunkedPreparation(400) {
                    let placeholders = chunk.map { _ in "?" }
                        .joined(separator: ",")
                    for row in try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, headword, reading, deck_id
                            FROM notes WHERE id IN (\(placeholders))
                            """,
                        arguments: StatementArguments(
                            chunk.map(DatabaseValueCodec.encode))) {
                        guard let deckID = try? DatabaseValueCodec
                            .decodeUUID(row["deck_id"]) else { continue }
                        let headword: String = row["headword"]
                        let reading: String? = row["reading"]
                        noteRows[try DatabaseValueCodec.decodeUUID(
                            row["id"])] = (
                            headword: headword,
                            reading: reading,
                            deckID: deckID)
                    }
                }
                var duplicates: [String: [(noteID: UUID, reading: String?,
                                          deckID: UUID)]] = [:]
                for chunk in headwords.chunkedPreparation(400) {
                    let placeholders = chunk.map { _ in "?" }
                        .joined(separator: ",")
                    for row in try Row.fetchAll(
                        db,
                        sql: """
                            SELECT id, headword, reading, deck_id
                            FROM notes
                            WHERE headword IN (\(placeholders))
                            """,
                        arguments: StatementArguments(Array(chunk))) {
                        let noteID = try DatabaseValueCodec.decodeUUID(
                            row["id"])
                        let headword: String = row["headword"]
                        let reading: String? = row["reading"]
                        guard let deckID = try? DatabaseValueCodec
                            .decodeUUID(row["deck_id"]) else { continue }
                        duplicates[headword, default: []].append((
                            noteID: noteID,
                            reading: reading,
                            deckID: deckID))
                    }
                }
                var result: [String: Patch] = [:]
                for (unitKey, unitID) in unitsByKey {
                    let linkedNotes = (primaryLinks[unitID] ?? [])
                        .compactMap {
                        noteID -> AIStudyPreviewItem.LinkedNote? in
                        guard let row = noteRows[noteID]
                        else { return nil }
                        return .init(
                            noteID: noteID,
                            headword: row.headword,
                            reading: row.reading,
                            deckID: row.deckID)
                    }
                    let linkedIDs = Set(links[unitID] ?? [])
                    let headword = headwordByKey[unitKey] ?? ""
                    let duplicateNotes =
                        (duplicates[headword] ?? [])
                        .filter { !linkedIDs.contains($0.noteID) }
                        .map {
                            AIStudyPreviewItem.LinkedNote(
                                noteID: $0.noteID,
                                headword: headword,
                                reading: $0.reading,
                                deckID: $0.deckID)
                        }
                    result[unitKey] = Patch(
                        unitID: unitID,
                        tooEasy: flags[unitID] ?? false,
                        deleted: (links[unitID] ?? []).isEmpty && history.contains(unitID),
                        linked: linkedNotes,
                        duplicates: duplicateNotes)
                }
                return result
            }
        } catch {
            // 学习态复核失败不阻塞预览——items 保持默认（新建倾向），
            // apply 事务内会再次复核既有 unit（不会盲写）。
            patches = nil
        }
        guard let patches else { return }
        for index in items.indices {
            guard let patch = patches[items[index].unitKey]
            else { continue }
            items[index].existingUnitID = patch.unitID
            items[index].unitIsTooEasy = patch.tooEasy
            items[index].hasDeletedLearningContent = patch.deleted
            items[index].linkedNotes = patch.linked
            items[index].duplicateNotes = patch.duplicates
        }
    }

    // MARK: - 选择落库（immutable revision）

    /// 确认：预览行决策 + 待确认改判 → `ai_study_selections` 新
    /// revision（epoch+scope 锚复核——过时预览直接拒）。
    ///
    /// - 改判（`correctedSelection != nil`）先落 `origin=user` 的
    ///   resolution 新 revision，再以**该 revision** 为
    ///   `evidenceRevision` 生成 selection（应用锚定语义一致）。
    /// - 同 unitKey 多 occurrence 改判只产生一行 selection。
    /// - decision=nil/pending 的项不产生 selection（§9 待确认语义）。
    /// - Returns: 新 selection revision。
    @discardableResult
    public func recordSelections(
        jobID: UUID,
        preview: AIStudyPreview,
        items: [AIStudyPreviewItem],
        correctedPending: [AIStudyPreviewPendingItem],
        directions: Set<VocabularyCardDirection> = Set(VocabularyCardDirection.allCases)
    ) async throws -> Int64 {
        let atMs = nowMs
        guard let manifest = try await loadManifest(jobID: jobID) else {
            throw PreparationError.manifestMissing(jobID: jobID)
        }
        let index = correctedPending.contains { $0.correctedSelection != nil }
            ? try await planIndex(manifest: manifest) : PlanIndex()
        return try await pool.write { db -> Int64 in
            guard let job = try GRDBAIStudyJobStore.fetchJob(
                id: jobID, in: db) else {
                throw PreparationError.jobNotFound(jobID)
            }
            guard job.status == .awaitingConfirmation
                    || job.status == .partiallyCompleted else {
                throw PreparationError.jobNotConfirmable(
                    jobID: jobID, status: job.status)
            }
            // 预览锚复核：epoch + scopeHash 双双须与实况一致。
            guard job.epoch == preview.jobEpoch,
                  job.scope.scopeHash == preview.scopeHash,
                  job.contentRevision == preview.contentRevision else {
                throw PreparationError.stalePreview(jobID: jobID)
            }
            // 文档 revision 事务内复核（§11.1 同口径）。
            let currentRevision = try Int.fetchOne(
                db,
                sql: """
                    SELECT content_revision FROM reader_documents
                    WHERE id = ?
                    """,
                arguments: [
                    DatabaseValueCodec.encode(job.documentID)])
            guard currentRevision == Int(job.contentRevision) else {
                throw PreparationError.staleContent(
                    expected: job.contentRevision,
                    found: Int64(currentRevision ?? -1))
            }

            let manifestEntries = Dictionary(
                uniqueKeysWithValues: manifest.dictionaryEntries
                    .map { ($0.id, $0) })
            var selections: [AIStudyJobSelection] = []
            var coveredUnitKeys = Set<String>()
            let newRevision = AIStudyJobStateMachine
                .nextSelectionRevision(for: job)

            let resolutions = try GRDBAIStudyJobStore.fetchResolutions(jobID: jobID, in: db)
            var latest: [String: AIStudyResolutionRecord] = [:]
            for record in resolutions {
                let key = "\(record.requestHash)\u{1F}\(record.tokenKey)"
                if let old = latest[key], old.revision >= record.revision { continue }
                latest[key] = record
            }
            // 改判：user resolution 行 + occurrence 链接 + selection。
            for pending in correctedPending {
                guard let corrected = pending.correctedSelection else { continue }
                // 从冻结请求复核候选，不信任调用方传来的 alternatives。
                guard let anchor = index.token(pending.tokenKey, requestHash: pending.requestHash),
                      let candidate = anchor.token.candidates.first(where: {
                          $0.entryID == corrected.entryID
                      }),
                      candidate.senses.contains(where: { $0.senseID == corrected.senseID }),
                      let entry = manifestEntries[corrected.entryID],
                      entry.senses.contains(where: {
                          $0.id == corrected.senseID
                      })
                else { throw PreparationError.invalidCorrection(tokenKey: pending.tokenKey) }
                guard let previous = latest["\(pending.requestHash)\u{1F}\(pending.tokenKey)"],
                      previous.id == pending.resolutionID else {
                    throw PreparationError.stalePreview(jobID: jobID)
                }
                guard let sense = entry.senses.first(where: { $0.id == corrected.senseID }),
                      let key = unitKey(entryID: corrected.entryID, sense: sense.materialize())
                else { throw PreparationError.invalidCorrection(tokenKey: pending.tokenKey) }
                let revision = try GRDBAIStudyJobStore
                    .nextResolutionRevision(
                        requestHash: pending.requestHash,
                        tokenKey: pending.tokenKey, in: db)
                let record = AIStudyResolutionRecord(
                    id: UUID(),
                    jobID: jobID,
                    jobBlockID: previous.jobBlockID,
                    documentID: job.documentID,
                    locatorJSON: previous.locatorJSON,
                    tokenKey: pending.tokenKey,
                    requestHash: pending.requestHash,
                    selectedEntryID: corrected.entryID,
                    selectedSenseID: corrected.senseID,
                    selectedDatasetVersion: manifest.requestMetadata.dictionaryDatasetVersion,
                    unitID: nil,
                    confidence: nil,
                    status: .userConfirmed,
                    reasonCode: nil,
                    origin: .user,
                    revision: revision,
                    createdAtMs: atMs,
                    sentenceTranslation: previous.selectedEntryID == corrected.entryID
                        && previous.selectedSenseID == corrected.senseID
                        ? previous.sentenceTranslation : nil)
                try GRDBAIStudyJobStore.insertResolution(
                    record, documentID: job.documentID, in: db)
                // occurrence 回填 userConfirmed：经 preview 携带的
                // 原 resolution 行 id 精确定位（不跨 Job 域误伤）。
                if let previousResolutionID = pending.resolutionID {
                    try db.execute(
                        sql: """
                            UPDATE reader_study_occurrences
                            SET resolution_status = 'userConfirmed',
                                resolution_id = ?
                            WHERE document_id = ? AND content_revision = ?
                              AND resolution_id = ?
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(record.id),
                            DatabaseValueCodec.encode(job.documentID),
                            job.contentRevision,
                            DatabaseValueCodec.encode(previousResolutionID),
                        ])
                }
                if coveredUnitKeys.insert(key).inserted {
                    // 载荷必须落值——decision=create 配 nil 动作在
                    // 应用层会落 invalidSelection（既有缺陷修正）。
                    selections.append(AIStudyJobSelection(
                        jobID: jobID,
                        unitKey: key,
                        selectionRevision: newRevision,
                        decision: .create,
                        proposedAction: .createNote(
                            directions: directions,
                            senseIDs: [corrected.senseID]),
                        evidenceRevision: revision))
                }
            }

            for item in items {
                guard let decision = item.decision,
                      decision != .pending else { continue }
                let action = item.proposedAction
                    ?? defaultAction(for: item, decision: decision)
                if coveredUnitKeys.insert(item.unitKey).inserted {
                    selections.append(AIStudyJobSelection(
                        jobID: jobID,
                        unitKey: item.unitKey,
                        selectionRevision: newRevision,
                        decision: decision,
                        proposedAction: action,
                        evidenceRevision: item.evidenceRevision))
                }
            }

            guard !selections.isEmpty else { return job.selectionRevision }
            try GRDBAIStudyJobStore.recordSelections(
                jobID: jobID,
                expectedEpoch: job.epoch,
                selections: selections,
                newRevision: newRevision,
                atMs: atMs,
                in: db)
            return newRevision
        }
    }

    /// selection 未带动作载荷时的默认重建（与预览策略默认值同
    /// 语义——显式 nil 回退防御）。
    private func defaultAction(
        for item: AIStudyPreviewItem,
        decision: AISelectionDecision
    ) -> AIStudyProposedAction? {
        switch decision {
        case .create:
            return .createNote(
                directions: Set(VocabularyCardDirection.allCases),
                senseIDs: item.mergedSenseIDs)
        case .reuse:
            return item.linkedNotes.first.map {
                .reuseNote(noteID: $0.noteID, addMembershipTo: nil)
            }
        case .tooEasy:
            return .setTooEasy
        case .skip:
            return .recordSkip
        case .pending:
            return .pending
        }
    }

    // MARK: - 终态摘要

    /// 导出同文档最近任务的本地结果，不包含原文、Prompt、密钥或请求缓存。
    /// 旧失败事务没有回执时明确标注“未提交”，不猜测原因。
    public func applicationDiagnostics(jobID: UUID) async throws -> String {
        try await pool.read { db in
            guard let current = try GRDBAIStudyJobStore.fetchJob(id: jobID, in: db) else {
                throw PreparationError.jobNotFound(jobID)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id FROM ai_study_jobs WHERE document_id = ?
                ORDER BY created_at_ms DESC, id DESC LIMIT 20
                """, arguments: [DatabaseValueCodec.encode(current.documentID)])
            var lines = ["Oboe 学习内容生成诊断", "当前分析：\(jobID.uuidString)",
                         "文档编号：\(current.documentID.uuidString)"]
            for row in rows {
                let id = try DatabaseValueCodec.decodeUUID(row["id"])
                guard let job = try GRDBAIStudyJobStore.fetchJob(id: id, in: db) else { continue }
                let selections = try GRDBAIStudyJobStore.fetchSelections(jobID: id, in: db)
                    .filter { $0.selectionRevision == job.selectionRevision }
                lines.append("任务 \(id.uuidString) 状态=\(job.status.rawValue) 选择版本=\(job.selectionRevision) 已选=\(selections.count)")
                for selection in selections.sorted(by: { $0.unitKey < $1.unitKey }) {
                    let receipt = try selection.appliedReceiptID.flatMap {
                        try GRDBAIStudyJobStore.fetchReceipt(operationID: $0, in: db)
                    }
                    let outcome = receipt.flatMap { try? JSONDecoder().decode(
                        AIStudyApplyUnitOutcome.self, from: Data($0.outcomeJSON.utf8)) }
                    let savedCards = try outcome?.noteID.map {
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                            arguments: [DatabaseValueCodec.encode($0)]) ?? 0
                    } ?? 0
                    lines.append("  \(selection.unitKey) 决策=\(selection.decision.rawValue) 结果=\(outcome?.kind.rawValue ?? "未提交") 原提交卡数=\(outcome?.cardCount ?? 0) 当前卡数=\(savedCards) 错误码=\(outcome?.errorCode ?? "无")")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 摘要：`AIStudyApplyReport` → 互斥分桶计数（应用未完成时
    /// report 可 nil——那时单元数恒 0）。
    public func summary(
        jobID: UUID,
        report: AIStudyApplyReport?,
        unselectedCount: Int,
        pendingCount: Int
    ) async throws -> AIStudyJobSummary {
        guard let job = try await jobStore.fetchJob(id: jobID) else {
            throw PreparationError.jobNotFound(jobID)
        }
        let (deckName, blockCounts) = try await pool.read { db in
            let name = job.studyDeckID.flatMap { id in
                try? String.fetchOne(
                    db,
                    sql: "SELECT name FROM decks WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(id)])
            }
            let blocks = try GRDBAIStudyJobStore.fetchBlocks(
                jobID: jobID, in: db)
            var resolved = 0, failed = 0, translated = 0
            for block in blocks {
                switch block.status {
                case .resolved, .applied: resolved += 1
                case .failed: failed += 1
                default: break
                }
                if block.translationStatus == .done { translated += 1 }
            }
            return (name, (blocks.count, resolved, failed, translated))
        }
        let units = report?.units ?? []
        let deletedCount = units.filter {
            $0.isSettled && ($0.kind == .skippedDeletedEvidence || $0.errorCode == "deletedEvidence")
        }.count
        let missingNoteCount = units.filter {
            $0.isSettled && ($0.kind == .skippedNoteMissing || $0.errorCode == "noteMissing")
        }.count
        return AIStudyJobSummary(
            jobID: jobID,
            status: report?.finalStatus ?? job.status,
            studyDeckID: job.studyDeckID,
            deckName: deckName,
            createdNoteCount: units.filter {
                $0.kind == .createdNote }.count,
            reusedNoteCount: units.filter {
                $0.kind == .reusedNote }.count,
            degradedToReuseCount: units.filter {
                $0.kind == .reusedExistingPrimary
                    || $0.kind == .promotedAndReused }.count,
            tooEasyCount: units.filter {
                $0.kind == .tooEasySet }.count,
            skippedCount: units.filter {
                $0.kind == .recordedSkip }.count + deletedCount + missingNoteCount,
            unselectedCount: unselectedCount,
            failedUnitCount: units.filter { !$0.isSettled }.count,
            unresolvedCount: pendingCount,
            createdCardCount: units.filter { $0.kind == .createdNote }.reduce(0) { $0 + $1.cardCount },
            translatedBlockCount: blockCounts.3,
            totalBlockCount: blockCounts.0,
            resolvedBlockCount: blockCounts.1,
            failedBlockCount: blockCounts.2,
            deletedContentCount: deletedCount,
            alreadyAppliedCount: units.filter {
                ($0.kind == .alreadyApplied || $0.kind == .replayed)
                    && $0.errorCode != "deletedEvidence" && $0.errorCode != "noteMissing"
            }.count)
    }
}

// MARK: - NL morphology / Reader 仓储适配

extension NLJapaneseMorphologyService:
    AIStudyPreparationService.MorphologySource {}

extension GRDBReaderRepository:
    AIStudyPreparationService.ReaderSource {}

// MARK: - 私有工具

private extension Array {
    /// 定长切片（私有工具——不与其他模块的 chunked 冲突）。
    func chunkedPreparation(_ size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [self[...]] }
        var chunks: [ArraySlice<Element>] = []
        chunks.reserveCapacity(count / size + 1)
        var index = startIndex
        while index < endIndex {
            let end = index + size < endIndex
                ? index + size : endIndex
            chunks.append(self[index..<end])
            index = end
        }
        return chunks
    }
}
