import CryptoKit
import Foundation
import OboeDomain

/// Deterministic content digest for capture commits. Covers only the logical
/// content (kind, deck, fields, card templates, source text, origin) — never
/// generated IDs or timestamps — so a retry of the same confirmation produces
/// the same hash while a different payload under the same operationID is caught.
enum CaptureCommitDigest {
    static func vocabulary(_ commit: VocabularyContentCommit) -> String {
        var fields: [String?] = [
            "vocabulary",
            commit.deckID.uuidString,
            commit.content.headword,
            commit.content.reading,
            commit.content.meaningZH,
            commit.content.partOfSpeech,
            commit.content.jlpt?.rawValue,
            commit.content.notes,
            commit.content.example?.japanese,
            commit.content.example?.translationZH,
            commit.origin.rawValue,
            commit.sourceText
        ]
        fields.append(contentsOf: commit.tags.map(\.normalizedName).sorted())
        fields.append(
            contentsOf: commit.cards.map(\.templateKind.rawValue).sorted()
        )
        return digest(fields)
    }

    static func grammar(_ commit: GrammarContentCommit) -> String {
        var fields: [String?] = [
            "grammar",
            commit.deckID.uuidString,
            commit.content.grammarForm,
            commit.content.meaningZH,
            commit.content.usage,
            commit.content.connection,
            commit.content.jlpt?.rawValue,
            commit.content.notes,
            commit.content.example?.japanese,
            commit.content.example?.translationZH,
            commit.card.templateKind.rawValue,
            commit.origin.rawValue,
            commit.sourceText
        ]
        fields.append(contentsOf: commit.tags.map(\.normalizedName).sorted())
        return digest(fields)
    }

    static func batch(_ batch: SentenceAnalysisCardBatchCommit) -> String {
        var fields: [String?] = ["sentence_analysis_batch", batch.deckID.uuidString]
        fields.append(
            contentsOf: batch.items.map { item in
                switch item {
                case let .vocabulary(commit): vocabulary(commit)
                case let .grammar(commit): grammar(commit)
                }
            }
        )
        return digest(fields)
    }

    private static func digest(_ fields: [String?]) -> String {
        let joined = fields
            .map { $0 ?? "\u{1E}" }
            .joined(separator: "\u{1F}")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
