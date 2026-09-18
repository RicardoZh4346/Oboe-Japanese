import Foundation
import GRDB
import OboeDomain
import OboeSharedCapture
import XCTest
@testable import OboeInfrastructure

/// The consumer side of the shared-queue contract: receipt-guarded idempotent
/// import, same-ID-different-content quarantine, corrupt files never blocking
/// the queue, crash windows resolved by the receipt, and pause/resume for
/// database replacement.
final class CaptureImportCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureImportCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPendingEnvelopeImportsWithAllFieldsAndFileIsConsumed() async throws {
        let harness = try Harness(in: directory)
        let envelope = harness.envelope(
            text: "日本に行ったことがありますか。",
            action: .continueInApp,
            sourceApp: "com.example.reader",
            sourceURL: "https://example.com/article"
        )
        _ = try harness.store.publish(envelope)

        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.imported.count, 1)
        XCTAssertEqual(report.imported.first?.requestedAction, .continueInApp)
        XCTAssertEqual(report.alreadyImportedCount, 0)
        XCTAssertEqual(report.quarantinedCount, 0)
        XCTAssertFalse(report.containerUnavailable)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)

        let item = try await harness.inbox.fetchItem(id: envelope.captureID)
        XCTAssertEqual(item?.text, envelope.text)
        XCTAssertEqual(item?.sourceType, .share)
        XCTAssertEqual(item?.sourceApp, "com.example.reader")
        XCTAssertEqual(item?.sourceURL, "https://example.com/article")
        XCTAssertEqual(item?.status, .unprocessed)
        XCTAssertEqual(
            item?.createdAt.timeIntervalSince1970 ?? 0,
            envelope.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        let receipt = try await harness.repository.fetchImportReceipt(
            captureID: envelope.captureID
        )
        XCTAssertEqual(
            receipt?.payloadHash,
            try CaptureEnvelopeCodec.payloadHash(envelope)
        )
        XCTAssertEqual(receipt?.inboxItemID, envelope.captureID)
    }

    func testRepublishedEnvelopeIsAlreadyImportedWithoutDuplicates() async throws {
        let harness = try Harness(in: directory)
        let envelope = harness.envelope()
        _ = try harness.store.publish(envelope)
        _ = try await harness.coordinator.drainPendingCaptures()

        // Crash window: consumed-confirm interrupted — file republished.
        _ = try harness.store.publish(envelope)
        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.imported.count, 0)
        XCTAssertEqual(report.alreadyImportedCount, 1)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)

        let count = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    func testSameCaptureIDWithDifferentContentIsQuarantined() async throws {
        let harness = try Harness(in: directory)
        let original = harness.envelope(text: "原文")
        _ = try harness.store.publish(original)
        _ = try await harness.coordinator.drainPendingCaptures()

        // Forged/corrupted retry under the same captureID: hand-write the
        // conflicting file directly (publish() would refuse it correctly).
        let tampered = harness.envelope(id: original.captureID, text: "被改写的不同内容")
        try writeRawEnvelope(tampered, to: harness.pendingDirectory)

        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.imported.count, 0)
        XCTAssertEqual(report.quarantinedCount, 1)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)

        let item = try await harness.inbox.fetchItem(id: original.captureID)
        XCTAssertEqual(item?.text, "原文", "Original record must not be overwritten")
    }

    func testCorruptFileIsQuarantinedWithoutBlockingOthers() async throws {
        let harness = try Harness(in: directory)
        try FileManager.default.createDirectory(
            at: harness.pendingDirectory,
            withIntermediateDirectories: true
        )
        // Corrupt JSON sorts before the valid one by filename.
        try Data("{\"broken\":".utf8).write(
            to: harness.pendingDirectory.appendingPathComponent(
                "00000000-0000-0000-0000-000000000001.json"
            )
        )
        let valid = harness.envelope()
        _ = try harness.store.publish(valid)

        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.imported.count, 1)
        XCTAssertEqual(report.quarantinedCount, 1)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)
        let quarantined = try FileManager.default.contentsOfDirectory(
            atPath: harness.pendingDirectory
                .deletingLastPathComponent()
                .appendingPathComponent(CaptureQueueLayout.quarantineDirectoryName)
                .path
        )
        XCTAssertEqual(quarantined.count, 1)
    }

    func testUnknownVersionAndOversizedFilesAreQuarantined() async throws {
        let harness = try Harness(in: directory)
        try FileManager.default.createDirectory(
            at: harness.pendingDirectory,
            withIntermediateDirectories: true
        )
        var object = try JSONSerialization.jsonObject(
            with: CaptureEnvelopeCodec.encode(harness.envelope())
        ) as! [String: Any]
        object["schemaVersion"] = 99
        let versioned = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try versioned.write(
            to: harness.pendingDirectory.appendingPathComponent("future.oboe-json.json")
        )
        try Data(repeating: 0x20, count: 70 * 1_024).write(
            to: harness.pendingDirectory.appendingPathComponent("huge.json")
        )

        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.quarantinedCount, 2)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)
    }

    func testDeletedItemIsNotRecreatedByRepublishedFile() async throws {
        let harness = try Harness(in: directory)
        let envelope = harness.envelope()
        _ = try harness.store.publish(envelope)
        _ = try await harness.coordinator.drainPendingCaptures()
        try await harness.inbox.delete(id: envelope.captureID)

        _ = try harness.store.publish(envelope)
        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.alreadyImportedCount, 1)
        let refetched = try await harness.inbox.fetchItem(id: envelope.captureID)
        XCTAssertNil(refetched, "The import receipt must not resurrect a deleted item")
    }

    func testUnavailableContainerReportsHonestly() async throws {
        let harness = try Harness(in: directory)
        let coordinator = CaptureImportCoordinator(
            inboxService: harness.inbox,
            store: nil
        )
        let report = try await coordinator.drainPendingCaptures()
        XCTAssertTrue(report.containerUnavailable)
        XCTAssertTrue(report.imported.isEmpty)
    }

    func testPauseBlocksDrainAndResumeCompletesIt() async throws {
        let harness = try Harness(in: directory)
        _ = try harness.store.publish(harness.envelope())
        await harness.coordinator.pauseAndWait()

        var report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertEqual(try harness.store.pendingFileURLs().count, 1)

        await harness.coordinator.resume()
        report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.imported.count, 1)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)
    }

    func testPauseAndWaitLetsInFlightDrainFinish() async throws {
        let enumerationStarted = Flag()
        let harness = try Harness(
            in: directory,
            store: SlowStore(
                base: AppGroupCaptureStore(queueDirectoryURL: directory),
                enumerationDelay: 0.15,
                onEnumerate: { enumerationStarted.mark() }
            )
        )
        _ = try harness.store.publish(harness.envelope())

        async let drained = harness.coordinator.drainPendingCaptures()
        // Wait until the drain is definitely inside enumeration before
        // pausing — the pause must then wait for it to finish rather than
        // cutting it off.
        while !enumerationStarted.value {
            await Task.yield()
        }
        await harness.coordinator.pauseAndWait()
        let report = try await drained
        XCTAssertEqual(report.imported.count, 1)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)
        await harness.coordinator.resume()
    }

    func testConcurrentDrainsCoalesceIntoOneImportPass() async throws {
        let harness = try Harness(in: directory)
        let envelopes = (0..<4).map { _ in harness.envelope() }
        for envelope in envelopes {
            _ = try harness.store.publish(envelope)
        }
        async let first = harness.coordinator.drainPendingCaptures()
        async let second = harness.coordinator.drainPendingCaptures()
        async let third = harness.coordinator.drainPendingCaptures()
        let reports = try await [first, second, third]

        // Concurrent calls coalesce onto one in-flight task or run serially —
        // either way each capture lands exactly once.
        let importedIDs = Set(reports.flatMap(\.imported).map(\.itemID))
        XCTAssertEqual(importedIDs, Set(envelopes.map(\.captureID)))
        XCTAssertEqual(
            reports.filter(\.containerUnavailable).count, 0
        )
        let count = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? -1
        }
        XCTAssertEqual(count, 4)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)
    }

    func testConsumeFailureLeavesFileForNextDrain() async throws {
        let harness = try Harness(
            in: directory,
            store: FlakyConsumeStore(
                base: AppGroupCaptureStore(queueDirectoryURL: directory)
            )
        )
        let envelope = harness.envelope()
        _ = try harness.store.publish(envelope)

        // Commit succeeded but confirming consumption fails — the drain aborts
        // and the file stays for the next pass.
        (harness.store as! FlakyConsumeStore).failNextConsume = true
        do {
            _ = try await harness.coordinator.drainPendingCaptures()
            XCTFail("Consume failure must abort the drain")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try harness.store.pendingFileURLs().count, 1)

        let report = try await harness.coordinator.drainPendingCaptures()
        XCTAssertEqual(report.alreadyImportedCount, 1)
        XCTAssertTrue(try harness.store.pendingFileURLs().isEmpty)
        let count = try await harness.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Helpers

    private func writeRawEnvelope(
        _ envelope: CaptureEnvelope,
        to pendingDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: true
        )
        let data = try CaptureEnvelopeCodec.encode(envelope)
        try data.write(
            to: pendingDirectory.appendingPathComponent(
                envelope.captureID.uuidString.lowercased() + ".json"
            )
        )
    }
}

private extension CaptureImportCoordinatorTests {
    struct Harness {
        let database: OboeDatabase
        let repository: GRDBInboxRepository
        let inbox: InboxService
        let store: any CaptureQueueStoring
        let coordinator: CaptureImportCoordinator
        let pendingDirectory: URL

        /// `store` nil → a real `AppGroupCaptureStore` rooted at `directory`.
        init(in directory: URL, store: (any CaptureQueueStoring)? = nil) throws {
            database = try OboeDatabase(
                path: directory.appendingPathComponent("oboe.sqlite").path
            )
            repository = GRDBInboxRepository(database: database)
            inbox = InboxService(repository: repository)
            self.store = store ?? AppGroupCaptureStore(queueDirectoryURL: directory)
            coordinator = CaptureImportCoordinator(inboxService: inbox, store: self.store)
            pendingDirectory = directory
                .appendingPathComponent(CaptureQueueLayout.pendingDirectoryName)
        }

        func envelope(
            id: UUID = UUID(),
            text: String = "日本に行ったことがありますか。",
            action: CaptureRequestedAction = .save,
            sourceApp: String? = nil,
            sourceURL: String? = nil
        ) -> CaptureEnvelope {
            CaptureEnvelope(
                captureID: id,
                text: text,
                createdAt: Date(timeIntervalSince1970: 1_789_056_000),
                sourceApp: sourceApp,
                sourceURL: sourceURL,
                requestedAction: action
            )
        }
    }

    /// Thread-safe one-shot flag for observing when a store method began.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flagged = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flagged
        }

        func mark() {
            lock.lock()
            flagged = true
            lock.unlock()
        }
    }

    /// Delays enumeration so pause semantics can be observed deterministically.
    struct SlowStore: CaptureQueueStoring {
        let base: AppGroupCaptureStore
        let enumerationDelay: TimeInterval
        var onEnumerate: @Sendable () -> Void = {}

        func publish(_ envelope: CaptureEnvelope) throws -> URL {
            return try base.publish(envelope)
        }

        func pendingFileURLs() throws -> [URL] {
            onEnumerate()
            Thread.sleep(forTimeInterval: enumerationDelay)
            return try base.pendingFileURLs()
        }

        func consume(_ fileURL: URL) throws {
            try base.consume(fileURL)
        }

        func quarantine(_ fileURL: URL) throws -> URL {
            try base.quarantine(fileURL)
        }
    }

    /// Fails the next consume to simulate the post-commit/pre-confirm window.
    final class FlakyConsumeStore: CaptureQueueStoring, @unchecked Sendable {
        let base: AppGroupCaptureStore
        var failNextConsume = false

        init(base: AppGroupCaptureStore) {
            self.base = base
        }

        func publish(_ envelope: CaptureEnvelope) throws -> URL {
            return try base.publish(envelope)
        }

        func pendingFileURLs() throws -> [URL] {
            try base.pendingFileURLs()
        }

        func consume(_ fileURL: URL) throws {
            if failNextConsume {
                failNextConsume = false
                throw CocoaError(.fileWriteUnknown)
            }
            try base.consume(fileURL)
        }

        func quarantine(_ fileURL: URL) throws -> URL {
            try base.quarantine(fileURL)
        }
    }
}
