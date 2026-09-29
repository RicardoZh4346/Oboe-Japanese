import Foundation
import GRDB
import OboeDomain

/// v0.7.5 S17：三模式译文的 Reader 侧编排器。
///
/// # 职责
///
/// 1. **水合（零网络）**：`hydrate` 按章取
///    `reader_translation_blocks` 的 current 行，锚点经
///    `ReaderTranslationLocator`（locatorJSON 序数 + `#r` 区间）
///    解析到活动 `ReaderBlock`——`source_hash == block.textHash`
///    才可渲染（译文不出现在不匹配原文下；§14.2「缺失/过期结果
///    不触发请求」——本路径永不发请求）。
/// 2. **主动翻译/重译**：`translate`/`retranslate` 把目标块打成
///    **纯翻译请求**（`AIStudyRequest`，`tokens = []`——§6.3
///    「没有候选的纯翻译块允许 words=[]」），经 `sender` 接缝
///    派发；校验通过的 `translationStatus == .done` 译文经
///    `GRDBReaderTranslationStore.publish` 落库——旧译文在新
///    结果落库前恒为 current（同事务翻转，结果未到不丢旧值）。
/// 3. **重挂**：`ReaderTranslationReanchor`（同文件）在 relink
///    提交事务内把译文锚点迁移到新章/块序数——见 commitRelink。
///
/// # 不静默覆盖
///
/// provider/model/promptVersion 只作为**新修订的 provenance**：
/// 请求元数据从 `context` 闭包当次快照构造，`requestHash` 覆盖
/// 配置字段——配置变更产生新 requestHash/新修订行，既有行永不
/// 改写（§8.1「candidate/prompt/model 变化也不覆盖已选译文」）。
///
/// # 请求形状
///
/// 与 study 管线同一 wire 契约：`AIStudyRequestSerializer`
/// blockKey/requestID/requestHash 同一组确定性构造函数——同一
/// locator/元数据重算必得同一 requestHash（§4.4）。`blockKey`
/// 直接用译文 locator_key（`tr:` 规范形态），dispatch/caching/
/// 持久化三层键自然一致。
public actor ReaderTranslationOrchestrator {

    /// 派发前的环境快照：连接配置 + 凭据 + 版本组分
    /// （requestHash 的环境侧字段）。由宿主闭包在**每次派发批**
    /// 取一次——配置变更只影响下一批，不半途换元数据。
    public struct RequestContext: Sendable {
        public var resolved: ResolvedAIConfiguration
        public var credential: String
        /// §4.4 requestHash 环境组分（宿主注入——形态/词典服务
        /// 版本，随容器世代冻结）。
        public var dictionaryDatasetVersion: String
        public var morphologyVersion: String
        public var osBuild: String

        public init(
            resolved: ResolvedAIConfiguration,
            credential: String,
            dictionaryDatasetVersion: String,
            morphologyVersion: String,
            osBuild: String
        ) {
            self.resolved = resolved
            self.credential = credential
            self.dictionaryDatasetVersion = dictionaryDatasetVersion
            self.morphologyVersion = morphologyVersion
            self.osBuild = osBuild
        }
    }

    /// transport 接缝——生产接 `AIStudyResolverClient.resolve`
    /// （`Self.sender(resolver:)` 工厂），测试接脚本化 fake。
    public typealias Sender = @Sendable (
        AIStudyRequest, RequestContext
    ) async throws -> AIStudyResolverResult

    public enum OrchestratorError: Error, Equatable, Sendable {
        /// 派发前环境快照获取失败（AI 未启用/未选模型/Key 缺席——
        /// UI 据此给设置入口，不静默降级）。
        case contextUnavailable
        case cancelled
    }

    /// 块级发送状态（VM 的占位/进度数据源）。
    public enum DispatchState: Equatable, Sendable {
        case requesting
        /// 该块的全部请求已收束（成败看 BlockRunOutcome +
        /// hydrate 复核——成功行已 publish）。
        case settled
    }

    /// 一个目标块的一次翻译运行结果。
    public struct BlockRunOutcome: Equatable, Sendable {
        public var blockID: UUID
        /// 本次成功落库的区间（含缓存命中——命中也算成功，§8.2
        /// 请求复用零网络）。
        public var completedRanges: [Range<Int>]
        /// 派发失败的区间（发送错/校验拒/译文缺失）——UI 给
        /// 部分失败占位 + 重试。
        public var failedRanges: [Range<Int>]
        /// 归因码（`FailureCode` 域）——nil 表示全成。
        public var errorCode: String?
        /// `onlyMissing` 下因已有完整覆盖而跳过（未发请求）。
        public var skipped: Bool

        public init(
            blockID: UUID,
            completedRanges: [Range<Int>],
            failedRanges: [Range<Int>],
            errorCode: String?,
            skipped: Bool = false
        ) {
            self.blockID = blockID
            self.completedRanges = completedRanges
            self.failedRanges = failedRanges
            self.errorCode = errorCode
            self.skipped = skipped
        }
    }

    /// 一个派发目标：一个 Reader 块 + 章序 + 上块尾上下文
    /// （`AIStudyPreparationService` 的 400 Character 口径）。
    public struct Target: Sendable {
        public var block: ReaderBlock
        public var chapterOrdinal: Int
        /// 相邻上文（前块尾部）——可为空串。
        public var context: String

        public init(
            block: ReaderBlock,
            chapterOrdinal: Int,
            context: String = ""
        ) {
            self.block = block
            self.chapterOrdinal = chapterOrdinal
            self.context = context
        }
    }

    /// `last_error_code` 归因码（与 Runner 同域，UI/审计共享）。
    public enum FailureCode {
        public static let rateLimited = "rateLimited"
        public static let authFailed = "authFailed"
        public static let retryable = "retryable"
        public static let unsupportedConfiguration =
            "unsupportedConfiguration"
        public static let redirectRejected = "redirectRejected"
        public static let cancelled = "cancelled"
        /// 响应通过外层校验但 translation 子状态失败/译文为空。
        public static let translationRejected = "translationRejected"
        /// 环境快照缺失（未启用/未选模型/无 Key）。
        public static let contextUnavailable = "contextUnavailable"
    }

    private let pool: DatabasePool
    private let jobStore: GRDBAIStudyJobStore
    private let contextProvider: @Sendable () async throws -> RequestContext
    private let sender: Sender
    private let maxConcurrentRequests: Int
    private let now: @Sendable () -> Date

    /// 在途 requestHash——同 hash 派发合并去重（§8.2 请求复用
    /// 进程内层；持久层由 ai_study_cache + UNIQUE 兜底）。
    private var inFlight: Set<String> = []
    /// 停派标记：authFailed 后本批不再发新请求（§9.2）。
    private var halted = false

    public init(
        pool: DatabasePool,
        jobStore: GRDBAIStudyJobStore? = nil,
        contextProvider: @escaping @Sendable () async throws
            -> RequestContext,
        sender: @escaping Sender,
        maxConcurrentRequests: Int = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pool = pool
        self.jobStore = jobStore ?? GRDBAIStudyJobStore(pool: pool)
        self.contextProvider = contextProvider
        self.sender = sender
        self.maxConcurrentRequests = max(1, min(4, maxConcurrentRequests))
        self.now = now
    }

    /// 生产 transport 接线（与 `AIStudyRunner` 的 sendRequest 约定
    /// 同源：配置/凭据由 context 快照供给，resolver 不读 Keychain）。
    public static func sender(
        resolver: AIStudyResolverClient
    ) -> Sender {
        { request, context in
            try await resolver.resolve(
                request,
                configuration: context.resolved,
                credential: context.credential)
        }
    }

    // MARK: - 水合（零网络，§14.2）

    /// 单章可渲染译文：current 行 → 锚点解析 → 活动块 hash 复核
    /// → 逐块装配。**不触发任何网络请求**（§14.2 缺译只给占位）。
    ///
    /// - Parameter blocks: 该章活动块（`repository.fetchBlocks`
    ///   原样传入）；锚点序数落在块集外或 hash 不符的行不返回。
    /// - Returns: `blockID → 装配结果`（无可用译文的块不在字典）。
    public func hydrate(
        documentID: UUID,
        language: String,
        chapterOrdinal: Int,
        blocks: [ReaderBlock]
    ) async throws -> [UUID: ReaderTranslationAssembly.Outcome] {
        let rows = try await pool.read { db in
            try Self.fetchChapterCurrentRows(
                documentID: documentID,
                language: language,
                chapterOrdinal: chapterOrdinal,
                in: db)
        }
        let byOrdinal = Dictionary(
            uniqueKeysWithValues: blocks.map { ($0.ordinal, $0) })
        var piecesByBlock: [UUID: [ReaderTranslationPiece]] = [:]
        for row in rows {
            guard let anchor = ReaderTranslationLocator.anchor(
                locatorKey: row.locatorKey,
                locatorJSON: row.locatorJSON
            ), anchor.chapterOrdinal == chapterOrdinal,
               let block = byOrdinal[anchor.blockOrdinal],
               block.textHash == row.sourceHash else { continue }
            piecesByBlock[block.id, default: []].append(
                ReaderTranslationPiece(
                    locatorKey: row.locatorKey,
                    range: anchor.range,
                    text: row.translatedText,
                    translationRevision: row.translationRevision,
                    provider: row.provider,
                    model: row.model,
                    promptVersion: row.promptVersion,
                    createdAt: row.createdAt))
        }
        var result: [UUID: ReaderTranslationAssembly.Outcome] = [:]
        for (blockID, pieces) in piecesByBlock {
            guard let block = blocks.first(where: { $0.id == blockID })
            else { continue }
            result[blockID] = ReaderTranslationAssembly.assemble(
                pieces: pieces,
                blockUTF16Length: block.text.utf16.count)
        }
        return result
    }

    /// 章级 current 行查询：`locator_key LIKE '%:ch:<co>:b:%'`
    /// 同时覆盖 `tr:` 与旧 `doc:` 规范（两形都含 `:ch:N:b:` 子串）；
    /// 行解码与 `GRDBReaderTranslationStore` 同列序。
    static func fetchChapterCurrentRows(
        documentID: UUID,
        language: String,
        chapterOrdinal: Int,
        in db: Database
    ) throws -> [ReaderTranslationRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, document_id, locator_key, locator_json,
                       source_hash, translation_revision, translated_text,
                       language, provider, model, prompt_version,
                       request_hash, is_current, created_at_ms
                FROM reader_translation_blocks
                WHERE document_id = ? AND is_current = 1
                  AND language = ?
                  AND locator_key LIKE ?
                ORDER BY locator_key
                """,
            arguments: [
                DatabaseValueCodec.encode(documentID),
                language,
                "%:ch:\(chapterOrdinal):b:%",
            ])
        return try rows.map(Self.decodeRow)
    }

    /// 行解码（列序与 `GRDBReaderTranslationStore.columnList` 一致——
    /// store 的私有解码在本编排层复制，避免改动冻结面）。
    static func decodeRow(_ row: Row) throws -> ReaderTranslationRow {
        ReaderTranslationRow(
            id: try DatabaseValueCodec.decodeUUID(row["id"]),
            documentID: try DatabaseValueCodec.decodeUUID(row["document_id"]),
            locatorKey: row["locator_key"],
            locatorJSON: row["locator_json"],
            sourceHash: row["source_hash"],
            translationRevision: row["translation_revision"],
            translatedText: row["translated_text"],
            language: row["language"],
            provider: row["provider"],
            model: row["model"],
            promptVersion: row["prompt_version"],
            requestHash: row["request_hash"],
            isCurrent: row["is_current"] != 0,
            createdAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["created_at_ms"]))
    }

    // MARK: - 主动翻译 / 重译

    /// 批量翻译：`onlyMissing` 时已有完整覆盖的块跳过（不重发）；
    /// `force`（用户显式重译）则全部重发——旧译文在新结果 publish
    /// 前保持 current。
    ///
    /// `onState` 在 actor 上下文回调（块开始/收束各一次）——
    /// VM 侧自行 hop 主线程。
    @discardableResult
    public func translate(
        document: ReaderDocumentMetadata,
        targets: [Target],
        language: String = AIStudyPreparation.targetLanguage,
        onlyMissing: Bool = true,
        onState: (@Sendable (UUID, DispatchState) -> Void)? = nil
    ) async -> [BlockRunOutcome] {
        guard !targets.isEmpty else { return [] }
        let context: RequestContext
        do {
            context = try await contextProvider()
        } catch {
            return targets.map {
                BlockRunOutcome(
                    blockID: $0.block.id,
                    completedRanges: [],
                    failedRanges: [0..<$0.block.text.utf16.count],
                    errorCode: FailureCode.contextUnavailable)
            }
        }

        // onlyMissing：先按当前持久态算各块缺口——完整的直接跳过。
        var pending = targets
        var outcomes: [BlockRunOutcome] = []
        if onlyMissing {
            var still: [Target] = []
            for target in targets {
                let hydrated = try? await hydrate(
                    documentID: document.id,
                    language: language,
                    chapterOrdinal: target.chapterOrdinal,
                    blocks: [target.block])
                if case .complete = hydrated?[target.block.id] {
                    outcomes.append(BlockRunOutcome(
                        blockID: target.block.id,
                        completedRanges: [0..<target.block.text.utf16.count],
                        failedRanges: [],
                        errorCode: nil,
                        skipped: true))
                } else {
                    still.append(target)
                }
            }
            pending = still
        }

        halted = false
        // 有界并发批（≤4）——批间推进，authFailed/cancel 停派。
        for batch in pending.chunked(into: maxConcurrentRequests) {
            if halted || Task.isCancelled {
                for target in batch {
                    outcomes.append(BlockRunOutcome(
                        blockID: target.block.id,
                        completedRanges: [],
                        failedRanges: [0..<target.block.text.utf16.count],
                        errorCode: FailureCode.cancelled))
                }
                continue
            }
            await withTaskGroup(of: BlockRunOutcome.self) { group in
                for target in batch {
                    group.addTask {
                        await self.runOne(
                            document: document,
                            target: target,
                            language: language,
                            context: context,
                            onState: onState)
                    }
                }
                for await outcome in group {
                    outcomes.append(outcome)
                }
            }
        }
        return outcomes
    }

    /// 单块重译（主动重译入口）——始终重发；失败时旧译文原样
    /// 保留（publish 未发生）。
    @discardableResult
    public func retranslate(
        document: ReaderDocumentMetadata,
        target: Target,
        language: String = AIStudyPreparation.targetLanguage,
        onState: (@Sendable (UUID, DispatchState) -> Void)? = nil
    ) async -> BlockRunOutcome {
        let outcomes = await translate(
            document: document,
            targets: [target],
            language: language,
            onlyMissing: false,
            onState: onState)
        return outcomes.first ?? BlockRunOutcome(
            blockID: target.block.id,
            completedRanges: [],
            failedRanges: [0..<target.block.text.utf16.count],
            errorCode: FailureCode.cancelled)
    }

    /// 停派：后续批不再发新请求（在途收束仍回报——与 runner
    /// 「已提交保留」同纪律，未发目标记 cancelled）。
    public func halt() { halted = true }

    // MARK: - 单目标派发

    /// 整块一个请求：ReaderBlock 硬上限 8192 UTF-16 units ⇒
    /// 序列化载荷 ≤ ~28KiB（含 400 字上下文与信封），恒低于
    /// §3.2 的 48KiB 预算——纯翻译路径不需要 subblock 拆分；
    /// study 管线产生的 `#r` 片段行渲染侧按区间装配。
    private func runOne(
        document: ReaderDocumentMetadata,
        target: Target,
        language: String,
        context: RequestContext,
        onState: (@Sendable (UUID, DispatchState) -> Void)?
    ) async -> BlockRunOutcome {
        let blockID = target.block.id
        onState?(blockID, .requesting)
        defer { onState?(blockID, .settled) }
        let fullRange = 0..<target.block.text.utf16.count

        let request = Self.makeRequest(
            document: document,
            target: target,
            language: language,
            context: context)

        // ① 请求复用：缓存命中零网络落库（§8.2）。
        if let cached = try? await jobStore.cachedResult(
            requestHash: request.requestHash),
           cached.translationStatus == .done,
           let translation = cached.translation,
           !translation.isEmpty {
            do {
                try await publish(
                    documentID: document.id,
                    request: request,
                    target: target,
                    translatedText: translation,
                    provider: cached.providerKind,
                    model: cached.model,
                    promptVersion: cached.promptVersion,
                    requestHash: cached.requestHash)
                return BlockRunOutcome(
                    blockID: blockID,
                    completedRanges: [fullRange],
                    failedRanges: [],
                    errorCode: nil)
            } catch {
                return BlockRunOutcome(
                    blockID: blockID,
                    completedRanges: [],
                    failedRanges: [fullRange],
                    errorCode: FailureCode.retryable)
            }
        }

        // ② 在途合并：同 requestHash 已由本 actor 派发——跳过
        //    （对端收束后的重试由调用方决定）。
        guard inFlight.insert(request.requestHash).inserted else {
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [],
                failedRanges: [fullRange],
                errorCode: FailureCode.retryable)
        }
        defer { inFlight.remove(request.requestHash) }

        // ③ 派发：一次尝试（重试由用户显式触发——自动退避重跑
        //    是 Job 语义，独立翻译路径保持轻量）。
        let result: AIStudyResolverResult
        do {
            try Task.checkCancellation()
            result = try await sender(request, context)
        } catch let error as AIStudyResolverError {
            let code = Self.failureCode(for: error)
            if code == FailureCode.authFailed { halted = true }
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [],
                failedRanges: [fullRange],
                errorCode: code)
        } catch is CancellationError {
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [],
                failedRanges: [fullRange],
                errorCode: FailureCode.cancelled)
        } catch {
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [],
                failedRanges: [fullRange],
                errorCode: FailureCode.retryable)
        }

        // ④ 校验后落库：translation 子状态 done 且非空才 publish——
        //    失败路径零写入，旧 current 原样保留。
        guard result.outcome.translationStatus == .done,
              let translation = result.outcome.translation,
              !translation.isEmpty else {
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [],
                failedRanges: [fullRange],
                errorCode: FailureCode.translationRejected)
        }
        do {
            try await publish(
                documentID: document.id,
                request: request,
                target: target,
                translatedText: translation,
                provider: result.providerKind,
                model: result.model,
                promptVersion: result.promptVersion,
                requestHash: request.requestHash)
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [fullRange],
                failedRanges: [],
                errorCode: nil)
        } catch {
            return BlockRunOutcome(
                blockID: blockID,
                completedRanges: [],
                failedRanges: [fullRange],
                errorCode: FailureCode.retryable)
        }
    }

    /// 发表（库写唯一出口——行形态由 `ReaderTranslationLocator`
    /// 规范生成，`publish` 负责同链 revision/current 翻转）。
    private func publish(
        documentID: UUID,
        request: AIStudyRequest,
        target: Target,
        translatedText: String,
        provider: String?,
        model: String?,
        promptVersion: String?,
        requestHash: String?
    ) async throws {
        let locatorKey = ReaderTranslationLocator.wholeBlockKey(
            chapterOrdinal: target.chapterOrdinal,
            blockOrdinal: target.block.ordinal,
            blockUTF16Length: target.block.text.utf16.count)
        let locatorJSON = try ReaderTranslationLocator.locatorJSON(
            sourceText: target.block.text,
            blockTextHash: target.block.textHash,
            chapterOrdinal: target.chapterOrdinal,
            blockOrdinal: target.block.ordinal,
            targetRange: 0..<target.block.text.utf16.count)
        let at = now()
        try await pool.write { db in
            _ = try GRDBReaderTranslationStore.publish(
                documentID: documentID,
                locatorKey: locatorKey,
                locatorJSON: locatorJSON,
                sourceHash: target.block.textHash,
                language: request.metadata.language,
                translatedText: translatedText,
                provider: provider,
                model: model,
                promptVersion: promptVersion,
                requestHash: requestHash,
                at: at,
                in: db)
        }
    }

    // MARK: - 请求构造（与 study 管线同一 wire 形态）

    /// 纯翻译块请求：`tokens = []`、`wantsTranslation = true`、
    /// `blockKey` = 译文 locator_key。requestID/requestHash 走
    /// `AIStudyRequestSerializer` 确定性构造（同输入同 hash）。
    static func makeRequest(
        document: ReaderDocumentMetadata,
        target: Target,
        language: String,
        context: RequestContext
    ) -> AIStudyRequest {
        let utf16Length = target.block.text.utf16.count
        let blockKey = ReaderTranslationLocator.wholeBlockKey(
            chapterOrdinal: target.chapterOrdinal,
            blockOrdinal: target.block.ordinal,
            blockUTF16Length: utf16Length)
        let block = AIStudyBlock(
            blockKey: blockKey,
            targetText: target.block.text,
            context: target.context,
            targetUTF16Start: 0,
            targetUTF16Length: utf16Length,
            tokens: [],
            candidateSetHash: AIStudyRequestSerializer.candidateSetHash(
                tokens: []),
            wantsTranslation: true)
        let metadata = AIStudyRequestMetadata(
            dictionaryDatasetVersion: context.dictionaryDatasetVersion,
            morphologyVersion: context.morphologyVersion,
            parserVersion: document.parserVersion,
            osBuild: context.osBuild,
            providerKind: context.resolved.serviceKind.rawValue,
            endpointFingerprint: AIStudyEndpointFingerprint.normalize(
                context.resolved.baseURL.absoluteString),
            model: context.resolved.modelID,
            responseMode: context.resolved.responseFormatMode.rawValue,
            promptVersion: AIStudyPrompt.promptVersion,
            language: language,
            generationParameters: [:])
        var request = AIStudyRequest(
            requestID: AIStudyRequestSerializer.requestID(
                blockKey: blockKey),
            blocks: [block],
            metadata: metadata,
            requestHash: "")
        request = AIStudyRequest(
            requestID: request.requestID,
            blocks: request.blocks,
            metadata: request.metadata,
            requestHash: AIStudyRequestSerializer.requestHash(request))
        return request
    }

    /// 错误 → 归因码；`authFailed` 由调用方顺带停派（§9.2：
    /// 修好 Key 前续发无意义）。
    private static func failureCode(
        for error: AIStudyResolverError
    ) -> String {
        switch error {
        case .cancelled:
            return FailureCode.cancelled
        case .authFailed:
            return FailureCode.authFailed
        case .rateLimited:
            return FailureCode.rateLimited
        case .retryable:
            return FailureCode.retryable
        case .unsupportedConfiguration:
            return FailureCode.unsupportedConfiguration
        case .redirectRejected:
            return FailureCode.redirectRejected
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var index = startIndex
        while index < endIndex {
            let end = Swift.min(index + size, endIndex)
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
