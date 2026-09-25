import Foundation

/// practiceOnly 模式下的一次评分记录（v16 `practice_attempts`，
/// 设计 §7.2 / D06）。
///
/// 语义红线：practice 提交**不调用 FSRS、不写 review_logs、不动
/// firstStudiedAt/新词额度/统计**——它只证明「这张卡在这次专项练习里
/// 被评过」。`cardKey`/`noteID` 是历史锚点：Card 删除后历史仍按
/// card_key 保留，因此两列不加 FK（与 `review_logs.card_key` 同款
/// 宽松历史约定）。
///
/// 幂等：`eventID` 是提交幂等键（UNIQUE）。同 eventID + 同内容的重放
/// 返回已存行；同 eventID 内容不同（sessionID/cardKey/noteID/rating/
/// answeredAt/durationMilliseconds/contentVersion 任一不一致）抛
/// `CustomStudyRepositoryError.conflictingEventID`。`id` 是行级
/// 代理键，不参与幂等比较。
///
/// 撤销：`undoneAt` 置位即撤销（恢复队列位置由会话层处理），不删行、
/// 不回填——与 review_logs 的 undo 语义平行，但完全不碰调度状态。
public struct PracticeAttempt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let eventID: UUID
    public let sessionID: UUID
    /// 历史锚点 = 提交时的 Card id（Card 删除后保留）。
    public let cardKey: UUID
    public let noteID: UUID
    public let rating: ReviewRating
    public let answeredAt: Date
    public let durationMilliseconds: Int
    /// 评分时面对的 Note 内容版本——用于把历史标注在对应版本上。
    public let contentVersion: Int
    public let undoneAt: Date?

    public init(
        id: UUID,
        eventID: UUID,
        sessionID: UUID,
        cardKey: UUID,
        noteID: UUID,
        rating: ReviewRating,
        answeredAt: Date,
        durationMilliseconds: Int,
        contentVersion: Int,
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.sessionID = sessionID
        self.cardKey = cardKey
        self.noteID = noteID
        self.rating = rating
        self.answeredAt = answeredAt
        self.durationMilliseconds = durationMilliseconds
        self.contentVersion = contentVersion
        self.undoneAt = undoneAt
    }
}

/// scheduled 模式下正式提交的来源登记（v16 `scheduled_review_origins`）。
///
/// 一次 `.customScheduled` 评分落正式 `review_logs` 之后，在同一事务内
/// 登记本行：把 review_log 的 `eventID` 归因到发起它的专项 session。
/// undo 正式评分时经 origin 校验对应模式（custom 撤销不再依赖原
/// daily_tasks 成员资格）；origin 行保留审计，不删除到无法识别。
public struct ScheduledReviewOrigin: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let sessionID: UUID
    public let submissionKind: ScheduledReviewSubmissionKind

    public init(
        eventID: UUID,
        sessionID: UUID,
        submissionKind: ScheduledReviewSubmissionKind = .customScheduled
    ) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.submissionKind = submissionKind
    }
}

/// `scheduled_review_origins.submission_kind`（冻结 CHECK：
/// 'customScheduled'）。预留枚举扩展位——首版只有专项正式提交一种。
public enum ScheduledReviewSubmissionKind: String, Codable, CaseIterable, Sendable {
    case customScheduled
}

/// 正式评分提交路径的事务层策略（设计 §7.3，D06 冻结）。
///
/// - `normal`：保持现有 due 与 daily_tasks 成员检查。
/// - `customScheduled(sessionID:)`：专项提前评分——由 service 构造，
///   事务层验证真实 session、mode = scheduled、冻结队列成员与
///   generation；仍验证启用状态、stateVersion、contentVersion、有效
///   study day、时钟单调、牌组归因。UI 不能传任意 allowEarly 绕过。
///
/// 接入点（主 agent 在 S08 后半完成）：`SubmitReview`/`commitReview`
/// 增加 policy 参数；`.customScheduled` 分支跳过「非 new 且未来到期
/// 拒绝」与「daily_tasks 成员」两项检查，改为上述 session 校验，并把
/// `ScheduledReviewOrigin` 与 review_log 写进同一事务（持久层提供
/// `GRDBCustomStudyRepository.insertScheduledOrigin(_:in:)` 共享写
/// 函数）。undo 路径同样按 origin 分流：custom 提交不查 daily_tasks。
public enum ReviewSubmissionPolicy: Equatable, Sendable {
    case normal
    case customScheduled(sessionID: UUID)
}
