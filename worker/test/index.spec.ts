import { env } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { handleRequest, ifNoneMatchMatches, type Env } from "../src/config";
import {
  buildPayload,
  computeVersion,
  normaliseEntries,
  type ConfigPayload,
} from "../src/payload";
import * as entryModule from "../src/index";

const BASE = "https://config.example.com";
const KEY = "test-client-key";

function get(path: string, headers: Record<string, string> = {}): Promise<Response> {
  return exports.default.fetch(
    new Request(BASE + path, { headers: { "X-Client-Key": KEY, ...headers } }),
  );
}

async function putTemplate(template: string, value: unknown): Promise<void> {
  await env.CONFIG_KV.put(
    `config:${template}`,
    typeof value === "string" ? value : JSON.stringify(value),
  );
}

beforeEach(async () => {
  const { keys } = await env.CONFIG_KV.list();
  await Promise.all(keys.map((k) => env.CONFIG_KV.delete(k.name)));
});

describe("GET /v1/config", () => {
  it("returns normalised entries with version and ETag", async () => {
    await putTemplate("default", {
      welcome: "Hello",
      max_items: 10,
      ratio: 1.5,
      dark_mode: true,
      nested: { a: [1, 2] },
      removed: null,
    });

    const res = await get("/v1/config");
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("application/json");
    expect(res.headers.get("Cache-Control")).toBe("no-cache");
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");

    const body = (await res.json()) as ConfigPayload;
    expect(body.entries).toEqual({
      dark_mode: "true",
      max_items: "10",
      nested: '{"a":[1,2]}',
      ratio: "1.5",
      welcome: "Hello",
    });
    expect(body.version).toMatch(/^[0-9a-f]{64}$/);
    expect(res.headers.get("ETag")).toBe(`"${body.version}"`);
  });

  it("returns empty entries when the template does not exist", async () => {
    const res = await get("/v1/config");
    expect(res.status).toBe(200);
    const body = (await res.json()) as ConfigPayload;
    expect(body.entries).toEqual({});
    expect(body.version).toBe(await computeVersion({}));
  });

  it("selects the template from the query string", async () => {
    await putTemplate("default", { env: "prod" });
    await putTemplate("staging", { env: "staging" });
    const body = (await (await get("/v1/config?template=staging")).json()) as ConfigPayload;
    expect(body.entries).toEqual({ env: "staging" });
  });

  it("rejects invalid template names", async () => {
    for (const t of ["", "a/b", "a b", "x".repeat(65), "../default"]) {
      const res = await get(`/v1/config?template=${encodeURIComponent(t)}`);
      expect(res.status, `template=${t}`).toBe(400);
      expect(((await res.json()) as { error: string }).error).toBe("invalid_template");
    }
  });

  it("returns 304 when If-None-Match matches, 200 otherwise", async () => {
    await putTemplate("default", { a: "1" });
    const first = await get("/v1/config");
    const etag = first.headers.get("ETag")!;

    const notModified = await get("/v1/config", { "If-None-Match": etag });
    expect(notModified.status).toBe(304);
    expect(notModified.headers.get("ETag")).toBe(etag);
    expect(await notModified.text()).toBe("");

    const weak = await get("/v1/config", { "If-None-Match": `W/${etag}` });
    expect(weak.status).toBe(304);

    const stale = await get("/v1/config", { "If-None-Match": '"stale"' });
    expect(stale.status).toBe(200);
  });

  it("changes version when config changes", async () => {
    await putTemplate("default", { a: "1" });
    const v1 = ((await (await get("/v1/config")).json()) as ConfigPayload).version;
    await putTemplate("default", { a: "2" });
    const v2 = ((await (await get("/v1/config")).json()) as ConfigPayload).version;
    expect(v1).not.toBe(v2);
  });

  it("returns 500 invalid_config for malformed stored data", async () => {
    for (const bad of ["{not json", "[1,2]", "null", '"str"', "42"]) {
      await putTemplate("default", bad);
      const res = await get("/v1/config");
      expect(res.status, bad).toBe(500);
      expect(((await res.json()) as { error: string }).error).toBe("invalid_config");
    }
  });
});

describe("client key", () => {
  it("rejects missing or wrong key", async () => {
    const missing = await exports.default.fetch(new Request(BASE + "/v1/config"));
    expect(missing.status).toBe(401);
    const wrong = await get("/v1/config", { "X-Client-Key": "nope" });
    expect(wrong.status).toBe(401);
    expect(wrong.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });

  it("does not require a key when CLIENT_KEY is unset", async () => {
    const openEnv: Env = { CONFIG_KV: env.CONFIG_KV };
    const res = await handleRequest(new Request(BASE + "/v1/config"), openEnv);
    expect(res.status).toBe(200);
  });
});

describe("routing and CORS", () => {
  it("answers CORS preflight without auth", async () => {
    const res = await exports.default.fetch(
      new Request(BASE + "/v1/config", { method: "OPTIONS" }),
    );
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Headers")).toContain("X-Client-Key");
    expect(res.headers.get("Access-Control-Expose-Headers")).toBe("ETag");
  });

  it("returns 405 for unsupported methods", async () => {
    for (const method of ["POST", "PUT", "DELETE"]) {
      const res = await exports.default.fetch(
        new Request(BASE + "/v1/config", { method, headers: { "X-Client-Key": KEY } }),
      );
      expect(res.status, method).toBe(405);
      expect(res.headers.get("Allow")).toBe("GET, OPTIONS");
    }
  });

  it("returns 404 for unknown routes", async () => {
    for (const path of ["/", "/v1", "/v1/config/extra", "/v2/config"]) {
      expect((await get(path)).status, path).toBe(404);
    }
  });

  it("returns 503 when KV read fails", async () => {
    const brokenKv = {
      get: () => Promise.reject(new Error("boom")),
    } as unknown as KVNamespace;
    const res = await handleRequest(new Request(BASE + "/v1/config"), { CONFIG_KV: brokenKv });
    expect(res.status).toBe(503);
  });
});

describe("entry module", () => {
  it("exports only the default handler (workerd rejects other named exports)", () => {
    expect(Object.keys(entryModule)).toEqual(["default"]);
  });
});

describe("helpers", () => {
  it("normaliseEntries sorts keys and stringifies values", () => {
    expect(Object.keys(normaliseEntries({ b: 1, a: false, c: [] }))).toEqual(["a", "b", "c"]);
    expect(normaliseEntries({ a: false, c: [], d: "", e: 0 })).toEqual({
      a: "false",
      c: "[]",
      d: "",
      e: "0",
    });
  });

  it("version is independent of key order", async () => {
    const a = await buildPayload({ x: "1", y: "2" });
    const b = await buildPayload({ y: "2", x: "1" });
    expect(a.version).toBe(b.version);
    expect(Object.keys(b.entries)).toEqual(["x", "y"]);
  });

  it("ifNoneMatchMatches handles lists, weak tags and wildcard", () => {
    expect(ifNoneMatchMatches(null, "v")).toBe(false);
    expect(ifNoneMatchMatches('"v"', "v")).toBe(true);
    expect(ifNoneMatchMatches('"a", W/"v"', "v")).toBe(true);
    expect(ifNoneMatchMatches("*", "v")).toBe(true);
    expect(ifNoneMatchMatches("v", "v")).toBe(false);
  });
});
