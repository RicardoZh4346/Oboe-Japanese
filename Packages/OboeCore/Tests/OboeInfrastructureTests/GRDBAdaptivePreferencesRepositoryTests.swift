import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class GRDBAdaptivePreferencesRepositoryTests: XCTestCase {
    /// 需求 §16 defaults: OFF/ON/OFF/ON — and every toggle persists across a
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
                typedAnswerChineseToJapanese: false,
                autoPlayListeningAudio: true,
                typedAnswerListening: false,
                leechRemindersEnabled: true
            )
        )

        _ = try await repository.updateTypedAnswerChineseToJapanese(true)
        _ = try await repository.updateAutoPlayListeningAudio(false)
        let updated = try await repository.updateTypedAnswerListening(true)
        XCTAssertEqual(
            updated,
            AdaptivePreferences(
                typedAnswerChineseToJapanese: true,
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
        XCTAssertEqual(row.0, true)
        XCTAssertEqual(row.1, false)
        XCTAssertEqual(row.2, true)
        XCTAssertEqual(row.3, true)
        // The new toggles must never alias the existing speech settings.
        XCTAssertEqual(row.4, false)
        XCTAssertEqual(row.5, false)
        try database.close()
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
