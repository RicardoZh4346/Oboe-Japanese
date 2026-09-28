import Foundation

/// v0.7.0 S02 冻结契约：Reader 域模型与解析器接口。
/// 依据：详细技术实现文档 §4（数据模型/定位协议/文件事务）、§5（五种解析器）
/// 与 S01 spike 结论（parser-epub-spike.md）。
/// 冻结项：ReaderLocation UTF-16 定位、流式 parse session、错误语义、
/// 受控相对路径文件仓库边界、取消与进度接口。
///
/// 约定：所有文本定位一律 UTF-16 code unit 偏移；不持久化像素位置与
/// Swift `String.Index`。原文全文属于本地资源，不进备份（D06）。

// MARK: - 文档与结构

/// 受支持的五种输入（Gate，D01）。
public enum ReaderDocumentFormat: String, Codable, CaseIterable, Sendable {
    case paste
    case txt
    case epub
    case srt
    case vtt
}

/// 文档可用性由 metadata + 本地资源状态推导（§4.1），
/// 不允许从备份恢复出一个虚假的 `available`。
public enum ReaderDocumentAvailability: String, Codable, Sendable {
    case available
    case processing
    case missing
    case failed
}

public struct ReaderDocumentMetadata: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let format: ReaderDocumentFormat
    public let createdAt: Date
    public let lastOpenedAt: Date?
    /// 原始文件名（仅展示用；不构成文件身份）。
    public let sourceFileName: String?
    /// 原文件 SHA-256（hex）。
    public let sourceSHA256: String
    /// 解析后 canonical 文本 hash——ZIP 元数据抖动不改变它（§4.2）。
    public let canonicalTextHash: String
    /// 产出本 metadata 的解析器版本；重关联时校验兼容（§4.2）。
    public let parserVersion: String
    public let contentRevision: Int
    /// 进度：0...10000 基点（万分比）。
    public let progressBasisPoints: Int
    public let availability: ReaderDocumentAvailability

    public init(
        id: UUID,
        title: String,
        format: ReaderDocumentFormat,
        createdAt: Date,
        lastOpenedAt: Date?,
        sourceFileName: String?,
        sourceSHA256: String,
        canonicalTextHash: String,
        parserVersion: String,
        contentRevision: Int,
        progressBasisPoints: Int,
        availability: ReaderDocumentAvailability
    ) {
        self.id = id
        self.title = title
        self.format = format
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.sourceFileName = sourceFileName
        self.sourceSHA256 = sourceSHA256
        self.canonicalTextHash = canonicalTextHash
        self.parserVersion = parserVersion
        self.contentRevision = contentRevision
        self.progressBasisPoints = progressBasisPoints
        self.availability = availability
    }
}

public struct ReaderChapterMetadata: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let documentID: UUID
    /// 0 起始的顺序号；UNIQUE(documentID, ordinal)。
    public let ordinal: Int
    public let title: String?
    /// 格式相关的定位串（EPUB = manifest href + #fragment；
    /// 字幕 = cue 区间），不透明存储，进 `reader_chapters.source_locator`。
    public let sourceLocator: String?
    public let canonicalHash: String
    public let textUTF16Length: Int

    public init(
        id: UUID,
        documentID: UUID,
        ordinal: Int,
        title: String?,
        sourceLocator: String?,
        canonicalHash: String,
        textUTF16Length: Int
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.title = title
        self.sourceLocator = sourceLocator
        self.canonicalHash = canonicalHash
        self.textUTF16Length = textUTF16Length
    }
}

/// 正文块：渲染与挖词的基本单位。目标 ~2000 UTF-16 units，硬上限 8192；
/// 尽量按段落/句末切分，不断开组合字符（§5）。
public struct ReaderBlock: Equatable, Identifiable, Sendable {
    public static let targetUTF16Length = 2_000
    public static let maximumUTF16Length = 8_192

    public let id: UUID
    public let documentID: UUID
    public let chapterID: UUID
    public let ordinal: Int
    /// canonical 原文；查询规范化只作用于副本，不回写此字段（§6.1）。
    public let text: String
    public let textHash: String
    /// 该块在原文件中的定位（格式相关，不透明）。
    public let locatorJSON: String?

    public init(
        id: UUID,
        documentID: UUID,
        chapterID: UUID,
        ordinal: Int,
        text: String,
        textHash: String,
        locatorJSON: String?
    ) {
        self.id = id
        self.documentID = documentID
        self.chapterID = chapterID
        self.ordinal = ordinal
        self.text = text
        self.textHash = textHash
        self.locatorJSON = locatorJSON
    }
}

// MARK: - 定位协议（§4.2）

/// 位置/书签的统一定位结构。`version` 当前为 1。
/// 字号/窗口变化后先定位块，再定位 UTF-16 偏移；歧义退回章节开头并
/// 显示「位置未能精确恢复」，不静默落错位置。
public struct ReaderLocation: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    /// prefix/suffix 各至多 32 个 Character（不是 UTF-16 units）。
    public static let contextCharacterLimit = 32

    public let version: Int
    public let chapterOrdinal: Int
    public let blockOrdinal: Int
    /// 块内 UTF-16 偏移。
    public let utf16Offset: Int
    /// 目标块的 canonical text hash——内容不符即降级到章节开头。
    public let blockTextHash: String
    public let prefix: String
    public let suffix: String
    /// 字幕 cue 起点毫秒（仅 srt/vtt 使用；EPUB 恒 nil）。
    public let cueStartMilliseconds: Int?

    public init(
        chapterOrdinal: Int,
        blockOrdinal: Int,
        utf16Offset: Int,
        blockTextHash: String,
        prefix: String,
        suffix: String,
        cueStartMilliseconds: Int? = nil
    ) {
        self.version = Self.currentVersion
        self.chapterOrdinal = chapterOrdinal
        self.blockOrdinal = blockOrdinal
        self.utf16Offset = utf16Offset
        self.blockTextHash = blockTextHash
        self.prefix = String(prefix.prefix(Self.contextCharacterLimit))
        self.suffix = String(suffix.prefix(Self.contextCharacterLimit))
        self.cueStartMilliseconds = cueStartMilliseconds
    }
}

public struct ReaderBookmark: Equatable, Identifiable, Sendable {
    /// label 上限（§4.1 表注）。
    public static let maximumLabelCharacters = 200

    public let id: UUID
    public let documentID: UUID
    public let chapterID: UUID?
    public let location: ReaderLocation
    public let label: String?
    public let createdAt: Date

    public init(
        id: UUID,
        documentID: UUID,
        chapterID: UUID?,
        location: ReaderLocation,
        label: String?,
        createdAt: Date
    ) {
        self.id = id
        self.documentID = documentID
        self.chapterID = chapterID
        self.location = location
        self.label = label
        self.createdAt = createdAt
    }
}

public struct ReaderPosition: Equatable, Sendable {
    public let documentID: UUID
    public let chapterID: UUID?
    public let location: ReaderLocation
    /// 以写入时刻裁决：旧保存请求不得覆盖较新的 updatedAt（§4.2）。
    public let updatedAt: Date

    public init(
        documentID: UUID,
        chapterID: UUID?,
        location: ReaderLocation,
        updatedAt: Date
    ) {
        self.documentID = documentID
        self.chapterID = chapterID
        self.location = location
        self.updatedAt = updatedAt
    }
}

// MARK: - 解析器契约（§5 + S01 spike 修订）

/// 解析输入限额（§5 建议值；实现可接受更小值用于测试）。
public struct ReaderParserLimits: Equatable, Sendable {
    public var maximumInputBytes: Int
    public var maximumExpandedBytes: Int
    public var maximumEntryBytes: Int
    public var maximumEntryCount: Int
    public var maximumExpansionRatio: Double
    /// 单章 XHTML 上限——超出硬拒（S01 决议：不为单章放宽，
    /// 错误明示原因）。
    public var maximumChapterBytes: Int

    public init(
        maximumInputBytes: Int = 50 * 1024 * 1024,
        maximumExpandedBytes: Int = 200 * 1024 * 1024,
        maximumEntryBytes: Int = 20 * 1024 * 1024,
        maximumEntryCount: Int = 10_000,
        maximumExpansionRatio: Double = 100.0,
        maximumChapterBytes: Int = 20 * 1024 * 1024
    ) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumEntryCount = maximumEntryCount
        self.maximumExpansionRatio = maximumExpansionRatio
        self.maximumChapterBytes = maximumChapterBytes
    }

    public static let `default` = ReaderParserLimits()
}

/// 解析/导入错误分类（§5 错误语义：失败要能说清原因，不静默降级；
/// spike 对齐：backup 的 PortableBackupPackageError 文案不透出）。
public enum ReaderParserError: Error, Equatable, Sendable {
    /// 输入格式不被该 parser 支持或签名不符（非 ZIP/无 mimetype/坏 SRT 头等）。
    case notRecognized
    /// ZIP/OCF 结构损坏（映射自底层 reader，文案不透出 backup 域）。
    case malformedContainer(reason: String)
    case missingContainerXML
    case malformedOPF(reason: String)
    /// EPUB：zip bit0 加密条目或 encryption.xml 非字体混淆算法 → DRM 拒绝。
    /// v1 用粗粒度（不定到条目名），文案「含加密/DRM 内容」。
    case encryptedContent
    /// 固定布局 rendition:layout=pre-paginated。
    case fixedLayoutUnsupported
    /// ZIP64/多卷/非 store|deflate 压缩等明确不支持项。
    case unsupportedVariant(variant: String)
    /// 超限：输入体积/展开体积/entry 数/展开比/单章。
    case limitExceeded(metric: String, limit: Int64, actual: Int64)
    /// 路径穿越/绝对路径/符号链接/同名覆盖（zip 安全校验）。
    case unsafeEntryPath(String)
    /// 编码无法确定且置信度不足——调用方应走手动编码预览（TXT/CSV）。
    case undeterminedEncoding(sampledEncodings: [String])
    /// 字幕：非法 cue（1 起始行号）；少量坏 cue 由调用方显式跳过。
    case malformedCue(line: Int, reason: String)
    /// 粘贴空白/文档空内容。
    case emptyContent
    /// 用户取消。
    case cancelled
}

/// 解析出的章节草稿（documentID 由安装方赋予）。
public struct ReaderChapterDraft: Equatable, Sendable {
    public let ordinal: Int
    public let title: String?
    public let sourceLocator: String?
    public let canonicalHash: String
    public let textUTF16Length: Int

    public init(
        ordinal: Int,
        title: String?,
        sourceLocator: String?,
        canonicalHash: String,
        textUTF16Length: Int
    ) {
        self.ordinal = ordinal
        self.title = title
        self.sourceLocator = sourceLocator
        self.canonicalHash = canonicalHash
        self.textUTF16Length = textUTF16Length
    }
}

public struct ReaderBlockDraft: Equatable, Sendable {
    public let ordinal: Int
    public let text: String
    public let textHash: String
    public let locatorJSON: String?

    public init(ordinal: Int, text: String, textHash: String, locatorJSON: String?) {
        self.ordinal = ordinal
        self.text = text
        self.textHash = textHash
        self.locatorJSON = locatorJSON
    }
}

/// 资源安装计划（EPUB 图片等本地资源；路径必须是规范化容器内相对路径）。
public struct ReaderAssetPlan: Equatable, Sendable {
    public let relativePath: String
    public let sourceSHA256: String
    /// true = 需要落盘安装；false = 仅登记（如解析期跳过的远程/不支持资源）。
    public let requiresInstall: Bool

    public init(relativePath: String, sourceSHA256: String, requiresInstall: Bool) {
        self.relativePath = relativePath
        self.sourceSHA256 = sourceSHA256
        self.requiresInstall = requiresInstall
    }
}

/// 块流：逐章拉取、不整书驻留（§5：10MB EPUB 可增量读取；
/// §17 内存约束）。实现侧可用 AsyncThrowingStream。
public typealias ReaderBlockStream = AsyncThrowingStream<ReaderBlockDraft, Error>

/// 解析 session：open 后结构先行，块文本按需逐章流出。
/// `Task` 取消时底层流须终止并抛 `cancelled`。
public protocol ReaderParseSession: Sendable {
    var format: ReaderDocumentFormat { get }
    /// 建议标题（用户可改）。
    var suggestedTitle: String { get }
    /// 原文件 SHA-256（staging 阶段算好传入或直接度量）。
    var sourceSHA256: String { get }
    /// canonical 文本 hash（结构就绪后可得；EPUB = spine 正文级联 hash）。
    var canonicalTextHash: String { get }
    var parserVersion: String { get }
    var chapters: [ReaderChapterDraft] { get }
    var assets: [ReaderAssetPlan] { get }
    /// 单章块流；重复调用返回新流（按 ordinal 索引）。
    func blocks(forChapter ordinal: Int) throws -> ReaderBlockStream
}

public protocol ReaderParser: Sendable {
    /// 该实现服务的格式；registry 按 format 分发。
    var format: ReaderDocumentFormat { get }
    /// 实现版本串，写入文档 `parserVersion`。
    var parserVersion: String { get }
    /// 输入：已 staging 的受控本地文件（security-scope 已在外层处理），
    /// 不接任意网络 URL；`Task` 取消语义贯穿整个 session 生命周期。
    func open(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) async throws -> ReaderParseSession
}

// MARK: - 文件仓库与持久化边界（§4.3 / v17）

/// 受控文件仓库边界：所有路径为受控相对路径；
/// staging → 原子 install → 启动清理 journal。
public protocol ReaderFileStore: Sendable {
    /// 把用户选择的文件复制进 staging 并返回 hash/字节数；
    /// 调用方负责 security-scope 生命周期。
    func stage(fileURL: URL) async throws -> ReaderStagedFile
    /// staging → `ReaderFiles/<documentID>/` 原子安装；返回受控相对路径。
    func install(staged: ReaderStagedFile, documentID: UUID) async throws -> String
    /// 文档删除/恢复清理其文件目录。
    func removeFiles(documentID: UUID) async throws
    /// 启动收敛：清理未完成 staging/中断 install 的残留。
    func collectOrphans() async throws
    /// 按 documentID 解析出可用本地文件；文件缺失返回 nil（→ missing）。
    func fileURL(documentID: UUID, relativePath: String) -> URL?
}

public struct ReaderStagedFile: Equatable, Sendable {
    public let stagingURL: URL
    public let sha256: String
    public let byteCount: Int64

    public init(stagingURL: URL, sha256: String, byteCount: Int64) {
        self.stagingURL = stagingURL
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// 元数据/书签/位置/块的持久化边界（v17）。实现见
/// Infrastructure 的 GRDB 仓储；Domain 只依赖此协议。
public protocol ReaderRepository: Sendable {
    func createDocument(
        _ document: ReaderDocumentMetadata,
        chapters: [ReaderChapterMetadata],
        blocks: [ReaderBlock]
    ) async throws
    func fetchDocument(id: UUID) async throws -> ReaderDocumentMetadata?
    func fetchDocumentSummaries() async throws -> [ReaderDocumentMetadata]
    func fetchChapters(documentID: UUID) async throws -> [ReaderChapterMetadata]
    /// 块读取按章分页，不整书载入（§17 内存约束）。
    func fetchBlocks(documentID: UUID, chapterID: UUID) async throws -> [ReaderBlock]
    func savePosition(_ position: ReaderPosition) async throws
    func fetchPosition(documentID: UUID) async throws -> ReaderPosition?
    func addBookmark(_ bookmark: ReaderBookmark) async throws
    func removeBookmark(id: UUID) async throws
    func fetchBookmarks(documentID: UUID) async throws -> [ReaderBookmark]
    /// 删除文档连带位置/书签/正文/缓存；SourceContext/Cloze/统计历史保留（§4.3-5）。
    func deleteDocument(id: UUID) async throws
    func updateAvailability(id: UUID, availability: ReaderDocumentAvailability) async throws
    /// 按内容重关联（§4.2/§14.2）：文件 hash 精确优先，canonical hash 需确认。
    func findDocumentByHash(sourceSHA256: String) async throws -> ReaderDocumentMetadata?
    func findDocumentsByCanonicalHash(_ canonicalTextHash: String) async throws -> [ReaderDocumentMetadata]
}
