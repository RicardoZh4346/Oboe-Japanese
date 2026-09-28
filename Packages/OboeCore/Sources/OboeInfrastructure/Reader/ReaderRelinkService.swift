import Foundation
import OboeDomain

/// relink 拒绝原因（S24 §14.2）：全部显式、不静默覆盖。
public enum ReaderRelinkError: Error, Equatable, Sendable {
    /// 目标文档行不存在（可能刚被删除）。
    case documentNotFound
    /// 所选文件与文档无关：source SHA-256 不命中、canonical hash 也
    /// 不命中——不覆盖任何文件或库内行。
    case contentMismatch
    /// 协作取消在阶段边界生效。
    case cancelled
}

/// relink 结果（驱动 UI toast 与测试断言）。
public struct ReaderRelinkOutcome: Equatable, Sendable {
    /// 命中方式：源文件字节一致，或 canonical 文本一致（重打包场景）。
    public enum Confirmation: String, Equatable, Sendable {
        case sourceSHA256
        case canonicalText
    }
    public let document: ReaderDocumentMetadata
    public let confirmation: Confirmation
    /// 正文行是否真的被替换/补齐（keep 集外的旧行被删）。
    public let rebuiltContent: Bool
    /// 新装源文件在 `ReaderFiles/<documentID>/` 下的受控相对路径。
    public let sourceRelativePath: String

    public init(
        document: ReaderDocumentMetadata,
        confirmation: Confirmation,
        rebuiltContent: Bool,
        sourceRelativePath: String
    ) {
        self.document = document
        self.confirmation = confirmation
        self.rebuiltContent = rebuiltContent
        self.sourceRelativePath = sourceRelativePath
    }
}

/// relink 单事务写计划：最终章节/块集合 + 可复用行 ID + 文档
/// metadata 更新 + 资产登记，全部进同一 `pool.write`。
///
/// 稳定 ID 语义（S24）：复用行保留原 `chapter_id`/`block_id`——
/// `reader_positions`/`reader_bookmarks` 的 `chapter_id` 弱引用、
/// `reader_token_cache` 的 `block_id` 外键在内容一致时原样存活；
/// 被替换行的 token_cache 随块级联、章节引用 SET NULL（schema 语义）。
public struct ReaderRelinkPlan: Sendable {
    public var documentID: UUID
    /// 以下字段覆写 reader_documents；title/created_at/last_opened/
    /// progress_basis_points 一律保留。
    public var format: ReaderDocumentFormat
    public var sourceFileName: String?
    public var sourceSHA256: String
    public var canonicalTextHash: String
    public var parserVersion: String
    /// 内容行集合有实际增删时 true → content_revision +1。
    public var contentChanged: Bool
    /// 最终章节/块全集（含复用行）。
    public var chapters: [ReaderChapterMetadata]
    public var blocks: [ReaderBlock]
    /// 复用行：不删不插，仅刷新可变字段（章节 title/locator，块
    /// locator_json/text_hash）。
    public var reusableChapterIDs: Set<UUID>
    public var reusableBlockIDs: Set<UUID>
    /// 源文件 + 附属资源资产行（UPSERT）。
    public var assets: [ReaderAssetRecord]

    public init(
        documentID: UUID,
        format: ReaderDocumentFormat,
        sourceFileName: String?,
        sourceSHA256: String,
        canonicalTextHash: String,
        parserVersion: String,
        contentChanged: Bool,
        chapters: [ReaderChapterMetadata],
        blocks: [ReaderBlock],
        reusableChapterIDs: Set<UUID>,
        reusableBlockIDs: Set<UUID>,
        assets: [ReaderAssetRecord]
    ) {
        self.documentID = documentID
        self.format = format
        self.sourceFileName = sourceFileName
        self.sourceSHA256 = sourceSHA256
        self.canonicalTextHash = canonicalTextHash
        self.parserVersion = parserVersion
        self.contentChanged = contentChanged
        self.chapters = chapters
        self.blocks = blocks
        self.reusableChapterIDs = reusableChapterIDs
        self.reusableBlockIDs = reusableBlockIDs
        self.assets = assets
    }
}

/// relink 写边界：单事务原子提交（GRDB 实现见
/// `GRDBReaderRepository` extension——与 createDocument 同一纪律，
/// 任一步失败整体回滚，metadata/进度/书签/位置行零副作用）。
public protocol ReaderRelinkStore: Sendable {
    func commitRelink(_ plan: ReaderRelinkPlan) async throws
}

/// 缺原文重关联服务（S24）：用户为 missing 文档重新选择源文件。
///
/// 流程（§4.2/§14.2 hash-relink）：
/// 1. stage 度量 SHA-256；
/// 2. `parser.open` 拿结构 + canonical hash；
/// 3. 二段确认：字节一致（source SHA-256）或内容一致
///    （canonicalTextHash——重打包 EPUB/改写行尾 TXT 场景）；
///    都不命中 → `contentMismatch`，staging 即弃、文件/库零写入；
/// 4. 逐章块流收集 → 与现有行按 (ordinal, canonicalHash/textHash)
///    求复用集（v8 恢复后块缺失是常态——导出不含 blocks，relink
///    把正文补回来）；
/// 5. 文件侧：`ReaderFiles/<documentID>/` 整体换新（旧目录先删再
///    install——目录为受控内容，replace 语义随 plan 已验证内容）；
/// 6. `commitRelink` 单事务提交；库写失败 → 回滚文件目录，文档
///    留在 missing 态可重试。
///
/// 顺序与 ingest 同纪律：文件先动、库后提交——库失败的最坏结果是
/// 文档仍缺文件（missing），不会出现 available-但无文件。
public struct ReaderRelinkService: Sendable {
    public typealias Progress = @Sendable (Double) -> Void

    private let fileStore: any ReaderFileStore
    private let repository: any ReaderRepository
    private let store: any ReaderRelinkStore
    private let assets: (any ReaderAssetRegistrar)?
    private let now: @Sendable () -> Date

    public init(
        fileStore: any ReaderFileStore,
        repository: any ReaderRepository,
        store: any ReaderRelinkStore,
        assets: (any ReaderAssetRegistrar)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileStore = fileStore
        self.repository = repository
        self.store = store
        self.assets = assets ?? repository as? any ReaderAssetRegistrar
        self.now = now
    }

    /// `preparedFileURL` 为已获 security-scope 的本地文件（scope 生命周期
    /// 归调用方）。`format` 缺省取文档记录的 format——重打包文件通常
    /// 同格式；显式传入可处理跨格式同 canonical 的极端场景。
    @discardableResult
    public func relink(
        documentID: UUID,
        preparedFileURL: URL,
        format: ReaderDocumentFormat? = nil,
        encodingOverride: PlainTextEncoding? = nil,
        limits: ReaderParserLimits = .default,
        displayName: String? = nil,
        progress: Progress? = nil
    ) async throws -> ReaderRelinkOutcome {
        do {
            return try await run(
                documentID: documentID,
                preparedFileURL: preparedFileURL,
                format: format,
                encodingOverride: encodingOverride,
                limits: limits,
                displayName: displayName,
                progress: progress
            )
        } catch is CancellationError {
            throw ReaderRelinkError.cancelled
        }
    }

    private func run(
        documentID: UUID,
        preparedFileURL: URL,
        format: ReaderDocumentFormat?,
        encodingOverride: PlainTextEncoding?,
        limits: ReaderParserLimits,
        displayName: String?,
        progress: Progress?
    ) async throws -> ReaderRelinkOutcome {
        try Task.checkCancellation()
        progress?(0.02)
        guard let document = try await repository.fetchDocument(id: documentID)
        else {
            throw ReaderRelinkError.documentNotFound
        }

        let staged = try await fileStore.stage(fileURL: preparedFileURL)
        var stagingConsumed = false
        defer {
            if !stagingConsumed {
                let fileManager = FileManager.default
                let parent = staged.stagingURL.deletingLastPathComponent()
                try? fileManager.removeItem(at: staged.stagingURL)
                if let entries = try? fileManager.contentsOfDirectory(
                    atPath: parent.path
                ), entries.isEmpty {
                    try? fileManager.removeItem(at: parent)
                }
            }
        }
        progress?(0.1)
        try Task.checkCancellation()

        let parser = Self.makeParser(
            format: format ?? document.format,
            encodingOverride: encodingOverride,
            now: now
        )
        let session = try await parser.open(
            fileURL: staged.stagingURL,
            sourceSHA256: staged.sha256,
            limits: limits
        )
        progress?(0.45)
        try Task.checkCancellation()

        // 二段确认：字节优先，canonical 兜底——均不命中即拒绝，
        // staging defer 清理，文件/库零写入。
        let confirmation: ReaderRelinkOutcome.Confirmation
        if staged.sha256 == document.sourceSHA256 {
            confirmation = .sourceSHA256
        } else if session.canonicalTextHash == document.canonicalTextHash {
            confirmation = .canonicalText
        } else {
            throw ReaderRelinkError.contentMismatch
        }

        // 收集最终章节/块（复用 ingest 的流式收集）。
        var chapters: [ReaderChapterMetadata] = []
        var blocks: [ReaderBlock] = []
        chapters.reserveCapacity(session.chapters.count)
        var blocksByChapterOrdinal: [Int: [ReaderBlock]] = [:]
        for chapterDraft in session.chapters {
            try Task.checkCancellation()
            let chapterID = UUID()
            chapters.append(
                ReaderChapterMetadata(
                    id: chapterID,
                    documentID: documentID,
                    ordinal: chapterDraft.ordinal,
                    title: chapterDraft.title,
                    sourceLocator: chapterDraft.sourceLocator,
                    canonicalHash: chapterDraft.canonicalHash,
                    textUTF16Length: chapterDraft.textUTF16Length
                )
            )
            var chapterBlocks: [ReaderBlock] = []
            let stream = try session.blocks(forChapter: chapterDraft.ordinal)
            for try await blockDraft in stream {
                try Task.checkCancellation()
                chapterBlocks.append(
                    ReaderBlock(
                        id: UUID(),
                        documentID: documentID,
                        chapterID: chapterID,
                        ordinal: blockDraft.ordinal,
                        text: blockDraft.text,
                        textHash: blockDraft.textHash,
                        locatorJSON: blockDraft.locatorJSON
                    )
                )
            }
            try Task.checkCancellation()
            blocksByChapterOrdinal[chapterDraft.ordinal] = chapterBlocks
            blocks.append(contentsOf: chapterBlocks)
        }
        progress?(0.7)

        // 稳定 ID 复用：同 ordinal 且 canonicalHash 相同的旧章保留原
        // ID（v8 恢复导出的正是这批章——bookmark/position 的
        // chapter_id 引用不断）；块按 (章 ordinal, block ordinal,
        // textHash) 复用，token_cache 随块 ID 存活。
        let oldChapters = try await repository.fetchChapters(
            documentID: documentID
        )
        var oldBlocks: [ReaderBlock] = []
        for oldChapter in oldChapters {
            oldBlocks.append(
                contentsOf: try await repository.fetchBlocks(
                    documentID: documentID, chapterID: oldChapter.id
                )
            )
        }
        var reusableChapterIDs = Set<UUID>()
        var reusableBlockIDs = Set<UUID>()
        for index in chapters.indices {
            guard let old = oldChapters.first(where: {
                $0.ordinal == chapters[index].ordinal
                    && $0.canonicalHash == chapters[index].canonicalHash
            }) else { continue }
            let reusedChapterID = old.id
            chapters[index] = ReaderChapterMetadata(
                id: reusedChapterID,
                documentID: documentID,
                ordinal: chapters[index].ordinal,
                title: chapters[index].title,
                sourceLocator: chapters[index].sourceLocator,
                canonicalHash: chapters[index].canonicalHash,
                textUTF16Length: chapters[index].textUTF16Length
            )
            reusableChapterIDs.insert(reusedChapterID)
            let oldChapterBlocks = oldBlocks.filter {
                $0.chapterID == reusedChapterID
            }
            var chapterBlocks = blocksByChapterOrdinal[
                chapters[index].ordinal
            ] ?? []
            // 章复用 → 该章全部块（含新插入的）都必须重指到复用
            // chapterID，否则块仍引用已弃用的 fresh ID。
            for blockIndex in chapterBlocks.indices {
                let block = chapterBlocks[blockIndex]
                let oldBlock = oldChapterBlocks.first(where: {
                    $0.ordinal == block.ordinal
                        && $0.textHash == block.textHash
                })
                let blockID = oldBlock?.id ?? block.id
                if let oldBlock { reusableBlockIDs.insert(oldBlock.id) }
                chapterBlocks[blockIndex] = ReaderBlock(
                    id: blockID,
                    documentID: documentID,
                    chapterID: reusedChapterID,
                    ordinal: block.ordinal,
                    text: block.text,
                    textHash: block.textHash,
                    locatorJSON: block.locatorJSON
                )
            }
            blocksByChapterOrdinal[chapters[index].ordinal] = chapterBlocks
        }
        // 块数组重建（复用 ID 已写回按章桶）。
        blocks = session.chapters.flatMap {
            blocksByChapterOrdinal[$0.ordinal] ?? []
        }
        // 内容实际变更 = 旧行有被淘汰的，或新集有新增的——两侧都比
        // 复用集才算数（v8 恢复态：块行全缺 → 全新插 → changed）。
        let contentChanged =
            reusableChapterIDs.count != oldChapters.count
            || reusableChapterIDs.count != chapters.count
            || reusableBlockIDs.count != oldBlocks.count
            || reusableBlockIDs.count != blocks.count
        progress?(0.8)
        try Task.checkCancellation()

        // 文件侧：确认通过后才允许动 ReaderFiles——先清旧目录
        // （受控内容整体换新），再原子 install。
        try await fileStore.removeFiles(documentID: documentID)
        let relativePath = try await fileStore.install(
            staged: staged,
            documentID: documentID
        )
        stagingConsumed = true

        var assetRows = [
            ReaderAssetRecord(
                documentID: documentID,
                relativePath: relativePath,
                sourceSHA256: staged.sha256,
                installState: .installed
            )
        ]
        for assetPlan in session.assets {
            assetRows.append(
                ReaderAssetRecord(
                    documentID: documentID,
                    relativePath: assetPlan.relativePath,
                    sourceSHA256: assetPlan.sourceSHA256,
                    installState: assetPlan.requiresInstall
                        ? .pending : .skipped
                )
            )
        }

        let plan = ReaderRelinkPlan(
            documentID: documentID,
            format: session.format,
            sourceFileName: displayName ?? preparedFileURL.lastPathComponent,
            sourceSHA256: staged.sha256,
            canonicalTextHash: session.canonicalTextHash,
            parserVersion: session.parserVersion,
            contentChanged: contentChanged,
            chapters: chapters,
            blocks: blocks,
            reusableChapterIDs: reusableChapterIDs,
            reusableBlockIDs: reusableBlockIDs,
            assets: assetRows
        )
        do {
            try await store.commitRelink(plan)
        } catch {
            // 库提交失败 → 回滚文件目录，文档保持 missing 可重试。
            try? await fileStore.removeFiles(documentID: documentID)
            throw error
        }
        progress?(1.0)

        let updated = ReaderDocumentMetadata(
            id: document.id,
            title: document.title,
            format: session.format,
            createdAt: document.createdAt,
            lastOpenedAt: document.lastOpenedAt,
            sourceFileName: plan.sourceFileName,
            sourceSHA256: staged.sha256,
            canonicalTextHash: session.canonicalTextHash,
            parserVersion: session.parserVersion,
            contentRevision: document.contentRevision
                + (contentChanged ? 1 : 0),
            progressBasisPoints: document.progressBasisPoints,
            availability: .available
        )
        return ReaderRelinkOutcome(
            document: updated,
            confirmation: confirmation,
            rebuiltContent: contentChanged
                || reusableBlockIDs.count != blocks.count,
            sourceRelativePath: relativePath
        )
    }

    private static func makeParser(
        format: ReaderDocumentFormat,
        encodingOverride: PlainTextEncoding?,
        now: @escaping @Sendable () -> Date
    ) -> any ReaderParser {
        switch format {
        case .epub:
            return EPUBParser(now: now)
        case .srt:
            return SubtitleParser(
                format: .srt, encodingOverride: encodingOverride
            )
        case .vtt:
            return SubtitleParser(
                format: .vtt, encodingOverride: encodingOverride
            )
        case .txt:
            return PlainTextParser(
                format: .txt, encodingOverride: encodingOverride, now: now
            )
        case .paste:
            return PlainTextParser(format: .paste, now: now)
        }
    }
}
