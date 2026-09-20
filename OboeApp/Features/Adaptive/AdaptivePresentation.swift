import OboeDomain
import SwiftUI

/// Display text for the Adaptive center. Deliberately keeps the product
/// wording honest: leech is "可能难记", never "已掌握" or a mastery claim
/// (requirement §4.1/§5.1).
extension AdaptiveCardStatus {
    var title: String {
        switch self {
        case .leech: "经常遗忘"
        case .warning: "近期偏难"
        case .normal: "正常"
        }
    }

    var tint: Color {
        switch self {
        case .leech: .red
        case .warning: .orange
        case .normal: .secondary
        }
    }
}

extension AdaptiveTrigger {
    /// Why the rule fired — one line each, backed by `AdaptiveMetrics`.
    var explanation: String {
        switch self {
        case .lifetimeLapses: "累计遗忘次数达到阈值"
        case .recentAgainBurst: "最近 10 次有效评分中重来过半"
        case .dueAgainStreak: "最近连续到期复习均为重来"
        case .persistentDifficulty: "难度偏高且近期仍频繁重来"
        }
    }
}

extension AdaptiveListFilter {
    var title: String {
        switch self {
        case .leech: "易错"
        case .warning: "预警"
        case .suspended: "已暂停"
        }
    }

    var emptyTitle: String {
        switch self {
        case .leech: "当前没有易错卡"
        case .warning: "当前没有预警卡"
        case .suspended: "没有已暂停的卡"
        }
    }

    var emptyDescription: String {
        switch self {
        case .leech: "最近复习表现稳定，暂无需要特别关注的卡片。"
        case .warning: "没有接近易错阈值的卡片。"
        case .suspended: "暂停的卡会保留学习记录，可随时重新启用。"
        }
    }
}

extension CardTemplateKind {
    /// Direction label for list rows and the detail header.
    var adaptiveDirectionLabel: String {
        switch self {
        case .vocabularyJapaneseToChinese: "日语 → 中文"
        case .vocabularyChineseToJapanese: "中文 → 日语"
        case .vocabularyListening: "听力"
        case .grammarFormToExplanation: "语法形式 → 解释"
        }
    }
}

extension AdaptiveReviewSample {
    /// History rows label the note content version only when the visible set
    /// actually spans a version change (design §4.1).
    var contentVersionBadge: String {
        "v\(contentVersion)"
    }
}
