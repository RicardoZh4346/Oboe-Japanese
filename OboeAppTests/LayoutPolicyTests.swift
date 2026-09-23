import SwiftUI
import XCTest
@testable import Oboe

/// LayoutPolicy 阈值是集中 token：compact < 700，regular 700…1099，
/// wide ≥ 1100；环境 size class 为 compact 时优先于容器宽度。
final class LayoutPolicyTests: XCTestCase {
    func testNarrowContainerResolvesCompact() {
        let policy = LayoutPolicy.resolve(
            containerWidth: 393,
            horizontalSizeClass: .compact,
            dynamicTypeSize: .medium
        )
        XCTAssertEqual(policy.mode, .compact)
        XCTAssertFalse(policy.usesSplitNavigation)
    }

    func testCompactSizeClassOverridesWideContainer() {
        // iPad 1/3 Split View：环境 compact 优先于像素宽度。
        let policy = LayoutPolicy.resolve(
            containerWidth: 900,
            horizontalSizeClass: .compact,
            dynamicTypeSize: .medium
        )
        XCTAssertEqual(policy.mode, .compact)
    }

    func testRegularBand() {
        let policy = LayoutPolicy.resolve(
            containerWidth: 800,
            horizontalSizeClass: .regular,
            dynamicTypeSize: .medium
        )
        XCTAssertEqual(policy.mode, .regular)
        XCTAssertTrue(policy.usesSplitNavigation)
    }

    func testRegularLowerBoundIsInclusive() {
        let policy = LayoutPolicy.resolve(
            containerWidth: LayoutPolicy.compactWidthLimit,
            horizontalSizeClass: .regular,
            dynamicTypeSize: .medium
        )
        XCTAssertEqual(policy.mode, .regular)
    }

    func testWideThreshold() {
        let policy = LayoutPolicy.resolve(
            containerWidth: LayoutPolicy.wideWidthLimit,
            horizontalSizeClass: .regular,
            dynamicTypeSize: .medium
        )
        XCTAssertEqual(policy.mode, .wide)
    }

    func testAccessibilityTypeNarrowsReadableWidth() {
        let normal = LayoutPolicy.resolve(
            containerWidth: 1200,
            horizontalSizeClass: .regular,
            dynamicTypeSize: .medium
        )
        let ax = LayoutPolicy.resolve(
            containerWidth: 1200,
            horizontalSizeClass: .regular,
            dynamicTypeSize: .accessibility3
        )
        XCTAssertLessThan(ax.readableContentMaxWidth, normal.readableContentMaxWidth)
        XCTAssertLessThan(ax.editorMaxWidth, normal.editorMaxWidth)
    }
}
