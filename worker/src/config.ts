/**
 * HTTP handling for the remote config Worker (see `index.ts`).
 *
 * Kept separate from the entry module because workerd treats every named
 * export of the entry module as an entrypoint and rejects non-handler values.
 *
 * HTTP contract (consumed by the `cloudflare_worker_kv` Flutter package):
 *
 *   GET /v1/config?template=<name>
 *     Headers (optional): X-Client-Key, If-None-Match
 *     200 {"version": "<sha256>", "entries": {"key": "string value", ...}} + ETag
 *     304 when If-None-Match matches the current version
 *
 * Where the entries come from is configured with environment variables; see
 * `settings.ts` and README.md.
 */
import { buildPayload, InvalidConfigError } from "./payload";
import { MisconfiguredError, readSettings, type Env } from "./settings";
import { createSourceDeps, loadEntries, TooManyKeysError, type SourceDeps } from "./sources";

export type { Env } from "./settings";

export const CONFIG_PATH = "/v1/config";
export const DEFAULT_TEMPLATE = "default";

const TEMPLATE_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "X-Client-Key, If-None-Match, Content-Type",
  "Access-Control-Expose-Headers": "ETag",
  "Access-Control-Max-Age": "86400",
};

/** Shared by every request handled by this isolate. */
const isolateDeps = createSourceDeps();

export async function handleRequest(
  request: Request,
  env: Env,
  deps: SourceDeps = isolateDeps,
): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname !== CONFIG_PATH) {
    return errorResponse(404, "not_found", "Unknown route.");
  }
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method !== "GET") {
    return errorResponse(405, "method_not_allowed", "Only GET is supported.", {
      Allow: "GET, OPTIONS",
    });
  }

  if (env.CLIENT_KEY) {
    const provided = request.headers.get("X-Client-Key") ?? "";
    if (!(await timingSafeEqualStrings(provided, env.CLIENT_KEY))) {
      return errorResponse(401, "unauthorized", "Missing or invalid X-Client-Key.");
    }
  }

  const template = url.searchParams.get("template") ?? DEFAULT_TEMPLATE;
  if (!TEMPLATE_PATTERN.test(template)) {
    return errorResponse(400, "invalid_template", "Template must match [A-Za-z0-9_-]{1,64}.");
  }

  let entries: Record<string, string>;
  try {
    entries = await loadEntries(env, readSettings(env), template, deps);
  } catch (e) {
    if (e instanceof MisconfiguredError) {
      return errorResponse(500, "worker_misconfigured", e.message);
    }
    if (e instanceof InvalidConfigError) {
      return errorResponse(500, "invalid_config", e.message);
    }
    if (e instanceof TooManyKeysError) {
      return errorResponse(500, "too_many_keys", e.message);
    }
    return errorResponse(503, "kv_unavailable", "Failed to read config from KV.");
  }

  const payload = await buildPayload(entries);
  const headers: Record<string, string> = {
    ...CORS_HEADERS,
    ETag: `"${payload.version}"`,
    "Cache-Control": "no-cache",
  };

  if (ifNoneMatchMatches(request.headers.get("If-None-Match"), payload.version)) {
    return new Response(null, { status: 304, headers });
  }

  return new Response(JSON.stringify(payload), {
    status: 200,
    headers: { ...headers, "Content-Type": "application/json; charset=utf-8" },
  });
}

/** Implements If-None-Match weak comparison (RFC 9110 §13.1.2). */
export function ifNoneMatchMatches(header: string | null, version: string): boolean {
  if (!header) return false;
  const trimmed = header.trim();
  if (trimmed === "*") return true;
  return trimmed
    .split(",")
    .map((tag) => tag.trim().replace(/^W\//, ""))
    .some((tag) => tag === `"${version}"`);
}

async function timingSafeEqualStrings(a: string, b: string): Promise<boolean> {
  // Hash first so both buffers have equal length regardless of input.
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(ha, hb);
}

function errorResponse(
  status: number,
  code: string,
  message: string,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify({ error: code, message }), {
    status,
    headers: {
      ...CORS_HEADERS,
      ...extraHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}
