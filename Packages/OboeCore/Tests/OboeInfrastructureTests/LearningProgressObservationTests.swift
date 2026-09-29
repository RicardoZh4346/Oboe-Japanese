import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S18：`GRDBLearningProgressRepository.observeProgress()`
/// 与 `GRDBReaderStudyDeckRepository` 的集成测试。
///
/// 覆盖点（对应「无需重开页面就同步 / 不重跑 AI·morphology」）：
/// - 首发即全库快照（deck 进度 + 绑定 + 指纹）；
/// - 评分写卡（rowid `cards`）→ 发射新进度；
/// - tooEasy/链接（WITHOUT ROWID 表）经 `learning_unit_events`
///   审计代理触发；
/// - 成员关系（WITHOUT ROWID `note_decks`）随同事务的 rowid 写
///   （`notes.updated_at_ms`——与全部生产写路径一致）触发；
/// - 无内容变化的 region 命中被 `.removeDuplicates()` 压掉；
/// - 文档绑定生命周期（绑定/牌组删除 SET NULL）入载荷；
/// - coverage v2 活算投影（occurrence+三态+块）只读重放。
final class LearningProgressObservationTests: XCTestCase {

    // MARK: - 发射与内容

    /// 首发发射：库内全部 deck 都在 `progressByDeck`（无覆盖 unit
    /// 的 deck `progress = nil, unitCount = 0`，不是缺键）。
    func testInitialEmissionCoversAllDecks() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let deckA = try await fixture.addDeck()
        let emptyDeck = try await fixture.addDeck(sortOrder: 1)
        let noteID = try await fixture.addNote(deckID: deckA)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            stability: 30
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }

        try await waitUntil { await collector.count >= 1 }
        let firstUpdate = await collector.latest
        let first = try XCTUnwrap(firstUpdate)
        XCTAssertEqual(first.progressByDeck[deckA]?.unitCount, 1)
        XCTAssertEqual(
            first.progressByDeck[deckA]?.progress ?? -1,
            1,
            accuracy: 1e-9
        )
        XCTAssertNil(
            first.progressByDeck[emptyDeck]?.progress ?? nil,
            "空 deck progress = nil（UI 显示「—」）"
        )
        XCTAssertEqual(first.progressByDeck[emptyDeck]?.unitCount, 0)
        XCTAssertTrue(first.studyDeckLinks.isEmpty)
        XCTAssertEqual(first.knowledgeFingerprint.linkCount, 1)
    }

    /// 评分写卡（stability 更新）→ 新发射携带新进度；同一 pool
    /// 上的写——跨 scene 同池写入就是这条路径。
    func testReviewWriteEmitsUpdatedProgress() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        let cardID = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            stability: 0
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil { await collector.count >= 1 }
        let initialProgress = await collector.latest?
            .progressByDeck[deckID]?.progress
        XCTAssertEqual(initialProgress, 0)

        // 模拟评分落库：stability 0 → 30（cardProgress 0 → 1）。
        try await fixture.setCardStability(cardID, 30)
        try await waitUntil {
            await collector.latest?.progressByDeck[deckID]?.progress == 1
        }
        let emittedCount = await collector.count
        XCTAssertGreaterThanOrEqual(emittedCount, 2)
    }

    /// Too Easy（WITHOUT ROWID `learning_unit_flags`）经
    /// `learning_unit_events` 审计代理触发重估并发射。
    func testTooEasyEmitsViaAuditProxy() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            stability: 0
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil { await collector.count >= 1 }

        try await fixture.setTooEasy(unitID: unitID, value: true)
        try await waitUntil {
            await collector.latest?.progressByDeck[deckID]?.progress == 1
        }
        let update = await collector.latest
        XCTAssertEqual(update?.knowledgeFingerprint.tooEasyCount, 1)
        XCTAssertGreaterThan(
            update?.knowledgeFingerprint.unitEventCount ?? 0, 0
        )

        // 撤销 tooEasy（行不增 revision 递增）也发射。
        try await fixture.setTooEasy(unitID: unitID, value: false)
        try await waitUntil {
            await collector.latest?.progressByDeck[deckID]?.progress == 0
        }
    }

    /// 成员关系：直连写 `note_decks`（WITHOUT ROWID）+ 同事务的
    /// `notes` 行更新（生产写路径的既有纪律）→ deckB 获得该 unit。
    func testMembershipWriteEmits() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let deckA = try await fixture.addDeck()
        let deckB = try await fixture.addDeck(sortOrder: 1)
        let noteID = try await fixture.addNote(deckID: deckA)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            stability: 30
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil { await collector.count >= 1 }
        let deckBUnits = await collector.latest?
            .progressByDeck[deckB]?.unitCount
        XCTAssertEqual(deckBUnits, 0)

        try await fixture.addMembership(noteID: noteID, deckID: deckB)
        try await waitUntil {
            await collector.latest?.progressByDeck[deckB]?.unitCount == 1
        }
        let deckBProgress = await collector.latest?
            .progressByDeck[deckB]?.progress
        XCTAssertEqual(deckBProgress, 1)
    }

    /// 去重：region 命中但载荷不变（无操作 UPDATE）→ 不发射；
    /// 之后再做真实写确认流仍然活着。
    func testIdenticalPayloadIsDeduplicated() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil { await collector.count >= 1 }
        let baseline = await collector.count

        // 触发跟踪表但载荷不变：name 重写为同值。
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE decks SET name = name WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let afterNoop = await collector.count
        XCTAssertEqual(
            afterNoop, baseline,
            "无内容变化的重估被 removeDuplicates 压掉"
        )

        // 真实写仍然发射——流没死。新建牌组在 progressByDeck 里
        // 新增条目，载荷必变（裸 notes 行是内容中性的，不够）。
        _ = try await fixture.addDeck(sortOrder: 1)
        try await waitUntil { await collector.count > baseline }
    }

    /// 绑定生命周期：UPDATE study_deck_id → 载荷携带绑定行；
    /// 删牌组 → FK SET NULL → 绑定消失（两发射各见各态）。
    func testBindingLifecycleEmits() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let documentID = try await fixture.addDocument(title: "テスト")
        let deckID = try await fixture.addDeck()

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil { await collector.count >= 1 }
        let initialIDs = await collector.latest?.readerDocumentIDs
        XCTAssertEqual(initialIDs, Set([documentID]))
        let initialLinks = await collector.latest?.studyDeckLinks ?? []
        XCTAssertTrue(initialLinks.isEmpty)

        // 绑定（ensureStudyDeck 已经建组 + UPDATE 同事务——直接用
        // 池级仓储走正路）。
        let studyDecks = GRDBReaderStudyDeckRepository(
            database: fixture.database
        )
        let boundDeck = try await studyDecks.ensureStudyDeck(
            forDocument: documentID
        )
        XCTAssertNotEqual(boundDeck, deckID)
        try await waitUntil {
            await collector.latest?.studyDeckLinks.count == 1
        }
        let firstLink = await collector.latest?.studyDeckLinks.first
        let link = try XCTUnwrap(firstLink)
        XCTAssertEqual(link.documentID, documentID)
        XCTAssertEqual(link.deckID, boundDeck)
        XCTAssertEqual(link.documentTitle, "テスト")

        // 牌组删除 → study_deck_id SET NULL → 绑定行消失。
        try await fixture.deleteDeck(boundDeck)
        try await waitUntil {
            await collector.latest?.studyDeckLinks.isEmpty == true
        }
        let remainingIDs = await collector.latest?.readerDocumentIDs ?? []
        XCTAssertTrue(
            remainingIDs.contains(documentID),
            "牌组陪葬只解绑，文档保留"
        )
    }

    /// 文档删除 → readerDocumentIDs 集合变化。
    func testDocumentDeletionEmits() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let documentID = try await fixture.addDocument(title: "文")

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil {
            await collector.latest?.readerDocumentIDs
                .contains(documentID) == true
        }

        try await fixture.deleteDocument(documentID)
        try await waitUntil {
            await collector.latest?.readerDocumentIDs
                .contains(documentID) == false
        }
    }

    // MARK: - GRDBReaderStudyDeckRepository

    /// ensureStudyDeck 幂等 + 双向反查 + 牌组删除解绑。
    func testStudyDeckRepositoryBindings() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let documentID = try await fixture.addDocument(title: "作品")
        let repository = GRDBReaderStudyDeckRepository(
            database: fixture.database
        )

        let beforeBind = try await repository.studyDeckID(
            forDocument: documentID
        )
        XCTAssertNil(beforeBind)
        let deckID = try await repository.ensureStudyDeck(
            forDocument: documentID
        )
        // 幂等：重复 ensure 返回同一绑定。
        let rebound = try await repository.ensureStudyDeck(
            forDocument: documentID
        )
        XCTAssertEqual(rebound, deckID)
        let forward = try await repository.studyDeckID(
            forDocument: documentID
        )
        XCTAssertEqual(forward, deckID)
        let backward = try await repository.boundDocumentID(
            forDeck: deckID
        )
        XCTAssertEqual(backward, documentID)

        try await fixture.deleteDeck(deckID)
        let afterDeckDelete = try await repository.studyDeckID(
            forDocument: documentID
        )
        XCTAssertNil(afterDeckDelete)
        let backwardAfterDelete = try await repository.boundDocumentID(
            forDeck: deckID
        )
        XCTAssertNil(backwardAfterDelete)
    }

    /// coverage v2 活算：resolved/pending/oov occurrence 分组 +
    /// 块覆盖 + unit 三态 —— `documentCoverageResult` 全程只读。
    func testDocumentCoverageProjection() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let documentID = try await fixture.addDocument(title: "記事")
        let chapterID = try await fixture.addChapter(
            documentID: documentID, ordinal: 0
        )
        try await fixture.addBlock(
            documentID: documentID, chapterID: chapterID,
            ordinal: 0, locatorKey: "0/0"
        )
        try await fixture.addBlock(
            documentID: documentID, chapterID: chapterID,
            ordinal: 1, locatorKey: "0/1"
        )

        let repository = GRDBReaderStudyDeckRepository(
            database: fixture.database
        )
        // 无 occurrence → 空分母 → resolvedCoverage nil（不落 0%）。
        var result = try await repository.documentCoverageResult(
            forDocument: documentID
        )
        XCTAssertEqual(result?.resolvedUnique, 0)
        XCTAssertNil(result?.resolvedCoverage ?? nil)

        // 两个已解析 unit（一个 link → learning，一个 tooEasy →
        // mastered）+ 一条 pending + 一条 OOV，都落在块0 →
        // analyzedBlocks = 1 < totalBlocks = 2 → partial。
        let deckID = try await fixture.addDeck()
        let unitLearning = try await fixture.makeUnit()
        let noteID = try await fixture.addNote(deckID: deckID)
        try await fixture.link(
            noteID: noteID, to: unitLearning, role: .primary
        )
        let unitMastered = try await fixture.makeUnit()
        try await fixture.setTooEasy(unitID: unitMastered, value: true)

        try await fixture.addOccurrence(
            documentID: documentID, blockOrdinal: 0,
            unitID: unitLearning, status: "aiResolved"
        )
        try await fixture.addOccurrence(
            documentID: documentID, blockOrdinal: 0,
            unitID: unitMastered, status: "userConfirmed"
        )
        try await fixture.addOccurrence(
            documentID: documentID, blockOrdinal: 0,
            unitID: nil, status: "pending"
        )
        try await fixture.addOccurrence(
            documentID: documentID, blockOrdinal: 0,
            unitID: nil, status: "unresolved"
        )

        result = try await repository.documentCoverageResult(
            forDocument: documentID
        )
        XCTAssertEqual(result?.resolvedUnique, 2)
        XCTAssertEqual(result?.learningUnique, 1)
        XCTAssertEqual(result?.masteredUnique, 1)
        XCTAssertEqual(result?.pendingOccurrences, 1)
        XCTAssertEqual(result?.oovOccurrences, 1)
        XCTAssertEqual(result?.analyzedBlocks, 1)
        XCTAssertEqual(result?.totalBlocks, 2)
        XCTAssertEqual(result?.isPartial, true)
        XCTAssertEqual(
            result?.resolvedCoverage ?? -1, 1, accuracy: 1e-9,
            "(learning + mastered) / resolved = (1+1)/2"
        )

        // tooEasy 撤销 → mastered 回 unknown（无 link）→ 覆盖 0.5。
        try await fixture.setTooEasy(unitID: unitMastered, value: false)
        result = try await repository.documentCoverageResult(
            forDocument: documentID
        )
        XCTAssertEqual(result?.resolvedCoverage ?? -1, 0.5, accuracy: 1e-9)

        // 不存在的文档 → nil（「文档消失」与「未分析」分开）。
        let missingResult = try await repository.documentCoverageResult(
            forDocument: UUID()
        )
        XCTAssertNil(missingResult)
    }

    /// 观察流发射后（occurrence 变更是 rowid 写）覆盖率投影
    /// 立即反映——订阅方收到 ping 后重投影即得新值。
    func testOccurrenceWriteEmitsAndProjectionFollows() async throws {
        let fixture = try await ObservationFixture.make()
        defer { fixture.remove() }
        let documentID = try await fixture.addDocument(title: "再読")
        let chapterID = try await fixture.addChapter(
            documentID: documentID, ordinal: 0
        )
        try await fixture.addBlock(
            documentID: documentID, chapterID: chapterID,
            ordinal: 0, locatorKey: "0/0"
        )
        let deckID = try await fixture.addDeck()
        let unitID = try await fixture.makeUnit()
        let noteID = try await fixture.addNote(deckID: deckID)
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let collector = UpdateCollector()
        let task = collect(repository.observeProgress(), into: collector)
        defer { task.cancel() }
        try await waitUntil { await collector.count >= 1 }
        let initialOccurrences = await collector.latest?
            .knowledgeFingerprint.occurrenceCount
        XCTAssertEqual(initialOccurrences, 0)

        try await fixture.addOccurrence(
            documentID: documentID, blockOrdinal: 0,
            unitID: unitID, status: "aiResolved"
        )
        try await waitUntil {
            await collector.latest?.knowledgeFingerprint
                .occurrenceCount == 1
        }

        let coverage = try await GRDBReaderStudyDeckRepository(
            database: fixture.database
        ).documentCoverageResult(forDocument: documentID)
        XCTAssertEqual(coverage?.resolvedCoverage ?? -1, 1, accuracy: 1e-9)
    }

    // MARK: - 收集工具

    private actor UpdateCollector {
        private(set) var updates: [LearningProgressUpdate] = []
        var count: Int { updates.count }
        var latest: LearningProgressUpdate? { updates.last }
        func append(_ update: LearningProgressUpdate) {
            updates.append(update)
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<LearningProgressUpdate, Error>,
        into collector: UpdateCollector
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await update in stream {
                    await collector.append(update)
                }
            } catch {
                // 测试生命周期内不期望错误； fixture 拆除即终。
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待条件超时", file: file, line: line)
    }
}

// MARK: - 观察夹具

/// observeProgress 夹具：v1–v26 全量迁移；deck/note/note_decks/
/// cards + unit/link/flag 正路 + reader_documents/chapters/blocks/
/// occurrences 最小行。
private final class ObservationFixture: @unchecked Sendable {
    let directoryURL: URL
    let database: OboeDatabase
    let profileID: UUID
    private var sequence = 0

    private init(
        directoryURL: URL,
        database: OboeDatabase,
        profileID: UUID
    ) {
        self.directoryURL = directoryURL
        self.database = database
        self.profileID = profileID
    }

    static func make() async throws -> ObservationFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Oboe-Observe-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        let profileID = UUID()
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json, desired_retention,
                        max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters,
                    profile.targetRetention,
                    profile.maximumIntervalDays
                ]
            )
        }
        return ObservationFixture(
            directoryURL: directoryURL,
            database: database,
            profileID: profileID
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func addDeck(sortOrder: Int = 0) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, ?, ?, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    "Deck \(sortOrder)",
                    sortOrder
                ]
            )
        }
        return id
    }

    func deleteDeck(_ deckID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM decks WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
    }

    func addNote(
        deckID: UUID,
        kind: String = "vocabulary"
    ) async throws -> UUID {
        sequence += 1
        let id = UUID()
        let meaning: String? = kind == "sentence" ? nil : "含义 \(sequence)"
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID),
                    kind,
                    "词 \(sequence)",
                    meaning,
                    sequence,
                    sequence
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                    VALUES (?, ?, 1)
                    ON CONFLICT(note_id, deck_id) DO NOTHING
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID)
                ]
            )
        }
        return id
    }

    /// 显式成员关系：与生产写路径同一纪律——同事务内顺手更新
    /// `notes.updated_at_ms`（WITHOUT ROWID 表本身不触发 SQLite
    /// 更新钩子，rowid 伴随写是观察链路的约定触发点）。
    func addMembership(noteID: UUID, deckID: UUID) async throws {
        try await database.pool.write { db in
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
            try db.execute(
                sql: "UPDATE notes SET updated_at_ms = updated_at_ms + 1 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
    }

    @discardableResult
    func addCard(
        noteID: UUID,
        template: CardTemplateKind,
        isEnabled: Bool = true,
        stability: Double
    ) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, ?, 0, 1, ?, 5, 1, 0, 1, 1, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    isEnabled,
                    stability,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return id
    }

    func setCardStability(_ cardID: UUID, _ stability: Double) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET stability = ? WHERE id = ?",
                arguments: [stability, DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    func makeUnit() async throws -> UUID {
        try await database.pool.write { db in
            try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .localNote,
                identityKey: "local:\(UUID().uuidString)",
                lemma: "词",
                reading: nil,
                atMilliseconds: 1,
                in: db
            ).id
        }
    }

    func link(
        noteID: UUID,
        to unitID: UUID,
        role: LearningUnitNoteLinkRole
    ) async throws {
        try await database.pool.write { db in
            _ = try GRDBLearningUnitRepository.linkNote(
                unitID: unitID,
                noteID: noteID,
                role: role,
                origin: .manual,
                atMilliseconds: 1,
                in: db
            )
        }
    }

    func setTooEasy(unitID: UUID, value: Bool) async throws {
        try await database.pool.write { db in
            let current = try GRDBLearningUnitRepository
                .fetchFlag(unitID: unitID, in: db)
            _ = try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: unitID,
                value: value,
                expectedRevision: current?.revision ?? 0,
                operationID: UUID(),
                atMilliseconds: 2,
                in: db
            )
        }
    }

    // MARK: - Reader 行

    func addDocument(title: String) async throws -> UUID {
        let id = UUID()
        let hash = String(repeating: "a", count: 64)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_documents(
                        id, title, format, created_at_ms,
                        source_sha256, canonical_text_hash,
                        parser_version, content_revision,
                        progress_basis_points, availability
                    ) VALUES (?, ?, 'txt', 1, ?, ?, 'test', 1, 0, 'available')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    title,
                    hash,
                    "canonical-\(id.uuidString)"
                ]
            )
        }
        return id
    }

    func deleteDocument(_ documentID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(documentID)]
            )
        }
    }

    func addChapter(
        documentID: UUID, ordinal: Int
    ) async throws -> UUID {
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_chapters(
                        id, document_id, ordinal, canonical_hash,
                        text_utf16_length
                    ) VALUES (?, ?, ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(documentID),
                    ordinal,
                    "chapter-\(ordinal)-\(id.uuidString)"
                ]
            )
        }
        return id
    }

    /// `locator_json` 需含 `chapterOrdinal`/`blockOrdinal`——coverage
    /// 投影按这两个键给块去重计数。
    func addBlock(
        documentID: UUID,
        chapterID: UUID,
        ordinal: Int,
        locatorKey: String
    ) async throws {
        let locator = """
            {"chapterOrdinal":0,"blockOrdinal":\(ordinal)}
            """
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_blocks(
                        id, document_id, chapter_id, ordinal, text,
                        text_hash, locator_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID),
                    DatabaseValueCodec.encode(chapterID),
                    ordinal,
                    "本文 \(ordinal)",
                    "hash-\(locatorKey)",
                    locator
                ]
            )
        }
    }

    /// occurrence：locator_json 里的 chapterOrdinal/blockOrdinal 与
    /// 块一致，distinct 块计数命中块0。
    func addOccurrence(
        documentID: UUID,
        blockOrdinal: Int,
        unitID: UUID?,
        status: String
    ) async throws {
        let locator = """
            {"chapterOrdinal":0,"blockOrdinal":\(blockOrdinal)}
            """
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reader_study_occurrences(
                        id, document_id, content_revision, locator_json,
                        block_source_hash, tokenizer_version,
                        start_utf16, length_utf16, unit_id,
                        resolution_status
                    ) VALUES (?, ?, 1, ?, 'blockhash', 'test-tok', ?, 2, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID),
                    locator,
                    Int.random(in: 0...1000),
                    unitID.map(DatabaseValueCodec.encode),
                    status
                ]
            )
        }
    }
}
