import SwiftUI
import XCTest
@testable import Oboe

/// PresentationRole → 呈现策略的映射契约：compact 永远 sheet
/// （iPhone 行为不变），regular/wide 按角色分流。
final class AdaptivePresentationTests: XCTestCase {
    private func policy(
        width: CGFloat,
        sizeClass: UserInterfaceSizeClass? = .regular
    ) -> LayoutPolicy {
        LayoutPolicy.resolve(
            containerWidth: width,
            horizontalSizeClass: sizeClass,
            dynamicTypeSize: .medium
        )
    }

    func testCompactAlwaysSheet() {
        let compact = policy(width: 390, sizeClass: .compact)
        for role in [PresentationRole.quickPicker, .editor, .inspector,
                     .blockingFlow, .focusedWorkflow] {
            XCTAssertEqual(
                compact.presentation(for: role), .sheet,
                "compact 下 \(role) 必须保持 sheet"
            )
        }
    }

    func testQuickPickerBecomesPopoverOnRegular() {
        XCTAssertEqual(
            policy(width: 900).presentation(for: .quickPicker), .popover
        )
        XCTAssertEqual(
            policy(width: 1300).presentation(for: .quickPicker), .popover
        )
    }

    func testInspectorRoleUsesInspectorOnRegular() {
        XCTAssertEqual(
            policy(width: 900).presentation(for: .inspector), .inspector
        )
    }

    func testEditorAndFlowsStaySheetOnRegular() {
        let regular = policy(width: 900)
        XCTAssertEqual(regular.presentation(for: .editor), .sheet)
        XCTAssertEqual(regular.presentation(for: .blockingFlow), .sheet)
        XCTAssertEqual(regular.presentation(for: .focusedWorkflow), .sheet)
    }
}
