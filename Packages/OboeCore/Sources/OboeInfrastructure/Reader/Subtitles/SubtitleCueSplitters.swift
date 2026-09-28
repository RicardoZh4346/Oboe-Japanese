import Foundation
import OboeDomain

/// SRT cue 切分：canonical 文本按空行分组；
/// 组内 `序号行? → 时间轴行 → 正文行…`。
enum SRTCueSplitter {
    /// `HH:MM:SS,mmm`（逗号/点号毫秒）+ `-->` + 同格式结束。
    /// 行尾允许位置参数（部分工具输出 `X1:… X2:…`）。
    private static let timingPattern = try! NSRegularExpression(
        pattern: """
            ^(\\d{2,}):(\\d{2}):(\\d{2})[,.](\\d{3})\
            \\s*-->\\s*\
            (\\d{2,}):(\\d{2}):(\\d{2})[,.](\\d{3})(\\s.*)?$
            """
    )
    /// 纯数字行（SRT 序号）。
    private static let indexPattern = try! NSRegularExpression(
        pattern: "^\\d+$"
    )

    static func split(_ text: String) throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var group: [(line: String, number: Int)] = []
        var firstGroup = true
        for (index, raw) in text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmed.isEmpty {
                if !group.isEmpty {
                    try flush(&group, into: &cues,
                              isFirst: firstGroup)
                    firstGroup = false
                }
                continue
            }
            group.append((line, index + 1))
        }
        if !group.isEmpty {
            try flush(&group, into: &cues, isFirst: firstGroup)
        }
        return cues
    }

    private static func flush(
        _ group: inout [(line: String, number: Int)],
        into cues: inout [SubtitleCue],
        isFirst: Bool
    ) throws {
        defer { group.removeAll(keepingCapacity: false) }
        var lines = group
        // 可选序号行。
        var identifier: String?
        if let first = lines.first,
           match(first.line, indexPattern) != nil {
            identifier = first.line.trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        guard let timingLine = lines.first else {
            if isFirst {
                throw ReaderParserError.notRecognized
            }
            throw ReaderParserError.malformedCue(
                line: group.first?.number ?? 0,
                reason: "cue 缺少时间轴行"
            )
        }
        guard let range = match(timingLine.line, timingPattern),
              let times = parseTiming(range, in: timingLine.line) else {
            if isFirst, cues.isEmpty {
                // 首个非空块就不是 cue → 输入不是 SRT。
                throw ReaderParserError.notRecognized
            }
            throw ReaderParserError.malformedCue(
                line: timingLine.number,
                reason: "时间轴行格式不符 HH:MM:SS,mmm --> HH:MM:SS,mmm"
            )
        }
        lines.removeFirst()
        // 时间轴行尾随参数（SRT 扩展如 `X1:… X2:…`）。
        let settings = Self.group(9, of: range, in: timingLine.line)
        let text = lines.map {
            $0.line.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            return  // 空 cue 跳过（§6 正常样例）
        }
        cues.append(SubtitleCue(
            ordinal: cues.count,
            identifier: identifier,
            startMilliseconds: times.0,
            endMilliseconds: times.1,
            text: text,
            settings: settings,
            sourceLine: timingLine.number
        ))
    }

    private static func match(
        _ line: String, _ pattern: NSRegularExpression
    ) -> NSTextCheckingResult? {
        pattern.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        )
    }

    /// capture group → 已 trim 的字符串（未命中/空 → nil）。
    static func group(
        _ index: Int,
        of match: NSTextCheckingResult,
        in line: String
    ) -> String? {
        guard match.numberOfRanges > index else { return nil }
        let r = match.range(at: index)
        guard r.location != NSNotFound,
              let sr = Range(r, in: line) else { return nil }
        let value = line[sr].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func parseTiming(
        _ match: NSTextCheckingResult, in line: String
    ) -> (Int, Int)? {
        func value(_ i: Int) -> Int? {
            let r = match.range(at: i)
            guard r.location != NSNotFound,
                  let swiftRange = Range(r, in: line) else { return nil }
            return Int(line[swiftRange])
        }
        guard let h1 = value(1), let m1 = value(2), let s1 = value(3),
              let ms1 = value(4),
              let h2 = value(5), let m2 = value(6), let s2 = value(7),
              let ms2 = value(8) else { return nil }
        return (
            ((h1 * 60 + m1) * 60 + s1) * 1000 + ms1,
            ((h2 * 60 + m2) * 60 + s2) * 1000 + ms2
        )
    }
}

/// VTT cue 切分：`WEBVTT` 签名 + 块分组；`NOTE`/`STYLE`/`REGION`
/// 跳过；cue = `identifier? → 时间轴 → 正文`；标签剥离 + 实体解码。
enum VTTCueSplitter {
    /// `MM:SS.mmm` 或 `HH:MM:SS.mmm`（小时可多位）。
    private static let timingPattern = try! NSRegularExpression(
        pattern: """
            ^(?:(\\d{2,}):)?(\\d{2}):(\\d{2})\\.(\\d{3})\
            \\s+-->\\s+\
            (?:(\\d{2,}):)?(\\d{2}):(\\d{2})\\.(\\d{3})(\\s.*)?$
            """
    )
    /// 行内是否含时间轴（区分 identifier 行）。
    private static let arrowPattern = try! NSRegularExpression(
        pattern: "-->"
    )

    static func split(_ text: String) throws -> [SubtitleCue] {
        var lines = text.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated().map { (String($0.element), $0.offset + 1) }
        guard let first = lines.first else {
            throw ReaderParserError.notRecognized
        }
        // `WEBVTT` 签名：首行必须 `WEBVTT`（可跟空格+注释）。
        guard first.0 == "WEBVTT"
                || first.0.hasPrefix("WEBVTT ")
                || first.0.hasPrefix("WEBVTT\t") else {
            throw ReaderParserError.notRecognized
        }
        lines.removeFirst()
        var cues: [SubtitleCue] = []
        var group: [(String, Int)] = []
        for entry in lines {
            let trimmed = entry.0.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmed.isEmpty {
                try flush(&group, into: &cues)
                continue
            }
            group.append(entry)
        }
        try flush(&group, into: &cues)
        return cues
    }

    private static func flush(
        _ group: inout [(String, Int)],
        into cues: inout [SubtitleCue]
    ) throws {
        defer { group.removeAll(keepingCapacity: false) }
        guard let head = group.first else { return }
        let headTrimmed = head.0.trimmingCharacters(in: .whitespaces)
        // NOTE/STYLE/REGION 块整体跳过（STYLE 块内容样式定义
        // 不进正文；头部 "WEBVTT" 后空行已分组完毕）。
        if headTrimmed == "NOTE" || headTrimmed.hasPrefix("NOTE ")
            || headTrimmed == "STYLE" || headTrimmed.hasPrefix("STYLE ")
            || headTrimmed == "REGION" || headTrimmed.hasPrefix("REGION ") {
            return
        }
        var lines = group
        var identifier: String?
        var timingEntry = lines.first!
        if !timingEntry.0.contains("-->") {
            // identifier 行：第二行必须是时间轴。
            identifier = headTrimmed
            lines.removeFirst()
            guard let next = lines.first else {
                throw ReaderParserError.malformedCue(
                    line: head.1,
                    reason: "identifier 后缺时间轴行"
                )
            }
            timingEntry = next
        }
        guard let range = timingPattern.firstMatch(
            in: timingEntry.0,
            range: NSRange(timingEntry.0.startIndex..., in: timingEntry.0)
        ), let times = parseTiming(range, in: timingEntry.0) else {
            throw ReaderParserError.malformedCue(
                line: timingEntry.1,
                reason: "时间轴行格式不符 [HH:]MM:SS.mmm --> …"
            )
        }
        lines.removeFirst()
        let settings = SRTCueSplitter.group(
            9, of: range, in: timingEntry.0
        )
        let text = lines.map {
            stripTags($0.0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            return  // 空 cue 跳过
        }
        cues.append(SubtitleCue(
            ordinal: cues.count,
            identifier: identifier,
            startMilliseconds: times.0,
            endMilliseconds: times.1,
            text: text,
            settings: settings,
            sourceLine: timingEntry.1
        ))
    }

    /// 时间轴 → (start_ms, end_ms)。capture groups 可选小时位。
    private static func parseTiming(
        _ match: NSTextCheckingResult, in line: String
    ) -> (Int, Int)? {
        func value(_ i: Int) -> Int? {
            let r = match.range(at: i)
            guard r.location != NSNotFound,
                  let sr = Range(r, in: line) else { return nil }
            return Int(line[sr])
        }
        guard let m1 = value(2), let s1 = value(3), let ms1 = value(4),
              let m2 = value(6), let s2 = value(7), let ms2 = value(8)
        else { return nil }
        let h1 = value(1) ?? 0
        let h2 = value(5) ?? 0
        return (
            ((h1 * 60 + m1) * 60 + s1) * 1000 + ms1,
            ((h2 * 60 + m2) * 60 + s2) * 1000 + ms2
        )
    }

    /// `<v name>`/`<c.klass>`/`</v>` 等标签剥离 + 实体解码。
    static func stripTags(_ line: String) -> String {
        var out = ""
        out.reserveCapacity(line.count)
        var cursor = line.startIndex
        while cursor < line.endIndex {
            if line[cursor] == "<",
               let close = line[cursor...].firstIndex(of: ">") {
                cursor = line.index(after: close)
                continue
            }
            out.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        return decodeEntities(out)
    }

    /// VTT 允许实体：`&amp;`/`&lt;`/`&gt;`/`&lrm;`/`&rlm;`/`&nbsp;`
    /// + `&#N;`/`&#xH;` 数值实体。
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let known: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">",
            "lrm": "\u{200E}", "rlm": "\u{200F}", "nbsp": "\u{A0}",
        ]
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&" else {
                out.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            let nameStart = text.index(after: cursor)
            guard let semi = text[nameStart...].firstIndex(of: ";"),
                  text.distance(from: nameStart, to: semi) <= 10
            else {
                out.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            let name = String(text[nameStart..<semi])
            if name.hasPrefix("#x") || name.hasPrefix("#X"),
               let code = UInt32(name.dropFirst(2), radix: 16),
               let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else if name.hasPrefix("#"),
                      let code = UInt32(name.dropFirst()),
                      let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else if let decoded = known[name] {
                out.append(decoded)
            } else {
                // 未知实体原样保留（宽松策略，不让一条坏实体毁掉整书）。
                out.append(contentsOf: text[cursor...semi])
            }
            cursor = text.index(after: semi)
        }
        return out
    }
}
