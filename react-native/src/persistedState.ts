import { ConfigSnapshot, isJsonObject } from './configSnapshot';
import type { FetchStatus } from './fetchStatus';
import { fetchStatusFromStored, fetchStatusToStored } from './fetchStatus';
import { warn } from './log';
import { defaultSettings, settingsFromJson, settingsToJson } from './remoteConfigSettings';
import type { ConfigSettings } from './remoteConfigSettings';

/** Version of the cache format; a cache with another version is ignored. */
export const STORAGE_FORMAT_VERSION = 1;

/** Prefix of the storage key, shared with the other SDKs. */
export const STORAGE_KEY_PREFIX = 'cloudflare_worker_kv:';

/** Everything that survives a restart. Defaults are never persisted. */
export interface PersistedState {
  active: ConfigSnapshot | undefined;
  fetched: ConfigSnapshot | undefined;
  etag: string | undefined;
  lastSuccessfulFetchMillis: number | undefined;
  throttleEndMillis: number | undefined;
  lastFetchStatus: FetchStatus;
  settings: Readonly<ConfigSettings>;
}

/** `cloudflare_worker_kv:{endpoint}|{template}`, with the endpoint as configured. */
export function storageKey(endpoint: string, template: string): string {
  return `${STORAGE_KEY_PREFIX}${endpoint}|${template}`;
}

/** The state of a client that has never fetched. */
export function initialState(): PersistedState {
  return {
    active: undefined,
    fetched: undefined,
    etag: undefined,
    lastSuccessfulFetchMillis: undefined,
    throttleEndMillis: undefined,
    lastFetchStatus: 'no_fetch_yet',
    settings: defaultSettings(),
  };
}

/**
 * Serialises `state` in the key order of the Flutter package, writing
 * missing values as `null`.
 */
export function encodeState(state: PersistedState): string {
  return JSON.stringify({
    formatVersion: STORAGE_FORMAT_VERSION,
    active: state.active?.toJson() ?? null,
    fetched: state.fetched?.toJson() ?? null,
    etag: state.etag ?? null,
    lastSuccessfulFetchMs: state.lastSuccessfulFetchMillis ?? null,
    throttleEndMs: state.throttleEndMillis ?? null,
    lastFetchStatus: fetchStatusToStored(state.lastFetchStatus),
    settings: settingsToJson(state.settings),
  });
}

/**
 * Parses a cache written by {@link encodeState} (or by the Flutter package).
 *
 * Returns a clean state when the cache is not valid JSON, not an object, has
 * another `formatVersion` or holds a malformed snapshot. Invalid individual
 * fields fall back to their defaults.
 */
export function decodeState(raw: string): PersistedState {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch (error) {
    warn('ignoring corrupt cache:', error);
    return initialState();
  }
  if (!isJsonObject(json) || json['formatVersion'] !== STORAGE_FORMAT_VERSION) {
    return initialState();
  }
  try {
    const active = json['active'];
    const fetched = json['fetched'];
    const etag = json['etag'];
    return {
      active: active == null ? undefined : ConfigSnapshot.fromJson(active),
      fetched: fetched == null ? undefined : ConfigSnapshot.fromJson(fetched),
      etag: typeof etag === 'string' ? etag : undefined,
      lastSuccessfulFetchMillis: readTime(json['lastSuccessfulFetchMs']),
      throttleEndMillis: readTime(json['throttleEndMs']),
      lastFetchStatus: fetchStatusFromStored(json['lastFetchStatus']),
      settings: settingsFromJson(json['settings']) ?? defaultSettings(),
    };
  } catch (error) {
    warn('ignoring corrupt cache:', error);
    return initialState();
  }
}

function readTime(ms: unknown): number | undefined {
  return typeof ms === 'number' && Number.isInteger(ms) ? ms : undefined;
}
