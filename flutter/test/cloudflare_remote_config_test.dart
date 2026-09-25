import 'dart:async';
import 'dart:convert';

import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fake_worker.dart';

final endpoint = Uri.parse('https://cfg.example.com');

void main() {
  late FakeWorker worker;
  late InMemoryConfigStorage storage;
  late FakeClock clock;

  CloudflareRemoteConfig create({
    http.Client? httpClient,
    ConfigStorage? storageOverride,
    String template = 'default',
    String? clientKey,
  }) =>
      CloudflareRemoteConfig(
        endpoint: endpoint,
        template: template,
        clientKey: clientKey,
        httpClient: httpClient ?? worker.client,
        storage: storageOverride ?? storage,
        clock: clock.call,
      );

  Future<CloudflareRemoteConfig> ready(
      {Duration interval = Duration.zero}) async {
    final rc = create();
    await rc.ensureInitialized();
    await rc.setConfigSettings(
        RemoteConfigSettings(minimumFetchInterval: interval));
    return rc;
  }

  Matcher throwsCode(String code) =>
      throwsA(isA<RemoteConfigException>().having((e) => e.code, 'code', code));

  setUp(() {
    worker = FakeWorker(entries: {'welcome': 'Hello', 'max_items': '10'});
    storage = InMemoryConfigStorage();
    clock = FakeClock();
  });

  tearDown(CloudflareRemoteConfig.resetInstance);

  group('initial state', () {
    test('before any fetch', () async {
      final rc = await ready();
      expect(rc.lastFetchStatus, RemoteConfigFetchStatus.noFetchYet);
      expect(rc.lastFetchTime, DateTime.fromMillisecondsSinceEpoch(0));
      expect(rc.getAll(), isEmpty);
      expect(rc.getValue('missing'),
          const RemoteConfigValue(null, ValueSource.valueStatic));
    });

    test('rejects invalid template names', () {
      for (final t in ['', 'a/b', 'x' * 65]) {
        expect(() => create(template: t), throwsArgumentError, reason: t);
      }
    });
  });

  group('defaults', () {
    test('are used until a remote value is activated', () async {
      final rc = await ready();
      await rc.setDefaults({
        'welcome': 'Default',
        'max_items': 5,
        'ratio': 0.5,
        'dark': true,
        'json': {'a': 1},
        'list': [1, 2],
        'ignored': null,
      });
      expect(rc.getString('welcome'), 'Default');
      expect(rc.getInt('max_items'), 5);
      expect(rc.getDouble('ratio'), 0.5);
      expect(rc.getBool('dark'), isTrue);
      expect(rc.getString('json'), '{"a":1}');
      expect(rc.getString('list'), '[1,2]');
      expect(rc.getValue('ignored').source, ValueSource.valueStatic);
      expect(rc.getValue('welcome').source, ValueSource.valueDefault);
    });

    test('unsupported types throw', () async {
      final rc = await ready();
      expect(() => rc.setDefaults({'x': DateTime(2026)}), throwsArgumentError);
    });

    test('setDefaults replaces previous defaults', () async {
      final rc = await ready();
      await rc.setDefaults({'a': '1'});
      await rc.setDefaults({'b': '2'});
      expect(rc.getValue('a').source, ValueSource.valueStatic);
      expect(rc.getString('b'), '2');
    });
  });

  group('fetch & activate', () {
    test('fetch does not change active values until activate', () async {
      final rc = await ready();
      await rc.setDefaults({'welcome': 'Default'});
      await rc.fetch();
      expect(rc.lastFetchStatus, RemoteConfigFetchStatus.success);
      expect(rc.lastFetchTime, clock.now);
      expect(rc.getString('welcome'), 'Default');

      expect(await rc.activate(), isTrue);
      expect(rc.getString('welcome'), 'Hello');
      expect(rc.getValue('welcome').source, ValueSource.valueRemote);
      expect(rc.getInt('max_items'), 10);
    });

    test('activate returns false when nothing new', () async {
      final rc = await ready();
      expect(await rc.activate(), isFalse);
      expect(await rc.fetchAndActivate(), isTrue);
      expect(await rc.activate(), isFalse);
      // Unchanged remote config -> 304 -> nothing to activate.
      expect(await rc.fetchAndActivate(), isFalse);
      expect(worker.requests.last.headers['If-None-Match'], isNotNull);
    });

    test('changed remote config is picked up via a new fetch', () async {
      final rc = await ready();
      await rc.fetchAndActivate();
      worker.entries = {'welcome': 'Updated'};
      expect(await rc.fetchAndActivate(), isTrue);
      expect(rc.getString('welcome'), 'Updated');
      // Keys removed remotely fall back to defaults/static.
      expect(rc.getValue('max_items').source, ValueSource.valueStatic);
    });

    test('remote rollback to the active config discards pending fetch',
        () async {
      final rc = await ready();
      await rc.fetchAndActivate(); // active = A
      final original = Map<String, String>.of(worker.entries);
      worker.entries = {'welcome': 'B'};
      await rc.fetch(); // pending = B
      worker.entries = original;
      await rc.fetch(); // server back to A
      expect(await rc.activate(), isFalse);
      expect(rc.getString('welcome'), 'Hello');
    });

    test('empty remote config with nothing active -> nothing to activate',
        () async {
      worker.entries = {};
      final rc = await ready();
      expect(await rc.fetchAndActivate(), isFalse);
      expect(rc.lastFetchStatus, RemoteConfigFetchStatus.success);
    });

    test('getAll merges defaults and remote values', () async {
      final rc = await ready();
      await rc.setDefaults({'welcome': 'Default', 'only_default': 'x'});
      await rc.fetchAndActivate();
      final all = rc.getAll();
      expect(
          all.keys, unorderedEquals(['welcome', 'max_items', 'only_default']));
      expect(all['welcome'],
          const RemoteConfigValue('Hello', ValueSource.valueRemote));
      expect(all['only_default']!.source, ValueSource.valueDefault);
    });

    test('client key is sent', () async {
      worker.clientKey = 'k';
      final rc = create(clientKey: 'k');
      await rc.setConfigSettings(
          RemoteConfigSettings(minimumFetchInterval: Duration.zero));
      expect(await rc.fetchAndActivate(), isTrue);
    });
  });

  group('minimumFetchInterval', () {
    test('skips the network inside the interval', () async {
      final rc = await ready(interval: const Duration(hours: 1));
      await rc.fetch();
      expect(worker.requests, hasLength(1));

      clock.advance(const Duration(minutes: 59));
      await rc.fetch();
      expect(worker.requests, hasLength(1));

      clock.advance(const Duration(minutes: 1));
      await rc.fetch();
      expect(worker.requests, hasLength(2));
    });

    test('failed fetches do not start the interval', () async {
      final rc = await ready(interval: const Duration(hours: 1));
      worker.override = (_) => http.Response('', 500);
      await expectLater(rc.fetch(), throwsA(isA<RemoteConfigException>()));
      worker.override = null;
      await rc.fetch();
      expect(worker.requests, hasLength(2));
    });

    test('clock moving backwards does not block fetching', () async {
      final rc = await ready(interval: const Duration(hours: 1));
      await rc.fetch();
      clock.advance(const Duration(hours: -2));
      await rc.fetch();
      expect(worker.requests, hasLength(2));
    });
  });

  group('failures', () {
    final cases = <String, (http.Response Function(http.Request), String)>{
      '500': (
        (_) => http.Response('{"error":"invalid_config"}', 500),
        RemoteConfigException.codeServerError
      ),
      '401': (
        (_) => http.Response('', 401),
        RemoteConfigException.codeUnauthorized
      ),
      'bad json': (
        (_) => http.Response('oops', 200),
        RemoteConfigException.codeInvalidResponse
      ),
      'network': (
        (_) => throw http.ClientException('offline'),
        RemoteConfigException.codeNetworkError
      ),
    };

    cases.forEach((name, c) {
      test('$name -> failure status, active config untouched', () async {
        final rc = await ready();
        await rc.fetchAndActivate();
        final fetchTime = rc.lastFetchTime;
        clock.advance(const Duration(minutes: 1));

        worker.override = c.$1;
        await expectLater(rc.fetchAndActivate(), throwsCode(c.$2));
        expect(rc.lastFetchStatus, RemoteConfigFetchStatus.failure);
        expect(rc.lastFetchTime, fetchTime);
        expect(rc.getString('welcome'), 'Hello');
      });
    });

    test('timeout -> failure', () async {
      final rc = create(
          httpClient: MockClient((_) => Completer<http.Response>().future));
      await rc.setConfigSettings(RemoteConfigSettings(
        fetchTimeout: const Duration(milliseconds: 20),
        minimumFetchInterval: Duration.zero,
      ));
      await expectLater(
          rc.fetch(), throwsCode(RemoteConfigException.codeTimeout));
      expect(rc.lastFetchStatus, RemoteConfigFetchStatus.failure);
    });
  });

  group('throttling', () {
    test('429 sets throttle and blocks fetches until it ends', () async {
      final rc = await ready();
      worker.override =
          (_) => http.Response('', 429, headers: {'retry-after': '30'});
      await expectLater(
          rc.fetch(), throwsCode(RemoteConfigException.codeThrottled));
      expect(rc.lastFetchStatus, RemoteConfigFetchStatus.throttle);
      expect(worker.requests, hasLength(1));

      worker.override = null;
      clock.advance(const Duration(seconds: 29));
      await expectLater(
        rc.fetch(),
        throwsA(isA<RemoteConfigException>().having((e) => e.throttleEndTime,
            'throttleEndTime', clock.now.add(const Duration(seconds: 1)))),
      );
      expect(worker.requests, hasLength(1),
          reason: 'no network while throttled');

      clock.advance(const Duration(seconds: 1));
      await rc.fetch();
      expect(rc.lastFetchStatus, RemoteConfigFetchStatus.success);
      expect(worker.requests, hasLength(2));
    });
  });

  group('concurrency', () {
    test('concurrent fetches share one request', () async {
      final gate = Completer<void>();
      var calls = 0;
      final rc = create(
        httpClient: MockClient((req) async {
          calls++;
          await gate.future;
          return worker.handle(req);
        }),
      );
      await rc.setConfigSettings(
          RemoteConfigSettings(minimumFetchInterval: Duration.zero));

      final a = rc.fetch();
      final b = rc.fetch();
      final activated = rc.fetchAndActivate();
      gate.complete();
      await Future.wait([a, b]);
      expect(await activated, isTrue);
      expect(calls, 1);

      await rc.fetch(); // a new fetch after completion hits the network again
      expect(calls, 2);
    });

    test('concurrent failing fetches all throw', () async {
      final rc = await ready();
      worker.override = (_) => http.Response('', 500);
      final a = rc.fetch();
      final b = rc.fetch();
      await expectLater(a, throwsA(isA<RemoteConfigException>()));
      await expectLater(b, throwsA(isA<RemoteConfigException>()));
      expect(worker.requests, hasLength(1));
    });
  });

  group('persistence', () {
    test('active, pending, settings and status survive restarts', () async {
      final rc1 = await ready(interval: const Duration(hours: 1));
      await rc1.fetchAndActivate();
      worker.entries = {'welcome': 'Pending'};
      clock.advance(const Duration(hours: 1));
      await rc1.fetch();

      final rc2 = create();
      await rc2.ensureInitialized();
      expect(rc2.getString('welcome'), 'Hello');
      expect(rc2.settings.minimumFetchInterval, const Duration(hours: 1));
      expect(rc2.lastFetchStatus, RemoteConfigFetchStatus.success);
      expect(rc2.lastFetchTime.isAtSameMomentAs(clock.now), isTrue);

      // Pending config from rc1 can be activated after restart.
      expect(await rc2.activate(), isTrue);
      expect(rc2.getString('welcome'), 'Pending');

      // minimumFetchInterval is honoured across restarts.
      await rc2.fetch();
      expect(worker.requests, hasLength(2));
    });

    test('ETag survives restarts', () async {
      final rc1 = await ready();
      await rc1.fetchAndActivate();
      final rc2 = create();
      await rc2.fetch();
      expect(
          worker.requests.last.headers['If-None-Match'], '"${worker.version}"');
    });

    test('templates and endpoints are stored separately', () async {
      final rc1 = await ready();
      await rc1.fetchAndActivate();
      final other = create(template: 'staging');
      await other.ensureInitialized();
      expect(other.getValue('welcome').source, ValueSource.valueStatic);
      await other.setConfigSettings(RemoteConfigSettings());
      expect(storage.data.keys, {
        'cloudflare_worker_kv:$endpoint|default',
        'cloudflare_worker_kv:$endpoint|staging',
      });
      expect(rc1.settings.minimumFetchInterval, Duration.zero);
    });

    for (final corrupt in [
      'not json',
      '[]',
      '{"formatVersion":99}',
      '{"formatVersion":1,"active":{"entries":"nope"}}',
    ]) {
      test('corrupt cache is ignored: $corrupt', () async {
        final key = 'cloudflare_worker_kv:$endpoint|default';
        storage = InMemoryConfigStorage({key: corrupt});
        final rc = create();
        await rc.ensureInitialized();
        expect(rc.getAll(), isEmpty);
        expect(rc.lastFetchStatus, RemoteConfigFetchStatus.noFetchYet);
        expect(rc.settings, RemoteConfigSettings());
        await rc.setConfigSettings(
            RemoteConfigSettings(minimumFetchInterval: Duration.zero));
        expect(await rc.fetchAndActivate(), isTrue);
      });
    }

    test('storage failures never break fetch/activate', () async {
      final rc = create(storageOverride: _ThrowingStorage());
      await rc.ensureInitialized();
      await rc.setConfigSettings(
          RemoteConfigSettings(minimumFetchInterval: Duration.zero));
      expect(await rc.fetchAndActivate(), isTrue);
      expect(rc.getString('welcome'), 'Hello');
    });

    test('last write wins when writes overlap', () async {
      final slow = _SlowStorage();
      final rc2 = create(storageOverride: slow);
      await rc2.ensureInitialized();
      await rc2.setConfigSettings(
          RemoteConfigSettings(minimumFetchInterval: Duration.zero));
      await rc2.fetch();
      slow.resetDelays();

      // Two persists in flight at once; the first is the slowest.
      final newSettings = RemoteConfigSettings(
          minimumFetchInterval: const Duration(minutes: 5));
      await Future.wait([rc2.activate(), rc2.setConfigSettings(newSettings)]);

      final saved = jsonDecode(slow.data.values.single) as Map<String, Object?>;
      expect(saved['active'], isNotNull);
      expect(saved['fetched'], isNull);
      expect(RemoteConfigSettings.tryFromJson(saved['settings']), newSettings);
    });
  });

  group('singleton', () {
    test('instance throws before initialize', () {
      expect(() => CloudflareRemoteConfig.instance, throwsStateError);
    });

    test('initialize loads cache and exposes instance', () async {
      final rc1 = await ready();
      await rc1.fetchAndActivate();

      final rc = await CloudflareRemoteConfig.initialize(
        endpoint: endpoint,
        httpClient: worker.client,
        storage: storage,
      );
      expect(identical(CloudflareRemoteConfig.instance, rc), isTrue);
      expect(rc.getString('welcome'), 'Hello'); // no await needed
    });
  });
}

class _ThrowingStorage implements ConfigStorage {
  @override
  Future<String?> read(String key) => Future.error(StateError('read'));
  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('write'));
  @override
  Future<void> delete(String key) => Future.error(StateError('delete'));
}

class _SlowStorage extends InMemoryConfigStorage {
  var _delay = 0;

  void resetDelays() => _delay = 30;

  @override
  Future<void> write(String key, String value) async {
    // Earlier writes take longer, so unserialised writes would finish out of
    // order and leave stale data behind.
    final delay = _delay;
    _delay = (_delay - 10).clamp(0, 30);
    await Future<void>.delayed(Duration(milliseconds: delay));
    await super.write(key, value);
  }
}
