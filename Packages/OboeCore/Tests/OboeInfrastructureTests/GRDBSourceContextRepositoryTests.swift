import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// `source_contexts`（v15，设计 §6.1/§6.2）仓储测试：CRUD、排序、
/// primary 切换的事务正确性、约束→领域错误映射、级联删除与宽松
/// 图片引用。
final class GRDBSourceContextRepositoryTests: XCTestCase {
    func testInsertAndFetchRoundTrip() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let context = Self.makeContext(
                noteID: noteID,
                sourceType: .ocr,
                originalSentence: "そんなことを言われても困る。",
                surroundingText: "前文……後文",
                sourceTitle: "截图 OCR",
                sourceApp: "com.apple.Photos",
                imageReference: "img-resource-1",
                isPrimary: true
            )

            try await repository.insert(context)

            let fetched = try await repository.fetch(id: context.id)
            XCTAssertEqual(fetched, context)
            let forNote = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(forNote, [context])
            let primary = try await repository.fetchPrimary(noteID: noteID)
            XCTAssertEqual(primary, context)
        }
    }

    func testFetchForNoteOrdersByCreatedAtThenID() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let t1 = Date(timeIntervalSince1970: 1_768_000_000)
            let t2 = Date(timeIntervalSince1970: 1_768_000_100)
            // created_at 相同的两条按 id 文本升序兜底——先写「大」id 证明
            // 排序不依赖插入顺序。
            let sameTimeB = Self.makeContext(
                id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")!,
                noteID: noteID,
                sourceType: .manual,
                isPrimary: false,
                createdAt: t1
            )
            let sameTimeA = Self.makeContext(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                noteID: noteID,
                sourceType: .share,
                isPrimary: false,
                createdAt: t1
            )
            let later = Self.makeContext(
                noteID: noteID,
                sourceType: .dictionary,
                isPrimary: false,
                createdAt: t2
            )

            try await repository.insert(later)
            try await repository.insert(sameTimeB)
            try await repository.insert(sameTimeA)

            let ordered = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(
                ordered.map(\.id),
                [sameTimeA.id, sameTimeB.id, later.id],
                "必须按 (created_at_ms, id) 升序，与 source_contexts_on_note 同序"
            )
        }
    }

    func testFetchPrimaryReturnsNilWithoutPrimary() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let empty = try await repository.fetchPrimary(noteID: noteID)
            XCTAssertNil(empty)

            let nonPrimary = Self.makeContext(
                noteID: noteID,
                sourceType: .manual,
                isPrimary: false
            )
            try await repository.insert(nonPrimary)
            let stillEmpty = try await repository.fetchPrimary(noteID: noteID)
            XCTAssertNil(stillEmpty)
        }
    }

    func testSecondPrimaryInsertMapsToPrimaryConflict() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            let otherNoteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            try await insertNoteFixture(noteID: otherNoteID, in: database)

            let first = Self.makeContext(noteID: noteID, isPrimary: true)
            try await repository.insert(first)

            let second = Self.makeContext(noteID: noteID, isPrimary: true)
            await assertThrowsSourceContextError(
                { try await repository.insert(second) },
                equals: .primaryConflict(noteID: noteID)
            )

            // 冲突写整体回滚：note 仍只有第一条 primary。
            let remaining = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(remaining.map(\.id), [first.id])
            // 其它 Note 的 primary 不受影响。
            let unrelated = Self.makeContext(
                noteID: otherNoteID,
                isPrimary: true
            )
            try await repository.insert(unrelated)
            let otherPrimary = try await repository.fetchPrimary(
                noteID: otherNoteID
            )
            XCTAssertEqual(otherPrimary?.id, unrelated.id)
        }
    }

    /// 并发同 Note 多条 primary：写事务串行化后必有且只有一条胜出，
    /// 其余全部映射为 `primaryConflict`——唯一索引不依赖时序运气。
    func testConcurrentPrimaryInsertsExactlyOneSucceeds() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let contexts = (0..<4).map { _ in
                Self.makeContext(noteID: noteID, isPrimary: true)
            }

            let outcomes = await withTaskGroup(
                of: InsertOutcome.self,
                returning: [InsertOutcome].self
            ) { group in
                for context in contexts {
                    group.addTask {
                        do {
                            try await repository.insert(context)
                            return .success
                        } catch let error as SourceContextError {
                            return .domain(error)
                        } catch {
                            return .other(String(describing: error))
                        }
                    }
                }
                var collected: [InsertOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }

            var successes = 0
            var conflicts = 0
            for outcome in outcomes {
                switch outcome {
                case .success:
                    successes += 1
                case .domain(.primaryConflict(let conflictedNoteID)):
                    XCTAssertEqual(conflictedNoteID, noteID)
                    conflicts += 1
                case .domain(let error):
                    XCTFail("并发 primary 写入应只产出 primaryConflict，实际：\(error)")
                case .other(let message):
                    XCTFail("并发 primary 写入应只产出 primaryConflict，实际：\(message)")
                }
            }
            XCTAssertEqual(successes, 1, "必须恰好一条 primary 落库")
            XCTAssertEqual(conflicts, 3)
            let stored = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(stored.count, 1)
            XCTAssertTrue(stored[0].isPrimary)
        }
    }

    func testSetPrimarySwitchesAtomically() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let original = Self.makeContext(
                noteID: noteID,
                sourceType: .ocr,
                isPrimary: true,
                createdAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            let incoming = Self.makeContext(
                noteID: noteID,
                sourceType: .share,
                isPrimary: false,
                createdAt: Date(timeIntervalSince1970: 1_768_000_100)
            )
            try await repository.insert(original)
            try await repository.insert(incoming)

            try await repository.setPrimary(
                contextID: incoming.id,
                noteID: noteID
            )

            let stored = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(stored.map(\.id), [original.id, incoming.id])
            XCTAssertEqual(stored.map(\.isPrimary), [false, true])
            let primary = try await repository.fetchPrimary(noteID: noteID)
            XCTAssertEqual(primary?.id, incoming.id)

            // 对已 primary 的行再 setPrimary 是幂等的。
            try await repository.setPrimary(
                contextID: incoming.id,
                noteID: noteID
            )
            let primaryAgain = try await repository.fetchPrimary(noteID: noteID)
            XCTAssertEqual(primaryAgain?.id, incoming.id)
        }
    }

    /// 目标行不存在 → contextNotFound 且事务回滚，原 primary 保持。
    /// 若实现不是「先清后置」单事务，这里会丢光 primary。
    func testSetPrimaryMissingTargetRollsBack() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let original = Self.makeContext(noteID: noteID, isPrimary: true)
            try await repository.insert(original)

            let missingID = UUID()
            do {
                try await repository.setPrimary(
                    contextID: missingID,
                    noteID: noteID
                )
                XCTFail("预期 contextNotFound")
            } catch let error as SourceContextRepositoryError {
                XCTAssertEqual(
                    error,
                    .contextNotFound(contextID: missingID, noteID: noteID)
                )
            }

            let primary = try await repository.fetchPrimary(noteID: noteID)
            XCTAssertEqual(
                primary?.id,
                original.id,
                "失败切换不得清掉原 primary"
            )
        }
    }

    /// 行属于其它 Note 时同样 contextNotFound（id 存在但 note 不匹配）。
    func testSetPrimaryRejectsCrossNoteContext() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            let otherNoteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            try await insertNoteFixture(noteID: otherNoteID, in: database)
            let foreign = Self.makeContext(noteID: otherNoteID, isPrimary: true)
            try await repository.insert(foreign)

            do {
                try await repository.setPrimary(
                    contextID: foreign.id,
                    noteID: noteID
                )
                XCTFail("预期 contextNotFound")
            } catch let error as SourceContextRepositoryError {
                XCTAssertEqual(
                    error,
                    .contextNotFound(contextID: foreign.id, noteID: noteID)
                )
            }
        }
    }

    func testDeleteIsIdempotent() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let context = Self.makeContext(noteID: noteID, isPrimary: true)
            try await repository.insert(context)

            let firstDelete = try await repository.delete(id: context.id)
            XCTAssertTrue(firstDelete)
            let secondDelete = try await repository.delete(id: context.id)
            XCTAssertFalse(secondDelete)
            let fetched = try await repository.fetch(id: context.id)
            XCTAssertNil(fetched)
        }
    }

    func testNoteDeleteCascadesContexts() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            try await repository.insert(
                Self.makeContext(noteID: noteID, isPrimary: true)
            )
            try await repository.insert(
                Self.makeContext(
                    noteID: noteID,
                    isPrimary: false,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_100)
                )
            )

            try await database.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM notes WHERE id = ?",
                    arguments: [DatabaseValueCodec.encode(noteID)]
                )
            }

            let remaining = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(
                remaining,
                [],
                "note_id 级联：Note 消失其来源随之消失"
            )
        }
    }

    /// 宽松 image_reference：指向未登记附件照样可写（无 FK），孤儿
    /// 清理由统一引用查询负责。
    func testLooseImageReferenceTolerated() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let context = Self.makeContext(
                noteID: noteID,
                imageReference: "img-does-not-exist",
                isPrimary: false
            )
            try await repository.insert(context)
            let fetched = try await repository.fetch(id: context.id)
            XCTAssertEqual(fetched?.imageReference, "img-does-not-exist")
        }
    }

    func testInsertWithMissingNoteMapsToMissingNote() async throws {
        try await withTemporaryRepository { repository, _ in
            let dangling = UUID()
            let context = Self.makeContext(noteID: dangling, isPrimary: true)
            await assertThrowsSourceContextError(
                { try await repository.insert(context) },
                equals: .missingNote(noteID: dangling)
            )
        }
    }

    /// 重复主键（同 id）不是 primaryConflict——映射必须区分扩展码。
    func testDuplicateIDDoesNotMapToPrimaryConflict() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let context = Self.makeContext(noteID: noteID, isPrimary: false)
            try await repository.insert(context)
            do {
                try await repository.insert(context)
                XCTFail("预期重复主键报错")
            } catch is SourceContextError {
                XCTFail("PK 冲突不得映射为 SourceContextError")
            } catch {
                XCTAssertTrue(error is DatabaseError)
            }
        }
    }

    func testFetchImageReferencesReturnsNonEmptyOnly() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            try await repository.insert(
                Self.makeContext(
                    noteID: noteID,
                    imageReference: "img-a",
                    isPrimary: true
                )
            )
            try await repository.insert(
                Self.makeContext(
                    noteID: noteID,
                    imageReference: "img-a",
                    isPrimary: false,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_100)
                )
            )
            try await repository.insert(
                Self.makeContext(
                    noteID: noteID,
                    imageReference: "img-b",
                    isPrimary: false,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_200)
                )
            )
            try await repository.insert(
                Self.makeContext(
                    noteID: noteID,
                    imageReference: nil,
                    isPrimary: false,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_300)
                )
            )
            // 空串引用（宽松列允许）不得进入 keep set。
            try await repository.insert(
                Self.makeContext(
                    noteID: noteID,
                    imageReference: "",
                    isPrimary: false,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_400)
                )
            )

            let references = try await repository.fetchImageReferences()
            XCTAssertEqual(references, ["img-a", "img-b"])
        }
    }

    /// 批量写整批原子：中间一行冲突 → 已写行一并回滚。
    func testInsertAllRollsBackOnConflict() async throws {
        try await withTemporaryRepository { repository, database in
            let noteID = UUID()
            try await insertNoteFixture(noteID: noteID, in: database)
            let existing = Self.makeContext(
                noteID: noteID,
                isPrimary: true,
                createdAt: Date(timeIntervalSince1970: 1_768_000_000)
            )
            try await repository.insert(existing)

            let batchOK = Self.makeContext(
                noteID: noteID,
                isPrimary: false,
                createdAt: Date(timeIntervalSince1970: 1_768_000_100)
            )
            let batchConflict = Self.makeContext(
                noteID: noteID,
                isPrimary: true,
                createdAt: Date(timeIntervalSince1970: 1_768_000_200)
            )
            await assertThrowsSourceContextError(
                { try await repository.insertAll([batchOK, batchConflict]) },
                equals: .primaryConflict(noteID: noteID)
            )

            let remaining = try await repository.fetchForNote(noteID: noteID)
            XCTAssertEqual(
                remaining.map(\.id),
                [existing.id],
                "整批回滚：batchOK 不得残留"
            )
        }
    }

    func testInsertAllHappyPath() async throws {
        try await withTemporaryRepository { repository, database in
            let noteA = UUID()
            let noteB = UUID()
            try await insertNoteFixture(noteID: noteA, in: database)
            try await insertNoteFixture(noteID: noteB, in: database)
            let contexts = [
                Self.makeContext(
                    noteID: noteA,
                    isPrimary: true,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_000)
                ),
                Self.makeContext(
                    noteID: noteB,
                    isPrimary: true,
                    createdAt: Date(timeIntervalSince1970: 1_768_000_100)
                )
            ]
            try await repository.insertAll(contexts)
            let forA = try await repository.fetchForNote(noteID: noteA)
            XCTAssertEqual(Set(forA.map(\.id)), [contexts[0].id])
            let forB = try await repository.fetchForNote(noteID: noteB)
            XCTAssertEqual(Set(forB.map(\.id)), [contexts[1].id])
            // 空批量是 no-op。
            try await repository.insertAll([])
        }
    }

    // MARK: - 工具

    private enum InsertOutcome: Sendable {
        case success
        case domain(SourceContextError)
        case other(String)
    }

    private static func makeContext(
        id: UUID = UUID(),
        noteID: UUID,
        sourceType: SourceContextType = .manual,
        originalSentence: String? = nil,
        surroundingText: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        sourceApp: String? = nil,
        imageReference: String? = nil,
        dictionaryEntryID: Int64? = nil,
        dictionaryVersion: String? = nil,
        dictionarySenseKey: String? = nil,
        selectedGlossLanguage: String? = nil,
        isPrimary: Bool,
        createdAt: Date = Date(timeIntervalSince1970: 1_768_000_000)
    ) -> SourceContext {
        SourceContext(
            id: id,
            noteID: noteID,
            sourceType: sourceType,
            originalSentence: originalSentence,
            surroundingText: surroundingText,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            sourceApp: sourceApp,
            imageReference: imageReference,
            dictionaryEntryID: dictionaryEntryID,
            dictionaryVersion: dictionaryVersion,
            dictionarySenseKey: dictionarySenseKey,
            selectedGlossLanguage: selectedGlossLanguage,
            isPrimary: isPrimary,
            createdAt: createdAt
        )
    }

    private func withTemporaryRepository(
        _ body: (GRDBSourceContextRepository, OboeDatabase) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GRDBSourceContextRepositoryTests-\(UUID().uuidString)",
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
        try await body(GRDBSourceContextRepository(database: database), database)
        try? database.close()
    }

    private func insertNoteFixture(
        noteID: UUID,
        in database: OboeDatabase
    ) async throws {
        try await database.pool.write { db in
            try Self.insertDeckAndNote(noteID: noteID, in: db)
        }
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

    private func assertThrowsSourceContextError(
        _ body: () async throws -> Any,
        equals expected: SourceContextError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("预期抛出 \(expected)，但调用成功返回", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? SourceContextError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
