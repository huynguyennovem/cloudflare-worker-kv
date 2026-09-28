/// Outcome of the most recent fetch attempt.
///
/// The raw values are the names stored in the persisted cache, shared with the
/// other SDKs of this repository.
public enum RemoteConfigFetchStatus: String, Sendable, CaseIterable {
    /// No fetch has been attempted yet.
    case noFetchYet
    /// The last fetch succeeded, including "not modified" responses.
    case success
    /// The last fetch failed: network error, timeout, bad response, ...
    case failure
    /// The last fetch was rejected because of rate limiting (HTTP 429).
    case throttled = "throttle"
}
