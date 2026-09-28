import type { ConfigStorage } from './configStorage';

/** Loads the AsyncStorage module. */
export type AsyncStorageLoader = () => Promise<unknown>;

/**
 * A {@link ConfigStorage} backed by `@react-native-async-storage/async-storage`.
 *
 * The module is imported lazily on first use and memoised. If it cannot be
 * loaded (AsyncStorage v2 throws "NativeModule: AsyncStorage is null" at
 * import time when its native module is missing), every call rejects; the
 * client logs that as a storage failure and keeps working without a cache.
 */
export function createDefaultStorage(
  // A literal import() so that Metro resolves the module statically.
  load: AsyncStorageLoader = () => import('@react-native-async-storage/async-storage'),
): ConfigStorage {
  let storage: Promise<ConfigStorage> | undefined;
  const resolve = (): Promise<ConfigStorage> => (storage ??= load().then(unwrap));
  return {
    async getItem(key: string): Promise<string | null> {
      return (await resolve()).getItem(key);
    },
    async setItem(key: string, value: string): Promise<void> {
      await (await resolve()).setItem(key, value);
    },
    async removeItem(key: string): Promise<void> {
      await (await resolve()).removeItem(key);
    },
  };
}

let shared: ConfigStorage | undefined;

/** The AsyncStorage-backed storage shared by all clients. */
export function getDefaultStorage(): ConfigStorage {
  return (shared ??= createDefaultStorage());
}

/**
 * Finds the storage object in the imported module: the module itself, its
 * `default` export, or `default.default` (CommonJS interop).
 */
function unwrap(module: unknown): ConfigStorage {
  let candidate = module;
  for (let depth = 0; depth < 3; depth++) {
    if (isStorage(candidate)) return candidate;
    if (typeof candidate !== 'object' || candidate === null) break;
    candidate = (candidate as { default?: unknown }).default;
  }
  throw new TypeError(
    '@react-native-async-storage/async-storage does not export getItem, setItem and removeItem.',
  );
}

function isStorage(value: unknown): value is ConfigStorage {
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as Partial<Record<keyof ConfigStorage, unknown>>;
  return (
    typeof candidate.getItem === 'function' &&
    typeof candidate.setItem === 'function' &&
    typeof candidate.removeItem === 'function'
  );
}
