import Foundation
import OboeDomain

/// v0.7.0 S16：CSV/TSV 增量解析器（§10.1 冻结契约 `DelimitedTextParser` 的实现）。
///
/// 设计要点：
/// - 四态状态机 `fieldStart / unquoted / quoted / afterQuote`，逐 `Character`
///   处理。输入已是解码后的 `String`（编码层在 parser 上游，见
///   `IncrementalTextDecoder`），因此 feed 边界永远落在 grapheme cluster
///   边界上；多字节 UTF-8 序列的跨 chunk 拆分由上游 decoder 吸收。
/// - 即使调用方把同一 grapheme 的多个 Unicode scalar 拆到两次 feed
///   （如 "e" + U+0301），逐 Character 追加字段仍得到等价文本。
/// - 行结束符：`\n`、`\r\n`、孤立 `\r` 均算一条物理行结束。
///   `\r` 若在 chunk 末尾出现，用 `swallowLeadingLF` 在下一 chunk 开头吞掉
///   紧随的 `\n`，保证 CRLF 跨 chunk 时只计一行。
/// - `rawLineRange` 约定：1 起始的物理行号半开区间 `start..<end`，
///   `end` = 该逻辑记录占用的最后一行 + 1。被换行符终止的记录
///   `end == 终止符后的新行号`；EOF 无换行时 `end == 最后行号 + 1`。
/// - 取消：`feed`/`finish` 入口检查 `Task.isCancelled`（粒度 = 每次 feed，
///   与 §10.3 「取消检查发生在记录解析和批之间」一致，契约无需变更）。
/// - 严格引号语义（RFC 4180）：引号只允许出现在字段开头；unquoted
///   字段中出现 `"`、收尾引号后出现非分隔符/非换行字符，均为
///   `malformedRow`。若产品需要放宽为「字面引号」，只改两处分支。
///
/// 绝对不用 `split("\n")`。
public struct DelimitedTextParserImpl: DelimitedTextParser {

    // MARK: - 配置

    /// 解析预算（§10.1 建议值：100k 行 / 64KiB 单字段 / 1MiB 单记录）。
    /// 文件级 50MiB 由 `IncrementalTextDecoder` 在字节层执行。
    public struct Limits: Sendable, Equatable {
        public var maximumLogicalRows: Int
        public var maximumFieldUTF8Bytes: Int
        public var maximumRecordUTF8Bytes: Int

        public init(
            maximumLogicalRows: Int = 100_000,
            maximumFieldUTF8Bytes: Int = 64 * 1024,
            maximumRecordUTF8Bytes: Int = 1024 * 1024
        ) {
            self.maximumLogicalRows = maximumLogicalRows
            self.maximumFieldUTF8Bytes = maximumFieldUTF8Bytes
            self.maximumRecordUTF8Bytes = maximumRecordUTF8Bytes
        }
    }

    public static let candidateDelimiters: [Character] = [",", "\t", ";"]

    private let delimiter: Character
    private let limits: Limits

    /// - Parameter delimiter: 必须为单 grapheme；逗号/制表符/分号之外的分隔符
    ///   也允许，但多 scalar 的 Character 永远不会匹配（确定性退化）。
    public init(delimiter: Character, limits: Limits = Limits()) {
        self.delimiter = delimiter
        self.limits = limits
    }

    // MARK: - 状态机状态

    private enum State: Equatable {
        /// 字段开头：分隔符→空字段；引号→quoted；换行→结束记录；其余→unquoted。
        case fieldStart
        /// 无引号字段内部。
        case unquoted
        /// 引号字段内部（分隔符/换行均为字面量）。
        case quoted
        /// 收尾引号之后：`"`→转义回 quoted；分隔符/换行→结束；其余→错误。
        case afterQuote
    }

    private var state: State = .fieldStart

    /// 当前字段缓冲与其 UTF-8 字节数（64KiB 预算）。
    private var fieldBuffer = String()
    private var fieldUTF8Bytes = 0

    /// 当前记录已完成的字段。
    private var pendingFields: [String] = []
    /// 当前记录累计 UTF-8 字节（1MiB 预算）。
    private var recordUTF8Bytes = 0

    /// 当前记录是否有已消费输入（区分空文件与「一行空字段」）。
    private var recordActive = false
    /// 当前记录起始物理行号（1 起始）。
    private var recordStartLine = 1
    /// 当前物理行号（1 起始）；消费一条行结束符后 +1。
    private var lineNumber = 1

    /// 上一个被当作记录终止符消费的是 `\r`：吞掉紧随的 `\n`（CRLF 跨 chunk）。
    private var swallowLeadingLF = false

    /// quoted 字段内刚消费字面 `\r`：紧随的 `\n`（可能跨 chunk）是同一 CRLF，
    /// 追加到字段但不再计行。
    private var quotedCRPending = false

    /// 已产出的逻辑记录数。
    private var emittedRows = 0

    /// `finish()` 只允许调用一次后的幂等保护。
    private var finished = false

    // MARK: - DelimitedTextParser

    public mutating func feed(_ chunk: String) throws -> [ImportLogicalRow] {
        try throwIfCancelled()
        if finished {
            throw ImportParseError.malformedRow(
                logicalRow: emittedRows + 1,
                rawLines: recordStartLine..<(lineNumber + 1),
                reason: "feed() called after finish()"
            )
        }
        var rows: [ImportLogicalRow] = []
        for character in chunk {
            if swallowLeadingLF {
                swallowLeadingLF = false
                if character == "\n" {
                    continue // CRLF 的 LF 部分已被 \r 计入
                }
            }
            try process(character, into: &rows)
        }
        return rows
    }

    public mutating func finish() throws -> [ImportLogicalRow] {
        try throwIfCancelled()
        if finished { return [] }
        finished = true
        swallowLeadingLF = false

        switch state {
        case .fieldStart:
            guard recordActive || !pendingFields.isEmpty else { return [] }
            // 以分隔符结尾的尾行 → 尾部空字段（"a," EOF → ["a", ""]）。
            flushField()
            return [try emitRecord(atEOF: true)]
        case .unquoted:
            flushField()
            return [try emitRecord(atEOF: true)]
        case .afterQuote:
            flushField()
            return [try emitRecord(atEOF: true)]
        case .quoted:
            throw ImportParseError.malformedRow(
                logicalRow: emittedRows + 1,
                rawLines: recordStartLine..<(lineNumber + 1),
                reason: "unterminated quoted field at EOF"
            )
        }
    }

    // MARK: - 逐字符推进

    private mutating func process(
        _ character: Character,
        into rows: inout [ImportLogicalRow]
    ) throws {
        switch state {
        case .fieldStart:
            if character == "\"" {
                markRecordActive()
                state = .quoted
            } else if character == delimiter {
                markRecordActive()
                flushField() // 空字段
            } else if isTerminator(character) {
                markRecordActive()
                flushField() // 空行 → [""]；行尾分隔符 → 尾部空字段
                rows.append(try emitRecord(terminatedBy: character))
            } else {
                markRecordActive()
                state = .unquoted
                try appendToField(character)
            }

        case .unquoted:
            if character == delimiter {
                flushField()
                state = .fieldStart
            } else if isTerminator(character) {
                flushField()
                rows.append(try emitRecord(terminatedBy: character))
                state = .fieldStart
            } else if character == "\"" {
                throw malformed("unexpected quote inside unquoted field")
            } else {
                try appendToField(character)
            }

        case .quoted:
            if character == "\"" {
                quotedCRPending = false
                state = .afterQuote
            } else {
                // 分隔符与换行在引号内均为字面量；换行仍要计入
                // lineNumber 以维持 rawLineRange 准确。`\r` 先计入一行，
                // 紧随的 `\n`（含跨 chunk）不再重复计数——与外层 CRLF
                // 语义一致。
                try appendToField(character)
                if character == "\r\n" {
                    lineNumber += 1
                    quotedCRPending = false
                } else if character == "\r" {
                    lineNumber += 1
                    quotedCRPending = true
                } else if character == "\n" {
                    if !quotedCRPending { lineNumber += 1 }
                    quotedCRPending = false
                } else {
                    quotedCRPending = false
                }
            }

        case .afterQuote:
            if character == "\"" {
                state = .quoted
                try appendToField("\"")
            } else if character == delimiter {
                flushField()
                state = .fieldStart
            } else if isTerminator(character) {
                flushField()
                rows.append(try emitRecord(terminatedBy: character))
                state = .fieldStart
            } else {
                throw malformed("unexpected character after closing quote")
            }
        }
    }

    // MARK: - 辅助

    private func isTerminator(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }

    private mutating func markRecordActive() {
        if !recordActive {
            recordActive = true
            recordStartLine = lineNumber
        }
    }

    private mutating func appendToField(_ character: Character) throws {
        let byteCount = String(character).utf8.count
        if fieldUTF8Bytes + byteCount > limits.maximumFieldUTF8Bytes {
            throw ImportParseError.limitExceeded(
                metric: "fieldUTF8Bytes",
                limit: limits.maximumFieldUTF8Bytes
            )
        }
        if recordUTF8Bytes + byteCount > limits.maximumRecordUTF8Bytes {
            throw ImportParseError.limitExceeded(
                metric: "recordUTF8Bytes",
                limit: limits.maximumRecordUTF8Bytes
            )
        }
        fieldBuffer.append(character)
        fieldUTF8Bytes += byteCount
        recordUTF8Bytes += byteCount
    }

    private mutating func flushField() {
        pendingFields.append(fieldBuffer)
        fieldBuffer.removeAll(keepingCapacity: true)
        fieldUTF8Bytes = 0
    }

    /// `terminatedBy`：消费记录终止换行符的版本；`\r` 时挂起 LF 吞并。
    private mutating func emitRecord(
        terminatedBy terminator: Character
    ) throws -> ImportLogicalRow {
        if terminator == "\r" {
            swallowLeadingLF = true
        }
        lineNumber += 1
        return try emitRecord(atEOF: false)
    }

    private mutating func emitRecord(atEOF: Bool) throws -> ImportLogicalRow {
        let next = emittedRows + 1
        if next > limits.maximumLogicalRows {
            throw ImportParseError.limitExceeded(
                metric: "logicalRows",
                limit: limits.maximumLogicalRows
            )
        }
        // atEOF：记录占满当前行 → end = lineNumber + 1。
        // 否则 lineNumber 已指向下一行 → end = lineNumber。
        let endLine = atEOF ? lineNumber + 1 : lineNumber
        let row = ImportLogicalRow(
            logicalRowNumber: next,
            rawLineRange: recordStartLine..<endLine,
            fields: pendingFields
        )
        emittedRows = next
        pendingFields = []
        recordUTF8Bytes = 0
        recordActive = false
        recordStartLine = lineNumber
        return row
    }

    private func malformed(_ reason: String) -> ImportParseError {
        ImportParseError.malformedRow(
            logicalRow: emittedRows + 1,
            rawLines: recordStartLine..<(lineNumber + 1),
            reason: reason
        )
    }

    private func throwIfCancelled() throws {
        if Task.isCancelled {
            throw ImportParseError.cancelled
        }
    }
}
