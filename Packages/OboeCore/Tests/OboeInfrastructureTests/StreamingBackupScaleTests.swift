import CryptoKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S04 集成与规模测试（v0.6.0 §8.2/§8.3、需求 §13.4）：
/// 100/300 MiB 多附件包的导出 + 读取 + 预检内存趋势、
/// attachmentFileProvider 契约、取消与失败清理、
/// FileHandle 短读、records 行长防线。
final class StreamingBackupScaleTests: XCTestCase {

    private var rootURL: URL!
    private var sourceDatabaseURL: URL!
    private var currentDatabaseURL: URL!
    private var exportsURL: URL!
    private var preparationsURL: URL!
    private var extractionURL: URL!
    private var storeURL: URL!
    private var store: InboxImageStore!
    private let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StreamingBackupScaleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
        currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
        exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
        preparationsURL = rootURL.appendingPathComponent(
            "preparations",
            isDirectory: true
        )
        extractionURL = rootURL.appendingPathComponent(
            "extraction",
            isDirectory: true
        )
        storeURL = rootURL.appendingPathComponent("source-images", isDirectory: true)
        store = InboxImageStore(rootDirectoryURL: storeURL)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    // MARK: - 100 MiB / 300 MiB

    /// 100 MiB 级包：多个各自合法的真实 JPEG（每张 ~4MiB），
    /// 导出 → 流式读取校验 → preparePackage 全链路，RSS 峰值必须
    /// 明显低于整包物化水位。
    func testExportAndPrepare100MiBPackage() async throws {
        try await runScaleScenario(targetBytes: 100 * 1_024 * 1_024)
    }

    /// 300 MiB 级包同链路（需求 §13.4 的大包用例）。
    func testExportAndPrepare300MiBPackage() async throws {
        try await runScaleScenario(targetBytes: 300 * 1_024 * 1_024)
    }

    private func runScaleScenario(targetBytes: Int64) async throws {
        // 每个文件都是可解码的真实 JPEG（噪声编码，~4MiB），
        // 不造超限 blob 或伪装图片绕过 sniff。
        let sample = try Self.makeNoisyJPEG(width: 1_600, height: 1_200)
        let perFile = Int64(sample.count)
        let count = Int(targetBytes / perFile) + 1
        let fixtureBytes = perFile * Int64(count)
        var ids: [String] = []
        var totalWritten: Int64 = 0
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        let source = try OboeDatabase(path: sourceDatabaseURL.path)
        defer { try? source.close() }
        try await seedDeck(into: source)
        for index in 0..<count {
            // 每张内容不同（seed 混入像素），各自独立合法。
            let jpeg = try Self.makeNoisyJPEG(
                width: 1_600,
                height: 1_200,
                seed: UInt32(index &* 97 &+ 11)
            )
            let id = "img\(index)-\(UUID().uuidString.lowercased().prefix(8))"
            try jpeg.write(to: storeURL.appendingPathComponent("\(id).jpg"))
            try await seedInboxItem(into: source, imageReference: id)
            ids.append(id)
            totalWritten += Int64(jpeg.count)
        }

        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: store,
            workingDirectoryURL: exportsURL
        )

        // —— 导出阶段内存 ——
        let sampler = PeakRSSSampler()
        let baseline = Self.residentSize()
        let exportStart = Date()
        sampler.start()
        let export = try await exporter.export(
            appVersion: "s04-scale",
            at: exportedAt
        )
        let exportDuration = Date().timeIntervalSince(exportStart)
        let exportPeak = sampler.stop() - baseline
        let packageSize = try FileManager.default.attributesOfItem(
            atPath: export.url.path
        )[.size] as? Int64 ?? 0

        XCTAssertEqual(export.attachments.count, count)
        XCTAssertEqual(export.unresolvedAttachmentIDs, [])
        // store 直通：包体 ≈ 附件字节总量（含少量容器头开销）。
        XCTAssertGreaterThan(packageSize, totalWritten)
        // 内存峰值必须远低于整包物化（旧实现同时持有附件 Data + 归档 Data）。
        XCTAssertLessThan(
            exportPeak,
            fixtureBytes / 2,
            "导出阶段峰值 RSS \(exportPeak)B 超过 fixture \(fixtureBytes)B 一半"
        )

        // —— 读取校验阶段内存 ——
        let readerBaseline = Self.residentSize()
        let extractStart = Date()
        sampler.start()
        let extracted = try PortableBackupPackageReader().extractAndValidate(
            fileURL: export.url,
            to: extractionURL
        )
        let extractDuration = Date().timeIntervalSince(extractStart)
        let extractPeak = sampler.stop() - readerBaseline
        XCTAssertEqual(extracted.attachmentDescriptors.count, count)
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            atPath: extracted.attachmentsDirectoryURL.path
        )
        XCTAssertEqual(stagedFiles.count, count)
        XCTAssertLessThan(
            extractPeak,
            fixtureBytes / 2,
            "读取阶段峰值 RSS \(extractPeak)B 超过 fixture \(fixtureBytes)B 一半"
        )

        // —— 恢复预检（完整 preparePackage 链路）——
        let current = try OboeDatabase(path: currentDatabaseURL.path)
        defer { try? current.close() }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: preparationsURL
        )
        let prepareBaseline = Self.residentSize()
        let prepareStart = Date()
        sampler.start()
        let prepared = try await preparer.preparePackage(fileURL: export.url)
        let prepareDuration = Date().timeIntervalSince(prepareStart)
        let preparePeak = sampler.stop() - prepareBaseline
        XCTAssertEqual(prepared.attachmentDescriptors.count, count)
        XCTAssertEqual(
            prepared.stagedAttachmentsDirectoryURL.map {
                (try? FileManager.default.contentsOfDirectory(atPath: $0.path))?.count
            },
            count
        )
        try await preparer.discard(prepared)
        XCTAssertLessThan(
            preparePeak,
            fixtureBytes / 2,
            "预检阶段峰值 RSS \(preparePeak)B 超过 fixture \(fixtureBytes)B 一半"
        )

        // 实测数据写入测试日志，供报告引用。
        print("""
            [S04-SCALE] fixture=\(fixtureBytes)B files=\(count) \
            package=\(packageSize)B \
            export=\(String(format: "%.2f", exportDuration))s/peak+\(exportPeak)B \
            extract=\(String(format: "%.2f", extractDuration))s/peak+\(extractPeak)B \
            prepare=\(String(format: "%.2f", prepareDuration))s/peak+\(preparePeak)B
            """)
    }

    // MARK: - provider 契约（S05 lease 预留）

    /// 注入 provider 从替代目录供文件——不依赖 InboxImageStore 默认实现。
    func testCustomAttachmentFileProvider() async throws {
        let alternateURL = rootURL.appendingPathComponent(
            "leased",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: alternateURL,
            withIntermediateDirectories: true
        )
        let jpeg = try Self.makeNoisyJPEG(width: 320, height: 240)
        try jpeg.write(to: alternateURL.appendingPathComponent("lease-1.jpg"))
        let source = try OboeDatabase(path: sourceDatabaseURL.path)
        defer { try? source.close() }
        try await seedDeck(into: source)
        try await seedInboxItem(into: source, imageReference: "lease-1")

        let provider: PortableBackupPackageExporter.AttachmentFileProvider = {
            resourceID in
            alternateURL.appendingPathComponent("\(resourceID).jpg")
        }
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: store,      // 默认目录是空的——能出包证明走了 provider
            workingDirectoryURL: exportsURL,
            attachmentFileProvider: provider,
            snapshotCreatedHook: nil
        )
        let export = try await exporter.export(appVersion: "s04-provider")
        XCTAssertEqual(export.attachments.map(\.id), ["lease-1"])
        XCTAssertEqual(export.attachments[0].mimeType, "image/jpeg")

        let extracted = try PortableBackupPackageReader().extractAndValidate(
            fileURL: export.url,
            to: extractionURL
        )
        XCTAssertEqual(extracted.attachmentDescriptors.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: extracted.attachmentsDirectoryURL
                .appendingPathComponent("lease-1.jpg")),
            jpeg
        )
    }

    /// provider 给不出文件 → 记入 unresolved（与旧缺文件语义一致）。
    func testMissingProviderFileIsUnresolved() async throws {
        let source = try OboeDatabase(path: sourceDatabaseURL.path)
        defer { try? source.close() }
        try await seedDeck(into: source)
        try await seedInboxItem(into: source, imageReference: "ghost")

        let provider: PortableBackupPackageExporter.AttachmentFileProvider = {
            _ in throw InboxImageError.imageUnavailable
        }
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: store,
            workingDirectoryURL: exportsURL,
            attachmentFileProvider: provider,
            snapshotCreatedHook: nil
        )
        let export = try await exporter.export(appVersion: "s04-ghost")
        XCTAssertEqual(export.unresolvedAttachmentIDs, ["ghost"])
        XCTAssertEqual(export.attachments, [])
    }

    // MARK: - 取消与失败清理

    /// 预先取消的任务在导出入口即抛 CancellationError，
    /// 工作目录不留 .pending/.packaging/成品文件。
    func testPreCancelledExportProducesNoArtifacts() async throws {
        let source = try OboeDatabase(path: sourceDatabaseURL.path)
        defer { try? source.close() }
        try await seedDeck(into: source)
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: store,
            workingDirectoryURL: exportsURL
        )
        let task = Task { try await exporter.export(appVersion: "s04-cancel") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("应抛出取消错误")
        } catch is CancellationError {
            // 预期。
        }
        assertNoPackagingLeftovers()
    }

    /// 打包阶段中途取消：provider 每次调用自旋 30ms 拉长窗口，
    /// 取消落在附件流式写入期间 → CancellationError，且不留残件。
    func testCancellationDuringExportLeavesNoArtifacts() async throws {
        let source = try OboeDatabase(path: sourceDatabaseURL.path)
        defer { try? source.close() }
        try await seedDeck(into: source)
        let jpeg = try Self.makeNoisyJPEG(width: 800, height: 600)
        try FileManager.default.createDirectory(
            at: storeURL,
            withIntermediateDirectories: true
        )
        var ids: [String] = []
        for index in 0..<8 {
            let id = "cancel-\(index)"
            try jpeg.write(to: storeURL.appendingPathComponent("\(id).jpg"))
            try await seedInboxItem(into: source, imageReference: id)
            ids.append(id)
        }

        let storeDirectory = storeURL!
        let provider: PortableBackupPackageExporter.AttachmentFileProvider = {
            resourceID in
            Thread.sleep(forTimeInterval: 0.03)
            return storeDirectory.appendingPathComponent("\(resourceID).jpg")
        }
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: store,
            workingDirectoryURL: exportsURL,
            attachmentFileProvider: provider,
            snapshotCreatedHook: nil
        )
        let task = Task { try await exporter.export(appVersion: "s04-cancel2") }
        // 附件循环 ~240ms，100ms 时取消大概率落在打包中段。
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            // 取消若落在窗口外导出可能成功——断言目标不变：
            // 无论成败都不能留 pending/packaging 残件。
        } catch is CancellationError {
            // 预期主路径。
        }
        assertNoPackagingLeftovers()
    }

    /// 快照钩子抛错：导出失败不留下任何打包残件。
    func testExportFailureLeavesNoArtifacts() async throws {
        struct HookFailure: Error {}
        let source = try OboeDatabase(path: sourceDatabaseURL.path)
        defer { try? source.close() }
        try await seedDeck(into: source)
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: store,
            workingDirectoryURL: exportsURL,
            attachmentFileProvider: nil,
            snapshotCreatedHook: { throw HookFailure() }
        )
        do {
            _ = try await exporter.export(appVersion: "s04-fail")
            XCTFail("应抛出 HookFailure")
        } catch is HookFailure {
            // 预期。
        }
        assertNoPackagingLeftovers()
    }

    // MARK: - FileHandle 短读

    /// FileHandle 包装的短读字节源：每次最多 397 字节，
    /// EOCD/中央目录/本地头/解压全链路正确。
    func testShortReadFileHandleSourceExtracts() throws {
        let payload = Data((0..<150_000).map { UInt8($0 % 241) })
        let packageURL = rootURL.appendingPathComponent("shortread.oboe-backup")
        try ZipArchive.archive(entries: [
            ZipArchive.WriteEntry(name: "d.bin", data: payload, method: .deflate),
            ZipArchive.WriteEntry(name: "s.bin", data: payload, method: .store)
        ]).write(to: packageURL)

        let source = try ShortReadFileSource(
            fileURL: packageURL,
            maxReadCount: 397
        )
        let reader = try StreamingZipReader(source: source)
        defer { reader.close() }
        try reader.validateLocalHeaders()
        for name in ["d.bin", "s.bin"] {
            let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
            XCTAssertEqual(
                try reader.extractToData(entry, byteLimit: .max),
                payload
            )
        }
    }

    // MARK: - records 行长防线（preparePackage 层）

    /// 包内 records.ndjson 的行长超限 → lineTooLarge（导入管线防线不变）。
    func testOversizedRecordLineRejectedAtPrepare() async throws {
        let counts = Dictionary(
            uniqueKeysWithValues: PortableBackupFormatV6.recordTypes.map { ($0, 0) }
        )
        let manifestObject: [String: Any] = [
            "recordType": "manifest",
            "format": PortableBackupFormat.identifier,
            "formatVersion": 6,
            "appVersion": "s04",
            "exportedAt": PortableBackupPackageFormat.iso8601String(
                from: exportedAt
            ),
            "encoding": "utf-8",
            "lineEnding": "lf",
            "checksumAlgorithm": PortableBackupFormat.checksumAlgorithm,
            "recordOrder": PortableBackupFormatV6.recordTypes,
            "counts": counts,
            "excludedScopes": PortableBackupFormat.excludedScopes
        ]
        var records = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )
        records.append(0x0A)
        // 超过 1MiB 上限、无换行的巨行。
        records.append(Data(repeating: 0x61, count: 1_200_000))
        records.append(0x0A)

        let packageURL = rootURL.appendingPathComponent("bigline.oboe-backup")
        let writer = try StreamingZipWriter(fileURL: packageURL)
        try writer.beginEntry(name: "records.ndjson", method: .deflate)
        try writer.write(records)
        let recordsResult = try writer.finishEntry()
        try writer.beginEntry(name: "manifest.json", method: .deflate)
        try writer.write(makePackageManifest(attachments: []))
        _ = try writer.finishEntry()
        try writer.beginEntry(name: "checksums.json", method: .deflate)
        try writer.write(makeChecksumsJSON(
            files: ["records.ndjson": recordsResult.sha256]
        ))
        _ = try writer.finishEntry()
        try writer.finalizeArchive()

        let current = try OboeDatabase(path: currentDatabaseURL.path)
        defer { try? current.close() }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: preparationsURL
        )
        do {
            _ = try await preparer.preparePackage(fileURL: packageURL)
            XCTFail("应抛出 lineTooLarge")
        } catch PortableBackupPreparationError.lineTooLarge(let line, _) {
            XCTAssertEqual(line, 2)
        }
    }

    // MARK: - helpers

    private func assertNoPackagingLeftovers(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: exportsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let leftovers = contents.filter { url in
            let name = url.lastPathComponent
            // .export-snapshots 目录是导出基础设施（快照文件已按 defer 清掉）。
            guard name != ".export-snapshots" else { return false }
            return true
        }
        XCTAssertTrue(
            leftovers.isEmpty,
            "导出失败后工作目录残留：\(leftovers.map(\.lastPathComponent))",
            file: file,
            line: line
        )
    }

    private func seedDeck(into database: OboeDatabase) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, 0, 1, 2)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID()), "规模牌组"]
            )
        }
    }

    private func seedInboxItem(
        into database: OboeDatabase,
        imageReference: String
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        image_reference, created_at_ms, updated_at_ms
                    ) VALUES (?, '截图', 'manual', 'unprocessed', 1, ?, 1, 2)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    imageReference
                ]
            )
        }
    }

    /// 真实可解码 JPEG：伪随机噪声像素 → CGImage → JPEG 编码。
    /// 噪声不可压，单张 ~4MiB，多个文件各自合法且 ≤ 附件单条限额。
    static func makeNoisyJPEG(
        width: Int,
        height: Int,
        seed: UInt32 = 7
    ) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state = seed == 0 ? 1 : seed
        for index in pixels.indices {
            // xorshift32——比 SystemRandom 快且逐文件内容不同。
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            pixels[index] = UInt8(truncatingIfNeeded: state)
        }
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(pixels) as CFData)
        )
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makePackageManifest(
        attachments: [AttachmentDescriptor]
    ) throws -> Data {
        try PortableBackupPackageManifest(
            format: PortableBackupFormat.identifier,
            formatVersion: PortableBackupPackageFormat.formatVersion,
            container: PortableBackupPackageFormat.container,
            appVersion: "s04-scale",
            exportedAt: PortableBackupPackageFormat.iso8601String(
                from: exportedAt
            ),
            encoding: "utf-8",
            lineEnding: "lf",
            checksumAlgorithm: PortableBackupFormat.checksumAlgorithm,
            recordFormatVersion: 6,  // fixture 声明与其内嵌的 v6 记录流一致
            recordOrder: PortableBackupFormatV6.recordTypes,
            counts: Dictionary(
                uniqueKeysWithValues: PortableBackupFormatV6.recordTypes.map {
                    ($0, 0)
                }
            ),
            excludedScopes: PortableBackupPackageFormat.excludedScopes,
            attachments: attachments
        ).encoded()
    }

    private func makeChecksumsJSON(files: [String: String]) throws -> Data {
        try PortableBackupChecksums(
            algorithm: PortableBackupFormat.checksumAlgorithm,
            files: files
        ).encoded()
    }

    /// 当前进程 RSS。
    static func residentSize() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
        ) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}

/// 5ms 周期采样 RSS 取峰值。
private final class PeakRSSSampler: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private var lock = NSLock()
    private var peakValue: Int64 = 0

    func start() {
        lock.lock()
        peakValue = 0
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let current = StreamingBackupScaleTests.residentSize()
            self.lock.lock()
            self.peakValue = max(self.peakValue, current)
            self.lock.unlock()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }
}

/// FileHandle 短读字节源：单次 read 最多 maxReadCount 字节。
private final class ShortReadFileSource: StreamingZipByteSource {
    private let handle: FileHandle
    private let maxReadCount: Int
    let sizeInBytes: Int64

    init(fileURL: URL, maxReadCount: Int) throws {
        handle = try FileHandle(forReadingFrom: fileURL)
        sizeInBytes = Int64(try handle.seekToEnd())
        self.maxReadCount = maxReadCount
    }

    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        guard offset >= 0, maximumCount > 0, offset < sizeInBytes else {
            return Data()
        }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(
            upToCount: min(maximumCount, maxReadCount)
        ) ?? Data()
    }

    func close() {
        try? handle.close()
    }
}
