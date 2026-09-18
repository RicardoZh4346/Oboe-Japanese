import Foundation
import OboeDomain
import OboeSharedCapture

public struct ImportedCapture: Equatable, Sendable {
    public let itemID: UUID
    public let requestedAction: CaptureRequestedAction

    public init(itemID: UUID, requestedAction: CaptureRequestedAction) {
        self.itemID = itemID
        self.requestedAction = requestedAction
    }
}

/// Per-drain outcome. Per-file failures are quarantined and counted rather
/// than thrown — one corrupt envelope must not block the rest of the queue.
/// Infrastructure failures (enumeration, database) still throw so the caller
/// can retry the whole drain later.
public struct CaptureImportReport: Equatable, Sendable {
    public var imported: [ImportedCapture] = []
    public var alreadyImportedCount = 0
    public var quarantinedCount = 0
    public var containerUnavailable = false

    public init() {}
}

/// Serializes shared-queue consumption behind one actor. Triggers (cold
/// start, foreground, entering the Inbox) are hints — the pending directory
/// is the source of truth, so duplicate drains coalesce onto one run.
public actor CaptureImportCoordinator {
    private let inboxService: InboxService
    private let store: (any CaptureQueueStoring)?
    private var drainTask: Task<CaptureImportReport, Error>?
    private var paused = false

    /// A nil store means the shared container is unavailable (no App Group
    /// entitlement, e.g. unsigned builds) — drains report that honestly
    /// instead of failing or silently writing elsewhere.
    public init(inboxService: InboxService, store: (any CaptureQueueStoring)?) {
        self.inboxService = inboxService
        self.store = store
    }

    public func drainPendingCaptures() async throws -> CaptureImportReport {
        if let active = drainTask {
            return try await active.value
        }
        guard !paused, let store else {
            var report = CaptureImportReport()
            report.containerUnavailable = store == nil
            return report
        }
        let task = Task { [inboxService, store] in
            try await Self.performDrain(inboxService: inboxService, store: store)
        }
        drainTask = task
        defer { drainTask = nil }
        return try await task.value
    }

    /// Restoration pauses imports before the database is swapped. In-flight
    /// work finishes first; new drains after resume see only the files that
    /// were still pending at the boundary.
    public func pauseAndWait() async {
        paused = true
        _ = try? await drainTask?.value
    }

    public func resume() {
        paused = false
    }

    /// Pending file count without consuming — used after a restore boundary
    /// to surface "shares arrived but not yet imported" for user choice.
    /// nil when the shared container is unavailable.
    public func pendingFileCount() async -> Int? {
        guard let store else { return nil }
        return try? store.pendingFileURLs().count
    }

    private static func performDrain(
        inboxService: InboxService,
        store: any CaptureQueueStoring
    ) async throws -> CaptureImportReport {
        var report = CaptureImportReport()
        for fileURL in try store.pendingFileURLs() {
            guard !Task.isCancelled else { break }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                if (try? store.quarantine(fileURL)) != nil {
                    report.quarantinedCount += 1
                }
                continue
            }
            let envelope: CaptureEnvelope
            do {
                envelope = try CaptureEnvelopeCodec.decode(data)
            } catch {
                if (try? store.quarantine(fileURL)) != nil {
                    report.quarantinedCount += 1
                }
                continue
            }
            do {
                let result = try await inboxService.importCapture(
                    captureID: envelope.captureID,
                    text: envelope.text,
                    sourceType: .share,
                    sourceApp: envelope.sourceApp,
                    sourceURL: envelope.sourceURL,
                    payloadHash: CaptureEnvelopeCodec.payloadHash(envelope),
                    capturedAt: envelope.createdAt
                )
                switch result {
                case let .imported(item):
                    report.imported.append(
                        ImportedCapture(
                            itemID: item.id,
                            requestedAction: envelope.requestedAction
                        )
                    )
                case .alreadyImported:
                    report.alreadyImportedCount += 1
                }
                try store.consume(fileURL)
            } catch is InboxError {
                // Same captureID with a different digest is a real conflict —
                // quarantine the file instead of overwriting the original.
                if (try? store.quarantine(fileURL)) != nil {
                    report.quarantinedCount += 1
                }
            }
        }
        return report
    }
}
