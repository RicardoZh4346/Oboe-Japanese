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
        fields.append(contentsOf: sourceContextFields(commit.sourceContext))
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
        fields.append(contentsOf: sourceContextFields(commit.sourceContext))
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

    /// 来源记录只折逻辑内容字段——id/noteID/createdAt 每次 commit 都
    /// 不同，不属于「用户确认的同一内容」。重试同 operationID 得同一
    /// hash；改了来源文本/词典条目的重试判冲突（设计 §6.2）。
    private static func sourceContextFields(_ context: SourceContext?) -> [String?] {
        guard let context else { return [] }
        return [
            "source_context",
            context.sourceType.rawValue,
            context.originalSentence,
            context.surroundingText,
            context.sourceTitle,
            context.sourceURL,
            context.sourceApp,
            context.imageReference,
            context.dictionaryEntryID.map(String.init),
            context.dictionaryVersion,
            context.dictionarySenseKey,
            context.selectedGlossLanguage,
            context.isPrimary ? "1" : "0"
        ]
    }

    private static func digest(_ fields: [String?]) -> String {
        let joined = fields
            .map { $0 ?? "\u{1E}" }
            .joined(separator: "\u{1F}")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
