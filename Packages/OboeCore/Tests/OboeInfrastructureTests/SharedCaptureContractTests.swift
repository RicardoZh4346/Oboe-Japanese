import Foundation
import XCTest
@testable import OboeSharedCapture

/// The wire contract between producer (share extension) and consumer (main
/// app): canonical encoding, strict field validation, deterministic payload
/// hash, atomic publish into pending/, and filename-filtered enumeration.
final class SharedCaptureContractTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedCaptureContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEnvelope(
        id: UUID = UUID(),
        text: String = "日本に行ったことがありますか。",
        action: CaptureRequestedAction = .save,
        sourceApp: String? = "com.example.reader",
        sourceURL: String? = "https://example.com/article"
    ) -> CaptureEnvelope {
        CaptureEnvelope(
            captureID: id,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_789_056_000.5),
            sourceApp: sourceApp,
            sourceURL: sourceURL,
            requestedAction: action
        )
    }

    // MARK: - Envelope codec

    func testEnvelopeRoundTripPreservesAllFields() throws {
        let envelope = makeEnvelope(action: .continueInApp)
        let data = try CaptureEnvelopeCodec.encode(envelope)
        let decoded = try CaptureEnvelopeCodec.decode(data)
        XCTAssertEqual(decoded.captureID, envelope.captureID)
        XCTAssertEqual(decoded.text, envelope.text)
        XCTAssertEqual(decoded.sourceType, "share")
        XCTAssertEqual(decoded.sourceApp, envelope.sourceApp)
        XCTAssertEqual(decoded.sourceURL, envelope.sourceURL)
        XCTAssertEqual(decoded.requestedAction, .continueInApp)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            envelope.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testPayloadHashIsDeterministicAcrossEncodes() throws {
        let envelope = makeEnvelope()
        let first = try CaptureEnvelopeCodec.payloadHash(envelope)
        let second = try CaptureEnvelopeCodec.payloadHash(envelope)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
    }

    func testTextLimitsAndRequiredFields() throws {
        XCTAssertNoThrow(try CaptureEnvelopeCodec.encode(
            makeEnvelope(text: String(repeating: "あ", count: 1_000))
        ))
        XCTAssertThrowsError(try CaptureEnvelopeCodec.encode(
            makeEnvelope(text: String(repeating: "あ", count: 1_001))
        )) { error in
            XCTAssertEqual(error as? CaptureEnvelopeError, .textTooLong(maximumCharacters: 1_000))
        }
        XCTAssertThrowsError(try CaptureEnvelopeCodec.encode(makeEnvelope(text: "   \n"))) { error in
            XCTAssertEqual(error as? CaptureEnvelopeError, .emptyText)
        }
    }

    func testSourceURLMustBeWebURL() throws {
        XCTAssertNoThrow(try CaptureEnvelopeCodec.encode(
            makeEnvelope(sourceURL: "HTTPS://Example.com/Path")
        ))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "not a url", ""] {
            XCTAssertThrowsError(try CaptureEnvelopeCodec.encode(
                makeEnvelope(sourceURL: bad)
            )) { error in
                guard case .invalidField = error as? CaptureEnvelopeError else {
                    return XCTFail("Expected invalidField for \(bad), got \(error)")
                }
            }
        }
    }

    func testOversizedDataFailsBeforeDecoding() throws {
        let oversized = Data(repeating: 0x20, count: 70 * 1_024)
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(oversized)) { error in
            XCTAssertEqual(
                error as? CaptureEnvelopeError,
                .envelopeTooLarge(maximumBytes: 64 * 1_024)
            )
        }
    }

    func testUnknownSchemaVersionIsRejected() throws {
        var object = try JSONSerialization.jsonObject(
            with: CaptureEnvelopeCodec.encode(makeEnvelope())
        ) as! [String: Any]
        object["schemaVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(data)) { error in
            XCTAssertEqual(error as? CaptureEnvelopeError, .unsupportedSchemaVersion(99))
        }
    }

    func testMalformedWireFieldsAreRejected() throws {
        func mutated(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(
                with: CaptureEnvelopeCodec.encode(makeEnvelope())
            ) as! [String: Any]
            mutate(&object)
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        // Non-canonical captureID
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(
            mutated { $0["captureID"] = "not-a-uuid" }
        )) { XCTAssertTrue($0 is CaptureEnvelopeError) }
        // Uppercase UUID is not the canonical producer form
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(
            mutated { $0["captureID"] = UUID().uuidString }
        )) { XCTAssertTrue($0 is CaptureEnvelopeError) }
        // Unknown action must not silently degrade to .save
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(
            mutated { $0["requestedAction"] = "launchSomething" }
        )) { XCTAssertTrue($0 is CaptureEnvelopeError) }
        // Non-share source type
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(
            mutated { $0["sourceType"] = "ocr" }
        )) { error in
            XCTAssertEqual(
                error as? CaptureEnvelopeError,
                .unsupportedSourceType("ocr")
            )
        }
        XCTAssertThrowsError(try CaptureEnvelopeCodec.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? CaptureEnvelopeError, .invalidJSON)
        }
    }

    // MARK: - Store

    func testPublishWritesAtomicallyIntoPending() throws {
        let store = AppGroupCaptureStore(queueDirectoryURL: directory)
        let envelope = makeEnvelope()
        let url = try store.publish(envelope)

        XCTAssertEqual(
            url.deletingLastPathComponent().lastPathComponent,
            CaptureQueueLayout.pendingDirectoryName
        )
        XCTAssertEqual(
            url.lastPathComponent,
            envelope.captureID.uuidString.lowercased() + ".json"
        )
        // No temp files left behind in the queue directory.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(CaptureQueueLayout.temporaryPrefix) }
        XCTAssertTrue(leftovers.isEmpty)
        let decoded = try CaptureEnvelopeCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(decoded.captureID, envelope.captureID)
    }

    func testPublishRetryWithIdenticalBytesIsIdempotent() throws {
        let store = AppGroupCaptureStore(queueDirectoryURL: directory)
        let envelope = makeEnvelope()
        let first = try store.publish(envelope)
        let second = try store.publish(envelope)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.pendingFileURLs().count, 1)
    }

    func testPublishSameIDWithDifferentBytesConflicts() throws {
        let store = AppGroupCaptureStore(queueDirectoryURL: directory)
        let id = UUID()
        _ = try store.publish(makeEnvelope(id: id, text: "原文"))
        XCTAssertThrowsError(try store.publish(makeEnvelope(id: id, text: "被改写"))) { error in
            XCTAssertEqual(
                error as? CaptureStoreError,
                .publishConflict(captureID: id)
            )
        }
        // The original stays queued — never silently overwritten.
        let pending = try XCTUnwrap(try store.pendingFileURLs().first)
        let decoded = try CaptureEnvelopeCodec.decode(Data(contentsOf: pending))
        XCTAssertEqual(decoded.text, "原文")
    }

    func testPendingEnumerationIgnoresTempAndNonJSONFiles() throws {
        let store = AppGroupCaptureStore(queueDirectoryURL: directory)
        let envelope = makeEnvelope()
        _ = try store.publish(envelope)
        // Stray temp file from an interrupted write, plus non-envelope junk.
        try Data("partial".utf8).write(
            to: directory.appendingPathComponent(
                CaptureQueueLayout.pendingDirectoryName
            ).appendingPathComponent(".write-deadbeef.tmp")
        )
        try Data("junk".utf8).write(
            to: directory.appendingPathComponent(
                CaptureQueueLayout.pendingDirectoryName
            ).appendingPathComponent("notes.txt")
        )
        let pending = try store.pendingFileURLs()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.lastPathComponent.contains(".tmp"), false)
    }

    func testQuarantineMovesAndDeduplicates() throws {
        let store = AppGroupCaptureStore(queueDirectoryURL: directory)
        let first = try store.publish(makeEnvelope())
        let quarantined = try store.quarantine(first)
        XCTAssertEqual(
            quarantined.deletingLastPathComponent().lastPathComponent,
            CaptureQueueLayout.quarantineDirectoryName
        )
        XCTAssertTrue(try store.pendingFileURLs().isEmpty)
        // A second quarantine with the same filename gets a suffix.
        let second = try store.publish(makeEnvelope())
        let secondQuarantined = try store.quarantine(second)
        XCTAssertNotEqual(quarantined, secondQuarantined)
    }

    func testConsumeOnlyDeletesPendingFiles() throws {
        let store = AppGroupCaptureStore(queueDirectoryURL: directory)
        let url = try store.publish(makeEnvelope())
        try store.consume(url)
        XCTAssertTrue(try store.pendingFileURLs().isEmpty)
        XCTAssertThrowsError(try store.consume(
            directory.appendingPathComponent("elsewhere.json")
        )) { error in
            guard case .notAPendingFile = error as? CaptureStoreError else {
                return XCTFail("Expected notAPendingFile, got \(error)")
            }
        }
    }
}
