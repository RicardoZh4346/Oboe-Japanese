import Foundation
import OboeDomain

/// v0.7.0 S16：导入编码检测 + 严格增量解码（§10.1）。
///
/// 检测顺序（BOM 优先）：
/// 1. `EF BB BF` → UTF-8（BOM 剥离）；
///    `FF FE` → UTF-16LE；`FE FF` → UTF-16BE。
/// 2. 无 BOM：采样做严格 UTF-8 校验，通过 → `utf8`（`viaBOM=false`）。
/// 3. 校验失败 → `undetermined`，列出候选编码供用户手动选择；
///    由调用方映射为契约错误 `ImportParseError.undeterminedEncoding`
///    或在 UI 层让用户指定后构造 `IncrementalTextDecoder`（手动 override 钩子）。
///
/// 说明：v0.7.0 的 S05（TXT 增量解码层）与本模块并行开发；当前仓库中没有可
/// 复用的 TXT decoder，故此处实现了自包含的严格增量解码器。若 S05 落地后
/// 暴露公共 API，可用其替换 `IncrementalTextDecoder` 的内部实现——本文件
/// 的公开面（检测 + 逐 chunk `decode`/`finish`）已按可替换设计。
public enum ImportTextEncoding: String, Sendable, CaseIterable {
    case utf8
    case utf16LE
    case utf16BE
}

/// 检测结果。
public enum ImportEncodingDetection: Equatable, Sendable {
    /// 确定编码。`bomBytes` = 需要跳过的 BOM 字节数（无 BOM 为 0）。
    case detected(encoding: ImportTextEncoding, bomBytes: Int, viaBOM: Bool)
    /// 低置信：采样候选，调用方应让用户选择（§10.1「手动指定其他编码」）。
    case undetermined(sampledCandidates: [ImportTextEncoding])
}

public enum ImportEncodingDetector {

    /// 对输入前缀（建议 ≥ 4 字节，通常直接给整文件头几个 KiB）做检测。
    public static func detect(prefix: some Sequence<UInt8>) -> ImportEncodingDetection {
        let bytes = Array(prefix)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .detected(encoding: .utf8, bomBytes: 3, viaBOM: true)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return .detected(encoding: .utf16LE, bomBytes: 2, viaBOM: true)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return .detected(encoding: .utf16BE, bomBytes: 2, viaBOM: true)
        }
        if IncrementalTextDecoder.isValidUTF8(bytes) {
            return .detected(encoding: .utf8, bomBytes: 0, viaBOM: false)
        }
        // 启发排序：奇/偶位 NUL 分布提示 UTF-16。
        var candidates = ImportTextEncoding.allCases
        let evenNULs = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        let oddNULs = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
        if oddNULs > evenNULs {
            candidates = [.utf16BE, .utf16LE, .utf8]
        } else if evenNULs > oddNULs {
            candidates = [.utf16LE, .utf16BE, .utf8]
        }
        return .undetermined(sampledCandidates: candidates)
    }
}

/// 严格增量文本解码器：把任意切分的字节流解码为可安全喂给
/// `DelimitedTextParser.feed` 的 `String` chunk。
///
/// - UTF-8：严格校验（拒绝 overlong、代理区、越界码点、截断序列）。
///   每个 chunk 末尾的不完整前缀缓存进 `pending` 等待下一 chunk。
/// - UTF-16LE/BE：缓存奇数尾字节与未配对高代理；孤立代理/截断 → 错误。
/// - 字节预算：默认 50MiB（§10.1 文件级上限），超限抛
///   `ImportParseError.limitExceeded(metric: "fileBytes")`。
/// - 解码错误抛 `ImportParseError.invalidEncoding(offset:reason:)`：
///   编码已确定（检测或手动指定）后流中途失败，与检测期的
///   `undeterminedEncoding` 区分。
public struct IncrementalTextDecoder: Sendable {

    public static let defaultMaximumInputBytes = 50 * 1024 * 1024

    private let encoding: ImportTextEncoding
    private var bomBytesToSkip: Int
    private let maximumInputBytes: Int

    private var fedBytes = 0
    /// UTF-8 未完结前缀 / UTF-16 奇数尾字节。
    private var pendingBytes: [UInt8] = []
    /// UTF-16 未配对高代理（0xD800–0xDBFF）。
    private var pendingHighSurrogate: UInt16?

    /// - Parameters:
    ///   - encoding: 目标编码（手动 override 直接传值即可）。
    ///   - bomBytes: 流开头要跳过的 BOM 字节数（来自 `detect` 结果）。
    ///   - maximumInputBytes: 文件字节预算（§10.1 50MiB）。
    public init(
        encoding: ImportTextEncoding,
        bomBytes: Int = 0,
        maximumInputBytes: Int = IncrementalTextDecoder.defaultMaximumInputBytes
    ) {
        self.encoding = encoding
        self.bomBytesToSkip = bomBytes
        self.maximumInputBytes = maximumInputBytes
    }

    /// 便捷构造：直接吃 `detect` 的确定结果。
    public init?(detection: ImportEncodingDetection, maximumInputBytes: Int = IncrementalTextDecoder.defaultMaximumInputBytes) {
        guard case let .detected(encoding, bomBytes, _) = detection else { return nil }
        self.init(encoding: encoding, bomBytes: bomBytes, maximumInputBytes: maximumInputBytes)
    }

    /// 推进一个字节 chunk。返回本 chunk 解码出的完整文本（可能为空——
    /// 尾部不完整的字节会缓存到下次 decode / finish）。
    public mutating func decode(_ bytes: some Sequence<UInt8>) throws -> String {
        var chunk = Array(bytes)
        fedBytes += chunk.count
        if fedBytes > maximumInputBytes {
            throw ImportParseError.limitExceeded(
                metric: "fileBytes",
                limit: maximumInputBytes
            )
        }
        if bomBytesToSkip > 0 {
            let skip = Swift.min(bomBytesToSkip, chunk.count)
            chunk.removeFirst(skip)
            bomBytesToSkip -= skip
            if chunk.isEmpty { return "" }
        }
        guard !chunk.isEmpty else { return "" }
        switch encoding {
        case .utf8: return try decodeUTF8(chunk)
        case .utf16LE: return try decodeUTF16(chunk, littleEndian: true)
        case .utf16BE: return try decodeUTF16(chunk, littleEndian: false)
        }
    }

    /// EOF 冲刷：仍有未完结字节/代理 → 编码判定不成立。
    public mutating func finish() throws -> String {
        if bomBytesToSkip > 0 || !pendingBytes.isEmpty || pendingHighSurrogate != nil {
            throw ImportParseError.invalidEncoding(
                offset: fedBytes,
                reason: "input ends with an incomplete sequence"
            )
        }
        return ""
    }

    // MARK: - UTF-8

    /// 严格校验整段字节是否为合法 UTF-8（含截断判定）。
    static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            guard let length = utf8SequenceLength(at: i, in: bytes) else { return false }
            i += length
        }
        return true
    }

    /// 返回从 `bytes[i]` 开始的 UTF-8 序列长度；非法返回 nil，
    /// 截断（到末尾仍不完整但前缀合法）返回 nil 但 `isTruncated` 语义由
    /// 调用处区分——这里把截断也视为 invalid。
    private static func utf8SequenceLength(at i: Int, in bytes: [UInt8]) -> Int? {
        let b0 = bytes[i]
        switch b0 {
        case 0x00...0x7F:
            return 1
        case 0xC2...0xDF:
            guard i + 1 < bytes.count, isContinuation(bytes[i + 1]) else { return nil }
            return 2
        case 0xE0...0xEF:
            guard i + 2 < bytes.count else { return nil }
            let b1 = bytes[i + 1]
            // E0: 第二字节须 A0–BF（禁 overlong）；ED: 80–9F（禁代理区）。
            if b0 == 0xE0 && !(0xA0...0xBF).contains(b1) { return nil }
            if b0 == 0xED && !(0x80...0x9F).contains(b1) { return nil }
            guard isContinuation(b1), isContinuation(bytes[i + 2]) else { return nil }
            return 3
        case 0xF0...0xF4:
            guard i + 3 < bytes.count else { return nil }
            let b1 = bytes[i + 1]
            // F0: 90–BF（禁 overlong）；F4: 80–8F（禁 >U+10FFFF）。
            if b0 == 0xF0 && !(0x90...0xBF).contains(b1) { return nil }
            if b0 == 0xF4 && !(0x80...0x8F).contains(b1) { return nil }
            guard isContinuation(b1),
                  isContinuation(bytes[i + 2]),
                  isContinuation(bytes[i + 3]) else { return nil }
            return 4
        default:
            return nil // 0x80–0xBF 裸续字节 / 0xC0/0xC1 overlong / 0xF5+
        }
    }

    /// 判定 `bytes[i...]` 是否可能是合法序列的未完结前缀（供 pending 缓存）。
    private static func utf8IncompletePrefixLength(at i: Int, in bytes: [UInt8]) -> Int? {
        let remaining = bytes.count - i
        let b0 = bytes[i]
        let expected: Int
        switch b0 {
        case 0x00...0x7F: return nil
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: return nil
        }
        guard remaining < expected else { return nil } // 足够长但非法 → 真错误
        // 校验已有的续字节与边界约束；全部合法则是未完结前缀。
        if remaining >= 2 {
            let b1 = bytes[i + 1]
            if b0 == 0xE0 && !(0xA0...0xBF).contains(b1) { return nil }
            if b0 == 0xED && !(0x80...0x9F).contains(b1) { return nil }
            if b0 == 0xF0 && !(0x90...0xBF).contains(b1) { return nil }
            if b0 == 0xF4 && !(0x80...0x8F).contains(b1) { return nil }
            if !isContinuation(b1) { return nil }
        }
        if remaining >= 3 && !isContinuation(bytes[i + 2]) { return nil }
        return remaining
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        (0x80...0xBF).contains(byte)
    }

    private mutating func decodeUTF8(_ chunk: [UInt8]) throws -> String {
        let bytes = pendingBytes + chunk
        pendingBytes = []
        var validEnd = 0
        var i = 0
        while i < bytes.count {
            if let length = IncrementalTextDecoder.utf8SequenceLength(at: i, in: bytes) {
                i += length
                validEnd = i
            } else if let prefix = IncrementalTextDecoder.utf8IncompletePrefixLength(at: i, in: bytes) {
                // 合法但未完结的尾前缀：缓存等待下一 chunk。
                pendingBytes = Array(bytes[i..<(i + prefix)])
                i += prefix
            } else {
                throw ImportParseError.invalidEncoding(
                    offset: fedBytes - bytes.count + i,
                    reason: "invalid UTF-8 sequence"
                )
            }
        }
        guard validEnd > 0 else { return "" }
        return String(decoding: bytes[0..<validEnd], as: UTF8.self)
    }

    // MARK: - UTF-16

    private mutating func decodeUTF16(_ chunk: [UInt8], littleEndian: Bool) throws -> String {
        let bytes = pendingBytes + chunk
        pendingBytes = []
        var output = String()
        output.reserveCapacity(bytes.count / 2)

        var i = 0
        while i + 1 < bytes.count {
            let unit: UInt16 = littleEndian
                ? UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
                : (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
            i += 2
            if let high = pendingHighSurrogate {
                pendingHighSurrogate = nil
                guard (0xDC00...0xDFFF).contains(unit), let scalar = Unicode.Scalar(
                    0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
                ) else {
                    throw ImportParseError.invalidEncoding(
                        offset: fedBytes - bytes.count + i - 2,
                        reason: "high surrogate not followed by low surrogate"
                    )
                }
                output.unicodeScalars.append(scalar)
            } else if (0xD800...0xDBFF).contains(unit) {
                pendingHighSurrogate = unit
            } else if (0xDC00...0xDFFF).contains(unit) {
                throw ImportParseError.invalidEncoding(
                    offset: fedBytes - bytes.count + i - 2,
                    reason: "lone low surrogate"
                )
            } else if let scalar = Unicode.Scalar(unit) {
                output.unicodeScalars.append(scalar)
            } else {
                throw ImportParseError.invalidEncoding(
                    offset: fedBytes - bytes.count + i - 2,
                    reason: "invalid UTF-16 code unit"
                )
            }
        }
        if i < bytes.count {
            pendingBytes = [bytes[i]] // 奇数尾字节
        }
        return output
    }
}
