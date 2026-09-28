/**
 * Persistence for the cached config.
 *
 * The shape matches AsyncStorage and the web's `localStorage`, so both can be
 * passed as they are. Methods may be synchronous or return promises, and may
 * throw: failures are logged and never break fetching or reading values.
 */
export interface ConfigStorage {
  /** Returns the value stored under `key`, or `null` if absent. */
  getItem(key: string): Promise<string | null> | string | null;
  /** Stores `value` under `key`, replacing any previous value. */
  setItem(key: string, value: string): Promise<void> | void;
  /** Removes `key`. */
  removeItem(key: string): Promise<void> | void;
}
