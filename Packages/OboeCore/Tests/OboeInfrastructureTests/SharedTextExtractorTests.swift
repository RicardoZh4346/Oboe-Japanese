import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import OboeSharedCapture

/// Provider → candidate extraction: one candidate per provider regardless of
/// how many type representations it offers, URL becomes metadata only, and
/// URL-only shares are reported honestly.
final class SharedTextExtractorTests: XCTestCase {
    func testPlainTextProviderYieldsSingleCandidate() async {
        let provider = NSItemProvider(
            item: "日本語のテキスト" as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        let result = await SharedTextExtractor.extract(from: [provider])
        guard case .candidates(let candidates) = result else {
            return XCTFail("Expected candidates, got \(result)")
        }
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "日本語のテキスト")
        XCTAssertNil(candidates[0].sourceURL)
    }

    func testProviderWithSeveralTextRepresentationsYieldsOneCandidate() async {
        // Same content advertised as both plain text and text — must not
        // double-import.
        let provider = NSItemProvider()
        provider.registerItem(
            forTypeIdentifier: UTType.plainText.identifier,
            loadHandler: { completion, _, _ in
                completion?("同じ内容" as NSSecureCoding, nil)
            }
        )
        provider.registerItem(
            forTypeIdentifier: UTType.text.identifier,
            loadHandler: { completion, _, _ in
                completion?("同じ内容" as NSSecureCoding, nil)
            }
        )
        let result = await SharedTextExtractor.extract(from: [provider])
        guard case .candidates(let candidates) = result else {
            return XCTFail("Expected candidates, got \(result)")
        }
        XCTAssertEqual(candidates.count, 1)
    }

    func testMultipleProvidersYieldIndependentCandidates() async {
        let first = NSItemProvider(
            item: "第一段" as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        let second = NSItemProvider(
            item: "第二段" as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        let result = await SharedTextExtractor.extract(from: [first, second])
        guard case .candidates(let candidates) = result else {
            return XCTFail("Expected candidates, got \(result)")
        }
        XCTAssertEqual(candidates.map(\.text), ["第一段", "第二段"])
        XCTAssertEqual(candidates.map(\.providerIndex), [0, 1])
    }

    func testURLOnSameProviderBecomesSourceMetadata() async {
        let provider = NSItemProvider()
        provider.registerItem(
            forTypeIdentifier: UTType.plainText.identifier,
            loadHandler: { completion, _, _ in
                completion?("正文文本" as NSSecureCoding, nil)
            }
        )
        provider.registerItem(
            forTypeIdentifier: UTType.url.identifier,
            loadHandler: { completion, _, _ in
                completion?(URL(string: "https://example.com/a")! as NSSecureCoding, nil)
            }
        )
        let result = await SharedTextExtractor.extract(from: [provider])
        guard case .candidates(let candidates) = result else {
            return XCTFail("Expected candidates, got \(result)")
        }
        XCTAssertEqual(candidates[0].text, "正文文本")
        XCTAssertEqual(candidates[0].sourceURL, "https://example.com/a")
    }

    func testURLOnlyProvidersReportURLList() async {
        let provider = NSItemProvider(
            item: URL(string: "https://example.com")! as NSURL,
            typeIdentifier: UTType.url.identifier
        )
        let result = await SharedTextExtractor.extract(from: [provider])
        guard case .urlOnly(let urls) = result else {
            return XCTFail("Expected urlOnly, got \(result)")
        }
        XCTAssertEqual(urls, ["https://example.com"])
    }

    func testNonWebURLIsNotTreatedAsSource() async {
        let provider = NSItemProvider(
            item: URL(fileURLWithPath: "/tmp/secret.txt") as NSURL,
            typeIdentifier: UTType.url.identifier
        )
        let result = await SharedTextExtractor.extract(from: [provider])
        XCTAssertEqual(result, .empty)
    }

    func testWhitespaceOnlyTextIsNotACandidate() async {
        let provider = NSItemProvider(
            item: "   \n  " as NSString,
            typeIdentifier: UTType.plainText.identifier
        )
        let result = await SharedTextExtractor.extract(from: [provider])
        XCTAssertEqual(result, .empty)
    }

    func testEmptyProviderListReportsEmpty() async {
        let result = await SharedTextExtractor.extract(from: [])
        XCTAssertEqual(result, .empty)
    }
}
