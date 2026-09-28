/// A ``ConfigStorage`` that keeps data in memory only. Useful for tests and
/// previews.
public actor InMemoryConfigStorage: ConfigStorage {
    /// The stored data.
    public private(set) var data: [String: String]

    /// Creates a storage, optionally pre-populated with `initial`.
    public init(_ initial: [String: String] = [:]) {
        data = initial
    }

    public func value(forKey key: String) -> String? {
        data[key]
    }

    public func setValue(_ value: String, forKey key: String) {
        data[key] = value
    }

    public func removeValue(forKey key: String) {
        data[key] = nil
    }
}
