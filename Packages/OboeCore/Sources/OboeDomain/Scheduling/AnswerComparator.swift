import Foundation

/// Offline, pure-function comparison of a confirmed typed answer against the
/// card's accepted answers (design §7.2). Feedback only — it never derives a
/// ReviewRating, writes no ReviewLog and touches no persistence.
public enum AnswerComparator {
    /// The accepted set is the non-empty headword and reading: either
    /// normalized equality counts, so kanji and kana stay interchangeable —
    /// "おかあさん" matches the reading even when the headword is "お母さん".
    /// Returns nil when nothing can be compared (blank input or no accepted
    /// answer), which the confirm flow already rejects before reaching here.
    public static func compare(
        input: String,
        headword: String?,
        reading: String?
    ) -> RecallComparison? {
        let normalizedInput = normalize(input)
        guard !normalizedInput.isEmpty else { return nil }
        let accepted = Set(
            [headword, reading]
                .compactMap { $0.map(normalize) }
                .filter { !$0.isEmpty }
        )
        guard !accepted.isEmpty else { return nil }
        if accepted.contains(normalizedInput) { return .matched }
        let characters = Array(normalizedInput)
        guard characters.count >= 4, isPureKana(normalizedInput) else {
            return .different
        }
        let isClose = accepted.contains { candidate in
            let candidateCharacters = Array(candidate)
            return abs(candidateCharacters.count - characters.count) <= 1
                && editDistance(between: characters, and: candidateCharacters) == 1
        }
        return isClose ? .close : .different
    }

    /// trim → NFKC → katakana→hiragana → NFC — identical to the search/index
    /// normalizer so typed answers see the same text the database stores.
    /// Meaningful punctuation, long vowels and geminates stay distinct;
    /// romaji is never transliterated.
    private static func normalize(_ value: String) -> String {
        SearchTextNormalizer.normalize(value)
    }

    /// Hiragana block plus the prolonged sound mark; kanji, punctuation,
    /// ASCII and surviving katakana (e.g. ヷ) make the string non-kana.
    private static func isPureKana(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            (0x3040 ... 0x309F).contains($0.value) || $0.value == 0x30FC
        }
    }

    private static func editDistance(
        between source: [Character],
        and target: [Character]
    ) -> Int {
        if source == target { return 0 }
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }
        var previous = Array(0 ... target.count)
        for (row, sourceCharacter) in source.enumerated() {
            var current = [Int](repeating: 0, count: target.count + 1)
            current[0] = row + 1
            for (column, targetCharacter) in target.enumerated() {
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (sourceCharacter == targetCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[target.count]
    }
}
