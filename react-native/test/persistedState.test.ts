// The cache format of spec/README.md §2.8, shared with the Flutter package.
import { beforeEach, describe, expect, test, vi } from 'vitest';

import { ConfigSnapshot } from '../src/configSnapshot';
import { CloudflareRemoteConfig, InMemoryConfigStorage } from '../src/index';
import {
  decodeState,
  encodeState,
  initialState,
  storageKey,
} from '../src/persistedState';
import type { PersistedState } from '../src/persistedState';

const T = 1_767_225_600_000; // 2026-01-01T00:00:00Z

function snapshot(version: string, entries: Record<string, string>): ConfigSnapshot {
  return new ConfigSnapshot(version, new Map(Object.entries(entries)));
}

function plain(state: PersistedState): unknown {
  return {
    ...state,
    active: state.active?.toJson(),
    fetched: state.fetched?.toJson(),
  };
}

beforeEach(() => {
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

test('storage key', () => {
  expect(storageKey('https://cfg.example.com/', 'staging')).toBe(
    'cloudflare_worker_kv:https://cfg.example.com/|staging',
  );
});

test('encodes in the key order of the Flutter package (golden)', () => {
  const state: PersistedState = {
    ...initialState(),
    active: snapshot('v1', { k: 'v' }),
    etag: '"v1"',
    lastSuccessfulFetchMillis: T,
    lastFetchStatus: 'success',
  };
  expect(encodeState(state)).toBe(
    '{"formatVersion":1,"active":{"version":"v1","entries":{"k":"v"}},"fetched":null,' +
      '"etag":"\\"v1\\"","lastSuccessfulFetchMs":1767225600000,"throttleEndMs":null,' +
      '"lastFetchStatus":"success","settings":{"fetchTimeoutMs":60000,"minimumFetchIntervalMs":43200000}}',
  );
});

test('an initial state writes every field as null', () => {
  expect(encodeState(initialState())).toBe(
    '{"formatVersion":1,"active":null,"fetched":null,"etag":null,"lastSuccessfulFetchMs":null,' +
      '"throttleEndMs":null,"lastFetchStatus":"noFetchYet",' +
      '"settings":{"fetchTimeoutMs":60000,"minimumFetchIntervalMs":43200000}}',
  );
});

test('writes the status names of the Flutter package', () => {
  const names = (['no_fetch_yet', 'success', 'failure', 'throttled'] as const).map(
    (lastFetchStatus) =>
      (JSON.parse(encodeState({ ...initialState(), lastFetchStatus })) as { lastFetchStatus: string })
        .lastFetchStatus,
  );
  expect(names).toEqual(['noFetchYet', 'success', 'failure', 'throttle']);
});

test('round trip', () => {
  const state: PersistedState = {
    active: snapshot('v1', { a: '1', ['__proto__']: 'p' }),
    fetched: snapshot('v2', { a: '2' }),
    etag: 'W/"v2"',
    lastSuccessfulFetchMillis: T,
    throttleEndMillis: T + 30_000,
    lastFetchStatus: 'throttled',
    settings: { fetchTimeoutMillis: 5_000, minimumFetchIntervalMillis: 0 },
  };
  const decoded = decodeState(encodeState(state));
  expect(plain(decoded)).toEqual(plain(state));
  expect(decoded.active?.entries.get('__proto__')).toBe('p');
});

describe('loads a cache written by the Flutter package', () => {
  test('noFetchYet', () => {
    const blob =
      '{"formatVersion":1,"active":null,"fetched":null,"etag":null,"lastSuccessfulFetchMs":null,' +
      '"throttleEndMs":null,"lastFetchStatus":"noFetchYet",' +
      '"settings":{"fetchTimeoutMs":10000,"minimumFetchIntervalMs":0}}';
    expect(plain(decodeState(blob))).toEqual(
      plain({
        ...initialState(),
        settings: { fetchTimeoutMillis: 10_000, minimumFetchIntervalMillis: 0 },
      }),
    );
  });

  test('throttle', async () => {
    const blob = JSON.stringify({
      formatVersion: 1,
      active: { version: 'v1', entries: { welcome: 'Hello', max_items: '10' } },
      fetched: { version: 'v2', entries: { welcome: 'Pending' } },
      etag: '"v2"',
      lastSuccessfulFetchMs: T,
      throttleEndMs: T + 60_000,
      lastFetchStatus: 'throttle',
      settings: { fetchTimeoutMs: 60000, minimumFetchIntervalMs: 3600000 },
    });
    const endpoint = 'https://cfg.example.com';
    const rc = new CloudflareRemoteConfig({
      endpoint,
      storage: new InMemoryConfigStorage({ [storageKey(endpoint, 'default')]: blob }),
      fetch: () => Promise.reject(new Error('no network in this test')),
      now: () => T + 1_000,
    });
    await rc.ensureInitialized();
    expect(rc.lastFetchStatus).toBe('throttled');
    expect(rc.fetchTimeMillis).toBe(T);
    expect(rc.getString('welcome')).toBe('Hello');
    expect(rc.getNumber('max_items')).toBe(10);
    expect(rc.settings).toEqual({ fetchTimeoutMillis: 60_000, minimumFetchIntervalMillis: 3_600_000 });
    // Still throttled: fails without a request.
    await expect(rc.fetch()).rejects.toMatchObject({
      code: 'throttled',
      throttleEndTimeMillis: T + 60_000,
    });
    expect(await rc.activate()).toBe(true);
    expect(rc.getString('welcome')).toBe('Pending');
  });
});

test('invalid fields fall back to their defaults', () => {
  const decoded = decodeState(
    JSON.stringify({
      formatVersion: 1,
      etag: 5,
      lastSuccessfulFetchMs: 1.5,
      throttleEndMs: '1',
      lastFetchStatus: 'toString',
      settings: { fetchTimeoutMs: 0, minimumFetchIntervalMs: 0 },
    }),
  );
  expect(plain(decoded)).toEqual(plain(initialState()));
  for (const status of ['bogus', '__proto__', 'no_fetch_yet', 'throttled', null, 1]) {
    expect(
      decodeState(JSON.stringify({ formatVersion: 1, lastFetchStatus: status })).lastFetchStatus,
      String(status),
    ).toBe('no_fetch_yet');
  }
});

test('a snapshot without a string version gets an empty version', () => {
  const decoded = decodeState('{"formatVersion":1,"active":{"version":3,"entries":{"a":"1"}}}');
  expect(decoded.active?.version).toBe('');
  expect(decoded.active?.entries.get('a')).toBe('1');
});

test('corrupt caches give a clean state', () => {
  for (const corrupt of [
    'not json',
    '',
    '[]',
    'null',
    '"x"',
    '{"formatVersion":99}',
    '{"formatVersion":"1"}',
    '{"formatVersion":1,"active":{"entries":"nope"}}',
    '{"formatVersion":1,"fetched":[]}',
    '{"formatVersion":1,"active":{"version":"v"}}',
  ]) {
    expect(plain(decodeState(corrupt)), corrupt).toEqual(plain(initialState()));
  }
});
