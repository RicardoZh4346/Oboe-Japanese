import Foundation
import XCTest
@testable import OboeDomain

final class VocabularyServiceTests: XCTestCase {
    func testFormalContentValidationNormalizesFieldsAndRequiresJapaneseForTranslation() throws {
        let form = VocabularyFormData(
            headword: "  食べる  ",
            reading: "  たべる ",
            meaningZH: " 吃 ",
            partOfSpeech: " 一段动词 ",
            jlpt: .n5,
            exampleJapanese: " 毎朝パンを食べます。 ",
            exampleTranslationZH: " 我每天早上吃面包。 ",
            notes: " 常用词 "
        )

        let content = try form.validatedContent()
        XCTAssertEqual(content.headword, "食べる")
        XCTAssertEqual(content.reading, "たべる")
        XCTAssertEqual(content.meaningZH, "吃")
        XCTAssertEqual(content.partOfSpeech, "一段动词")
        XCTAssertEqual(content.jlpt, .n5)
        XCTAssertEqual(content.example?.japanese, "毎朝パンを食べます。")
        XCTAssertEqual(content.example?.translationZH, "我每天早上吃面包。")
        XCTAssertEqual(content.notes, "常用词")

        XCTAssertThrowsError(try VocabularyFormData(meaningZH: "吃").validatedContent()) {
            XCTAssertEqual($0 as? VocabularyValidationError, .headwordRequired)
        }
        XCTAssertThrowsError(try VocabularyFormData(headword: "食べる").validatedContent()) {
            XCTAssertEqual($0 as? VocabularyValidationError, .meaningRequired)
        }
        XCTAssertThrowsError(
            try VocabularyFormData(
                headword: "食べる",
                meaningZH: "吃",
                exampleTranslationZH: "翻译"
            ).validatedContent()
        ) {
            XCTAssertEqual($0 as? VocabularyValidationError, .exampleJapaneseRequired)
        }
    }

    func testCommitRequestRequiresAtLeastOneCardDirection() throws {
        let form = VocabularyFormData(headword: "食べる", meaningZH: "吃")
        XCTAssertThrowsError(
            try NewVocabularyCommitRequest(
                noteID: UUID(),
                deckID: UUID(),
                formData: form,
                directions: []
            )
        ) {
            XCTAssertEqual($0 as? VocabularyValidationError, .cardDirectionRequired)
        }

        let request = try NewVocabularyCommitRequest(
            noteID: UUID(),
            deckID: UUID(),
            formData: form,
            directions: [.japaneseToChinese]
        )
        XCTAssertEqual(request.directions, [.japaneseToChinese])
    }

    func testServiceUsesInjectedIdentityAndClockForDraftAndEdit() async throws {
        let repository = VocabularyRepositorySpy()
        let stableID = UUID()
        let noteID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_768_478_400.123)
        let service = VocabularyService(
            repository: repository,
            now: { timestamp },
            makeID: { stableID }
        )
        let draftForm = VocabularyFormData(headword: "途中", reading: "とちゅう")

        let draft = try await service.saveDraft(id: nil, deckID: nil, formData: draftForm)
        XCTAssertEqual(draft.id, stableID)
        XCTAssertEqual(draft.updatedAt, timestamp)
        let savedDraft = await repository.savedDraft()
        XCTAssertEqual(savedDraft, draft)

        _ = try await service.updateVocabulary(
            id: noteID,
            formData: VocabularyFormData(headword: "食べる", meaningZH: "吃")
        )
        let edit = await repository.capturedEdit()
        XCTAssertEqual(edit?.id, noteID)
        XCTAssertEqual(edit?.newExampleID, stableID)
        XCTAssertEqual(edit?.date, timestamp)
    }
}

private actor VocabularyRepositorySpy: VocabularyRepository {
    struct Edit: Sendable {
        let id: UUID
        let newExampleID: UUID
        let date: Date
    }

    private var draft: VocabularyDraft?
    private var edit: Edit?

    func fetchVocabularySummaries(deckID: UUID) async throws -> [VocabularyNoteSummary] {
        []
    }

    func fetchVocabulary(id: UUID) async throws -> VocabularyNote? {
        nil
    }

    func saveVocabularyDraft(_ draft: VocabularyDraft) async throws {
        self.draft = draft
    }

    func fetchLatestVocabularyDraft() async throws -> VocabularyDraft? {
        draft
    }

    func deleteVocabularyDraft(id: UUID) async throws {
        if draft?.id == id {
            draft = nil
        }
    }

    func updateVocabulary(
        id: UUID,
        content: ValidatedVocabularyContent,
        newExampleID: UUID,
        at date: Date
    ) async throws -> VocabularyNote? {
        edit = Edit(id: id, newExampleID: newExampleID, date: date)
        return nil
    }

    func savedDraft() -> VocabularyDraft? {
        draft
    }

    func capturedEdit() -> Edit? {
        edit
    }
}
