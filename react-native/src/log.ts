const PREFIX = '[react-native-cloudflare-worker-kv]';

/**
 * Logs a non-fatal problem (storage failures, a corrupt cache). Never throws.
 */
export function warn(message: string, error?: unknown): void {
  try {
    if (typeof console === 'undefined' || typeof console.warn !== 'function') {
      return;
    }
    if (error === undefined) {
      console.warn(`${PREFIX} ${message}`);
    } else {
      console.warn(`${PREFIX} ${message}`, error);
    }
  } catch {
    // Logging must never break the caller.
  }
}

/** `String(value)` that cannot throw (e.g. for `Object.create(null)`). */
export function describe(value: unknown): string {
  try {
    return String(value);
  } catch {
    return Object.prototype.toString.call(value);
  }
}
