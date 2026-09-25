import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'remote_config_exception.dart';

/// Path of the config endpoint, relative to the Worker endpoint.
const String configPath = 'v1/config';

/// Used when a 429 response carries no usable `Retry-After` header.
const Duration defaultThrottleDuration = Duration(minutes: 1);

/// An immutable set of remote entries plus the version the Worker assigned.
@internal
@immutable
class ConfigSnapshot {
  /// Creates a snapshot.
  ConfigSnapshot({required this.version, required Map<String, String> entries})
      : entries = Map.unmodifiable(entries);

  /// An empty snapshot.
  static final ConfigSnapshot empty = ConfigSnapshot(version: '', entries: {});

  /// Opaque version identifier (the Worker uses a SHA-256 of the entries).
  final String version;

  /// Parameter values, always strings.
  final Map<String, String> entries;

  /// Whether both snapshots contain exactly the same entries.
  bool hasSameEntries(ConfigSnapshot other) {
    if (entries.length != other.entries.length) return false;
    for (final e in entries.entries) {
      if (other.entries[e.key] != e.value) return false;
    }
    return true;
  }

  /// Serialises the snapshot for persistence and for the wire format.
  Map<String, Object?> toJson() => {'version': version, 'entries': entries};

  /// Parses a payload of the form `{"version": "...", "entries": {...}}`.
  ///
  /// Non-string entry values are converted like the Worker does (numbers and
  /// booleans via `toString`, maps and lists as JSON); `null` entries are
  /// dropped. Throws [FormatException] when the shape is wrong.
  factory ConfigSnapshot.fromJson(Object? json, {String? fallbackVersion}) {
    if (json is! Map) {
      throw const FormatException('Config payload must be a JSON object.');
    }
    final rawEntries = json['entries'];
    if (rawEntries is! Map) {
      throw const FormatException('"entries" must be a JSON object.');
    }
    final entries = <String, String>{};
    rawEntries.forEach((Object? key, Object? value) {
      if (key is! String || value == null) return;
      entries[key] = switch (value) {
        String() => value,
        Map() || List() => jsonEncode(value),
        _ => value.toString(),
      };
    });
    final version = json['version'];
    return ConfigSnapshot(
      version: version is String ? version : (fallbackVersion ?? ''),
      entries: entries,
    );
  }
}

/// Result of [WorkerClient.fetch].
@internal
sealed class WorkerFetchResult {
  const WorkerFetchResult();
}

/// The Worker returned a (possibly unchanged) config.
@internal
final class WorkerConfigFetched extends WorkerFetchResult {
  /// Creates a result.
  const WorkerConfigFetched(this.snapshot, this.etag);

  /// The fetched config.
  final ConfigSnapshot snapshot;

  /// The response `ETag`, sent back as `If-None-Match` on the next fetch.
  final String? etag;
}

/// The Worker returned `304 Not Modified`.
@internal
final class WorkerConfigNotModified extends WorkerFetchResult {
  /// Creates a result.
  const WorkerConfigNotModified();
}

/// Low-level HTTP client for the config Worker.
@internal
class WorkerClient {
  /// Creates a client.
  WorkerClient({
    required Uri endpoint,
    required this.template,
    this.clientKey,
    http.Client? httpClient,
    DateTime Function()? clock,
  })  : configUri = buildConfigUri(endpoint, template),
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _clock = clock ?? DateTime.now;

  /// Template name sent as the `template` query parameter.
  final String template;

  /// Optional value for the `X-Client-Key` header.
  final String? clientKey;

  /// Fully resolved URL of the config endpoint.
  final Uri configUri;

  final http.Client _http;
  final bool _ownsHttpClient;
  final DateTime Function() _clock;

  /// Appends [configPath] to [endpoint]'s path and sets `template`,
  /// preserving any existing path prefix and query parameters.
  static Uri buildConfigUri(Uri endpoint, String template) {
    if (!endpoint.hasScheme || endpoint.host.isEmpty) {
      throw ArgumentError.value(
          endpoint, 'endpoint', 'must be an absolute http(s) URL');
    }
    final base = endpoint.path.endsWith('/')
        ? endpoint.path.substring(0, endpoint.path.length - 1)
        : endpoint.path;
    return endpoint.removeFragment().replace(
      path: '$base/$configPath',
      queryParameters: {...endpoint.queryParameters, 'template': template},
    );
  }

  /// Fetches the config. Sends `If-None-Match: etag` when [etag] is given.
  ///
  /// Throws [RemoteConfigException] on any failure.
  Future<WorkerFetchResult> fetch({
    String? etag,
    required Duration timeout,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      if (clientKey != null) 'X-Client-Key': clientKey!,
      if (etag != null) 'If-None-Match': etag,
    };

    final http.Response response;
    try {
      response = await _http.get(configUri, headers: headers).timeout(timeout);
    } on TimeoutException catch (e) {
      throw RemoteConfigException(
        code: RemoteConfigException.codeTimeout,
        message: 'No response within ${timeout.inMilliseconds} ms.',
        cause: e,
      );
    } on Exception catch (e) {
      throw RemoteConfigException(
        code: RemoteConfigException.codeNetworkError,
        message: 'Request to $configUri failed: $e',
        cause: e,
      );
    }

    final status = response.statusCode;
    if (status == 304) {
      if (etag == null) {
        throw const RemoteConfigException(
          code: RemoteConfigException.codeInvalidResponse,
          message: 'Received 304 for an unconditional request.',
          statusCode: 304,
        );
      }
      return const WorkerConfigNotModified();
    }
    if (status == 200) {
      final responseEtag = response.headers['etag'];
      try {
        final snapshot = ConfigSnapshot.fromJson(
          jsonDecode(utf8.decode(response.bodyBytes)),
          fallbackVersion: _stripEtag(responseEtag),
        );
        return WorkerConfigFetched(snapshot, responseEtag);
      } on FormatException catch (e) {
        throw RemoteConfigException(
          code: RemoteConfigException.codeInvalidResponse,
          message: 'Malformed config payload: ${e.message}',
          statusCode: status,
          cause: e,
        );
      }
    }
    if (status == 401 || status == 403) {
      throw RemoteConfigException(
        code: RemoteConfigException.codeUnauthorized,
        message: 'The Worker rejected the client key.',
        statusCode: status,
      );
    }
    if (status == 429) {
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      throw RemoteConfigException(
        code: RemoteConfigException.codeThrottled,
        message: 'Fetch is rate limited.',
        statusCode: status,
        throttleEndTime: _clock().add(retryAfter),
      );
    }
    throw RemoteConfigException(
      code: RemoteConfigException.codeServerError,
      message: 'Unexpected response: ${_describeError(response)}',
      statusCode: status,
    );
  }

  /// Closes the underlying HTTP client if this instance created it.
  void close() {
    if (_ownsHttpClient) _http.close();
  }

  static Duration _parseRetryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    if (seconds == null || seconds < 0) return defaultThrottleDuration;
    return Duration(seconds: seconds);
  }

  static String? _stripEtag(String? etag) {
    if (etag == null) return null;
    var tag = etag.trim();
    if (tag.startsWith('W/')) tag = tag.substring(2);
    if (tag.length >= 2 && tag.startsWith('"') && tag.endsWith('"')) {
      tag = tag.substring(1, tag.length - 1);
    }
    return tag;
  }

  static String _describeError(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is String) {
        return '${body['error']}${body['message'] is String ? ' - ${body['message']}' : ''}';
      }
    } on FormatException {
      // Fall through to the raw reason phrase.
    }
    return response.reasonPhrase ?? 'HTTP ${response.statusCode}';
  }
}
