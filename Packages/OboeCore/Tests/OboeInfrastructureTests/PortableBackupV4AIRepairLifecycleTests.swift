import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T10: full repair lifecycle across an export → replace-restore — real
/// service-driven commits (in-place repair, split with pause, split with
/// delete), an unfinished suggested draft, an in-flight `.analyzing` draft,
/// a committed receipt whose created note was deleted afterwards, and a
/// non-repair draft all survive intact. After restore the launch sweep must
/// recover drafts without firing a single request or adopting anything.
final class PortableBackupV4AIRepairLifecycleTests: XCTestCase {

    private var fixture: AdaptiveDatabaseFixture!
    private var work: WorkDirectory!

    override func setUp() async throws {
        fixture = try await AdaptiveDatabaseFixture.make()
        work = try WorkDirectory()
    }

    override func tearDown() async throws {
        fixture.remove()
        work.remove()
        fixture = nil
        work = nil
    }

    /// 生成→预览→采用→导出→替换恢复→复查 — every artifact type produced by
    /// the real pipeline must be present and consistent after restore.
    func testRepairLifecycleArtifactsSurviveBackupRestore() async throws {
        let fixture = try XCTUnwrap(fixture)
        let work = try XCTUnwrap(work)
        let timeZone = AdaptiveDatabaseFixture.timeZoneID

        let client = StubRepairClient()
        let drafts = GRDBAIRepairDraftRepository(database: fixture.database)
        let service = Self.makeService(database: fixture.database, client: client)

        // 1) In-place adopt on the lapsed card — its six logs must survive.
        let lapsedCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        let (inPlaceDraftID, _) = try await service.prepareDraft(
            cardID: lapsedCard,
            userComment: "例句偏长"
        )
        _ = try await service.analyze(
            draftID: inPlaceDraftID,
            defaultTimeZoneID: timeZone
        )
        try await service.markPreviewing(draftID: inPlaceDraftID)
        _ = try await service.commitInPlaceRepair(
            draftID: inPlaceDraftID,
            suggestionIndex: 0
        )

        // 2) Split adopt on the fresh card — pause the original direction.
        let freshCard = fixture.freshNote.cardID(.vocabularyJapaneseToChinese)
        let freshSibling = fixture.freshNote.cardID(.vocabularyChineseToJapanese)
        let (splitDraftID, _) = try await service.prepareDraft(cardID: freshCard)
        _ = try await service.analyze(
            draftID: splitDraftID,
            defaultTimeZoneID: timeZone
        )
        let splitReceipt = try await service.commitSplitRepair(
            draftID: splitDraftID,
            suggestionIndex: 1,
            deckID: fixture.deckAID,
            directions: [
                [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese],
                [.vocabularyJapaneseToChinese]
            ],
            originalCardDisposition: .pause
        )

        // 3) Split adopt on the undone note's only direction — delete it,
        //    keeping the note and its orphaned logs.
        let undoneCard = fixture.undoneNote.cardID(.vocabularyJapaneseToChinese)
        let (deleteDraftID, _) = try await service.prepareDraft(cardID: undoneCard)
        _ = try await service.analyze(
            draftID: deleteDraftID,
            defaultTimeZoneID: timeZone
        )
        let deleteReceipt = try await service.commitSplitRepair(
            draftID: deleteDraftID,
            suggestionIndex: 1,
            deckID: fixture.deckBID,
            directions: [
                [.vocabularyJapaneseToChinese],
                [.vocabularyChineseToJapanese]
            ],
            originalCardDisposition: .delete
        )

        // 4) An unfinished draft left at `.suggested`.
        let otherCard = fixture.otherDeckNote.cardID(.vocabularyJapaneseToChinese)
        let (liveDraftID, _) = try await service.prepareDraft(
            cardID: otherCard,
            userComment: "分不清两个读音"
        )
        _ = try await service.analyze(
            draftID: liveDraftID,
            defaultTimeZoneID: timeZone
        )

        // 5) An in-flight draft persisted mid-request (.analyzing) — restart
        //    recovery is the launch sweep's job, exercised after restore.
        let lapsedSibling = fixture.lapsedNote.cardID(.vocabularyChineseToJapanese)
        let (analyzingDraftID, _) = try await service.prepareDraft(cardID: lapsedSibling)
        let loadedDraft = try await service.loadDraft(id: analyzingDraftID)
        var analyzing = try XCTUnwrap(loadedDraft)
        analyzing.phase = .analyzing
        try await drafts.saveDraft(
            id: analyzingDraftID,
            envelope: analyzing,
            provenance: Self.provenance,
            updatedAt: Date()
        )

        // 6) A committed receipt that now references deleted objects: drop
        //    the split commit's first created note (its cards cascade).
        let deletedNoteID = try XCTUnwrap(splitReceipt.createdNoteIDs.first)
        let deletedCardIDs = Set(splitReceipt.createdCardIDs)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deletedNoteID)]
            )
        }

        // 7) A non-repair draft — other draft kinds must pass through
        //    untouched (Capture/Draft pipeline unaffected).
        let vocabularyDraftID = UUID()
        let vocabularyDraftPayload = #"{"headword":"食べる"}"#
        let inboxItemID = UUID()
        let inboxContextID = UUID()
        let captureID = UUID()
        let inboxOperationID = UUID()
        let baseMilliseconds = try DatabaseValueCodec.encode(AdaptiveDatabaseFixture.baseDate)
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO drafts(
                        id, draft_kind, payload_version, payload_json,
                        provider_id, model_id, prompt_version, updated_at_ms
                    ) VALUES (?, 'vocabulary', 1, ?, NULL, NULL, NULL, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(vocabularyDraftID),
                    vocabularyDraftPayload
                ]
            )
            // Capture 链路：收件箱条目 + 处理上下文 + 导入/提交回执。
            try db.execute(
                sql: """
                    INSERT INTO inbox_items(
                        id, text, source_type, status, content_revision,
                        created_at_ms, updated_at_ms, processed_at_ms
                    ) VALUES (?, '食べる', 'manual', 'processed', 1, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(inboxItemID),
                    baseMilliseconds, baseMilliseconds, baseMilliseconds
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_processing_contexts(
                        id, inbox_item_id, content_revision, input_text, mode,
                        draft_id, payload_version, updated_at_ms
                    ) VALUES (?, ?, 1, '食べる', 'vocabulary_generation', ?, 1, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(inboxContextID),
                    DatabaseValueCodec.encode(inboxItemID),
                    DatabaseValueCodec.encode(vocabularyDraftID),
                    baseMilliseconds
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO capture_import_receipts(
                        capture_id, payload_hash, inbox_item_id, imported_at_ms
                    ) VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(captureID),
                    String(repeating: "ab", count: 32),
                    DatabaseValueCodec.encode(inboxItemID),
                    baseMilliseconds
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO inbox_commit_receipts(
                        operation_id, processing_context_id, payload_hash,
                        result_json, committed_at_ms
                    ) VALUES (?, ?, ?, '{}', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(inboxOperationID),
                    DatabaseValueCodec.encode(inboxContextID),
                    String(repeating: "cd", count: 32),
                    baseMilliseconds
                ]
            )
        }

        // Export → prepare (replace-restore path).
        let backup = try await PortableBackupExporter(
            database: fixture.database,
            workingDirectoryURL: work.exportsURL
        ).export(appVersion: "test", at: Date())
        let current = try OboeDatabase(path: work.currentDatabaseURL.path)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: work.preparationsURL
        )
        let prepared = try await preparer.prepare(fileURL: backup.url)

        XCTAssertEqual(prepared.sourceFormatVersion, PortableBackupFormat.currentVersion)
        XCTAssertEqual(prepared.backup.draftCount, 6)
        XCTAssertTrue(prepared.restoresInboxData, "Capture 收件箱数据必须保留")

        let restored = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)

        // --- 原位修改：内容与版本持久，原历史保留 -------------------------
        let repaired = try await noteRow(restored, noteID: fixture.lapsedNote.noteID)
        XCTAssertEqual(repaired["notes"], "注意与「戻す」区分：戻る为自动词。")
        XCTAssertEqual(repaired["content_version"], "2")
        let lapsedLogCount = try await reviewLogCount(restored, cardID: lapsedCard)
        XCTAssertEqual(lapsedLogCount, 5, "原位修卡后原卡历史必须完整保留")

        // --- 拆卡：新笔记/新卡存在，新卡无旧历史与每日任务 -----------------
        for noteID in splitReceipt.createdNoteIDs + deleteReceipt.createdNoteIDs {
            let row = try await noteRow(restored, noteID: noteID)
            if noteID == deletedNoteID {
                XCTAssertNil(row["id"], "提交后删除的笔记保持删除状态")
            } else {
                XCTAssertEqual(row["origin"], "ai")
            }
        }
        for cardID in splitReceipt.createdCardIDs + deleteReceipt.createdCardIDs {
            if deletedCardIDs.contains(cardID) {
                continue // belongs to the deleted note — cascade removed it
            }
            let card = try await cardRow(restored, cardID: cardID)
            XCTAssertEqual(card["state"], "0", "新卡必须保持 New 状态")
            XCTAssertEqual(card["reps"], "0")
            let newLogCount = try await reviewLogCount(restored, cardID: cardID)
            XCTAssertEqual(newLogCount, 0, "新卡不得携带任何复习历史")
            let newTaskCount = try await dailyTaskCount(restored, cardID: cardID)
            XCTAssertEqual(newTaskCount, 0, "新卡不得复制每日任务")
        }

        // --- 原卡处置：暂停仅写 is_enabled；删除仅删目标卡 ---------------
        let pausedCard = try await cardRow(restored, cardID: freshCard)
        XCTAssertEqual(pausedCard["is_enabled"], "0", "原卡处置 pause 必须保留")
        let siblingCard = try await cardRow(restored, cardID: freshSibling)
        XCTAssertEqual(siblingCard["is_enabled"], "1", "兄弟方向不受影响")

        let deletedOriginal = try await cardRow(restored, cardID: undoneCard)
        XCTAssertNil(deletedOriginal["id"], "处置 delete 的原卡必须已删除")
        let undoneNote = try await noteRow(restored, noteID: fixture.undoneNote.noteID)
        XCTAssertNotNil(undoneNote["id"], "删除最后一张卡后 Note 必须保留")
        let orphanedLogs = try await restored.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM review_logs
                    WHERE note_id = ? AND card_id IS NULL
                    """,
                arguments: [DatabaseValueCodec.encode(fixture.undoneNote.noteID)]
            )
        } ?? 0
        XCTAssertGreaterThan(orphanedLogs, 0, "删除卡的孤儿历史必须保留")

        // --- 草稿与回执 ---------------------------------------------------
        let restoredDrafts = GRDBAIRepairDraftRepository(database: restored)

        let inPlace = try await restoredDrafts.fetchDraft(id: inPlaceDraftID)
        XCTAssertEqual(inPlace?.phase, .committed)
        XCTAssertEqual(inPlace?.commitReceipt?.originalCardDisposition, .keep)

        let split = try await restoredDrafts.fetchDraft(id: splitDraftID)
        XCTAssertEqual(split?.commitReceipt?.createdNoteIDs, splitReceipt.createdNoteIDs)
        XCTAssertEqual(
            split?.commitReceipt?.originalCardDisposition, .pause
        )

        // 回执引用已删对象（原卡已删/新建笔记已删）仍可恢复、可解码。
        let deleted = try await restoredDrafts.fetchDraft(id: deleteDraftID)
        XCTAssertEqual(deleted?.phase, .committed)
        XCTAssertEqual(
            deleted?.commitReceipt?.createdNoteIDs, deleteReceipt.createdNoteIDs,
            "引用已删对象的回执必须原样恢复"
        )

        let live = try await restoredDrafts.fetchDraft(id: liveDraftID)
        XCTAssertEqual(live?.phase, .suggested)
        XCTAssertFalse(live?.adoptionBlocked ?? true)
        XCTAssertEqual(live?.userComment, "分不清两个读音")

        let inFlight = try await restoredDrafts.fetchDraft(id: analyzingDraftID)
        XCTAssertEqual(inFlight?.phase, .analyzing, "在途草稿按原样落库")

        // 非修卡草稿原样通过。
        let otherDraftPayload = try await restored.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT payload_json FROM drafts WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(vocabularyDraftID)]
            )
        }
        XCTAssertEqual(
            otherDraftPayload, vocabularyDraftPayload,
            "既有 Draft 记录必须逐字节保留"
        )

        // Capture 事务不受影响：条目、上下文、导入/提交回执全部在。
        let inboxCounts = try await restored.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items") ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM inbox_processing_contexts"
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM capture_import_receipts"
                ) ?? -1,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM inbox_commit_receipts"
                ) ?? -1
            )
        }
        XCTAssertEqual(inboxCounts.0, 1)
        XCTAssertEqual(inboxCounts.1, 1)
        XCTAssertEqual(inboxCounts.2, 1)
        XCTAssertEqual(inboxCounts.3, 1)

        // --- 恢复后不自动请求/采用：启动清扫只改草稿相位 -----------------
        let callsBefore = await client.callCount
        let restoredService = Self.makeService(database: restored, client: client)
        try await restoredService.restoreDraftsForLaunch()

        let swept = try await restoredDrafts.fetchDraft(id: analyzingDraftID)
        XCTAssertEqual(swept?.phase, .editing, "在途草稿恢复后回到可重试态")
        let stillCommitted = try await restoredDrafts.fetchDraft(id: splitDraftID)
        XCTAssertEqual(stillCommitted?.phase, .committed)
        let callsAfterSweep = await client.callCount
        XCTAssertEqual(
            callsAfterSweep, callsBefore,
            "恢复过程不得发起任何 AI 请求"
        )
        let untouchedNote = try await noteRow(restored, noteID: fixture.otherDeckNote.noteID)
        XCTAssertEqual(
            untouchedNote["content_version"], "1",
            "恢复过程不得采用任何建议"
        )

        // --- 重复确认幂等：恢复后的回执回放返回既有回执，零新对象 ---------
        let objectCountsBefore = try await objectCounts(restored)
        let replayedSplit = try await restoredService.commitSplitRepair(
            draftID: splitDraftID,
            suggestionIndex: 1,
            deckID: fixture.deckAID,
            directions: [
                [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese],
                [.vocabularyJapaneseToChinese]
            ],
            originalCardDisposition: .pause
        )
        XCTAssertEqual(replayedSplit.operationID, splitReceipt.operationID)
        XCTAssertEqual(replayedSplit.payloadHash, splitReceipt.payloadHash)
        XCTAssertEqual(replayedSplit.createdNoteIDs, splitReceipt.createdNoteIDs)
        let replayedInPlace = try await restoredService.commitInPlaceRepair(
            draftID: inPlaceDraftID,
            suggestionIndex: 0
        )
        XCTAssertEqual(replayedInPlace.originalCardDisposition, .keep)
        let objectCountsAfter = try await objectCounts(restored)
        XCTAssertEqual(
            objectCountsAfter.notes, objectCountsBefore.notes,
            "回执回放不得产生任何新 Note"
        )
        XCTAssertEqual(
            objectCountsAfter.cards, objectCountsBefore.cards,
            "回执回放不得产生任何新 Card"
        )

        try restored.close()
        try current.close()
        try await preparer.discard(prepared)
    }

    /// T10 真实 API 质量验收（可选门控）：用合成内容小批调用真实服务，
    /// 严格走 `AIRepairOutputDecoder` —— 不放宽 JSON 验证。记录模型、
    /// promptVersion 与失败样例到测试日志。
    /// 运行方式：OBOE_AI_QUALITY_BASE_URL / OBOE_AI_QUALITY_API_KEY /
    /// OBOE_AI_QUALITY_MODEL 三个环境变量齐备时执行。
    func testRealAIQualityAcceptance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURLString = environment["OBOE_AI_QUALITY_BASE_URL"],
              let baseURL = URL(string: baseURLString),
              let apiKey = environment["OBOE_AI_QUALITY_API_KEY"], !apiKey.isEmpty,
              let model = environment["OBOE_AI_QUALITY_MODEL"], !model.isEmpty
        else {
            throw XCTSkip(
                "Set OBOE_AI_QUALITY_BASE_URL/API_KEY/MODEL for the real-API acceptance run."
            )
        }

        let configuration = AIConfiguration(
            isEnabled: true,
            serviceKind: .custom,
            serviceName: "quality-acceptance",
            baseURL: baseURL,
            modelID: model,
            responseFormatMode: .jsonObject,
            credentialReference: AICredentialReference(
                id: UUID(), serviceKind: .custom, host: baseURL.host ?? "unknown"
            )
        )
        let client = ChatCompletionsAIRepairClient()

        // 合成内容——绝不使用用户真实数据。
        let contexts: [AIRepairRequestContext] = [
            AIRepairRequestContext(
                note: AIRepairNoteSnapshot(
                    kind: .vocabulary,
                    headword: "受ける",
                    reading: "うける",
                    meaningZH: "接受；遭受；受到",
                    partOfSpeech: "动词",
                    jlpt: .n3,
                    examples: [AIRepairExampleCandidate(
                        japanese: "影響を受ける", translationZH: "受到影响"
                    )]
                ),
                direction: .vocabularyJapaneseToChinese,
                reviewSummary: AIRepairReviewSummary(
                    recentCount: 6, recentAgainCount: 6,
                    dueAgainStreak: 3, lifetimeLapses: 6
                ),
                userComment: "总是和其他词混淆"
            ),
            AIRepairRequestContext(
                note: AIRepairNoteSnapshot(
                    kind: .vocabulary,
                    headword: "明らか",
                    reading: "あきらか",
                    meaningZH: "明显；明确；清楚",
                    partOfSpeech: "形容动词",
                    jlpt: .n2
                ),
                direction: .vocabularyChineseToJapanese,
                reviewSummary: AIRepairReviewSummary(
                    recentCount: 4, recentAgainCount: 3,
                    dueAgainStreak: 2, lifetimeLapses: 5
                )
            ),
            AIRepairRequestContext(
                note: AIRepairNoteSnapshot(
                    kind: .grammar,
                    headword: "〜ざるを得ない",
                    meaningZH: "不得不～",
                    jlpt: .n2,
                    usage: "表示别无选择",
                    connection: "动词ない形＋ざるを得ない"
                ),
                direction: .grammarFormToExplanation,
                reviewSummary: AIRepairReviewSummary(
                    recentCount: 5, recentAgainCount: 4,
                    dueAgainStreak: 2, lifetimeLapses: 4
                )
            )
        ]

        var failures: [String] = []
        for (index, context) in contexts.enumerated() {
            do {
                let raw = try await client.analyze(
                    context: context,
                    configuration: configuration,
                    credential: apiKey
                )
                do {
                    let response = try AIRepairOutputDecoder.decode(raw)
                    XCTAssertFalse(response.suggestions.isEmpty)
                } catch {
                    failures.append("context \(index): decode failed — \(error)")
                }
            } catch {
                failures.append("context \(index): request failed — \(error)")
            }
        }

        print("""
        AI_QUALITY model=\(model) \
        promptVersion=\(AIRepairPromptV2.promptVersion) \
        contexts=\(contexts.count) \
        succeeded=\(contexts.count - failures.count) \
        failures=\(failures.joined(separator: " | "))
        """)
        XCTAssertEqual(
            failures.count, 0,
            "真实 API 验收失败样例：\(failures.joined(separator: " | "))"
        )
    }

    // MARK: - Environment

    private static var provenance: AIRepairDraftProvenance {
        AIRepairDraftProvenance(
            providerID: "custom",
            modelID: "fixture-model",
            promptVersion: AIRepairPromptV2.promptVersion
        )
    }

    private static func makeService(
        database: OboeDatabase,
        client: StubRepairClient
    ) -> AIRepairService {
        AIRepairService(
            draftStore: GRDBAIRepairDraftRepository(database: database),
            commitStore: GRDBAIRepairCommitRepository(database: database),
            configurationRepository: StubAIConfigurationRepository(),
            credentialStore: StubCredentialStore(),
            client: client,
            vocabularyRepository: GRDBVocabularyRepository(database: database),
            grammarRepository: GRDBGrammarRepository(database: database),
            contentCardRepository: GRDBContentCardRepository(database: database),
            adaptiveCardService: AdaptiveCardService(
                repository: GRDBAdaptiveRepository(database: database)
            )
        )
    }

    // MARK: - Row probes

    /// `[String: String]` with NULL columns omitted — a missing `["id"]`
    /// means the row is absent or the column is NULL, which is what the
    /// assertions need to distinguish.
    private func noteRow(
        _ database: OboeDatabase,
        noteID: UUID
    ) async throws -> [String: String] {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, kind, headword, notes, origin, content_version
                    FROM notes WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            ) else { return [:] }
            var values: [String: String] = [:]
            for column in ["id", "kind", "headword", "notes", "origin"] {
                values[column] = row[column] as? String
            }
            values["content_version"] = (row["content_version"] as? Int64)
                .map(String.init)
            return values
        }
    }

    private func cardRow(
        _ database: OboeDatabase,
        cardID: UUID
    ) async throws -> [String: String] {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, is_enabled, state, reps, lapses
                    FROM cards WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) else { return [:] }
            var values: [String: String] = [:]
            values["id"] = row["id"] as? String
            for column in ["is_enabled", "state", "reps", "lapses"] {
                values[column] = (row[column] as? Int64).map(String.init)
            }
            return values
        }
    }

    private func reviewLogCount(
        _ database: OboeDatabase,
        cardID: UUID
    ) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? 0
        }
    }

    private func dailyTaskCount(
        _ database: OboeDatabase,
        cardID: UUID
    ) async throws -> Int {
        try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM daily_tasks WHERE card_id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) ?? 0
        }
    }

    private func objectCounts(
        _ database: OboeDatabase
    ) async throws -> (notes: Int, cards: Int) {
        try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1
            )
        }
    }
}

private extension PortableBackupV4AIRepairLifecycleTests {
    struct WorkDirectory {
        let rootURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "PortableBackupV4AIRepairLifecycle-\(UUID().uuidString)",
                    isDirectory: true
                )
            currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            preparationsURL = rootURL.appendingPathComponent("preparations", isDirectory: true)
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}

/// Deterministic repair response shared by every draft in the lifecycle —
/// index 0 is an in-place suggestion, index 1 a two-candidate split.
private actor StubRepairClient: AIRepairClient {
    private(set) var callCount = 0

    func analyze(
        context: AIRepairRequestContext,
        configuration: AIConfiguration,
        credential: String
    ) async throws -> String {
        callCount += 1
        return Self.responseJSON
    }

    private static let responseJSON = #"""
    {
        "schemaVersion": 2,
        "problemTypes": ["example_too_complex", "similar_words_confusion"],
        "summary": "例句偏长，且与近形词混淆。",
        "suggestions": [
            {
                "type": "add_disambiguation",
                "title": "补充辨析说明",
                "reason": "与近形词区分度不足",
                "replacement": {"notes": "注意与「戻す」区分：戻る为自动词。"}
            },
            {
                "type": "split_card",
                "title": "拆为两张卡",
                "reason": "义项跨语境，合并回忆目标过宽",
                "splitNotes": [
                    {
                        "kind": "vocabulary",
                        "headword": "戻る",
                        "reading": "もどる",
                        "meaningZH": "返回（场所）",
                        "partsOfSpeech": ["五段动词", "自动词"],
                        "pitchAccent": 0,
                        "jlpt": null,
                        "usage": null,
                        "connection": null,
                        "notes": null,
                        "examples": [
                            {"japanese": "家に戻る", "translationZH": "回家"}
                        ]
                    },
                    {
                        "kind": "vocabulary",
                        "headword": "戻る",
                        "reading": "もどる",
                        "meaningZH": "恢复（状态）",
                        "partsOfSpeech": ["五段动词", "自动词"],
                        "pitchAccent": 0,
                        "jlpt": null,
                        "usage": null,
                        "connection": null,
                        "notes": null,
                        "examples": [
                            {"japanese": "元に戻る", "translationZH": "恢复原状"}
                        ]
                    }
                ]
            }
        ]
    }
    """#
}

private final class StubAIConfigurationRepository: AIConfigurationRepository,
    @unchecked Sendable {
    var configuration = AIConfiguration(
        isEnabled: true,
        serviceKind: .custom,
        serviceName: "Fixture",
        baseURL: URL(string: "https://fixture.example/v1")!,
        modelID: "fixture-model",
        responseFormatMode: .jsonObject,
        credentialReference: AICredentialReference(
            id: UUID(),
            serviceKind: .custom,
            host: "fixture.example"
        )
    )

    func loadOrCreateAIConfiguration(
        defaultTimeZoneID: String
    ) async throws -> AIConfiguration {
        configuration
    }

    func saveAIConfiguration(_ configuration: AIConfiguration) async throws {
        self.configuration = configuration
    }
}

private actor StubCredentialStore: AICredentialStore {
    private var credential: String? = "fixture-key"

    func readCredential(
        for reference: AICredentialReference
    ) async throws -> String? {
        credential
    }

    func saveCredential(
        _ credential: String,
        for reference: AICredentialReference
    ) async throws {
        self.credential = credential
    }

    func deleteCredential(
        for reference: AICredentialReference
    ) async throws {
        credential = nil
    }
}
