import Foundation

/// Counts Tokyo-style pitch morae in a Japanese reading.
///
/// The reading is normalized first (compatibility mapping, katakana →
/// hiragana, canonical precompose) so half-width katakana and either kana
/// script count identically. Counting rules:
/// - every full-size kana starts a new mora;
/// - small combining kana (ぁぃぅぇぉゃゅょゎゕゖ and katakana equivalents)
///   attach to the preceding mora, so ティ or キャ each count once;
/// - 促音 っ/ッ, 拨音 ん/ン and 長音符 ー each form their own mora;
/// - whitespace is ignored; any other character (kanji, latin) counts as a
///   single mora — the counter is intended for kana readings and only feeds
///   the `pitch <= moraCount` sanity bound.
public enum JapaneseMoraCounter {
    public static func moraCount(of reading: String) -> Int {
        let scalars = normalizedScalars(of: reading)
        var count = 0
        for scalar in scalars {
            guard !CharacterSet.whitespaces.contains(scalar) else {
                continue
            }
            if isCombiningSmallKana(scalar), count > 0 {
                continue
            }
            count += 1
        }
        return count
    }

    static func normalizedScalars(of reading: String) -> [UnicodeScalar] {
        let normalized = reading
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
        let mapped = normalized.unicodeScalars.map { scalar -> UnicodeScalar in
            switch scalar.value {
            case 0x30A1...0x30F6, 0x30FD...0x30FE:
                return UnicodeScalar(scalar.value - 0x60) ?? scalar
            default:
                return scalar
            }
        }
        return String(String.UnicodeScalarView(mapped))
            .precomposedStringWithCanonicalMapping
            .unicodeScalars
            .map { $0 }
    }

    private static func isCombiningSmallKana(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        // ぁぃぅぇぉゃゅょゎゕゖ — 促音 っ 与拨音 ん 不占位，各自独立成 mora。
        case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049,
             0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096:
            return true
        default:
            return false
        }
    }
}
