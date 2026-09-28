import { describe } from './log';

/** Settings that control fetch behaviour. */
export interface ConfigSettings {
  /**
   * Maximum time for a whole request, including reading the body.
   * An integer greater than zero. Default: 60 000 (60 seconds).
   */
  fetchTimeoutMillis: number;
  /**
   * Minimum age of the last successful fetch before `fetch()` reaches the
   * network again. A non-negative integer. Default: 43 200 000 (12 hours).
   * Use `0` during development.
   */
  minimumFetchIntervalMillis: number;
}

export const DEFAULT_FETCH_TIMEOUT_MILLIS = 60_000;
export const DEFAULT_MINIMUM_FETCH_INTERVAL_MILLIS = 43_200_000;

/** The default settings: a 60 s timeout and a 12 h interval. */
export function defaultSettings(): Readonly<ConfigSettings> {
  return Object.freeze({
    fetchTimeoutMillis: DEFAULT_FETCH_TIMEOUT_MILLIS,
    minimumFetchIntervalMillis: DEFAULT_MINIMUM_FETCH_INTERVAL_MILLIS,
  });
}

/**
 * Validates `settings`, filling omitted fields with their defaults (the
 * settings are replaced as a whole, like in the Flutter package).
 *
 * Throws a `TypeError` for a non-number and a `RangeError` for a number that
 * is not an integer or out of range.
 */
export function resolveSettings(settings: Partial<ConfigSettings>): Readonly<ConfigSettings> {
  if (settings === null || typeof settings !== 'object') {
    throw new TypeError(`settings must be an object, got ${describe(settings)}.`);
  }
  const fetchTimeoutMillis = readSetting(
    settings.fetchTimeoutMillis,
    'fetchTimeoutMillis',
    DEFAULT_FETCH_TIMEOUT_MILLIS,
    1,
  );
  const minimumFetchIntervalMillis = readSetting(
    settings.minimumFetchIntervalMillis,
    'minimumFetchIntervalMillis',
    DEFAULT_MINIMUM_FETCH_INTERVAL_MILLIS,
    0,
  );
  return Object.freeze({ fetchTimeoutMillis, minimumFetchIntervalMillis });
}

function readSetting(value: unknown, name: string, fallback: number, min: number): number {
  if (value === undefined) return fallback;
  if (typeof value !== 'number') {
    throw new TypeError(`${name} must be a number, got ${describe(value)}.`);
  }
  if (!Number.isInteger(value) || value < min) {
    const rule = min > 0 ? 'greater than zero' : 'zero or more';
    throw new RangeError(`${name} must be an integer ${rule}, got ${value}.`);
  }
  return value;
}

/** The persisted form of the settings. */
export interface StoredSettings {
  fetchTimeoutMs: number;
  minimumFetchIntervalMs: number;
}

/** Serialises the settings for persistence. */
export function settingsToJson(settings: ConfigSettings): StoredSettings {
  return {
    fetchTimeoutMs: settings.fetchTimeoutMillis,
    minimumFetchIntervalMs: settings.minimumFetchIntervalMillis,
  };
}

/** Restores settings saved by {@link settingsToJson}; `undefined` when invalid. */
export function settingsFromJson(json: unknown): Readonly<ConfigSettings> | undefined {
  if (json === null || typeof json !== 'object' || Array.isArray(json)) return undefined;
  const { fetchTimeoutMs: timeout, minimumFetchIntervalMs: interval } = json as Record<
    string,
    unknown
  >;
  if (typeof timeout !== 'number' || !Number.isInteger(timeout) || timeout <= 0) return undefined;
  if (typeof interval !== 'number' || !Number.isInteger(interval) || interval < 0) {
    return undefined;
  }
  return Object.freeze({ fetchTimeoutMillis: timeout, minimumFetchIntervalMillis: interval });
}
