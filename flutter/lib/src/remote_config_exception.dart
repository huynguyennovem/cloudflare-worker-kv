/// Error thrown by fetch operations.
class RemoteConfigException implements Exception {
  /// Creates an exception.
  const RemoteConfigException({
    required this.code,
    required this.message,
    this.statusCode,
    this.throttleEndTime,
    this.cause,
  });

  /// The request did not complete within `fetchTimeout`.
  static const String codeTimeout = 'timeout';

  /// The request failed at the network layer.
  static const String codeNetworkError = 'network-error';

  /// The Worker rejected the client key (HTTP 401/403).
  static const String codeUnauthorized = 'unauthorized';

  /// Fetching is rate limited (HTTP 429). See [throttleEndTime].
  static const String codeThrottled = 'throttled';

  /// The Worker responded with an unexpected HTTP status.
  static const String codeServerError = 'server-error';

  /// The Worker responded with a body that is not a valid config payload.
  static const String codeInvalidResponse = 'invalid-response';

  /// Machine readable error code, one of the `code*` constants.
  final String code;

  /// Human readable description.
  final String message;

  /// HTTP status code, when the error came from an HTTP response.
  final int? statusCode;

  /// For [codeThrottled]: when fetching may be retried.
  final DateTime? throttleEndTime;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'RemoteConfigException[$code]$status: $message';
  }
}
