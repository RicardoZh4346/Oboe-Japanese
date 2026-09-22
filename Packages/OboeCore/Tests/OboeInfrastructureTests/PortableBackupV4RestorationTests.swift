import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T00B: the v4 contract — exports always carry the four Adaptive settings,
/// `vocabulary_listening` cards and strict `ai_repair` drafts; v1–v3 restores
/// fill the new settings defaults; uncommitted repair drafts whose target no
/// longer resolves degrade to `adoptionBlocked` instead of failing.
final class PortableBackupV4RestorationTests: XCTestCase {
    func testV4RoundTripPreservesSettingsTogglesListeningCardAndRepairDrafts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let prepared = try await preparer.prepare(fileURL: backup.url)

        XCTAssertEqual(prepared.sourceFormatVersion, PortableBackupFormat.currentVersion)
        XCTAssertEqual(prepared.preparedFormatVersion, PortableBackupFormat.currentVersion)
        XCTAssertTrue(prepared.restoresInboxData)
        XCTAssertEqual(prepared.backup.draftCount, 4)
        // 词汇笔记备份含 ja→zh + 听力两方向，恢复时 v12 补齐中文→日语 → 4 张卡。
        XCTAssertEqual(prepared.backup.cardCount, 4)

        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        let restored = try await queue.read { db in
            let settingsRow = try XCTUnwrap(try Row.fetchOne(
                db, sql: "SELECT * FROM app_settings WHERE id = 1"
            ))
            return (
                settings: (
                    settingsRow["typed_answer_zh_ja"] as Bool,
                    settingsRow["auto_play_listening_audio"] as Bool,
                    settingsRow["typed_answer_listening"] as Bool,
                    settingsRow["leech_reminders_enabled"] as Bool
                ),
                templates: try String.fetchAll(
                    db,
                    sql: "SELECT template_kind FROM cards ORDER BY template_kind"
                ),
                drafts: try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, payload_version, payload_json
                        FROM drafts ORDER BY updated_at_ms, id
                        """
                ).map {
                    (
                        $0["id"] as String,
                        $0["payload_version"] as Int,
                        $0["payload_json"] as String
                    )
                }
            )
        }
        XCTAssertEqual(restored.settings.0, true)
        XCTAssertEqual(restored.settings.1, false)
        XCTAssertEqual(restored.settings.2, true)
        XCTAssertEqual(restored.settings.3, false)
        XCTAssertEqual(
            restored.templates,
            [
                "grammar_form_explanation", "vocabulary_ja_zh",
                "vocabulary_listening", "vocabulary_zh_ja"
            ].sorted()
        )

        let draftByID = Dictionary(
            uniqueKeysWithValues: restored.drafts.map { ($0.0, $0.2) }
        )
        let liveEnvelope = try decodeEnvelope(draftByID[seed.encodedLiveDraftID])
        XCTAssertFalse(liveEnvelope.adoptionBlocked)
        XCTAssertEqual(liveEnvelope.phase, .suggested)

        let blockedEnvelope = try decodeEnvelope(draftByID[seed.encodedBlockedDraftID])
        XCTAssertTrue(
            blockedEnvelope.adoptionBlocked,
            "uncommitted draft with a deleted target must degrade, not reject"
        )

        let committedEnvelope = try decodeEnvelope(draftByID[seed.encodedCommittedDraftID])
        XCTAssertEqual(committedEnvelope.phase, .committed)
        XCTAssertFalse(committedEnvelope.adoptionBlocked)
        XCTAssertEqual(
            committedEnvelope.commitReceipt?.payloadHash,
            seed.receiptHash
        )
        try await preparer.discard(prepared)
    }

    func testV1V2V3BackupsRestoreWithAdaptiveDefaults() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        for version in [3, 2, 1] {
            let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
            let legacyURL = fixture.rootURL.appendingPathComponent(
                "legacy-v\(version).oboe-backup"
            )
            try rewriteBackup(backup.url, to: legacyURL) { objects in
                downgradeBackupToLegacyFormat(&objects, version: version)
            }
            let preparer = PortableBackupRestorationPreparer(
                currentDatabase: current,
                workingDirectoryURL: fixture.preparationsURL
            )
            let prepared = try await preparer.prepare(fileURL: legacyURL)
            XCTAssertEqual(prepared.sourceFormatVersion, version)

            let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
            let settings = try await queue.read { db in
                let row = try XCTUnwrap(try Row.fetchOne(
                    db, sql: "SELECT * FROM app_settings WHERE id = 1"
                ))
                return (
                    row["typed_answer_zh_ja"] as Bool,
                    row["auto_play_listening_audio"] as Bool,
                    row["typed_answer_listening"] as Bool,
                    row["leech_reminders_enabled"] as Bool,
                    row["auto_play_word_audio"] as Bool
                )
            }
            XCTAssertEqual(settings.0, false)
            XCTAssertEqual(settings.1, true)
            XCTAssertEqual(settings.2, false)
            XCTAssertEqual(settings.3, true)
            XCTAssertEqual(settings.4, true)
            try await preparer.discard(prepared)
            try queue.close()
            try current.close()
        }
    }

    /// The template↔kind invariant is a restore-time semantic check: a
    /// vocabulary_* card on a grammar note (or a grammar card on a vocabulary
    /// note) can never enter the prepared database.
    func testCardTemplateKindMustMatchItsNoteKind() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let mismatchedURL = fixture.rootURL.appendingPathComponent("mismatched.oboe-backup")
        try rewriteBackup(backup.url, to: mismatchedURL) { objects in
            self.mutateRecord(&objects, type: "card") { record in
                guard record["template_kind"] as? String == "grammar_form_explanation" else {
                    return
                }
                record["template_kind"] = "vocabulary_listening"
            }
        }
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: try OboeDatabase(path: fixture.currentDatabaseURL.path),
            workingDirectoryURL: fixture.preparationsURL
        )
        await XCTAssertThrowsPreparationError {
            _ = try await preparer.prepare(fileURL: mismatchedURL)
        }
    }

    func testMalformedRepairDraftsAreRejectedBeforeTouchingCurrent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        try await seedSource(source, seed: seed)
        try await seedCurrent(current)
        let backup = try await export(source, fixture: fixture)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )

        let cases: [(String, (inout [[String: Any]]) -> Void)] = [
            ("unknown payload_version", { objects in
                self.mutateDraft(&objects, id: seed.encodedLiveDraftID) { record in
                    record["payload_version"] = 99
                }
            }),
            ("undecodable envelope", { objects in
                self.mutateDraft(&objects, id: seed.encodedLiveDraftID) { record in
                    record["payload_json"] = #"{"schemaVersion":1}"#
                }
            }),
            ("committed without receipt", { objects in
                self.mutateDraft(&objects, id: seed.encodedLiveDraftID) { record in
                    record["payload_json"] = seed.committedWithoutReceiptJSON
                }
            }),
            ("bad receipt hash", { objects in
                self.mutateDraft(&objects, id: seed.encodedCommittedDraftID) { record in
                    record["payload_json"] = seed.badHashReceiptJSON
                }
            }),
            ("unknown draft kind", { objects in
                self.mutateDraft(&objects, id: seed.encodedLiveDraftID) { record in
                    record["draft_kind"] = "future_draft"
                }
            })
        ]

        for (index, entry) in cases.enumerated() {
            let (name, mutate) = entry
            let mutatedURL = fixture.rootURL.appendingPathComponent(
                "mutated-v4-\(index).oboe-backup"
            )
            try rewriteBackup(backup.url, to: mutatedURL, transform: mutate)
            do {
                _ = try await preparer.prepare(fileURL: mutatedURL)
                XCTFail("\(name) must be rejected")
            } catch is PortableBackupPreparationError {
                // Expected — malformed repair drafts fail preparation.
            }
        }

        let intact = try await current.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1
        }
        XCTAssertEqual(intact, 1, "rejected preparations must not touch current data")
    }

    func testExportedSettingsRecordCarriesTheFourNewKeys() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let backup = try await export(source, fixture: fixture)

        let objects = try String(contentsOf: backup.url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        let settings = try XCTUnwrap(
            objects.first { $0["recordType"] as? String == "settings" }
        )
        XCTAssertEqual(settings["typed_answer_zh_ja"] as? Int, 1)
        XCTAssertEqual(settings["auto_play_listening_audio"] as? Int, 0)
        XCTAssertEqual(settings["typed_answer_listening"] as? Int, 1)
        XCTAssertEqual(settings["leech_reminders_enabled"] as? Int, 0)
        XCTAssertEqual(settings["primary_deck_id"] as? NSNull, NSNull())
    }

    /// v5: the primary-deck choice round-trips through export → prepare →
    /// restore, and the next reconcile keeps honouring it.
    func testPrimaryDeckSurvivesBackupRoundTrip() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = try Seed()
        let source = try OboeDatabase(path: fixture.sourceDatabaseURL.path)
        try await seedSource(source, seed: seed)
        let primary = seed.deckID
        _ = try await GRDBStudyDayPlanningRepository(database: source)
            .updatePrimaryDeck(primary)
        let backup = try await export(source, fixture: fixture)

        let objects = try String(contentsOf: backup.url, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { line in
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        let settings = try XCTUnwrap(
            objects.first { $0["recordType"] as? String == "settings" }
        )
        XCTAssertEqual(settings["primary_deck_id"] as? String, primary.uuidString.lowercased())

        let current = try OboeDatabase(path: fixture.currentDatabaseURL.path)
        let preparer = PortableBackupRestorationPreparer(
            currentDatabase: current,
            workingDirectoryURL: fixture.preparationsURL
        )
        let prepared = try await preparer.prepare(fileURL: backup.url)
        let queue = try DatabaseQueue(path: prepared.temporaryDatabaseURL.path)
        let restoredPrimary = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT primary_deck_id FROM app_settings WHERE id = 1")
        }
        XCTAssertEqual(restoredPrimary, primary.uuidString.lowercased())
        try queue.close()
    }
}

private extension PortableBackupV4RestorationTests {
    struct Fixture {
        let rootURL: URL
        let sourceDatabaseURL: URL
        let currentDatabaseURL: URL
        let exportsURL: URL
        let preparationsURL: URL
        let exportedAt = Date(timeIntervalSince1970: 1_789_056_000.123)

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PortableBackupV4RestorationTests-\(UUID().uuidString)",
                isDirectory: true
            )
            sourceDatabaseURL = rootURL.appendingPathComponent("source.sqlite")
            currentDatabaseURL = rootURL.appendingPathComponent("current.sqlite")
            exportsURL = rootURL.appendingPathComponent("exports", isDirectory: true)
            preparationsURL = rootURL.appendingPathComponent("preparations", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    struct Seed {
        let deckID = UUID()
        let vocabularyNoteID = UUID()
        let grammarNoteID = UUID()
        let jaZhCardID = UUID()
        let listeningCardID = UUID()
        let grammarCardID = UUID()
        let profileID = UUID()
        let liveDraftID = UUID()
        let blockedDraftID = UUID()
        let committedDraftID = UUID()
        let vocabularyDraftID = UUID()
        let operationID = UUID()
        let receiptHash = String(repeating: "b", count: 64)
        let committedWithoutReceiptJSON: String
        let badHashReceiptJSON: String

        var encodedLiveDraftID: String { DatabaseValueCodec.encode(liveDraftID) }
        var encodedBlockedDraftID: String { DatabaseValueCodec.encode(blockedDraftID) }
        var encodedCommittedDraftID: String { DatabaseValueCodec.encode(committedDraftID) }

        init() throws {
            committedWithoutReceiptJSON = try AIRepairDraftCodec.encode(
                AIRepairDraftEnvelope(
                    targetNoteID: vocabularyNoteID,
                    targetCardID: jaZhCardID,
                    expectedContentVersion: 1,
                    targetCardEnabled: true,
                    affectedTemplateKinds: [.vocabularyJapaneseToChinese],
                    operationID: operationID,
                    phase: .committing
                )
            ).replacingOccurrences(of: #""phase":"committing""#, with: #""phase":"committed""#)
            badHashReceiptJSON = try AIRepairDraftCodec.encode(
                AIRepairDraftEnvelope(
                    targetNoteID: UUID(),
                    targetCardID: UUID(),
                    expectedContentVersion: 1,
                    targetCardEnabled: false,
                    affectedTemplateKinds: [.vocabularyJapaneseToChinese],
                    operationID: operationID,
                    phase: .committed,
                    commitReceipt: AIRepairCommitReceipt(
                        operationID: operationID,
                        payloadHash: receiptHash,
                        createdNoteIDs: [UUID()],
                        createdCardIDs: [UUID()],
                        originalCardDisposition: .delete
                    )
                )
            ).replacingOccurrences(of: receiptHash, with: "not-a-sha256")
        }
    }

    func export(
        _ database: OboeDatabase,
        fixture: Fixture
    ) async throws -> PortableBackupExport {
        try await PortableBackupExporter(
            database: database,
            workingDirectoryURL: fixture.exportsURL
        ).export(appVersion: "test", at: fixture.exportedAt)
    }

    func decodeEnvelope(_ rawJSON: String?) throws -> AIRepairDraftEnvelope {
        let json = try XCTUnwrap(rawJSON)
        return try AIRepairDraftCodec.decode(json)
    }

    func seedSource(_ database: OboeDatabase, seed: Seed) async throws {
        let encode: @Sendable (UUID) -> String = DatabaseValueCodec.encode
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, 'v4 源', 0, 1, 2)",
                arguments: [encode(seed.deckID)]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '食べる', 'たべる', '吃',
                              'manual', 1, 1, 2)
                    """,
                arguments: [encode(seed.vocabularyNoteID), encode(seed.deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: seed.vocabularyNoteID, deckID: seed.deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'grammar', '〜たことがある', '曾经～过',
                              'manual', 1, 1, 2)
                    """,
                arguments: [encode(seed.grammarNoteID), encode(seed.deckID)]
            )
            try insertHomeMembershipIfSupported(noteID: seed.grammarNoteID, deckID: seed.deckID, in: db)
            let parameters = String(
                decoding: try JSONEncoder().encode(SchedulerProfile.fsrs6DefaultParameters),
                as: UTF8.self
            )
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version, library_revision,
                        parameters_json, desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, 'fsrs-6.0-default-r90-v1', 'FSRS-6.0', ?, ?, 0.9, 36500, 1)
                    """,
                arguments: [
                    encode(seed.profileID),
                    SwiftFSRSReviewScheduler.dependencyRevision,
                    parameters
                ]
            )
            for (cardID, noteID, template) in [
                (seed.jaZhCardID, seed.vocabularyNoteID, "vocabulary_ja_zh"),
                (seed.listeningCardID, seed.vocabularyNoteID, "vocabulary_listening"),
                (seed.grammarCardID, seed.grammarNoteID, "grammar_form_explanation")
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO cards(
                            id, note_id, template_kind, is_enabled, state, due_at_ms,
                            stability, difficulty, reps, lapses, scheduled_days,
                            elapsed_days, learning_step, state_version,
                            algorithm_version, profile_id
                        ) VALUES (?, ?, ?, 1, 0, 1789056000000, 0, 0, 0, 0,
                                  0, 0, 0, 0, 'FSRS-6.0', ?)
                        """,
                    arguments: [
                        encode(cardID), encode(noteID), template, encode(seed.profileID)
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id,
                        daily_new_card_limit, retention_preset,
                        auto_play_word_audio, auto_play_example_audio, appearance,
                        typed_answer_zh_ja, auto_play_listening_audio,
                        typed_answer_listening, leech_reminders_enabled
                    ) VALUES (1, 1, 'Asia/Shanghai', 10, 90, 1, 0, 'system',
                              1, 0, 1, 0)
                    """
            )
            let drafts: [(UUID, String, Int, String)] = [
                (
                    seed.liveDraftID, "ai_repair", 1,
                    try AIRepairDraftCodec.encode(
                        AIRepairDraftEnvelope(
                            targetNoteID: seed.vocabularyNoteID,
                            targetCardID: seed.jaZhCardID,
                            expectedContentVersion: 1,
                            targetCardEnabled: true,
                            affectedTemplateKinds: [
                                .vocabularyJapaneseToChinese, .vocabularyListening
                            ],
                            userComment: "例句偏长",
                            requestGeneration: 1,
                            response: AIRepairResponse(
                                problemTypes: [.exampleTooComplex],
                                summary: "例句过长",
                                suggestions: [
                                    AIRepairSuggestion(
                                        type: .replaceExample,
                                        title: "替换例句",
                                        reason: "更短更具代表性"
                                    )
                                ]
                            ),
                            phase: .suggested
                        )
                    )
                ),
                (
                    seed.blockedDraftID, "ai_repair", 1,
                    try AIRepairDraftCodec.encode(
                        AIRepairDraftEnvelope(
                            targetNoteID: UUID(),
                            targetCardID: UUID(),
                            expectedContentVersion: 2,
                            targetCardEnabled: true,
                            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
                            requestGeneration: 1,
                            phase: .editing
                        )
                    )
                ),
                (
                    seed.committedDraftID, "ai_repair", 1,
                    try AIRepairDraftCodec.encode(
                        AIRepairDraftEnvelope(
                            targetNoteID: UUID(),
                            targetCardID: UUID(),
                            expectedContentVersion: 4,
                            targetCardEnabled: false,
                            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
                            requestGeneration: 3,
                            operationID: seed.operationID,
                            phase: .committed,
                            commitReceipt: AIRepairCommitReceipt(
                                operationID: seed.operationID,
                                payloadHash: seed.receiptHash,
                                createdNoteIDs: [UUID()],
                                createdCardIDs: [UUID(), UUID()],
                                originalCardDisposition: .pause
                            )
                        )
                    )
                ),
                (seed.vocabularyDraftID, "vocabulary", 1, #"{"headword":"食べる"}"#)
            ]
            for (index, draft) in drafts.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO drafts(
                            id, draft_kind, payload_version, payload_json,
                            provider_id, model_id, prompt_version, updated_at_ms
                        ) VALUES (?, ?, ?, ?, 'provider', 'model', 'repair-v1', ?)
                        """,
                    arguments: [
                        encode(draft.0), draft.1, draft.2, draft.3,
                        1_789_056_000_000 + index
                    ]
                )
            }
        }
    }

    func seedCurrent(_ database: OboeDatabase) async throws {
        let deckID = DatabaseValueCodec.encode(UUID())
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO decks VALUES (?, '当前库', 0, 1, 2)",
                arguments: [deckID]
            )
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, meaning_zh,
                        origin, content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'vocabulary', '飲む', '喝',
                              'manual', 1, 1, 2)
                    """,
                arguments: [DatabaseValueCodec.encode(UUID()), deckID]
            )
        }
    }

    // （seedCurrent 的 Note 无 note_decks 行，验证导出 UNION 兜底路径。）

    func mutateRecord(
        _ objects: inout [[String: Any]],
        type: String,
        mutate: (inout [String: Any]) -> Void
    ) {
        for index in objects.indices
        where objects[index]["recordType"] as? String == type {
            mutate(&objects[index])
        }
    }

    func mutateDraft(
        _ objects: inout [[String: Any]],
        id encodedID: String,
        mutate: (inout [String: Any]) -> Void
    ) {
        for index in objects.indices
        where objects[index]["recordType"] as? String == "draft"
            && objects[index]["id"] as? String == encodedID {
            mutate(&objects[index])
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsPreparationError(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected preparation error", file: file, line: line)
        } catch is PortableBackupPreparationError {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
