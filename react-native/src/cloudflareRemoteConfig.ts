import { ConfigSnapshot } from './configSnapshot';
import type { FetchStatus } from './fetchStatus';
import type { FetchLike } from './http';
import { describe, warn } from './log';
import { decodeState, encodeState, initialState, storageKey } from './persistedState';
import type { PersistedState } from './persistedState';
import { RemoteConfigError } from './remoteConfigError';
import { resolveSettings } from './remoteConfigSettings';
import type { ConfigSettings } from './remoteConfigSettings';
import { RemoteConfigValue } from './remoteConfigValue';
import type { ConfigStorage } from './storage/configStorage';
import { getDefaultStorage } from './storage/defaultStorage';
import { checkTemplate, WorkerClient } from './workerClient';

/** Options for {@link CloudflareRemoteConfig}. */
export interface CloudflareRemoteConfigOptions {
  /**
   * Base URL of the Worker, e.g. `https://my-config.<subdomain>.workers.dev`.
   * Must be absolute; a path prefix and query parameters are allowed.
   */
  endpoint: string;
  /** Which config template to read. Must match `[A-Za-z0-9_-]{1,64}`. Default: `'default'`. */
  template?: string | undefined;
  /** Sent as `X-Client-Key`, for Workers that set `CLIENT_KEY`. Not a secret. */
  clientKey?: string | undefined;
  /** Custom `fetch` (proxies, testing...). Default: the global `fetch`, looked up at call time. */
  fetch?: FetchLike | undefined;
  /** Persistence for the cache. Default: AsyncStorage, imported lazily. */
  storage?: ConfigStorage | undefined;
  /** Clock in epoch milliseconds. Default: `Date.now`. */
  now?: (() => number) | undefined;
}

/**
 * A value accepted by `setDefaults`: strings are kept, numbers and booleans are
 * converted with `String()`, arrays and plain objects are stored as JSON, and
 * `null` / `undefined` are ignored.
 */
export type DefaultValue =
  | string
  | number
  | boolean
  | null
  | undefined
  | readonly unknown[]
  | { readonly [key: string]: unknown };

/** In-app default values, keyed by parameter name. */
export type ConfigDefaults = Record<string, DefaultValue>;

let sharedInstance: CloudflareRemoteConfig | undefined;

/**
 * Remote config backed by a Cloudflare Worker reading from Workers KV.
 *
 * ```ts
 * const remoteConfig = await CloudflareRemoteConfig.initialize({
 *   endpoint: 'https://my-config.<subdomain>.workers.dev',
 * });
 * await remoteConfig.setDefaults({ welcome: 'Hello' });
 * await remoteConfig.fetchAndActivate();
 * const welcome = remoteConfig.getString('welcome');
 * ```
 *
 * Values resolve in this order: activated remote value, default value,
 * static value (`''`, `0`, `false`).
 */
export class CloudflareRemoteConfig {
  /** Template used when none is given. */
  static readonly DEFAULT_TEMPLATE = 'default';

  /**
   * The instance created by {@link initialize}.
   *
   * Throws an `Error` if `initialize()` has not been called.
   */
  static get instance(): CloudflareRemoteConfig {
    if (sharedInstance === undefined) {
      throw new Error(
        'CloudflareRemoteConfig.initialize() must be called before accessing ' +
          'CloudflareRemoteConfig.instance.',
      );
    }
    return sharedInstance;
  }

  /**
   * Creates the shared {@link instance}, loads the cached config from storage
   * and returns it. Calling it again replaces the shared instance.
   */
  static async initialize(options: CloudflareRemoteConfigOptions): Promise<CloudflareRemoteConfig> {
    const config = new CloudflareRemoteConfig(options);
    await config.ensureInitialized();
    sharedInstance = config;
    return config;
  }

  /** Clears the shared {@link instance}. Intended for tests. */
  static resetInstance(): void {
    sharedInstance = undefined;
  }

  private readonly client: WorkerClient;
  private readonly storage: ConfigStorage;
  private readonly storageKey: string;
  private readonly now: () => number;

  private defaults: ReadonlyMap<string, string> = new Map();
  private active: ConfigSnapshot | undefined;
  private fetched: ConfigSnapshot | undefined;
  private etag: string | undefined;
  private lastSuccessfulFetchMillis: number | undefined;
  private throttleEndMillis: number | undefined;
  private status: FetchStatus = 'no_fetch_yet';
  private currentSettings: Readonly<ConfigSettings>;

  private initialization: Promise<void> | undefined;
  private inFlight: Promise<void> | undefined;
  private pendingWrite: Promise<void> = Promise.resolve();

  /**
   * Creates an instance. Most apps use {@link initialize} and
   * {@link instance} instead; create instances directly to read several
   * templates or Workers. Call {@link ensureInitialized} before reading values.
   *
   * Throws a `TypeError` for an invalid template or endpoint.
   */
  constructor(options: CloudflareRemoteConfigOptions) {
    if (options === null || typeof options !== 'object') {
      throw new TypeError(`options must be an object, got ${describe(options)}.`);
    }
    const template = checkTemplate(options.template ?? CloudflareRemoteConfig.DEFAULT_TEMPLATE);
    const now = options.now ?? ((): number => Date.now());
    this.client = new WorkerClient({
      endpoint: options.endpoint,
      template,
      clientKey: options.clientKey,
      fetch: options.fetch,
      now,
    });
    this.now = now;
    this.storage = options.storage ?? getDefaultStorage();
    this.storageKey = storageKey(options.endpoint, template);
    this.currentSettings = initialState().settings;
  }

  /** When the last successful fetch completed, in epoch milliseconds; `-1` if none has. */
  get fetchTimeMillis(): number {
    return this.lastSuccessfulFetchMillis ?? -1;
  }

  /** Outcome of the most recent fetch attempt. */
  get lastFetchStatus(): FetchStatus {
    return this.status;
  }

  /** The current fetch settings. */
  get settings(): Readonly<ConfigSettings> {
    return this.currentSettings;
  }

  /**
   * Loads the cached config from storage. Safe to call multiple times; never
   * rejects.
   *
   * Every other asynchronous method awaits this internally, but the
   * synchronous getters only see cached values once it has completed.
   */
  ensureInitialized(): Promise<void> {
    return (this.initialization ??= this.load());
  }

  /**
   * Replaces the fetch settings and persists them. Omitted fields take their
   * defaults (60 s timeout, 12 h interval).
   *
   * Rejects with a `TypeError` or `RangeError` for invalid values.
   */
  async setConfigSettings(settings: Partial<ConfigSettings>): Promise<void> {
    const resolved = resolveSettings(settings);
    await this.ensureInitialized();
    this.currentSettings = resolved;
    await this.persist();
  }

  /**
   * Replaces the in-app default values. They apply immediately and are not
   * persisted: set them on every launch.
   *
   * Strings are kept, numbers and booleans are converted with `String()`,
   * arrays and plain objects are stored as JSON, and `null` / `undefined`
   * values are ignored. Rejects with a `TypeError` for any other type.
   */
  async setDefaults(defaults: ConfigDefaults): Promise<void> {
    if (defaults === null || typeof defaults !== 'object') {
      throw new TypeError(`defaults must be an object, got ${describe(defaults)}.`);
    }
    const converted = new Map<string, string>();
    for (const [key, value] of Object.entries(defaults)) {
      const text = convertDefault(key, value);
      if (text !== undefined) converted.set(key, text);
    }
    this.defaults = converted;
  }

  /**
   * Fetches the latest config from the Worker without activating it.
   *
   * Does nothing when the last successful fetch is younger than
   * `minimumFetchIntervalMillis`. Concurrent calls share a single request.
   * Rejects with a {@link RemoteConfigError} on failure; the active config is
   * never modified by a failed fetch.
   */
  fetch(): Promise<void> {
    return (this.inFlight ??= this.runFetch().finally(() => {
      this.inFlight = undefined;
    }));
  }

  /**
   * Makes the last fetched config available to the getters.
   *
   * Resolves to `true` if a newer config was activated, `false` if there was
   * nothing new to activate.
   */
  async activate(): Promise<boolean> {
    await this.ensureInitialized();
    const fetched = this.fetched;
    if (fetched === undefined) return false;
    this.active = fetched;
    this.fetched = undefined;
    await this.persist();
    return true;
  }

  /** Calls {@link fetch} then {@link activate}; resolves to the result of `activate`. */
  async fetchAndActivate(): Promise<boolean> {
    await this.fetch();
    return this.activate();
  }

  /** Every known key (remote and default) with its resolved value. */
  getAll(): Record<string, RemoteConfigValue> {
    const keys = new Set<string>(this.defaults.keys());
    if (this.active !== undefined) {
      for (const key of this.active.entries.keys()) keys.add(key);
    }
    return Object.fromEntries(Array.from(keys, (key) => [key, this.getValue(key)]));
  }

  /** The value for `key`, including its source. */
  getValue(key: string): RemoteConfigValue {
    const remote = this.active?.entries.get(key);
    if (remote !== undefined) return new RemoteConfigValue(remote, 'remote');
    const fallback = this.defaults.get(key);
    if (fallback !== undefined) return new RemoteConfigValue(fallback, 'default');
    return new RemoteConfigValue(undefined, 'static');
  }

  /** The value for `key` as a string (`''` when unknown). */
  getString(key: string): string {
    return this.getValue(key).asString();
  }

  /** The value for `key` as a number (`0` when unknown or not numeric). */
  getNumber(key: string): number {
    return this.getValue(key).asNumber();
  }

  /** The value for `key` as a boolean (`false` when unknown). */
  getBoolean(key: string): boolean {
    return this.getValue(key).asBoolean();
  }

  private async runFetch(): Promise<void> {
    await this.ensureInitialized();
    const now = this.now();

    const throttleEnd = this.throttleEndMillis;
    if (throttleEnd !== undefined && now < throttleEnd) {
      this.status = 'throttled';
      throw new RemoteConfigError('throttled', `Fetch is throttled until ${formatTime(throttleEnd)}.`, {
        throttleEndTimeMillis: throttleEnd,
      });
    }

    const lastSuccess = this.lastSuccessfulFetchMillis;
    if (
      lastSuccess !== undefined &&
      now - lastSuccess < this.currentSettings.minimumFetchIntervalMillis &&
      !(now < lastSuccess)
    ) {
      return; // The cached config is fresh enough.
    }

    try {
      const result = await this.client.fetch({
        etag: this.etag,
        timeoutMillis: this.currentSettings.fetchTimeoutMillis,
      });
      if (result.kind === 'fetched') {
        this.etag = result.etag;
        const active = this.active ?? ConfigSnapshot.EMPTY;
        // Only keep a pending config when it differs from the active one.
        this.fetched = result.snapshot.hasSameEntries(active) ? undefined : result.snapshot;
      }
      // On 304, whatever is pending or active is still current.
      this.lastSuccessfulFetchMillis = this.now();
      this.throttleEndMillis = undefined;
      this.status = 'success';
    } catch (error) {
      if (error instanceof RemoteConfigError) {
        if (error.code === 'throttled') {
          this.throttleEndMillis = error.throttleEndTimeMillis;
          this.status = 'throttled';
        } else {
          this.status = 'failure';
        }
      }
      throw error;
    } finally {
      await this.persist();
    }
  }

  private async load(): Promise<void> {
    let raw: unknown;
    try {
      raw = await this.storage.getItem(this.storageKey);
    } catch (error) {
      warn('failed to read cache:', error);
      return;
    }
    if (typeof raw !== 'string') return;
    const state = decodeState(raw);
    this.active = state.active;
    this.fetched = state.fetched;
    this.etag = state.etag;
    this.lastSuccessfulFetchMillis = state.lastSuccessfulFetchMillis;
    this.throttleEndMillis = state.throttleEndMillis;
    this.status = state.lastFetchStatus;
    this.currentSettings = state.settings;
  }

  /**
   * Persists the current state. Writes are serialised so that the last call
   * always wins, and storage failures are logged, never thrown.
   */
  private persist(): Promise<void> {
    const state: PersistedState = {
      active: this.active,
      fetched: this.fetched,
      etag: this.etag,
      lastSuccessfulFetchMillis: this.lastSuccessfulFetchMillis,
      throttleEndMillis: this.throttleEndMillis,
      lastFetchStatus: this.status,
      settings: this.currentSettings,
    };
    const snapshot = encodeState(state);
    return (this.pendingWrite = this.pendingWrite.then(async () => {
      try {
        await this.storage.setItem(this.storageKey, snapshot);
      } catch (error) {
        warn('failed to write cache:', error);
      }
    }));
  }
}

function convertDefault(key: string, value: unknown): string | undefined {
  if (value === null || value === undefined) return undefined;
  switch (typeof value) {
    case 'string':
      return value;
    case 'number':
    case 'boolean':
      return String(value);
    case 'object':
      if (Array.isArray(value) || isPlainObject(value)) return JSON.stringify(value);
      break;
  }
  throw new TypeError(
    `Unsupported default value for "${key}": ${describeType(value)}. ` +
      'Use a string, number, boolean, array or plain object.',
  );
}

function isPlainObject(value: object): boolean {
  const prototype: unknown = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function describeType(value: unknown): string {
  if (typeof value === 'object' && value !== null) {
    const name = (value as { constructor?: { name?: unknown } }).constructor?.name;
    return typeof name === 'string' && name !== '' ? name : 'object';
  }
  return typeof value;
}

function formatTime(millis: number): string {
  const date = new Date(millis);
  return Number.isNaN(date.getTime()) ? `${millis} ms` : date.toISOString();
}
