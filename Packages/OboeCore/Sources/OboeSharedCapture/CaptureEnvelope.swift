import CryptoKit
import Foundation

/// What the user asked the share sheet to do. `save` lands the text in the
/// Inbox; `continueInApp` additionally asks the main app to offer a
/// continue-processing entry when it next activates.
public enum CaptureRequestedAction: String, Codable, Sendable {
    case save
    case continueInApp
}

/// Versioned transfer contract between the share extension and the main app.
/// One user confirmation produces one `captureID`; retries of the same
/// confirmation reuse it, while sharing the same text again is a new capture.
public struct CaptureEnvelope: Equatable, Sendable {
    public let schemaVersion: Int
    public let captureID: UUID
    public let text: String
    public let createdAt: Date
    public let sourceType: String
    public let sourceApp: String?
    public let sourceURL: String?
    public let requestedAction: CaptureRequestedAction

    public init(
        captureID: UUID,
        text: String,
        createdAt: Date,
        sourceApp: String? = nil,
        sourceURL: String? = nil,
        requestedAction: CaptureRequestedAction = .save
    ) {
        self.schemaVersion = CaptureEnvelopeFormat.currentSchemaVersion
        self.captureID = captureID
        self.text = text
        self.createdAt = createdAt
        self.sourceType = CaptureEnvelopeFormat.shareSourceType
        self.sourceApp = sourceApp
        self.sourceURL = sourceURL
        self.requestedAction = requestedAction
    }

    /// Decoder path — producers always go through the public init, which pins
    /// schemaVersion/sourceType; only the codec reconstructs all fields.
    init(
        schemaVersion: Int,
        captureID: UUID,
        text: String,
        createdAt: Date,
        sourceType: String,
        sourceApp: String?,
        sourceURL: String?,
        requestedAction: CaptureRequestedAction
    ) {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.text = text
        self.createdAt = createdAt
        self.sourceType = sourceType
        self.sourceApp = sourceApp
        self.sourceURL = sourceURL
        self.requestedAction = requestedAction
    }
}

public enum CaptureEnvelopeFormat {
    public static let currentSchemaVersion = 1
    /// Share-sheet text cap in user-visible characters (Swift `String.count`).
    public static let maximumTextCharacters = 1_000
    /// Whole encoded envelope cap — guards against pathological metadata.
    public static let maximumEnvelopeBytes = 64 * 1_024
    public static let maximumSourceAppCharacters = 200
    public static let maximumSourceURLCharacters = 2_048
    public static let shareSourceType = "share"
}

public enum CaptureEnvelopeError: Error, Equatable, Sendable {
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case emptyText
    case textTooLong(maximumCharacters: Int)
    case envelopeTooLarge(maximumBytes: Int)
    case unsupportedSourceType(String)
    case invalidField(String)
}

public enum CaptureEnvelopeCodec {
    /// Canonical encoding — sorted keys make `payloadHash` deterministic.
    public static func encode(_ envelope: CaptureEnvelope) throws -> Data {
        try validate(envelope)
        let wire = WireEnvelope(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(wire)
        } catch {
            throw CaptureEnvelopeError.invalidJSON
        }
        guard data.count <= CaptureEnvelopeFormat.maximumEnvelopeBytes else {
            throw CaptureEnvelopeError.envelopeTooLarge(
                maximumBytes: CaptureEnvelopeFormat.maximumEnvelopeBytes
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CaptureEnvelope {
        guard data.count <= CaptureEnvelopeFormat.maximumEnvelopeBytes else {
            throw CaptureEnvelopeError.envelopeTooLarge(
                maximumBytes: CaptureEnvelopeFormat.maximumEnvelopeBytes
            )
        }
        let wire: WireEnvelope
        do {
            wire = try JSONDecoder().decode(WireEnvelope.self, from: data)
        } catch {
            throw CaptureEnvelopeError.invalidJSON
        }
        guard wire.schemaVersion == CaptureEnvelopeFormat.currentSchemaVersion else {
            throw CaptureEnvelopeError.unsupportedSchemaVersion(wire.schemaVersion)
        }
        let envelope = try wire.makeEnvelope()
        try validate(envelope)
        return envelope
    }

    /// SHA-256 over the canonical encoding — identical envelope contents
    /// always hash identically, so the import receipt can detect "same
    /// captureID, different payload" as a real conflict.
    public static func payloadHash(_ envelope: CaptureEnvelope) throws -> String {
        let data = try encode(envelope)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ envelope: CaptureEnvelope) throws {
        guard envelope.schemaVersion == CaptureEnvelopeFormat.currentSchemaVersion else {
            throw CaptureEnvelopeError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.sourceType == CaptureEnvelopeFormat.shareSourceType else {
            throw CaptureEnvelopeError.unsupportedSourceType(envelope.sourceType)
        }
        guard !envelope.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureEnvelopeError.emptyText
        }
        guard envelope.text.count <= CaptureEnvelopeFormat.maximumTextCharacters else {
            throw CaptureEnvelopeError.textTooLong(
                maximumCharacters: CaptureEnvelopeFormat.maximumTextCharacters
            )
        }
        if let sourceApp = envelope.sourceApp {
            guard !sourceApp.isEmpty,
                  sourceApp.count <= CaptureEnvelopeFormat.maximumSourceAppCharacters else {
                throw CaptureEnvelopeError.invalidField("sourceApp")
            }
        }
        if let sourceURL = envelope.sourceURL {
            guard sourceURL.count <= CaptureEnvelopeFormat.maximumSourceURLCharacters,
                  let url = URL(string: sourceURL),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw CaptureEnvelopeError.invalidField("sourceURL")
            }
        }
    }

    private struct WireEnvelope: Codable {
        var schemaVersion: Int
        var captureID: String
        var text: String
        var createdAtMs: Int64
        var sourceType: String
        var sourceApp: String?
        var sourceURL: String?
        var requestedAction: String

        init(_ envelope: CaptureEnvelope) {
            schemaVersion = envelope.schemaVersion
            captureID = envelope.captureID.uuidString.lowercased()
            text = envelope.text
            createdAtMs = Int64(envelope.createdAt.timeIntervalSince1970 * 1_000)
            sourceType = envelope.sourceType
            sourceApp = envelope.sourceApp
            sourceURL = envelope.sourceURL
            requestedAction = envelope.requestedAction.rawValue
        }

        func makeEnvelope() throws -> CaptureEnvelope {
            guard let id = UUID(uuidString: captureID),
                  id.uuidString.lowercased() == captureID else {
                throw CaptureEnvelopeError.invalidField("captureID")
            }
            guard createdAtMs > 0 else {
                throw CaptureEnvelopeError.invalidField("createdAtMs")
            }
            guard let action = CaptureRequestedAction(rawValue: requestedAction) else {
                throw CaptureEnvelopeError.invalidField("requestedAction")
            }
            return CaptureEnvelope(
                schemaVersion: schemaVersion,
                captureID: id,
                text: text,
                createdAt: Date(timeIntervalSince1970: Double(createdAtMs) / 1_000),
                sourceType: sourceType,
                sourceApp: sourceApp,
                sourceURL: sourceURL,
                requestedAction: action
            )
        }
    }
}
