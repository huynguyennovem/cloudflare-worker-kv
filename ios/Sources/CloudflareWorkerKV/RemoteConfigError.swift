import Foundation

/// The error thrown by ``CloudflareRemoteConfig/fetch()`` and
/// ``CloudflareRemoteConfig/fetchAndActivate()``.
///
/// A failed fetch never changes the active config: cached and default values
/// stay available.
///
/// ```swift
/// do {
///     try await remoteConfig.fetchAndActivate()
/// } catch let error as RemoteConfigError where error.code == .throttled {
///     print("Retry after \(error.throttleEndTime!)")
/// }
/// ```
public struct RemoteConfigError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// What went wrong. The raw values are shared with the other SDKs.
    public enum Code: String, Sendable, CaseIterable {
        /// No complete response within `fetchTimeout`.
        case timeout
        /// The request failed at the network layer.
        case networkError = "network-error"
        /// The Worker rejected the client key (HTTP 401 or 403).
        case unauthorized
        /// Fetching is rate limited (HTTP 429). See ``throttleEndTime``.
        case throttled
        /// The Worker responded with an unexpected HTTP status.
        case serverError = "server-error"
        /// The Worker responded with a body that is not a valid config.
        case invalidResponse = "invalid-response"
    }

    /// Machine-readable error code.
    public let code: Code

    /// Human-readable description.
    public let message: String

    /// The HTTP status code, when the error came from an HTTP response.
    public let statusCode: Int?

    /// For ``Code/throttled``: when fetching may be retried.
    public let throttleEndTime: Date?

    /// The underlying error, if any (for example a `URLError`).
    public let underlyingError: (any Error)?

    /// Creates an error.
    public init(
        code: Code,
        message: String,
        statusCode: Int? = nil,
        throttleEndTime: Date? = nil,
        underlyingError: (any Error)? = nil
    ) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
        self.throttleEndTime = throttleEndTime
        self.underlyingError = underlyingError
    }

    /// For example `RemoteConfigError[server-error] (HTTP 502): boom`.
    public var description: String {
        let status = statusCode.map { " (HTTP \($0))" } ?? ""
        return "RemoteConfigError[\(code.rawValue)]\(status): \(message)"
    }

    public var errorDescription: String? { description }
}
