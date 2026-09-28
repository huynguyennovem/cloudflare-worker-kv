import Foundation

/// Thrown by ``withTimeout(seconds:operation:)`` when time runs out.
struct TimeoutError: Error {}

/// Runs `operation`, and cancels it and throws ``TimeoutError`` if it has not
/// finished after `seconds`. The limit covers the whole operation, unlike
/// `URLRequest.timeoutInterval`, which is an idle timeout.
func withTimeout<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        // The first child to finish wins; the other one is cancelled.
        guard let value = try await group.next() else { throw TimeoutError() }
        return value
    }
}

/// `seconds` in nanoseconds, clamped to about 30 years.
private func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    let clamped = min(max(seconds, 0), 1_000_000_000)
    return UInt64(clamped * 1_000_000_000)
}
