import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_worker.dart';

void main() {
  void contract(String name, ConfigStorage Function() create) {
    group(name, () {
      test('read/write/delete', () async {
        final s = create();
        expect(await s.read('k'), isNull);
        await s.write('k', 'v1');
        expect(await s.read('k'), 'v1');
        await s.write('k', 'v2');
        expect(await s.read('k'), 'v2');
        await s.delete('k');
        expect(await s.read('k'), isNull);
      });
    });
  }

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  contract('InMemoryConfigStorage', InMemoryConfigStorage.new);
  contract(
      'SharedPreferencesConfigStorage', SharedPreferencesConfigStorage.new);

  test('default storage persists across instances', () async {
    final worker = FakeWorker(entries: {'a': '1'});
    final endpoint = Uri.parse('https://cfg.example.com');
    final rc1 =
        CloudflareRemoteConfig(endpoint: endpoint, httpClient: worker.client);
    await rc1.setConfigSettings(
        RemoteConfigSettings(minimumFetchInterval: Duration.zero));
    await rc1.fetchAndActivate();

    final rc2 =
        CloudflareRemoteConfig(endpoint: endpoint, httpClient: worker.client);
    await rc2.ensureInitialized();
    expect(rc2.getString('a'), '1');
  });
}
