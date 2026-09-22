import Foundation
import GRDB
@testable import OboeInfrastructure

/// 测试共享辅助：裸 `INSERT INTO notes` 的夹具在 v13+ schema 下同步 home
/// 成员行，保持“每 Note 至少一个 membership”不变量；在旧 schema（v13 前）
/// 夹具/迁移测试中自动跳过。
func insertHomeMembershipIfSupported(
    noteID: UUID,
    deckID: UUID,
    in db: Database
) throws {
    guard try db.tableExists("note_decks") else { return }
    try db.execute(
        sql: """
            INSERT INTO note_decks(note_id, deck_id, added_at_ms)
            VALUES (?, ?, 1)
            ON CONFLICT(note_id, deck_id) DO NOTHING
            """,
        arguments: [
            DatabaseValueCodec.encode(noteID),
            DatabaseValueCodec.encode(deckID)
        ]
    )
}
