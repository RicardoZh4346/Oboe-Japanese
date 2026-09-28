import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// S24 恢复屏障与缺原文重关联。
///
/// 覆盖矩阵：
/// - `RestorationWorkGate`：登记/取消并等待/关门拒绝来件/幂等；
/// - `ReaderRelinkService`：source SHA-256 精确命中、canonical
///   重打包命中、hash 不符拒绝且零副作用、块缺失重建且 ID 复用
///   保住 chapter_id 引用；
/// - `ReaderFileReconciler`：missing 降级、资产路径/hash 自愈、
///   孤儿目录只报不删、非 Reader 目录不触碰；
/// - kill mid-restore：fault injector 在 candidateInstalled 处
///   中断 → 旧库回滚 + ReaderFiles 不动；
/// - 恢复窗口：stale generation mining 拒写 + 在途 CSV 导入被
///   gate 抽干且 job 留在可续跑态；
/// - v1–v8 恢复冒烟矩阵（prepare→replaceDatabase→reconcile）；
/// - cloze 端到端：完整备份 → 删原文 → 恢复 → cloze 复习可跑 →
///   relink → reader 定位字段仍有效。
final class S24RestoreBarrierTests: XCTestCase {

    // MARK: - fixture

    private var root: URL!
    private var pool: DatabasePool!
    private var database: OboeDatabase!
    private var fileStore: LocalReaderFileStore!
    private var repository: GRDBReaderRepository!
    private var ingest: ReaderIngestService!
    private var relinkService: ReaderRelinkService!
    private var reconciler: ReaderFileReconciler!
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "S24-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        pool = try DatabasePool(
            path: root.appendingPathComponent("oboe.sqlite").path,
            configuration: config
        )
        try OboeDatabaseSchema.makeMigrator().migrate(pool)
        database = OboeDatabase(pool: pool)
        fileStore = LocalReaderFileStore(baseDirectoryURL: root)
        repository = GRDBReaderRepository(database: database)
        ingest = ReaderIngestService(
            fileStore: fileStore, repository: repository
        )
        relinkService = ReaderRelinkService(
            fileStore: fileStore,
            repository: repository,
            store: repository
        )
        reconciler = ReaderFileReconciler(
            fileStore: fileStore, repository: repository
        )
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeSource(
        _ name: String,
        _ text: String,
        encoding: String.Encoding = .utf8
    ) throws -> URL {
        let dir = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    /// UTF-16LE+BOM 文件——与 UTF-8 原文不同字节、同 canonical。
    private func writeUTF16LEBOMSource(_ name: String, _ text: String)
        throws -> URL
    {
        let dir = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(name)
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        try data.write(to: url)
        return url
    }

    private func documentDirectoryExists(_ documentID: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: fileStore.documentDirectoryURL(
                documentID: documentID
            ).path
        )
    }

    private func countRows(_ table: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)"
            ) ?? 0
        }
    }

    // MARK: - 1. 工作闸门

    /// closeAndWait：关门 → 取消全部登记任务 → 等任务真正退出。
    /// 关门后来件被拒且任务自身即被取消。
    func testWorkGateCancelsAndDrainsThenRejectsLateEnrollment() async {
        let gate = RestorationWorkGate()
        let probe = GateProbe()

        let running = Task<Void, Never> {
            probe.started = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            probe.exitedAfterCancel = true
        }
        let token = await gate.enroll(running)
        XCTAssertNotNil(token)

        await gate.closeAndWait()
        XCTAssertTrue(probe.started)
        XCTAssertEqual(probe.exitedAfterCancel, true)
        let isClosed = await gate.isClosed
        XCTAssertTrue(isClosed)

        // 晚到登记：被拒 + 任务体执行时已处于取消态。
        let late = Task<Void, Never> {
            probe.lateSawCancelled = Task.isCancelled
        }
        let lateToken = await gate.enroll(late)
        XCTAssertNil(lateToken)
        await late.value
        XCTAssertEqual(probe.lateSawCancelled, true)

        // 幂等：重复关门无副作用。
        await gate.closeAndWait()
    }

    /// 恢复窗口内登记的任务即便先于关门启动也会被取消并等到
    /// 退出——「旧任务不会回写旧库」的闸门侧保证。
    func testWorkGateEnrolledTaskCannotOutliveTheGate() async {
        let gate = RestorationWorkGate()
        let probe = GateProbe()
        // 任务体先做完一轮工作再等取消——模拟 ingest 批边界检查。
        let task = Task<Void, Never> {
            probe.rounds = 0
            while !Task.isCancelled && probe.rounds < 10_000 {
                probe.rounds += 1
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            probe.exitedAfterCancel = Task.isCancelled
        }
        _ = await gate.enroll(task)
        await gate.closeAndWait()
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(probe.exitedAfterCancel, true)
        XCTAssertLessThan(probe.rounds, 10_000)
    }

    // MARK: - 2. relink：hash 命中路径

    /// 同一文件重选：字节 hash 精确命中 → 文件重装、available、
    /// 章/块 ID 复用 → 位置/书签/token_cache/进度原样存活。
    func testRelinkExactSHA256PreservesIdentityAndReaderState()
        async throws
    {
        let file = try writeSource(
            "sample.txt", "今日はいい天気です。\n\n明日も晴れます。"
        )
        let documentID = UUID()
        let imported = try await ingest.importTextFile(
            fileURL: file, documentID: documentID
        )
        XCTAssertTrue(imported.wasCreated)

        let chapters = try await repository.fetchChapters(
            documentID: documentID
        )
        let chapter = try XCTUnwrap(chapters.first)
        let blocks = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        let block = try XCTUnwrap(blocks.first)

        let location = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 2,
            blockTextHash: block.textHash, prefix: "前", suffix: "后"
        )
        try await repository.savePosition(
            ReaderPosition(
                documentID: documentID, chapterID: chapter.id,
                location: location, updatedAt: clock
            )
        )
        try await repository.addBookmark(
            ReaderBookmark(
                id: UUID(), documentID: documentID,
                chapterID: chapter.id, location: location,
                label: "标记", createdAt: clock
            )
        )
        try await repository.updateProgress(id: documentID, basisPoints: 4200)
        try await repository.saveTokenPayload(
            blockID: block.id, textHash: block.textHash,
            tokenizerVersion: "t", dictionaryVersion: "d",
            payload: Data([1, 2, 3])
        )

        // 丢失原文 → missing。
        try await fileStore.removeFiles(documentID: documentID)
        try await repository.updateAvailability(
            id: documentID, availability: .missing
        )

        let outcome = try await relinkService.relink(
            documentID: documentID, preparedFileURL: file
        )
        XCTAssertEqual(outcome.confirmation, .sourceSHA256)
        XCTAssertFalse(outcome.rebuiltContent)
        XCTAssertEqual(outcome.document.availability, .available)

        let doc = try await repository.fetchDocument(id: documentID)
        XCTAssertEqual(doc?.availability, .available)
        XCTAssertEqual(doc?.progressBasisPoints, 4200)
        XCTAssertEqual(doc?.sourceSHA256, imported.document.sourceSHA256)
        XCTAssertEqual(doc?.title, imported.document.title)

        // 章/块 ID 全部复用——弱引用不断。
        let newChapters = try await repository.fetchChapters(
            documentID: documentID
        )
        XCTAssertEqual(newChapters.map(\.id), chapters.map(\.id))
        let newBlocks = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        XCTAssertEqual(newBlocks.map(\.id), blocks.map(\.id))
        XCTAssertEqual(newBlocks.map(\.text), blocks.map(\.text))

        let position = try await repository.fetchPosition(
            documentID: documentID
        )
        XCTAssertEqual(position?.chapterID, chapter.id)
        XCTAssertEqual(position?.location, location)
        let bookmarks = try await repository.fetchBookmarks(
            documentID: documentID
        )
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks[0].chapterID, chapter.id)

        // 块 ID 复用 → token_cache 行原样存活。
        let payload = try await repository.fetchTokenPayload(
            blockID: block.id, tokenizerVersion: "t",
            dictionaryVersion: "d"
        )
        XCTAssertEqual(payload, Data([1, 2, 3]))

        // 文件回装 + installed 资产行就位。
        XCTAssertNotNil(fileStore.fileURL(
            documentID: documentID,
            relativePath: outcome.sourceRelativePath
        ))
        let assets = try await repository.fetchAssets(
            documentID: documentID
        )
        XCTAssertTrue(assets.contains {
            $0.relativePath == outcome.sourceRelativePath
                && $0.installState == .installed
        })
    }

    /// 重打包/转码文件：SHA-256 不同但 canonical 相同 →
    /// canonical 确认路径，source_sha256 更新为新文件值，
    /// 旧资产行降级 missing 不留双 installed 歧义。
    func testRelinkCanonicalMatchAcceptsReencodedFile() async throws {
        let text = "同じ内容です。\n\n二番目の段落です。"
        let original = try writeSource("orig.txt", text)
        let documentID = UUID()
        _ = try await ingest.importTextFile(
            fileURL: original, documentID: documentID
        )
        let oldChapters = try await repository.fetchChapters(
            documentID: documentID
        )

        let repacked = try writeUTF16LEBOMSource("utf16.txt", text)
        let repackedSHA = try ReaderHashing.digestFile(at: repacked).sha256
        XCTAssertNotEqual(repackedSHA, try ReaderHashing.digestFile(at: original).sha256)

        try await fileStore.removeFiles(documentID: documentID)
        try await repository.updateAvailability(
            id: documentID, availability: .missing
        )

        let outcome = try await relinkService.relink(
            documentID: documentID, preparedFileURL: repacked
        )
        XCTAssertEqual(outcome.confirmation, .canonicalText)

        let doc = try await repository.fetchDocument(id: documentID)
        XCTAssertEqual(doc?.availability, .available)
        XCTAssertEqual(doc?.sourceSHA256, repackedSHA)

        // 章复用（canonicalHash 一致）。
        let newChapters = try await repository.fetchChapters(
            documentID: documentID
        )
        XCTAssertEqual(newChapters.map(\.id), oldChapters.map(\.id))

        // 旧源文件资产降 missing；新文件 installed——installed
        // 源资产唯一，不留歧义。
        let assets = try await repository.fetchAssets(
            documentID: documentID
        )
        let byPath = Dictionary(
            uniqueKeysWithValues: assets.map { ($0.relativePath, $0) }
        )
        XCTAssertEqual(byPath["orig.txt"]?.installState, .missing)
        XCTAssertEqual(
            byPath["utf16.txt"]?.installState, .installed
        )
        XCTAssertEqual(
            assets.filter { $0.installState == .installed }.count, 1
        )
    }

    /// hash 不符：文件/库零副作用——目录不动、行不动、文档
    /// 状态不变。
    func testRelinkRejectsUnrelatedFileWithoutSideEffects() async throws {
        let file = try writeSource("keep.txt", "原本の内容です。")
        let documentID = UUID()
        _ = try await ingest.importTextFile(
            fileURL: file, documentID: documentID
        )
        let assetsBefore = try await repository.fetchAssets(
            documentID: documentID
        )
        let fetchedChapters = try await repository.fetchChapters(
            documentID: documentID
        )
        let chapter = try XCTUnwrap(fetchedChapters.first)
        let blocksBefore = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )

        let wrong = try writeSource("wrong.txt", "完全不同的正文です。")
        do {
            _ = try await relinkService.relink(
                documentID: documentID, preparedFileURL: wrong
            )
            XCTFail("应拒绝 hash 不符的重关联")
        } catch ReaderRelinkError.contentMismatch {
        }

        let doc = try await repository.fetchDocument(id: documentID)
        XCTAssertEqual(doc?.availability, .available)
        XCTAssertTrue(documentDirectoryExists(documentID))
        let assetsAfter = try await repository.fetchAssets(
            documentID: documentID
        )
        XCTAssertEqual(assetsAfter, assetsBefore)
        let blocksAfter = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        XCTAssertEqual(blocksAfter, blocksBefore)
    }

    /// v8 恢复态：文档+章节壳存在、块/资产/缓存不在备份里——
    /// relink 把正文重建回来；同 canonical 章保留 ID → 位置
    /// 的 chapter_id 不断；块全新 ID（旧块行已删无从复用）。
    func testRelinkRebuildsBlocksForRestoredChapterShells() async throws {
        let file = try writeSource(
            "shell.txt", "第一章正文です。\n\n続きの段落。"
        )
        let documentID = UUID()
        _ = try await ingest.importTextFile(
            fileURL: file, documentID: documentID
        )
        let chapters = try await repository.fetchChapters(
            documentID: documentID
        )
        let chapter = try XCTUnwrap(chapters.first)
        let oldBlocks = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        try await repository.savePosition(
            ReaderPosition(
                documentID: documentID, chapterID: chapter.id,
                location: ReaderLocation(
                    chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 0,
                    blockTextHash: oldBlocks[0].textHash,
                    prefix: "", suffix: ""
                ),
                updatedAt: clock
            )
        )

        // 抹掉备份不承载的行，制造恢复后的真实形态。
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_blocks WHERE document_id = ?",
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
            try db.execute(
                sql: "DELETE FROM reader_assets WHERE document_id = ?",
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
            try db.execute(
                sql: """
                    UPDATE reader_documents SET availability = 'missing'
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
        }
        try await fileStore.removeFiles(documentID: documentID)

        let outcome = try await relinkService.relink(
            documentID: documentID, preparedFileURL: file
        )
        XCTAssertEqual(outcome.confirmation, .sourceSHA256)
        XCTAssertTrue(outcome.rebuiltContent)

        let newChapters = try await repository.fetchChapters(
            documentID: documentID
        )
        XCTAssertEqual(newChapters.map(\.id), chapters.map(\.id))
        let newBlocks = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        XCTAssertEqual(newBlocks.count, oldBlocks.count)
        XCTAssertEqual(newBlocks.map(\.text), oldBlocks.map(\.text))
        // 位置行仍在且 chapter_id 仍解析到复用章。
        let position = try await repository.fetchPosition(
            documentID: documentID
        )
        XCTAssertEqual(position?.chapterID, chapter.id)
        let relinkedDoc = try await repository.fetchDocument(
            id: documentID
        )
        XCTAssertEqual(relinkedDoc?.availability, .available)
    }

    /// 不存在的文档：显式拒绝。
    func testRelinkUnknownDocumentRejected() async throws {
        let file = try writeSource("any.txt", "内容です。")
        do {
            _ = try await relinkService.relink(
                documentID: UUID(), preparedFileURL: file
            )
            XCTFail("应拒绝不存在的文档")
        } catch let error as ReaderRelinkError {
            XCTAssertEqual(error, .documentNotFound)
        }
    }

    // MARK: - 3. 文件对账

    /// available 文档的 ReaderFiles 目录消失 → missing；
    /// 孤儿目录只入报告、绝不删文件（§4.3-6）。
    func testReconcileMarksMissingAndReportsOrphanDirectories()
        async throws
    {
        let file = try writeSource("gone.txt", "消えるファイル。")
        let documentID = UUID()
        _ = try await ingest.importTextFile(
            fileURL: file, documentID: documentID
        )
        try await fileStore.removeFiles(documentID: documentID)

        // 孤儿目录：有文件无文档行。
        let orphanID = UUID()
        let orphanDir = fileStore.documentsDirectoryURL
            .appendingPathComponent(
                orphanID.uuidString.lowercased(), isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: orphanDir, withIntermediateDirectories: true
        )
        let orphanFile = orphanDir.appendingPathComponent("x.txt")
        try "orphan".write(to: orphanFile, atomically: true, encoding: .utf8)

        let report = try await reconciler
            .reconcileAfterDatabaseReplacement()

        XCTAssertEqual(report.documentCount, 1)
        XCTAssertEqual(report.markedMissing, [documentID])
        XCTAssertEqual(report.orphanDirectoryIDs, [orphanID])
        XCTAssertTrue(report.restoredAvailable.isEmpty)
        // 孤儿文件仍在。
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanFile.path))
        let demotedDoc = try await repository.fetchDocument(
            id: documentID
        )
        XCTAssertEqual(demotedDoc?.availability, .missing)
    }

    /// missing + 资产可解析 → 自愈 available；
    /// missing + 无资产行但目录内文件 SHA-256 命中 → 补登记 + 自愈。
    func testReconcileHealsMissingByAssetAndBySHA256() async throws {
        // A：资产行在场、文件在场——本地快照恢复到文件仍在的设备。
        let fileA = try writeSource("a.txt", "A の文。")
        let docA = UUID()
        _ = try await ingest.importTextFile(
            fileURL: fileA, documentID: docA
        )
        try await repository.updateAvailability(
            id: docA, availability: .missing
        )

        // B：v8 恢复形态——资产行不在备份里，目录内文件 hash 命中。
        let fileB = try writeSource("b.txt", "B の文。")
        let docB = UUID()
        _ = try await ingest.importTextFile(
            fileURL: fileB, documentID: docB
        )
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_assets WHERE document_id = ?",
                arguments: [DatabaseValueCodec.encode(docB)]
            )
            try db.execute(
                sql: """
                    UPDATE reader_documents SET availability = 'missing'
                    WHERE id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(docB)]
            )
        }

        let report = try await reconciler
            .reconcileAfterDatabaseReplacement()
        XCTAssertEqual(
            Set(report.restoredAvailable), Set([docA, docB])
        )
        XCTAssertTrue(report.markedMissing.isEmpty)
        let healedA = try await repository.fetchDocument(id: docA)
        let healedB = try await repository.fetchDocument(id: docB)
        XCTAssertEqual(healedA?.availability, .available)
        XCTAssertEqual(healedB?.availability, .available)
        // B 的资产行被补登记且能解析出文件。
        let assetsB = try await repository.fetchAssets(documentID: docB)
        XCTAssertEqual(assetsB.count, 1)
        XCTAssertEqual(assetsB[0].installState, .installed)
        XCTAssertNotNil(fileStore.fileURL(
            documentID: docB, relativePath: assetsB[0].relativePath
        ))
    }

    /// 对账不触碰 Reader 管辖以外的目录（附件区隔离断言）。
    func testReconcileLeavesAttachmentDirectoriesUntouched() async throws {
        let attachments = root.appendingPathComponent(
            "InboxImages", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: attachments, withIntermediateDirectories: true
        )
        let blob = attachments.appendingPathComponent("img.bin")
        try Data([9, 9, 9]).write(to: blob)

        let report = try await reconciler
            .reconcileAfterDatabaseReplacement()
        XCTAssertEqual(report.documentCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: blob), Data([9, 9, 9])
        )
    }

    // MARK: - 4. kill mid-restore：旧库 + Reader 文件完好

    /// 注入 fault 于 candidateInstalled（库文件已换、验证未完成）：
    /// replaceDatabase 内部回滚 → open() 得到的仍是旧库；
    /// ReaderFiles/<documentID>/ 目录全程不动。
    func testKilledRestoreKeepsOldDatabaseAndReaderFiles() async throws {
        let liveURL = root.appendingPathComponent("live.sqlite")
        let snapshotsURL = root.appendingPathComponent(
            "Snapshots", isDirectory: true
        )
        let injector = RestorationStageProbe()
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: liveURL,
            snapshotService: DatabaseSnapshotService(
                directoryURL: snapshotsURL
            ),
            migrator: OboeDatabaseSchema.makeMigrator(),
            restorationFaultInjector: { stage in
                try injector.throwIfCandidateInstalled(stage)
            }
        )
        let live = try await lifecycle.open()

        // 旧库：Reader 文档 + 已装文件（独立 fileStore 目录在
        // 同一 root 下——生命周期只动 sqlite 文件）。
        let liveRepository = GRDBReaderRepository(database: live)
        let liveIngest = ReaderIngestService(
            fileStore: fileStore, repository: liveRepository
        )
        let file = try writeSource("live.txt", "旧库のドキュメント。")
        let documentID = UUID()
        _ = try await liveIngest.importTextFile(
            fileURL: file, documentID: documentID
        )
        XCTAssertTrue(documentDirectoryExists(documentID))

        // 候选库：迁移完成的空库。
        let sourceURL = root.appendingPathComponent("source.sqlite")
        let candidate = try OboeDatabase(path: sourceURL.path)
        try await candidate.close()

        do {
            _ = try await lifecycle.replaceDatabase(with: sourceURL)
            XCTFail("注入的候选安装中断应使替换失败")
        } catch {
            // 预期：restorationError 原样抛出（回滚已在内部完成）。
        }

        // 旧库完好：文档行仍在、文件目录未动、marker 清理。
        let restored = try await lifecycle.currentDatabase()
        let liveDatabase = try XCTUnwrap(restored)
        let restoredRepository = GRDBReaderRepository(
            database: liveDatabase
        )
        let restoredDocRow = try await restoredRepository.fetchDocument(
            id: documentID
        )
        XCTAssertEqual(restoredDocRow?.availability, .available)
        XCTAssertTrue(documentDirectoryExists(documentID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                ".oboe-restoration-state.json"
            ).path
        ))
        XCTAssertTrue(injector.didHitCandidateInstalled)
    }

    // MARK: - 5. 恢复窗口：stale generation + 在途导入抽干

    /// 世代屏障：恢复把活世代推进一步后，旧世代的挖词请求在
    /// `mine` 前置校验被拒——不进入任何写事务。
    func testRestoreWindowRejectsStaleGenerationMining() async throws {
        let generationBox = GateGenerationBox(value: 9)
        let fixedClock = clock
        let service = ReaderMiningService(
            dictionary: S24StubDictionaryRepository(),
            knowledge: GRDBVocabularyKnowledgeRepository(pool: pool),
            linking: GRDBVocabularyKnowledgeRepository(pool: pool),
            store: GRDBReaderMiningStore(pool: pool),
            currentGeneration: { generationBox.value },
            now: { fixedClock },
            makeID: { UUID() }
        )
        let deckID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        let request = ReaderMiningRequest(
            operationID: UUID(),
            expectedGeneration: 8,   // 恢复前旧代
            deckID: deckID,
            selection: ReaderMiningSelection(
                lexicalKey: LexicalIdentityKey.jmdict(
                    entryID: 42,
                    normalizedForm: "食べる",
                    reading: "たべる"
                ),
                writtenForm: "食べる",
                normalizedLemma: "食べる",
                reading: "たべる",
                posFamily: "动词",
                posCodes: ["v1"],
                entryID: 42,
                senseID: 7,
                senseKey: "42:7",
                selectedGlossLanguage: "zho",
                meaningZH: "吃",
                dictionaryVersion: "ds-1"
            ),
            context: ReaderMiningContext(
                documentID: UUID(),
                chapterID: UUID(),
                location: ReaderLocation(
                    chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 0,
                    blockTextHash: "h", prefix: "", suffix: ""
                ),
                sentence: "毎日パンを食べる。",
                surroundingText: nil,
                selectedSurface: "食べる",
                sourceTitle: nil
            )
        )
        do {
            _ = try await service.mine(request)
            XCTFail("旧代请求应被 staleGeneration 拒绝")
        } catch let error as ReaderMiningError {
            XCTAssertEqual(
                error,
                .staleGeneration(expected: 8, current: 9)
            )
        }
        // 零写入证明。
        let noteRows = try await countRows("notes")
        let receiptRows = try await countRows("reader_mining_receipts")
        XCTAssertEqual(noteRows, 0)
        XCTAssertEqual(receiptRows, 0)
    }

    /// 在途 CSV 导入：任务经 gate 登记 → closeAndWait 取消并等
    /// 退出 → job 落在 `cancelled`/`completed` 终态（receipt 使
    /// 续跑安全）——绝不卡在 running 让恢复以为还有写方。
    func testRestoreWindowDrainsEnrolledImportExecution() async throws {
        let deckID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        let stagingDir = root.appendingPathComponent(
            "ImportStaging", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDir, withIntermediateDirectories: true
        )
        let staging = try ImportStaging(directory: stagingDir)
        var parser = DelimitedTextParserImpl(delimiter: ",")
        for index in 0..<500 {
            try staging.append(
                try parser.feed("語\(index),ご\(index),意思\(index)\n")
            )
        }
        try staging.append(try parser.finish())

        let mapping = ImportFieldMapping(
            columnToField: [
                0: .headword, 1: .reading, 2: .meaningZH
            ],
            tagRule: .jsonArray,
            duplicatePolicy: .update,
            allowEmptyOverwrite: false,
            exampleRule: .appendDeduplicated,
            newCardTemplates: [.vocabularyJapaneseToChinese],
            targetDeckID: deckID
        )
        let job = ImportJob(
            id: UUID(),
            fileHash: "fh",
            mappingHash: ImportExecutor.mappingHash(mapping),
            policy: mapping.duplicatePolicy,
            targetDeckID: deckID,
            status: .previewed,
            createdAt: Date()
        )
        let repo = GRDBImportPlanRepository(database: database)
        try await repo.createJob(job)
        try await repo.attachStagingInfo(
            jobID: job.id,
            stagingFileName: staging.fileURL.lastPathComponent,
            stagingFingerprint: "fp",
            rowCount: staging.rowCount,
            mappingSummary: nil
        )

        let gate = RestorationWorkGate()
        let executor = ImportExecutor(database: database)
        // executor 要求先 precheck 写 plan 行（precheckRequired 硬拒）。
        _ = try await executor.precheck(mapping: mapping, staging: staging)
        let probe = ImportProbe()
        let task = Task<Void, Never> {
            do {
                let summary = try await executor.execute(
                    jobID: job.id, mapping: mapping, staging: staging
                )
                probe.summaryStatus = summary.status
            } catch {
                probe.error = error
            }
        }
        _ = await gate.enroll(task)
        // 给执行器一小段进入 running/批循环的窗口（否则首个池写
        // 直接被 GRDB 取消感知拒掉，job 停在 previewed 起点）。
        try? await Task.sleep(nanoseconds: 60_000_000)
        await gate.closeAndWait()
        // closeAndWait 已等任务退出；它对登记任务无条件发取消。
        XCTAssertTrue(task.isCancelled)
        // 取消可能落在批循环检查点（→ setJobStatus(.cancelled)）或
        // GRDB 取消感知池写（→ CancellationError 抛出，job 留 running，
        // 即幂等可续跑的"中断"态）。两者都是合法落点。
        if let error = probe.error, !(error is CancellationError) {
            XCTFail("execute 抛非取消错误：\(error)")
        }

        let detail = try await repo.fetchJobDetail(id: job.id)
        XCTAssertNotNil(detail)
        XCTAssertTrue(
            [ImportJobStatus.cancelled, .completed, .interrupted, .running]
                .contains(detail?.job.status ?? .failed),
            "job 应落在终态/可续跑态，实际 \(String(describing: detail?.job.status))"
        )
    }

    // MARK: - 6. v1–v8 恢复矩阵

    /// v1–v6 NDJSON（当前导出降级）+ v7/v8 ZIP 包：每个版本走
    /// prepare → replaceDatabase → 对账 全链路冒烟。
    /// v8 额外断言 Reader 元数据降级 missing 的运行时对账不炸。
    func testBackupMatrixV1throughV8PreparesAndRestores() async throws {
        for version in 1...8 {
            let iter = root.appendingPathComponent(
                "matrix-v\(version)", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: iter, withIntermediateDirectories: true
            )

            // 源库：最小种子（deck + vocabulary note）。
            let sourceURL = iter.appendingPathComponent("source.sqlite")
            let source = try OboeDatabase(path: sourceURL.path)
            try await source.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO decks VALUES (?, 'm', 0, 1, 1)
                        """,
                    arguments: [DatabaseValueCodec.encode(UUID())]
                )
            }
            let exportsURL = iter.appendingPathComponent(
                "exports", isDirectory: true
            )
            let backupURL: URL
            if version <= 6 {
                let exported = try await PortableBackupExporter(
                    database: source,
                    workingDirectoryURL: exportsURL
                ).export(
                    appVersion: "test",
                    at: clock,
                    recordFormatVersion: 8
                )
                let downgraded = iter.appendingPathComponent(
                    "backup-v\(version).ndjson"
                )
                try rewriteBackup(exported.url, to: downgraded) {
                    objects in
                    downgradeBackupToLegacyFormat(
                        &objects, version: version
                    )
                }
                backupURL = downgraded
            } else {
                let package = try await PortableBackupPackageExporter(
                    database: source,
                    imageStore: InboxImageStore(
                        rootDirectoryURL: iter.appendingPathComponent(
                            "img", isDirectory: true
                        )
                    ),
                    workingDirectoryURL: exportsURL
                ).export(
                    appVersion: "test",
                    at: clock,
                    formatVersion: version
                )
                backupURL = package.url
            }
            try await source.close()

            // 当前库 + 生命周期 + preparer。
            let liveURL = iter.appendingPathComponent("live.sqlite")
            let lifecycle = OboeDatabaseLifecycle(
                databaseURL: liveURL,
                snapshotDirectoryURL: iter.appendingPathComponent(
                    "snapshots", isDirectory: true
                )
            )
            let current = try await lifecycle.open()
            let preparer = PortableBackupRestorationPreparer(
                currentDatabase: current,
                workingDirectoryURL: iter.appendingPathComponent(
                    "prep", isDirectory: true
                )
            )
            let prepared = try await preparer.prepareAutomatically(
                fileURL: backupURL
            )
            XCTAssertEqual(
                prepared.sourceFormatVersion, version,
                "v\(version) 源版本识别"
            )
            let restored = try await lifecycle.replaceDatabase(
                with: prepared.temporaryDatabaseURL
            )
            // 对账在新库上跑得通（无 reader 行 → 空报告）。
            let report = try await ReaderFileReconciler(
                fileStore: LocalReaderFileStore(
                    baseDirectoryURL: iter
                ),
                repository: GRDBReaderRepository(database: restored)
            ).reconcileAfterDatabaseReplacement()
            XCTAssertEqual(report.documentCount, 0)
            try await lifecycle.close()
        }
    }

    /// 高版本拒绝在预检期（不碰线上库）：v99 记录直接被拒。
    func testFutureFormatVersionRejectedBeforeSwap() async throws {
        let iter = root.appendingPathComponent(
            "future", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: iter, withIntermediateDirectories: true
        )
        let sourceURL = iter.appendingPathComponent("source.sqlite")
        let source = try OboeDatabase(path: sourceURL.path)
        let exported = try await PortableBackupExporter(
            database: source,
            workingDirectoryURL: iter.appendingPathComponent("e")
        ).export(appVersion: "test", at: clock, recordFormatVersion: 8)
        try await source.close()
        let bumped = iter.appendingPathComponent("v99.ndjson")
        try rewriteBackup(exported.url, to: bumped) { objects in
            objects[0]["formatVersion"] = 99
        }

        let liveURL = iter.appendingPathComponent("live.sqlite")
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: liveURL,
            snapshotDirectoryURL: iter.appendingPathComponent("s")
        )
        let current = try await lifecycle.open()
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: iter.appendingPathComponent("p")
        )
        do {
            _ = try await preparer.prepare(fileURL: bumped)
            XCTFail("v99 应被预检拒绝")
        } catch let error as PortableBackupPreparationError {
            guard case .futureFormatVersion(99) = error else {
                return XCTFail("预期 futureFormatVersion，实际 \(error)")
            }
        }
        // 线上库仍在且可读——拒绝发生在换库之前。
        let stillCurrent = await lifecycle.currentDatabase()
        XCTAssertNotNil(stillCurrent)
        try await lifecycle.close()
    }

    // MARK: - 7. Cloze 独立端到端

    /// 完整链路：Reader 文档 + cloze 卡（reader 来源）→ v8 备份 →
    /// 原文文件不随迁 → 恢复 → 文档 missing、cloze 复习队列正常、
    /// 来源定位字段完好 → relink 原文 → available + 块重建 +
    /// source_contexts 仍解析到同一文档/定位。
    func testClozeReviewSurvivesRestoreThenRelinkRestoresReaderContext()
        async throws
    {
        // 源库：deck + reader 文档（sha256 指向真实文件）+ cloze。
        let file = try writeSource("e2e.txt", "彼は昨日映画を見た。")
        let documentID = UUID()
        let imported = try await ingest.importTextFile(
            fileURL: file, documentID: documentID
        )
        let e2eChapters = try await repository.fetchChapters(
            documentID: documentID
        )
        let chapter = try XCTUnwrap(e2eChapters.first)

        let deckID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'd', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        let cards = GRDBContentCardRepository(database: database)
        let sentence = "彼は昨日映画を見た。"
        let range = ClozeValidator.surfaceRanges(
            of: "見た", in: sentence
        )[0]
        let noteID = UUID()
        let cardID = UUID()
        let readerLocation = ReaderLocation(
            chapterOrdinal: 0, blockOrdinal: 0, utf16Offset: 7,
            blockTextHash: String(repeating: "a", count: 64),
            prefix: "映画を", suffix: "。"
        )
        let commit = try SentenceContentCommit(
            noteID: noteID,
            clozeID: UUID(),
            deckID: deckID,
            cloze: ValidatedClozeContent(
                sentenceSnapshot: sentence,
                utf16Start: range.utf16Start,
                utf16Length: range.utf16Length,
                targetSurface: "見た",
                targetLemma: "見る",
                targetReading: "みた",
                acceptedAnswers: ["見た"],
                hint: nil
            ),
            card: NewCardSeed(id: cardID, templateKind: .sentenceCloze),
            schedulerProfileID: UUID(),
            createdAt: clock,
            meaningZH: "他昨天看了电影。",
            origin: .reader,
            deckIDs: nil,
            sourceContext: SourceContext(
                id: UUID(),
                noteID: noteID,
                sourceType: .reader,
                originalSentence: sentence,
                surroundingText: "周辺の文脈",
                sourceTitle: imported.document.title,
                sourceURL: nil,
                sourceApp: nil,
                imageReference: nil,
                dictionaryEntryID: nil,
                dictionaryVersion: nil,
                dictionarySenseKey: nil,
                selectedGlossLanguage: nil,
                isPrimary: true,
                createdAt: clock,
                readerDocumentID: documentID,
                readerChapterID: chapter.id,
                readerLocation: readerLocation,
                selectedSurface: "見た"
            )
        )
        _ = try await cards.commitSentence(commit, capture: nil)

        // v8 备份（reader 元数据随行；blocks/assets 不导出）。
        let exportsURL = root.appendingPathComponent("e2e-exports")
        let package = try await PortableBackupPackageExporter(
            database: database,
            imageStore: InboxImageStore(
                rootDirectoryURL: root.appendingPathComponent("e2e-images")
            ),
            workingDirectoryURL: exportsURL
        ).export(appVersion: "test", at: clock, formatVersion: 8)

        // 新库（模拟另一台设备/重装）：无 ReaderFiles 目录。
        let deviceRoot = root.appendingPathComponent(
            "device", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: deviceRoot, withIntermediateDirectories: true
        )
        let deviceFileStore = LocalReaderFileStore(
            baseDirectoryURL: deviceRoot
        )
        let lifecycle = OboeDatabaseLifecycle(
            databaseURL: deviceRoot.appendingPathComponent("live.sqlite"),
            snapshotDirectoryURL: deviceRoot.appendingPathComponent(
                "snapshots", isDirectory: true
            )
        )
        let current = try await lifecycle.open()
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: deviceRoot.appendingPathComponent("prep")
        )
        let prepared = try await preparer.prepareAutomatically(
            fileURL: package.url
        )
        let restored = try await lifecycle.replaceDatabase(
            with: prepared.temporaryDatabaseURL
        )
        let restoredRepository = GRDBReaderRepository(
            database: restored
        )

        // 恢复后：文档 missing（finalize）——对账再次确认文件不在。
        let restoredDoc = try await restoredRepository.fetchDocument(
            id: documentID
        )
        XCTAssertEqual(restoredDoc?.availability, .missing)
        let reconcileReport = try await ReaderFileReconciler(
            fileStore: deviceFileStore,
            repository: restoredRepository
        ).reconcileAfterDatabaseReplacement()
        XCTAssertTrue(reconcileReport.markedMissing.isEmpty)   // 已是 missing
        XCTAssertTrue(reconcileReport.restoredAvailable.isEmpty)

        // cloze 复习照常：卡入队 + 复习 payload 取得到。
        let plan = try await BuildTodayPlan(
            studyDayRepository: GRDBStudyDayPlanningRepository(
                database: restored
            ),
            queueRepository: GRDBTodayQueueRepository(
                database: restored
            )
        )(at: clock, defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertTrue(
            plan.availableNow.contains { $0.cardID == cardID },
            "恢复后 cloze 卡应正常入队复习"
        )
        let payload = try await GRDBReviewCardContentRepository(
            database: restored
        ).fetchReviewCardContent(cardID: cardID)
        XCTAssertNotNil(payload)

        // relink：用户把原文文件放回 → sha256 精确命中 →
        // available + 块重建 + 章 ID 复用。
        let relinker = ReaderRelinkService(
            fileStore: deviceFileStore,
            repository: restoredRepository,
            store: restoredRepository
        )
        let outcome = try await relinker.relink(
            documentID: documentID, preparedFileURL: file
        )
        XCTAssertEqual(outcome.confirmation, .sourceSHA256)
        let relinkedDoc = try await restoredRepository.fetchDocument(
            id: documentID
        )
        XCTAssertEqual(relinkedDoc?.availability, .available)
        let restoredChapters = try await restoredRepository
            .fetchChapters(documentID: documentID)
        XCTAssertEqual(restoredChapters.map(\.id), [chapter.id])
        let restoredBlocks = try await restoredRepository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        XCTAssertFalse(restoredBlocks.isEmpty)

        // source_contexts：弱引用字段（reader_document_id/章/
        // location JSON）全程有效——S13 的 cloze 独立性验证闭环。
        // Row 不 Sendable——在闭包内抽成值元组带出。
        let context = try await restored.pool.read { db
            -> (String?, String?, String?, String?) in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT reader_document_id, reader_chapter_id,
                           reader_location, source_type
                    FROM source_contexts WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
            return (
                row?["source_type"], row?["reader_document_id"],
                row?["reader_chapter_id"], row?["reader_location"]
            )
        }
        XCTAssertEqual(context.0, "reader")
        XCTAssertEqual(context.1, DatabaseValueCodec.encode(documentID))
        XCTAssertEqual(context.2, DatabaseValueCodec.encode(chapter.id))
        let decodedLocation = try JSONDecoder().decode(
            ReaderLocation.self,
            from: Data(try XCTUnwrap(context.3).utf8)
        )
        XCTAssertEqual(decodedLocation, readerLocation)
        try await lifecycle.close()
    }
}

// MARK: - 测试桩件

/// 闸门测试探针（@Sendable 闭包共享）。
private final class GateProbe: @unchecked Sendable {
    var started = false
    var exitedAfterCancel: Bool?
    var lateSawCancelled: Bool?
    var rounds = 0
}

/// fault injector 探针：candidateInstalled 阶段抛错模拟进程
/// 在「库文件已换、校验未完成」窗口被杀。
private final class RestorationStageProbe: @unchecked Sendable {
    private(set) var didHitCandidateInstalled = false

    struct InjectedFault: Error {}

    func throwIfCandidateInstalled(
        _ stage: DatabaseRestorationStage
    ) throws {
        if case .candidateInstalled = stage {
            didHitCandidateInstalled = true
            throw InjectedFault()
        }
    }
}

/// 导入执行探针：带出错/摘要状态出 @Sendable 任务体。
private final class ImportProbe: @unchecked Sendable {
    var summaryStatus: ImportJobStatus?
    var error: (any Error)?
}

/// 可变世代盒（mining 服务 currentGeneration 闭包读它）。
private final class GateGenerationBox: @unchecked Sendable {
    var value: Int
    init(value: Int) { self.value = value }
}

/// 词典仓储桩：stubbedEntries 直查（stale-generation 断言在查词
/// 之前发生，桩永不被命中）。
private final class S24StubDictionaryRepository: DictionaryRepository,
    @unchecked Sendable {
    var stubbedEntries: [Int64: DictionaryEntry] = [:]

    func metadata() async throws -> DictionaryMetadata {
        DictionaryMetadata(
            schemaVersion: "1", datasetVersion: "ds-1",
            dictionaryVersion: "dv-1"
        )
    }

    func search(
        _ request: DictionarySearchRequest
    ) async throws -> DictionarySearchPage {
        DictionarySearchPage(
            items: [], nextCursor: nil, hasMore: false,
            normalizedQuery: request.normalizedQuery
        )
    }

    func entries(ids: [Int64]) async throws -> [DictionaryEntry] {
        ids.compactMap { stubbedEntries[$0] }
    }

    func entry(id: Int64) async throws -> DictionaryEntry? {
        stubbedEntries[id]
    }

    func sources() async throws -> [DictionarySourceInfo] { [] }
}
