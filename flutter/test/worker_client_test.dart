import 'dart:async';
import 'dart:convert';

import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:cloudflare_worker_kv/src/worker_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final endpoint = Uri.parse('https://cfg.example.com');
  const timeout = Duration(seconds: 5);

  WorkerClient clientFor(MockClient http, {String? clientKey}) => WorkerClient(
        endpoint: endpoint,
        template: 'default',
        clientKey: clientKey,
        httpClient: http,
        clock: () => DateTime.utc(2026, 1, 1),
      );

  Matcher throwsCode(String code, {int? status}) => throwsA(
        isA<RemoteConfigException>()
            .having((e) => e.code, 'code', code)
            .having((e) => e.statusCode, 'statusCode', status),
      );

  group('buildConfigUri', () {
    test('appends path and template', () {
      expect(
        WorkerClient.buildConfigUri(Uri.parse('https://a.dev'), 'default'),
        Uri.parse('https://a.dev/v1/config?template=default'),
      );
    });

    test('preserves path prefix, query and drops fragment', () {
      expect(
        WorkerClient.buildConfigUri(
            Uri.parse('https://a.dev/api/?x=1#frag'), 'staging'),
        Uri.parse('https://a.dev/api/v1/config?x=1&template=staging'),
      );
    });

    test('keeps a custom port', () {
      expect(
        WorkerClient.buildConfigUri(
            Uri.parse('https://config.example.com:8443'), 'd'),
        Uri.parse('https://config.example.com:8443/v1/config?template=d'),
      );
    });

    test('rejects relative URLs', () {
      expect(() => WorkerClient.buildConfigUri(Uri.parse('/config'), 'd'),
          throwsArgumentError);
    });
  });

  test('sends headers and parses 200', () async {
    late http.Request seen;
    final client = clientFor(
      MockClient((req) async {
        seen = req;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'version': 'v1',
            'entries': {
              'a': 'xin chào',
              'n': 1,
              'b': true,
              'o': {'k': 1},
              'z': null
            },
          })),
          200,
          headers: {'etag': '"v1"'},
        );
      }),
      clientKey: 'secret',
    );

    final result = await client.fetch(etag: '"v0"', timeout: timeout);

    expect(seen.method, 'GET');
    expect(seen.url.toString(),
        'https://cfg.example.com/v1/config?template=default');
    expect(seen.headers['X-Client-Key'], 'secret');
    expect(seen.headers['If-None-Match'], '"v0"');
    expect(result, isA<WorkerConfigFetched>());
    final fetched = result as WorkerConfigFetched;
    expect(fetched.etag, '"v1"');
    expect(fetched.snapshot.version, 'v1');
    expect(fetched.snapshot.entries,
        {'a': 'xin chào', 'n': '1', 'b': 'true', 'o': '{"k":1}'});
  });

  test('omits optional headers when not provided', () async {
    late http.Request seen;
    final client = clientFor(MockClient((req) async {
      seen = req;
      return http.Response('{"version":"v","entries":{}}', 200);
    }));
    await client.fetch(timeout: timeout);
    expect(seen.headers.containsKey('X-Client-Key'), isFalse);
    expect(seen.headers.containsKey('If-None-Match'), isFalse);
  });

  test('falls back to ETag when version is missing', () async {
    final client = clientFor(MockClient((_) async =>
        http.Response('{"entries":{}}', 200, headers: {'etag': 'W/"abc"'})));
    final result = await client.fetch(timeout: timeout) as WorkerConfigFetched;
    expect(result.snapshot.version, 'abc');
  });

  test('304 with etag -> not modified', () async {
    final client = clientFor(MockClient((_) async => http.Response('', 304)));
    expect(await client.fetch(etag: '"v"', timeout: timeout),
        isA<WorkerConfigNotModified>());
  });

  test('304 without etag -> invalid-response', () {
    final client = clientFor(MockClient((_) async => http.Response('', 304)));
    expect(client.fetch(timeout: timeout),
        throwsCode(RemoteConfigException.codeInvalidResponse, status: 304));
  });

  test('malformed bodies -> invalid-response', () async {
    for (final body in ['not json', '[]', '{"entries":[]}', '{}', 'null']) {
      final client =
          clientFor(MockClient((_) async => http.Response(body, 200)));
      await expectLater(client.fetch(timeout: timeout),
          throwsCode(RemoteConfigException.codeInvalidResponse, status: 200),
          reason: body);
    }
  });

  test('401 and 403 -> unauthorized', () async {
    for (final status in [401, 403]) {
      final client =
          clientFor(MockClient((_) async => http.Response('', status)));
      await expectLater(client.fetch(timeout: timeout),
          throwsCode(RemoteConfigException.codeUnauthorized, status: status));
    }
  });

  test('429 -> throttled with Retry-After', () async {
    final client = clientFor(MockClient(
        (_) async => http.Response('', 429, headers: {'retry-after': '120'})));
    await expectLater(
      client.fetch(timeout: timeout),
      throwsA(isA<RemoteConfigException>()
          .having((e) => e.code, 'code', RemoteConfigException.codeThrottled)
          .having((e) => e.throttleEndTime, 'throttleEndTime',
              DateTime.utc(2026, 1, 1, 0, 2))),
    );
  });

  test('429 without Retry-After uses default duration', () async {
    final client = clientFor(MockClient((_) async => http.Response('', 429)));
    await expectLater(
      client.fetch(timeout: timeout),
      throwsA(isA<RemoteConfigException>().having(
          (e) => e.throttleEndTime,
          'throttleEndTime',
          DateTime.utc(2026, 1, 1).add(defaultThrottleDuration))),
    );
  });

  test('5xx -> server-error with worker error code in message', () async {
    final client = clientFor(MockClient((_) async =>
        http.Response('{"error":"invalid_config","message":"bad"}', 500)));
    await expectLater(
      client.fetch(timeout: timeout),
      throwsA(isA<RemoteConfigException>()
          .having((e) => e.code, 'code', RemoteConfigException.codeServerError)
          .having((e) => e.statusCode, 'statusCode', 500)
          .having((e) => e.message, 'message', contains('invalid_config'))),
    );
  });

  test('network error -> network-error', () {
    final client = clientFor(
        MockClient((_) async => throw http.ClientException('offline')));
    expect(client.fetch(timeout: timeout),
        throwsCode(RemoteConfigException.codeNetworkError));
  });

  test('slow response -> timeout', () {
    final client = clientFor(MockClient(
        (_) => Completer<http.Response>().future)); // never completes
    expect(client.fetch(timeout: const Duration(milliseconds: 20)),
        throwsCode(RemoteConfigException.codeTimeout));
  });

  test('exception toString is informative', () {
    const e = RemoteConfigException(
        code: 'server-error', message: 'boom', statusCode: 502);
    expect(
        e.toString(), 'RemoteConfigException[server-error] (HTTP 502): boom');
  });
}
