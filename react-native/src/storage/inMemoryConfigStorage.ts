import type { ConfigStorage } from './configStorage';

/** A {@link ConfigStorage} that keeps data in memory only. Useful for tests. */
export class InMemoryConfigStorage implements ConfigStorage {
  private readonly map: Map<string, string>;

  /** Creates a storage, optionally pre-populated with `initial`. */
  constructor(initial?: Record<string, string>) {
    this.map = new Map(initial === undefined ? [] : Object.entries(initial));
  }

  /** A read-only copy of the stored data. */
  get data(): Readonly<Record<string, string>> {
    return Object.freeze(Object.fromEntries(this.map));
  }

  getItem(key: string): Promise<string | null> {
    return Promise.resolve(this.map.get(key) ?? null);
  }

  setItem(key: string, value: string): Promise<void> {
    this.map.set(key, value);
    return Promise.resolve();
  }

  removeItem(key: string): Promise<void> {
    this.map.delete(key);
    return Promise.resolve();
  }
}
