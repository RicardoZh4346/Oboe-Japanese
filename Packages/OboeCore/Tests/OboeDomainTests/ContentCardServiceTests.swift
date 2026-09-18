import Foundation
import XCTest
@testable import OboeDomain

final class ContentCardServiceTests: XCTestCase {
    func testCommitRequiresDeckAndCardDirection() async throws {
        let service = ContentCardService(repository: ContentCardRepositorySpy())

        await XCTAssertThrowsErrorAsync(
            try await service.commitVocabulary(
                draftID: nil,
                deckID: nil,
                formData: VocabularyFormData(headword: "食べる", meaningZH: "吃"),
                directions: [.japaneseToChinese]
            )
        ) { error in
            XCTAssertEqual(error as? ContentCardError, .deckRequired)
        }
        await XCTAssertThrowsErrorAsync(
            try await service.commitGrammar(
                draftID: nil,
                deckID: UUID(),
                formData: GrammarFormData(grammarForm: "～ながら", meaningZH: "一边……一边……"),
                includesDirection: false
            )
        ) { error in
            XCTAssertEqual(error as? ContentCardError, .cardDirectionRequired)
        }
    }

    func testVocabularyCommitMapsTwoDirectionsAndDeduplicatesTags() async throws {
        let repository = ContentCardRepositorySpy()
        let ids = LockedIDSequence((0..<8).map { _ in UUID() })
        let timestamp = Date(timeIntervalSince1970: 100)
        let service = ContentCardService(
            repository: repository,
            now: { timestamp },
            makeID: { ids.next() }
        )
        let deckID = UUID()

        let result = try await service.commitVocabulary(
            draftID: UUID(),
            deckID: deckID,
            formData: VocabularyFormData(headword: " 食べる ", meaningZH: " 吃 "),
            directions: [.japaneseToChinese, .chineseToJapanese],
            rawTagNames: [" N5 ", "ｎ５"]
        )

        let commit = await repository.vocabularyCommit()
        XCTAssertEqual(result.cardCount, 2)
        XCTAssertEqual(commit?.deckID, deckID)
        XCTAssertEqual(
            Set(commit?.cards.map(\.templateKind) ?? []),
            [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        XCTAssertEqual(commit?.tags.map(\.normalizedName), ["n5"])
        XCTAssertEqual(commit?.content.headword, "食べる")
        XCTAssertEqual(commit?.createdAt, timestamp)
    }
}

private actor ContentCardRepositorySpy: ContentCardRepository {
    private var capturedVocabulary: VocabularyContentCommit?

    func commitVocabulary(
        _ commit: VocabularyContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        capturedVocabulary = commit
        return ContentCommitResult(noteID: commit.noteID, cardCount: commit.cards.count)
    }

    func commitGrammar(
        _ commit: GrammarContentCommit,
        capture: CaptureCommitContext?
    ) async throws -> ContentCommitResult {
        ContentCommitResult(noteID: commit.noteID, cardCount: 1)
    }

    func fetchCardDirections(noteID: UUID) async throws -> [CardDirectionState] {
        []
    }

    func replaceEnabledCardDirections(
        _ replacement: CardDirectionReplacement
    ) async throws -> [CardDirectionState] {
        []
    }

    func vocabularyCommit() -> VocabularyContentCommit? {
        capturedVocabulary
    }
}

private final class LockedIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return ids.removeFirst()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown")
    } catch {
        errorHandler(error)
    }
}
