import OboeDomain
import SwiftUI

extension ReviewRating {
    var title: String {
        switch self {
        case .again: "重来"
        case .hard: "困难"
        case .good: "良好"
        case .easy: "简单"
        }
    }

    var identifier: String {
        switch self {
        case .again: "again"
        case .hard: "hard"
        case .good: "good"
        case .easy: "easy"
        }
    }

    var tint: Color {
        switch self {
        case .again: .red
        case .hard: .gray
        case .good: OboeTheme.Colors.accent
        case .easy: Color(red: 0.34, green: 0.62, blue: 0.94)
        }
    }

    var foregroundTint: Color {
        switch self {
        case .again: .red
        case .hard: Color(.darkGray)
        case .good: OboeTheme.Colors.accent
        case .easy: Color(red: 0.12, green: 0.44, blue: 0.84)
        }
    }
}

extension RecallComparison {
    /// Answer-face feedback copy for typed recall (T13). Honest wording:
    /// "different" only means the strings differ — synonyms, missing readings
    /// and unlisted kanji variants exist — so the learner still self-assesses
    /// with the four rating buttons. Never a correctness verdict.
    var feedbackText: String {
        switch self {
        case .matched: "和标准答案一致。"
        case .close: "和标准答案接近，请对照差异自评。"
        case .different: "写法不同，请对照答案自评。"
        }
    }

    var tint: Color {
        switch self {
        case .matched: OboeTheme.Colors.accent
        case .close: .orange
        case .different: .secondary
        }
    }
}
