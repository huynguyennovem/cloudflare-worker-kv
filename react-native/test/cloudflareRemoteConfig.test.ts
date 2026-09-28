// Port of flutter/test/cloudflare_remote_config_test.dart: same groups, same
// test names, same scenarios.
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

import {
  CloudflareRemoteConfig,
  InMemoryConfigStorage,
  isRemoteConfigError,
  RemoteConfigError,
  RemoteConfigValue,
} from '../src/index';
import type {
  ConfigStorage,
  DefaultValue,
  FetchLike,
  RemoteConfigErrorCode,
} from '../src/index';
import { FakeClock } from './helpers/fakeClock';
import { FakeWorker } from './helpers/fakeWorker';
import type { RecordedRequest } from './helpers/fakeWorker';
import { SlowStorage, ThrowingStorage } from './helpers/storages';

const endpoint = 'https://cfg.example.com';
const HOUR = 3_600_000;
const MINUTE = 60_000;
const SECOND = 1_000;

let worker: FakeWorker;
let storage: InMemoryConfigStorage;
let clock: FakeClock;

function create(
  options: {
    fetch?: FetchLike;
    storage?: ConfigStorage;
    template?: string;
    clientKey?: string;
  } = {},
): CloudflareRemoteConfig {
  return new CloudflareRemoteConfig({
    endpoint,
    template: options.template ?? 'default',
    clientKey: options.clientKey,
    fetch: options.fetch ?? worker.fetch,
    storage: options.storage ?? storage,
    now: clock.call,
  });
}

async function ready(interval = 0): Promise<CloudflareRemoteConfig> {
  const rc = create();
  await rc.ensureInitialized();
  await rc.setConfigSettings({ minimumFetchIntervalMillis: interval });
  return rc;
}

/** Awaits `promise`, expecting a {@link RemoteConfigError} with `code`. */
async function expectCode(
  promise: Promise<unknown>,
  code: RemoteConfigErrorCode,
): Promise<RemoteConfigError> {
  const error = await promise.then(
    () => {
      throw new Error(`expected a rejection with code ${code}`);
    },
    (e: unknown) => e,
  );
  expect(error).toBeInstanceOf(RemoteConfigError);
  expect((error as RemoteConfigError).code).toBe(code);
  return error as RemoteConfigError;
}

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void;
  const promise = new Promise<void>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

beforeEach(() => {
  worker = new FakeWorker({ entries: { welcome: 'Hello', max_items: '10' } });
  storage = new InMemoryConfigStorage();
  clock = new FakeClock();
  // Corrupt caches and failing storages log warnings on purpose.
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(() => {
  CloudflareRemoteConfig.resetInstance();
  vi.useRealTimers();
});

describe('initial state', () => {
  test('before any fetch', async () => {
    const rc = await ready();
    expect(rc.lastFetchStatus).toBe('no_fetch_yet');
    expect(rc.fetchTimeMillis).toBe(-1);
    expect(rc.getAll()).toEqual({});
    expect(rc.getValue('missing')).toEqual(new RemoteConfigValue(undefined, 'static'));
    expect(rc.getValue('missing').getSource()).toBe('static');
  });

  test('rejects invalid template names', () => {
    for (const t of ['', 'a/b', 'x'.repeat(65)]) {
      expect(() => create({ template: t }), t).toThrow(TypeError);
    }
  });

  test('rejects endpoints without a scheme and a host', () => {
    for (const e of ['', '/config', 'a.dev/config', 'mailto:someone@example.com', 'https://']) {
      expect(() => new CloudflareRemoteConfig({ endpoint: e, storage }), e).toThrow(TypeError);
    }
  });

  test('checks the template before the endpoint', () => {
    expect(() => new CloudflareRemoteConfig({ endpoint: '/config', template: 'a/b', storage })).toThrow(
      /template/,
    );
  });
});

describe('defaults', () => {
  test('are used until a remote value is activated', async () => {
    const rc = await ready();
    await rc.setDefaults({
      welcome: 'Default',
      max_items: 5,
      ratio: 0.5,
      dark: true,
      json: { a: 1 },
      list: [1, 2],
      ignored: null,
      alsoIgnored: undefined,
    });
    expect(rc.getString('welcome')).toBe('Default');
    expect(rc.getNumber('max_items')).toBe(5);
    expect(rc.getValue('max_items').asInteger()).toBe(5);
    expect(rc.getNumber('ratio')).toBe(0.5);
    expect(rc.getBoolean('dark')).toBe(true);
    expect(rc.getString('json')).toBe('{"a":1}');
    expect(rc.getString('list')).toBe('[1,2]');
    expect(rc.getValue('ignored').getSource()).toBe('static');
    expect(rc.getValue('alsoIgnored').getSource()).toBe('static');
    expect(rc.getValue('welcome').getSource()).toBe('default');
  });

  test('unsupported types throw', async () => {
    const rc = await ready();
    const unsupported: unknown[] = [
      new Date(2026, 0, 1),
      new Map(),
      () => 1,
      Symbol('x'),
      BigInt(1),
      new (class Custom {})(),
    ];
    for (const value of unsupported) {
      await expect(rc.setDefaults({ x: value as DefaultValue }), String(typeof value)).rejects.toThrow(
        TypeError,
      );
    }
  });

  test('a rejected setDefaults keeps the previous defaults', async () => {
    const rc = await ready();
    await rc.setDefaults({ a: '1' });
    await expect(rc.setDefaults({ b: '2', x: new Date() as unknown as DefaultValue })).rejects.toThrow(
      TypeError,
    );
    expect(rc.getString('a')).toBe('1');
    expect(rc.getValue('b').getSource()).toBe('static');
  });

  test('are applied synchronously', () => {
    const rc = create();
    void rc.setDefaults({ a: 'now', n: 0.0 });
    expect(rc.getString('a')).toBe('now');
    expect(rc.getString('n')).toBe('0'); // JavaScript numbers print without ".0".
  });

  test('objects without a prototype are stored as JSON', async () => {
    const rc = await ready();
    const bare = Object.create(null) as Record<string, unknown>;
    bare['k'] = 'v';
    await rc.setDefaults({ bare });
    expect(rc.getString('bare')).toBe('{"k":"v"}');
  });

  test('setDefaults replaces previous defaults', async () => {
    const rc = await ready();
    await rc.setDefaults({ a: '1' });
    await rc.setDefaults({ b: '2' });
    expect(rc.getValue('a').getSource()).toBe('static');
    expect(rc.getString('b')).toBe('2');
  });
});

describe('fetch & activate', () => {
  test('fetch does not change active values until activate', async () => {
    const rc = await ready();
    await rc.setDefaults({ welcome: 'Default' });
    await rc.fetch();
    expect(rc.lastFetchStatus).toBe('success');
    expect(rc.fetchTimeMillis).toBe(clock.now);
    expect(rc.getString('welcome')).toBe('Default');

    expect(await rc.activate()).toBe(true);
    expect(rc.getString('welcome')).toBe('Hello');
    expect(rc.getValue('welcome').getSource()).toBe('remote');
    expect(rc.getNumber('max_items')).toBe(10);
  });

  test('activate returns false when nothing new', async () => {
    const rc = await ready();
    expect(await rc.activate()).toBe(false);
    expect(await rc.fetchAndActivate()).toBe(true);
    expect(await rc.activate()).toBe(false);
    // Unchanged remote config -> 304 -> nothing to activate.
    expect(await rc.fetchAndActivate()).toBe(false);
    expect(worker.requests.at(-1)?.headers['If-None-Match']).toBeDefined();
  });

  test('changed remote config is picked up via a new fetch', async () => {
    const rc = await ready();
    await rc.fetchAndActivate();
    worker.entries = { welcome: 'Updated' };
    expect(await rc.fetchAndActivate()).toBe(true);
    expect(rc.getString('welcome')).toBe('Updated');
    // Keys removed remotely fall back to defaults/static.
    expect(rc.getValue('max_items').getSource()).toBe('static');
  });

  test('remote rollback to the active config discards pending fetch', async () => {
    const rc = await ready();
    await rc.fetchAndActivate(); // active = A
    const original = { ...worker.entries };
    worker.entries = { welcome: 'B' };
    await rc.fetch(); // pending = B
    worker.entries = original;
    await rc.fetch(); // server back to A
    expect(await rc.activate()).toBe(false);
    expect(rc.getString('welcome')).toBe('Hello');
  });

  test('empty remote config with nothing active -> nothing to activate', async () => {
    worker.entries = {};
    const rc = await ready();
    expect(await rc.fetchAndActivate()).toBe(false);
    expect(rc.lastFetchStatus).toBe('success');
  });

  test('getAll merges defaults and remote values', async () => {
    const rc = await ready();
    await rc.setDefaults({ welcome: 'Default', only_default: 'x' });
    await rc.fetchAndActivate();
    const all = rc.getAll();
    expect(Object.keys(all).sort()).toEqual(['max_items', 'only_default', 'welcome']);
    expect(all['welcome']).toEqual(new RemoteConfigValue('Hello', 'remote'));
    expect(all['only_default']?.getSource()).toBe('default');
  });

  test('getAll keeps __proto__ as a plain key', async () => {
    worker.entries = { ['__proto__']: 'remote' };
    const rc = await ready();
    await rc.fetchAndActivate();
    const all = rc.getAll();
    expect(Object.keys(all)).toEqual(['__proto__']);
    expect(Object.getPrototypeOf(all)).toBe(Object.prototype);
    expect(rc.getString('__proto__')).toBe('remote');
    expect(rc.getValue('toString').getSource()).toBe('static');
  });

  test('client key is sent', async () => {
    worker.clientKey = 'k';
    const rc = create({ clientKey: 'k' });
    await rc.setConfigSettings({ minimumFetchIntervalMillis: 0 });
    expect(await rc.fetchAndActivate()).toBe(true);
    expect(worker.requests[0]?.headers['X-Client-Key']).toBe('k');
  });
});

describe('minimumFetchInterval', () => {
  test('skips the network inside the interval', async () => {
    const rc = await ready(HOUR);
    await rc.fetch();
    expect(worker.requests).toHaveLength(1);

    clock.advance(59 * MINUTE);
    await rc.fetch();
    expect(worker.requests).toHaveLength(1);

    clock.advance(MINUTE);
    await rc.fetch();
    expect(worker.requests).toHaveLength(2);
  });

  test('failed fetches do not start the interval', async () => {
    const rc = await ready(HOUR);
    worker.override = () => new Response('', { status: 500 });
    await expectCode(rc.fetch(), 'server-error');
    worker.override = undefined;
    await rc.fetch();
    expect(worker.requests).toHaveLength(2);
  });

  test('clock moving backwards does not block fetching', async () => {
    const rc = await ready(HOUR);
    await rc.fetch();
    clock.advance(-2 * HOUR);
    await rc.fetch();
    expect(worker.requests).toHaveLength(2);
  });
});

describe('failures', () => {
  const cases: Record<string, [(request: RecordedRequest) => Response, RemoteConfigErrorCode]> = {
    '500': [() => new Response('{"error":"invalid_config"}', { status: 500 }), 'server-error'],
    '401': [() => new Response('', { status: 401 }), 'unauthorized'],
    'bad json': [() => new Response('oops', { status: 200 }), 'invalid-response'],
    network: [
      () => {
        throw new TypeError('Network request failed');
      },
      'network-error',
    ],
  };

  for (const [name, [override, code]] of Object.entries(cases)) {
    test(`${name} -> failure status, active config untouched`, async () => {
      const rc = await ready();
      await rc.fetchAndActivate();
      const fetchTime = rc.fetchTimeMillis;
      clock.advance(MINUTE);

      worker.override = override;
      await expectCode(rc.fetchAndActivate(), code);
      expect(rc.lastFetchStatus).toBe('failure');
      expect(rc.fetchTimeMillis).toBe(fetchTime);
      expect(rc.getString('welcome')).toBe('Hello');
    });
  }

  test('timeout -> failure', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
    const rc = create({ fetch: () => new Promise(() => {}) });
    await rc.setConfigSettings({ fetchTimeoutMillis: 20, minimumFetchIntervalMillis: 0 });
    const fetching = expectCode(rc.fetch(), 'timeout');
    await vi.advanceTimersByTimeAsync(20);
    await fetching;
    expect(rc.lastFetchStatus).toBe('failure');
  });

  test('errors are RemoteConfigError instances', async () => {
    const rc = await ready();
    worker.override = () => new Response('', { status: 502, statusText: 'Bad Gateway' });
    const error = await expectCode(rc.fetch(), 'server-error');
    expect(isRemoteConfigError(error)).toBe(true);
    expect(error).toBeInstanceOf(Error);
    expect(error.name).toBe('RemoteConfigError');
    expect(error.statusCode).toBe(502);
    expect(error.message).toBe('Unexpected response: Bad Gateway');
  });
});

describe('throttling', () => {
  test('429 sets throttle and blocks fetches until it ends', async () => {
    const rc = await ready();
    worker.override = () => new Response('', { status: 429, headers: { 'retry-after': '30' } });
    await expectCode(rc.fetch(), 'throttled');
    expect(rc.lastFetchStatus).toBe('throttled');
    expect(worker.requests).toHaveLength(1);

    worker.override = undefined;
    clock.advance(29 * SECOND);
    const error = await expectCode(rc.fetch(), 'throttled');
    expect(error.throttleEndTimeMillis).toBe(clock.now + SECOND);
    expect(worker.requests, 'no network while throttled').toHaveLength(1);

    clock.advance(SECOND);
    await rc.fetch();
    expect(rc.lastFetchStatus).toBe('success');
    expect(worker.requests).toHaveLength(2);
  });
});

describe('concurrency', () => {
  test('concurrent fetches share one request', async () => {
    const gate = deferred();
    let calls = 0;
    const rc = create({
      fetch: async (url, init) => {
        calls++;
        await gate.promise;
        return worker.fetch(url, init);
      },
    });
    await rc.setConfigSettings({ minimumFetchIntervalMillis: 0 });

    const a = rc.fetch();
    const b = rc.fetch();
    const activated = rc.fetchAndActivate();
    gate.resolve();
    await Promise.all([a, b]);
    expect(await activated).toBe(true);
    expect(calls).toBe(1);

    await rc.fetch(); // a new fetch after completion hits the network again
    expect(calls).toBe(2);
  });

  test('concurrent failing fetches all throw', async () => {
    const rc = await ready();
    worker.override = () => new Response('', { status: 500 });
    const a = rc.fetch();
    const b = rc.fetch();
    await expectCode(a, 'server-error');
    await expectCode(b, 'server-error');
    expect(worker.requests).toHaveLength(1);
  });
});

describe('persistence', () => {
  const key = `cloudflare_worker_kv:${endpoint}|default`;

  test('active, pending, settings and status survive restarts', async () => {
    const rc1 = await ready(HOUR);
    await rc1.fetchAndActivate();
    worker.entries = { welcome: 'Pending' };
    clock.advance(HOUR);
    await rc1.fetch();

    const rc2 = create();
    await rc2.ensureInitialized();
    expect(rc2.getString('welcome')).toBe('Hello');
    expect(rc2.settings.minimumFetchIntervalMillis).toBe(HOUR);
    expect(rc2.lastFetchStatus).toBe('success');
    expect(rc2.fetchTimeMillis).toBe(clock.now);

    // Pending config from rc1 can be activated after restart.
    expect(await rc2.activate()).toBe(true);
    expect(rc2.getString('welcome')).toBe('Pending');

    // minimumFetchInterval is honoured across restarts.
    await rc2.fetch();
    expect(worker.requests).toHaveLength(2);
  });

  test('ETag survives restarts', async () => {
    const rc1 = await ready();
    await rc1.fetchAndActivate();
    const rc2 = create();
    await rc2.fetch();
    expect(worker.requests.at(-1)?.headers['If-None-Match']).toBe(`"${worker.version}"`);
  });

  test('templates and endpoints are stored separately', async () => {
    const rc1 = await ready();
    await rc1.fetchAndActivate();
    const other = create({ template: 'staging' });
    await other.ensureInitialized();
    expect(other.getValue('welcome').getSource()).toBe('static');
    await other.setConfigSettings({});
    const otherEndpoint = new CloudflareRemoteConfig({
      endpoint: `${endpoint}/`,
      fetch: worker.fetch,
      storage,
    });
    await otherEndpoint.ensureInitialized();
    expect(otherEndpoint.getValue('welcome').getSource()).toBe('static');
    await otherEndpoint.setConfigSettings({});
    expect(Object.keys(storage.data).sort()).toEqual([
      `cloudflare_worker_kv:${endpoint}/|default`,
      `cloudflare_worker_kv:${endpoint}|default`,
      `cloudflare_worker_kv:${endpoint}|staging`,
    ]);
    expect(rc1.settings.minimumFetchIntervalMillis).toBe(0);
  });

  for (const corrupt of [
    'not json',
    '[]',
    '{"formatVersion":99}',
    '{"formatVersion":1,"active":{"entries":"nope"}}',
  ]) {
    test(`corrupt cache is ignored: ${corrupt}`, async () => {
      storage = new InMemoryConfigStorage({ [key]: corrupt });
      const rc = create();
      await rc.ensureInitialized();
      expect(rc.getAll()).toEqual({});
      expect(rc.lastFetchStatus).toBe('no_fetch_yet');
      expect(rc.settings).toEqual({
        fetchTimeoutMillis: 60_000,
        minimumFetchIntervalMillis: 43_200_000,
      });
      await rc.setConfigSettings({ minimumFetchIntervalMillis: 0 });
      expect(await rc.fetchAndActivate()).toBe(true);
    });
  }

  test('storage failures never break fetch/activate', async () => {
    const rc = create({ storage: new ThrowingStorage() });
    await rc.ensureInitialized();
    await rc.setConfigSettings({ minimumFetchIntervalMillis: 0 });
    expect(await rc.fetchAndActivate()).toBe(true);
    expect(rc.getString('welcome')).toBe('Hello');
    expect(console.warn).toHaveBeenCalledWith(
      '[react-native-cloudflare-worker-kv] failed to read cache:',
      expect.any(Error),
    );
    expect(console.warn).toHaveBeenCalledWith(
      '[react-native-cloudflare-worker-kv] failed to write cache:',
      expect.any(Error),
    );
  });

  test('synchronously throwing storage never breaks fetch/activate', async () => {
    const rc = create({ storage: new ThrowingStorage('sync') });
    await rc.ensureInitialized();
    await rc.setConfigSettings({ minimumFetchIntervalMillis: 0 });
    expect(await rc.fetchAndActivate()).toBe(true);
    expect(rc.getString('welcome')).toBe('Hello');
  });

  test('last write wins when writes overlap', async () => {
    const slow = new SlowStorage();
    const rc2 = create({ storage: slow });
    await rc2.ensureInitialized();
    await rc2.setConfigSettings({ minimumFetchIntervalMillis: 0 });
    await rc2.fetch();
    slow.resetDelays();

    // Two persists in flight at once; the first is the slowest.
    await Promise.all([
      rc2.activate(),
      rc2.setConfigSettings({ minimumFetchIntervalMillis: 5 * MINUTE }),
    ]);

    const values = Object.values(slow.data);
    expect(values).toHaveLength(1);
    const saved = JSON.parse(values[0] ?? '') as Record<string, unknown>;
    expect(saved['active']).not.toBeNull();
    expect(saved['fetched']).toBeNull();
    expect(saved['settings']).toEqual({ fetchTimeoutMs: 60_000, minimumFetchIntervalMs: 5 * MINUTE });
  });

  test('defaults are not persisted', async () => {
    const rc = await ready();
    await rc.setDefaults({ only_default: 'x' });
    await rc.fetchAndActivate();
    expect(storage.data[key]).not.toContain('only_default');
    const restarted = create();
    await restarted.ensureInitialized();
    expect(restarted.getValue('only_default').getSource()).toBe('static');
  });
});

describe('singleton', () => {
  test('instance throws before initialize', () => {
    expect(() => CloudflareRemoteConfig.instance).toThrow(/initialize\(\) must be called/);
  });

  test('initialize loads cache and exposes instance', async () => {
    const rc1 = await ready();
    await rc1.fetchAndActivate();

    const rc = await CloudflareRemoteConfig.initialize({
      endpoint,
      fetch: worker.fetch,
      storage,
    });
    expect(CloudflareRemoteConfig.instance).toBe(rc);
    expect(rc.getString('welcome')).toBe('Hello'); // no await needed
  });

  test('initialize replaces the shared instance and resetInstance clears it', async () => {
    const first = await CloudflareRemoteConfig.initialize({ endpoint, fetch: worker.fetch, storage });
    const second = await CloudflareRemoteConfig.initialize({ endpoint, fetch: worker.fetch, storage });
    expect(second).not.toBe(first);
    expect(CloudflareRemoteConfig.instance).toBe(second);
    CloudflareRemoteConfig.resetInstance();
    expect(() => CloudflareRemoteConfig.instance).toThrow(Error);
  });

  test('DEFAULT_TEMPLATE is default', () => {
    expect(CloudflareRemoteConfig.DEFAULT_TEMPLATE).toBe('default');
  });
});
