import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class GRDBAdaptivePreferencesRepositoryTests: XCTestCase {
    /// v0.5.5 defaults: ON/ON/ON/ON — and every toggle persists across a
    /// database reopen without touching the speech auto-play columns.
    func testDefaultsAndAllTogglesPersistAcrossReopenWithoutTouchingSpeech() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AdaptivePreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        var database = try OboeDatabase(path: databaseURL.path)
        var repository = GRDBAdaptivePreferencesRepository(database: database)

        let defaults = try await repository.loadOrCreateAdaptivePreferences(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(defaults, .defaults)
        XCTAssertEqual(
            defaults,
            AdaptivePreferences(
                typedAnswerChineseToJapanese: true,
                autoPlayListeningAudio: true,
                typedAnswerListening: true,
                leechRemindersEnabled: true
            )
        )

        _ = try await repository.updateTypedAnswerChineseToJapanese(false)
        _ = try await repository.updateAutoPlayListeningAudio(false)
        let updated = try await repository.updateTypedAnswerListening(true)
        XCTAssertEqual(
            updated,
            AdaptivePreferences(
                typedAnswerChineseToJapanese: false,
                autoPlayListeningAudio: false,
                typedAnswerListening: true,
                leechRemindersEnabled: true
            )
        )

        try database.close()
        database = try OboeDatabase(path: databaseURL.path)
        repository = GRDBAdaptivePreferencesRepository(database: database)
        let reopened = try await repository.loadOrCreateAdaptivePreferences(
            defaultTimeZoneID: "Asia/Tokyo"
        )
        XCTAssertEqual(reopened, updated)

        let stored = try await database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM app_settings WHERE id = 1").map {
                (
                    $0["typed_answer_zh_ja"] as Bool?,
                    $0["auto_play_listening_audio"] as Bool?,
                    $0["typed_answer_listening"] as Bool?,
                    $0["leech_reminders_enabled"] as Bool?,
                    $0["auto_play_word_audio"] as Bool?,
                    $0["auto_play_example_audio"] as Bool?
                )
            }
        }
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.0, false)
        XCTAssertEqual(row.1, false)
        XCTAssertEqual(row.2, true)
        XCTAssertEqual(row.3, true)
        // The new toggles must never alias the existing speech settings.
        XCTAssertEqual(row.4, false)
        XCTAssertEqual(row.5, false)
        try database.close()
    }

    /// v0.5.5：行缺失时显式写入领域默认（typed 双开关 ON）——v13 冻结的
    /// 列 DEFAULT 仍是 v0.4 的 0/1/0/1，绝不能依赖 schema 兜底。
    func testMissingRowIsCreatedWithTypedDefaultsEnabled() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AdaptivePreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        defer { try? database.close() }
        let repository = GRDBAdaptivePreferencesRepository(database: database)

        let loaded = try await repository.loadOrCreateAdaptivePreferences(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(loaded, .defaults)
        XCTAssertTrue(loaded.typedAnswerChineseToJapanese)
        XCTAssertTrue(loaded.typedAnswerListening)

        // 直接读库确认列值显式写入为 1（而非恰好与 schema DEFAULT 一致）。
        let stored = try await database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT typed_answer_zh_ja, typed_answer_listening
                    FROM app_settings WHERE id = 1
                    """
            ).map {
                ($0["typed_answer_zh_ja"] as Bool?,
                 $0["typed_answer_listening"] as Bool?)
            }
        }
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row.0, true)
        XCTAssertEqual(row.1, true)
    }

    /// 已存行的 false 选择永不被 loadOrCreate 改写（ON CONFLICT DO NOTHING）。
    func testLoadOrCreatePreservesExistingFalseValues() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AdaptivePreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        defer { try? database.close() }
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings(
                        id, schema_version, learning_time_zone_id, daily_new_card_limit,
                        typed_answer_zh_ja, auto_play_listening_audio,
                        typed_answer_listening, leech_reminders_enabled
                    ) VALUES (1, 1, 'Asia/Shanghai', 10, 0, 1, 0, 1)
                    """
            )
        }

        let repository = GRDBAdaptivePreferencesRepository(database: database)
        let loaded = try await repository.loadOrCreateAdaptivePreferences(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertFalse(loaded.typedAnswerChineseToJapanese)
        XCTAssertFalse(loaded.typedAnswerListening)
        XCTAssertTrue(loaded.autoPlayListeningAudio)
        XCTAssertTrue(loaded.leechRemindersEnabled)
    }

    /// 无论哪个 repository 先物化 app_settings 行，缺失行都写入新领域
    /// 默认——覆盖"speech 仓储先于 adaptive 仓储建行"的初始化顺序。
    func testRowCreatedByAnotherRepositoryStillCarriesAdaptiveDefaults() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AdaptivePreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        defer { try? database.close() }

        let speech = GRDBSpeechPreferencesRepository(database: database)
        _ = try await speech.loadOrCreateSpeechPreferences(
            defaultTimeZoneID: "Asia/Shanghai"
        )

        let repository = GRDBAdaptivePreferencesRepository(database: database)
        let loaded = try await repository.loadOrCreateAdaptivePreferences(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(loaded, .defaults)
        XCTAssertTrue(loaded.typedAnswerChineseToJapanese)
        XCTAssertTrue(loaded.typedAnswerListening)
    }

    func testInvalidTimeZoneIsRejectedBeforeCreatingRow() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-AdaptivePreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let database = try OboeDatabase(
            path: directoryURL.appendingPathComponent("oboe.sqlite").path
        )
        let service = AdaptivePreferencesService(
            repository: GRDBAdaptivePreferencesRepository(database: database)
        )
        await XCTAssertThrowsErrorAsync(
            try await service.load(defaultTimeZoneID: "Not/AZone")
        ) { error in
            XCTAssertEqual(
                error as? StudyDayPlanningError,
                .invalidTimeZone("Not/AZone")
            )
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ errorHandler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error to be thrown. \(message())", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
