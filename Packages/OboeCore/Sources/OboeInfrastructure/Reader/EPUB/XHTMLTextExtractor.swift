import Foundation
import OboeDomain

/// XHTML → canonical 文本事件流（EPUB 正文抽取，§5）。
///
/// `XMLParser` SAX（命名空间开、外部实体解析 never——外部 DTD
/// 不加载，避免 XXE 与网络访问）。事件直接驱动
/// `CanonicalTextNormalizer` → `PlainTextBlocker`：
///
/// - 块级元素（p/h1-6/li/blockquote/pre/dt/dd/figcaption/tr/div/
///   section/article 等）首尾置段落边界 → `\n\n` 换行序列；
/// - `<br>` → 单 `\n`；`<img>` 仅跳过（alt 不入正文）；
/// - `script/style/head/title/rt/rp/template` 内容整棵丢弃——
///   ruby 注音舍弃 rt/rp、保留 base（形态素要的是汉字本体，
///   取舍已记入报告）；
/// - 源文本空白按 HTML 语义折叠为单空格（markup 缩进/换行不产
///   生阅读换行），事件边界处去重；
/// - 未声明命名实体（`&nbsp;` 等）先经 `XHTMLEntityTable` 预展开
///   ——XMLParser 严格模式下未声明实体会让整章失败；
/// - 首个 h1–h6 文本成为章节建议标题（≤200 字符）。
///
/// 切块不变性：canonical 文本与块分割与事件粒度无关
/// （normalizer 扣押末簇、pending 合并再判界）。
final class XHTMLTextExtractor: NSObject, XMLParserDelegate {

    /// 事件消费者。`feed` 接收**未规范化**文本片段（段落分隔符由
    /// 提取器插入 `\n\n`，normalizer 下游完成 NFC/行尾折叠）。
    /// `onChapterTitle` 只在首个非空标题元素结束时触发一次。
    struct Sink {
        var feed: (String) -> Void
        var onChapterTitle: (String) -> Void
    }

    /// 入口：解析一章 XHTML，通过 sink 流出文本片段。
    /// `byteLimit` 截断由上游 `extractToData` 负责。
    func extract(data: Data, sink: Sink) throws {
        guard let text = Self.decodeToString(data) else {
            throw ReaderParserError.malformedContainer(
                reason: "XHTML 非 UTF-8/UTF-16"
            )
        }
        // 文本层预处理：① 剥 XML 声明（内容已解码，声明里的
        //   encoding 与重编码后的 utf8 字节不一致会误导解析器）；
        // ② 展开常见命名实体（严格解析器不加载外部 DTD）。
        let cleaned = Self.stripXMLDeclaration(
            Self.preExpandEntities(text)
        )
        self.sink = sink
        ignoreDepth = 0
        paragraphPending = false
        trailingSpacePending = false
        sawText = false
        headingDepth = 0
        headingText = ""
        headingEmitted = false

        let parser = XMLParser(data: Data(cleaned.utf8))
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        // SDK ≥26 将 case 名回退为 NSXMLParserResolveExternalEntitiesNever；
        // rawValue 0 == Never，跨 SDK 稳定。
        parser.externalEntityResolvingPolicy = XMLParser.ExternalEntityResolvingPolicy(rawValue: 0)! // NSXMLParserResolveExternalEntitiesNever
        if !parser.parse() {
            let line = parser.lineNumber
            throw ReaderParserError.malformedContainer(
                reason: "XHTML 第 \(line) 行: "
                    + (parser.parserError?.localizedDescription ?? "?")
            )
        }
    }

    // MARK: - 字节 → String（UTF-8/UTF-16 + BOM）

    private static func decodeToString(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(
                data: data.dropFirst(2), encoding: .utf16LittleEndian
            )
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(
                data: data.dropFirst(2), encoding: .utf16BigEndian
            )
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        return String(data: bytes, encoding: .utf8)
    }

    /// 剥掉 `<?xml ...?>` 声明——重编码后 encoding 属性是错的。
    private static func stripXMLDeclaration(_ text: String) -> String {
        guard text.hasPrefix("<?xml"),
              let close = text.range(of: "?>") else { return text }
        return String(text[close.upperBound...])
    }

    /// 常见 HTML 命名实体预展开（严格解析器不载外部 DTD）。
    /// 仅处理已知名字；`&amp;/&lt;/&gt;/&quot;/&apos;` 与数值实体
    /// 保留给 XMLParser；未知名字原样放行交由解析器报错。
    static func preExpandEntities(_ xml: String) -> String {
        guard xml.contains("&") else { return xml }
        var output = ""
        output.reserveCapacity(xml.count)
        var index = xml.startIndex
        while index < xml.endIndex {
            guard xml[index] == "&" else {
                output.append(xml[index])
                index = xml.index(after: index)
                continue
            }
            let nameStart = xml.index(after: index)
            var cursor = nameStart
            var name = ""
            while cursor < xml.endIndex {
                let c = xml[cursor]
                guard c.isLetter || c.isNumber else { break }
                name.append(c)
                cursor = xml.index(after: cursor)
            }
            if cursor < xml.endIndex, xml[cursor] == ";",
               !name.isEmpty, !name.hasPrefix("#"),
               let scalar = XHTMLEntityTable.lookup(name) {
                output.append(scalar)
                index = xml.index(after: cursor)
            } else {
                output.append(xml[index])
                index = xml.index(after: index)
            }
        }
        return output
    }

    // MARK: - 内部状态

    private var sink = Sink(feed: { _ in }, onChapterTitle: { _ in })
    /// suppress 元素子树深度（>0 时丢弃字符与边界）。
    private var ignoreDepth = 0
    /// 块边界待出：下次出文本前先吐 `\n\n`（相邻多块折叠为一组）。
    private var paragraphPending = false
    /// HTML 空白折叠：上一可见字符是空白 → 前导空白继续折叠。
    private var trailingSpacePending = false
    /// 是否已出过非空白文本——控制段落分隔/纯空白 run 的丢弃。
    private var sawText = false
    /// 首个 h1-h6 的文本捕获（headingDepth>0 时累计原始文本）。
    private var headingDepth = 0
    private var headingText = ""
    private var headingEmitted = false

    private static let blockElements: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "li", "ul", "ol", "blockquote", "pre",
        "dt", "dd", "figcaption", "tr",
        "div", "section", "article", "aside",
        "header", "footer", "main", "nav",
    ]
    private static let headingElements: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    private static let suppressingElements: Set<String> = [
        "script", "style", "head", "title",
        "rt", "rp", "template", "noscript",
    ]

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if ignoreDepth > 0 {
            ignoreDepth += 1
            return
        }
        if Self.suppressingElements.contains(elementName) {
            ignoreDepth = 1
            return
        }
        if Self.headingElements.contains(elementName) {
            paragraphPending = true
            if !headingEmitted {
                headingDepth += 1
                if headingDepth == 1 { headingText = "" }
            }
            return
        }
        if Self.blockElements.contains(elementName) {
            paragraphPending = true
            return
        }
        if elementName == "br", sawText {
            sink.feed("\n")
            trailingSpacePending = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard ignoreDepth == 0 else { return }
        if headingDepth > 0 { headingText += string }
        // HTML 空白折叠：任意空白串 → 单空格，边界处去重。
        var collapsed = ""
        collapsed.reserveCapacity(string.count)
        var lastWasSpace = trailingSpacePending
        for scalar in string.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace {
                    collapsed.append(" ")
                    lastWasSpace = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        trailingSpacePending = lastWasSpace
        guard !collapsed.isEmpty else { return }
        if paragraphPending {
            // 块边界处的前导空白是 markup 排版噪音，不进 canonical
            // （HTML 语义）；分隔符 `\n\n` 只在已有文本后出现。
            while collapsed.hasPrefix(" ") { collapsed.removeFirst() }
            guard !collapsed.isEmpty else { return }
            paragraphPending = false
            if sawText { sink.feed("\n\n") }
        }
        // 纯空白 run（折叠后恰一个空格）只在正文中段有意义：
        // 文档级前导空白与块边界空白一律丢弃。
        if collapsed == " ", !sawText { return }
        sink.feed(collapsed)
        if collapsed != " " { sawText = true }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if ignoreDepth > 0 {
            ignoreDepth -= 1
            return
        }
        if Self.headingElements.contains(elementName) {
            paragraphPending = true
            if headingDepth > 0 {
                headingDepth -= 1
                if headingDepth == 0, !headingEmitted {
                    headingEmitted = true
                    let trimmed = headingText
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        sink.onChapterTitle(
                            String(trimmed.prefix(200))
                        )
                    }
                }
            }
            return
        }
        if Self.blockElements.contains(elementName) {
            paragraphPending = true
        }
    }
}

/// 常见 HTML 命名实体表（外部 DTD 缺席时的本地替代）。
/// 覆盖 XHTML1 Latin-1 + 常用符号/标点；未知名字由 XMLParser
/// 报错为 malformedContainer。
enum XHTMLEntityTable {
    static func lookup(_ name: String) -> String? {
        table[name].map(String.init)
    }

    /// 标量值表（UInt32 → Character）。
    private static let table: [String: UInt32] = {
        var t: [String: UInt32] = [
            "nbsp": 0xA0, "iexcl": 0xA1, "cent": 0xA2, "pound": 0xA3,
            "curren": 0xA4, "yen": 0xA5, "brvbar": 0xA6, "sect": 0xA7,
            "uml": 0xA8, "copy": 0xA9, "ordf": 0xAA, "laquo": 0xAB,
            "not": 0xAC, "shy": 0xAD, "reg": 0xAE, "macr": 0xAF,
            "deg": 0xB0, "plusmn": 0xB1, "sup2": 0xB2, "sup3": 0xB3,
            "acute": 0xB4, "micro": 0xB5, "para": 0xB6, "middot": 0xB7,
            "cedil": 0xB8, "sup1": 0xB9, "ordm": 0xBA, "raquo": 0xBB,
            "frac14": 0xBC, "frac12": 0xBD, "frac34": 0xBE,
            "iquest": 0xBF, "times": 0xD7, "divide": 0xF7,
            "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018,
            "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C,
            "rdquo": 0x201D, "bdquo": 0x201E, "dagger": 0x2020,
            "Dagger": 0x2021, "permil": 0x2030, "lsaquo": 0x2039,
            "rsaquo": 0x203A, "euro": 0x20AC, "trade": 0x2122,
            "hellip": 0x2026, "bull": 0x2022, "prime": 0x2032,
            "Prime": 0x2033, "oline": 0x203E, "frasl": 0x2044,
            "weierp": 0x2118, "image": 0x2111, "real": 0x211C,
            "alefsym": 0x2135, "larr": 0x2190, "uarr": 0x2191,
            "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194,
            "crarr": 0x21B5, "forall": 0x2200, "part": 0x2202,
            "exist": 0x2203, "empty": 0x2205, "nabla": 0x2207,
            "isin": 0x2208, "notin": 0x2209, "ni": 0x220B,
            "prod": 0x220F, "sum": 0x2211, "minus": 0x2212,
            "lowast": 0x2217, "radic": 0x221A, "prop": 0x221D,
            "infin": 0x221E, "ang": 0x2220, "and": 0x2227,
            "or": 0x2228, "cap": 0x2229, "cup": 0x222A,
            "int": 0x222B, "there4": 0x2234, "sim": 0x223C,
            "cong": 0x2245, "asymp": 0x2248, "ne": 0x2260,
            "equiv": 0x2261, "le": 0x2264, "ge": 0x2265,
            "sub": 0x2282, "sup": 0x2283, "nsub": 0x2284,
            "sube": 0x2286, "supe": 0x2287, "oplus": 0x2295,
            "otimes": 0x2297, "perp": 0x22A5, "sdot": 0x22C5,
            "lceil": 0x2308, "rceil": 0x2309, "lfloor": 0x230A,
            "rfloor": 0x230B, "lang": 0x2329, "rang": 0x232A,
            "loz": 0x25CA, "spades": 0x2660, "clubs": 0x2663,
            "hearts": 0x2665, "diams": 0x2666,
        ]
        // Latin-1 带变音字母（Agrave…yuml）：程序化补齐。
        let latin1: [(String, UInt32)] = [
            ("Agrave", 0xC0), ("Aacute", 0xC1), ("Acirc", 0xC2),
            ("Atilde", 0xC3), ("Auml", 0xC4), ("Aring", 0xC5),
            ("AElig", 0xC6), ("Ccedil", 0xC7), ("Egrave", 0xC8),
            ("Eacute", 0xC9), ("Ecirc", 0xCA), ("Euml", 0xCB),
            ("Igrave", 0xCC), ("Iacute", 0xCD), ("Icirc", 0xCE),
            ("Iuml", 0xCF), ("ETH", 0xD0), ("Ntilde", 0xD1),
            ("Ograve", 0xD2), ("Oacute", 0xD3), ("Ocirc", 0xD4),
            ("Otilde", 0xD5), ("Ouml", 0xD6), ("Oslash", 0xD8),
            ("Ugrave", 0xD9), ("Uacute", 0xDA), ("Ucirc", 0xDB),
            ("Uuml", 0xDC), ("Yacute", 0xDD), ("THORN", 0xDE),
            ("szlig", 0xDF), ("agrave", 0xE0), ("aacute", 0xE1),
            ("acirc", 0xE2), ("atilde", 0xE3), ("auml", 0xE4),
            ("aring", 0xE5), ("aelig", 0xE6), ("ccedil", 0xE7),
            ("egrave", 0xE8), ("eacute", 0xE9), ("ecirc", 0xEA),
            ("euml", 0xEB), ("igrave", 0xEC), ("iacute", 0xED),
            ("icirc", 0xEE), ("iuml", 0xEF), ("eth", 0xF0),
            ("ntilde", 0xF1), ("ograve", 0xF2), ("oacute", 0xF3),
            ("ocirc", 0xF4), ("otilde", 0xF5), ("ouml", 0xF6),
            ("oslash", 0xF8), ("ugrave", 0xF9), ("uacute", 0xFA),
            ("ucirc", 0xFB), ("uuml", 0xFC), ("yacute", 0xFD),
            ("thorn", 0xFE), ("yuml", 0xFF),
        ]
        for (name, value) in latin1 { t[name] = value }
        return t
    }()
}
