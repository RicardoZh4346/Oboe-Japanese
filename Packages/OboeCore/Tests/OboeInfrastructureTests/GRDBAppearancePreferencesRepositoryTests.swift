import Foundation
import XCTest
import OboeDomain
@testable import OboeInfrastructure

final class GRDBAppearancePreferencesRepositoryTests: XCTestCase {
    func testAppearanceDefaultsToSystemAndPersistsAcrossReopen() async throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Oboe-P21b-Appearance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let databaseURL = directoryURL.appendingPathComponent("oboe.sqlite")
        var database = try OboeDatabase(path: databaseURL.path)
        var service = AppearancePreferencesService(
            repository: GRDBAppearancePreferencesRepository(database: database)
        )

        let defaultAppearance = try await service.load(defaultTimeZoneID: "Asia/Shanghai")
        XCTAssertEqual(defaultAppearance, .system)
        let darkAppearance = try await service.set(.dark)
        XCTAssertEqual(darkAppearance, .dark)
        try database.close()

        database = try OboeDatabase(path: databaseURL.path)
        service = AppearancePreferencesService(
            repository: GRDBAppearancePreferencesRepository(database: database)
        )
        let reopenedAppearance = try await service.load(defaultTimeZoneID: "Asia/Tokyo")
        XCTAssertEqual(reopenedAppearance, .dark)
        let lightAppearance = try await service.set(.light)
        XCTAssertEqual(lightAppearance, .light)
        try database.close()
    }
}
