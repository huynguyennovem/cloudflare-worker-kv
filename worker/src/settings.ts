/**
 * Worker settings read from environment variables, so the same code can be
 * pointed at an existing KV namespace without edits. Every variable is
 * optional; dashboard variables always arrive as strings.
 */

export interface Env {
  CONFIG_KV: KVNamespace;
  /** Optional shared key. When set, requests must send a matching `X-Client-Key`. */
  CLIENT_KEY?: string;
  /** `json` (default): one KV value holds a JSON object. `keys`: one KV key per parameter. */
  CONFIG_SOURCE?: string;
  /** `json` source: KV key to read. `{template}` is replaced. Default `config:{template}`. */
  CONFIG_KEY?: string;
  /** `keys` source: only keys starting with this prefix are parameters. `{template}` is replaced. Default: empty. */
  KEY_PREFIX?: string;
  /** `keys` source: `raw` (default) keeps values as stored; `json` decodes JSON values. */
  VALUE_FORMAT?: string;
  /** Cache lifetime in seconds for KV reads (and the aggregated `keys` result). */
  CACHE_TTL?: string | number;
}

export type ConfigSource = "json" | "keys";
export type ValueFormat = "raw" | "json";

export interface WorkerSettings {
  source: ConfigSource;
  configKey: string;
  keyPrefix: string;
  valueFormat: ValueFormat;
  cacheTtl: number;
}

/** Smallest `cacheTtl` Workers KV accepts, in seconds. */
export const MIN_CACHE_TTL = 30;

export const DEFAULT_SETTINGS: WorkerSettings = {
  source: "json",
  configKey: "config:{template}",
  keyPrefix: "",
  valueFormat: "raw",
  cacheTtl: 60,
};

export const TEMPLATE_PLACEHOLDER = "{template}";

/** A variable has an unsupported value. Reported to clients as 500. */
export class MisconfiguredError extends Error {}

export function readSettings(env: Env): WorkerSettings {
  const source = readEnum(env.CONFIG_SOURCE, "CONFIG_SOURCE", ["json", "keys"], DEFAULT_SETTINGS.source);
  const valueFormat = readEnum(env.VALUE_FORMAT, "VALUE_FORMAT", ["raw", "json"], DEFAULT_SETTINGS.valueFormat);

  const configKey = env.CONFIG_KEY ?? DEFAULT_SETTINGS.configKey;
  if (source === "json" && configKey.trim() === "") {
    throw new MisconfiguredError("CONFIG_KEY must not be empty.");
  }

  let cacheTtl = DEFAULT_SETTINGS.cacheTtl;
  if (env.CACHE_TTL !== undefined && String(env.CACHE_TTL).trim() !== "") {
    const raw = String(env.CACHE_TTL).trim();
    cacheTtl = Number(raw);
    if (!/^\d+$/.test(raw) || cacheTtl < MIN_CACHE_TTL) {
      throw new MisconfiguredError(
        `CACHE_TTL must be an integer number of seconds >= ${MIN_CACHE_TTL} (got "${raw}").`,
      );
    }
  }

  return {
    source,
    configKey,
    keyPrefix: env.KEY_PREFIX ?? DEFAULT_SETTINGS.keyPrefix,
    valueFormat,
    cacheTtl,
  };
}

/** Substitutes `{template}` in a key or prefix pattern. */
export function resolvePattern(pattern: string, template: string): string {
  return pattern.split(TEMPLATE_PLACEHOLDER).join(template);
}

function readEnum<T extends string>(
  value: string | undefined,
  name: string,
  allowed: readonly T[],
  fallback: T,
): T {
  if (value === undefined || value.trim() === "") return fallback;
  const normalised = value.trim().toLowerCase();
  if ((allowed as readonly string[]).includes(normalised)) return normalised as T;
  throw new MisconfiguredError(`${name} must be one of ${allowed.join(", ")} (got "${value}").`);
}
