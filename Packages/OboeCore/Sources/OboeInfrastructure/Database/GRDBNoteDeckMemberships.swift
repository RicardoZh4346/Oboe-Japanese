import Foundation
import GRDB
import OboeDomain

/// `note_decks` 成员关系的共享读写辅助（设计 §4.2/§4.3）。
///
/// `note_decks` 是权威的多对多成员表，`notes.deck_id` 仅表示归属（home）
/// 牌组。所有成员关系替换都应在调用方的写事务内完成，保证原子性。
enum GRDBNoteDeckMemberships {
    /// 批量读取成员牌组集合，key/value 均为编码后的 UUID 字符串。
    static func fetchDeckIDMap(
        noteIDs: [String],
        in db: Database
    ) throws -> [String: Set<String>] {
        guard !noteIDs.isEmpty else { return [:] }
        let placeholders = noteIDs.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT note_id, deck_id FROM note_decks WHERE note_id IN (\(placeholders))",
            arguments: StatementArguments(noteIDs)
        )
        var map: [String: Set<String>] = [:]
        for row in rows {
            let noteID: String = row["note_id"]
            let deckID: String = row["deck_id"]
            map[noteID, default: []].insert(deckID)
        }
        return map
    }

    /// 读取单个 Note 的成员关系；Note 不存在时返回 nil。
    static func fetchMembership(
        noteID: UUID,
        in db: Database
    ) throws -> NoteDeckMembership? {
        let noteIDValue = DatabaseValueCodec.encode(noteID)
        guard let homeValue = try String.fetchOne(
            db,
            sql: "SELECT deck_id FROM notes WHERE id = ?",
            arguments: [noteIDValue]
        ) else {
            return nil
        }
        var deckIDValues = try fetchDeckIDMap(noteIDs: [noteIDValue], in: db)[noteIDValue] ?? []
        // 防御：home deck 必须同时是成员（v13 不变量）。
        deckIDValues.insert(homeValue)
        return try NoteDeckMembership(
            homeDeckID: DatabaseValueCodec.decodeUUID(homeValue),
            deckIDs: Set(try deckIDValues.map { try DatabaseValueCodec.decodeUUID($0) })
        )
    }

    /// 在同一事务内原子替换成员关系（设计 §4.3）：
    /// 校验 Note/牌组存在性与 home∈members，插入缺失成员、删除移除成员、
    /// 更新 `notes.deck_id` 与 `updated_at_ms`。任一步失败整体回滚。
    @discardableResult
    static func replaceMembership(
        noteID: UUID,
        deckIDs: Set<UUID>,
        homeDeckID: UUID,
        atMilliseconds: Int64,
        in db: Database
    ) throws -> NoteDeckMembership {
        let noteIDValue = DatabaseValueCodec.encode(noteID)
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ?)",
            arguments: [noteIDValue]
        ) == true else {
            throw NoteDeckMembershipError.noteNotFound
        }

        // 校验成员集合不变量（非空、home∈members）。
        let membership = try NoteDeckMembership(homeDeckID: homeDeckID, deckIDs: deckIDs)

        // 校验全部目标牌组存在。
        let targetDeckIDValues = deckIDs.map(DatabaseValueCodec.encode)
        let placeholders = targetDeckIDValues.map { _ in "?" }.joined(separator: ",")
        let existingDeckIDValues = Set(
            try String.fetchAll(
                db,
                sql: "SELECT id FROM decks WHERE id IN (\(placeholders))",
                arguments: StatementArguments(targetDeckIDValues)
            )
        )
        for deckID in deckIDs {
            guard existingDeckIDValues.contains(DatabaseValueCodec.encode(deckID)) else {
                throw NoteDeckMembershipError.deckNotFound(deckID)
            }
        }

        let currentDeckIDValues = try fetchDeckIDMap(noteIDs: [noteIDValue], in: db)[noteIDValue] ?? []
        let targetValues = Set(targetDeckIDValues)

        // 插入缺失成员。
        for deckIDValue in targetValues.subtracting(currentDeckIDValues) {
            try db.execute(
                sql: """
                    INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                    VALUES (?, ?, ?)
                    """,
                arguments: [noteIDValue, deckIDValue, atMilliseconds]
            )
        }
        // 删除被移除的成员。
        for deckIDValue in currentDeckIDValues.subtracting(targetValues) {
            try db.execute(
                sql: "DELETE FROM note_decks WHERE note_id = ? AND deck_id = ?",
                arguments: [noteIDValue, deckIDValue]
            )
        }
        // 更新 home 归属与修改时间。
        try db.execute(
            sql: "UPDATE notes SET deck_id = ?, updated_at_ms = ? WHERE id = ?",
            arguments: [
                DatabaseValueCodec.encode(homeDeckID),
                atMilliseconds,
                noteIDValue
            ]
        )
        return membership
    }
}
