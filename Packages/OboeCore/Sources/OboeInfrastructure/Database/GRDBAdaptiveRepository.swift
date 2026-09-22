import Foundation
import GRDB
import OboeDomain

/// Batched adaptive evidence source (design §4.3). Every card in scope is
/// fetched with its note display fields in ONE query, then all valid review
/// samples are pulled in a handful of chunked `card_key IN (...)` queries —
/// inside a single `pool.read`, so the whole snapshot is one consistent SQLite
/// view and no per-row access exists (no N+1).
///
/// First version scans the in-scope valid logs and accumulates them per card;
/// the v8 partial index `review_logs(card_key, reviewed_at_ms DESC) WHERE
/// undone_at_ms IS NULL` keeps that scan indexed. If the performance gate on
/// the 10k-card/100k-log fixture ever misses its budget, the optimization path
/// is windowed `ROW_NUMBER()` queries plus SQL aggregates — never a change to
/// what counts as a valid sample.
public struct GRDBAdaptiveRepository: AdaptiveRepository, Sendable {
    /// `card_key IN (...)` chunk size, well below SQLite's variable limit.
    private static let keyBatchSize = 400

    private let pool: DatabasePool
    /// Test hook invoked once per issued SQL statement — lets tests assert the
    /// query count stays constant as the card count grows.
    private let queryObserver: (@Sendable () -> Void)?

    public init(database: OboeDatabase) {
        pool = database.pool
        queryObserver = nil
    }

    init(database: OboeDatabase, queryObserver: (@Sendable () -> Void)?) {
        pool = database.pool
        self.queryObserver = queryObserver
    }

    public func fetchDataVersion() async throws -> Int {
        try await pool.read { db in
            queryObserver?()
            return try Self.dataVersion(db)
        }
    }

    public func fetchSnapshot(scope: AdaptiveScope) async throws -> AdaptiveEvidenceSnapshot {
        try await pool.read { db in
            let dataVersion = try Self.dataVersion(db)
            let descriptors = try fetchCardDescriptors(db, scope: scope)
            let cardIDs = descriptors.map(\.card.id)
            var samplesByCard = try fetchSamples(db, cardIDs: cardIDs)
            for key in samplesByCard.keys {
                samplesByCard[key]?.sort(by: AdaptiveReviewSample.isOrderedBefore)
            }
            let records = descriptors.map { descriptor in
                AdaptiveCardRecord(
                    evidence: AdaptiveCardEvidence(
                        cardID: descriptor.card.id,
                        noteID: descriptor.card.noteID,
                        deckID: descriptor.deckID,
                        templateKind: descriptor.card.templateKind,
                        isEnabled: descriptor.card.isEnabled,
                        scheduling: descriptor.card.scheduling,
                        firstStudiedAt: descriptor.card.firstStudiedAt,
                        samples: samplesByCard[descriptor.card.id] ?? []
                    ),
                    headword: descriptor.headword,
                    noteContentVersion: descriptor.noteContentVersion
                )
            }
            return AdaptiveEvidenceSnapshot(
                scope: scope,
                dataVersion: dataVersion,
                records: records
            )
        }
    }

    public func fetchEvidence(cardID: UUID) async throws -> AdaptiveCardRecord? {
        try await pool.read { db in
            queryObserver?()
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT cards.*, notes.deck_id, notes.headword,
                           notes.content_version AS note_content_version
                    FROM cards
                    JOIN notes ON notes.id = cards.note_id
                    WHERE cards.id = ?
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) else {
                return nil
            }
            let descriptor = try Self.decodeCardDescriptor(row)
            var samples = try fetchSamples(db, cardIDs: [cardID])[cardID] ?? []
            samples.sort(by: AdaptiveReviewSample.isOrderedBefore)
            return AdaptiveCardRecord(
                evidence: AdaptiveCardEvidence(
                    cardID: descriptor.card.id,
                    noteID: descriptor.card.noteID,
                    deckID: descriptor.deckID,
                    templateKind: descriptor.card.templateKind,
                    isEnabled: descriptor.card.isEnabled,
                    scheduling: descriptor.card.scheduling,
                    firstStudiedAt: descriptor.card.firstStudiedAt,
                    samples: samples
                ),
                headword: descriptor.headword,
                noteContentVersion: descriptor.noteContentVersion
            )
        }
    }

    // MARK: - Queries

    private struct CardDescriptor {
        let card: PersistedSchedulingCard
        let deckID: UUID
        let headword: String
        let noteContentVersion: Int
    }

    private func fetchCardDescriptors(
        _ db: Database,
        scope: AdaptiveScope
    ) throws -> [CardDescriptor] {
        var sql = """
            SELECT cards.*, notes.deck_id, notes.headword,
                   notes.content_version AS note_content_version
            FROM cards
            JOIN notes ON notes.id = cards.note_id
            """
        var arguments: [any DatabaseValueConvertible] = []
        if let deckID = scope.deckID {
            // 牌组过滤走 `note_decks` 成员关系（设计 §4.4）。
            sql += """

                WHERE EXISTS (
                    SELECT 1 FROM note_decks nd
                    WHERE nd.note_id = notes.id AND nd.deck_id = ?
                )
                """
            arguments.append(DatabaseValueCodec.encode(deckID))
        }
        sql += "\nORDER BY cards.id"
        queryObserver?()
        return try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
        ).map(Self.decodeCardDescriptor)
    }

    /// All valid samples for the given card keys, grouped by card. Chunked
    /// `IN` queries keep the statement count constant per batch size — for
    /// 10,000 cards that is 25 log queries total, not one per card.
    private func fetchSamples(
        _ db: Database,
        cardIDs: [UUID]
    ) throws -> [UUID: [AdaptiveReviewSample]] {
        var result: [UUID: [AdaptiveReviewSample]] = [:]
        guard !cardIDs.isEmpty else { return result }
        for chunk in cardIDs.chunked(into: Self.keyBatchSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            queryObserver?()
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, card_key, rating, reviewed_at_ms, was_first_study,
                           content_version, previous_state_json, next_state_json
                    FROM review_logs
                    WHERE undone_at_ms IS NULL AND card_key IN (\(placeholders))
                    ORDER BY reviewed_at_ms DESC
                    """,
                arguments: StatementArguments(
                    chunk.map { DatabaseValueCodec.encode($0) }
                )
            )
            for row in rows {
                let sample = try Self.decodeSample(row)
                result[sample.cardKey, default: []].append(sample.sample)
            }
        }
        return result
    }

    // MARK: - Decoding

    private static func dataVersion(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
    }

    private static func decodeCardDescriptor(_ row: Row) throws -> CardDescriptor {
        try CardDescriptor(
            card: GRDBSchedulingCardRepository.decode(row),
            deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
            headword: row["headword"],
            noteContentVersion: row["note_content_version"]
        )
    }

    private static func decodeSample(
        _ row: Row
    ) throws -> (cardKey: UUID, sample: AdaptiveReviewSample) {
        let ratingValue: Int = row["rating"]
        guard let rating = ReviewRating(rawValue: ratingValue) else {
            throw SubmitReviewError.invalidPersistedRating(ratingValue)
        }
        let wasFirstStudy: Int = row["was_first_study"]
        let sample = try AdaptiveReviewSample(
            logID: DatabaseValueCodec.decodeUUID(row["id"]),
            rating: rating,
            reviewedAt: DatabaseValueCodec.decodeDate(
                milliseconds: row["reviewed_at_ms"]
            ),
            wasFirstStudy: wasFirstStudy == 1,
            contentVersion: row["content_version"],
            previousState: decodeSnapshot(row["previous_state_json"]),
            nextState: decodeSnapshot(row["next_state_json"])
        )
        return (
            try DatabaseValueCodec.decodeUUID(row["card_key"]),
            sample
        )
    }

    private static func decodeSnapshot(_ json: String) throws -> ReviewSchedulingSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(
            ReviewSchedulingSnapshot.self,
            from: Data(json.utf8)
        )
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
