import XCTest
@testable import OboeDomain

final class OCRReadingOrderTests: XCTestCase {
    private func block(_ text: String, x: Double, y: Double, w: Double = 0.4, h: Double = 0.1) -> OCRTextBlock {
        OCRTextBlock(
            id: 0,
            text: text,
            confidence: 0.9,
            boundingBox: OCRBoundingBox(x: x, y: y, width: w, height: h)
        )
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(OCRReadingOrder.ordered([]).isEmpty)
    }

    func testSingleBlockKeepsTextAndGetsIndexZero() {
        let ordered = OCRReadingOrder.ordered([block("a", x: 0.5, y: 0.5)])
        XCTAssertEqual(ordered.map(\.text), ["a"])
        XCTAssertEqual(ordered[0].id, 0)
    }

    func testLinesSortTopToBottom() {
        let ordered = OCRReadingOrder.ordered([
            block("third", x: 0, y: 0.8),
            block("first", x: 0, y: 0.1),
            block("second", x: 0, y: 0.45),
        ])
        XCTAssertEqual(ordered.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(ordered.map(\.id), [0, 1, 2])
    }

    func testSameLineSortsLeftToRight() {
        // Two blocks on the same line (overlapping vertical span).
        let ordered = OCRReadingOrder.ordered([
            block("right", x: 0.55, y: 0.1),
            block("left", x: 0.0, y: 0.12),
        ])
        XCTAssertEqual(ordered.map(\.text), ["left", "right"])
    }

    func testStaggeredBlocksOnOneLineStayTogether() {
        // Second block is slightly lower but its vertical range still overlaps
        // the line's union — must not split into separate lines.
        let ordered = OCRReadingOrder.ordered([
            block("b", x: 0.5, y: 0.15, h: 0.1),
            block("a", x: 0.0, y: 0.1, h: 0.1),
            block("c", x: 0.2, y: 0.9, h: 0.1),
        ])
        XCTAssertEqual(ordered.map(\.text), ["a", "b", "c"])
    }

    func testNonOverlappingLinesStaySeparate() {
        // "word" belongs to line 1 vertically but sits to the right; "line2" is
        // a clearly separate line below.
        let ordered = OCRReadingOrder.ordered([
            block("line2", x: 0.0, y: 0.6, h: 0.1),
            block("word", x: 0.55, y: 0.12, h: 0.1),
            block("line1", x: 0.0, y: 0.1, h: 0.1),
        ])
        XCTAssertEqual(ordered.map(\.text), ["line1", "word", "line2"])
    }

    func testOrderingIsDeterministicRegardlessOfInputOrder() {
        let input = [
            block("3", x: 0.0, y: 0.5),
            block("1", x: 0.0, y: 0.0),
            block("2", x: 0.5, y: 0.02),
            block("4", x: 0.5, y: 0.52),
        ]
        let forward = OCRReadingOrder.ordered(input)
        let reversed = OCRReadingOrder.ordered(input.reversed())
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.map(\.text), ["1", "2", "3", "4"])
    }
}
