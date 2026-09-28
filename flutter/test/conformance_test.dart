// Runs the shared fixtures in ../spec/fixtures against this package, the
// reference implementation. Every other SDK runs the same files, so a failure
// here means the fixture (or the spec) is wrong, not the other SDKs.
import 'dart:convert';
import 'dart:io';

import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:cloudflare_worker_kv/src/worker_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<Map<String, dynamic>> _cases(String file) {
  final json = jsonDecode(File('../spec/fixtures/$file').readAsStringSync())
      as Map<String, dynamic>;
  return (json['cases'] as List).cast<Map<String, dynamic>>();
}

void main() {
  group('value-conversions.json', () {
    for (final c in _cases('value-conversions.json')) {
      final raw = c['raw'] as String?;
      test(jsonEncode(raw), () {
        final value = RemoteConfigValue(
          raw,
          raw == null ? ValueSource.valueStatic : ValueSource.valueRemote,
        );
        expect(value.asString(), c['string']);
        expect(value.asBool(), c['bool']);
        expect(value.asInt(), c['int']);
        expect(value.asDouble(), (c['double'] as num).toDouble());
      });
    }
  });

  group('config-uri.json', () {
    for (final c in _cases('config-uri.json')) {
      final endpoint = c['endpoint'] as String;
      final template = c['template'] as String;
      test('$endpoint + $template', () {
        Uri build() =>
            WorkerClient.buildConfigUri(Uri.parse(endpoint), template);
        if (c['error'] == true) {
          expect(build, throwsA(anything));
        } else {
          expect(build().toString(), c['expected']);
        }
      });
    }
  });

  group('responses.json', () {
    final now = DateTime.utc(2026, 1, 1);
    for (final c in _cases('responses.json')) {
      test(c['name'] as String, () async {
        final headers = {
          for (final e in (c['headers'] as Map<String, dynamic>).entries)
            e.key.toLowerCase(): e.value as String,
        };
        final client = WorkerClient(
          endpoint: Uri.parse('https://cfg.example.com'),
          template: 'default',
          httpClient: MockClient((_) async => http.Response.bytes(
                utf8.encode(c['body'] as String),
                c['status'] as int,
                headers: headers,
              )),
          clock: () => now,
        );
        final expected = c['expect'] as Map<String, dynamic>;
        final fetch = client.fetch(
          etag: c['sentEtag'] as String?,
          timeout: const Duration(seconds: 5),
        );

        switch (expected['result']) {
          case 'fetched':
            final result = await fetch;
            expect(result, isA<WorkerConfigFetched>());
            final fetched = result as WorkerConfigFetched;
            expect(fetched.snapshot.version, expected['version']);
            expect(fetched.etag, expected['etag']);
            expect(fetched.snapshot.entries, expected['entries']);
          case 'notModified':
            expect(await fetch, isA<WorkerConfigNotModified>());
          default:
            final throttleSeconds = expected['throttleSeconds'] as int?;
            final messageContains = expected['messageContains'] as String?;
            await expectLater(
              fetch,
              throwsA(isA<RemoteConfigException>()
                  .having((e) => e.code, 'code', expected['error'])
                  .having(
                      (e) => e.statusCode, 'statusCode', expected['statusCode'])
                  .having(
                      (e) => e.throttleEndTime,
                      'throttleEndTime',
                      throttleSeconds == null
                          ? isNull
                          : now.add(Duration(seconds: throttleSeconds)))
                  .having((e) => e.message, 'message',
                      contains(messageContains ?? ''))),
            );
        }
      });
    }
  });
}
