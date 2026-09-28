// Port of flutter/test/remote_config_value_test.dart. The groups use the React
// Native method names: asBool -> asBoolean, asInt -> asInteger,
// asDouble -> asNumber.
import { describe, expect, test } from 'vitest';

import { RemoteConfigValue, ValueSource } from '../src/index';

function remote(value: string): RemoteConfigValue {
  return new RemoteConfigValue(value, 'remote');
}

describe('asBoolean', () => {
  test('truthy strings (case-insensitive, trimmed)', () => {
    for (const v of ['1', 'true', 'TRUE', 't', 'T', 'yes', 'Y', 'on', ' On ']) {
      expect(remote(v).asBoolean(), v).toBe(true);
    }
  });

  test('everything else is false', () => {
    for (const v of ['0', 'false', 'no', 'off', '', '2', 'truthy', 'null']) {
      expect(remote(v).asBoolean(), v).toBe(false);
    }
  });
});

describe('asInteger', () => {
  test('parses integers', () => {
    expect(remote('42').asInteger()).toBe(42);
    expect(remote('-7').asInteger()).toBe(-7);
    expect(remote('+7').asInteger()).toBe(7);
    expect(remote(' 5 ').asInteger()).toBe(5);
  });

  test('non-integers fall back to 0', () => {
    for (const v of ['1.5', 'abc', '', 'true', '10.0', '1e3', '0x10', '1 2']) {
      expect(remote(v).asInteger(), v).toBe(0);
    }
  });

  test('-0 is normalised to 0', () => {
    expect(Object.is(remote('-0').asInteger(), 0)).toBe(true);
  });
});

describe('asNumber', () => {
  test('parses numbers', () => {
    expect(remote('1.5').asNumber()).toBe(1.5);
    expect(remote('3').asNumber()).toBe(3);
    expect(remote('-0.25').asNumber()).toBe(-0.25);
    expect(remote('1e3').asNumber()).toBe(1000);
    expect(remote(' .5 ').asNumber()).toBe(0.5);
  });

  test('non-numeric falls back to 0', () => {
    for (const v of ['abc', '', ' ', 'true', '1 2']) {
      expect(remote(v).asNumber(), v).toBe(0);
    }
  });
});

test('asString returns the raw value unchanged', () => {
  expect(remote(' 5 ').asString()).toBe(' 5 ');
  expect(remote('').asString()).toBe('');
});

test('static values use type defaults', () => {
  const v = new RemoteConfigValue(undefined, 'static');
  expect(v.asString()).toBe(RemoteConfigValue.DEFAULT_VALUE_FOR_STRING);
  expect(v.asString()).toBe('');
  expect(v.asInteger()).toBe(0);
  expect(v.asNumber()).toBe(RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER);
  expect(v.asBoolean()).toBe(RemoteConfigValue.DEFAULT_VALUE_FOR_BOOLEAN);
  expect(v.asBoolean()).toBe(false);
  expect(v.getSource()).toBe(ValueSource.STATIC);
});

test('equality', () => {
  expect(remote('a')).toEqual(remote('a'));
  expect(remote('a')).not.toEqual(new RemoteConfigValue('a', 'default'));
  expect(remote('a')).not.toEqual(remote('b'));
});

test('ValueSource constants', () => {
  expect(ValueSource).toEqual({ STATIC: 'static', DEFAULT: 'default', REMOTE: 'remote' });
  expect(Object.isFrozen(ValueSource)).toBe(true);
});
