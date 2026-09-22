import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// Shared synthetic dataset for the v0.4 adaptive-learning work (T00).
///
/// Seeded scenarios (all inside one temporary database):
/// - `freshNote`: vocabulary note with two enabled directions and zero logs
///   ("无日志新卡").
/// - `lapsedNote`: card whose persisted lapses and due-review history make it a
///   lifetime/recent-failure candidate ("累计遗忘卡").
/// - `undoneNote`: card whose newest evidence was undone, plus a deleted
///   sibling direction whose orphaned `card_key` history must not reattach
///   ("被撤销日志" / 删除后同方向重建）.
/// - `otherDeckNote`: note living in a second deck for scope filtering
///   ("不同牌组").
///
/// The third vocabulary direction ("同 Note 三方向") only becomes creatable
/// once the `vocabulary_listening` template lands (v9/T15); `addCard` and
/// `VocabularyCardDirection` iteration are kept generic so the same fixture
/// covers it without structural changes.
final class AdaptiveDatabaseFixture: @unchecked Sendable {
    static let baseDate = Date(timeIntervalSince1970: 1_788_000_000) // 2026-08-28T00:00:00Z
    static let timeZoneID = "Asia/Shanghai"

    struct SeededNote: Sendable {
        let noteID: UUID
        let deckID: UUID
        var cards: [CardTemplateKind: UUID]

        func cardID(_ kind: CardTemplateKind) -> UUID {
            guard let id = cards[kind] else {
                preconditionFailure("Seeded note has no \(kind.rawValue) card")
            }
            return id
        }
    }

    struct SeededLog: Sendable {
        let id: UUID
        let cardKey: UUID
        let rating: ReviewRating
        let reviewedAt: Date
        let undoneAt: Date?
    }

    let directoryURL: URL
    let databaseURL: URL
    let database: OboeDatabase
    let profileID: UUID
    let studyDayID: UUID
    let deckAID: UUID
    let deckBID: UUID

    private(set) var freshNote: SeededNote
    private(set) var lapsedNote: SeededNote
    private(set) var undoneNote: SeededNote
    private(set) var otherDeckNote: SeededNote
    private(set) var deletedCardKey: UUID

    private init(
        directoryURL: URL,
        databaseURL: URL,
        database: OboeDatabase,
        profileID: UUID,
        studyDayID: UUID,
        deckAID: UUID,
        deckBID: UUID,
        freshNote: SeededNote,
        lapsedNote: SeededNote,
        undoneNote: SeededNote,
        otherDeckNote: SeededNote,
        deletedCardKey: UUID
    ) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.database = database
        self.profileID = profileID
        self.studyDayID = studyDayID
        self.deckAID = deckAID
        self.deckBID = deckBID
        self.freshNote = freshNote
        self.lapsedNote = lapsedNote
        self.undoneNote = undoneNote
        self.otherDeckNote = otherDeckNote
        self.deletedCardKey = deletedCardKey
    }

    static func make() async throws -> AdaptiveDatabaseFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-Adaptive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let database = try OboeDatabase(path: databaseURL.path)

        let profileID = UUID()
        let studyDayID = UUID()
        let deckAID = UUID()
        let deckBID = UUID()
        let base = baseDate
        let baseMilliseconds = try DatabaseValueCodec.encode(base)

        let profile = SchedulerProfile.standard
        let parametersJSON = String(
            decoding: try JSONEncoder().encode(profile.parameters),
            as: UTF8.self
        )

        try await database.pool.write { db in
            for (index, deckID) in [deckAID, deckBID].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO decks(id, name, sort_order, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        DatabaseValueCodec.encode(deckID),
                        "Deck-\(index)",
                        index,
                        baseMilliseconds,
                        baseMilliseconds
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(profileID),
                    profile.configurationVersion,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parametersJSON,
                    profile.targetRetention,
                    profile.maximumIntervalDays,
                    baseMilliseconds
                ]
            )
            // A single study day wide enough to hold every seeded log.
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-08-01', ?, ?, ?, 50)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    timeZoneID,
                    baseMilliseconds - 90 * 86_400_000,
                    baseMilliseconds + 90 * 86_400_000
                ]
            )
        }

        let fixture = AdaptiveDatabaseFixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            profileID: profileID,
            studyDayID: studyDayID,
            deckAID: deckAID,
            deckBID: deckBID,
            freshNote: SeededNote(noteID: UUID(), deckID: deckAID, cards: [:]),
            lapsedNote: SeededNote(noteID: UUID(), deckID: deckAID, cards: [:]),
            undoneNote: SeededNote(noteID: UUID(), deckID: deckAID, cards: [:]),
            otherDeckNote: SeededNote(noteID: UUID(), deckID: deckBID, cards: [:]),
            deletedCardKey: UUID()
        )

        try await fixture.insertNote(
            fixture.freshNote.noteID,
            deckID: deckAID,
            headword: "新規",
            reading: "しんき",
            meaningZH: "新的"
        )
        try await fixture.insertNote(
            fixture.lapsedNote.noteID,
            deckID: deckAID,
            headword: "難しい",
            reading: "むずかしい",
            meaningZH: "困难"
        )
        try await fixture.insertNote(
            fixture.undoneNote.noteID,
            deckID: deckAID,
            headword: "戻る",
            reading: "もどる",
            meaningZH: "返回"
        )
        try await fixture.insertNote(
            fixture.otherDeckNote.noteID,
            deckID: deckBID,
            headword: "別冊",
            reading: "べっさつ",
            meaningZH: "另册"
        )

        fixture.freshNote.cards = try await fixture.seedCards(
            noteID: fixture.freshNote.noteID,
            templates: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        fixture.lapsedNote.cards = try await fixture.seedCards(
            noteID: fixture.lapsedNote.noteID,
            templates: [.vocabularyJapaneseToChinese, .vocabularyChineseToJapanese]
        )
        fixture.undoneNote.cards = try await fixture.seedCards(
            noteID: fixture.undoneNote.noteID,
            templates: [.vocabularyJapaneseToChinese]
        )
        fixture.otherDeckNote.cards = try await fixture.seedCards(
            noteID: fixture.otherDeckNote.noteID,
            templates: [.vocabularyJapaneseToChinese]
        )

        // 累计遗忘卡：lapses=6、到期 Review 连续 Again 的 ja→zh 卡。
        let lapsedCard = fixture.lapsedNote.cardID(.vocabularyJapaneseToChinese)
        try await fixture.updateScheduling(
            cardID: lapsedCard,
            state: .review,
            dueAt: base.addingTimeInterval(86_400),
            stability: 4.2,
            difficulty: 9.1,
            repetitions: 14,
            lapses: 6,
            firstStudiedAt: base.addingTimeInterval(-60 * 86_400),
            stateVersion: 14
        )
        var stateVersion = 7
        for offset in stride(from: -50, through: -16, by: 7) {
            let reviewedAt = base.addingTimeInterval(TimeInterval(offset * 86_400))
            try await fixture.insertReviewLog(
                cardKey: lapsedCard,
                cardID: lapsedCard,
                noteID: fixture.lapsedNote.noteID,
                deckID: deckAID,
                rating: .again,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 3.0,
                    difficulty: 8.8,
                    repetitions: 10,
                    lapses: 5,
                    stateVersion: stateVersion
                ),
                nextSnapshot: fixture.snapshot(
                    state: .relearning,
                    dueAt: reviewedAt.addingTimeInterval(600_000),
                    stability: 1.0,
                    difficulty: 9.0,
                    repetitions: 11,
                    lapses: 6,
                    stateVersion: stateVersion + 1
                )
            )
            stateVersion += 2
        }

        // 被撤销日志：三条有效记录中最新一条被撤销。
        let undoneCard = fixture.undoneNote.cardID(.vocabularyJapaneseToChinese)
        try await fixture.updateScheduling(
            cardID: undoneCard,
            state: .review,
            dueAt: base.addingTimeInterval(2 * 86_400),
            stability: 6.0,
            difficulty: 5.0,
            repetitions: 3,
            lapses: 1,
            firstStudiedAt: base.addingTimeInterval(-30 * 86_400),
            stateVersion: 3
        )
        for (index, rating) in [ReviewRating.good, .good, .again].enumerated() {
            let reviewedAt = base.addingTimeInterval(TimeInterval((index - 3) * 3 * 86_400))
            try await fixture.insertReviewLog(
                cardKey: undoneCard,
                cardID: undoneCard,
                noteID: fixture.undoneNote.noteID,
                deckID: deckAID,
                rating: rating,
                reviewedAt: reviewedAt,
                previousSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(-86_400),
                    stability: 5.0,
                    difficulty: 5.0,
                    repetitions: index,
                    lapses: index == 2 ? 0 : 1,
                    stateVersion: index
                ),
                nextSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: reviewedAt.addingTimeInterval(3 * 86_400),
                    stability: 6.0,
                    difficulty: 5.0,
                    repetitions: index + 1,
                    lapses: index == 2 ? 1 : 0,
                    stateVersion: index + 1
                ),
                undoneAt: index == 2 ? base.addingTimeInterval(-86_400) : nil
            )
        }

        // 已删除方向留下的孤儿 card_key 历史（card_id SET NULL 由外键处理，
        // 夹具直接以 card_id = NULL 落库模拟删除后的状态）。
        let deletedKey = fixture.deletedCardKey
        try await fixture.insertReviewLog(
            cardKey: deletedKey,
            cardID: nil,
            noteID: fixture.undoneNote.noteID,
            deckID: deckAID,
            rating: .again,
            reviewedAt: base.addingTimeInterval(-10 * 86_400),
            previousSnapshot: fixture.snapshot(
                state: .review,
                dueAt: base.addingTimeInterval(-11 * 86_400),
                stability: 2.0,
                difficulty: 7.0,
                repetitions: 8,
                lapses: 4,
                stateVersion: 8
            ),
            nextSnapshot: fixture.snapshot(
                state: .relearning,
                dueAt: base.addingTimeInterval(-10 * 86_400 + 600_000),
                stability: 1.0,
                difficulty: 7.5,
                repetitions: 9,
                lapses: 5,
                stateVersion: 9
            )
        )

        return fixture
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: - Seeding helpers

    func snapshot(
        state: SchedulingState,
        dueAt: Date,
        stability: Double,
        difficulty: Double,
        repetitions: Int,
        lapses: Int,
        stateVersion: Int,
        firstStudiedAt: Date? = nil,
        lastReviewAt: Date? = nil
    ) -> ReviewSchedulingSnapshot {
        ReviewSchedulingSnapshot(
            scheduling: SchedulingCard(
                dueAt: dueAt,
                stability: stability,
                difficulty: difficulty,
                elapsedDays: 0,
                scheduledDays: 0,
                learningStep: 0,
                repetitions: repetitions,
                lapses: lapses,
                state: state,
                lastReviewAt: lastReviewAt
            ),
            firstStudiedAt: firstStudiedAt,
            stateVersion: stateVersion,
            algorithmVersion: SwiftFSRSReviewScheduler.algorithmVersion,
            profileID: profileID
        )
    }

    func insertNote(
        _ noteID: UUID,
        deckID: UUID,
        kind: String = "vocabulary",
        headword: String,
        reading: String?,
        meaningZH: String,
        origin: String = "manual",
        contentVersion: Int = 1
    ) async throws {
        let now = try DatabaseValueCodec.encode(Self.baseDate)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    kind,
                    headword,
                    reading,
                    meaningZH,
                    origin,
                    contentVersion,
                    now,
                    now
                ]
            )
            try insertHomeMembershipIfSupported(noteID: noteID, deckID: deckID, in: db)
        }
    }

    @discardableResult
    func addCard(
        noteID: UUID,
        template: CardTemplateKind,
        cardID: UUID = UUID()
    ) async throws -> UUID {
        let now = try DatabaseValueCodec.encode(Self.baseDate)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state, due_at_ms,
                        stability, difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, state_version,
                        algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, 0, ?, 0, 0, 0, 0, 0, 0, 0, 0, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    template.rawValue,
                    now,
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    DatabaseValueCodec.encode(profileID)
                ]
            )
        }
        return cardID
    }

    private func seedCards(
        noteID: UUID,
        templates: [CardTemplateKind]
    ) async throws -> [CardTemplateKind: UUID] {
        var result: [CardTemplateKind: UUID] = [:]
        for template in templates {
            result[template] = try await addCard(noteID: noteID, template: template)
        }
        return result
    }

    func updateScheduling(
        cardID: UUID,
        state: SchedulingState,
        dueAt: Date,
        stability: Double,
        difficulty: Double,
        repetitions: Int,
        lapses: Int,
        firstStudiedAt: Date?,
        stateVersion: Int,
        isEnabled: Bool = true
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE cards SET
                        is_enabled = ?, state = ?, due_at_ms = ?,
                        stability = ?, difficulty = ?, reps = ?, lapses = ?,
                        first_studied_at_ms = ?, state_version = ?
                    WHERE id = ?
                    """,
                arguments: [
                    isEnabled,
                    state.rawValue,
                    try DatabaseValueCodec.encode(dueAt),
                    stability,
                    difficulty,
                    repetitions,
                    lapses,
                    try firstStudiedAt.map(DatabaseValueCodec.encode),
                    stateVersion,
                    DatabaseValueCodec.encode(cardID)
                ]
            )
        }
    }

    @discardableResult
    func insertReviewLog(
        cardKey: UUID,
        cardID: UUID?,
        noteID: UUID,
        deckID: UUID,
        rating: ReviewRating,
        reviewedAt: Date,
        previousSnapshot: ReviewSchedulingSnapshot,
        nextSnapshot: ReviewSchedulingSnapshot,
        wasFirstStudy: Bool = false,
        undoneAt: Date? = nil,
        contentVersion: Int = 1
    ) async throws -> SeededLog {
        let logID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let previousJSON = String(
            decoding: try encoder.encode(previousSnapshot),
            as: UTF8.self
        )
        let nextJSON = String(
            decoding: try encoder.encode(nextSnapshot),
            as: UTF8.self
        )
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id, deck_id_at_review,
                        reviewed_at_ms, study_day_id, was_first_study, rating,
                        previous_state_json, next_state_json, duration_ms,
                        content_version, profile_id, algorithm_version, undone_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(logID),
                    DatabaseValueCodec.encode(UUID()),
                    cardID.map(DatabaseValueCodec.encode),
                    DatabaseValueCodec.encode(cardKey),
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deckID),
                    try DatabaseValueCodec.encode(reviewedAt),
                    DatabaseValueCodec.encode(studyDayID),
                    wasFirstStudy,
                    rating.rawValue,
                    previousJSON,
                    nextJSON,
                    900,
                    contentVersion,
                    DatabaseValueCodec.encode(profileID),
                    SwiftFSRSReviewScheduler.algorithmVersion,
                    try undoneAt.map(DatabaseValueCodec.encode)
                ]
            )
        }
        return SeededLog(
            id: logID,
            cardKey: cardKey,
            rating: rating,
            reviewedAt: reviewedAt,
            undoneAt: undoneAt
        )
    }
}
