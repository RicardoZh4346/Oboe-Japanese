import Foundation

public protocol SchedulingClock: Sendable {
    func now() -> Date
}

public struct SystemSchedulingClock: SchedulingClock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}
