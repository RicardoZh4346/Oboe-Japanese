import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// 统一附件引用查询（D09，设计 §6.3）：并集当前覆盖
/// `inbox_items.image_reference ∪ source_contexts.image_reference`。
/// 「已持久化且持图的草稿」暂无第三分量——现行 draft/resume payload
/// 无图片引用字段，草稿只能经存活 inbox item 持图；本文件用测试钉死
/// 该不变量与已知缺口。
final class GRDBAttachmentReferenceRepositoryTests: XCTestCase {
    func testUnionCoversInboxAndSourceContexts() async throws {
        try await withTemporaryRepository { repository, database in
            let inboxID = UUID()
            let noteID = UUID()
            try await database.pool.write { db in
                try Self.insertInboxItem(
                    id: inboxID,
                    imageReference: "img-inbox",
                    in: db
                )
                try Self.insertDeckAndNote(noteID: noteID, in: db)
                try Self.insertSourceContext(
                    id: UUID(),
                    noteID: noteID,
                    imageReference: "img-source",
                    in: db
                )
            }

            let referenced = try await repository.referencedResourceIDs()
            XCTAssertEqual(referenced, ["img-inbox", "img-source"])
            let inboxReferenced = try await repository.isReferenced("img-inbox")
            let sourceReferenced = try await repository.isReferenced("img-source")
            let nobodyReferenced = try await repository.isReferenced("img-nobody")
            XCTAssertTrue(inboxReferenced)
            XCTAssertTrue(sourceReferenced)
            XCTAssertFalse(nobodyReferenced)
        }
    }

    func testReferencingOwnersDistinguishesTables() async throws {
        try await withTemporaryRepository { repository, database in
            let inboxID = UUID()
            let noteID = UUID()
            let earlierContext = UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!
            let laterContext = UUID(
                uuidString: "FFFFFFFF-0000-0000-0000-000000000000"
            )!
            try await database.pool.write { db in
                try Self.insertInboxItem(
                    id: inboxID,
                    imageReference: "img-shared",
                    in: db
                )
                try Self.insertDeckAndNote(noteID: noteID, in: db)
                // 写入顺序打乱，断言输出仍按 (created_at_ms, id) 稳定。
                try Self.insertSourceContext(
                    id: laterContext,
                    noteID: noteID,
                    imageReference: "img-shared",
                    createdAtMs: 2,
                    in: db
                )
                try Self.insertSourceContext(
                    id: earlierContext,
                    noteID: noteID,
                    imageReference: "img-shared",
                    createdAtMs: 1,
                    in: db
                )
            }

            let owners = try await repository.referencingOwners(of: "img-shared")
            XCTAssertEqual(
                owners,
                [
                    .inboxItem(inboxID),
                    .sourceContext(earlierContext),
                    .sourceContext(laterContext)
                ]
            )
            let noOwners = try await repository.referencingOwners(of: "img-nobody")
            XCTAssertEqual(noOwners, [])
        }
    }

    /// D09 红线：删除 Inbox 后仍被 source_contexts 引用的图片不得丢——
    /// 引用集合不能把存活引用误判成零。
    func testDeletingInboxItemKeepsSourceContextReference() async throws {
        try await withTemporaryRepository { repository, database in
            let inboxID = UUID()
            let noteID = UUID()
            let contextID = UUID()
            try await database.pool.write { db in
                try Self.insertInboxItem(
                    id: inboxID,
                    imageReference: "img-shared",
                    in: db
                )
                try Self.insertDeckAndNote(noteID: noteID, in: db)
                try Self.insertSourceContext(
                    id: contextID,
                    noteID: noteID,
                    imageReference: "img-shared",
                    in: db
                )
                try db.execute(
                    sql: "DELETE FROM inbox_items WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(inboxID)]
                )
            }

            let stillReferenced = try await repository.isReferenced("img-shared")
            XCTAssertTrue(stillReferenced)
            let referenced = try await repository.referencedResourceIDs()
            XCTAssertEqual(referenced, ["img-shared"])
            let owners = try await repository.referencingOwners(of: "img-shared")
            XCTAssertEqual(owners, [.sourceContext(contextID)])
        }
    }

    /// 反向同理：最后一个引用（source_contexts 行删除/级联）移除后，
    /// 资源才可回收。
    func testLastReferenceRemovalReleasesResource() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await database.pool.write { db in
                try Self.insertDeckAndNote(noteID: noteID, in: db)
                try Self.insertSourceContext(
                    id: UUID(),
                    noteID: noteID,
                    imageReference: "img-only",
                    in: db
                )
            }
            let beforeDelete = try await repository.isReferenced("img-only")
            XCTAssertTrue(beforeDelete)

            // 删除 Note → source_contexts 级联消失 → 引用归零。
            try await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                )
            }
            let afterDelete = try await repository.isReferenced("img-only")
            XCTAssertFalse(afterDelete)
            let referenced = try await repository.referencedResourceIDs()
            XCTAssertEqual(referenced, [])
        }
    }

    /// 已知缺口钉板测试：草稿本身不产出引用。`drafts` /
    /// `inbox_processing_contexts` 当前无图片引用列/字段；草稿持图的
    /// 不变量 = 只能通过存活 inbox item 持图。删除 inbox item 时
    /// `inbox_processing_contexts` 随 `inbox_item_id` 级联删除，而
    /// `drafts` 行残留——残留草稿不再计为图片所有者。未来 payload
    /// 引入 `imageReference` 时本测试必须随 `.draft` owner 一起改。
    func testDraftHoldsImageOnlyThroughLiveInboxItem() async throws {
        try await withTemporaryRepository { repository, database in
            let inboxID = UUID()
            let draftID = UUID()
            try await database.pool.write { db in
                try Self.insertInboxItem(
                    id: inboxID,
                    imageReference: "img-draft",
                    in: db
                )
                try Self.insertDraft(id: draftID, in: db)
                try Self.insertProcessingContext(
                    id: UUID(),
                    inboxItemID: inboxID,
                    draftID: draftID,
                    in: db
                )
            }
            let referenced = try await repository.referencedResourceIDs()
            XCTAssertEqual(
                referenced,
                ["img-draft"],
                "草稿经宿主 inbox item 持图时，资源算被引用"
            )
            let owners = try await repository.referencingOwners(of: "img-draft")
            XCTAssertEqual(owners, [.inboxItem(inboxID)])

            // 删除宿主 item：context 级联删除，draft 行残留。
            try await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM inbox_items WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(inboxID)]
                )
            }
            let draftSurvives = try await database.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM drafts WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(draftID)]
                ) ?? 0
            }
            XCTAssertEqual(draftSurvives, 1, "draft 行不因 inbox 删除而消失")
            let stillReferenced = try await repository.isReferenced("img-draft")
            XCTAssertFalse(
                stillReferenced,
                "宿主 item 删除后草稿不再持有该图片——缺口见协议文档"
            )
        }
    }

    func testNullAndEmptyReferencesExcluded() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await database.pool.write { db in
                try Self.insertInboxItem(
                    id: UUID(),
                    imageReference: nil,
                    in: db
                )
                try Self.insertInboxItem(
                    id: UUID(),
                    imageReference: "",
                    in: db
                )
                try Self.insertDeckAndNote(noteID: noteID, in: db)
                try Self.insertSourceContext(
                    id: UUID(),
                    noteID: noteID,
                    imageReference: nil,
                    in: db
                )
                try Self.insertSourceContext(
                    id: UUID(),
                    noteID: noteID,
                    imageReference: "",
                    createdAtMs: 2,
                    in: db
                )
            }

            let referenced = try await repository.referencedResourceIDs()
            XCTAssertEqual(referenced, [])
            let emptyReferenced = try await repository.isReferenced("")
            XCTAssertFalse(emptyReferenced)
            let emptyOwners = try await repository.referencingOwners(of: "")
            XCTAssertEqual(emptyOwners, [])
        }
    }

    // MARK: - 工具

    private func withTemporaryRepository(
        _ body: (GRDBAttachmentReferenceRepository, OboeDatabase) async throws
            -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBAttachmentReferenceRepositoryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let database = try OboeDatabase(
            path: directory.appendingPathComponent("oboe.sqlite").path
        )
        try await body(
            GRDBAttachmentReferenceRepository(database: database),
            database
        )
        try? database.close()
    }

    static func insertInboxItem(
        id: UUID,
        imageReference: String?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_items(
                    id, text, source_type, status, content_revision,
                    image_reference, created_at_ms, updated_at_ms
                ) VALUES (?, 'テキスト', 'share', 'unprocessed', 1, ?, 1, 1)
                """,
            arguments: [DatabaseValueCodec.encode(id), imageReference]
        )
    }

    static func insertDeckAndNote(noteID: UUID, in db: Database) throws {
        let deckID = UUID()
        let nowMs = try DatabaseValueCodec.encode(
            Date(timeIntervalSince1970: 1_768_000_000)
        )
        try db.execute(
            sql: """
                INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                VALUES (?, '测试牌组', 0, ?, ?)
                """,
            arguments: [DatabaseValueCodec.encode(deckID), nowMs, nowMs]
        )
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, reading, meaning_zh,
                    is_favorite, origin, content_version,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'vocabulary', '見る', 'みる', '看', 0, 'manual', 1, ?, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(noteID),
                DatabaseValueCodec.encode(deckID),
                nowMs,
                nowMs
            ]
        )
        try insertHomeMembershipIfSupported(
            noteID: noteID,
            deckID: deckID,
            in: db
        )
    }

    static func insertSourceContext(
        id: UUID,
        noteID: UUID,
        imageReference: String?,
        createdAtMs: Int64 = 1,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO source_contexts(
                    id, note_id, source_type, image_reference,
                    is_primary, created_at_ms
                ) VALUES (?, ?, 'ocr', ?, 0, ?)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(noteID),
                imageReference,
                createdAtMs
            ]
        )
    }

    static func insertDraft(id: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO drafts(
                    id, draft_kind, payload_version, payload_json, updated_at_ms
                ) VALUES (?, 'sentence_analysis', 1, '{}', 1)
                """,
            arguments: [DatabaseValueCodec.encode(id)]
        )
    }

    static func insertProcessingContext(
        id: UUID,
        inboxItemID: UUID,
        draftID: UUID,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO inbox_processing_contexts(
                    id, inbox_item_id, content_revision, input_text, mode,
                    draft_id, payload_version, resume_payload_json, updated_at_ms
                ) VALUES (?, ?, 1, 'テキスト', 'sentence_analysis', ?, 1, NULL, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(id),
                DatabaseValueCodec.encode(inboxItemID),
                DatabaseValueCodec.encode(draftID)
            ]
        )
    }
}
