import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.0 S16：`ImportStaging` 测试——追加/重放往返保序、批量游标、
/// 文件生命周期、内存有界（只留一批）。
final class ImportStagingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportStagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func row(_ n: Int, fields: [String]? = nil) -> ImportLogicalRow {
        ImportLogicalRow(
            logicalRowNumber: n,
            rawLineRange: n..<(n + 1),
            fields: fields ?? ["w\(n)", "r\(n)", "m\(n)"]
        )
    }

    // MARK: - 往返

    func testAppendAndReplayPreservesOrder() throws {
        let staging = try ImportStaging(directory: directory)
        let expected = (1...500).map { row($0) }
        try staging.append(Array(expected[0..<200]))
        try staging.append(Array(expected[200..<400]))
        try staging.append(Array(expected[400..<500]))

        var cursor = try staging.makeReplayCursor(batchSize: 200)
        var replayed: [ImportLogicalRow] = []
        while let batch = try cursor.nextBatch() {
            XCTAssertLessThanOrEqual(batch.count, 200)
            replayed.append(contentsOf: batch)
        }
        XCTAssertEqual(replayed, expected)
        XCTAssertEqual(staging.rowCount, 500)
    }

    func testReplayCursorBatches() throws {
        let staging = try ImportStaging(directory: directory)
        try staging.append((1...7).map { row($0) })
        var cursor = try staging.makeReplayCursor(batchSize: 3)
        var sizes: [Int] = []
        while let batch = try cursor.nextBatch() {
            sizes.append(batch.count)
        }
        XCTAssertEqual(sizes, [3, 3, 1])
        XCTAssertNil(try cursor.nextBatch()) // 耗尽后稳定返回 nil
    }

    func testForEachBatch() throws {
        let staging = try ImportStaging(directory: directory)
        try staging.append((1...10).map { row($0) })
        var seen: [Int] = []
        try staging.forEachBatch(batchSize: 4) { batch in
            seen.append(contentsOf: batch.map(\.logicalRowNumber))
        }
        XCTAssertEqual(seen, Array(1...10))
    }

    /// 字段含 Unicode/换行/引号时 JSON 往返必须无损。
    func testFieldRoundTripWithUnicodeAndNewlines() throws {
        let staging = try ImportStaging(directory: directory)
        let tricky = ImportLogicalRow(
            logicalRowNumber: 1,
            rawLineRange: 3..<7,
            fields: ["line1\nline2", "q\"uote", "😀", "", "tab\tsep"]
        )
        try staging.append([tricky])
        var cursor = try staging.makeReplayCursor(batchSize: 10)
        let batch = try XCTUnwrap(cursor.nextBatch())
        XCTAssertEqual(batch, [tricky])
    }

    // MARK: - 文件生命周期

    func testFileCreatedUnderControlledDirectory() throws {
        let staging = try ImportStaging(directory: directory)
        XCTAssertTrue(staging.fileURL.path.hasPrefix(directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.fileURL.path))
        XCTAssertTrue(staging.fileURL.lastPathComponent.hasPrefix("import-staging-"))
    }

    func testDiscardRemovesSQLiteAndSidecars() throws {
        let url: URL
        do {
            let staging = try ImportStaging(directory: directory)
            try staging.append([row(1)])
            url = staging.fileURL
            try staging.discard()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testDeinitCleansUpByDefault() throws {
        var url: URL?
        do {
            let staging = try ImportStaging(directory: directory)
            try staging.append([row(1)])
            url = staging.fileURL
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url!.path))
    }

    func testPreservesFileOnDeinit() throws {
        var url: URL?
        do {
            let staging = try ImportStaging(directory: directory)
            try staging.append([row(1)])
            staging.preservesFileOnDeinit = true // 续传场景
            url = staging.fileURL
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
        // 清理
        try? FileManager.default.removeItem(at: url!)
    }

    func testUseAfterDiscardThrows() throws {
        let staging = try ImportStaging(directory: directory)
        try staging.discard()
        XCTAssertThrowsError(try staging.append([row(1)])) { error in
            XCTAssertEqual(error as? ImportStaging.Error, .closed)
        }
    }

    /// 库内不持久化绝对路径：staging 行内容只含逻辑行数据。
    func testNoAbsolutePathsPersisted() throws {
        let staging = try ImportStaging(directory: directory)
        try staging.append([row(1)])
        let raw = try Data(contentsOf: staging.fileURL)
        XCTAssertNil(raw.range(of: Data(directory.path.utf8)))
    }

    // MARK: - 有界性（规模）

    /// 10k 行追加+重放不扩容内存中的批：批大小恒 ≤ 200。
    func testBoundedBatchesAtScale() throws {
        let staging = try ImportStaging(directory: directory)
        for start in stride(from: 1, through: 10_000, by: 200) {
            let batch = (start..<min(start + 200, 10_001)).map { row($0) }
            try staging.append(batch)
        }
        XCTAssertEqual(staging.rowCount, 10_000)
        var cursor = try staging.makeReplayCursor(batchSize: 200)
        var maxBatch = 0
        var total = 0
        while let batch = try cursor.nextBatch() {
            maxBatch = max(maxBatch, batch.count)
            total += batch.count
        }
        XCTAssertEqual(total, 10_000)
        XCTAssertLessThanOrEqual(maxBatch, ImportBatchPolicy.maximumRowsPerBatch)
    }
}
