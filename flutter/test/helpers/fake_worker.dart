import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Simulates the config Worker's HTTP contract in memory.
class FakeWorker {
  FakeWorker({Map<String, String>? entries, this.clientKey})
      : entries = {...?entries};

  /// Current config served by the fake Worker.
  Map<String, String> entries;

  /// When set, requests must send a matching `X-Client-Key`.
  String? clientKey;

  /// When set, returned instead of the normal response.
  http.Response Function(http.Request request)? override;

  /// Every request received, in order.
  final List<http.Request> requests = [];

  String get version {
    final sorted = entries.keys.toList()..sort();
    return base64Url.encode(utf8.encode(jsonEncode([
      for (final k in sorted) [k, entries[k]]
    ])));
  }

  late final MockClient client = MockClient(handle);

  /// Handles one request like the real Worker would.
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final o = override;
    if (o != null) return o(request);
    if (clientKey != null && request.headers['X-Client-Key'] != clientKey) {
      return http.Response('{"error":"unauthorized"}', 401);
    }
    final etag = '"$version"';
    if (request.headers['If-None-Match'] == etag) {
      return http.Response('', 304, headers: {'etag': etag});
    }
    return http.Response.bytes(
      utf8.encode(jsonEncode({'version': version, 'entries': entries})),
      200,
      headers: {'etag': etag, 'content-type': 'application/json'},
    );
  }
}

/// A controllable clock.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 1, 1);

  DateTime now;

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}
