import Foundation

/// v0.7.0 S20 统计口径的纯计算件（冻结 §11.1 / D09）。
///
/// 放在 Domain 的理由：学习日分桶（04:00 边界）与「实测保持率样本谓词」
/// 是纯函数——Infrastructure 的 SQL 谓词必须与这里的语义逐条对应，
/// 测试两侧互验，避免统计层悄悄换分母（契约纪律：口径变更须升级
/// metric version，不静默改）。
///
/// 时区纪律：一切日历运算使用学习日记录的 `timeZoneID`，绝不使用设备
/// 当前时区重分历史日志。
public enum StatisticsMetricMath {

    /// 实测保持率样本的最小间隔：评分距「上次正式评分」≥1 个自然日
    /// （24h）。FSRS 的 elapsed_days 按 floor(Δt/86400) 取整，这里与
    /// SQL 谓词统一用毫秒差 ≥ 86400_000，避免「同日两次 review 被算成
    /// 长期保持样本」。
    public static let minimumRetentionGapMilliseconds: Int64 = 86_400_000

    /// 实测保持率样本谓词（冻结 §11.1「实测保持率」行）：
    /// 非首学 + 评分前 `state = review` + 距上次正式评分 ≥ 1 日。
    /// `previousState` 是评分写日志时冻结的快照——`lastReviewAt` 为 NULL
    /// 时必然不入选（new→review 首次过渡不计）。
    public static func isRetentionSample(
        wasFirstStudy: Bool,
        previousState: ReviewSchedulingSnapshot,
        reviewedAt: Date
    ) -> Bool {
        guard !wasFirstStudy,
              previousState.scheduling.state == .review,
              let lastReviewAt = previousState.scheduling.lastReviewAt else {
            return false
        }
        return reviewedAt.timeIntervalSince(lastReviewAt) * 1_000
            >= Double(minimumRetentionGapMilliseconds)
    }
}

/// 学习日分桶：把任意瞬时映射为「04:00 学习日」相对参考学习日的偏移。
///
/// 原理：学习日 D 覆盖 [D 04:00, D+1 04:00)，等价于 `instant - 4h` 的
/// 日历日 = D。因此 offset = localDate(instant - 4h) − localDate(ref)。
/// 两个本地日期的差在同一 gregorian 日历上取 `.day` 分量——DST 切换日
/// （23/25 小时）也按日历日走，与 `StudyDayBoundaryCalculator` 一致。
public enum StudyDayBucketMath {

    /// `instant` 所属学习日的本地日历日（时区 `timeZoneID`，边界沿用
    /// `StudyDayBoundaryCalculator.rolloverHour`）。返回值为该日历日的
    /// startOfDay（仅作日历日载体，不直接表示学习日起点）。
    public static func localDateIndex(
        of instant: Date,
        timeZoneID: String
    ) throws -> Date {
        let calendar = try calendar(timeZoneID: timeZoneID)
        let shifted = instant.addingTimeInterval(
            -TimeInterval(StudyDayBoundaryCalculator.rolloverHour) * 3_600
        )
        return calendar.startOfDay(for: shifted)
    }

    /// `instant` 相对参考学习日 `referenceLocalDate`（"YYYY-MM-DD"）的
    /// 偏移天数：0 = 同一学习日，负值 = 参考日之前（过期），正值 =
    /// 未来第 N 个学习日。
    public static func dayOffset(
        of instant: Date,
        referenceLocalDate: String,
        timeZoneID: String
    ) throws -> Int {
        let calendar = try calendar(timeZoneID: timeZoneID)
        let parts = referenceLocalDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let reference = calendar.date(
                  from: DateComponents(
                      timeZone: calendar.timeZone,
                      year: year, month: month, day: day
                  )
              ) else {
            throw StudyDayPlanningError.invalidPersistedStudyDay
        }
        let index = try localDateIndex(of: instant, timeZoneID: timeZoneID)
        guard let offset = calendar.dateComponents(
            [.day],
            from: reference,
            to: index
        ).day else {
            throw StudyDayPlanningError.invalidStudyDayBoundary
        }
        return offset
    }

    private static func calendar(timeZoneID: String) throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneID) else {
            throw StudyDayPlanningError.invalidTimeZone(timeZoneID)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
