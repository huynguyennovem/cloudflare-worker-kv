/// Persistence for the cached config, so that the last activated config
/// survives app restarts.
///
/// The default is ``UserDefaultsConfigStorage``. Implement this protocol to
/// use another store (the Keychain, a file, ...). Implementations may throw:
/// failures are logged and never break fetching or reading values.
public protocol ConfigStorage: Sendable {
    /// Returns the value stored under `key`, or `nil` if there is none.
    func value(forKey key: String) async throws -> String?

    /// Stores `value` under `key`, replacing any previous value.
    func setValue(_ value: String, forKey key: String) async throws

    /// Removes the value stored under `key`.
    func removeValue(forKey key: String) async throws
}
