import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'remote_config_exception.dart';
import 'remote_config_fetch_status.dart';
import 'remote_config_settings.dart';
import 'remote_config_value.dart';
import 'storage/config_storage.dart';
import 'storage/shared_preferences_config_storage.dart';
import 'worker_client.dart';

/// Remote config backed by a Cloudflare Worker reading from Workers KV.
///
/// Typical use:
///
/// ```dart
/// await CloudflareRemoteConfig.initialize(
///   endpoint: Uri.parse('https://my-config.example.workers.dev'),
/// );
/// final remoteConfig = CloudflareRemoteConfig.instance;
/// await remoteConfig.setDefaults({'welcome': 'Hello'});
/// await remoteConfig.fetchAndActivate();
/// final welcome = remoteConfig.getString('welcome');
/// ```
///
/// Values are resolved in this order: activated remote value, default value,
/// static value (empty string / 0 / false).
class CloudflareRemoteConfig {
  /// Creates an instance. Most apps should use [initialize] and [instance]
  /// instead; create instances directly to talk to several templates or
  /// Workers at once. Call [ensureInitialized] before reading values.
  ///
  /// - [endpoint]: base URL of the Worker, e.g.
  ///   `https://my-config.example.workers.dev`. A path prefix is allowed.
  /// - [template]: which KV config template to read (`config:<template>`).
  /// - [clientKey]: sent as `X-Client-Key` when the Worker requires one.
  /// - [httpClient]: custom HTTP client (proxies, testing, ...).
  /// - [storage]: persistence for the cache; defaults to shared_preferences.
  CloudflareRemoteConfig({
    required Uri endpoint,
    String template = defaultTemplate,
    String? clientKey,
    http.Client? httpClient,
    ConfigStorage? storage,
    @visibleForTesting DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _storage = storage ?? SharedPreferencesConfigStorage(),
        _storageKey = '$_storageKeyPrefix${endpoint.toString()}|$template',
        _client = WorkerClient(
          endpoint: endpoint,
          template: _checkTemplate(template),
          clientKey: clientKey,
          httpClient: httpClient,
          clock: clock,
        );

  /// Template used when none is given.
  static const String defaultTemplate = 'default';

  static const String _storageKeyPrefix = 'cloudflare_worker_kv:';
  static const int _storageFormatVersion = 1;
  static final RegExp _templatePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  static CloudflareRemoteConfig? _instance;

  /// The instance created by [initialize].
  ///
  /// Throws a [StateError] if [initialize] has not been called.
  static CloudflareRemoteConfig get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'CloudflareRemoteConfig.initialize() must be called before '
        'accessing CloudflareRemoteConfig.instance.',
      );
    }
    return instance;
  }

  /// Creates the shared [instance], loads the cached config from storage and
  /// returns it. Calling it again replaces the shared instance.
  ///
  /// See the [CloudflareRemoteConfig.new] constructor for the parameters.
  static Future<CloudflareRemoteConfig> initialize({
    required Uri endpoint,
    String template = defaultTemplate,
    String? clientKey,
    http.Client? httpClient,
    ConfigStorage? storage,
  }) async {
    final config = CloudflareRemoteConfig(
      endpoint: endpoint,
      template: template,
      clientKey: clientKey,
      httpClient: httpClient,
      storage: storage,
    );
    await config.ensureInitialized();
    final previous = _instance;
    _instance = config;
    previous?.dispose();
    return config;
  }

  /// Clears the shared [instance]. Intended for tests.
  @visibleForTesting
  static void resetInstance() {
    _instance?.dispose();
    _instance = null;
  }

  final DateTime Function() _clock;
  final ConfigStorage _storage;
  final String _storageKey;
  final WorkerClient _client;

  Map<String, String> _defaults = const {};
  ConfigSnapshot? _active;
  ConfigSnapshot? _fetched;
  String? _etag;
  DateTime? _lastSuccessfulFetch;
  DateTime? _throttleEndTime;
  RemoteConfigFetchStatus _lastFetchStatus = RemoteConfigFetchStatus.noFetchYet;
  RemoteConfigSettings _settings = RemoteConfigSettings();

  Future<void>? _initialization;
  Future<void>? _inFlightFetch;
  Future<void> _pendingWrite = Future.value();

  /// When the last successful fetch completed, or the epoch if none has.
  DateTime get lastFetchTime =>
      _lastSuccessfulFetch ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// Outcome of the most recent fetch attempt.
  RemoteConfigFetchStatus get lastFetchStatus => _lastFetchStatus;

  /// The current fetch settings.
  RemoteConfigSettings get settings => _settings;

  /// Loads the cached config from storage. Safe to call multiple times.
  ///
  /// Every other asynchronous method awaits this internally, but the
  /// synchronous getters only see cached values once it has completed.
  Future<void> ensureInitialized() => _initialization ??= _load();

  /// Replaces the fetch settings and persists them.
  Future<void> setConfigSettings(RemoteConfigSettings settings) async {
    await ensureInitialized();
    _settings = settings;
    await _persist();
  }

  /// Replaces the in-app default values.
  ///
  /// Supported value types are [String], [num], [bool], and JSON-encodable
  /// [Map] / [List] values (stored as JSON strings). `null` values are
  /// ignored. Throws [ArgumentError] for any other type.
  Future<void> setDefaults(Map<String, dynamic> defaultParameters) async {
    final converted = <String, String>{};
    defaultParameters.forEach((key, value) {
      if (value == null) return;
      converted[key] = switch (value) {
        String() => value,
        num() || bool() => value.toString(),
        Map() || List() => jsonEncode(value),
        _ => throw ArgumentError.value(
            value, key, 'unsupported default type ${value.runtimeType}'),
      };
    });
    _defaults = Map.unmodifiable(converted);
  }

  /// Fetches the latest config from the Worker without activating it.
  ///
  /// Does nothing if the last successful fetch is younger than
  /// [RemoteConfigSettings.minimumFetchInterval]. Concurrent calls share a
  /// single request. Throws [RemoteConfigException] on failure; the active
  /// config is never modified by a failed fetch.
  Future<void> fetch() => _inFlightFetch ??= _fetch().whenComplete(() {
        _inFlightFetch = null;
      });

  /// Makes the last fetched config available to the getters.
  ///
  /// Returns `true` if a newer config was activated, `false` if there was
  /// nothing new to activate.
  Future<bool> activate() async {
    await ensureInitialized();
    final fetched = _fetched;
    if (fetched == null) return false;
    _active = fetched;
    _fetched = null;
    await _persist();
    return true;
  }

  /// Calls [fetch] then [activate]. Returns the result of [activate].
  Future<bool> fetchAndActivate() async {
    await fetch();
    return activate();
  }

  /// Returns every known key (remote and default) with its resolved value.
  Map<String, RemoteConfigValue> getAll() {
    final keys = <String>{..._defaults.keys, ...?_active?.entries.keys};
    return {for (final key in keys) key: getValue(key)};
  }

  /// Returns the value for [key] as a [bool].
  bool getBool(String key) => getValue(key).asBool();

  /// Returns the value for [key] as an [int].
  int getInt(String key) => getValue(key).asInt();

  /// Returns the value for [key] as a [double].
  double getDouble(String key) => getValue(key).asDouble();

  /// Returns the value for [key] as a [String].
  String getString(String key) => getValue(key).asString();

  /// Returns the [RemoteConfigValue] for [key], including its [ValueSource].
  RemoteConfigValue getValue(String key) {
    final remote = _active?.entries[key];
    if (remote != null) {
      return RemoteConfigValue(remote, ValueSource.valueRemote);
    }
    final fallback = _defaults[key];
    if (fallback != null) {
      return RemoteConfigValue(fallback, ValueSource.valueDefault);
    }
    return const RemoteConfigValue(null, ValueSource.valueStatic);
  }

  /// Releases the HTTP client if this instance created it.
  void dispose() => _client.close();

  Future<void> _fetch() async {
    await ensureInitialized();
    final now = _clock();

    final throttleEnd = _throttleEndTime;
    if (throttleEnd != null && now.isBefore(throttleEnd)) {
      _lastFetchStatus = RemoteConfigFetchStatus.throttle;
      throw RemoteConfigException(
        code: RemoteConfigException.codeThrottled,
        message: 'Fetch is throttled until $throttleEnd.',
        throttleEndTime: throttleEnd,
      );
    }

    final lastSuccess = _lastSuccessfulFetch;
    if (lastSuccess != null &&
        now.difference(lastSuccess) < _settings.minimumFetchInterval &&
        !now.isBefore(lastSuccess)) {
      return; // Cached config is fresh enough.
    }

    try {
      final result = await _client.fetch(
        etag: _etag,
        timeout: _settings.fetchTimeout,
      );
      switch (result) {
        case WorkerConfigFetched(:final snapshot, :final etag):
          _etag = etag;
          final active = _active ?? ConfigSnapshot.empty;
          // Only keep a pending config when it differs from the active one.
          _fetched = snapshot.hasSameEntries(active) ? null : snapshot;
        case WorkerConfigNotModified():
          break; // Whatever is pending or active is still current.
      }
      _lastSuccessfulFetch = _clock();
      _throttleEndTime = null;
      _lastFetchStatus = RemoteConfigFetchStatus.success;
    } on RemoteConfigException catch (e) {
      if (e.code == RemoteConfigException.codeThrottled) {
        _throttleEndTime = e.throttleEndTime;
        _lastFetchStatus = RemoteConfigFetchStatus.throttle;
      } else {
        _lastFetchStatus = RemoteConfigFetchStatus.failure;
      }
      rethrow;
    } finally {
      await _persist();
    }
  }

  Future<void> _load() async {
    final String? raw;
    try {
      raw = await _storage.read(_storageKey);
    } on Object catch (e) {
      debugPrint('cloudflare_worker_kv: failed to read cache: $e');
      return;
    }
    if (raw == null) return;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['formatVersion'] != _storageFormatVersion) {
        return;
      }
      final active = json['active'];
      final fetched = json['fetched'];
      final etag = json['etag'];
      _active = active == null ? null : ConfigSnapshot.fromJson(active);
      _fetched = fetched == null ? null : ConfigSnapshot.fromJson(fetched);
      _etag = etag is String ? etag : null;
      _lastSuccessfulFetch = _readTime(json['lastSuccessfulFetchMs']);
      _throttleEndTime = _readTime(json['throttleEndMs']);
      _lastFetchStatus = RemoteConfigFetchStatus.values.firstWhere(
        (s) => s.name == json['lastFetchStatus'],
        orElse: () => RemoteConfigFetchStatus.noFetchYet,
      );
      _settings = RemoteConfigSettings.tryFromJson(json['settings']) ??
          RemoteConfigSettings();
    } on Object catch (e) {
      debugPrint('cloudflare_worker_kv: ignoring corrupt cache: $e');
      _active = null;
      _fetched = null;
      _etag = null;
      _lastSuccessfulFetch = null;
      _throttleEndTime = null;
      _lastFetchStatus = RemoteConfigFetchStatus.noFetchYet;
      _settings = RemoteConfigSettings();
    }
  }

  /// Persists the current state. Writes are serialised so that the last
  /// call always wins, and storage failures are logged but never thrown.
  Future<void> _persist() {
    final snapshot = jsonEncode({
      'formatVersion': _storageFormatVersion,
      'active': _active?.toJson(),
      'fetched': _fetched?.toJson(),
      'etag': _etag,
      'lastSuccessfulFetchMs': _lastSuccessfulFetch?.millisecondsSinceEpoch,
      'throttleEndMs': _throttleEndTime?.millisecondsSinceEpoch,
      'lastFetchStatus': _lastFetchStatus.name,
      'settings': _settings.toJson(),
    });
    return _pendingWrite = _pendingWrite.then((_) async {
      try {
        await _storage.write(_storageKey, snapshot);
      } on Object catch (e) {
        debugPrint('cloudflare_worker_kv: failed to write cache: $e');
      }
    });
  }

  static String _checkTemplate(String template) {
    if (!_templatePattern.hasMatch(template)) {
      throw ArgumentError.value(
          template, 'template', 'must match [A-Za-z0-9_-]{1,64}');
    }
    return template;
  }

  static DateTime? _readTime(Object? ms) =>
      ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
}
