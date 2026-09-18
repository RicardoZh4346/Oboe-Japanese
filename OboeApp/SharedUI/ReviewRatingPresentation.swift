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
