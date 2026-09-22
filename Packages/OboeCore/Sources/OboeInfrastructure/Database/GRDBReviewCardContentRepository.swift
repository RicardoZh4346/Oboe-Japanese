import Foundation
import GRDB
import OboeDomain

public struct GRDBReviewCardContentRepository: ReviewCardContentRepository, Sendable {
    private let pool: DatabasePool

    public init(database: OboeDatabase) {
        pool = database.pool
    }

    public func fetchReviewCardContent(cardID: UUID) async throws -> ReviewCardContent? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT cards.id AS card_id, cards.note_id, cards.template_kind,
                           notes.content_version, notes.deck_id, notes.headword, notes.reading, notes.meaning_zh,
                           notes.part_of_speech, notes.usage, notes.connection, notes.notes,
                           notes.pitch_accent,
                           examples.japanese AS example_japanese,
                           examples.translation_zh AS example_translation_zh
                    FROM cards
                    JOIN notes ON notes.id = cards.note_id
                    LEFT JOIN examples ON examples.id = (
                        SELECT id FROM examples
                        WHERE note_id = notes.id
                        ORDER BY sort_order, id
                        LIMIT 1
                    )
                    WHERE cards.id = ? AND cards.is_enabled = 1
                    """,
                arguments: [DatabaseValueCodec.encode(cardID)]
            ) else {
                return nil
            }
            let templateValue: String = row["template_kind"]
            guard let templateKind = CardTemplateKind(rawValue: templateValue) else {
                throw DatabaseValueCodecError.invalidCardTemplate(templateValue)
            }
            let noteIDValue: String = row["note_id"]
            let homeDeckIDValue: String = row["deck_id"]
            let memberDeckIDs = try GRDBNoteDeckMemberships.fetchDeckIDMap(
                noteIDs: [noteIDValue],
                in: db
            )[noteIDValue] ?? [homeDeckIDValue]
            return try ReviewCardContent(
                cardID: DatabaseValueCodec.decodeUUID(row["card_id"]),
                noteID: DatabaseValueCodec.decodeUUID(row["note_id"]),
                deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
                templateKind: templateKind,
                headword: row["headword"],
                reading: row["reading"],
                meaningZH: row["meaning_zh"],
                partOfSpeech: row["part_of_speech"],
                usage: row["usage"],
                connection: row["connection"],
                exampleJapanese: row["example_japanese"],
                exampleTranslationZH: row["example_translation_zh"],
                notes: row["notes"],
                contentVersion: row["content_version"],
                pitchAccent: (row["pitch_accent"] as Int?).flatMap(PitchAccent.init(rawValue:)),
                deckIDs: Set(try memberDeckIDs.map { try DatabaseValueCodec.decodeUUID($0) })
            )
        }
    }
}
