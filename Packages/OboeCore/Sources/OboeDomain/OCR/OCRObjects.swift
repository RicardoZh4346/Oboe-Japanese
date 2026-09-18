import Foundation

/// Normalized image coordinates, origin top-left, y increasing downward
/// (SwiftUI/UIKit convention). All components are in 0...1 relative to the
/// recognized image after orientation is applied.
public struct OCRBoundingBox: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One recognized text region. `id` equals the block's index in reading order
/// inside its `OCRResult`, so it is stable for the lifetime of that result and
/// deterministic for identical inputs.
public struct OCRTextBlock: Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
    /// Recognizer confidence in 0...1 as reported by the engine.
    public let confidence: Double
    public let boundingBox: OCRBoundingBox

    public init(id: Int, text: String, confidence: Double, boundingBox: OCRBoundingBox) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct OCRResult: Equatable, Sendable {
    /// Blocks sorted in reading order; `block.id == index` in this array.
    public let blocks: [OCRTextBlock]
    /// Languages the recognizer actually used, in preference order.
    public let recognizedLanguages: [String]

    public init(blocks: [OCRTextBlock], recognizedLanguages: [String]) {
        self.blocks = blocks
        self.recognizedLanguages = recognizedLanguages
    }

    /// All block texts joined in reading order — the full recognized text.
    public var fullText: String {
        blocks.map(\.text).joined(separator: "\n")
    }
}

public enum OCRError: Error, Equatable, Sendable {
    /// Input bytes could not be decoded as an image.
    case undecodableImage
    /// The engine does not support any of the required languages on this
    /// device/OS version. `supported` lists what the engine reports.
    case languageUnavailable(supported: [String])
    /// The engine was invoked but failed before producing a result.
    case recognitionFailed(String)
}

/// On-device text recognition. Implementations must be safe to call from any
/// context and must not retain Vision or UIKit types in their surface area —
/// results cross the domain boundary as pure DTOs.
///
/// Concurrency contract: a new `recognize` call supersedes the previous
/// in-flight call — the superseded call throws `CancellationError` and its
/// (stale) result is never delivered.
public protocol OCRRecognizing: Sendable {
    /// Runs recognition on encoded image bytes (JPEG/PNG/HEIC).
    /// EXIF orientation is applied by the implementation.
    func recognize(imageData: Data) async throws -> OCRResult
}

/// Deterministic horizontal reading order: blocks are grouped into lines by
/// vertical overlap, lines sort top-to-bottom, blocks within a line sort
/// left-to-right. Vertical writing (e.g. manga columns) is explicitly not
/// promised — accuracy there is engine-dependent.
public enum OCRReadingOrder {
    /// Returns the input blocks re-indexed so `id` matches position in the
    /// returned array.
    public static func ordered(_ blocks: [OCRTextBlock]) -> [OCRTextBlock] {
        struct Line {
            var top: Double
            var bottom: Double
            var members: [OCRTextBlock]
        }

        var lines: [Line] = []
        // Seed lines with the visually highest blocks first.
        for block in blocks.sorted(by: { ($0.boundingBox.y, $0.boundingBox.x) < ($1.boundingBox.y, $1.boundingBox.x) }) {
            let top = block.boundingBox.y
            let bottom = block.boundingBox.y + block.boundingBox.height
            if let index = lines.firstIndex(where: { line in
                // Same line when the block's vertical midpoint falls inside the
                // line's span, or spans overlap by more than half the block.
                let overlap = min(bottom, line.bottom) - max(top, line.top)
                let midpointInside = block.boundingBox.midY >= line.top && block.boundingBox.midY <= line.bottom
                return midpointInside || overlap > block.boundingBox.height / 2
            }) {
                lines[index].top = min(lines[index].top, top)
                lines[index].bottom = max(lines[index].bottom, bottom)
                lines[index].members.append(block)
            } else {
                lines.append(Line(top: top, bottom: bottom, members: [block]))
            }
        }

        return lines
            .sorted { ($0.top, $0.bottom) < ($1.top, $1.bottom) }
            .flatMap { line in line.members.sorted { ($0.boundingBox.x, $0.boundingBox.y) < ($1.boundingBox.x, $1.boundingBox.y) } }
            .enumerated()
            .map { index, block in
                OCRTextBlock(id: index, text: block.text, confidence: block.confidence, boundingBox: block.boundingBox)
            }
    }
}
