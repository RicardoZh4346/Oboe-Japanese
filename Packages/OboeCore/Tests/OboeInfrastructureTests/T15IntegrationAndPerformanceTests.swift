import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T15（设计 §10.5）：v0.5 全链路集成与性能回归。
///
/// - 链 A：新建双牌组词 → 三方向 → 今日 admission → 学习评分（含
///   eventID 幂等）→ 修改 membership → 导出 → 恢复，全程只走 App 使用
///   的真实服务，回归任一环即断链。
/// - 链 B：旧（v1）词库导入 → 词库升级 v2 → enrichment 只补 NULL →
///   用户编辑保护。
/// - 性能门控：10k Note / 30k Card / 平均 2.5 membership / 100k
///   review logs 上验证队列去重、首页/牌组/搜索预算与
///   `note_decks_on_deck_note` 索引使用。默认跳过，设
///   `OBOE_RUN_T15_PERFORMANCE=1` 执行（与 P22b 同约定）。
final class T15IntegrationAndPerformanceTests: XCTestCase {

    // MARK: - 链 A：多牌组词汇全链路

    func testMultiDeckVocabularyFullChain() async throws {
        let fixture = try await MultiDeckDatabaseFixture.make()
        defer { fixture.remove() }
        let now = MultiDeckDatabaseFixture.baseDate
        let timeZoneID = MultiDeckDatabaseFixture.timeZoneID

        let contentCards = GRDBContentCardRepository(database: fixture.database)
        let knowledge = GRDBKnowledgePointRepository(database: fixture.database)
        let planning = GRDBStudyDayPlanningRepository(database: fixture.database)
        let queue = GRDBTodayQueueRepository(database: fixture.database)

        // ── 1) 新建双牌组词（三方向 + 音调）─────────────────────────
        let commit = VocabularyContentCommit(
            noteID: UUID(),
            exampleID: UUID(),
            draftID: nil,
            deckID: fixture.deckAID,
            content: ValidatedVocabularyContent(
                headword: "共有語",
                reading: "きょうゆうご",
                meaningZH: "共享词",
                partOfSpeech: "名词",
                jlpt: nil,
                example: VocabularyExampleContent(
                    japanese: "共有語を使う。",
                    translationZH: "使用共享词。"
                ),
                notes: nil,
                pitchAccent: PitchAccent(rawValue: 3)
            ),
            tags: [],
            cards: [
                NewCardSeed(id: UUID(), templateKind: .vocabularyJapaneseToChinese),
                NewCardSeed(id: UUID(), templateKind: .vocabularyChineseToJapanese),
                NewCardSeed(id: UUID(), templateKind: .vocabularyListening)
            ],
            schedulerProfileID: fixture.profileID,
            createdAt: now,
            deckIDs: [fixture.deckAID, fixture.deckBID]
        )
        let commitResult = try await contentCards.commitVocabulary(commit, capture: nil)
        XCTAssertTrue(commitResult.wasCreated)

        // 两处可见同一 Note；membership = {A,B}，home=A。
        let membership = try await knowledge.fetchDeckMembership(noteID: commit.noteID)
        XCTAssertEqual(membership?.homeDeckID, fixture.deckAID)
        XCTAssertEqual(membership?.deckIDs, [fixture.deckAID, fixture.deckBID])
        let deckA = try await knowledge.fetchKnowledgePointSummaries(deckID: fixture.deckAID)
        let deckB = try await knowledge.fetchKnowledgePointSummaries(deckID: fixture.deckBID)
        XCTAssertTrue(deckA.contains { $0.id == commit.noteID })
        XCTAssertTrue(deckB.contains { $0.id == commit.noteID })
        // 复习内容层看到同一 Card 携带完整成员集合。
        let reviewContent = try await GRDBReviewCardContentRepository(
            database: fixture.database
        ).fetchReviewCardContent(cardID: commit.cards[0].id)
        XCTAssertEqual(reviewContent?.deckIDs, [fixture.deckAID, fixture.deckBID])

        // ── 2) 今日 admission：一个 Note 占一个新词额度，三方向成组 ──
        let fetchedDay = try await planning.fetchStudyDay(containing: now)
        let studyDay = try XCTUnwrap(fetchedDay)
        _ = try await planning.persistAndReconcileNewCards(studyDay, at: now)
        let plan = try await queue.buildQueue(for: studyDay, at: now)
        let allItems = plan.availableNow + plan.availableLater
        XCTAssertEqual(
            Set(allItems.map(\.cardID)).count, allItems.count,
            "全局队列按 cardID 唯一——多牌组不产生重复"
        )
        let newNoteItems = allItems.filter { $0.noteID == commit.noteID }
        XCTAssertEqual(Set(newNoteItems.map(\.cardID)), Set(commit.cards.map(\.id)))
        for item in newNoteItems {
            XCTAssertEqual(item.deckIDs, [fixture.deckAID, fixture.deckBID])
        }
        // 牌组 B 过滤队列同样不重复。
        let deckBSummary = try await queue.fetchSummary(
            for: studyDay, deckID: fixture.deckBID, at: now
        )
        XCTAssertEqual(deckBSummary.newCount, 3) // shared + exclusive + 新词

        // ── 3) 学习评分：成员 scope 归因 + eventID 幂等 ─────────────
        let submissions = GRDBReviewSubmissionRepository(database: fixture.database)
        let session = StudySessionService(
            studyDayRepository: planning,
            queueRepository: queue,
            contentRepository: GRDBReviewCardContentRepository(database: fixture.database),
            submissionRepository: submissions,
            undoRepository: submissions,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: T15FixedClock(value: now)
        )
        let ratedCard = commit.cards[1].id // 中→日方向
        let loaded = try await session.loadReviewCard(cardID: ratedCard)
        let eventID = UUID()
        let log = try await session.submit(
            card: loaded,
            rating: .good,
            studyDay: plan.studyDay,
            eventID: eventID,
            durationMilliseconds: 800,
            scopeDeckID: fixture.deckBID
        )
        XCTAssertEqual(log.deckIDAtReview, fixture.deckBID)
        let duplicate = try await session.submit(
            card: loaded,
            rating: .easy,
            studyDay: plan.studyDay,
            eventID: eventID,
            durationMilliseconds: 800,
            scopeDeckID: fixture.deckAID
        )
        XCTAssertEqual(duplicate.id, log.id, "重复 eventID 幂等返回同一日志")
        let noteLogCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_logs WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(commit.noteID)]
            )
        }
        XCTAssertEqual(noteLogCount, 1)

        // ── 4) 修改 membership：{A,B}→{B}，home 改 B；卡与日志不动 ──
        let updated = try await knowledge.replaceDeckMembership(
            noteID: commit.noteID,
            deckIDs: [fixture.deckBID],
            homeDeckID: fixture.deckBID,
            at: now.addingTimeInterval(60)
        )
        XCTAssertEqual(updated.deckIDs, [fixture.deckBID])
        XCTAssertEqual(updated.homeDeckID, fixture.deckBID)
        let cardCount = try await fixture.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM cards WHERE note_id = ?",
                arguments: [DatabaseValueCodec.encode(commit.noteID)]
            )
        }
        XCTAssertEqual(cardCount, 3)
        let persistedLog = try await submissions.fetchSubmittedReview(eventID: eventID)
        XCTAssertEqual(persistedLog?.deckIDAtReview, fixture.deckBID)

        // ── 5) 导出 → 恢复 → 恢复库上重算 ───────────────────────────
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-T15Chain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let export = try await PortableBackupExporter(
            database: fixture.database,
            workingDirectoryURL: root.appendingPathComponent("exports", isDirectory: true)
        ).export(appVersion: "test", at: now)
        let current = try OboeDatabase(
            path: root.appendingPathComponent("current.sqlite").path
        )
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: root.appendingPathComponent("preparations", isDirectory: true)
        )
        let prepared = try await preparer.prepare(fileURL: export.url)
        defer {
            Task { try? await preparer.discard(prepared) }
            try? current.close()
        }

        let restored = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        defer { try? restored.close() }
        let restoredKnowledge = GRDBKnowledgePointRepository(database: restored)

        // membership 收缩结果与 home 变化随备份恢复。
        let restoredMembership = try await restoredKnowledge.fetchDeckMembership(
            noteID: commit.noteID
        )
        XCTAssertEqual(restoredMembership?.deckIDs, [fixture.deckBID])
        XCTAssertEqual(restoredMembership?.homeDeckID, fixture.deckBID)

        // 同一 Note 同一组 Card ID、同一 FSRS 状态、同一历史。
        let restoredNote = try await GRDBVocabularyRepository(database: restored)
            .fetchVocabulary(id: commit.noteID)
        XCTAssertEqual(restoredNote?.deckIDs, [fixture.deckBID])
        XCTAssertEqual(restoredNote?.pitchAccent, PitchAccent(rawValue: 3))
        let restoredCards = try await restored.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, state, state_version FROM cards
                    WHERE note_id = ? ORDER BY template_kind
                    """,
                arguments: [DatabaseValueCodec.encode(commit.noteID)]
            ).map { row in
                (
                    id: try DatabaseValueCodec.decodeUUID(row["id"] as String),
                    state: row["state"] as Int,
                    stateVersion: row["state_version"] as Int
                )
            }
        }
        XCTAssertEqual(
            Set(restoredCards.map(\.id)),
            Set(commit.cards.map(\.id))
        )
        XCTAssertEqual(
            restoredCards.first { $0.id == ratedCard }?.state,
            SchedulingState.learning.rawValue
        )
        let restoredLogCount = try await restored.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM review_logs
                    WHERE note_id = ? AND event_id = ? AND undone_at_ms IS NULL
                    """,
                arguments: [
                    DatabaseValueCodec.encode(commit.noteID),
                    DatabaseValueCodec.encode(eventID)
                ]
            )
        }
        XCTAssertEqual(restoredLogCount, 1)

        // 恢复库上今日队列依旧无重复；该 Note 只在 B 可见。
        let restoredFetchedDay = try await GRDBStudyDayPlanningRepository(database: restored)
            .fetchStudyDay(containing: now)
        let restoredDay = try XCTUnwrap(restoredFetchedDay)
        let restoredPlan = try await GRDBTodayQueueRepository(database: restored)
            .buildQueue(for: restoredDay, at: now)
        let restoredItems = restoredPlan.availableNow + restoredPlan.availableLater
        XCTAssertEqual(
            Set(restoredItems.map(\.cardID)).count, restoredItems.count
        )
        let restoredDeckA = try await restoredKnowledge
            .fetchKnowledgePointSummaries(deckID: fixture.deckAID)
        let restoredDeckB = try await restoredKnowledge
            .fetchKnowledgePointSummaries(deckID: fixture.deckBID)
        XCTAssertFalse(restoredDeckA.contains { $0.id == commit.noteID })
        XCTAssertTrue(restoredDeckB.contains { $0.id == commit.noteID })
    }

    // MARK: - 链 B：旧 JLPT 导入 → 词库升级 → enrichment → 编辑保护

    func testLegacyJLPTImportUpgradeEnrichmentProtectsUserEdits() async throws {
        let location = try T15LibraryLocation()
        defer { location.remove() }
        let database = try OboeDatabase(path: location.userDatabaseURL.path)
        defer { try? database.close() }
        let deckID = try await makeDeck(in: database)

        // ── 1) 旧版（v1）词库导入：无音调/中文翻译列 ────────────────
        try makeLibraryV1(at: location.libraryURL)
        let legacyRepository = try GRDBJLPTLibraryRepository(
            databaseURL: location.libraryURL
        )
        XCTAssertFalse(legacyRepository.offersEnrichmentData)
        let importer = GRDBJLPTImporter(database: database)
        for ref in ["openjlpt:N5:000001", "openjlpt:N5:000002", "openjlpt:N5:000003"] {
            let row = try await legacyRepository.vocabulary(id: ref)
            let entry = try XCTUnwrap(row)
            let result = try await importer.importVocabulary(
                entry,
                deckID: deckID,
                meaningZH: entry.meaningZH ?? "义",
                directions: [.japaneseToChinese]
            )
            XCTAssertEqual(result.imported, 1)
        }
        let blankState = try await jlptPitchAndTranslations(in: database)
        XCTAssertEqual(blankState.pitchByRef.count, 0)
        XCTAssertEqual(blankState.translations.count, 0)

        // ── 2) 用户在升级前部分编辑，制造"候选但含用户值"的行 ────────
        // 走与详情页相同的 updateVocabulary 路径，非直接改 SQL：
        // 学校只填音调（例句翻译仍 NULL）、水只填例句译文（音调仍 NULL），
        // 两条都仍是候选，enrichment 必须只补另一侧的 NULL。
        let vocabulary = GRDBVocabularyRepository(database: database)
        let schoolIDRaw = try await importedNoteID(
            sourceRef: "openjlpt:N5:000002", in: database
        )
        let schoolID = try XCTUnwrap(schoolIDRaw)
        let schoolNote = try await vocabulary.fetchVocabulary(id: schoolID)
        let school = try XCTUnwrap(schoolNote)
        let editedSchool = try await vocabulary.updateVocabulary(
            id: schoolID,
            content: ValidatedVocabularyContent(
                headword: school.headword,
                reading: school.reading,
                meaningZH: school.meaningZH,
                partOfSpeech: school.partOfSpeech,
                jlpt: school.jlpt,
                example: VocabularyExampleContent(
                    japanese: school.examples.first?.japanese ?? "学校へ行く。",
                    translationZH: nil
                ),
                notes: school.notes,
                pitchAccent: PitchAccent(rawValue: 4)
            ),
            newExampleID: UUID(),
            at: Date()
        )
        XCTAssertEqual(editedSchool?.pitchAccent, PitchAccent(rawValue: 4))

        let waterIDRaw = try await importedNoteID(
            sourceRef: "openjlpt:N5:000003", in: database
        )
        let waterID = try XCTUnwrap(waterIDRaw)
        let waterNote = try await vocabulary.fetchVocabulary(id: waterID)
        let water = try XCTUnwrap(waterNote)
        let editedWater = try await vocabulary.updateVocabulary(
            id: waterID,
            content: ValidatedVocabularyContent(
                headword: water.headword,
                reading: water.reading,
                meaningZH: water.meaningZH,
                partOfSpeech: water.partOfSpeech,
                jlpt: water.jlpt,
                example: VocabularyExampleContent(
                    japanese: water.examples.first?.japanese ?? "水を飲む。",
                    translationZH: "用户自己的译文"
                ),
                notes: water.notes,
                pitchAccent: nil
            ),
            newExampleID: UUID(),
            at: Date()
        )
        XCTAssertNil(editedWater?.pitchAccent)

        // ── 3) 词库升级到 schema v2（同 id，新增音调/翻译数据）────────
        try makeLibraryV2(at: location.libraryURL)
        let upgradedRepository = try GRDBJLPTLibraryRepository(
            databaseURL: location.libraryURL
        )
        XCTAssertTrue(upgradedRepository.offersEnrichmentData)

        // ── 4) enrichment：只补 NULL，用户值原样保留 ─────────────────
        let service = JLPTLibraryEnrichmentService(
            source: upgradedRepository,
            store: GRDBJLPTEnrichmentRepository(database: database)
        )
        let report = try await service.enrich()
        XCTAssertEqual(report.candidateCount, 3)
        XCTAssertEqual(report.pitchFilled, 2)   // 000001、000003；000002 用户值保留
        XCTAssertEqual(report.examplesFilled, 2) // 000001、000002；000003 用户译文保留

        let state = try await jlptPitchAndTranslations(in: database)
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000001"], 2)
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000002"], 4, "用户音调不被覆盖")
        XCTAssertEqual(state.pitchByRef["openjlpt:N5:000003"], 0)
        XCTAssertEqual(state.translations["openjlpt:N5:000001"], "吃饭。")
        XCTAssertEqual(state.translations["openjlpt:N5:000002"], "去学校。")
        XCTAssertEqual(
            state.translations["openjlpt:N5:000003"], "用户自己的译文",
            "用户例句译文不被覆盖"
        )

        // 幂等：重跑零写入。
        let second = try await service.enrich()
        XCTAssertEqual(second.pitchFilled, 0)
        XCTAssertEqual(second.examplesFilled, 0)
    }

    // MARK: - 性能门控（OBOE_RUN_T15_PERFORMANCE=1）

    func testMultiDeckDatasetPerformanceGate() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OBOE_RUN_T15_PERFORMANCE"] == "1",
            "Set OBOE_RUN_T15_PERFORMANCE=1 for the T15 performance gate."
        )
        let fixture = try T15PerformanceFixture()
        defer { fixture.remove() }
        try await fixture.seed()

        let counts = try await fixture.counts()
        XCTAssertEqual(counts.notes, 10_000)
        XCTAssertEqual(counts.cards, 30_000)
        XCTAssertEqual(counts.memberships, 25_000) // 平均 2.5/Note
        XCTAssertEqual(counts.reviewLogs, 100_000)
        print("T15_DATASET=notes:\(counts.notes),cards:\(counts.cards),memberships:\(counts.memberships),review_logs:\(counts.reviewLogs)")

        let database = try OboeDatabase(path: fixture.databaseURL.path)
        defer { try? database.close() }
        let session = fixture.makeStudySessionService(database: database)
        let queue = GRDBTodayQueueRepository(database: database)
        let history = GRDBStudyHistoryRepository(database: database)
        let decks = GRDBDeckRepository(database: database)
        let knowledge = GRDBKnowledgePointRepository(database: database)

        // 今日计划去重：全局与逐牌组均不得因 membership 产生重复。
        let plan = try await session.buildTodayPlan(
            defaultTimeZoneID: fixture.timeZoneID
        )
        let allItems = plan.availableNow + plan.availableLater
        XCTAssertEqual(
            Set(allItems.map(\.cardID)).count, allItems.count,
            "全局今日队列 cardID 必须唯一"
        )
        for deckID in fixture.deckIDs {
            let scoped = try await queue.fetchSummary(
                for: plan.studyDay, deckID: deckID, at: fixture.now
            )
            XCTAssertGreaterThan(scoped.reviewCount + scoped.newCount, 0)
        }

        // 首页暖查询 p95 ≤ 300ms（设计 §10.5）。
        let homeP95 = try await t15Percentile95(samples: 20) {
            let warm = try await session.buildTodayPlan(
                defaultTimeZoneID: fixture.timeZoneID
            )
            async let deckSummaries = decks.fetchDeckSummaries()
            async let statistics = history.fetchTodayStatistics(
                studyDayID: warm.studyDay.id
            )
            _ = try await (deckSummaries, statistics)
        }
        t15PrintMetric("T15_HOME_QUERY_P95_MS", homeP95)
        XCTAssertLessThan(homeP95, 0.3)

        // 牌组详情首屏 ≤ 500ms：最大牌组的成员列表（批量装载成员集合，
        // 不允许 N+1——结果必须带完整 deckIDs）。
        let busiestDeck = fixture.deckIDs[0]
        _ = try await knowledge.fetchKnowledgePointSummaries(deckID: busiestDeck)
        let deckP95 = try await t15Percentile95(samples: 20) {
            let summaries = try await knowledge.fetchKnowledgePointSummaries(
                deckID: busiestDeck
            )
            XCTAssertFalse(summaries.isEmpty)
            XCTAssertTrue(summaries.allSatisfy { !$0.deckIDs.isEmpty })
        }
        t15PrintMetric("T15_DECK_DETAIL_P95_MS", deckP95)
        XCTAssertLessThan(deckP95, 0.5)

        // 全局搜索：成员集合批量回填（结果带完整 deckIDs 集合）。
        let search = GRDBKnowledgeSearchRepository(database: database)
        _ = try await search.search(
            normalizedQuery: "预热", deckID: nil, limit: 20, offset: 0
        )
        var searchHitDeckIDs: Set<UUID> = []
        let searchP95 = try await t15Percentile95(samples: 20) {
            let page = try await search.search(
                normalizedQuery: "唯一目标针", deckID: nil, limit: 20, offset: 0
            )
            XCTAssertEqual(page.items.count, 1)
            searchHitDeckIDs = page.items.first?.deckIDs ?? []
        }
        // 目标词 noteIndex=9999 → 成员数 2（3/3/2/2 交替），须批量装载。
        XCTAssertEqual(searchHitDeckIDs.count, 2)
        t15PrintMetric("T15_SEARCH_P95_MS", searchP95)
        XCTAssertLessThan(searchP95, 0.3)

        // enrichment 候选扫描在 10k Note 上秒级返回（批量路径由 T12
        // 的 8,334 全量用例覆盖吞吐）。
        let enrichmentStore = GRDBJLPTEnrichmentRepository(database: database)
        let scanStart = ContinuousClock.now
        let candidates = try await enrichmentStore.enrichmentCandidates()
        XCTAssertTrue(candidates.isEmpty, "manual 数据集的候选应为空")
        XCTAssertLessThan(t15Seconds(since: scanStart), 1.0)

        // EXPLAIN QUERY PLAN：成员过滤必须走索引。
        let plans = try await fixture.explainMembershipPlans()
        print("T15_QUERY_PLANS=\(plans)")
        XCTAssertTrue(
            plans.memberEnumeration.contains("note_decks_on_deck_note"),
            "牌组成员枚举应使用 note_decks_on_deck_note：\(plans.memberEnumeration)"
        )
        XCTAssertFalse(
            plans.deckFilteredExists.contains("SCAN note_decks"),
            "牌组过滤 EXISTS 不得全表扫描 note_decks：\(plans.deckFilteredExists)"
        )
        XCTAssertTrue(
            plans.deckFilteredExists.contains("SEARCH") ,
            "牌组过滤 EXISTS 应命中索引：\(plans.deckFilteredExists)"
        )
    }

    // MARK: - 链 B 辅助

    private struct T15LibraryLocation {
        let rootURL: URL
        let libraryURL: URL
        let userDatabaseURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "T15IntegrationTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            libraryURL = rootURL.appendingPathComponent("library.sqlite")
            userDatabaseURL = rootURL.appendingPathComponent("user.sqlite")
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    private func makeDeck(in database: OboeDatabase) async throws -> UUID {
        let deckID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '牌组', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
        }
        return deckID
    }

    private func importedNoteID(
        sourceRef: String,
        in database: OboeDatabase
    ) async throws -> UUID? {
        try await database.pool.read { db in
            let raw = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM notes
                    WHERE origin = 'builtin_jlpt' AND source_ref = ?
                    """,
                arguments: [sourceRef]
            )
            return try raw.map(DatabaseValueCodec.decodeUUID)
        }
    }

    /// source_ref → pitch；source_ref → 首条例句翻译（仅非空行）。
    private func jlptPitchAndTranslations(
        in database: OboeDatabase
    ) async throws -> (pitchByRef: [String: Int], translations: [String: String]) {
        try await database.pool.read { db in
            var pitch: [String: Int] = [:]
            var translations: [String: String] = [:]
            let noteRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_ref, pitch_accent FROM notes
                    WHERE origin = 'builtin_jlpt' AND source_ref IS NOT NULL
                    """
            )
            var noteToRef: [String: String] = [:]
            for row in noteRows {
                let ref: String = row["source_ref"]
                noteToRef[row["id"] as String] = ref
                if let value: Int = row["pitch_accent"] {
                    pitch[ref] = value
                }
            }
            let exampleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT note_id, translation_zh FROM examples
                    WHERE translation_zh IS NOT NULL
                    ORDER BY note_id, sort_order
                    """
            )
            for row in exampleRows {
                let noteID: String = row["note_id"]
                guard let ref = noteToRef[noteID] else { continue }
                translations[ref] = row["translation_zh"]
            }
            return (pitch, translations)
        }
    }

    /// 迷你 v1 词库（无 v2 列）：000001 食べる、000002 学校。
    private func makeLibraryV1(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE vocab (
                    id TEXT PRIMARY KEY NOT NULL,
                    level TEXT NOT NULL,
                    headword TEXT NOT NULL,
                    reading TEXT NOT NULL,
                    meaning_zh TEXT,
                    meaning_en_json TEXT NOT NULL,
                    part_of_speech TEXT,
                    frequency_rank INTEGER,
                    normalized_headword TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL,
                    normalized_meaning_zh TEXT,
                    sort_order INTEGER NOT NULL,
                    data_flags INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE vocab_examples (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
                    japanese TEXT NOT NULL,
                    english TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO vocab VALUES
                    ('openjlpt:N5:000001', 'N5', '食べる', 'たべる', '吃',
                     '["to eat"]', '动词', 1, '食べる', 'たべる', '吃', 0, 0),
                    ('openjlpt:N5:000002', 'N5', '学校', 'がっこう', '学校',
                     '["school"]', '名词', 5, '学校', 'がっこう', '学校', 1, 0),
                    ('openjlpt:N5:000003', 'N5', '水', 'みず', '水',
                     '["water"]', '名词', 8, '水', 'みず', '水', 2, 0);
                INSERT INTO vocab_examples VALUES
                    ('ex-1', 'openjlpt:N5:000001', 'ご飯を食べる。', 'Eat a meal.', 0),
                    ('ex-2', 'openjlpt:N5:000002', '学校へ行く。', 'I go to school.', 0),
                    ('ex-3', 'openjlpt:N5:000003', '水を飲む。', 'I drink water.', 0);
                """)
        }
        try queue.close()
    }

    /// 同 id 的 v2 词库：补 pitch_accent 与 translation_zh 列。
    private func makeLibraryV2(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS vocab_examples; DROP TABLE IF EXISTS vocab;")
            try db.execute(sql: """
                CREATE TABLE vocab (
                    id TEXT PRIMARY KEY NOT NULL,
                    level TEXT NOT NULL,
                    headword TEXT NOT NULL,
                    reading TEXT NOT NULL,
                    meaning_zh TEXT,
                    meaning_en_json TEXT NOT NULL,
                    part_of_speech TEXT,
                    pitch_accent INTEGER,
                    pitch_source TEXT,
                    pitch_source_ref TEXT,
                    frequency_rank INTEGER,
                    normalized_headword TEXT NOT NULL,
                    normalized_reading TEXT NOT NULL,
                    normalized_meaning_zh TEXT,
                    sort_order INTEGER NOT NULL,
                    data_flags INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE vocab_examples (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocab_id TEXT NOT NULL REFERENCES vocab(id) ON DELETE CASCADE,
                    japanese TEXT NOT NULL,
                    english TEXT,
                    translation_zh TEXT,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO vocab(
                    id, level, headword, reading, meaning_zh, meaning_en_json,
                    part_of_speech, pitch_accent, pitch_source, pitch_source_ref,
                    frequency_rank, normalized_headword, normalized_reading,
                    normalized_meaning_zh, sort_order, data_flags
                ) VALUES
                    ('openjlpt:N5:000001', 'N5', '食べる', 'たべる', '吃',
                     '["to eat"]', '动词', 2, 'unidic_cwj', 'cwj:taberu',
                     1, '食べる', 'たべる', '吃', 0, 0),
                    ('openjlpt:N5:000002', 'N5', '学校', 'がっこう', '学校',
                     '["school"]', '名词', 0, 'unidic_cwj', 'cwj:gakkou',
                     5, '学校', 'がっこう', '学校', 1, 0),
                    ('openjlpt:N5:000003', 'N5', '水', 'みず', '水',
                     '["water"]', '名词', 0, 'unidic_cwj', 'cwj:mizu',
                     8, '水', 'みず', '水', 2, 0);
                INSERT INTO vocab_examples(
                    id, vocab_id, japanese, english, translation_zh, sort_order
                ) VALUES
                    ('ex-1', 'openjlpt:N5:000001', 'ご飯を食べる。', 'Eat a meal.', '吃饭。', 0),
                    ('ex-2', 'openjlpt:N5:000002', '学校へ行く。', 'I go to school.', '去学校。', 0),
                    ('ex-3', 'openjlpt:N5:000003', '水を飲む。', 'I drink water.', '喝水。', 0);
                """)
        }
        try queue.close()
    }
}

private struct T15FixedClock: SchedulingClock {
    let value: Date
    func now() -> Date { value }
}

// MARK: - 性能夹具（10k Note / 30k Card / 25k membership / 100k logs）

private struct T15PerformanceFixture {
    let directoryURL: URL
    let databaseURL: URL
    let now = Date(timeIntervalSince1970: 1_789_344_000)
    let timeZoneID = "Asia/Shanghai"
    /// 4 个牌组；Note i%4∈{0,1} → 3 个成员、{2,3} → 2 个成员（均值 2.5）。
    let deckIDs = (0..<4).map { t15UUID(1 + $0) }

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "T15PerformanceTests-\(UUID().uuidString)", isDirectory: true
            )
        databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
    }

    func seed() async throws {
        let database = try OboeDatabase(path: databaseURL.path)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, primary_deck_id
                    ) VALUES (1, 1, ?, 500, ?)
                    """,
                arguments: [timeZoneID, DatabaseValueCodec.encode(deckIDs[0])]
            )
            let profileID = try GRDBSchedulerProfileStore.ensureProfile(
                preset: .standard,
                candidateID: t15UUID(9),
                createdAtMilliseconds: nowMs,
                in: db
            )
            for (index, deckID) in deckIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(deckID), "牌组\(index)",
                        index, nowMs, nowMs
                    ]
                )
            }

            let todayID = t15UUID(60_000)
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-09-14', ?, ?, ?, 500)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(todayID), timeZoneID,
                    nowMs - 6 * 3_600_000, nowMs + 18 * 3_600_000
                ]
            )

            // 10,000 Note：home 轮转 4 个牌组，成员数 3/3/2/2 交替。
            for noteIndex in 0..<10_000 {
                let noteID = t15UUID(10_000 + noteIndex)
                let homeDeck = deckIDs[noteIndex % 4]
                try db.execute(
                    sql: """
                        INSERT INTO notes(
                            id, deck_id, kind, headword, reading, meaning_zh,
                            origin, content_version, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, 'vocabulary', ?, ?, ?, 'manual', 1, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(noteID),
                        DatabaseValueCodec.encode(homeDeck),
                        "性能词条\(noteIndex)", "せいのう\(noteIndex)",
                        noteIndex == 9_999 ? "唯一目标针" : "常用释义\(noteIndex)",
                        nowMs, nowMs
                    ]
                )
                let memberCount = noteIndex % 4 < 2 ? 3 : 2
                for offset in 0..<memberCount {
                    let memberDeck = deckIDs[(noteIndex + offset) % 4]
                    try db.execute(
                        sql: """
                            INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                            VALUES (?, ?, ?)
                            ON CONFLICT(note_id, deck_id) DO NOTHING
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(noteID),
                            DatabaseValueCodec.encode(memberDeck),
                            nowMs
                        ]
                    )
                }

                // 每 Note 3 方向卡：前 600 张到期复习，其余未来到期。
                for direction in 0..<3 {
                    let cardIndex = noteIndex * 3 + direction
                    let cardID = t15UUID(30_000 + cardIndex)
                    let due = cardIndex < 600
                    let dueAt = due
                        ? nowMs - Int64(600 - cardIndex) * 1_000
                        : nowMs + 7 * 86_400_000
                    let template = switch direction {
                    case 0: CardTemplateKind.vocabularyJapaneseToChinese
                    case 1: CardTemplateKind.vocabularyChineseToJapanese
                    default: CardTemplateKind.vocabularyListening
                    }
                    try db.execute(
                        sql: """
                            INSERT INTO cards(
                                id, note_id, template_kind, is_enabled, state,
                                due_at_ms, last_review_at_ms, stability, difficulty,
                                reps, lapses, scheduled_days, elapsed_days,
                                learning_step, first_studied_at_ms, state_version,
                                algorithm_version, profile_id
                            ) VALUES (?, ?, ?, 1, 2, ?, ?, 30, 5, 5, 0, 30, 30, 0, ?, 5, ?, ?)
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(cardID),
                            DatabaseValueCodec.encode(noteID),
                            template.rawValue, dueAt,
                            nowMs - 30 * 86_400_000, nowMs - 30 * 86_400_000,
                            SwiftFSRSReviewScheduler.algorithmVersion,
                            DatabaseValueCodec.encode(profileID)
                        ]
                    )
                }
            }

            // 100,000 历史日志均摊到全部卡。
            let snapshots = try t15ReviewSnapshots(profileID: profileID, now: now)
            for logIndex in 0..<100_000 {
                let cardIndex = logIndex % 30_000
                let noteIndex = cardIndex / 3
                try db.execute(
                    sql: """
                        INSERT INTO review_logs(
                            id, event_id, card_id, card_key, note_id, deck_id_at_review,
                            reviewed_at_ms, study_day_id, was_first_study, rating,
                            previous_state_json, next_state_json, duration_ms,
                            content_version, profile_id, algorithm_version, undone_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 500, 1, ?, ?, NULL)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(t15UUID(400_000 + logIndex)),
                        DatabaseValueCodec.encode(t15UUID(500_000 + logIndex)),
                        DatabaseValueCodec.encode(t15UUID(30_000 + cardIndex)),
                        DatabaseValueCodec.encode(t15UUID(30_000 + cardIndex)),
                        DatabaseValueCodec.encode(t15UUID(10_000 + noteIndex)),
                        DatabaseValueCodec.encode(deckIDs[noteIndex % 4]),
                        nowMs - 30 * 86_400_000 + Int64(logIndex),
                        DatabaseValueCodec.encode(todayID), (logIndex % 4) + 1,
                        snapshots.previous, snapshots.next,
                        DatabaseValueCodec.encode(profileID),
                        SwiftFSRSReviewScheduler.algorithmVersion
                    ]
                )
            }
        }
        try database.close()
    }

    func counts() async throws -> (
        notes: Int, cards: Int, memberships: Int, reviewLogs: Int
    ) {
        let database = try OboeDatabase(path: databaseURL.path)
        defer { try? database.close() }
        return try await database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_decks") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_logs") ?? 0
            )
        }
    }

    /// EXPLAIN：牌组成员枚举（应命中 note_decks_on_deck_note）与
    /// 首页/列表共用的 EXISTS 牌组过滤（应 SEARCH 而非 SCAN）。
    func explainMembershipPlans() async throws -> (
        memberEnumeration: String, deckFilteredExists: String
    ) {
        let database = try OboeDatabase(path: databaseURL.path)
        defer { try? database.close() }
        return try await database.pool.read { db in
            let enumeration = try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT note_id FROM note_decks WHERE deck_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(deckIDs[0])]
            ).map { $0["detail"] as String }.joined(separator: " | ")
            let exists = try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id FROM notes
                    WHERE EXISTS (
                        SELECT 1 FROM note_decks nd
                        WHERE nd.note_id = notes.id AND nd.deck_id = ?
                    )
                    """,
                arguments: [DatabaseValueCodec.encode(deckIDs[0])]
            ).map { $0["detail"] as String }.joined(separator: " | ")
            return (enumeration, exists)
        }
    }

    func makeStudySessionService(database: OboeDatabase) -> StudySessionService {
        let submissions = GRDBReviewSubmissionRepository(database: database)
        return StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: GRDBReviewCardContentRepository(database: database),
            submissionRepository: submissions,
            undoRepository: submissions,
            scheduler: SwiftFSRSReviewScheduler(),
            clock: T15FixedClock(value: now)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func t15UUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func t15ReviewSnapshots(
    profileID: UUID,
    now: Date
) throws -> (previous: String, next: String) {
    let previous = ReviewSchedulingSnapshot(
        scheduling: SchedulingCard(
            dueAt: now.addingTimeInterval(-86_400),
            stability: 30, difficulty: 5, elapsedDays: 30, scheduledDays: 30,
            repetitions: 4, state: .review,
            lastReviewAt: now.addingTimeInterval(-30 * 86_400)
        ),
        firstStudiedAt: now.addingTimeInterval(-365 * 86_400),
        stateVersion: 4,
        algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
        profileID: profileID
    )
    let next = ReviewSchedulingSnapshot(
        scheduling: SchedulingCard(
            dueAt: now.addingTimeInterval(30 * 86_400),
            stability: 30, difficulty: 5, elapsedDays: 30, scheduledDays: 30,
            repetitions: 5, state: .review, lastReviewAt: now
        ),
        firstStudiedAt: now.addingTimeInterval(-365 * 86_400),
        stateVersion: 5,
        algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
        profileID: profileID
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return (
        String(decoding: try encoder.encode(previous), as: UTF8.self),
        String(decoding: try encoder.encode(next), as: UTF8.self)
    )
}

private func t15Percentile95(
    samples: Int,
    operation: () async throws -> Void
) async throws -> TimeInterval {
    var durations: [TimeInterval] = []
    for _ in 0..<samples {
        let started = ContinuousClock.now
        try await operation()
        durations.append(t15Seconds(since: started))
    }
    let sorted = durations.sorted()
    return sorted[Int(Double(sorted.count - 1) * 0.95)]
}

private func t15Seconds(since started: ContinuousClock.Instant) -> TimeInterval {
    let duration = started.duration(to: .now)
    return Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
}

private func t15PrintMetric(_ name: String, _ seconds: TimeInterval) {
    print(String(format: "%@=%.3f", name, seconds * 1_000))
}
