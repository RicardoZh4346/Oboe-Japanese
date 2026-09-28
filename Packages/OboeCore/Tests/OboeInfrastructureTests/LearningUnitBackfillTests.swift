import Foundation
import GRDB
import XCTest
import OboeDomain
@testable import OboeInfrastructure

/// v0.7.5 S05 存量回填 + 词典换库重绑定端到端测试。
/// 覆盖：linked/unlinked/local/conflict Note 分派、known→tooEasy /
/// ignored→仅审计、多 Note primary 选举、守恒审计、幂等重放、
/// 中断续跑、projection flag 随迁、指纹重绑四分支（unique/
/// ambiguous/stale + 旧 alias superseded）、Bundle.module fixture。
final class LearningUnitBackfillTests: XCTestCase {
    private typealias Service = LearningUnitBackfillService
    private typealias Alias = LearningUnitDictionaryAlias

    private var directory: URL!
    private var pool: DatabasePool!
    private var deckID: UUID!
    private var profileID: UUID!
    private var studyDayID: UUID!
    private let atMs: Int64 = 1_700_000_000_000
    private let dictVersion = "dict-v1"

    override func setUpWithError() throws {
        directory = DictionaryS19Fixture.temporaryDirectory("LUBackfill")
        pool = try DictionaryS19Fixture.makeAppPool(into: directory)
        deckID = UUID()
        profileID = UUID()
        studyDayID = UUID()
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO decks(id, name, sort_order, created_at_ms,
                                      updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(deckID)])
            try db.execute(
                sql: """
                    INSERT INTO scheduler_profiles(
                        id, configuration_version, algorithm_version,
                        library_revision, parameters_json,
                        desired_retention, max_interval_days, created_at_ms
                    ) VALUES (?, 'cfg-1', 'fsrs-5', 'rev1', '{}',
                              0.9, 365, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(profileID)])
            try db.execute(
                sql: """
                    INSERT INTO study_days(
                        id, local_date, time_zone_id, starts_at_ms,
                        ends_at_ms, new_limit
                    ) VALUES (?, '2025-01-01', 'Asia/Shanghai', 0,
                              86400000, 10)
                    """,
                arguments: [DatabaseValueCodec.encode(studyDayID)])
        }
    }

    override func tearDownWithError() throws {
        try? pool?.close()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - 词典 fixture（显式 sense id + tags/受限——GRDB 通道实测）

    private struct DSense {
        var id: Int64
        var pos: [String] = []
        var tags: [(String, String)] = []
        var en: [String] = []
        var zh: [String] = []
        var rForms: [String] = []
        var rReadings: [String] = []
    }

    private struct DEntry {
        var id: Int64
        var forms: [String]
        var readings: [String] = []
        var senses: [DSense]
    }

    private func makeDict(
        _ entries: [DEntry],
        datasetVersion: String? = nil
    ) throws -> DatabaseQueue {
        let version = datasetVersion ?? dictVersion
        let queue = try DatabaseQueue()
        try queue.write { db in
            try DictionaryS19Fixture.createSchema(
                db, datasetVersion: version)
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT INTO entries(id, primary_form, common_rank)
                        VALUES (?,?,NULL)
                        """,
                    arguments: [entry.id, entry.forms[0]])
                var formIDs: [String: Int64] = [:]
                for form in entry.forms {
                    try db.execute(
                        sql: """
                            INSERT INTO forms(entry_id, text, normalized_text)
                            VALUES (?,?,?)
                            """,
                        arguments: [
                            entry.id, form,
                            SearchTextNormalizer.normalize(form)])
                    formIDs[form] = db.lastInsertedRowID
                }
                var readingIDs: [String: Int64] = [:]
                for reading in entry.readings {
                    try db.execute(
                        sql: """
                            INSERT INTO readings(
                                entry_id, reading, normalized_reading)
                            VALUES (?,?,?)
                            """,
                        arguments: [
                            entry.id, reading,
                            SearchTextNormalizer.normalize(reading)])
                    readingIDs[reading] = db.lastInsertedRowID
                }
                for (order, sense) in entry.senses.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO senses(id, entry_id, sense_order)
                            VALUES (?,?,?)
                            """,
                        arguments: [sense.id, entry.id, order])
                    for code in sense.pos {
                        try db.execute(
                            sql: """
                                INSERT INTO sense_pos(sense_id, code)
                                VALUES (?,?)
                                """,
                            arguments: [sense.id, code])
                    }
                    for (category, code) in sense.tags {
                        try db.execute(
                            sql: """
                                INSERT INTO sense_tags(
                                    sense_id, category, code)
                                VALUES (?,?,?)
                                """,
                            arguments: [sense.id, category, code])
                    }
                    for (glossOrder, text) in sense.en.enumerated() {
                        try db.execute(
                            sql: """
                                INSERT INTO glosses(
                                    sense_id, language, text, gloss_order,
                                    source_id, is_machine_generated)
                                VALUES (?,'eng',?,?,'test',0)
                                """,
                            arguments: [sense.id, text, glossOrder])
                    }
                    for (glossOrder, text) in sense.zh.enumerated() {
                        try db.execute(
                            sql: """
                                INSERT INTO glosses(
                                    sense_id, language, text, gloss_order,
                                    source_id, is_machine_generated)
                                VALUES (?,'zho',?,?,'test',0)
                                """,
                            arguments: [sense.id, text, glossOrder])
                    }
                    for form in sense.rForms {
                        try db.execute(
                            sql: """
                                INSERT INTO sense_form_restrictions(
                                    sense_id, form_id)
                                VALUES (?,?)
                                """,
                            arguments: [sense.id, formIDs[form]!])
                    }
                    for reading in sense.rReadings {
                        try db.execute(
                            sql: """
                                INSERT INTO sense_reading_restrictions(
                                    sense_id, reading_id)
                                VALUES (?,?)
                                """,
                            arguments: [sense.id, readingIDs[reading]!])
                    }
                }
            }
            try db.execute(sql: """
                UPDATE dictionary_metadata SET value =
                    (SELECT CAST(COUNT(*) AS TEXT) FROM entries)
                WHERE key = 'entry_count';
                UPDATE dictionary_metadata SET value =
                    (SELECT CAST(COUNT(*) AS TEXT) FROM senses)
                WHERE key = 'sense_count';
                UPDATE dictionary_metadata SET value =
                    (SELECT CAST(COUNT(*) AS TEXT) FROM glosses)
                WHERE key = 'gloss_count';
                """)
        }
        return queue
    }

    private func source(
        _ dictQueue: DatabaseQueue
    ) -> GRDBLearningUnitSenseSnapshotReader {
        GRDBLearningUnitSenseSnapshotReader(reader: dictQueue)
    }

    private func verifier(
        _ dictQueue: DatabaseQueue
    ) -> GRDBLexemeEntryVerifier {
        GRDBLexemeEntryVerifier(reader: dictQueue)
    }

    private func makeService(
        batchSize: Int = 200
    ) -> LearningUnitBackfillService {
        LearningUnitBackfillService(
            pool: pool, batchSize: batchSize,
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    // MARK: - app 库夹具

    private func insertNote(
        headword: String,
        reading: String? = nil,
        kind: String = "vocabulary",
        id: UUID = UUID(),
        createdAtMs: Int64 = 1
    ) async throws -> UUID {
        let deck = deckID!
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO notes(
                        id, deck_id, kind, headword, reading, meaning_zh,
                        part_of_speech, is_favorite, origin,
                        content_version, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'm', NULL, 0, 'manual', 1, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(deck),
                    kind, headword, reading, createdAtMs,
                ])
        }
        return id
    }

    private func insertContext(
        noteID: UUID,
        entryID: Int64? = nil,
        datasetVersion: String? = nil,
        senseKey: String? = nil,
        isPrimary: Bool = true
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source_contexts(
                        id, note_id, source_type, is_primary,
                        dictionary_entry_id, dictionary_version,
                        dictionary_sense_key, created_at_ms
                    ) VALUES (?, ?, 'dictionary', ?, ?, ?, ?, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(noteID),
                    isPrimary ? 1 : 0, entryID, datasetVersion, senseKey,
                ])
        }
    }

    private func insertLexeme(
        provider: String = "jmdict",
        entryID: Int64? = nil,
        writtenForm: String,
        reading: String? = nil,
        id: UUID = UUID()
    ) async throws -> UUID {
        let version = dictVersion
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexemes(
                        id, provider, external_id, entry_id, written_form,
                        reading, normalized_lemma, pos_family, identity_key,
                        dictionary_version_at_resolution, resolution_status,
                        created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, 'resolved', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id), provider,
                    "ext-\(id.uuidString)", entryID, writtenForm, reading,
                    SearchTextNormalizer.normalize(writtenForm),
                    "lk|\(id.uuidString)", version,
                ])
            return id
        }
    }

    private func linkLexeme(_ lexemeID: UUID, noteID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexeme_note_links(
                        lexeme_id, note_id, association_origin,
                        created_at_ms
                    ) VALUES (?, ?, 'userConfirmed', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID),
                    DatabaseValueCodec.encode(noteID)])
        }
    }

    private func insertOverride(
        _ lexemeID: UUID, state: String
    ) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO vocabulary_knowledge_overrides(
                        lexeme_id, state, updated_at_ms
                    ) VALUES (?, ?, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(lexemeID), state])
        }
    }

    private func insertBinding(
        _ lexemeID: UUID, entryID: Int64,
        tier: String = "sourceContext",
        dataset: String? = nil,
        status: String = "current"
    ) async throws {
        let version = dataset ?? dictVersion
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO lexeme_dictionary_bindings(
                        lexeme_id, entry_id, match_tier, dataset_version,
                        status, resolved_at_ms, updated_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 1, 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(lexemeID), entryID, tier,
                    version, status])
        }
    }

    private func insertCard(
        noteID: UUID,
        template: String = "vocabulary_ja_zh",
        id: UUID = UUID()
    ) async throws -> UUID {
        let profile = profileID!
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cards(
                        id, note_id, template_kind, is_enabled, state,
                        due_at_ms, last_review_at_ms, stability,
                        difficulty, reps, lapses, scheduled_days,
                        elapsed_days, learning_step, first_studied_at_ms,
                        state_version, algorithm_version, profile_id
                    ) VALUES (?, ?, ?, 1, 2, 1000, 900, 12.5, 5.5, 7, 1,
                              3.0, 4.0, 0, 100, 3, 'fsrs-5', ?)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(noteID),
                    template, DatabaseValueCodec.encode(profile)])
            return id
        }
    }

    private func insertReviewLog(
        cardID: UUID, noteID: UUID,
        id: UUID = UUID()
    ) async throws -> UUID {
        let deck = deckID!
        let day = studyDayID!
        let profile = profileID!
        return try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO review_logs(
                        id, event_id, card_id, card_key, note_id,
                        deck_id_at_review, reviewed_at_ms, study_day_id,
                        was_first_study, rating, previous_state_json,
                        next_state_json, duration_ms, content_version,
                        profile_id, algorithm_version
                    ) VALUES (?, ?, ?, ?, ?, ?, 500, ?, 1, 3, '{}', '{}',
                              1500, 1, ?, 'fsrs-5')
                    """,
                arguments: [
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(id),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(cardID),
                    DatabaseValueCodec.encode(noteID),
                    DatabaseValueCodec.encode(deck),
                    DatabaseValueCodec.encode(day),
                    DatabaseValueCodec.encode(profile)])
            return id
        }
    }

    /// 预建「已绑定到某快照行」的 dictionarySense unit + alias 行。
    private func insertBoundUnit(
        dataset: String,
        entryID: Int64,
        senseID: Int64,
        fingerprint: String,
        status: Alias.Status = .current,
        lemma: String = "x"
    ) async throws -> LearningUnit {
        let ms = atMs
        return try await pool.write { db in
            let probe = Alias(
                unitID: UUID(), provider: "jmdict",
                datasetVersion: dataset, entryID: entryID,
                senseID: senseID, fingerprint: fingerprint, status: status)
            let unit = try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .dictionarySense,
                identityKey: probe.identityKey,
                lemma: lemma, reading: nil, provider: "jmdict",
                entryID: entryID, fingerprint: fingerprint,
                fingerprintVersion: "sense-fp-1",
                bindingStatus: status == .current
                    ? .current : .needsConfirmation,
                atMilliseconds: ms, in: db)
            _ = try GRDBLearningUnitRepository.upsertAlias(
                Alias(
                    unitID: unit.id, provider: "jmdict",
                    datasetVersion: dataset, entryID: entryID,
                    senseID: senseID, fingerprint: fingerprint,
                    status: status),
                resolvedAtMs: ms, in: db)
            return unit
        }
    }

    // MARK: - 读断言 helper

    private func unwrap<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "unexpected nil",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, message(), file: file, line: line)
    }

    private func units() async throws -> [LearningUnit] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, identity_kind, identity_key, provider,
                           dictionary_entry_id, semantic_fingerprint,
                           fingerprint_version, lemma, reading,
                           sense_snapshot_json, binding_status, revision,
                           created_at_ms, updated_at_ms
                    FROM lexical_learning_units
                    ORDER BY created_at_ms, id
                    """).map { row in
                let kindRaw: String = row["identity_kind"]
                let bindingRaw: String = row["binding_status"]
                let idRaw: String = row["id"]
                return LearningUnit(
                    id: try DatabaseValueCodec.decodeUUID(idRaw),
                    identityKind: LearningUnitIdentityKind(
                        rawValue: kindRaw)!,
                    identityKey: row["identity_key"],
                    provider: row["provider"],
                    dictionaryEntryID: row["dictionary_entry_id"],
                    semanticFingerprint: row["semantic_fingerprint"],
                    fingerprintVersion: row["fingerprint_version"],
                    lemma: row["lemma"], reading: row["reading"],
                    senseSnapshotJSON: row["sense_snapshot_json"],
                    bindingStatus: LearningUnitBindingStatus(
                        rawValue: bindingRaw)!,
                    revision: row["revision"],
                    createdAtMs: row["created_at_ms"],
                    updatedAtMs: row["updated_at_ms"])
            }
        }
    }

    private func unit(identityKey: String) async throws -> LearningUnit? {
        try await pool.read { db in
            try GRDBLearningUnitRepository.fetchUnit(
                identityKey: identityKey, in: db)
        }
    }

    private func link(
        noteID: UUID
    ) async throws -> (unitID: UUID, role: String)? {
        try await pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT unit_id, role FROM learning_unit_note_links
                    WHERE note_id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(noteID)])
            .map { row in
                let unitRaw: String = row["unit_id"]
                return (
                    try DatabaseValueCodec.decodeUUID(unitRaw),
                    row["role"] as String)
            }
        }
    }

    private func flags(unitID: UUID) async throws -> Bool? {
        try await pool.read { db in
            try GRDBLearningUnitRepository.fetchFlag(
                unitID: unitID, in: db)?.tooEasy
        }
    }

    private struct AliasRow: Equatable {
        var dataset: String
        var entryID: Int64
        var senseID: Int64
        var fingerprint: String
        var status: String
    }

    private func aliasRows(unitID: UUID) async throws -> [AliasRow] {
        try await pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT dataset_version, entry_id, sense_id,
                           fingerprint, status
                    FROM learning_unit_dictionary_aliases
                    WHERE unit_id = ?
                    ORDER BY dataset_version, entry_id, sense_id
                    """,
                arguments: [DatabaseValueCodec.encode(unitID)])
            .map {
                AliasRow(
                    dataset: $0["dataset_version"],
                    entryID: $0["entry_id"], senseID: $0["sense_id"],
                    fingerprint: $0["fingerprint"], status: $0["status"])
            }
        }
    }

    private func migrationItem(
        sourceKey: String
    ) async throws -> LearningUnitMigrationItem? {
        try await pool.read { db in
            try GRDBLearningUnitRepository.fetchMigrationItem(
                sourceKey: sourceKey, in: db)
        }
    }

    private func rowCount(_ table: String) async throws -> Int {
        try await pool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    private func eventKinds(unitID: UUID) async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT kind FROM learning_unit_events
                    WHERE unit_id_snapshot = ? ORDER BY created_at_ms, kind
                    """,
                arguments: [DatabaseValueCodec.encode(unitID)])
        }
    }

    private func fingerprint(
        entryID: Int64, glosses: [String], pos: [String] = [],
        rForms: [String] = [], rReadings: [String] = [],
        tags: [(String, String)] = []
    ) -> String {
        SemanticFingerprint.compute(
            entryID: entryID, normalizedGlosses: glosses,
            posCodes: pos, restrictedForms: rForms,
            restrictedReadings: rReadings,
            tags: tags.map {
                DictionarySenseTag(category: $0.0, code: $0.1)
            })
    }

    // MARK: - 1) Note 分派

    /// lexeme 链接 + 唯一义项 entry → dictionarySense unit（共享 key）
    /// + verified alias + primary link + applied 审计项。
    func testLinkedNoteVerifiesToDictionarySense() async throws {
        let dict = try makeDict([DEntry(
            id: 100, forms: ["食べる"], readings: ["たべる"],
            senses: [DSense(id: 1, pos: ["v5"], en: ["to eat"])])])
        let noteID = try await insertNote(
            headword: "食べる", reading: "たべる")
        let lexemeID = try await insertLexeme(
            entryID: 100, writtenForm: "食べる", reading: "たべる")
        try await linkLexeme(lexemeID, noteID: noteID)

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesBoundVerified, 1)
        XCTAssertFalse(summary.interrupted)

        let link = try unwrap(await self.link(noteID: noteID))
        XCTAssertEqual(link.role, "primary")
        let unit = try unwrap(await units().first)
        XCTAssertEqual(link.unitID, unit.id)
        XCTAssertEqual(unit.identityKind, .dictionarySense)
        XCTAssertTrue(unit.identityKey.hasPrefix("jmdict:sense-v1:100:"))
        XCTAssertEqual(unit.dictionaryEntryID, 100)
        XCTAssertEqual(unit.bindingStatus, .current)

        let fp = fingerprint(entryID: 100, glosses: ["to eat"], pos: ["v5"])
        XCTAssertEqual(
            unit.identityKey, "jmdict:sense-v1:100:\(fp)")
        let aliases = try await aliasRows(unitID: unit.id)
        XCTAssertEqual(aliases, [AliasRow(
            dataset: dictVersion, entryID: 100, senseID: 1,
            fingerprint: fp, status: "current")])

        let item = try unwrap(await 
            migrationItem(sourceKey: "note:\(noteID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .applied)
        XCTAssertEqual(item.targetUnitID, unit.id)
        XCTAssertEqual(item.oldState, "learning")
        let kinds = try await eventKinds(unitID: unit.id)
        XCTAssertTrue(kinds.contains("migrated"))
        XCTAssertTrue(kinds.contains("noteLinked"))
    }

    /// `dictionary_sense_key = "entry:sense"` 且同 dataset_version →
    /// 多义项 entry 中精确落到指定 sense。
    func testSenseKeyContextVerifiesAmongMultipleSenses() async throws {
        let dict = try makeDict([DEntry(
            id: 200, forms: ["行く"], readings: ["いく"],
            senses: [
                DSense(id: 6, pos: ["v5"], en: ["to go"]),
                DSense(id: 7, pos: ["v5"], en: ["to proceed"]),
            ])])
        let noteID = try await insertNote(headword: "行く", reading: "いく")
        try await insertContext(
            noteID: noteID, entryID: 200,
            datasetVersion: dictVersion, senseKey: "200:7")

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesBoundVerified, 1)

        let unit = try unwrap(await units().first)
        let fp = fingerprint(entryID: 200, glosses: ["to proceed"], pos: ["v5"])
        XCTAssertEqual(unit.identityKey, "jmdict:sense-v1:200:\(fp)")
        let aliases = try await aliasRows(unitID: unit.id)
        XCTAssertEqual(aliases.map(\.senseID), [7])
        XCTAssertEqual(aliases.first?.status, "current")
    }

    /// entry 级证据但义项多份 → legacyUnresolved + needsConfirmation，
    /// 不任选义项。
    func testMultiSenseEvidenceBecomesLegacyUnresolved() async throws {
        let dict = try makeDict([DEntry(
            id: 300, forms: ["上がる"], readings: ["あがる"],
            senses: [
                DSense(id: 1, pos: ["v5"], en: ["to rise"]),
                DSense(id: 2, pos: ["v5"], en: ["to be raised"]),
            ])])
        let noteID = try await insertNote(headword: "上がる", reading: "あがる")
        try await insertContext(
            noteID: noteID, entryID: 300, datasetVersion: dictVersion)

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesPendingConfirmation, 1)
        XCTAssertEqual(summary.notesBoundVerified, 0)

        let key = Service.legacyNoteIdentityKey(noteID: noteID)
        let unit = try unwrap(await unit(identityKey: key))
        XCTAssertEqual(unit.identityKind, .legacyUnresolved)
        XCTAssertEqual(unit.bindingStatus, .legacy)
        let link = try unwrap(await self.link(noteID: noteID))
        XCTAssertEqual(link.unitID, unit.id)
        let item = try unwrap(await 
            migrationItem(sourceKey: "note:\(noteID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .needsConfirmation)
        XCTAssertTrue(item.evidenceJSON?.contains("multi_sense") ?? false)
        let aliases = try await aliasRows(unitID: unit.id)
        XCTAssertTrue(aliases.isEmpty)
    }

    /// 同 Note 两条同版本 sense_key 指向不同义项 → 冲突证据，
    /// 绝不任选其一。
    func testConflictingSourceContextsNeverPick() async throws {
        let dict = try makeDict([DEntry(
            id: 400, forms: ["事"], readings: ["こと"],
            senses: [
                DSense(id: 10, pos: ["n"], en: ["thing"]),
                DSense(id: 11, pos: ["n"], en: ["incident"]),
            ])])
        let noteID = try await insertNote(headword: "事", reading: "こと")
        try await insertContext(
            noteID: noteID, entryID: 400,
            datasetVersion: dictVersion, senseKey: "400:10")
        try await insertContext(
            noteID: noteID, entryID: 400,
            datasetVersion: dictVersion, senseKey: "400:11",
            isPrimary: false)

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesPendingConfirmation, 1)

        let unit = try unwrap(await 
            unit(identityKey: Service.legacyNoteIdentityKey(noteID: noteID)))
        XCTAssertEqual(unit.identityKind, .legacyUnresolved)
        let item = try unwrap(await 
            migrationItem(sourceKey: "note:\(noteID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .needsConfirmation)
        XCTAssertTrue(
            item.evidenceJSON?.contains("conflicting_sense_refs") ?? false)
    }

    /// 无词典证据 → local-note unit。
    func testNoEvidenceNoteBecomesLocalNote() async throws {
        let dict = try makeDict([])
        let noteID = try await insertNote(headword: "造語")

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesLocal, 1)

        let unit = try unwrap(await 
            unit(identityKey: Service.localNoteIdentityKey(noteID: noteID)))
        XCTAssertEqual(unit.identityKind, .localNote)
        let link = try unwrap(await self.link(noteID: noteID))
        XCTAssertEqual(link.unitID, unit.id)
        let item = try unwrap(await 
            migrationItem(sourceKey: "note:\(noteID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .applied)
        XCTAssertEqual(item.oldState, "unknown")
    }

    /// 已有正式关联（dictionarySense）的 Note → alreadyLinked 幂等，
    /// 不抢占既有决定。
    func testAlreadyLinkedNoteSkipped() async throws {
        let dict = try makeDict([DEntry(
            id: 500, forms: ["猫"], readings: ["ねこ"],
            senses: [DSense(id: 1, pos: ["n"], en: ["cat"])])])
        let noteID = try await insertNote(headword: "猫", reading: "ねこ")
        let fp = fingerprint(entryID: 500, glosses: ["cat"], pos: ["n"])
        let unit = try await insertBoundUnit(
            dataset: dictVersion, entryID: 500, senseID: 1,
            fingerprint: fp)
        let ms = atMs
        try await pool.write { db in
            _ = try GRDBLearningUnitRepository.linkNote(
                unitID: unit.id, noteID: noteID, role: .primary,
                origin: .manual, atMilliseconds: ms, in: db)
        }

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesAlreadyLinked, 1)
        XCTAssertEqual(summary.notesBoundVerified, 0)
        let link = try unwrap(await self.link(noteID: noteID))
        XCTAssertEqual(link.unitID, unit.id)
        let item = try unwrap(await 
            migrationItem(sourceKey: "note:\(noteID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .applied)
        XCTAssertTrue(
            item.evidenceJSON?.contains("already_linked") ?? false)
    }

    // MARK: - 2) overrides：known/ignored（D03/D04/D19）

    /// known 无 Note、唯一可靠义项 → unit + tooEasy flag + 证据；
    /// 绝不为补 Note 造行。
    func testKnownOverrideWithoutNoteSetsFlag() async throws {
        let dict = try makeDict([DEntry(
            id: 600, forms: ["水"], readings: ["みず"],
            senses: [DSense(id: 1, pos: ["n"], en: ["water"])])])
        let lexemeID = try await insertLexeme(
            entryID: 600, writtenForm: "水", reading: "みず")
        try await insertOverride(lexemeID, state: "known")

        let notesBefore = try await rowCount("notes")
        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.overridesKnownFlagged, 1)
        let notesAfter = try await rowCount("notes")
        XCTAssertEqual(notesAfter, notesBefore)

        let unit = try unwrap(await units().first)
        XCTAssertEqual(unit.identityKind, .dictionarySense)
        let flag = try await flags(unitID: unit.id)
        XCTAssertEqual(flag, true)
        let item = try unwrap(await 
            migrationItem(sourceKey: "override:\(lexemeID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .applied)
        XCTAssertEqual(item.oldState, "known")
        XCTAssertEqual(item.targetUnitID, unit.id)
        let kinds = try await eventKinds(unitID: unit.id)
        XCTAssertTrue(kinds.contains("tooEasySet"))
    }

    /// known + Note 关联验证同义项 → 同 unit 同时挂 flag 与 Note link。
    func testKnownOverrideWithLinkedNoteFlagsSameUnit() async throws {
        let dict = try makeDict([DEntry(
            id: 610, forms: ["犬"], readings: ["いぬ"],
            senses: [DSense(id: 1, pos: ["n"], en: ["dog"])])])
        let noteID = try await insertNote(headword: "犬", reading: "いぬ")
        let lexemeID = try await insertLexeme(
            entryID: 610, writtenForm: "犬", reading: "いぬ")
        try await linkLexeme(lexemeID, noteID: noteID)
        try await insertOverride(lexemeID, state: "known")

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesBoundVerified, 1)
        XCTAssertEqual(summary.overridesKnownFlagged, 1)

        let unit = try unwrap(await units().first)
        let flag = try await flags(unitID: unit.id)
        XCTAssertEqual(flag, true)
        let link = try unwrap(await self.link(noteID: noteID))
        XCTAssertEqual(link.unitID, unit.id)
        let unitCount = try await rowCount("lexical_learning_units")
        XCTAssertEqual(unitCount, 1)
    }

    /// known 但义项多份 → needsConfirmation + old_state 留痕，
    /// 绝不对任意义项停学。
    func testKnownOverrideAmbiguousNeverStopsLearning() async throws {
        let dict = try makeDict([DEntry(
            id: 700, forms: ["目"], readings: ["め"],
            senses: [
                DSense(id: 1, pos: ["n"], en: ["eye"]),
                DSense(id: 2, pos: ["n"], en: ["stitch"]),
            ])])
        let lexemeID = try await insertLexeme(
            entryID: 700, writtenForm: "目", reading: "め")
        try await insertOverride(lexemeID, state: "known")

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.overridesKnownPending, 1)
        XCTAssertEqual(summary.overridesKnownFlagged, 0)
        let flagCount = try await rowCount("learning_unit_flags")
        XCTAssertEqual(flagCount, 0)

        let item = try unwrap(await 
            migrationItem(sourceKey: "override:\(lexemeID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .needsConfirmation)
        XCTAssertEqual(item.oldState, "known")
        XCTAssertTrue(item.evidenceJSON?.contains("multi_sense") ?? false)
    }

    /// known + 冲突候选（lexeme entry 与 binding entry 不同）→
    /// needsConfirmation，不猜。
    func testKnownOverrideConflictingEntriesPending() async throws {
        let dict = try makeDict([
            DEntry(id: 710, forms: ["事"], readings: ["こと"],
                   senses: [DSense(id: 1, pos: ["n"], en: ["thing"])]),
            DEntry(id: 711, forms: ["事"], readings: ["こと"],
                   senses: [DSense(id: 2, pos: ["n"], en: ["matter"])]),
        ])
        let lexemeID = try await insertLexeme(
            entryID: 710, writtenForm: "事", reading: "こと")
        try await insertBinding(
            lexemeID, entryID: 711, dataset: dictVersion)
        try await insertOverride(lexemeID, state: "known")

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.overridesKnownPending, 1)
        let item = try unwrap(await 
            migrationItem(sourceKey: "override:\(lexemeID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .needsConfirmation)
        XCTAssertTrue(
            item.evidenceJSON?.contains("conflicting_entries") ?? false)
    }

    /// local provider lexeme 的 known → 无义项证据，待确认不猜停。
    func testKnownOverrideLocalLexemeStaysPending() async throws {
        let lexemeID = try await insertLexeme(
            provider: "local", writtenForm: "ローカル")
        try await insertOverride(lexemeID, state: "known")

        let dict = try makeDict([])
        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.overridesKnownPending, 1)
        let unitCount = try await rowCount("lexical_learning_units")
        XCTAssertEqual(unitCount, 0)
        let item = try unwrap(await 
            migrationItem(sourceKey: "override:\(lexemeID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .needsConfirmation)
        XCTAssertEqual(item.oldState, "known")
    }

    /// ignored → skipped 证据存档，不进运行态、不转 tooEasy。
    func testIgnoredOverrideArchivedOnly() async throws {
        let dict = try makeDict([DEntry(
            id: 720, forms: ["空"], readings: ["そら"],
            senses: [DSense(id: 1, pos: ["n"], en: ["sky"])])])
        let lexemeID = try await insertLexeme(
            entryID: 720, writtenForm: "空", reading: "そら")
        try await insertOverride(lexemeID, state: "ignored")

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.overridesIgnoredArchived, 1)
        XCTAssertEqual(summary.overridesKnownFlagged, 0)
        let flagCount = try await rowCount("learning_unit_flags")
        XCTAssertEqual(flagCount, 0)

        let item = try unwrap(await 
            migrationItem(sourceKey: "override:\(lexemeID.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .skipped)
        XCTAssertEqual(item.oldState, "ignored")
        XCTAssertTrue(
            item.evidenceJSON?.contains("ignored_archived") ?? false)
    }

    /// 无 override 无 Note 的 lexeme（旧 unknown）→ 不造任何行。
    func testUnlinkedLexemeWithoutOverrideCreatesNothing() async throws {
        _ = try await insertLexeme(
            entryID: 730, writtenForm: "鳥", reading: "とり")
        let dict = try makeDict([DEntry(
            id: 730, forms: ["鳥"], readings: ["とり"],
            senses: [DSense(id: 1, pos: ["n"], en: ["bird"])])])
        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        let unitCount = try await rowCount("lexical_learning_units")
        XCTAssertEqual(unitCount, 0)
        let linkCount = try await rowCount("learning_unit_note_links")
        XCTAssertEqual(linkCount, 0)
        _ = summary
    }

    // MARK: - 3) 多 Note primary 选举（§3.2）

    /// 同义项两条 Note：created_at_ms 更早者 primary，
    /// 其余 legacy_secondary；created 相同则 note_id 字典序。
    func testDuplicateNotesDeterministicPrimaryAndSecondary() async throws {
        let dict = try makeDict([DEntry(
            id: 800, forms: ["本"], readings: ["ほん"],
            senses: [DSense(id: 1, pos: ["n"], en: ["book"])])])
        // 扫描序按 note_id——故意让 id 大的 note created 更早，
        // 验证选举不受扫描序影响。
        let newerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let olderID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let olderNote = try await insertNote(
            headword: "本", reading: "ほん", id: olderID, createdAtMs: 10)
        let newerNote = try await insertNote(
            headword: "本", reading: "ほん", id: newerID, createdAtMs: 20)
        // 并列 created 的第三条：note_id 更小者赢。olderID 字典序
        // 比 bothID 大，所以 bothID（并列 created=10 时）应赢 olderNote。
        let bothID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let bothNote = try await insertNote(
            headword: "本", reading: "ほん", id: bothID, createdAtMs: 10)
        for noteID in [olderNote, newerNote, bothNote] {
            try await insertContext(
                noteID: noteID, entryID: 800, datasetVersion: dictVersion)
        }

        let summary = try await makeService().run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesBoundVerified, 3)
        let unitCount = try await rowCount("lexical_learning_units")
        XCTAssertEqual(unitCount, 1)
        let linkCount = try await rowCount("learning_unit_note_links")
        XCTAssertEqual(linkCount, 3)

        // created=10 且 id 最小 = bothID → primary；另两条 secondary。
        let bothLink = try unwrap(await self.link(noteID: bothNote))
        XCTAssertEqual(bothLink.role, "primary")
        let olderLink = try unwrap(await self.link(noteID: olderNote))
        XCTAssertEqual(olderLink.role, "legacy_secondary")
        let newerLink = try unwrap(await self.link(noteID: newerNote))
        XCTAssertEqual(newerLink.role, "legacy_secondary")
        XCTAssertEqual(bothLink.unitID, olderLink.unitID)
        XCTAssertEqual(olderLink.unitID, newerLink.unitID)
    }

    // MARK: - 4) 守恒审计（§3.3）

    /// 回填前后 notes/cards/review_logs 行数、ID 集合、逐列摘要
    /// （含 FSRS 调度列）完全不变。
    func testConservationAcrossBackfill() async throws {
        let dict = try makeDict([DEntry(
            id: 900, forms: ["走る"], readings: ["はしる"],
            senses: [DSense(id: 1, pos: ["v5"], en: ["to run"])])])
        let note1 = try await insertNote(headword: "走る", reading: "はしる")
        let note2 = try await insertNote(headword: "造語")
        try await insertContext(
            noteID: note1, entryID: 900, datasetVersion: dictVersion)
        let card1 = try await insertCard(noteID: note1)
        let card2 = try await insertCard(
            noteID: note1, template: "vocabulary_zh_ja")
        _ = try await insertReviewLog(cardID: card1, noteID: note1)
        _ = try await insertReviewLog(cardID: card2, noteID: note1)
        let lexemeID = try await insertLexeme(
            entryID: 900, writtenForm: "走る", reading: "はしる")
        try await insertOverride(lexemeID, state: "known")

        let service = makeService()
        let before = try await service.auditSummary()
        _ = try await service.run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        let after = try await service.auditSummary()

        XCTAssertEqual(after, before)
        XCTAssertTrue(after.differences(from: before).isEmpty)
        XCTAssertEqual(before.notesCount, 2)
        XCTAssertEqual(before.cardsCount, 2)
        XCTAssertEqual(before.reviewLogsCount, 2)
        _ = note2
    }

    // MARK: - 5) 幂等 / 中断续跑 / checkpoint

    /// 完整回填重放：六张 v23 表行数不变，无新增事件/审计行。
    func testRerunIsIdempotent() async throws {
        let dict = try makeDict([DEntry(
            id: 910, forms: ["飲む"], readings: ["のむ"],
            senses: [DSense(id: 1, pos: ["v5"], en: ["to drink"])])])
        let noteID = try await insertNote(headword: "飲む", reading: "のむ")
        try await insertContext(
            noteID: noteID, entryID: 910, datasetVersion: dictVersion)
        _ = try await insertNote(headword: "OOV")
        let ambiguous = try await insertNote(headword: "目")
        _ = ambiguous
        let lexemeID = try await insertLexeme(
            entryID: 910, writtenForm: "飲む", reading: "のむ")
        try await insertOverride(lexemeID, state: "known")
        let ignored = try await insertLexeme(
            provider: "local", writtenForm: "無視")
        try await insertOverride(ignored, state: "ignored")

        let service = makeService()
        _ = try await service.run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        let tables = [
            "lexical_learning_units",
            "learning_unit_dictionary_aliases",
            "learning_unit_note_links",
            "learning_unit_flags",
            "learning_unit_events",
            "learning_unit_migration_items",
        ]
        var countsBefore: [String: Int] = [:]
        for table in tables {
            countsBefore[table] = try await rowCount(table)
        }
        let second = try await service.run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        for table in tables {
            let count = try await rowCount(table)
            XCTAssertEqual(
                count, countsBefore[table],
                "\(table) 重跑产生新增行")
        }
        XCTAssertEqual(second.notesBoundVerified, 0)
        XCTAssertEqual(second.overridesKnownFlagged, 0)
    }

    /// 中断模拟：batchSize=2、batchLimit=1 只跑一批；续跑收敛完成，
    /// 全部 Note 有审计项、run marker 落账。
    func testInterruptionResumesFromCheckpoint() async throws {
        let dict = try makeDict([DEntry(
            id: 920, forms: ["読む"], readings: ["よむ"],
            senses: [DSense(id: 1, pos: ["v5"], en: ["to read"])])])
        var noteIDs: [UUID] = []
        for index in 0..<5 {
            let noteID = try await insertNote(
                headword: index < 3 ? "読む" : "造語\(index)",
                reading: index < 3 ? "よむ" : nil)
            if index < 3 {
                try await insertContext(
                    noteID: noteID, entryID: 920,
                    datasetVersion: dictVersion)
            }
            noteIDs.append(noteID)
        }

        let limited = makeService(batchSize: 2)
        let first = try await limited.run(
            senseSource: source(dict), entryVerifier: verifier(dict),
            batchLimit: 1)
        XCTAssertTrue(first.interrupted)
        XCTAssertEqual(first.batchesCommitted, 1)
        let markerBeforeResume = try await migrationItem(
            sourceKey: Service.runMarkerSourceKey)
        XCTAssertNil(markerBeforeResume)

        let resumed = try await limited.run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertFalse(resumed.interrupted)
        for noteID in noteIDs {
            let item = try unwrap(await migrationItem(
                sourceKey: "note:\(noteID.uuidString.lowercased())"))
            XCTAssertTrue(
                [.applied, .needsConfirmation].contains(item.status))
        }
        let marker = try unwrap(await 
            migrationItem(sourceKey: Service.runMarkerSourceKey))
        XCTAssertEqual(marker.status, .applied)
        // 全部 note 落 unit 关联（3 verified + 2 local）。
        let linkCount = try await rowCount("learning_unit_note_links")
        XCTAssertEqual(linkCount, 5)
    }

    // MARK: - 6) 未回填投影 helper（§3.3「不漏计」）

    /// ensureLegacyNoteUnit 投影 + flag → 回填验证后 flag 随迁到
    /// dictionarySense unit，投影 unit 被回收、identity key 升级。
    func testProjectionHelperAndFlagCarry() async throws {
        let dict = try makeDict([DEntry(
            id: 930, forms: ["書く"], readings: ["かく"],
            senses: [DSense(id: 1, pos: ["v5"], en: ["to write"])])])
        let noteID = try await insertNote(headword: "書く", reading: "かく")
        try await insertContext(
            noteID: noteID, entryID: 930, datasetVersion: dictVersion)

        let service = makeService()
        // 未回填时的稳定投影 + Too Easy 标记。
        let projectedKey = try await service.projectedUnitIdentityKey(
            noteID: noteID)
        XCTAssertEqual(
            projectedKey,
            "legacy-note:\(noteID.uuidString.lowercased())")
        let projection = try await service.ensureLegacyNoteUnit(
            noteID: noteID, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(projection.identityKind, .legacyUnresolved)
        let ms = atMs
        try await pool.write { db in
            _ = try GRDBLearningUnitRepository.setFlagTooEasy(
                unitID: projection.id, value: true, expectedRevision: 0,
                operationID: UUID(), atMilliseconds: ms, in: db)
        }
        // 重复 ensure 幂等——返回同一投影。
        let again = try await service.ensureLegacyNoteUnit(
            noteID: noteID, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(again.id, projection.id)

        let summary = try await service.run(
            senseSource: source(dict), entryVerifier: verifier(dict))
        XCTAssertEqual(summary.notesBoundVerified, 1)
        XCTAssertEqual(summary.projectionsReplaced, 1)
        XCTAssertEqual(summary.flagsCarried, 1)

        let unit = try unwrap(await 
            units().first { $0.identityKind == .dictionarySense })
        let flag = try await flags(unitID: unit.id)
        XCTAssertEqual(flag, true)
        let link = try unwrap(await self.link(noteID: noteID))
        XCTAssertEqual(link.unitID, unit.id)
        // 投影已回收；投影 helper 现在指向正式 unit key。
        let projectionGone = try await pool.read { db in
            try GRDBLearningUnitRepository.fetchUnit(
                id: projection.id, in: db)
        }
        XCTAssertNil(projectionGone)
        let projectedAfter = try await service.projectedUnitIdentityKey(
            noteID: noteID)
        XCTAssertEqual(projectedAfter, unit.identityKey)
    }

    // MARK: - 7) 词典换库重绑定（spike 纪律）

    /// 唯一指纹候选 → 新快照行 current、旧行 superseded、
    /// unit UUID/identity_key 不变。
    func testRebindUniqueCandidateKeepsIdentity() async throws {
        let glosses = ["to take (time)", "to cost"]
        let fp = fingerprint(
            entryID: 100005, glosses: glosses, pos: ["v5r", "vi"],
            rForms: ["掛かる"], tags: [("misc", "uk")])
        let v1Unit = try await insertBoundUnit(
            dataset: "dict-v1", entryID: 100005, senseID: 8,
            fingerprint: fp, lemma: "掛かる")
        // v2：同 entry 语义字段不变但 sense 行号迁移（8 → 9）。
        let dictV2 = try makeDict([DEntry(
            id: 100005, forms: ["掛かる"], readings: ["かかる"],
            senses: [DSense(
                id: 9, pos: ["v5r", "vi"], tags: [("misc", "uk")],
                en: glosses, zh: ["花费"], rForms: ["掛かる"])])],
            datasetVersion: "dict-v2")
        let unitIDBefore = v1Unit.id
        let keyBefore = v1Unit.identityKey

        let summary = try await makeService().rebindAliases(
            senseSource: source(dictV2))
        XCTAssertEqual(summary.rebound, 1)
        XCTAssertEqual(summary.markedAmbiguous, 0)
        XCTAssertEqual(summary.markedStale, 0)

        let unit = try unwrap(await 
            units().first { $0.id == unitIDBefore })
        XCTAssertEqual(unit.identityKey, keyBefore)
        XCTAssertEqual(unit.bindingStatus, .current)
        let aliases = try await aliasRows(unitID: unitIDBefore)
        XCTAssertEqual(
            aliases.first { $0.dataset == "dict-v2" }?.status, "current")
        XCTAssertEqual(
            aliases.first { $0.dataset == "dict-v2" }?.senseID, 9)
        XCTAssertEqual(
            aliases.first { $0.dataset == "dict-v1" }?.status, "superseded")
        let item = try unwrap(await migrationItem(
            sourceKey: "rebind:\(unitIDBefore.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .applied)

        // 重放幂等：二次重绑仍是同一行 current，无新增。
        let second = try await makeService().rebindAliases(
            senseSource: source(dictV2))
        XCTAssertEqual(second.confirmedCurrent, 1)
        XCTAssertEqual(second.rebound, 0)
        let aliasCount = try await rowCount(
            "learning_unit_dictionary_aliases")
        XCTAssertEqual(aliasCount, 2)
    }

    /// 同 entry 两个不可区分指纹 → needsConfirmation，
    /// 旧行引用保留、绝不自动择一。
    func testRebindMultipleCandidatesNeedsConfirmation() async throws {
        let glosses = ["to take (time)", "to cost"]
        let fp = fingerprint(
            entryID: 100005, glosses: glosses, pos: ["v5r", "vi"],
            rForms: ["掛かる"], tags: [("misc", "uk")])
        let unit = try await insertBoundUnit(
            dataset: "dict-v1", entryID: 100005, senseID: 8,
            fingerprint: fp, lemma: "掛かる")
        let dictV2 = try makeDict([DEntry(
            id: 100005, forms: ["掛かる"], readings: ["かかる"],
            senses: [
                DSense(id: 9, pos: ["v5r", "vi"],
                       tags: [("misc", "uk")], en: glosses,
                       rForms: ["掛かる"]),
                DSense(id: 10, pos: ["v5r", "vi"],
                       tags: [("misc", "uk")], en: glosses,
                       zh: ["重复"], rForms: ["掛かる"]),
            ])],
            datasetVersion: "dict-v2")

        let summary = try await makeService().rebindAliases(
            senseSource: source(dictV2))
        XCTAssertEqual(summary.markedAmbiguous, 1)
        XCTAssertEqual(summary.rebound, 0)

        let updated = try unwrap(await 
            units().first { $0.id == unit.id })
        XCTAssertEqual(updated.identityKey, unit.identityKey)
        XCTAssertEqual(updated.bindingStatus, .needsConfirmation)
        let aliases = try await aliasRows(unitID: unit.id)
        XCTAssertEqual(aliases.count, 1)                 // 未新增别名行
        XCTAssertEqual(aliases[0].dataset, "dict-v1")    // 保留旧行引用
        XCTAssertEqual(aliases[0].status, "needsConfirmation")
        let item = try unwrap(await migrationItem(
            sourceKey: "rebind:\(unit.id.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .needsConfirmation)
        XCTAssertTrue(
            item.evidenceJSON?.contains("ambiguous_candidates") ?? false)
    }

    /// 新快照零候选 → stale，保留旧行引用（下轮可重试）。
    func testRebindZeroCandidateMarksStale() async throws {
        let fp = fingerprint(
            entryID: 100006, glosses: ["water"], pos: ["n"])
        let unit = try await insertBoundUnit(
            dataset: "dict-v1", entryID: 100006, senseID: 10,
            fingerprint: fp, lemma: "水")
        let dictV2 = try makeDict([DEntry(
            id: 100006, forms: ["水"], readings: ["みず"],
            senses: [DSense(id: 11, pos: ["n"], en: ["water", "cold water"])])],
            datasetVersion: "dict-v2")

        let summary = try await makeService().rebindAliases(
            senseSource: source(dictV2))
        XCTAssertEqual(summary.markedStale, 1)

        let updated = try unwrap(await 
            units().first { $0.id == unit.id })
        XCTAssertEqual(updated.bindingStatus, .stale)
        XCTAssertEqual(updated.identityKey, unit.identityKey)
        let aliases = try await aliasRows(unitID: unit.id)
        XCTAssertEqual(aliases.count, 1)
        XCTAssertEqual(aliases[0].dataset, "dict-v1")
        XCTAssertEqual(aliases[0].status, "stale")
        let item = try unwrap(await migrationItem(
            sourceKey: "rebind:\(unit.id.uuidString.lowercased())"))
        XCTAssertEqual(item.status, .pending)
    }

    /// localNote/legacyUnresolved unit 不参与词典重绑。
    func testRebindDoesNotTouchLocalOrLegacyUnits() async throws {
        let noteID = try await insertNote(headword: "造語")
        let ms = atMs
        try await pool.write { db in
            _ = try Service.ensureLegacyNoteUnit(
                noteID: noteID, atMilliseconds: ms, in: db)
            _ = try GRDBLearningUnitRepository.resolveOrCreateUnit(
                identityKind: .localNote,
                identityKey: "local-note:\(UUID().uuidString.lowercased())",
                lemma: "x", reading: nil, bindingStatus: .legacy,
                atMilliseconds: ms, in: db)
        }
        let dictV2 = try makeDict([], datasetVersion: "dict-v2")
        let summary = try await makeService().rebindAliases(
            senseSource: source(dictV2))
        XCTAssertEqual(summary.unitsScanned, 0)
        let all = try await units()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.bindingStatus == .legacy })
    }

    // MARK: - 8) identity-spike fixture（Bundle.module）

    private struct SpikeTag: Decodable {
        let category: String
        let code: String
    }

    private struct SpikeSense: Decodable {
        let senseID: Int64
        let glossesEN: [String]
        let posCodes: [String]
        let restrictedForms: [String]
        let restrictedReadings: [String]
        let tags: [SpikeTag]

        enum CodingKeys: String, CodingKey {
            case senseID = "sense_id"
            case glossesEN = "glosses_en"
            case posCodes = "pos_codes"
            case restrictedForms = "restricted_forms"
            case restrictedReadings = "restricted_readings"
            case tags
        }
    }

    private struct SpikeEntry: Decodable {
        let entryID: Int64
        let senses: [SpikeSense]
        enum CodingKeys: String, CodingKey {
            case entryID = "entry_id"
            case senses
        }
    }

    private struct SpikeSnapshot: Decodable {
        let datasetVersion: String
        let entries: [SpikeEntry]
        enum CodingKeys: String, CodingKey {
            case datasetVersion = "dataset_version"
            case entries
        }

        func senses(of entryID: Int64) -> [SpikeSense] {
            entries.first { $0.entryID == entryID }?.senses ?? []
        }

        func fingerprint(of sense: SpikeSense, entryID: Int64) -> String {
            SemanticFingerprint.compute(
                entryID: entryID,
                normalizedGlosses: sense.glossesEN,
                posCodes: sense.posCodes,
                restrictedForms: sense.restrictedForms,
                restrictedReadings: sense.restrictedReadings,
                tags: sense.tags.map {
                    DictionarySenseTag(category: $0.category, code: $0.code)
                })
        }
    }

    /// JSON fixture 驱动的 SenseSnapshotReader——与
    /// GRDBLearningUnitSenseSnapshotReader 同接口，验证协议可插拔。
    private struct SpikeSnapshotReader: Service.SenseSnapshotReader {
        let snapshot: SpikeSnapshot
        func datasetVersion() async throws -> String? {
            snapshot.datasetVersion
        }
        func verifiedSenses(
            entryID: Int64
        ) async throws -> [Service.VerifiedSense] {
            snapshot.senses(of: entryID).map { sense in
                Service.VerifiedSense(
                    entryID: entryID, senseID: sense.senseID,
                    fingerprint: snapshot.fingerprint(
                        of: sense, entryID: entryID),
                    glossesEN: sense.glossesEN, posCodes: sense.posCodes)
            }
        }
    }

    private func loadSpikeSnapshot(
        _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SpikeSnapshot {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "json",
                subdirectory: "Fixtures/identity-spike"),
            "\(name).json missing from test bundle",
            file: file, line: line)
        return try JSONDecoder().decode(
            SpikeSnapshot.self, from: Data(contentsOf: url))
    }

    /// 真实 spike 数据驱动重绑：v1 绑定的 unit 在 v2 快照上按指纹
    /// 找到唯一候选（100002 sense 3 「to eat」→ v2 sense 4）。
    func testRebindWithIdentitySpikeFixture() async throws {
        let v1 = try loadSpikeSnapshot("snapshot-v1")
        let v2 = try loadSpikeSnapshot("snapshot-v2")
        let sense3 = try XCTUnwrap(v1.senses(of: 100002).first {
            $0.senseID == 3
        })
        let fp = v1.fingerprint(of: sense3, entryID: 100002)
        let unit = try await insertBoundUnit(
            dataset: v1.datasetVersion, entryID: 100002, senseID: 3,
            fingerprint: fp, lemma: "食べる")

        let summary = try await makeService().rebindAliases(
            senseSource: SpikeSnapshotReader(snapshot: v2))
        XCTAssertEqual(summary.rebound, 1)
        let aliases = try await aliasRows(unitID: unit.id)
        let newAlias = try XCTUnwrap(
            aliases.first { $0.dataset == v2.datasetVersion })
        XCTAssertEqual(newAlias.senseID, 4)
        XCTAssertEqual(newAlias.status, "current")
        XCTAssertEqual(
            aliases.first { $0.dataset == v1.datasetVersion }?.status,
            "superseded")
        let unchanged = try unwrap(await 
            units().first { $0.id == unit.id })
        XCTAssertEqual(unchanged.identityKey, unit.identityKey)
    }
}
