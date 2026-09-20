import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

/// T06: `ai_repair` draft persistence — envelopes round-trip through the
/// drafts table via the strict codec, provenance lands on the row, and
/// foreign payload versions are rejected instead of silently decoded.
final class GRDBAIRepairDraftRepositoryTests: XCTestCase {
    private var directoryURL: URL!

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AIRepairDraftTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func testSaveFetchRoundTripAndUpsert() async throws {
        let database = try makeDatabase()
        let repository = GRDBAIRepairDraftRepository(database: database)
        let draftID = UUID()
        let envelope = Self.envelope(phase: .editing, comment: "例句太难")

        try await repository.saveDraft(
            id: draftID,
            envelope: envelope,
            provenance: Self.provenance,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let fetched = try await repository.fetchDraft(id: draftID)
        XCTAssertEqual(fetched, envelope)

        var analyzing = envelope
        analyzing.phase = .analyzing
        analyzing.requestGeneration = 2
        try await repository.saveDraft(
            id: draftID,
            envelope: analyzing,
            provenance: Self.provenance,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let updated = try await repository.fetchDraft(id: draftID)
        XCTAssertEqual(updated?.phase, .analyzing)
        XCTAssertEqual(updated?.requestGeneration, 2)

        // Provenance lands on the row — non-secret identifiers only.
        let provenance = try await database.pool.read { db -> (String?, String?, String?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT provider_id, model_id, prompt_version FROM drafts WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(draftID)]
            )
            return (
                row?["provider_id"] as String?,
                row?["model_id"] as String?,
                row?["prompt_version"] as String?
            )
        }
        XCTAssertEqual(provenance.0, "custom")
        XCTAssertEqual(provenance.1, "fixture-model")
        XCTAssertEqual(provenance.2, "oboe-ai-repair-v1")
    }

    func testFetchAllDeleteAndForeignPayloadVersion() async throws {
        let database = try makeDatabase()
        let repository = GRDBAIRepairDraftRepository(database: database)

        let firstID = UUID()
        let secondID = UUID()
        try await repository.saveDraft(
            id: firstID,
            envelope: Self.envelope(phase: .suggested, comment: "一"),
            provenance: Self.provenance,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try await repository.saveDraft(
            id: secondID,
            envelope: Self.envelope(phase: .editing, comment: "二"),
            provenance: Self.provenance,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let all = try await repository.fetchAllDrafts()
        XCTAssertEqual(Set(all.map(\.id)), [firstID, secondID])

        try await repository.deleteDraft(id: firstID)
        let remaining = try await repository.fetchAllDrafts()
        XCTAssertEqual(remaining.map(\.id), [secondID])

        // A row with a foreign payload_version fails loudly on read.
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE drafts SET payload_version = 99 WHERE id = ?",
                arguments: [DatabaseValueCodec.encode(secondID)]
            )
        }
        do {
            _ = try await repository.fetchDraft(id: secondID)
            XCTFail("expected unsupportedDraftPayloadVersion")
        } catch {
            XCTAssertEqual(
                error as? GRDBAIRepairDraftRepositoryError,
                .unsupportedDraftPayloadVersion(99)
            )
        }
    }

    func testCommittedEnvelopePersistsReceipt() async throws {
        let database = try makeDatabase()
        let repository = GRDBAIRepairDraftRepository(database: database)
        let operationID = UUID()
        var envelope = Self.envelope(phase: .committed, comment: "")
        envelope.operationID = operationID
        envelope.commitReceipt = AIRepairCommitReceipt(
            operationID: operationID,
            payloadHash: String(repeating: "c", count: 64),
            createdNoteIDs: [UUID(), UUID()],
            createdCardIDs: [UUID()],
            originalCardDisposition: .delete
        )
        let draftID = UUID()
        try await repository.saveDraft(
            id: draftID,
            envelope: envelope,
            provenance: Self.provenance,
            updatedAt: Date()
        )
        let restored = try await repository.fetchDraft(id: draftID)
        XCTAssertEqual(restored, envelope)
        XCTAssertEqual(restored?.commitReceipt?.createdNoteIDs.count, 2)
    }

    // MARK: - Helpers

    private static var provenance: AIRepairDraftProvenance {
        AIRepairDraftProvenance(
            providerID: "custom",
            modelID: "fixture-model",
            promptVersion: "oboe-ai-repair-v1"
        )
    }

    private static func envelope(
        phase: AIRepairDraftPhase,
        comment: String
    ) -> AIRepairDraftEnvelope {
        AIRepairDraftEnvelope(
            targetNoteID: UUID(),
            targetCardID: UUID(),
            expectedContentVersion: 2,
            targetCardEnabled: true,
            affectedTemplateKinds: [.vocabularyJapaneseToChinese],
            userComment: comment,
            requestGeneration: 1,
            phase: phase
        )
    }

    private func makeDatabase() throws -> OboeDatabase {
        try OboeDatabase(
            path: directoryURL.appendingPathComponent("db.sqlite").path
        )
    }
}
