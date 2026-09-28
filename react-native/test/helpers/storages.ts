import { InMemoryConfigStorage } from '../../src/index';
import type { ConfigStorage } from '../../src/index';

/** Every call fails: asynchronously by default, or by throwing synchronously. */
export class ThrowingStorage implements ConfigStorage {
  constructor(private readonly mode: 'async' | 'sync' = 'async') {}

  getItem(): Promise<string | null> {
    return this.fail('read');
  }

  setItem(): Promise<void> {
    return this.fail('write');
  }

  removeItem(): Promise<void> {
    return this.fail('delete');
  }

  private fail(operation: string): Promise<never> {
    const error = new Error(operation);
    if (this.mode === 'sync') throw error;
    return Promise.reject(error);
  }
}

/**
 * Earlier writes take longer (30, 20, 10 ms after `resetDelays`), so
 * unserialised writes would finish out of order and leave stale data behind.
 */
export class SlowStorage extends InMemoryConfigStorage {
  private delay = 0;

  resetDelays(): void {
    this.delay = 30;
  }

  override async setItem(key: string, value: string): Promise<void> {
    const delay = this.delay;
    this.delay = Math.min(Math.max(this.delay - 10, 0), 30);
    await new Promise((resolve) => setTimeout(resolve, delay));
    await super.setItem(key, value);
  }
}

/** A synchronous, `localStorage`-like storage. */
export class SyncStorage implements ConfigStorage {
  private readonly map = new Map<string, string>();

  getItem(key: string): string | null {
    return this.map.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.map.set(key, value);
  }

  removeItem(key: string): void {
    this.map.delete(key);
  }

  get data(): Record<string, string> {
    return Object.fromEntries(this.map);
  }
}
