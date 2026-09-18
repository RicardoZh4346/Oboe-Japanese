import Foundation
import ImageIO
import OboeDomain
@preconcurrency import Vision

/// On-device OCR backed by `VNRecognizeTextRequest` in `.accurate` mode.
/// Japanese-first (`ja-JP`, then `en-US`); the latest framework revision
/// supported by the running OS is selected at runtime.
///
/// Runs decoding and recognition off the calling actor. A new `recognize`
/// call cancels the in-flight one: the superseded call throws
/// `CancellationError` and its stale result is dropped.
///
/// Scope: horizontal text is the supported layout. Vertical writing
/// (manga columns) produces engine-dependent output with no accuracy promise.
public actor VisionOCRService: OCRRecognizing {
    /// Language preference order. `ja-JP` is required — the product's core
    /// flow is Japanese text; without it the feature cannot serve its purpose.
    public static let preferredLanguages = ["ja-JP", "en-US"]

    private var generation: UInt64 = 0
    private var inFlight: Task<OCRResult, Error>?
    private let requestBox = OCRRequestBox()

    public init() {}

    public nonisolated static func resolvedRecognitionLanguages() throws -> [String] {
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        probe.revision = preferredRevision()
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []
        let usable = preferredLanguages.filter { supported.contains($0) }
        guard usable.contains(preferredLanguages[0]) else {
            throw OCRError.languageUnavailable(supported: supported)
        }
        return usable
    }

    /// Highest `VNRecognizeTextRequest` revision the running OS supports.
    public nonisolated static func preferredRevision() -> Int {
        VNRecognizeTextRequest.supportedRevisions.max() ?? VNRecognizeTextRequestRevision1
    }

    public func recognize(imageData: Data) async throws -> OCRResult {
        generation &+= 1
        let ticket = generation
        inFlight?.cancel()

        let languages = try Self.resolvedRecognitionLanguages()
        let box = requestBox
        let task = Task.detached(priority: .userInitiated) {
            try Self.performRecognition(imageData: imageData, languages: languages, requestBox: box)
        }
        inFlight = task

        do {
            return try await withTaskCancellationHandler {
                let result = try await task.value
                guard ticket == generation else { throw CancellationError() }
                return result
            } onCancel: {
                task.cancel()
                box.cancel()
            }
        } catch {
            if Task.isCancelled || ticket != generation || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func performRecognition(
        imageData: Data,
        languages: [String],
        requestBox: OCRRequestBox
    ) throws -> OCRResult {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetType(source) != nil else {
            throw OCRError.undecodableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation ?? 1) ?? .up

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.revision = preferredRevision()
        requestBox.install(request)
        defer { requestBox.clear(request) }
        try Task.checkCancellation()

        let handler = VNImageRequestHandler(data: imageData, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A cancelled request throws out of `perform`; map it honestly.
            if Task.isCancelled { throw CancellationError() }
            throw OCRError.recognitionFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let blocks = (request.results ?? []).compactMap { observation -> OCRTextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision boxes are normalized with a bottom-left origin; convert to
            // top-left for the domain DTO.
            let vision = observation.boundingBox
            return OCRTextBlock(
                id: 0,
                text: text,
                confidence: Double(candidate.confidence),
                boundingBox: OCRBoundingBox(
                    x: Double(vision.minX),
                    y: Double(1 - vision.maxY),
                    width: Double(vision.width),
                    height: Double(vision.height)
                )
            )
        }
        return OCRResult(blocks: OCRReadingOrder.ordered(blocks), recognizedLanguages: languages)
    }
}

/// Thread-safe slot for the in-flight `VNRecognizeTextRequest` so task
/// cancellation can reach the blocking `perform` call.
final class OCRRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?

    func install(_ request: VNRecognizeTextRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func clear(_ request: VNRecognizeTextRequest) {
        lock.lock()
        if self.request === request { self.request = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.cancel()
    }
}
