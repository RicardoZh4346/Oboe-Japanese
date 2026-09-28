import CryptoKit
import Foundation

/// 流式 SHA-256 摘要结果（小写 hex + 字节数）。
public struct ReaderFileDigest: Equatable, Sendable {
    public let sha256: String
    public let byteCount: Int64

    public init(sha256: String, byteCount: Int64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Reader 受控文件仓库的哈希工具（设计 §4.2/§4.3：staging 边复制边算
/// source SHA-256；canonical text hash 由解析器产出，这里提供 data/string
/// 便捷口）。输出恒为小写 64 位 hex，与 `PortableBackupPackageFormat`
/// 的校验口径一致。
public enum ReaderHashing {
    /// 单次读取窗口。50 MiB 输入限额下 1 MiB/chunk 常驻内存可控。
    public static let defaultChunkSize = 1 << 20

    /// 流式度量已存在文件；不整体载入内存。
    public static func digestFile(
        at url: URL,
        chunkSize: Int = defaultChunkSize
    ) throws -> ReaderFileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return ReaderFileDigest(
            sha256: hex(hasher.finalize()),
            byteCount: total
        )
    }

    /// 边复制边哈希（staging 路径）：源逐块读出、写入目标并更新摘要。
    /// 中途失败删除部分写出的目标文件再抛错——与
    /// `StreamingZipReader.extractToFile` 同一纪律。
    @discardableResult
    public static func copyHashing(
        from sourceURL: URL,
        to destinationURL: URL,
        chunkSize: Int = defaultChunkSize
    ) throws -> ReaderFileDigest {
        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteFileExists)
        }
        do {
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destinationURL)
            do {
                var hasher = SHA256()
                var total: Int64 = 0
                while let chunk = try input.read(upToCount: chunkSize),
                      !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    hasher.update(data: chunk)
                    total += Int64(chunk.count)
                }
                try output.synchronize()
                try output.close()
                return ReaderFileDigest(
                    sha256: hex(hasher.finalize()),
                    byteCount: total
                )
            } catch {
                try? output.close()
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    /// canonical hash 计算（S05+ 解析器）与测试共用的 in-memory 版本。
    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
