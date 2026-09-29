import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// 记录协议 v8（v0.7.0 S23，设计 §14 / contracts-frozen §5）：Reader
/// 元数据、lexical knowledge、Cloze 独立快照、Reader/Import/活用历史
/// 的导出—恢复往返，以及排除红线和坏记录预检。
///
/// v8 记录类型在当前协议（v9）下继续导出/恢复；v8 版本号本身自
/// v0.7.5 起只读不可再生成（见 `testLegacyRecordFormatVersionIsNotExportable`）。
final class PortableBackupV8RecordsTests: XCTestCase {

    // MARK: - 导出与记录序

    /// 当前协议（v9）NDJSON：manifest 声明当前版本、recordOrder/counts
    /// 覆盖全部 50 类记录、父先子后顺序逐对成立、v7 记录的相对顺序
    /// 不漂移，且实际记录行严格按声明顺序排列。
    func testCurrentExportManifestAndRecordOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportCurrent(source)

        let objects = try fixture.backupObjects(backup.url)
        let manifest = try XCTUnwrap(objects.first)
        XCTAssertEqual(manifest["formatVersion"] as? Int,
                       PortableBackupFormat.currentVersion)
        let recordOrder = try XCTUnwrap(manifest["recordOrder"] as? [String])
        XCTAssertEqual(recordOrder, PortableBackupFormatV9.recordTypes)
        XCTAssertEqual(recordOrder.count, 50)
        let counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
        XCTAssertEqual(Set(counts.keys), Set(recordOrder))
        let scopes = try XCTUnwrap(manifest["excludedScopes"] as? [String])
        for scope in [
            "readerContent", "readerDerivedData", "dictionaryData",
            "importStaging"
        ] {
            XCTAssertTrue(scopes.contains(scope), "v8 manifest 缺 \(scope)")
        }

        // 冻结 §5 依赖链：在声明顺序上逐对断言（覆盖未播种类型）。
        let position = Dictionary(
            uniqueKeysWithValues: recordOrder.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let parentsFirst: [(String, String)] = [
            ("deck", "readerDocument"),
            ("readerDocument", "readerChapter"),
            ("readerChapter", "readerPosition"),
            ("readerChapter", "readerBookmark"),
            ("readerBookmark", "note"),
            ("note", "noteDeck"),
            ("noteDeck", "lexeme"),
            ("lexeme", "lexemeNoteLink"),
            ("lexeme", "vocabularyKnowledgeOverride"),
            ("lexemeNoteLink", "sourceContext"),
            ("vocabularyKnowledgeOverride", "sourceContext"),
            ("noteDeck", "sourceContext"),
            ("sourceContext", "profile"),
            ("profile", "card"),
            ("card", "clozeDefinition"),
            ("review", "readerActivityEvent"),
            ("readerActivityEvent", "readerMiningReceipt"),
            ("studyDay", "readerCoverageSnapshot"),
            ("deck", "importJob"),
            ("importJob", "importRowReceipt"),
            ("conjugationSession", "conjugationPracticeAttempt"),
            ("scheduledReviewOrigin", "readerActivityEvent")
        ]
        for (parent, child) in parentsFirst {
            XCTAssertLessThan(
                position[parent]!, position[child]!,
                "\(parent) 必须排在 \(child) 之前"
            )
        }
        // v7 旧记录的相对顺序不漂移（抽查锚点）。
        XCTAssertLessThan(position["note"]!, position["example"]!)
        XCTAssertLessThan(position["tag"]!, position["noteTag"]!)
        XCTAssertLessThan(position["card"]!, position["studyDay"]!)
        XCTAssertLessThan(position["inboxItem"]!, position["inboxCommitReceipt"]!)
        XCTAssertEqual(position["settings"], recordOrder.count - 1)

        // 实际记录行单调不减地遵循声明顺序（footer 在最后）。
        var last = -1
        for object in objects.dropFirst().dropLast() {
            let type = try XCTUnwrap(object["recordType"] as? String)
            let index = try XCTUnwrap(position[type])
            XCTAssertGreaterThanOrEqual(index, last)
            last = index
        }
        XCTAssertEqual(objects.last?["recordType"] as? String, "footer")
    }

    /// 默认导出即 v9：v0.7.5 起 currentVersion=9，记录序覆盖全部
    /// 50 类（数据为空的类型照常进 recordOrder/counts）。
    func testDefaultExportIsV9() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seedV7Compatible(source)
        let backup = try await PortableBackupExporter(
            database: source,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "test", at: fixture.exportedAt)
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
    }

    /// 早于当前默认的版本不可再生成：v6/v7/v8 opt-in 都必须报错
    /// 而不是静默降级。
    func testLegacyRecordFormatVersionIsNotExportable() async throws {
        for version in [6, 7, 8] {
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
                    recordFormatVersion: version
                )
                XCTFail("v\(version) 记录版本不得再被生成")
            } catch let error as PortableBackupExportError {
                XCTAssertEqual(
                    error,
                    .unsupportedRecordFormatVersion(version)
                )
            }
        }
    }

    // MARK: - 排除红线

    /// v8 记录流绝不携带正文、可重建缓存、资产路径、词典台账、
    /// staging 路径——源库里放进哨兵数据，断言它们没有任何字节泄漏。
    func testV8ExportExcludesReaderContentAndLocalArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportCurrent(source)
        let text = try String(contentsOf: backup.url, encoding: .utf8)

        // 表名不得作为记录类型出现。
        for banned in [
            "reader_blocks", "reader_assets", "reader_token_cache",
            "dictionary_artifact_records", "lexeme_dictionary_bindings"
        ] {
            XCTAssertFalse(text.contains(banned), "v8 记录流泄漏了 \(banned)")
        }
        // 哨兵值：正文文本、资产相对路径、token payload、词典 hash、
        // 工作目录绝对路径，一律不得出现。
        for sentinel in Fixture.excludedSentinels + [fixture.rootURL.path] {
            XCTAssertFalse(
                text.contains(sentinel),
                "v8 记录流泄漏了哨兵值 \(sentinel)"
            )
        }
        // 被排除的表在 manifest counts 中也没有入口。
        let manifest = try XCTUnwrap(fixture.backupObjects(backup.url).first)
        let counts = try XCTUnwrap(manifest["counts"] as? [String: Any])
        for banned in ["readerBlock", "readerAsset", "readerTokenCache",
                       "dictionaryArtifactRecord", "lexemeDictionaryBinding"] {
            XCTAssertNil(counts[banned])
        }
    }

    // MARK: - round trip

    /// v8 导出 → prepare → 临时库：全部新记录逐字段一致；availability
    /// 强制 missing（不假恢复 available）；未终态 job/session 标
    /// interrupted/abandoned；被排除表在恢复库中为空。
    func testV8RoundTripPreservesNewRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportCurrent(source)

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: backup.url)
        XCTAssertEqual(prepared.sourceFormatVersion,
                       PortableBackupFormat.currentVersion)
        XCTAssertEqual(prepared.preparedFormatVersion,
                       PortableBackupFormat.currentVersion)
        XCTAssertEqual(prepared.backup.recordCounts["readerDocument"], 1)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            // Reader 元数据
            let document = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_documents"
            ))
            XCTAssertEqual(document["title"] as? String, "源文档")
            XCTAssertEqual(document["format"] as? String, "txt")
            // 恢复语义：绝不假恢复 available/processing。
            XCTAssertEqual(document["availability"] as? String, "missing")
            let chapter = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_chapters"
            ))
            XCTAssertEqual(chapter["ordinal"] as? Int64, 0)
            XCTAssertEqual(chapter["text_utf16_length"] as? Int64, 1234)
            let position = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_positions"
            ))
            let locationJSON: String = position["locator_json"]
            let location = try JSONDecoder().decode(
                ReaderLocation.self,
                from: Data(locationJSON.utf8)
            )
            XCTAssertEqual(location.blockOrdinal, 2)
            XCTAssertEqual(
                position["document_id"] as? String,
                DatabaseValueCodec.encode(fixture.documentID)
            )
            let bookmark = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_bookmarks"
            ))
            XCTAssertEqual(bookmark["label"] as? String, "好句")

            // lexical
            let lexeme = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM lexemes WHERE provider = 'jmdict'"
            ))
            XCTAssertEqual(lexeme["written_form"] as? String, "見る")
            XCTAssertEqual(lexeme["resolution_status"] as? String, "resolved")
            let link = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM lexeme_note_links"
            ))
            XCTAssertEqual(
                link["association_origin"] as? String, "userConfirmed"
            )
            let override = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM vocabulary_knowledge_overrides"
            ))
            XCTAssertEqual(override["state"] as? String, "ignored")

            // Cloze：快照全字段一致，且可被 validatePersisted 复检通过。
            let cloze = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM cloze_definitions"
            ))
            let sentence: String = cloze["sentence_snapshot"]
            XCTAssertEqual(sentence, Fixture.ClozeCase.sentence)
            XCTAssertEqual(
                cloze["sentence_sha256"] as? String,
                ClozeValidator.snapshotSHA256(sentence)
            )
            XCTAssertEqual(cloze["target_surface"] as? String, "見た")
            XCTAssertEqual(cloze["range_utf16_start"] as? Int64, 7)
            XCTAssertEqual(cloze["range_utf16_length"] as? Int64, 2)
            XCTAssertEqual(
                cloze["source_context_id"] as? String,
                DatabaseValueCodec.encode(fixture.sourceContextID)
            )
            let answersJSON: String = cloze["accepted_answers_json"]
            XCTAssertEqual(
                try JSONDecoder().decode(
                    [String].self, from: Data(answersJSON.utf8)
                ),
                ["見た", "みた"]
            )
            let sentenceNote = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, headword, origin, meaning_zh FROM notes
                    WHERE kind = 'sentence'
                    """
            ))
            XCTAssertEqual(sentenceNote["headword"] as? String, sentence)
            XCTAssertEqual(sentenceNote["origin"] as? String, "reader")
            XCTAssertEqual(
                sentenceNote["meaning_zh"] as? String, "我昨天看了电影。"
            )
            // sourceContext 的 v8 定位列。
            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_contexts WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(fixture.sentenceNoteID)]
            ))
            XCTAssertEqual(
                context["reader_document_id"] as? String,
                DatabaseValueCodec.encode(fixture.documentID)
            )
            XCTAssertEqual(context["selected_surface"] as? String, "見た")

            // 历史：event/receipt/coverage 全保留。
            let event = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_activity_events"
            ))
            XCTAssertEqual(event["kind"] as? String, "minedNewNote")
            XCTAssertEqual(
                event["document_id"] as? String,
                DatabaseValueCodec.encode(fixture.documentID)
            )
            let receipt = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_mining_receipts"
            ))
            XCTAssertEqual(receipt["kind"] as? String, "mine_vocabulary")
            let coverage = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT * FROM reader_coverage_snapshots"
            ))
            XCTAssertEqual(coverage["known_count"] as? Int64, 42)
            XCTAssertEqual(coverage["document_title"] as? String, "源文档")

            // Import 历史：completed 保留，running → interrupted。
            let jobs = try Row.fetchAll(
                db,
                sql: "SELECT status FROM import_jobs ORDER BY created_at_ms"
            )
            XCTAssertEqual(
                jobs.compactMap { $0["status"] as? String },
                ["completed", "interrupted"]
            )
            let rowReceipt = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT action, logical_row FROM import_row_receipts"
            ))
            XCTAssertEqual(rowReceipt["action"] as? String, "created")
            XCTAssertEqual(rowReceipt["logical_row"] as? Int64, 3)

            // 活用：finished 保留，active → abandoned（finished_at=导出时刻）。
            let sessions = try Row.fetchAll(
                db,
                sql: """
                    SELECT status, finished_at_ms FROM conjugation_sessions
                    ORDER BY started_at_ms
                    """
            )
            XCTAssertEqual(
                sessions.compactMap { $0["status"] as? String },
                ["finished", "abandoned"]
            )
            let expectedMs = try DatabaseValueCodec.encode(fixture.exportedAt)
            XCTAssertEqual(
                sessions[1]["finished_at_ms"] as? Int64, expectedMs
            )
            let attempt = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: """
                    SELECT result, lemma, matched_answer
                    FROM conjugation_practice_attempts
                    """
            ))
            XCTAssertEqual(attempt["result"] as? String, "correct")
            XCTAssertEqual(attempt["lemma"] as? String, "見る")
            XCTAssertEqual(attempt["matched_answer"] as? String, "見た")

            // 排除表在恢复库中为空——记录从未离开源库。
            for table in [
                "reader_blocks", "reader_assets", "reader_token_cache",
                "dictionary_artifact_records", "lexeme_dictionary_bindings"
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0,
                    "\(table) 在恢复库中必须为空"
                )
            }
        }
    }

    // MARK: - 坏包预检

    /// 坏 Cloze 记录（hash/range/surface/answers/rangeVersion 任一不一致）
    /// 整包拒绝，且当前数据库不被触碰。
    func testCorruptClozeRecordsAreRejected() async throws {
        let corruptions: [(String, (inout [String: Any]) -> Void)] = [
            ("hash", { record in
                record["sentence_sha256"] = String(repeating: "0", count: 64)
            }),
            ("range", { record in
                record["range_utf16_start"] = 0
            }),
            ("surface", { record in
                record["target_surface"] = "行った"
            }),
            ("answers-missing-surface", { record in
                record["accepted_answers_json"] = #"["みた"]"#
            }),
            ("range-version", { record in
                record["range_version"] = 99
            })
        ]
        for (name, corrupt) in corruptions {
            let fixture = try Fixture()
            let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
            try await fixture.seed(source)
            let backup = try await fixture.exportCurrent(source)
            let corruptURL = fixture.uniqueURL("corrupt-\(name).oboe-backup")
            try rewriteBackup(backup.url, to: corruptURL) { objects in
                let index = objects.firstIndex {
                    $0["recordType"] as? String == "clozeDefinition"
                }!
                corrupt(&objects[index])
            }
            let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
            try await fixture.seedCurrent(current)
            do {
                _ = try await fixture.preparer(current: current)
                    .prepare(fileURL: corruptURL)
                XCTFail("坏 Cloze（\(name)）必须被拒绝")
            } catch let error as PortableBackupPreparationError {
                guard case .databaseValidation = error else {
                    fixture.remove()
                    return XCTFail(
                        "\(name)：预期 databaseValidation，实得 \(error)"
                    )
                }
            }
            // 当前库不被触碰。
            let deckName = try await current.pool.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM decks")
            }
            XCTAssertEqual(deckName, "当前资料")
            fixture.remove()
        }
    }

    /// 孤儿引用、跨文档挂接、缺定义、未知类型、路径夹带、坏 locator、
    /// 坏 identity key 一律整包拒绝。
    func testOrphanAndInconsistentV8RecordsAreRejected() async throws {
        // 孤儿 lexemeNoteLink：lexeme_id 指向不存在的 lexeme → FK 违例。
        try await assertRejected("orphan-lexeme-note-link") { objects in
            let index = objects.firstIndex {
                $0["recordType"] as? String == "lexemeNoteLink"
            }!
            objects[index]["lexeme_id"] = DatabaseValueCodec.encode(UUID())
        }
        // 孤儿 clozeDefinition：note_id 指向不存在的 Note → FK 违例。
        try await assertRejected("orphan-cloze-note") { objects in
            let index = objects.firstIndex {
                $0["recordType"] as? String == "clozeDefinition"
            }!
            objects[index]["note_id"] = DatabaseValueCodec.encode(UUID())
        }
        // 跨文档书签：chapter 属于另一 document。
        try await assertRejected("cross-document-bookmark") { objects in
            let extraDocID = DatabaseValueCodec.encode(UUID())
            let extraChapterID = DatabaseValueCodec.encode(UUID())
            objects.insert(
                [
                    "recordType": "readerDocument", "id": extraDocID,
                    "title": "别的书", "format": "txt",
                    "created_at_ms": 1, "last_opened_at_ms": NSNull(),
                    "source_file_name": "other.txt",
                    "source_sha256": String(repeating: "b", count: 64),
                    "canonical_text_hash": String(repeating: "c", count: 64),
                    "parser_version": "txt-1", "content_revision": 1,
                    "progress_basis_points": 0, "availability": "available"
                ],
                at: objects.firstIndex {
                    $0["recordType"] as? String == "readerChapter"
                }!
            )
            objects.insert(
                [
                    "recordType": "readerChapter", "id": extraChapterID,
                    "document_id": extraDocID, "ordinal": 0,
                    "title": NSNull(), "source_locator": NSNull(),
                    "canonical_hash": String(repeating: "d", count: 64),
                    "text_utf16_length": 10
                ],
                at: objects.firstIndex {
                    $0["recordType"] as? String == "readerPosition"
                }!
            )
            let bookmarkIndex = objects.firstIndex {
                $0["recordType"] as? String == "readerBookmark"
            }!
            objects[bookmarkIndex]["chapter_id"] = extraChapterID
            var counts = objects[0]["counts"] as! [String: Any]
            counts["readerDocument"] = 2
            counts["readerChapter"] = 2
            objects[0]["counts"] = counts
        }
        // sentence Note 没有 clozeDefinition → §9.1 完整性失败。
        try await assertRejected("sentence-note-without-definition") { objects in
            objects.removeAll {
                $0["recordType"] as? String == "clozeDefinition"
            }
            var counts = objects[0]["counts"] as! [String: Any]
            counts["clozeDefinition"] = 0
            objects[0]["counts"] = counts
        }
        // 未知记录类型不得静默丢弃。
        try await assertRejected("unknown-record-type") { objects in
            // footer 已由 rewriteBackup 摘除：尾部追加一条未知类型。
            objects.append(["recordType": "mysteryV9", "id": "x"])
        }
        // staging_file_name 夹带路径 → 拒绝。
        try await assertRejected("staging-path-leak") { objects in
            let index = objects.firstIndex {
                $0["recordType"] as? String == "importJob"
            }!
            objects[index]["staging_file_name"] = "../escape.sqlite"
        }
        // 无法解码的 locator JSON → 拒绝。
        try await assertRejected("invalid-locator") { objects in
            let index = objects.firstIndex {
                $0["recordType"] as? String == "readerPosition"
            }!
            objects[index]["locator_json"] = #"{"version": 9}"#
        }
        // lexeme identity_key 与 provider/entry 组合不符 → 拒绝。
        try await assertRejected("bad-identity-key") { objects in
            let index = objects.firstIndex {
                $0["recordType"] as? String == "lexeme"
                    && $0["provider"] as? String == "jmdict"
            }!
            objects[index]["identity_key"] = "local|見る|みる|verb"
        }
        // 重复记录：再写一条相同 PK 的 clozeDefinition → PK 冲突拒绝。
        try await assertRejected("duplicate-cloze-record") { objects in
            let index = objects.firstIndex {
                $0["recordType"] as? String == "clozeDefinition"
            }!
            objects.insert(objects[index], at: index + 1)
            var counts = objects[0]["counts"] as! [String: Any]
            counts["clozeDefinition"] = 2
            objects[0]["counts"] = counts
        }
    }

    private func assertRejected(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ transform: @escaping (inout [[String: Any]]) -> Void
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let backup = try await fixture.exportCurrent(source)
        let corruptedURL = fixture.uniqueURL("\(name).oboe-backup")
        try rewriteBackup(backup.url, to: corruptedURL, transform: transform)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        do {
            _ = try await fixture.preparer(current: current)
                .prepare(fileURL: corruptedURL)
            XCTFail("\(name) 必须被拒绝", file: file, line: line)
        } catch is PortableBackupPreparationError {
            // 预期路径：任一类预检错误都算整包拒绝。
        }
        let deckName = try await current.pool.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM decks")
        }
        XCTAssertEqual(deckName, "当前资料", file: file, line: line)
    }

    // MARK: - ZIP 包

    /// v8/v8 包：manifest 版本对、v8 excludedScopes、records 不含哨兵，
    /// preparePackage 往返数据完整。
    func testV8PackageRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: fixture.store,
            workingDirectoryURL: fixture.exportsURL
        )
        let export = try await exporter.export(
            appVersion: "8.0-test",
            at: fixture.exportedAt,
            formatVersion: 9
        )

        let files = try fixture.unzip(export.url)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: files["manifest.json"]!)
                as? [String: Any]
        )
        XCTAssertEqual(manifest["formatVersion"] as? Int, 9)
        XCTAssertEqual(manifest["recordFormatVersion"] as? Int, 9)
        XCTAssertEqual(
            manifest["recordOrder"] as? [String],
            PortableBackupFormatV9.recordTypes
        )
        let scopes = try XCTUnwrap(manifest["excludedScopes"] as? [String])
        XCTAssertTrue(scopes.contains("readerContent"))
        XCTAssertFalse(scopes.contains("imageAttachments"))
        let records = try XCTUnwrap(files["records.ndjson"])
        let recordsText = String(decoding: records, as: UTF8.self)
        for sentinel in Fixture.excludedSentinels {
            XCTAssertFalse(
                recordsText.contains(sentinel),
                "v8 包 records 泄漏 \(sentinel)"
            )
        }

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        let prepared = try await fixture.preparer(current: current)
            .preparePackage(fileURL: export.url)
        XCTAssertEqual(prepared.sourceFormatVersion,
                       PortableBackupFormat.currentVersion)
        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM cloze_definitions"
                ),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM reader_documents"
                ),
                1
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT availability FROM reader_documents"
                ),
                "missing"
            )
        }
    }

    /// 非法版本对 (8,6)/(7,8)/(8,7) 一律拒绝。
    func testPackageVersionPairIsEnforced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seed(source)
        let exporter = PortableBackupPackageExporter(
            database: source,
            imageStore: fixture.store,
            workingDirectoryURL: fixture.exportsURL
        )
        let export = try await exporter.export(
            appVersion: "8.0-test",
            at: fixture.exportedAt,
            formatVersion: 9
        )
        for (packageVersion, recordVersion) in [(8, 6), (7, 8), (8, 7)] {
            let mutatedURL = fixture.uniqueURL(
                "pair-\(packageVersion)-\(recordVersion).oboe-backup"
            )
            try fixture.repackaging(export.url, to: mutatedURL) { files in
                var manifest = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: files["manifest.json"]!)
                        as? [String: Any]
                )
                manifest["formatVersion"] = packageVersion
                manifest["recordFormatVersion"] = recordVersion
                files["manifest.json"] = try JSONSerialization.data(
                    withJSONObject: manifest, options: [.sortedKeys]
                )
            }
            XCTAssertThrowsError(
                try PortableBackupPackageReader().readManifest(
                    fileURL: mutatedURL
                ),
                "版本对 \(packageVersion)/\(recordVersion) 必须被拒绝"
            ) { error in
                guard let packageError = error as? PortableBackupPackageError,
                      case .invalidManifest = packageError else {
                    return XCTFail(
                        "\(packageVersion)/\(recordVersion)：预期 "
                            + "invalidManifest，实得 \(error)"
                    )
                }
            }
        }
    }

    // MARK: - v7 及以下回归

    /// v7 备份仍按旧规格解析：v8 新表在临时库存在但为空，
    /// sourceContext 不带 v8 定位列也能恢复（迁移补 NULL）。
    /// 注：v7 格式表达不了 v0.7 新实体——本测试用 v0.6 形态种子。
    func testV7BackupStillRestoresWithEmptyV8Tables() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await fixture.seedV7Compatible(source)
        // 默认导出 v8 → 降级出 v7 fixture（v7 已不可再生成）。
        let v8Backup = try await PortableBackupExporter(
            database: source,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "test", at: fixture.exportedAt)
        let backup = fixture.exportsURL.appendingPathComponent(
            "v7-fixture.oboe-backup"
        )
        try rewriteBackup(v8Backup.url, to: backup) { objects in
            downgradeBackupToLegacyFormat(&objects, version: 7)
        }

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await fixture.seedCurrent(current)
        let prepared = try await fixture.preparer(current: current)
            .prepare(fileURL: backup)
        XCTAssertEqual(prepared.sourceFormatVersion, 7)
        XCTAssertEqual(
            prepared.preparedFormatVersion,
            PortableBackupFormat.currentVersion
        )

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        defer { try? queue.close() }
        try await queue.read { db in
            for table in [
                "reader_documents", "lexemes", "cloze_definitions",
                "import_jobs", "conjugation_practice_attempts"
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"),
                    0
                )
            }
            // v7 记录的 sourceContext 照常恢复，v8 新列落 NULL。
            let context = try XCTUnwrap(try Row.fetchOne(
                db,
                sql: "SELECT source_type, reader_document_id FROM source_contexts"
            ))
            XCTAssertEqual(context["source_type"] as? String, "ocr")
            let readerDocumentID: String? = context["reader_document_id"]
            XCTAssertNil(readerDocumentID)
        }
    }
}

// MARK: - 测试夹具

private extension PortableBackupV8RecordsTests {
    struct Fixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let storeURL: URL
        let store: InboxImageStore
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        // 稳定 id：测试断言里要逐字段核对。
        let deckID = UUID()
        let vocabNoteID = UUID()
        let sentenceNoteID = UUID()
        let sourceContextID = UUID()
        let profileID = UUID()
        let vocabCardID = UUID()
        let clozeCardID = UUID()
        let clozeDefinitionID = UUID()
        let documentID = UUID()
        let chapterID = UUID()
        let bookmarkID = UUID()
        let lexemeAID = UUID()
        let lexemeBID = UUID()
        let eventID = UUID()
        let coverageID = UUID()
        let studyDayID = UUID()
        let completedJobID = UUID()
        let runningJobID = UUID()
        let finishedSessionID = UUID()
        let activeSessionID = UUID()
        let attemptID = UUID()

        /// 不应出现在任何 v8 文件里的哨兵值（正文、资产路径、token、
        /// 词典台账、绑定数据集名；绝对路径由 rootURL.path 覆盖）。
        static let excludedSentinels = [
            "SENTINEL_block_text_正文不得导出",
            "SENTINEL_asset/path.epub",
            "SENTINEL_token_payload",
            "SENTINEL_dictionary_sha",
            "SENTINEL_binding"
        ]

        /// 复用 s12 fixture 的 basic-kanji-target 样本（已验证 hash/range）。
        enum ClozeCase {
            static let sentence = "私は昨日映画を見た。"
            static let sha256 = "2b2de942e32d25fdad26ce16a510651a223645ddd6d25bf08bf286ebfac90302"
            static let surface = "見た"
            static let lemma = "見る"
            static let reading = "みた"
            static let start = 7
            static let length = 2
            static let answers = ["見た", "みた"]
        }

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupV8RecordsTests-\(UUID().uuidString)",
                isDirectory: true
            )
            sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
            currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            preparationsURL = rootURL.appendingPathComponent(
                "preparations", isDirectory: true
            )
            storeURL = rootURL.appendingPathComponent("images", isDirectory: true)
            store = InboxImageStore(rootDirectoryURL: storeURL)
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func uniqueURL(_ name: String) -> URL {
            rootURL.appendingPathComponent(
                "\(UUID().uuidString.lowercased())-\(name)"
            )
        }

        func exportCurrent(_ database: OboeDatabase) async throws -> PortableBackupExport {
            try await PortableBackupExporter(
                database: database,
                workingDirectoryURL: exportsURL
            ).export(
                appVersion: "test",
                at: exportedAt,
                recordFormatVersion: PortableBackupFormat.currentVersion
            )
        }

        func preparer(current: OboeDatabase) -> PortableBackupRestorationPreparer {
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

        func unzip(_ url: URL) throws -> [String: Data] {
            let reader = try ZipArchive.Reader(data: Data(contentsOf: url))
            var result: [String: Data] = [:]
            for entry in reader.entries where !entry.isDirectory {
                result[entry.name] = try reader.extract(entry)
            }
            return result
        }

        /// 解包 → transform → 重打包（沿用 v7 测试的 manifest 篡改手法）。
        func repackaging(
            _ sourceURL: URL,
            to destinationURL: URL,
            transform: (inout [String: Data]) throws -> Void
        ) throws {
            var files = try unzip(sourceURL)
            try transform(&files)
            let writer = try StreamingZipWriter(fileURL: destinationURL)
            for name in ["records.ndjson", "manifest.json", "checksums.json"]
                where files[name] != nil {
                try writer.beginEntry(name: name, method: .deflate)
                try writer.write(files[name]!)
                _ = try writer.finishEntry()
            }
            try writer.finalizeArchive()
        }

        // MARK: - 种子

        /// 仅 v0.6 形态的数据：deck + 词汇 note + 卡 + profile +
        /// 无 Reader 定位的 sourceContext。v7 备份回归用。
        func seedV7Compatible(_ database: OboeDatabase) async throws {
            let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
            let parametersJSON = String(
                decoding: try JSONEncoder().encode(
                    SchedulerProfile.fsrs6DefaultParameters
                ),
                as: UTF8.self
            )
            try await database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO decks VALUES (?, '备份牌组', 0, 1, 2)",
                    arguments: [encode(deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', '見る', 'みる', '看',
                                  'manual', 1, 1, 2)
                        """,
                    arguments: [encode(vocabNoteID), encode(deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        VALUES (?, ?, 1)
                        """,
                    arguments: [encode(vocabNoteID), encode(deckID)]
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
                        encode(profileID),
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
                        encode(vocabCardID), encode(vocabNoteID),
                        encode(profileID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO source_contexts(
                            id, note_id, source_type, original_sentence,
                            source_title, is_primary, created_at_ms
                        ) VALUES (?, ?, 'ocr', 'パンを食べたい。',
                                  '截图来源', 1, 1)
                        """,
                    arguments: [encode(sourceContextID), encode(vocabNoteID)]
                )
            }
        }

        /// 完整 v0.7 形态：Reader 元数据、lexical、Cloze、历史、Import、
        /// 活用全部种入；另带哨兵数据验证排除红线。
        func seed(_ database: OboeDatabase) async throws {
            let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
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
            let answersJSON = String(
                decoding: try JSONEncoder().encode(ClozeCase.answers),
                as: UTF8.self
            )

            try await database.pool.write { db in
                try db.execute(
                    sql: "INSERT INTO decks VALUES (?, '备份牌组', 0, 1, 2)",
                    arguments: [encode(deckID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', '見る', 'みる', '看',
                                  'manual', 1, 1, 2)
                        """,
                    arguments: [encode(vocabNoteID), encode(deckID)]
                )
                // sentence Note（Cloze 宿主）：meaning_zh 可空但这里给出。
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'sentence', ?, '我昨天看了电影。',
                                  'reader', 1, 1, 2)
                        """,
                    arguments: [
                        encode(sentenceNoteID), encode(deckID),
                        ClozeCase.sentence
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                        VALUES (?, ?, 1), (?, ?, 1)
                        """,
                    arguments: [
                        encode(vocabNoteID), encode(deckID),
                        encode(sentenceNoteID), encode(deckID)
                    ]
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
                        encode(profileID),
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
                        encode(vocabCardID), encode(vocabNoteID),
                        encode(profileID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state,
                            due_at_ms, stability, difficulty, reps, lapses,
                            scheduled_days, elapsed_days, learning_step,
                            state_version, algorithm_version, profile_id
                        ) VALUES (?, ?, 'sentence_cloze', 1, 0,
                                  1789056000000, 0, 0, 0, 0, 0, 0, 0, 0,
                                  'FSRS-6.0', ?)
                        """,
                    arguments: [
                        encode(clozeCardID), encode(sentenceNoteID),
                        encode(profileID)
                    ]
                )

                // Reader 元数据：document + chapter + position + bookmark。
                try db.execute(
                    sql: """
                        INSERT INTO reader_documents(
                            id, title, format, created_at_ms,
                            last_opened_at_ms, source_file_name,
                            source_sha256, canonical_text_hash,
                            parser_version, content_revision,
                            progress_basis_points, availability
                        ) VALUES (?, '源文档', 'txt', 1, 2, 'book.txt', ?, ?,
                                  'txt-1', 1, 2500, 'available')
                        """,
                    arguments: [
                        encode(documentID),
                        String(repeating: "e", count: 64),
                        String(repeating: "f", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_chapters(
                            id, document_id, ordinal, title, source_locator,
                            canonical_hash, text_utf16_length
                        ) VALUES (?, ?, 0, '第一章', NULL, ?, 1234)
                        """,
                    arguments: [
                        encode(chapterID), encode(documentID),
                        String(repeating: "1", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_positions(
                            document_id, chapter_id, locator_json, updated_at_ms
                        ) VALUES (?, ?, ?, 3)
                        """,
                    arguments: [
                        encode(documentID), encode(chapterID), locatorJSON
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_bookmarks(
                            id, document_id, chapter_id, locator_json,
                            label, created_at_ms
                        ) VALUES (?, ?, ?, ?, '好句', 4)
                        """,
                    arguments: [
                        encode(bookmarkID), encode(documentID),
                        encode(chapterID), locatorJSON
                    ]
                )
                // 哨兵：正文块 / 资产 / token cache —— 源库存在但绝不导出。
                let blockID = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO reader_blocks(
                            id, document_id, chapter_id, ordinal, text,
                            text_hash, locator_json
                        ) VALUES (?, ?, ?, 0,
                                  'SENTINEL_block_text_正文不得导出', ?, NULL)
                        """,
                    arguments: [
                        encode(blockID), encode(documentID),
                        encode(chapterID), String(repeating: "2", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_assets(
                            document_id, relative_path, source_sha256,
                            install_state
                        ) VALUES (?, 'SENTINEL_asset/path.epub', ?,
                                  'installed')
                        """,
                    arguments: [
                        encode(documentID), String(repeating: "3", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_token_cache(
                            block_id, text_hash, tokenizer_version,
                            dictionary_version, payload
                        ) VALUES (?, ?, 'tokenizer-1', 'dict-1', ?)
                        """,
                    arguments: [
                        encode(blockID), String(repeating: "4", count: 64),
                        Data("SENTINEL_token_payload".utf8)
                    ]
                )
                // 词典台账 + 绑定：源库存在但按归属决策不导出。
                try db.execute(
                    sql: """
                        INSERT INTO dictionary_artifact_records(
                            id, file_sha256, byte_count, schema_version,
                            dataset_version, verification_status,
                            first_seen_at_ms, last_verified_at_ms
                        ) VALUES (?, ?, 100, 'ds-1', '2025.1',
                                  'verified', 1, 2)
                        """,
                    arguments: [
                        encode(UUID()),
                        "SENTINEL_dictionary_sha"
                            + String(repeating: "0", count: 41)
                    ]
                )

                // lexical：jmdict lexeme + local lexeme（override 宿主）。
                try db.execute(
                    sql: """
                        INSERT INTO lexemes(
                            id, provider, external_id, entry_id,
                            written_form, reading, normalized_lemma,
                            pos_family, identity_key,
                            resolution_status, created_at_ms
                        ) VALUES (?, 'jmdict', '1358280', 1358280,
                                  '見る', 'みる', '見る', 'verb',
                                  'jmdict|1358280|見る|みる',
                                  'resolved', 1)
                        """,
                    arguments: [encode(lexemeAID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO lexemes(
                            id, provider, external_id, entry_id,
                            written_form, reading, normalized_lemma,
                            pos_family, identity_key,
                            resolution_status, created_at_ms
                        ) VALUES (?, 'local', '謎語|なぞなぞ|noun', NULL,
                                  '謎語', 'なぞなぞ', '謎語', 'noun',
                                  'local|謎語|なぞなぞ|noun',
                                  'unresolved', 1)
                        """,
                    arguments: [encode(lexemeBID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO lexeme_note_links(
                            lexeme_id, note_id, association_origin,
                            confidence, created_at_ms
                        ) VALUES (?, ?, 'userConfirmed', 1.0, 1)
                        """,
                    arguments: [encode(lexemeAID), encode(vocabNoteID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO lexeme_dictionary_bindings(
                            lexeme_id, entry_id, match_tier,
                            dataset_version, status, resolved_at_ms,
                            updated_at_ms
                        ) VALUES (?, 1358280, 'exactWritten',
                                  'SENTINEL_binding', 'current', 1, 2)
                        """,
                    arguments: [encode(lexemeAID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO vocabulary_knowledge_overrides(
                            lexeme_id, state, updated_at_ms
                        ) VALUES (?, 'ignored', 5)
                        """,
                    arguments: [encode(lexemeBID)]
                )

                // Cloze：sentence Note + 唯一定义 + 唯一卡 + reader 来源。
                try db.execute(
                    sql: """
                        INSERT INTO source_contexts(
                            id, note_id, source_type, original_sentence,
                            reader_document_id, reader_chapter_id,
                            reader_location, selected_surface,
                            is_primary, created_at_ms
                        ) VALUES (?, ?, 'reader', ?, ?, ?, ?, ?, 1, 1)
                        """,
                    arguments: [
                        encode(sourceContextID), encode(sentenceNoteID),
                        ClozeCase.sentence, encode(documentID),
                        encode(chapterID), locatorJSON, ClozeCase.surface
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO cloze_definitions(
                            id, note_id, card_id, source_context_id,
                            sentence_snapshot, sentence_sha256,
                            range_version, range_utf16_start,
                            range_utf16_length, target_surface,
                            target_lemma, target_reading,
                            accepted_answers_json, hint, content_version
                        ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?,
                                  '動詞・過去形', 1)
                        """,
                    arguments: [
                        encode(clozeDefinitionID), encode(sentenceNoteID),
                        encode(clozeCardID), encode(sourceContextID),
                        ClozeCase.sentence, ClozeCase.sha256,
                        ClozeCase.start, ClozeCase.length, ClozeCase.surface,
                        ClozeCase.lemma, ClozeCase.reading, answersJSON
                    ]
                )

                // Reader 历史：event + receipt + coverage。
                try db.execute(
                    sql: """
                        INSERT INTO reader_activity_events(
                            id, operation_id, kind, lexeme_id, note_id,
                            document_id, snapshot_json, created_at_ms,
                            undone_at_ms
                        ) VALUES (?, ?, 'minedNewNote', ?, ?, ?,
                                  '{"surface":"見る"}', 6, NULL)
                        """,
                    arguments: [
                        encode(eventID), encode(UUID()),
                        encode(lexemeAID), encode(vocabNoteID),
                        encode(documentID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_mining_receipts(
                            operation_id, kind, payload_hash, result_json,
                            committed_at_ms
                        ) VALUES (?, 'mine_vocabulary', ?, '{}', 7)
                        """,
                    arguments: [
                        encode(UUID()), String(repeating: "5", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO study_days(
                            id, local_date, time_zone_id, starts_at_ms,
                            ends_at_ms, new_limit
                        ) VALUES (?, '2026-09-12', 'Asia/Shanghai', 0, 1, 10)
                        """,
                    arguments: [encode(studyDayID)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO reader_coverage_snapshots(
                            id, document_id, document_title, scope_key,
                            chapter_id, content_hash, metric_version,
                            morphology_version, dictionary_version,
                            known_count, learning_count, unknown_count,
                            ignored_count, unique_numerator,
                            unique_denominator, analyzed_blocks,
                            total_blocks, study_day_id, created_at_ms
                        ) VALUES (?, ?, '源文档', 'doc', ?, ?, 'm1', 'mo1',
                                  'd1', 42, 3, 10, 1, 40, 50, 10, 12, ?, 8)
                        """,
                    arguments: [
                        encode(coverageID), encode(documentID),
                        encode(chapterID), String(repeating: "6", count: 64),
                        encode(studyDayID)
                    ]
                )

                // Import 历史：completed job + receipt、running job。
                try db.execute(
                    sql: """
                        INSERT INTO import_jobs(
                            id, file_hash, mapping_hash, policy,
                            target_deck_id, status, staging_file_name,
                            staging_fingerprint, row_count, committed_rows,
                            mapping_summary, failure_reason,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, 'skip', ?, 'completed',
                                  'import-staging-a.sqlite', ?, 10, 9,
                                  'headword→headword', NULL, 1, 2)
                        """,
                    arguments: [
                        encode(completedJobID),
                        String(repeating: "7", count: 64),
                        String(repeating: "8", count: 64),
                        encode(deckID),
                        String(repeating: "9", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO import_jobs(
                            id, file_hash, mapping_hash, policy,
                            target_deck_id, status, staging_file_name,
                            staging_fingerprint, row_count, committed_rows,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, 'update', ?, 'running',
                                  'import-staging-b.sqlite', ?, 5, 2, 3, 4)
                        """,
                    arguments: [
                        encode(runningJobID),
                        String(repeating: "a", count: 64),
                        String(repeating: "b", count: 64),
                        encode(deckID),
                        String(repeating: "c", count: 64)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO import_row_receipts(
                            job_id, logical_row, payload_digest, action,
                            target_note_id, detail, created_at_ms
                        ) VALUES (?, 3, ?, 'created', ?, NULL, 5)
                        """,
                    arguments: [
                        encode(completedJobID),
                        String(repeating: "d", count: 64),
                        encode(vocabNoteID)
                    ]
                )

                // 活用：finished + active session，attempt 挂 finished。
                try db.execute(
                    sql: """
                        INSERT INTO conjugation_sessions(
                            id, planned_question_count, status,
                            started_at_ms, finished_at_ms
                        ) VALUES (?, 3, 'finished', 1, 2),
                                 (?, 5, 'active', 3, NULL)
                        """,
                    arguments: [
                        encode(finishedSessionID), encode(activeSessionID)
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO conjugation_practice_attempts(
                            id, event_id, session_id, question_id, lemma,
                            reading, conjugation_class, form, rule_id,
                            prompt, expected_primary, accepted_json,
                            user_input, normalized_input, result,
                            matched_answer, duration_ms, answered_at_ms,
                            undone_at_ms
                        ) VALUES (?, ?, ?, ?, '見る', 'みる',
                                  'godan', 'past', 'r-godan-past',
                                  '見る（过去）', '見た', '["見た","みた"]',
                                  '見た', '見た', 'correct', '見た',
                                  1200, 9, NULL)
                        """,
                    arguments: [
                        encode(attemptID), encode(UUID()),
                        encode(finishedSessionID), encode(UUID())
                    ]
                )
            }
        }
    }
}
