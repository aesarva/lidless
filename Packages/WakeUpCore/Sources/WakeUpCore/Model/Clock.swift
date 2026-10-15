import Foundation

public protocol WakeClock: Sendable { var now: Date { get } }

public struct SystemClock: WakeClock {
    public init() {}
    public var now: Date { Date() }
}
