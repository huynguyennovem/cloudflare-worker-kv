/** The JSON form of a {@link ConfigSnapshot}, on the wire and in the cache. */
export interface ConfigSnapshotJson {
  version: string;
  entries: Record<string, string>;
}

/**
 * An immutable set of remote entries plus the version the Worker assigned.
 *
 * Entries live in a `Map`, so keys such as `__proto__` are plain keys.
 */
export class ConfigSnapshot {
  /** An empty snapshot. */
  static readonly EMPTY: ConfigSnapshot = new ConfigSnapshot('', new Map());

  /** Opaque version identifier (the Worker uses a SHA-256 of the entries). */
  readonly version: string;
  /** Parameter values, always strings. */
  readonly entries: ReadonlyMap<string, string>;

  constructor(version: string, entries: ReadonlyMap<string, string>) {
    this.version = version;
    this.entries = entries;
  }

  /** Whether both snapshots contain exactly the same entries. */
  hasSameEntries(other: ConfigSnapshot): boolean {
    if (this.entries.size !== other.entries.size) return false;
    for (const [key, value] of this.entries) {
      if (other.entries.get(key) !== value) return false;
    }
    return true;
  }

  /** Serialises the snapshot. */
  toJson(): ConfigSnapshotJson {
    return { version: this.version, entries: Object.fromEntries(this.entries) };
  }

  /**
   * Parses a payload of the form `{"version": "...", "entries": {...}}`.
   *
   * Non-string entry values are normalised like the Worker does: `null` is
   * dropped, objects and arrays become compact JSON, anything else goes
   * through `String()`. `version` falls back to `fallbackVersion`, then `''`.
   * Throws a `TypeError` when the shape is wrong.
   */
  static fromJson(json: unknown, fallbackVersion?: string): ConfigSnapshot {
    if (!isJsonObject(json)) {
      throw new TypeError('Config payload must be a JSON object.');
    }
    const rawEntries = json['entries'];
    if (!isJsonObject(rawEntries)) {
      throw new TypeError('"entries" must be a JSON object.');
    }
    const entries = new Map<string, string>();
    for (const [key, value] of Object.entries(rawEntries)) {
      if (value === null || value === undefined) continue;
      entries.set(key, typeof value === 'string' ? value : normalise(value));
    }
    const version = json['version'];
    return new ConfigSnapshot(
      typeof version === 'string' ? version : (fallbackVersion ?? ''),
      entries,
    );
  }
}

function normalise(value: unknown): string {
  return typeof value === 'object' ? JSON.stringify(value) : String(value);
}

/** A non-null, non-array object. */
export function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
