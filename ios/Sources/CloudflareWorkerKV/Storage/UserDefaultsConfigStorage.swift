import Foundation

/// The default ``ConfigStorage``, backed by `UserDefaults`.
///
/// Values are stored under keys starting with `cloudflare_worker_kv:`.
public final class UserDefaultsConfigStorage: ConfigStorage, @unchecked Sendable {
    // UserDefaults is thread-safe.
    private let userDefaults: UserDefaults

    /// Creates a storage backed by `userDefaults`.
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func value(forKey key: String) async throws -> String? {
        userDefaults.string(forKey: key)
    }

    public func setValue(_ value: String, forKey key: String) async throws {
        userDefaults.set(value, forKey: key)
    }

    public func removeValue(forKey key: String) async throws {
        userDefaults.removeObject(forKey: key)
    }
}
