import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S14（角色 C）：`GRDBLearningProgressRepository` 的批量
/// SQL 投影 + `LearningProgressMath` 纯函数端对端口径
/// （contracts §5.1、技术文档 §13.1/§13.2、D08/D13）。
///
/// 覆盖：§13.1 样例端到端、同 unit 跨 deck 一票、全停用、无卡、
/// Cloze-only deck、tooEasy、删除、停用重算、非有限 stability
/// 异常标记、三态批量查询。
final class GRDBLearningProgressRepositoryTests: XCTestCase {
    /// §13.1 样例端到端：unit A 三卡进度 0/0.5/1 → 0.5；unit B 一卡
    /// 1 → 1；牌组 = 0.75（不是四张物理卡的 0.625）。标 A tooEasy →
    /// 1；解除 → 恢复 0.75。
    func testSection13SampleEndToEnd() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        // unit A：三个启用方向，稳定性 0 / √31−1 / 30 → 0 / 0.5 / 1。
        let noteA = try await fixture.addNote(deckID: deckID)
        let unitA = try await fixture.makeUnit()
        try await fixture.link(noteID: noteA, to: unitA, role: .primary)
        try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyJapaneseToChinese,
            stability: 0
        )
        try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyChineseToJapanese,
            stability: exp(0.5 * log1p(30)) - 1 // cardProgress = 0.5
        )
        try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyListening,
            stability: 30 // cardProgress = 1（clamp 上界）
        )
        // unit B：一张启用方向卡，stability 30 → 1。
        let noteB = try await fixture.addNote(deckID: deckID)
        let unitB = try await fixture.makeUnit()
        try await fixture.link(noteID: noteB, to: unitB, role: .primary)
        try await fixture.addCard(
            noteID: noteB,
            template: .vocabularyJapaneseToChinese,
            stability: 30
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let unitResults = try await repository.unitProgresses(
            unitIDs: [unitA, unitB]
        )
        XCTAssertEqual(
            unitResults[unitA]?.value ?? -1,
            0.5,
            accuracy: 1e-9,
            "unit A = mean(0, 0.5, 1)"
        )
        XCTAssertEqual(unitResults[unitA]?.enabledCardCount, 3)
        XCTAssertEqual(unitResults[unitB]?.value ?? -1, 1, accuracy: 1e-9)

        var decks = try await repository.deckProgress(deckIDs: [deckID])
        var progress = try XCTUnwrap(decks[deckID])
        XCTAssertEqual(
            progress.progress ?? -1,
            0.75,
            accuracy: 1e-9,
            "按 unit 平均 0.75——不是四张物理卡的 0.625"
        )
        XCTAssertEqual(progress.unitCount, 2)
        XCTAssertTrue(progress.hasEnabledVocabularyCards)
        XCTAssertEqual(progress.anomalousCardCount, 0)
        let progressValues = try await repository.deckProgressValues(
            deckIDs: [deckID]
        )
        let onlyValue = try XCTUnwrap(progressValues[deckID] ?? nil)
        XCTAssertEqual(onlyValue, 0.75, accuracy: 1e-9)

        // tooEasy → unit = 1（启用卡数仍如实上报），牌组 = 1。
        try await fixture.setTooEasy(unitID: unitA, value: true)
        decks = try await repository.deckProgress(deckIDs: [deckID])
        XCTAssertEqual(decks[deckID]?.progress ?? -1, 1, accuracy: 1e-9)
        let flaggedUnit = try await repository.unitProgresses(
            unitIDs: [unitA]
        )[unitA]
        XCTAssertEqual(flaggedUnit?.value, 1)
        XCTAssertEqual(
            flaggedUnit?.enabledCardCount,
            3,
            "tooEasy 时启用卡计数照报（D13）"
        )

        // 解除 → 恢复 0.75。
        try await fixture.setTooEasy(unitID: unitA, value: false)
        decks = try await repository.deckProgress(deckIDs: [deckID])
        XCTAssertEqual(decks[deckID]?.progress ?? -1, 0.75, accuracy: 1e-9)
    }

    /// 同一 unit 跨 deck：不同 Note 分摊在两个牌组，各自都用全局
    /// unitProgress，且每 deck 只占一票（§13.1 明确语义）。
    func testSameUnitSharedAcrossDecksUsesGlobalProgress() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckA = try await fixture.addDeck(sortOrder: 0)
        let deckB = try await fixture.addDeck(sortOrder: 1)
        let unit = try await fixture.makeUnit()
        // primary Note 在 deckA（stability 30 → 1），legacy secondary
        // Note 在 deckB（stability 0 → 0）——unit 全局均值 0.5。
        let noteA = try await fixture.addNote(deckID: deckA)
        try await fixture.link(noteID: noteA, to: unit, role: .primary)
        try await fixture.addCard(
            noteID: noteA,
            template: .vocabularyJapaneseToChinese,
            stability: 30
        )
        let noteB = try await fixture.addNote(deckID: deckB)
        try await fixture.link(
            noteID: noteB,
            to: unit,
            role: .legacySecondary
        )
        try await fixture.addCard(
            noteID: noteB,
            template: .vocabularyJapaneseToChinese,
            stability: 0
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let decks = try await repository.deckProgress(
            deckIDs: [deckA, deckB]
        )
        XCTAssertEqual(
            decks[deckA]?.progress ?? -1,
            0.5,
            accuracy: 1e-9,
            "deckA 用全局 unitProgress（含 secondary Note 的卡）"
        )
        XCTAssertEqual(
            decks[deckB]?.progress ?? -1,
            0.5,
            accuracy: 1e-9,
            "deckB 同一 unit 同一全局进度，一票"
        )
        XCTAssertEqual(decks[deckA]?.unitCount, 1)
        XCTAssertEqual(decks[deckB]?.unitCount, 1)
    }

    /// 全停用：unitProgress = 0、hasEnabledVocabularyCards = false；
    /// deck progress 是 0（有 unit 覆盖）而非 nil。
    func testAllCardsDisabledYieldsZeroWithMarker() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            isEnabled: false,
            stability: 30
        )
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyChineseToJapanese,
            isEnabled: false,
            stability: 30
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let unit = try await repository.unitProgresses(
            unitIDs: [unitID]
        )[unitID]
        XCTAssertEqual(unit?.value, 0)
        XCTAssertEqual(unit?.enabledCardCount, 0)
        XCTAssertEqual(unit?.hasEnabledVocabularyCards, false)
        let deck = try await repository.deckProgress(
            deckIDs: [deckID]
        )[deckID]
        XCTAssertEqual(deck?.progress, 0, "覆盖到 unit → 0 而不是 nil")
        XCTAssertEqual(deck?.unitCount, 1)
        XCTAssertEqual(
            deck?.hasEnabledVocabularyCards,
            false,
            "D13「无启用方向」标记"
        )
    }

    /// 牌组没有任何链接 unit（Note 未挂单元/空牌组）→ progress nil。
    func testDeckWithoutLinkedUnitsReturnsNil() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        _ = try await fixture.addNote(deckID: deckID) // 未挂 unit
        let emptyDeck = try await fixture.addDeck()

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let decks = try await repository.deckProgress(
            deckIDs: [deckID, emptyDeck]
        )
        XCTAssertNil(decks[deckID]?.progress ?? nil)
        XCTAssertEqual(decks[deckID]?.unitCount, 0)
        XCTAssertNil(decks[emptyDeck]?.progress ?? nil)
        let nilValues = try await repository.deckProgressValues(
            deckIDs: [deckID, emptyDeck]
        )
        XCTAssertEqual(nilValues, [deckID: nil, emptyDeck: nil])
    }

    /// 仅 Cloze/Grammar 的牌组 → nil（「—」不是 0%）；非词汇模板
    /// 不进分子也不进分母。
    func testClozeAndGrammarOnlyDeckReturnsNil() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let sentence = try await fixture.addNote(
            deckID: deckID,
            kind: "sentence"
        )
        try await fixture.addCard(
            noteID: sentence,
            template: .sentenceCloze,
            stability: 30
        )
        let grammar = try await fixture.addNote(
            deckID: deckID,
            kind: "grammar"
        )
        try await fixture.addCard(
            noteID: grammar,
            template: .grammarFormToExplanation,
            stability: 30
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let deck = try await repository.deckProgress(
            deckIDs: [deckID]
        )[deckID]
        XCTAssertNil(deck?.progress ?? nil)
        XCTAssertEqual(deck?.unitCount, 0)
    }

    /// 无启用词汇卡 + tooEasy → unitProgress = 1（tooEasy 直接判
    /// mastered，不依赖卡面证据）。
    func testTooEasyUnitCountsAsOneWithoutEnabledCards() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            isEnabled: false,
            stability: 0
        )
        try await fixture.setTooEasy(unitID: unitID, value: true)

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let unit = try await repository.unitProgresses(
            unitIDs: [unitID]
        )[unitID]
        XCTAssertEqual(unit?.value, 1)
        XCTAssertEqual(unit?.enabledCardCount, 0)
        let deck = try await repository.deckProgress(
            deckIDs: [deckID]
        )[deckID]
        XCTAssertEqual(deck?.progress, 1)
    }

    /// 非有限 stability（+Inf）→ 异常标记 + 该卡按 0 计；
    /// NaN/Inf 绝不传播到 UI（D13）。
    func testNonFiniteStabilityMarkedAnomalous() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        let anomalous = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            stability: 5
        )
        try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyChineseToJapanese,
            stability: 30
        )
        // CHECK(stability >= 0) 放行 +Inf——写入路径污染模拟。
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET stability = 1e999 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(anomalous)]
            )
        }

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let unit = try await repository.unitProgresses(
            unitIDs: [unitID]
        )[unitID]
        XCTAssertEqual(unit?.anomalousCardCount, 1)
        XCTAssertEqual(
            unit?.value ?? -1,
            0.5,
            accuracy: 1e-9,
            "异常卡按 0 入均值——(0 + 1) / 2"
        )
        let deck = try await repository.deckProgress(
            deckIDs: [deckID]
        )[deckID]
        XCTAssertEqual(deck?.anomalousCardCount, 1)
    }

    /// Note 删除：该 Note 的卡随 CASCADE 消失，link 行残留与否都
    /// 不再投影出卡——unit 只剩另一 Note 的证据（legacy secondary
    /// Note 参与均值，§13.1）。
    func testDeleteNoteRecalculatesProgress() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let unitID = try await fixture.makeUnit()
        let primary = try await fixture.addNote(deckID: deckID)
        try await fixture.link(noteID: primary, to: unitID, role: .primary)
        try await fixture.addCard(
            noteID: primary,
            template: .vocabularyJapaneseToChinese,
            stability: 30
        )
        let secondary = try await fixture.addNote(deckID: deckID)
        try await fixture.link(
            noteID: secondary,
            to: unitID,
            role: .legacySecondary
        )
        try await fixture.addCard(
            noteID: secondary,
            template: .vocabularyJapaneseToChinese,
            stability: 30
        )

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        var unit = try await repository.unitProgresses(
            unitIDs: [unitID]
        )[unitID]
        XCTAssertEqual(unit?.value ?? -1, 1, accuracy: 1e-9)

        try await fixture.deleteNote(secondary)
        unit = try await repository.unitProgresses(unitIDs: [unitID])[
            unitID
        ]
        XCTAssertEqual(
            unit?.value ?? -1,
            1,
            accuracy: 1e-9,
            "删除 secondary Note 后只剩 primary 证据"
        )
        XCTAssertEqual(unit?.enabledCardCount, 1)
        try await fixture.deleteNote(primary)
        unit = try await repository.unitProgresses(unitIDs: [unitID])[
            unitID
        ]
        XCTAssertEqual(unit?.value, 0)
        XCTAssertEqual(unit?.enabledCardCount, 0)
        let deck = try await repository.deckProgress(
            deckIDs: [deckID]
        )[deckID]
        XCTAssertNil(
            deck?.progress ?? nil,
            "全部成员 Note 删除后 deck 无覆盖 unit → nil"
        )
    }

    /// 停用重算：均值随启用集合变化（D13 active 口径）；单张停用
    /// 只挪分子分母，全部停用才归零。
    func testDisableCardRecalculatesUnitMean() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let noteID = try await fixture.addNote(deckID: deckID)
        let unitID = try await fixture.makeUnit()
        try await fixture.link(noteID: noteID, to: unitID, role: .primary)
        let low = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyJapaneseToChinese,
            stability: 0
        )
        let high = try await fixture.addCard(
            noteID: noteID,
            template: .vocabularyChineseToJapanese,
            stability: 30
        )
        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        var unit = try await repository.unitProgresses(
            unitIDs: [unitID]
        )[unitID]
        XCTAssertEqual(unit?.value ?? -1, 0.5, accuracy: 1e-9)

        try await fixture.setCardEnabled(high, false)
        unit = try await repository.unitProgresses(unitIDs: [unitID])[
            unitID
        ]
        XCTAssertEqual(
            unit?.value ?? -1,
            0,
            accuracy: 1e-9,
            "停用高进度卡后均值 = 0（只数启用卡）"
        )
        XCTAssertEqual(unit?.enabledCardCount, 1)

        try await fixture.setCardEnabled(low, false)
        unit = try await repository.unitProgresses(unitIDs: [unitID])[
            unitID
        ]
        XCTAssertEqual(unit?.value, 0)
        XCTAssertEqual(unit?.enabledCardCount, 0)
        let deck = try await repository.deckProgress(
            deckIDs: [deckID]
        )[deckID]
        XCTAssertEqual(
            deck?.hasEnabledVocabularyCards,
            false,
            "全停用 → 「无启用方向」标记"
        )
    }

    /// 三态批量：flags + links 两查 → LearningKnowledgeResolver——
    /// mastered/learning/unknown 与 §2.1 真值表一致。
    func testKnowledgeStatesResolver() async throws {
        let fixture = try await ProgressFixture.make()
        defer { fixture.remove() }
        let deckID = try await fixture.addDeck()
        let masteredUnit = try await fixture.makeUnit()
        let linkedUnit = try await fixture.makeUnit()
        let danglingUnit = try await fixture.makeUnit()
        let noteA = try await fixture.addNote(deckID: deckID)
        try await fixture.link(
            noteID: noteA,
            to: masteredUnit,
            role: .primary
        )
        let noteB = try await fixture.addNote(deckID: deckID)
        try await fixture.link(
            noteID: noteB,
            to: linkedUnit,
            role: .primary
        )
        try await fixture.setTooEasy(unitID: masteredUnit, value: true)
        let missing = UUID()

        let repository = GRDBLearningProgressRepository(
            database: fixture.database
        )
        let states = try await repository.knowledgeStates(
            unitIDs: [masteredUnit, linkedUnit, danglingUnit, missing]
        )
        XCTAssertEqual(states[masteredUnit], .mastered)
        XCTAssertEqual(states[linkedUnit], .learning)
        XCTAssertEqual(
            states[danglingUnit],
            .unknown,
            "无有效词汇 Note 链接 → unknown（真值表）"
        )
        XCTAssertEqual(states[missing], .unknown)

        // 解除 flag → mastered 回 learning（链接仍在）。
        try await fixture.setTooEasy(unitID: masteredUnit, value: false)
        let cleared = try await repository.knowledgeStates(
            unitIDs: [masteredUnit]
        )
        XCTAssertEqual(cleared[masteredUnit], .learning)
    }
}

// MARK: - 测试夹具

/// 进度投影夹具：v1–v23 全量迁移 + deck/note/note_decks/cards +
/// v23 unit/link/flag 正路写入。
private final class ProgressFixture: @unchecked Sendable {
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

    static func make() async throws -> ProgressFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Oboe-Progress-\(UUID().uuidString)",
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
        return ProgressFixture(
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
            try insertHomeMembershipIfSupported(
                noteID: id,
                deckID: deckID,
                in: db
            )
        }
        return id
    }

    /// 显式把 Note 挂进另一牌组（多牌组成员语义，§4.6）。
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

    /// `.localNote` unit（identityKey 全局唯一）。
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

    /// primary/legacy_secondary 角色都走正路校验。
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

    func deleteNote(_ noteID: UUID) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM notes WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(noteID)]
            )
        }
    }

    func setCardEnabled(_ cardID: UUID, _ enabled: Bool) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE cards SET is_enabled = ? WHERE id = ?",
                arguments: [enabled, DatabaseValueCodec.encode(cardID)]
            )
        }
    }
}
