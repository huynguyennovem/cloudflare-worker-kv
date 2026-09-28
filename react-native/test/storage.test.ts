// Port of flutter/test/storage_test.dart: the same contract runs against every
// storage, and the default (AsyncStorage) storage persists across instances.
import { beforeEach, describe, expect, test, vi } from 'vitest';

import { CloudflareRemoteConfig, InMemoryConfigStorage } from '../src/index';
import type { ConfigStorage } from '../src/index';
import { createDefaultStorage, getDefaultStorage } from '../src/storage/defaultStorage';
import AsyncStorageStub, { reset, snapshot } from './helpers/asyncStorageStub';
import { FakeWorker } from './helpers/fakeWorker';
import { SyncStorage } from './helpers/storages';

const endpoint = 'https://cfg.example.com';

beforeEach(() => {
  reset();
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

function contract(name: string, create: () => ConfigStorage): void {
  describe(name, () => {
    test('read/write/delete', async () => {
      const s = create();
      expect(await s.getItem('k')).toBeNull();
      await s.setItem('k', 'v1');
      expect(await s.getItem('k')).toBe('v1');
      await s.setItem('k', 'v2');
      expect(await s.getItem('k')).toBe('v2');
      await s.removeItem('k');
      expect(await s.getItem('k')).toBeNull();
    });
  });
}

contract('InMemoryConfigStorage', () => new InMemoryConfigStorage());
contract('default storage (AsyncStorage)', () => createDefaultStorage());
contract('synchronous storage (localStorage-like)', () => new SyncStorage());

test('default storage persists across instances', async () => {
  const worker = new FakeWorker({ entries: { a: '1' } });
  const rc1 = new CloudflareRemoteConfig({ endpoint, fetch: worker.fetch });
  await rc1.setConfigSettings({ minimumFetchIntervalMillis: 0 });
  await rc1.fetchAndActivate();
  expect(Object.keys(snapshot())).toEqual([`cloudflare_worker_kv:${endpoint}|default`]);

  const rc2 = new CloudflareRemoteConfig({ endpoint, fetch: worker.fetch });
  await rc2.ensureInitialized();
  expect(rc2.getString('a')).toBe('1');
});

test('a synchronous storage persists across instances', async () => {
  const worker = new FakeWorker({ entries: { a: '1' } });
  const storage = new SyncStorage();
  const rc1 = new CloudflareRemoteConfig({ endpoint, fetch: worker.fetch, storage });
  await rc1.setConfigSettings({ minimumFetchIntervalMillis: 0 });
  await rc1.fetchAndActivate();

  const rc2 = new CloudflareRemoteConfig({ endpoint, fetch: worker.fetch, storage });
  await rc2.ensureInitialized();
  expect(rc2.getString('a')).toBe('1');
});

test('the default storage is shared and created lazily', () => {
  expect(getDefaultStorage()).toBe(getDefaultStorage());
});

describe('AsyncStorage loading', () => {
  test('is lazy and memoised', async () => {
    const load = vi.fn(() => Promise.resolve({ default: AsyncStorageStub }));
    const storage = createDefaultStorage(load);
    expect(load).not.toHaveBeenCalled();
    await storage.setItem('k', 'v');
    expect(await storage.getItem('k')).toBe('v');
    await storage.removeItem('k');
    expect(load).toHaveBeenCalledTimes(1);
  });

  test('finds the storage in the module, default or default.default export', async () => {
    for (const module of [
      AsyncStorageStub,
      { default: AsyncStorageStub },
      { default: { default: AsyncStorageStub } },
      { __esModule: true, default: { default: AsyncStorageStub } },
    ]) {
      const storage = createDefaultStorage(() => Promise.resolve(module));
      await storage.setItem('k', 'v');
      expect(await storage.getItem('k')).toBe('v');
    }
  });

  test('a module without getItem/setItem/removeItem is a storage failure', async () => {
    for (const module of [{}, null, { default: {} }, { default: { getItem() {} } }]) {
      const storage = createDefaultStorage(() => Promise.resolve(module));
      await expect(storage.getItem('k')).rejects.toThrow(TypeError);
    }
  });

  test('a rejecting loader degrades to a warning', async () => {
    const load = vi.fn(() => Promise.reject(new Error('NativeModule: AsyncStorage is null')));
    const worker = new FakeWorker({ entries: { welcome: 'Hello' } });
    const rc = new CloudflareRemoteConfig({
      endpoint,
      fetch: worker.fetch,
      storage: createDefaultStorage(load),
    });
    await rc.ensureInitialized();
    await rc.setConfigSettings({ minimumFetchIntervalMillis: 0 });
    expect(await rc.fetchAndActivate()).toBe(true);
    expect(rc.getString('welcome')).toBe('Hello');
    expect(load).toHaveBeenCalledTimes(1);
    expect(console.warn).toHaveBeenCalledWith(
      '[react-native-cloudflare-worker-kv] failed to read cache:',
      expect.objectContaining({ message: 'NativeModule: AsyncStorage is null' }),
    );
    expect(console.warn).toHaveBeenCalledWith(
      '[react-native-cloudflare-worker-kv] failed to write cache:',
      expect.objectContaining({ message: 'NativeModule: AsyncStorage is null' }),
    );
  });
});

describe('InMemoryConfigStorage', () => {
  test('starts with the initial values', async () => {
    const s = new InMemoryConfigStorage({ a: '1' });
    expect(await s.getItem('a')).toBe('1');
    expect(s.data).toEqual({ a: '1' });
  });

  test('data is a read-only copy', async () => {
    const s = new InMemoryConfigStorage();
    await s.setItem('k', 'v');
    const data = s.data;
    expect(Object.isFrozen(data)).toBe(true);
    await s.setItem('k', 'w');
    expect(data['k']).toBe('v');
  });
});
