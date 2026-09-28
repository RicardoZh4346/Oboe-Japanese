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
                           examples.translation_zh AS example_translation_zh,
                           cloze_definitions.id AS cloze_id,
                           cloze_definitions.card_id AS cloze_card_id,
                           cloze_definitions.source_context_id AS cloze_source_context_id,
                           cloze_definitions.sentence_snapshot AS cloze_sentence_snapshot,
                           cloze_definitions.sentence_sha256 AS cloze_sentence_sha256,
                           cloze_definitions.range_version AS cloze_range_version,
                           cloze_definitions.range_utf16_start AS cloze_range_utf16_start,
                           cloze_definitions.range_utf16_length AS cloze_range_utf16_length,
                           cloze_definitions.target_surface AS cloze_target_surface,
                           cloze_definitions.target_lemma AS cloze_target_lemma,
                           cloze_definitions.target_reading AS cloze_target_reading,
                           cloze_definitions.accepted_answers_json AS cloze_accepted_answers_json,
                           cloze_definitions.hint AS cloze_hint,
                           cloze_definitions.content_version AS cloze_content_version
                    FROM cards
                    JOIN notes ON notes.id = cards.note_id
                    LEFT JOIN examples ON examples.id = (
                        SELECT id FROM examples
                        WHERE note_id = notes.id
                        ORDER BY sort_order, id
                        LIMIT 1
                    )
                    LEFT JOIN cloze_definitions ON cloze_definitions.card_id = cards.id
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
            // v19：sentence_cloze 卡必须带 cloze_definitions——
            // 定义行缺失是数据损坏信号（正面渲染需要 range 做遮罩），
            // 抛错而不是回落成会泄题的默认展示。
            let cloze = try Self.decodeCloze(row, templateKind: templateKind)
            return try ReviewCardContent(
                cardID: DatabaseValueCodec.decodeUUID(row["card_id"]),
                noteID: DatabaseValueCodec.decodeUUID(row["note_id"]),
                deckID: DatabaseValueCodec.decodeUUID(row["deck_id"]),
                templateKind: templateKind,
                headword: row["headword"],
                reading: row["reading"],
                // v19 起 meaning_zh 可空（sentence）——归一为空串。
                meaningZH: (row["meaning_zh"] as String?) ?? "",
                partOfSpeech: row["part_of_speech"],
                usage: row["usage"],
                connection: row["connection"],
                exampleJapanese: row["example_japanese"],
                exampleTranslationZH: row["example_translation_zh"],
                notes: row["notes"],
                contentVersion: row["content_version"],
                pitchAccent: (row["pitch_accent"] as Int?).flatMap(PitchAccent.init(rawValue:)),
                deckIDs: Set(try memberDeckIDs.map { try DatabaseValueCodec.decodeUUID($0) }),
                cloze: cloze
            )
        }
    }

    /// cloze_definitions 列以前缀别名 join：无行返回 nil；sentence_cloze
    /// 卡缺行抛 `inconsistentCardLink`；非 cloze 模板意外带行同样抛错
    /// （写入侧的不变量被破坏，不静默继续）。
    private static func decodeCloze(
        _ row: Row,
        templateKind: CardTemplateKind
    ) throws -> ClozeDefinition? {
        let clozeIDValue: String? = row["cloze_id"]
        switch (templateKind, clozeIDValue) {
        case (.sentenceCloze, .none):
            throw ClozeError.inconsistentCardLink
        case (.sentenceCloze, .some), (_, .some):
            break
        case (_, .none):
            return nil
        }
        guard let clozeIDValue else { return nil }
        let answersJSON: String = row["cloze_accepted_answers_json"]
        guard let answers = try? JSONDecoder().decode(
            [String].self,
            from: Data(answersJSON.utf8)
        ), !answers.isEmpty else {
            throw ClozeError.emptyAcceptedAnswers
        }
        let sourceContextIDValue: String? = row["cloze_source_context_id"]
        return ClozeDefinition(
            id: try DatabaseValueCodec.decodeUUID(clozeIDValue),
            noteID: try DatabaseValueCodec.decodeUUID(row["note_id"] as String),
            cardID: try DatabaseValueCodec.decodeUUID(row["cloze_card_id"] as String),
            sourceContextID: try sourceContextIDValue.map {
                try DatabaseValueCodec.decodeUUID($0)
            },
            sentenceSnapshot: row["cloze_sentence_snapshot"],
            sentenceSHA256: row["cloze_sentence_sha256"],
            range: try ClozeRange(
                persistedVersion: row["cloze_range_version"],
                utf16Start: row["cloze_range_utf16_start"],
                utf16Length: row["cloze_range_utf16_length"]
            ),
            targetSurface: row["cloze_target_surface"],
            targetLemma: row["cloze_target_lemma"],
            targetReading: row["cloze_target_reading"],
            acceptedAnswers: answers,
            hint: row["cloze_hint"],
            contentVersion: row["cloze_content_version"]
        )
    }
}
