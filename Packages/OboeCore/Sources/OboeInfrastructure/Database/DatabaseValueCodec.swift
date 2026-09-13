import Foundation

public enum DatabaseValueCodecError: Error, Equatable, Sendable {
    case invalidUUID(String)
    case invalidDate(Double)
    case invalidSchedulingState(Int)
    case invalidCardTemplate(String)
}

public enum DatabaseValueCodec {
    public static func encode(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    public static func decodeUUID(_ value: String) throws -> UUID {
        guard value.count == 36, let uuid = UUID(uuidString: value) else {
            throw DatabaseValueCodecError.invalidUUID(value)
        }
        return uuid
    }

    public static func encode(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max) else {
            throw DatabaseValueCodecError.invalidDate(date.timeIntervalSince1970)
        }
        return Int64(milliseconds.rounded())
    }

    public static func decodeDate(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
