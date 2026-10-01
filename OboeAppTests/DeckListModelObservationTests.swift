import Foundation
import GRDB
import OboeDomain
import OboeInfrastructure
import XCTest
@testable import Oboe

/// S18 DeckListModel 观察集成测试：真库驱动——评分写、成员增删、
/// 牌组删除都经共享观察流（`LearningProgressProviding.observeProgress`）
/// 推入 model，断言 progressByDeck/contentSignature/studyDeckLinks
/// 无需重建 model 即同步。卡片 stability 更新即「评级落库」的最小
/// 形态（评分写路径 = cards UPDATE + review_logs INSERT，两张表都
/// 在跟踪区域）。
@MainActor
final class DeckListModelObservationTests: XCTestCase {

    func testRefreshFailurePreservesLoadedDecksAndReportsFailure() async throws {
        let fixture = try await AppObservationFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let model = fixture.makeModel()
        let loaded = await model.refreshDecks()
        XCTAssertTrue(loaded)
        XCTAssertTrue(model.decks.contains { $0.id == deckID })
        try fixture.database.close()
        let refreshed = await model.refreshDecks()
        XCTAssertFalse(refreshed, "读取失败不能被页面当成成功后缺失")
        XCTAssertNotNil(model.deckLoadErrorMessage)
        XCTAssertTrue(model.decks.contains { $0.id == deckID }, "保留此前成功快照")
    }

    func testSuccessfulRefreshCanConfirmActualDeckDeletion() async throws {
        let fixture = try await AppObservationFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let model = fixture.makeModel()
        let loaded = await model.refreshDecks()
        XCTAssertTrue(loaded)
        let deleted = await model.deleteEmptyDeck(id: deckID)
        XCTAssertTrue(deleted)
        XCTAssertFalse(model.decks.contains { $0.id == deckID })
        XCTAssertNil(model.deckLoadErrorMessage)
    }

    /// 同一 unit 的成员写进第二个牌组后，两 deck 在评级写后同步
    /// 刷新进度——跨窗口/跨表面写共享同一 pool 就是这条路径。
    func testMembershipAndRatingRefreshAllDecks() async throws {
        let fixture = try await AppObservationFixture.make()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let deckA = try await fixture.addDeck()
        let deckB = try await fixture.addDeck(sortOrder: 1)
        let noteID = try await fixture.addNote(deckID: deckA)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID)
        let cardID = try await fixture.addCard(noteID: noteID, stability: 0)

        model.startObserving()
        try await waitUntil { model.decks.count == 2 }
        try await waitUntil { model.progressByDeck[deckA] != nil }
        let initialProgress = model.progressByDeck[deckA]?.progress
        XCTAssertEqual(initialProgress, 0)
        let deckBUnits = model.progressByDeck[deckB]?.unitCount
        XCTAssertEqual(deckBUnits, 0)
        let signatureBaseline = model.contentSignature

        // 成员写：note 同时进入 deckB——同 unit 跨 deck 共享全局进度。
        try await fixture.addMembership(noteID: noteID, deckID: deckB)
        try await waitUntil {
            model.progressByDeck[deckB]?.unitCount == 1
        }

        // 评级落库（stability 0→30 → cardProgress 0→1）：两个牌组
        // 的行级进度同步收敛到 1，不重建 model 不重开页面。
        try await fixture.setCardStability(cardID, 30)
        try await waitUntil {
            model.progressByDeck[deckA]?.progress == 1
                && model.progressByDeck[deckB]?.progress == 1
        }
        XCTAssertGreaterThan(model.contentSignature, signatureBaseline)
    }

    /// 牌组删除：观察流发射把 progressByDeck 条目移除、decks 列表
    /// 收敛——「牌组已不存在」与空态各自正确，不留陈旧键。
    func testDeckDeletionDropsProgressEntry() async throws {
        let fixture = try await AppObservationFixture.make()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let deckID = try await fixture.addDeck()

        model.startObserving()
        try await waitUntil { model.decks.count == 1 }
        try await waitUntil { model.progressByDeck[deckID] != nil }

        let deleted = await model.deleteEmptyDeck(id: deckID)
        XCTAssertTrue(deleted)
        try await waitUntil { model.decks.isEmpty }
        try await waitUntil { model.progressByDeck[deckID] == nil }
    }

    /// 空牌组：progress = nil（UI 显示「—」）、unitCount = 0——
    /// 不崩溃、不虚报 0%。
    func testEmptyDeckReportsNilProgress() async throws {
        let fixture = try await AppObservationFixture.make()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let deckID = try await fixture.addDeck()

        model.startObserving()
        try await waitUntil { model.progressByDeck[deckID] != nil }

        let progress = model.progressByDeck[deckID]
        XCTAssertEqual(progress?.unitCount, 0)
        XCTAssertNil(progress?.progress ?? nil)
        XCTAssertFalse(progress?.hasEnabledVocabularyCards ?? true)
    }

    /// Reader ↔ Deck 绑定面：绑定后 studyDeckLinks 出现，
    /// `studyDeckLink(for:)` 反查命中——Deck 详情「打开文档」的数据源。
    func testStudyDeckBindingFlowsIntoModel() async throws {
        let fixture = try await AppObservationFixture.make()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let documentID = try await fixture.addDocument(title: "読書")

        model.startObserving()
        try await waitUntil { !model.decks.isEmpty || model.isLoading == false }
        try await waitUntil { model.studyDeckLinks.isEmpty }

        let boundDeck = try await GRDBReaderStudyDeckRepository(
            database: fixture.database
        ).ensureStudyDeck(forDocument: documentID)
        try await waitUntil { model.studyDeckLinks.count == 1 }
        XCTAssertEqual(
            model.studyDeckLink(for: boundDeck)?.documentID, documentID
        )
    }

    // MARK: - 工具

    private func waitUntil(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待条件超时", file: file, line: line)
    }
}

// MARK: - 夹具

/// 真库夹具：v1–v26 全量迁移 + 最小 scheduler_profile + 正路
/// unit/link 写。只覆盖 app 测试所需行——occurrence/flag 链路在
/// 包级 LearningProgressObservationTests 已钉死。
private final class AppObservationFixture: @unchecked Sendable {
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

    static func make() async throws -> AppObservationFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Oboe-AppObserve-\(UUID().uuidString)",
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
        return AppObservationFixture(
            directoryURL: directoryURL,
            database: database,
            profileID: profileID
        )
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    @MainActor
    func makeModel() -> DeckListModel {
        DeckListModel(
            service: DeckManagementService(
                repository: GRDBDeckRepository(database: database)
            ),
            studyService: AppFeatureContainerFactory
                .makeStudySessionService(database: database),
            historyService: StudyHistoryService(
                repository: GRDBStudyHistoryRepository(database: database)
            ),
            learningProgress: GRDBLearningProgressRepository(
                database: database
            ),
            studyDecks: GRDBReaderStudyDeckRepository(database: database)
        )
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

    func addNote(deckID: UUID) async throws -> UUID {
        sequence += 1
        let id = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deckID),
                    "词 \(sequence)",
                    "含义 \(sequence)",
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

    /// 与生产写路径同一纪律：note_decks（WITHOUT ROWID）+ 同事务
    /// notes 行更新作 rowid 伴随触发。
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
                    ) VALUES (?, ?, ?, 1, 0, 1, ?, 5, 1, 0, 1, 1, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(noteID),
                    CardTemplateKind.vocabularyJapaneseToChinese.rawValue,
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

    func link(noteID: UUID, to unitID: UUID) async throws {
        try await database.pool.write { db in
            _ = try GRDBLearningUnitRepository.linkNote(
                unitID: unitID,
                noteID: noteID,
                role: .primary,
                origin: .manual,
                atMilliseconds: 1,
                in: db
            )
        }
    }

    func addDocument(title: String) async throws -> UUID {
        let id = UUID()
        let hash = String(repeating: "b", count: 64)
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
}
