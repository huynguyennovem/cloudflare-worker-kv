// Stands in for @react-native-async-storage/async-storage in tests (see the
// alias in vitest.config.ts). Like the real module, the storage object is the
// default export.
const store = new Map<string, string>();

const AsyncStorage = {
  getItem(key: string): Promise<string | null> {
    return Promise.resolve(store.get(key) ?? null);
  },
  setItem(key: string, value: string): Promise<void> {
    store.set(key, value);
    return Promise.resolve();
  },
  removeItem(key: string): Promise<void> {
    store.delete(key);
    return Promise.resolve();
  },
};

/** Clears the stub's data. */
export function reset(): void {
  store.clear();
}

/** A copy of the stub's data. */
export function snapshot(): Record<string, string> {
  return Object.fromEntries(store);
}

export default AsyncStorage;
