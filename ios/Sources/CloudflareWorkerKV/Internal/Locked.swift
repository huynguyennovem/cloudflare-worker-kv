import Foundation

/// A value protected by a lock. Unlike an actor, it can be read synchronously,
/// for example from a SwiftUI `body`.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value. `body` must not block
    /// or call back into this lock.
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}
