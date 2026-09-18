import Foundation

/// File-queue layout shared by the share extension (producer) and the main
/// app (consumer). Publishing writes a uniquely named temp file inside the
/// same directory and then renames it into `pending/` — the rename is atomic
/// on the same filesystem, so consumers never observe a partial envelope.
///
///     CaptureQueue/
///         pending/<captureID>.json     published, awaiting import
///         quarantine/<captureID>.json  malformed/conflicting, kept for review
///         .write-<uuid>.tmp            in-flight producer writes (ignored)
public enum CaptureQueueLayout {
    public static let directoryName = "CaptureQueue"
    public static let pendingDirectoryName = "pending"
    public static let quarantineDirectoryName = "quarantine"
    public static let temporaryPrefix = ".write-"
    public static let temporarySuffix = ".tmp"
    public static let envelopeFileExtension = "json"

    /// The App Group both processes must share. Resolved from the host
    /// bundle's `OboeAppGroupIdentifier` Info.plist key so a self-signed
    /// build can point at the signer's own group without a source change;
    /// the project default applies when the key is absent.
    public static var appGroupIdentifier: String {
        guard let configured = Bundle.main.object(
            forInfoDictionaryKey: "OboeAppGroupIdentifier"
        ) as? String, !configured.isEmpty else {
            return "group.org.example.Oboe"
        }
        return configured
    }

    /// Files are needed for cold-start import after first unlock, but must not
    /// be readable while the device has never been unlocked.
    public static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication
}

public enum CaptureStoreError: Error, Equatable, Sendable {
    case containerUnavailable
    case notAPendingFile(String)
    case publishConflict(captureID: UUID)
}

public protocol CaptureQueueStoring: Sendable {
    func publish(_ envelope: CaptureEnvelope) throws -> URL
    func pendingFileURLs() throws -> [URL]
    func consume(_ fileURL: URL) throws
    func quarantine(_ fileURL: URL) throws -> URL
}

public struct AppGroupCaptureStore: CaptureQueueStoring {
    public let queueDirectoryURL: URL

    /// Resolves the shared App Group container; returns nil when the app lacks
    /// the entitlement so callers can report "unavailable" honestly instead
    /// of silently writing into a private directory. When the exact group is
    /// not granted, profile-allowed variants carrying it as a prefix are
    /// tried — personal-team signing grants `<requested>.<TeamID>` instead
    /// of the literal identifier.
    public init?(applicationGroupIdentifier: String = CaptureQueueLayout.appGroupIdentifier) {
        for candidate in Self.groupCandidates(applicationGroupIdentifier) {
            if let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: candidate
            ) {
                queueDirectoryURL = container.appendingPathComponent(
                    CaptureQueueLayout.directoryName,
                    isDirectory: true
                )
                return
            }
        }
        return nil
    }

    /// The requested group first, then any profile-allowed group named after
    /// it (`<requested>.<suffix>`). Candidates come from the bundle's own
    /// embedded profile, so they are this signing identity's groups.
    static func groupCandidates(
        _ requested: String,
        allowed: [String]? = SigningDiagnostics.profileAllowedAppGroups()
    ) -> [String] {
        var candidates = [requested]
        for group in allowed ?? [] where group != requested
            && group.hasPrefix(requested + ".") {
            candidates.append(group)
        }
        return candidates
    }

    /// Direct-directory initializer — used by tests and the app when an
    /// explicit queue directory is configured (e.g. UI-test overrides).
    public init(queueDirectoryURL: URL) {
        self.queueDirectoryURL = queueDirectoryURL
    }

    public func publish(_ envelope: CaptureEnvelope) throws -> URL {
        let data = try CaptureEnvelopeCodec.encode(envelope)
        try createQueueDirectories()

        let temporaryURL = queueDirectoryURL.appendingPathComponent(
            CaptureQueueLayout.temporaryPrefix
                + UUID().uuidString.lowercased()
                + CaptureQueueLayout.temporarySuffix
        )
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        try applyFileProtection(at: temporaryURL)

        let pendingURL = pendingDirectoryURL.appendingPathComponent(
            envelope.captureID.uuidString.lowercased()
                + "." + CaptureQueueLayout.envelopeFileExtension
        )
        if let existing = try? Data(contentsOf: pendingURL) {
            // A retry of the same confirmation reuses the captureID — identical
            // bytes mean the file is already queued, so publish is a no-op
            // success. Different bytes under the same ID is a real anomaly and
            // must not silently overwrite the queued original.
            try? FileManager.default.removeItem(at: temporaryURL)
            guard existing == data else {
                throw CaptureStoreError.publishConflict(
                    captureID: envelope.captureID
                )
            }
            return pendingURL
        }
        try FileManager.default.moveItem(at: temporaryURL, to: pendingURL)
        return pendingURL
    }

    /// Published envelopes only — temp files and anything non-JSON are
    /// ignored by name, never parsed. Deterministic order (filename).
    public func pendingFileURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: pendingDirectoryURL.path) else {
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: pendingDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == CaptureQueueLayout.envelopeFileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func consume(_ fileURL: URL) throws {
        // Enumerated URLs resolve symlinks (/var → /private/var on macOS) while
        // queueDirectoryURL keeps the configured form — compare resolved paths.
        guard fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == pendingDirectoryURL.resolvingSymlinksInPath().path else {
            throw CaptureStoreError.notAPendingFile(fileURL.lastPathComponent)
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    public func quarantine(_ fileURL: URL) throws -> URL {
        try createQueueDirectories()
        var candidate = quarantineDirectoryURL.appendingPathComponent(
            fileURL.lastPathComponent
        )
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = quarantineDirectoryURL.appendingPathComponent(
                fileURL.deletingPathExtension().lastPathComponent
                    + "-\(counter)."
                    + CaptureQueueLayout.envelopeFileExtension
            )
            counter += 1
        }
        try FileManager.default.moveItem(at: fileURL, to: candidate)
        return candidate
    }

    private var pendingDirectoryURL: URL {
        queueDirectoryURL.appendingPathComponent(
            CaptureQueueLayout.pendingDirectoryName,
            isDirectory: true
        )
    }

    private var quarantineDirectoryURL: URL {
        queueDirectoryURL.appendingPathComponent(
            CaptureQueueLayout.quarantineDirectoryName,
            isDirectory: true
        )
    }

    private func createQueueDirectories() throws {
        for url in [queueDirectoryURL, pendingDirectoryURL, quarantineDirectoryURL] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            try applyFileProtection(at: url)
        }
    }

    private func applyFileProtection(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: CaptureQueueLayout.fileProtection],
            ofItemAtPath: url.path
        )
    }
}
