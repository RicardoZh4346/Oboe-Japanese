import Foundation

enum StudyTimeText {
    static func until(_ date: Date) -> String {
        interval(seconds: max(0, date.timeIntervalSinceNow))
    }

    static func interval(until date: Date) -> String {
        interval(seconds: max(0, date.timeIntervalSinceNow))
    }

    private static func interval(seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60))) 分钟" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600))) 小时" }
        return "\(max(1, Int(seconds / 86_400))) 天"
    }
}
