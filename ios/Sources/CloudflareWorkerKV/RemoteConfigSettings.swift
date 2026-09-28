import Foundation

/// Settings that control fetch behaviour.
///
/// ```swift
/// await remoteConfig.setConfigSettings(RemoteConfigSettings(
///     fetchTimeout: 10,
///     minimumFetchInterval: 3_600 // use 0 during development
/// ))
/// ```
public struct RemoteConfigSettings: Sendable, Hashable, CustomStringConvertible {
    /// The default ``fetchTimeout``: 60 seconds.
    public static let defaultFetchTimeout: TimeInterval = 60

    /// The default ``minimumFetchInterval``: 12 hours.
    public static let defaultMinimumFetchInterval: TimeInterval = 43_200

    /// Maximum time, in seconds, for a whole fetch request, body included.
    public let fetchTimeout: TimeInterval

    /// Minimum age, in seconds, of the last successful fetch before
    /// ``CloudflareRemoteConfig/fetch()`` contacts the Worker again.
    public let minimumFetchInterval: TimeInterval

    /// Creates settings.
    ///
    /// - Precondition: `fetchTimeout` is finite and greater than zero, and
    ///   `minimumFetchInterval` is finite and not negative.
    public init(
        fetchTimeout: TimeInterval = defaultFetchTimeout,
        minimumFetchInterval: TimeInterval = defaultMinimumFetchInterval
    ) {
        if let problem = Self.problem(fetchTimeout: fetchTimeout,
                                      minimumFetchInterval: minimumFetchInterval) {
            preconditionFailure("Invalid RemoteConfigSettings: \(problem)")
        }
        self.fetchTimeout = fetchTimeout
        self.minimumFetchInterval = minimumFetchInterval
    }

    public var description: String {
        "RemoteConfigSettings(fetchTimeout: \(fetchTimeout), minimumFetchInterval: \(minimumFetchInterval))"
    }

    /// Why the values are invalid, or `nil` when they are valid.
    static func problem(fetchTimeout: TimeInterval, minimumFetchInterval: TimeInterval) -> String? {
        if !fetchTimeout.isFinite || fetchTimeout <= 0 {
            return "fetchTimeout must be greater than zero, got \(fetchTimeout)."
        }
        if !minimumFetchInterval.isFinite || minimumFetchInterval < 0 {
            return "minimumFetchInterval must not be negative, got \(minimumFetchInterval)."
        }
        return nil
    }

    /// Restores settings persisted as
    /// `{"fetchTimeoutMs": <int>, "minimumFetchIntervalMs": <int>}`.
    /// Returns `nil` on invalid input.
    init?(validatingMs json: JSONValue?) {
        guard case .int(let timeout)? = json?["fetchTimeoutMs"],
              case .int(let interval)? = json?["minimumFetchIntervalMs"],
              timeout > 0, interval >= 0
        else { return nil }
        self.init(fetchTimeout: Double(timeout) / 1000,
                  minimumFetchInterval: Double(interval) / 1000)
    }

    /// The persisted form, in whole milliseconds.
    var jsonValue: JSONValue {
        [
            "fetchTimeoutMs": .int(Self.milliseconds(fetchTimeout)),
            "minimumFetchIntervalMs": .int(Self.milliseconds(minimumFetchInterval)),
        ]
    }

    /// Rounds `seconds` to whole milliseconds, clamped to the Int64 range.
    static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        let ms = (seconds * 1000).rounded()
        if ms.isNaN { return 0 }
        if ms >= 9.2e18 { return .max }
        if ms <= -9.2e18 { return .min }
        return Int64(ms)
    }
}
