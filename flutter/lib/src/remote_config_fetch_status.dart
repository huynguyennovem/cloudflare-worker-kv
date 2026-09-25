/// Outcome of the most recent fetch attempt.
enum RemoteConfigFetchStatus {
  /// No fetch has been attempted yet.
  noFetchYet,

  /// The last fetch succeeded (including "not modified" responses).
  success,

  /// The last fetch failed (network error, timeout, bad response, ...).
  failure,

  /// The last fetch was rejected because of rate limiting.
  throttle,
}
