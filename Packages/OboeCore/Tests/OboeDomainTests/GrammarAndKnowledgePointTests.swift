import Foundation
import XCTest
@testable import OboeDomain

final class GrammarAndKnowledgePointTests: XCTestCase {
    func testGrammarValidationNormalizesGrammarOnlyFields() throws {
        let form = GrammarFormData(
            grammarForm: "  ～たことがある ",
            meaningZH: " 曾经做过…… ",
            usage: " 表示过去经历 ",
            connection: " 动词た形 + ことがある ",
            exampleJapanese: " 日本へ行ったことがあります。 ",
            exampleTranslationZH: " 曾经去过日本。 ",
            jlpt: .n4,
            notes: " 注意否定形式 "
        )

        let content = try form.validatedContent()
        XCTAssertEqual(content.grammarForm, "～たことがある")
        XCTAssertEqual(content.meaningZH, "曾经做过……")
        XCTAssertEqual(content.usage, "表示过去经历")
        XCTAssertEqual(content.connection, "动词た形 + ことがある")
        XCTAssertEqual(content.example?.japanese, "日本へ行ったことがあります。")
        XCTAssertEqual(content.example?.translationZH, "曾经去过日本。")
        XCTAssertEqual(content.jlpt, .n4)
        XCTAssertEqual(content.notes, "注意否定形式")

        XCTAssertThrowsError(try GrammarFormData(meaningZH: "经历").validatedContent()) {
            XCTAssertEqual($0 as? GrammarValidationError, .grammarFormRequired)
        }
        XCTAssertThrowsError(try GrammarFormData(grammarForm: "～たことがある").validatedContent()) {
            XCTAssertEqual($0 as? GrammarValidationError, .meaningRequired)
        }
        XCTAssertThrowsError(
            try GrammarFormData(
                grammarForm: "～たことがある",
                meaningZH: "经历",
                exampleTranslationZH: "去过日本"
            ).validatedContent()
        ) {
            XCTAssertEqual($0 as? GrammarValidationError, .exampleJapaneseRequired)
        }
    }

    func testGrammarServiceUsesInjectedIdentityAndClock() async throws {
        let repository = GrammarRepositorySpy()
        let stableID = UUID()
        let noteID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_768_478_500)
        let service = GrammarService(
            repository: repository,
            now: { timestamp },
            makeID: { stableID }
        )

        let draft = try await service.saveDraft(
            id: nil,
            deckID: nil,
            formData: GrammarFormData(grammarForm: "途中")
        )
        XCTAssertEqual(draft.id, stableID)
        XCTAssertEqual(draft.updatedAt, timestamp)

        _ = try await service.updateGrammar(
            id: noteID,
            formData: GrammarFormData(grammarForm: "～ながら", meaningZH: "一边……一边……")
        )
        let edit = await repository.capturedEdit()
        XCTAssertEqual(edit?.id, noteID)
        XCTAssertEqual(edit?.newExampleID, stableID)
        XCTAssertEqual(edit?.date, timestamp)
    }

    func testTagNormalizationCollapsesEquivalentNamesAndWhitespace() throws {
        let fullWidth = try KnowledgeTagName(validating: "  Ｎ５　重点  ")
        let ascii = try KnowledgeTagName(validating: "n5  重点")
        XCTAssertEqual(fullWidth.displayName, "Ｎ５ 重点")
        XCTAssertEqual(fullWidth.normalizedName, "n5 重点")
        XCTAssertEqual(fullWidth.normalizedName, ascii.normalizedName)
        XCTAssertThrowsError(try KnowledgeTagName(validating: "   ")) {
            XCTAssertEqual($0 as? KnowledgeTagValidationError, .empty)
        }
    }

    func testKnowledgePointServiceDeduplicatesTagsBeforeRepositoryWrite() async throws {
        let repository = KnowledgePointRepositorySpy()
        let service = KnowledgePointService(repository: repository)
        let noteID = UUID()

        let updated = try await service.replaceTags(
            noteID: noteID,
            rawNames: ["N5", "ｎ５", " 动漫 ", "动漫"]
        )

        XCTAssertTrue(updated)
        let captured = await repository.capturedTags()
        XCTAssertEqual(captured?.noteID, noteID)
        XCTAssertEqual(captured?.tags.map(\.normalizedName), ["n5", "动漫"])
        XCTAssertEqual(captured?.tags.map(\.name), ["N5", "动漫"])
    }
}

private actor GrammarRepositorySpy: GrammarRepository {
    struct Edit: Sendable {
        let id: UUID
        let newExampleID: UUID
        let date: Date
    }

    private var draft: GrammarDraft?
    private var edit: Edit?

    func fetchGrammar(id: UUID) async throws -> GrammarNote? { nil }

    func saveGrammarDraft(_ draft: GrammarDraft) async throws {
        self.draft = draft
    }

    func fetchLatestGrammarDraft() async throws -> GrammarDraft? { draft }

    func fetchGrammarDraft(id: UUID) async throws -> GrammarDraft? {
        draft?.id == id ? draft : nil
    }

    func deleteGrammarDraft(id: UUID) async throws {
        if draft?.id == id {
            draft = nil
        }
    }

    func updateGrammar(
        id: UUID,
        content: ValidatedGrammarContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> GrammarNote? {
        edit = Edit(id: id, newExampleID: newExampleID, date: date)
        return nil
    }

    func capturedEdit() -> Edit? { edit }
}

private actor KnowledgePointRepositorySpy: KnowledgePointRepository {
    struct Tags: Sendable {
        let noteID: UUID
        let tags: [KnowledgeTag]
    }

    private var tags: Tags?

    func fetchKnowledgePointSummaries(deckID: UUID) async throws -> [KnowledgePointSummary] { [] }
    func fetchFavoriteSummaries() async throws -> [KnowledgePointSummary] { [] }
    func fetchDuplicateSummaries(
        kind: KnowledgePointKind,
        headword: String,
        reading: String?,
        excluding noteID: UUID?
    ) async throws -> [KnowledgePointSummary] { [] }
    func fetchMetadata(noteID: UUID) async throws -> KnowledgePointMetadata? { nil }
    func setFavorite(noteID: UUID, isFavorite: Bool, at date: Date) async throws -> Bool { true }

    func replaceTags(noteID: UUID, tags: [KnowledgeTag], at date: Date) async throws -> Bool {
        self.tags = Tags(noteID: noteID, tags: tags)
        return true
    }

    func capturedTags() -> Tags? { tags }

    func moveKnowledgePoint(
        noteID: UUID,
        to destinationDeckID: UUID,
        at date: Date
    ) async throws -> KnowledgePointMoveResult { .moved(cardCount: 0) }

    func fetchDeletionImpact(noteID: UUID) async throws -> KnowledgePointDeletionImpact? { nil }

    func deleteKnowledgePoint(noteID: UUID) async throws -> KnowledgePointDeletionResult { .notFound }
}
