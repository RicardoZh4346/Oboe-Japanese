import CryptoKit
import Foundation
import OboeDomain

/// SRT/VTT `ReaderParser`（§5）：编码检测复用 TXT 管线
/// （`PlainTextDecodePump` + `PlainTextEncoding` 手动覆盖），
/// canonical 规范化后按 cue 切 block——**一 cue 一块**
/// （字幕 cue 定位语义必须保真），超长 cue 在 grapheme 边界
/// 二次切分共享 cue locator。
///
/// - SRT：可选序号行 + `HH:MM:SS,mmm --> HH:MM:SS,mmm` 时间轴
///   （逗号/点号毫秒分隔都收）；cue 内多行合并为 `\n` 拼接；
///   空 cue 跳过；时间轴缺失 → `malformedCue(line:)`。
/// - VTT：首行 `WEBVTT` 签名（否则 `notRecognized`）；`NOTE`/
///   `STYLE`/`REGION` 块跳过；cue 可选 identifier 行；
///   时间戳 `HH:MM:SS.mmm`/`MM:SS.mmm`；`<v>`/`<c>`/`<b>` 等
///   标签剥离 + `&amp;`/`&lt;`/`&gt;`/`&nbsp;`/数值实体解码。
/// - canonical 文本 = cue 正文按 `\n\n` 级联（时间轴/序号不进
///   canonical，经 locatorJSON 保留：`{"v":1,"cue":N,"ident":"…",
///   "start_ms":…,"end_ms":…,"utf16_start":…}`）。
/// - 章节恒单章（ordinal 0）；`open` 阶段完成解码+cue 解析
///   （字幕体量受 `maximumInputBytes` 约束，无 EPUB 式大文件
///   需求），blocks() 直接重放已解析 cue。
public struct SubtitleParser: ReaderParser, Sendable {
    public let format: ReaderDocumentFormat
    public let parserVersion = "subtitle-1.0"
    private let encodingOverride: PlainTextEncoding?

    public init(
        format: ReaderDocumentFormat = .srt,
        encodingOverride: PlainTextEncoding? = nil
    ) {
        precondition(
            format == .srt || format == .vtt,
            "SubtitleParser 仅支持 srt/vtt"
        )
        self.format = format
        self.encodingOverride = encodingOverride
    }

    public func open(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) async throws -> ReaderParseSession {
        let parser = self
        let task = Task.detached(priority: .userInitiated) {
            try parser.scan(
                fileURL: fileURL, sourceSHA256: sourceSHA256, limits: limits)
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

    // MARK: - 扫描

    private func scan(
        fileURL: URL,
        sourceSHA256: String,
        limits: ReaderParserLimits
    ) throws -> SubtitleParseSession {
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
        var normalizer = CanonicalTextNormalizer()
        var canonical = ""
        try PlainTextDecodePump.run(
            fileURL: fileURL,
            encodingOverride: encodingOverride,
            limits: limits
        ) { piece in
            for cluster in normalizer.feed(piece) {
                canonical.append(cluster)
            }
        }
        for cluster in normalizer.finish() {
            canonical.append(cluster)
        }
        try Task.checkCancellation()

        let cues: [SubtitleCue] = format == .vtt
            ? try VTTCueSplitter.split(canonical)
            : try SRTCueSplitter.split(canonical)
        guard !cues.isEmpty else {
            // 一个 cue 都解析不出 = 输入不是该格式（§5 签名不符）。
            throw ReaderParserError.notRecognized
        }
        // canonical 文本 = cue 正文 \n\n 级联（时间轴/序号不进）。
        var canonicalHasher = SHA256()
        var totalUTF16 = 0
        for (index, cue) in cues.enumerated() {
            if index > 0 {
                canonicalHasher.update(data: Data("\n\n".utf8))
                totalUTF16 += 2
            }
            canonicalHasher.update(data: Data(cue.text.utf8))
            totalUTF16 += cue.text.utf16.count
        }
        guard totalUTF16 > 0,
              !cues.allSatisfy({ $0.text.utf16.isEmpty }) else {
            throw ReaderParserError.emptyContent
        }
        let title = fileURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SubtitleParseSession(
            format: format,
            sourceSHA256: sourceSHA256,
            canonicalTextHash: ReaderHashing.hex(
                canonicalHasher.finalize()
            ),
            parserVersion: parserVersion,
            suggestedTitle: title.isEmpty ? "Untitled" : title,
            cues: cues,
            totalUTF16Length: totalUTF16
        )
    }
}

/// 解析后的字幕 cue。
struct SubtitleCue: Equatable, Sendable {
    /// cue 顺序号（ordinal 序）。
    let ordinal: Int
    /// SRT 的序号行 / VTT 的 identifier（可空）。
    let identifier: String?
    let startMilliseconds: Int
    let endMilliseconds: Int
    /// cue 正文（多行已合并、标签已剥离）。
    let text: String
    /// VTT cue settings / SRT 位置参数（时间轴行尾随内容）。
    let settings: String?
    /// 源文件行号（canonical 文本 1 基）——错误定位用。
    let sourceLine: Int
}

/// SRT/VTT session：cue 在 open 期已解析，blocks() 重放切块。
struct SubtitleParseSession: ReaderParseSession {
    let format: ReaderDocumentFormat
    let sourceSHA256: String
    let canonicalTextHash: String
    let parserVersion: String
    let suggestedTitle: String
    let cues: [SubtitleCue]
    let totalUTF16Length: Int

    var chapters: [ReaderChapterDraft] {
        [ReaderChapterDraft(
            ordinal: 0,
            title: nil,
            sourceLocator: format == .vtt ? "vtt" : "srt",
            canonicalHash: canonicalTextHash,
            textUTF16Length: totalUTF16Length
        )]
    }
    var assets: [ReaderAssetPlan] { [] }

    func blocks(forChapter ordinal: Int) throws -> ReaderBlockStream {
        guard ordinal == 0 else {
            throw ReaderParserError.malformedContainer(
                reason: "subtitle 仅一章 (ordinal 0)，收到 \(ordinal)"
            )
        }
        let cues = self.cues
        return ReaderBlockStream { continuation in
            let task = Task.detached {
                var utf16Offset = 0
                var blockOrdinal = 0
                func emit(_ text: String, cue: SubtitleCue) {
                    let locator = SubtitleCueLocator(
                        cueOrdinal: cue.ordinal,
                        identifier: cue.identifier,
                        startMilliseconds: cue.startMilliseconds,
                        endMilliseconds: cue.endMilliseconds,
                        settings: cue.settings,
                        utf16Start: utf16Offset
                    )
                    continuation.yield(ReaderBlockDraft(
                        ordinal: blockOrdinal,
                        text: text,
                        textHash: ReaderHashing.sha256Hex(
                            Data(text.utf8)
                        ),
                        locatorJSON: locator.jsonString
                    ))
                    blockOrdinal += 1
                    utf16Offset += text.utf16.count
                }
                for cue in cues {
                    if Task.isCancelled {
                        continuation.finish(
                            throwing: ReaderParserError.cancelled
                        )
                        return
                    }
                    // 一 cue 一块；超长 cue 在 grapheme 边界二次切
                    // （共享 cue locator，utf16_start 顺延）。
                    for part in cue.text.utf16BoundChunks(
                        maximumUTF16: ReaderBlock.maximumUTF16Length
                    ) {
                        emit(part, cue: cue)
                    }
                    // canonical 间隔：非末 cue 后有两个 \n。
                    if cue.ordinal < cues.count - 1 {
                        utf16Offset += 2
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// block locatorJSON 内容（cue 定位保真）。
private struct SubtitleCueLocator {
    let cueOrdinal: Int
    let identifier: String?
    let startMilliseconds: Int
    let endMilliseconds: Int
    let settings: String?
    let utf16Start: Int

    var jsonString: String {
        var parts = [
            "\"v\":1",
            "\"cue\":\(cueOrdinal)",
            "\"start_ms\":\(startMilliseconds)",
            "\"end_ms\":\(endMilliseconds)",
            "\"utf16_start\":\(utf16Start)",
        ]
        if let identifier {
            parts.append(
                "\"ident\":\"\(Self.escape(identifier))\""
            )
        }
        if let settings {
            parts.append(
                "\"settings\":\"\(Self.escape(settings))\""
            )
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

private extension String {
    /// 按 grapheme cluster 切 ≤maximumUTF16 的串（超长 cue 兜底）。
    func utf16BoundChunks(maximumUTF16: Int) -> [String] {
        guard utf16.count > maximumUTF16 else { return [self] }
        var result: [String] = []
        var current = ""
        var currentLength = 0
        for cluster in self {  // Character 迭代 = grapheme cluster
            let length = String(cluster).utf16.count
            if currentLength + length > maximumUTF16, !current.isEmpty {
                result.append(current)
                current = String(cluster)
                currentLength = length
            } else {
                current.append(cluster)
                currentLength += length
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
