import 'package:cloudflare_worker_kv/cloudflare_worker_kv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RemoteConfigValue remote(String v) =>
      RemoteConfigValue(v, ValueSource.valueRemote);

  group('asBool', () {
    test('truthy strings (case-insensitive, trimmed)', () {
      for (final v in [
        '1',
        'true',
        'TRUE',
        't',
        'T',
        'yes',
        'Y',
        'on',
        ' On '
      ]) {
        expect(remote(v).asBool(), isTrue, reason: v);
      }
    });

    test('everything else is false', () {
      for (final v in ['0', 'false', 'no', 'off', '', '2', 'truthy', 'null']) {
        expect(remote(v).asBool(), isFalse, reason: v);
      }
    });
  });

  group('asInt', () {
    test('parses integers', () {
      expect(remote('42').asInt(), 42);
      expect(remote('-7').asInt(), -7);
      expect(remote(' 5 ').asInt(), 5);
    });

    test('non-integers fall back to 0', () {
      for (final v in ['1.5', 'abc', '', 'true', '10.0']) {
        expect(remote(v).asInt(), 0, reason: v);
      }
    });
  });

  group('asDouble', () {
    test('parses numbers', () {
      expect(remote('1.5').asDouble(), 1.5);
      expect(remote('3').asDouble(), 3.0);
      expect(remote('-0.25').asDouble(), -0.25);
    });

    test('non-numeric falls back to 0.0', () {
      for (final v in ['abc', '', 'true']) {
        expect(remote(v).asDouble(), 0.0, reason: v);
      }
    });
  });

  test('static values use type defaults', () {
    const v = RemoteConfigValue(null, ValueSource.valueStatic);
    expect(v.asString(), '');
    expect(v.asInt(), 0);
    expect(v.asDouble(), 0.0);
    expect(v.asBool(), isFalse);
    expect(v.source, ValueSource.valueStatic);
  });

  test('equality and hashCode', () {
    expect(remote('a'), remote('a'));
    expect(remote('a').hashCode, remote('a').hashCode);
    expect(remote('a'),
        isNot(const RemoteConfigValue('a', ValueSource.valueDefault)));
  });
}
