import Foundation
import GRDB
import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// T23 integration tests (design §11): real user SQLite + real bundled-
/// shape vocab sqlite + real adaptive evidence. Word-level buckets are
/// verified end to end through `JLPTProgressService` — association by
/// exact `source_ref`, per-card status via the same `LeechClassifier`.
final class GRDBJLPTProgressTests: XCTestCase {

    func testDashboardSnapshotListsPartitionCountsAndRefreshAfterImport() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:a", "N5"), ("v:b", "N4")])
        let service = fixture.makeProgressService()
        let empty = try await service.snapshot(targetLevel: .n3, at: fixture.now)
        XCTAssertEqual(empty.entries(in: .notAdded).map(\.id), ["v:a", "v:b"])
        XCTAssertEqual(empty.summary.notStartedCount, 0)
        for ref in empty.entries {
            let note = try await fixture.addBuiltinNote(sourceRef: ref.id)
            _ = try await fixture.addCard(noteID: note, template: .vocabularyJapaneseToChinese)
            _ = try await fixture.addCard(noteID: note, template: .vocabularyListening)
        }
        let imported = try await service.snapshot(targetLevel: .n3, at: fixture.now)
        XCTAssertTrue(imported.entries(in: .notAdded).isEmpty)
        XCTAssertEqual(imported.summary.notStartedCount, 2)
        XCTAssertEqual(imported.entries(in: .learning).count, 2)
        XCTAssertTrue(imported.entries.allSatisfy { $0.status.isNotStarted })
        for bucket in JLPTWordBucket.allCases {
            XCTAssertEqual(imported.entries(in: bucket).count, imported.summary.count(bucket))
        }
        XCTAssertEqual(Set(imported.entries.map(\.id)).count, imported.summary.totalEntries)
    }

    func testDashboardEmptyDatasetHasZeroCountsAndNoRows() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([])
        let snapshot = try await fixture.makeProgressService().snapshot(targetLevel: .n1, at: fixture.now)
        XCTAssertEqual(snapshot.summary.totalEntries, 0)
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(JLPTWordBucket.allCases.allSatisfy { snapshot.summary.count($0) == 0 })
    }

    func testDashboardRecomputesSameClassificationFromRestoredBackup() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:a", "N5"), ("v:b", "N4")])
        let note = try await fixture.addBuiltinNote(sourceRef: "v:a")
        let card = try await fixture.addCard(noteID: note, template: .vocabularyJapaneseToChinese)
        // 词汇固定三方向：补齐其余方向，恢复填充即为空操作，快照逐字节一致。
        _ = try await fixture.addCard(noteID: note, template: .vocabularyChineseToJapanese)
        _ = try await fixture.addCard(noteID: note, template: .vocabularyListening)
        _ = try await fixture.submit(cardID: card, rating: .again)
        let original = try await fixture.makeProgressService().snapshot(targetLevel: .n3, at: fixture.now)
        let backup = try await PortableBackupExporter(
            database: fixture.database,
            workingDirectoryURL: fixture.rootURL.appendingPathComponent("export")
        ).export(appVersion: "0.4-test", at: fixture.now)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: fixture.database,
            workingDirectoryURL: fixture.rootURL.appendingPathComponent("restore")
        )
        let prepared = try await preparer.prepare(fileURL: backup.url)
        let restored = try OboeDatabase(path: prepared.temporaryDatabaseURL.path)
        defer { try? restored.close() }
        let rebuilt = try await JLPTProgressService(
            libraryRepository: GRDBJLPTLibraryRepository(databaseURL: fixture.libraryURL),
            associationRepository: GRDBJLPTNoteAssociationRepository(database: restored),
            adaptiveRepository: GRDBAdaptiveRepository(database: restored)
        ).snapshot(targetLevel: .n3, at: fixture.now)
        XCTAssertEqual(rebuilt, original)
        XCTAssertEqual(rebuilt.entries(in: .recentlyForgotten).map(\.id), ["v:a"])
    }

    func testCumulativeLevelsAndBucketSumEqualsDenominator() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([
            ("openjlpt:N5:000001", "N5"), ("openjlpt:N5:000002", "N5"),
            ("openjlpt:N4:000001", "N4"), ("openjlpt:N2:000001", "N2")
        ])
        let noteA = try await fixture.addBuiltinNote(sourceRef: "openjlpt:N5:000001")
        _ = try await fixture.addCard(noteID: noteA, template: .vocabularyJapaneseToChinese)
        _ = try await fixture.addCard(noteID: noteA, template: .vocabularyChineseToJapanese)
        let noteC = try await fixture.addBuiltinNote(sourceRef: "openjlpt:N4:000001")
        _ = try await fixture.addCard(noteID: noteC, template: .vocabularyJapaneseToChinese)

        let service = fixture.makeProgressService()
        let n3 = try await service.progress(targetLevel: .n3, at: fixture.now)
        // N3 累计 = N5+N4+N3 —— 本词库 2+1+0；N2 条目不参与。
        XCTAssertEqual(n3.includedLevels, [.n5, .n4, .n3])
        XCTAssertEqual(n3.totalEntries, 3)
        XCTAssertEqual(n3.count(.learning), 2)
        XCTAssertEqual(n3.count(.notAdded), 1)
        XCTAssertEqual(n3.bucketCounts.values.reduce(0, +), n3.totalEntries,
                       "五桶总和必须等于词库分母")
        XCTAssertEqual(n3.notStartedCount, 2)

        let n5 = try await service.progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(n5.totalEntries, 2)
        XCTAssertEqual(n5.count(.learning), 1)
        XCTAssertEqual(n5.count(.notAdded), 1)

        let n1 = try await service.progress(targetLevel: .n1, at: fixture.now)
        XCTAssertEqual(n1.totalEntries, 4)
    }

    func testAllFiveBucketsClassifyFromRealEvidence() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([
            ("v:leech", "N5"), ("v:recent", "N5"), ("v:stable", "N5"),
            ("v:learning", "N5"), ("v:absent", "N5")
        ])

        // 经常遗忘：lapses ≥ 阈值且无可恢复证据 → leech（同源规则 A）。
        let leechNote = try await fixture.addBuiltinNote(sourceRef: "v:leech")
        _ = try await fixture.addCard(
            noteID: leechNote, template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(
                dueAt: fixture.now, stability: 2, difficulty: 5,
                repetitions: 9, lapses: 6, state: .review,
                lastReviewAt: fixture.now.addingTimeInterval(-86_400)
            ),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )

        // 近期遗忘：真实 Again 提交 → 末次有效评分 Again 且此刻发生。
        let recentNote = try await fixture.addBuiltinNote(sourceRef: "v:recent")
        let recentCard = try await fixture.addCard(
            noteID: recentNote, template: .vocabularyJapaneseToChinese
        )
        _ = try await fixture.submit(cardID: recentCard, rating: .again)

        // 较稳定：真实 Easy 提交（state=review、末次=easy）+ stability 达阈。
        let stableNote = try await fixture.addBuiltinNote(sourceRef: "v:stable")
        let stableCard = try await fixture.addCard(
            noteID: stableNote, template: .vocabularyJapaneseToChinese
        )
        _ = try await fixture.submit(cardID: stableCard, rating: .easy)
        try await fixture.patchCard(cardID: stableCard, sql: "stability = 30")

        // 学习中：已加入未开始。
        let learningNote = try await fixture.addBuiltinNote(sourceRef: "v:learning")
        _ = try await fixture.addCard(noteID: learningNote, template: .vocabularyJapaneseToChinese)

        let snapshot = try await fixture.makeProgressService()
            .snapshot(targetLevel: .n5, at: fixture.now)
        let progress = snapshot.summary
        for bucket in JLPTWordBucket.allCases {
            XCTAssertEqual(snapshot.entries(in: bucket).count, progress.count(bucket))
        }
        XCTAssertEqual(snapshot.entries(in: .frequentlyForgotten).map(\.id), ["v:leech"])
        XCTAssertEqual(snapshot.entries(in: .recentlyForgotten).map(\.id), ["v:recent"])
        XCTAssertEqual(snapshot.entries(in: .stable).map(\.id), ["v:stable"])
        XCTAssertEqual(snapshot.entries(in: .learning).map(\.id), ["v:learning"])
        XCTAssertEqual(snapshot.entries(in: .notAdded).map(\.id), ["v:absent"])
        XCTAssertEqual(progress.totalEntries, 5)
        XCTAssertEqual(progress.count(.frequentlyForgotten), 1)
        XCTAssertEqual(progress.count(.recentlyForgotten), 1)
        XCTAssertEqual(progress.count(.stable), 1)
        XCTAssertEqual(progress.count(.learning), 1)
        XCTAssertEqual(progress.count(.notAdded), 1)
        XCTAssertEqual(progress.bucketCounts.values.reduce(0, +), 5)
        XCTAssertEqual(progress.notStartedCount, 1)
        XCTAssertEqual(progress.suspendedCount, 0)
    }

    func testAllSuspendedWordIsLearningSuspendedEvenWithLeechEvidence() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:sus", "N5"), ("v:empty", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:sus")
        _ = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese,
            scheduling: SchedulingCard(
                dueAt: fixture.now, stability: 2, difficulty: 5,
                repetitions: 9, lapses: 6, state: .review,
                lastReviewAt: fixture.now.addingTimeInterval(-86_400)
            ),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400),
            enabled: false
        )
        _ = try await fixture.addCard(
            noteID: noteID, template: .vocabularyChineseToJapanese, enabled: false
        )

        let progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        // 全部暂停 → 仍属已加入/学习中 + 已暂停；暂停卡的 leech 不计入。
        XCTAssertEqual(progress.count(.learning), 1)
        XCTAssertEqual(progress.count(.frequentlyForgotten), 0)
        XCTAssertEqual(progress.suspendedCount, 1)
        XCTAssertEqual(progress.count(.notAdded), 1)
    }

    func testNewEnabledListeningDirectionRegressesStableWord() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:w", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:w")
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        _ = try await fixture.submit(cardID: cardID, rating: .easy)
        try await fixture.patchCard(cardID: cardID, sql: "stability = 30")

        var progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.stable), 1)

        // 新增启用听力方向（未学）→ 该词回落学习中（§11.2 明确结果）。
        let listening = try await fixture.addCard(
            noteID: noteID, template: .vocabularyListening
        )
        progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.learning), 1)
        XCTAssertEqual(progress.count(.stable), 0)

        // 暂停该方向后聚合只看启用卡 → 恢复较稳定。
        try await fixture.setEnabled(false, cardID: listening)
        progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.stable), 1)
    }

    func testAISplitAndManualNotesNeverAssociateWithBuiltinEntry() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:x", "N5")])
        // 同 headword 的 AI 拆分 Note 与手动 Note —— origin 非 builtin，
        // source_ref 受 CHECK 约束必为 NULL，不可能占用条目关联。
        _ = try await fixture.addNote(
            origin: "ai", sourceRef: nil, headword: "食べる"
        )
        _ = try await fixture.addNote(
            origin: "manual", sourceRef: nil, headword: "食べる"
        )

        var progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.notAdded), 1)
        XCTAssertEqual(progress.count(.learning), 0)

        // 真正的 builtin Note 建立关联；AI/手动卡再多也不重复计数。
        let builtin = try await fixture.addBuiltinNote(sourceRef: "v:x")
        _ = try await fixture.addCard(noteID: builtin, template: .vocabularyJapaneseToChinese)
        _ = try await fixture.addCard(noteID: builtin, template: .vocabularyChineseToJapanese)
        _ = try await fixture.addCard(noteID: builtin, template: .vocabularyListening)
        progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.learning), 1,
                       "同一词三方向只计一次——不按 Card 数累加")
        XCTAssertEqual(progress.count(.notAdded), 0)

        // source_ref 唯一索引：第二个 builtin Note 同 ref 直接冲突。
        do {
            _ = try await fixture.addBuiltinNote(sourceRef: "v:x")
            XCTFail("duplicate builtin source_ref must violate the unique index")
        } catch {}
    }

    func testLibraryUpdateWithoutMappingLeavesEntriesUnassociated() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("openjlpt:N5:old", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "openjlpt:N5:old")
        _ = try await fixture.addCard(noteID: noteID, template: .vocabularyJapaneseToChinese)
        var progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.learning), 1)

        // 词库更新：条目换 ID、同 headword —— 未映射的 ID 变化按
        // 「未关联」处理，绝不按 headword 模糊合并（§11.2）。
        try fixture.makeLibrary([("openjlpt:N5:new", "N5")])
        progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.totalEntries, 1)
        XCTAssertEqual(progress.count(.notAdded), 1)
        XCTAssertEqual(progress.count(.learning), 0)

        // 用户 Note/Card 零写入：原 Note、source_ref、卡全部原样。
        let counts = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1,
                try String.fetchOne(
                    db, sql: "SELECT source_ref FROM notes"
                ),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cards") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, "openjlpt:N5:old")
        XCTAssertEqual(counts.2, 1)
    }

    func testUndoLatestAgainClearsRecentForgetEvidence() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:u", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:u")
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        let log = try await fixture.submit(cardID: cardID, rating: .again)
        var progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.recentlyForgotten), 1)

        // 撤销该次评分 → 有效样本消失 → 重算回落学习中（未开始）。
        try await fixture.undo(eventID: log.eventID)
        progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.recentlyForgotten), 0)
        XCTAssertEqual(progress.count(.learning), 1)
        XCTAssertEqual(progress.notStartedCount, 1)
    }

    func testOldAgainBeyondWindowIsNotRecent() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:o", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:o")
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese
        )
        _ = try await fixture.submit(cardID: cardID, rating: .again)
        // 把日志时间改到 8 天前 —— 时间跨度判定而非次数判定。
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE review_logs SET reviewed_at_ms = ?",
                arguments: [
                    try DatabaseValueCodec.encode(
                        fixture.now.addingTimeInterval(-8 * 86_400)
                    )
                ]
            )
        }
        let progress = try await fixture.makeProgressService()
            .progress(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(progress.count(.recentlyForgotten), 0)
        XCTAssertEqual(progress.count(.learning), 1)
    }

    // MARK: - T25 薄弱词汇（weakEntries / weakCards）

    /// 同词两张 leech 只出现一条词汇；展开列出全部匹配方向，且
    /// 五桶计数与 weakEntries 来自同一份证据。
    func testWeakEntriesDeduplicateWordAndListEveryWeakDirection() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:w", "N5"), ("v:x", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:w")
        let ja2zh = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese,
            scheduling: leechScheduling(at: fixture.now),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )
        let zh2ja = try await fixture.addCard(
            noteID: noteID, template: .vocabularyChineseToJapanese,
            scheduling: leechScheduling(at: fixture.now),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )
        // 第二个词一张 normal 新卡 —— 不进任何 weak 筛选。
        let otherNote = try await fixture.addBuiltinNote(sourceRef: "v:x")
        _ = try await fixture.addCard(noteID: otherNote, template: .vocabularyJapaneseToChinese)

        let snapshot = try await fixture.makeProgressService()
            .snapshot(targetLevel: .n5, at: fixture.now)
        let weak = snapshot.weakEntries(matching: .leech)
        XCTAssertEqual(weak.map(\.id), ["v:w"],
                       "同一词两张 leech 卡只出现一次——统计单位是词库条目")
        XCTAssertEqual(weak[0].weakCards(matching: .leech).map(\.cardID),
                       [ja2zh, zh2ja],
                       "展开须列出各薄弱方向并按方向序稳定")
        XCTAssertEqual(weak[0].weakCards(matching: .leech).map(\.templateKind),
                       [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese])
        // 与五桶同一份分类：经常遗忘词数 = 1，与 weak 列表一致。
        XCTAssertEqual(snapshot.summary.count(.frequentlyForgotten), 1)
        XCTAssertTrue(snapshot.weakEntries(matching: .warning).isEmpty)
        XCTAssertTrue(snapshot.weakEntries(matching: .suspended).isEmpty)
    }

    /// JLPT 薄弱方向与易错中心的同一张卡状态逐张一致 —— 同一
    /// LeechClassifier、同一筛选规则，不维护第二套阈值。
    func testWeakCardStatusMatchesAdaptiveCenterCardByCard() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:w", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:w")
        let leechID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese,
            scheduling: leechScheduling(at: fixture.now),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )
        let warningID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyChineseToJapanese,
            scheduling: SchedulingCard(
                dueAt: fixture.now, stability: 4, difficulty: 6,
                repetitions: 8, lapses: 3, state: .review,
                lastReviewAt: fixture.now.addingTimeInterval(-86_400)
            ),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )

        let service = fixture.makeProgressService()
        let snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        let adaptive = try await AdaptiveCardService(
            repository: GRDBAdaptiveRepository(database: fixture.database)
        ).snapshot(at: fixture.now)
        let statusByCard = Dictionary(
            uniqueKeysWithValues: adaptive.items.map { ($0.cardID, $0.assessment.status) }
        )

        let entry = try XCTUnwrap(snapshot.entries.first { $0.id == "v:w" })
        // 同词既在易错筛选（leech 方向）也在预警筛选（warning 方向）。
        XCTAssertEqual(entry.weakCards(matching: .leech).map(\.cardID), [leechID])
        XCTAssertEqual(entry.weakCards(matching: .warning).map(\.cardID), [warningID])
        for card in entry.cards {
            XCTAssertEqual(
                card.adaptiveStatus, statusByCard[card.cardID],
                "卡 \(card.cardID) 在 JLPT 侧与易错中心必须同状态"
            )
        }
        // 聚合桶由 leech 决定；warning 方向不影响「经常遗忘」去重计数。
        XCTAssertEqual(snapshot.weakEntries(matching: .leech).map(\.id), ["v:w"])
        XCTAssertEqual(snapshot.weakEntries(matching: .warning).map(\.id), ["v:w"])
        XCTAssertEqual(snapshot.summary.count(.frequentlyForgotten), 1)
    }

    /// 暂停与恢复在两侧过滤一致：暂停的 leech 离开易错筛选进入
    /// 已暂停；重新启用后同一证据回到易错 —— 与易错中心行为相同。
    func testWeakEntriesSuspendAndResumeMirrorAdaptiveFiltering() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:w", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:w")
        let leechID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese,
            scheduling: leechScheduling(at: fixture.now),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )
        _ = try await fixture.addCard(
            noteID: noteID, template: .vocabularyChineseToJapanese
        )

        let service = fixture.makeProgressService()
        var snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(snapshot.weakEntries(matching: .leech).map(\.id), ["v:w"])

        try await fixture.setEnabled(false, cardID: leechID)
        snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        XCTAssertTrue(snapshot.weakEntries(matching: .leech).isEmpty,
                      "暂停的 leech 不得再计入易错筛选（同易错中心）")
        let suspended = snapshot.weakEntries(matching: .suspended)
        XCTAssertEqual(suspended.map(\.id), ["v:w"])
        XCTAssertEqual(suspended[0].weakCards(matching: .suspended).map(\.cardID),
                       [leechID],
                       "已暂停筛选只展开暂停方向，不混入仍启用的卡")

        try await fixture.setEnabled(true, cardID: leechID)
        snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(snapshot.weakEntries(matching: .leech).map(\.id), ["v:w"])
        XCTAssertTrue(snapshot.weakEntries(matching: .suspended).isEmpty)
    }

    /// 未关联手动/AI Note 即便整卡 leech 也不计入内置进度 ——
    /// weakEntries 只认 source_ref 精确关联；该卡在易错中心仍是 leech。
    func testWeakEntriesExcludeUnassociatedManualAndAINotes() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:w", "N5")])
        for origin in ["manual", "ai"] {
            let noteID = try await fixture.addNote(
                origin: origin, sourceRef: nil, headword: "食べる"
            )
            _ = try await fixture.addCard(
                noteID: noteID, template: .vocabularyJapaneseToChinese,
                scheduling: leechScheduling(at: fixture.now),
                firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
            )
        }

        let service = fixture.makeProgressService()
        let snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        for filter in AdaptiveListFilter.allCases {
            XCTAssertTrue(snapshot.weakEntries(matching: filter).isEmpty,
                          "\(filter) 下不得出现未关联 Note")
        }
        XCTAssertEqual(snapshot.summary.count(.notAdded), 1)

        // 同一份证据在易错中心确实是 2 张 leech —— 只是不属于内置词汇。
        let adaptive = try await AdaptiveCardService(
            repository: GRDBAdaptiveRepository(database: fixture.database)
        ).snapshot(at: fixture.now)
        XCTAssertEqual(adaptive.leechCount, 2)
    }

    /// 弱项证据随编辑/修卡后的数据版本自动重算：leech 卡 lapses
    /// 被修复回阈值以下后，下一快照即离开 weakEntries —— 没有缓存
    /// 旧状态（返回刷新依赖同一路径）。
    func testWeakEntriesRecomputeAfterCardStateChanges() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        try fixture.makeLibrary([("v:w", "N5")])
        let noteID = try await fixture.addBuiltinNote(sourceRef: "v:w")
        let cardID = try await fixture.addCard(
            noteID: noteID, template: .vocabularyJapaneseToChinese,
            scheduling: leechScheduling(at: fixture.now),
            firstStudiedAt: fixture.now.addingTimeInterval(-30 * 86_400)
        )

        let service = fixture.makeProgressService()
        var snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        XCTAssertEqual(snapshot.weakEntries(matching: .leech).map(\.id), ["v:w"])

        try await fixture.patchCard(cardID: cardID, sql: "lapses = 1, difficulty = 4")
        snapshot = try await service.snapshot(targetLevel: .n5, at: fixture.now)
        XCTAssertTrue(snapshot.weakEntries(matching: .leech).isEmpty)
        XCTAssertTrue(snapshot.weakEntries(matching: .warning).isEmpty)
    }

    private func leechScheduling(at now: Date) -> SchedulingCard {
        SchedulingCard(
            dueAt: now, stability: 2, difficulty: 5,
            repetitions: 9, lapses: 6, state: .review,
            lastReviewAt: now.addingTimeInterval(-86_400)
        )
    }
}

// MARK: - Fixture

private final class ProgressClock: SchedulingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ProgressFixture: @unchecked Sendable {
    let rootURL: URL
    let libraryURL: URL
    let database: OboeDatabase
    let deckID: UUID
    let profileID: UUID
    let now: Date
    let clock: ProgressClock

    private init(
        rootURL: URL, libraryURL: URL, database: OboeDatabase,
        deckID: UUID, profileID: UUID, now: Date, clock: ProgressClock
    ) {
        self.rootURL = rootURL
        self.libraryURL = libraryURL
        self.database = database
        self.deckID = deckID
        self.profileID = profileID
        self.now = now
        self.clock = clock
    }

    static func make() async throws -> ProgressFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-T23-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let libraryURL = rootURL.appendingPathComponent("library.sqlite")
        let database = try OboeDatabase(
            path: rootURL.appendingPathComponent("oboe.sqlite").path
        )
        let deckID = UUID()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = SchedulerProfile.standard
        let parameters = String(
            decoding: try JSONEncoder().encode(profile.parameters), as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms) VALUES (?, 'T23', 0, 1, 1)",
                arguments: [DatabaseValueCodec.encode(deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
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
        return ProgressFixture(
            rootURL: rootURL, libraryURL: libraryURL, database: database,
            deckID: deckID, profileID: profileID, now: now,
            clock: ProgressClock(now)
        )
    }

    /// 迷你只读词库：仅保留 refs 查询所需列。
    func makeLibrary(_ entries: [(id: String, level: String)]) throws {
        let queue = try DatabaseQueue(path: libraryURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS vocab(
                    id TEXT PRIMARY KEY, level TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0
                );
                DELETE FROM vocab;
                """)
            for (index, entry) in entries.enumerated() {
                try db.execute(
                    sql: "INSERT INTO vocab(id, level, sort_order) VALUES (?, ?, ?)",
                    arguments: [entry.id, entry.level, index]
                )
            }
        }
        try queue.close()
    }

    func addBuiltinNote(sourceRef: String) async throws -> UUID {
        try await addNote(origin: "builtin_jlpt", sourceRef: sourceRef, headword: "食べる")
    }

    func addNote(origin: String, sourceRef: String?, headword: String) async throws -> UUID {
        let noteID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, jlpt, origin, source_ref,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', ?, 'たべる', '吃', '动词',
                              'N5', ?, ?, 1, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    headword,
                    origin,
                    sourceRef
                ]
            )
        }
        return noteID
    }

    func addCard(
        noteID: UUID,
        template: CardTemplateKind,
        scheduling: SchedulingCard? = nil,
        firstStudiedAt: Date? = nil,
        enabled: Bool = true
    ) async throws -> UUID {
        let card = scheduling ?? SchedulingCard(dueAt: now)
        let cardID = UUID()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        last_review_at_ms, stability, difficulty, reps, lapses,
                        scheduled_days, elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    enabled,
                    card.state.rawValue,
                    try DatabaseValueCodec.encode(card.dueAt),
                    try card.lastReviewAt.map { try DatabaseValueCodec.encode($0) },
                    card.stability,
                    card.difficulty,
                    card.repetitions,
                    card.lapses,
                    card.scheduledDays,
                    card.elapsedDays,
                    card.learningStep,
                    try firstStudiedAt.map { try DatabaseValueCodec.encode($0) },
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return cardID
    }

    func setEnabled(_ enabled: Bool, cardID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = ? WHERE id = ?",
                arguments: [enabled, DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    func patchCard(cardID: UUID, sql: String) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET \(sql) WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(cardID)]
            )
        }
    }

    func makeService() -> StudySessionService {
        StudySessionService(
            studyDayRepository: GRDBStudyDayPlanningRepository(database: database),
            queueRepository: GRDBTodayQueueRepository(database: database),
            contentRepository: GRDBReviewCardContentRepository(database: database),
            submissionRepository: GRDBReviewSubmissionRepository(database: database),
            undoRepository: GRDBReviewSubmissionRepository(database: database),
            scheduler: SwiftFSRSReviewScheduler(clock: clock),
            clock: clock
        )
    }

    func makeProgressService() -> JLPTProgressService {
        JLPTProgressService(
            libraryRepository: try! GRDBJLPTLibraryRepository(databaseURL: libraryURL),
            associationRepository: GRDBJLPTNoteAssociationRepository(database: database),
            adaptiveRepository: GRDBAdaptiveRepository(database: database)
        )
    }

    @discardableResult
    func submit(cardID: UUID, rating: ReviewRating) async throws -> ReviewLogRecord {
        let service = makeService()
        let plan = try await service.buildTodayPlan(defaultTimeZoneID: "Asia/Shanghai")
        let card = try await service.loadReviewCard(cardID: cardID)
        return try await service.submit(
            card: card, rating: rating, studyDay: plan.studyDay,
            eventID: UUID(), durationMilliseconds: 500
        )
    }

    func undo(eventID: UUID) async throws {
        let service = makeService()
        let plan = try await service.buildTodayPlan(defaultTimeZoneID: "Asia/Shanghai")
        _ = try await service.undoLastReview(eventID: eventID, studyDay: plan.studyDay)
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: rootURL)
    }
}
