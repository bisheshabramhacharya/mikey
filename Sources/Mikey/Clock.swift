import Foundation

/// Time source for Session naming and timestamps. Faked in tests.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}
