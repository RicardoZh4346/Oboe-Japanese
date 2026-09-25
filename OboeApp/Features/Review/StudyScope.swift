import Foundation
import OboeDomain

/// 复习页面 scope：牌组/标题是展示信息，队列来源决定驱动路径——
/// `.normal` 走今日计划；`.customStudy` 走冻结队列的专项会话
/// （设计 §7.4：sessionID 进 Hashable，scene 缓存随 session+世代
/// 隔离，resize/rotation 不重建会话）。
struct StudyScope: Hashable {
    enum QueueSource: Hashable {
        case normal
        case customStudy(sessionID: UUID, mode: CustomStudyMode)
    }

    let deckID: UUID?
    let title: String
    let queueSource: QueueSource

    init(
        deckID: UUID? = nil,
        title: String,
        queueSource: QueueSource = .normal
    ) {
        self.deckID = deckID
        self.title = title
        self.queueSource = queueSource
    }

    var customSessionID: UUID? {
        if case .customStudy(let sessionID, _) = queueSource { return sessionID }
        return nil
    }

    var customMode: CustomStudyMode? {
        if case .customStudy(_, let mode) = queueSource { return mode }
        return nil
    }
}
