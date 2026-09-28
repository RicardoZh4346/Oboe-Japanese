import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// LocalReaderFileStore（v0.7.0 §4.3 文件事务）：
/// staging → 原子 install → fileURL 往返；缺文件 nil → missing；
/// removeFiles/collectOrphans 收敛；失败 install 不伤既有文档。
final class ReaderFileStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ReaderFileStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> LocalReaderFileStore {
        LocalReaderFileStore(baseDirectoryURL: root)
    }

    private func makeSourceFile(
        named name: String = "source.txt",
        contents: Data = Data("吾輩は猫である".utf8)
    ) throws -> URL {
        let url = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        let file = url.appendingPathComponent(name)
        try contents.write(to: file)
        return file
    }

    func testStageInstallFileURLRoundTrip() async throws {
        let store = makeStore()
        let payload = Data("猫はまたたびが好き".utf8)
        let source = try makeSourceFile(named: "novel.txt", contents: payload)
        let staged = try await store.stage(fileURL: source)

        XCTAssertEqual(staged.sha256, ReaderHashing.sha256Hex(payload))
        XCTAssertEqual(staged.byteCount, Int64(payload.count))
        XCTAssertTrue(
            staged.stagingURL.path.contains("/ReaderStaging/"),
            "staging 必须落在受控 staging 目录，实际 \(staged.stagingURL)"
        )

        let documentID = UUID()
        let relativePath = try await store.install(
            staged: staged, documentID: documentID
        )
        XCTAssertEqual(relativePath, "novel.txt")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staged.stagingURL.deletingLastPathComponent().path
            ),
            "install 成功后 staging 槽位必须清理"
        )

        let resolved = try XCTUnwrap(
            store.fileURL(documentID: documentID, relativePath: relativePath)
        )
        XCTAssertEqual(try Data(contentsOf: resolved), payload)
        XCTAssertTrue(
            resolved.path.contains("/ReaderFiles/\(documentID.uuidString.lowercased())/"),
            "安装路径必须落在 ReaderFiles/<documentID>/"
        )
        XCTAssertEqual(store.installedDocumentIDs(), [documentID])
    }

    func testFileURLMissingAndUnsafePathsReturnNil() async throws {
        let store = makeStore()
        let documentID = UUID()
        // 未安装/已删文件 → nil（上层据此把 availability 降级 missing）。
        XCTAssertNil(store.fileURL(
            documentID: documentID, relativePath: "source.txt"
        ))
        for bad in ["", "/", "/etc/passwd", "../x", "a/../b", "a//b",
                    "a\\b", ".", "..", "tail/"] {
            XCTAssertNil(
                store.fileURL(documentID: documentID, relativePath: bad),
                "应拒绝 \(bad.debugDescription)"
            )
        }

        let source = try makeSourceFile()
        let staged = try await store.stage(fileURL: source)
        let relativePath = try await store.install(
            staged: staged, documentID: documentID
        )
        XCTAssertNotNil(store.fileURL(
            documentID: documentID, relativePath: relativePath
        ))
        // 文件物理消失 → nil。
        try FileManager.default.removeItem(
            at: store.documentDirectoryURL(documentID: documentID)
                .appendingPathComponent(relativePath)
        )
        XCTAssertNil(store.fileURL(
            documentID: documentID, relativePath: relativePath
        ))
    }

    func testRemoveFilesDeletesDirectoryAndIsIdempotent() async throws {
        let store = makeStore()
        let documentID = UUID()
        let staged = try await store.stage(fileURL: makeSourceFile())
        _ = try await store.install(staged: staged, documentID: documentID)

        try await store.removeFiles(documentID: documentID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.documentDirectoryURL(documentID: documentID).path
        ))
        XCTAssertEqual(store.installedDocumentIDs(), [])
        // 重复删除不是错误。
        try await store.removeFiles(documentID: documentID)
    }

    /// 崩溃收敛：staging 残留与半截 `.incoming-*` 安装被清理，
    /// 已安装文档目录不动（验收 3）。
    func testCollectOrphansRemovesHalfInstalledState() async throws {
        let store = makeStore()
        let documentID = UUID()
        let staged = try await store.stage(fileURL: makeSourceFile())
        _ = try await store.install(staged: staged, documentID: documentID)

        // 残留 staging：模拟 stage 后崩溃。
        let strayStaging = store.stagingDirectoryURL
            .appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(
            at: strayStaging, withIntermediateDirectories: true
        )
        try Data("x".utf8).write(
            to: strayStaging.appendingPathComponent("half.txt")
        )
        // 半截 install：`.incoming-*` 目录遗留（含 journal 与文件）。
        let incoming = store.documentsDirectoryURL
            .appendingPathComponent(".incoming-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(
            at: incoming, withIntermediateDirectories: true
        )
        try Data(UUID().uuidString.utf8).write(
            to: incoming.appendingPathComponent(".journal")
        )
        try Data("partial".utf8).write(
            to: incoming.appendingPathComponent("book.epub")
        )

        try await store.collectOrphans()

        XCTAssertFalse(FileManager.default.fileExists(atPath: strayStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        let documentsEntries = try FileManager.default.contentsOfDirectory(
            atPath: store.documentsDirectoryURL.path
        )
        XCTAssertEqual(
            documentsEntries,
            [documentID.uuidString.lowercased()],
            "已安装文档目录必须完整保留"
        )
        // 已安装文件仍可访问。
        XCTAssertNotNil(store.fileURL(
            documentID: documentID, relativePath: "source.txt"
        ))
    }

    /// 失败 install 绝不影响既有文档（验收 3）；目标目录已存在直接拒绝。
    func testFailedInstallDoesNotTouchExistingDocument() async throws {
        let store = makeStore()
        let firstID = UUID()
        let payload = Data("原本".utf8)
        let source = try makeSourceFile(named: "first.txt", contents: payload)
        _ = try await store.install(
            staged: try await store.stage(fileURL: source),
            documentID: firstID
        )

        // 1) 对同一 documentID 重复 install → installTargetExists，
        //    既有文件原样。
        let replay = try await store.stage(
            fileURL: makeSourceFile(named: "evil.txt")
        )
        await XCTAssertAsyncThrows(
            try await store.install(staged: replay, documentID: firstID)
        ) { error in
            XCTAssertEqual(
                error as? ReaderFileStoreError, .installTargetExists
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(store.fileURL(
                documentID: firstID, relativePath: "first.txt"
            ))),
            payload
        )
        XCTAssertNil(store.fileURL(documentID: firstID, relativePath: "evil.txt"))

        // 2) staged 文件中途消失 → install 失败；新文档目录不残留，
        //    既有文档不受影响；staging 残留由 collectOrphans 收敛。
        let secondID = UUID()
        let doomed = try await store.stage(
            fileURL: makeSourceFile(named: "second.txt")
        )
        try FileManager.default.removeItem(at: doomed.stagingURL)
        await XCTAssertAsyncThrows(
            try await store.install(staged: doomed, documentID: secondID)
        ) { error in
            guard case ReaderFileStoreError.installFailed = error else {
                return XCTFail("应为 installFailed，实际 \(error)")
            }
        }
        XCTAssertEqual(store.installedDocumentIDs(), [firstID])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.documentDirectoryURL(documentID: secondID).path
        ))
        // `.incoming-*` 已被 install 失败分支清掉。
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: store.documentsDirectoryURL.path
        ).filter { $0.hasPrefix(".incoming-") }
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(store.fileURL(
                documentID: firstID, relativePath: "first.txt"
            ))),
            payload
        )
    }

    func testStageRejectsDirectoryAndComputesRealDigest() async throws {
        let store = makeStore()
        await XCTAssertAsyncThrows(
            try await store.stage(fileURL: root)
        ) { error in
            guard case ReaderFileStoreError.stageFailed = error else {
                return XCTFail("应为 stageFailed，实际 \(error)")
            }
        }
        await XCTAssertAsyncThrows(
            try await store.stage(
                fileURL: root.appendingPathComponent("missing.txt")
            )
        )
    }
}

/// async 版本的 XCTAssertThrowsError。
private func XCTAssertAsyncThrows(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: String = "",
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("期待抛错但未抛 \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
