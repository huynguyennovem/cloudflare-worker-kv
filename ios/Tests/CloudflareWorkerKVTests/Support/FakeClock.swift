import Foundation
@testable import CloudflareWorkerKV

/// A controllable clock, starting at 2026-01-01T00:00:00Z.
final class FakeClock: Sendable {
    static let start = Date(timeIntervalSince1970: 1_767_225_600)

    private let current: Locked<Date>

    init(_ start: Date = FakeClock.start) {
        current = Locked(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    /// The clock as the SDK takes it.
    var function: @Sendable () -> Date {
        { [self] in now }
    }
}
