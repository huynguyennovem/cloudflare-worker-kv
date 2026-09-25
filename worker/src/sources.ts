/**
 * Reads config entries from KV using one of two layouts:
 *
 * - `json`: a single KV value holds a JSON object of parameters.
 * - `keys`: every KV key under a prefix is one parameter (prefix stripped).
 *
 * The `keys` layout needs a `list()` plus bulk reads, so its aggregated result
 * is cached in isolate memory for `cacheTtl` seconds.
 */
import { normaliseValue, parseConfigDocument } from "./payload";
import { resolvePattern, type Env, type WorkerSettings } from "./settings";

/** Keys per `list()` page (the KV maximum). */
export const LIST_PAGE_SIZE = 1000;
/** Keys per bulk `get()` call (the KV maximum). */
export const BULK_GET_SIZE = 100;
/** Upper bound on parameters in the `keys` layout, to stay within per-request limits. */
export const MAX_KEYS = 1000;

/** The `keys` layout found more than {@link MAX_KEYS} keys. */
export class TooManyKeysError extends Error {}

interface CacheEntry {
  expiresAt: number;
  entries: Record<string, string>;
}

export interface SourceDeps {
  /** Milliseconds since epoch. */
  now: () => number;
  /**
   * Aggregated `keys` results, shared by requests in the same isolate. Only
   * plain data is stored: sharing promises or I/O objects across requests is
   * unsafe in Workers (continuations are dropped if the creating request ends).
   */
  cache: Map<string, CacheEntry>;
}

export function createSourceDeps(now: () => number = Date.now): SourceDeps {
  return { now, cache: new Map() };
}

export async function loadEntries(
  env: Env,
  settings: WorkerSettings,
  template: string,
  deps: SourceDeps,
): Promise<Record<string, string>> {
  if (settings.source === "json") {
    const key = resolvePattern(settings.configKey, template);
    const raw = await env.CONFIG_KV.get(key, { cacheTtl: settings.cacheTtl });
    return raw === null ? {} : parseConfigDocument(raw);
  }

  const prefix = resolvePattern(settings.keyPrefix, template);
  const cacheKey = JSON.stringify([prefix, settings.valueFormat, settings.cacheTtl]);
  const cached = deps.cache.get(cacheKey);
  if (cached && cached.expiresAt > deps.now()) return cached.entries;

  const entries = await readKeys(env.CONFIG_KV, prefix, settings);
  deps.cache.set(cacheKey, { expiresAt: deps.now() + settings.cacheTtl * 1000, entries });
  return entries;
}

async function readKeys(
  kv: KVNamespace,
  prefix: string,
  settings: WorkerSettings,
): Promise<Record<string, string>> {
  const names: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await kv.list({ prefix, cursor, limit: LIST_PAGE_SIZE });
    for (const key of page.keys) {
      if (key.name.length > prefix.length) names.push(key.name);
    }
    if (names.length > MAX_KEYS) {
      throw new TooManyKeysError(
        `More than ${MAX_KEYS} keys match prefix "${prefix}". Use a narrower KEY_PREFIX.`,
      );
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  const entries: Record<string, string> = {};
  for (let i = 0; i < names.length; i += BULK_GET_SIZE) {
    const chunk = names.slice(i, i + BULK_GET_SIZE);
    const values = await kv.get(chunk, { type: "text", cacheTtl: settings.cacheTtl });
    // workerd drops array-index-like names ("0", "2024") from the bulk Map,
    // so read any key missing from it individually.
    for (const name of chunk) {
      if (!values.has(name)) {
        values.set(name, await kv.get(name, { type: "text", cacheTtl: settings.cacheTtl }));
      }
    }
    for (const [name, value] of values) {
      // A key deleted between list() and get() comes back as null.
      if (value === null) continue;
      const decoded = decodeValue(value, settings);
      if (decoded !== undefined) entries[name.slice(prefix.length)] = decoded;
    }
  }
  return entries;
}

function decodeValue(value: string, settings: WorkerSettings): string | undefined {
  if (settings.valueFormat === "raw") return value;
  try {
    return normaliseValue(JSON.parse(value));
  } catch {
    // Not JSON: keep the stored text, so mixed data still works.
    return value;
  }
}
