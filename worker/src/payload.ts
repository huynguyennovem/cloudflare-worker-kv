/**
 * Pure helpers that turn KV data into the wire payload
 * `{"version": "<sha256>", "entries": {"key": "string value"}}`.
 */

export interface ConfigPayload {
  version: string;
  entries: Record<string, string>;
}

/** The stored data cannot be turned into a config (bad JSON, wrong shape). */
export class InvalidConfigError extends Error {}

/**
 * Converts one stored value to the string exposed to clients: strings as-is,
 * numbers/booleans via `String()`, objects/arrays as JSON. Returns `undefined`
 * for `null`, which callers treat as "parameter not set".
 */
export function normaliseValue(value: unknown): string | undefined {
  if (value === null || value === undefined) return undefined;
  return typeof value === "object" ? JSON.stringify(value) : String(value);
}

/** Normalises every value and sorts keys so the output is canonical. */
export function normaliseEntries(obj: Record<string, unknown>): Record<string, string> {
  const entries: Record<string, string> = {};
  for (const key of Object.keys(obj).sort()) {
    const value = normaliseValue(obj[key]);
    if (value !== undefined) entries[key] = value;
  }
  return entries;
}

/** Parses a stored JSON document that must be a plain object of parameters. */
export function parseConfigDocument(raw: string): Record<string, string> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new InvalidConfigError("Stored config is not valid JSON.");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new InvalidConfigError("Stored config must be a JSON object.");
  }
  return normaliseEntries(parsed as Record<string, unknown>);
}

/** SHA-256 over the canonical (key-sorted) entries. */
export async function computeVersion(entries: Record<string, string>): Promise<string> {
  const sorted = Object.keys(entries)
    .sort()
    .map((k) => [k, entries[k]]);
  const bytes = new TextEncoder().encode(JSON.stringify(sorted));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function buildPayload(entries: Record<string, string>): Promise<ConfigPayload> {
  const sorted: Record<string, string> = {};
  for (const key of Object.keys(entries).sort()) sorted[key] = entries[key]!;
  return { version: await computeVersion(sorted), entries: sorted };
}
