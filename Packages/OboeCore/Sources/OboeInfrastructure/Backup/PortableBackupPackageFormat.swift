import Foundation
import ImageIO
import OboeDomain
import UniformTypeIdentifiers

/// 便携备份 v7 的 ZIP 容器约定（设计 §11.2）。
///
/// `.oboe-backup` 扩展名不变，内部是 ZIP：
/// `manifest.json` + `records.ndjson` + `attachments/<id>.<ext>` + `checksums.json`。
/// `records.ndjson` 仍是完整的 v6 NDJSON 流（manifest 行 + 记录行 + footer），
/// 单独解出来就是一个可读的 v6 备份；附件元数据只在 package manifest 里
/// 登记一次，不进记录流——避免同一信息两处存储漂移。
public enum PortableBackupPackageFormat {
    public static let formatVersion = 7
    public static let container = "zip"
    public static let manifestEntryName = "manifest.json"
    public static let recordsEntryName = "records.ndjson"
    public static let checksumsEntryName = "checksums.json"
    public static let attachmentsDirectoryName = "attachments"

    /// 内嵌 `records.ndjson` 遵循的记录流版本。v7 的增量只在容器层
    /// （附件 sidecar + checksums），记录契约与 v6 完全一致。
    public static let recordsFormatVersion = PortableBackupFormat.currentVersion

    /// v7 的排除范围：imageAttachments 移出——附件字节随包分发。
    /// 其余排除项与 v3+ 相同（凭据、AI 连接配置、共享中转、派生索引）。
    public static let excludedScopes: [String] = [
        "credentials",
        "aiConnectionConfiguration",
        "sharedTransferFiles",
        "derivedSearchIndex"
    ]

    /// 接受的图片 MIME → 允许的包内扩展名（小写）。
    /// 与 `InboxImageValidator` 接受的源格式一致；当前导出端只写 JPEG 预览，
    /// 白名单留了 png/heic 给未来的非重编码附件类型。
    public static let allowedExtensionsByMIMEType: [String: Set<String>] = [
        "image/jpeg": ["jpg", "jpeg"],
        "image/png": ["png"],
        "image/heic": ["heic", "heif"]
    ]

    /// descriptor.relativePath 的规范形态：`attachments/<id>.<ext>`。
    /// 固定单级目录 + id 即文件名主干，从结构上排除了路径歧义。
    public static func canonicalRelativePath(id: String, fileExtension ext: String) -> String {
        "\(attachmentsDirectoryName)/\(id).\(ext)"
    }

    /// descriptor 字段级校验。全部通过才允许进入 manifest 或 staging。
    static func validate(descriptor raw: [String: Any], context: String) throws
        -> AttachmentDescriptor
    {
        let allowedKeys: Set<String> = [
            "id", "relativePath", "mimeType", "byteCount",
            "sha256", "pixelWidth", "pixelHeight"
        ]
        let requiredKeys: Set<String> = [
            "id", "relativePath", "mimeType", "byteCount", "sha256"
        ]
        guard Set(raw.keys).isSubset(of: allowedKeys),
              Set(raw.keys).isSuperset(of: requiredKeys) else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件字段集合无效。"
            )
        }
        guard let id = raw["id"] as? String,
              (try? InboxImageStore.validateResourceID(id)) != nil else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 id 不是受控资源 ID。"
            )
        }
        guard let mimeType = raw["mimeType"] as? String,
              let allowedExtensions = allowedExtensionsByMIMEType[mimeType] else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 mimeType 不受支持。"
            )
        }
        guard let relativePath = raw["relativePath"] as? String else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 relativePath 缺失。"
            )
        }
        // 结构校验：恰好 `attachments/<id>.<ext>`，扩展名属于该 MIME 的白名单。
        let prefix = attachmentsDirectoryName + "/"
        guard relativePath.hasPrefix(prefix) else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 relativePath 必须以 \(prefix) 开头。"
            )
        }
        let fileName = String(relativePath.dropFirst(prefix.count))
        guard fileName.hasPrefix(id + "."),
              let ext = fileName.split(separator: ".").last.map(String.init),
              fileName == "\(id).\(ext)",
              allowedExtensions.contains(ext) else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 relativePath 与 id/MIME 不一致。"
            )
        }
        let byteCount = try packageInteger(raw["byteCount"], field: "byteCount", context: context)
        guard byteCount >= 0 else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 byteCount 不能为负。"
            )
        }
        guard let sha256 = raw["sha256"] as? String, isLowercaseSHA256Hex(sha256) else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件 sha256 不是小写十六进制摘要。"
            )
        }
        let pixelWidth = try optionalPackageInteger(
            raw["pixelWidth"], field: "pixelWidth", context: context
        )
        let pixelHeight = try optionalPackageInteger(
            raw["pixelHeight"], field: "pixelHeight", context: context
        )
        guard pixelWidth == nil || pixelWidth! > 0,
              pixelHeight == nil || pixelHeight! > 0 else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的附件像素尺寸必须为正。"
            )
        }
        return AttachmentDescriptor(
            id: id,
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: byteCount,
            sha256: sha256,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    static func isLowercaseSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }

    static func packageInteger(
        _ rawValue: Any?,
        field: String,
        context: String
    ) throws -> Int {
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int64(number.stringValue),
              value <= Int64(Int.max), value >= Int64(Int.min) else {
            throw PortableBackupPackageError.invalidManifest(
                "\(context) 的 \(field) 必须是整数。"
            )
        }
        return Int(value)
    }

    static func optionalPackageInteger(
        _ rawValue: Any?,
        field: String,
        context: String
    ) throws -> Int? {
        guard let rawValue, !(rawValue is NSNull) else { return nil }
        return try packageInteger(rawValue, field: field, context: context)
    }

    /// ISO 8601（UTC、含毫秒）——与 v1–v6 manifest 的 exportedAt 约定一致。
    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func iso8601Date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }
}

/// package 级 manifest.json 的解码模型。
public struct PortableBackupPackageManifest: Codable, Equatable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var container: String
    public var appVersion: String
    public var exportedAt: String
    public var encoding: String
    public var lineEnding: String
    public var checksumAlgorithm: String
    /// 内嵌 records.ndjson 遵循的记录流版本（当前 = 6）。
    public var recordFormatVersion: Int
    public var recordOrder: [String]
    public var counts: [String: Int]
    public var excludedScopes: [String]
    public var attachments: [AttachmentDescriptor]

    public init(
        format: String,
        formatVersion: Int,
        container: String,
        appVersion: String,
        exportedAt: String,
        encoding: String,
        lineEnding: String,
        checksumAlgorithm: String,
        recordFormatVersion: Int,
        recordOrder: [String],
        counts: [String: Int],
        excludedScopes: [String],
        attachments: [AttachmentDescriptor]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.container = container
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.checksumAlgorithm = checksumAlgorithm
        self.recordFormatVersion = recordFormatVersion
        self.recordOrder = recordOrder
        self.counts = counts
        self.excludedScopes = excludedScopes
        self.attachments = attachments
    }

    /// 序列化：sortedKeys 保证输出确定性（与 v1–v6 manifest 行同约定）。
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// checksums.json 的解码模型：`files` 把包内入口路径映射到小写 sha256。
/// manifest.json 本身是信任根，不参与自校验。
public struct PortableBackupChecksums: Codable, Equatable, Sendable {
    public var algorithm: String
    public var files: [String: String]

    public init(algorithm: String, files: [String: String]) {
        self.algorithm = algorithm
        self.files = files
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// v7 包读入/校验的资源上限。默认值为常规备份留足余量，
/// 又能在 zip 炸弹（条目数、单条目、解压总量）下 fail-fast。
public struct PortableBackupPackageLimits: Equatable, Sendable {
    /// ZIP 文件本身的字节上限。
    public var maximumPackageBytes: Int64
    /// 中央目录条目数上限（文件数炸弹）。
    public var maximumEntryCount: Int
    /// 全部条目解压总量上限。
    public var maximumTotalUncompressedBytes: Int64
    /// 单条目解压后上限（附件独立再受限于此值）。
    public var maximumEntryBytes: Int64
    /// manifest.json / checksums.json 各自的上限。
    public var maximumManifestBytes: Int
    /// records.ndjson 解压后上限（对齐 NDJSON 路径的文件上限）。
    public var maximumRecordsBytes: Int64
    /// manifest 里允许声明的附件数上限。
    public var maximumAttachmentCount: Int

    public init(
        maximumPackageBytes: Int64 = 1_024 * 1_024 * 1_024,
        maximumEntryCount: Int = 10_000,
        maximumTotalUncompressedBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumEntryBytes: Int64 = 128 * 1_024 * 1_024,
        maximumManifestBytes: Int = 4 * 1_024 * 1_024,
        maximumRecordsBytes: Int64 = 200 * 1_024 * 1_024,
        maximumAttachmentCount: Int = 5_000
    ) {
        precondition(maximumPackageBytes > 0)
        precondition(maximumEntryCount > 0)
        precondition(maximumTotalUncompressedBytes > 0)
        precondition(maximumEntryBytes > 0)
        precondition(maximumManifestBytes > 0)
        precondition(maximumRecordsBytes > 0)
        precondition(maximumAttachmentCount >= 0)
        self.maximumPackageBytes = maximumPackageBytes
        self.maximumEntryCount = maximumEntryCount
        self.maximumTotalUncompressedBytes = maximumTotalUncompressedBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumRecordsBytes = maximumRecordsBytes
        self.maximumAttachmentCount = maximumAttachmentCount
    }
}

public enum PortableBackupPackageError: Error, Equatable, Sendable {
    /// 不是 ZIP 容器（首字节不是 PK 签名 / 找不到 EOCD）。
    case notAPackage
    /// ZIP 结构损坏或使用了不支持的特性（多卷、ZIP64、data descriptor 错位等）。
    case malformedArchive(String)
    case packageTooLarge(actual: Int64, limit: Int64)
    case tooManyEntries(actual: Int, limit: Int)
    case totalUncompressedTooLarge(actual: Int64, limit: Int64)
    case entryTooLarge(name: String, actual: Int64, limit: Int64)
    /// 加密条目（flags bit0）。
    case encryptedArchive
    /// 非 store/deflate 的压缩方式。
    case unsupportedCompressionMethod(UInt16)
    /// 文件名非法 UTF-8 / 为空。
    case invalidEntryName(String)
    /// 路径穿越：绝对路径、`..`、反斜杠、空分段。
    case invalidEntryPath(String)
    /// 符号链接或其他非常规文件（UNIX mode 位）。
    case nonRegularFileEntry(String)
    case duplicateEntry(String)
    /// 格式内未声明的额外文件条目。
    case unexpectedEntry(String)
    /// 格式要求但缺失的条目。
    case missingEntry(String)
    case sizeMismatch(name: String, expected: Int, actual: Int)
    case crcMismatch(name: String)
    case invalidManifest(String)
    case invalidChecksums(String)
    /// checksums.json 声明值与实际解压内容不符。
    case checksumMismatch(file: String)
    /// manifest 声明了附件但包内缺对应文件。
    case attachmentMissing(id: String)
    case attachmentSizeMismatch(id: String, expected: Int64, actual: Int64)
    case attachmentChecksumMismatch(id: String)
    /// 内容嗅探出的 MIME 与 manifest 声明不一致。
    case attachmentTypeMismatch(id: String, declared: String, actual: String)
    /// 声明的像素尺寸与实际不符。
    case attachmentPixelMismatch(id: String)
    /// 包声明的 formatVersion 比当前实现新。
    case futurePackageVersion(Int)
    /// formatVersion 不是已知的包版本。
    case unsupportedPackageVersion(Int)
    /// 附件数超过上限。
    case tooManyAttachments(actual: Int, limit: Int)
}

extension PortableBackupPackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAPackage:
            "备份不是有效的 ZIP 容器。"
        case let .malformedArchive(reason):
            "备份容器结构无效：\(reason)"
        case let .packageTooLarge(actual, limit):
            "备份包过大（\(actual) 字节，上限 \(limit) 字节）。"
        case let .tooManyEntries(actual, limit):
            "备份包含 \(actual) 个条目，超过 \(limit) 条上限。"
        case let .totalUncompressedTooLarge(actual, limit):
            "备份解压总量 \(actual) 字节，超过 \(limit) 字节上限。"
        case let .entryTooLarge(name, actual, limit):
            "备份条目 \(name) 解压后 \(actual) 字节，超过 \(limit) 字节上限。"
        case .encryptedArchive:
            "不支持加密的备份包。"
        case let .unsupportedCompressionMethod(method):
            "备份使用了不支持的压缩方式（\(method)）。"
        case let .invalidEntryName(name):
            "备份条目名无效：\(name)。"
        case let .invalidEntryPath(path):
            "备份条目路径不安全：\(path)。"
        case let .nonRegularFileEntry(name):
            "备份条目 \(name) 不是常规文件（符号链接等不受支持）。"
        case let .duplicateEntry(name):
            "备份包含重复条目 \(name)。"
        case let .unexpectedEntry(name):
            "备份包含未声明的条目 \(name)。"
        case let .missingEntry(name):
            "备份缺少必需条目 \(name)。"
        case let .sizeMismatch(name, expected, actual):
            "备份条目 \(name) 解压大小不符（声明 \(expected)，实际 \(actual)）。"
        case let .crcMismatch(name):
            "备份条目 \(name) 的 CRC 校验失败。"
        case let .invalidManifest(reason):
            "备份 manifest 无效：\(reason)"
        case let .invalidChecksums(reason):
            "备份 checksums 无效：\(reason)"
        case let .checksumMismatch(file):
            "备份文件 \(file) 的 SHA-256 校验失败。"
        case let .attachmentMissing(id):
            "备份声明的附件 \(id) 在包内缺失。"
        case let .attachmentSizeMismatch(id, expected, actual):
            "附件 \(id) 大小不符（声明 \(expected)，实际 \(actual)）。"
        case let .attachmentChecksumMismatch(id):
            "附件 \(id) 的 SHA-256 校验失败。"
        case let .attachmentTypeMismatch(id, declared, actual):
            "附件 \(id) 类型不符（声明 \(declared)，实际 \(actual)）。"
        case let .attachmentPixelMismatch(id):
            "附件 \(id) 的像素尺寸与声明不符。"
        case let .futurePackageVersion(version):
            "备份包版本 \(version) 比当前应用新，请升级 Oboe。"
        case let .unsupportedPackageVersion(version):
            "不支持备份包版本 \(version)。"
        case let .tooManyAttachments(actual, limit):
            "备份包含 \(actual) 个附件，超过 \(limit) 个上限。"
        }
    }
}

/// 附件字节内容嗅探：真实 UTI（`CGImageSourceGetType`）+ 像素尺寸，
/// 不经文件扩展名——与 `InboxImageValidator` 同一判定来源。
enum AttachmentContentSniffer {
    struct Inspection: Equatable, Sendable {
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// 返回 nil 表示内容不是受支持的图片类型或尺寸不可解析。
    static func inspect(_ data: Data) -> Inspection? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) as? String else {
            return nil
        }
        let mimeType: String
        switch uti {
        case UTType.jpeg.identifier:
            mimeType = "image/jpeg"
        case UTType.png.identifier:
            mimeType = "image/png"
        case "public.heic", "public.heif":
            mimeType = "image/heic"
        default:
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return Inspection(mimeType: mimeType, pixelWidth: width, pixelHeight: height)
    }

    /// 该 MIME 的规范包内扩展名（白名单里的第一个候选）。
    static func canonicalExtension(forMimeType mimeType: String) -> String? {
        switch mimeType {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        default: return nil
        }
    }
}
