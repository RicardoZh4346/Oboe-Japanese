import Foundation

/// 词性原子白名单（T01 冻结口径）：新建/编辑界面只允许从该集合多选，
/// 底层仍以固定顺序用 " / " 连接成单一字符串保存，兼容现有数据库、
/// 备份和内置 JLPT 数据。CaseIterable 声明顺序即 UI 展示与规范化排序。
public enum VocabularyPartOfSpeech: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case noun = "名词"
    case pronoun = "代词"
    case godanVerb = "五段动词"
    case ichidanVerb = "一段动词"
    case suruVerb = "する动词"
    case kuruVerb = "くる动词"
    case transitive = "他动词"
    case intransitive = "自动词"
    case iAdjective = "い形容词"
    case naAdjective = "な形容词"
    case adverb = "副词"
    case particle = "助词"
    case auxiliaryVerb = "助动词"
    case conjunction = "接续词"
    case interjection = "感叹词"
    case counter = "量词"
    case prefix = "接头词"
    case suffix = "接尾词"
    case expression = "表达"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public extension VocabularyPartOfSpeech {
    /// Splits a stored `part_of_speech` string on "/" into atoms. Known atoms
    /// come back in canonical order; unknown legacy strings are preserved
    /// verbatim so callers can display them read-only until the user
    /// re-picks — they are never silently dropped.
    static func parse(_ raw: String) -> (known: [Self], unknown: [String]) {
        let atoms = raw
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var known = Set<Self>()
        var unknown: [String] = []
        for atom in atoms {
            if let value = Self(rawValue: atom) {
                known.insert(value)
            } else if !unknown.contains(atom) {
                unknown.append(atom)
            }
        }
        return (known.sorted(), unknown)
    }

    /// Canonical stored form: atoms sorted by whitelist order and joined with
    /// " / ". Returns nil when the selection is empty.
    static func format(_ parts: some Sequence<Self>) -> String? {
        let sorted = Set(parts).sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.map(\.rawValue).joined(separator: " / ")
    }
}
