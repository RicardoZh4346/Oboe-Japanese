import CryptoKit
import Foundation
import OboeDomain

/// TXT/Paste 手动编码覆盖选项（§5「可手动指定 Shift-JIS」）。
/// utf8/utf16LE/utf16BE 走 S16 `IncrementalTextDecoder` 严格增量解码；
/// shiftJIS 走 Foundation 一次性解码（手动重试路径，仍受输入限额约束）。
public enum PlainTextEncoding: String, CaseIterable, Sendable {
    case utf8
    case utf16LE
    case utf16BE
    case shiftJIS

    /// 映射到 S16 增量解码器可承载的编码；nil = 需要整段解码路径。
    var importEncoding: ImportTextEncoding? {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LE
        case .utf16BE: return .utf16BE
        case .shiftJIS: return nil
        }
    }

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .shiftJIS: return .shiftJIS
        }
    }
}

/// TXT/Paste `ReaderParser`（§5）：BOM/严格 UTF-8 检测 → 增量解码 →
/// canonical 规范化（CRLF→LF + NFC）→ grapheme 分块。
///
/// - TXT：建议标题 = 文件名去扩展名；粘贴：首行截断 ≤80 字符，
///   空白退化为 "Pasted YYYY-MM-DD"（`now` 注入便于测试）。
/// - `open` 的结构扫描（编码检测 + 全量解码 + hash/长度）在
///   `Task.detached` 内执行——MainActor 不被整书扫描占用。
/// - 解码错误语义：检测期 undetermined / 非 BOM 判定中途失败 /
///   手动编码失败 → `ReaderParserError.undeterminedEncoding`
///   （供 UI 走手动编码预览）；BOM 锚定后中途损坏 →
///   `malformedContainer`（该编码下的真实损坏，不再猜编码）。
public struct PlainTextParser: ReaderParser, Sendable {
    public let format: ReaderDocumentFormat
    public let parserVersion = "plaintext-1.0"
    /// 手动编码覆盖：nil = 自动检测。手动指定即按指定解码（预览确认流程）。
    private let encodingOverride: PlainTextEncoding?
    private let now: @Sendable () -> Date

    /// 文件读取窗口。增量解码本身切块无感，64KiB 是 I/O 折中。
    static let readChunkSize = 64 * 1024

    public init(
        format: ReaderDocumentFormat = .txt,
        encodingOverride: PlainTextEncoding? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        precondition(
            format == .txt || format == .paste,
            "PlainTextParser 仅支持 txt/paste"
        )
        self.format = format
        self.encodingOverride = encodingOverride
        self.now = now
    }

    public func open(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) async throws -> ReaderParseSession {
        let parser = self
        // 整书扫描离开调用方 executor：MainActor 只等结果（§3/§17）。
        // detached 不继承取消——经 withTaskCancellationHandler 传播，
        // 取消时终止内部扫描并统一抛 cancelled（§5 取消语义）。
        let scanTask = Task.detached(priority: .userInitiated) {
            try parser.scanStructure(fileURL: fileURL, limits: limits)
        }
        let scan: PlainTextScanResult
        do {
            scan = try await withTaskCancellationHandler {
                try await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
        } catch is CancellationError {
            throw ReaderParserError.cancelled
        }
        return PlainTextParseSession(
            fileURL: fileURL,
            format: format,
            sourceSHA256: sourceSHA256,
            canonicalTextHash: scan.canonicalTextHash,
            parserVersion: parserVersion,
            encodingOverride: encodingOverride,
            limits: limits,
            suggestedTitle: suggestTitle(fileURL: fileURL, scan: scan),
            chapter: ReaderChapterDraft(
                ordinal: 0,
                title: nil,
                sourceLocator: nil,
                canonicalHash: scan.canonicalTextHash,
                textUTF16Length: scan.textUTF16Length
            )
        )
    }

    // MARK: - 标题

    private func suggestTitle(
        fileURL: URL,
        scan: PlainTextScanResult
    ) -> String {
        switch format {
        case .paste:
            let trimmed = scan.firstLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                return String(trimmed.prefix(80))
            }
            return "Pasted \(Self.dateFormatter.string(from: now()))"
        default:
            let name = fileURL.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - 结构扫描

    /// 第一遍：检测编码 → 全量解码 → 规范化 → canonical hash/长度/
    /// 首行。为保流式，不存整文，仅累积 hash 与少量 metadata。
    private func scanStructure(
        fileURL: URL,
        limits: ReaderParserLimits
    ) throws -> PlainTextScanResult {
        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.size] as? Int64) ?? 0
        if fileSize > Int64(limits.maximumInputBytes) {
            throw ReaderParserError.limitExceeded(
                metric: "fileBytes",
                limit: Int64(limits.maximumInputBytes),
                actual: fileSize
            )
        }
        var normalizer = CanonicalTextNormalizer()
        var hasher = SHA256()
        var totalUTF16 = 0
        var sawNonWhitespace = false
        var firstLine = ""
        var firstLineComplete = false

        func absorb(_ cluster: String) {
            hasher.update(data: Data(cluster.utf8))
            totalUTF16 += cluster.utf16.count
            if !sawNonWhitespace,
               !cluster.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                sawNonWhitespace = true
            }
            if !firstLineComplete {
                if cluster == "\n" {
                    firstLineComplete = true
                } else if firstLine.utf16.count < 512 {
                    firstLine.append(cluster)
                }
            }
        }

        try PlainTextDecodePump.run(
            fileURL: fileURL,
            encodingOverride: encodingOverride,
            limits: limits
        ) { piece in
            for cluster in normalizer.feed(piece) {
                absorb(cluster)
            }
        }
        for cluster in normalizer.finish() {
            absorb(cluster)
        }
        guard sawNonWhitespace else {
            throw ReaderParserError.emptyContent
        }
        return PlainTextScanResult(
            canonicalTextHash: ReaderHashing.hex(hasher.finalize()),
            textUTF16Length: totalUTF16,
            firstLine: firstLine
        )
    }
}

/// 结构扫描结果（canonical hash、总 UTF-16 长、首行）。
struct PlainTextScanResult: Sendable {
    let canonicalTextHash: String
    let textUTF16Length: Int
    let firstLine: String
}

/// TXT 为单章文档（§5 未要求 TXT 章节切分）：整文一章，
/// 块按段落/句末切。
struct PlainTextParseSession: ReaderParseSession {
    let fileURL: URL
    let format: ReaderDocumentFormat
    let sourceSHA256: String
    let canonicalTextHash: String
    let parserVersion: String
    let encodingOverride: PlainTextEncoding?
    let limits: ReaderParserLimits
    let suggestedTitle: String
    let chapter: ReaderChapterDraft

    var chapters: [ReaderChapterDraft] { [chapter] }
    /// TXT/Paste 无附属资源（§4.1 assets 为空）。
    var assets: [ReaderAssetPlan] { [] }

    /// 第二遍：重走解码管线逐块流出。重复调用返回独立新流；
    /// 取消时底层解码循环检查 `Task.isCancelled` → `cancelled`。
    func blocks(forChapter ordinal: Int) throws -> ReaderBlockStream {
        guard ordinal == chapter.ordinal else {
            throw ReaderParserError.malformedContainer(
                reason: "plaintext 仅一章 (ordinal 0)，收到 \(ordinal)"
            )
        }
        let fileURL = self.fileURL
        let encodingOverride = self.encodingOverride
        let limits = self.limits
        return ReaderBlockStream { continuation in
            let task = Task.detached {
                do {
                    var normalizer = CanonicalTextNormalizer()
                    var blocker = PlainTextBlocker()
                    func emit(_ text: String) {
                        // 块真起点 = 已消费 canonical 长度 − 本块长度
                        // （丢弃的前导空白也计入 consumedUTF16）。
                        let start = blocker.consumedUTF16
                            - text.utf16.count
                        let draft = ReaderBlockDraft(
                            ordinal: blocker.nextOrdinal - 1,
                            text: text,
                            textHash: ReaderHashing.sha256Hex(
                                Data(text.utf8)
                            ),
                            locatorJSON:
                                "{\"v\":1,\"utf16_start\":\(start)}"
                        )
                        continuation.yield(draft)
                    }
                    try PlainTextDecodePump.run(
                        fileURL: fileURL,
                        encodingOverride: encodingOverride,
                        limits: limits
                    ) { piece in
                        for cluster in normalizer.feed(piece) {
                            if let blockText = blocker.feed(cluster) {
                                emit(blockText)
                            }
                        }
                    }
                    for cluster in normalizer.finish() {
                        if let blockText = blocker.feed(cluster) {
                            emit(blockText)
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

/// 解码泵：文件 →（检测/编码覆盖 解码器）→ 逐段喂规范化器。
/// 两处调用方：open 的结构扫描与 blocks() 的块流。错误统一映射为
/// `ReaderParserError`（见各分支注释）。
enum PlainTextDecodePump {
    static let chunkSize = PlainTextParser.readChunkSize

    /// `sink` 收到解码后的文本片段（顺序、长度由解码器决定）。
    static func run(
        fileURL: URL,
        encodingOverride: PlainTextEncoding?,
        limits: ReaderParserLimits,
        sink: (String) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        if let encodingOverride, encodingOverride.importEncoding == nil {
            // Shift-JIS 等仅 Foundation 解码路径：整段一次解码后喂流。
            // 手动重试路径，仍受 maximumInputBytes 约束。
            let data = try handle.readToEnd() ?? Data()
            try Task.checkCancellation()
            guard let text = String(
                data: data, encoding: encodingOverride.foundationEncoding
            ) else {
                throw ReaderParserError.undeterminedEncoding(
                    sampledEncodings: PlainTextEncoding.allCases.map(\.rawValue)
                )
            }
            try sink(text)
            return
        }

        // 探测前缀：detector 需要 BOM + 严格 UTF-8 判定样本。
        // 注意：64KiB 窗口可能恰好截在多字节序列中间——detector 对
        // 截断尾部一律 invalid。回退 ≤3 字节重试（UTF-8 序列最长 4
        // 字节），解码器仍吃完整 head（截断尾部会缓存到下一 chunk）。
        var chunk = try handle.read(upToCount: chunkSize) ?? Data()
        let encoding: ImportTextEncoding
        var bomBytes = 0
        var detectedViaBOM = false
        if let encodingOverride,
           let importEncoding = encodingOverride.importEncoding {
            encoding = importEncoding  // 手动指定：不再探测 BOM
        } else {
            var probe = chunk
            var detection = ImportEncodingDetector.detect(prefix: probe)
            var retries = 0
            while case .undetermined = detection,
                  retries < 3, !probe.isEmpty {
                probe = probe.dropLast()
                detection = ImportEncodingDetector.detect(prefix: probe)
                retries += 1
            }
            switch detection {
            case let .detected(found, bom, viaBOM):
                encoding = found
                bomBytes = bom
                detectedViaBOM = viaBOM
            case let .undetermined(candidates):
                throw ReaderParserError.undeterminedEncoding(
                    sampledEncodings: candidates.map(\.rawValue)
                )
            }
        }
        var decoder = IncrementalTextDecoder(
            encoding: encoding,
            bomBytes: bomBytes,
            maximumInputBytes: limits.maximumInputBytes
        )
        while !chunk.isEmpty {
            try Task.checkCancellation()
            let piece: String
            do {
                piece = try decoder.decode(chunk)
            } catch {
                throw mapDecodeError(
                    error,
                    detectedViaBOM: detectedViaBOM,
                    manualOverride: encodingOverride != nil
                )
            }
            try sink(piece)
            chunk = try handle.read(upToCount: chunkSize) ?? Data()
        }
        do {
            try sink(try decoder.finish())
        } catch {
            throw mapDecodeError(
                error,
                detectedViaBOM: detectedViaBOM,
                manualOverride: encodingOverride != nil
            )
        }
    }

    /// ImportParseError → ReaderParserError（契约错误域）。
    private static func mapDecodeError(
        _ error: Error,
        detectedViaBOM: Bool,
        manualOverride: Bool
    ) -> Error {
        guard let parseError = error as? ImportParseError else { return error }
        switch parseError {
        case let .limitExceeded(metric, limit):
            return ReaderParserError.limitExceeded(
                metric: metric,
                limit: Int64(limit),
                actual: Int64(limit) + 1
            )
        case .invalidEncoding:
            // BOM 锚定的编码中途损坏 = 文件损坏；其余情况（推断 UTF-8 /
            // 手动指定失败）→ 回到手动编码预览流程。
            if detectedViaBOM {
                return ReaderParserError.malformedContainer(
                    reason: "encoding declared by BOM is corrupt mid-stream"
                )
            }
            return ReaderParserError.undeterminedEncoding(
                sampledEncodings: PlainTextEncoding.allCases.map(\.rawValue)
            )
        case .undeterminedEncoding:
            return ReaderParserError.undeterminedEncoding(
                sampledEncodings: PlainTextEncoding.allCases.map(\.rawValue)
            )
        case .cancelled:
            return ReaderParserError.cancelled
        case .malformedRow:
            return ReaderParserError.malformedContainer(
                reason: "decoder invariant violation"
            )
        }
    }
}
