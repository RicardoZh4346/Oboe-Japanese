import Foundation
import OboeDomain

/// `reader_assets` 写入口：源文件本身登记为 installed 资产，
/// 之后打开文档 = fetchAssets 找 sourceSHA256 匹配行 → fileURL 解析。
/// 抽成小协议便于 ingest 与仓储解耦（GRDBReaderRepository 已实现
/// 同名方法，见文件尾 extension）。
public protocol ReaderAssetRegistrar: Sendable {
    func registerAsset(
        documentID: UUID,
        relativePath: String,
        sourceSHA256: String,
        installState: ReaderAssetInstallState
    ) async throws
    func fetchAssets(documentID: UUID) async throws -> [ReaderAssetRecord]
}

public struct ReaderImportResult: Equatable, Sendable {
    public let document: ReaderDocumentMetadata
    /// true = 新建；false = source SHA-256 命中既有文档（去重，§4.3-4）。
    public let wasCreated: Bool
    /// 源文件在 `ReaderFiles/<documentID>/` 下的受控相对路径；
    /// 命中去重时为既有文档的资产路径（若已登记）。
    public let sourceRelativePath: String?

    public init(
        document: ReaderDocumentMetadata,
        wasCreated: Bool,
        sourceRelativePath: String?
    ) {
        self.document = document
        self.wasCreated = wasCreated
        self.sourceRelativePath = sourceRelativePath
    }
}

/// Reader 导入编排（S05 纵向：stage → 去重 → 解析 → install → commit）。
///
/// 顺序与失败语义（§4.3 文件事务）：
/// 1. `fileStore.stage` 复制进 staging 并出 SHA-256；
/// 2. `findDocumentByHash` 精确命中 → 弃 staging、返回既有文档
///    （不重复建；副本创建是 UI 层显式选择，不经此路径）；
/// 3. `parser.open` + 逐章块流收集——parse 失败不安装文件、不落库；
/// 4. `install` 原子安装 → `registerAsset` 登记源文件 →
///    `createDocument` 单事务提交 documents+chapters+blocks；
///    install 失败发生在任何 DB 写之前（无行可清）；
///    createDocument 失败 → `removeFiles` 回滚已装目录。
/// 5. 取消粒度：阶段边界 + 每块；取消 → `ReaderParserError.cancelled`，
///    staging/文件/库内行按所处阶段收敛。
///
/// 恢复/重关联插桩点（不实现恢复）：hash 命中走 `findDocumentByHash`
/// （文件 SHA-256 精确）——canonical hash 确认式重关联在 UI 流程另起；
/// 文件可开性 = `fileURL(documentID:relativePath:)`。
public struct ReaderIngestService: Sendable {
    public typealias Progress = @Sendable (Double) -> Void

    private let fileStore: any ReaderFileStore
    private let repository: any ReaderRepository
    private let assets: (any ReaderAssetRegistrar)?
    private let now: @Sendable () -> Date

    public init(
        fileStore: any ReaderFileStore,
        repository: any ReaderRepository,
        assets: (any ReaderAssetRegistrar)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileStore = fileStore
        self.repository = repository
        // GRDB 仓储传入时自带资产登记能力（extension 见下）。
        self.assets = assets ?? repository as? any ReaderAssetRegistrar
        self.now = now
    }

    /// TXT 文件导入：`fileURL` 为已获 security-scope 的本地文件
    /// （scope 生命周期归调用方）。`documentID` 可注入以定测试。
    public func importTextFile(
        fileURL: URL,
        encodingOverride: PlainTextEncoding? = nil,
        limits: ReaderParserLimits = .default,
        documentID: UUID = UUID(),
        progress: Progress? = nil
    ) async throws -> ReaderImportResult {
        let parser = PlainTextParser(
            format: .txt,
            encodingOverride: encodingOverride,
            now: now
        )
        return try await ingestFile(
            preparedFileURL: fileURL,
            displayName: fileURL.lastPathComponent,
            parser: parser,
            limits: limits,
            documentID: documentID,
            progress: progress
        )
    }

    /// 粘贴导入：规范化行尾（CRLF/CR→LF）后写成 UTF-8 TXT 再走同一
    /// 管线——保证「导出原文 TXT」有真实文件（§4.3）。
    /// 空白内容硬拒 `emptyContent`（§5：不读后台剪贴板、空白拒绝）。
    public func importPaste(
        _ text: String,
        limits: ReaderParserLimits = .default,
        documentID: UUID = UUID(),
        progress: Progress? = nil
    ) async throws -> ReaderImportResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ReaderParserError.emptyContent
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "oboe-paste-\(UUID().uuidString.lowercased()).txt"
            )
        do {
            try Data(normalized.utf8).write(to: temporary)
        } catch {
            throw ReaderParserError.malformedContainer(
                reason: "粘贴文本落盘失败"
            )
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let parser = PlainTextParser(format: .paste, now: now)
        return try await ingestFile(
            preparedFileURL: temporary,
            displayName: nil,
            parser: parser,
            limits: limits,
            documentID: documentID,
            progress: progress
        )
    }

    /// 按格式分派的文件导入（S06 EPUB/SRT/VTT 入口）：
    /// `fileURL` 为已获 security-scope 的本地文件。
    public func importFile(
        fileURL: URL,
        format: ReaderDocumentFormat,
        encodingOverride: PlainTextEncoding? = nil,
        limits: ReaderParserLimits = .default,
        documentID: UUID = UUID(),
        progress: Progress? = nil
    ) async throws -> ReaderImportResult {
        let parser: any ReaderParser
        switch format {
        case .epub:
            parser = EPUBParser(now: now)
        case .srt:
            parser = SubtitleParser(
                format: .srt, encodingOverride: encodingOverride
            )
        case .vtt:
            parser = SubtitleParser(
                format: .vtt, encodingOverride: encodingOverride
            )
        case .txt:
            parser = PlainTextParser(
                format: .txt, encodingOverride: encodingOverride,
                now: now
            )
        case .paste:
            parser = PlainTextParser(format: .paste, now: now)
        }
        return try await ingestFile(
            preparedFileURL: fileURL,
            displayName: fileURL.lastPathComponent,
            parser: parser,
            limits: limits,
            documentID: documentID,
            progress: progress
        )
    }

    /// 任意 parser 的通用导入（S06 EPUB/字幕复用同一管线）。
    /// `displayName` = `source_file_name` 展示名（与原文件名无关身份）。
    public func ingestFile(
        preparedFileURL: URL,
        displayName: String?,
        parser: any ReaderParser,
        limits: ReaderParserLimits,
        documentID: UUID,
        progress: Progress?
    ) async throws -> ReaderImportResult {
        do {
            return try await ingest(
                preparedFileURL: preparedFileURL,
                displayName: displayName,
                parser: parser,
                limits: limits,
                documentID: documentID,
                progress: progress
            )
        } catch is CancellationError {
            throw ReaderParserError.cancelled
        }
    }

    // MARK: - 管线

    private func ingest(
        preparedFileURL: URL,
        displayName: String?,
        parser: any ReaderParser,
        limits: ReaderParserLimits,
        documentID: UUID,
        progress: Progress?
    ) async throws -> ReaderImportResult {
        try Task.checkCancellation()
        progress?(0.02)
        let staged = try await fileStore.stage(fileURL: preparedFileURL)
        var stagingConsumed = false
        defer {
            if !stagingConsumed {
                Self.discardStagedFile(staged)
            }
        }
        progress?(0.1)
        try Task.checkCancellation()

        // §4.3-4：同 source SHA-256 不重复建文档。
        if let existing = try await repository.findDocumentByHash(
            sourceSHA256: staged.sha256
        ) {
            let installedPath = await existingSourcePath(
                for: existing
            )
            return ReaderImportResult(
                document: existing,
                wasCreated: false,
                sourceRelativePath: installedPath
            )
        }

        // 解析：结构扫描 + 逐章块流（parse 失败 → defer 清 staging）。
        let session = try await parser.open(
            fileURL: staged.stagingURL,
            sourceSHA256: staged.sha256,
            limits: limits
        )
        progress?(0.55)
        try Task.checkCancellation()

        var chapters: [ReaderChapterMetadata] = []
        var blocks: [ReaderBlock] = []
        chapters.reserveCapacity(session.chapters.count)
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
            let stream = try session.blocks(
                forChapter: chapterDraft.ordinal
            )
            for try await blockDraft in stream {
                try Task.checkCancellation()
                blocks.append(
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
            // 消费侧取消时 for-await 以 nil 静默退出——出口处必须显式
            // 检查，否则取消会滑进 install/commit。
            try Task.checkCancellation()
        }
        progress?(0.8)

        // §4.3-3：先原子移动文件，再提交 metadata——install 失败时
        // 库内尚无行可清（文件侧残留由 store 自身收敛）。
        let relativePath = try await fileStore.install(
            staged: staged,
            documentID: documentID
        )
        stagingConsumed = true
        let document = ReaderDocumentMetadata(
            id: documentID,
            title: session.suggestedTitle,
            format: session.format,
            createdAt: now(),
            lastOpenedAt: nil,
            sourceFileName: displayName,
            sourceSHA256: staged.sha256,
            canonicalTextHash: session.canonicalTextHash,
            parserVersion: session.parserVersion,
            contentRevision: 1,
            progressBasisPoints: 0,
            availability: .available
        )
        do {
            // 元数据先行（registerAsset 有 document 存在性外键约束），
            // 资产登记随后——任一失败：删行 + 回滚文件目录。
            try await repository.createDocument(
                document,
                chapters: chapters,
                blocks: blocks
            )
            if let assets {
                // 源文件登记为 installed 资产：打开时用 fileURL 解析。
                try await assets.registerAsset(
                    documentID: documentID,
                    relativePath: relativePath,
                    sourceSHA256: staged.sha256,
                    installState: .installed
                )
                // parser 报告的附属资源计划（S06 EPUB 图片等）；
                // TXT/Paste 恒为空。
                for assetPlan in session.assets {
                    try await assets.registerAsset(
                        documentID: documentID,
                        relativePath: assetPlan.relativePath,
                        sourceSHA256: assetPlan.sourceSHA256,
                        installState: assetPlan.requiresInstall
                            ? .pending : .skipped
                    )
                }
            }
        } catch {
            // 提交半截失败 → 删文档行（级联清章/块/资产）+ 回滚
            // 已装文件目录，不留半截文档。
            try? await repository.deleteDocument(id: documentID)
            try? await fileStore.removeFiles(documentID: documentID)
            throw error
        }
        progress?(1.0)
        return ReaderImportResult(
            document: document,
            wasCreated: true,
            sourceRelativePath: relativePath
        )
    }

    /// 去重命中时找既有文档的源文件相对路径（登记的 installed 资产中
    /// sourceSHA256 == 文档 source_sha256 的行）。
    private func existingSourcePath(
        for document: ReaderDocumentMetadata
    ) async -> String? {
        guard let assets,
              let records = try? await assets.fetchAssets(
                  documentID: document.id
              ) else {
            return nil
        }
        return records.first {
            $0.sourceSHA256 == document.sourceSHA256
                && $0.installState == .installed
        }?.relativePath
    }

    /// staging 槽位清理：未走 install 的 staged 文件连槽位删除。
    /// 父目录只在删后为空时移除——不假设 stagingURL 一定有专属槽位，
    /// 其他 ReaderFileStore 实现下也安全。
    private static func discardStagedFile(_ staged: ReaderStagedFile) {
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

extension GRDBReaderRepository: ReaderAssetRegistrar {}
