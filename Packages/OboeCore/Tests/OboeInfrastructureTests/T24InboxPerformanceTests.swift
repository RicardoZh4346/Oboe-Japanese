import Foundation
import GRDB
import ImageIO
import OboeDomain
import OboeSharedCapture
import UniformTypeIdentifiers
import XCTest
@testable import OboeInfrastructure

/// T24 release-gate performance run for the v0.3 capture surface: long Inbox
/// lists, pagination, search, capture inserts, large-image validation and
/// pending-queue drain. Numbers print even when assertions pass so the plan
/// can record real measurements rather than assumed budgets.
/// Run with `OBOE_RUN_T24_PERFORMANCE=1`.
final class T24InboxPerformanceTests: XCTestCase {
    func testInboxSurfaceMeetsReleasePerformanceTargets() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OBOE_RUN_T24_PERFORMANCE"] == "1",
            "Set OBOE_RUN_T24_PERFORMANCE=1 for the release performance run."
        )

        let fixture = try T24InboxFixture(itemCount: 5_000)
        defer { fixture.remove() }
        try await fixture.seed()
        print("T24_DATASET=inbox_items:\(fixture.itemCount)")

        let service = InboxService(repository: fixture.repository)

        // First page of a 5k-item Inbox.
        _ = try await service.fetchPage()
        let firstPageP95 = try await Self.percentile95(samples: 20) {
            let page = try await service.fetchPage()
            XCTAssertEqual(page.items.count, InboxService.pageSize)
        }

        // Deep pagination — page 50 of 100, the worst offset a user can reach.
        var cursor: InboxPageCursor?
        for _ in 0..<49 {
            cursor = try await service.fetchPage(cursor: cursor).nextCursor
        }
        let deepPageP95 = try await Self.percentile95(samples: 20) {
            let page = try await service.fetchPage(cursor: cursor)
            XCTAssertFalse(page.items.isEmpty)
        }

        // Search over the whole 5k-item set.
        _ = try await service.fetchPage(query: "性能針")
        let searchP95 = try await Self.percentile95(samples: 20) {
            let page = try await service.fetchPage(query: "性能針")
            XCTAssertEqual(page.items.count, 1)
        }

        // Capture insert cost on top of the populated table.
        let captureInsertP95 = try await Self.percentile95(samples: 20) {
            _ = try await service.capture(text: "追加の計測対象テキスト。", sourceType: .manual)
        }

        // Large image: 24 MP JPEG through validation + preview re-encode.
        let largeJPEG = T24TestImage.makeJPEG(width: 6_000, height: 4_000)
        print("T24_IMAGE_BYTES=\(largeJPEG.count)")
        _ = try InboxImageValidator.inspect(data: largeJPEG)
        let imageValidateP95 = try Self.percentile95Sync(samples: 5) {
            _ = try InboxImageValidator.inspect(data: largeJPEG)
        }
        let imagePreviewP95 = try Self.percentile95Sync(samples: 5) {
            _ = try InboxImageValidator.makePreviewJPEG(data: largeJPEG)
        }

        // Startup import: 50 pending share envelopes drain in one pass.
        let drainStart = ContinuousClock.now
        let drainCount = 50
        for index in 0..<drainCount {
            _ = try fixture.queueStore.publish(
                CaptureEnvelope(
                    captureID: UUID(),
                    text: "起動時取り込み計測 \(index) 番目の共有テキスト。",
                    createdAt: Date(timeIntervalSince1970: 1_768_000_000 + Double(index))
                )
            )
        }
        let coordinator = CaptureImportCoordinator(
            inboxService: service,
            store: fixture.queueStore
        )
        let report = try await coordinator.drainPendingCaptures()
        let drainTotal = Self.seconds(since: drainStart)
        XCTAssertEqual(report.imported.count, drainCount)
        XCTAssertEqual(report.quarantinedCount, 0)

        Self.printMetric("T24_INBOX_FIRST_PAGE_P95_MS", firstPageP95)
        Self.printMetric("T24_INBOX_DEEP_PAGE_P95_MS", deepPageP95)
        Self.printMetric("T24_INBOX_SEARCH_P95_MS", searchP95)
        Self.printMetric("T24_CAPTURE_INSERT_P95_MS", captureInsertP95)
        Self.printMetric("T24_IMAGE_24MP_VALIDATE_P95_MS", imageValidateP95)
        Self.printMetric("T24_IMAGE_24MP_PREVIEW_P95_MS", imagePreviewP95)
        Self.printMetric("T24_DRAIN_50_TOTAL_MS", drainTotal)

        // Release budgets — generous on purpose; the printed numbers are the
        // real record, budgets only catch order-of-magnitude regressions.
        XCTAssertLessThan(firstPageP95, 0.15)
        XCTAssertLessThan(deepPageP95, 0.15)
        XCTAssertLessThan(searchP95, 0.3)
        XCTAssertLessThan(captureInsertP95, 0.05)
        XCTAssertLessThan(imageValidateP95, 0.5)
        XCTAssertLessThan(imagePreviewP95, 2.0)
        XCTAssertLessThan(drainTotal, 5.0)
    }
}

private struct T24InboxFixture {
    let directoryURL: URL
    let databaseURL: URL
    let queueDirectoryURL: URL
    let database: OboeDatabase
    let repository: GRDBInboxRepository
    let queueStore: AppGroupCaptureStore
    let itemCount: Int

    init(itemCount: Int) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("T24InboxPerformance-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        queueDirectoryURL = directoryURL.appendingPathComponent("queue", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        database = try OboeDatabase(path: databaseURL.path)
        repository = GRDBInboxRepository(database: database)
        queueStore = AppGroupCaptureStore(queueDirectoryURL: queueDirectoryURL)
        self.itemCount = itemCount
    }

    /// Direct repository inserts — seeding speed matters less than using the
    /// same write path production uses.
    func seed() async throws {
        let base = Date(timeIntervalSince1970: 1_768_000_000)
        for index in 0..<itemCount {
            let item = InboxItem(
                id: UUID(),
                text: "計測用の収集テキスト \(index) 番目です。",
                sourceType: index.isMultiple(of: 10) ? .share : .manual,
                status: .unprocessed,
                contentRevision: 1,
                sourceApp: index.isMultiple(of: 10) ? "Safari" : nil,
                sourceURL: nil,
                imageReference: nil,
                createdAt: base.addingTimeInterval(Double(index)),
                updatedAt: base.addingTimeInterval(Double(index)),
                processedAt: nil,
                archivedAt: nil,
                statusBeforeArchive: nil
            )
            try await repository.insertItem(item)
        }
        // One searchable needle among 5k rows.
        try await repository.insertItem(
            InboxItem(
                id: UUID(),
                text: "この行だけが性能針を含みます。",
                sourceType: .manual,
                status: .unprocessed,
                contentRevision: 1,
                sourceApp: nil,
                sourceURL: nil,
                imageReference: nil,
                createdAt: base.addingTimeInterval(-1),
                updatedAt: base.addingTimeInterval(-1),
                processedAt: nil,
                archivedAt: nil,
                statusBeforeArchive: nil
            )
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum T24TestImage {
    static func makeJPEG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            fatalError("无法生成测试图片")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Noise strip so the JPEG does not collapse to a trivial encode.
        for x in stride(from: 0, to: width, by: 40) {
            context.setFillColor(
                red: CGFloat(x % 255) / 255, green: 0.4, blue: 0.6, alpha: 1
            )
            context.fill(CGRect(x: x, y: 0, width: 20, height: height))
        }
        guard let drawn = context.makeImage() else {
            fatalError("无法生成测试图片")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            fatalError("无法创建 JPEG 目标")
        }
        CGImageDestinationAddImage(destination, drawn, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private extension T24InboxPerformanceTests {
    static func percentile95(
        samples: Int,
        _ body: () async throws -> Void
    ) async throws -> TimeInterval {
        var durations: [TimeInterval] = []
        for _ in 0..<samples {
            let started = ContinuousClock.now
            try await body()
            durations.append(seconds(since: started))
        }
        return percentile95(durations)
    }

    static func percentile95Sync(
        samples: Int,
        _ body: () throws -> Void
    ) throws -> TimeInterval {
        var durations: [TimeInterval] = []
        for _ in 0..<samples {
            let started = ContinuousClock.now
            try body()
            durations.append(seconds(since: started))
        }
        return percentile95(durations)
    }

    static func percentile95(_ durations: [TimeInterval]) -> TimeInterval {
        let sorted = durations.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.95)]
    }

    static func seconds(since started: ContinuousClock.Instant) -> TimeInterval {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    static func printMetric(_ name: String, _ seconds: TimeInterval) {
        print("\(name)=\(String(format: "%.1f", seconds * 1_000))")
    }
}
