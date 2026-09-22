import Foundation

enum StudyTimeText {
    static func until(_ date: Date) -> String {
        interval(seconds: max(0, date.timeIntervalSinceNow))
    }

    static func interval(until date: Date) -> String {
        interval(seconds: max(0, date.timeIntervalSinceNow))
    }

    /// 已发生的用时（毫秒）压缩展示，供统计行使用。
    static func duration(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3_600) 小时 \(seconds % 3_600 / 60) 分钟"
    }

    private static func interval(seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60))) 分钟" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600))) 小时" }
        return "\(max(1, Int(seconds / 86_400))) 天"
    }
}
