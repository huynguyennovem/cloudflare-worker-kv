# Remote config contract

This is the reference for everything the modules of this repository share:

- the **HTTP API** that the [Worker](../worker/) serves, and that any other
  backend can implement instead;
- the **client behaviour** that every SDK implements the same way:
  [Flutter](../flutter/), [React Native](../react-native/),
  [Android](../android/) and [iOS](../ios/);
- the **shared test fixtures** in [`fixtures/`](fixtures/), which every SDK's
  test suite runs.

The Flutter package is the reference implementation. When this document and
an SDK disagree, fix whichever is wrong, then add a fixture case so the others
cannot drift.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. HTTP API

### Request

```
GET {endpoint}/v1/config?template={template}
Accept: application/json
X-Client-Key: <client key>        (optional)
If-None-Match: <ETag>             (optional)
```

- `template` defaults to `default` and MUST match `^[A-Za-z0-9_-]{1,64}$`.
- `X-Client-Key` is required only when the Worker sets `CLIENT_KEY`. It keeps
  casual traffic away; it is not a secret, because it ships inside the app.
- `If-None-Match` carries the `ETag` of the last `200` response, verbatim.

### Responses

| Status | Body | Meaning |
| --- | --- | --- |
| `200` | `{"version": "<opaque>", "entries": {"key": "value", ...}}` | The current config. Carries an `ETag` header, `"<version>"`. A template with no data has empty `entries`. |
| `304` | empty | `If-None-Match` matches the current version. |
| `400` | error | Invalid template name (`invalid_template`). |
| `401` | error | `CLIENT_KEY` is set and `X-Client-Key` is missing or wrong (`unauthorized`). |
| `404` / `405` | error | Unknown route / method. |
| `500` | error | `invalid_config`, `worker_misconfigured` or `too_many_keys`. |
| `503` | error | KV read failed (`kv_unavailable`). |

- The Worker always sends entry values as **strings**, with keys sorted.
  `version` is a SHA-256 of the entries, but clients MUST treat it as opaque.
- Error bodies are `{"error": "<code>", "message": "<text>"}`.
- A proxy, WAF or Cloudflare rate limiting rule in front of the Worker can
  also return `403` and `429` (with `Retry-After`), so clients handle them too.
- Every response carries CORS headers (`Access-Control-Allow-Origin: *`,
  `Access-Control-Expose-Headers: ETag`), so web builds need no extra setup.

## 2. Client behaviour

### 2.1 Endpoint and URL

A client is configured with an **endpoint** (the Worker's base URL, which may
include a path prefix and query parameters), a **template** and an optional
**client key**.

- The endpoint MUST have a scheme and a host; otherwise creating the client
  fails immediately (a programming error, not a fetch error).
- The template MUST match the pattern above; otherwise creating the client
  fails immediately.
- The request URL is built from the endpoint:
  1. remove one trailing `/` from the path, then append `/v1/config`;
  2. keep the scheme, host, port and existing query parameters;
  3. set `template`: replace an existing `template` parameter in place,
     otherwise append it;
  4. drop the fragment.

  Example: `https://a.dev/api/?x=1#frag` with template `staging` becomes
  `https://a.dev/api/v1/config?x=1&template=staging`.

### 2.2 Request headers

Send `Accept: application/json`; `X-Client-Key` when a client key is
configured; `If-None-Match` with the stored ETag when there is one. Send
nothing else: extra headers trigger CORS preflights on the web.

Clients MUST bypass any HTTP cache of the platform (so that a `304` is never
turned into a cached `200` behind the client's back, and vice versa), and
MUST enforce `fetchTimeout` as a limit on the **whole** request, including
reading the body.

### 2.3 Response handling

| Response | Outcome |
| --- | --- |
| `200` with a valid body | **Fetched**: a snapshot `{version, entries}` and the response `ETag` (verbatim, or none). |
| `200` with an invalid body | Error `invalid-response`. The body is invalid when it is not JSON, not an object, or has no `entries` object. |
| `304` after sending `If-None-Match` | **Not modified**. |
| `304` without sending `If-None-Match` | Error `invalid-response`. |
| `401`, `403` | Error `unauthorized`. |
| `429` | Error `throttled`. The throttle ends `Retry-After` seconds after the request (a non-negative integer, trimmed); if the header is missing or invalid, after 60 seconds. |
| anything else | Error `server-error`. The message includes the `error` and `message` fields of a JSON error body when present. |
| no response within `fetchTimeout` | Error `timeout`. |
| network failure | Error `network-error`. |

**Snapshot parsing.** `version` is used when it is a string; otherwise the
`ETag` with any `W/` prefix and surrounding quotes removed; otherwise `""`.
Entry values are normalised to strings, defensively, since the Worker already
sends strings:

- strings are kept as is;
- `null` values are dropped;
- integers and booleans become their JSON text (`42`, `true`);
- objects and arrays become compact JSON (`{"k":1}`, `[1,"two"]`), without
  escaping `/`.

### 2.4 Values

**Resolution order** for a key: the activated remote value, else the in-app
default, else a static value. Every value reports its **source**
(`remote`, `default` or `static`).

**Conversions** never throw. Values are trimmed before parsing:

| Conversion | Result |
| --- | --- |
| string | The raw value; `""` for static values. |
| bool | `true` when the lowercased value is one of `1`, `true`, `t`, `yes`, `y`, `on`; otherwise `false`. |
| int | A decimal integer with an optional sign; otherwise `0`. `"10.0"` gives `0`. |
| double | A decimal number with optional fraction and exponent; otherwise `0.0`. |

### 2.5 Defaults

`setDefaults` **replaces** all defaults. Strings are kept, numbers and
booleans are converted to text, maps/objects and lists/arrays are stored as
JSON text, and `null` values are ignored. Other types are rejected. Defaults
are never persisted: apps set them on every launch.

### 2.6 Settings

| Setting | Default | Rule |
| --- | --- | --- |
| `fetchTimeout` | 60 seconds | MUST be greater than zero. |
| `minimumFetchInterval` | 12 hours | MUST NOT be negative. Use `0` during development. |

Changing the settings replaces both values and persists them.

### 2.7 Fetch and activate

**`fetch`** downloads the config without changing what the getters return:

1. If a throttle is active (now is before the throttle end), set the status
   to *throttle* and fail with `throttled`, without a request.
2. If the last successful fetch is younger than `minimumFetchInterval`,
   return without a request. If the clock moved backwards (now is before the
   last successful fetch), ignore the interval.
3. Send the request with the stored ETag.
   - **Fetched:** store the new ETag (even when there is none). Keep the
     snapshot as *pending* only when its entries differ from the active
     entries (an empty config when nothing is active); otherwise clear the
     pending snapshot.
   - **Not modified:** keep whatever is pending or active.
   - Then record the time of this successful fetch, clear the throttle, and
     set the status to *success*.
4. On an error, set the status to *throttle* (and store the throttle end) for
   `throttled`, otherwise to *failure*, and rethrow the error. A failed fetch
   never changes the active or pending config, and does not start the
   `minimumFetchInterval`.
5. Persist the state after steps 3 and 4.

Concurrent `fetch` calls MUST share one request; all callers get its result
or its error.

**`activate`** makes the pending snapshot active and clears it, persists, and
returns `true`. With nothing pending it returns `false`.

**`fetchAndActivate`** calls both and returns the result of `activate`.

The **fetch status** is one of *no fetch yet*, *success*, *failure* and
*throttle*. The **last fetch time** is the time of the last successful fetch.

### 2.8 Persistence

Clients persist their state so the last activated config survives restarts,
and load it before the first read.

- The storage key is `cloudflare_worker_kv:{endpoint}|{template}`, with the
  endpoint as the app configured it, so every endpoint/template pair has its
  own cache.
- The value is JSON:

  ```json
  {
    "formatVersion": 1,
    "active": {"version": "v1", "entries": {"k": "v"}},
    "fetched": null,
    "etag": "\"v1\"",
    "lastSuccessfulFetchMs": 1767225600000,
    "throttleEndMs": null,
    "lastFetchStatus": "success",
    "settings": {"fetchTimeoutMs": 60000, "minimumFetchIntervalMs": 43200000}
  }
  ```

  `lastFetchStatus` is one of `noFetchYet`, `success`, `failure`, `throttle`.
  Missing values are written as `null`.
- Writes are serialised and the last write wins.
- Storage failures are logged, never thrown: fetching and reading keep working.
- A cache that is not valid JSON, not an object, or has a different
  `formatVersion`, or whose snapshots are malformed, is ignored: the client
  starts from a clean state. Invalid individual fields fall back to their
  defaults (a non-string ETag, non-integer times, an unknown status, invalid
  settings).

### 2.9 Instances

Each SDK offers a shared instance, created by an `initialize` call that loads
the cache and replaces any previous shared instance, plus the option to create
extra instances for other templates or Workers.

## 3. Not normative

These may differ between SDKs, and the fixtures avoid them:

- parsing of exotic numbers: hexadecimal, `NaN`, `Infinity`, type suffixes
  such as `1.5f`, digits outside ASCII, integers beyond 64 bits (or beyond
  2^53 in JavaScript);
- how defaults and entries print non-integer numbers (`0.0` becomes `"0"` in
  JavaScript and `"0.0"` in Dart), and the key order of multi-key objects;
- normalisation of unusual endpoints: upper-case schemes or hosts, default
  ports, percent-encoded or value-less query parameters.

## 4. Shared test fixtures

Every SDK loads these files from the repository checkout (not from its
published package) and runs every case:

| File | What it pins | Case shape |
| --- | --- | --- |
| [`value-conversions.json`](fixtures/value-conversions.json) | §2.4 conversions | `{raw, string, bool, int, double}`; `raw: null` is a static value |
| [`config-uri.json`](fixtures/config-uri.json) | §2.1 URL building | `{endpoint, template, expected}` or `{endpoint, template, error: true}` |
| [`responses.json`](fixtures/responses.json) | §2.3 response handling | `{name, sentEtag, status, headers, body, expect}` |

In `responses.json`, `expect` is one of:

- `{"result": "fetched", "version", "etag", "entries"}` (`etag` is `null` when
  the response has none);
- `{"result": "notModified"}`;
- `{"error": "<code>", "statusCode", "throttleSeconds"?, "messageContains"?}`,
  where the throttle end is the request time plus `throttleSeconds`.

Header names are case-insensitive. Test runners use a fixed clock for the
request time.

| SDK | Test |
| --- | --- |
| Flutter | [`flutter/test/conformance_test.dart`](../flutter/test/conformance_test.dart) |
| React Native | [`react-native/test/conformance.test.ts`](../react-native/test/conformance.test.ts) |
| Android | [`android/cloudflare-worker-kv/src/test/…/conformance/`](../android/cloudflare-worker-kv/src/test/kotlin/io/github/huynguyennovem/cloudflareworkerkv/conformance/) |
| iOS | [`ios/Tests/CloudflareWorkerKVTests/SharedFixtureTests.swift`](../ios/Tests/CloudflareWorkerKVTests/SharedFixtureTests.swift) |

## 5. API names across SDKs

Each SDK follows its platform's conventions and mirrors that platform's
Firebase Remote Config API, so the behaviour above hides behind different
names:

| Concept | Flutter | React Native | Android | iOS |
| --- | --- | --- | --- | --- |
| Shared instance | `initialize(endpoint:)`, `instance` | `initialize({endpoint})`, `instance` | `initialize(context, endpoint)`, `instance` | `initialize(endpoint:)`, `shared` |
| Settings | `RemoteConfigSettings` (`Duration`) | `{fetchTimeoutMillis, minimumFetchIntervalMillis}` | `remoteConfigSettings { }` (`Duration`) | `RemoteConfigSettings` (`TimeInterval`) |
| Typed getters | `getString` `getBool` `getInt` `getDouble` | `getString` `getBoolean` `getNumber` | `getString` `getBoolean` `getLong` `getDouble` | `rc[key].stringValue` `.boolValue` `.intValue` `.doubleValue` |
| Value | `getValue(key)` | `getValue(key)` | `getValue(key)` | `configValue(forKey:)` |
| All values | `getAll()` | `getAll()` | `getAll()` | `allValues()` |
| Source | `ValueSource.valueRemote` … | `'remote'` … | `ValueSource.REMOTE` … | `.remote` … |
| Fetch status | `lastFetchStatus` | `lastFetchStatus` | `info.lastFetchStatus` | `lastFetchStatus` |
| Last fetch time | `lastFetchTime` (epoch if never) | `fetchTimeMillis` (`-1` if never) | `info.fetchTimeMillis` (`-1` if never) | `lastFetchTime` (`nil` if never) |
| Error | `RemoteConfigException` | `RemoteConfigError` | `RemoteConfigException` | `RemoteConfigError` |
| Default storage | `shared_preferences` | AsyncStorage | `SharedPreferences` | `UserDefaults` |

The six error codes are the same strings everywhere: `timeout`,
`network-error`, `unauthorized`, `throttled`, `server-error`,
`invalid-response`.
