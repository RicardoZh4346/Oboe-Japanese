import Foundation

/// Note 的牌组成员关系（T01 冻结口径）。
///
/// `notes.deck_id` 语义收窄为归属牌组（home deck），`note_decks` 表为
/// 权威的多对多成员关系。不变量：恰好一个 home deck，且 home deck
/// 必须同时是成员；成员集合至少一个。Card、FSRS 状态与复习日志挂在
/// Note 上，成员关系不复制这些记录。
public struct NoteDeckMembership: Equatable, Sendable {
    public let homeDeckID: UUID
    public let deckIDs: Set<UUID>

    public init(homeDeckID: UUID, deckIDs: Set<UUID>) throws {
        guard !deckIDs.isEmpty else {
            throw NoteDeckMembershipError.atLeastOneDeckRequired
        }
        guard deckIDs.contains(homeDeckID) else {
            throw NoteDeckMembershipError.homeDeckMustBeMember
        }
        self.homeDeckID = homeDeckID
        self.deckIDs = deckIDs
    }
}

/// 多牌组选择 UI 的工作状态（T07）：成员集合 + home 归属。允许中间态
/// （home 暂缺），提交前经 `normalized` 归一化。
public struct DeckMembershipSelection: Equatable, Sendable {
    public var homeDeckID: UUID?
    public var deckIDs: Set<UUID>

    public init(homeDeckID: UUID? = nil, deckIDs: Set<UUID> = []) {
        self.homeDeckID = homeDeckID
        self.deckIDs = deckIDs
    }

    public init(membership: NoteDeckMembership) {
        homeDeckID = membership.homeDeckID
        deckIDs = membership.deckIDs
    }

    /// 单个牌组的初始选择：home 与唯一成员同为一个牌组。
    public init(single deckID: UUID) {
        homeDeckID = deckID
        deckIDs = [deckID]
    }

    /// 归一化到给定牌组列表：剔除已删除的牌组；home 不在成员中时按
    /// `preferredHomeID`（当前主牌组）→ 列表顺序首个成员 依次回退。
    /// 成员为空时返回空选择（home 为 nil），由调用方决定是否允许提交。
    public func normalized(
        decks: [DeckSummary],
        preferredHomeID: UUID? = nil
    ) -> DeckMembershipSelection {
        let validIDs = Set(decks.map(\.id))
        let members = deckIDs.intersection(validIDs)
        let orderedMembers = decks.map(\.id).filter { members.contains($0) }
        let home: UUID?
        if let homeDeckID, members.contains(homeDeckID) {
            home = homeDeckID
        } else if let preferredHomeID, members.contains(preferredHomeID) {
            home = preferredHomeID
        } else {
            home = orderedMembers.first
        }
        return DeckMembershipSelection(homeDeckID: home, deckIDs: members)
    }

    /// 切换某个牌组的成员状态；移除 home 时按牌组顺序回退到首个剩余成员。
    /// 移除最后一个成员会被拒绝（返回 false）。
    @discardableResult
    public mutating func toggle(deckID: UUID, decks: [DeckSummary]) -> Bool {
        if deckIDs.contains(deckID) {
            guard deckIDs.count > 1 else { return false }
            deckIDs.remove(deckID)
            if homeDeckID == deckID {
                homeDeckID = decks.map(\.id).first(where: { deckIDs.contains($0) })
            }
        } else {
            deckIDs.insert(deckID)
            if homeDeckID == nil { homeDeckID = deckID }
        }
        return true
    }
}

public enum NoteDeckMembershipError: Error, Equatable, Sendable {
    case atLeastOneDeckRequired
    case homeDeckMustBeMember
    /// 共享 Note 删除牌组时只允许移除成员关系；禁止删除最后一个
    /// membership，也禁止在未先切换 home 的情况下移除 home membership。
    case cannotRemoveLastMembership
    case cannotRemoveHomeMembership
    /// membership 替换目标 Note 不存在。
    case noteNotFound
    /// membership 目标集合包含不存在的牌组。
    case deckNotFound(UUID)
}
