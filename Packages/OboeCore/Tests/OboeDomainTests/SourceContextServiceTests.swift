import Foundation
import XCTest
@testable import OboeDomain

/// `SourceContextService`（设计 §6.1/§6.2）：draft→record 装配、
/// 主来源降级规则、图片引用集合——纯领域逻辑，不碰 DB。
final class SourceContextServiceTests: XCTestCase {
    private let service = SourceContextService()

    func testMakeContextAssemblesAndNormalizes() {
        let noteID = UUID()
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let draft = SourceContextDraft(
            sourceType: .share,
            originalSentence: "  そんなことを言われても困る。  ",
            surroundingText: "前文",
            sourceTitle: "  Safari 分享  ",
            sourceURL: " https://example.com ",
            sourceApp: "com.apple.Safari",
            imageReference: "img-1",
            dictionaryEntryID: 1_234_567,
            dictionaryVersion: " 2026-09 ",
            dictionarySenseKey: " sense-1 ",
            selectedGlossLanguage: " zho ",
            isPrimary: true
        )

        let context = service.makeContext(
            from: draft,
            noteID: noteID,
            now: now,
            makeID: { id }
        )

        XCTAssertEqual(context.id, id)
        XCTAssertEqual(context.noteID, noteID)
        XCTAssertEqual(context.createdAt, now)
        XCTAssertEqual(context.sourceType, .share)
        XCTAssertEqual(context.originalSentence, "そんなことを言われても困る。")
        XCTAssertEqual(context.sourceTitle, "Safari 分享")
        XCTAssertEqual(context.sourceURL, "https://example.com")
        XCTAssertEqual(context.dictionaryVersion, "2026-09")
        XCTAssertEqual(context.dictionarySenseKey, "sense-1")
        XCTAssertEqual(context.selectedGlossLanguage, "zho")
        XCTAssertTrue(context.isPrimary)
        XCTAssertEqual(context.imageReference, "img-1")
        XCTAssertEqual(context.dictionaryEntryID, 1_234_567)
    }

    func testMakeContextNormalizesBlankAndTruncatesSurrounding() {
        let overlong = String(repeating: "あ", count: 5_000)
        let draft = SourceContextDraft(
            sourceType: .ocr,
            originalSentence: "   \n\t  ",
            surroundingText: "  \(overlong)  ",
            sourceTitle: "   ",
            sourceURL: "\n",
            isPrimary: false
        )

        let context = service.makeContext(
            from: draft,
            noteID: UUID(),
            now: Date(),
            makeID: { UUID() }
        )

        XCTAssertNil(context.originalSentence, "纯空白归一为 nil")
        XCTAssertNil(context.sourceTitle)
        XCTAssertNil(context.sourceURL)
        XCTAssertEqual(
            context.surroundingText?.count,
            SourceContextDraft.maximumSurroundingCharacters,
            "surrounding 截断到冻结上限"
        )
    }

    func testResolvePrimaryDemotesNewDraftWhenPrimaryExists() {
        let existingPrimary = Self.context(isPrimary: true)
        var draft = SourceContextDraft(sourceType: .share, isPrimary: true)

        let resolved = service.resolvePrimary(
            existing: [existingPrimary],
            newDraft: draft
        )
        XCTAssertFalse(
            resolved.isPrimary,
            "已有 primary 时新来源默认降级——显式 setPrimary 才切换"
        )

        // draft 本就非 primary：不受影响。
        draft.isPrimary = false
        XCTAssertFalse(
            service.resolvePrimary(
                existing: [existingPrimary],
                newDraft: draft
            ).isPrimary
        )
    }

    func testResolvePrimaryKeepsDraftWhenNoExistingPrimary() {
        let draft = SourceContextDraft(sourceType: .manual, isPrimary: true)
        // 无既有来源。
        XCTAssertTrue(
            service.resolvePrimary(existing: [], newDraft: draft).isPrimary
        )
        // 有来源但无 primary（旧 primary 被删/未设）。
        XCTAssertTrue(
            service.resolvePrimary(
                existing: [Self.context(isPrimary: false)],
                newDraft: draft
            ).isPrimary
        )
    }

    func testMakeContextWithExistingDemotesPrimary() {
        let context = service.makeContext(
            from: SourceContextDraft(sourceType: .share, isPrimary: true),
            existing: [Self.context(isPrimary: true)],
            noteID: UUID(),
            now: Date(),
            makeID: { UUID() }
        )
        XCTAssertFalse(context.isPrimary)
    }

    func testImageReferencesCollectsNonEmpty() {
        let contexts = [
            Self.context(imageReference: "img-a"),
            Self.context(imageReference: "img-a"),
            Self.context(imageReference: "img-b"),
            Self.context(imageReference: nil),
            Self.context(imageReference: "")
        ]
        XCTAssertEqual(
            service.imageReferences(in: contexts),
            ["img-a", "img-b"]
        )
        XCTAssertEqual(service.imageReferences(in: []), [])
    }

    // MARK: - 工具

    private static func context(
        isPrimary: Bool = false,
        imageReference: String? = nil
    ) -> SourceContext {
        SourceContext(
            id: UUID(),
            noteID: UUID(),
            sourceType: .manual,
            originalSentence: nil,
            surroundingText: nil,
            sourceTitle: nil,
            sourceURL: nil,
            sourceApp: nil,
            imageReference: imageReference,
            dictionaryEntryID: nil,
            dictionaryVersion: nil,
            dictionarySenseKey: nil,
            selectedGlossLanguage: nil,
            isPrimary: isPrimary,
            createdAt: Date(timeIntervalSince1970: 1_768_000_000)
        )
    }
}
