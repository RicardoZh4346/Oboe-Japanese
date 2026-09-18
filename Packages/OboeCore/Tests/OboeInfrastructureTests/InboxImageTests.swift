import CoreGraphics
import Foundation
import ImageIO
@testable import OboeInfrastructure
import UniformTypeIdentifiers
import XCTest

final class InboxImageValidatorTests: XCTestCase {
    func testInspectAcceptsJPEGPNGHEIC() throws {
        let jpeg = try InboxImageValidator.inspect(data: TestImage.make(.jpeg))
        XCTAssertEqual(jpeg.format, .jpeg)
        XCTAssertEqual(jpeg.pixelWidth, 120)
        XCTAssertEqual(jpeg.pixelHeight, 60)

        let png = try InboxImageValidator.inspect(data: TestImage.make(.png))
        XCTAssertEqual(png.format, .png)

        let heic = try InboxImageValidator.inspect(data: TestImage.make(.heic))
        XCTAssertEqual(heic.format, .heic)
    }

    func testInspectRejectsEmptyCorruptAndUnsupported() {
        XCTAssertThrowsError(
            try InboxImageValidator.inspect(data: Data())
        ) { XCTAssertEqual($0 as? InboxImageError, .emptyFile) }

        XCTAssertThrowsError(
            try InboxImageValidator.inspect(data: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        ) { XCTAssertEqual($0 as? InboxImageError, .corruptImage) }

        // A valid GIF is a decodable image container but not an accepted
        // capture format — rejection must be by real UTI, not extension.
        XCTAssertThrowsError(
            try InboxImageValidator.inspect(data: TestImage.make(.gif))
        ) { XCTAssertEqual($0 as? InboxImageError, .unsupportedFormat) }
    }

    func testInspectEnforcesByteAndPixelLimits() throws {
        let data = TestImage.make(.jpeg)
        XCTAssertThrowsError(
            try InboxImageValidator.inspect(
                data: data,
                limits: InboxImageLimits(maximumFileBytes: data.count - 1)
            )
        ) { XCTAssertEqual($0 as? InboxImageError, .fileTooLarge(actual: data.count, limit: data.count - 1)) }

        XCTAssertThrowsError(
            try InboxImageValidator.inspect(
                data: data,
                limits: InboxImageLimits(maximumPixelCount: 120 * 60 - 1)
            )
        ) { XCTAssertEqual($0 as? InboxImageError, .imageTooLarge(actualPixelCount: 7200, limit: 7199)) }
    }

    func testPreviewDownsamplesBakesOrientationAndStripsEXIF() throws {
        // Source: 120x60 landscape recorded as orientation 6 (rotated 90° CW).
        let data = TestImage.make(.jpeg, orientation: 6)
        let info = try InboxImageValidator.inspect(data: data)
        XCTAssertEqual(info.orientation, 6)

        let preview = try InboxImageValidator.makePreviewJPEG(
            data: data,
            limits: InboxImageLimits(previewMaxPixelSize: 50)
        )
        guard let source = CGImageSourceCreateWithData(preview as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            XCTFail("预览输出不可解析")
            return
        }
        // Orientation baked into pixels: 60x120 portrait then downsampled to
        // the 50px long-edge bound.
        XCTAssertEqual(width, 25)
        XCTAssertEqual(height, 50)
        // Re-encode drops source EXIF — the orientation tag must not survive.
        // (The encoder writes a minimal dimension-only EXIF block itself;
        // that carries no source metadata.)
        XCTAssertNil(properties[kCGImagePropertyOrientation])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?["Orientation" as CFString])
    }
}

final class InboxImageStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InboxImageStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> InboxImageStore {
        InboxImageStore(rootDirectoryURL: root)
    }

    func testImportStoresControlledPreviewAndExposesResource() throws {
        let store = makeStore()
        let resource = try store.importImage(data: TestImage.make(.jpeg))

        XCTAssertEqual(resource.id.count, 36)
        XCTAssertNoThrow(
            try InboxImageStore.validateResourceID(resource.id),
            "资源 ID 必须符合备份契约的受控字符集"
        )
        XCTAssertTrue(store.exists(resource.id))

        let data = try store.loadPreviewData(for: resource.id)
        XCTAssertEqual(data.count, resource.storedByteCount)
        let info = try InboxImageValidator.inspect(data: data)
        XCTAssertEqual(info.format, .jpeg)
        XCTAssertLessThanOrEqual(
            max(info.pixelWidth, info.pixelHeight),
            InboxImageLimits().previewMaxPixelSize
        )
        // Temporary import files are cleaned up on success.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["\(resource.id).jpg"])
    }

    func testResourceIDValidationRejectsTraversal() throws {
        let store = makeStore()
        for bad in ["../x", "a/b", "a.jpg", "", " ", "a.b", "中文", "a\\b"] {
            XCTAssertThrowsError(try store.fileURL(for: bad), "应拒绝 \(bad)")
            XCTAssertFalse(store.exists(bad))
            XCTAssertThrowsError(try store.delete(bad))
            XCTAssertThrowsError(try store.loadPreviewData(for: bad))
        }
        XCTAssertNoThrow(try store.fileURL(
            for: "Abc_123-XYZ-" + String(repeating: "0", count: 110)
        ))
    }

    func testDeleteRemovesFileAndIgnoresMissing() throws {
        let store = makeStore()
        let resource = try store.importImage(data: TestImage.make(.png))
        XCTAssertTrue(store.exists(resource.id))
        try store.delete(resource.id)
        XCTAssertFalse(store.exists(resource.id))
        XCTAssertNoThrow(try store.delete(resource.id))
    }

    func testOrphanedIDsRespectKeepSetTempFilesAndAge() throws {
        let store = makeStore()
        let kept = try store.importImage(data: TestImage.make(.jpeg))
        let orphan = try store.importImage(data: TestImage.make(.jpeg))
        try Data([1]).write(to: root.appendingPathComponent(".tmp-hidden"))
        try Data([1]).write(to: root.appendingPathComponent("notajpeg.txt"))

        var orphans = try store.orphanedResourceIDs(keeping: [kept.id])
        XCTAssertEqual(orphans, [orphan.id])

        // Fresh orphans are protected by the age buffer.
        orphans = try store.orphanedResourceIDs(
            keeping: [kept.id],
            olderThan: 3600
        )
        XCTAssertEqual(orphans, [])

        // Backdate the file so the buffer no longer covers it.
        let url = try store.fileURL(for: orphan.id)
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: url.path
        )
        orphans = try store.orphanedResourceIDs(
            keeping: [kept.id],
            olderThan: 3600
        )
        XCTAssertEqual(orphans, [orphan.id])
    }

    func testMissingRootReadsAsEmptyAndLoadFails() throws {
        let store = makeStore()
        XCTAssertEqual(try store.orphanedResourceIDs(keeping: []), [])
        XCTAssertFalse(store.exists(UUID().uuidString.lowercased()))
    }
}

/// Deterministic image bytes for tests — no asset files required.
private enum TestImage {
    enum Kind {
        case jpeg, png, heic, gif
    }

    static func make(_ kind: Kind, orientation: Int? = nil) -> Data {
        let image = makeCGImage(width: 120, height: 60)
        let typeIdentifier: String
        switch kind {
        case .jpeg: typeIdentifier = UTType.jpeg.identifier
        case .png: typeIdentifier = UTType.png.identifier
        case .heic: typeIdentifier = "public.heic"
        case .gif: typeIdentifier = UTType.gif.identifier
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            fatalError("无法创建 \(typeIdentifier) 目标")
        }
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(
            destination, image, properties as CFDictionary
        )
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private static func makeCGImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("无法创建测试位图")
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 10, y: 10, width: width / 3, height: height / 3))
        guard let image = context.makeImage() else {
            fatalError("无法生成测试图片")
        }
        return image
    }
}
