import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resource limits for local image input. Values are conservative defaults —
/// the plan calls for real-device measurement before they are treated as
/// verified performance data.
public struct InboxImageLimits: Sendable, Equatable {
    /// Raw file bytes accepted before any decoding work happens.
    public var maximumFileBytes: Int
    /// Total pixel area (width × height) — guards decompression cost even
    /// though previews are produced by ImageIO downsampling.
    public var maximumPixelCount: Int
    /// Long-edge pixel size of the stored preview.
    public var previewMaxPixelSize: Int
    /// JPEG quality of the re-encoded preview (0...1).
    public var previewJPEGQuality: Double

    public init(
        maximumFileBytes: Int = 32 * 1_024 * 1_024,
        maximumPixelCount: Int = 50_000_000,
        previewMaxPixelSize: Int = 2_048,
        previewJPEGQuality: Double = 0.85
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumPixelCount = maximumPixelCount
        self.previewMaxPixelSize = previewMaxPixelSize
        self.previewJPEGQuality = previewJPEGQuality
    }
}

public enum InboxImageError: Error, Equatable, Sendable {
    case emptyFile
    /// Actual image type is not a decodable JPEG/PNG/HEIC source.
    case unsupportedFormat
    case fileTooLarge(actual: Int, limit: Int)
    case imageTooLarge(actualPixelCount: Int, limit: Int)
    case corruptImage
    case previewGenerationFailed
    case storageFailure
    /// Picked item produced no readable data (e.g. still remote in iCloud).
    case imageUnavailable
}

/// Image metadata read from the container without decoding the bitmap.
public struct InboxImageInfo: Sendable, Equatable {
    public enum Format: String, Sendable {
        case jpeg
        case png
        case heic
    }

    public let format: Format
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// CGImagePropertyOrientation recorded in the file (1...8, 1 = upright).
    public let orientation: Int

    public init(format: Format, pixelWidth: Int, pixelHeight: Int, orientation: Int) {
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
    }
}

/// Validates image bytes and produces a normalized preview entirely through
/// ImageIO — no full-size bitmap decode ever happens on this path.
public enum InboxImageValidator {
    /// Reads container metadata and enforces format/byte/pixel limits.
    /// Format comes from the real UTI (`CGImageSourceGetType`), never the
    /// file extension.
    public static func inspect(
        data: Data,
        limits: InboxImageLimits = InboxImageLimits()
    ) throws -> InboxImageInfo {
        guard !data.isEmpty else {
            throw InboxImageError.emptyFile
        }
        guard data.count <= limits.maximumFileBytes else {
            throw InboxImageError.fileTooLarge(
                actual: data.count,
                limit: limits.maximumFileBytes
            )
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) else {
            throw InboxImageError.corruptImage
        }
        let format: InboxImageInfo.Format
        switch uti as String {
        case UTType.jpeg.identifier, "public.heic", "public.heif":
            format = uti as String == UTType.jpeg.identifier ? .jpeg : .heic
        case UTType.png.identifier:
            format = .png
        default:
            throw InboxImageError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw InboxImageError.corruptImage
        }
        let pixelCount = width * height
        guard pixelCount <= limits.maximumPixelCount else {
            throw InboxImageError.imageTooLarge(
                actualPixelCount: pixelCount,
                limit: limits.maximumPixelCount
            )
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        return InboxImageInfo(
            format: format,
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation
        )
    }

    /// Downsamples via `CGImageSourceCreateThumbnailAtIndex` (no full decode)
    /// and re-encodes as JPEG. The thumbnail transform flag bakes EXIF
    /// orientation into the pixels; writing only the image to a fresh
    /// destination drops all EXIF metadata from the stored preview.
    public static func makePreviewJPEG(
        data: Data,
        limits: InboxImageLimits = InboxImageLimits()
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw InboxImageError.corruptImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.previewMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            throw InboxImageError.previewGenerationFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw InboxImageError.previewGenerationFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality:
                limits.previewJPEGQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            throw InboxImageError.previewGenerationFailed
        }
        return output as Data
    }
}
