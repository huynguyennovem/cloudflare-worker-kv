import Foundation
@testable import CloudflareWorkerKV

struct StorageFailure: Error, CustomStringConvertible {
    let description: String
}

/// A storage whose every operation fails.
struct ThrowingStorage: ConfigStorage {
    func value(forKey key: String) async throws -> String? {
        throw StorageFailure(description: "read")
    }

    func setValue(_ value: String, forKey key: String) async throws {
        throw StorageFailure(description: "write")
    }

    func removeValue(forKey key: String) async throws {
        throw StorageFailure(description: "delete")
    }
}

/// An in-memory storage whose writes can be slowed down: after
/// ``resetDelays()`` the first write takes 30 ms, the second 20 ms, the third
/// 10 ms. Unserialised writes would finish out of order and leave stale data.
actor SlowStorage: ConfigStorage {
    private(set) var data: [String: String] = [:]
    private var delayMs: UInt64 = 0

    func resetDelays() {
        delayMs = 30
    }

    func value(forKey key: String) -> String? {
        data[key]
    }

    func setValue(_ value: String, forKey key: String) async throws {
        let delay = delayMs
        delayMs = delayMs >= 10 ? delayMs - 10 : 0
        try await Task.sleep(nanoseconds: delay * 1_000_000)
        data[key] = value
    }

    func removeValue(forKey key: String) {
        data[key] = nil
    }
}
