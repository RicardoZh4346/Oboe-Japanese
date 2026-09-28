import Foundation
import OboeDomain

/// Reader 受控文件仓库错误（设计 §4.3 文件事务）。
public enum ReaderFileStoreError: Error, Equatable, Sendable {
    /// staging 源不可读/是目录——调用方先修复输入再重试。
    case stageFailed(String)
    /// `ReaderFiles/<documentID>/` 已存在：install 绝不覆盖既有文档，
    /// 失败安装不影响已安装内容（验收：失败 install 不动既有文件）。
    case installTargetExists
    /// install 中途失败（journal 残留由 collectOrphans 收敛）。
    case installFailed(String)
    /// 相对路径越界：绝对路径、`..`、反斜杠、空段。
    case unsafeRelativePath(String)
}

/// 受控相对路径规则——文件仓库与 `reader_assets` 写路径共用同一判定，
/// 保证落库路径与落盘路径口径一致（§4.1「路径为受控相对路径」）。
public enum ReaderControlledPath {
    /// 合法：`a.txt`、`OEBPS/images/pic.png`。
    /// 非法：`/abs`、`a/../b`、`a//b`、`.`、`..`、反斜杠、NUL、空串。
    public static func isValid(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0") else {
            return false
        }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                component != "." && component != ".." && !component.isEmpty
            }
    }

    /// staging 落盘文件名：保留原名中安全的一段，危险名退化为固定名
    ///（原始文件名由 `source_file_name` 展示，不构成文件身份）。
    static func sanitizedFileName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".", trimmed != "..",
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0") else {
            return "source.bin"
        }
        return trimmed
    }
}

/// 本地受控文件仓库（设计 §4.3）：`base/ReaderStaging` 暂存，
/// `base/ReaderFiles/<documentID>/` 为已安装文档目录。
///
/// 事务形态：
/// 1. `stage` 流式复制 + SHA-256 度量进 `ReaderStaging/<uuid>/`；
/// 2. `install` 先把 staged 文件移入 `ReaderFiles/.incoming-<uuid>/`
///    （含 `.journal` 记录目标 documentID），再原子 rename 为
///    `ReaderFiles/<documentID>/`——同卷 rename 原子，崩溃只剩
///    `.incoming-*` 半成品；
/// 3. `collectOrphans` 在启动时清掉全部 staging 残留与 `.incoming-*`，
///    使任何中断收敛到「无半截文档」。
///
/// 恢复屏障/重关联插桩点（S04 不实现恢复，见 §14.2）：
/// - 恢复换库后调用方应重新跑 `collectOrphans`，并以
///   `installedDocumentIDs()` 与新库 `reader_documents` 对账：
///   目录无记录→孤立清理/按 hash 重关联候选；记录无文件→`fileURL`
///   返回 nil 降级 missing。旧 UUID 不自动接到新 metadata（§4.3-6）。
/// - generation 屏障在 ReaderRuntime/service 层拒绝迟到的旧代写入；
///   本类型无 DB 依赖、无世代概念，只保证文件形态自洽。
public struct LocalReaderFileStore: ReaderFileStore, Sendable {
    /// 应用级基目录（通常 Application Support 下的子目录）。
    public let baseDirectoryURL: URL
    /// 已安装文档根目录 `ReaderFiles/`。
    public var documentsDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("ReaderFiles", isDirectory: true)
    }
    /// staging 根目录 `ReaderStaging/`。
    public var stagingDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent("ReaderStaging", isDirectory: true)
    }

    private static let incomingPrefix = ".incoming-"
    private static let journalFileName = ".journal"

    public init(baseDirectoryURL: URL) {
        self.baseDirectoryURL = baseDirectoryURL
    }

    /// 把用户选择的文件复制进 staging 并返回 hash/字节数；
    /// security-scope 生命周期由调用方负责（契约）。
    public func stage(fileURL: URL) async throws -> ReaderStagedFile {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path,
                                             isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ReaderFileStoreError.stageFailed(
                "源不存在或不是文件：\(fileURL.lastPathComponent)"
            )
        }
        let stagingDirectory = stagingDirectoryURL.appendingPathComponent(
            UUID().uuidString.lowercased(), isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory, withIntermediateDirectories: true
            )
        } catch {
            throw ReaderFileStoreError.stageFailed(
                "无法创建 staging 目录：\(error.localizedDescription)"
            )
        }
        let name = ReaderControlledPath.sanitizedFileName(fileURL.lastPathComponent)
        let destination = stagingDirectory.appendingPathComponent(name, isDirectory: false)
        do {
            let digest = try ReaderHashing.copyHashing(
                from: fileURL, to: destination
            )
            Self.applyProtectionAttributes(at: destination)
            return ReaderStagedFile(
                stagingURL: destination,
                sha256: digest.sha256,
                byteCount: digest.byteCount
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw ReaderFileStoreError.stageFailed(
                "复制失败：\(error.localizedDescription)"
            )
        }
    }

    /// staging → `ReaderFiles/<documentID>/` 原子安装；返回受控相对路径
    ///（相对文档目录，如 `source.txt`）。目标目录已存在时拒绝，
    /// 不覆盖既有文档。成功后清理 staging 目录。
    ///
    /// 注意：staged 文件是 *移动* 而非复制——install 一旦失败，
    /// 该 staging 槽位即被消费，调用方需重新 stage。
    @discardableResult
    public func install(
        staged: ReaderStagedFile,
        documentID: UUID
    ) async throws -> String {
        let relativePath = ReaderControlledPath.sanitizedFileName(
            staged.stagingURL.lastPathComponent
        )
        guard ReaderControlledPath.isValid(relativePath) else {
            throw ReaderFileStoreError.unsafeRelativePath(relativePath)
        }
        let documentsRoot = documentsDirectoryURL
        let documentDirectory = documentsRoot.appendingPathComponent(
            Self.directoryName(for: documentID), isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: documentDirectory.path) else {
            throw ReaderFileStoreError.installTargetExists
        }
        let incoming = documentsRoot.appendingPathComponent(
            Self.incomingPrefix + UUID().uuidString.lowercased(),
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: incoming, withIntermediateDirectories: true
            )
            // journal：把目标 documentID 留给收敛/诊断；清理本身靠目录名前缀。
            try Data(Self.directoryName(for: documentID).utf8).write(
                to: incoming.appendingPathComponent(Self.journalFileName)
            )
            try FileManager.default.moveItem(
                at: staged.stagingURL,
                to: incoming.appendingPathComponent(relativePath, isDirectory: false)
            )
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw ReaderFileStoreError.installFailed(error.localizedDescription)
        }
        do {
            // 同卷目录 rename = 原子提交点。
            try FileManager.default.moveItem(at: incoming, to: documentDirectory)
        } catch {
            try? FileManager.default.removeItem(at: incoming)
            throw ReaderFileStoreError.installFailed(error.localizedDescription)
        }
        Self.applyProtectionAttributes(at: documentDirectory)
        Self.applyProtectionAttributes(
            at: documentDirectory.appendingPathComponent(relativePath)
        )
        // staging 槽位清理只作用于本仓库管理的目录内。
        let stagingParent = staged.stagingURL.deletingLastPathComponent()
        if stagingParent.standardizedFileURL.path
            .hasPrefix(stagingDirectoryURL.standardizedFileURL.path + "/") {
            try? FileManager.default.removeItem(at: stagingParent)
        }
        return relativePath
    }

    /// 文档删除/恢复清理其文件目录；缺失不是错误（与
    /// `InboxImageStore.delete` 同一纪律）。
    public func removeFiles(documentID: UUID) async throws {
        let directory = documentsDirectoryURL.appendingPathComponent(
            Self.directoryName(for: documentID), isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw ReaderFileStoreError.installFailed(
                "删除失败：\(error.localizedDescription)"
            )
        }
    }

    /// 启动收敛：清掉未完成 staging 与中断 install 的残留
    ///（`ReaderStaging/*`、`ReaderFiles/.incoming-*`）。
    /// 有意不碰 `ReaderFiles/<uuid>`——没有 DB 视野，已安装目录的
    /// 对账/重关联由服务层借 `installedDocumentIDs()` 完成。
    public func collectOrphans() async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: stagingDirectoryURL.path) {
            for entry in try fileManager.contentsOfDirectory(
                at: stagingDirectoryURL,
                includingPropertiesForKeys: nil
            ) {
                try? fileManager.removeItem(at: entry)
            }
        }
        if fileManager.fileExists(atPath: documentsDirectoryURL.path) {
            for entry in try fileManager.contentsOfDirectory(
                at: documentsDirectoryURL,
                includingPropertiesForKeys: nil
            ) where entry.lastPathComponent.hasPrefix(Self.incomingPrefix) {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    /// 按 documentID + 受控相对路径解析本地文件；缺失返回 nil
    ///（→ 上层把 availability 降级 missing）。非法路径也返回 nil——
    /// 读取路径绝不允许逃出文档目录。
    public func fileURL(documentID: UUID, relativePath: String) -> URL? {
        guard ReaderControlledPath.isValid(relativePath) else { return nil }
        let directory = documentsDirectoryURL.appendingPathComponent(
            Self.directoryName(for: documentID), isDirectory: true
        )
        let url = directory.appendingPathComponent(relativePath)
        guard url.standardizedFileURL.path
            .hasPrefix(directory.standardizedFileURL.path + "/") else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 已安装文档目录名集合——恢复/重关联对账用（见类型文档插桩点）。
    public func installedDocumentIDs() -> [UUID] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: documentsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), let id = UUID(uuidString: name) else {
                return nil
            }
            return id
        }
    }

    /// 文档目录 URL——S05+ EPUB 资源解包时的受控写入落点
    ///（本步骤不创建目录；install 之后才存在）。
    public func documentDirectoryURL(documentID: UUID) -> URL {
        documentsDirectoryURL.appendingPathComponent(
            Self.directoryName(for: documentID), isDirectory: true
        )
    }

    static func directoryName(for documentID: UUID) -> String {
        documentID.uuidString.lowercased()
    }

    /// 与 InboxImageStore 一致的数据保护口径；尽力而为，失败不阻断。
    static func applyProtectionAttributes(at url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}
