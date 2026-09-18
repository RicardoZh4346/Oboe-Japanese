import Foundation
import UniformTypeIdentifiers

/// One independent text candidate extracted from a single item provider.
/// A provider's multiple type representations are alternative encodings of the
/// same content — extraction picks exactly one per provider, never several.
public struct SharedTextCandidate: Equatable, Sendable {
    /// Index into the input provider array — lets the UI label each source.
    public let providerIndex: Int
    public let text: String
    /// http(s) URL offered by the same provider, kept as metadata only.
    public let sourceURL: String?

    public init(providerIndex: Int, text: String, sourceURL: String?) {
        self.providerIndex = providerIndex
        self.text = text
        self.sourceURL = sourceURL
    }
}

public enum ShareExtractionResult: Equatable, Sendable {
    /// At least one usable text — the UI previews/selects when several.
    case candidates([SharedTextCandidate])
    /// Only URL(s) arrived — the sheet must ask the user to share text.
    case urlOnly([String])
    /// Nothing usable at all.
    case empty
}

/// Turns `NSItemProvider` attachments into capture candidates.
///
/// Per provider, text type identifiers are tried in preference order and the
/// first that yields non-empty text wins — the same provider is never counted
/// twice. A `public.url` on the same provider becomes `sourceURL` metadata
/// (http/https only); providers that only carry a URL feed `urlOnly`.
public enum SharedTextExtractor {
    /// Text representations in preference order — plain text first, then the
    /// broader text UTI which may surface as `NSAttributedString`.
    private static let textTypeIdentifiers = [
        UTType.plainText.identifier,
        UTType.utf8PlainText.identifier,
        UTType.text.identifier
    ]

    /// `providers` is `sending`: NSItemProvider isn't Sendable, but the array
    /// is handed over whole and never shared afterwards.
    public static func extract(
        from providers: sending [NSItemProvider]
    ) async -> ShareExtractionResult {
        var candidates: [SharedTextCandidate] = []
        var urls: [String] = []

        for (index, provider) in providers.enumerated() {
            let url = await loadWebURL(from: provider)
            if let text = await loadText(from: provider) {
                candidates.append(
                    SharedTextCandidate(
                        providerIndex: index,
                        text: text,
                        sourceURL: url
                    )
                )
            } else if let url {
                urls.append(url)
            }
        }

        if !candidates.isEmpty { return .candidates(candidates) }
        if !urls.isEmpty { return .urlOnly(urls) }
        return .empty
    }

    // MARK: - Provider decoding

    private static func loadText(from provider: NSItemProvider) async -> String? {
        for typeIdentifier in textTypeIdentifiers {
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                continue
            }
            if let text = try? await provider.loadItem(
                forTypeIdentifier: typeIdentifier
            ), let string = coerceToText(text) {
                return string
            }
        }
        return nil
    }

    private static func loadWebURL(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else {
            return nil
        }
        guard let item = try? await provider.loadItem(
            forTypeIdentifier: UTType.url.identifier
        ) else {
            return nil
        }
        let string: String?
        switch item {
        case let url as URL:
            string = url.absoluteString
        case let text as String:
            string = text
        case let data as Data:
            string = String(data: data, encoding: .utf8)
        default:
            string = nil
        }
        guard let string,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return string
    }

    private static func coerceToText(_ item: NSSecureCoding) -> String? {
        let raw: String?
        switch item {
        case let string as String:
            raw = string
        case let attributed as NSAttributedString:
            raw = attributed.string
        case let data as Data:
            raw = String(data: data, encoding: .utf8)
        case let url as URL:
            // A file URL delivering text content — read it; a web URL is
            // metadata and is handled separately.
            if url.isFileURL {
                raw = try? String(contentsOf: url, encoding: .utf8)
            } else {
                raw = nil
            }
        default:
            raw = nil
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : raw
    }
}

/// `NSSecureCoding` isn't `Sendable`; the loaded item is handed off exactly
/// once through the continuation and never shared, so an unchecked box is
/// safe here.
private struct SendableItemBox: @unchecked Sendable {
    let item: NSSecureCoding
}

private extension NSItemProvider {
    /// `loadItem` is completion-based; bridge it so extraction stays `async`.
    func loadItem(forTypeIdentifier typeIdentifier: String) async throws -> NSSecureCoding {
        let box = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SendableItemBox, Error>) in
            loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: SendableItemBox(item: item))
                } else {
                    continuation.resume(
                        throwing: CocoaError(.coderReadCorrupt)
                    )
                }
            }
        }
        return box.item
    }
}
