import CryptoKit
import Foundation
import OboeDomain

/// EPUB `ReaderParser`（§5）：ZIP 结构 → container.xml → OPF →
/// spine 顺序逐 item 抽取 XHTML 正文。
///
/// 解析模型（两遍流式，不整书驻留）：
/// - `open()`：zip 限额闸 → mimetype → container → encryption.xml
///   扫描 → OPF → 逐 spine 章抽取 canonical 文本（hash/长度/标题），
///   manifest 图片/字体登记为 `ReaderAssetPlan(requiresInstall:false)`
///   ——资源留在容器内，`relativePath` = zip 内路径，S10 经
///   StreamingZipReader 在已装源包内取（装态 `.skipped`）。
/// - `blocks(forChapter:)`：重解该章 XHTML → 块流（逐章独立，
///   `open` 与 `blocks` 的内存上限都是单章 `maximumChapterBytes`）。
///
/// 拒绝语义（§5 错误分类，全部走 `ReaderParserError`）：
/// - 非 ZIP/无 EOCD、`mimetype` 非首条或内容错 → `notRecognized`；
/// - ZIP64/多卷/非 store|deflate → `unsupportedVariant`；
/// - 加密 flag（bit0）→ `encryptedContent`；`encryption.xml` 含
///   非字体混淆条目 → `encryptedContent`（字体混淆不拒绝）；
/// - 固定布局 rendition:layout=pre-paginated → `fixedLayoutUnsupported`；
/// - container.xml 缺失 → `missingContainerXML`；OPF 坏 → `malformedOPF`；
/// - 绝对/`..`/反斜杠路径 → `unsafeEntryPath`；
/// - 输入/展开/单章/条目数/膨胀比超限 → `limitExceeded`；
/// - ZIP 结构损坏 → `malformedContainer`。
public struct EPUBParser: ReaderParser, Sendable {
    public let format: ReaderDocumentFormat = .epub
    public let parserVersion = "epub-1.0"
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// 允许登记为资产的 MIME 族（`image/*`、`font/*`）。
    private static func isAssetMediaType(_ mediaType: String) -> Bool {
        mediaType.hasPrefix("image/") || mediaType.hasPrefix("font/")
    }

    /// 仅 spine 章节接受的内容类型。
    private static let xhtmlMediaType = "application/xhtml+xml"

    public func open(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) async throws -> ReaderParseSession {
        let parser = self
        // 结构与正文扫描离开调用方 executor；detached 不继承取消，
        // 经 handler 显式传播，内部任务接到 cancel 后由扫描循环的
        // checkCancellation 终止。
        let task = Task.detached(priority: .userInitiated) {
            try parser.scanStructure(
                fileURL: fileURL,
                sourceSHA256: sourceSHA256,
                limits: limits
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw ReaderParserError.cancelled
        }
    }

    // MARK: - open 的结构扫描

    private func scanStructure(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) throws -> EPUBParseSession {
        try Task.checkCancellation()
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.size] as? Int64) ?? 0
        guard fileSize <= Int64(limits.maximumInputBytes) else {
            throw ReaderParserError.limitExceeded(
                metric: "fileBytes",
                limit: Int64(limits.maximumInputBytes),
                actual: fileSize
            )
        }
        let reader = try Self.openZip(at: fileURL)
        defer { reader.close() }
        // 本地头校验先行：validateLocalHeaders 会向 entries 回填
        // dataStart，之后 fetch 的条目才可抽取。
        do {
            try reader.validateLocalHeaders()
        } catch {
            throw Self.mapZipError(error)
        }

        // ---- 包级限额（中央目录元数据期判定，不解压） ----
        guard reader.entries.count <= limits.maximumEntryCount else {
            throw ReaderParserError.limitExceeded(
                metric: "entryCount",
                limit: Int64(limits.maximumEntryCount),
                actual: Int64(reader.entries.count)
            )
        }
        let totalUncompressed = reader.entries.reduce(Int64(0)) {
            $0 + $1.uncompressedSize
        }
        let totalCompressed = reader.entries.reduce(Int64(0)) {
            $0 + $1.compressedSize
        }
        guard totalUncompressed <= Int64(limits.maximumExpandedBytes)
        else {
            throw ReaderParserError.limitExceeded(
                metric: "expandedBytes",
                limit: Int64(limits.maximumExpandedBytes),
                actual: totalUncompressed
            )
        }
        let ratio = totalCompressed > 0
            ? Double(totalUncompressed) / Double(totalCompressed) : 0
        guard ratio <= limits.maximumExpansionRatio else {
            throw ReaderParserError.limitExceeded(
                metric: "expansionRatio",
                limit: Int64(Int64(limits.maximumExpansionRatio)),
                actual: Int64(ratio)
            )
        }

        // ---- 条目名全量体检：`../`/绝对路径/反斜杠/空组件一律拒。
        // StreamingZipReader 不替我们查（它不向磁盘展开）；
        // 目录条目（结尾 /）在 EPUB 中合法，跳过体检。
        for entry in reader.entries where !entry.name.hasSuffix("/") {
            guard ReaderControlledPath.isValid(entry.name) else {
                throw ReaderParserError.unsafeEntryPath(entry.name)
            }
        }

        // ---- mimetype 签名 ----
        guard let first = reader.entries.first,
              first.name == "mimetype",
              first.method == .store else {
            throw ReaderParserError.notRecognized
        }
        let mimetype = try Self.extract(reader, entry: first, limit: 128)
        guard String(data: mimetype, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
                == "application/epub+zip" else {
            throw ReaderParserError.notRecognized
        }
        try Task.checkCancellation()

        // ---- container.xml → OPF 路径 ----
        guard let containerEntry = reader.entries.first(where: {
            $0.name == "META-INF/container.xml"
        }) else {
            throw ReaderParserError.missingContainerXML
        }
        let containerData = try Self.extract(
            reader, entry: containerEntry,
            limit: Int64(limits.maximumEntryBytes)
        )
        let rootfilePath = try EPUBStructureParser.parseContainer(
            containerData
        )
        guard ReaderControlledPath.isValid(rootfilePath) else {
            throw ReaderParserError.unsafeEntryPath(rootfilePath)
        }

        // ---- encryption.xml → DRM 判定 ----
        if let encryptionEntry = reader.entries.first(where: {
            $0.name == "META-INF/encryption.xml"
        }) {
            let data = try Self.extract(
                reader, entry: encryptionEntry,
                limit: Int64(limits.maximumEntryBytes)
            )
            switch try EPUBStructureParser.scanEncryption(data) {
            case .none, .fontObfuscationOnly:
                break  // 字体混淆不阻断正文
            case .encryptedContent:
                throw ReaderParserError.encryptedContent
            }
        }

        // ---- OPF ----
        guard let opfEntry = reader.entries.first(where: {
            $0.name == rootfilePath
        }) else {
            throw ReaderParserError.malformedOPF(
                reason: "rootfile \(rootfilePath) 不存在于包内"
            )
        }
        let opfData = try Self.extract(
            reader, entry: opfEntry,
            limit: Int64(limits.maximumEntryBytes)
        )
        let package = try EPUBStructureParser.parseOPF(opfData)
        guard !package.isFixedLayout else {
            throw ReaderParserError.fixedLayoutUnsupported
        }
        let opfBase = rootfilePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast().joined(separator: "/")

        // ---- spine → 章节（逐章抽取 canonical 文本） ----
        var chapters: [EPUBChapterDescriptor] = []
        var chapterDrafts: [ReaderChapterDraft] = []
        var canonicalHasher = SHA256()
        for itemref in package.spine where itemref.linear {
            try Task.checkCancellation()
            guard let item = package.items[itemref.idref] else {
                throw ReaderParserError.malformedOPF(
                    reason: "spine 引用未知 manifest id: \(itemref.idref)"
                )
            }
            guard item.mediaType == Self.xhtmlMediaType else {
                continue  // 非 XHTML spine item 跳过（如封面图片章）
            }
            guard let path = Self.resolve(
                base: opfBase, href: item.href
            ), ReaderControlledPath.isValid(path) else {
                throw ReaderParserError.unsafeEntryPath(item.href)
            }
            guard let entry = reader.entries.first(where: {
                $0.name == path
            }) else {
                throw ReaderParserError.malformedOPF(
                    reason: "spine 引用缺失条目: \(path)"
                )
            }
            let data = try Self.extract(
                reader, entry: entry,
                limit: Int64(limits.maximumChapterBytes)
            )
            let chapter = try Self.scanChapter(data: data)
            // 文档级 canonical hash = 各章 canonical hash 的级联
            // （hash-of-hashes，不受章节内分隔符歧义影响）。
            canonicalHasher.update(
                data: Data(chapter.canonicalHash.utf8)
            )
            chapters.append(EPUBChapterDescriptor(
                ordinal: chapters.count,
                entryName: path,
                canonicalHash: chapter.canonicalHash,
                textUTF16Length: chapter.textUTF16Length
            ))
            chapterDrafts.append(ReaderChapterDraft(
                ordinal: chapterDrafts.count,
                title: chapter.headingTitle,
                sourceLocator: path,
                canonicalHash: chapter.canonicalHash,
                textUTF16Length: chapter.textUTF16Length
            ))
        }
        guard !chapters.isEmpty else {
            throw ReaderParserError.malformedOPF(
                reason: "spine 中没有 XHTML 章节"
            )
        }

        // ---- 资产计划：image/font 登记 zip 内路径 ----
        var assetPlans: [ReaderAssetPlan] = []
        for item in package.items.values {
            guard Self.isAssetMediaType(item.mediaType) else { continue }
            guard let path = Self.resolve(
                base: opfBase, href: item.href
            ), ReaderControlledPath.isValid(path) else {
                throw ReaderParserError.unsafeEntryPath(item.href)
            }
            guard let entry = reader.entries.first(where: {
                $0.name == path
            }) else {
                continue  // manifest 引用的缺失图片容忍跳过
            }
            let bytes = try Self.extract(
                reader, entry: entry,
                limit: Int64(limits.maximumEntryBytes)
            )
            assetPlans.append(ReaderAssetPlan(
                relativePath: path,
                sourceSHA256: ReaderHashing.sha256Hex(bytes),
                requiresInstall: false
            ))
            try Task.checkCancellation()
        }

        let documentHash = ReaderHashing.hex(canonicalHasher.finalize())
        let title = package.title
            ?? fileURL.deletingPathExtension().lastPathComponent
        return EPUBParseSession(
            fileURL: fileURL,
            sourceSHA256: sourceSHA256,
            canonicalTextHash: documentHash,
            parserVersion: parserVersion,
            limits: limits,
            suggestedTitle: title.isEmpty ? "Untitled" : title,
            chapterDescriptors: chapters,
            chapterDrafts: chapterDrafts,
            assetPlans: assetPlans
        )
    }

    /// 单章 canonical 扫描：XHTML → normalizer → hash/len/标题。
    private static func scanChapter(
        data: Data
    ) throws -> (canonicalHash: String, textUTF16Length: Int,
                 headingTitle: String?) {
        var normalizer = CanonicalTextNormalizer()
        var hasher = SHA256()
        var totalUTF16 = 0
        var headingTitle: String?
        let extractor = XHTMLTextExtractor()
        try extractor.extract(data: data, sink: .init(
            feed: { piece in
                for cluster in normalizer.feed(piece) {
                    hasher.update(data: Data(cluster.utf8))
                    totalUTF16 += cluster.utf16.count
                }
            },
            onChapterTitle: { title in headingTitle = title }
        ))
        for cluster in normalizer.finish() {
            hasher.update(data: Data(cluster.utf8))
            totalUTF16 += cluster.utf16.count
        }
        return (ReaderHashing.hex(hasher.finalize()), totalUTF16, headingTitle)
    }

    /// OPF 相对 href → zip 内规范路径。`../` 允许内部回退但不得越根。
    static func resolve(base: String, href: String) -> String? {
        let decoded = href.removingPercentEncoding ?? href
        let noFragment = decoded.split(
            separator: "#", maxSplits: 1, omittingEmptySubsequences: false
        ).first.map(String.init) ?? decoded
        var stack = base.isEmpty
            ? [String]()
            : base.split(separator: "/").map(String.init)
        for component in noFragment.split(
            separator: "/", omittingEmptySubsequences: true
        ) {
            switch component {
            case ".": continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default:
                stack.append(String(component))
            }
        }
        let result = stack.joined(separator: "/")
        return result.isEmpty ? nil : result
    }

    // MARK: - zip 适配

    // fileprivate：blocks(forChapter:) 的 ReaderBlockStream 闭包在同文件
    // 的其他类型里调用（private 会限定在 EPUBParser 词法域内）。
    fileprivate static func openZip(at fileURL: URL) throws -> StreamingZipReader {
        do {
            return try StreamingZipReader(fileURL: fileURL)
        } catch {
            throw mapZipError(error)
        }
    }

    fileprivate static func extract(
        _ reader: StreamingZipReader,
        entry: StreamingZipReader.Entry,
        limit: Int64
    ) throws -> Data {
        do {
            return try reader.extractToData(entry, byteLimit: limit)
        } catch {
            throw mapZipError(error)
        }
    }

    /// PortableBackupPackageError → ReaderParserError（backup 文案
    /// 不透出；§5 粗粒度分类）。
    static func mapZipError(_ error: Error) -> Error {
        guard let zipError = error as? PortableBackupPackageError else {
            return error
        }
        switch zipError {
        case .notAPackage, .invalidEntryName:
            return ReaderParserError.notRecognized
        case .encryptedArchive:
            return ReaderParserError.encryptedContent
        case let .unsupportedCompressionMethod(method):
            return ReaderParserError.unsupportedVariant(
                variant: "compression \(method)"
            )
        case let .packageTooLarge(actual, limit),
             let .totalUncompressedTooLarge(actual, limit):
            return ReaderParserError.limitExceeded(
                metric: "expandedBytes", limit: limit, actual: actual
            )
        case let .tooManyEntries(actual, limit):
            return ReaderParserError.limitExceeded(
                metric: "entryCount", limit: Int64(limit),
                actual: Int64(actual)
            )
        case let .entryTooLarge(_, actual, limit):
            return ReaderParserError.limitExceeded(
                metric: "entryBytes", limit: limit, actual: actual
            )
        case let .invalidEntryPath(name),
             let .nonRegularFileEntry(name):
            return ReaderParserError.unsafeEntryPath(name)
        case let .duplicateEntry(name):
            return ReaderParserError.malformedContainer(
                reason: "duplicate entry: \(name)"
            )
        case let .malformedArchive(reason):
            return ReaderParserError.malformedContainer(reason: reason)
        case let .sizeMismatch(name, expected, actual):
            return ReaderParserError.malformedContainer(
                reason: "\(name) 解压大小不符 \(actual)≠\(expected)"
            )
        case let .crcMismatch(name):
            return ReaderParserError.malformedContainer(
                reason: "\(name) CRC32 校验失败"
            )
        default:
            return ReaderParserError.malformedContainer(
                reason: "\(zipError)"
            )
        }
    }
}

/// 单章描述符（blocks 流按其 entryName 重解 zip 内路径）。
struct EPUBChapterDescriptor: Sendable {
    let ordinal: Int
    let entryName: String
    let canonicalHash: String
    let textUTF16Length: Int
}

/// EPUB session：结构先行，块文本逐章按需重解流。
struct EPUBParseSession: ReaderParseSession {
    let fileURL: URL
    let format: ReaderDocumentFormat = .epub
    let sourceSHA256: String
    let canonicalTextHash: String
    let parserVersion: String
    let limits: ReaderParserLimits
    let suggestedTitle: String
    /// open() 建立的章描述符（zip 内路径 + canonical hash + 长度），
    /// blocks(forChapter:) 按 entryName 重解。
    let chapterDescriptors: [EPUBChapterDescriptor]
    let chapterDrafts: [ReaderChapterDraft]
    let assetPlans: [ReaderAssetPlan]

    var chapters: [ReaderChapterDraft] { chapterDrafts }
    var assets: [ReaderAssetPlan] { assetPlans }

    func blocks(forChapter ordinal: Int) throws -> ReaderBlockStream {
        guard let chapter = chapterDescriptors.first(where: {
            $0.ordinal == ordinal
        }) else {
            throw ReaderParserError.malformedContainer(
                reason: "EPUB 无章 ordinal \(ordinal)"
            )
        }
        let fileURL = self.fileURL
        let limits = self.limits
        return ReaderBlockStream { continuation in
            let task = Task.detached {
                do {
                    let reader = try EPUBParser.openZip(at: fileURL)
                    defer { reader.close() }
                    do {
                        try reader.validateLocalHeaders()
                    } catch {
                        throw EPUBParser.mapZipError(error)
                    }
                    guard let entry = reader.entries.first(where: {
                        $0.name == chapter.entryName
                    }) else {
                        throw ReaderParserError.malformedContainer(
                            reason: "章条目消失: \(chapter.entryName)"
                        )
                    }
                    let data = try EPUBParser.extract(
                        reader, entry: entry,
                        limit: Int64(limits.maximumChapterBytes)
                    )
                    var normalizer = CanonicalTextNormalizer()
                    var blocker = PlainTextBlocker()
                    let extractor = XHTMLTextExtractor()
                    func emit(_ text: String) {
                        let start = blocker.consumedUTF16
                            - text.utf16.count
                        continuation.yield(ReaderBlockDraft(
                            ordinal: blocker.nextOrdinal - 1,
                            text: text,
                            textHash: ReaderHashing.sha256Hex(
                                Data(text.utf8)
                            ),
                            locatorJSON:
                                "{\"v\":1,\"utf16_start\":\(start)}"
                        ))
                    }
                    try extractor.extract(data: data, sink: .init(
                        feed: { piece in
                            for cluster in normalizer.feed(piece) {
                                if let block = blocker.feed(cluster) {
                                    emit(block)
                                }
                            }
                        },
                        onChapterTitle: { _ in }
                    ))
                    for cluster in normalizer.finish() {
                        if let block = blocker.feed(cluster) {
                            emit(block)
                        }
                    }
                    if let tail = blocker.finish() {
                        emit(tail)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(
                        throwing: ReaderParserError.cancelled
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
