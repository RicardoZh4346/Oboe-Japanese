import Foundation
import GRDB

/// v0.7.5 S06（contracts §5、v24 迁移的运行时半）：
/// Reader 文档 ↔ 学习牌组的绑定生命周期。
///
/// 不变量（技术文档 §4 `reader_documents.study_deck_id`）：
/// - 每文档至多一个 study deck，`study_deck_id` 一旦写入不再改绑；
/// - 牌组名默认 `阅读·《<title>》`，同名不同文档各建各的牌组
///   （不按名查重——同名书各自一组卡）；
/// - `name_follows_title = 1` 时文档重命名可跟随改牌组名；用户
///   手动改过牌组名（`renameDeck`）后 flag 落 0，不再跟随；
/// - 删除文档只解除绑定（行随文档消失，FK SET NULL），牌组与其
///   Note/Card 全部保留——学习对象不随文章陪葬。
public enum GRDBReaderStudyDeckService {
    /// 文档 study deck 默认命名（name_follows_title 期间跟随此模板）。
    public static func studyDeckName(title: String) -> String {
        "阅读·《\(title)》"
    }

    /// 确保文档已绑定 study deck——无则**同事务**创建牌组并绑定。
    ///
    /// - Parameter expectedContentRevision: 可选并发防线——与调用方
    ///   读到的内容修订不符即抛错，调用方重新预检（mining/pipeline
    ///   写路径的同类检查一致）。
    /// - Returns: 绑定的 deck id（新建或既有）。
    @discardableResult
    public static func ensureStudyDeck(
        documentID: UUID,
        expectedContentRevision: Int? = nil,
        at date: Date = Date(),
        in db: Database
    ) throws -> UUID {
        let documentIDValue = DatabaseValueCodec.encode(documentID)
        guard let doc = try Row.fetchOne(
            db,
            sql: """
                SELECT title, study_deck_id, study_deck_name_follows_title,
                       content_revision
                FROM reader_documents WHERE id = ?
                """,
            arguments: [documentIDValue]
        ) else {
            throw ReaderStudyDeckError.documentNotFound(documentID)
        }

        if let expectedContentRevision {
            let current: Int = doc["content_revision"]
            guard current == expectedContentRevision else {
                throw ReaderStudyDeckError.staleContentRevision(
                    expected: expectedContentRevision, current: current
                )
            }
        }

        if let raw: String = doc["study_deck_id"],
           let existing = try? DatabaseValueCodec.decodeUUID(raw) {
            return existing // 已绑定——幂等返回，永不改绑
        }

        let deckID = UUID()
        let milliseconds = try DatabaseValueCodec.encode(date)
        let sortOrder = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM decks"
        ) ?? 0
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(deckID),
                studyDeckName(title: doc["title"]),
                sortOrder, milliseconds, milliseconds
            ]
        )
        // 绑定一次有效——并发窗口另一侧先绑则本侧放弃自建牌组，
        // 读回胜出者的 deck id（GRDB 串行写队列内罕见但可判）。
        try db.execute(
            sql: """
                UPDATE reader_documents
                SET study_deck_id = ?, study_deck_name_follows_title = 1
                WHERE id = ? AND study_deck_id IS NULL
                """,
            arguments: [
                DatabaseValueCodec.encode(deckID), documentIDValue
            ]
        )
        if db.changesCount == 0 {
            try db.execute(
                sql: "DELETE FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
            guard let rebound = try Row.fetchOne(
                db,
                sql: "SELECT study_deck_id FROM reader_documents WHERE id = ?",
                arguments: [documentIDValue]
            ), let raw: String = rebound["study_deck_id"],
               let winner = try? DatabaseValueCodec.decodeUUID(raw) else {
                throw ReaderStudyDeckError.bindingRaceLost(documentID)
            }
            return winner
        }
        return deckID
    }

    /// 文档重命名跟随：name_follows_title=1 的绑定把牌组名改为新
    /// 标题模板。显式改名的牌组（flag=0）不动。
    /// 返回是否改动了牌组名。
    @discardableResult
    public static func documentTitleChanged(
        documentID: UUID,
        newTitle: String,
        at date: Date = Date(),
        in db: Database
    ) throws -> Bool {
        let milliseconds = try DatabaseValueCodec.encode(date)
        try db.execute(
            sql: """
                UPDATE decks SET name = ?, updated_at_ms = ?
                WHERE id = (
                    SELECT study_deck_id FROM reader_documents
                    WHERE id = ? AND study_deck_name_follows_title = 1
                )
                """,
            arguments: [
                studyDeckName(title: newTitle), milliseconds,
                DatabaseValueCodec.encode(documentID)
            ]
        )
        return db.changesCount == 1
    }

    /// 牌组被用户显式改名时解除跟随（GRDBDeckRepository.renameDeck
    /// 同事务调用）——之后文档改名不再动这组牌。
    public static func markDeckManuallyRenamed(
        deckID: UUID, in db: Database
    ) throws {
        try db.execute(
            sql: """
                UPDATE reader_documents
                SET study_deck_name_follows_title = 0
                WHERE study_deck_id = ?
                """,
            arguments: [DatabaseValueCodec.encode(deckID)]
        )
    }
}

public enum ReaderStudyDeckError: Error, Equatable, Sendable {
    case documentNotFound(UUID)
    case staleContentRevision(expected: Int, current: Int)
    /// 并发窗口：本侧自建牌组已弃，但读回绑定失败——极罕见，
    /// 调用方重试 ensureStudyDeck 即可（幂等）。
    case bindingRaceLost(UUID)
}
