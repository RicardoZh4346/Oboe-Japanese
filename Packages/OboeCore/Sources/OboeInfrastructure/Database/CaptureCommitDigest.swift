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

    /// v0.7.0 S12：sentence commit 的 digest——覆盖全部 Cloze 逻辑内容
    ///（快照/hash/range/surface/lemma/reading/answers/hint/meaning），
    /// 同 operationID 的不同挖空参数会被判为 payload 冲突。
    static func sentence(_ commit: SentenceContentCommit) -> String {
        var fields: [String?] = [
            "sentence",
            commit.deckID.uuidString,
            commit.cloze.sentenceSnapshot,
            commit.cloze.sentenceSHA256,
            String(commit.cloze.range.version),
            String(commit.cloze.range.utf16Start),
            String(commit.cloze.range.utf16Length),
            commit.cloze.targetSurface,
            commit.cloze.targetLemma,
            commit.cloze.targetReading,
            commit.cloze.hint,
            commit.meaningZH,
            commit.notes,
            commit.card.templateKind.rawValue,
            commit.origin.rawValue,
            commit.sourceText
        ]
        // answers 顺序本身是内容（用户确认序），不做排序归并。
        fields.append(contentsOf: commit.cloze.acceptedAnswers)
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
            // v19 定位列：Reader 来源的同一确认重试产生同一组字段；
            // 改了定位的重试判冲突（与其他内容字段同规则）。
            context.readerDocumentID?.uuidString,
            context.readerChapterID?.uuidString,
            context.readerLocation.map {
                [
                    String($0.version),
                    String($0.chapterOrdinal),
                    String($0.blockOrdinal),
                    String($0.utf16Offset),
                    $0.blockTextHash,
                    $0.prefix,
                    $0.suffix,
                    $0.cueStartMilliseconds.map(String.init) ?? ""
                ].joined(separator: ":")
            },
            context.selectedSurface,
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
