import Foundation
import GRDB
@testable import OboeDomain
@testable import OboeInfrastructure
import XCTest

/// S20：v26 快照投影 + Reader→学习项转化漏斗。
///
/// 覆盖：`recordDocumentSnapshot` 的桶口径/幂等/knowledge_revision
/// 漂移/文档删除 SET NULL 后按 snapshot id 追溯；`funnel` 的
/// occurrence/selection/job 分组与最新 selection_revision 去重。
final class GRDBReaderStudyMetricsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "study-metrics-tests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 快照投影

    /// 两类已确认 unit（learning 经 link、mastered 经 tooEasy）+
    /// pending/lowConfidence/rejected/unresolved 桶 + 块覆盖。
    func testSnapshotBucketsAndCoverageCounts() async throws {
        let env = try makeEnvironment()
        let learningUnit = UUID()
        let masteredUnit = UUID()
        try await env.pool.write { db in
            try Self.seedTwoBlockDocument(
                documentID: env.documentID, chapterID: env.chapterID,
                in: db)
            try Self.insertUnit(
                id: learningUnit, key: "local-note:learn", in: db)
            try Self.insertUnit(
                id: masteredUnit, key: "local-note:master", in: db)
            // learning：词汇 Note link。
            let noteID = try Self.insertNote(
                deckID: env.deckID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_note_links(
                        unit_id, note_id, role, origin, created_at_ms)
                    VALUES (?, ?, 'primary', 'manual', 1)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(learningUnit),
                    DatabaseValueCodec.encode(noteID),
                ])
            // mastered：tooEasy flag。
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms)
                    VALUES (?, 1, 3, 777)
                    """,
                arguments: [DatabaseValueCodec.encode(masteredUnit)])
            // occurrences：6 行覆盖两块的全部桶。
            for (status, unit, block, start) in [
                ("aiResolved", learningUnit, 0, 0),
                ("userConfirmed", masteredUnit, 0, 5),
                ("pending", nil as UUID?, 0, 10),
                ("lowConfidence", nil as UUID?, 1, 0),
                ("rejected", nil as UUID?, 1, 5),
                ("unresolved", nil as UUID?, 1, 10),
            ] as [(String, UUID?, Int, Int)] {
                try Self.insertOccurrence(
                    documentID: env.documentID, contentRevision: 1,
                    chapterOrdinal: 0, blockOrdinal: block,
                    startUTF16: start, lengthUTF16: 4,
                    unitID: unit, status: status, in: db)
            }
        }

        let (result, inserted) = try await env.pool.write { db in
            try GRDBReaderCoverageSnapshotStore.recordDocumentSnapshot(
                documentID: env.documentID,
                dictionaryVersion: "dict-1", morphologyVersion: "m-1",
                at: Date(timeIntervalSince1970: 1_000), in: db)
        }
        XCTAssertTrue(inserted)
        XCTAssertEqual(result.resolvedUnique, 2)
        XCTAssertEqual(result.learningUnique, 1)
        XCTAssertEqual(result.masteredUnique, 1)
        XCTAssertEqual(result.unlearnedUnique, 0)
        XCTAssertEqual(result.pendingOccurrences, 3)
        XCTAssertEqual(result.oovOccurrences, 1)
        XCTAssertEqual(result.analyzedBlocks, 2)
        XCTAssertEqual(result.totalBlocks, 2)
        XCTAssertEqual(result.resolvedCoverage, 1.0)

        let snapshots = try await env.pool.read { db in
            try GRDBReaderCoverageSnapshotStore.fetchSnapshots(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(
            snapshots.first?.metricVersion,
            "coverage-resolved-sense-2.0.0")
        XCTAssertEqual(
            snapshots.first?.scopeHash,
            AIStudyScope.fullDocument.scopeHash)
        XCTAssertEqual(snapshots.first?.resolvedUnique, 2)
    }

    /// 同上下文重算 = 无害回放（唯一键去重，不重复落行）；
    /// flag 翻转 → knowledge_revision 变 → 新快照。
    func testSnapshotIdempotentAndKnowledgeRevisionDrift() async throws {
        let env = try makeEnvironment()
        let unit = UUID()
        try await env.pool.write { db in
            try Self.seedTwoBlockDocument(
                documentID: env.documentID, chapterID: env.chapterID,
                in: db)
            try Self.insertUnit(id: unit, key: "local-note:u", in: db)
            try Self.insertOccurrence(
                documentID: env.documentID, contentRevision: 1,
                chapterOrdinal: 0, blockOrdinal: 0,
                startUTF16: 0, lengthUTF16: 4,
                unitID: unit, status: "aiResolved", in: db)
        }

        let first = try await env.pool.write { db in
            try GRDBReaderCoverageSnapshotStore.recordDocumentSnapshot(
                documentID: env.documentID,
                dictionaryVersion: "d", morphologyVersion: "m",
                in: db)
        }
        let second = try await env.pool.write { db in
            try GRDBReaderCoverageSnapshotStore.recordDocumentSnapshot(
                documentID: env.documentID,
                dictionaryVersion: "d", morphologyVersion: "m",
                in: db)
        }
        XCTAssertTrue(first.inserted)
        XCTAssertFalse(second.inserted)

        // flag 置位——知识语境变化必须产生新快照行。
        try await env.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO learning_unit_flags(
                        unit_id, too_easy, revision, updated_at_ms)
                    VALUES (?, 1, 1, 42)
                    """,
                arguments: [DatabaseValueCodec.encode(unit)])
        }
        let third = try await env.pool.write { db in
            try GRDBReaderCoverageSnapshotStore.recordDocumentSnapshot(
                documentID: env.documentID,
                dictionaryVersion: "d", morphologyVersion: "m",
                in: db)
        }
        XCTAssertTrue(third.inserted)
        XCTAssertEqual(third.result.masteredUnique, 1)

        let count = try await env.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM reader_learning_coverage_snapshots
                    """)
        }
        XCTAssertEqual(count, 2)
    }

    /// 文档删除：行 SET NULL，快照按 document_id_snapshot 仍可追溯。
    func testSnapshotSurvivesDocumentDeletion() async throws {
        let env = try makeEnvironment()
        try await env.pool.write { db in
            try Self.seedTwoBlockDocument(
                documentID: env.documentID, chapterID: env.chapterID,
                in: db)
            _ = try GRDBReaderCoverageSnapshotStore
                .recordDocumentSnapshot(
                    documentID: env.documentID,
                    dictionaryVersion: "d", morphologyVersion: "m",
                    in: db)
            try db.execute(
                sql: "DELETE FROM reader_documents WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(env.documentID)])
        }

        let snapshotID = DatabaseValueCodec.encode(env.documentID)
        let bySnapshot = try await env.pool.read { db in
            try GRDBReaderCoverageSnapshotStore.fetchSnapshots(
                snapshotOf: snapshotID, in: db)
        }
        XCTAssertEqual(bySnapshot.count, 1)
        XCTAssertNil(bySnapshot.first?.documentID)
        XCTAssertEqual(
            bySnapshot.first?.documentIDSnapshot, snapshotID)

        // 直查 document_id 已查不到（SET NULL）。
        let byDoc = try await env.pool.read { db in
            try GRDBReaderCoverageSnapshotStore.fetchSnapshots(
                documentID: env.documentID, in: db)
        }
        XCTAssertTrue(byDoc.isEmpty)
    }

    func testSnapshotMissingDocumentThrows() async throws {
        let env = try makeEnvironment()
        await s19AssertThrowsAsync(
            try await env.pool.write { db in
                try GRDBReaderCoverageSnapshotStore
                    .recordDocumentSnapshot(
                        documentID: UUID(),
                        dictionaryVersion: "d", morphologyVersion: "m",
                        in: db)
            })
    }

    // MARK: - 漏斗

    /// 最新 selection_revision 去重 + applied/selected 分列 +
    /// job 状态桶。
    func testFunnelCountsLatestSelectionRevisionOnly() async throws {
        let env = try makeEnvironment()
        let jobID = UUID()
        try await env.pool.write { db in
            try Self.seedTwoBlockDocument(
                documentID: env.documentID, chapterID: env.chapterID,
                in: db)
            // 3 条 occurrence：resolved/pending/unresolved。
            for (status, start) in [
                ("aiResolved", 0), ("pending", 4), ("unresolved", 8),
            ] as [(String, Int)] {
                try Self.insertOccurrence(
                    documentID: env.documentID, contentRevision: 1,
                    chapterOrdinal: 0, blockOrdinal: 0,
                    startUTF16: start, lengthUTF16: 3,
                    unitID: nil, status: status, in: db)
            }
            // 完成态 job + 选择：u1 create rev1→rev2（applied），
            // u2 reuse（未应用）。
            try GRDBAIStudyJobStore.insertJob(
                Self.makeCompletedJob(id: jobID, documentID: env.documentID),
                in: db)
            for (unitKey, rev, decision, receipt) in [
                ("u1", 1, "reuse", nil as String?),
                ("u1", 2, "create", UUID().uuidString.lowercased()),
                ("u2", 1, "reuse", nil as String?),
            ] as [(String, Int64, String, String?)] {
                try GRDBAIStudyJobStore.insertSelection(
                    AIStudyJobSelection(
                        jobID: jobID, unitKey: unitKey,
                        selectionRevision: rev,
                        decision: AISelectionDecision(
                            rawValue: decision)!,
                        evidenceRevision: 1,
                        appliedReceiptID: receipt.map {
                            UUID(uuidString: $0)!
                        }),
                    in: db)
            }
        }

        let funnel = try await env.pool.read { db in
            try GRDBReaderStudyMetricsRepository.funnel(
                documentID: env.documentID, in: db)
        }
        XCTAssertEqual(funnel.preparedOccurrences, 3)
        XCTAssertEqual(funnel.resolvedOccurrences, 1)
        XCTAssertEqual(funnel.pendingOccurrences, 1)
        XCTAssertEqual(funnel.oovOccurrences, 1)
        // u1 只计 rev2（create：selected+applied 双计入——applied
        // ⊂ selected）；u2 计 selected reuse（未应用）。
        XCTAssertEqual(funnel.appliedCreate, 1)
        XCTAssertEqual(funnel.appliedReuse, 0)
        XCTAssertEqual(funnel.selectedReuse, 1)
        XCTAssertEqual(funnel.selectedCreate, 1)
        XCTAssertEqual(funnel.selectedTotal, 2)
        XCTAssertEqual(funnel.appliedTotal, 1)
        XCTAssertEqual(funnel.completedJobs, 1)
        XCTAssertEqual(funnel.activeJobs, 0)
    }

    func testFunnelMissingDocumentIsEmpty() async throws {
        let env = try makeEnvironment()
        let funnel = try await env.pool.read { db in
            try GRDBReaderStudyMetricsRepository.funnel(
                documentID: UUID(), in: db)
        }
        XCTAssertEqual(funnel, ReaderStudyFunnel())
    }

    // MARK: - 环境/夹具

    private struct Environment {
        let pool: DatabasePool
        let documentID: UUID
        let chapterID: UUID
        let deckID: UUID
    }

    private func makeEnvironment() throws -> Environment {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction(
                "oboe_normalize_search", argumentCount: 1, pure: true
            ) { values in
                guard let value = String.fromDatabaseValue(values[0])
                else { return nil }
                return SearchTextNormalizer.normalize(value)
            })
        }
        let pool = try DatabasePool(
            path: directory.appendingPathComponent("db.sqlite").path,
            configuration: configuration)
        try OboeDatabaseSchema.makeMigrator(
            applying: OboeDatabaseSchema.migrationIdentifiers
        ).migrate(pool)
        let env = Environment(
            pool: pool, documentID: UUID(), chapterID: UUID(),
            deckID: UUID())
        try pool.write { db in
            try Self.insertDocument(id: env.documentID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO decks(
                        id, name, sort_order, created_at_ms, updated_at_ms)
                    VALUES (?, 'd', 0, 1, 1)
                    """,
                arguments: [DatabaseValueCodec.encode(env.deckID)])
        }
        return env
    }

    private static func insertDocument(id: UUID, in db: Database)
        throws
    {
        try db.execute(
            sql: """
                INSERT INTO reader_documents(
                    id, title, format, created_at_ms, source_sha256,
                    canonical_text_hash, parser_version, availability)
                VALUES (?, '指标测试', 'paste', 1,
                        '0000000000000000000000000000000000000000000000000000000000000000',
                        'hash1', 'parser-1', 'available')
                """,
            arguments: [DatabaseValueCodec.encode(id)])
    }

    /// 两块的文档骨架（content_revision=1）。
    private static func seedTwoBlockDocument(
        documentID: UUID, chapterID: UUID, in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO reader_chapters(
                    id, document_id, ordinal, title, source_locator,
                    canonical_hash, text_utf16_length)
                VALUES (?, ?, 0, '章', NULL, 'ch', 20)
                """,
            arguments: [
                DatabaseValueCodec.encode(chapterID),
                DatabaseValueCodec.encode(documentID),
            ])
        for ordinal in 0..<2 {
            try db.execute(
                sql: """
                    INSERT INTO reader_blocks(
                        id, document_id, chapter_id, ordinal, text,
                        text_hash, locator_json)
                    VALUES (?, ?, ?, ?, '原文', ?, NULL)
                    """,
                arguments: [
                    DatabaseValueCodec.encode(UUID()),
                    DatabaseValueCodec.encode(documentID),
                    DatabaseValueCodec.encode(chapterID),
                    ordinal,
                    "h\(ordinal)",
                ])
        }
    }

    private static func insertUnit(id: UUID, key: String, in db: Database)
        throws
    {
        try GRDBLearningUnitRepository.insertUnit(
            LearningUnit(
                id: id, identityKind: .localNote, identityKey: key,
                lemma: key, bindingStatus: .legacy,
                createdAtMs: 1, updatedAtMs: 1),
            in: db)
    }

    private static func insertNote(deckID: UUID, in db: Database)
        throws -> UUID
    {
        let noteID = UUID()
        try db.execute(
            sql: """
                INSERT INTO notes(
                    id, deck_id, kind, headword, meaning_zh,
                    is_favorite, origin, content_version,
                    created_at_ms, updated_at_ms)
                VALUES (?, ?, 'vocabulary', '詞', '义', 0,
                        'manual', 1, 1, 1)
                """,
            arguments: [
                DatabaseValueCodec.encode(noteID),
                DatabaseValueCodec.encode(deckID),
            ])
        return noteID
    }

    /// occurrence 行：`locator_json` 带 chapterOrdinal/blockOrdinal
    /// （与 `finalizeResults` 回填的锚点键一致），`block_source_hash`
    /// 参与唯一键但快照不计。
    private static func insertOccurrence(
        documentID: UUID, contentRevision: Int,
        chapterOrdinal: Int, blockOrdinal: Int,
        startUTF16: Int, lengthUTF16: Int,
        unitID: UUID?, status: String, in db: Database
    ) throws {
        let locatorJSON = """
            {"chapterOrdinal":\(chapterOrdinal),"blockOrdinal":\(blockOrdinal)}
            """
        try db.execute(
            sql: """
                INSERT INTO reader_study_occurrences(
                    id, document_id, content_revision, locator_json,
                    block_source_hash, tokenizer_version,
                    start_utf16, length_utf16, unit_id,
                    resolution_status, resolution_id)
                VALUES (?, ?, ?, ?, 'bh', 'tok-1', ?, ?, ?, ?, NULL)
                """,
            arguments: [
                DatabaseValueCodec.encode(UUID()),
                DatabaseValueCodec.encode(documentID),
                contentRevision,
                locatorJSON,
                startUTF16, lengthUTF16,
                unitID.map(DatabaseValueCodec.encode),
                status,
            ])
    }

    private static func makeCompletedJob(id: UUID, documentID: UUID)
        -> AIStudyJob
    {
        var job = AIStudyJob(
            id: id, documentID: documentID,
            scope: .fullDocument, inputFingerprint: "fp",
            contentRevision: 1,
            providerSnapshot: AIStudyProviderSnapshot(
                providerKind: "fake", model: "fake-model",
                responseMode: "promptedJSON",
                promptVersion: "ai-study-prompt-v1",
                policyVersion: "policy-1"),
            model: "fake-model", pipelineVersion: "pipe-1",
            promptVersion: "ai-study-prompt-v1", policyVersion: "policy-1",
            createdAtMs: 1, updatedAtMs: 1)
        job.status = .completed
        return job
    }
}
