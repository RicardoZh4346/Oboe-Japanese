import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v13 → v14（便携备份 v7，设计 §11.1）：新建 `attachments` 元数据表。
/// 升级必须是纯增量——表存在、为空、不动既有数据，`image_reference`
/// 维持宽松引用（无 FK，老数据里的悬空引用不阻塞迁移）。
final class OboeSchemaV14MigrationTests: XCTestCase {
    func testV13UpgradeCreatesEmptyAttachmentsTable() throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let danglingReference = "orphaned-image-id"

        try stageLegacyDatabase(
            at: location.file,
            through: "v13_note_deck_membership_and_pitch"
        ) { db in
            // 一条引用已不存在图片的 inbox 行：迁移必须容忍这种悬空引用。
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        image_reference, created_at_ms, updated_at_ms
                    ) VALUES (?, '旧截图', 'manual', 'unprocessed', 1, ?, 1, 2)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID()), danglingReference]
            )
        }

        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }
        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("attachments"))
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachments"), 0,
                "升级后 attachments 必须为空表"
            )
            let columns = try db.columns(in: "attachments").map(\.name)
            XCTAssertEqual(
                Set(columns),
                [
                    "id", "relative_path", "mime_type", "byte_count", "sha256",
                    "pixel_width", "pixel_height", "created_at_ms"
                ]
            )
            // 悬空引用原样保留——v14 不加外键，兼容性靠写入方约束。
            let reference: String? = try Row.fetchOne(
                db,
                sql: "SELECT image_reference FROM inbox_items"
            )?["image_reference"]
            XCTAssertEqual(reference, danglingReference)
            let applied = try OboeDatabaseSchema.makeMigrator().appliedIdentifiers(db)
            XCTAssertEqual(applied, Set(OboeDatabaseSchema.migrationIdentifiers))
        }

        let integrity = try database.pool.read { db in
            (
                try String.fetchAll(db, sql: "PRAGMA integrity_check"),
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            )
        }
        XCTAssertEqual(integrity.0, ["ok"])
        XCTAssertTrue(integrity.1.isEmpty)
    }

    func testAttachmentsTableConstraintsAndRepository() async throws {
        let location = temporaryDatabaseLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let database = try OboeDatabase(path: location.file.path)
        defer { try? database.close() }
        let repository = GRDBAttachmentRepository(database: database)

        let descriptor = AttachmentDescriptor(
            id: "img-1",
            relativePath: "attachments/img-1.jpg",
            mimeType: "image/jpeg",
            byteCount: 128,
            sha256: String(repeating: "a", count: 64),
            pixelWidth: 120,
            pixelHeight: 60
        )
        let stored = StoredAttachment(
            descriptor: descriptor,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        // 基本 CRUD + 幂等 upsert。
        try await repository.upsert(stored)
        try await repository.upsert(stored)
        let fetched = try await repository.fetch(id: "img-1")
        XCTAssertEqual(fetched, stored)
        let batchIDs = try await repository.fetch(ids: ["img-1", "img-missing"])
            .map(\.id)
        XCTAssertEqual(batchIDs, ["img-1"])
        // 同 id 不同摘要 → 数据漂移，拒绝。
        await XCTAssertAsyncThrowsError(
            try await repository.upsert(
                StoredAttachment(
                    descriptor: AttachmentDescriptor(
                        id: "img-1",
                        relativePath: "attachments/img-1.jpg",
                        mimeType: "image/jpeg",
                        byteCount: 128,
                        sha256: String(repeating: "b", count: 64),
                        pixelWidth: 120,
                        pixelHeight: 60
                    ),
                    createdAt: stored.createdAt
                )
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentError, .metadataConflict("img-1"))
        }
        // 非法 id / sha256 在写入前被领域校验拦截。
        await XCTAssertAsyncThrowsError(
            try await repository.upsert(
                StoredAttachment(
                    descriptor: AttachmentDescriptor(
                        id: "../escape",
                        relativePath: "attachments/x.jpg",
                        mimeType: "image/jpeg",
                        byteCount: 1,
                        sha256: String(repeating: "a", count: 64),
                        pixelWidth: nil,
                        pixelHeight: nil
                    ),
                    createdAt: stored.createdAt
                )
            )
        ) { error in
            XCTAssertEqual(error as? AttachmentError, .invalidResourceID("../escape"))
        }

        // 引用关系反查：inbox 行引用 → referenced / unreferenced 集合。
        let inboxID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        image_reference, created_at_ms, updated_at_ms
                    ) VALUES (?, '截图', 'manual', 'unprocessed', 1, 'img-1', 1, 2)
                    """,
                arguments: [DatabaseValueCodec.encode(inboxID)]
            )
        }
        let referencing = try await repository
            .referencingInboxItemIDs(attachmentID: "img-1")
        XCTAssertEqual(referencing, [inboxID])
        let referenced = try await repository.referencedAttachmentIDs()
        XCTAssertEqual(referenced, ["img-1"])
        let unreferenced = try await repository.unreferencedAttachmentIDs()
        XCTAssertEqual(unreferenced, [])

        let deleted = try await repository.delete(id: "img-1")
        XCTAssertTrue(deleted)
        let deletedAgain = try await repository.delete(id: "img-1")
        XCTAssertFalse(deletedAgain)
        let afterDelete = try await repository.fetch(id: "img-1")
        XCTAssertNil(afterDelete)
    }

    // MARK: - 工具

    private struct TemporaryDatabaseLocation {
        let directory: URL
        let file: URL
    }

    private func temporaryDatabaseLocation() -> TemporaryDatabaseLocation {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OboeSchemaV14MigrationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return TemporaryDatabaseLocation(
            directory: directory,
            file: directory.appendingPathComponent("oboe.sqlite")
        )
    }

    private func stageLegacyDatabase(
        at file: URL,
        through lastIdentifier: String,
        seed: (Database) throws -> Void
    ) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search",
                argumentCount: 1,
                pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0]) else {
                    return nil
                }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let prefix = Array(
            OboeDatabaseSchema.migrationIdentifiers.prefix(
                through: OboeDatabaseSchema.migrationIdentifiers
                    .firstIndex(of: lastIdentifier)!
            )
        )
        let migrator = OboeDatabaseSchema.makeMigrator(applying: prefix)
        let queue = try DatabaseQueue(path: file.path, configuration: configuration)
        try migrator.migrate(queue)
        try queue.write(seed)
        try queue.close()
    }
}

/// `async throws` 断言工具：XCTest 没有 async 版 throws 断言。
func XCTAssertAsyncThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("预期抛出错误但未抛出。\(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
