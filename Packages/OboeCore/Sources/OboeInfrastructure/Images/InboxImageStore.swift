import Foundation

/// A stored local image attachment. `id` is the opaque resource ID persisted
/// in `inbox_items.image_reference` — never a filesystem path.
public struct InboxImageResource: Sendable, Equatable {
    public let id: String
    public let format: InboxImageInfo.Format
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Stored preview byte count (re-encoded JPEG).
    public let storedByteCount: Int

    public init(
        id: String,
        format: InboxImageInfo.Format,
        pixelWidth: Int,
        pixelHeight: Int,
        storedByteCount: Int
    ) {
        self.id = id
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.storedByteCount = storedByteCount
    }
}

/// Controlled local storage for Inbox image attachments. Resources live in a
/// dedicated directory keyed by an app-generated ID matching the backup
/// contract ([A-Za-z0-9_-]{1,128}); previews are re-encoded JPEGs with EXIF
/// stripped. Imports write a unique temporary file then rename atomically.
public struct InboxImageStore: Sendable {
    private let rootDirectoryURL: URL
    private let limits: InboxImageLimits
    private let makeID: @Sendable () -> UUID

    public init(
        rootDirectoryURL: URL,
        limits: InboxImageLimits = InboxImageLimits(),
        makeID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.limits = limits
        self.makeID = makeID
    }

    /// Validates the source bytes, normalizes orientation and size into a
    /// re-encoded JPEG preview, and publishes it under a fresh resource ID.
    public func importImage(data: Data) throws -> InboxImageResource {
        let info = try InboxImageValidator.inspect(data: data, limits: limits)
        let preview = try InboxImageValidator.makePreviewJPEG(
            data: data,
            limits: limits
        )
        let resourceID = makeID().uuidString.lowercased()
        try ensureRootDirectory()
        let finalURL = rootDirectoryURL.appendingPathComponent(
            "\(resourceID).jpg",
            isDirectory: false
        )
        let temporaryURL = rootDirectoryURL.appendingPathComponent(
            ".tmp-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try preview.write(
                to: temporaryURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            _ = try FileManager.default.replaceItemAt(
                finalURL,
                withItemAt: temporaryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw InboxImageError.storageFailure
        }
        return InboxImageResource(
            id: resourceID,
            format: info.format,
            pixelWidth: info.pixelWidth,
            pixelHeight: info.pixelHeight,
            storedByteCount: preview.count
        )
    }

    /// URL of the stored preview for a well-formed resource ID. The ID is
    /// validated before touching the file system — references are opaque
    /// resources, never paths, so traversal cannot resolve outside the root.
    public func fileURL(for resourceID: String) throws -> URL {
        try Self.validateResourceID(resourceID)
        return rootDirectoryURL.appendingPathComponent(
            "\(resourceID).jpg",
            isDirectory: false
        )
    }

    public func exists(_ resourceID: String) -> Bool {
        guard let url = try? fileURL(for: resourceID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func loadPreviewData(for resourceID: String) throws -> Data {
        try Data(contentsOf: fileURL(for: resourceID))
    }

    /// Removes the stored file. Missing files are not an error — deletion is
    /// used both for orphan cleanup and unreferenced-attachment cleanup.
    public func delete(_ resourceID: String) throws {
        let url = try fileURL(for: resourceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw InboxImageError.storageFailure
        }
    }

    /// Stored resource IDs not present in `referenced` — candidates for
    /// deferred cleanup (abandoned picks, removed Inbox items). Temporary
    /// import files are ignored, and files younger than `minimumAge` are
    /// skipped so a just-written resource is never swept underneath an
    /// in-flight attach.
    public func orphanedResourceIDs(
        keeping referenced: Set<String>,
        olderThan minimumAge: TimeInterval = 0
    ) throws -> [String] {
        guard FileManager.default.fileExists(atPath: rootDirectoryURL.path) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-minimumAge)
        let files = try FileManager.default.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey]
        )
        return files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".jpg"), !name.hasPrefix(".") else { return nil }
            let resourceID = String(name.dropLast(4))
            guard !referenced.contains(resourceID) else { return nil }
            if minimumAge > 0,
               let created = try? url.resourceValues(forKeys: [.creationDateKey])
                   .creationDate,
               created > cutoff {
                return nil
            }
            return resourceID
        }
    }

    /// Same contract the backup restorer enforces on `image_reference`:
    /// [A-Za-z0-9_-]{1,128} — reject anything that could address the file
    /// system (separators, traversal, dots).
    public static func validateResourceID(_ value: String) throws {
        guard value.count <= 128, !value.isEmpty,
              value.allSatisfy({ character in
                  character == "-" || character == "_"
                      || ("a"..."z").contains(character)
                      || ("A"..."Z").contains(character)
                      || ("0"..."9").contains(character)
              }) else {
            throw InboxImageError.unsupportedFormat
        }
    }

    private func ensureRootDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: rootDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw InboxImageError.storageFailure
        }
    }
}
