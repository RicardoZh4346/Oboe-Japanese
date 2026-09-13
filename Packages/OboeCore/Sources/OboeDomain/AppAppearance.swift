import Foundation

public enum AppAppearance: String, CaseIterable, Codable, Hashable, Sendable {
    case system
    case light
    case dark
}

public protocol AppearancePreferencesRepository: Sendable {
    func loadOrCreateAppearance(defaultTimeZoneID: String) async throws -> AppAppearance
    func updateAppearance(_ appearance: AppAppearance) async throws -> AppAppearance
}

public struct AppearancePreferencesService: Sendable {
    private let repository: any AppearancePreferencesRepository

    public init(repository: any AppearancePreferencesRepository) {
        self.repository = repository
    }

    public func load(defaultTimeZoneID: String) async throws -> AppAppearance {
        guard TimeZone(identifier: defaultTimeZoneID) != nil else {
            throw StudyDayPlanningError.invalidTimeZone(defaultTimeZoneID)
        }
        return try await repository.loadOrCreateAppearance(
            defaultTimeZoneID: defaultTimeZoneID
        )
    }

    public func set(_ appearance: AppAppearance) async throws -> AppAppearance {
        try await repository.updateAppearance(appearance)
    }
}
