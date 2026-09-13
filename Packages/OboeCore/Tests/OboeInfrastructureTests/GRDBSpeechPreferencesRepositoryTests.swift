import Foundation
import GRDB
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class GRDBSpeechPreferencesRepositoryTests: XCTestCase {
    func testDefaultsAndBothAudioPreferencesPersistAcrossReopenAndExportColumns() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oboe-SpeechPreferences-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        var database = try OboeDatabase(path: databaseURL.path)
        var repository = GRDBSpeechPreferencesRepository(database: database)

        let defaults = try await repository.loadOrCreateSpeechPreferences(
            defaultTimeZoneID: "Asia/Shanghai"
        )
        XCTAssertEqual(defaults, .defaults)
        let wordEnabled = try await repository.updateAutoPlayWordAudio(true)
        XCTAssertEqual(
            wordEnabled,
            SpeechPreferences(autoPlayWordAudio: true, autoPlayExampleAudio: false)
        )
        let bothEnabled = try await repository.updateAutoPlayExampleAudio(true)
        XCTAssertEqual(
            bothEnabled,
            SpeechPreferences(autoPlayWordAudio: true, autoPlayExampleAudio: true)
        )

        try database.close()
        database = try OboeDatabase(path: databaseURL.path)
        repository = GRDBSpeechPreferencesRepository(database: database)
        let reopened = try await repository.loadOrCreateSpeechPreferences(
            defaultTimeZoneID: "Asia/Tokyo"
        )
        XCTAssertEqual(
            reopened,
            SpeechPreferences(autoPlayWordAudio: true, autoPlayExampleAudio: true)
        )
        let stored = try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM app_settings WHERE id = 1")
        }
        XCTAssertEqual(stored?["auto_play_word_audio"] as Bool?, true)
        XCTAssertEqual(stored?["auto_play_example_audio"] as Bool?, true)
        try database.close()
    }
}
