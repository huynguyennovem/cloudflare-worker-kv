import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { handleRequest, type Env } from "../src/config";
import type { ConfigPayload } from "../src/payload";
import { MIN_CACHE_TTL, MisconfiguredError, readSettings, resolvePattern } from "../src/settings";
import { BULK_GET_SIZE, createSourceDeps, MAX_KEYS, type SourceDeps } from "../src/sources";

const BASE = "https://config.example.com/v1/config";

type Vars = Omit<Env, "CONFIG_KV">;

function makeEnv(vars: Vars, kv: KVNamespace = env.CONFIG_KV): Env {
  return { CONFIG_KV: kv, ...vars };
}

async function fetchConfig(
  e: Env,
  template?: string,
  deps: SourceDeps = createSourceDeps(),
  headers: Record<string, string> = {},
): Promise<Response> {
  const url = template === undefined ? BASE : `${BASE}?template=${template}`;
  return handleRequest(new Request(url, { headers }), e, deps);
}

async function entriesOf(res: Response): Promise<Record<string, string>> {
  expect(res.status).toBe(200);
  return ((await res.json()) as ConfigPayload).entries;
}

async function errorOf(res: Response): Promise<{ status: number; error: string; message: string }> {
  const body = (await res.json()) as { error: string; message: string };
  return { status: res.status, ...body };
}

async function putAll(pairs: Record<string, string>): Promise<void> {
  await Promise.all(Object.entries(pairs).map(([k, v]) => env.CONFIG_KV.put(k, v)));
}

/** In-memory KV double that records calls and can paginate/fail on demand. */
class FakeKv {
  lists = 0;
  gets: number[] = [];
  failNext = false;
  constructor(
    public data: Map<string, string>,
    private pageSize = 1000,
  ) {}

  asKv(): KVNamespace {
    return this as unknown as KVNamespace;
  }

  async list(opts: { prefix?: string; cursor?: string; limit?: number }) {
    this.lists++;
    if (this.failNext) {
      this.failNext = false;
      throw new Error("KV down");
    }
    const names = [...this.data.keys()].filter((k) => k.startsWith(opts.prefix ?? "")).sort();
    const start = opts.cursor ? Number(opts.cursor) : 0;
    const size = Math.min(this.pageSize, opts.limit ?? 1000);
    const keys = names.slice(start, start + size).map((name) => ({ name }));
    const next = start + size;
    return next < names.length
      ? { keys, list_complete: false, cursor: String(next), cacheStatus: null }
      : { keys, list_complete: true, cacheStatus: null };
  }

  async get(keys: string | string[]) {
    if (!Array.isArray(keys)) return this.data.get(keys) ?? null;
    if (keys.length > BULK_GET_SIZE) throw new Error(`bulk get of ${keys.length} keys`);
    this.gets.push(keys.length);
    return new Map(keys.map((k) => [k, this.data.get(k) ?? null]));
  }
}

beforeEach(async () => {
  let cursor: string | undefined;
  do {
    const page = await env.CONFIG_KV.list({ cursor });
    await Promise.all(page.keys.map((k) => env.CONFIG_KV.delete(k.name)));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
});

describe("readSettings", () => {
  const kv = env.CONFIG_KV;

  it("uses defaults when nothing is set", () => {
    expect(readSettings({ CONFIG_KV: kv })).toEqual({
      source: "json",
      configKey: "config:{template}",
      keyPrefix: "",
      valueFormat: "raw",
      cacheTtl: 60,
    });
  });

  it("treats empty strings as unset and is case-insensitive", () => {
    const s = readSettings({ CONFIG_KV: kv, CONFIG_SOURCE: " KEYS ", VALUE_FORMAT: "Json", CACHE_TTL: "" });
    expect(s.source).toBe("keys");
    expect(s.valueFormat).toBe("json");
    expect(s.cacheTtl).toBe(60);
  });

  it("accepts CACHE_TTL as string or number", () => {
    expect(readSettings({ CONFIG_KV: kv, CACHE_TTL: " 300 " }).cacheTtl).toBe(300);
    expect(readSettings({ CONFIG_KV: kv, CACHE_TTL: 120 }).cacheTtl).toBe(120);
    expect(readSettings({ CONFIG_KV: kv, CACHE_TTL: String(MIN_CACHE_TTL) }).cacheTtl).toBe(MIN_CACHE_TTL);
  });

  it.each([
    [{ CONFIG_SOURCE: "yaml" }, "CONFIG_SOURCE"],
    [{ VALUE_FORMAT: "xml" }, "VALUE_FORMAT"],
    [{ CACHE_TTL: "abc" }, "CACHE_TTL"],
    [{ CACHE_TTL: "90.5" }, "CACHE_TTL"],
    [{ CACHE_TTL: "-60" }, "CACHE_TTL"],
    [{ CACHE_TTL: String(MIN_CACHE_TTL - 1) }, "CACHE_TTL"],
    [{ CONFIG_KEY: "  " }, "CONFIG_KEY"],
  ] as [Vars, string][])("rejects %j", (vars, name) => {
    expect(() => readSettings(makeEnv(vars))).toThrow(MisconfiguredError);
    expect(() => readSettings(makeEnv(vars))).toThrow(name);
  });

  it("ignores an empty CONFIG_KEY in keys mode", () => {
    expect(readSettings(makeEnv({ CONFIG_SOURCE: "keys", CONFIG_KEY: "" })).source).toBe("keys");
  });

  it("resolvePattern replaces every placeholder", () => {
    expect(resolvePattern("a/{template}/{template}", "x")).toBe("a/x/x");
    expect(resolvePattern("no-placeholder", "x")).toBe("no-placeholder");
  });

  it("reports misconfiguration as HTTP 500 worker_misconfigured", async () => {
    const res = await fetchConfig(makeEnv({ CONFIG_SOURCE: "yaml" }));
    expect(await errorOf(res)).toMatchObject({ status: 500, error: "worker_misconfigured" });
  });
});

describe("json source with a custom CONFIG_KEY", () => {
  it("reads a fixed key for every template", async () => {
    await putAll({ "app-config": JSON.stringify({ welcome: "Hi", max: 3 }) });
    const e = makeEnv({ CONFIG_KEY: "app-config" });
    expect(await entriesOf(await fetchConfig(e))).toEqual({ max: "3", welcome: "Hi" });
    expect(await entriesOf(await fetchConfig(e, "staging"))).toEqual({ max: "3", welcome: "Hi" });
  });

  it("substitutes {template}", async () => {
    await putAll({
      "remote-config/prod": JSON.stringify({ env: "prod" }),
      "remote-config/staging": JSON.stringify({ env: "staging" }),
    });
    const e = makeEnv({ CONFIG_KEY: "remote-config/{template}" });
    expect(await entriesOf(await fetchConfig(e, "prod"))).toEqual({ env: "prod" });
    expect(await entriesOf(await fetchConfig(e, "staging"))).toEqual({ env: "staging" });
    expect(await entriesOf(await fetchConfig(e, "missing"))).toEqual({});
  });
});

describe("keys source (real KV)", () => {
  beforeEach(async () => {
    await putAll({
      "rc:default:welcome": "Hello",
      "rc:default:max_items": "10",
      "rc:default:flags": '{"beta":true}',
      "rc:default:": "key equal to prefix is ignored",
      "rc:staging:welcome": "Staging",
      "session:abc": "unrelated data",
    });
  });

  it("strips the prefix and keeps raw values", async () => {
    const e = makeEnv({ CONFIG_SOURCE: "keys", KEY_PREFIX: "rc:{template}:" });
    expect(await entriesOf(await fetchConfig(e))).toEqual({
      flags: '{"beta":true}',
      max_items: "10",
      welcome: "Hello",
    });
    expect(await entriesOf(await fetchConfig(e, "staging"))).toEqual({ welcome: "Staging" });
    expect(await entriesOf(await fetchConfig(e, "nothing"))).toEqual({});
  });

  it("with an empty prefix exposes every key in the namespace", async () => {
    const e = makeEnv({ CONFIG_SOURCE: "keys" });
    const entries = await entriesOf(await fetchConfig(e));
    expect(Object.keys(entries)).toHaveLength(6);
    expect(entries["session:abc"]).toBe("unrelated data");
  });

  it("keeps numeric key names that bulk get leaves out of its Map", async () => {
    // workerd builds the bulk-get Map with SKIP_INDICES, so keys like "2024" are missing.
    await putAll({ "2024": "year", "7": "seven", "0": "zero" });
    const e = makeEnv({ CONFIG_SOURCE: "keys" });
    const entries = await entriesOf(await fetchConfig(e));
    expect(entries["2024"]).toBe("year");
    expect(entries["7"]).toBe("seven");
    expect(entries["0"]).toBe("zero");
    expect(entries.welcome).toBeUndefined(); // "rc:default:welcome" keeps its full name
    expect(entries["rc:default:welcome"]).toBe("Hello");
  });

  it("supports ETag / 304", async () => {
    const e = makeEnv({ CONFIG_SOURCE: "keys", KEY_PREFIX: "rc:{template}:" });
    const deps = createSourceDeps();
    const first = await fetchConfig(e, undefined, deps);
    const etag = first.headers.get("ETag")!;
    const second = await fetchConfig(e, undefined, deps, { "If-None-Match": etag });
    expect(second.status).toBe(304);
  });

  it("chunks bulk reads for more than BULK_GET_SIZE keys", async () => {
    const pairs: Record<string, string> = {};
    for (let i = 0; i < BULK_GET_SIZE * 2 + 17; i++) pairs[`bulk:p${String(i).padStart(3, "0")}`] = `v${i}`;
    await putAll(pairs);
    const e = makeEnv({ CONFIG_SOURCE: "keys", KEY_PREFIX: "bulk:" });
    const entries = await entriesOf(await fetchConfig(e));
    expect(Object.keys(entries)).toHaveLength(BULK_GET_SIZE * 2 + 17);
    expect(entries.p000).toBe("v0");
    expect(entries.p216).toBe("v216");
  });
});

describe("keys source VALUE_FORMAT", () => {
  const stored = {
    "v:quoted": '"hello"',
    "v:number": "42",
    "v:bool": "true",
    "v:object": '{ "a": [1, 2] }',
    "v:null": "null",
    "v:plain": "not json",
    "v:empty": "",
  };

  it("raw keeps stored text", async () => {
    await putAll(stored);
    const e = makeEnv({ CONFIG_SOURCE: "keys", KEY_PREFIX: "v:" });
    expect(await entriesOf(await fetchConfig(e))).toEqual({
      bool: "true",
      empty: "",
      null: "null",
      number: "42",
      object: '{ "a": [1, 2] }',
      plain: "not json",
      quoted: '"hello"',
    });
  });

  it("json decodes values and keeps non-JSON text", async () => {
    await putAll(stored);
    const e = makeEnv({ CONFIG_SOURCE: "keys", KEY_PREFIX: "v:", VALUE_FORMAT: "json" });
    expect(await entriesOf(await fetchConfig(e))).toEqual({
      bool: "true",
      empty: "",
      number: "42",
      object: '{"a":[1,2]}',
      plain: "not json",
      quoted: "hello",
    });
  });
});

describe("keys source (fake KV)", () => {
  const vars: Vars = { CONFIG_SOURCE: "keys", KEY_PREFIX: "p:", CACHE_TTL: "60" };

  function fakeWith(count: number, pageSize = 1000): FakeKv {
    const data = new Map<string, string>();
    for (let i = 0; i < count; i++) data.set(`p:k${String(i).padStart(4, "0")}`, String(i));
    return new FakeKv(data, pageSize);
  }

  it("follows list() cursors across short pages", async () => {
    const kv = fakeWith(7, 2);
    const entries = await entriesOf(await fetchConfig(makeEnv(vars, kv.asKv())));
    expect(Object.keys(entries)).toHaveLength(7);
    expect(kv.lists).toBe(4);
  });

  it("reads values in bulk chunks", async () => {
    const kv = fakeWith(250);
    await entriesOf(await fetchConfig(makeEnv(vars, kv.asKv())));
    expect(kv.gets).toEqual([100, 100, 50]);
  });

  it("rejects more than MAX_KEYS keys", async () => {
    const kv = fakeWith(MAX_KEYS + 1);
    const res = await fetchConfig(makeEnv(vars, kv.asKv()));
    expect(await errorOf(res)).toMatchObject({ status: 500, error: "too_many_keys" });
  });

  it("accepts exactly MAX_KEYS keys", async () => {
    const kv = fakeWith(MAX_KEYS);
    const entries = await entriesOf(await fetchConfig(makeEnv(vars, kv.asKv())));
    expect(Object.keys(entries)).toHaveLength(MAX_KEYS);
  });

  it("skips keys deleted between list() and get()", async () => {
    const kv = fakeWith(3);
    const realGet = kv.get.bind(kv);
    kv.get = async (keys: string | string[]) => {
      kv.data.delete("p:k0001");
      return realGet(keys);
    };
    const entries = await entriesOf(await fetchConfig(makeEnv(vars, kv.asKv())));
    expect(entries).toEqual({ k0000: "0", k0002: "2" });
  });

  it("caches the aggregate for CACHE_TTL seconds per prefix", async () => {
    let now = 1_000_000;
    const deps = createSourceDeps(() => now);
    const kv = fakeWith(2);
    const e = makeEnv({ ...vars, KEY_PREFIX: "p:{template}" }, kv.asKv());
    kv.data.set("p:defaultA", "1");

    await fetchConfig(e, undefined, deps);
    await fetchConfig(e, undefined, deps);
    expect(kv.lists).toBe(1);

    await fetchConfig(e, "other", deps); // different prefix -> separate entry
    expect(kv.lists).toBe(2);

    now += 59_999;
    await fetchConfig(e, undefined, deps);
    expect(kv.lists).toBe(2);

    now += 1;
    kv.data.set("p:defaultA", "2");
    const entries = await entriesOf(await fetchConfig(e, undefined, deps));
    expect(kv.lists).toBe(3);
    expect(entries.A).toBe("2");
  });

  it("serves concurrent requests on a cold cache", async () => {
    const deps = createSourceDeps();
    const kv = fakeWith(5);
    const e = makeEnv(vars, kv.asKv());
    const responses = await Promise.all([1, 2, 3].map(() => fetchConfig(e, undefined, deps)));
    expect(responses.map((r) => r.status)).toEqual([200, 200, 200]);
    await fetchConfig(e, undefined, deps);
    expect(kv.lists).toBe(3); // no promise sharing; the 4th request is a cache hit
  });

  it("does not cache failures", async () => {
    const deps = createSourceDeps();
    const kv = fakeWith(2);
    kv.failNext = true;
    const e = makeEnv(vars, kv.asKv());
    expect((await fetchConfig(e, undefined, deps)).status).toBe(503);
    expect((await fetchConfig(e, undefined, deps)).status).toBe(200);
    expect(kv.lists).toBe(2);
  });

  it("json source does not use the isolate cache", async () => {
    const deps = createSourceDeps();
    await putAll({ "config:default": '{"a":"1"}' });
    await fetchConfig(makeEnv({}), undefined, deps);
    expect(deps.cache.size).toBe(0);
  });
});
