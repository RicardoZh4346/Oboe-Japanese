import CoreText
import ImageIO
import XCTest
@testable import OboeDomain
@testable import OboeInfrastructure

final class VisionOCRServiceTests: XCTestCase {
    func testRecognizesJapaneseAndEnglishLines() async throws {
        let data = try TextImage.make(lines: ["こんにちは", "Hello world"])
        let result = try await VisionOCRService().recognize(imageData: data)

        XCTAssertEqual(result.recognizedLanguages.first, "ja-JP")
        XCTAssertGreaterThanOrEqual(result.blocks.count, 2)
        XCTAssertTrue(result.fullText.contains("こんにちは"), result.fullText)
        XCTAssertTrue(result.fullText.contains("Hello"), result.fullText)
        // Block ids match their position in reading order.
        XCTAssertEqual(result.blocks.map(\.id), Array(0 ..< result.blocks.count))
        for block in result.blocks {
            XCTAssertTrue((0 ... 1).contains(block.confidence), "\(block.confidence)")
            XCTAssertTrue((0 ... 1).contains(block.boundingBox.x))
            XCTAssertTrue((0 ... 1).contains(block.boundingBox.y))
            XCTAssertLessThanOrEqual(block.boundingBox.x + block.boundingBox.width, 1.01)
            XCTAssertLessThanOrEqual(block.boundingBox.y + block.boundingBox.height, 1.01)
        }
    }

    func testUndecodableBytesThrow() async {
        do {
            _ = try await VisionOCRService().recognize(imageData: Data([0xFF, 0xD8, 0x00, 0x01]))
            XCTFail("损坏字节必须报 undecodableImage")
        } catch {
            XCTAssertEqual(error as? OCRError, .undecodableImage)
        }
    }

    func testEmptyDataThrowsUndecodable() async {
        do {
            _ = try await VisionOCRService().recognize(imageData: Data())
            XCTFail("空数据必须报 undecodableImage")
        } catch {
            XCTAssertEqual(error as? OCRError, .undecodableImage)
        }
    }

    func testBlankImageReturnsNoBlocks() async throws {
        let result = try await VisionOCRService().recognize(imageData: TextImage.blank())
        XCTAssertTrue(result.blocks.isEmpty)
        XCTAssertEqual(result.fullText, "")
    }

    func testEXIFOrientationIsAppliedBeforeRecognition() async throws {
        // Horizontal text stored with orientation 6 — the recognizer must
        // honor EXIF or the text reads sideways and fails.
        let data = try TextImage.make(lines: ["Hello"], orientation: 6)
        let result = try await VisionOCRService().recognize(imageData: data)
        XCTAssertTrue(result.fullText.contains("Hello"), result.fullText)
    }

    func testNewRecognitionSupersedesInFlightCall() async throws {
        let service = VisionOCRService()
        // Large enough that recognition cannot finish before the second call
        // reaches the actor — the first call is deterministically superseded.
        let data = try TextImage.make(
            lines: Array(repeating: "こんにちは Hello world", count: 12),
            width: 2400, lineHeight: 120
        )
        let stale = Task { try await service.recognize(imageData: data) }
        // Give the first call time to enter the actor and install its
        // in-flight task; otherwise ordering is unspecified and "fresh"
        // could legitimately be the one superseded.
        try await Task.sleep(for: .milliseconds(50))
        let fresh = try await service.recognize(imageData: data)
        XCTAssertTrue(fresh.fullText.contains("Hello"))
        do {
            _ = try await stale.value
            XCTFail("被取代的调用必须取消,不能返回过期结果")
        } catch {
            XCTAssertTrue(error is CancellationError, "期望 CancellationError,得到 \(error)")
        }
    }
}

/// Synthesizes deterministic text images with CoreText — no fixture assets.
private enum TextImage {
    enum ImageError: Error { case fontUnavailable }

    static func make(
        lines: [String],
        orientation: Int? = nil,
        width: Int = 800,
        lineHeight: Int = 90
    ) throws -> Data {
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 56, nil)
        let family = CTFontCopyFamilyName(font) as String
        guard family.contains("Hiragino") else { throw ImageError.fontUnavailable }

        let height = 60 + lineHeight * lines.count
        let context = makeContext(width: width, height: height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Bitmap context is bottom-left origin; CoreText draws glyphs above
        // the baseline — place the first baseline near the top.
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(gray: 0, alpha: 1),
            ]
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: line, attributes: attributes)
            )
            context.textPosition = CGPoint(
                x: 30, y: CGFloat(height - 70 - index * lineHeight)
            )
            CTLineDraw(ctLine, context)
        }
        return try encode(context, orientation: orientation)
    }

    static func blank(width: Int = 400, height: Int = 200) -> Data {
        let context = makeContext(width: width, height: height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return (try? encode(context, orientation: nil)) ?? Data()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("无法创建测试位图") }
        return context
    }

    private static func encode(_ context: CGContext, orientation: Int?) throws -> Data {
        guard let image = context.makeImage() else { throw ImageError.fontUnavailable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil
        ) else { throw ImageError.fontUnavailable }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
