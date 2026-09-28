// Port of flutter/test/remote_config_settings_test.dart. Settings are plain
// `{fetchTimeoutMillis, minimumFetchIntervalMillis}` objects in React Native.
import { expect, test } from 'vitest';

import { CloudflareRemoteConfig, InMemoryConfigStorage } from '../src/index';
import {
  resolveSettings,
  settingsFromJson,
  settingsToJson,
} from '../src/remoteConfigSettings';
import type { ConfigSettings } from '../src/remoteConfigSettings';

function create(): CloudflareRemoteConfig {
  return new CloudflareRemoteConfig({
    endpoint: 'https://cfg.example.com',
    storage: new InMemoryConfigStorage(),
    fetch: () => Promise.reject(new Error('offline')),
  });
}

test('defaults to a 60 s timeout and a 12 h interval', () => {
  const s = resolveSettings({});
  expect(s.fetchTimeoutMillis).toBe(60_000);
  expect(s.minimumFetchIntervalMillis).toBe(43_200_000);
  expect(create().settings).toEqual(s);
});

test('validates durations', () => {
  for (const fetchTimeoutMillis of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    expect(() => resolveSettings({ fetchTimeoutMillis }), String(fetchTimeoutMillis)).toThrow(
      RangeError,
    );
  }
  for (const minimumFetchIntervalMillis of [-1, 1.5, Number.NaN]) {
    expect(
      () => resolveSettings({ minimumFetchIntervalMillis }),
      String(minimumFetchIntervalMillis),
    ).toThrow(RangeError);
  }
  expect(() => resolveSettings({ fetchTimeoutMillis: '5' as unknown as number })).toThrow(TypeError);
  expect(() => resolveSettings(null as unknown as ConfigSettings)).toThrow(TypeError);
  expect(resolveSettings({ minimumFetchIntervalMillis: 0 }).minimumFetchIntervalMillis).toBe(0);
});

test('setConfigSettings rejects invalid values and keeps the current settings', async () => {
  const rc = create();
  await rc.setConfigSettings({ fetchTimeoutMillis: 5_000, minimumFetchIntervalMillis: 0 });
  await expect(rc.setConfigSettings({ fetchTimeoutMillis: 0 })).rejects.toThrow(RangeError);
  await expect(
    rc.setConfigSettings({ minimumFetchIntervalMillis: 'x' as unknown as number }),
  ).rejects.toThrow(TypeError);
  expect(rc.settings).toEqual({ fetchTimeoutMillis: 5_000, minimumFetchIntervalMillis: 0 });
});

test('setConfigSettings replaces both values', async () => {
  const rc = create();
  await rc.setConfigSettings({ fetchTimeoutMillis: 5_000, minimumFetchIntervalMillis: 0 });
  await rc.setConfigSettings({ minimumFetchIntervalMillis: 60_000 });
  // The omitted fetchTimeoutMillis goes back to its default, as in Flutter.
  expect(rc.settings).toEqual({ fetchTimeoutMillis: 60_000, minimumFetchIntervalMillis: 60_000 });
  expect(Object.isFrozen(rc.settings)).toBe(true);
});

test('json round trip', () => {
  const s = resolveSettings({ fetchTimeoutMillis: 5_000, minimumFetchIntervalMillis: 180_000 });
  expect(settingsToJson(s)).toEqual({ fetchTimeoutMs: 5_000, minimumFetchIntervalMs: 180_000 });
  expect(settingsFromJson(settingsToJson(s))).toEqual(s);
});

test('settingsFromJson rejects invalid input', () => {
  for (const json of [
    null,
    'x',
    [],
    {},
    { fetchTimeoutMs: '1', minimumFetchIntervalMs: 1 },
    { fetchTimeoutMs: 0, minimumFetchIntervalMs: 1 },
    { fetchTimeoutMs: 1, minimumFetchIntervalMs: -1 },
    { fetchTimeoutMs: 1.5, minimumFetchIntervalMs: 1 },
    { fetchTimeoutMs: 1, minimumFetchIntervalMs: null },
  ]) {
    expect(settingsFromJson(json), JSON.stringify(json)).toBeUndefined();
  }
});
