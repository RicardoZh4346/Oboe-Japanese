import CryptoKit
import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// 记录协议 v9 的真实导出→prepare round-trip 断言。
///
/// `PortableBackupV9SpecTests` 只校验规格声明的形状；本套测试校验
/// wire §2.1 全部 14 类新记录的真实往返——种入源库 → v9 opt-in 导出
/// → `PortableBackupRestorationPreparer.prepare` → 逐字段断言暂存库。
/// 同时锁定 v9 恢复语义（wire §4.1/§4.2）：alias `current` 降为
/// `needsConfirmation`、在途 Job 归一 `paused`+`missingSource`、
/// 无结果的 `requesting` 块归一 `retryScheduled`、运行态 cache 不越线。
final class PortableBackupV9RecordsTests: XCTestCase {

    // MARK: - 导出形态

    /// v9 opt-in 导出：manifest formatVersion=9、recordOrder 恰为
    /// v9 五十类、excludedScopes 叠加 aiStudyRuntime/providerSecrets，
    /// 且运行态 `ai_study_cache` 的哨兵值没有任何字节泄漏。
    func testV9ExportManifestAndCacheExclusion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportV9(source)

        let objects = try fixture.backupObjects(backup.url)
        let manifest = try XCTUnwrap(objects.first)
        XCTAssertEqual(manifest["formatVersion"] as? Int, 9)
        XCTAssertEqual(
            manifest["recordOrder"] as? [String],
            PortableBackupFormatV9.recordTypes
        )
        XCTAssertEqual(
            manifest["excludedScopes"] as? [String],
            PortableBackupFormat.excludedScopes
                + PortableBackupFormatV8.additionalExcludedScopes
                + PortableBackupFormatV9.additionalExcludedScopes
        )

        // 运行态红线：cache 内容不得出现在记录流任何字节中。
        let text = try String(contentsOf: backup.url, encoding: .utf8)
        XCTAssertFalse(
            text.contains(Fixture.cacheSentinel),
            "v9 记录流泄漏了 ai_study_cache 运行态数据"
        )
        XCTAssertFalse(text.contains("ai_study_cache"))
    }

    /// v9 起 v8 只读：显式声明 v8 的导出被拒绝（旧格式不可再生成；
    /// 默认导出为 v9 由 V8 套件 `testDefaultExportIsV9` 锁定）。
    func testExplicitV8ExportIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        do {
            _ = try await PortableBackupExporter(
                database: source,
                workingDirectoryURL: fixture.exportsURL
            ).export(
                appVersion: "test",
                at: fixture.exportedAt,
                recordFormatVersion: 8
            )
            XCTFail("v8 记录版本不得再被生成")
        } catch let error as PortableBackupExportError {
            XCTAssertEqual(error, .unsupportedRecordFormatVersion(8))
        }
    }

    /// 升级后混合 aisk1/aisk2 凭据通过 v9 原样恢复，无需 schema 变更。
    func testV9PreservesMixedLegacyAndJobScopedReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let key = AIStudyActionKey(jobID: Fixture.awaitingJobID,
            documentID: Fixture.documentID, contentRevision: 1,
            unitKey: "unit-0", selectionRevision: 1, actionType: .createNote)
        let currentReceiptID = UUID()
        try await source.pool.write { db in
            try db.execute(sql: "UPDATE ai_study_receipts SET action_key = ?",
                arguments: [key.legacyCanonicalKey])
            try GRDBAIStudyJobStore.recordReceipt(AIStudyReceipt(
                operationID: currentReceiptID, actionKey: key.canonicalKey,
                payloadHash: String(repeating: "b", count: 64),
                outcomeJSON: "{\"applied\":2}", committedAtMs: 131), in: db)
        }
        let backup = try await fixture.exportV9(source)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        let prepared = try await fixture.preparer(current: current).prepare(fileURL: backup.url)
        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let old = try XCTUnwrap(GRDBAIStudyJobStore.fetchReceipt(
                operationID: Fixture.receiptOperationID, in: db))
            XCTAssertEqual(old.actionKey, key.legacyCanonicalKey)
            XCTAssertEqual(old.payloadHash, String(repeating: "a", count: 64))
            XCTAssertEqual(old.outcomeJSON, "{\"applied\":1}")
            let new = try XCTUnwrap(GRDBAIStudyJobStore.fetchReceipt(
                operationID: currentReceiptID, in: db))
            XCTAssertEqual(new.actionKey, key.canonicalKey)
            XCTAssertEqual(new.payloadHash, String(repeating: "b", count: 64))
            XCTAssertEqual(new.outcomeJSON, "{\"applied\":2}")
        }
    }

    // MARK: - round trip

    /// v9 导出 → prepare → 暂存库：wire §2.1 全部 14 类新记录逐字段
    /// 往返；恢复语义逐条断言；运行态 cache 在恢复库中为空。
    func testV9RoundTripPreservesNewRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportV9(source)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: backup.url)
        XCTAssertEqual(prepared.sourceFormatVersion, 9)
        XCTAssertEqual(prepared.preparedFormatVersion, 9)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode

            // learningUnit：两类身份（词典义项 + 本地 Note）原样往返。
            let units = try Row.fetchAll(
                db,
                sql: "SELECT * FROM lexical_learning_units ORDER BY lemma"
            )
            XCTAssertEqual(units.count, 2)
            let dictionaryUnit = try XCTUnwrap(
                units.first { $0["identity_kind"] as? String
                    == "dictionarySense" }
            )
            XCTAssertEqual(
                dictionaryUnit["id"] as? String,
                encode(Fixture.dictionaryUnitID)
            )
            XCTAssertEqual(
                dictionaryUnit["identity_key"] as? String,
                "jmdict:sense-v1:1434700:1"
            )
            XCTAssertEqual(dictionaryUnit["provider"] as? String, "jmdict")
            XCTAssertEqual(
                dictionaryUnit["dictionary_entry_id"] as? Int64, 1434700
            )
            XCTAssertEqual(dictionaryUnit["lemma"] as? String, "見る")
            XCTAssertEqual(dictionaryUnit["reading"] as? String, "みる")
            XCTAssertEqual(
                dictionaryUnit["binding_status"] as? String, "current"
            )
            let localUnit = try XCTUnwrap(
                units.first { $0["identity_kind"] as? String == "localNote" }
            )
            XCTAssertEqual(
                localUnit["id"] as? String,
                encode(Fixture.localUnitID)
            )
            XCTAssertNil(localUnit["provider"] as? String)

            // alias 恢复语义（wire §4.1）：current → needsConfirmation；
            // stale 是历史态原样保留。
            let aliases = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM learning_unit_dictionary_aliases
                    ORDER BY sense_id
                    """
            )
            XCTAssertEqual(aliases.count, 2)
            XCTAssertEqual(
                aliases[0]["status"] as? String, "needsConfirmation"
            )
            XCTAssertEqual(aliases[0]["entry_id"] as? Int64, 1434700)
            XCTAssertEqual(aliases[1]["status"] as? String, "stale")

            // note link / flag / event / migration item 原样往返。
            let link = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM learning_unit_note_links"
            ))
            XCTAssertEqual(
                link["unit_id"] as? String, encode(Fixture.dictionaryUnitID)
            )
            XCTAssertEqual(link["role"] as? String, "primary")
            XCTAssertEqual(link["origin"] as? String, "aiPipeline")
            let flag = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM learning_unit_flags"
            ))
            XCTAssertEqual(flag["too_easy"] as? Int64, 1)
            let event = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM learning_unit_events"
            ))
            XCTAssertEqual(event["kind"] as? String, "tooEasySet")
            let migrationItem = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM learning_unit_migration_items"
            ))
            XCTAssertEqual(migrationItem["status"] as? String, "applied")

            // Reader 派生数据：occurrence 与 translation 原样往返。
            let occurrences = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM reader_study_occurrences
                    ORDER BY start_utf16
                    """
            )
            XCTAssertEqual(occurrences.count, 2)
            XCTAssertEqual(
                occurrences[0]["resolution_status"] as? String, "pending"
            )
            XCTAssertEqual(
                occurrences[1]["resolution_status"] as? String,
                "aiResolved"
            )
            XCTAssertEqual(
                occurrences[1]["unit_id"] as? String,
                encode(Fixture.dictionaryUnitID)
            )
            let translation = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM reader_translation_blocks"
            ))
            XCTAssertEqual(
                translation["translated_text"] as? String, "前文译文"
            )
            XCTAssertEqual(translation["is_current"] as? Int64, 1)
            XCTAssertEqual(translation["language"] as? String, "zh-Hans")

            // aiStudy Job 恢复语义（wire §4.2）：waitingForAI → paused +
            // missingSource；awaitingConfirmation（等用户）原样保留。
            let pausedJob = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM ai_study_jobs WHERE id = ?",
                arguments: [encode(Fixture.inFlightJobID)]
            ))
            XCTAssertEqual(pausedJob["status"] as? String, "paused")
            XCTAssertEqual(
                pausedJob["resume_reason"] as? String, "missingSource"
            )
            let awaitingJob = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM ai_study_jobs WHERE id = ?",
                arguments: [encode(Fixture.awaitingJobID)]
            ))
            XCTAssertEqual(
                awaitingJob["status"] as? String, "awaitingConfirmation"
            )
            XCTAssertNil(awaitingJob["resume_reason"] as? String)

            // 无持久化结果的 requesting 块 → retryScheduled（未知窗口
            // 不承诺 exactly-once）；resolved/已有结果的块原样保留。
            let orphanedBlock = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM ai_study_job_blocks WHERE id = ?",
                arguments: [encode(Fixture.requestingBlockID)]
            ))
            XCTAssertEqual(
                orphanedBlock["status"] as? String, "retryScheduled"
            )
            XCTAssertNil(orphanedBlock["next_retry_at_ms"] as? Int64)
            let resolvedBlock = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM ai_study_job_blocks WHERE id = ?",
                arguments: [encode(Fixture.resolvedBlockID)]
            ))
            XCTAssertEqual(resolvedBlock["status"] as? String, "resolved")

            // resolution / selection / receipt / 快照原样往返。
            let resolution = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM ai_study_resolutions"
            ))
            XCTAssertEqual(
                resolution["status"] as? String, "userConfirmed"
            )
            XCTAssertEqual(resolution["origin"] as? String, "user")
            let selection = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM ai_study_selections"
            ))
            XCTAssertEqual(selection["decision"] as? String, "create")
            let receipt = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM ai_study_receipts"
            ))
            XCTAssertEqual(
                receipt["operation_id"] as? String,
                encode(Fixture.receiptOperationID)
            )
            let snapshot = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM reader_learning_coverage_snapshots"
            ))
            XCTAssertEqual(snapshot["resolved_unique"] as? Int64, 7)
            XCTAssertEqual(snapshot["unknown_unique"] as? Int64, 3)

            // 运行态 cache 不进备份、恢复库中为空。
            let cacheCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ai_study_cache"
            )
            XCTAssertEqual(cacheCount, 0)
        }
    }

    /// v9 源的 dangling 弱引用按 wire §4.1 归一为 NULL——SET NULL 列
    /// 上指向不存在目标的引用不得让整批恢复失败。本端导出器有 FK 红线
    /// （foreignKeyViolations 拒绝导出），悬空值只能来自外部构造的
    /// 备份文件——故对导出的记录流做字节级篡改再重算 checksum。
    func testV9DanglingWeakReferencesNullified() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportV9(source)

        // 篡改 readerStudyOccurrence.unit_id 为悬空值并重打 footer。
        let tamperedURL = fixture.rootURL
            .appendingPathComponent("tampered.\(PortableBackupFormat.fileExtension)")
        try fixture.tamperingRecord(
            at: backup.url,
            to: tamperedURL,
            recordType: "readerStudyOccurrence"
        ) { record in
            guard record["resolution_status"] as? String == "pending"
            else { return }
            record["unit_id"] = DatabaseValueCodec.encode(UUID())
        }

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: tamperedURL)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            let dangling = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM reader_study_occurrences
                    WHERE resolution_status = 'pending'
                    """
            ))
            XCTAssertNil(
                dangling["unit_id"] as? String,
                "悬空的 unit_id 必须被归一为 NULL"
            )
            // 非悬空引用不受影响：aiResolved 行的 unit_id 原样保留。
            let resolved = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM reader_study_occurrences
                    WHERE resolution_status = 'aiResolved'
                    """
            ))
            XCTAssertEqual(
                resolved["unit_id"] as? String,
                DatabaseValueCodec.encode(Fixture.dictionaryUnitID)
            )
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        static let cacheSentinel = "v9-cache-sentinel-payload"

        static let deckID = UUID(uuidString:
            "11111111-1111-1111-1111-111111111111")!
        static let vocabNoteID = UUID(uuidString:
            "22222222-2222-2222-2222-222222222222")!
        static let vocabCardID = UUID(uuidString:
            "33333333-3333-3333-3333-333333333333")!
        static let profileID = UUID(uuidString:
            "44444444-4444-4444-4444-444444444444")!
        static let documentID = UUID(uuidString:
            "55555555-5555-5555-5555-555555555555")!
        static let dictionaryUnitID = UUID(uuidString:
            "66666666-6666-6666-6666-666666666666")!
        static let localUnitID = UUID(uuidString:
            "77777777-7777-7777-7777-777777777777")!
        static let inFlightJobID = UUID(uuidString:
            "88888888-8888-8888-8888-888888888888")!
        static let awaitingJobID = UUID(uuidString:
            "99999999-9999-9999-9999-999999999999")!
        static let requestingBlockID = UUID(uuidString:
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        static let resolvedBlockID = UUID(uuidString:
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        static let receiptOperationID = UUID(uuidString:
            "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        static let unitEventID = UUID(uuidString:
            "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        static let unitEventOperationID = UUID(uuidString:
            "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PortableBackupV9RecordsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        var sourceDatabaseURL: URL {
            rootURL.appendingPathComponent("source.sqlite")
        }
        var currentDatabaseURL: URL {
            rootURL.appendingPathComponent("current.sqlite")
        }
        var exportsURL: URL {
            rootURL.appendingPathComponent("exports", isDirectory: true)
        }
        var preparationsURL: URL {
            rootURL.appendingPathComponent("preparations", isDirectory: true)
        }
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            try FileManager.default.createDirectory(
                at: exportsURL, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: preparationsURL, withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func exportV9(_ database: OboeDatabase) async throws
            -> PortableBackupExport
        {
            try await PortableBackupExporter(
                database: database,
                workingDirectoryURL: exportsURL
            ).export(
                appVersion: "test",
                at: exportedAt,
                recordFormatVersion: 9
            )
        }

        func preparer(current: OboeDatabase)
            -> PortableBackupRestorationPreparer
        {
            PortableBackupRestorationPreparer(
                currentDatabase: current,
                workingDirectoryURL: preparationsURL
            )
        }

        func seedCurrent(_ database: OboeDatabase) async throws {
            try await database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO decks VALUES (?, '当前资料', 0, 1, 1)",
                    arguments: [DatabaseValueCodec.encode(UUID())]
                )
            }
        }

        func backupObjects(_ url: URL) throws -> [[String: Any]] {
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .compactMap { line in
                    try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any]
                }
        }

        /// 篡改指定记录类型的字段并重打 footer checksum——footer 的
        /// sha256 覆盖此前全部原始行字节（含行尾 \n），篡改后必须重算
        /// 才能得到一份「结构上合法、内容被污染」的备份文件。
        func tamperingRecord(
            at sourceURL: URL,
            to destinationURL: URL,
            recordType: String,
            mutate: (inout [String: Any]) throws -> Void
        ) throws {
            let rawLines = try String(contentsOf: sourceURL, encoding: .utf8)
                .components(separatedBy: "\n")
                .dropLast()  // 末行尾换行产生的空串
            var body = Data()
            var footerObject: [String: Any]?
            for raw in rawLines {
                guard var object = try JSONSerialization.jsonObject(
                    with: Data(raw.utf8)
                ) as? [String: Any] else { continue }
                if object["recordType"] as? String == "footer" {
                    footerObject = object
                    continue
                }
                if object["recordType"] as? String == recordType {
                    try mutate(&object)
                }
                let line = try JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys]
                )
                body.append(line)
                body.append(0x0A)
            }
            var footer = try XCTUnwrap(footerObject, "备份文件缺少 footer")
            let digest = SHA256.hash(data: body)
            footer["checksum"] = digest
                .map { String(format: "%02x", $0) }
                .joined()
            let footerLine = try JSONSerialization.data(
                withJSONObject: footer, options: [.sortedKeys]
            )
            body.append(footerLine)
            body.append(0x0A)
            try body.write(to: destinationURL)
        }

        /// v9 全量种子：v0.7 基线（deck/note/card/profile/document）
        /// + wire §2.1 全部 14 类新记录 + 一条 cache 哨兵。
        func seed(_ database: OboeDatabase) async throws {
            let encode: @Sendable (UUID) -> String =
                DatabaseValueCodec.encode
            let locatorJSON = String(
                decoding: try JSONEncoder().encode(
                    ReaderLocation(
                        chapterOrdinal: 0,
                        blockOrdinal: 2,
                        utf16Offset: 5,
                        blockTextHash: String(repeating: "a", count: 64),
                        prefix: "前文",
                        suffix: "后文"
                    )
                ),
                as: UTF8.self
            )
            let parametersJSON = String(
                decoding: try JSONEncoder().encode(
                    SchedulerProfile.fsrs6DefaultParameters
                ),
                as: UTF8.self
            )
            let fingerprint = String(repeating: "b", count: 64)

            try await database.pool.write { db in
                // ---- v0.7 基线 ----
                try db.execute(
                    sql: "INSERT INTO decks VALUES (?, '备份牌组', 0, 1, 2)",
                    arguments: [encode(Self.deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', '見る', 'みる', '看',
                                  'manual', 1, 1, 2)
                        """,
                    arguments: [encode(Self.vocabNoteID), encode(Self.deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        VALUES (?, ?, 1)
                        """,
                    arguments: [encode(Self.vocabNoteID), encode(Self.deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO scheduler_profiles(
                            id, configuration_version, algorithm_version,
                            library_revision, parameters_json,
                            desired_retention, max_interval_days, created_at_ms
                        ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0',
                                  ?, ?, 0.9, 36500, 1)
                        """,
                    arguments: [
                        encode(Self.profileID),
                        SwiftFSRSReviewScheduler.dependencyRevision,
                        parametersJSON
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state,
                            due_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, 'vocabulary_ja_zh', 1, 0,
                                  1789056000000, 0, 0, 0, 0, 0, 0, 0, 0,
                                  'FSRS-6.0', ?)
                        """,
                    arguments: [
                        encode(Self.vocabCardID), encode(Self.vocabNoteID),
                        encode(Self.profileID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_documents(
                            id, title, format, created_at_ms,
                            last_opened_at_ms, source_file_name,
                            source_sha256, canonical_text_hash,
                            parser_version, content_revision,
                            progress_basis_points, availability
                        ) VALUES (?, '源文档', 'txt', 1, 2, 'book.txt', ?, ?,
                                  'txt-1', 2, 2500, 'available')
                        """,
                    arguments: [
                        encode(Self.documentID),
                        String(repeating: "e", count: 64),
                        String(repeating: "f", count: 64)
                    ]
                )

                // ---- learningUnit 组（wire §2.1）----
                try db.execute(
                    sql: """
                        INSERT INTO lexical_learning_units(
                            id, identity_kind, identity_key, provider,
                            dictionary_entry_id, semantic_fingerprint,
                            fingerprint_version, lemma, reading,
                            sense_snapshot_json, binding_status, revision,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, 'dictionarySense',
                                  'jmdict:sense-v1:1434700:1', 'jmdict',
                                  1434700, ?, 'sense-fp-1', '見る', 'みる',
                                  '{"gloss":"看"}', 'current', 1, 10, 20)
                        """,
                    arguments: [encode(Self.dictionaryUnitID), fingerprint]
                )
                try db.execute(
                    sql: """
                        INSERT INTO lexical_learning_units(
                            id, identity_kind, identity_key, lemma,
                            binding_status, revision,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, 'localNote',
                                  'local-note:\(Self.vocabNoteID.uuidString)',
                                  '私有词', 'current', 0, 10, 20)
                        """,
                    arguments: [encode(Self.localUnitID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_dictionary_aliases(
                            unit_id, provider, dataset_version, entry_id,
                            sense_id, fingerprint, fingerprint_version,
                            status, resolved_at_ms
                        ) VALUES (?, 'jmdict', '2024-01', 1434700, 1, ?,
                                  'sense-fp-1', 'current', 30),
                                 (?, 'jmdict', '2024-01', 1434700, 2, ?,
                                  'sense-fp-1', 'stale', 25)
                        """,
                    arguments: [
                        encode(Self.dictionaryUnitID), fingerprint,
                        encode(Self.dictionaryUnitID), fingerprint
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_note_links(
                            unit_id, note_id, role, origin, created_at_ms
                        ) VALUES (?, ?, 'primary', 'aiPipeline', 40)
                        """,
                    arguments: [
                        encode(Self.dictionaryUnitID), encode(Self.vocabNoteID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_flags(
                            unit_id, too_easy, revision, updated_at_ms
                        ) VALUES (?, 1, 2, 50)
                        """,
                    arguments: [encode(Self.dictionaryUnitID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_events(
                            id, operation_id, unit_id, unit_id_snapshot,
                            kind, before_json, after_json, payload_hash,
                            created_at_ms, undone_at_ms
                        ) VALUES (?, ?, ?, ?, 'tooEasySet',
                                  '{"tooEasy":0}', '{"tooEasy":1}', ?, 60,
                                  NULL)
                        """,
                    arguments: [
                        encode(Self.unitEventID),
                        encode(Self.unitEventOperationID),
                        encode(Self.dictionaryUnitID),
                        encode(Self.dictionaryUnitID),
                        String(repeating: "c", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO learning_unit_migration_items(
                            source_key, note_id, status, evidence_json,
                            target_unit_id
                        ) VALUES ('v06-note-1', ?, 'applied',
                                  '{"rule":"sense-fp"}', ?)
                        """,
                    arguments: [
                        encode(Self.vocabNoteID),
                        encode(Self.dictionaryUnitID)
                    ]
                )

                // ---- Reader 派生（occurrence / translation）----
                try db.execute(
                    sql: """
                        INSERT INTO reader_study_occurrences(
                            id, document_id, content_revision, locator_json,
                            block_source_hash, tokenizer_version,
                            start_utf16, length_utf16,
                            resolution_status
                        ) VALUES (?, ?, 1, ?, ?, 'tokenizers-v1', 0, 2,
                                  'pending')
                        """,
                    arguments: [
                        encode(UUID()), encode(Self.documentID),
                        locatorJSON, String(repeating: "d", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_study_occurrences(
                            id, document_id, content_revision, locator_json,
                            block_source_hash, tokenizer_version,
                            start_utf16, length_utf16, unit_id,
                            resolution_status
                        ) VALUES (?, ?, 1, ?, ?, 'tokenizers-v1', 5, 2, ?,
                                  'aiResolved')
                        """,
                    arguments: [
                        encode(UUID()), encode(Self.documentID),
                        locatorJSON, String(repeating: "d", count: 64),
                        encode(Self.dictionaryUnitID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_translation_blocks(
                            id, document_id, locator_key, locator_json,
                            source_hash, translation_revision,
                            translated_text, language, provider, model,
                            prompt_version, request_hash, is_current,
                            created_at_ms
                        ) VALUES (?, ?, 'c0:b2', ?, ?, 1, '前文译文',
                                  'zh-Hans', 'fake-provider', 'fake-model',
                                  'prompt-v1', ?, 1, 70)
                        """,
                    arguments: [
                        encode(UUID()), encode(Self.documentID),
                        locatorJSON, String(repeating: "d", count: 64),
                        String(repeating: "1", count: 64)
                    ]
                )

                // ---- aiStudy 组：一个在途 Job（恢复语义断言对象）+
                // 一个 awaitingConfirmation Job（原样保留）----
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_jobs(
                            id, document_id, study_deck_id, scope_json,
                            input_fingerprint, content_revision,
                            provider_snapshot_json, model, pipeline_version,
                            prompt_version, policy_version, status, epoch,
                            selection_revision, processed_blocks,
                            applied_units, confirmed_units, failed_blocks,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, '{"kind":"document"}', ?, 1,
                                  '{"provider":"fake"}', 'fake-model',
                                  'pipeline-v1', 'prompt-v1', 'policy-v1',
                                  'waitingForAI', 0, 0, 1, 0, 0, 0,
                                  100, 110)
                        """,
                    arguments: [
                        encode(Self.inFlightJobID), encode(Self.documentID),
                        encode(Self.deckID),
                        String(repeating: "2", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_jobs(
                            id, document_id, study_deck_id, scope_json,
                            input_fingerprint, content_revision,
                            provider_snapshot_json, model, pipeline_version,
                            prompt_version, policy_version, status, epoch,
                            selection_revision, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, '{"kind":"document"}', ?, 2,
                                  '{"provider":"fake"}', 'fake-model',
                                  'pipeline-v1', 'prompt-v1', 'policy-v1',
                                  'awaitingConfirmation', 0, 1, 200, 210)
                        """,
                    arguments: [
                        encode(Self.awaitingJobID), encode(Self.documentID),
                        encode(Self.deckID),
                        String(repeating: "3", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_job_blocks(
                            id, job_id, locator_json, source_hash,
                            subblock_key, candidate_set_hash, request_hash,
                            status, attempt_count
                        ) VALUES (?, ?, ?, ?, 'b0', ?, ?, 'requesting', 1)
                        """,
                    arguments: [
                        encode(Self.requestingBlockID),
                        encode(Self.inFlightJobID), locatorJSON,
                        String(repeating: "4", count: 64),
                        String(repeating: "5", count: 64),
                        String(repeating: "6", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_job_blocks(
                            id, job_id, locator_json, source_hash,
                            subblock_key, candidate_set_hash, request_hash,
                            status, attempt_count
                        ) VALUES (?, ?, ?, ?, 'b1', ?, ?, 'resolved', 1)
                        """,
                    arguments: [
                        encode(Self.resolvedBlockID),
                        encode(Self.awaitingJobID), locatorJSON,
                        String(repeating: "7", count: 64),
                        String(repeating: "8", count: 64),
                        String(repeating: "9", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_resolutions(
                            id, job_id, job_block_id, document_id,
                            locator_json, token_key, request_hash,
                            selected_entry_id, selected_sense_id,
                            selected_dataset_version, unit_id, confidence,
                            status, origin, revision, created_at_ms
                        ) VALUES (?, ?, ?, ?, ?, '見る@0', ?, 1434700, 1,
                                  '2024-01', ?, 0.91, 'userConfirmed',
                                  'user', 1, 120)
                        """,
                    arguments: [
                        encode(UUID()), encode(Self.awaitingJobID),
                        encode(Self.resolvedBlockID),
                        encode(Self.documentID), locatorJSON,
                        String(repeating: "9", count: 64),
                        encode(Self.dictionaryUnitID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_selections(
                            job_id, unit_key, selection_revision, decision,
                            evidence_revision
                        ) VALUES (?, 'unit-0', 1, 'create', 0)
                        """,
                    arguments: [encode(Self.awaitingJobID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_receipts(
                            operation_id, action_key, payload_hash,
                            outcome_json, committed_at_ms
                        ) VALUES (?, 'selection-apply-0', ?,
                                  '{"applied":1}', 130)
                        """,
                    arguments: [
                        encode(Self.receiptOperationID),
                        String(repeating: "a", count: 64)
                    ]
                )

                // ---- v26 覆盖快照 ----
                try db.execute(
                    sql: """
                        INSERT INTO reader_learning_coverage_snapshots(
                            id, document_id, document_id_snapshot,
                            scope_hash, content_revision, knowledge_revision,
                            metric_version, dictionary_version,
                            morphology_version, resolved_unique,
                            unknown_unique, learning_unique, mastered_unique,
                            pending_occurrences, oov_occurrences,
                            analyzed_blocks, total_blocks, calculated_at_ms
                        ) VALUES (?, ?, ?, ?, 2, 9, 'metrics-v1',
                                  'jmdict-2024-01', 'morph-v1', 7, 3, 2, 11,
                                  4, 1, 12, 15, 140)
                        """,
                    arguments: [
                        encode(UUID()), encode(Self.documentID),
                        encode(Self.documentID),
                        String(repeating: "0", count: 64)
                    ]
                )

                // ---- 运行态哨兵：绝不进备份 ----
                try db.execute(
                    sql: """
                        INSERT INTO ai_study_cache(
                            request_hash, validated_result_json, size_bytes,
                            created_at_ms, last_accessed_at_ms
                        ) VALUES (?, ?, 1, 1, 1)
                        """,
                    arguments: [
                        String(repeating: "7", count: 64),
                        #"{"payload":"\#(Self.cacheSentinel)"}"#
                    ]
                )
            }
        }
    }
}
