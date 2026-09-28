import Foundation
import OboeDomain

/// EPUB 结构文件解析：container.xml / OPF / encryption.xml。
/// 全部走 `XMLParser` SAX（命名空间开、外部实体 never）——
/// §5「XML 外部实体禁用」。
///
/// 共同的严格性注意：XMLParser 是严格 XML 解析器——未声明的实体
/// （如外部 DTD 里的 `&nbsp;`）会失败；`XHTMLTextExtractor` 在文本层
/// 预展开常见 HTML 命名实体，这些结构文件规范上不该有未声明实体，
/// 解析失败 → `malformedContainer`/`malformedOPF`。
enum EPUBStructureParser {

    /// 把 `data` 交给 `parser`，统一把 XMLParserError 映射为
    /// `ReaderParserError`（外部实体策略在解析器工厂里钉死）。
    static func parse<Parser: NSObject & XMLParserDelegate>(
        _ data: Data,
        delegate: Parser,
        errorMapping: (String) -> ReaderParserError
    ) throws -> Parser {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        // SDK ≥26 将 case 名回退为 NSXMLParserResolveExternalEntitiesNever；
        // rawValue 0 == Never，跨 SDK 稳定。
        parser.externalEntityResolvingPolicy = XMLParser.ExternalEntityResolvingPolicy(rawValue: 0)! // NSXMLParserResolveExternalEntitiesNever
        if !parser.parse() {
            let line = parser.lineNumber
            let reason = parser.parserError.map {
                "\($0.localizedDescription)@\(line)"
            } ?? "unknown"
            throw errorMapping(reason)
        }
        return delegate
    }

    // MARK: - container.xml

    /// META-INF/container.xml → OPF rootfile 路径。
    static func parseContainer(_ data: Data) throws -> String {
        let delegate = try parse(data, delegate: ContainerDelegate()) {
            ReaderParserError.malformedContainer(
                reason: "container.xml: \($0)"
            )
        }
        guard let rootfile = delegate.rootfilePath else {
            throw ReaderParserError.malformedContainer(
                reason: "container.xml 无 rootfile"
            )
        }
        return rootfile
    }

    /// EPUB2 NCX / EPUB3 NAV 之外的判别我们不依赖 namespace——
    /// 按 local name 匹配（`<opf:item>` 这类命名空间前缀容错）。
    private final class ContainerDelegate: NSObject, XMLParserDelegate {
        var rootfilePath: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            guard elementName == "rootfile",
                  let path = attributes["full-path"],
                  !path.isEmpty else { return }
            // 首个 rootfile 即 OPF（多 rendition 不展开）。
            if rootfilePath == nil { rootfilePath = path }
        }
    }

    // MARK: - OPF（package.opf）

    struct ManifestItem: Sendable {
        let id: String
        let href: String
        let mediaType: String
        let properties: Set<String>
    }

    struct SpineItem: Sendable {
        let idref: String
        let linear: Bool
    }

    struct PackageDocument: Sendable {
        let title: String?
        let items: [String: ManifestItem]   // id → item
        let spine: [SpineItem]
        /// rendition:layout=pre-paginated → 固定布局拒绝。
        let isFixedLayout: Bool
    }

    static func parseOPF(_ data: Data) throws -> PackageDocument {
        let delegate = try parse(data, delegate: OPFDelegate()) {
            ReaderParserError.malformedOPF(reason: $0)
        }
        guard !delegate.spine.isEmpty else {
            throw ReaderParserError.malformedOPF(reason: "spine 为空")
        }
        return PackageDocument(
            title: delegate.title,
            items: delegate.items,
            spine: delegate.spine,
            isFixedLayout: delegate.isFixedLayout
        )
    }

    private final class OPFDelegate: NSObject, XMLParserDelegate {
        var title: String?
        var items: [String: ManifestItem] = [:]
        var spine: [SpineItem] = []
        var isFixedLayout = false

        private var inDCTitle = false
        private var titleText = ""
        /// rendition:layout 的 meta 文本捕获（EPUB3 property 与
        /// EPUB2 name/content 两种形态都认）。
        private var capturingRenditionMeta = false
        private var renditionText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "title":
                // dc:title：namespaceURI = purl.org/dc/elements/1.1/；
                // 裸 <title> 也接受（不规范包容错）。
                if title == nil {
                    inDCTitle = true
                    titleText = ""
                }
            case "meta":
                let name = attributes["name"]?.lowercased() ?? ""
                let property = attributes["property"]?.lowercased() ?? ""
                let content = attributes["content"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? ""
                if name == "rendition:layout", content == "pre-paginated" {
                    isFixedLayout = true
                }
                if property == "rendition:layout" {
                    capturingRenditionMeta = true
                    renditionText = ""
                }
            case "item":
                guard let id = attributes["id"],
                      let href = attributes["href"],
                      let mediaType = attributes["media-type"]
                else { return }
                items[id] = ManifestItem(
                    id: id,
                    href: href,
                    mediaType: mediaType.lowercased(),
                    properties: Set(
                        (attributes["properties"] ?? "")
                            .split(whereSeparator: \.isWhitespace)
                            .map(String.init)
                    )
                )
            case "itemref":
                guard let idref = attributes["idref"] else { return }
                let linear = (attributes["linear"]?.lowercased() ?? "yes")
                    != "no"
                spine.append(SpineItem(idref: idref, linear: linear))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inDCTitle { titleText += string }
            if capturingRenditionMeta { renditionText += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch elementName {
            case "title":
                if inDCTitle {
                    let value = titleText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if title == nil, !value.isEmpty { title = value }
                    inDCTitle = false
                }
            case "meta":
                if capturingRenditionMeta {
                    if renditionText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() == "pre-paginated" {
                        isFixedLayout = true
                    }
                    capturingRenditionMeta = false
                }
            default:
                break
            }
        }
    }

    // MARK: - encryption.xml（DRM 判定）

    /// 已知的字体混淆算法（可读正文不受影响）：
    /// IDPF font obfuscation 与 Adobe font embedding obfuscation。
    static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// 字体目标判定：URI 扩展名或 MimeType 落字体族。
    static let fontExtensions: Set<String> = [
        "ttf", "otf", "woff", "woff2", "ttc",
    ]

    enum EncryptionScanResult: Equatable {
        /// 无 encryption.xml——完全未加密。
        case none
        /// 只有字体混淆条目 → 正文可读，字体资产照常登记（不解码）。
        case fontObfuscationOnly(targets: [String])
        /// 存在非字体混淆算法的加密条目 → 正文可能加密，拒读。
        case encryptedContent
    }

    static func scanEncryption(_ data: Data?) throws -> EncryptionScanResult {
        guard let data else { return .none }
        let delegate = try parse(data, delegate: EncryptionDelegate()) {
            ReaderParserError.malformedContainer(
                reason: "encryption.xml: \($0)"
            )
        }
        var targets: [String] = []
        for entry in delegate.entries {
            let algorithm = (entry.algorithm ?? "")
                .lowercased()
            let target = entry.uri?.lowercased() ?? ""
            let mime = entry.mimeType?.lowercased() ?? ""
            let isObfuscation = fontObfuscationAlgorithms.contains(algorithm)
            let ext = URL(fileURLWithPath: target)
                .pathExtension.lowercased()
            let isFontTarget = fontExtensions.contains(ext)
                || mime.hasPrefix("font/")
            // 全量条目都必须是「混淆算法 + 字体目标」才算字体混淆。
            guard isObfuscation, isFontTarget else {
                return .encryptedContent
            }
            targets.append(entry.uri ?? "")
        }
        return delegate.entries.isEmpty
            ? .none : .fontObfuscationOnly(targets: targets)
    }

    private struct EncryptedEntry {
        var algorithm: String?
        var uri: String?
        var mimeType: String?
    }

    /// 收集 `<enc:EncryptedData>` 的 Algorithm/URI/MimeType。
    private final class EncryptionDelegate: NSObject, XMLParserDelegate {
        var entries: [EncryptedEntry] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch elementName {
            case "EncryptedData":
                var entry = EncryptedEntry()
                entry.mimeType = attributes["MimeType"]
                entries.append(entry)
            case "EncryptionMethod":
                guard !entries.isEmpty else { break }
                entries[entries.count - 1].algorithm =
                    attributes["Algorithm"]
            case "CipherReference":
                guard !entries.isEmpty else { break }
                entries[entries.count - 1].uri = attributes["URI"]
            default:
                break
            }
        }
    }
}
