import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defaults to a 60 s timeout and a 12 h interval', () {
    final s = RemoteConfigSettings();
    expect(s.fetchTimeout, const Duration(seconds: 60));
    expect(s.minimumFetchInterval, const Duration(hours: 12));
  });

  test('validates durations', () {
    expect(() => RemoteConfigSettings(fetchTimeout: Duration.zero),
        throwsArgumentError);
    expect(
        () => RemoteConfigSettings(
            minimumFetchInterval: const Duration(seconds: -1)),
        throwsArgumentError);
    expect(RemoteConfigSettings(minimumFetchInterval: Duration.zero),
        isA<RemoteConfigSettings>());
  });

  test('json round trip', () {
    final s = RemoteConfigSettings(
      fetchTimeout: const Duration(seconds: 5),
      minimumFetchInterval: const Duration(minutes: 3),
    );
    expect(RemoteConfigSettings.tryFromJson(s.toJson()), s);
  });

  test('tryFromJson rejects invalid input', () {
    for (final json in <Object?>[
      null,
      'x',
      <String, Object?>{},
      {'fetchTimeoutMs': '1', 'minimumFetchIntervalMs': 1},
      {'fetchTimeoutMs': 0, 'minimumFetchIntervalMs': 1},
      {'fetchTimeoutMs': 1, 'minimumFetchIntervalMs': -1},
    ]) {
      expect(RemoteConfigSettings.tryFromJson(json), isNull, reason: '$json');
    }
  });
}
