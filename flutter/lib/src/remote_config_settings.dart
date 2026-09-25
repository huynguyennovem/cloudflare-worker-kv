import 'package:meta/meta.dart';

/// Settings that control fetch behaviour.
@immutable
class RemoteConfigSettings {
  /// Creates settings.
  ///
  /// Defaults: a 60 second [fetchTimeout] and a 12 hour
  /// [minimumFetchInterval]. Use a small interval (e.g. [Duration.zero])
  /// during development.
  RemoteConfigSettings({
    this.fetchTimeout = const Duration(seconds: 60),
    this.minimumFetchInterval = const Duration(hours: 12),
  }) {
    if (fetchTimeout <= Duration.zero) {
      throw ArgumentError.value(
          fetchTimeout, 'fetchTimeout', 'must be greater than zero');
    }
    if (minimumFetchInterval.isNegative) {
      throw ArgumentError.value(
          minimumFetchInterval, 'minimumFetchInterval', 'must not be negative');
    }
  }

  /// Maximum time to wait for a response from the Worker.
  final Duration fetchTimeout;

  /// Minimum age of the cached config before `fetch` hits the network again.
  final Duration minimumFetchInterval;

  /// Serialises the settings for persistence.
  Map<String, Object?> toJson() => {
        'fetchTimeoutMs': fetchTimeout.inMilliseconds,
        'minimumFetchIntervalMs': minimumFetchInterval.inMilliseconds,
      };

  /// Restores settings saved by [toJson]. Returns `null` on invalid input.
  static RemoteConfigSettings? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final timeout = json['fetchTimeoutMs'];
    final interval = json['minimumFetchIntervalMs'];
    if (timeout is! int || interval is! int) return null;
    if (timeout <= 0 || interval < 0) return null;
    return RemoteConfigSettings(
      fetchTimeout: Duration(milliseconds: timeout),
      minimumFetchInterval: Duration(milliseconds: interval),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteConfigSettings &&
      other.fetchTimeout == fetchTimeout &&
      other.minimumFetchInterval == minimumFetchInterval;

  @override
  int get hashCode => Object.hash(fetchTimeout, minimumFetchInterval);

  @override
  String toString() => 'RemoteConfigSettings(fetchTimeout: $fetchTimeout, '
      'minimumFetchInterval: $minimumFetchInterval)';
}
