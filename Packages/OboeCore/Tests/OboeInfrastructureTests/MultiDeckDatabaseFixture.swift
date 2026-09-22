import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// Shared synthetic dataset for the v0.5 multi-deck work (T00).
///
/// Seeded scenarios (all inside one temporary database):
/// - `sharedNote`: vocabulary note whose home deck is A and whose intended
///   membership is {A, B} ("一 Note 两牌组"). All three directions exist;
///   ja→zh carries review history attributed to deck A, the other two
///   directions are still new and hold today's 'new' admission.
/// - `exclusiveNote`: vocabulary note belonging to deck B only ("独占内容"),
///   with three fresh direction cards all admitted today.
/// - `app_settings` with `primary_deck_id = deck A` ("主牌组").
///
/// `note_decks` only exists after schema v13 (T02). The fixture records the
/// intended membership in `membershipSpec` and applies it through
/// `syncMemberships()` when the table is present, so the same seed covers
/// both the v12 baseline and the post-migration assertions in T04–T07.
final class MultiDeckDatabaseFixture: @unchecked Sendable {
    static let baseDate = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-15T01:33:20Z
    static let timeZoneID = "Asia/Shanghai"

    struct SeededNote: Sendable {
        let noteID: UUID
        let homeDeckID: UUID
        let membershipDeckIDs: Set<UUID>
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
        let deckIDAtReview: UUID
        let undoneAt: Date?
    }

    let directoryURL: URL
    let databaseURL: URL
    let database: OboeDatabase
    let profileID: UUID
    let studyDayID: UUID
    let previousStudyDayID: UUID
    let deckAID: UUID
    let deckBID: UUID

    private(set) var sharedNote: SeededNote
    private(set) var exclusiveNote: SeededNote
    private(set) var seededLogs: [SeededLog] = []

    /// Intended `note_decks` content once schema v13 exists.
    var membershipSpec: [UUID: (homeDeckID: UUID, deckIDs: Set<UUID>)] {
        [
            sharedNote.noteID: (sharedNote.homeDeckID, sharedNote.membershipDeckIDs),
            exclusiveNote.noteID: (exclusiveNote.homeDeckID, exclusiveNote.membershipDeckIDs)
        ]
    }

    private init(
        directoryURL: URL,
        databaseURL: URL,
        database: OboeDatabase,
        profileID: UUID,
        studyDayID: UUID,
        previousStudyDayID: UUID,
        deckAID: UUID,
        deckBID: UUID,
        sharedNote: SeededNote,
        exclusiveNote: SeededNote
    ) {
        self.directoryURL = directoryURL
        self.databaseURL = databaseURL
        self.database = database
        self.profileID = profileID
        self.studyDayID = studyDayID
        self.previousStudyDayID = previousStudyDayID
        self.deckAID = deckAID
        self.deckBID = deckBID
        self.sharedNote = sharedNote
        self.exclusiveNote = exclusiveNote
    }

    static func make() async throws -> MultiDeckDatabaseFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-MultiDeck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        let database = try OboeDatabase(path: databaseURL.path)

        let profileID = UUID()
        let studyDayID = UUID()
        let previousStudyDayID = UUID()
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
                        index == 0 ? "主牌组" : "共享牌组",
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
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, primary_deck_id
                    ) VALUES (1, 1, ?, 10, ?)
                    """,
                arguments: [
                    timeZoneID,
                    DatabaseValueCodec.encode(deckAID)
                ]
            )
            // 昨日学习日保存评分历史；今日学习日覆盖 baseDate 用于 admission。
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-09-14', ?, ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(previousStudyDayID),
                    timeZoneID,
                    baseMilliseconds - 30 * 3_600_000,
                    baseMilliseconds - 6 * 3_600_000
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms, ends_at_ms, new_limit
                    ) VALUES (?, '2026-09-15', ?, ?, ?, 10)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    timeZoneID,
                    baseMilliseconds - 6 * 3_600_000,
                    baseMilliseconds + 18 * 3_600_000
                ]
            )
        }

        let fixture = MultiDeckDatabaseFixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            profileID: profileID,
            studyDayID: studyDayID,
            previousStudyDayID: previousStudyDayID,
            deckAID: deckAID,
            deckBID: deckBID,
            sharedNote: SeededNote(
                noteID: UUID(),
                homeDeckID: deckAID,
                membershipDeckIDs: [deckAID, deckBID],
                cards: [:]
            ),
            exclusiveNote: SeededNote(
                noteID: UUID(),
                homeDeckID: deckBID,
                membershipDeckIDs: [deckBID],
                cards: [:]
            )
        )

        try await fixture.insertNote(
            fixture.sharedNote.noteID,
            deckID: deckAID,
            headword: "共有",
            reading: "きょうゆう",
            meaningZH: "共享"
        )
        try await fixture.insertNote(
            fixture.exclusiveNote.noteID,
            deckID: deckBID,
            headword: "独占",
            reading: "どくせん",
            meaningZH: "独占"
        )

        fixture.sharedNote.cards = try await fixture.seedCards(
            noteID: fixture.sharedNote.noteID,
            templates: [
                .vocabularyJapaneseToChinese,
                .vocabularyChineseToJapanese,
                .vocabularyListening
            ]
        )
        fixture.exclusiveNote.cards = try await fixture.seedCards(
            noteID: fixture.exclusiveNote.noteID,
            templates: [
                .vocabularyJapaneseToChinese,
                .vocabularyChineseToJapanese,
                .vocabularyListening
            ]
        )

        // 评分历史：ja→zh 昨日首学（归归因 deck A），今日到期进入 review 态。
        let reviewedCard = fixture.sharedNote.cardID(.vocabularyJapaneseToChinese)
        try await fixture.updateScheduling(
            cardID: reviewedCard,
            state: .review,
            dueAt: base.addingTimeInterval(-3_600),
            stability: 5.4,
            difficulty: 6.2,
            repetitions: 2,
            lapses: 0,
            firstStudiedAt: base.addingTimeInterval(-86_400),
            stateVersion: 2
        )
        let firstStudyAt = base.addingTimeInterval(-86_400)
        fixture.seededLogs.append(
            try await fixture.insertReviewLog(
                cardKey: reviewedCard,
                cardID: reviewedCard,
                noteID: fixture.sharedNote.noteID,
                deckID: deckAID,
                rating: .good,
                reviewedAt: firstStudyAt,
                studyDayID: previousStudyDayID,
                previousSnapshot: fixture.snapshot(
                    state: .new,
                    dueAt: firstStudyAt,
                    stability: 0,
                    difficulty: 0,
                    repetitions: 0,
                    lapses: 0,
                    stateVersion: 0
                ),
                nextSnapshot: fixture.snapshot(
                    state: .learning,
                    dueAt: firstStudyAt.addingTimeInterval(600),
                    stability: 1.2,
                    difficulty: 6.0,
                    repetitions: 1,
                    lapses: 0,
                    stateVersion: 1
                ),
                wasFirstStudy: true
            )
        )
        fixture.seededLogs.append(
            try await fixture.insertReviewLog(
                cardKey: reviewedCard,
                cardID: reviewedCard,
                noteID: fixture.sharedNote.noteID,
                deckID: deckAID,
                rating: .good,
                reviewedAt: base.addingTimeInterval(-7_200),
                studyDayID: previousStudyDayID,
                previousSnapshot: fixture.snapshot(
                    state: .learning,
                    dueAt: base.addingTimeInterval(-7_800),
                    stability: 1.2,
                    difficulty: 6.0,
                    repetitions: 1,
                    lapses: 0,
                    stateVersion: 1
                ),
                nextSnapshot: fixture.snapshot(
                    state: .review,
                    dueAt: base.addingTimeInterval(-3_600),
                    stability: 5.4,
                    difficulty: 6.2,
                    repetitions: 2,
                    lapses: 0,
                    stateVersion: 2
                )
            )
        )

        // 今日 new admission：sharedNote 的两个未学方向 + exclusiveNote 全部
        // 三方向一起收录（一个 Note 只占一个新词额度，方向成组入场）。
        var admissionOffset: Int64 = 0
        for card in [
            fixture.sharedNote.cardID(.vocabularyChineseToJapanese),
            fixture.sharedNote.cardID(.vocabularyListening),
            fixture.exclusiveNote.cardID(.vocabularyJapaneseToChinese),
            fixture.exclusiveNote.cardID(.vocabularyChineseToJapanese),
            fixture.exclusiveNote.cardID(.vocabularyListening)
        ] {
            try await fixture.admitNewCard(cardID: card, offset: admissionOffset)
            admissionOffset += 1
        }

        try await fixture.syncMemberships()
        return fixture
    }

    func remove() {
        try? database.close()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: - Seeding helpers

    /// Applies `membershipSpec` when `note_decks` exists (post-v13); a no-op
    /// on the v12 baseline so the fixture stays usable before T02 lands.
    func syncMemberships() async throws {
        try await database.pool.write { db in
            guard try db.tableExists("note_decks") else { return }
            for (noteID, spec) in membershipSpec {
                for deckID in spec.deckIDs {
                    try db.execute(
                        sql: """
                            INSERT INTO note_decks(note_id, deck_id, added_at_ms)
                            VALUES (?, ?, ?)
                            ON CONFLICT(note_id, deck_id) DO NOTHING
                            """,
                        arguments: [
                            DatabaseValueCodec.encode(noteID),
                            DatabaseValueCodec.encode(deckID),
                            try DatabaseValueCodec.encode(Self.baseDate)
                        ]
                    )
                }
            }
        }
    }

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

    func admitNewCard(cardID: UUID, offset: Int64) async throws {
        let admittedAt = try DatabaseValueCodec.encode(Self.baseDate) + offset
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO daily_tasks(
                        study_day_id, card_id, category_at_admission, admitted_at_ms
                    ) VALUES (?, ?, 'new', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(studyDayID),
                    DatabaseValueCodec.encode(cardID),
                    admittedAt
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
        studyDayID: UUID? = nil,
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
                    DatabaseValueCodec.encode(studyDayID ?? self.studyDayID),
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
            deckIDAtReview: deckID,
            undoneAt: undoneAt
        )
    }
}
